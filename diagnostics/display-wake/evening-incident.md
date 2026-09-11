# Office-to-home display failure, 2026-09-11

## Conclusion

This incident establishes a reproducible undock-policy defect and a later
physical-output restoration failure. It does not establish that a single
underlying fault caused both, or that it shares the morning incident's root
cause.

The lid service counted Hyprland's synthetic `FALLBACK` output as an external
monitor. It therefore kept the internal panel disabled after the real office
monitor was disconnected. That left no enabled physical output during travel.
At home, invalid monitor observations prevented reconciliation, including
processing the lid opening. After the home dock was unplugged, the service
restored the panel according to Hyprland, but the kernel continued reporting
its connector disabled. The service detected persistent output-state
disagreement and did not attempt further recovery, as documented by its
current validation-only design.

The defect is specifically treating the compositor's synthetic fallback as
evidence of an external display. Hyprland v0.56.2 creates it using its headless
backend when the last active monitor is removed. See
[FallbackState.cpp](https://raw.githubusercontent.com/hyprwm/Hyprland/v0.56.2/src/state/FallbackState.cpp),
particularly the monitor-removal handler and `initOutput`.

## Timeline and evidence

Times are local, UTC+03:00. Failed boot:
`e7b7903c5fc640adaeeed972d809e70d`.
Private extracts are in `captures/incident-20260911-evening/`.

| Time | Observed event |
| --- | --- |
| 19:13:46 | Office DisplayPort MST connection removed. |
| 19:13:47 | Lid closed; eDP-1 disabled; only `FALLBACK` represented as an enabled external. Service logs `enabled_external_count=1`, `desired_internal=disabled`, and `layout_noop`. |
| 19:23:43 | logind accepted a user-session `systemctl` suspend request; s2idle began. The roughly ten-minute delay is consistent with the configured idle timer, although its process parent was not captured. |
| 20:27:47 | Resume completed. Home USB devices began enumeration. Lid service received the resume event but rejected monitor topology. |
| 20:27:48–20:27:59 | All 40 resume stability samples failed observation; reconciliation entered cooldown. |
| Before 20:28:40 | User opened the lid while still docked; internal panel also stayed blank. Exact physical opening time is not preserved in the available service logs. |
| 20:28:40 | User disconnected the home dock as a recovery attempt. |
| 20:28:41 | First valid joint observation after the error interval; service now logs lid open with eDP-1 disabled and `FALLBACK` enabled. |
| 20:28:42 | Internal restore changes Hyprland topology to enabled eDP-1 with no external output. Disappearance of `FALLBACK` causes a generation-mismatch result and restabilization. |
| 20:28:43 | Hyprland reports eDP-1 enabled and DPMS on; kernel reports `card1-eDP-1/enabled=disabled`. Validation enters pending. |
| 20:28:44 | Reconciliation verifies the compositor state, still with pending independent validation. |
| 20:28:45 | Validation becomes degraded: `persistent_disagreement`, compositor enabled/DPMS true, kernel disabled. No recovery-to-agreement event appears before shutdown. |
| 20:29:21 | logind receives a short power-key press and performs orderly shutdown. |
| 20:29:56 | New boot begins. |

There were 81 topology-observation failures before the 20:28:41 recovery of
valid observations. The raw rejected monitor JSON is unavailable, so the exact
validation predicate that failed cannot be identified.

The reported lid timestamp does not contradict the user's order of actions.
`runtime/lid-monitor.sh` reads lid and topology together; its polling loop
continues without logging a lid change or reconciling it when joint observation
fails. Thus an invalid external-output record can prevent internal-panel
restoration while the lid is already open.

The machine resumed and continued running services. Hyprlock processed
authentication attempts, and logind responded to the power button. It was not
a total system hang. Later authentication failures caused a temporary account
lockout; those occurred after the displays were already blank and cannot
explain the initial display failure. No Hyprland or Hyprlock crash was found
in the incident window; Spotify did crash during USB enumeration.

After reboot, the home Dell U2715H appears as DP-3 at 2560x1440, approximately
60 Hz. Both it and eDP-1 are enabled in compositor and kernel state. USB-C
`unknown error 256` and USB Billboard devices appear in this working boot too,
so those messages alone do not establish a failed cable or alternate-mode
negotiation. The Silicon Motion USB device's presence alone also does not
establish that the working external screen uses USB graphics: the working
display is exposed through the AMD DRM card as DP-3.

## Offline reproduction of the policy defect

```bash
bash diagnostics/display-wake/replay-fallback.sh
```

This invokes the real runtime CLI in dry-run mode inside a temporary directory.
A fake compositor supplies only monitor observations and rejects other
commands. The fixture is reconstructed from the normalized 19:13:47 journal
record; it is not a raw `hyprctl` dump. Only parser-consumed fields are rebuilt.

Observed result, exit status 1:

```text
With FALLBACK:    decision=disable_internal enabled_external_count=1
Without FALLBACK: decision=enable_internal  enabled_external_count=0
FAIL: the synthetic FALLBACK output keeps the panel disabled.
```

The control changes only the presence of the synthetic output. This reproduces
the wrong undock decision without touching the live displays. It does not
reproduce the hardware failure after resume and must not be presented as proof
that correcting classification fixes every black screen.

`monitor-state.sh` matches the installed copy. The installed lid daemon and
CLI match the source templates after substituting the internal output name.

## Relationship to the morning failure and next correction

Both incidents show monitor observations rejected while a dock is present and
display restoration that does not produce the expected result. This evening
adds direct kernel/compositor disagreement for the internal panel and the
earlier fallback classification error. The morning evidence does not show that
same disagreement or establish fallback classification as its cause.

The first correction should prevent the compositor-owned synthetic fallback
from satisfying the external-display condition. It must remain distinguishable
from user-created virtual outputs and the service's own recovery output, and
must be tested with last-physical-output removal and recovery. The current
README explicitly classifies every represented non-internal output as external,
so this requires a documented exception rather than an undocumented filter.

That correction addresses the proven undock-policy defect. The invalid raw
topology and the failed kernel enablement still need capture to attribute the
later failure to a specific compositor/backend/driver operation. Existing
kernel enablement corroborates encoder attachment, not physical illumination.
No live display settings or installed runtime files were changed during this
investigation.

## Classification correction in the checkout

The runtime now excludes the exact reserved name `FALLBACK` from its normal
external-output list and lid/topology fingerprints. The offline replay passes.
Installed-CLI regression tests cover fallback-only undocking, a physical output
alongside fallback, and intentional virtual outputs including similar names.
Deliberately removing or broadening the exclusion makes the relevant tests
fail. The generated installer and README reflect the new classification.

This correction is not a resolution of the remaining display-restoration
failure. Invalid raw topology and persistent compositor/kernel disagreement
remain open; no new kernel recovery action was added and the live installation
has not been updated as part of this change.
