#!/usr/bin/env bash

# Include all functions directly in this script to avoid sourcing issues

# Function to extract project environment from .project.nix files
extract_project_environment() {
  local config_file="$1"
  local tmp_nix=$(mktemp --suffix=.nix)
  
  # Debug output
  echo "Extracting environment from: $config_file" >&2
  
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
    echo "Error evaluating Nix expression" >&2
    return 1
  fi
  
  # Process output (remove quotes and newline escapes)
  echo "$output" | tr -d '"' | sed 's/\\n/\n/g'
}

# Function to test environment extraction
test_extraction() {
  local config_file="$1"
  if [ ! -f "$config_file" ]; then
    echo "File not found: $config_file"
    return 1
  fi
  
  echo "Testing environment extraction from: $config_file"
  echo "----------------------------------------"
  
  local items
  items=$(extract_project_environment "$config_file")
  
  if [ $? -ne 0 ]; then
    echo "Error: Failed to extract environment items"
    return 1
  fi
  
  echo "$items" | while IFS='|' read -r type command position url files; do
    echo "Type:     $type"
    echo "Command:  $command"
    echo "Position: $position"
    echo "URL:      $url"
    echo "Files:    $files"
    echo "----------------------------------------"
  done
}

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
    echo "This is just a test, so we'll simulate what would happen."
    echo "Would switch to workspace $workspace"
    echo "Would execute programs from: $directory"
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

# Main script

# Test environment extraction
test_project="$HOME/test-projects/web-app/.project.nix"

if [ ! -f "$test_project" ]; then
  echo "Test project file not found: $test_project"
  echo "Make sure you've run the test.sh script to create test projects"
  exit 1
fi

# Test the extraction function
echo "Testing environment extraction:"
test_extraction "$test_project"

# Test setting up the environment
echo "Testing environment setup (this will actually launch applications if Hyprland is running):"
echo "Press Enter to continue or Ctrl+C to cancel..."
read

# Get project directory
project_dir=$(dirname "$test_project")

# Set up the environment
setup_environment "$test_project" "$project_dir" 2 "React Web App"

echo "Test complete!"
