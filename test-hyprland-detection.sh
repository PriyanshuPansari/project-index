#!/usr/bin/env bash

# Function to check if Hyprland is running (improved detection)
is_hyprland_running() {
  echo "Testing Hyprland detection methods..."
  
  # Method 1: Check using command presence and execution
  echo -n "Method 1 (hyprctl monitors): "
  if command -v hyprctl &> /dev/null && hyprctl monitors &> /dev/null; then
    echo "DETECTED"
  else
    echo "NOT DETECTED"
  fi
  
  # Method 2: Check using process name (more flexible matching)
  echo -n "Method 2 (process name - exact): "
  if pgrep -x "Hyprland" &> /dev/null; then
    echo "DETECTED"
  else
    echo "NOT DETECTED"
  fi
  
  echo -n "Method 2 (process name - substring): "
  if pgrep -f "Hyprland" &> /dev/null; then
    echo "DETECTED"
  else
    echo "NOT DETECTED"
  fi
  
  echo -n "Method 2 (process name - case insensitive): "
  if pgrep -i "hypr" &> /dev/null; then
    echo "DETECTED"
  else
    echo "NOT DETECTED"
  fi

  # Method 3: Check for Hyprland environment variables
  echo -n "Method 3 (environment variables): "
  if [[ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]]; then
    echo "DETECTED (HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE)"
  else
    echo "NOT DETECTED"
  fi
  
  echo
  echo "Final detection result:"
  if command -v hyprctl &> /dev/null && hyprctl monitors &> /dev/null; then
    echo "✅ Hyprland is running (detected via hyprctl)"
    return 0
  elif pgrep -f "Hyprland" &> /dev/null || pgrep -i "hypr" &> /dev/null; then
    if command -v hyprctl &> /dev/null; then
      echo "✅ Hyprland is running (detected via process name)"
      return 0
    fi
  elif [[ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]]; then
    echo "✅ Hyprland is running (detected via environment variables)"
    return 0
  else
    echo "❌ Hyprland is not running"
    return 1
  fi
}

# Run the test
is_hyprland_running
exit_code=$?

echo
echo "Exit code: $exit_code (0 = Hyprland detected, 1 = Not detected)"

# Additional system information
echo
echo "System information:"
echo "-------------------"
echo "Process listing containing 'hypr':"
ps aux | grep -i hypr | grep -v grep

echo
echo "Available Hyprland commands:"
which hyprctl 2>/dev/null || echo "hyprctl not found"

echo
echo "Hyprland environment variables:"
env | grep -i hypr
