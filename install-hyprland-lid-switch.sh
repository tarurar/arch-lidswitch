#!/bin/bash

################################################################################
# Hyprland Lid Switch Installer
# 
# This script installs an automatic lid switch handler for Hyprland that:
# - Disables laptop display when lid is closed with an enabled external output
# - Re-enables laptop display when lid is opened
# - Works safely without crashing Wayland sessions
#
# Compatible with: Arch Linux, Hyprland, laptops with external monitors
# Author: https://github.com/aserper/hyprland-lid-switch
################################################################################

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
HYPRLAND_CONFIG_FILE="${HYPR_LID_HYPRLAND_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua}"
HYPR_CONFIG_DIR="$(dirname "$HYPRLAND_CONFIG_FILE")"
SCRIPTS_DIR="$HYPR_CONFIG_DIR/scripts"
SESSION_MODULE_DIR="$HYPR_CONFIG_DIR/arch_lidswitch"
SESSION_MODULE="$SESSION_MODULE_DIR/session.lua"
SESSION_BRIDGE="$SCRIPTS_DIR/lid-session-bridge.sh"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SESSION_TARGET_FILE="$SYSTEMD_USER_DIR/hyprland-session.target"
SERVICE_FILE="$SYSTEMD_USER_DIR/lid-monitor.service"
RESUME_SERVICE_FILE="$SYSTEMD_USER_DIR/lid-resume-monitor.service"
DOCTOR_FILE="$SCRIPTS_DIR/lid-switch-doctor.sh"
MONITOR_STATE_FILE="$SCRIPTS_DIR/monitor-state.sh"
RESUME_MONITOR_FILE="$SCRIPTS_DIR/lid-resume-monitor.sh"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/arch-lidswitch"
TRANSACTIONS_DIR="$STATE_ROOT/transactions"
BACKUPS_DIR="$STATE_ROOT/backups"
CURRENT_MANIFEST="$STATE_ROOT/current.manifest"

SESSION_CONFIG_BEGIN='-- BEGIN arch-lidswitch managed session integration'
SESSION_CONFIG_END='-- END arch-lidswitch managed session integration'

# Global variables
laptop_monitor=""
HYPRCTL_BIN=""
JQ_BIN=""
TIMEOUT_BIN=""
SYSTEMD_ANALYZE_BIN=""
HYPRLAND_MONITORS_JSON=""
session_config_state=""
legacy_default_target_service=false
transaction_active=false
transaction_committed=false
backup_promoted_uncommitted=false
transaction_lock_fd=""
transaction_id=""
transaction_dir=""
transaction_stage_dir=""
transaction_before_dir=""
transaction_manifest=""
config_candidate=""
config_snapshot_mode=""
config_publish_intent=false
config_exchange_sibling=""
config_candidate_identity=""
config_displaced_validated=false
manifest_publish_intent=false
manifest_exchange_sibling=""
manifest_candidate_identity=""
manifest_displaced_validated=false
manifest_was_present=false
manifest_was_mode=""
manifest_was_hash=""
service_state_changed=false
service_restart_intent=false
main_enablement_state=""
resume_enablement_state=""
main_was_active=false
resume_was_active=false
main_prior_pid=""
main_prior_invocation=""
resume_prior_pid=""
resume_prior_invocation=""
verified_main_pid=""
verified_main_invocation=""
verified_resume_pid=""
verified_resume_invocation=""
service_runtime_pid=""
service_runtime_invocation=""
service_sample_fingerprint=""
service_sample_main_pid=""
service_sample_main_invocation=""
service_sample_resume_pid=""
service_sample_resume_invocation=""
service_signal_injected=false
deferred_transaction_signal=""
trap_restore_signal_injected=false
scripts_dir_existed=false
session_module_dir_existed=false
systemd_user_dir_existed=false

ARTIFACT_IDS=(
    lid-state
    monitor-state
    lid-switch
    lid-switch-doctor
    lid-monitor
    lid-resume-monitor
    lid-session-bridge
    session-module
    session-target
    main-service
    resume-service
)
declare -A ARTIFACT_RELATIVE_PATH=(
    [lid-state]=scripts/lid-state.sh
    [monitor-state]=scripts/monitor-state.sh
    [lid-switch]=scripts/lid-switch.sh
    [lid-switch-doctor]=scripts/lid-switch-doctor.sh
    [lid-monitor]=scripts/lid-monitor.sh
    [lid-resume-monitor]=scripts/lid-resume-monitor.sh
    [lid-session-bridge]=scripts/lid-session-bridge.sh
    [session-module]=arch_lidswitch/session.lua
    [session-target]=systemd/user/hyprland-session.target
    [main-service]=systemd/user/lid-monitor.service
    [resume-service]=systemd/user/lid-resume-monitor.service
)
declare -A ARTIFACT_DESTINATION=(
    [lid-state]="$SCRIPTS_DIR/lid-state.sh"
    [monitor-state]="$MONITOR_STATE_FILE"
    [lid-switch]="$SCRIPTS_DIR/lid-switch.sh"
    [lid-switch-doctor]="$DOCTOR_FILE"
    [lid-monitor]="$SCRIPTS_DIR/lid-monitor.sh"
    [lid-resume-monitor]="$RESUME_MONITOR_FILE"
    [lid-session-bridge]="$SESSION_BRIDGE"
    [session-module]="$SESSION_MODULE"
    [session-target]="$SESSION_TARGET_FILE"
    [main-service]="$SERVICE_FILE"
    [resume-service]="$RESUME_SERVICE_FILE"
)
declare -A ARTIFACT_MODE=(
    [lid-state]=0755
    [monitor-state]=0755
    [lid-switch]=0755
    [lid-switch-doctor]=0755
    [lid-monitor]=0755
    [lid-resume-monitor]=0755
    [lid-session-bridge]=0755
    [session-module]=0644
    [session-target]=0644
    [main-service]=0644
    [resume-service]=0644
)
declare -A ARTIFACT_WAS_PRESENT=()
declare -A ARTIFACT_WAS_MODE=()
declare -A ARTIFACT_WAS_HASH=()
declare -A ARTIFACT_PUBLISH_INTENT=()
declare -A ARTIFACT_EXCHANGE_SIBLING=()
declare -A ARTIFACT_CANDIDATE_IDENTITY=()
declare -A ARTIFACT_DISPLACED_VALIDATED=()
TEMPORARY_DESTINATIONS=()

FAULT_CHECKPOINTS=(
    prepared
    services-quiesced
    legacy-stopped
    installed-lid-state
    installed-monitor-state
    installed-lid-switch
    installed-lid-switch-doctor
    installed-lid-monitor
    installed-lid-resume-monitor
    installed-lid-session-bridge
    installed-session-module
    installed-session-target
    installed-main-service
    installed-resume-service
    manifest-installed
    config-integrated
    daemon-reloaded
    main-enabled
    session-imported
    main-started
    resume-started
    health-checked
)

################################################################################
# Utility Functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if we're running Hyprland
check_hyprland() {
    if [[ "${XDG_SESSION_TYPE:-}" != "wayland" ]] || ! command_exists hyprctl; then
        log_error "This script requires Hyprland to be running"
        exit 1
    fi

    HYPRCTL_BIN=$(command -v hyprctl)

    if [[ -z "${WAYLAND_DISPLAY:-}" ]] || [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        log_error "This script requires WAYLAND_DISPLAY and HYPRLAND_INSTANCE_SIGNATURE from the active Hyprland session"
        exit 1
    fi
}

check_hyprland_capabilities() {
    local version_json version_string version_major version_minor
    local instances_json instance_count instance_signature instance_socket
    local status_json config_provider
    local lua_probe_output

    if ! command_exists jq; then
        log_error "This installer requires jq to validate Hyprland capabilities"
        return 1
    fi

    JQ_BIN=$(command -v jq)

    if ! version_json=$("$HYPRCTL_BIN" -j version); then
        log_error "Could not query the active Hyprland version with 'hyprctl -j version'"
        return 1
    fi
    if ! version_string=$("$JQ_BIN" -er \
        'if type == "object" and (.version | type == "string") then .version else empty end' \
        <<< "$version_json"); then
        log_error "Hyprland returned malformed version JSON or a missing version string"
        return 1
    fi
    if [[ ! "$version_string" =~ ^([0-9]{1,9})\.([0-9]{1,9})\.[0-9]{1,9}$ ]]; then
        log_error "Hyprland returned a malformed version string: $version_string"
        return 1
    fi

    version_major=$((10#${BASH_REMATCH[1]}))
    version_minor=$((10#${BASH_REMATCH[2]}))
    if (( version_major == 0 && version_minor < 55 )); then
        log_error "Hyprland $version_string is unsupported; version 0.55.0 or newer is required"
        return 1
    fi

    if ! instances_json=$("$HYPRCTL_BIN" -j instances); then
        log_error "Could not query running Hyprland instances with 'hyprctl -j instances'"
        return 1
    fi
    if ! instance_count=$("$JQ_BIN" -er \
        'if type == "array" then length else empty end' <<< "$instances_json"); then
        log_error "Hyprland returned a malformed instances array"
        return 1
    fi
    if (( instance_count != 1 )); then
        log_error "Expected exactly one running Hyprland instance, found $instance_count; instance selection is not supported"
        return 1
    fi
    if ! instance_signature=$("$JQ_BIN" -er \
        'if type == "array" and length == 1 and (.[0] | type) == "object" and (.[0].instance | type) == "string" then .[0].instance else empty end' \
        <<< "$instances_json"); then
        log_error "Hyprland returned a malformed selected instance record"
        return 1
    fi
    if [[ "$instance_signature" != "$HYPRLAND_INSTANCE_SIGNATURE" ]]; then
        log_error "Running Hyprland instance=$instance_signature does not match HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE"
        return 1
    fi
    if "$JQ_BIN" -e '.[0] | has("wl_socket")' <<< "$instances_json" >/dev/null; then
        if ! instance_socket=$("$JQ_BIN" -er \
            'if (.[0].wl_socket | type) == "string" then .[0].wl_socket else empty end' \
            <<< "$instances_json"); then
            log_error "Hyprland returned a malformed wl_socket in the selected instance record"
            return 1
        fi
        if [[ "$instance_socket" != "$WAYLAND_DISPLAY" ]]; then
            log_error "Running Hyprland wl_socket=$instance_socket does not match WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
            return 1
        fi
    fi

    if ! status_json=$("$HYPRCTL_BIN" -j status); then
        log_error "Could not query the active Hyprland configuration provider with 'hyprctl -j status'"
        return 1
    fi
    if ! config_provider=$("$JQ_BIN" -er \
        'if type == "object" and (.configProvider | type == "string") then .configProvider else empty end' \
        <<< "$status_json"); then
        log_error "Hyprland returned malformed status JSON or a missing configProvider"
        return 1
    fi
    if [[ "$config_provider" != "lua" ]]; then
        log_error "Hyprland configProvider=$config_provider is unsupported; expected lua"
        return 1
    fi

    if ! HYPRLAND_MONITORS_JSON=$("$HYPRCTL_BIN" -j monitors all); then
        log_error "Could not query monitor capabilities with 'hyprctl -j monitors all'"
        return 1
    fi
    if ! "$JQ_BIN" -e 'type == "array"' <<< "$HYPRLAND_MONITORS_JSON" >/dev/null; then
        log_error "Hyprland 'hyprctl -j monitors all' did not return a valid monitor array"
        return 1
    fi

    if ! lua_probe_output=$("$HYPRCTL_BIN" eval \
        'assert(type(hl) == "table" and type(hl.monitor) == "function" and type(hl.dispatch) == "function" and type(hl.dsp) == "table" and type(hl.dsp.dpms) == "function", "required Hyprland Lua APIs unavailable")'); then
        log_error "Hyprland Lua capability probe failed: required hl.monitor, hl.dispatch, and hl.dsp.dpms APIs are unavailable"
        return 1
    fi
    if [[ "$lua_probe_output" != "ok" ]]; then
        log_error "Hyprland Lua capability probe failed: required hl.monitor, hl.dispatch, and hl.dsp.dpms APIs are unavailable"
        return 1
    fi

    log_success "Hyprland $version_string capability profile is compatible (configProvider=lua instances=1)"
}

check_resume_runtime_dependencies() {
    local version_output version_line version_major
    local busctl_bin stdbuf_bin

    if ! command_exists stdbuf; then
        log_error "This installer requires stdbuf from GNU coreutils for the resume event stream"
        return 1
    fi
    if ! command_exists timeout; then
        log_error "This installer requires timeout from GNU coreutils for bounded Hyprland commands"
        return 1
    fi
    if ! command_exists busctl; then
        log_error "This installer requires busctl from systemd 257 or newer"
        return 1
    fi
    stdbuf_bin=$(command -v stdbuf)
    busctl_bin=$(command -v busctl)
    TIMEOUT_BIN=$(command -v timeout)

    if ! version_output=$("$stdbuf_bin" -oL "$busctl_bin" --version); then
        log_error "Could not query systemd/busctl version"
        return 1
    fi
    version_line=${version_output%%$'\n'*}
    if [[ ! "$version_line" =~ ^systemd[[:space:]]+([0-9]{1,9})([[:space:]]|$) ]]; then
        log_error "Could not parse systemd/busctl version: $version_line"
        return 1
    fi
    version_major=$((10#${BASH_REMATCH[1]}))
    if (( version_major < 257 )); then
        log_error "systemd/busctl 257 or newer is required; found $version_major"
        return 1
    fi
    log_success "systemd/busctl $version_major supports the resume event stream"
}

check_transaction_dependencies() {
    local dependency

    if [[ -n "${XDG_STATE_HOME:-}" && "$XDG_STATE_HOME" != /* ]]; then
        log_error "XDG_STATE_HOME must be an absolute path"
        return 1
    fi
    for dependency in cmp flock sha256sum stat luac systemd-analyze; do
        if ! command_exists "$dependency"; then
            log_error "This installer requires $dependency for transactional installation"
            return 1
        fi
    done
    SYSTEMD_ANALYZE_BIN=$(command -v systemd-analyze)
}

run_lid_switch_doctor() {
    /bin/bash -s -- --policy-only <<'EOF'
#!/bin/bash

set -u

LOGIN1_SERVICE="org.freedesktop.login1"
LOGIN1_PATH="/org/freedesktop/login1"
LOGIN1_MANAGER="org.freedesktop.login1.Manager"

usage() {
    printf 'usage: %s [--policy-only]\n' "${0##*/}" >&2
}

print_remediation() {
    printf '%s\n' \
        'INFO Inspect effective policy with: systemd-analyze cat-config systemd/logind.conf' \
        'INFO Inspect lid inhibitors with: systemd-inhibit --list --what=handle-lid-switch --no-pager' \
        'INFO This installer does not modify /etc or systemd-logind policy.'
}

read_manager_string_property() {
    local property=$1
    local raw_value

    if ! raw_value=$(busctl get-property \
        "$LOGIN1_SERVICE" \
        "$LOGIN1_PATH" \
        "$LOGIN1_MANAGER" \
        "$property"); then
        printf 'ERROR Could not read effective logind property %s.\n' \
            "$property" >&2
        return 2
    fi

    if [[ "$raw_value" =~ ^s[[:space:]]+\"([^\"]*)\"$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    printf 'ERROR Unexpected value for logind property %s: %s\n' \
        "$property" "$raw_value" >&2
    return 2
}

call_manager_string_method() {
    local method=$1
    local diagnostic_level=${2:-ERROR}
    local raw_value

    if ! raw_value=$(busctl call \
        "$LOGIN1_SERVICE" \
        "$LOGIN1_PATH" \
        "$LOGIN1_MANAGER" \
        "$method"); then
        printf '%s Could not query login1 capability %s.\n' \
            "$diagnostic_level" "$method" >&2
        return 2
    fi

    if [[ "$raw_value" =~ ^s[[:space:]]+\"([^\"]*)\"$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    printf '%s Unexpected value for login1 capability %s: %s\n' \
        "$diagnostic_level" "$method" "$raw_value" >&2
    return 2
}

check_lid_power_policy() {
    local handle_lid_switch handle_lid_switch_docked
    local handle_lid_switch_external_power can_suspend can_hibernate
    local inhibitor_output
    local policy_status=0

    if ! handle_lid_switch=$(read_manager_string_property HandleLidSwitch); then
        print_remediation
        return 2
    fi
    if ! handle_lid_switch_docked=$(read_manager_string_property HandleLidSwitchDocked); then
        print_remediation
        return 2
    fi
    if ! handle_lid_switch_external_power=$(read_manager_string_property HandleLidSwitchExternalPower); then
        print_remediation
        return 2
    fi
    if ! can_suspend=$(call_manager_string_method CanSuspend); then
        print_remediation
        return 2
    fi
    if [[ "$can_suspend" == "yes" ]]; then
        printf 'PASS CanSuspend=yes\n'
    else
        printf 'FAIL CanSuspend=%s expected=yes\n' "$can_suspend"
        policy_status=1
    fi
    if can_hibernate=$(call_manager_string_method CanHibernate WARN); then
        case "$can_hibernate" in
            yes)
                printf 'INFO CanHibernate=yes hibernate=available-but-unused\n'
                ;;
            *)
                printf 'INFO CanHibernate=%s hibernate=unused\n' "$can_hibernate"
                ;;
        esac
    else
        printf 'WARN CanHibernate=<unavailable> hibernate=unused\n'
    fi
    if ! inhibitor_output=$(systemd-inhibit \
        --list \
        --what=handle-lid-switch \
        --no-pager \
        --no-legend); then
        printf 'ERROR Could not inspect handle-lid-switch inhibitors.\n' >&2
        print_remediation
        return 2
    fi

    if [[ "$handle_lid_switch" != "suspend" ]]; then
        printf 'FAIL HandleLidSwitch=%s expected=suspend\n' "$handle_lid_switch"
        policy_status=1
    else
        printf 'PASS HandleLidSwitch=suspend\n'
    fi

    if [[ "$handle_lid_switch_docked" != "ignore" ]]; then
        printf 'FAIL HandleLidSwitchDocked=%s expected=ignore\n' \
            "$handle_lid_switch_docked"
        policy_status=1
    else
        printf 'PASS HandleLidSwitchDocked=ignore\n'
    fi

    case "$handle_lid_switch_external_power" in
        "")
            printf 'PASS HandleLidSwitchExternalPower=<unset> fallback=HandleLidSwitch\n'
            ;;
        suspend)
            printf 'PASS HandleLidSwitchExternalPower=suspend\n'
            ;;
        *)
            printf 'FAIL HandleLidSwitchExternalPower=%s expected=<unset-or-suspend>\n' \
                "$handle_lid_switch_external_power"
            policy_status=1
            ;;
    esac

    if [[ -n "$inhibitor_output" && "$inhibitor_output" != "No inhibitors listed." ]]; then
        printf 'FAIL handle-lid-switch inhibitor present: %s\n' "$inhibitor_output"
        policy_status=1
    else
        printf 'PASS handle-lid-switch inhibitors=none\n'
    fi

    if (( policy_status != 0 )); then
        print_remediation
    fi

    return "$policy_status"
}

case "${1:-}" in
    ""|--policy-only)
        if (( $# > 1 )); then
            usage
            exit 2
        fi
        check_lid_power_policy
        ;;
    *)
        usage
        exit 2
        ;;
esac
EOF
}

check_lid_power_policy() {
    local doctor_status=0

    log_info "Checking effective systemd-logind lid policy..."
    run_lid_switch_doctor || doctor_status=$?
    if (( doctor_status != 0 )); then
        log_error "systemd-logind lid policy check failed"
        return "$doctor_status"
    fi

    log_success "systemd-logind is the configured lid-power owner"
}

write_session_config_block() {
    cat <<'EOF'
-- BEGIN arch-lidswitch managed session integration
do
    local ok, err = pcall(require, "arch_lidswitch.session")
    if not ok then
        print("arch-lidswitch: failed to load session integration: " .. tostring(err))
    end
end
-- END arch-lidswitch managed session integration
EOF
}

inspect_session_config() {
    local begin_count end_count existing_block expected_block

    if [[ -L "$HYPRLAND_CONFIG_FILE" ]]; then
        log_error "Refusing to replace symlinked Hyprland config: $HYPRLAND_CONFIG_FILE"
        exit 1
    fi

    if [[ ! -f "$HYPRLAND_CONFIG_FILE" ]]; then
        log_error "Could not find Hyprland Lua config: $HYPRLAND_CONFIG_FILE"
        exit 1
    fi

    begin_count=$(grep -Fxc -- "$SESSION_CONFIG_BEGIN" "$HYPRLAND_CONFIG_FILE" || true)
    end_count=$(grep -Fxc -- "$SESSION_CONFIG_END" "$HYPRLAND_CONFIG_FILE" || true)

    if (( begin_count == 0 && end_count == 0 )); then
        if grep -Fq -- 'arch_lidswitch.session' "$HYPRLAND_CONFIG_FILE"; then
            log_error "Hyprland config already references arch_lidswitch.session outside the managed block"
            exit 1
        fi
        session_config_state="missing"
        return 0
    fi

    if (( begin_count != 1 || end_count != 1 )); then
        log_error "Hyprland config contains malformed arch-lidswitch ownership markers"
        exit 1
    fi

    existing_block=$(awk \
        -v begin="$SESSION_CONFIG_BEGIN" \
        -v end="$SESSION_CONFIG_END" \
        '$0 == begin { capture = 1 } capture { print } $0 == end { capture = 0 }' \
        "$HYPRLAND_CONFIG_FILE")
    expected_block=$(write_session_config_block)

    if [[ "$existing_block" != "$expected_block" ]]; then
        log_error "Hyprland config contains an edited arch-lidswitch managed block"
        exit 1
    fi

    session_config_state="present"
}

# Detect laptop and external monitors
detect_monitors() {
    local configured_internal=${HYPR_LID_INTERNAL_OUTPUT:-}
    local internal_count internal_status external_records

    if ! "$JQ_BIN" -e '
        type == "array" and
        all(.[]; type == "object" and
            (.name | type == "string" and test("^[A-Za-z0-9_.:-]+$")) and
            (.disabled | type == "boolean")) and
        ((map(.name) | length) == (map(.name) | unique | length))
    ' <<< "$HYPRLAND_MONITORS_JSON" >/dev/null; then
        log_error "Hyprland returned malformed monitor identity or activation records"
        exit 1
    fi

    if [[ -n "$configured_internal" ]]; then
        if [[ ! "$configured_internal" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
            log_error "HYPR_LID_INTERNAL_OUTPUT contains an invalid output name"
            exit 1
        fi
        internal_count=$("$JQ_BIN" -r --arg output "$configured_internal" \
            '[.[] | select(.name == $output)] | length' \
            <<< "$HYPRLAND_MONITORS_JSON")
        if (( internal_count == 0 )); then
            log_error "Configured internal output not found: $configured_internal"
            exit 1
        elif (( internal_count > 1 )); then
            log_error "Configured internal output is ambiguous: $configured_internal"
            exit 1
        fi
        laptop_monitor=$configured_internal
    else
        internal_count=$("$JQ_BIN" -r \
            '[.[] | select(.name | startswith("eDP"))] | length' \
            <<< "$HYPRLAND_MONITORS_JSON")
        if (( internal_count == 0 )); then
            log_error "Could not detect an internal output; set HYPR_LID_INTERNAL_OUTPUT"
            exit 1
        elif (( internal_count > 1 )); then
            log_error "Multiple internal output candidates detected; set HYPR_LID_INTERNAL_OUTPUT"
            exit 1
        fi
        laptop_monitor=$("$JQ_BIN" -r \
            '.[] | select(.name | startswith("eDP")) | .name' \
            <<< "$HYPRLAND_MONITORS_JSON")
    fi

    internal_status=$("$JQ_BIN" -r --arg output "$laptop_monitor" \
        '.[] | select(.name == $output) |
            if .disabled then "inactive" else "enabled" end' \
        <<< "$HYPRLAND_MONITORS_JSON")
    log_info "Detected internal output: $laptop_monitor ($internal_status)"

    external_records=$("$JQ_BIN" -r --arg internal "$laptop_monitor" '
        [.[] | select(.name != $internal)]
        | sort_by(.name)
        | .[]
        | [.name, (if .disabled then "inactive" else "enabled" end)]
        | @tsv
    ' <<< "$HYPRLAND_MONITORS_JSON")
    if [[ -z "$external_records" ]]; then
        log_info "No external outputs detected"
    else
        while IFS=$'\t' read -r output status; do
            log_info "Detected external output: $output ($status)"
        done <<< "$external_records"
    fi
}

# Render the helper that orders environment import before session activation.
render_session_bridge() {
    local destination=$1

    cat > "$destination" << 'EOF'
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
EOF
}

render_session_module() {
    local destination=$1

    cat > "$destination" << 'EOF'
local source = debug.getinfo(1, "S").source
local module_path = source:match("^@(.+)$")
local config_dir = module_path and module_path:match("^(.*)/arch_lidswitch/session%.lua$")

if not config_dir then
    error("arch-lidswitch: unable to locate the Hyprland configuration directory")
end

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local bridge = shell_quote(config_dir .. "/scripts/lid-session-bridge.sh")

hl.on("hyprland.start", function()
    hl.exec_cmd(bridge .. " start")
end)

hl.on("hyprland.shutdown", function()
    os.execute(bridge .. " stop")
end)

return true
EOF
}

render_session_target() {
    local destination=$1

    cat > "$destination" << 'EOF'
[Unit]
Description=Hyprland session
BindsTo=graphical-session.target
Wants=graphical-session-pre.target
After=graphical-session-pre.target
PropagatesStopTo=graphical-session.target
EOF
}

render_lid_state_script() {
    local destination=$1

    cat > "$destination" << 'EOF'
#!/bin/bash

read_lid_state() {
    local lid_root="${HYPR_LID_STATE_ROOT:-/proc/acpi/button/lid}"
    local nullglob_was_enabled=0
    local state_file state_line state observed_state=""
    local -a state_files

    if shopt -q nullglob; then
        nullglob_was_enabled=1
    else
        shopt -s nullglob
    fi
    state_files=("$lid_root"/*/state)
    if (( ! nullglob_was_enabled )); then
        shopt -u nullglob
    fi

    if (( ${#state_files[@]} == 0 )); then
        printf 'No ACPI lid state files found under %s\n' "$lid_root" >&2
        printf '%s\n' unknown
        return 2
    fi

    for state_file in "${state_files[@]}"; do
        if [[ ! -f "$state_file" || ! -r "$state_file" ]] || ! state_line=$(<"$state_file"); then
            printf 'Unable to read ACPI lid state: %s\n' "$state_file" >&2
            printf '%s\n' unknown
            return 3
        fi

        if [[ "$state_line" =~ ^[[:space:]]*(state:[[:space:]]*)?(open|closed)[[:space:]]*$ ]]; then
            state="${BASH_REMATCH[2]}"
        else
            printf 'Malformed ACPI lid state: %s\n' "$state_file" >&2
            printf '%s\n' unknown
            return 4
        fi

        if [[ -z "$observed_state" ]]; then
            observed_state="$state"
        elif [[ "$state" != "$observed_state" ]]; then
            printf 'Conflicting ACPI lid states found under %s\n' "$lid_root" >&2
            printf '%s\n' unknown
            return 5
        fi
    done

    printf '%s\n' "$observed_state"
}
EOF
}

render_monitor_state_script() {
    local destination=$1

    cat > "$destination" << 'EOF'
#!/bin/bash

MONITOR_STATE_ERROR=""
MONITOR_STATE_DIR=""
MONITOR_STATE_FILE=""
MONITOR_STATE_TOPOLOGY=""
MONITOR_STATE_SNAPSHOT=""
HYPRCTL_TIMEOUT_SECONDS=2

monitor_state_fail() {
    MONITOR_STATE_ERROR=$1
    return 2
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
EOF
}

render_lid_switch_script() {
    local destination=$1
    local internal_output=$2

    cat > "$destination" << 'EOF'
#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_record() {
    local level=$1
    local event=$2
    shift 2

    printf 'level=%s component=lid-switch event=%s' "$level" "$event"
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

if ! . "$SCRIPT_DIR/lid-state.sh"; then
    log_error lid_state_observer_load_failed
    exit 1
fi
if ! . "$SCRIPT_DIR/monitor-state.sh"; then
    log_error monitor_state_module_load_failed
    exit 1
fi

LAPTOP_DISPLAY="LAPTOP_MONITOR_PLACEHOLDER"
EXPECTED_LID=${ARCH_LIDSWITCH_EXPECTED_LID:-}
EXPECTED_POLICY_TOKEN=${ARCH_LIDSWITCH_EXPECTED_POLICY_TOKEN:-}
POST_LAYOUT_HOOK=${ARCH_LIDSWITCH_POST_LAYOUT_HOOK:-}

run_post_layout_hook() {
    local action=$1
    local outcome=$2
    local internal_output=$3
    local hook_status

    if [[ -z "$POST_LAYOUT_HOOK" ]]; then
        return 0
    fi
    if [[ "$POST_LAYOUT_HOOK" != /* ]]; then
        log_error post_layout_hook_invalid reason=not_absolute \
            action="$action" outcome="$outcome" \
            internal_output="$internal_output"
        return 0
    fi
    if [[ ! -f "$POST_LAYOUT_HOOK" ]]; then
        log_error post_layout_hook_invalid reason=not_regular \
            action="$action" outcome="$outcome" \
            internal_output="$internal_output"
        return 0
    fi
    if [[ ! -x "$POST_LAYOUT_HOOK" ]]; then
        log_error post_layout_hook_invalid reason=not_executable \
            action="$action" outcome="$outcome" \
            internal_output="$internal_output"
        return 0
    fi

    if timeout --kill-after=1s 2s "$POST_LAYOUT_HOOK" \
        "$action" "$outcome" "$internal_output"; then
        log_info post_layout_hook_succeeded action="$action" \
            outcome="$outcome" internal_output="$internal_output"
    else
        hook_status=$?
        log_error post_layout_hook_failed action="$action" \
            outcome="$outcome" internal_output="$internal_output" \
            status="$hook_status"
    fi
    return 0
}

validate_expected_generation_contract() {
    local action=$1

    if [[ -z "$EXPECTED_LID" && -z "$EXPECTED_POLICY_TOKEN" ]]; then
        return 0
    fi
    if [[ -z "$EXPECTED_LID" || -z "$EXPECTED_POLICY_TOKEN" ]] || \
        [[ "$EXPECTED_LID" != open && "$EXPECTED_LID" != closed ]] || \
        [[ "$action" == open && "$EXPECTED_LID" != open ]] || \
        [[ "$action" == close && "$EXPECTED_LID" != closed ]]; then
        log_error invalid_generation_contract action="$action" status=1
        return 1
    fi
    if ! jq -e '
        type == "object" and
        (keys | sort) == ["externals", "internal"] and
        (.internal | type == "string") and
        (.externals | type == "array") and
        all(.externals[];
            type == "object" and
            (keys | sort) == ["enabled", "output"] and
            (.output | type == "string") and
            (.enabled | type == "boolean"))
    ' <<< "$EXPECTED_POLICY_TOKEN" >/dev/null; then
        log_error invalid_generation_contract action="$action" status=1
        return 1
    fi
}

verify_expected_generation() {
    local action=$1
    local phase=$2
    local observed_lid observed_policy_token

    if [[ -z "$EXPECTED_LID" ]]; then
        return 0
    fi
    if ! observed_lid=$(read_lid_state); then
        log_error reconciliation_failed action="$action" phase="$phase" \
            status=2 reason=lid_state_unavailable \
            expected_lid="$EXPECTED_LID"
        return 2
    fi
    if ! observed_policy_token=$(monitor_state_policy_environment_token); then
        log_error reconciliation_failed action="$action" phase="$phase" \
            status=2 reason=policy_token_unavailable \
            expected_lid="$EXPECTED_LID"
        return 2
    fi
    if [[ "$observed_lid" != "$EXPECTED_LID" || \
        "$observed_policy_token" != "$EXPECTED_POLICY_TOKEN" ]]; then
        log_error reconciliation_failed action="$action" phase="$phase" \
            status=5 reason=generation_mismatch \
            expected_lid="$EXPECTED_LID" observed_lid="$observed_lid" \
            expected_policy_token="$EXPECTED_POLICY_TOKEN" \
            observed_policy_token="$observed_policy_token" \
            topology="$MONITOR_STATE_TOPOLOGY"
        return 5
    fi
}

reconcile_lid_state() {
    local action=$1
    local preserve_dpms=$2
    local internal_enabled enabled_external_count desired_internal
    local post_external_count post_desired_internal snapshot_status
    local wake_required=false desired_dpms=preserved
    local mutation_status=0 mutation_reason=none
    local layout_changed=false snapshot_involved=false noop_reason=""
    local verified_internal verified_dpms topology_snapshot

    log_info transition_started action="$action"
    if ! monitor_state_observe_topology "$LAPTOP_DISPLAY"; then
        log_error monitor_query_failed action="$action" reason="$MONITOR_STATE_ERROR"
        log_error reconciliation_failed action="$action" phase=observe \
            desired_internal=unknown status=2 reason="$MONITOR_STATE_ERROR"
        return 2
    fi
    if verify_expected_generation "$action" pre_apply; then
        :
    else
        return $?
    fi

    topology_snapshot=$MONITOR_STATE_TOPOLOGY
    internal_enabled=$(monitor_state_internal_enabled)
    enabled_external_count=$(monitor_state_enabled_external_count)
    if [[ "$action" == close && "$enabled_external_count" -gt 0 ]]; then
        desired_internal=disabled
    else
        desired_internal=enabled
    fi

    if [[ "$action" == open ]]; then
        if [[ "$preserve_dpms" != true || "$internal_enabled" == false ]]; then
            wake_required=true
            desired_dpms=true
        fi
    fi

    log_info reconciliation_attempt action="$action" \
        desired_internal="$desired_internal" desired_dpms="$desired_dpms" \
        enabled_external_count="$enabled_external_count" \
        topology="$topology_snapshot"

    if [[ "$desired_internal" == disabled ]]; then
        if [[ "$internal_enabled" == false ]]; then
            if monitor_state_load_internal_layout_snapshot "$LAPTOP_DISPLAY"; then
                noop_reason=internal_already_disabled
            else
                mutation_status=$?
                mutation_reason=$MONITOR_STATE_ERROR
            fi
        elif ! monitor_state_capture_internal_layout "$LAPTOP_DISPLAY"; then
            mutation_status=2
            mutation_reason=$MONITOR_STATE_ERROR
        elif monitor_state_disable_internal_output "$LAPTOP_DISPLAY"; then
            layout_changed=true
        else
            mutation_status=$?
            mutation_reason=$MONITOR_STATE_ERROR
        fi
    else
        if [[ "$internal_enabled" == false ]]; then
            if monitor_state_restore_internal_layout "$LAPTOP_DISPLAY"; then
                layout_changed=true
                snapshot_involved=true
            else
                mutation_status=$?
                mutation_reason=$MONITOR_STATE_ERROR
            fi
        else
            if monitor_state_snapshot_present; then
                snapshot_involved=true
                if monitor_state_internal_layout_matches_snapshot \
                    "$LAPTOP_DISPLAY"; then
                    noop_reason=internal_already_enabled
                else
                    snapshot_status=$?
                    if (( snapshot_status == 1 )); then
                        if monitor_state_restore_internal_layout \
                            "$LAPTOP_DISPLAY"; then
                            layout_changed=true
                        else
                            mutation_status=$?
                            mutation_reason=$MONITOR_STATE_ERROR
                        fi
                    else
                        mutation_status=$snapshot_status
                        mutation_reason=$MONITOR_STATE_ERROR
                    fi
                fi
            else
                snapshot_status=$?
                if (( snapshot_status == 1 )); then
                    noop_reason=internal_already_enabled
                else
                    mutation_status=$snapshot_status
                    mutation_reason=$MONITOR_STATE_ERROR
                fi
            fi
        fi

        if (( mutation_status == 0 )) && [[ "$wake_required" == true ]]; then
            if monitor_state_enable_internal_dpms "$LAPTOP_DISPLAY"; then
                :
            else
                mutation_status=$?
                mutation_reason=$MONITOR_STATE_ERROR
            fi
        fi
    fi

    if ! monitor_state_observe_topology "$LAPTOP_DISPLAY"; then
        log_error monitor_query_failed action="$action" phase=postcondition \
            reason="$MONITOR_STATE_ERROR"
        log_error reconciliation_failed action="$action" phase=postcondition \
            desired_internal="$desired_internal" desired_dpms="$desired_dpms" \
            status=2 reason="$MONITOR_STATE_ERROR" \
            apply_status="$mutation_status" apply_reason="$mutation_reason"
        return 2
    fi

    topology_snapshot=$MONITOR_STATE_TOPOLOGY
    if verify_expected_generation "$action" post_apply; then
        :
    else
        return $?
    fi
    verified_internal=$(monitor_state_internal_enabled)
    if verified_dpms=$(monitor_state_internal_dpms); then
        :
    else
        verified_dpms=unknown
    fi
    post_external_count=$(monitor_state_enabled_external_count)
    if [[ "$action" == close && "$post_external_count" -gt 0 ]]; then
        post_desired_internal=disabled
    else
        post_desired_internal=enabled
    fi

    if [[ "$post_desired_internal" != "$desired_internal" ]]; then
        log_error reconciliation_failed action="$action" phase=postcondition \
            desired_internal="$desired_internal" \
            observed_desired_internal="$post_desired_internal" \
            desired_dpms="$desired_dpms" status=4 reason=policy_changed \
            topology="$topology_snapshot"
        return 4
    fi

    if (( mutation_status != 0 )); then
        if (( mutation_status == 2 )); then
            log_error layout_snapshot_failed action="$action" \
                reason="$mutation_reason"
        else
            log_error layout_apply_failed action="$action" \
                reason="$mutation_reason"
        fi
        log_error reconciliation_failed action="$action" phase=apply \
            desired_internal="$desired_internal" desired_dpms="$desired_dpms" \
            status="$mutation_status" reason="$mutation_reason" \
            topology="$topology_snapshot"
        return "$mutation_status"
    fi

    if [[ "$desired_internal" == enabled && "$verified_internal" != true ]] || \
        [[ "$desired_internal" == disabled && "$verified_internal" != false ]] || \
        { [[ "$wake_required" == true ]] && [[ "$verified_dpms" != true ]]; }; then
        log_error reconciliation_failed action="$action" phase=postcondition \
            desired_internal="$desired_internal" desired_dpms="$desired_dpms" \
            status=4 reason=postcondition_mismatch topology="$topology_snapshot"
        return 4
    fi

    if [[ "$desired_internal" == disabled ]] && \
        ! monitor_state_load_internal_layout_snapshot "$LAPTOP_DISPLAY"; then
        log_error reconciliation_failed action="$action" phase=postcondition \
            desired_internal="$desired_internal" desired_dpms="$desired_dpms" \
            status=2 reason="$MONITOR_STATE_ERROR" topology="$topology_snapshot"
        return 2
    fi

    if [[ "$snapshot_involved" == true ]]; then
        if monitor_state_internal_layout_matches_snapshot "$LAPTOP_DISPLAY"; then
            :
        else
            snapshot_status=$?
            if (( snapshot_status == 1 )); then
                log_error reconciliation_failed action="$action" \
                    phase=postcondition desired_internal="$desired_internal" \
                    desired_dpms="$desired_dpms" status=4 \
                    reason=layout_postcondition_mismatch \
                    topology="$topology_snapshot"
                return 4
            fi
            log_error reconciliation_failed action="$action" \
                phase=postcondition desired_internal="$desired_internal" \
                desired_dpms="$desired_dpms" status=2 \
                reason="$MONITOR_STATE_ERROR" topology="$topology_snapshot"
            return 2
        fi
    fi

    if [[ "$snapshot_involved" == true ]] && \
        ! monitor_state_cleanup_internal_layout; then
        log_error layout_snapshot_failed action="$action" \
            reason="$MONITOR_STATE_ERROR"
        log_error reconciliation_failed action="$action" phase=snapshot_cleanup \
            desired_internal="$desired_internal" desired_dpms="$desired_dpms" \
            status=2 reason="$MONITOR_STATE_ERROR" topology="$topology_snapshot"
        return 2
    fi

    if [[ -n "$noop_reason" ]]; then
        log_info layout_noop action="$action" reason="$noop_reason" \
            enabled_external_count="$enabled_external_count"
    elif [[ "$desired_internal" == disabled ]]; then
        log_info layout_applied action="$action" laptop=disabled \
            enabled_external_count="$enabled_external_count"
    else
        log_info layout_applied action="$action" layout=internal_restored \
            enabled_external_count="$enabled_external_count"
    fi

    if [[ "$layout_changed" == true ]]; then
        run_post_layout_hook "$action" "$desired_internal" "$LAPTOP_DISPLAY"
    fi
    if [[ "$action" == close && "$enabled_external_count" -eq 0 ]]; then
        log_info power_delegated owner=systemd-logind action=close \
            reason=no_enabled_external
    fi
    log_info reconciliation_verified action="$action" \
        desired_internal="$desired_internal" desired_dpms="$desired_dpms" \
        topology="$topology_snapshot"
}

preserve_dpms=false
if [[ "${1:-}" == --preserve-dpms ]]; then
    preserve_dpms=true
    shift
fi

if (( $# > 1 )); then
    log_error invalid_arguments status=1
    exit 1
fi

case "${1:-}" in
    close|closed)
        if [[ "$preserve_dpms" == true ]]; then
            log_error invalid_arguments status=1 reason=preserve_dpms_requires_open
            exit 1
        fi
        validate_expected_generation_contract close || exit $?
        reconcile_lid_state close false
        ;;
    open)
        validate_expected_generation_contract open || exit $?
        reconcile_lid_state open "$preserve_dpms"
        ;;
    "")
        if [[ "$preserve_dpms" == true ]]; then
            log_error invalid_arguments status=1 reason=preserve_dpms_requires_open
            exit 1
        fi
        if ! lid_state=$(read_lid_state); then
            log_error lid_state_unknown action=auto status=2
            exit 2
        fi
        log_info lid_state_detected state="$lid_state"
        if [[ "$lid_state" == closed ]]; then
            validate_expected_generation_contract close || exit $?
            reconcile_lid_state close false
        else
            validate_expected_generation_contract open || exit $?
            reconcile_lid_state open false
        fi
        ;;
    *)
        log_error invalid_arguments status=1 action="${1:-}"
        exit 1
        ;;
esac
EOF

    sed -i "s/LAPTOP_MONITOR_PLACEHOLDER/$internal_output/g" "$destination"
}

render_lid_switch_doctor() {
    local destination=$1

    cat > "$destination" << 'EOF'
#!/bin/bash

set -u

LOGIN1_SERVICE="org.freedesktop.login1"
LOGIN1_PATH="/org/freedesktop/login1"
LOGIN1_MANAGER="org.freedesktop.login1.Manager"

usage() {
    printf 'usage: %s [--policy-only]\n' "${0##*/}" >&2
}

print_remediation() {
    printf '%s\n' \
        'INFO Inspect effective policy with: systemd-analyze cat-config systemd/logind.conf' \
        'INFO Inspect lid inhibitors with: systemd-inhibit --list --what=handle-lid-switch --no-pager' \
        'INFO This installer does not modify /etc or systemd-logind policy.'
}

read_manager_string_property() {
    local property=$1
    local raw_value

    if ! raw_value=$(busctl get-property \
        "$LOGIN1_SERVICE" \
        "$LOGIN1_PATH" \
        "$LOGIN1_MANAGER" \
        "$property"); then
        printf 'ERROR Could not read effective logind property %s.\n' \
            "$property" >&2
        return 2
    fi

    if [[ "$raw_value" =~ ^s[[:space:]]+\"([^\"]*)\"$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    printf 'ERROR Unexpected value for logind property %s: %s\n' \
        "$property" "$raw_value" >&2
    return 2
}

call_manager_string_method() {
    local method=$1
    local diagnostic_level=${2:-ERROR}
    local raw_value

    if ! raw_value=$(busctl call \
        "$LOGIN1_SERVICE" \
        "$LOGIN1_PATH" \
        "$LOGIN1_MANAGER" \
        "$method"); then
        printf '%s Could not query login1 capability %s.\n' \
            "$diagnostic_level" "$method" >&2
        return 2
    fi

    if [[ "$raw_value" =~ ^s[[:space:]]+\"([^\"]*)\"$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    printf '%s Unexpected value for login1 capability %s: %s\n' \
        "$diagnostic_level" "$method" "$raw_value" >&2
    return 2
}

check_lid_power_policy() {
    local handle_lid_switch handle_lid_switch_docked
    local handle_lid_switch_external_power can_suspend can_hibernate
    local inhibitor_output
    local policy_status=0

    if ! handle_lid_switch=$(read_manager_string_property HandleLidSwitch); then
        print_remediation
        return 2
    fi
    if ! handle_lid_switch_docked=$(read_manager_string_property HandleLidSwitchDocked); then
        print_remediation
        return 2
    fi
    if ! handle_lid_switch_external_power=$(read_manager_string_property HandleLidSwitchExternalPower); then
        print_remediation
        return 2
    fi
    if ! can_suspend=$(call_manager_string_method CanSuspend); then
        print_remediation
        return 2
    fi
    if [[ "$can_suspend" == "yes" ]]; then
        printf 'PASS CanSuspend=yes\n'
    else
        printf 'FAIL CanSuspend=%s expected=yes\n' "$can_suspend"
        policy_status=1
    fi
    if can_hibernate=$(call_manager_string_method CanHibernate WARN); then
        case "$can_hibernate" in
            yes)
                printf 'INFO CanHibernate=yes hibernate=available-but-unused\n'
                ;;
            *)
                printf 'INFO CanHibernate=%s hibernate=unused\n' "$can_hibernate"
                ;;
        esac
    else
        printf 'WARN CanHibernate=<unavailable> hibernate=unused\n'
    fi
    if ! inhibitor_output=$(systemd-inhibit \
        --list \
        --what=handle-lid-switch \
        --no-pager \
        --no-legend); then
        printf 'ERROR Could not inspect handle-lid-switch inhibitors.\n' >&2
        print_remediation
        return 2
    fi

    if [[ "$handle_lid_switch" != "suspend" ]]; then
        printf 'FAIL HandleLidSwitch=%s expected=suspend\n' "$handle_lid_switch"
        policy_status=1
    else
        printf 'PASS HandleLidSwitch=suspend\n'
    fi

    if [[ "$handle_lid_switch_docked" != "ignore" ]]; then
        printf 'FAIL HandleLidSwitchDocked=%s expected=ignore\n' \
            "$handle_lid_switch_docked"
        policy_status=1
    else
        printf 'PASS HandleLidSwitchDocked=ignore\n'
    fi

    case "$handle_lid_switch_external_power" in
        "")
            printf 'PASS HandleLidSwitchExternalPower=<unset> fallback=HandleLidSwitch\n'
            ;;
        suspend)
            printf 'PASS HandleLidSwitchExternalPower=suspend\n'
            ;;
        *)
            printf 'FAIL HandleLidSwitchExternalPower=%s expected=<unset-or-suspend>\n' \
                "$handle_lid_switch_external_power"
            policy_status=1
            ;;
    esac

    if [[ -n "$inhibitor_output" && "$inhibitor_output" != "No inhibitors listed." ]]; then
        printf 'FAIL handle-lid-switch inhibitor present: %s\n' "$inhibitor_output"
        policy_status=1
    else
        printf 'PASS handle-lid-switch inhibitors=none\n'
    fi

    if (( policy_status != 0 )); then
        print_remediation
    fi

    return "$policy_status"
}

case "${1:-}" in
    ""|--policy-only)
        if (( $# > 1 )); then
            usage
            exit 2
        fi
        check_lid_power_policy
        ;;
    *)
        usage
        exit 2
        ;;
esac
EOF
}

render_lid_monitor_script() {
    local destination=$1
    local internal_output=$2

    cat > "$destination" << 'EOF'
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

observe_joint_state() {
    local trigger=$1

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
        previous_topology_error=$observed_topology_error
        log_error topology_observation_failed reason="$observed_topology_error" \
            trigger="$trigger"
        return 2
    fi
}

stabilize_joint_state() {
    local trigger=$1
    local candidate="" sample_key final_key
    local consecutive=0 samples=0
    local last_valid_state="" last_valid_topology=""
    local last_valid_full_topology="" last_valid_policy_token=""

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
    if [[ "$state" == open && "$require_dpms" == true ]]; then
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

    if [[ "$commit_generation" == true ]]; then
        if [[ "$state" == open && "$preserve_dpms" == true ]]; then
            ARCH_LIDSWITCH_EXPECTED_LID="$expected_lid" \
            ARCH_LIDSWITCH_EXPECTED_POLICY_TOKEN="$expected_policy_token" \
                "$LID_SWITCH_SCRIPT" --preserve-dpms open
        else
            ARCH_LIDSWITCH_EXPECTED_LID="$expected_lid" \
            ARCH_LIDSWITCH_EXPECTED_POLICY_TOKEN="$expected_policy_token" \
                "$LID_SWITCH_SCRIPT" "$state"
        fi
    elif [[ "$state" == open && "$preserve_dpms" == true ]]; then
        "$LID_SWITCH_SCRIPT" --preserve-dpms open
    else
        "$LID_SWITCH_SCRIPT" "$state"
    fi
}

apply_observed_joint_state() {
    local trigger=$1
    local attempt=$2
    local preserve_dpms=$3
    local commit_generation=$4
    local attempted_state=$current_state
    local attempted_topology=$current_topology
    local attempted_policy_token=$current_policy_token
    local attempted_internal wake_required=false
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
            if ! stabilize_joint_state resume; then
                exit 2
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
EOF

    sed -i "s/LAPTOP_MONITOR_PLACEHOLDER/$internal_output/g" "$destination"
}

render_lid_resume_monitor_script() {
    local destination=$1

    cat > "$destination" << 'EOF'
#!/bin/bash

MAX_NOTIFY_ATTEMPTS=3
NOTIFY_RETRY_DELAY=0.1
RECONNECT_DELAY=1
LOGIN1_SERVICE=org.freedesktop.login1
LOGIN1_PATH=/org/freedesktop/login1
LOGIN1_MANAGER=org.freedesktop.login1.Manager
LOGIN1_SIGNAL=PrepareForSleep

log_record() {
    local level=$1
    local event=$2
    shift 2

    printf 'level=%s component=lid-resume-monitor event=%s' "$level" "$event"
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

notify_main_monitor() {
    local attempt

    for ((attempt = 1; attempt <= MAX_NOTIFY_ATTEMPTS; attempt++)); do
        if systemctl --user kill --kill-whom=main --signal=USR1 \
            lid-monitor.service; then
            log_info resume_notification_succeeded attempt="$attempt"
            return 0
        fi
        log_error resume_notification_failed attempt="$attempt" status=3
        if (( attempt < MAX_NOTIFY_ATTEMPTS )); then
            sleep "$NOTIFY_RETRY_DELAY"
        fi
    done
    return 3
}

handle_prepare_for_sleep_event() {
    local event_json=$1

    case "$event_json" in
        '{"type":"b","data":[true]}')
            log_info prepare_for_sleep state=true action=none
            return 0
            ;;
        '{"type":"b","data":[false]}')
            log_info prepare_for_sleep state=false action=notify
            notify_main_monitor
            ;;
        *)
            log_error prepare_for_sleep_invalid status=2 payload="$event_json"
            return 2
            ;;
    esac
}

run_subscription() {
    local message_limit=$1
    local once_mode=$2
    local stream_fd stream_pid event_json
    local event_status=0 wait_status=0 received_event=false
    local abort_subscription=false

    coproc RESUME_EVENTS {
        exec stdbuf -oL busctl --system --json=short \
            --limit-messages="$message_limit" wait \
            "$LOGIN1_SERVICE" "$LOGIN1_PATH" "$LOGIN1_MANAGER" \
            "$LOGIN1_SIGNAL"
    }
    exec {stream_fd}<&"${RESUME_EVENTS[0]}"
    stream_pid=$RESUME_EVENTS_PID

    while IFS= read -r -u "$stream_fd" event_json 2>/dev/null; do
        received_event=true
        if handle_prepare_for_sleep_event "$event_json"; then
            :
        else
            event_status=$?
            if [[ "$once_mode" != true ]]; then
                abort_subscription=true
                break
            fi
        fi
        if [[ "$once_mode" == true ]]; then
            break
        fi
    done
    exec {stream_fd}<&-
    if [[ "$abort_subscription" == true ]]; then
        kill "$stream_pid" 2>/dev/null || true
        sleep 0.1
        kill -KILL "$stream_pid" 2>/dev/null || true
        log_error subscription_aborted status="$event_status" \
            reason=invalid_or_unhandled_event
    fi
    wait "$stream_pid" 2>/dev/null || wait_status=$?

    if (( event_status != 0 )); then
        return "$event_status"
    fi
    if (( wait_status != 0 )); then
        log_error subscription_failed status=2 busctl_status="$wait_status"
        return 2
    fi
    if [[ "$received_event" != true ]]; then
        log_error subscription_failed status=2 reason=no_event
        return 2
    fi
    if [[ "$once_mode" != true ]]; then
        log_error subscription_ended status=2 reason=unexpected_eof
        return 2
    fi
}

case "${1:-}" in
    --once)
        run_subscription 1 true
        exit $?
        ;;
    "")
        ;;
    *)
        log_error invalid_arguments status=1
        exit 1
        ;;
esac

while true; do
    run_subscription infinity false || true
    sleep "$RECONNECT_DELAY"
done
EOF
}

replace_literal_token() {
    local file=$1
    local token=$2
    local replacement=$3
    local temporary line prefix suffix

    temporary=$(mktemp "$file.replace.XXXXXX")
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *"$token"* ]]; then
            prefix=${line%%"$token"*}
            suffix=${line#*"$token"}
            line=$prefix$replacement$suffix
        fi
        printf '%s\n' "$line"
    done < "$file" > "$temporary"
    mv -f -- "$temporary" "$file"
}

render_systemd_services() {
    local main_destination=$1
    local resume_destination=$2

    cat > "$main_destination" << 'EOF'
[Unit]
Description=Hyprland Lid Switch Monitor
Wants=lid-resume-monitor.service
PartOf=graphical-session.target
After=graphical-session.target
ConditionEnvironment=HYPRLAND_INSTANCE_SIGNATURE
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=exec
EnvironmentFile=-%h/.config/arch-lidswitch/environment
ExecStartPre=$TIMEOUT_BIN --kill-after=1s 2s $HYPRCTL_BIN monitors
ExecStart=$SCRIPTS_DIR/lid-monitor.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=arch-lidswitch
Restart=on-failure
RestartPreventExitStatus=1
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF

    cat > "$resume_destination" << 'EOF'
[Unit]
Description=Hyprland Lid Resume Signal Monitor
BindsTo=lid-monitor.service
PartOf=graphical-session.target
After=graphical-session.target lid-monitor.service
ConditionEnvironment=HYPRLAND_INSTANCE_SIGNATURE
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=exec
ExecStart=$SCRIPTS_DIR/lid-resume-monitor.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=arch-lidswitch-resume
Restart=on-failure
RestartPreventExitStatus=1
RestartSec=2
EOF

    replace_literal_token "$main_destination" '$TIMEOUT_BIN' "$TIMEOUT_BIN"
    replace_literal_token "$main_destination" '$HYPRCTL_BIN' "$HYPRCTL_BIN"
    replace_literal_token "$main_destination" '$SCRIPTS_DIR' "$SCRIPTS_DIR"
    replace_literal_token "$resume_destination" '$SCRIPTS_DIR' "$SCRIPTS_DIR"
}

################################################################################
# Transaction Module
################################################################################

artifact_stage_path() {
    local artifact_id=$1
    printf '%s/%s\n' "$transaction_stage_dir" \
        "${ARTIFACT_RELATIVE_PATH[$artifact_id]}"
}

sha256_file() {
    local output

    if ! output=$(sha256sum -- "$1"); then
        log_error "Could not hash file: $1" >&2
        return 1
    fi
    output=${output%% *}
    if [[ ! "$output" =~ ^[0-9a-fA-F]{64}$ ]]; then
        log_error "Could not parse file hash: $1" >&2
        return 1
    fi
    printf '%s\n' "$output"
}

validate_fault_checkpoint() {
    local configured=${ARCH_LIDSWITCH_TEST_FAIL_AFTER:-}
    local checkpoint

    if [[ -z "$configured" ]]; then
        return 0
    fi
    for checkpoint in "${FAULT_CHECKPOINTS[@]}"; do
        if [[ "$configured" == "$checkpoint" ]]; then
            return 0
        fi
    done
    log_error "Unknown transactional fault checkpoint: $configured"
    return 1
}

fault_after() {
    local checkpoint=$1

    if [[ "${ARCH_LIDSWITCH_TEST_FAIL_AFTER:-}" == "$checkpoint" ]]; then
        log_error "Injected transactional failure after checkpoint=$checkpoint"
        return 97
    fi
}

defer_transaction_signals() {
    deferred_transaction_signal=""
    trap 'deferred_transaction_signal=130' INT
    trap 'deferred_transaction_signal=143' TERM
}

restore_and_deliver_transaction_signals() {
    local deferred

    trap 'log_error "Installation interrupted"; exit 130' INT
    if [[ "${ARCH_LIDSWITCH_TEST_SIGNAL_DURING_TRAP_RESTORE:-0}" == 1 && \
        "$trap_restore_signal_injected" != true ]]; then
        trap_restore_signal_injected=true
        kill -s TERM "$$"
    fi
    trap 'log_error "Installation terminated"; exit 143' TERM
    deferred=$deferred_transaction_signal
    deferred_transaction_signal=""
    if [[ -n "$deferred" ]]; then
        log_warning "Delivering deferred installation signal status=$deferred"
        exit "$deferred"
    fi
}

ensure_private_directory() {
    local directory=$1

    if [[ -L "$directory" ]]; then
        log_error "Refusing symlinked transaction directory: $directory"
        return 1
    fi
    mkdir -p -- "$directory"
    chmod 0700 -- "$directory"
}

initialize_transaction() {
    local lock_file

    scripts_dir_existed=$([[ -d "$SCRIPTS_DIR" ]] && printf true || printf false)
    session_module_dir_existed=$([[ -d "$SESSION_MODULE_DIR" ]] && printf true || printf false)
    systemd_user_dir_existed=$([[ -d "$SYSTEMD_USER_DIR" ]] && printf true || printf false)

    ensure_private_directory "$STATE_ROOT"
    ensure_private_directory "$TRANSACTIONS_DIR"
    ensure_private_directory "$BACKUPS_DIR"

    lock_file="$STATE_ROOT/install.lock"
    if [[ -L "$lock_file" ]]; then
        log_error "Refusing symlinked transaction lock: $lock_file"
        return 1
    fi
    exec {transaction_lock_fd}>"$lock_file"
    chmod 0600 -- "$lock_file"
    if ! flock -n "$transaction_lock_fd"; then
        log_error "Another arch-lidswitch installation is already running"
        return 1
    fi

    transaction_id="$(date +%Y%m%dT%H%M%S)-$$"
    transaction_dir="$TRANSACTIONS_DIR/$transaction_id"
    transaction_stage_dir="$transaction_dir/stage"
    transaction_before_dir="$transaction_dir/before"
    transaction_manifest="$transaction_dir/new.manifest"
    mkdir -- "$transaction_dir"
    chmod 0700 -- "$transaction_dir"
    mkdir -p -- "$transaction_stage_dir" "$transaction_before_dir/files"
    chmod 0700 -- "$transaction_stage_dir" "$transaction_before_dir" \
        "$transaction_before_dir/files"
    transaction_active=true
}

validate_mv_exchange_support() {
    local first="$transaction_dir/exchange-check-a"
    local second="$transaction_dir/exchange-check-b"
    local absent="$transaction_dir/no-replace-check"
    local no_replace_status=0

    if ! printf '%s\n' first > "$first" || \
        ! printf '%s\n' second > "$second"; then
        log_error "Could not prepare the atomic-exchange capability check"
        return 1
    fi
    if ! ARCH_LIDSWITCH_ATOMIC_CONTEXT=exchange-check \
        mv --exchange --no-copy -T -- "$first" "$second"; then
        log_error "GNU mv with --exchange --no-copy support is required"
        rm -f -- "$first" "$second" || true
        return 1
    fi
    if [[ "$(<"$first")" != second || "$(<"$second")" != first ]]; then
        log_error "GNU mv atomic-exchange capability check failed"
        rm -f -- "$first" "$second" || true
        return 1
    fi
    ARCH_LIDSWITCH_ATOMIC_CONTEXT=no-replace-collision-check \
        mv --update=none-fail --no-copy -T -- "$first" "$second" \
        || no_replace_status=$?
    if (( no_replace_status == 0 )) || \
        [[ ! -f "$first" || ! -f "$second" ]] || \
        [[ "$(<"$first")" != second || "$(<"$second")" != first ]]; then
        log_error "GNU mv atomic no-replace collision check failed"
        rm -f -- "$first" "$second" "$absent" || true
        return 1
    fi
    if ! ARCH_LIDSWITCH_ATOMIC_CONTEXT=no-replace-check \
        mv --update=none-fail --no-copy -T -- "$first" "$absent" || \
        [[ -e "$first" || -L "$first" || ! -f "$absent" ]] || \
        [[ "$(<"$absent")" != second ]]; then
        log_error "GNU mv atomic no-replace capability check failed"
        rm -f -- "$first" "$second" "$absent" || true
        return 1
    fi
    if ! rm -f -- "$first" "$second" "$absent"; then
        log_error "Could not clean the atomic-exchange capability check"
        return 1
    fi
}

capture_enablement_state() {
    local unit=$1
    local role=$2
    local output status=0

    output=$(systemctl --user is-enabled "$unit" 2>/dev/null) || status=$?
    case "$output" in
        enabled)
            if [[ "$role" == resume ]]; then
                log_error "Static resume listener is unexpectedly enabled" >&2
                return 1
            fi
            printf '%s\n' enabled
            ;;
        disabled)
            if [[ "$role" == resume ]]; then
                log_error "Static resume listener has unexpected enablement state: disabled" >&2
                return 1
            fi
            printf '%s\n' disabled
            ;;
        not-found)
            printf '%s\n' not-found
            ;;
        static)
            if [[ "$role" != resume ]]; then
                log_error "Main service has unexpected enablement state: static" >&2
                return 1
            fi
            printf '%s\n' static
            ;;
        masked|masked-runtime)
            log_error "Refusing masked user service: $unit" >&2
            return 1
            ;;
        "")
            if (( status == 0 )); then
                log_error "Could not parse enablement state for $unit" >&2
                return 1
            fi
            log_error "Could not determine enablement state for $unit" >&2
            return 1
            ;;
        *)
            log_error "Unsupported enablement state for $unit: $output" >&2
            return 1
            ;;
    esac
}

capture_active_state() {
    local unit=$1
    local status

    if systemctl --user is-active --quiet "$unit"; then
        printf '%s\n' true
    else
        status=$?
        case "$status" in
            3|4)
                printf '%s\n' false
                ;;
            *)
                log_error "Could not determine active state for $unit" >&2
                return 1
                ;;
        esac
    fi
}

query_service_runtime() {
    local unit=$1
    local output line key value
    local load_state="" active_state="" sub_state="" main_pid=""
    local invocation=""
    local load_seen=0 active_seen=0 sub_seen=0 pid_seen=0 invocation_seen=0

    if ! output=$("$TIMEOUT_BIN" --kill-after=1s 2s \
        systemctl --user show --no-pager \
        --property=LoadState --property=ActiveState --property=SubState \
        --property=MainPID --property=InvocationID "$unit"); then
        log_error "Could not query service runtime identity: $unit"
        return 1
    fi
    while IFS= read -r line; do
        if [[ "$line" != *=* ]]; then
            log_error "Malformed service runtime property for $unit: $line"
            return 2
        fi
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            LoadState)
                load_seen=$((load_seen + 1))
                load_state=$value
                ;;
            ActiveState)
                active_seen=$((active_seen + 1))
                active_state=$value
                ;;
            SubState)
                sub_seen=$((sub_seen + 1))
                sub_state=$value
                ;;
            MainPID)
                pid_seen=$((pid_seen + 1))
                main_pid=$value
                ;;
            InvocationID)
                invocation_seen=$((invocation_seen + 1))
                invocation=$value
                ;;
            *)
                log_error "Unexpected service runtime property for $unit: $key"
                return 2
                ;;
        esac
    done <<< "$output"
    if (( load_seen != 1 || active_seen != 1 || sub_seen != 1 || \
        pid_seen != 1 || invocation_seen != 1 )); then
        log_error "Incomplete service runtime identity for $unit"
        return 2
    fi
    if [[ "$load_state" != loaded || "$active_state" != active || \
        "$sub_state" != running || ! "$main_pid" =~ ^[1-9][0-9]*$ || \
        ! "$invocation" =~ ^[0-9a-fA-F]{32}$ || \
        "$invocation" == 00000000000000000000000000000000 ]]; then
        return 3
    fi
    service_runtime_pid=$main_pid
    service_runtime_invocation=${invocation,,}
}

capture_prior_runtime_sample() {
    local main_active resume_active status
    local main_pid="-" main_invocation="-" resume_pid="-"
    local resume_invocation="-"

    main_active=$(capture_active_state lid-monitor.service) || return 1
    resume_active=$(capture_active_state lid-resume-monitor.service) || return 1
    if [[ "$main_active" == true ]]; then
        query_service_runtime lid-monitor.service || {
            status=$?
            return "$status"
        }
        main_pid=$service_runtime_pid
        main_invocation=$service_runtime_invocation
    fi
    if [[ "$resume_active" == true ]]; then
        query_service_runtime lid-resume-monitor.service || {
            status=$?
            return "$status"
        }
        resume_pid=$service_runtime_pid
        resume_invocation=$service_runtime_invocation
    fi
    service_sample_fingerprint="$main_active:$main_pid:$main_invocation|$resume_active:$resume_pid:$resume_invocation"
    service_sample_main_pid=$main_pid
    service_sample_main_invocation=$main_invocation
    service_sample_resume_pid=$resume_pid
    service_sample_resume_invocation=$resume_invocation
    main_was_active=$main_active
    resume_was_active=$resume_active
}

capture_coherent_prior_service_runtime() {
    local previous="" attempt status

    for attempt in 1 2 3 4; do
        status=0
        capture_prior_runtime_sample || status=$?
        if (( status != 0 )); then
            log_error "Could not capture a healthy prior service generation pair"
            return "$status"
        fi
        if [[ -n "$previous" && "$service_sample_fingerprint" == "$previous" ]]; then
            main_prior_pid=$service_sample_main_pid
            main_prior_invocation=$service_sample_main_invocation
            resume_prior_pid=$service_sample_resume_pid
            resume_prior_invocation=$service_sample_resume_invocation
            return 0
        fi
        previous=$service_sample_fingerprint
    done
    log_error "Prior service generation pair changed during transaction snapshot"
    return 1
}

consistent_snapshot_mode=""
consistent_snapshot_hash=""

copy_consistent_snapshot() {
    local source=$1
    local snapshot=$2
    local label=$3
    local snapshot_mode snapshot_hash live_mode

    if ! mkdir -p -- "$(dirname "$snapshot")"; then
        log_error "Could not create snapshot directory: $snapshot"
        return 1
    fi
    if ! ARCH_LIDSWITCH_ATOMIC_CONTEXT="snapshot-$label" \
        cp -p -- "$source" "$snapshot"; then
        log_error "Could not copy transaction snapshot: $source"
        return 1
    fi
    if [[ -L "$snapshot" || ! -f "$snapshot" ]] || \
        ! snapshot_mode=$(stat -c %a -- "$snapshot") || \
        ! snapshot_hash=$(sha256_file "$snapshot"); then
        log_error "Could not inspect transaction snapshot: $source"
        return 1
    fi
    if [[ -L "$source" || ! -f "$source" ]] || \
        ! live_mode=$(stat -c %a -- "$source") || \
        [[ "$live_mode" != "$snapshot_mode" ]] || \
        ! cmp -s -- "$snapshot" "$source"; then
        log_error "Source changed while transaction snapshot was copied: $source"
        return 1
    fi
    consistent_snapshot_mode=$snapshot_mode
    consistent_snapshot_hash=$snapshot_hash
}

snapshot_managed_file() {
    local artifact_id=$1
    local destination=${ARTIFACT_DESTINATION[$artifact_id]}
    local relative=${ARTIFACT_RELATIVE_PATH[$artifact_id]}
    local snapshot="$transaction_before_dir/files/$relative"
    local mode hash

    if [[ -L "$destination" ]] || \
        { [[ -e "$destination" ]] && [[ ! -f "$destination" ]]; }; then
        log_error "Refusing non-regular managed destination: $destination"
        return 1
    fi
    if [[ -f "$destination" ]]; then
        copy_consistent_snapshot "$destination" "$snapshot" "$artifact_id"
        mode=$consistent_snapshot_mode
        hash=$consistent_snapshot_hash
        ARTIFACT_WAS_PRESENT[$artifact_id]=true
        ARTIFACT_WAS_MODE[$artifact_id]=$mode
        ARTIFACT_WAS_HASH[$artifact_id]=$hash
        printf '%s\tpresent\t%s\t%s\t%s\n' \
            "$artifact_id" "$mode" "$hash" "$destination" \
            >> "$transaction_before_dir/snapshot.tsv"
    else
        ARTIFACT_WAS_PRESENT[$artifact_id]=false
        ARTIFACT_WAS_MODE[$artifact_id]=""
        ARTIFACT_WAS_HASH[$artifact_id]=""
        printf '%s\tabsent\t-\t-\t%s\n' \
            "$artifact_id" "$destination" \
            >> "$transaction_before_dir/snapshot.tsv"
    fi
    ARTIFACT_PUBLISH_INTENT[$artifact_id]=false
    ARTIFACT_EXCHANGE_SIBLING[$artifact_id]=""
    ARTIFACT_CANDIDATE_IDENTITY[$artifact_id]=""
    ARTIFACT_DISPLACED_VALIDATED[$artifact_id]=false
}

snapshot_current_manifest() {
    if [[ -L "$CURRENT_MANIFEST" ]] || \
        { [[ -e "$CURRENT_MANIFEST" ]] && [[ ! -f "$CURRENT_MANIFEST" ]]; }; then
        log_error "Refusing non-regular current manifest: $CURRENT_MANIFEST"
        return 1
    fi
    if [[ -f "$CURRENT_MANIFEST" ]]; then
        copy_consistent_snapshot "$CURRENT_MANIFEST" \
            "$transaction_before_dir/current.manifest" current-manifest
        manifest_was_present=true
        manifest_was_mode=$consistent_snapshot_mode
        manifest_was_hash=$consistent_snapshot_hash
    else
        manifest_was_present=false
        manifest_was_mode=""
        manifest_was_hash=""
    fi
    printf 'current-manifest\t%s\t%s\t%s\t%s\n' \
        "$([[ "$manifest_was_present" == true ]] && printf present || printf absent)" \
        "${manifest_was_mode:--}" "${manifest_was_hash:--}" \
        "$CURRENT_MANIFEST" >> "$transaction_before_dir/snapshot.tsv"
}

snapshot_installation_state() {
    local artifact_id

    : > "$transaction_before_dir/snapshot.tsv"
    chmod 0600 -- "$transaction_before_dir/snapshot.tsv"
    for artifact_id in "${ARTIFACT_IDS[@]}"; do
        snapshot_managed_file "$artifact_id"
    done
    snapshot_current_manifest

    copy_consistent_snapshot "$HYPRLAND_CONFIG_FILE" \
        "$transaction_before_dir/hyprland.lua" hyprland-config
    config_snapshot_mode=$consistent_snapshot_mode

    main_enablement_state=$(capture_enablement_state lid-monitor.service main)
    resume_enablement_state=$(capture_enablement_state lid-resume-monitor.service resume)
    capture_coherent_prior_service_runtime
    {
        printf 'main_enablement=%s\n' "$main_enablement_state"
        printf 'resume_enablement=%s\n' "$resume_enablement_state"
        printf 'main_active=%s\n' "$main_was_active"
        printf 'resume_active=%s\n' "$resume_was_active"
        printf 'main_pid=%s\n' "$main_prior_pid"
        printf 'main_invocation=%s\n' "$main_prior_invocation"
        printf 'resume_pid=%s\n' "$resume_prior_pid"
        printf 'resume_invocation=%s\n' "$resume_prior_invocation"
    } > "$transaction_before_dir/service-state"
    chmod 0600 -- "$transaction_before_dir/service-state"

    detect_legacy_default_target_service
}

render_staged_artifacts() {
    local artifact_id stage_path

    mkdir -p -- "$transaction_stage_dir/scripts" \
        "$transaction_stage_dir/arch_lidswitch" \
        "$transaction_stage_dir/systemd/user"

    render_lid_state_script "$(artifact_stage_path lid-state)"
    render_monitor_state_script "$(artifact_stage_path monitor-state)"
    render_lid_switch_script "$(artifact_stage_path lid-switch)" "$laptop_monitor"
    render_lid_switch_doctor "$(artifact_stage_path lid-switch-doctor)"
    render_lid_monitor_script "$(artifact_stage_path lid-monitor)" "$laptop_monitor"
    render_lid_resume_monitor_script "$(artifact_stage_path lid-resume-monitor)"
    render_session_bridge "$(artifact_stage_path lid-session-bridge)"
    render_session_module "$(artifact_stage_path session-module)"
    render_session_target "$(artifact_stage_path session-target)"
    render_systemd_services "$(artifact_stage_path main-service)" \
        "$(artifact_stage_path resume-service)"

    for artifact_id in "${ARTIFACT_IDS[@]}"; do
        stage_path=$(artifact_stage_path "$artifact_id")
        chmod "${ARTIFACT_MODE[$artifact_id]}" -- "$stage_path"
    done
}

render_config_candidate() {
    config_candidate="$transaction_dir/hyprland.lua.candidate"
    cp -p -- "$transaction_before_dir/hyprland.lua" "$config_candidate"
    if [[ "$session_config_state" == missing ]]; then
        {
            printf '\n'
            write_session_config_block
        } >> "$config_candidate"
    fi
    chmod "$config_snapshot_mode" -- "$config_candidate"
    if ! sha256_file "$config_candidate" >/dev/null; then
        log_error "Could not validate rendered Hyprland config candidate"
        return 1
    fi
}

validate_staged_systemd_units() {
    local verify_dir="$transaction_dir/unit-verify"
    local verify_runtime="$transaction_dir/unit-verify-runtime"
    local verify_target="$verify_dir/hyprland-session.target"
    local verify_main="$verify_dir/lid-monitor.service"
    local verify_resume="$verify_dir/lid-resume-monitor.service"
    local validation_output

    if ! mkdir -p -- "$verify_dir" "$verify_runtime" || \
        ! chmod 0700 -- "$verify_dir" "$verify_runtime" || \
        ! cp -- "$(artifact_stage_path session-target)" "$verify_target" || \
        ! cp -- "$(artifact_stage_path main-service)" "$verify_main" || \
        ! cp -- "$(artifact_stage_path resume-service)" "$verify_resume"; then
        log_error "Could not prepare staged systemd unit validation"
        return 1
    fi
    if ! replace_literal_token "$verify_main" \
        "ExecStart=$SCRIPTS_DIR/lid-monitor.sh" \
        "ExecStart=\"$(artifact_stage_path lid-monitor)\"" || \
        ! replace_literal_token "$verify_resume" \
        "ExecStart=$SCRIPTS_DIR/lid-resume-monitor.sh" \
        "ExecStart=\"$(artifact_stage_path lid-resume-monitor)\""; then
        log_error "Could not prepare staged systemd unit command paths"
        return 1
    fi

    if ! validation_output=$(SYSTEMD_UNIT_PATH="$verify_dir:" \
        XDG_RUNTIME_DIR="$verify_runtime" \
        "$SYSTEMD_ANALYZE_BIN" --user --generators=no --man=no \
        --recursive-errors=yes verify \
        "$verify_target" "$verify_main" "$verify_resume" 2>&1); then
        log_error "Staged systemd unit validation failed"
        if [[ -n "$validation_output" ]]; then
            printf '%s\n' "$validation_output" >&2
        fi
        return 1
    fi
}

validate_staged_artifacts() {
    local artifact_id stage_path actual_mode hash
    local -a shell_artifacts=(
        lid-state monitor-state lid-switch lid-switch-doctor lid-monitor
        lid-resume-monitor lid-session-bridge
    )

    for artifact_id in "${shell_artifacts[@]}"; do
        /bin/bash -n "$(artifact_stage_path "$artifact_id")"
    done
    luac -p "$(artifact_stage_path session-module)"
    luac -p "$config_candidate"
    validate_staged_systemd_units

    : > "$transaction_manifest"
    chmod 0600 -- "$transaction_manifest"
    for artifact_id in "${ARTIFACT_IDS[@]}"; do
        stage_path=$(artifact_stage_path "$artifact_id")
        if grep -Eq '@@[A-Z0-9_]+@@|LAPTOP_MONITOR_PLACEHOLDER|\$(TIMEOUT_BIN|HYPRCTL_BIN|SCRIPTS_DIR)' \
            "$stage_path"; then
            log_error "Staged artifact contains an unresolved token: $artifact_id"
            return 1
        fi
        actual_mode=$(stat -c %a -- "$stage_path")
        if [[ "$actual_mode" != "${ARTIFACT_MODE[$artifact_id]#0}" ]]; then
            log_error "Staged artifact has an invalid mode: $artifact_id mode=$actual_mode"
            return 1
        fi
        hash=$(sha256_file "$stage_path")
        printf '%s\t%s\t%s\n' "$hash" \
            "${ARTIFACT_MODE[$artifact_id]}" \
            "${ARTIFACT_RELATIVE_PATH[$artifact_id]}" \
            >> "$transaction_manifest"
    done
}

test_staged_lid_detection() {
    local lid_state

    log_info "Testing lid state detection..."
    if lid_state=$("$(artifact_stage_path lid-monitor)" --print-state); then
        log_success "Lid state detection working: $lid_state"
    else
        log_warning "Could not determine lid state. The service may not work properly."
        log_info "Please check if your system supports ACPI lid events."
    fi
}

prepare_transaction() {
    log_info "Preparing transactional installation..."
    validate_fault_checkpoint
    initialize_transaction
    validate_mv_exchange_support
    # Revalidate user-owned configuration under the installer lock so the
    # snapshot and candidate are based on the same ownership state.
    inspect_session_config
    snapshot_installation_state
    render_staged_artifacts
    render_config_candidate
    validate_staged_artifacts
    test_staged_lid_detection
    log_success "Prepared and validated 11 managed artifacts"
    fault_after prepared
}

assert_managed_destination_unchanged() {
    local artifact_id=$1
    local destination=${ARTIFACT_DESTINATION[$artifact_id]}
    local current_hash current_mode

    if [[ "${ARTIFACT_WAS_PRESENT[$artifact_id]}" == true ]]; then
        if [[ -L "$destination" || ! -f "$destination" ]]; then
            log_error "Managed destination changed during installation: $destination"
            return 1
        fi
        current_hash=$(sha256_file "$destination")
        current_mode=$(stat -c %a -- "$destination")
        if [[ "$current_hash" != "${ARTIFACT_WAS_HASH[$artifact_id]}" || \
            "$current_mode" != "${ARTIFACT_WAS_MODE[$artifact_id]}" ]]; then
            log_error "Managed destination changed during installation: $destination"
            return 1
        fi
    elif [[ -e "$destination" || -L "$destination" ]]; then
        log_error "Managed destination appeared during installation: $destination"
        return 1
    fi
}

maybe_signal_after_publish() {
    local context=$1
    local signal_point=""

    case "$context" in
        install-manifest)
            signal_point=manifest
            ;;
        install-config)
            signal_point=config
            ;;
        install-*)
            signal_point="artifact-${context#install-}"
            ;;
    esac
    if [[ -n "$signal_point" && \
        "${ARCH_LIDSWITCH_TEST_SIGNAL_AFTER_PUBLISH:-}" == "$signal_point" ]]; then
        log_warning "Injecting TERM after publication=$signal_point"
        kill -s TERM "$$"
    fi
}

prepared_publication_sibling=""

prepare_publication_sibling() {
    local source=$1
    local destination=$2
    local mode=$3
    local context=$4
    local directory temporary actual_mode

    prepared_publication_sibling=""
    if ! directory=$(dirname "$destination"); then
        log_error "Could not resolve publication directory: $destination"
        return 1
    fi
    if ! mkdir -p -- "$directory"; then
        log_error "Could not create publication directory: $directory"
        return 1
    fi
    if ! temporary=$(mktemp "$directory/.arch-lidswitch.${destination##*/}.XXXXXX"); then
        log_error "Could not create publication sibling: $destination"
        return 1
    fi
    TEMPORARY_DESTINATIONS+=("$temporary")
    if ! ARCH_LIDSWITCH_ATOMIC_CONTEXT="$context" \
        cp -- "$source" "$temporary"; then
        log_error "Could not copy publication content: $destination"
        rm -f -- "$temporary" || \
            log_error "Could not remove failed publication sibling: $temporary"
        return 1
    fi
    if ! cmp -s -- "$source" "$temporary"; then
        log_error "Publication copy verification failed: $destination"
        rm -f -- "$temporary" || \
            log_error "Could not remove failed publication sibling: $temporary"
        return 1
    fi
    if ! ARCH_LIDSWITCH_ATOMIC_CONTEXT="$context" \
        chmod "$mode" -- "$temporary"; then
        log_error "Could not set publication mode: $destination"
        rm -f -- "$temporary" || \
            log_error "Could not remove failed publication sibling: $temporary"
        return 1
    fi
    if ! actual_mode=$(stat -c %a -- "$temporary") || \
        [[ "$actual_mode" != "${mode#0}" ]]; then
        log_error "Publication mode verification failed: $destination"
        rm -f -- "$temporary" || \
            log_error "Could not remove failed publication sibling: $temporary"
        return 1
    fi
    prepared_publication_sibling=$temporary
}

atomic_publish_file() {
    local source=$1
    local destination=$2
    local mode=$3
    local context=$4
    local temporary actual_mode

    if ! prepare_publication_sibling "$source" "$destination" "$mode" \
        "$context"; then
        return 1
    fi
    temporary=$prepared_publication_sibling
    if ! ARCH_LIDSWITCH_ATOMIC_CONTEXT="$context" \
        mv -fT -- "$temporary" "$destination"; then
        log_error "Could not publish prepared sibling: $destination"
        rm -f -- "$temporary" || \
            log_error "Could not remove failed publication sibling: $temporary"
        return 1
    fi
    if [[ -L "$destination" || ! -f "$destination" ]] || \
        ! cmp -s -- "$source" "$destination" || \
        ! actual_mode=$(stat -c %a -- "$destination") || \
        [[ "$actual_mode" != "${mode#0}" ]]; then
        log_error "Published destination verification failed: $destination"
        return 1
    fi
    maybe_signal_after_publish "$context"
}

record_publication_sibling() {
    local owner=$1
    local owner_id=$2
    local sibling=$3
    local candidate_identity

    if ! candidate_identity=$(stat -c '%d:%i' -- "$sibling"); then
        log_error "Could not identify publication sibling: $sibling"
        return 1
    fi

    case "$owner" in
        artifact)
            ARTIFACT_EXCHANGE_SIBLING[$owner_id]=$sibling
            ARTIFACT_CANDIDATE_IDENTITY[$owner_id]=$candidate_identity
            ;;
        manifest)
            manifest_exchange_sibling=$sibling
            manifest_candidate_identity=$candidate_identity
            ;;
        *)
            log_error "Unknown publication owner: $owner"
            return 1
            ;;
    esac
}

mark_publication_displaced_validated() {
    local owner=$1
    local owner_id=$2

    case "$owner" in
        artifact)
            ARTIFACT_DISPLACED_VALIDATED[$owner_id]=true
            ;;
        manifest)
            manifest_displaced_validated=true
            ;;
        *)
            log_error "Unknown publication owner: $owner"
            return 1
            ;;
    esac
}

compare_and_swap_publish_file() {
    local source=$1
    local destination=$2
    local mode=$3
    local context=$4
    local was_present=$5
    local reference=$6
    local reference_mode=$7
    local owner=$8
    local owner_id=$9
    local temporary actual_mode publish_status=0

    if ! prepare_publication_sibling "$source" "$destination" "$mode" \
        "$context"; then
        return 1
    fi
    temporary=$prepared_publication_sibling
    if ! record_publication_sibling "$owner" "$owner_id" "$temporary"; then
        return 1
    fi

    defer_transaction_signals
    if [[ "$was_present" == true ]]; then
        ARCH_LIDSWITCH_ATOMIC_CONTEXT="$context" \
            mv --exchange --no-copy -T -- "$temporary" "$destination" \
            || publish_status=$?
    else
        ARCH_LIDSWITCH_ATOMIC_CONTEXT="$context" \
            mv --update=none-fail --no-copy -T -- "$temporary" "$destination" \
            || publish_status=$?
    fi
    if (( publish_status != 0 )); then
        log_error "Atomic compare-and-swap publication failed: $destination"
        restore_and_deliver_transaction_signals
        return "$publish_status"
    fi

    if [[ "$was_present" == true ]]; then
        if ! regular_file_matches_reference "$temporary" "$reference" \
            "$reference_mode"; then
            log_error "Destination changed before atomic publication: $destination"
            restore_and_deliver_transaction_signals
            return 1
        fi
        if ! mark_publication_displaced_validated "$owner" "$owner_id"; then
            restore_and_deliver_transaction_signals
            return 1
        fi
    elif [[ -e "$temporary" || -L "$temporary" ]]; then
        log_error "Destination appeared before atomic publication: $destination"
        restore_and_deliver_transaction_signals
        return 1
    fi

    if [[ -L "$destination" || ! -f "$destination" ]] || \
        ! cmp -s -- "$source" "$destination" || \
        ! actual_mode=$(stat -c %a -- "$destination") || \
        [[ "$actual_mode" != "${mode#0}" ]]; then
        log_error "Published destination verification failed: $destination"
        restore_and_deliver_transaction_signals
        return 1
    fi
    maybe_signal_after_publish "$context"
    restore_and_deliver_transaction_signals
}

quiesce_services() {
    local main_preexisting=false resume_preexisting=false
    local observed_main_active observed_resume_active

    if [[ "$main_enablement_state" != not-found || "$main_was_active" == true ]]; then
        main_preexisting=true
    fi
    if [[ "$resume_enablement_state" != not-found || \
        "$resume_was_active" == true ]]; then
        resume_preexisting=true
    fi
    if [[ "$resume_preexisting" == true || "$main_preexisting" == true ]]; then
        service_state_changed=true
    fi
    if [[ "$resume_preexisting" == true ]]; then
        systemctl --user stop lid-resume-monitor.service
    fi
    if [[ "$main_preexisting" == true ]]; then
        systemctl --user stop lid-monitor.service
    fi
    observed_main_active=$(capture_active_state lid-monitor.service)
    observed_resume_active=$(capture_active_state lid-resume-monitor.service)
    if [[ "$observed_main_active" != false || \
        "$observed_resume_active" != false ]]; then
        log_error "Could not quiesce lid services before publication"
        return 1
    fi
    fault_after services-quiesced
}

verify_live_artifact_set() {
    local artifact_id destination expected_hash actual_hash actual_mode

    for artifact_id in "${ARTIFACT_IDS[@]}"; do
        destination=${ARTIFACT_DESTINATION[$artifact_id]}
        expected_hash=$(sha256_file "$(artifact_stage_path "$artifact_id")")
        if [[ -L "$destination" || ! -f "$destination" ]]; then
            log_error "Installed artifact is not a regular file: $destination"
            return 1
        fi
        actual_hash=$(sha256_file "$destination")
        actual_mode=$(stat -c %a -- "$destination")
        if [[ "$actual_hash" != "$expected_hash" || \
            "$actual_mode" != "${ARTIFACT_MODE[$artifact_id]#0}" ]]; then
            log_error "Installed artifact verification failed: $destination"
            return 1
        fi
    done
}

assert_manifest_unchanged() {
    local current_hash current_mode

    if [[ "$manifest_was_present" == true ]]; then
        if [[ -L "$CURRENT_MANIFEST" || ! -f "$CURRENT_MANIFEST" ]]; then
            log_error "Current manifest changed during installation"
            return 1
        fi
        current_hash=$(sha256_file "$CURRENT_MANIFEST")
        current_mode=$(stat -c %a -- "$CURRENT_MANIFEST")
        if [[ "$current_hash" != "$manifest_was_hash" || \
            "$current_mode" != "$manifest_was_mode" ]]; then
            log_error "Current manifest changed during installation"
            return 1
        fi
    elif [[ -e "$CURRENT_MANIFEST" || -L "$CURRENT_MANIFEST" ]]; then
        log_error "Current manifest appeared during installation"
        return 1
    fi
}

publish_config_candidate() {
    local directory temporary actual_mode

    if [[ -L "$HYPRLAND_CONFIG_FILE" || ! -f "$HYPRLAND_CONFIG_FILE" ]]; then
        log_error "Hyprland config changed during installation"
        return 1
    fi
    if ! regular_file_matches_reference "$HYPRLAND_CONFIG_FILE" \
        "$transaction_before_dir/hyprland.lua" "$config_snapshot_mode"; then
        log_error "Hyprland config changed during installation"
        return 1
    fi

    if [[ "$session_config_state" == present ]]; then
        log_info "Hyprland session integration is already present"
        return 0
    fi

    if ! directory=$(dirname "$HYPRLAND_CONFIG_FILE") || \
        ! temporary=$(mktemp "$directory/.arch-lidswitch.hyprland.lua.XXXXXX"); then
        log_error "Could not create Hyprland config exchange sibling"
        return 1
    fi
    config_exchange_sibling=$temporary
    TEMPORARY_DESTINATIONS+=("$temporary")
    if ! ARCH_LIDSWITCH_ATOMIC_CONTEXT=prepare-config-exchange \
        cp -- "$config_candidate" "$temporary" || \
        ! cmp -s -- "$config_candidate" "$temporary" || \
        ! ARCH_LIDSWITCH_ATOMIC_CONTEXT=prepare-config-exchange \
            chmod "$config_snapshot_mode" -- "$temporary" || \
        ! actual_mode=$(stat -c %a -- "$temporary") || \
        [[ "$actual_mode" != "${config_snapshot_mode#0}" ]]; then
        log_error "Could not prepare verified Hyprland config exchange sibling"
        rm -f -- "$temporary" || true
        return 1
    fi
    if ! config_candidate_identity=$(stat -c '%d:%i' -- "$temporary"); then
        log_error "Could not identify Hyprland config exchange candidate"
        rm -f -- "$temporary" || true
        return 1
    fi

    config_publish_intent=true
    defer_transaction_signals
    if ! ARCH_LIDSWITCH_ATOMIC_CONTEXT=install-config \
        mv --exchange --no-copy -T -- "$temporary" "$HYPRLAND_CONFIG_FILE"; then
        log_error "Could not atomically exchange Hyprland config"
        restore_and_deliver_transaction_signals
        return 1
    fi
    maybe_signal_after_publish install-config

    if ! regular_file_matches_reference "$temporary" \
        "$transaction_before_dir/hyprland.lua" "$config_snapshot_mode"; then
        if ! exchange_restore_checked "$HYPRLAND_CONFIG_FILE" "$temporary" \
            "$config_candidate" "$config_snapshot_mode" \
            "$config_candidate_identity" revert-config-exchange; then
            log_error "Could not preserve raced Hyprland config"
            restore_and_deliver_transaction_signals
            return 1
        fi
        config_publish_intent=false
        log_error "Hyprland config changed during installation"
        restore_and_deliver_transaction_signals
        return 1
    fi

    config_displaced_validated=true
    session_config_state=present
    restore_and_deliver_transaction_signals
    log_success "Hyprland session integration added to $HYPRLAND_CONFIG_FILE"
}

import_session_environment() {
    local variable_name
    local -a environment_names=(
        DISPLAY WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP
        QT_QPA_PLATFORMTHEME PATH XDG_DATA_DIRS
    )
    local -a defined_names=()

    for variable_name in "${environment_names[@]}"; do
        if [[ -v "$variable_name" ]]; then
            defined_names+=("$variable_name")
        fi
    done
    systemctl --user import-environment "${defined_names[@]}"
}

capture_expected_runtime_sample() {
    local main_expected=$1
    local resume_expected=$2
    local forbidden_main=$3
    local forbidden_resume=$4
    local status active
    local main_pid="-" main_invocation="-" resume_pid="-"
    local resume_invocation="-"

    if [[ "$main_expected" == true ]]; then
        status=0
        query_service_runtime lid-monitor.service || status=$?
        if (( status != 0 )); then
            return "$status"
        fi
        main_pid=$service_runtime_pid
        main_invocation=$service_runtime_invocation
        if [[ -n "$forbidden_main" && "$forbidden_main" != - && \
            "$main_invocation" == "$forbidden_main" ]]; then
            return 3
        fi
    else
        active=$(capture_active_state lid-monitor.service) || return 1
        if [[ "$active" != false ]]; then
            return 3
        fi
    fi
    if [[ "$resume_expected" == true ]]; then
        status=0
        query_service_runtime lid-resume-monitor.service || status=$?
        if (( status != 0 )); then
            return "$status"
        fi
        resume_pid=$service_runtime_pid
        resume_invocation=$service_runtime_invocation
        if [[ -n "$forbidden_resume" && "$forbidden_resume" != - && \
            "$resume_invocation" == "$forbidden_resume" ]]; then
            return 3
        fi
    else
        active=$(capture_active_state lid-resume-monitor.service) || return 1
        if [[ "$active" != false ]]; then
            return 3
        fi
    fi

    service_sample_fingerprint="$main_expected:$main_pid:$main_invocation|$resume_expected:$resume_pid:$resume_invocation"
    service_sample_main_pid=$main_pid
    service_sample_main_invocation=$main_invocation
    service_sample_resume_pid=$resume_pid
    service_sample_resume_invocation=$resume_invocation
}

maybe_signal_after_service_event() {
    local event=$1

    if [[ "${ARCH_LIDSWITCH_TEST_SIGNAL_AFTER_SERVICE_EVENT:-}" == "$event" && \
        "${service_signal_injected:-false}" != true ]]; then
        service_signal_injected=true
        log_warning "Injecting TERM after service event=$event"
        kill -s TERM "$$"
    fi
}

verify_stable_service_runtime() {
    local phase=$1
    local main_expected=$2
    local resume_expected=$3
    local forbidden_main=$4
    local forbidden_resume=$5
    local previous="" attempt status stable_count=0

    for (( attempt=1; attempt<=8; attempt++ )); do
        status=0
        capture_expected_runtime_sample "$main_expected" "$resume_expected" \
            "$forbidden_main" "$forbidden_resume" || status=$?
        if (( status == 0 )) && [[ "$phase" == restored ]] && \
            { [[ "$main_expected" == true && \
                "$service_sample_main_invocation" == "$main_prior_invocation" ]] || \
            [[ "$resume_expected" == true && \
                "$service_sample_resume_invocation" == "$resume_prior_invocation" ]]; }; then
            status=3
        fi
        case "$status" in
            0)
                if [[ "$service_sample_fingerprint" == "$previous" ]]; then
                    stable_count=$((stable_count + 1))
                else
                    previous=$service_sample_fingerprint
                    stable_count=1
                fi
                if [[ "$phase" == candidate && "$stable_count" == 1 ]]; then
                    maybe_signal_after_service_event health-sample
                fi
                if (( stable_count >= 3 )); then
                    if [[ "$phase" == candidate ]]; then
                        verified_main_pid=$service_sample_main_pid
                        verified_main_invocation=$service_sample_main_invocation
                        verified_resume_pid=$service_sample_resume_pid
                        verified_resume_invocation=$service_sample_resume_invocation
                    fi
                    return 0
                fi
                ;;
            1|2)
                log_error "Service runtime query failed during $phase verification"
                return 1
                ;;
            3)
                previous=""
                stable_count=0
                ;;
            *)
                log_error "Unexpected service runtime status=$status during $phase verification"
                return 1
                ;;
        esac
        if (( attempt < 8 )); then
            sleep 1.1
        fi
    done
    log_error "Service runtime did not stabilize during $phase verification"
    return 1
}

activate_installed_services() {
    service_state_changed=true
    systemctl --user daemon-reload
    fault_after daemon-reloaded

    systemctl --user enable lid-monitor.service
    fault_after main-enabled

    import_session_environment
    fault_after session-imported

    service_restart_intent=true
    systemctl --user restart \
        lid-monitor.service lid-resume-monitor.service
    maybe_signal_after_service_event restart
    fault_after main-started
    fault_after resume-started

    if ! verify_stable_service_runtime candidate true true \
        "$main_prior_invocation" "$resume_prior_invocation"; then
        log_error "Failed to verify fresh lid service generations"
        return 1
    fi
    log_success "Lid monitor and resume services are running fresh verified generations"
    fault_after health-checked
}

apply_transaction() {
    local artifact_id stage_path destination mode was_present
    local reference reference_mode

    quiesce_services
    if [[ "$legacy_default_target_service" == true ]]; then
        service_state_changed=true
        systemctl --user disable --now lid-monitor.service
        fault_after legacy-stopped
    fi

    for artifact_id in "${ARTIFACT_IDS[@]}"; do
        assert_managed_destination_unchanged "$artifact_id"
        stage_path=$(artifact_stage_path "$artifact_id")
        destination=${ARTIFACT_DESTINATION[$artifact_id]}
        mode=${ARTIFACT_MODE[$artifact_id]}
        was_present=${ARTIFACT_WAS_PRESENT[$artifact_id]}
        if [[ "$was_present" == true ]]; then
            reference="$transaction_before_dir/files/${ARTIFACT_RELATIVE_PATH[$artifact_id]}"
            reference_mode=${ARTIFACT_WAS_MODE[$artifact_id]}
        else
            reference=""
            reference_mode=""
        fi
        ARTIFACT_PUBLISH_INTENT[$artifact_id]=true
        compare_and_swap_publish_file "$stage_path" "$destination" "$mode" \
            "install-$artifact_id" "$was_present" "$reference" \
            "$reference_mode" artifact "$artifact_id"
        fault_after "installed-$artifact_id"
    done
    verify_live_artifact_set

    assert_manifest_unchanged
    manifest_publish_intent=true
    compare_and_swap_publish_file "$transaction_manifest" "$CURRENT_MANIFEST" \
        0600 install-manifest "$manifest_was_present" \
        "$transaction_before_dir/current.manifest" "$manifest_was_mode" \
        manifest current-manifest
    fault_after manifest-installed

    publish_config_candidate
    fault_after config-integrated
    activate_installed_services
}

restore_snapshot_file() {
    local source=$1
    local destination=$2
    local mode=$3
    local context=$4

    atomic_publish_file "$source" "$destination" "$mode" "$context"
}

regular_file_matches_reference() {
    local live_file=$1
    local reference_file=$2
    local expected_mode=$3
    local live_mode

    if [[ -L "$live_file" || ! -f "$live_file" || \
        -L "$reference_file" || ! -f "$reference_file" ]]; then
        return 1
    fi
    if ! live_mode=$(stat -c %a -- "$live_file") || \
        [[ "$live_mode" != "${expected_mode#0}" ]]; then
        return 1
    fi
    cmp -s -- "$reference_file" "$live_file"
}

regular_file_has_identity() {
    local path=$1
    local expected_identity=$2
    local actual_identity

    if [[ -z "$expected_identity" || -L "$path" || ! -f "$path" ]] || \
        ! actual_identity=$(stat -c '%d:%i' -- "$path"); then
        return 1
    fi
    [[ "$actual_identity" == "$expected_identity" ]]
}

path_has_lstat_identity() {
    local path=$1
    local expected_identity=$2
    local actual_identity

    if [[ -z "$expected_identity" || \
        ( ! -e "$path" && ! -L "$path" ) ]] || \
        ! actual_identity=$(stat -c '%d:%i:%f' -- "$path"); then
        return 1
    fi
    [[ "$actual_identity" == "$expected_identity" ]]
}

captured_file_hash=""
captured_file_mode=""
captured_file_identity=""

capture_regular_file_state() {
    local path=$1

    captured_file_hash=""
    captured_file_mode=""
    captured_file_identity=""
    if [[ -L "$path" || ! -f "$path" ]] || \
        ! captured_file_hash=$(sha256_file "$path") || \
        ! captured_file_mode=$(stat -c %a -- "$path") || \
        ! captured_file_identity=$(stat -c '%d:%i' -- "$path"); then
        return 1
    fi
}

regular_file_matches_state() {
    local path=$1
    local expected_hash=$2
    local expected_mode=$3
    local expected_identity=$4
    local actual_hash actual_mode

    if ! regular_file_has_identity "$path" "$expected_identity" || \
        ! actual_hash=$(sha256_file "$path") || \
        ! actual_mode=$(stat -c %a -- "$path"); then
        return 1
    fi
    [[ "$actual_hash" == "$expected_hash" && \
        "$actual_mode" == "$expected_mode" ]]
}

exchange_restore_checked() {
    local destination=$1
    local replacement=$2
    local candidate=$3
    local candidate_mode=$4
    local candidate_identity=$5
    local context=$6
    local replacement_hash replacement_mode replacement_identity
    local raced_hash raced_mode raced_identity
    local exchange_status=0 revert_status=0

    if ! capture_regular_file_state "$replacement"; then
        log_error "Could not identify rollback exchange replacement: $replacement"
        return 1
    fi
    replacement_hash=$captured_file_hash
    replacement_mode=$captured_file_mode
    replacement_identity=$captured_file_identity
    if ! regular_file_matches_reference "$destination" "$candidate" \
        "$candidate_mode" || \
        ! regular_file_has_identity "$destination" "$candidate_identity"; then
        log_error "Rollback destination changed before exchange: $destination"
        return 1
    fi

    ARCH_LIDSWITCH_ATOMIC_CONTEXT="$context" \
        mv --exchange --no-copy -T -- "$replacement" "$destination" \
        || exchange_status=$?
    if regular_file_matches_state "$destination" "$replacement_hash" \
        "$replacement_mode" "$replacement_identity" && \
        regular_file_matches_reference "$replacement" "$candidate" \
            "$candidate_mode" && \
        regular_file_has_identity "$replacement" "$candidate_identity"; then
        if (( exchange_status != 0 )); then
            log_warning "Rollback exchange reported status=$exchange_status after completing: $destination"
        fi
        rm -f -- "$replacement" || \
            log_warning "Could not remove rolled-back publication candidate: $replacement"
        return 0
    fi

    if regular_file_matches_state "$destination" "$replacement_hash" \
        "$replacement_mode" "$replacement_identity" && \
        capture_regular_file_state "$replacement"; then
        raced_hash=$captured_file_hash
        raced_mode=$captured_file_mode
        raced_identity=$captured_file_identity
        ARCH_LIDSWITCH_ATOMIC_CONTEXT="${context}-preserve-concurrent" \
            mv --exchange --no-copy -T -- "$replacement" "$destination" \
            || revert_status=$?
        if regular_file_matches_state "$destination" "$raced_hash" \
            "$raced_mode" "$raced_identity" && \
            regular_file_matches_state "$replacement" "$replacement_hash" \
                "$replacement_mode" "$replacement_identity"; then
            if (( revert_status != 0 )); then
                log_warning "Concurrent rollback exchange reported status=$revert_status after completing: $destination"
            fi
            log_error "Rollback destination changed during exchange; concurrent content restored"
            return 1
        fi
    fi
    log_error "Could not atomically restore destination without losing concurrent content: $destination"
    return 1
}

exchange_restore_nonregular_checked() {
    local destination=$1
    local replacement=$2
    local candidate=$3
    local candidate_mode=$4
    local candidate_identity=$5
    local context=$6
    local replacement_identity raced_identity
    local exchange_status=0 revert_status=0

    if [[ ! -e "$replacement" && ! -L "$replacement" ]] || \
        ! replacement_identity=$(stat -c '%d:%i:%f' -- "$replacement"); then
        log_error "Could not identify non-regular rollback replacement: $replacement"
        return 1
    fi
    if ! regular_file_matches_reference "$destination" "$candidate" \
        "$candidate_mode" || \
        ! regular_file_has_identity "$destination" "$candidate_identity"; then
        log_error "Rollback destination changed before non-regular exchange: $destination"
        return 1
    fi

    ARCH_LIDSWITCH_ATOMIC_CONTEXT="$context" \
        mv --exchange --no-copy -T -- "$replacement" "$destination" \
        || exchange_status=$?
    if path_has_lstat_identity "$destination" "$replacement_identity" && \
        regular_file_matches_reference "$replacement" "$candidate" \
            "$candidate_mode" && \
        regular_file_has_identity "$replacement" "$candidate_identity"; then
        if (( exchange_status != 0 )); then
            log_warning "Non-regular rollback exchange reported status=$exchange_status after completing: $destination"
        fi
        rm -f -- "$replacement" || \
            log_warning "Could not remove rolled-back publication candidate: $replacement"
        return 0
    fi

    if path_has_lstat_identity "$destination" "$replacement_identity" && \
        [[ -e "$replacement" || -L "$replacement" ]] && \
        raced_identity=$(stat -c '%d:%i:%f' -- "$replacement"); then
        ARCH_LIDSWITCH_ATOMIC_CONTEXT="${context}-preserve-concurrent" \
            mv --exchange --no-copy -T -- "$replacement" "$destination" \
            || revert_status=$?
        if path_has_lstat_identity "$destination" "$raced_identity" && \
            path_has_lstat_identity "$replacement" "$replacement_identity"; then
            if (( revert_status != 0 )); then
                log_warning "Concurrent non-regular exchange reported status=$revert_status after completing: $destination"
            fi
            log_error "Rollback destination changed during non-regular exchange; concurrent path restored"
            return 1
        fi
    fi
    log_error "Could not restore non-regular concurrent destination: $destination"
    return 1
}

rollback_present_cas_publish() {
    local destination=$1
    local candidate=$2
    local candidate_mode=$3
    local snapshot=$4
    local snapshot_mode=$5
    local sibling=$6
    local candidate_identity=$7
    local displaced_validated=$8
    local context=$9
    local fallback_sibling

    if regular_file_matches_reference "$destination" "$snapshot" \
        "$snapshot_mode"; then
        return 0
    fi
    if ! regular_file_matches_reference "$destination" "$candidate" \
        "$candidate_mode" || \
        ! regular_file_has_identity "$destination" "$candidate_identity"; then
        log_error "Cannot safely restore concurrently changed destination: $destination"
        return 1
    fi

    if [[ -n "$sibling" && ( -e "$sibling" || -L "$sibling" ) ]]; then
        if [[ ! -L "$sibling" && -f "$sibling" ]]; then
            if exchange_restore_checked "$destination" "$sibling" "$candidate" \
                "$candidate_mode" "$candidate_identity" "$context"; then
                return 0
            fi
        else
            if exchange_restore_nonregular_checked "$destination" "$sibling" \
                "$candidate" "$candidate_mode" "$candidate_identity" \
                "$context"; then
                return 0
            fi
        fi
        if [[ -e "$sibling" || -L "$sibling" ]]; then
            return 1
        fi
    fi

    if [[ "$displaced_validated" == true ]] && \
        regular_file_matches_reference "$destination" "$candidate" \
            "$candidate_mode" && \
        regular_file_has_identity "$destination" "$candidate_identity"; then
        if ! prepare_publication_sibling "$snapshot" "$destination" \
            "$snapshot_mode" "${context}-fallback"; then
            return 1
        fi
        fallback_sibling=$prepared_publication_sibling
        exchange_restore_checked "$destination" "$fallback_sibling" \
            "$candidate" "$candidate_mode" "$candidate_identity" \
            "${context}-fallback"
        return $?
    fi
    log_error "Displaced destination is unavailable for safe restoration: $destination"
    return 1
}

rollback_absent_cas_publish() {
    local destination=$1
    local candidate=$2
    local candidate_mode=$3
    local sibling=$4
    local candidate_identity=$5
    local context=$6
    local directory quarantine_dir quarantine
    local move_status=0 restore_status=0 captured_hash captured_mode
    local captured_identity restored_hash restored_mode

    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
        return 0
    fi
    if ! regular_file_matches_reference "$destination" "$candidate" \
        "$candidate_mode" || \
        ! regular_file_has_identity "$destination" "$candidate_identity"; then
        if [[ -n "$sibling" ]] && \
            regular_file_matches_reference "$sibling" "$candidate" \
                "$candidate_mode" && \
            regular_file_has_identity "$sibling" "$candidate_identity"; then
            rm -f -- "$sibling" || return 1
            return 0
        fi
        log_error "Cannot safely remove concurrently changed destination: $destination"
        return 1
    fi

    if ! directory=$(dirname "$destination") || \
        ! quarantine_dir=$(mktemp -d \
            "$directory/.arch-lidswitch.rollback-quarantine.XXXXXX") || \
        ! chmod 0700 -- "$quarantine_dir"; then
        log_error "Could not prepare rollback quarantine: $destination"
        return 1
    fi
    quarantine="$quarantine_dir/candidate"
    ARCH_LIDSWITCH_ATOMIC_CONTEXT="$context" \
        mv --update=none-fail --no-copy -T -- "$destination" "$quarantine" \
        || move_status=$?

    if regular_file_has_identity "$quarantine" "$candidate_identity" && \
        regular_file_matches_reference "$quarantine" "$candidate" \
            "$candidate_mode" && \
        [[ ! -e "$destination" && ! -L "$destination" ]]; then
        if (( move_status != 0 )); then
            log_warning "Rollback quarantine move reported status=$move_status after completing: $destination"
        fi
        rm -f -- "$quarantine" || return 1
        rmdir -- "$quarantine_dir" || return 1
        return 0
    fi

    if [[ ! -L "$quarantine" && -f "$quarantine" ]]; then
        captured_hash=$(sha256_file "$quarantine") || return 1
        captured_mode=$(stat -c %a -- "$quarantine") || return 1
        captured_identity=$(stat -c '%d:%i' -- "$quarantine") || return 1
        ARCH_LIDSWITCH_ATOMIC_CONTEXT="${context}-restore-concurrent" \
            mv --update=none-fail --no-copy -T -- "$quarantine" \
                "$destination" || restore_status=$?
        restored_hash=$(sha256_file "$destination") || restored_hash=""
        restored_mode=$(stat -c %a -- "$destination") || restored_mode=""
        if regular_file_has_identity "$destination" "$captured_identity" && \
            [[ "$restored_hash" == "$captured_hash" && \
            "$restored_mode" == "$captured_mode" ]] && \
            [[ ! -e "$quarantine" && ! -L "$quarantine" ]]; then
            if (( restore_status != 0 )); then
                log_warning "Concurrent rollback restoration reported status=$restore_status after completing: $destination"
            fi
            rmdir -- "$quarantine_dir" || return 1
            return 0
        fi
        log_error "Concurrent destination retained in rollback quarantine: $quarantine"
        return 1
    fi

    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
        rmdir -- "$quarantine_dir" || return 1
        return 0
    fi
    rmdir -- "$quarantine_dir" 2>/dev/null || true
    log_error "Could not quarantine newly published destination: $destination"
    return 1
}

rollback_managed_publish() {
    local artifact_id=$1
    local destination=${ARTIFACT_DESTINATION[$artifact_id]}
    local candidate snapshot sibling candidate_identity

    if [[ "${ARTIFACT_PUBLISH_INTENT[$artifact_id]:-false}" != true ]]; then
        return 0
    fi
    candidate=$(artifact_stage_path "$artifact_id")
    sibling=${ARTIFACT_EXCHANGE_SIBLING[$artifact_id]:-}
    candidate_identity=${ARTIFACT_CANDIDATE_IDENTITY[$artifact_id]:-}
    if [[ "${ARTIFACT_WAS_PRESENT[$artifact_id]}" == true ]]; then
        snapshot="$transaction_before_dir/files/${ARTIFACT_RELATIVE_PATH[$artifact_id]}"
        rollback_present_cas_publish "$destination" "$candidate" \
            "${ARTIFACT_MODE[$artifact_id]}" "$snapshot" \
            "${ARTIFACT_WAS_MODE[$artifact_id]}" "$sibling" \
            "$candidate_identity" \
            "${ARTIFACT_DISPLACED_VALIDATED[$artifact_id]:-false}" \
            "rollback-$artifact_id"
        return $?
    else
        rollback_absent_cas_publish "$destination" "$candidate" \
            "${ARTIFACT_MODE[$artifact_id]}" "$sibling" \
            "$candidate_identity" "rollback-$artifact_id"
        return $?
    fi
}

rollback_manifest_publish() {
    if [[ "$manifest_publish_intent" != true ]]; then
        return 0
    fi
    if [[ "$manifest_was_present" == true ]]; then
        rollback_present_cas_publish "$CURRENT_MANIFEST" \
            "$transaction_manifest" 0600 \
            "$transaction_before_dir/current.manifest" "$manifest_was_mode" \
            "$manifest_exchange_sibling" "$manifest_candidate_identity" \
            "$manifest_displaced_validated" rollback-manifest
        return $?
    else
        rollback_absent_cas_publish "$CURRENT_MANIFEST" \
            "$transaction_manifest" 0600 "$manifest_exchange_sibling" \
            "$manifest_candidate_identity" rollback-manifest
        return $?
    fi
}

rollback_config_publish() {
    if [[ "$config_publish_intent" != true ]]; then
        return 0
    fi
    rollback_present_cas_publish "$HYPRLAND_CONFIG_FILE" \
        "$config_candidate" "$config_snapshot_mode" \
        "$transaction_before_dir/hyprland.lua" "$config_snapshot_mode" \
        "$config_exchange_sibling" "$config_candidate_identity" \
        "$config_displaced_validated" rollback-config
}

rollback_transaction() {
    local rollback_status=0 content_restore_status=0 service_restore_status=0
    local service_stop_failed=false
    local service_recovery_required=false
    local main_unit_may_exist=false resume_unit_may_exist=false
    local artifact_id destination
    local index
    local -a restore_units=()

    log_warning "Rolling back incomplete installation transaction=$transaction_id"

    if [[ "$service_state_changed" == true || \
        "$service_restart_intent" == true || \
        "${ARTIFACT_PUBLISH_INTENT[main-service]:-false}" == true || \
        "${ARTIFACT_PUBLISH_INTENT[resume-service]:-false}" == true ]]; then
        service_recovery_required=true
    fi
    if [[ "$main_enablement_state" != not-found || \
        "$main_was_active" == true || -e "$SERVICE_FILE" || \
        -L "$SERVICE_FILE" ]]; then
        main_unit_may_exist=true
    fi
    if [[ "$resume_enablement_state" != not-found || \
        "$resume_was_active" == true || -e "$RESUME_SERVICE_FILE" || \
        -L "$RESUME_SERVICE_FILE" ]]; then
        resume_unit_may_exist=true
    fi

    if [[ "$service_recovery_required" == true ]]; then
        if [[ "$resume_unit_may_exist" == true ]]; then
            systemctl --user stop lid-resume-monitor.service >/dev/null 2>&1 \
                || service_stop_failed=true
        fi
        if [[ "$main_unit_may_exist" == true ]]; then
            systemctl --user stop lid-monitor.service >/dev/null 2>&1 \
                || service_stop_failed=true
        fi
        if [[ "$service_stop_failed" == true ]]; then
            log_error "Rollback cannot safely replace files while a service may still be running"
            log_error "Rollback incomplete; recovery snapshot retained at $transaction_before_dir"
            return 1
        fi
        if [[ "$(capture_active_state lid-monitor.service)" != false || \
            "$(capture_active_state lid-resume-monitor.service)" != false ]]; then
            log_error "Rollback cannot replace files until both services are inactive"
            log_error "Rollback incomplete; recovery snapshot retained at $transaction_before_dir"
            return 1
        fi
        if [[ "$main_unit_may_exist" == true ]]; then
            systemctl --user disable lid-monitor.service >/dev/null 2>&1 \
                || service_restore_status=1
        fi
    fi

    for (( index=${#ARTIFACT_IDS[@]} - 1; index >= 0; index-- )); do
        artifact_id=${ARTIFACT_IDS[$index]}
        rollback_managed_publish "$artifact_id" || content_restore_status=1
    done

    rollback_manifest_publish || content_restore_status=1

    rollback_config_publish || content_restore_status=1

    if (( content_restore_status != 0 )); then
        if [[ "$service_recovery_required" == true ]]; then
            systemctl --user stop lid-resume-monitor.service >/dev/null 2>&1 || true
            systemctl --user stop lid-monitor.service >/dev/null 2>&1 || true
            if [[ "$(capture_active_state lid-monitor.service)" != false || \
                "$(capture_active_state lid-resume-monitor.service)" != false ]]; then
                log_error "Rollback failure left a lid service active"
            fi
            log_error "Services remain stopped because installation content could not be restored coherently"
        fi
        log_error "Rollback incomplete; recovery snapshot retained at $transaction_before_dir"
        return 1
    fi

    if [[ "$service_recovery_required" == true ]]; then
        if ! systemctl --user daemon-reload >/dev/null 2>&1; then
            log_error "Could not reload restored user-systemd unit definitions"
            service_restore_status=1
        else
            case "$main_enablement_state" in
                enabled)
                    systemctl --user enable lid-monitor.service >/dev/null 2>&1 \
                        || service_restore_status=1
                    ;;
                disabled)
                    systemctl --user disable lid-monitor.service >/dev/null 2>&1 \
                        || service_restore_status=1
                    ;;
                not-found)
                    ;;
                *)
                    service_restore_status=1
                    ;;
            esac
        fi
        if (( service_restore_status == 0 )) && \
            { [[ "$(capture_enablement_state lid-monitor.service main)" != \
                "$main_enablement_state" ]] || \
            [[ "$(capture_enablement_state lid-resume-monitor.service resume)" != \
                "$resume_enablement_state" ]]; }; then
            log_error "Could not verify prior service enablement state"
            service_restore_status=1
        fi
        if (( service_restore_status == 0 )); then
            if [[ "$main_was_active" == true ]]; then
                restore_units+=(lid-monitor.service)
            fi
            if [[ "$resume_was_active" == true ]]; then
                restore_units+=(lid-resume-monitor.service)
            fi
            if (( ${#restore_units[@]} > 0 )); then
                service_restart_intent=true
                systemctl --user restart "${restore_units[@]}" \
                    >/dev/null 2>&1 || service_restore_status=1
            fi
            if [[ "$main_was_active" != true ]]; then
                systemctl --user stop lid-monitor.service >/dev/null 2>&1 || true
            fi
            if [[ "$resume_was_active" != true ]]; then
                systemctl --user stop lid-resume-monitor.service >/dev/null 2>&1 || true
            fi
            if (( service_restore_status == 0 )) && \
                ! verify_stable_service_runtime restored \
                    "$main_was_active" "$resume_was_active" \
                    "$verified_main_invocation" \
                    "$verified_resume_invocation"; then
                log_error "Could not verify restored service generations"
                service_restore_status=1
            fi
        fi
        if (( service_restore_status != 0 )); then
            systemctl --user stop lid-resume-monitor.service >/dev/null 2>&1 || true
            systemctl --user stop lid-monitor.service >/dev/null 2>&1 || true
            log_error "Services remain stopped because restored service state could not be verified"
        fi
    fi

    rollback_status=$service_restore_status

    if (( rollback_status == 0 )); then
        for destination in "${TEMPORARY_DESTINATIONS[@]}"; do
            rm -f -- "$destination" || true
        done
        if [[ "$scripts_dir_existed" == false ]]; then
            rmdir -- "$SCRIPTS_DIR" 2>/dev/null || true
        fi
        if [[ "$session_module_dir_existed" == false ]]; then
            rmdir -- "$SESSION_MODULE_DIR" 2>/dev/null || true
        fi
        if [[ "$systemd_user_dir_existed" == false ]]; then
            rmdir -- "$SYSTEMD_USER_DIR" 2>/dev/null || true
        fi
        if [[ "$backup_promoted_uncommitted" == true ]]; then
            if ! rm -rf -- "$transaction_before_dir" || \
                [[ -e "$transaction_before_dir" || \
                -L "$transaction_before_dir" ]]; then
                log_error "Could not remove rejected promoted rollback snapshot: $transaction_before_dir"
                rollback_status=1
            else
                backup_promoted_uncommitted=false
            fi
        fi
        if (( rollback_status == 0 )); then
            if ! rm -rf -- "$transaction_dir" || \
                [[ -e "$transaction_dir" || -L "$transaction_dir" ]]; then
                log_error "Could not remove completed rollback transaction: $transaction_dir"
                rollback_status=1
            else
                transaction_active=false
                log_success "Previous installation state restored"
            fi
        fi
    fi
    if (( rollback_status != 0 )); then
        log_error "Rollback incomplete; recovery snapshot retained at $transaction_before_dir"
    fi
    return "$rollback_status"
}

append_backup_integrity_entry() {
    local root=$1
    local relative=$2
    local manifest=$3
    local path="$root/$relative"
    local hash mode

    if [[ -L "$path" || ! -f "$path" ]] || \
        ! hash=$(sha256_file "$path") || \
        ! mode=$(stat -c %a -- "$path"); then
        log_error "Rollback snapshot entry is unavailable: $relative"
        return 1
    fi
    printf 'file\t%s\t%s\t%s\n' "$hash" "$mode" "$relative" \
        >> "$manifest"
}

append_backup_integrity_directory() {
    local root=$1
    local relative=$2
    local manifest=$3
    local path identity mode

    if [[ "$relative" == . ]]; then
        path=$root
    else
        path="$root/$relative"
    fi
    if [[ -L "$path" || ! -d "$path" ]] || \
        ! identity=$(stat -c '%d:%i' -- "$path") || \
        ! mode=$(stat -c %a -- "$path"); then
        log_error "Rollback snapshot directory is unavailable: $relative"
        return 1
    fi
    printf 'directory\t%s\t%s\t%s\n' "$identity" "$mode" "$relative" \
        >> "$manifest"
}

write_backup_integrity_manifest() {
    local root=$1
    local manifest=$2
    local artifact_id relative parent
    local -A required_directories=([.]=true [files]=true)

    if [[ -L "$root" || ! -d "$root" || \
        -L "$root/files" || ! -d "$root/files" ]]; then
        log_error "Rollback snapshot directories are incomplete"
        return 1
    fi
    if ! : > "$manifest" || ! chmod 0600 -- "$manifest"; then
        log_error "Could not create rollback snapshot integrity manifest"
        return 1
    fi
    for artifact_id in "${ARTIFACT_IDS[@]}"; do
        if [[ "${ARTIFACT_WAS_PRESENT[$artifact_id]}" == true ]]; then
            relative="files/${ARTIFACT_RELATIVE_PATH[$artifact_id]}"
            parent=${relative%/*}
            while [[ -n "$parent" && "$parent" != "$relative" ]]; do
                required_directories[$parent]=true
                if [[ "$parent" != */* ]]; then
                    break
                fi
                parent=${parent%/*}
            done
        fi
    done
    for relative in "${!required_directories[@]}"; do
        append_backup_integrity_directory "$root" "$relative" "$manifest" \
            || return 1
    done

    for relative in snapshot.tsv service-state hyprland.lua; do
        append_backup_integrity_entry "$root" "$relative" "$manifest" \
            || return 1
    done
    if [[ "$manifest_was_present" == true ]]; then
        append_backup_integrity_entry "$root" current.manifest "$manifest" \
            || return 1
    fi
    for artifact_id in "${ARTIFACT_IDS[@]}"; do
        if [[ "${ARTIFACT_WAS_PRESENT[$artifact_id]}" == true ]]; then
            relative="files/${ARTIFACT_RELATIVE_PATH[$artifact_id]}"
            append_backup_integrity_entry "$root" "$relative" "$manifest" \
                || return 1
        fi
    done
}

verify_backup_integrity_manifest() {
    local root=$1
    local manifest=$2
    local kind expected_fingerprint expected_mode relative path
    local actual_fingerprint actual_mode
    local entries=0

    if [[ -L "$root" || ! -d "$root" || \
        -L "$root/files" || ! -d "$root/files" ]]; then
        return 1
    fi
    while IFS=$'\t' read -r kind expected_fingerprint expected_mode relative; do
        entries=$((entries + 1))
        if [[ -z "$relative" || "$relative" == /* || \
            "$relative" == *'..'* ]]; then
            return 1
        fi
        if [[ "$relative" == . ]]; then
            path=$root
        else
            path="$root/$relative"
        fi
        case "$kind" in
            directory)
                if [[ -L "$path" || ! -d "$path" ]] || \
                    ! actual_fingerprint=$(stat -c '%d:%i' -- "$path"); then
                    return 1
                fi
                ;;
            file)
                if [[ -L "$path" || ! -f "$path" ]] || \
                    ! actual_fingerprint=$(sha256_file "$path"); then
                    return 1
                fi
                ;;
            *)
                return 1
                ;;
        esac
        if ! actual_mode=$(stat -c %a -- "$path") || \
            [[ "$actual_fingerprint" != "$expected_fingerprint" || \
            "$actual_mode" != "$expected_mode" ]]; then
            return 1
        fi
    done < "$manifest"
    (( entries >= 5 ))
}

revalidate_candidate_runtime_identity() {
    local status=0

    capture_expected_runtime_sample true true "" "" || status=$?
    if (( status != 0 )) || \
        [[ "$service_sample_main_pid" != "$verified_main_pid" || \
        "$service_sample_main_invocation" != "$verified_main_invocation" || \
        "$service_sample_resume_pid" != "$verified_resume_pid" || \
        "$service_sample_resume_invocation" != "$verified_resume_invocation" ]]; then
        log_error "Candidate service generation changed before transaction commit"
        return 1
    fi
}

commit_transaction() {
    local backup_destination old_backup destination
    local promotion_status=0
    local backup_source_identity backup_destination_identity backup_mode
    local backup_integrity_manifest backup_integrity_hash actual_integrity_hash
    local -a backups=()

    backup_destination="$BACKUPS_DIR/$transaction_id"
    backup_integrity_manifest="$transaction_dir/backup.integrity"
    if ! write_backup_integrity_manifest "$transaction_before_dir" \
        "$backup_integrity_manifest" || \
        ! backup_integrity_hash=$(sha256_file "$backup_integrity_manifest"); then
        log_error "Could not fingerprint the complete rollback snapshot"
        return 1
    fi
    if [[ -L "$transaction_before_dir" || ! -d "$transaction_before_dir" ]] || \
        ! backup_source_identity=$(stat -c '%d:%i' -- "$transaction_before_dir") || \
        ! backup_mode=$(stat -c %a -- "$transaction_before_dir") || \
        [[ "$backup_mode" != 700 ]] || \
        [[ -L "$transaction_before_dir/snapshot.tsv" || \
        ! -f "$transaction_before_dir/snapshot.tsv" || \
        -L "$transaction_before_dir/service-state" || \
        ! -f "$transaction_before_dir/service-state" || \
        -L "$transaction_before_dir/hyprland.lua" || \
        ! -f "$transaction_before_dir/hyprland.lua" || \
        -L "$transaction_before_dir/files" || \
        ! -d "$transaction_before_dir/files" ]]; then
        log_error "Pre-install rollback snapshot is incomplete before promotion"
        return 1
    fi
    defer_transaction_signals
    ARCH_LIDSWITCH_ATOMIC_CONTEXT=commit-backup \
        mv -T -- "$transaction_before_dir" "$backup_destination" \
        || promotion_status=$?
    backup_destination_identity=$(stat -c '%d:%i' -- "$backup_destination" 2>/dev/null) \
        || backup_destination_identity=""
    backup_mode=$(stat -c %a -- "$backup_destination" 2>/dev/null) \
        || backup_mode=""
    if [[ ! -e "$transaction_before_dir" && \
        ! -L "$transaction_before_dir" && \
        -d "$backup_destination" && ! -L "$backup_destination" && \
        "$backup_destination_identity" == "$backup_source_identity" && \
        "$backup_mode" == 700 ]]; then
        transaction_before_dir="$backup_destination"
        backup_promoted_uncommitted=true
    else
        log_error "Could not verify promoted rollback snapshot identity"
        restore_and_deliver_transaction_signals
        if (( promotion_status != 0 )); then
            return "$promotion_status"
        fi
        return 1
    fi
    actual_integrity_hash=$(sha256_file "$backup_integrity_manifest") \
        || actual_integrity_hash=""
    if [[ "$actual_integrity_hash" != "$backup_integrity_hash" ]] || \
        ! verify_backup_integrity_manifest "$backup_destination" \
            "$backup_integrity_manifest"; then
        log_error "Promoted rollback snapshot failed complete integrity verification"
        restore_and_deliver_transaction_signals
        return 1
    fi
    if (( promotion_status != 0 )); then
        log_warning "Backup promotion reported status=$promotion_status after completing; reconciled committed destination"
    fi
    if ! revalidate_candidate_runtime_identity; then
        restore_and_deliver_transaction_signals
        return 1
    fi
    if [[ "${ARCH_LIDSWITCH_TEST_SIGNAL_AFTER_PUBLISH:-}" == \
        backup-promotion ]]; then
        log_warning "Injecting TERM after backup promotion"
        kill -s TERM "$$"
    fi
    transaction_committed=true
    transaction_active=false
    backup_promoted_uncommitted=false

    for destination in "${TEMPORARY_DESTINATIONS[@]}"; do
        rm -f -- "$destination" || \
            log_warning "Could not remove committed publication sibling: $destination"
    done
    rm -rf -- "$transaction_stage_dir" "$transaction_manifest" \
        "$config_candidate" "$config_exchange_sibling" || \
        log_warning "Could not remove committed transaction staging files"
    rm -rf -- "$transaction_dir" || \
        log_warning "Could not remove committed transaction directory"

    shopt -s nullglob
    backups=("$BACKUPS_DIR"/*)
    shopt -u nullglob
    for old_backup in "${backups[@]}"; do
        if [[ "$old_backup" != "$backup_destination" ]]; then
            rm -rf -- "$old_backup" || \
                log_warning "Could not prune old rollback set: $old_backup"
        fi
    done
    chmod 0700 -- "$backup_destination" || \
        log_warning "Could not reaffirm rollback-set permissions"
    if [[ -n "$transaction_lock_fd" ]]; then
        flock -u "$transaction_lock_fd" || true
        exec {transaction_lock_fd}>&-
        transaction_lock_fd=""
    fi
    log_success "Committed artifact transaction; rollback set: $backup_destination"
    restore_and_deliver_transaction_signals
}

activate_session_target_after_commit() {
    if ! "$SESSION_BRIDGE" start; then
        log_warning "Installed services are healthy, but current-session target activation failed"
        log_info "The Hyprland session hook will retry target activation on the next session"
    fi
}

report_committed_runtime() {
    local manifest_hash

    if ! manifest_hash=$(sha256_file "$CURRENT_MANIFEST"); then
        log_error "Committed installation manifest could not be hashed"
        return 1
    fi
    printf 'Active installation manifest_sha256=%s\n' "$manifest_hash"
    printf 'Active service unit=lid-monitor.service main_pid=%s invocation_id=%s\n' \
        "$verified_main_pid" "$verified_main_invocation"
    printf 'Active service unit=lid-resume-monitor.service main_pid=%s invocation_id=%s\n' \
        "$verified_resume_pid" "$verified_resume_invocation"
}

handle_installer_exit() {
    local status=$?

    trap - EXIT
    trap '' INT TERM
    if [[ "$transaction_active" == true && "$transaction_committed" != true ]]; then
        set +e
        set +u
        if ! rollback_transaction; then
            status=1
        elif (( status == 0 )); then
            status=1
        fi
    fi
    if [[ -n "$transaction_lock_fd" ]]; then
        flock -u "$transaction_lock_fd" >/dev/null 2>&1 || true
        exec {transaction_lock_fd}>&-
    fi
    exit "$status"
}

detect_legacy_default_target_service() {
    if [[ -f "$SERVICE_FILE" ]] && grep -Fqx 'WantedBy=default.target' "$SERVICE_FILE"; then
        legacy_default_target_service=true
    fi
}

# Print final instructions
print_final_instructions() {
    echo
    log_success "Installation completed successfully!"
    echo
    echo -e "${BLUE}What was installed:${NC}"
    echo "  • Lid state observer: $SCRIPTS_DIR/lid-state.sh"
    echo "  • Monitor state module: $MONITOR_STATE_FILE"
    echo "  • Lid switch handler script: $SCRIPTS_DIR/lid-switch.sh"
    echo "  • Lid switch doctor: $DOCTOR_FILE"
    echo "  • Lid monitor daemon: $SCRIPTS_DIR/lid-monitor.sh"
    echo "  • Resume event listener: $RESUME_MONITOR_FILE"
    echo "  • Hyprland session bridge: $SESSION_BRIDGE"
    echo "  • Hyprland session module: $SESSION_MODULE"
    echo "  • Hyprland session target: hyprland-session.target"
    echo "  • Systemd user service: lid-monitor.service"
    echo "  • Systemd resume service: lid-resume-monitor.service"
    echo
    echo -e "${BLUE}How it works:${NC}"
    echo "  • When lid closes + an enabled external output: laptop screen turns off"
    echo "  • When lid closes without an enabled external output: systemd-logind owns the power action"
    echo "  • When lid opens: laptop screen turns back on (dual monitor setup)"
    echo "  • Awake output activation and hotplug changes are reconciled automatically"
    echo "  • Resume events wait for stable lid and output topology before reconciliation"
    echo "  • Service starts automatically on login without changing the initial layout"
    echo
    echo -e "${BLUE}Useful commands:${NC}"
    echo "  • Check service status: systemctl --user status lid-monitor.service"
    echo "  • Check lid power policy: $DOCTOR_FILE"
    echo "  • Follow service logs: journalctl --user -u lid-monitor.service -f -o cat"
    echo "  • View current-boot logs: journalctl --user -u lid-monitor.service -b -o cat"
    echo "  • Stop service: systemctl --user stop lid-monitor.service"
    echo "  • Restart service: systemctl --user restart lid-monitor.service"
    echo
    echo -e "${GREEN}Run $DOCTOR_FILE to re-check lid power ownership.${NC}"
}

################################################################################
# Main Installation Process
################################################################################

main() {
    echo "=================================="
    echo "Hyprland Lid Switch Installer"
    echo "=================================="
    echo

    # Pre-installation checks
    log_info "Performing pre-installation checks..."
    check_hyprland
    inspect_session_config
    check_resume_runtime_dependencies
    check_transaction_dependencies
    check_lid_power_policy
    check_hyprland_capabilities

    # Detect monitors
    log_info "Detecting Monitors..."
    detect_monitors
    
    prepare_transaction
    apply_transaction
    commit_transaction
    report_committed_runtime

    # Target activation can affect the wider graphical session, so it occurs
    # only after the file/service transaction is durably committed.
    activate_session_target_after_commit
    
    # Print final instructions
    print_final_instructions
}

# Handle interruption and every incomplete transaction through one rollback path.
trap handle_installer_exit EXIT
trap 'log_error "Installation interrupted"; exit 130' INT
trap 'log_error "Installation terminated"; exit 143' TERM

# Run main function
main "$@"
