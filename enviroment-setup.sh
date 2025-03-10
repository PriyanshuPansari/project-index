#!/usr/bin/env bash

# Function to set up the environment for a project
setup_environment() {
  local config_file="$1"
  local directory="$2"
  local workspace="$3"
  local project_name="$4"
  
  echo "Setting up environment for $project_name (workspace $workspace)"
  
  # Verify Hyprland is running
  if ! command -v hyprctl &> /dev/null; then
    echo "Error: hyprctl command not found. Is Hyprland running?"
    return 1
  fi
  
  # First, switch to the workspace
  echo "Switching to workspace $workspace"
  hyprctl dispatch workspace "$workspace"
  
  # Wait for the workspace switch to complete
  sleep 0.5
  
  # Extract environment items
  local env_items
  env_items=$(extract_project_environment "$config_file")
  
  # Check if extraction succeeded
  if [ $? -ne 0 ] || [ -z "$env_items" ]; then
    echo "Warning: Failed to extract environment or no environment specified"
    echo "Launching a terminal in the project directory"
    hyprctl dispatch exec -- "alacritty --working-directory $directory"
    return 0
  fi
  
  # Process each environment item
  echo "$env_items" | while IFS='|' read -r type command position url files; do
    echo "Setting up item: type=$type"
    
    case "$type" in
      "terminal")
        if [ -n "$command" ]; then
          echo "Launching terminal with command: $command"
          hyprctl dispatch exec -- "alacritty --working-directory $directory -e bash -c '$command; exec bash'"
        else
          echo "Launching terminal in project directory"
          hyprctl dispatch exec -- "alacritty --working-directory $directory"
        fi
        ;;
        
      "editor")
        if [ -n "$command" ]; then
          # Convert comma-separated files to space-separated for command arguments
          local files_args=$(echo "$files" | tr ',' ' ')
          
          if [ -n "$files_args" ]; then
            echo "Launching editor with files: $command $files_args"
            hyprctl dispatch exec -- "alacritty --working-directory $directory -e bash -c '$command $files_args'"
          else
            echo "Launching editor: $command"
            hyprctl dispatch exec -- "alacritty --working-directory $directory -e bash -c '$command'"
          fi
        fi
        ;;
        
      "browser")
        if [ -n "$url" ]; then
          echo "Opening URL: $url"
          hyprctl dispatch exec -- "xdg-open $url"
        fi
        ;;
        
      *)
        echo "Unknown environment item type: $type"
        ;;
    esac
    
    # Small delay between launching applications
    sleep 1
  done
  
  echo "Environment setup complete"
  return 0
}
