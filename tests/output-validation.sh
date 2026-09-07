#!/bin/bash

prepare_validation_fixture() {
    test_root=$(mktemp -d)
    trap 'rm -rf "$test_root"' EXIT
    local home="$test_root/home"
    local fake_bin="$test_root/fake-bin" safe_bin="$test_root/safe-bin"

    mkdir -p "$home" "$test_root/lid/LID0" "$test_root/drm/card7-eDP-1"
    printf 'state: open\n' > "$test_root/lid/LID0/state"
    printf 'disabled\n' > "$test_root/drm/card7-eDP-1/enabled"
    prepare_hyprland_config "$home"
    install_safe_path "$fake_bin" "$safe_bin"
    : > "$test_root/effects"
    validation_environment=(
        HOME="$home" PATH="$fake_bin:$safe_bin"
        TEST_EFFECT_LOG="$test_root/effects"
        TEST_MONITORS_FIXTURE="$ROOT_DIR/tests/fixtures/monitors/one-external.txt"
        TEST_HYPRCTL_MONITORS_STATE_FILE="$test_root/monitors.json"
        HYPR_LID_STATE_ROOT="$test_root/lid"
        HYPR_DRM_ROOT="$test_root/drm"
    )
    jq 'map(.dpmsStatus = true)' \
        "$ROOT_DIR/tests/fixtures/monitors-json/framework.json" \
        > "$test_root/monitors.json"
    validation_environment+=("TEST_HYPRCTL_MONITORS_JSON=$(<"$test_root/monitors.json")")
    "$ENV_BIN" -i "${validation_environment[@]}" \
        WAYLAND_DISPLAY=wayland-test HYPRLAND_INSTANCE_SIGNATURE=test-instance \
        XDG_SESSION_TYPE=wayland "$ROOT_DIR/install-hyprland-lid-switch.sh" \
        > "$test_root/install.out" 2>&1
    validation_cli="$home/.config/hypr/scripts/lid-switch.sh"
    validation_daemon="$home/.config/hypr/scripts/lid-monitor.sh"
    : > "$test_root/effects"
}

validation_persistent_disagreement() (
    set -euo pipefail
    local test_root validation_cli validation_daemon
    local -a validation_environment
    local status=0 output
    prepare_validation_fixture || return

    "$ENV_BIN" -i "${validation_environment[@]}" \
        "$TIMEOUT_BIN" 3.5 "$validation_daemon" \
        > "$test_root/daemon.out" 2>&1 || status=$?

    [[ "$status" == 124 ]] || return 1
    output=$(<"$test_root/daemon.out")
    assert_contains "$output" 'validation=degraded' \
        'two seconds of compositor/kernel disagreement must be observable' || return
    [[ $(grep -c 'event=output_validation_changed.*validation=degraded' \
        "$test_root/daemon.out") == 1 ]]
)

validation_cli_bounds_settling() (
    set -euo pipefail
    local test_root validation_cli validation_daemon output status=0
    local -a validation_environment
    prepare_validation_fixture || return

    # A topology change partway through the budget prevents a full interval.
    (
        "$REAL_SLEEP_BIN" 0.6
        jq 'map(if .name == "DP-2" then .x += 1 else . end)' \
            "$test_root/monitors.json" > "$test_root/changed.json"
        mv "$test_root/changed.json" "$test_root/monitors.json"
    ) &
    local changer=$!
    "$ENV_BIN" -i "${validation_environment[@]}" \
        "$TIMEOUT_BIN" 2.5 "$validation_cli" --preserve-dpms open \
        > "$test_root/cli.out" 2>&1 || status=$?
    wait "$changer" || return

    [[ "$status" == 0 ]] || return 1
    output=$(<"$test_root/cli.out")
    assert_contains "$output" 'verification_scope=compositor' \
        'CLI success must state the scope of verification' || return
    assert_contains "$output" 'validation=pending' \
        'the one-shot budget must not certify an incomplete settling period' || return
    assert_not_contains "$output" 'validation=degraded' \
        'different topologies cannot be combined to establish persistence' || return
    assert_not_contains "$(<"$test_root/effects")" $'hyprctl\teval' \
        'independent validation must not add display commands'
)

validation_unavailable_evidence() (
    set -euo pipefail
    local test_root validation_cli validation_daemon scenario reason output
    local -a validation_environment
    prepare_validation_fixture || return

    for scenario in missing unreadable malformed nul extra-lines ambiguous; do
        rm -rf "$test_root/drm"
        mkdir -p "$test_root/drm/card7-eDP-1"
        printf 'disabled\n' > "$test_root/drm/card7-eDP-1/enabled"
        case "$scenario" in
            missing)
                rm -rf "$test_root/drm/card7-eDP-1"
                reason=connector_missing
                ;;
            unreadable)
                chmod 000 "$test_root/drm/card7-eDP-1/enabled"
                reason=kernel_enabled_unreadable
                ;;
            malformed)
                printf 'unexpected\n' > "$test_root/drm/card7-eDP-1/enabled"
                reason=kernel_enabled_malformed
                ;;
            nul)
                printf 'enabled\0\n' > "$test_root/drm/card7-eDP-1/enabled"
                reason=kernel_enabled_malformed
                ;;
            extra-lines)
                printf 'enabled\n\n' > "$test_root/drm/card7-eDP-1/enabled"
                reason=kernel_enabled_malformed
                ;;
            ambiguous)
                mkdir "$test_root/drm/card12-eDP-1"
                printf 'enabled\n' > "$test_root/drm/card12-eDP-1/enabled"
                reason=connector_ambiguous
                ;;
        esac
        "$ENV_BIN" -i "${validation_environment[@]}" \
            "$validation_cli" --preserve-dpms open \
            > "$test_root/cli.out" 2>&1 || return
        output=$(<"$test_root/cli.out")
        assert_contains "$output" "validation=unavailable reason=$reason" \
            "$scenario evidence must explicitly qualify success" || return
        assert_contains "$output" 'verification_scope=compositor' \
            'unavailable validation must not claim independent verification' || return
    done
    assert_not_contains "$(<"$test_root/effects")" $'hyprctl\teval' \
        'unavailable evidence must not add display commands'
)

wait_for_validation_log() {
    local expected=$1 attempt
    for ((attempt = 0; attempt < 100; attempt++)); do
        if grep -q "$expected" "$test_root/daemon.out"; then
            return 0
        fi
        "$REAL_SLEEP_BIN" 0.05
    done
    printf 'Missing log: %s\n%s\n' "$expected" "$(<"$test_root/daemon.out")" >&2
    return 1
}

start_validation_daemon() {
    setsid "$ENV_BIN" -i "${validation_environment[@]}" \
        "$validation_daemon" > "$test_root/daemon.out" 2>&1 &
    validation_pid=$!
    trap 'kill -KILL -- "-$validation_pid" 2>/dev/null || true;
        wait "$validation_pid" 2>/dev/null || true; rm -rf "$test_root"' EXIT
    wait_for_validation_log 'event=monitor_started'
}

validation_reports_recovery() (
    set -euo pipefail
    local test_root validation_cli validation_daemon validation_pid output
    local -a validation_environment
    prepare_validation_fixture || return
    start_validation_daemon || return
    wait_for_validation_log 'validation=degraded' || return

    printf 'enabled\n' > "$test_root/drm/card7-eDP-1/enabled"
    wait_for_validation_log 'validation=agreement' || return

    output=$(<"$test_root/daemon.out")
    assert_before "$output" 'validation=degraded' 'validation=agreement' \
        'polling must report recovery without a compositor topology change' || return
    [[ $(grep -c 'event=reconciliation_started' "$test_root/daemon.out") == 1 ]]
)

validation_clears_transient_disagreement() (
    set -euo pipefail
    local test_root validation_cli validation_daemon validation_pid
    local -a validation_environment
    prepare_validation_fixture || return
    start_validation_daemon || return

    printf 'enabled\n' > "$test_root/drm/card7-eDP-1/enabled"
    wait_for_validation_log 'validation=agreement' || return
    "$REAL_SLEEP_BIN" 2.1

    assert_not_contains "$(<"$test_root/daemon.out")" 'validation=degraded' \
        'agreement before the deadline must cancel disagreement'
)

validation_dpms_sleep_resets_settling() (
    set -euo pipefail
    local test_root validation_cli validation_daemon validation_pid
    local -a validation_environment
    prepare_validation_fixture || return
    start_validation_daemon || return

    jq 'map(.dpmsStatus = false)' "$test_root/monitors.json" \
        > "$test_root/asleep.json"
    mv "$test_root/asleep.json" "$test_root/monitors.json"
    wait_for_validation_log 'validation=suspended reason=dpms_sleep' || return
    "$REAL_SLEEP_BIN" 2.1
    assert_not_contains "$(<"$test_root/daemon.out")" 'validation=degraded' \
        'DPMS sleep must suspend assessment for as long as the display sleeps' || return
    jq 'map(.dpmsStatus = true)' "$test_root/monitors.json" \
        > "$test_root/awake.json"
    mv "$test_root/awake.json" "$test_root/monitors.json"
    "$REAL_SLEEP_BIN" 1
    assert_not_contains "$(<"$test_root/daemon.out")" 'validation=degraded' \
        'wake must start a fresh two-second period' || return
    wait_for_validation_log 'validation=degraded' || return
    [[ $(grep -c 'event=reconciliation_started' "$test_root/daemon.out") == 1 ]] || return 1
    assert_not_contains "$(<"$test_root/effects")" $'hyprctl\teval' \
        'DPMS-only observations must never wake or reconfigure the display'
)

validation_unavailable_resets_settling() (
    set -euo pipefail
    local test_root validation_cli validation_daemon validation_pid
    local -a validation_environment
    prepare_validation_fixture || return
    start_validation_daemon || return

    printf 'invalid\n' > "$test_root/drm/card7-eDP-1/enabled"
    wait_for_validation_log 'validation=unavailable reason=kernel_enabled_malformed' || return
    "$REAL_SLEEP_BIN" 2.1
    printf 'disabled\n' > "$test_root/drm/card7-eDP-1/enabled"
    "$REAL_SLEEP_BIN" 1

    assert_not_contains "$(<"$test_root/daemon.out")" 'validation=degraded' \
        'unavailable observations must break consecutive disagreement' || return
    wait_for_validation_log 'validation=degraded'
)

validation_resume_keeps_operation_status() (
    set -euo pipefail
    local test_root validation_cli validation_daemon output mode mutations baseline
    local -a validation_environment
    prepare_validation_fixture || return

    for mode in enabled disabled; do
        printf '%s\n' "$mode" > "$test_root/drm/card7-eDP-1/enabled"
        : > "$test_root/effects"
        "$ENV_BIN" -i "${validation_environment[@]}" \
            "$validation_daemon" --resume-once \
            > "$test_root/resume-$mode.out" 2>&1 || return
        output=$(<"$test_root/resume-$mode.out")
        assert_contains "$output" 'event=reconciliation_succeeded trigger=resume attempt=1' \
            'independent validation must preserve resume success without retries' || return
        assert_contains "$output" 'verification_scope=compositor validation=' \
            'resume success must include the independent outcome' || return
        mutations=$(grep $'hyprctl\teval' "$test_root/effects" || true)
        if [[ "$mode" == enabled ]]; then
            assert_contains "$output" 'validation=agreement' \
                'enabled kernel state corroborates compositor restoration' || return
            baseline=$mutations
        else
            assert_not_contains "$output" 'validation=agreement' \
                'disabled kernel state must not independently verify resume' || return
            [[ "$mutations" == "$baseline" ]] || return 1
        fi
    done
)

validation_budget_includes_slow_queries() (
    set -euo pipefail
    local test_root validation_cli validation_daemon status=0 changer
    local -a validation_environment
    prepare_validation_fixture || return
    mkdir -m 0700 "$test_root/runtime"
    validation_environment+=(XDG_RUNTIME_DIR="$test_root/runtime")

    (
        "$REAL_SLEEP_BIN" 0.6
        : > "$test_root/delay-query"
    ) &
    changer=$!
    "$ENV_BIN" -i "${validation_environment[@]}" \
        TEST_HYPRCTL_QUERY_DELAY_MARKER="$test_root/delay-query" \
        TEST_HYPRCTL_QUERY_PID_FILE="$test_root/query-pid" \
        TEST_REAL_SLEEP_BIN="$REAL_SLEEP_BIN" \
        "$TIMEOUT_BIN" 2.5 "$validation_cli" --preserve-dpms open \
        > "$test_root/cli.out" 2>&1 || status=$?
    wait "$changer" || return

    [[ "$status" == 0 ]] || return 1
    assert_contains "$(<"$test_root/cli.out")" 'validation=pending' \
        'a slow query must not extend the budget or certify persistence' || return
    local query_pid query_state ignored
    query_pid=$(<"$test_root/query-pid")
    "$REAL_SLEEP_BIN" 0.1
    if [[ -r "/proc/$query_pid/stat" ]]; then
        read -r ignored ignored query_state ignored < "/proc/$query_pid/stat"
        if [[ "$query_state" != Z ]]; then
            printf 'Validation query %s survived the observation budget\n' "$query_pid" >&2
            return 1
        fi
    fi
    rm "$test_root/delay-query"
    printf 'enabled\n' > "$test_root/drm/card7-eDP-1/enabled"
    "$ENV_BIN" -i "${validation_environment[@]}" \
        "$validation_cli" --preserve-dpms open \
        > "$test_root/next-cli.out" 2>&1 || {
        printf 'Validation retained the reconciliation lock:\n%s\n' \
            "$(<"$test_root/next-cli.out")" >&2
        return 1
    }
)

validation_generation_resets_settling() (
    set -euo pipefail
    local test_root validation_cli validation_daemon validation_pid
    local -a validation_environment
    local change=${VALIDATION_GENERATION_CHANGE:-topology}
    prepare_validation_fixture || return
    if [[ "$change" == lid ]]; then
        # With no external display, both lid states keep the internal enabled.
        jq 'map(select(.name == "eDP-1"))' "$test_root/monitors.json" \
            > "$test_root/laptop-only.json"
        mv "$test_root/laptop-only.json" "$test_root/monitors.json"
        validation_environment+=("TEST_HYPRCTL_MONITORS_JSON=$(<"$test_root/monitors.json")")
    fi
    start_validation_daemon || return
    "$REAL_SLEEP_BIN" 1.1

    if [[ "$change" == lid ]]; then
        printf 'state: closed\n' > "$test_root/lid/LID0/state"
        wait_for_validation_log 'event=lid_state_changed' || return
    else
        jq 'map(if .name == "DP-2" then .x += 1 else . end)' \
            "$test_root/monitors.json" > "$test_root/changed.json"
        mv "$test_root/changed.json" "$test_root/monitors.json"
    fi
    "$REAL_SLEEP_BIN" 1.1

    assert_not_contains "$(<"$test_root/daemon.out")" 'validation=degraded' \
        "$change change must prevent combining observations across generations" || return
    wait_for_validation_log 'validation=degraded'
)

validation_lid_resets_settling() {
    VALIDATION_GENERATION_CHANGE=lid validation_generation_resets_settling
}

validation_reports_worker_failure() (
    set -euo pipefail
    local test_root validation_cli validation_daemon
    local -a validation_environment
    prepare_validation_fixture || return
    cat > "$test_root/fake-bin/timeout" <<'FAKE'
#!/bin/bash
if [[ "$1" == --signal=KILL ]]; then
    exit 125
fi
exec "$TEST_REAL_TIMEOUT_BIN" "$@"
FAKE
    chmod +x "$test_root/fake-bin/timeout"

    "$ENV_BIN" -i "${validation_environment[@]}" \
        TEST_REAL_TIMEOUT_BIN="$TIMEOUT_BIN" \
        "$validation_cli" --preserve-dpms open \
        > "$test_root/cli.out" 2>&1 || return

    assert_contains "$(<"$test_root/cli.out")" \
        'validation=unavailable reason=validation_worker_failed' \
        'worker infrastructure failure must be reported without failing reconciliation'
)

validation_maps_unique_connector() (
    set -euo pipefail
    local test_root validation_cli validation_daemon
    local -a validation_environment
    prepare_validation_fixture || return
    printf 'enabled\n' > "$test_root/drm/card7-eDP-1/enabled"

    "$ENV_BIN" -i "${validation_environment[@]}" \
        "$validation_cli" --preserve-dpms open \
        > "$test_root/cli.out" 2>&1 || return

    assert_contains "$(<"$test_root/cli.out")" \
        'validation=agreement reason=kernel_enabled internal_output=eDP-1 connector=card7-eDP-1' \
        'unique mapping must corroborate enablement without assuming a DRM card number'
)

validation_does_not_reconcile_kernel_changes() (
    set -euo pipefail
    local test_root validation_cli validation_daemon validation_pid baseline
    local -a validation_environment
    prepare_validation_fixture || return
    printf 'enabled\n' > "$test_root/drm/card7-eDP-1/enabled"
    start_validation_daemon || return
    baseline=$(grep $'hyprctl\teval' "$test_root/effects" || true)

    printf 'disabled\n' > "$test_root/drm/card7-eDP-1/enabled"
    wait_for_validation_log 'validation=degraded' || return

    [[ $(grep -c 'event=reconciliation_started' "$test_root/daemon.out") == 1 ]] || return 1
    [[ $(grep $'hyprctl\teval' "$test_root/effects" || true) == "$baseline" ]]
)

validation_once_bounds_total_budget() (
    set -euo pipefail
    local test_root validation_cli validation_daemon changer status=0
    local -a validation_environment
    local mode=${1:---once}
    prepare_validation_fixture || return
    jq 'map(select(.name == "eDP-1"))' "$test_root/monitors.json" \
        > "$test_root/laptop.json"
    mv "$test_root/laptop.json" "$test_root/monitors.json"
    validation_environment+=("TEST_HYPRCTL_MONITORS_JSON=$(<"$test_root/monitors.json")")
    (
        "$REAL_SLEEP_BIN" 1
        printf 'state: closed\n' > "$test_root/lid/LID0/state"
    ) &
    changer=$!
    "$ENV_BIN" -i "${validation_environment[@]}" \
        "$TIMEOUT_BIN" 3.5 "$validation_daemon" "$mode" \
        > "$test_root/once.out" 2>&1 || status=$?
    wait "$changer" || return
    if [[ "$status" != 0 ]]; then
        printf 'One-shot exceeded its total validation budget: status=%s\n%s\n' \
            "$status" "$(<"$test_root/once.out")" >&2
        return 1
    fi
    assert_contains "$(<"$test_root/once.out")" 'validation=pending' \
        'a lid change during settling must retain a single bounded budget' || return
    local trigger=${mode#--}
    trigger=${trigger%-once}
    assert_contains "$(<"$test_root/once.out")" \
        "event=reconciliation_succeeded trigger=$trigger attempt=2 state=closed" \
        'post-settle checks must reconcile the new lid state within that budget'
)

validation_resume_bounds_total_budget() {
    validation_once_bounds_total_budget --resume-once
}
