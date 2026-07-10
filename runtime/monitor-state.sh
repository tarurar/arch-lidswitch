#!/bin/bash

MONITOR_STATE_ERROR=""
MONITOR_STATE_DIR=""
MONITOR_STATE_FILE=""
MONITOR_STATE_TOPOLOGY=""

monitor_state_fail() {
    MONITOR_STATE_ERROR=$1
    return 2
}

monitor_state_observe_topology() {
    local output=$1
    local monitors_json

    MONITOR_STATE_ERROR=""
    MONITOR_STATE_TOPOLOGY=""
    if ! monitors_json=$(hyprctl -j monitors all); then
        monitor_state_fail monitor_query_failed
        return
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
            (.disabled | type == "boolean")))
        | select((map(.name) | length) == (map(.name) | unique | length))
        | . as $monitors
        | [$monitors[] | select(.name == $output)]
        | select(length == 1)
        | .[0] as $internal
        | select($internal.disabled or ($internal | valid_layout))
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
                    dpms: dpms
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

monitor_state_enabled_external_count() {
    jq -er '[.externals[] | select(.enabled)] | length' \
        <<< "$MONITOR_STATE_TOPOLOGY"
}

monitor_state_topology_fingerprint() {
    jq -cer '{
        internal: {
            output: .internal.output,
            enabled: .internal.enabled,
            dpms: .internal.dpms
        },
        externals: [.externals[] | {
            output: .output,
            enabled: .enabled,
            dpms: .dpms
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
