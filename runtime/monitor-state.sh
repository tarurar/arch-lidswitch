#!/bin/bash

MONITOR_STATE_ERROR=""
MONITOR_STATE_DIR=""
MONITOR_STATE_FILE=""

monitor_state_fail() {
    MONITOR_STATE_ERROR=$1
    return 2
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
}

monitor_state_capture_internal_layout() {
    local output=$1
    local monitors_json temporary_snapshot

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

    if ! monitors_json=$(hyprctl -j monitors all); then
        rm -f -- "$temporary_snapshot"
        monitor_state_fail monitor_query_failed
        return
    fi

    if ! jq -ce --arg output "$output" '
        def integer:
            type == "number" and . == floor;
        def positive_integer:
            integer and . > 0;
        def output_name:
            type == "string" and test("^[A-Za-z0-9_.:-]+$");

        select(type == "array")
        | [.[] | select(.name == $output)]
        | select(length == 1)
        | .[0] as $monitor
        | select(
            ($monitor.name | output_name) and
            ($monitor.width | positive_integer) and
            ($monitor.height | positive_integer) and
            ($monitor.refreshRate | type == "number" and . > 0) and
            ($monitor.x | integer) and
            ($monitor.y | integer) and
            ($monitor.scale | type == "number" and . > 0 and . <= 10) and
            ($monitor.transform | integer and . >= 0 and . <= 7) and
            ($monitor.disabled == false) and
            (($monitor.mirrorOf == "none") or ($monitor.mirrorOf | output_name))
        )
        | {
            output: $monitor.name,
            mode: (($monitor.width | tostring) + "x" +
                ($monitor.height | tostring) + "@" +
                ($monitor.refreshRate | tostring)),
            position: (($monitor.x | tostring) + "x" +
                ($monitor.y | tostring)),
            scale: $monitor.scale,
            transform: $monitor.transform,
            mirror: (if $monitor.mirrorOf == "none" then "" else $monitor.mirrorOf end)
        }
    ' <<< "$monitors_json" > "$temporary_snapshot"; then
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

    MONITOR_STATE_ERROR=""
    if [[ ! "$output" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
        monitor_state_fail internal_output_invalid
        return
    fi
    if ! hyprctl eval \
        "hl.monitor({ output = \"$output\", disabled = true })"; then
        MONITOR_STATE_ERROR=disable_apply_failed
        return 3
    fi
}

monitor_state_restore_internal_layout() {
    local output=$1
    local restore_expression

    MONITOR_STATE_ERROR=""
    if ! monitor_state_prepare_directory; then
        return 2
    fi
    if [[ ! -f "$MONITOR_STATE_FILE" || -L "$MONITOR_STATE_FILE" || \
        ! -O "$MONITOR_STATE_FILE" ]]; then
        monitor_state_fail snapshot_missing
        return
    fi

    if ! restore_expression=$(jq -er --arg output "$output" '
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
        | "hl.monitor({ output = \(.output | @json), disabled = false, " +
            "mode = \(.mode | @json), position = \(.position | @json), " +
            "scale = \(.scale), transform = \(.transform), " +
            "mirror = \(.mirror | @json) })"
    ' "$MONITOR_STATE_FILE"); then
        monitor_state_fail snapshot_invalid
        return
    fi

    if ! hyprctl eval "$restore_expression"; then
        MONITOR_STATE_ERROR=restore_apply_failed
        return 3
    fi

    if ! rm -f -- "$MONITOR_STATE_FILE"; then
        monitor_state_fail snapshot_cleanup_failed
        return
    fi
}
