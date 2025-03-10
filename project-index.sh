#!/usr/bin/env bash

# Configuration
PROJECT_DIRS=("$HOME/test-projects")  # Directories to scan for projects
CACHE_DIR="$HOME/.cache/project-index"
CACHE_FILE="$CACHE_DIR/projects.cache"
RECENT_FILE="$CACHE_DIR/recent.cache"
LOCK_FILE="$CACHE_DIR/index.lock"
PID_FILE="$CACHE_DIR/monitor.pid"
MAX_RECENT=5

# Create cache directory if it doesn't exist
mkdir -p "$CACHE_DIR"

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
  echo "Building project index..."
  
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
      echo "Found $(wc -l < "$CACHE_FILE") projects"
    else
      echo "No projects found"
      rm "$tmp_cache"
      > "$CACHE_FILE"  # Create empty cache file
    fi
  ) 200>"$LOCK_FILE"
}

# Function to start file monitoring as a separate daemon process
start_monitoring() {
  if ! command -v inotifywait &> /dev/null; then
    echo "inotifywait not found. Install inotify-tools for file monitoring."
    return 1
  fi
  
  # Check if monitoring is already running
  if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    echo "Monitoring is already running with PID $(cat "$PID_FILE")"
    return 0
  fi
  
  # Start the monitoring daemon
  nohup bash -c '
    # Write PID to file
    echo $$ > '"$PID_FILE"'
    
    echo "Starting file monitoring for .project.nix changes..."
    
    # Ensure the cache is built before starting
    '"$(realpath "$0")"' build
    
    while true; do
      dirs=()
      for dir in '"${PROJECT_DIRS[*]}"'; do
        if [ -d "$dir" ]; then
          dirs+=("$dir")
        fi
      done
      
      if [ ${#dirs[@]} -eq 0 ]; then
        echo "No valid directories to monitor"
        exit 1
      fi
      
      # Monitor directories for changes
      inotifywait -q -r -e create,modify,delete,move "${dirs[@]}" --format "%w%f" | grep -q "\.project\.nix$"
      
      # Small delay to avoid excessive rebuilds
      sleep 1
      
      # Rebuild cache
      '"$(realpath "$0")"' build
    done
  ' > /dev/null 2>&1 &
  
  # Wait a moment to confirm it started
  sleep 1
  if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    echo "Monitoring started with PID $(cat "$PID_FILE")"
    return 0
  else
    echo "Failed to start monitoring daemon"
    return 1
  fi
}

# Function to stop monitoring
stop_monitoring() {
  if [ -f "$PID_FILE" ]; then
    if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
      echo "Stopping monitoring process (PID: $(cat "$PID_FILE"))..."
      kill $(cat "$PID_FILE")
      rm "$PID_FILE"
      return 0
    else
      echo "No active monitoring process found. Removing stale PID file."
      rm "$PID_FILE"
      return 1
    fi
  else
    echo "No monitoring process found."
    return 1
  fi
}

# Function to check monitoring status
monitor_status() {
  if [ -f "$PID_FILE" ]; then
    if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
      echo "Monitoring is running with PID $(cat "$PID_FILE")"
      return 0
    else
      echo "Monitoring process is not running but PID file exists. Removing stale PID file."
      rm "$PID_FILE"
      return 1
    fi
  else
    echo "Monitoring is not running."
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

# Function to get recent projects
get_recent_projects() {
  if [ -f "$RECENT_FILE" ]; then
    cat "$RECENT_FILE" | awk -F'|' '{print $1}'
  fi
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

# Function to save project state
save_project_state() {
  local project_name="$1"
  local workspace="$2"
  local state_dir="$CACHE_DIR/states/$project_name"
  mkdir -p "$state_dir"
  
  # Check if Hyprland is running
  if pgrep -x "Hyprland" > /dev/null; then
    # Save window layout
    hyprctl clients -j > "$state_dir/windows.json"
    
    # TODO: Save open files and terminal history
    # This would require application-specific integration
  fi
  
  echo "Project state saved: $project_name"
}

# Function to restore project state
restore_project_state() {
  local project_name="$1"
  local workspace="$2"
  local state_dir="$CACHE_DIR/states/$project_name"
  
  if [ ! -d "$state_dir" ]; then
    echo "No saved state found for project: $project_name"
    return 1
  fi
  
  # Check if Hyprland is running
  if pgrep -x "Hyprland" > /dev/null && [ -f "$state_dir/windows.json" ]; then
    # TODO: Restore window layout
    # This would require parsing the windows.json and issuing hyprctl commands
    echo "Restoring window layout for project: $project_name"
  fi
  
  # TODO: Restore open files and terminal history
  
  echo "Project state restored: $project_name"
}

# Function to open the selected project
open_project() {
  project_name="$1"
  
  if [ -z "$project_name" ]; then
    echo "No project selected"
    exit 1
  fi
  
  # Find project in cache
  project_line=$(grep -m 1 "^$project_name|" "$CACHE_FILE")
  
  if [ -z "$project_line" ]; then
    echo "Project not found in cache"
    exit 1
  fi
  
  # Parse project information
  IFS='|' read -r name workspace directory config_file tags <<< "$project_line"
  
  echo "Opening project: $name"
  echo "Workspace: $workspace"
  echo "Directory: $directory"
  echo "Config: $config_file"
  
  # Record access
  record_access "$name"
  
  # Check for saved state
  local state_dir="$CACHE_DIR/states/$name"
  local has_saved_state=false
  
  if [ -d "$state_dir" ] && [ -f "$state_dir/windows.json" ]; then
    has_saved_state=true
  fi
  
  # Check if Hyprland is running
  if pgrep -x "Hyprland" > /dev/null; then
    # Switch to workspace
    hyprctl dispatch workspace "$workspace"
    
    if [ "$has_saved_state" = true ]; then
      # Ask if user wants to restore state
      if [ -n "$DISPLAY" ]; then
        if rofi -dmenu -p "Restore previous state for $name?" <<< $'Yes\nNo' | grep -q "Yes"; then
          restore_project_state "$name" "$workspace"
          return
        fi
      else
        read -p "Restore previous state for $name? (y/N) " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          restore_project_state "$name" "$workspace"
          return
        fi
      fi
    fi
    
    # Parse environment from .project.nix and set up
    if command -v nix-instantiate &> /dev/null && command -v jq &> /dev/null; then
      local json=$(nix-instantiate --eval --json "$config_file" 2>/dev/null)
      
      if [ $? -eq 0 ]; then
        local env_items=$(echo "$json" | jq -c '.environment[]? // empty')
        
        if [ -n "$env_items" ]; then
          echo "$env_items" | while read -r item; do
            local type=$(echo "$item" | jq -r '.type // empty')
            local command=$(echo "$item" | jq -r '.command // empty')
            local position=$(echo "$item" | jq -r '.position // empty')
            local url=$(echo "$item" | jq -r '.url // empty')
            local files=$(echo "$item" | jq -r '.files // empty | if type == "array" then join(" ") else empty end')
            
            case "$type" in
              "terminal")
                if [ -n "$command" ]; then
                  hyprctl dispatch exec -- "alacritty --working-directory $directory -e bash -c '$command; exec bash'"
                else
                  hyprctl dispatch exec -- "alacritty --working-directory $directory"
                fi
                ;;
              "editor")
                if [ -n "$files" ] && [ -n "$command" ]; then
                  hyprctl dispatch exec -- "alacritty --working-directory $directory -e bash -c '$command $files'"
                elif [ -n "$command" ]; then
                  hyprctl dispatch exec -- "alacritty --working-directory $directory -e bash -c '$command'"
                fi
                ;;
              "browser")
                if [ -n "$url" ]; then
                  hyprctl dispatch exec -- "xdg-open $url"
                fi
                ;;
            esac
            
            # Small delay to allow windows to open
            sleep 0.5
          done
          
          # Save initial state
          save_project_state "$name" "$workspace"
          return
        fi
      fi
    fi
    
    # Fallback if parsing fails
    hyprctl dispatch exec -- "alacritty --working-directory $directory"
  else
    # Fallback for non-Hyprland environments
    cd "$directory" && exec $SHELL
  fi
}

# Main script logic
case "$1" in
  "build")
    build_cache
    ;;
  "monitor")
    start_monitoring
    ;;
  "stop-monitor")
    stop_monitoring
    ;;
  "monitor-status")
    monitor_status
    ;;
  "rofi")
    project=$(select_project_rofi)
    [ -n "$project" ] && open_project "$project"
    ;;
  "fzf")
    project=$(select_project_fzf)
    [ -n "$project" ] && open_project "$project"
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
  "save")
    if [ -z "$2" ]; then
      echo "Usage: $(basename "$0") save <project_name>"
      exit 1
    fi
    project_line=$(grep -m 1 "^$2|" "$CACHE_FILE")
    if [ -n "$project_line" ]; then
      IFS='|' read -r name workspace directory config_file tags <<< "$project_line"
      save_project_state "$name" "$workspace"
    else
      echo "Project not found: $2"
      exit 1
    fi
    ;;
  "restore")
    if [ -z "$2" ]; then
      echo "Usage: $(basename "$0") restore <project_name>"
      exit 1
    fi
    project_line=$(grep -m 1 "^$2|" "$CACHE_FILE")
    if [ -n "$project_line" ]; then
      IFS='|' read -r name workspace directory config_file tags <<< "$project_line"
      restore_project_state "$name" "$workspace"
    else
      echo "Project not found: $2"
      exit 1
    fi
    ;;
  *)
    echo "Usage: $(basename "$0") [command]"
    echo "Commands:"
    echo "  build           - Scan directories and build project cache"
    echo "  monitor         - Start file monitoring for project changes"
    echo "  stop-monitor    - Stop the monitoring process"
    echo "  monitor-status  - Check if monitoring is running"
    echo "  rofi            - Select a project using rofi"
    echo "  fzf             - Select a project using fzf"
    echo "  list            - List all projects"
    echo "  list-recent     - List recently opened projects"
    echo "  save <name>     - Save current state of a project"
    echo "  restore <name>  - Restore saved state of a project"
    ;;
esac
