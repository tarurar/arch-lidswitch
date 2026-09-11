#!/usr/bin/env bash
# Replays the undock policy decision, not the physical display failure.
set -euo pipefail
umask 077
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin" "$work/runtime"
cp "$root/runtime/monitor-state.sh" "$root/runtime/lid-state.sh" "$work/"
sed 's/LAPTOP_MONITOR_PLACEHOLDER/eDP-1/g' \
    "$root/runtime/lid-switch.sh.in" > "$work/lid-switch.sh"
cp "$root/diagnostics/display-wake/fallback-reconstructed.json" \
    "$work/monitors.json"
cat > "$work/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" == '-j monitors all' ]]; then
    cat "$REPLAY_MONITORS"
else
    printf 'Unexpected compositor command: %s\n' "$*" >&2
    exit 99
fi
FAKE
chmod +x "$work/bin/hyprctl"

run_decision() {
    PATH="$work/bin:$PATH" XDG_RUNTIME_DIR="$work/runtime" \
        REPLAY_MONITORS="$work/monitors.json" \
        ARCH_LIDSWITCH_EXPECTED_LID= ARCH_LIDSWITCH_EXPECTED_POLICY_TOKEN= \
        bash "$work/lid-switch.sh" --dry-run close
}

with_fallback=$(run_decision)
printf 'Observed undock topology:\n%s\n' "$with_fallback"
jq '[.[] | select(.name != "FALLBACK")]' "$work/monitors.json" \
    > "$work/without-fallback.json"
mv "$work/without-fallback.json" "$work/monitors.json"
without_fallback=$(run_decision)
printf '\nControl with the synthetic output removed:\n%s\n' "$without_fallback"

if [[ "$without_fallback" != *'decision=enable_internal'* ]]; then
    printf '\nControl failed: undocked policy did not enable the panel.\n' >&2
    exit 2
fi
if [[ "$with_fallback" != *'decision=enable_internal'* ]]; then
    printf '\nFAIL: the synthetic FALLBACK output keeps the panel disabled.\n' >&2
    exit 1
fi
printf '\nPASS: FALLBACK does not prevent internal restoration.\n'
