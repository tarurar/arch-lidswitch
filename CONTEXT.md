# Lid and display state

Language for lid-driven display policy and the evidence used to assess its
outcome.

## Language

**Compositor-reported restoration**:
The compositor reports that the internal output meets the requested enabled
and power state. This does not establish that the panel displays pixels.

**Output-state disagreement**:
The compositor reports the internal output enabled and powered on while the
corresponding kernel connector reports it disabled.

**Persistent disagreement**:
Output-state disagreement that remains observable throughout the settling
period for an unchanged lid and display topology.

**Degraded validation**:
A restoration assessment with persistent output-state disagreement. It is
distinct from failure to apply the compositor's requested display state.

**Validation unavailable**:
An independent restoration assessment cannot be made because the internal
output cannot be mapped unambiguously to readable kernel connector state.
It establishes neither agreement nor disagreement.
