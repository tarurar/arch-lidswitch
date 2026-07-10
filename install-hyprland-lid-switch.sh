#!/bin/bash

################################################################################
# Hyprland Lid Switch Installer
# 
# This script installs an automatic lid switch handler for Hyprland that:
# - Disables laptop display when lid is closed (with external monitor connected)
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
DOCTOR_FILE="$SCRIPTS_DIR/lid-switch-doctor.sh"

SESSION_CONFIG_BEGIN='-- BEGIN arch-lidswitch managed session integration'
SESSION_CONFIG_END='-- END arch-lidswitch managed session integration'

# Global variables
laptop_monitor=""
external_monitor=""
HYPRCTL_BIN=""
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
    local monitor_list=""
    
    # Get monitor information from hyprctl
    monitor_list=$(hyprctl monitors | awk '/Monitor / {print $2}')

    laptop_monitor=$(grep -m1 "^eDP" <<<"${monitor_list}" || true)
    external_monitor=$(grep -m1 -E "^(DP|HDMI|USB-C)" <<<"${monitor_list}" || true)
    
    if [[ -z "$laptop_monitor" ]]; then
        log_error "Could not detect laptop monitor (eDP-*)"
        exit 1
    fi
    
    log_info "Detected laptop monitor: $laptop_monitor"
    if [[ -n "$external_monitor" ]]; then
        log_info "Detected external monitor: $external_monitor"
    else
        log_info "No external monitor currently connected"
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

LAPTOP_DISPLAY="LAPTOP_MONITOR_PLACEHOLDER"
LAPTOP_MODE="2880x1920@120"
LAPTOP_POSITION="0x0"
LAPTOP_SCALE="2"

get_external_display() {
    local monitor_output external_display

    if ! monitor_output=$(hyprctl monitors); then
        return 2
    fi

    external_display=$(grep -E "^Monitor (DP|HDMI|USB-C)" <<< "$monitor_output" | grep -v "$LAPTOP_DISPLAY" | head -1 | cut -d' ' -f2)
    if [[ -z "$external_display" ]]; then
        return 1
    fi

    printf '%s\n' "$external_display"
}

configure_clamshell_layout() {
    local external_display="$1"

    hyprctl eval "hl.monitor({ output = \"$LAPTOP_DISPLAY\", disabled = true }); hl.monitor({ output = \"$external_display\", mode = \"preferred\", position = \"0x0\", scale = 1 })"
}

enable_laptop_display() {
    hyprctl eval "hl.monitor({ output = \"$LAPTOP_DISPLAY\", disabled = false, mode = \"$LAPTOP_MODE\", position = \"$LAPTOP_POSITION\", scale = $LAPTOP_SCALE })"
}

configure_dual_layout() {
    local external_display="$1"

    hyprctl eval "hl.monitor({ output = \"$LAPTOP_DISPLAY\", disabled = false, mode = \"$LAPTOP_MODE\", position = \"$LAPTOP_POSITION\", scale = $LAPTOP_SCALE }); hl.monitor({ output = \"$external_display\", mode = \"preferred\", position = \"auto-right\", scale = 1 })"
}

refresh_waybar_layout() {
    if pgrep -x waybar >/dev/null 2>&1; then
        pkill -x -SIGUSR1 waybar || {
            log_error waybar_refresh_failed phase=hide
            return 1
        }
        sleep 0.1
        pkill -x -SIGUSR1 waybar || log_error waybar_refresh_failed phase=show
    fi
}

handle_lid_close() {
    local discovery_status=0

    log_info transition_started action=close

    if CURRENT_EXTERNAL=$(get_external_display); then
        discovery_status=0
    else
        discovery_status=$?
    fi

    if (( discovery_status == 0 )); then
        log_info external_monitor_detected action=close output="$CURRENT_EXTERNAL"
        if configure_clamshell_layout "$CURRENT_EXTERNAL"; then
            refresh_waybar_layout
            log_info layout_applied action=close laptop=disabled external="$CURRENT_EXTERNAL"
        else
            log_error layout_apply_failed action=close
        fi
    elif (( discovery_status == 1 )); then
        log_info power_delegated owner=systemd-logind action=close reason=no_external_monitor
    else
        log_error monitor_query_failed action=close
        return 2
    fi
}

handle_lid_open() {
    local discovery_status=0

    log_info transition_started action=open

    if CURRENT_EXTERNAL=$(get_external_display); then
        discovery_status=0
    else
        discovery_status=$?
    fi

    if (( discovery_status == 0 )); then
        log_info external_monitor_detected action=open output="$CURRENT_EXTERNAL"
        if configure_dual_layout "$CURRENT_EXTERNAL"; then
            refresh_waybar_layout
            log_info layout_applied action=open layout=dual external="$CURRENT_EXTERNAL"
        else
            log_error layout_apply_failed action=open layout=dual
        fi
    elif (( discovery_status == 1 )); then
        log_info external_monitor_absent action=open
        if enable_laptop_display; then
            refresh_waybar_layout
            log_info layout_applied action=open layout=laptop_only
        else
            log_error layout_apply_failed action=open layout=laptop_only
        fi
    else
        log_error monitor_query_failed action=open
        return 2
    fi
}

case "${1:-}" in
    "close")
        handle_lid_close
        ;;
    "open")
        handle_lid_open
        ;;
    *)
        if ! lid_state=$(read_lid_state); then
            log_error lid_state_unknown action=auto
            exit 1
        fi
        log_info lid_state_detected state="$lid_state"
        
        if [[ "$lid_state" == "closed" ]]; then
            handle_lid_close
        else
            handle_lid_open
        fi
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

# Hyprland Lid State Monitor
# This script continuously monitors the lid state and triggers the appropriate action

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LID_SWITCH_SCRIPT="$SCRIPT_DIR/lid-switch.sh"

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

observe_lid_state() {
    local observation_status

    if observed_state=$(read_lid_state 2>/dev/null); then
        observed_error=""
        return 0
    else
        observation_status=$?
    fi

    observed_state="unknown"
    case "$observation_status" in
        2)
            observed_error="missing"
            ;;
        3)
            observed_error="unreadable"
            ;;
        4)
            observed_error="malformed"
            ;;
        5)
            observed_error="conflicting"
            ;;
        *)
            observed_error="unknown"
            ;;
    esac
    return "$observation_status"
}

if ! . "$SCRIPT_DIR/lid-state.sh"; then
    log_error lid_state_observer_load_failed
    exit 1
fi

if [[ "${1:-}" == "--print-state" ]]; then
    read_lid_state
    exit $?
fi

# Initial state
previous_error=""
if observe_lid_state; then
    previous_state="$observed_state"
else
    previous_state="unknown"
    previous_error="$observed_error"
    log_error lid_state_observation_failed reason="$observed_error"
fi
log_info monitor_started state="$previous_state"

while true; do
    if observe_lid_state; then
        current_state="$observed_state"
        previous_error=""
    else
        current_state="unknown"
        if [[ "$observed_error" != "$previous_error" ]]; then
            log_error lid_state_observation_failed reason="$observed_error"
        fi
        previous_error="$observed_error"
        sleep 1
        continue
    fi
    
    if [[ "$current_state" != "$previous_state" && "$current_state" != "unknown" ]]; then
        log_info lid_state_changed previous="$previous_state" current="$current_state"
        
        # Call the lid switch script with the appropriate argument
        if [[ "$current_state" == "closed" ]]; then
            "$LID_SWITCH_SCRIPT" close
        elif [[ "$current_state" == "open" ]]; then
            "$LID_SWITCH_SCRIPT" open
        fi
        
        previous_state="$current_state"
    fi
    
    sleep 1
done
EOF
    
    # Make script executable
    chmod +x "$SCRIPTS_DIR/lid-monitor.sh"
    
    log_success "Lid monitor script installed at $SCRIPTS_DIR/lid-monitor.sh"
}

# Install the systemd service
install_systemd_service() {
    log_info "Installing systemd user service..."
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Hyprland Lid Switch Monitor
PartOf=graphical-session.target
After=graphical-session.target
ConditionEnvironment=HYPRLAND_INSTANCE_SIGNATURE
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=exec
ExecStartPre=$HYPRCTL_BIN monitors
ExecStart=$SCRIPTS_DIR/lid-monitor.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=arch-lidswitch
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF
    
    log_success "Systemd service installed at $SYSTEMD_USER_DIR/lid-monitor.service"
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
    
    # Check if service started successfully
    if systemctl --user is-active --quiet lid-monitor.service; then
        log_success "Lid monitor service is running"
    else
        log_error "Failed to start lid monitor service"
        systemctl --user status lid-monitor.service
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
    
    if [[ -f "$SCRIPTS_DIR/lid-switch.sh" ]] || [[ -f "$SCRIPTS_DIR/lid-monitor.sh" ]]; then
        mkdir -p "$backup_dir"
        
        [[ -f "$SCRIPTS_DIR/lid-switch.sh" ]] && cp "$SCRIPTS_DIR/lid-switch.sh" "$backup_dir/"
        [[ -f "$SCRIPTS_DIR/lid-monitor.sh" ]] && cp "$SCRIPTS_DIR/lid-monitor.sh" "$backup_dir/"
        
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
    echo "  • Lid switch handler script: $SCRIPTS_DIR/lid-switch.sh"
    echo "  • Lid switch doctor: $DOCTOR_FILE"
    echo "  • Lid monitor daemon: $SCRIPTS_DIR/lid-monitor.sh"
    echo "  • Hyprland session bridge: $SESSION_BRIDGE"
    echo "  • Hyprland session module: $SESSION_MODULE"
    echo "  • Hyprland session target: hyprland-session.target"
    echo "  • Systemd user service: lid-monitor.service"
    echo
    echo -e "${BLUE}How it works:${NC}"
    echo "  • When lid closes + external monitor connected: laptop screen turns off"
    echo "  • When lid closes without an external monitor: systemd-logind owns the power action"
    echo "  • When lid opens: laptop screen turns back on (dual monitor setup)"
    echo "  • Service starts automatically on login"
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
    check_lid_power_policy
    
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
    install_lid_switch_script "$laptop_monitor"
    install_lid_switch_doctor
    install_lid_monitor_script
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
