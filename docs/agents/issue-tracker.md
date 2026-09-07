# Issue tracker: GitHub

Issues and specs live in GitHub Issues for `tarurar/arch-lidswitch`.
Use the `gh` CLI with `--repo tarurar/arch-lidswitch` to target this
repository explicitly, since the clone also has an upstream remote.

## Conventions

- Create: `gh issue create --repo tarurar/arch-lidswitch --title "..." --body-file <file>`
- Read: `gh issue view <number> --repo tarurar/arch-lidswitch --comments`
- List: `gh issue list --repo tarurar/arch-lidswitch --state open --json number,title,body,labels,comments`
- Comment: `gh issue comment <number> --repo tarurar/arch-lidswitch --body-file <file>`
- Label: `gh issue edit <number> --repo tarurar/arch-lidswitch --add-label "..."` or `--remove-label "..."`
- Close: `gh issue close <number> --repo tarurar/arch-lidswitch --comment "..."`

For multiline bodies, write the exact Markdown to a temporary file
and pass it with `--body-file`.

When a skill says "publish to the issue tracker", create a GitHub issue.
When it says "fetch the relevant ticket", read the issue with comments.

## Pull requests as a triage surface

**PRs as a request surface: no.**

GitHub issues and PRs share a number space. If a reference is ambiguous,
resolve its type before acting.

## Wayfinding operations

- Map: one issue labeled `wayfinder:map`, containing Notes,
  Decisions-so-far, and Fog.
- Child tickets: link them as GitHub sub-issues. If unavailable, use
  a task list in the map and `Part of #<map>` in each child.
  Label children `wayfinder:<type>` where type is `research`,
  `prototype`, `grilling`, or `task`.
- Blocking: use native GitHub issue dependencies when available;
  otherwise record `Blocked by: #<n>, #<n>` in the child.
  A ticket is unblocked when all blockers are closed.
- Frontier: select the first open, unassigned, unblocked child in map order.
- Claim: assign the ticket to the driving developer.
- Resolve: comment with the answer, close the child, and append a
  concise finding and link to the map's Decisions-so-far.
