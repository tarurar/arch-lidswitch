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

SESSION_CONFIG_BEGIN='-- BEGIN arch-lidswitch managed session integration'
SESSION_CONFIG_END='-- END arch-lidswitch managed session integration'

# Global variables
laptop_monitor=""
HYPRCTL_BIN=""
JQ_BIN=""
TIMEOUT_BIN=""
HYPRLAND_MONITORS_JSON=""
session_config_state=""
legacy_default_target_service=false

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

integrate_session_config() {
    local candidate

    if [[ "$session_config_state" == "present" ]]; then
        log_info "Hyprland session integration is already present"
        return 0
    fi

    candidate=$(mktemp "$HYPRLAND_CONFIG_FILE.arch-lidswitch.XXXXXX")
    if ! cp -p -- "$HYPRLAND_CONFIG_FILE" "$candidate"; then
        rm -f -- "$candidate"
        return 1
    fi

    {
        printf '\n'
        write_session_config_block
    } >> "$candidate"

    mv -- "$candidate" "$HYPRLAND_CONFIG_FILE"
    session_config_state="present"
    log_success "Hyprland session integration added to $HYPRLAND_CONFIG_FILE"
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

# Create directories if they don't exist
create_directories() {
    log_info "Creating necessary directories..."
    
    mkdir -p "$SCRIPTS_DIR"
    mkdir -p "$SESSION_MODULE_DIR"
    mkdir -p "$SYSTEMD_USER_DIR"
    
    log_success "Directories created"
}

# Install the helper that orders environment import before session activation
install_session_bridge() {
    log_info "Installing Hyprland session bridge..."

    cat > "$SESSION_BRIDGE" << 'EOF'
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

    chmod +x "$SESSION_BRIDGE"
    log_success "Hyprland session bridge installed at $SESSION_BRIDGE"
}

# Install the isolated Lua event handlers next to hyprland.lua
install_session_module() {
    log_info "Installing Hyprland session module..."

    cat > "$SESSION_MODULE" << 'EOF'
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

    log_success "Hyprland session module installed at $SESSION_MODULE"
}

# Install the compositor-specific target that owns graphical-session.target
install_session_target() {
    log_info "Installing Hyprland session target..."

    cat > "$SESSION_TARGET_FILE" << 'EOF'
[Unit]
Description=Hyprland session
BindsTo=graphical-session.target
Wants=graphical-session-pre.target
After=graphical-session-pre.target
PropagatesStopTo=graphical-session.target
EOF

    log_success "Hyprland session target installed at $SESSION_TARGET_FILE"
}

# Install the shared lid state observer
install_lid_state_script() {
    log_info "Installing shared lid state observer..."

    cat > "$SCRIPTS_DIR/lid-state.sh" << 'EOF'
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

    chmod +x "$SCRIPTS_DIR/lid-state.sh"

    log_success "Lid state observer installed at $SCRIPTS_DIR/lid-state.sh"
}

install_monitor_state_script() {
    log_info "Installing monitor state module..."

    cat > "$MONITOR_STATE_FILE" << 'EOF'
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

    chmod +x "$MONITOR_STATE_FILE"
    log_success "Monitor state module installed at $MONITOR_STATE_FILE"
}

# Install the lid switch script
install_lid_switch_script() {
    local laptop_monitor="$1"
    
    log_info "Installing lid switch script..."
    
    cat > "$SCRIPTS_DIR/lid-switch.sh" << 'EOF'
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

    # Replace placeholder with actual laptop monitor
    sed -i "s/LAPTOP_MONITOR_PLACEHOLDER/$laptop_monitor/g" "$SCRIPTS_DIR/lid-switch.sh"
    
    # Make script executable
    chmod +x "$SCRIPTS_DIR/lid-switch.sh"
    
    log_success "Lid switch script installed at $SCRIPTS_DIR/lid-switch.sh"
}

install_lid_switch_doctor() {
    log_info "Installing lid switch doctor..."

    cat > "$DOCTOR_FILE" << 'EOF'
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

    chmod +x "$DOCTOR_FILE"
    log_success "Lid switch doctor installed at $DOCTOR_FILE"
}

# Install the lid monitor script
install_lid_monitor_script() {
    log_info "Installing lid monitor script..."
    
    cat > "$SCRIPTS_DIR/lid-monitor.sh" << 'EOF'
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

    sed -i "s/LAPTOP_MONITOR_PLACEHOLDER/$laptop_monitor/g" \
        "$SCRIPTS_DIR/lid-monitor.sh"
    
    # Make script executable
    chmod +x "$SCRIPTS_DIR/lid-monitor.sh"
    
    log_success "Lid monitor script installed at $SCRIPTS_DIR/lid-monitor.sh"
}

install_lid_resume_monitor_script() {
    log_info "Installing lid resume monitor script..."

    cat > "$RESUME_MONITOR_FILE" << 'EOF'
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

    chmod +x "$RESUME_MONITOR_FILE"
    log_success "Lid resume monitor installed at $RESUME_MONITOR_FILE"
}

# Install the systemd service
install_systemd_service() {
    log_info "Installing systemd user services..."
    
    cat > "$SERVICE_FILE" << EOF
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

    cat > "$RESUME_SERVICE_FILE" << EOF
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
    
    log_success "Systemd services installed at $SYSTEMD_USER_DIR"
}

detect_legacy_default_target_service() {
    if [[ -f "$SERVICE_FILE" ]] && grep -Fqx 'WantedBy=default.target' "$SERVICE_FILE"; then
        legacy_default_target_service=true
    fi
}

migrate_legacy_default_target_service() {
    if [[ "$legacy_default_target_service" == true ]]; then
        log_info "Stopping the legacy default-target lid monitor service..."
        systemctl --user disable --now lid-monitor.service
    fi
}

# Enable and start the service
enable_service() {
    log_info "Enabling and starting lid monitor service..."
    
    # Reload systemd daemon
    systemctl --user daemon-reload
    
    # Enable the daemon as part of the graphical session.
    systemctl --user enable lid-monitor.service

    # Import the current compositor environment before starting its target.
    "$SESSION_BRIDGE" start

    # Ensure the daemon is started even if the session target was already active.
    systemctl --user start lid-monitor.service
    systemctl --user start lid-resume-monitor.service
    
    # Check if service started successfully
    if systemctl --user is-active --quiet lid-monitor.service; then
        log_success "Lid monitor service is running"
    else
        log_error "Failed to start lid monitor service"
        systemctl --user status lid-monitor.service
        exit 1
    fi
    if systemctl --user is-active --quiet lid-resume-monitor.service; then
        log_success "Lid resume monitor service is running"
    else
        log_error "Failed to start lid resume monitor service"
        systemctl --user status lid-resume-monitor.service
        exit 1
    fi
}

# Check if lid detection is working
test_lid_detection() {
    local lid_state

    log_info "Testing lid state detection..."

    if lid_state=$("$SCRIPTS_DIR/lid-monitor.sh" --print-state); then
        log_success "Lid state detection working: $lid_state"
    else
        log_warning "Could not determine lid state. The service may not work properly."
        log_info "Please check if your system supports ACPI lid events."
    fi
}

# Backup existing files
backup_existing_files() {
    log_info "Backing up existing files..."
    
    local backup_dir="$HYPR_CONFIG_DIR/scripts/.backup-$(date +%Y%m%d-%H%M%S)"
    
    if [[ -f "$SCRIPTS_DIR/lid-switch.sh" ]] || \
        [[ -f "$SCRIPTS_DIR/lid-monitor.sh" ]] || \
        [[ -f "$RESUME_MONITOR_FILE" ]]; then
        mkdir -p "$backup_dir"
        
        [[ -f "$SCRIPTS_DIR/lid-switch.sh" ]] && cp "$SCRIPTS_DIR/lid-switch.sh" "$backup_dir/"
        [[ -f "$SCRIPTS_DIR/lid-monitor.sh" ]] && cp "$SCRIPTS_DIR/lid-monitor.sh" "$backup_dir/"
        [[ -f "$RESUME_MONITOR_FILE" ]] && cp "$RESUME_MONITOR_FILE" "$backup_dir/"
        
        log_success "Existing files backed up to $backup_dir"
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
    check_lid_power_policy
    check_hyprland_capabilities
    
    # Detect monitors
    log_info "Detecting Monitors..."
    detect_monitors
    
    # Backup existing files
    backup_existing_files

    # Detect the previous default-target unit before replacing it.
    detect_legacy_default_target_service
    
    # Create directories
    create_directories
    
    # Prepare every non-service artifact before stopping a legacy service.
    install_lid_state_script
    install_monitor_state_script
    install_lid_switch_script "$laptop_monitor"
    install_lid_switch_doctor
    install_lid_monitor_script
    install_lid_resume_monitor_script
    install_session_bridge
    install_session_module
    install_session_target

    # Test the same lid observer used by the runtime scripts
    test_lid_detection

    # Replace the legacy lifecycle only after all preparation succeeded.
    migrate_legacy_default_target_service
    install_systemd_service
    
    # Enable and start service
    enable_service

    # Make future compositor sessions start and stop the target.
    integrate_session_config
    
    # Print final instructions
    print_final_instructions
}

# Handle script interruption
trap 'log_error "Installation interrupted"; exit 1' INT TERM

# Run main function
main "$@"
