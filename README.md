# Hyprland Lid Switch Handler

An automatic lid switch handler for Hyprland that intelligently manages monitor configuration when using laptops with external displays.

## Features

- 🔄 **Automatic Monitor Management**: Reconciles the internal display when either lid state or represented output topology changes
- 🖥️ **Structured Detection**: Reads `hyprctl -j monitors all`; uses one unique `eDP*` output as the default internal display and treats every other represented output as external, regardless of connector name
- ⚡ **Instant Response**: Real-time lid and output-topology monitoring with ~1 second response time
- 🛡️ **Hyprland Lua Compatible**: Uses `hyprctl eval`/`hl.monitor()` for modern Hyprland Lua configs
- 🔧 **Zero Configuration**: Works out of the box after installation
- 📝 **Journal Logging**: Structured service and transition records for troubleshooting
- 🔁 **Session-Bound Startup**: Systemd user service starts after Hyprland is reachable and stops with the graphical session
- 💤 **Single Power-Policy Owner**: Leaves every lid-triggered power decision to systemd-logind
- 📐 **Display Geometry Preservation**: Restores the internal panel's captured mode, position, scale, transform, and mirror without rewriting external outputs
- 🧩 **Optional Post-Layout Hook**: Runs one bounded user command after a verified internal-display layout change

## How It Works

### Lid Closed + Enabled External Output

- Counts every represented output other than the configured internal display; only records with `disabled=false` are enabled
- Captures the active internal panel layout in the private runtime directory
- Disables laptop internal display
- Leaves every external monitor's mode, position, scale, transform, and mirror untouched
- Leaves workspace migration and window placement to Hyprland
- Runs the optional post-layout hook once with the verified `disabled` outcome

### Lid Opened
- Re-enables the laptop internal display from its captured layout if it is disabled
- Makes no display change if the internal display is already enabled
- Restores its exact mode, position, scale, transform, and mirror settings
- Leaves the external monitor arrangement untouched
- Does not attempt to restore workspace-to-monitor assignments
- Runs the optional post-layout hook once with the verified `enabled` outcome

### Lid Closed + No Enabled External Output

- Treats absent and inactive (`disabled=true`) external outputs the same for clamshell policy
- Restores the internal display first if it was disabled by an earlier docked close
- Delegates the lid event to systemd-logind
- With the supported default policy, logind suspends when undocked and ignores a docked lid close

The daemon observes a joint lid-and-topology fingerprint. It reconciles the
first complete observation immediately at service startup, then uses that
observation as the baseline for later changes. While the session remains awake,
later dock, undock, or output activation changes are reconciled even when the
lid state itself has not changed. Multiple external outputs and inactive outputs
remain explicit records in the structured snapshot; DPMS state is observed
separately and never changes whether an output is classified as enabled. Before
startup, changed topology, or resume reconciliation can mutate a display, the
daemon requires three identical full lid/topology samples plus an immediate
matching precommit sample. A dedicated login1 listener keeps one subscription
across the sleep cycle and coalesces resume requests into the main daemon.

## Requirements

- **OS**: Arch Linux (or similar)
- **Desktop**: Hyprland 0.55.0 or newer, using the Lua configuration provider
- **Hardware**: Laptop with ACPI lid switch support
- **Session**: Wayland session
- **Tools**: `hyprctl`, `jq`, Lua's `luac`, util-linux `flock`, GNU diffutils `cmp`, and GNU coreutils 9.11 or newer (`mv`, `sha256sum`, `stat`, `stdbuf`, and `timeout`); transactional publication requires `mv --exchange --no-copy` and `mv --update=none-fail --no-copy`
- **System manager**: systemd 257 or newer with `systemd-analyze`; the resume listener uses typed `busctl wait` output
- **Lua APIs**: `hl.monitor`, `hl.dispatch`, and `hl.dsp.dpms`; the installer probes all three without changing display state
- **Instances**: Exactly one running Hyprland instance matching `HYPRLAND_INSTANCE_SIGNATURE` and the active Wayland socket; automatic instance selection is not supported
- **Power policy**: systemd-logind with `HandleLidSwitch=suspend`, `HandleLidSwitchDocked=ignore`, and no low-level `handle-lid-switch` inhibitor
- **Power capability**: login1 must report `CanSuspend=yes`; hibernation and swap/resume configuration are not required because this project never requests hibernation

## Installation

### Verified Pinned Install

1. **Confirm the pinned release**:

   The commands below pin `v0.1.0`. Before continuing, confirm that this exact
   version exists on the GitHub Releases page and is marked **Immutable**. If
   the release does not exist or is not immutable, stop rather than falling
   back to a branch or piping remote content into a shell.

2. **Download, verify, and install**:

   This verification path requires an authenticated GitHub CLI (`gh`) session.
   Download the installer and its checksum manifest into a private temporary
   directory, verify both release provenance and file integrity, then execute
   the verified local file:

   ```bash
   (
     set -euo pipefail

     ARCH_LIDSWITCH_VERSION='v0.1.0'
     download_dir=$(mktemp -d)
     trap 'rm -rf -- "$download_dir"' EXIT
     installer="$download_dir/install-hyprland-lid-switch.sh"
     checksums="$download_dir/SHA256SUMS"
     release_url="https://github.com/tarurar/arch-lidswitch/releases/download/${ARCH_LIDSWITCH_VERSION}"

     curl -fL --output "$installer" \
       "$release_url/install-hyprland-lid-switch.sh"
     curl -fL --output "$checksums" "$release_url/SHA256SUMS"

     grep -Eq \
       '^[0-9a-f]{64}  install-hyprland-lid-switch\.sh$' \
       "$checksums"
     [[ "$(wc -l < "$checksums")" -eq 1 ]]

     gh release verify "$ARCH_LIDSWITCH_VERSION" \
       --repo tarurar/arch-lidswitch
     gh release verify-asset "$ARCH_LIDSWITCH_VERSION" "$installer" \
       --repo tarurar/arch-lidswitch
     gh release verify-asset "$ARCH_LIDSWITCH_VERSION" "$checksums" \
       --repo tarurar/arch-lidswitch
     (
       cd "$download_dir"
       sha256sum --check --strict SHA256SUMS
     )
     chmod +x "$installer"
     "$installer"
   )
   ```

   The `gh release verify` commands verify the immutable release attestation and
   both downloaded assets. The exact, single-entry `SHA256SUMS` consistency
   check catches a mismatched or damaged installer.

3. **Test the installation**:

   Preview the close decision first. This reads the live topology but does not
   change display or power state:

   ```bash
   ~/.config/hypr/scripts/lid-switch.sh --dry-run close
   ```

   **MAY SUSPEND:** Physically closing the lid delegates the event to
   systemd-logind. On an undocked laptop with the supported policy, logind will
   suspend the system. Only perform a physical close after reviewing the
   dry-run output and saving your work.

By default, installation requires exactly one represented output whose name
starts with `eDP`. Hardware that uses another internal connector name, or a
topology with more than one `eDP*` candidate, must select the internal output
explicitly:

```bash
HYPR_LID_INTERNAL_OUTPUT=DSI-1 ./install-hyprland-lid-switch.sh
```

The selected output may be inactive during installation, but it must appear in
`hyprctl -j monitors all`. The installer records that identity in both runtime
scripts. Every other represented output is external; connector prefixes are
not used to classify external displays.

### Publishing Releases (Maintainers)

Before publishing the first release, an administrator must enable immutable
releases. This setting applies only to releases created after it is enabled:

```bash
gh api --method PUT repos/tarurar/arch-lidswitch/immutable-releases
```

Also create an active repository **tag ruleset** targeting `v*` before creating
the first version tag. Enable **Restrict updates**, **Restrict deletions**, and
**Block force pushes**, with no bypass for release tags. Creation must remain
allowed so a new version can be pushed once; afterward the tag cannot move
during the build-to-publication window. The workflow re-reads and peels the
remote tag immediately before publication and requires it to identify both the
triggering ref and the commit whose installer was tested.

The release workflow accepts only stable `vMAJOR.MINOR.PATCH` tags, reruns the
full test suite, packages the exact generated installer with a one-entry
`SHA256SUMS`, and publishes both assets from the verified remote tag. After all
changes intended for the release are committed, publish `v0.1.0` by creating
and pushing that tag; branch pushes never publish releases.

## What Gets Installed

The installer creates the following files:

```
~/.config/hypr/scripts/
├── lid-state.sh       # Shared ACPI lid state observer
├── monitor-state.sh   # Secure internal-layout snapshot and restore
├── lid-switch.sh      # Core lid switch logic
├── lid-switch-doctor.sh # Read-only logind policy diagnostics
├── lid-monitor.sh     # Background monitor daemon
├── lid-resume-monitor.sh # Lifetime login1 resume-event listener
└── lid-session-bridge.sh # Ordered Hyprland/systemd session startup

~/.config/hypr/arch_lidswitch/
└── session.lua        # Hyprland start and shutdown event handlers

~/.config/systemd/user/
├── hyprland-session.target # Graphical-session lifecycle target
├── lid-monitor.service     # Session-bound reconciliation daemon
└── lid-resume-monitor.service # Session-bound login1 listener
```

The installer also appends one clearly marked, idempotent `pcall(require, ...)`
block to `hyprland.lua`. Existing Lua callbacks and configuration are preserved.

Installation is transactional. All eleven managed artifacts and the config
candidate are staged and validated before the running services are stopped.
Each destination is then published through a temporary file in the same
directory. Existing files use an atomic exchange whose displaced bytes are
validated against the snapshot; initially absent files use an atomic
no-replace operation. The previous regular-file contents, modes, config,
manifest, and service state are restored if any later step fails. Config
publication uses the same exchange-and-validate rule. The installer lock and
private state live under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/arch-lidswitch/
├── current.manifest  # SHA-256 and mode for all eleven managed artifacts
├── transactions/     # Transaction work; normally empty after completion
└── backups/          # Complete pre-install rollback sets
```

When `XDG_STATE_HOME` is set, it must be an absolute path.

The state and backup directories are mode `0700`; the current manifest and
transaction metadata are mode `0600`. After committing the new installation,
the installer makes a best-effort attempt to prune older complete rollback sets
and normally retains only the newest one. A stale complete set can remain when
cleanup is denied; this does not roll back an already validated, running
installation, and uninstallation removes the whole private state root. This
rollback handles ordinary installer errors and termination; it does not claim
recovery from `SIGKILL`, power loss, or storage failure during publication.

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

The main service owns the auxiliary resume listener: starting or stopping
`lid-monitor.service` starts or stops the listener with it. The listener is a
static unit and is not enabled independently.

### Manual Testing

Dry-run mode queries the real lid/topology inputs and reports its intended
`action`, `decision`, `internal_output`, `internal_enabled`,
`enabled_external_count`, desired DPMS state, and topology. It does not create
or consume a layout snapshot, change display or power state, run the
post-layout hook, or perform postcondition mutations.

```bash
# Preview explicit close behavior without changing state
~/.config/hypr/scripts/lid-switch.sh --dry-run close

# Preview explicit open behavior without changing state
~/.config/hypr/scripts/lid-switch.sh --dry-run open

# Preview the decision for the currently observed lid state
~/.config/hypr/scripts/lid-switch.sh --dry-run
```

The normal close, open, auto-detect, `--once`, and `--resume-once` commands
below may change display state. They do not suspend or hibernate the system;
physical lid events and their systemd-logind policy are a separate boundary.

```bash
# Apply explicit lid close behavior
~/.config/hypr/scripts/lid-switch.sh close

# Apply explicit lid open behavior
~/.config/hypr/scripts/lid-switch.sh open

# Apply behavior for the currently observed lid state
~/.config/hypr/scripts/lid-switch.sh

# Reconcile the current lid and topology once, then exit
~/.config/hypr/scripts/lid-monitor.sh --once

# Exercise the bounded stable resume reconciliation path once
~/.config/hypr/scripts/lid-monitor.sh --resume-once
```

The `--print-state` command and the power-policy doctor are read-only: they do
not change display or power state.

```bash
# Inspect lid state
~/.config/hypr/scripts/lid-monitor.sh --print-state

# Inspect an alternate ACPI lid root
HYPR_LID_STATE_ROOT=/path/to/button/lid \
  ~/.config/hypr/scripts/lid-monitor.sh --print-state

# Inspect effective power policy and capabilities
~/.config/hypr/scripts/lid-switch-doctor.sh
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

# Follow the lifetime login1 resume listener
journalctl --user -u lid-resume-monitor.service -f -o cat
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

3. **Check the required Lua display APIs without changing the layout**:
   ```bash
   hyprctl eval 'assert(type(hl) == "table" and type(hl.monitor) == "function" and type(hl.dispatch) == "function" and type(hl.dsp) == "table" and type(hl.dsp.dpms) == "function", "required Hyprland Lua APIs unavailable")'
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

1. **List every represented output, including inactive outputs**:
   ```bash
   hyprctl -j monitors all | jq \
     '.[] | {name, enabled: (.disabled == false), disabled, dpmsStatus}'
   ```

2. **Rerun the installer with the internal identity selected explicitly**:
   ```bash
   HYPR_LID_INTERNAL_OUTPUT=your-internal-output \
     ./install-hyprland-lid-switch.sh
   ```

Do not edit only the installed `lid-switch.sh`: the CLI and daemon must share
the same internal identity, and rerunning the installer updates both.

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

arch-lidswitch does not inspect, signal, hide, reload, or restart Waybar. Preserving
external-output geometry avoids the original destructive layout rewrite. If a
bar still retains stale layer geometry, configure the optional post-layout hook
below with a refresh command supported by that bar and its current configuration.

## Customization

### Optional Post-Layout Hook

The default runtime has no process-specific refresh behavior. To run your own
integration after a successful internal-display layout change, create this
user-owned environment file:

```text
~/.config/arch-lidswitch/environment
```

Set one absolute executable path in it; environment-file values do not expand
shell variables:

```text
ARCH_LIDSWITCH_POST_LAYOUT_HOOK=/home/your-user/.local/bin/refresh-layout
```

Then restart the main service:

```bash
systemctl --user restart lid-monitor.service
```

The installer and uninstaller never create, modify, or remove this environment
file. The configured path must be absolute, regular, and executable. The hook is
invoked directly, without shell evaluation, with exactly three arguments:

```text
ACTION OUTCOME INTERNAL_OUTPUT
```

For example, a docked close supplies `close disabled eDP-1`; reopening supplies
`open enabled eDP-1`. Invocation occurs exactly once after the layout mutation
and its monitor postconditions have succeeded. No hook runs for a no-op, a
failed transition, or a DPMS-only wake. Runtime is limited to two seconds, with
a one-second forced-termination grace period. Invalid hooks, failures, and
timeouts are logged but advisory: they do not fail or retry display
reconciliation.

### Workspace Assignment Scope

Display geometry and workspace placement are separate responsibilities.
arch-lidswitch preserves only the internal output's geometry.
It does not capture or restore workspace-to-monitor assignments. When an output
is disabled, Hyprland may move its workspaces and windows to another output;
reopening the lid does not move them back automatically, including in
multi-external-monitor setups.

Use Hyprland workspace rules when assignments must be deterministic. The
optional post-layout hook can run additional user-specific placement logic, but
workspace restoration is not part of the built-in contract.

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
# Stop and disable the main service (which owns the static resume listener)
systemctl --user stop lid-monitor.service
systemctl --user disable lid-monitor.service

# Remove files
rm -f ~/.config/hypr/scripts/lid-state.sh
rm -f ~/.config/hypr/scripts/monitor-state.sh
rm -f ~/.config/hypr/scripts/lid-switch.sh
rm -f ~/.config/hypr/scripts/lid-switch-doctor.sh
rm -f ~/.config/hypr/scripts/lid-monitor.sh
rm -f ~/.config/hypr/scripts/lid-resume-monitor.sh
rm -f ~/.config/hypr/scripts/lid-session-bridge.sh
rm -f ~/.config/hypr/arch_lidswitch/session.lua
rm -f ~/.config/systemd/user/hyprland-session.target
rm -f ~/.config/systemd/user/lid-monitor.service
rm -f ~/.config/systemd/user/lid-resume-monitor.service

# Reload systemd
systemctl --user daemon-reload

# Remove the installer manifest and retained rollback set
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/arch-lidswitch"
```

Remove the exact block between `BEGIN arch-lidswitch managed session integration`
and `END arch-lidswitch managed session integration` from
`~/.config/hypr/hyprland.lua` as well. Do not remove surrounding user-owned Lua.

No separate runtime log files need removal. Existing journal records expire
according to the host's systemd-journald retention policy.
