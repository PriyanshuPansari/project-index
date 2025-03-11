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

# Debug level: ERROR, WARN, INFO, DEBUG
DEBUG_LEVEL=${DEBUG_LEVEL:-INFO}

# Create cache directory if it doesn't exist
mkdir -p "$CACHE_DIR"
touch "$LOG_FILE"

is_hyprland_running() {
  # Check using command presence and execution
  if command -v hyprctl &> /dev/null && hyprctl monitors &> /dev/null; then
    debug_log DEBUG "Hyprland detected via hyprctl"
    return 0  # Success - Hyprland is running
  fi
  
  # Check using process name (more flexible matching)
  if pgrep -f "Hyprland" &> /dev/null || pgrep -i "hypr" &> /dev/null; then
    # Process is found, but check if hyprctl is available
    if command -v hyprctl &> /dev/null; then
      debug_log DEBUG "Hyprland detected via process name"
      return 0  # Success - Hyprland is running
    fi
  fi

  # Check for Hyprland environment variables
  if [[ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]]; then
    debug_log DEBUG "Hyprland detected via environment variables"
    return 0  # Success - Hyprland environment variables are set
  fi
  
  debug_log DEBUG "Hyprland not detected"
  return 1  # Failed - Hyprland is not running
}
#Enhanced logging function with debug levels
# Usage: debug_log [ERROR|WARN|INFO|DEBUG] "message"
debug_log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  # Always print to log file regardless of DEBUG_LEVEL
  echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

  # Also print to stdout if DEBUG_LEVEL includes this level
  case "$level" in
    ERROR)
      echo -e "\e[31m[$level] $message\e[0m" ;;  # Red
    WARN)
      [[ "$DEBUG_LEVEL" =~ (WARN|INFO|DEBUG) ]] && echo -e "\e[33m[$level] $message\e[0m" ;;  # Yellow
    INFO)
      [[ "$DEBUG_LEVEL" =~ (INFO|DEBUG) ]] && echo -e "\e[36m[$level] $message\e[0m" ;;  # Cyan
    DEBUG)
      [[ "$DEBUG_LEVEL" == "DEBUG" ]] && echo -e "\e[90m[$level] $message\e[0m" ;;  # Gray
  esac
}

# Legacy log function for backward compatibility
log() {
  debug_log INFO "$*"
}

# Function to trace command execution
# Usage: trace_exec "command to execute"
trace_exec() {
  local cmd="$1"
  debug_log DEBUG "Executing: $cmd"
  eval "$cmd"
  local status=$?
  debug_log DEBUG "Command exited with status: $status"
  return $status
}

# Ensure only one instance runs at a time for interactive commands
acquire_instance_lock() {
  exec 8>"$INSTANCE_LOCK"
  if ! flock -n 8; then
    debug_log WARN "Another instance is already running. Exiting."
    exit 0
  fi
  # Lock will be automatically released when the script exits
}

# Function to extract information from .project.nix files
parse_project_nix() {
  local file="$1"
  local project_dir=$(dirname "$file")

  # Create a temporary Nix expression to extract and format the data
  local tmp_nix=$(mktemp --suffix=.nix)

  # Write a Nix expression that imports the project file and formats the output
  cat > "$tmp_nix" << 'EOF'
let 
  getAttrOr = attr: default: set: 
    if builtins.hasAttr attr set then builtins.getAttr attr set else default;

  formatList = list:
    if builtins.isList list then builtins.concatStringsSep "," list else "";

  projectFile = import ./project-file.nix;

  # Extract values with defaults
  name = getAttrOr "projectName" (builtins.baseNameOf (builtins.getEnv "PROJECT_DIR")) projectFile;
  workspace = toString (getAttrOr "workspace" 1 projectFile);
  tags = formatList (getAttrOr "tags" [] projectFile);
in
  "${name}|${workspace}|${tags}"
EOF

  # Create a symlink to the actual project file
  ln -sf "$file" "$(dirname "$tmp_nix")/project-file.nix"

  # Set the project directory as an environment variable
  export PROJECT_DIR="$project_dir"

  # Evaluate the Nix expression
  local result
  result=$(nix-instantiate --eval --strict "$tmp_nix" 2>/dev/null)

  # Clean up temporary files
  rm -f "$tmp_nix" "$(dirname "$tmp_nix")/project-file.nix"

  # Process the result (remove quotes)
  result=$(echo "$result" | tr -d '"')

  if [ -n "$result" ]; then
    # IMPORTANT: Output fields in the correct order
    # Format: name|workspace|tags|directory|config_file
    echo "$result|$project_dir|$file"
  else
    # Fallback if Nix parsing fails
    local project_name=$(basename "$project_dir")
    echo "$project_name|1||$project_dir|$file"
  fi
}

# Function to extract project environment from .project.nix files
extract_project_environment() {
  local config_file="$1"
  local tmp_nix=$(mktemp --suffix=.nix)

  debug_log DEBUG "Extracting environment from: $config_file"

  # Write a Nix expression that extracts environment details in a format we can parse
  cat > "$tmp_nix" << 'EOF'
let 
  projectFile = import ./project-file.nix;

  # Function to safely extract environment items
  formatEnvironmentItem = item:
    let
      # Extract fields with defaults
      type = if builtins.hasAttr "type" item then item.type else "unknown";
      command = if builtins.hasAttr "command" item then item.command else "";
      position = if builtins.hasAttr "position" item then item.position else "center";
      url = if builtins.hasAttr "url" item then item.url else "";

      # Handle files list
      filesList = 
        if builtins.hasAttr "files" item && builtins.isList item.files 
        then builtins.concatStringsSep "," item.files 
        else "";
    in
      "${type}|${command}|${position}|${url}|${filesList}";

  # Extract environment list
  environmentList = 
    if builtins.hasAttr "environment" projectFile && builtins.isList projectFile.environment
    then builtins.map formatEnvironmentItem projectFile.environment
    else [];

  # Create output string
  result = builtins.concatStringsSep "\n" environmentList;
in
  result
EOF

  # Create a symlink to the actual project file
  ln -sf "$config_file" "$(dirname "$tmp_nix")/project-file.nix"

  # Evaluate the Nix expression
  local output
  output=$(nix-instantiate --eval --strict "$tmp_nix" 2>/dev/null)
  local status=$?

  # Clean up files
  rm -f "$tmp_nix" "$(dirname "$tmp_nix")/project-file.nix"

  if [ $status -ne 0 ]; then
    debug_log WARN "Error evaluating Nix expression"
    return 1
  fi

  # Process output (remove quotes and newline escapes)
  echo "$output" | tr -d '"' | sed 's/\\n/\n/g'
}

# Function to fix the cache file format
fix_cache_file() {
  local cache_file="$1"

  if [ ! -f "$cache_file" ]; then
    debug_log WARN "Cache file not found: $cache_file"
    return 1
  fi

  local tmp_cache=$(mktemp)

  debug_log DEBUG "Fixing cache file format..."

  # Read each line and ensure fields are in the correct order
  while IFS='|' read -r name workspace tags_or_dir dir_or_file file_or_empty rest; do
    # Check if this is the old format (where fields are misaligned)
    if [[ "$tags_or_dir" == /* ]]; then  # Looks like a directory path
      # Old format detected, rearrange fields
      local directory="$tags_or_dir"
      local config_file="$dir_or_file"
      local tags=""

      echo "Fixed: $name|$workspace|$tags|$directory|$config_file" >> "$tmp_cache"
      debug_log DEBUG "Fixed entry: $name|$workspace|$tags|$directory|$config_file"
    else
      # Seems to be in correct format already
      echo "$name|$workspace|$tags_or_dir|$dir_or_file|$file_or_empty" >> "$tmp_cache"
    fi
  done < "$cache_file"

  # Replace the old cache with the fixed one
  mv "$tmp_cache" "$cache_file"

  debug_log DEBUG "Cache file fixed!"
}

# Function to scan for .project.nix files and build cache
build_cache() {
  debug_log INFO "Building project cache..."

  # Create cache directory if it doesn't exist
  mkdir -p "$(dirname "$CACHE_FILE")"

  # Use flock to ensure only one process updates the cache at a time
  (
  flock -x 200

    # Clear the cache file
    > "$CACHE_FILE"

    # Calculate total directories to scan
    local total_dirs=${#PROJECT_DIRS[@]}
    debug_log INFO "Scanning $total_dirs directories for projects..."

    # Counter for found projects
    local found_projects=0

    # Scan all project directories
    for dir in "${PROJECT_DIRS[@]}"; do
      if [ ! -d "$dir" ]; then
        debug_log WARN "Warning: Directory does not exist, skipping: $dir"
        continue
      fi

      debug_log DEBUG "Scanning directory: $dir"

      # Find .project.nix files
      while IFS= read -r file; do
        # Parse project info
        debug_log DEBUG "Found project file: $file"
        local project_info=$(parse_project_nix "$file")

        if [ -n "$project_info" ]; then
          # Add to cache
          echo "$project_info" >> "$CACHE_FILE"
          ((found_projects++))
        fi
      done < <(find "$dir" -name ".project.nix" -type f 2>/dev/null)
    done

    # Sort and remove duplicates
    if [ -s "$CACHE_FILE" ]; then
      sort -u "$CACHE_FILE" -o "$CACHE_FILE"
    fi

    debug_log INFO "Cache build complete. Found $found_projects projects."
    debug_log INFO "Cache file: $CACHE_FILE"

    # Fix cache file format
    fix_cache_file "$CACHE_FILE"

    ) 200>"$LOCK_FILE"
  }

# Function to set up the environment for a project
setup_environment() {
  local config_file="$1"
  local directory="$2"
  local workspace="$3"
  local project_name="$4"

  debug_log INFO "Setting up environment for $project_name (workspace $workspace)"

  # Verify Hyprland is running
  if ! is_hyprland_running; then
    debug_log ERROR "Error: hyprctl command not found. Is Hyprland running?"
    return 1
  fi

  # First, switch to the workspace
  debug_log INFO "Switching to workspace special:project$workspace"
  trace_exec "hyprctl dispatch workspace special:project$workspace"

  # Wait for the workspace switch to complete
  sleep 0.5

  # Extract environment items
  local env_items
  env_items=$(extract_project_environment "$config_file")

  # Check if extraction succeeded
  if [ $? -ne 0 ] || [ -z "$env_items" ]; then
    debug_log WARN "Warning: Failed to extract environment or no environment specified"
    debug_log INFO "Launching a terminal in the project directory"
    trace_exec "hyprctl dispatch exec -- \"kitty --working-directory $directory\""
    return 0
  fi

  # Process each environment item
  echo "$env_items" | while IFS='|' read -r type command position url files; do
  debug_log INFO "Setting up item: type=$type"

  case "$type" in
    "terminal")
      if [ -n "$command" ]; then
        debug_log INFO "Launching terminal with command: $command"
        trace_exec "hyprctl dispatch exec -- \"kitty --working-directory $directory -e bash -c '$command; exec bash'\""
      else
        debug_log INFO "Launching terminal in project directory"
        trace_exec "hyprctl dispatch exec -- \"kitty --working-directory $directory\""
      fi
      ;;

    "editor")
      if [ -n "$command" ]; then
        # Convert comma-separated files to space-separated for command arguments
        local files_args=$(echo "$files" | tr ',' ' ')

        if [ -n "$files_args" ]; then
          debug_log INFO "Launching editor with files: $command $files_args"
          trace_exec "hyprctl dispatch exec -- \"kitty --working-directory $directory -e bash -c '$command $files_args'\""
        else
          debug_log INFO "Launching editor: $command"
          trace_exec "hyprctl dispatch exec -- \"kitty --working-directory $directory -e bash -c '$command'\""
        fi
      fi
      ;;

    "browser")
      if [ -n "$url" ]; then
        debug_log INFO "Opening URL: $url"
        trace_exec "hyprctl dispatch exec -- \"xdg-open $url\""
      fi
      ;;

    *)
      debug_log WARN "Unknown environment item type: $type"
      ;;
  esac

    # Small delay between launching applications
    sleep 1
  done

  debug_log INFO "Environment setup complete"
  return 0
}

# Function to start file monitoring as a separate daemon process
start_monitoring() {
  if ! command -v inotifywait &> /dev/null; then
    debug_log ERROR "inotifywait not found. Install inotify-tools for file monitoring."
    return 1
  fi

  # Check if monitoring is already running
  if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    debug_log INFO "Monitoring is already running with PID $(cat "$PID_FILE")"
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
    debug_log INFO "Monitoring started with PID $(cat "$PID_FILE")"
    return 0
  else
    debug_log ERROR "Failed to start monitoring daemon"
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
  if ($3 != "") {
    printf "%s (ws:%s) [%s]", $1, $2, $3
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
  if ($3 != "") {
    printf "%s (ws:%s) [%s] - %s", $1, $2, $3, $4
  } else {
  printf "%s (ws:%s) - %s", $1, $2, $4
}
if ($6 == 1) printf " ★";
  print ""
}' | \
  fzf --height 40% --reverse --prompt="Select Project > ")

echo "$selected" | sed -E 's/ \(ws:[0-9]+\)( \[.*\])?( - .*)?( ★)?$//'
}

# Function to debug a project's configuration
debug_project() {
  local project_name="$1"

  if [ -z "$project_name" ]; then
    echo "Usage: $0 debug <project_name>"
    exit 1
  fi

  echo "Debugging project: $project_name"
  echo "----------------------------------------"

  # Find project in cache
  if [ ! -f "$CACHE_FILE" ]; then
    echo "Cache file not found. Building cache..."
    build_cache
  fi

  # Fix the cache file format if needed
  fix_cache_file "$CACHE_FILE"

  local project_line=$(grep -m 1 "^$project_name|" "$CACHE_FILE")

  if [ -z "$project_line" ]; then
    echo "Error: Project not found in cache: $project_name"
    exit 1
  fi

  # Parse project information - ENSURE FIELD ORDER IS CORRECT
  local name workspace tags directory config_file
  IFS='|' read -r name workspace tags directory config_file <<< "$project_line"

  echo "Project information from cache:"
  echo "  Name: $name"
  echo "  Workspace: $workspace"
  echo "  Directory: $directory"
  echo "  Config file: $config_file"
  echo "  Tags: ${tags:-none}"
  echo ""

  # Check if config file exists
  if [ ! -f "$config_file" ]; then
    echo "Error: Config file does not exist: $config_file"
    exit 1
  fi

  echo "Config file content:"
  echo "----------------------------------------"
  cat "$config_file"
  echo "----------------------------------------"
  echo ""

  # Try to parse using our functions
  echo "Attempting to parse config file using parse_project_nix():"
  local result=$(parse_project_nix "$config_file")
  echo "Parse result: $result"
  echo ""

  # Try to extract environment settings
  echo "Attempting to extract environment settings:"

  # Create a temporary Nix script for debugging
  local tmp_nix=$(mktemp --suffix=.nix)

  cat > "$tmp_nix" << 'EOF'
let
  projectFile = import ./project-file.nix;

  # Helper function to recursively convert Nix values to strings for debugging
  showValue = v:
    if builtins.isAttrs v then
      "{ " + (builtins.concatStringsSep ", " (
        builtins.map (name: "${name} = ${showValue (builtins.getAttr name v)}") 
        (builtins.attrNames v)
      )) + " }"
    else if builtins.isList v then
      "[ " + (builtins.concatStringsSep ", " (map showValue v)) + " ]"
    else if builtins.isString v then
      "\"${v}\""
    else
      toString v;

  # Get the environment list with detailed debug info
  result = 
    if builtins.hasAttr "environment" projectFile then
      if builtins.isList projectFile.environment then
        "environment is a list with ${toString (builtins.length projectFile.environment)} items:\n" +
        (builtins.concatStringsSep "\n" (
          builtins.map (env: "- " + showValue env) projectFile.environment
        ))
      else
        "environment exists but is not a list: ${showValue projectFile.environment}"
      else
      "environment attribute not found in config";
in
  result
EOF

  # Create a symlink to the actual project file
  ln -sf "$config_file" "$(dirname "$tmp_nix")/project-file.nix"

  # Evaluate the Nix expression
  local env_debug
  env_debug=$(nix-instantiate --eval --strict "$tmp_nix" 2>&1 || echo "Error evaluating Nix expression")

  # Clean up temporary files
  rm -f "$tmp_nix" "$(dirname "$tmp_nix")/project-file.nix"

  # Process the result (remove quotes)
  env_debug=$(echo "$env_debug" | sed 's/^"//;s/"$//;s/\\n/\n/g')

  echo "$env_debug"
  echo ""
  echo "----------------------------------------"

  # Test environment extraction
  echo "Testing environment extraction function:"
  local env_items
  env_items=$(extract_project_environment "$config_file")

  if [ $? -eq 0 ] && [ -n "$env_items" ]; then
    echo "$env_items" | while IFS='|' read -r type command position url files; do
    echo "Type:     $type"
    echo "Command:  $command"
    echo "Position: $position"
    echo "URL:      $url"
    echo "Files:    $files"
    echo "----------------------------------------"
  done
else
  echo "Failed to extract environment items"
  fi

  # Test if Hyprland is available
  if command -v hyprctl &> /dev/null; then
    echo "Hyprland is available. Testing workspace switch command:"
    echo "hyprctl dispatch workspace \"$workspace\""

    # Don't actually execute it, just show what would happen
    echo "Would execute: hyprctl dispatch workspace \"$workspace\""
  else
    echo "Hyprland is not available on this system."
  fi

  echo ""
  echo "Debug complete."
}

# Function to open the selected project
open_project() {
  local project_name="$1"

  if [ -z "$project_name" ]; then
    debug_log WARN "No project selected"
    exit 0
  fi

  # Find project in cache
  local project_line=$(grep -m 1 "^$project_name|" "$CACHE_FILE")

  if [ -z "$project_line" ]; then
    debug_log ERROR "Project not found in cache: $project_name"
    exit 1
  fi

  # Parse project information - with correct field order
  local name workspace tags directory config_file
  IFS='|' read -r name workspace tags directory config_file <<< "$project_line"

  debug_log INFO "Opening project: $name (workspace: $workspace, directory: $directory)"

  # Record access
  record_access "$name"

  # Determine execution context (terminal or hotkey)
  local is_terminal=false
  if [ -t 0 ]; then
    debug_log INFO "Running in terminal context"
    is_terminal=true
  else
    debug_log INFO "Running in non-terminal context (likely hotkey)"
  fi

  # Check if Hyprland is running
  if  is_hyprland_running; then
    # Use the enhanced environment setup function
    setup_environment "$config_file" "$directory" "$workspace" "$name"
  else
    # Running in terminal but not in Hyprland
    if [ "$is_terminal" = true ]; then
      debug_log INFO "Changing directory to: $directory"
      # Cannot directly change directory of parent shell, provide a message
      echo "Project directory: $directory"
      echo "Run: cd \"$directory\""
      # For convenience, if SHELL is bash and we're in an interactive session, try to cd
      if [[ -n "$BASH" && $- == *i* ]]; then
        cd "$directory" || return 1
      fi
    else
      debug_log WARN "Not running in Hyprland or terminal, no action taken"
    fi
  fi
}

# Main script logic
# Acquire lock for interactive commands that shouldn't run concurrently
case "$1" in
  "rofi"|"fzf"|"open")
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
        debug_log INFO "Stopping monitoring process (PID: $(cat "$PID_FILE"))..."
        kill $(cat "$PID_FILE")
        rm -f "$PID_FILE"
      else
        debug_log WARN "No active monitoring process found. Removing stale PID file."
        rm -f "$PID_FILE"
      fi
    else
      debug_log WARN "No monitoring process found."
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
    debug_log INFO "Starting rofi selection"
    project=$(select_project_rofi)
    debug_log INFO "Selected project: $project"
    if [ -n "$project" ]; then
      open_project "$project"
    else
      debug_log WARN "No project selected"
    fi
    ;;
  "fzf")
    debug_log INFO "Starting fzf selection"
    project=$(select_project_fzf)
    debug_log INFO "Selected project: $project"
    if [ -n "$project" ]; then
      open_project "$project"
    else
      debug_log WARN "No project selected"
    fi
    ;;
  "list")
    if [ ! -f "$CACHE_FILE" ]; then
      build_cache
    fi

    # Fix cache file format if needed
    fix_cache_file "$CACHE_FILE"

    format_project_list | awk -F'|' '{
    printf "%s (workspace: %s)", $1, $2
    if ($3 != "") printf " [%s]", $3
      printf " - %s", $4
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
      open_project "$2"
      ;;
    "debug")
      # Set debug level to DEBUG for this command
      export DEBUG_LEVEL=DEBUG
      debug_project "$2"
      ;;
    "set-debug")
      if [ -z "$2" ]; then
        echo "Current debug level: $DEBUG_LEVEL"
        echo "Usage: $0 set-debug [ERROR|WARN|INFO|DEBUG]"
        exit 0
      fi

      case "$2" in
        ERROR|WARN|INFO|DEBUG)
          echo "Setting debug level to $2"
          export DEBUG_LEVEL="$2"
          ;;
        *)
          echo "Invalid debug level: $2"
          echo "Valid options: ERROR, WARN, INFO, DEBUG"
          exit 1
          ;;
      esac
      ;;
    "fix-cache")
      if [ ! -f "$CACHE_FILE" ]; then
        echo "Cache file not found. Building cache first..."
        build_cache
      else
        fix_cache_file "$CACHE_FILE"
        echo "Cache file format fixed."
      fi
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
      echo "  debug <name>    - Debug a project's configuration"
      echo "  set-debug <lvl> - Set debug level (ERROR, WARN, INFO, DEBUG)"
      echo "  fix-cache       - Fix cache file format issues"
      echo "  help            - Show this help message"
      ;;
    *)
      if [ -z "$1" ]; then
        # Default action when no command is provided
        acquire_instance_lock
        debug_log INFO "No command specified, using default rofi selector"
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
