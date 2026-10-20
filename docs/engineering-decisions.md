# Engineering decision record

## Context

Burst/surge interference disconnected the PC USB measurement path.

## Decision

Keep acquisition scheduling separate from recovery experiments; address the physical path with USB isolation.

## Consequences and evidence

The USB isolator resolved the reported connection problem. Software restart behavior is a separate integration question.

See [architecture](architecture.md), [validation](validation.md) and the [case study](case-study.md) for implementation details and limits.
