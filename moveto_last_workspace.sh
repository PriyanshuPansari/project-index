#!/usr/bin/env bash

# Path to the last used special workspace file
LAST_WORKSPACE_FILE="$HOME/.cache/hypr/last_special_workspace"

# Check if the file exists
if [ -f "$LAST_WORKSPACE_FILE" ]; then
    # Get the last used workspace
    last_workspace=$(cat "$LAST_WORKSPACE_FILE")
    
    # Toggle the last used workspace
    if [ -n "$last_workspace" ]; then
        hyprctl dispatch movetoworkspace "special:$last_workspace"
    else
        notify-send "Hyprland" "No last special workspace found"
    fi
else
    notify-send "Hyprland" "No last special workspace found"
fi
