---
status: accepted
---

# Use monotonic UUIDv7 message IDs

## Context and Problem Statement

Message IDs are used for duplicate filtering and diagnostics during transfer.
Random GUID generation did not provide monotonic ordering, which made
time-correlated troubleshooting and deterministic ordering checks less direct.

## Considered Options

* Keep random GUID message IDs.
* Generate monotonic UUIDv7 message IDs.

## Decision Outcome

Chosen option: "Generate monotonic UUIDv7 message IDs". Message creation now
uses UUIDv7 semantics with monotonic progression in same-millisecond
generation, including counter rollover behavior.

### Consequences

* Good, because IDs remain globally unique while preserving chronological sort
  order for diagnostics and analysis.
* Good, because wire compatibility is preserved: `MessageId` remains a string
  field and requires no envelope schema change.
* Bad, because implementation complexity is higher than a simple GUID call and
  must be covered by deterministic tests.

### Confirmation

See UUIDv7 generation and message creation in
[KlipAroundProtocol.ps1](../../Private/KlipAroundProtocol.ps1), and monotonic
format/rollover tests in
[KlipAround.Tests.ps1](../../Tests/KlipAround.Tests.ps1).
