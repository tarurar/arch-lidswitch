# Hyprland Lid Switch Handler

An automatic lid switch handler for Hyprland that intelligently manages monitor configuration when using laptops with external displays.

## Features

- 🔄 **Automatic Monitor Management**: Seamlessly switches between laptop and external monitors based on lid state
- 🖥️ **Smart Detection**: Automatically detects laptop screen (eDP-*) and external monitors (DP-*/HDMI-*/USB-C-*)
- ⚡ **Instant Response**: Real-time lid state monitoring with ~1 second response time  
- 🛡️ **Hyprland Lua Compatible**: Uses `hyprctl eval`/`hl.monitor()` for modern Hyprland Lua configs
- 🔧 **Zero Configuration**: Works out of the box after installation
- 📝 **Journal Logging**: Structured service and transition records for troubleshooting
- 🔁 **Session-Bound Startup**: Systemd user service starts after Hyprland is reachable and stops with the graphical session
- 💤 **Single Power-Policy Owner**: Leaves every lid-triggered power decision to systemd-logind
- 📐 **Layout Preservation**: Restores the internal panel's captured mode, position, scale, transform, and mirror without rewriting external outputs
- 📊 **Waybar Layout Refresh**: Refreshes Waybar layer geometry without restarting the Waybar process

## How It Works

### Lid Closed + External Monitor Connected
- Captures the active internal panel layout in the private runtime directory
- Disables laptop internal display
- Leaves every external monitor's mode, position, scale, transform, and mirror untouched
- All workspaces remain accessible
- Waybar is briefly hidden/shown with `SIGUSR1` so its layer geometry follows the new layout

### Lid Opened
- Re-enables the laptop internal display from its captured layout
- Restores its exact mode, position, scale, transform, and mirror settings
- Leaves the external monitor arrangement untouched
- Maintains your workspace layout
- Refreshes Waybar layer geometry without restarting Waybar

### Lid Closed + No External Monitor
- Makes no display or power change
- Delegates the lid event to systemd-logind
- With the supported default policy, logind suspends when undocked and ignores a docked lid close

## Requirements

- **OS**: Arch Linux (or similar)
- **Desktop**: Hyprland 0.55.0 or newer, using the Lua configuration provider
- **Hardware**: Laptop with ACPI lid switch support
- **Session**: Wayland session
- **Tools**: `hyprctl` from the active Hyprland session and `jq` for installer checks and runtime layout validation
- **Instances**: Exactly one running Hyprland instance matching `HYPRLAND_INSTANCE_SIGNATURE` and the active Wayland socket; automatic instance selection is not supported
- **Power policy**: systemd-logind with `HandleLidSwitch=suspend`, `HandleLidSwitchDocked=ignore`, and no low-level `handle-lid-switch` inhibitor
- **Power capability**: login1 must report `CanSuspend=yes`; hibernation and swap/resume configuration are not required because this project never requests hibernation

## Installation

### Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/tarurar/arch-lidswitch/main/install-hyprland-lid-switch.sh | bash
```

### Manual Install

1. **Download the installer**:
   ```bash
   wget https://raw.githubusercontent.com/tarurar/arch-lidswitch/main/install-hyprland-lid-switch.sh
   chmod +x install-hyprland-lid-switch.sh
   ```

2. **Run the installer**:
   ```bash
   ./install-hyprland-lid-switch.sh
   ```

3. **Test the installation**:
   Close your laptop lid to verify it works!

## What Gets Installed

The installer creates the following files:

```
~/.config/hypr/scripts/
├── lid-state.sh       # Shared ACPI lid state observer
├── monitor-state.sh   # Secure internal-layout snapshot and restore
├── lid-switch.sh      # Core lid switch logic
├── lid-switch-doctor.sh # Read-only logind policy diagnostics
├── lid-monitor.sh     # Background monitor daemon
└── lid-session-bridge.sh # Ordered Hyprland/systemd session startup

~/.config/hypr/arch_lidswitch/
└── session.lua        # Hyprland start and shutdown event handlers

~/.config/systemd/user/
├── hyprland-session.target # Graphical-session lifecycle target
└── lid-monitor.service     # Session-bound daemon configuration
```

The installer also appends one clearly marked, idempotent `pcall(require, ...)`
block to `hyprland.lua`. Existing Lua callbacks and configuration are preserved.

## Usage

### Service Management

```bash
# Check service status
systemctl --user status lid-monitor.service

# Start service
systemctl --user start lid-monitor.service

# Stop service  
systemctl --user stop lid-monitor.service

# Restart service
systemctl --user restart lid-monitor.service

# Disable auto-start
systemctl --user disable lid-monitor.service

# Re-enable auto-start
systemctl --user enable lid-monitor.service
```

### Manual Testing

```bash
# Test lid close behavior
~/.config/hypr/scripts/lid-switch.sh close

# Test lid open behavior
~/.config/hypr/scripts/lid-switch.sh open

# Auto-detect current lid state
~/.config/hypr/scripts/lid-switch.sh

# Inspect lid state without changing display or power state
~/.config/hypr/scripts/lid-monitor.sh --print-state

# Inspect an alternate ACPI lid root
HYPR_LID_STATE_ROOT=/path/to/button/lid \
  ~/.config/hypr/scripts/lid-monitor.sh --print-state
```

### Power-Policy Doctor

```bash
~/.config/hypr/scripts/lid-switch-doctor.sh
```

The doctor reads effective systemd-logind properties, power capabilities, and
active low-level lid inhibitors. It succeeds only when logind is the sole
lid-power owner and its selected suspend action is available:

- `HandleLidSwitch=suspend`
- `HandleLidSwitchDocked=ignore`
- `HandleLidSwitchExternalPower` is unset or `suspend`
- `CanSuspend=yes`
- no process holds a `handle-lid-switch` inhibitor

`CanHibernate` is reported for context only. The reviewed host profile
`CanSuspend=yes` / `CanHibernate=na` is supported: logind suspends on the
undocked lid action, while this project neither requests hibernation nor
requires disk swap or a configured resume target. Even `CanHibernate=yes`
remains unused.

Exit status `1` means the effective policy conflicts with this supported
contract or `CanSuspend` is anything other than exactly `yes`. Exit status `2`
means the doctor could not collect a required diagnostic reliably. Failure to
read the unused `CanHibernate` capability produces a warning without blocking
installation. The doctor and installer are read-only with respect to system
policy: they never modify `/etc` or systemd-logind configuration.

### Monitoring Logs

```bash
# Follow monitor and switch records from the running service
journalctl --user -u lid-monitor.service -f -o cat

# View records from the current boot
journalctl --user -u lid-monitor.service -b -o cat

# View the previous boot when persistent journal storage is enabled
journalctl --user -u lid-monitor.service -b -1 -o cat
```

Runtime records use stable fields such as `component=lid-switch`,
`event=monitor_query_failed`, `event=layout_snapshot_failed`, and
`action=close`. The user service sends both stdout and stderr to journald with
the identifier `arch-lidswitch`; it does not create separate log files in
`/tmp`. Journal retention follows the host's systemd-journald configuration.

## Troubleshooting

### Service Not Starting

1. **Check service status**:
   ```bash
   systemctl --user status lid-monitor.service
   ```

   Inspect the service's current-boot diagnostics:
   ```bash
   journalctl --user -u lid-monitor.service -b -n 100 --no-pager -o cat
   ```

2. **Verify Hyprland is running**:
   ```bash
   echo $XDG_SESSION_TYPE  # Should output 'wayland'
   jq --version
   hyprctl -j version | jq '.version'
   hyprctl -j instances | jq \
     --arg instance "$HYPRLAND_INSTANCE_SIGNATURE" \
     --arg socket "$WAYLAND_DISPLAY" \
     'length == 1 and .[0].instance == $instance and (((.[0] | has("wl_socket")) | not) or .[0].wl_socket == $socket)'
   hyprctl -j status | jq '.configProvider'
   hyprctl -j monitors all | jq 'type'
   systemctl --user is-active hyprland-session.target graphical-session.target
   ```

   The supported profile reports Hyprland `0.55.0` or newer, exactly one
   instance selected by the current session environment, `configProvider`
   equal to `lua`, and a monitor response whose JSON type is `array`.

3. **Check the required Lua monitor API without changing the layout**:
   ```bash
   hyprctl eval 'assert(type(hl) == "table" and type(hl.monitor) == "function", "hl.monitor unavailable")'
   ```

   A compatible compositor prints exactly `ok`. The installer runs this
   nonmutating probe before it creates files or changes user-systemd state.

4. **Check lid detection**:
   ```bash
   cat /proc/acpi/button/lid/*/state
   ```

### Lid Events Not Detected

1. **Verify ACPI support**:
   ```bash
   ls /proc/acpi/button/lid/
   ```
   
2. **Check for alternative lid detection**:
   ```bash
   find /sys -name "*lid*" -type f 2>/dev/null
   ```

3. **Manual detection test**:
   ```bash
   ~/.config/hypr/scripts/lid-monitor.sh --print-state
   journalctl --user -u lid-monitor.service -f -o cat
   ```

### Conflicting Lid Power Policy

Run the installed doctor first:

```bash
~/.config/hypr/scripts/lid-switch-doctor.sh
```

Use these read-only commands to locate an override or competing owner:

```bash
systemd-analyze cat-config systemd/logind.conf
systemd-inhibit --list --what=handle-lid-switch --no-pager
```

Resolve a conflict through the host administrator's normal system policy
workflow. The installer reports conflicts before writing user files; it does
not create or edit logind configuration under `/etc`.

If the doctor reports `CanSuspend=na`, `no`, `challenge`, or another value,
login1 cannot provide the noninteractive suspend action this configuration
delegates. `CanHibernate` does not provide a fallback; its value is
informational because arch-lidswitch never requests hibernation.

### Wrong Monitor Detection

1. **List current monitors**:
   ```bash
   hyprctl monitors
   ```

2. **Edit the configuration** in `~/.config/hypr/scripts/lid-switch.sh`:
   ```bash
   # Update LAPTOP_DISPLAY variable if needed
   LAPTOP_DISPLAY="your-laptop-monitor-name"
   ```

3. **Restart the service**:
   ```bash
   systemctl --user restart lid-monitor.service
   ```

### Hyprland Reports "Use eval"

Hyprland Lua configs do not accept dynamic monitor changes through the legacy `hyprctl keyword monitor ...` path. If you see:

```text
keyword can't work with non-legacy parsers. Use eval.
```

use the current script version. It configures monitors through Lua:

```bash
hyprctl eval 'hl.monitor({ output = "eDP-1", disabled = true })'
```

### Waybar Is Offset After Closing the Lid

Some Waybar/Hyprland combinations keep stale layer geometry after a monitor is disabled. The script works around this by toggling Waybar visibility twice:

```bash
pkill -x -SIGUSR1 waybar
sleep 0.1
pkill -x -SIGUSR1 waybar
```

This forces Waybar to recalculate its layer position while keeping the same Waybar process alive. `SIGUSR2` is intentionally not used because it can terminate Waybar on some setups.

## Customization

### Monitor Resolution and Positioning

Configure monitor geometry in your normal Hyprland Lua configuration, not in
`lid-switch.sh`. On a docked close, arch-lidswitch validates and atomically
saves only the active internal output to:

```text
$XDG_RUNTIME_DIR/arch-lidswitch/internal-layout.json
```

The directory is private (`0700`) and the snapshot is private (`0600`). A lid
open restores that internal output and removes the consumed snapshot. Missing,
malformed, or unwritable state stops the transition before any monitor change.
External outputs are never targeted, so custom external modes, positions,
fractional scales, transforms, and mirroring remain owned by your Hyprland
configuration.

### Response Timing

Adjust the polling interval in `~/.config/hypr/scripts/lid-monitor.sh`:

```bash
# Change sleep duration (default: 1 second)
sleep 0.5  # For faster response
sleep 2    # For less CPU usage
```

### Logging

The monitor and switch scripts emit concise `key=value` records on stdout and
stderr. To inspect only transition failures from the current boot:

```bash
journalctl --user -u lid-monitor.service -b -o cat | grep 'level=error'
```

Storage limits, persistence, and rotation are controlled centrally by
systemd-journald rather than by these scripts.

## Uninstallation

```bash
# Stop and disable service
systemctl --user stop lid-monitor.service
systemctl --user disable lid-monitor.service

# Remove files
rm -f ~/.config/hypr/scripts/lid-state.sh
rm -f ~/.config/hypr/scripts/monitor-state.sh
rm -f ~/.config/hypr/scripts/lid-switch.sh
rm -f ~/.config/hypr/scripts/lid-switch-doctor.sh
rm -f ~/.config/hypr/scripts/lid-monitor.sh
rm -f ~/.config/hypr/scripts/lid-session-bridge.sh
rm -f ~/.config/hypr/arch_lidswitch/session.lua
rm -f ~/.config/systemd/user/hyprland-session.target
rm -f ~/.config/systemd/user/lid-monitor.service

# Reload systemd
systemctl --user daemon-reload
```

Remove the exact block between `BEGIN arch-lidswitch managed session
integration` and `END arch-lidswitch managed session integration` from
`~/.config/hypr/hyprland.lua` as well. Do not remove surrounding user-owned Lua.

No separate runtime log files need removal. Existing journal records expire
according to the host's systemd-journald retention policy.
