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

reconcile_current_joint_state() {
    local trigger=$1
    local reconciliation_status

    current_state=""
    current_topology=""

    if observe_lid_state; then
        current_state="$observed_state"
        previous_lid_error=""
    else
        reconciliation_status=$?
        previous_lid_error="$observed_error"
        log_error lid_state_observation_failed reason="$observed_error" \
            trigger="$trigger"
        return "$reconciliation_status"
    fi

    if observe_topology; then
        current_topology="$observed_topology"
        previous_topology_error=""
    else
        reconciliation_status=$?
        previous_topology_error="$observed_topology_error"
        log_error topology_observation_failed reason="$observed_topology_error" \
            trigger="$trigger"
        return "$reconciliation_status"
    fi

    log_info reconciliation_started trigger="$trigger" state="$current_state" \
        topology="$current_topology"
    if "$LID_SWITCH_SCRIPT" "$current_state"; then
        log_info reconciliation_succeeded trigger="$trigger" state="$current_state"
        return 0
    else
        reconciliation_status=$?
    fi

    log_error reconciliation_failed trigger="$trigger" state="$current_state" \
        status="$reconciliation_status"
    return "$reconciliation_status"
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

if [[ "${1:-}" == "--once" ]]; then
    previous_lid_error=""
    previous_topology_error=""
    reconcile_current_joint_state once
    exit $?
fi

# Reconcile the first complete joint observation before establishing the
# baseline used to detect later lid or topology changes.
baseline_ready=false
previous_state="unknown"
previous_topology=""
previous_lid_error=""
previous_topology_error=""
current_state=""
current_topology=""

reconcile_current_joint_state startup || true
if [[ -n "$current_state" && -n "$current_topology" ]]; then
    previous_state="$current_state"
    previous_topology="$current_topology"
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
        detected_state="$current_state"
        detected_topology="$current_topology"
        log_info joint_state_changed previous_state="$previous_state" \
            current_state="$current_state" \
            previous_topology="$previous_topology" \
            current_topology="$current_topology"

        if [[ "$current_state" != "$previous_state" ]]; then
            log_info lid_state_changed previous="$previous_state" current="$current_state"
        fi

        reconcile_current_joint_state joint_change || true
        if [[ -n "$current_state" && -n "$current_topology" ]]; then
            previous_state="$current_state"
            previous_topology="$current_topology"
        else
            previous_state="$detected_state"
            previous_topology="$detected_topology"
        fi
    fi

    sleep 1
done
