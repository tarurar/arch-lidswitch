# USB-C port-switch workaround

For the external display going blank after moving the same dock cable to
another USB-C port. This workaround was tested with the home dock and Dell
U2715H on 2026-09-11; it does not establish a workaround for the separate
morning wake/restoration incident.

## If the external screen is already blank

Reconnect the dock to the port that worked earlier in the same Hyprland
session. This restored the external screen in our tests without a reboot.

## Before moving the dock to another port

1. Open the laptop lid and confirm the internal screen works. Leave the dock
   connected to the working port for now.
2. Identify the currently connected external output:

   ```bash
   hyprctl monitors
   ```

   With the home dock, the observed names were:

   | Current port | External output |
   | --- | --- |
   | Left | DP-3 |
   | Right | DP-2 |

   Confirm the name before using a command below. These names are not a
   universal mapping and must not be assumed for the office dock. Keep the
   internal output, eDP-1, enabled.

3. In a terminal inside Hyprland, disable only the current external output.
   Run the command for the port the dock is connected to **now**:

   From the left port:

   ```bash
   hyprctl eval 'hl.monitor({ output = "DP-3", disabled = true })'
   ```

   From the right port:

   ```bash
   hyprctl eval 'hl.monitor({ output = "DP-2", disabled = true })'
   ```

4. Wait for the external screen to go dark. The laptop screen should remain
   usable. Unplug the dock and connect it to the other port.
5. Once the external screen works on the new port, clear the temporary
   disable rule by reloading your saved configuration:

   ```bash
   hyprctl reload
   ```

   This does not restart Hyprland. The workaround does not edit configuration
   files. If you cancel the switch or return to the original port, also run
   this command to clear its temporary disable rule.

## What was verified

The sequence **left → disable DP-3 → move right → reload** succeeded: the
kernel released the old display-controller assignment, the right output
activated at 2560x1440, and the internal screen kept working. The reverse
direction follows the same proposed procedure but has not been tested.

The temporary disable must happen while the old output is still connected.
Running `hyprctl reload` alone after the failure is not the procedure we
validated.

See the [incident evidence](port-switch-incident.md) and our
[upstream report](https://github.com/hyprwm/aquamarine/issues/386#issuecomment-5639634852).
