#!/usr/bin/env bash

# Ensure script uses absolute paths to avoid context-dependent issues
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# Configuration
PROJECT_DIRS=("$HOME/test-projects")  # Directories to scan for projects
CACHE_DIR="$HOME/.cache/project-index"
CACHE_FILE="$CACHE_DIR/projects.cache"
RECENT_FILE="$CACHE_DIR/recent.cache"
LOCK_FILE="$CACHE_DIR/index.lock"
PID_FILE="$CACHE_DIR/monitor.pid"
LOG_FILE="$CACHE_DIR/project-index.log"
INSTANCE_LOCK="$CACHE_DIR/instance.lock"
MAX_RECENT=5

# Enable logging
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Create cache directory if it doesn't exist
mkdir -p "$CACHE_DIR"
touch "$LOG_FILE"

# Ensure only one instance runs at a time for interactive commands
acquire_instance_lock() {
  exec 8>"$INSTANCE_LOCK"
  if ! flock -n 8; then
    log "Another instance is already running. Exiting."
    exit 0
  fi
  # Lock will be automatically released when the script exits
}

# Function to extract information from .project.nix files
parse_project_nix() {
  local file="$1"
  local project_dir=$(dirname "$file")
  
  # Parse using nix-instantiate if available (better parsing)
  if command -v nix-instantiate &> /dev/null; then
    # Convert Nix expression to JSON for easier parsing
    local json=$(nix-instantiate --eval --json "$file" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
      # Extract using jq if available
      if command -v jq &> /dev/null; then
        local project_name=$(echo "$json" | jq -r '.projectName // empty')
        local workspace=$(echo "$json" | jq -r '.workspace // empty')
        local tags=$(echo "$json" | jq -r '.tags // empty | if type == "array" then join(",") else empty end')
      else
        # Fallback to grep for basic extraction
        local project_name=$(grep -m 1 "projectName" "$file" | sed -E 's/.*projectName\s*=\s*"([^"]*)".*/\1/')
        local workspace=$(grep -m 1 "workspace" "$file" | sed -E 's/.*workspace\s*=\s*([0-9]+).*/\1/')
        local tags=$(grep -m 1 "tags" "$file" | grep -o '\[.*\]' | tr -d '[]" ' | tr ',' ',')
      fi
    else
      # Fallback to grep for basic extraction
      local project_name=$(grep -m 1 "projectName" "$file" | sed -E 's/.*projectName\s*=\s*"([^"]*)".*/\1/')
      local workspace=$(grep -m 1 "workspace" "$file" | sed -E 's/.*workspace\s*=\s*([0-9]+).*/\1/')
      local tags=$(grep -m 1 "tags" "$file" | grep -o '\[.*\]' | tr -d '[]" ' | tr ',' ',')
    fi
  else
    # Fallback to grep for basic extraction
    local project_name=$(grep -m 1 "projectName" "$file" | sed -E 's/.*projectName\s*=\s*"([^"]*)".*/\1/')
    local workspace=$(grep -m 1 "workspace" "$file" | sed -E 's/.*workspace\s*=\s*([0-9]+).*/\1/')
    local tags=$(grep -m 1 "tags" "$file" | grep -o '\[.*\]' | tr -d '[]" ' | tr ',' ',')
  fi
  
  # If project name not found, use directory name
  if [ -z "$project_name" ]; then
    project_name=$(basename "$project_dir")
  fi
  
  # Default workspace if not specified
  if [ -z "$workspace" ]; then
    workspace="1"
  fi
  
  echo "$project_name|$workspace|$project_dir|$file|$tags"
}

# Function to scan for .project.nix files and build cache
build_cache() {
  log "Building project index..."
  
  # Use flock to ensure only one process updates the cache at a time
  (
    flock -x 200
    
    # Create a temporary file for the new cache
    local tmp_cache=$(mktemp)
    
    for dir in "${PROJECT_DIRS[@]}"; do
      if [ -d "$dir" ]; then
        find "$dir" -type f -name ".project.nix" -print0 | while IFS= read -r -d '' file; do
          parse_project_nix "$file" >> "$tmp_cache"
        done
      fi
    done
    
    # Sort and remove duplicates before replacing the cache file
    if [ -s "$tmp_cache" ]; then
      sort -u "$tmp_cache" > "$CACHE_FILE"
      rm "$tmp_cache"
      log "Found $(wc -l < "$CACHE_FILE") projects"
    else
      log "No projects found"
      rm "$tmp_cache"
      > "$CACHE_FILE"  # Create empty cache file
    fi
  ) 200>"$LOCK_FILE"
}

# Function to start file monitoring as a separate daemon process
start_monitoring() {
  if ! command -v inotifywait &> /dev/null; then
    log "inotifywait not found. Install inotify-tools for file monitoring."
    return 1
  fi
  
  # Check if monitoring is already running
  if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    log "Monitoring is already running with PID $(cat "$PID_FILE")"
    return 0
  fi
  
  # Start the monitoring daemon
  nohup bash -c '
    # Write PID to file
    echo $$ > '"$PID_FILE"'
    
    echo "Starting file monitoring for .project.nix changes..." >> '"$LOG_FILE"'
    
    # Ensure the cache is built before starting
    '"$SCRIPT_PATH"' build
    
    while true; do
      dirs=()
      for dir in '"${PROJECT_DIRS[*]}"'; do
        if [ -d "$dir" ]; then
          dirs+=("$dir")
        fi
      done
      
      if [ ${#dirs[@]} -eq 0 ]; then
        echo "No valid directories to monitor" >> '"$LOG_FILE"'
        exit 1
      fi
      
      # Monitor directories for changes
      inotifywait -q -r -e create,modify,delete,move "${dirs[@]}" --format "%w%f" | grep -q "\.project\.nix$"
      
      # Small delay to avoid excessive rebuilds
      sleep 1
      
      # Rebuild cache
      '"$SCRIPT_PATH"' build
    done
  ' > /dev/null 2>&1 &
  
  # Wait a moment to confirm it started
  sleep 1
  if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    log "Monitoring started with PID $(cat "$PID_FILE")"
    return 0
  else
    log "Failed to start monitoring daemon"
    return 1
  fi
}

# Function to record project access
record_access() {
  local project_name="$1"
  local timestamp=$(date +%s)
  
  # Create recent file if it doesn't exist
  touch "$RECENT_FILE"
  
  # Add new entry at the beginning
  local tmp_file=$(mktemp)
  echo "$project_name|$timestamp" > "$tmp_file"
  
  # Add existing entries, excluding the current project
  grep -v "^$project_name|" "$RECENT_FILE" | head -n $((MAX_RECENT - 1)) >> "$tmp_file"
  
  # Replace recent file
  mv "$tmp_file" "$RECENT_FILE"
}

# Function to format project list with recent projects first
format_project_list() {
  local tmp_file=$(mktemp)
  
  # Get recent projects first (if recent file exists)
  if [ -f "$RECENT_FILE" ]; then
    while IFS='|' read -r recent_name recent_time; do
      grep "^$recent_name|" "$CACHE_FILE" | \
        awk -F'|' '{print $0 "|" 1}' >> "$tmp_file"
    done < "$RECENT_FILE"
  fi
  
  # Add remaining projects
  if [ -f "$RECENT_FILE" ]; then
    recent_names=$(awk -F'|' '{print $1}' "$RECENT_FILE" | paste -s -d'|')
    if [ -n "$recent_names" ]; then
      grep -v -E "^($recent_names)\\|" "$CACHE_FILE" | \
        awk -F'|' '{print $0 "|" 0}' >> "$tmp_file"
    else
      cat "$CACHE_FILE" | awk -F'|' '{print $0 "|" 0}' >> "$tmp_file"
    fi
  else
    cat "$CACHE_FILE" | awk -F'|' '{print $0 "|" 0}' >> "$tmp_file"
  fi
  
  # Return sorted list with unique entries only
  sort -t'|' -k6,6nr -k1,1 -u "$tmp_file"
  rm "$tmp_file"
}

# Function to select project using rofi
select_project_rofi() {
  if [ ! -f "$CACHE_FILE" ] || [ $(wc -l < "$CACHE_FILE") -eq 0 ]; then
    build_cache
  fi
  
  # Format projects for rofi with recent projects first and tags
  format_project_list | awk -F'|' '{
    if ($5 != "") {
      printf "%s (ws:%s) [%s]", $1, $2, $5
    } else {
      printf "%s (ws:%s)", $1, $2
    }
    if ($6 == 1) printf " ★";
    print ""
  }' | \
  rofi -dmenu -i -p "Select Project" | \
  sed -E 's/ \(ws:[0-9]+\)( \[.*\])?( ★)?$//'
}

# Function to select project using fzf (for terminal use)
select_project_fzf() {
  if [ ! -f "$CACHE_FILE" ] || [ $(wc -l < "$CACHE_FILE") -eq 0 ]; then
    build_cache
  fi
  
  # Format projects for fzf with recent projects first and tags
  selected=$(format_project_list | awk -F'|' '{
    if ($5 != "") {
      printf "%s (ws:%s) [%s] - %s", $1, $2, $5, $3
    } else {
      printf "%s (ws:%s) - %s", $1, $2, $3
    }
    if ($6 == 1) printf " ★";
    print ""
  }' | \
  fzf --height 40% --reverse --prompt="Select Project > ")
  
  echo "$selected" | sed -E 's/ \(ws:[0-9]+\)( \[.*\])?( - .*)?( ★)?$//'
}

# Function to open the selected project
open_project() {
  local project_name="$1"
  
  if [ -z "$project_name" ]; then
    log "No project selected"
    exit 0
  fi
  
  # Find project in cache
  local project_line=$(grep -m 1 "^$project_name|" "$CACHE_FILE")
  
  if [ -z "$project_line" ]; then
    log "Project not found in cache: $project_name"
    exit 1
  fi
  
  # Parse project information
  local name workspace directory config_file tags
  IFS='|' read -r name workspace directory config_file tags <<< "$project_line"
  
  log "Opening project: $name (workspace: $workspace, directory: $directory)"
  
  # Record access
  record_access "$name"
  
  # Determine execution context (terminal or hotkey)
  local is_terminal=false
  if [ -t 0 ]; then
    log "Running in terminal context"
    is_terminal=true
  else
    log "Running in non-terminal context (likely hotkey)"
  fi
  
  # Check if Hyprland is running
  if pgrep -x "Hyprland" > /dev/null; then
    # Switch to workspace
    log "Switching to workspace $workspace"
    hyprctl dispatch workspace "$workspace"
    
    # Parse environment from .project.nix and set up
    if command -v nix-instantiate &> /dev/null && command -v jq &> /dev/null; then
      local json=$(nix-instantiate --eval --json "$config_file" 2>/dev/null)
      
      if [ $? -eq 0 ]; then
        local env_items=$(echo "$json" | jq -c '.environment[]? // empty')
        
        if [ -n "$env_items" ]; then
          log "Setting up environment from .project.nix"
          echo "$env_items" | while read -r item; do
            local type=$(echo "$item" | jq -r '.type // empty')
            local command=$(echo "$item" | jq -r '.command // empty')
            local position=$(echo "$item" | jq -r '.position // empty')
            local url=$(echo "$item" | jq -r '.url // empty')
            local files=$(echo "$item" | jq -r '.files // empty | if type == "array" then join(" ") else empty end')
            
            case "$type" in
              "terminal")
                if [ -n "$command" ]; then
                  log "Launching terminal with command: $command"
                  hyprctl dispatch exec -- "alacritty --working-directory $directory -e bash -c '$command; exec bash'"
                else
                  log "Launching terminal in directory: $directory"
                  hyprctl dispatch exec -- "alacritty --working-directory $directory"
                fi
                ;;
              "editor")
                if [ -n "$files" ] && [ -n "$command" ]; then
                  log "Launching editor with files: $command $files"
                  hyprctl dispatch exec -- "alacritty --working-directory $directory -e bash -c '$command $files'"
                elif [ -n "$command" ]; then
                  log "Launching editor: $command"
                  hyprctl dispatch exec -- "alacritty --working-directory $directory -e bash -c '$command'"
                fi
                ;;
              "browser")
                if [ -n "$url" ]; then
                  log "Opening URL: $url"
                  hyprctl dispatch exec -- "xdg-open $url"
                fi
                ;;
            esac
            
            # Small delay to allow windows to open
            sleep 0.5
          done
          
          log "Environment setup completed for project: $name"
          exit 0
        fi
      else
        log "Failed to parse .project.nix file: $config_file"
      fi
    fi
    
    # Fallback if parsing fails or not available
    log "Using fallback: opening terminal in project directory"
    hyprctl dispatch exec -- "alacritty --working-directory $directory"
    exit 0
  else
    # Running in terminal but not in Hyprland
    if [ "$is_terminal" = true ]; then
      log "Changing directory to: $directory"
      # Cannot directly change directory of parent shell, provide a message
      echo "Project directory: $directory"
      echo "Run: cd \"$directory\""
      # For convenience, if SHELL is bash and we're in an interactive session, try to cd
      if [[ -n "$BASH" && $- == *i* ]]; then
        cd "$directory" || return 1
      fi
    else
      log "Not running in Hyprland or terminal, no action taken"
    fi
  fi
}

# Main script logic
# Acquire lock for interactive commands that shouldn't run concurrently
case "$1" in
  "rofi"|"fzf")
    acquire_instance_lock
    ;;
esac

case "$1" in
  "build")
    build_cache
    ;;
  "monitor")
    start_monitoring
    ;;
  "stop-monitor")
    if [ -f "$PID_FILE" ]; then
      if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        log "Stopping monitoring process (PID: $(cat "$PID_FILE"))..."
        kill $(cat "$PID_FILE")
        rm -f "$PID_FILE"
      else
        log "No active monitoring process found. Removing stale PID file."
        rm -f "$PID_FILE"
      fi
    else
      log "No monitoring process found."
    fi
    ;;
  "monitor-status")
    if [ -f "$PID_FILE" ]; then
      if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        echo "Monitoring is running with PID $(cat "$PID_FILE")"
      else
        echo "Monitoring process is not running but PID file exists. Removing stale PID file."
        rm -f "$PID_FILE"
      fi
    else
      echo "Monitoring is not running."
    fi
    ;;
  "rofi")
    log "Starting rofi selection"
    project=$(select_project_rofi)
    log "Selected project: $project"
    if [ -n "$project" ]; then
      open_project "$project"
    else
      log "No project selected"
    fi
    ;;
  "fzf")
    log "Starting fzf selection"
    project=$(select_project_fzf)
    log "Selected project: $project"
    if [ -n "$project" ]; then
      open_project "$project"
    else
      log "No project selected"
    fi
    ;;
  "list")
    if [ ! -f "$CACHE_FILE" ]; then
      build_cache
    fi
    format_project_list | awk -F'|' '{
      printf "%s (workspace: %s)", $1, $2
      if ($5 != "") printf " [%s]", $5
      printf " - %s", $3
      if ($6 == 1) printf " ★"
      print ""
    }'
    ;;
  "list-recent")
    if [ -f "$RECENT_FILE" ]; then
      awk -F'|' '{
        cmd = "date -d @" $2 " +\"%Y-%m-%d %H:%M:%S\""
        cmd | getline date
        close(cmd)
        printf "%s (last opened: %s)\n", $1, date
      }' "$RECENT_FILE"
    else
      echo "No recent projects found"
    fi
    ;;
  "open")
    if [ -z "$2" ]; then
      echo "Usage: $(basename "$0") open <project_name>"
      exit 1
    fi
    acquire_instance_lock
    open_project "$2"
    ;;
  "help")
    echo "Project Indexer - Quickly switch between development environments"
    echo ""
    echo "Usage: $(basename "$0") [command]"
    echo ""
    echo "Commands:"
    echo "  build           - Scan directories and build project cache"
    echo "  monitor         - Start file monitoring for project changes"
    echo "  stop-monitor    - Stop the monitoring process"
    echo "  monitor-status  - Check if monitoring is running"
    echo "  rofi            - Select a project using rofi"
    echo "  fzf             - Select a project using fzf"
    echo "  list            - List all projects"
    echo "  list-recent     - List recently opened projects"
    echo "  open <name>     - Directly open a project by name"
    echo "  help            - Show this help message"
    ;;
  *)
    if [ -z "$1" ]; then
      # Default action when no command is provided
      acquire_instance_lock
      log "No command specified, using default rofi selector"
      project=$(select_project_rofi)
      if [ -n "$project" ]; then
        open_project "$project"
      fi
    else
      echo "Unknown command: $1"
      echo "Run '$(basename "$0") help' for usage information"
      exit 1
    fi
    ;;
esac

# Exit gracefully
exit 0
