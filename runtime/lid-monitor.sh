#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LID_SWITCH_SCRIPT="$SCRIPT_DIR/lid-switch.sh"
LAPTOP_DISPLAY="LAPTOP_MONITOR_PLACEHOLDER"
MAX_RECONCILIATION_ATTEMPTS=3
RECONCILIATION_COOLDOWN_TICKS=5

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

    observed_state=unknown
    case "$observation_status" in
        2) observed_error=missing ;;
        3) observed_error=unreadable ;;
        4) observed_error=malformed ;;
        5) observed_error=conflicting ;;
        *) observed_error=unknown ;;
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
        observed_topology_error=topology_fingerprint_failed
    else
        observation_status=$?
        observed_topology_error=$MONITOR_STATE_ERROR
    fi

    observed_topology=""
    return "$observation_status"
}

observe_joint_state() {
    local trigger=$1
    local observation_status

    current_state=""
    current_topology=""
    if observe_lid_state; then
        current_state=$observed_state
        previous_lid_error=""
    else
        observation_status=$?
        previous_lid_error=$observed_error
        log_error lid_state_observation_failed reason="$observed_error" \
            trigger="$trigger"
        return 2
    fi

    if observe_topology; then
        current_topology=$observed_topology
        previous_topology_error=""
    else
        observation_status=$?
        previous_topology_error=$observed_topology_error
        log_error topology_observation_failed reason="$observed_topology_error" \
            trigger="$trigger"
        return 2
    fi
}

observed_joint_state_matches_policy() {
    local state=$1
    local require_dpms=$2
    local internal_enabled enabled_external_count internal_dpms

    internal_enabled=$(jq -er '.internal.enabled | tostring' \
        <<< "$current_topology") || return 1
    enabled_external_count=$(jq -er \
        '[.externals[] | select(.enabled)] | length' \
        <<< "$current_topology") || return 1

    if [[ "$state" == closed && "$enabled_external_count" -gt 0 ]]; then
        [[ "$internal_enabled" == false ]] || return 1
    else
        [[ "$internal_enabled" == true ]] || return 1
    fi
    if [[ "$state" == open && "$require_dpms" == true ]]; then
        internal_dpms=$(monitor_state_internal_dpms) || return 1
        [[ "$internal_dpms" == true ]] || return 1
    fi
}

apply_observed_joint_state() {
    local trigger=$1
    local attempt=$2
    local preserve_dpms=$3
    local attempted_state=$current_state
    local attempted_topology=$current_topology
    local attempted_internal wake_required=false
    local reconciliation_status

    log_info reconciliation_started trigger="$trigger" attempt="$attempt" \
        state="$attempted_state" preserve_dpms="$preserve_dpms" \
        topology="$attempted_topology"
    if [[ "$attempted_state" == open && "$preserve_dpms" == true ]]; then
        "$LID_SWITCH_SCRIPT" --preserve-dpms open
        reconciliation_status=$?
    else
        "$LID_SWITCH_SCRIPT" "$attempted_state"
        reconciliation_status=$?
    fi

    if (( reconciliation_status != 0 )); then
        log_error reconciliation_failed trigger="$trigger" attempt="$attempt" \
            state="$attempted_state" status="$reconciliation_status" \
            applied_ready="$applied_ready"
        return "$reconciliation_status"
    fi

    if observe_joint_state post_action; then
        :
    else
        reconciliation_status=$?
        log_error reconciliation_failed trigger="$trigger" attempt="$attempt" \
            state="$attempted_state" status="$reconciliation_status" \
            reason=post_action_observation_failed applied_ready="$applied_ready"
        return "$reconciliation_status"
    fi
    if [[ "$current_state" != "$attempted_state" ]]; then
        log_error reconciliation_failed trigger="$trigger" attempt="$attempt" \
            state="$attempted_state" status=4 \
            reason=lid_state_changed_during_reconciliation \
            observed_state="$current_state" applied_ready="$applied_ready"
        return 4
    fi
    attempted_internal=$(jq -er '.internal.enabled | tostring' \
        <<< "$attempted_topology")
    if [[ "$attempted_state" == open ]] && \
        { [[ "$preserve_dpms" != true ]] || \
            [[ "$attempted_internal" == false ]]; }; then
        wake_required=true
    fi
    if ! observed_joint_state_matches_policy "$attempted_state" \
        "$wake_required"; then
        log_error reconciliation_failed trigger="$trigger" attempt="$attempt" \
            state="$attempted_state" status=4 \
            reason=post_action_policy_mismatch topology="$current_topology" \
            applied_ready="$applied_ready"
        return 4
    fi

    applied_state=$current_state
    applied_topology=$current_topology
    applied_ready=true
    log_info reconciliation_succeeded trigger="$trigger" attempt="$attempt" \
        state="$applied_state" topology="$applied_topology"
}

run_reconciliation_attempt() {
    local trigger=$1
    local attempt=$2
    local preserve_dpms=$3
    local reconciliation_status

    if observe_joint_state "$trigger"; then
        :
    else
        reconciliation_status=$?
        log_error reconciliation_failed trigger="$trigger" attempt="$attempt" \
            state=unknown status="$reconciliation_status" applied_ready="$applied_ready"
        return "$reconciliation_status"
    fi
    apply_observed_joint_state "$trigger" "$attempt" "$preserve_dpms"
}

record_last_observed_state() {
    if [[ -n "$current_state" && -n "$current_topology" ]]; then
        last_observed_state=$current_state
        last_observed_topology=$current_topology
        last_observed_ready=true
    fi
}

if ! . "$SCRIPT_DIR/lid-state.sh"; then
    log_error lid_state_observer_load_failed
    exit 1
fi

if [[ "${1:-}" == --print-state ]]; then
    read_lid_state
    exit $?
fi

if ! . "$SCRIPT_DIR/monitor-state.sh"; then
    log_error monitor_state_observer_load_failed
    exit 1
fi

applied_ready=false
applied_state=unknown
applied_topology=""
last_observed_ready=false
last_observed_state=unknown
last_observed_topology=""
previous_lid_error=""
previous_topology_error=""
current_state=""
current_topology=""

if [[ "${1:-}" == --once ]]; then
    reconciliation_status=2
    for ((attempt = 1; attempt <= MAX_RECONCILIATION_ATTEMPTS; attempt++)); do
        if run_reconciliation_attempt once "$attempt" true; then
            exit 0
        else
            reconciliation_status=$?
        fi
        if (( reconciliation_status == 1 )); then
            log_error reconciliation_fatal trigger=once attempt="$attempt" \
                status=1 reason=contract_or_initialization_failure
            exit 1
        fi
        if (( attempt < MAX_RECONCILIATION_ATTEMPTS )); then
            sleep 0.05
        fi
    done
    log_error reconciliation_exhausted trigger=once \
        attempt="$MAX_RECONCILIATION_ATTEMPTS" status="$reconciliation_status"
    exit "$reconciliation_status"
fi

pending_reconciliation=true
pending_preserve_dpms=true
burst_attempts=0
cooldown_ticks=0

burst_attempts=1
if run_reconciliation_attempt startup "$burst_attempts" "$pending_preserve_dpms"; then
    pending_reconciliation=false
    burst_attempts=0
else
    reconciliation_status=$?
    if (( reconciliation_status == 1 )); then
        log_error reconciliation_fatal trigger=startup attempt=1 status=1 \
            reason=contract_or_initialization_failure
        exit 1
    fi
fi
record_last_observed_state
log_info monitor_started observed_state="$last_observed_state" \
    observed_topology="${last_observed_topology:-unavailable}" \
    applied_ready="$applied_ready" applied_state="$applied_state" \
    applied_topology="${applied_topology:-unavailable}"

while true; do
    if ! observe_joint_state poll; then
        sleep 1
        continue
    fi

    if [[ "$last_observed_ready" != true ]]; then
        pending_reconciliation=true
        pending_preserve_dpms=true
        burst_attempts=0
        cooldown_ticks=0
        log_info joint_state_baselined state="$current_state" \
            topology="$current_topology"
    elif [[ "$current_state" != "$last_observed_state" || \
        "$current_topology" != "$last_observed_topology" ]]; then
        log_info joint_state_changed previous_state="$last_observed_state" \
            current_state="$current_state" \
            previous_topology="$last_observed_topology" \
            current_topology="$current_topology"
        if [[ "$current_state" != "$last_observed_state" ]]; then
            log_info lid_state_changed previous="$last_observed_state" \
                current="$current_state"
            if [[ "$last_observed_state" == closed && "$current_state" == open ]]; then
                pending_preserve_dpms=false
            else
                pending_preserve_dpms=true
            fi
        elif [[ "$current_state" == open && "$pending_reconciliation" != true ]]; then
            pending_preserve_dpms=true
        fi
        pending_reconciliation=true
        burst_attempts=0
        cooldown_ticks=0
    fi
    record_last_observed_state

    if [[ "$pending_reconciliation" == true ]]; then
        if (( cooldown_ticks > 0 )); then
            cooldown_ticks=$((cooldown_ticks - 1))
            log_info reconciliation_cooldown_tick ticks_remaining="$cooldown_ticks"
            if (( cooldown_ticks == 0 )); then
                burst_attempts=0
                log_info reconciliation_rearmed reason=cooldown_elapsed
            fi
        else
            burst_attempts=$((burst_attempts + 1))
            if apply_observed_joint_state pending "$burst_attempts" \
                "$pending_preserve_dpms"; then
                pending_reconciliation=false
                pending_preserve_dpms=true
                burst_attempts=0
                record_last_observed_state
            else
                reconciliation_status=$?
                if (( reconciliation_status == 1 )); then
                    log_error reconciliation_fatal trigger=pending \
                        attempt="$burst_attempts" status=1 \
                        reason=contract_or_initialization_failure
                    exit 1
                elif (( burst_attempts >= MAX_RECONCILIATION_ATTEMPTS )); then
                    cooldown_ticks=$RECONCILIATION_COOLDOWN_TICKS
                    log_error reconciliation_cooldown_started \
                        ticks="$cooldown_ticks" applied_ready="$applied_ready"
                fi
            fi
        fi
    fi

    sleep 1
done
