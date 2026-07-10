#!/bin/bash

# Hyprland Lid State Monitor
# This script continuously monitors the lid state and triggers the appropriate action

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LID_SWITCH_SCRIPT="$SCRIPT_DIR/lid-switch.sh"
LOG_FILE="/tmp/hypr-lid-monitor.log"
if ! . "$SCRIPT_DIR/lid-state.sh"; then
    printf 'Unable to load lid state observer\n' >&2
    exit 1
fi

if [[ "${1:-}" == "--print-state" ]]; then
    read_lid_state
    exit $?
fi

log_message() {
    echo "$(date): $1" >> "$LOG_FILE"
}

# Initial state
previous_state=$(read_lid_state 2>/dev/null) || previous_state="unknown"
log_message "Lid monitor started, initial state: $previous_state"

while true; do
    current_state=$(read_lid_state 2>/dev/null) || current_state="unknown"
    
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
