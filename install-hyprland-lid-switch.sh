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
HYPR_CONFIG_DIR="$HOME/.config/hypr"
SCRIPTS_DIR="$HYPR_CONFIG_DIR/scripts"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

# Global variables
laptop_monitor=""
external_monitor=""

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
    mkdir -p "$SYSTEMD_USER_DIR"
    
    log_success "Directories created"
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
        log_info power_action_requested action=hibernate reason=no_external_monitor
        systemctl hibernate
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
    
    cat > "$SYSTEMD_USER_DIR/lid-monitor.service" << EOF
[Unit]
Description=Hyprland Lid Switch Monitor
After=graphical-session.target

[Service]
Type=simple
ExecStart=$SCRIPTS_DIR/lid-monitor.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=arch-lidswitch
Restart=always
RestartSec=2
Environment="DISPLAY=:0"

[Install]
WantedBy=default.target
EOF
    
    log_success "Systemd service installed at $SYSTEMD_USER_DIR/lid-monitor.service"
}

# Enable and start the service
enable_service() {
    log_info "Enabling and starting lid monitor service..."
    
    # Reload systemd daemon
    systemctl --user daemon-reload
    
    # Enable service to start on boot
    systemctl --user enable lid-monitor.service
    
    # Start service now
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
    echo "  • Lid monitor daemon: $SCRIPTS_DIR/lid-monitor.sh"
    echo "  • Systemd user service: lid-monitor.service"
    echo
    echo -e "${BLUE}How it works:${NC}"
    echo "  • When lid closes + external monitor connected: laptop screen turns off"
    echo "  • When lid opens: laptop screen turns back on (dual monitor setup)"
    echo "  • Service starts automatically on login"
    echo
    echo -e "${BLUE}Useful commands:${NC}"
    echo "  • Check service status: systemctl --user status lid-monitor.service"
    echo "  • Follow service logs: journalctl --user -u lid-monitor.service -f -o cat"
    echo "  • View current-boot logs: journalctl --user -u lid-monitor.service -b -o cat"
    echo "  • Stop service: systemctl --user stop lid-monitor.service"
    echo "  • Restart service: systemctl --user restart lid-monitor.service"
    echo
    echo -e "${GREEN}Try closing your laptop lid now to test!${NC}"
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
    
    # Detect monitors
    log_info "Detecting Monitors..."
    detect_monitors
    
    # Backup existing files
    backup_existing_files
    
    # Create directories
    create_directories
    
    # Install scripts and service
    install_lid_state_script
    install_lid_switch_script "$laptop_monitor"
    install_lid_monitor_script
    install_systemd_service

    # Test the same lid observer used by the runtime scripts
    test_lid_detection
    
    # Enable and start service
    enable_service
    
    # Print final instructions
    print_final_instructions
}

# Handle script interruption
trap 'log_error "Installation interrupted"; exit 1' INT TERM

# Run main function
main "$@"
