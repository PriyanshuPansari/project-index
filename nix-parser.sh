#!/usr/bin/env bash

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

# Run this function in a test to see what it extracts
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
