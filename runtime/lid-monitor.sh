#!/bin/bash

# Hyprland Lid State Monitor
# This script continuously monitors the lid state and triggers the appropriate action

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LID_SWITCH_SCRIPT="$SCRIPT_DIR/lid-switch.sh"
LAPTOP_DISPLAY="LAPTOP_MONITOR_PLACEHOLDER"

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

observe_topology() {
    local observation_status

    if monitor_state_observe_topology "$LAPTOP_DISPLAY"; then
        if observed_topology=$(monitor_state_topology_fingerprint); then
            observed_topology_error=""
            return 0
        fi
        observation_status=$?
        observed_topology_error="topology_fingerprint_failed"
    else
        observation_status=$?
        observed_topology_error="$MONITOR_STATE_ERROR"
    fi

    observed_topology=""
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

if ! . "$SCRIPT_DIR/monitor-state.sh"; then
    log_error monitor_state_observer_load_failed
    exit 1
fi

# Treat the first complete joint observation as a baseline. Reconciliation only
# begins after a later lid or topology change, so daemon startup remains inert.
baseline_ready=false
previous_state="unknown"
previous_topology=""
previous_lid_error=""
previous_topology_error=""
initial_lid_valid=false
initial_topology_valid=false

if observe_lid_state; then
    initial_lid_valid=true
    previous_state="$observed_state"
else
    previous_lid_error="$observed_error"
    log_error lid_state_observation_failed reason="$observed_error"
fi

if observe_topology; then
    initial_topology_valid=true
    previous_topology="$observed_topology"
else
    previous_topology_error="$observed_topology_error"
    log_error topology_observation_failed reason="$observed_topology_error"
fi

if [[ "$initial_lid_valid" == true && "$initial_topology_valid" == true ]]; then
    baseline_ready=true
fi
log_info monitor_started state="$previous_state" \
    topology="${previous_topology:-unavailable}" baseline_ready="$baseline_ready"

while true; do
    if observe_lid_state; then
        current_state="$observed_state"
        previous_lid_error=""
    else
        if [[ "$observed_error" != "$previous_lid_error" ]]; then
            log_error lid_state_observation_failed reason="$observed_error"
        fi
        previous_lid_error="$observed_error"
        sleep 1
        continue
    fi

    if observe_topology; then
        current_topology="$observed_topology"
        previous_topology_error=""
    else
        if [[ "$observed_topology_error" != "$previous_topology_error" ]]; then
            log_error topology_observation_failed reason="$observed_topology_error"
        fi
        previous_topology_error="$observed_topology_error"
        sleep 1
        continue
    fi

    if [[ "$baseline_ready" != true ]]; then
        previous_state="$current_state"
        previous_topology="$current_topology"
        baseline_ready=true
        log_info joint_state_baselined state="$current_state" \
            topology="$current_topology"
        sleep 1
        continue
    fi

    if [[ "$current_state" != "$previous_state" || \
        "$current_topology" != "$previous_topology" ]]; then
        log_info joint_state_changed previous_state="$previous_state" \
            current_state="$current_state" \
            previous_topology="$previous_topology" \
            current_topology="$current_topology"

        if [[ "$current_state" != "$previous_state" ]]; then
            log_info lid_state_changed previous="$previous_state" current="$current_state"
        fi

        # Call the lid switch script with the appropriate argument
        if [[ "$current_state" == "closed" ]]; then
            "$LID_SWITCH_SCRIPT" close
        elif [[ "$current_state" == "open" ]]; then
            "$LID_SWITCH_SCRIPT" open
        fi

        previous_state="$current_state"
        previous_topology="$current_topology"
    fi

    sleep 1
done
