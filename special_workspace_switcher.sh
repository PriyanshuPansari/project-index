#!/usr/bin/env bash
# Path to store the last used special workspace
LAST_WORKSPACE_FILE="$HOME/.cache/hypr/last_special_workspace"

# Create directory if it doesn't exist
mkdir -p "$(dirname "$LAST_WORKSPACE_FILE")"

# Get all special workspaces
special_workspaces=$(hyprctl workspaces -j | jq -r '.[] | select(.name | startswith("special:")) | .name' | sed 's/special://')

# If no special workspaces exist, show a message and exit
if [ -z "$special_workspaces" ]; then
    rofi -e "No special workspaces found"
    exit 0
fi

# Show workspaces in rofi and get selection
selected=$(echo "$special_workspaces" | rofi -dmenu -p "Special Workspaces")

# If user selected a workspace, toggle it and save as last used
if [ -n "$selected" ]; then
    echo "$selected" > "$LAST_WORKSPACE_FILE"
    hyprctl dispatch togglespecialworkspace "$selected"
fi
