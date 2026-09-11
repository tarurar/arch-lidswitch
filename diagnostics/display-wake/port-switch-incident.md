# Home dock port-switch failure, 2026-09-11

Status: stale display-controller assignment isolated by a successful controlled
experiment; upstream code fix not yet implemented or verified. The earlier
wake/restoration failure remains unresolved.
Times below are local (+03:00).

Upstream report: [published comment on Aquamarine #386](https://github.com/hyprwm/aquamarine/issues/386#issuecomment-5639634852),
posted as `tarurar` with the user's approval. Existing issues #386 and #394
cover the mechanism and port-switch trigger. The user chose upstream
maintenance rather than a custom build.

## Setup and user observation

- Home display: Dell U2715H, preferred 2560x1440 at approximately 60 Hz.
- Office display: Philips PHL24E1N5300. These are separate monitor/dock
  environments; findings from one must not automatically be attributed to the other.
- The home incident used the same dock, cable, and display throughout.
- Left USB-C port worked; right USB-C port did not light the external display.
- The laptop lid remained open and its internal screen continued working.
- Returning to the left port restored the external display without rebooting.

## Evidence

Boot ID: `23d004683ee945e986406c23236c2657`.

| Time | Observation |
| --- | --- |
| 21:31:57 | Left dock disconnected; service observed internal-only topology and made no layout change. |
| 21:32:05 | Right dock enumerated on USB buses 5/6; one hub reported `hub_ext_port_status failed (err = -71)` and re-enumerated. |
| 21:32:08 | DP-2 appeared; the service began rejecting invalid compositor topology. |
| 21:32:08–34 | 27 `monitor_topology_invalid` observations. |
| 21:32:34–35 | User disconnected right dock; valid internal-only topology returned. |
| 21:32:41 | Left dock enumerated on USB buses 7/8. |
| 21:32:43 | AMD driver warning in `dm_dp_aux_transfer` during EDID probing, after return to the left port. |
| 21:32:44–45 | DP-3 appeared and the service observed a healthy external layout; no layout change was needed. |

The preserved Hyprland file log provides additional evidence absent from
the lid-service journal. It has no wall-clock timestamps; connector event
order associates its DP-2 and DP-3 blocks with the journal sequence above.

- DP-2 was detected as the Dell and advertised 37 mode entries, including
  the preferred 2560x1440 mode. Display detection therefore progressed far
  enough to obtain the monitor description and mode list.
- Aquamarine assigned CRTC 437 to DP-2, then encountered 330 atomic DRM
  `Invalid argument` errors before DP-2 disconnected. Of those, 328 were
  test-only requests and two were actual commit attempts.
- Mode testing failed at the preferred resolution and at lower resolutions.
  The log eventually says `Modesetting DP-2 with 720x400@70.08Hz`, immediately
  followed by failed real commits. A modesetting log message alone does not
  establish successful display activation.
- Retries without `max_bpc` also failed. The retry warning does not establish
  that the color-depth property caused the problem.
- The subsequent DP-3 connection obtained the same Dell description and mode
  list, used CRTC 437, and modeset to 2560x1440 at 59.95 Hz. No atomic
  `Invalid argument` errors occur in that subsequent log block.

Private raw evidence is retained in the ignored directory
`captures/incident-20260911-port-switch/`. An additional failed-state snapshot is in
`captures/20260911T215107.nP0X28/`. Raw logs may contain personal data and
must be reviewed before sharing.

## Interpretation and limits

The immediate observed failure is rejection of the requested display state
at the compositor/backend–kernel modesetting boundary. The log does not
identify which atomic property or driver validation condition was rejected.
It cannot yet distinguish a compositor state defect, a driver defect, or
a USB-C/display-link state problem.

The lid service made no display changes during this transition, and no
lid-close or suspend was required. This incident does not demonstrate a
regression in the reserved `FALLBACK` classification fix.

The AMD warning occurred during the successful left-port recovery. Its
timing does not establish it as the cause of the earlier right-port failure.
Likewise, USB/UCSI errors alone are insufficient to assign causality.

The morning and evening incidents also included invalid topology, but
their failed-state raw monitor JSON and equivalent backend traces are
unavailable. A shared root cause remains possible, not confirmed.

Framework documents display support on both front and rear expansion-card
positions for this laptop generation: [manufacturer announcement](https://community.frame.work/t/introducing-the-framework-laptop-13-powered-by-amd-ryzen-ai-300-series/65007).
A right-side failure alone does not establish an unsupported display port
or damaged hardware.

## Next observation

### Live repeat captured at 21:51–21:54

The user repeated the switch before the continuous recorder started. Thus
`captures/port-retest-20260911T215134/` begins with the right port already
connected; it does not contain a sampled left-to-right transition. The
preserved backend log does include the preceding disconnect/connect events.

- Hyprland reports DP-2 `disabled=false`, `dpmsStatus=true`, but
  `width=0`, `height=0`.
- Kernel DP-2: connected, disabled, DPMS Off.
- Kernel DP-3: disconnected, enabled, DPMS On.
- Read-only `modetest -M amdgpu -c -e -p` confirms disconnected DP-3
  (connector 470) still references encoder 469, which references CRTC 437.
  Connected DP-2 (connector 464) has no encoder attached.
- The backend disconnect sequence logs `Cannot commit a disconnected output`,
  then clears its own stale CRTC 437 reference for DP-3 and assigns CRTC 437
  to DP-2. The kernel still retains the old DP-3 attachment.

This repeat establishes the exact invalid-topology field: an enabled external
output with zero dimensions, correctly rejected by `valid_layout` in the
runtime monitor parser. It also strengthens the hypothesis that incomplete
disconnect cleanup leaves a stale kernel assignment which conflicts with
the subsequent right-port modeset. It does not yet prove the causal link.

A controlled follow-up is proposed: return left, disable the external output
while still physically connected, verify the kernel releases its assignment,
then move right and check whether activation succeeds. This changes live
display state. The user approved and returned to the left port. Two attempts
to execute the temporary disable were rejected before process creation because
automatic permission review timed out (initial attempt plus the allowed retry).
No disable command was executed by the agent. The next step is for the user to
run the approved temporary disable locally, then capture kernel state before
moving right.

Matching [Aquamarine v0.15.0 source](https://github.com/hyprwm/aquamarine/blob/v0.15.0/src/backend/drm/DRM.cpp)
supports the proposed mechanism: `SDRMConnector::disconnect()` marks the
connector disconnected before emitting the output destroy event;
`CDRMOutput::commitState()` rejects commits for disconnected connectors,
including disable requests. Source inspection supports the hypothesis;
the controlled experiment is still needed to test its causal role here.

### Controlled experiment succeeded at 22:03

The user disabled DP-3 while the dock remained physically connected on the
left, using `hyprctl eval 'hl.monitor({ output = "DP-3", disabled = true })'`.
At 22:02:38, the kernel reported DP-3 connected but disabled, DPMS Off.
Before the next switch, read-only `modetest` verified that connector 470 had
encoder 0 and encoder 469 had CRTC 0: the old assignment was released.

The fresh recorder in `captures/clean-disconnect-20260911T220307/` captured:

| Time | Result |
| --- | --- |
| 22:03:07 | Internal display enabled; left DP-3 intentionally disabled. |
| 22:03:31 | Dock unplugged; internal-only compositor topology. |
| 22:03:39 | Right DP-2 enabled at 2560x1440, with DPMS on. |

The user confirmed that the external screen lit up. Kernel DP-2 was connected,
enabled, and On; old DP-3 was disconnected, disabled, and Off. The corresponding
DP-2 backend connection block contains zero atomic `Invalid argument` errors
and a successful preferred-mode activation. The same right port, dock, cable,
and Dell monitor now work after explicitly releasing the old assignment.

This isolates incomplete old-output cleanup as the causal mechanism for this
port-switch reproduction. The source ordering above is the leading code-level
explanation; no patched Aquamarine build has been tested. A blanket conclusion
about every earlier blank-screen incident is not justified by this experiment.

After the successful test, `hyprctl reload` returned `ok`, reloading the unchanged
configuration to clear the temporary DP-3 rule. No persistent monitor settings
were edited. The user can use the working right-port connection.

For another controlled cross-port move, explicitly disabling the currently
connected external output before unplugging is a demonstrated workaround in
this setup. Output names depend on the port and dock; do not blindly reuse
DP-3 for the office setup or when currently connected to DP-2.

### Original capture plan

Repeat the same left-to-right switch with the lid open while recording
compositor monitor JSON, kernel connector state, and backend logs. Leave
the dock on the failed right port long enough to capture it. Record visible
output separately: reported enabled/DPMS state cannot prove visible pixels.
This distinguishes the exact invalid topology from the activation failure
and provides a reproducible starting point for controlled follow-up tests.

The earlier wake/restoration investigation remains open independently.
