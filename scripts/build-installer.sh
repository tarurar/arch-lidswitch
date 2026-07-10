#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER_TEMPLATE="$ROOT_DIR/src/install-hyprland-lid-switch.sh.in"
INSTALLER="$ROOT_DIR/install-hyprland-lid-switch.sh"

usage() {
    echo "Usage: $0 [--check]" >&2
}

mode="write"
case "${1:-}" in
    "")
        ;;
    --check)
        mode="check"
        ;;
    *)
        usage
        exit 2
        ;;
esac

if [[ $# -gt 1 ]]; then
    usage
    exit 2
fi

temporary_installer=$(mktemp)
trap 'rm -f "$temporary_installer"' EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
        '@@LID_STATE_SCRIPT@@')
            sed -n 'p' "$ROOT_DIR/runtime/lid-state.sh"
            ;;
        '@@LID_SWITCH_SCRIPT@@')
            sed -n 'p' "$ROOT_DIR/runtime/lid-switch.sh.in"
            ;;
        '@@LID_MONITOR_SCRIPT@@')
            sed -n 'p' "$ROOT_DIR/runtime/lid-monitor.sh"
            ;;
        '@@LID_MONITOR_SERVICE@@')
            sed -n 'p' "$ROOT_DIR/runtime/lid-monitor.service.in"
            ;;
        *)
            printf '%s\n' "$line"
            ;;
    esac
done < "$INSTALLER_TEMPLATE" > "$temporary_installer"

if [[ "$mode" == "check" ]]; then
    if ! cmp -s "$temporary_installer" "$INSTALLER"; then
        echo "Generated installer is stale. Run scripts/build-installer.sh." >&2
        diff -u "$INSTALLER" "$temporary_installer" || true
        exit 1
    fi
    if [[ ! -x "$INSTALLER" ]]; then
        echo "Generated installer is not executable. Run scripts/build-installer.sh." >&2
        exit 1
    fi
    exit 0
fi

if ! cmp -s "$temporary_installer" "$INSTALLER"; then
    install -m 0755 "$temporary_installer" "$INSTALLER"
else
    chmod 0755 "$INSTALLER"
fi
