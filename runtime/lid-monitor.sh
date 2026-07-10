#!/bin/bash

# Hyprland Lid State Monitor
# This script continuously monitors the lid state and triggers the appropriate action

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LID_SWITCH_SCRIPT="$SCRIPT_DIR/lid-switch.sh"
LOG_FILE="/tmp/hypr-lid-monitor.log"

log_message() {
    echo "$(date): $1" >> "$LOG_FILE"
}

get_lid_state() {
    if [[ -f /proc/acpi/button/lid/LID0/state ]]; then
        local state_line=$(cat /proc/acpi/button/lid/LID0/state 2>/dev/null)
        if [[ "$state_line" =~ closed ]]; then
            echo "closed"
        else
            echo "open"
        fi
    else
        # Fallback for systems without specific LID0
        if [[ -f /proc/acpi/button/lid/*/state ]]; then
            cat /proc/acpi/button/lid/*/state 2>/dev/null | grep -q "closed" && echo "closed" || echo "open"
        else
            echo "unknown"
        fi
    fi
}

# Initial state
previous_state=$(get_lid_state)
log_message "Lid monitor started, initial state: $previous_state"

while true; do
    current_state=$(get_lid_state)
    
    if [[ "$current_state" != "$previous_state" && "$current_state" != "unknown" ]]; then
        log_message "Lid state changed from $previous_state to $current_state"
        
        # Call the lid switch script with the appropriate argument
        if [[ "$current_state" == "closed" ]]; then
            "$LID_SWITCH_SCRIPT" close
        elif [[ "$current_state" == "open" ]]; then
            "$LID_SWITCH_SCRIPT" open
        fi
        
        previous_state="$current_state"
    fi
    
    sleep 1
done
