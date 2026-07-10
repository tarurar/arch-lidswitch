#!/bin/bash

# Hyprland Lid State Monitor
# This script continuously monitors the lid state and triggers the appropriate action

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LID_SWITCH_SCRIPT="$SCRIPT_DIR/lid-switch.sh"

log_record() {
    local level=$1
    local event=$2
    shift 2

    printf 'level=%s component=lid-monitor event=%s' "$level" "$event"
    if (( $# > 0 )); then
        printf ' %s' "$@"
    fi
    printf '\n'
}

log_info() {
    log_record info "$@"
}

log_error() {
    log_record error "$@" >&2
}

observe_lid_state() {
    local observation_status

    if observed_state=$(read_lid_state 2>/dev/null); then
        observed_error=""
        return 0
    else
        observation_status=$?
    fi

    observed_state="unknown"
    case "$observation_status" in
        2)
            observed_error="missing"
            ;;
        3)
            observed_error="unreadable"
            ;;
        4)
            observed_error="malformed"
            ;;
        5)
            observed_error="conflicting"
            ;;
        *)
            observed_error="unknown"
            ;;
    esac
    return "$observation_status"
}

if ! . "$SCRIPT_DIR/lid-state.sh"; then
    log_error lid_state_observer_load_failed
    exit 1
fi

if [[ "${1:-}" == "--print-state" ]]; then
    read_lid_state
    exit $?
fi

# Initial state
previous_error=""
if observe_lid_state; then
    previous_state="$observed_state"
else
    previous_state="unknown"
    previous_error="$observed_error"
    log_error lid_state_observation_failed reason="$observed_error"
fi
log_info monitor_started state="$previous_state"

while true; do
    if observe_lid_state; then
        current_state="$observed_state"
        previous_error=""
    else
        current_state="unknown"
        if [[ "$observed_error" != "$previous_error" ]]; then
            log_error lid_state_observation_failed reason="$observed_error"
        fi
        previous_error="$observed_error"
        sleep 1
        continue
    fi
    
    if [[ "$current_state" != "$previous_state" && "$current_state" != "unknown" ]]; then
        log_info lid_state_changed previous="$previous_state" current="$current_state"
        
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
