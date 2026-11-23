---
status: accepted
---

# Enforce fail-closed protocol validation guardrails

## Context and Problem Statement

Phase 1 of protocol hardening addressed injection and malformed-payload risks on
the shared clipboard channel. The prior behavior tolerated more malformed
messages and weaker ACK invariants than needed, which increased the chance of
resource pressure or invalid state progression.

## Decision Drivers

* Reduce exploitability from oversized or malformed envelopes and blocks.
* Prevent impossible ACK transitions from altering sender progress state.
* Keep protocol behavior compatible for valid peers while failing closed on
  invalid messages.

## Considered Options

* Add strict guardrails and fail closed on invalid protocol data.
* Keep permissive parsing and attempt best-effort recovery from malformed
  messages.

## Decision Outcome

Chosen option: "Add strict guardrails and fail closed on invalid protocol
data". The implementation enforces envelope and block size limits, validates
HELLO/FILE_META/ACK_REPORT invariants against active transfer state, and
rejects invalid transitions instead of continuing transfer progress.

### Consequences

* Good, because malformed or spoofed messages are rejected earlier with
  explicit failures.
* Good, because sender/receiver state transitions are better constrained to
  expected protocol semantics.
* Bad, because peers that relied on previously tolerated malformed fields now
  fail instead of proceeding.

### Confirmation

See protocol guardrails and wait/decode behavior in
[KlipAroundProtocol.ps1](../../Private/KlipAroundProtocol.ps1), ACK validation
in [Send-KlipAround.ps1](../../Public/Send-KlipAround.ps1), receiver metadata
checks in [Receive-KlipAround.ps1](../../Public/Receive-KlipAround.ps1), and
associated tests in [KlipAround.Tests.ps1](../../Tests/KlipAround.Tests.ps1).
