Additional reproduction on Framework Laptop 13 AMD Ryzen AI 300, with a
controlled experiment showing that releasing the old output before unplugging
allows the other USB-C port to work. The port-switch symptom also matches
[#394](https://github.com/hyprwm/aquamarine/issues/394).

### Environment

- Arch Linux; kernel `7.2.3-arch1-3`, driver `amdgpu`.
- Aquamarine `0.15.0-2`; Hyprland `0.56.2-2`.
- Framework Laptop 13 AMD Ryzen AI 300 Series, Radeon 880M/890M graphics.
- Internal eDP-1: 2880x1920 at 120 Hz, scale 2.
- One Dell U2715H external monitor through a USB-C dock, preferred
  2560x1440 at approximately 60 Hz. Dock retail model not recorded.
- Same dock, cable, and external monitor throughout. Left port maps to
  DP-3; right port maps to DP-2 in this session.
- Lid open and internal display working throughout. No lock or suspend
  required. An installed lid service logged no layout changes during the
  original switch; it was not disabled for this experiment.

### Reproduction and failed state

1. Use the working external monitor on the left USB-C port (DP-3).
2. Unplug the dock and connect the same cable to the right USB-C port (DP-2).
3. The Dell is detected with its supported modes, but stays blank. The
   internal screen continues working.
4. Moving the dock back left restores the external screen without restarting
   Hyprland or rebooting.

Observed on the original occurrence and one subsequent repeat. This is not
a claim of a measured failure rate over many trials.

In the repeated failed state, `hyprctl -j monitors all` reports DP-2 as:

```json
{"name":"DP-2","width":0,"height":0,"refreshRate":60,"disabled":false,"dpmsStatus":true}
```

The contemporaneous kernel state disagrees:

| Connector | status | enabled | dpms |
| --- | --- | --- | --- |
| card1-eDP-1 | connected | enabled | On |
| card1-DP-2 | connected | disabled | Off |
| card1-DP-3 | disconnected | enabled | On |

Read-only `modetest -M amdgpu -c -e -p` confirms that disconnected DP-3
(connector 470) still references encoder 469, which still references CRTC
437. Connected DP-2 (connector 464) has encoder 0.

The backend log shows the following sequence (intervening lines omitted):

```text
drm: Connector DP-3 disconnected
drm: Cannot commit a disconnected output
drm: DP-3 is not connected, clearing stale crtc 437
drm: connected slot 1 crtc 437 assigned to DP-2
drm: Connector DP-2 connected
atomic drm request: failed to commit: Invalid argument, flags: ATOMIC_ALLOW_MODESET ATOMIC_TEST_ONLY
drm: atomic commit failed with max_bpc set, retrying without max_bpc
```

In the original failed DP-2 connection block there are 330 atomic `Invalid
argument` messages: 328 test-only and two real commit failures. Mode selection
walks down to 720x400 at 70.08 Hz; the real commit also fails. The subsequent
successful left-port connection uses 2560x1440 at 59.95 Hz with no atomic
`Invalid argument` messages in that connection block.

### Controlled experiment: disable before unplugging

After returning to the working left port, with the lid still open, I ran:

```sh
hyprctl eval 'hl.monitor({ output = "DP-3", disabled = true })'
```

Before unplugging, the kernel reported DP-3 connected but disabled/Off.
`modetest` now showed connector 470 with encoder 0 and encoder 469 with
CRTC 0: the old assignment had been released.

I then moved the same cable to the right port. The external desktop visibly
appeared at 2560x1440. DP-2 was connected/enabled/On in the kernel and
enabled at 2560x1440 in Hyprland. Old DP-3 was disconnected/disabled/Off.
There were zero atomic `Invalid argument` messages in this DP-2 connection
block. The internal screen kept working. This control was performed once.

Afterwards, `hyprctl reload` cleared the temporary monitor rule; both the
internal screen and right-port external output remained enabled.

This supports stale kernel assignment during disconnect as the mechanism
for this reproduction. I have not tested a patched build, bisected versions,
or captured the driver's detailed atomic validation reason. I am reporting
against the stock packages and would prefer a maintained upstream fix.

AI assistance was used to collect and analyze the local diagnostics and draft
this report. Physical cable changes and visible-screen observations were
performed by me. The excerpts omit monitor serials and unrelated session data.
