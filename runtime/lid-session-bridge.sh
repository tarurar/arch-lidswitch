#!/bin/bash

set -euo pipefail

SESSION_TARGET="hyprland-session.target"
HYPRLAND_ENV_NAMES=(
    DISPLAY
    WAYLAND_DISPLAY
    HYPRLAND_INSTANCE_SIGNATURE
    XDG_CURRENT_DESKTOP
    QT_QPA_PLATFORMTHEME
    PATH
    XDG_DATA_DIRS
)

usage() {
    echo "Usage: $0 {start|stop}" >&2
}

require_session_environment() {
    local variable_name

    for variable_name in WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE; do
        if [[ -z "${!variable_name:-}" ]]; then
            echo "arch-lidswitch: required session variable is missing: $variable_name" >&2
            return 1
        fi
    done
}

start_session() {
    local variable_name
    local -a defined_names=()

    require_session_environment

    for variable_name in "${HYPRLAND_ENV_NAMES[@]}"; do
        if [[ -v "$variable_name" ]]; then
            defined_names+=("$variable_name")
        fi
    done

    systemctl --user import-environment "${defined_names[@]}"
    systemctl --user start "$SESSION_TARGET"
}

stop_session() {
    local stop_status=0

    systemctl --user stop "$SESSION_TARGET" || stop_status=$?
    sleep 0.1
    return "$stop_status"
}

case "${1:-}" in
    start)
        start_session
        ;;
    stop)
        stop_session
        ;;
    *)
        usage
        exit 2
        ;;
esac
