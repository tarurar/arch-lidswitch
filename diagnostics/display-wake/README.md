# Display wake incident: 2026-09-11

## Findings

The failure followed an idle suspend/resume while docked with the lid closed.
The external monitor remained represented by Hyprland, and was eventually
reported enabled with DPMS on despite the user seeing a blank screen. The
surviving evidence does **not** identify the root cause inside the compositor,
graphics driver, or dock/display link. No hardware reproduction has been run.

There is one external Philips PHL24E1N5300 and the laptop panel. The user
confirmed that the dock disconnections below were deliberate recovery attempts.
They happened after the original failure.

All times below are local, UTC+03:00. Previous boot ID:
`443f0b015c8f48779f1f27f04ff4cabf`.

The relevant original journal extracts are saved locally under
`captures/incident-20260911/`: `lidswitch.log`, `sleep.log`, and
`kernel-display.log`. These private evidence files are ignored by Git.

| Time | Evidence |
| --- | --- |
| 09:44:02 | Morning resume completed. |
| 09:44:05 | Lid closed; eDP-1 disabled; DP-11 enabled and DPMS on, 1920x1080 at 74.973 Hz. Lid reconciliation made no display change. |
| 09:58:13 | logind accepted suspend from a user-session `systemctl` process. Kernel entered s2idle. Hypridle configuration requests suspend after 600 seconds idle; this is consistent with that timer, although the journal does not establish the caller's parent process. |
| 10:08:07 | Resume completed. |
| 10:08:09 | DP-11 remained enabled but DPMS was off. eDP-1 remained disabled. Lid reconciliation was a no-op and preserved external state. |
| 10:08:35 | Lid opened. DP-11 was now reported enabled with DPMS on. This does not prove physical illumination. |
| 10:08:36–10:08:47 | Seven internal-panel reconciliation attempts failed their postcondition: Hyprland still reported eDP-1 disabled. Repeated Waybar refreshes also eventually failed; that is a later, separate symptom. |
| 10:08:49–10:08:50 | Dock disconnected. eDP-1 became enabled in both Hyprland and kernel state; internal restoration verified. |
| 10:08:59 | Following reconnection, monitor observations started failing with `monitor_topology_invalid`. |
| 10:09:15–10:09:16 | Another dock disconnect; internal validation returned to agreement. |
| 10:09:45–10:09:46 | Dock reconnected; monitor observation failures returned. |
| 10:12:41–10:13:08 | Shutdown followed by a fresh boot. |

There were 182 `monitor_topology_invalid` observations between 10:08:59 and
10:12:34, interrupted by the second disconnect. Additional failures continued
during the last seconds before shutdown. The parser uses this error for several
conditions: malformed JSON, missing/duplicate output identity, invalid state
fields, or invalid enabled-output geometry. It does not save the rejected raw
snapshot or identify the specific field. Consequently we cannot infer which
condition occurred, or whether the parser was too restrictive.

Installed `monitor-state.sh` matches this checkout. Its parser is in
`runtime/monitor-state.sh`, function `monitor_state_observe_topology`.

The current configuration turns displays off after 420 seconds idle and back on
when activity resumes. Its `after_sleep_cmd` is empty. That can explain a delay
before a wake command, but does not by itself explain the persistent blank
screen after DPMS was reported on, or the later invalid monitor observations.

The kernel recorded USB-C errors during recovery, but an `unknown error 256`
also appeared during the successful morning resume. It is not sufficient to
attribute this incident to the dock. The message `Differing MST start` is an
informational branch returning success in the
[AMD driver source](https://github.com/RadeonOpenCompute/ROCK-Kernel-Driver/blob/master/drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm_helpers.c),
not proof of an MST failure.

No GPU reset/timeout or Hyprlock crash was found in the inspected incident
window. Absence of these messages does not exclude a graphics or locker fault.
The user could eventually see the laptop panel, but the old workspace/focus
state was not captured, so its feeling like a secondary screen cannot be
diagnosed from the saved topology alone.

Both boots used Linux 7.2.3-arch1-3. Current packages: Hyprland 0.56.2-2,
Aquamarine 0.15.0-2, Hypridle 0.1.8-2, Hyprlock 0.9.6-3. No relevant package
upgrade appears between the incident and reboot. After reboot, the external
screen is DP-10, 1920x1080 at 74.973 Hz, positioned at 1440x0; both panels are
enabled in compositor and kernel state.

## Evidence limit

Hyprland currently reports `debug:disable_logs=true` (default). Previous
runtime logs did not survive reboot, and SDDM's session log was replaced.
The external connector's kernel state during the failure and the rejected
monitor JSON were not captured. Reboot reset several layers simultaneously;
its success does not identify which layer failed.

This is a retrospective investigation, not a verified fix. A mock test cannot
establish that this physical monitor displays pixels. The next step is to
capture the real hardware transition before choosing a change.

## Controlled test result: 2026-09-11 afternoon

Capture: `captures/20260911T132707.QGdsTd/`.
The user reported successful authentication on the external screen without
opening the lid or reconnecting the dock: `EXTERNAL_BLANK=no`.

- 13:27:07: lid closed, internal panel disabled, DP-10 enabled and powered on
  in compositor and kernel state.
- 13:34:28: DPMS turned DP-10 off; its kernel connector remained connected
  but became disabled. This is an observed healthy idle transition.
- 13:37:28: kernel entered s2idle.
- 14:11:03: resume completed, after approximately 34 minutes asleep.
- 14:11:05: lid reconciliation was a no-op, with the external output enabled
  and DPMS still off. This also occurred during the morning failure, so that
  immediate post-resume state alone does not distinguish failure from success.
- 14:12:19: final capture showed DP-10 enabled and powered on in both compositor
  and kernel state; the lid remained closed.

The captured lid-service journal contains no topology-observation or
reconciliation failures. The `Differing MST start` message also occurred in
this successful run. Neither it nor a briefly powered-off external output
after resume is sufficient evidence for the morning root cause.

The original recorder had a limitation: its Bash `SECONDS` deadline expired
during the long sleep. Its 301 periodic samples end at 13:37:26, so this capture
lacks immediate post-wake kernel snapshots and backend history. The final
snapshot, journal extracts, and user observations remain valid evidence of a
successful cycle. The recorder now limits the number of samples instead of
elapsed time, preserving its remaining budget across suspend. A harness using
the actual recording loop and an injected clock advance stopped after one
sample before the change and completed all 900 samples afterward.

This run did not reproduce the incident or establish a root cause. Another
capture during a naturally recurring failure or another controlled cycle is
needed; one successful cycle cannot exclude an intermittent fault. No display,
idle, or power-policy settings were changed.

## Run the prepared test later

From this checkout, in a terminal inside the Hyprland session:

```bash
bash diagnostics/display-wake/capture.sh --test
```

Save work first: the physical failure may recur. The script asks you to close
the lid with the working external monitor connected, lock normally, leave the
machine idle for at least 11 minutes, then wake and attempt authentication.
It does not issue lock, suspend, DPMS, monitor-layout, or unlock commands.

During a failure, leave the dock connected for 20 seconds to capture the failed
state before changing hardware. Then open the lid if necessary. Do not enter
passwords into diagnostic prompts. If you must reboot, existing capture files
remain on disk; post-test prompts and final journal extraction will not run.

The capture records monitor JSON, kernel connector status/enablement/DPMS,
lid state, and filtered graphics-backend rolling logs. It samples approximately
every two seconds, with bounded compositor queries, for at most 900 samples
(roughly 30 minutes awake; longer if queries are slow). Sampling pauses during
sleep without consuming the remaining sample budget.
Only the latest backend rolling-log snapshot is retained during recording, so
finish the test promptly after recovering visibility. Report whether the
external monitor actually displayed pixels; software state alone is not a
pass/fail oracle for this symptom.

Results are private directories under `diagnostics/display-wake/captures/`,
ignored by Git and preserved across reboot. Monitor identity/serial information
may be present: review/redact before sharing publicly. No persistent system
configuration is changed. Ctrl+C stops the recorder.

For a read-only baseline without a physical test:

```bash
bash diagnostics/display-wake/capture.sh --snapshot
```

The baseline command was run successfully during preparation. That verifies
capture access and format only; it does not reproduce or fix the incident.
