#!/bin/bash

MONITOR_STATE_ERROR=""
MONITOR_STATE_DIR=""
MONITOR_STATE_FILE=""
MONITOR_STATE_RECOVERY_FILE=""
MONITOR_STATE_LOCK_FILE=""
MONITOR_STATE_LOCK_FD=""
MONITOR_STATE_LOCK_HELD=false
MONITOR_STATE_TOPOLOGY=""
MONITOR_STATE_SNAPSHOT=""
MONITOR_STATE_RECOVERY_TOPOLOGY=""
HYPRCTL_TIMEOUT_SECONDS=2
LAST_OUTPUT_RECOVERY_MAX_SAMPLES=40
LAST_OUTPUT_RECOVERY_SAMPLE_INTERVAL=0.05
LAST_OUTPUT_RECOVERY_DEADLINE_MICROSECONDS=2000000
LAST_OUTPUT_RECOVERY_NAME=ARCH-LIDSWITCH-RECOVERY
MONITOR_STATE_RECOVERY_OUTPUT=""
MONITOR_STATE_RECOVERY_USED=false
MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=false

monitor_state_fail() {
    MONITOR_STATE_ERROR=$1
    return 2
}

monitor_state_start_recovery_deadline() {
    local -n deadline_ref=$1
    local now=${EPOCHREALTIME/./}

    deadline_ref=$((10#$now + LAST_OUTPUT_RECOVERY_DEADLINE_MICROSECONDS))
}

monitor_state_recovery_deadline_reached() {
    local deadline=$1
    local now=${EPOCHREALTIME/./}

    (( 10#$now >= deadline ))
}

monitor_state_observe_topology() {
    local output=$1
    local monitors_json

    MONITOR_STATE_ERROR=""
    MONITOR_STATE_TOPOLOGY=""
    if ! monitors_json=$(timeout --kill-after=1s "$HYPRCTL_TIMEOUT_SECONDS" \
        hyprctl -j monitors all); then
        monitor_state_fail monitor_query_failed
        return
    fi
    if jq -e --arg recovery "$LAST_OUTPUT_RECOVERY_NAME" '
        type == "array" and any(.[]; .name == $recovery)
    ' <<< "$monitors_json" >/dev/null 2>&1; then
        MONITOR_STATE_ERROR=recovery_output_unowned
        return 3
    fi

    if ! MONITOR_STATE_TOPOLOGY=$(jq -ce --arg output "$output" '
        def integer:
            type == "number" and . == floor;
        def positive_integer:
            integer and . > 0;
        def output_name:
            type == "string" and test("^[A-Za-z0-9_.:-]+$");
        def valid_layout:
            (.width | positive_integer) and
            (.height | positive_integer) and
            (.refreshRate | type == "number" and . > 0) and
            (.x | integer) and
            (.y | integer) and
            (.scale | type == "number" and . > 0 and . <= 10) and
            (.transform | integer and . >= 0 and . <= 7) and
            ((.mirrorOf == "none") or (.mirrorOf | output_name));
        def dpms:
            if has("dpmsStatus") then .dpmsStatus else null end;

        select(type == "array" and length > 0)
        | select(all(.[];
            type == "object" and
            (.name | output_name) and
            (.disabled | type == "boolean") and
            ((has("dpmsStatus") | not) or
                (.dpmsStatus | type == "boolean"))))
        | select((map(.name) | length) == (map(.name) | unique | length))
        | . as $monitors
        | [$monitors[] | select(.name == $output)]
        | select(length == 1)
        | .[0] as $internal
        | select($internal.disabled or ($internal | valid_layout))
        | select(all($monitors[] | select(.name != $output);
            .disabled or (. | valid_layout)))
        | {
            internal: {
                output: $internal.name,
                enabled: ($internal.disabled == false),
                disabled: $internal.disabled,
                dpms: ($internal | dpms),
                layout: (if $internal.disabled then null else {
                    output: $internal.name,
                    mode: (($internal.width | tostring) + "x" +
                        ($internal.height | tostring) + "@" +
                        ($internal.refreshRate | tostring)),
                    position: (($internal.x | tostring) + "x" +
                        ($internal.y | tostring)),
                    scale: $internal.scale,
                    transform: $internal.transform,
                    mirror: (if $internal.mirrorOf == "none" then ""
                        else $internal.mirrorOf end)
                } end)
            },
            externals: ([$monitors[]
                | select(.name != $output)
                | {
                    output: .name,
                    enabled: (.disabled == false),
                    disabled: .disabled,
                    dpms: dpms,
                    layout: (if .disabled then null else {
                            output: .name,
                            mode: ((.width | tostring) + "x" +
                                (.height | tostring) + "@" +
                                (.refreshRate | tostring)),
                            position: ((.x | tostring) + "x" +
                                (.y | tostring)),
                            scale: .scale,
                            transform: .transform,
                            mirror: (if .mirrorOf == "none" then ""
                                else .mirrorOf end)
                        } end)
                }
            ] | sort_by(.output))
        }
    ' <<< "$monitors_json"); then
        monitor_state_fail monitor_topology_invalid
        return
    fi
}

monitor_state_internal_enabled() {
    jq -er '.internal.enabled' <<< "$MONITOR_STATE_TOPOLOGY"
}

monitor_state_internal_dpms() {
    jq -er '.internal.dpms
        | if type == "boolean" then tostring else error("invalid dpms") end' \
        <<< "$MONITOR_STATE_TOPOLOGY"
}

monitor_state_enabled_external_count() {
    jq -er '[.externals[] | select(.enabled)] | length' \
        <<< "$MONITOR_STATE_TOPOLOGY"
}

monitor_state_topology_fingerprint() {
    jq -cer '{
        internal: {
            output: .internal.output,
            enabled: .internal.enabled
        },
        externals: [.externals[] | {
            output: .output,
            enabled: .enabled
        }]
    }' <<< "$MONITOR_STATE_TOPOLOGY"
}

monitor_state_full_topology_fingerprint() {
    jq -cer '{
        internal: {
            output: .internal.output,
            enabled: .internal.enabled,
            disabled: .internal.disabled,
            dpms: .internal.dpms,
            layout: .internal.layout
        },
        externals: [.externals[] | {
            output: .output,
            enabled: .enabled,
            disabled: .disabled,
            dpms: .dpms,
            layout: .layout
        }]
    }' <<< "$MONITOR_STATE_TOPOLOGY"
}

monitor_state_policy_environment_token() {
    jq -cer '{
        internal: .internal.output,
        externals: [.externals[] | {
            output: .output,
            enabled: .enabled
        }]
    }' <<< "$MONITOR_STATE_TOPOLOGY"
}

monitor_state_prepare_directory() {
    local runtime_dir=${XDG_RUNTIME_DIR:-}
    local state_dir

    if [[ -z "$runtime_dir" || "$runtime_dir" != /* || \
        ! -d "$runtime_dir" || -L "$runtime_dir" || ! -O "$runtime_dir" ]]; then
        monitor_state_fail runtime_directory_unavailable
        return
    fi

    state_dir="$runtime_dir/arch-lidswitch"
    if [[ -e "$state_dir" || -L "$state_dir" ]]; then
        if [[ ! -d "$state_dir" || -L "$state_dir" || ! -O "$state_dir" ]]; then
            monitor_state_fail snapshot_directory_insecure
            return
        fi
    elif ! mkdir -m 0700 -- "$state_dir"; then
        monitor_state_fail snapshot_directory_unwritable
        return
    fi

    if ! chmod 0700 -- "$state_dir"; then
        monitor_state_fail snapshot_directory_unwritable
        return
    fi

    MONITOR_STATE_DIR=$state_dir
    MONITOR_STATE_FILE="$state_dir/internal-layout.json"
    MONITOR_STATE_RECOVERY_FILE="$state_dir/recovery-output"
    MONITOR_STATE_LOCK_FILE="$state_dir/reconciliation.lock"
}

monitor_state_acquire_reconciliation_lock() {
    if [[ "$MONITOR_STATE_LOCK_HELD" == true ]]; then
        return 0
    fi
    # Without a runtime directory no snapshot or recovery marker can exist,
    # so legacy read-only/no-layout paths remain safe without serialization.
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
        return 0
    fi
    if ! monitor_state_prepare_directory; then
        return 2
    fi
    if [[ -e "$MONITOR_STATE_LOCK_FILE" || -L "$MONITOR_STATE_LOCK_FILE" ]]; then
        if [[ ! -f "$MONITOR_STATE_LOCK_FILE" || \
            -L "$MONITOR_STATE_LOCK_FILE" || \
            ! -O "$MONITOR_STATE_LOCK_FILE" ]]; then
            monitor_state_fail recovery_lock_insecure
            return 2
        fi
    fi
    if exec {MONITOR_STATE_LOCK_FD}>> "$MONITOR_STATE_LOCK_FILE"; then
        :
    else
        MONITOR_STATE_LOCK_FD=""
        monitor_state_fail recovery_lock_unavailable
        return 2
    fi
    if ! chmod 0600 -- "$MONITOR_STATE_LOCK_FILE"; then
        exec {MONITOR_STATE_LOCK_FD}>&-
        MONITOR_STATE_LOCK_FD=""
        monitor_state_fail recovery_lock_unavailable
        return 2
    fi
    if flock -n "$MONITOR_STATE_LOCK_FD"; then
        MONITOR_STATE_LOCK_HELD=true
        return 0
    fi
    exec {MONITOR_STATE_LOCK_FD}>&-
    MONITOR_STATE_LOCK_FD=""
    MONITOR_STATE_ERROR=recovery_reconciliation_busy
    return 3
}

monitor_state_release_reconciliation_lock() {
    local release_status=0

    if [[ "$MONITOR_STATE_LOCK_HELD" != true ]]; then
        return 0
    fi
    if ! flock -u "$MONITOR_STATE_LOCK_FD"; then
        monitor_state_fail recovery_lock_release_failed
        release_status=2
    fi
    if ! exec {MONITOR_STATE_LOCK_FD}>&-; then
        monitor_state_fail recovery_lock_release_failed
        release_status=2
    fi
    MONITOR_STATE_LOCK_FD=""
    MONITOR_STATE_LOCK_HELD=false
    return "$release_status"
}

monitor_state_snapshot_present() {
    MONITOR_STATE_ERROR=""
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
        return 1
    fi
    if ! monitor_state_prepare_directory; then
        return 2
    fi
    [[ -e "$MONITOR_STATE_FILE" || -L "$MONITOR_STATE_FILE" ]]
}

monitor_state_load_internal_layout_snapshot() {
    local output=$1

    MONITOR_STATE_ERROR=""
    MONITOR_STATE_SNAPSHOT=""
    if ! monitor_state_prepare_directory; then
        return 2
    fi
    if [[ ! -f "$MONITOR_STATE_FILE" || -L "$MONITOR_STATE_FILE" || \
        ! -O "$MONITOR_STATE_FILE" ]]; then
        monitor_state_fail snapshot_missing
        return
    fi

    if ! MONITOR_STATE_SNAPSHOT=$(jq -ce --arg output "$output" '
        def integer:
            type == "number" and . == floor;
        def output_name:
            type == "string" and test("^[A-Za-z0-9_.:-]+$");

        select(type == "object")
        | select((keys | sort) ==
            ["mirror", "mode", "output", "position", "scale", "transform"])
        | select(.output == $output and (.output | output_name))
        | select(.mode | type == "string" and
            test("^[1-9][0-9]*x[1-9][0-9]*@[0-9]+([.][0-9]+)?$"))
        | select(.position | type == "string" and
            test("^-?[0-9]+x-?[0-9]+$"))
        | select(.scale | type == "number" and . > 0 and . <= 10)
        | select(.transform | integer and . >= 0 and . <= 7)
        | select(.mirror == "" or (.mirror | output_name))
    ' "$MONITOR_STATE_FILE"); then
        monitor_state_fail snapshot_invalid
        return
    fi
}

monitor_state_internal_layout_matches_snapshot() {
    local output=$1
    local load_status

    if monitor_state_load_internal_layout_snapshot "$output"; then
        :
    else
        load_status=$?
        return "$load_status"
    fi
    jq -e --arg output "$output" --argjson snapshot "$MONITOR_STATE_SNAPSHOT" '
        .internal.output == $output and
        .internal.enabled and
        .internal.layout == $snapshot
    ' <<< "$MONITOR_STATE_TOPOLOGY" >/dev/null
}

monitor_state_capture_internal_layout() {
    local output=$1
    local temporary_snapshot

    MONITOR_STATE_ERROR=""
    if ! monitor_state_prepare_directory; then
        return 2
    fi

    if ! temporary_snapshot=$(mktemp "$MONITOR_STATE_DIR/.internal-layout.XXXXXX"); then
        monitor_state_fail snapshot_unwritable
        return
    fi
    if ! chmod 0600 -- "$temporary_snapshot"; then
        rm -f -- "$temporary_snapshot"
        monitor_state_fail snapshot_unwritable
        return
    fi

    if ! jq -ce --arg output "$output" '
        select(.internal.output == $output and .internal.enabled)
        | .internal.layout
        | select(type == "object")
    ' <<< "$MONITOR_STATE_TOPOLOGY" > "$temporary_snapshot"; then
        rm -f -- "$temporary_snapshot"
        monitor_state_fail monitor_snapshot_invalid
        return
    fi

    if ! mv -f -- "$temporary_snapshot" "$MONITOR_STATE_FILE"; then
        rm -f -- "$temporary_snapshot"
        monitor_state_fail snapshot_unwritable
        return
    fi
}

monitor_state_disable_internal_output() {
    local output=$1
    local apply_output

    MONITOR_STATE_ERROR=""
    if [[ ! "$output" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
        monitor_state_fail internal_output_invalid
        return
    fi
    if ! apply_output=$(timeout --kill-after=1s "$HYPRCTL_TIMEOUT_SECONDS" hyprctl eval \
        "hl.monitor({ output = \"$output\", disabled = true })"); then
        MONITOR_STATE_ERROR=disable_apply_failed
        return 3
    fi
    if [[ "$apply_output" != ok ]]; then
        MONITOR_STATE_ERROR=disable_apply_failed
        return 3
    fi
}

monitor_state_restore_internal_layout() {
    local output=$1
    local restore_expression apply_output
    local load_status

    MONITOR_STATE_ERROR=""
    if monitor_state_load_internal_layout_snapshot "$output"; then
        :
    else
        load_status=$?
        return "$load_status"
    fi

    if ! restore_expression=$(jq -er '
        "hl.monitor({ output = \(.output | @json), disabled = false, " +
            "mode = \(.mode | @json), position = \(.position | @json), " +
            "scale = \(.scale), transform = \(.transform), " +
            "mirror = \(.mirror | @json) })"
    ' <<< "$MONITOR_STATE_SNAPSHOT"); then
        monitor_state_fail snapshot_invalid
        return
    fi

    if ! apply_output=$(timeout --kill-after=1s "$HYPRCTL_TIMEOUT_SECONDS" \
        hyprctl eval "$restore_expression"); then
        MONITOR_STATE_ERROR=restore_apply_failed
        return 3
    fi
    if [[ "$apply_output" != ok ]]; then
        MONITOR_STATE_ERROR=restore_apply_failed
        return 3
    fi
}

monitor_state_observe_recovery_topology() {
    local monitors_json validated_topology

    MONITOR_STATE_ERROR=""
    MONITOR_STATE_RECOVERY_TOPOLOGY=""
    if ! monitors_json=$(timeout --kill-after=1s "$HYPRCTL_TIMEOUT_SECONDS" \
        hyprctl -j monitors all); then
        monitor_state_fail recovery_monitor_query_failed
        return 2
    fi
    if ! validated_topology=$(jq -ce '
        def output_name:
            type == "string" and test("^[A-Za-z0-9_.:-]+$");

        select(type == "array" and length > 0)
        | select(all(.[];
            type == "object" and
            (.name | output_name) and
            (.disabled | type == "boolean")))
        | select((map(.name) | length) == (map(.name) | unique | length))
    ' <<< "$monitors_json"); then
        monitor_state_fail recovery_monitor_topology_invalid
        return 2
    fi
    MONITOR_STATE_RECOVERY_TOPOLOGY=$validated_topology
}

monitor_state_recovery_output_enabled() {
    local topology=$1

    jq -e --arg output "$LAST_OUTPUT_RECOVERY_NAME" '
        [.[] | select(.name == $output and .disabled == false)] | length == 1
    ' <<< "$topology" >/dev/null
}

monitor_state_recovery_output_absent() {
    local topology=$1

    jq -e --arg output "$LAST_OUTPUT_RECOVERY_NAME" '
        [.[] | select(.name == $output)] | length == 0
    ' <<< "$topology" >/dev/null
}

monitor_state_internal_output_enabled_in_recovery_topology() {
    local topology=$1
    local output=$2

    jq -e --arg output "$output" '
        [.[] | select(.name == $output and .disabled == false)] | length == 1
    ' <<< "$topology" >/dev/null
}

monitor_state_internal_dpms_enabled_in_recovery_topology() {
    local topology=$1
    local output=$2

    jq -e --arg output "$output" '
        [.[] | select(.name == $output and .disabled == false and
            .dpmsStatus == true)] | length == 1
    ' <<< "$topology" >/dev/null
}

monitor_state_recovery_generation_fingerprint() {
    local topology=$1

    jq -ce --arg recovery "$LAST_OUTPUT_RECOVERY_NAME" '
        [.[] | select(.name != $recovery) | if .disabled then {
            name,
            disabled,
            dpmsStatus: (if has("dpmsStatus") then .dpmsStatus else null end)
        } else {
            name,
            disabled,
            dpmsStatus: (if has("dpmsStatus") then .dpmsStatus else null end),
            width,
            height,
            refreshRate,
            x,
            y,
            scale,
            transform,
            mirrorOf
        } end] | sort_by(.name)
    ' <<< "$topology"
}

monitor_state_last_output_recovery_generation_matches() {
    local topology=$1
    local internal_output=$2
    local baseline_generation=$3
    local current_generation

    current_generation=$(monitor_state_recovery_generation_fingerprint \
        "$topology") || return 1
    [[ "$current_generation" == "$baseline_generation" ]] || return 1

    jq -e --arg recovery "$LAST_OUTPUT_RECOVERY_NAME" \
        --arg internal "$internal_output" '
        ([.[] | select(.name == $internal and .disabled == true)]
            | length == 1) and
        ([.[] | select(.name == $recovery and .disabled == false)]
            | length == 1) and
        ([.[] | select(.disabled == false)]
            | length == 1 and .[0].name == $recovery)
    ' <<< "$topology" >/dev/null
}

monitor_state_validate_recovery_marker() {
    local marker_mode marker_size marker_value expected_size

    if [[ ! -f "$MONITOR_STATE_RECOVERY_FILE" || \
        -L "$MONITOR_STATE_RECOVERY_FILE" || \
        ! -O "$MONITOR_STATE_RECOVERY_FILE" ]]; then
        monitor_state_fail recovery_marker_insecure
        return 2
    fi
    read -r marker_mode marker_size < <(
        stat -c '%a %s' -- "$MONITOR_STATE_RECOVERY_FILE"
    ) || {
        monitor_state_fail recovery_marker_insecure
        return 2
    }
    marker_value=$(<"$MONITOR_STATE_RECOVERY_FILE")
    expected_size=$((${#LAST_OUTPUT_RECOVERY_NAME} + 1))
    if [[ "$marker_mode" != 600 || "$marker_size" -ne "$expected_size" || \
        "$marker_value" != "$LAST_OUTPUT_RECOVERY_NAME" ]]; then
        monitor_state_fail recovery_marker_invalid
        return 2
    fi
    MONITOR_STATE_RECOVERY_OUTPUT=$marker_value
}

monitor_state_load_recovery_marker() {
    local runtime_dir=${XDG_RUNTIME_DIR:-}
    local marker_file

    if [[ -z "$runtime_dir" || "$runtime_dir" != /* ]]; then
        return 1
    fi
    marker_file="$runtime_dir/arch-lidswitch/recovery-output"
    if [[ ! -e "$marker_file" && ! -L "$marker_file" ]]; then
        return 1
    fi
    if ! monitor_state_prepare_directory; then
        return 2
    fi
    monitor_state_validate_recovery_marker
}

monitor_state_load_recovery_marker_read_only() {
    local runtime_dir=${XDG_RUNTIME_DIR:-}
    local state_dir state_mode marker_file

    if [[ -z "$runtime_dir" || "$runtime_dir" != /* ]]; then
        return 1
    fi
    state_dir="$runtime_dir/arch-lidswitch"
    marker_file="$state_dir/recovery-output"
    if [[ ! -e "$marker_file" && ! -L "$marker_file" ]]; then
        return 1
    fi
    if [[ ! -d "$runtime_dir" || -L "$runtime_dir" || \
        ! -O "$runtime_dir" || ! -d "$state_dir" || -L "$state_dir" || \
        ! -O "$state_dir" ]]; then
        monitor_state_fail recovery_marker_insecure
        return 2
    fi
    state_mode=$(stat -c '%a' -- "$state_dir") || {
        monitor_state_fail recovery_marker_insecure
        return 2
    }
    if [[ "$state_mode" != 700 ]]; then
        monitor_state_fail recovery_marker_insecure
        return 2
    fi
    MONITOR_STATE_DIR=$state_dir
    MONITOR_STATE_FILE="$state_dir/internal-layout.json"
    MONITOR_STATE_RECOVERY_FILE=$marker_file
    MONITOR_STATE_LOCK_FILE="$state_dir/reconciliation.lock"
    monitor_state_validate_recovery_marker
}

monitor_state_check_recovery_state_read_only() {
    local marker_status

    MONITOR_STATE_RECOVERY_OUTPUT=""
    if monitor_state_load_recovery_marker_read_only; then
        MONITOR_STATE_RECOVERY_OUTPUT=""
        MONITOR_STATE_ERROR=recovery_cleanup_pending
        return 2
    else
        marker_status=$?
        if (( marker_status == 1 )); then
            return 0
        fi
        return "$marker_status"
    fi
}

monitor_state_write_recovery_marker() {
    local temporary_marker

    if ! monitor_state_prepare_directory; then
        return 2
    fi
    if [[ -e "$MONITOR_STATE_RECOVERY_FILE" || \
        -L "$MONITOR_STATE_RECOVERY_FILE" ]]; then
        monitor_state_fail recovery_marker_exists
        return 2
    fi
    if ! temporary_marker=$(mktemp \
        "$MONITOR_STATE_DIR/.recovery-output.XXXXXX"); then
        monitor_state_fail recovery_marker_unwritable
        return 2
    fi
    if ! chmod 0600 -- "$temporary_marker" || \
        ! printf '%s\n' "$LAST_OUTPUT_RECOVERY_NAME" > "$temporary_marker" || \
        ! mv -nT -- "$temporary_marker" "$MONITOR_STATE_RECOVERY_FILE" || \
        [[ -e "$temporary_marker" ]]; then
        rm -f -- "$temporary_marker"
        monitor_state_fail recovery_marker_unwritable
        return 2
    fi
    MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=false
    MONITOR_STATE_RECOVERY_OUTPUT=$LAST_OUTPUT_RECOVERY_NAME
}

monitor_state_clear_recovery_marker() {
    if [[ -n "$MONITOR_STATE_RECOVERY_FILE" && \
        ( -e "$MONITOR_STATE_RECOVERY_FILE" || \
            -L "$MONITOR_STATE_RECOVERY_FILE" ) ]]; then
        if [[ ! -f "$MONITOR_STATE_RECOVERY_FILE" || \
            -L "$MONITOR_STATE_RECOVERY_FILE" || \
            ! -O "$MONITOR_STATE_RECOVERY_FILE" ]]; then
            monitor_state_fail recovery_marker_insecure
            return 2
        fi
        if ! rm -f -- "$MONITOR_STATE_RECOVERY_FILE"; then
            monitor_state_fail recovery_marker_unwritable
            return 2
        fi
    fi
}

monitor_state_remove_recovery_output() {
    local sample observation_status marker_status deadline remove_output

    if [[ -z "$MONITOR_STATE_RECOVERY_OUTPUT" ]]; then
        return 0
    fi
    if monitor_state_observe_recovery_topology; then
        :
    else
        observation_status=$?
        MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=true
        return "$observation_status"
    fi
    if monitor_state_recovery_output_absent \
        "$MONITOR_STATE_RECOVERY_TOPOLOGY"; then
        monitor_state_start_recovery_deadline deadline
        for ((sample = 2; sample <= LAST_OUTPUT_RECOVERY_MAX_SAMPLES; sample++)); do
            sleep "$LAST_OUTPUT_RECOVERY_SAMPLE_INTERVAL"
            if monitor_state_observe_recovery_topology; then
                :
            else
                observation_status=$?
                MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=true
                return "$observation_status"
            fi
            if ! monitor_state_recovery_output_absent \
                "$MONITOR_STATE_RECOVERY_TOPOLOGY"; then
                break
            fi
            if monitor_state_recovery_deadline_reached "$deadline"; then
                break
            fi
        done
        if monitor_state_recovery_output_absent \
            "$MONITOR_STATE_RECOVERY_TOPOLOGY"; then
            if monitor_state_clear_recovery_marker; then
                :
            else
                marker_status=$?
                MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=true
                return "$marker_status"
            fi
            MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=false
            MONITOR_STATE_RECOVERY_OUTPUT=""
            return 0
        fi
    fi
    if ! remove_output=$(timeout --kill-after=1s "$HYPRCTL_TIMEOUT_SECONDS" \
        hyprctl output remove "$MONITOR_STATE_RECOVERY_OUTPUT"); then
        monitor_state_fail recovery_output_remove_failed
        MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=true
        return 3
    fi
    if [[ "$remove_output" != ok ]]; then
        monitor_state_fail recovery_output_remove_failed
        MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=true
        return 3
    fi
    monitor_state_start_recovery_deadline deadline
    for ((sample = 1; sample <= LAST_OUTPUT_RECOVERY_MAX_SAMPLES; sample++)); do
        if monitor_state_observe_recovery_topology; then
            :
        else
            observation_status=$?
            MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=true
            return "$observation_status"
        fi
        if monitor_state_recovery_output_absent \
            "$MONITOR_STATE_RECOVERY_TOPOLOGY"; then
            if monitor_state_clear_recovery_marker; then
                :
            else
                marker_status=$?
                MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=true
                return "$marker_status"
            fi
            MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=false
            MONITOR_STATE_RECOVERY_OUTPUT=""
            return 0
        fi
        if (( sample == LAST_OUTPUT_RECOVERY_MAX_SAMPLES )) || \
            monitor_state_recovery_deadline_reached "$deadline"; then
            break
        fi
        sleep "$LAST_OUTPUT_RECOVERY_SAMPLE_INTERVAL"
    done
    monitor_state_fail recovery_output_remove_unverified
    MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=true
    return 3
}

monitor_state_reconcile_stale_recovery_output() {
    local marker_status

    MONITOR_STATE_RECOVERY_OUTPUT=""
    if monitor_state_load_recovery_marker; then
        :
    else
        marker_status=$?
        if (( marker_status == 1 )); then
            return 0
        fi
        return "$marker_status"
    fi
    monitor_state_remove_recovery_output
}

monitor_state_cleanup_recovery_output() {
    [[ -n "$MONITOR_STATE_RECOVERY_OUTPUT" ]] || return 0
    [[ "$MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED" != true ]] || return 0
    monitor_state_remove_recovery_output >/dev/null 2>&1 || true
    return 0
}

monitor_state_cleanup_recovery_output_on_exit() {
    local exit_status=$?

    trap - EXIT
    monitor_state_cleanup_recovery_output
    monitor_state_release_reconciliation_lock >/dev/null 2>&1 || true
    exit "$exit_status"
}

monitor_state_abort_last_output_recovery() {
    local failure_status=$1
    local failure_reason=$2
    local cleanup_status

    MONITOR_STATE_ERROR=$failure_reason
    if monitor_state_remove_recovery_output; then
        MONITOR_STATE_ERROR=$failure_reason
        return "$failure_status"
    else
        cleanup_status=$?
        return "$cleanup_status"
    fi
}

monitor_state_reject_unaccepted_recovery_create() {
    local marker_status

    if monitor_state_clear_recovery_marker; then
        MONITOR_STATE_RECOVERY_OUTPUT=""
        MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=false
        MONITOR_STATE_ERROR=recovery_output_create_failed
        return 3
    else
        marker_status=$?
        MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=true
        return "$marker_status"
    fi
}

monitor_state_restore_internal_layout_with_last_output_recovery() {
    local output=$1
    local expected_lid=${2:-}
    local require_dpms=${3:-false}
    local recovery_rule apply_output create_output sample deadline recovery_status=0
    local observation_status marker_status remove_status
    local recovery_absence_verified=false
    local baseline_generation observed_lid
    local original_error=""

    MONITOR_STATE_RECOVERY_USED=false
    MONITOR_STATE_RECOVERY_OUTPUT=""
    MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=false
    if monitor_state_observe_recovery_topology; then
        :
    else
        observation_status=$?
        return "$observation_status"
    fi
    if ! baseline_generation=$(monitor_state_recovery_generation_fingerprint \
        "$MONITOR_STATE_RECOVERY_TOPOLOGY"); then
        monitor_state_fail recovery_monitor_topology_invalid
        return 2
    fi
    if ! monitor_state_recovery_output_absent \
        "$MONITOR_STATE_RECOVERY_TOPOLOGY"; then
        monitor_state_fail recovery_output_collision
        return 3
    fi
    if monitor_state_write_recovery_marker; then
        :
    else
        marker_status=$?
        return "$marker_status"
    fi
    recovery_rule="hl.monitor({ output = \"$LAST_OUTPUT_RECOVERY_NAME\", disabled = false, mode = \"1280x720@60\", position = \"auto-right\", scale = 1 })"
    if ! apply_output=$(timeout --kill-after=1s "$HYPRCTL_TIMEOUT_SECONDS" \
        hyprctl eval "$recovery_rule"); then
        monitor_state_abort_last_output_recovery \
            3 recovery_output_rule_failed
        return $?
    fi
    if [[ "$apply_output" != ok ]]; then
        monitor_state_abort_last_output_recovery \
            3 recovery_output_rule_failed
        return $?
    fi
    if ! create_output=$(timeout --kill-after=1s "$HYPRCTL_TIMEOUT_SECONDS" \
        hyprctl output create headless "$LAST_OUTPUT_RECOVERY_NAME"); then
        monitor_state_abort_last_output_recovery \
            3 recovery_output_create_failed
        return $?
    fi
    if [[ "$create_output" != ok ]]; then
        monitor_state_reject_unaccepted_recovery_create
        return $?
    fi
    monitor_state_start_recovery_deadline deadline
    for ((sample = 1; sample <= LAST_OUTPUT_RECOVERY_MAX_SAMPLES; sample++)); do
        if monitor_state_observe_recovery_topology; then
            :
        else
            observation_status=$?
            recovery_status=$observation_status
            break
        fi
        if monitor_state_recovery_output_enabled \
            "$MONITOR_STATE_RECOVERY_TOPOLOGY"; then
            break
        fi
        if (( sample == LAST_OUTPUT_RECOVERY_MAX_SAMPLES )) || \
            monitor_state_recovery_deadline_reached "$deadline"; then
            monitor_state_fail recovery_output_create_unverified
            recovery_status=3
            if monitor_state_recovery_output_absent \
                "$MONITOR_STATE_RECOVERY_TOPOLOGY"; then
                recovery_absence_verified=true
            fi
            break
        fi
        sleep "$LAST_OUTPUT_RECOVERY_SAMPLE_INTERVAL"
    done

    if (( recovery_status == 0 )) && \
        ! monitor_state_last_output_recovery_generation_matches \
            "$MONITOR_STATE_RECOVERY_TOPOLOGY" "$output" \
            "$baseline_generation"; then
        MONITOR_STATE_ERROR=generation_mismatch
        recovery_status=5
    fi
    if (( recovery_status == 0 )) && [[ -n "$expected_lid" ]]; then
        if observed_lid=$(read_lid_state); then
            if [[ "$observed_lid" != "$expected_lid" ]]; then
                MONITOR_STATE_ERROR=generation_mismatch
                recovery_status=5
            fi
        else
            MONITOR_STATE_ERROR=recovery_lid_state_unavailable
            recovery_status=2
        fi
    fi
    if (( recovery_status == 0 )); then
        if monitor_state_restore_internal_layout "$output"; then
            :
        else
            recovery_status=$?
        fi
    fi
    if (( recovery_status == 0 )); then
        monitor_state_start_recovery_deadline deadline
        for ((sample = 1; sample <= LAST_OUTPUT_RECOVERY_MAX_SAMPLES; sample++)); do
            if monitor_state_observe_recovery_topology; then
                :
            else
                observation_status=$?
                recovery_status=$observation_status
                break
            fi
            if monitor_state_internal_output_enabled_in_recovery_topology \
                "$MONITOR_STATE_RECOVERY_TOPOLOGY" "$output"; then
                break
            fi
            if (( sample == LAST_OUTPUT_RECOVERY_MAX_SAMPLES )) || \
                monitor_state_recovery_deadline_reached "$deadline"; then
                monitor_state_fail recovery_internal_enable_unverified
                recovery_status=3
                break
            fi
            sleep "$LAST_OUTPUT_RECOVERY_SAMPLE_INTERVAL"
        done
    fi
    if (( recovery_status == 0 )) && [[ "$require_dpms" == true ]]; then
        if monitor_state_enable_internal_dpms "$output"; then
            monitor_state_start_recovery_deadline deadline
            for ((sample = 1; sample <= LAST_OUTPUT_RECOVERY_MAX_SAMPLES; sample++)); do
                if monitor_state_observe_recovery_topology; then
                    :
                else
                    observation_status=$?
                    recovery_status=$observation_status
                    break
                fi
                if monitor_state_internal_dpms_enabled_in_recovery_topology \
                    "$MONITOR_STATE_RECOVERY_TOPOLOGY" "$output"; then
                    break
                fi
                if (( sample == LAST_OUTPUT_RECOVERY_MAX_SAMPLES )) || \
                    monitor_state_recovery_deadline_reached "$deadline"; then
                    monitor_state_fail recovery_internal_dpms_unverified
                    recovery_status=3
                    break
                fi
                sleep "$LAST_OUTPUT_RECOVERY_SAMPLE_INTERVAL"
            done
        else
            recovery_status=$?
        fi
    fi
    if (( recovery_status != 0 )); then
        original_error=$MONITOR_STATE_ERROR
    fi
    if [[ "$recovery_absence_verified" == true ]]; then
        if monitor_state_clear_recovery_marker; then
            MONITOR_STATE_RECOVERY_CLEANUP_DEFERRED=false
            MONITOR_STATE_RECOVERY_OUTPUT=""
            MONITOR_STATE_ERROR=$original_error
        else
            recovery_status=$?
        fi
    elif monitor_state_remove_recovery_output; then
        if (( recovery_status != 0 )); then
            MONITOR_STATE_ERROR=$original_error
        fi
    else
        remove_status=$?
        recovery_status=$remove_status
    fi
    if (( recovery_status != 0 )); then
        return "$recovery_status"
    fi
    MONITOR_STATE_RECOVERY_USED=true
}

monitor_state_enable_internal_dpms() {
    local output=$1
    local apply_output

    MONITOR_STATE_ERROR=""
    if [[ ! "$output" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
        monitor_state_fail internal_output_invalid
        return
    fi
    if ! apply_output=$(timeout --kill-after=1s "$HYPRCTL_TIMEOUT_SECONDS" hyprctl eval \
        "hl.dispatch(hl.dsp.dpms({ action = \"enable\", monitor = \"$output\" }))"); then
        MONITOR_STATE_ERROR=dpms_apply_failed
        return 3
    fi
    if [[ "$apply_output" != ok ]]; then
        MONITOR_STATE_ERROR=dpms_apply_failed
        return 3
    fi
}

monitor_state_cleanup_internal_layout() {
    MONITOR_STATE_ERROR=""
    if ! monitor_state_prepare_directory; then
        return 2
    fi
    if [[ ! -e "$MONITOR_STATE_FILE" && ! -L "$MONITOR_STATE_FILE" ]]; then
        return 0
    fi
    if [[ ! -f "$MONITOR_STATE_FILE" || -L "$MONITOR_STATE_FILE" || \
        ! -O "$MONITOR_STATE_FILE" ]]; then
        monitor_state_fail snapshot_insecure
        return
    fi

    if ! rm -f -- "$MONITOR_STATE_FILE"; then
        monitor_state_fail snapshot_cleanup_failed
        return
    fi
}
