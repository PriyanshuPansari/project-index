#!/usr/bin/env bash

# Script to rebuild the project cache with the fixed format

# Ensure we have the cache directory
if [ -z "$CACHE_DIR" ]; then
  CACHE_DIR="$HOME/.cache/project-index"
fi

if [ -z "$CACHE_FILE" ]; then
  CACHE_FILE="$CACHE_DIR/projects.cache"
fi

echo "Rebuilding project cache..."
echo "Cache directory: $CACHE_DIR"
echo "Cache file: $CACHE_FILE"

# Make sure the cache directory exists
mkdir -p "$CACHE_DIR"

# Backup the existing cache file if it exists
if [ -f "$CACHE_FILE" ]; then
  backup_file="$CACHE_FILE.backup-$(date +%Y%m%d%H%M%S)"
  echo "Backing up existing cache to $backup_file"
  cp "$CACHE_FILE" "$backup_file"
fi

# Clear the cache file
> "$CACHE_FILE"

# Scan for .project.nix files in PROJECT_DIRS
for dir in "${PROJECT_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    echo "Scanning directory: $dir"
    
    # Find .project.nix files and parse them
    find "$dir" -type f -name ".project.nix" -print0 | while IFS= read -r -d '' file; do
      echo "Processing: $file"
      
      # Parse the project file and append to cache
      parse_project_nix "$file" >> "$CACHE_FILE"
    done
  else
    echo "Directory not found: $dir"
  fi
done

# Sort and remove duplicates
if [ -s "$CACHE_FILE" ]; then
  tmp_file=$(mktemp)
  sort -u "$CACHE_FILE" > "$tmp_file"
  mv "$tmp_file" "$CACHE_FILE"
  
  echo "Cache rebuilt successfully."
  echo "Found $(wc -l < "$CACHE_FILE") projects:"
  cat "$CACHE_FILE"
else
  echo "No projects found. Cache is empty."
fi
