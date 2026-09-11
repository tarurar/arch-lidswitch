# Upstream submission route

Published 2026-09-11 as `tarurar`, with the user's approval:
[report comment on Aquamarine #386](https://github.com/hyprwm/aquamarine/issues/386#issuecomment-5639634852).

Recommended destination: an additional evidence comment on
[Aquamarine #386](https://github.com/hyprwm/aquamarine/issues/386), which already
describes the stale kernel CRTC assignment, rejected modesets, and enabled
0x0 outputs. [#394](https://github.com/hyprwm/aquamarine/issues/394) independently
describes the same cross-port trigger on a Framework AMD laptop; the prepared
comment links it. Creating another issue would duplicate these reports.

The published report body is [upstream-report.md](upstream-report.md).

GitHub checks confirmed that `hyprwm/aquamarine` is public, not archived, and
has issues enabled. The local `gh` CLI is authenticated as `tarurar` and can
read its issues. No repository-specific issue-template directory was found.
The approved comment was successfully published using `gh`.

The publication command was (already completed; do not rerun):

```sh
gh issue comment 386 --repo hyprwm/aquamarine \
  --body-file diagnostics/display-wake/upstream-report.md
```

Use the published comment URL above to follow the discussion. Do not duplicate
the report on the same issue or open another issue for this reproduction.

Related patch status: [PR #395](https://github.com/hyprwm/aquamarine/pull/395)
is closed and unmerged. Its automated comment says it was closed because the
contributor was not vouched; this is not a maintainer verdict that the bug
does not exist. [Issue #396](https://github.com/hyprwm/aquamarine/issues/396)
contains the contributor's proposed workaround. We have not installed or
validated that patch, and this reporting workflow does not require doing so.

The previous custom-build plan is superseded by the user's preference to
remain on maintained packages and leave implementation to upstream developers.
