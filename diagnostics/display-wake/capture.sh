#!/usr/bin/env bash
# Read-only display capture with a human-driven suspend/resume test.
set -euo pipefail
umask 077

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mode=${1:---test}
case "$mode" in
    --snapshot|--test) ;;
    *) printf 'Usage: bash %s [--snapshot|--test]\n' "$0" >&2; exit 2 ;;
esac
mkdir -p "$root/captures"
destination=$(mktemp -d "$root/captures/$(date +%Y%m%dT%H%M%S).XXXXXX")
started=$(date --iso-8601=seconds)
printf 'Capture directory: %s\n' "$destination"

snapshot() {
    date --iso-8601=ns
    printf '\nCOMPOSITOR\n'
    timeout --kill-after=1s 3s hyprctl -j monitors all || true
    printf '\nKERNEL CONNECTORS\n'
    local file
    for file in /sys/class/drm/card*-*/{status,enabled,dpms}; do
        [[ -r "$file" ]] || continue
        printf '%s: ' "$file"
        cat "$file" || true
    done
    printf '\nLID\n'
    for file in /proc/acpi/button/lid/*/state; do
        [[ -r "$file" ]] || continue
        cat "$file" || true
    done
}

display_log() {
    # Restrict the rolling log to graphics-backend messages; omit client titles.
    timeout --kill-after=1s 3s hyprctl rollinglog 2>/dev/null |
        awk '/aquamarine|\[AQ\]/ && /drm:|DRM|connector|atomic|modeset|page.?flip|EDID/' || true
}

snapshot > "$destination/baseline.txt" 2>&1
display_log > "$destination/backend-baseline.log"
if [[ "$mode" == --snapshot ]]; then
    printf 'Baseline saved. This observes reported state, not visible pixels.\n'
    exit 0
fi

# Adapted from diagnosing-bugs/scripts/hitl-loop.template.sh.
step() {
    printf '\n>>> %s\n' "$1"
    read -r -p '    [Enter when done] ' _
}

capture() {
    local variable=$1 question=$2 answer
    printf '\n>>> %s\n' "$question"
    read -r -p '    > ' answer
    printf -v "$variable" '%s' "$answer"
}

step 'Save your work. Connect the dock, close the laptop lid, and confirm the external screen works. Leave this terminal open.'

# Count samples so time spent suspended cannot exhaust the recording budget.
# At the normal interval, 900 samples cover roughly 30 minutes while awake.
(
    for ((sample = 0; sample < 900; sample++)); do
        snapshot >> "$destination/timeline.txt" 2>&1
        display_log > "$destination/backend-latest.tmp"
        mv -- "$destination/backend-latest.tmp" "$destination/backend-latest.log"
        sleep 2
    done
) &
recorder=$!
cleanup() {
    kill "$recorder" 2>/dev/null || true
    wait "$recorder" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

step 'Press Super+L. Leave the system untouched for at least 11 minutes so the configured display sleep and suspend both occur. Wake it with the external keyboard/mouse, then try to unlock. If the external screen stays blank, leave the dock connected for 20 seconds before opening the lid. Return here once you can see this terminal. Saved capture files survive if you need to reboot.'
capture external_blank 'Did the external screen remain blank after wake and input? (yes/no)'
capture internal_recovered 'If you opened the lid, did the laptop panel show the lock screen or desktop? (yes/no/not-tested)'
capture actions 'What recovery actions did you take, in order? Do not include your password.'

cleanup
snapshot > "$destination/final.txt" 2>&1
display_log > "$destination/backend-final.log"
journalctl -b --since "$started" -t arch-lidswitch --no-pager \
    -o short-iso > "$destination/lidswitch.log" 2>&1 || true
journalctl -b -k --since "$started" --no-pager -o short-iso |
    awk '/drm|amdgpu|PM:|ucsi|typec|USB disconnect/' \
    > "$destination/kernel-display.log" || true
printf 'EXTERNAL_BLANK=%s\nINTERNAL_RECOVERED=%s\nACTIONS=%s\n' \
    "$external_blank" "$internal_recovered" "$actions" \
    > "$destination/observations.txt"
printf '\nCapture complete: %s\n' "$destination"
