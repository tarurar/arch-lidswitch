#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LID_SWITCH_SCRIPT="$SCRIPT_DIR/lid-switch.sh"
LAPTOP_DISPLAY="LAPTOP_MONITOR_PLACEHOLDER"
MAX_RECONCILIATION_ATTEMPTS=3
RECONCILIATION_COOLDOWN_TICKS=5
MAX_STABILITY_SAMPLES=40
REQUIRED_STABLE_SAMPLES=3
STABILITY_SAMPLE_INTERVAL=0.25

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

mark_resume_pending() {
    resume_pending=true
    log_info resume_requested coalesced=true
}

resume_pending=false
trap mark_resume_pending USR1

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
        :
    else
        observation_status=$?
        observed_topology=""
        observed_full_topology=""
        observed_policy_token=""
        observed_topology_error=$MONITOR_STATE_ERROR
        return "$observation_status"
    fi
    if ! observed_topology=$(monitor_state_topology_fingerprint); then
        observed_topology_error=topology_fingerprint_failed
        return 2
    fi
    if ! observed_full_topology=$(monitor_state_full_topology_fingerprint); then
        observed_topology_error=full_topology_fingerprint_failed
        return 2
    fi
    if ! observed_policy_token=$(monitor_state_policy_environment_token); then
        observed_topology_error=policy_token_failed
        return 2
    fi
    observed_topology_error=""
}

observe_joint_state_unlocked() {
    local trigger=$1
    local observation_status

    current_state=""
    current_topology=""
    current_full_topology=""
    current_policy_token=""
    if observe_lid_state; then
        current_state=$observed_state
        previous_lid_error=""
    else
        previous_lid_error=$observed_error
        log_error lid_state_observation_failed reason="$observed_error" \
            trigger="$trigger"
        return 2
    fi

    if observe_topology; then
        current_topology=$observed_topology
        current_full_topology=$observed_full_topology
        current_policy_token=$observed_policy_token
        previous_topology_error=""
    else
        observation_status=$?
        previous_topology_error=$observed_topology_error
        log_error topology_observation_failed reason="$observed_topology_error" \
            trigger="$trigger"
        return "$observation_status"
    fi
}

observe_joint_state() {
    local trigger=$1
    local observation_status=0 release_status

    if monitor_state_acquire_reconciliation_lock; then
        :
    else
        observation_status=$?
        log_error recovery_state_cleanup_failed phase=policy_observation \
            trigger="$trigger" status="$observation_status" \
            reason="$MONITOR_STATE_ERROR"
        return "$observation_status"
    fi
    if monitor_state_reconcile_stale_recovery_output; then
        :
    else
        observation_status=$?
        log_error recovery_state_cleanup_failed phase=policy_observation \
            trigger="$trigger" status="$observation_status" \
            reason="$MONITOR_STATE_ERROR"
    fi
    if (( observation_status == 0 )); then
        if observe_joint_state_unlocked "$trigger"; then
            :
        else
            observation_status=$?
        fi
    fi
    if monitor_state_release_reconciliation_lock; then
        :
    else
        release_status=$?
        if (( observation_status == 0 )); then
            observation_status=$release_status
            log_error recovery_state_cleanup_failed \
                phase=policy_observation trigger="$trigger" \
                status="$observation_status" reason="$MONITOR_STATE_ERROR"
        fi
    fi
    return "$observation_status"
}

stabilize_joint_state() {
    local trigger=$1
    local candidate="" sample_key final_key
    local consecutive=0 samples=0
    local last_valid_state="" last_valid_topology=""
    local last_valid_full_topology="" last_valid_policy_token=""
    local observation_status

    while (( samples < MAX_STABILITY_SAMPLES )); do
        samples=$((samples + 1))
        if observe_joint_state "stability_$trigger"; then
            last_valid_state=$current_state
            last_valid_topology=$current_topology
            last_valid_full_topology=$current_full_topology
            last_valid_policy_token=$current_policy_token
            sample_key="$current_state|$current_full_topology"
            if [[ "$sample_key" == "$candidate" ]]; then
                consecutive=$((consecutive + 1))
            else
                if [[ -n "$candidate" ]]; then
                    log_info stability_reset trigger="$trigger" samples="$samples" \
                        reason=sample_changed
                fi
                candidate=$sample_key
                consecutive=1
            fi
        else
            observation_status=$?
            if (( observation_status == 3 )) && \
                [[ "$previous_topology_error" == recovery_output_unowned ]]; then
                log_error stability_aborted trigger="$trigger" \
                    samples="$samples" status=3 \
                    reason=recovery_output_unowned
                return 3
            fi
            candidate=""
            consecutive=0
            log_info stability_reset trigger="$trigger" samples="$samples" \
                reason=observation_failed
        fi

        if (( consecutive >= REQUIRED_STABLE_SAMPLES )); then
            if (( samples >= MAX_STABILITY_SAMPLES )); then
                break
            fi
            samples=$((samples + 1))
            if observe_joint_state "stability_${trigger}_precommit"; then
                last_valid_state=$current_state
                last_valid_topology=$current_topology
                last_valid_full_topology=$current_full_topology
                last_valid_policy_token=$current_policy_token
                final_key="$current_state|$current_full_topology"
                if [[ "$final_key" == "$candidate" ]]; then
                    log_info stability_verified trigger="$trigger" samples="$samples" \
                        state="$current_state" topology="$current_full_topology" \
                        policy_token="$current_policy_token"
                    return 0
                fi
                candidate=$final_key
                consecutive=1
                log_info stability_reset trigger="$trigger" samples="$samples" \
                    reason=final_precommit_changed
            else
                candidate=""
                consecutive=0
                log_info stability_reset trigger="$trigger" samples="$samples" \
                    reason=final_precommit_failed
            fi
        fi

        if (( samples < MAX_STABILITY_SAMPLES )); then
            sleep "$STABILITY_SAMPLE_INTERVAL"
        fi
    done

    if [[ -n "$last_valid_state" ]]; then
        current_state=$last_valid_state
        current_topology=$last_valid_topology
        current_full_topology=$last_valid_full_topology
        current_policy_token=$last_valid_policy_token
    fi
    log_error stability_exhausted trigger="$trigger" \
        samples="$MAX_STABILITY_SAMPLES" status=2
    return 2
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
    if [[ "$require_dpms" == true ]]; then
        internal_dpms=$(monitor_state_internal_dpms) || return 1
        [[ "$internal_dpms" == true ]] || return 1
    fi
}

invoke_lid_switch() {
    local state=$1
    local preserve_dpms=$2
    local commit_generation=$3
    local expected_lid=$4
    local expected_policy_token=$5
    local invocation_status
    local require_dpms=false

    if [[ "$preserve_dpms" != true ]]; then
        require_dpms=true
    fi

    if [[ "$commit_generation" == true ]]; then
        if [[ "$state" == open && "$preserve_dpms" == true ]]; then
            ARCH_LIDSWITCH_EXPECTED_LID="$expected_lid" \
            ARCH_LIDSWITCH_EXPECTED_POLICY_TOKEN="$expected_policy_token" \
            ARCH_LIDSWITCH_REQUIRE_DPMS="$require_dpms" \
                "$LID_SWITCH_SCRIPT" --preserve-dpms open
        else
            ARCH_LIDSWITCH_EXPECTED_LID="$expected_lid" \
            ARCH_LIDSWITCH_EXPECTED_POLICY_TOKEN="$expected_policy_token" \
            ARCH_LIDSWITCH_REQUIRE_DPMS="$require_dpms" \
                "$LID_SWITCH_SCRIPT" "$state"
        fi
    elif [[ "$state" == open && "$preserve_dpms" == true ]]; then
        ARCH_LIDSWITCH_REQUIRE_DPMS="$require_dpms" \
            "$LID_SWITCH_SCRIPT" --preserve-dpms open
    else
        ARCH_LIDSWITCH_REQUIRE_DPMS="$require_dpms" \
            "$LID_SWITCH_SCRIPT" "$state"
    fi
    invocation_status=$?
    return "$invocation_status"
}

apply_observed_joint_state() {
    local trigger=$1
    local attempt=$2
    local preserve_dpms=$3
    local commit_generation=$4
    local attempted_state=$current_state
    local attempted_topology=$current_topology
    local attempted_policy_token=$current_policy_token
    local attempted_internal attempted_enabled_external_count
    local attempted_desired_internal wake_required=false
    local reconciliation_status

    log_info reconciliation_started trigger="$trigger" attempt="$attempt" \
        state="$attempted_state" preserve_dpms="$preserve_dpms" \
        commit_generation="$commit_generation" topology="$attempted_topology" \
        policy_token="$attempted_policy_token"
    invoke_lid_switch "$attempted_state" "$preserve_dpms" \
        "$commit_generation" "$attempted_state" "$attempted_policy_token"
    reconciliation_status=$?
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
    if [[ "$commit_generation" == true ]] && \
        { [[ "$current_state" != "$attempted_state" ]] || \
            [[ "$current_policy_token" != "$attempted_policy_token" ]]; }; then
        log_error reconciliation_failed trigger="$trigger" attempt="$attempt" \
            state="$attempted_state" status=5 \
            reason=post_action_generation_mismatch \
            observed_state="$current_state" \
            expected_policy_token="$attempted_policy_token" \
            observed_policy_token="$current_policy_token" \
            applied_ready="$applied_ready"
        return 5
    elif [[ "$current_state" != "$attempted_state" ]]; then
        log_error reconciliation_failed trigger="$trigger" attempt="$attempt" \
            state="$attempted_state" status=4 \
            reason=lid_state_changed_during_reconciliation \
            observed_state="$current_state" applied_ready="$applied_ready"
        return 4
    fi

    attempted_internal=$(jq -er '.internal.enabled | tostring' \
        <<< "$attempted_topology")
    attempted_enabled_external_count=$(jq -er \
        '[.externals[] | select(.enabled)] | length' \
        <<< "$attempted_topology")
    if [[ "$attempted_state" == closed && \
        "$attempted_enabled_external_count" -gt 0 ]]; then
        attempted_desired_internal=disabled
    else
        attempted_desired_internal=enabled
    fi
    if [[ "$attempted_desired_internal" == enabled ]] && \
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
    applied_policy_token=$current_policy_token
    applied_ready=true
    log_info reconciliation_succeeded trigger="$trigger" attempt="$attempt" \
        state="$applied_state" topology="$applied_topology" \
        policy_token="$applied_policy_token"
}

run_immediate_reconciliation_attempt() {
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
    apply_observed_joint_state "$trigger" "$attempt" "$preserve_dpms" false
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

recovery_cleanup_status=0
recovery_cleanup_error=""
recovery_lock_release_status=0
if monitor_state_acquire_reconciliation_lock; then
    if monitor_state_reconcile_stale_recovery_output; then
        :
    else
        recovery_cleanup_status=$?
        recovery_cleanup_error=$MONITOR_STATE_ERROR
    fi
    if monitor_state_release_reconciliation_lock; then
        if (( recovery_cleanup_status != 0 )); then
            MONITOR_STATE_ERROR=$recovery_cleanup_error
        fi
    else
        recovery_lock_release_status=$?
        if (( recovery_cleanup_status == 0 )); then
            recovery_cleanup_status=$recovery_lock_release_status
        else
            MONITOR_STATE_ERROR=$recovery_cleanup_error
        fi
    fi
else
    recovery_cleanup_status=$?
fi
if (( recovery_cleanup_status != 0 )); then
    log_error recovery_state_cleanup_failed phase=startup \
        status="$recovery_cleanup_status" reason="$MONITOR_STATE_ERROR"
    exit "$recovery_cleanup_status"
fi

applied_ready=false
applied_state=unknown
applied_topology=""
applied_policy_token=""
last_observed_ready=false
last_observed_state=unknown
last_observed_topology=""
previous_lid_error=""
previous_topology_error=""
current_state=""
current_topology=""
current_full_topology=""
current_policy_token=""

if [[ "${1:-}" == --once ]]; then
    reconciliation_status=2
    for ((attempt = 1; attempt <= MAX_RECONCILIATION_ATTEMPTS; attempt++)); do
        if run_immediate_reconciliation_attempt once "$attempt" true; then
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

if [[ "${1:-}" == --resume-once ]]; then
    reconciliation_status=2
    requires_stability=true
    for ((attempt = 1; attempt <= MAX_RECONCILIATION_ATTEMPTS; attempt++)); do
        if [[ "$requires_stability" == true ]]; then
            if stabilize_joint_state resume; then
                :
            else
                reconciliation_status=$?
                exit "$reconciliation_status"
            fi
            requires_stability=false
        fi
        if apply_observed_joint_state resume "$attempt" false true; then
            exit 0
        else
            reconciliation_status=$?
        fi
        case "$reconciliation_status" in
            1)
                exit 1
                ;;
            3)
                ;;
            2|4|5)
                requires_stability=true
                ;;
            *)
                requires_stability=true
                ;;
        esac
        if (( attempt < MAX_RECONCILIATION_ATTEMPTS )); then
            sleep 0.05
        fi
    done
    log_error reconciliation_exhausted trigger=resume \
        attempt="$MAX_RECONCILIATION_ATTEMPTS" status="$reconciliation_status"
    exit "$reconciliation_status"
fi

pending_reconciliation=true
pending_requires_stability=true
pending_preserve_dpms=true
pending_trigger=startup
burst_attempts=0
cooldown_ticks=0

process_pending_reconciliation() {
    local reconciliation_status

    if (( cooldown_ticks > 0 )); then
        cooldown_ticks=$((cooldown_ticks - 1))
        log_info reconciliation_cooldown_tick ticks_remaining="$cooldown_ticks"
        if (( cooldown_ticks == 0 )); then
            burst_attempts=0
            log_info reconciliation_rearmed reason=cooldown_elapsed
        fi
        return 0
    fi

    if [[ "$pending_requires_stability" == true ]]; then
        if stabilize_joint_state "$pending_trigger"; then
            pending_requires_stability=false
            burst_attempts=0
            record_last_observed_state
        else
            record_last_observed_state
            cooldown_ticks=$RECONCILIATION_COOLDOWN_TICKS
            log_error reconciliation_cooldown_started \
                ticks="$cooldown_ticks" reason=stability_exhausted \
                applied_ready="$applied_ready"
            return 2
        fi
    fi

    burst_attempts=$((burst_attempts + 1))
    if apply_observed_joint_state "$pending_trigger" "$burst_attempts" \
        "$pending_preserve_dpms" true; then
        pending_reconciliation=false
        pending_requires_stability=false
        pending_preserve_dpms=true
        pending_trigger=steady
        burst_attempts=0
        record_last_observed_state
        return 0
    else
        reconciliation_status=$?
    fi
    case "$reconciliation_status" in
        1)
            log_error reconciliation_fatal trigger="$pending_trigger" \
                attempt="$burst_attempts" status=1 \
                reason=contract_or_initialization_failure
            return 1
            ;;
        3)
            if (( burst_attempts >= MAX_RECONCILIATION_ATTEMPTS )); then
                cooldown_ticks=$RECONCILIATION_COOLDOWN_TICKS
                log_error reconciliation_cooldown_started \
                    ticks="$cooldown_ticks" reason=mutation_rejected \
                    applied_ready="$applied_ready"
            fi
            ;;
        2|4|5)
            pending_requires_stability=true
            burst_attempts=0
            log_info reconciliation_requires_stability \
                trigger="$pending_trigger" status="$reconciliation_status"
            ;;
        *)
            pending_requires_stability=true
            burst_attempts=0
            ;;
    esac
    return "$reconciliation_status"
}

if process_pending_reconciliation; then
    :
else
    reconciliation_status=$?
    if (( reconciliation_status == 1 )); then
        exit 1
    fi
fi
log_info monitor_started observed_state="$last_observed_state" \
    observed_topology="${last_observed_topology:-unavailable}" \
    applied_ready="$applied_ready" applied_state="$applied_state" \
    applied_topology="${applied_topology:-unavailable}"

while true; do
    if [[ "$resume_pending" == true ]]; then
        resume_pending=false
        pending_reconciliation=true
        pending_requires_stability=true
        pending_preserve_dpms=false
        pending_trigger=resume
        burst_attempts=0
        cooldown_ticks=0
        log_info resume_reconciliation_queued
    else
        if ! observe_joint_state poll; then
            sleep 1
            continue
        fi

        if [[ "$last_observed_ready" != true ]]; then
            pending_reconciliation=true
            pending_requires_stability=true
            pending_preserve_dpms=true
            pending_trigger=generation
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
                if [[ "$last_observed_state" == closed && \
                    "$current_state" == open ]]; then
                    pending_preserve_dpms=false
                else
                    pending_preserve_dpms=true
                fi
            elif [[ "$current_state" == open && \
                "$pending_reconciliation" != true ]]; then
                pending_preserve_dpms=true
            fi
            pending_reconciliation=true
            pending_requires_stability=true
            pending_trigger=generation
            burst_attempts=0
            cooldown_ticks=0
        fi
        record_last_observed_state
    fi

    if [[ "$pending_reconciliation" == true ]]; then
        if process_pending_reconciliation; then
            :
        else
            reconciliation_status=$?
            if (( reconciliation_status == 1 )); then
                exit 1
            fi
        fi
    fi

    sleep 1
done
