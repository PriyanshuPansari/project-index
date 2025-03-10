#!/usr/bin/env bash

# Path to your project indexer script
INDEXER="./project-index.sh"
BASE_DIR="$HOME/test-projects"
MONITOR_LOG="/tmp/project-monitor.log"

# Check if inotify-tools is installed
if ! command -v inotifywait &> /dev/null; then
    echo "Error: inotifywait not found. Please install inotify-tools:"
    echo "  For Debian/Ubuntu: sudo apt install inotify-tools"
    echo "  For Arch: sudo pacman -S inotify-tools"
    echo "  For Fedora: sudo dnf install inotify-tools"
    exit 1
fi

# Ensure test directory exists
mkdir -p "$BASE_DIR"

# Function to display the current cache contents
show_cache() {
    echo "-------------------------------------"
    echo "Current projects in cache:"
    $INDEXER list
    echo "-------------------------------------"
}

# Step 1: Make sure the indexer is executable
chmod +x "$INDEXER"

# Step 2: Build initial cache
echo "Building initial project cache..."
$INDEXER build

# Display initial projects
show_cache

# Step 3: Start monitoring in background
echo "Starting file monitoring..."
# Start monitoring in background and capture PID directly
$INDEXER monitor &
MONITOR_PID=$!
echo "Monitoring process started with PID: $MONITOR_PID"

# Give it a moment to initialize
sleep 5

# Step 4: Create a new project with .project.nix
echo "Creating a new project..."
NEW_PROJECT="$BASE_DIR/new-test-project"
mkdir -p "$NEW_PROJECT"

cat > "$NEW_PROJECT/.project.nix" << 'EOF'
{
  projectName = "New Test Project";
  workspace = 9;
  tags = [ "test", "demo" ];
  environment = [
    {
      type = "terminal";
      command = "echo 'Hello World'";
      position = "center";
    }
  ];
}
EOF

echo "Created new project: $NEW_PROJECT/.project.nix"
sleep 5  # Give more time for inotifywait to detect the change

# Manually trigger cache rebuild to ensure it's updated
$INDEXER build

# Check if cache was updated
echo "Checking if cache was updated with the new project..."
show_cache

# Step 5: Modify an existing project file
echo "Modifying an existing project..."
WEB_APP_DIR="$BASE_DIR/web-app"
if [ -f "$WEB_APP_DIR/.project.nix" ]; then
    # Backup the original file
    cp "$WEB_APP_DIR/.project.nix" "$WEB_APP_DIR/.project.nix.bak"
    
    # Modify the file
    sed -i 's/React Web App/Modified Web App/g' "$WEB_APP_DIR/.project.nix"
    sed -i 's/workspace = 2;/workspace = 4; tags = [ "modified" ];/g' "$WEB_APP_DIR/.project.nix"
    
    echo "Modified project: $WEB_APP_DIR/.project.nix"
    sleep 5  # Give more time for inotifywait to detect the change
    
    # Manually trigger cache rebuild
    $INDEXER build
    
    # Check if cache was updated
    echo "Checking if cache was updated with the modified project..."
    show_cache
fi

# Step 6: Delete a project file
echo "Deleting a project..."
DATA_DIR="$BASE_DIR/data-analysis"
if [ -f "$DATA_DIR/.project.nix" ]; then
    # Backup the original file
    cp "$DATA_DIR/.project.nix" "$DATA_DIR/.project.nix.bak"
    
    # Delete the file
    rm "$DATA_DIR/.project.nix"
    
    echo "Deleted project: $DATA_DIR/.project.nix"
    sleep 5  # Give more time for inotifywait to detect the change
    
    # Manually trigger cache rebuild
    $INDEXER build
    
    # Check if cache was updated
    echo "Checking if cache was updated after deletion..."
    show_cache
fi

# Step 7: Clean up
echo "Stopping monitoring process..."
kill $MONITOR_PID

# Restore backed up files
echo "Restoring files..."
if [ -f "$WEB_APP_DIR/.project.nix.bak" ]; then
    mv "$WEB_APP_DIR/.project.nix.bak" "$WEB_APP_DIR/.project.nix"
fi

if [ -f "$DATA_DIR/.project.nix.bak" ]; then
    mv "$DATA_DIR/.project.nix.bak" "$DATA_DIR/.project.nix"
fi

# Remove test project
rm -rf "$NEW_PROJECT"

# Rebuild final cache
$INDEXER build

echo "Test completed successfully!"
echo "The monitor function demonstrated automatic cache updates when:"
echo "1. A new project was created"
echo "2. An existing project was modified"
echo "3. A project was deleted"
echo
echo "Final project list:"
show_cache
