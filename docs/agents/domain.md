# Domain docs

This repository uses a single-context layout:

- `CONTEXT.md`: domain vocabulary at the repo root.
- `docs/adr/`: architecture decision records.

## Before exploring

Read `CONTEXT.md` and the ADRs relevant to the area being explored.

If these files do not exist, proceed silently. The `domain-modeling`
skill creates them lazily when terms or decisions are resolved.

## Use the glossary's vocabulary

Use the terms defined in `CONTEXT.md` in issue titles, proposals,
hypotheses, and test names.

If a needed concept is missing, reconsider whether it belongs to the
project's vocabulary or note the gap for `domain-modeling`.

## Surface ADR conflicts

If a proposal contradicts an existing ADR, identify the decision
and explain why it should be reconsidered.
