---
status: accepted
---

# Use versioned, single-Base64 framing and hash-based message tracking

## Context and Problem Statement

The original framing encoded data twice, expanding clipboard payloads.
Repeated copying and linear searches through message IDs also became more
expensive as sessions grew.

## Decision Drivers

* Reduce clipboard payload expansion and message lookup overhead.
* Reject incompatible messages rather than misinterpreting them.

## Considered Options

* Introduce protocol v2 with JSON envelopes and one Base64 layer for block data,
  and use hash sets for message IDs.
* Preserve the v1 framing and its wire compatibility.

## Decision Outcome

Chosen option: "Introduce protocol v2 with JSON envelopes and one Base64 layer
for block data, and use hash sets for message IDs". Envelopes use explicit
`KLIPAROUND/2` delimiters; sent and seen message IDs are tracked in hash sets.
The compatibility break was accepted in order to remove the redundant encoding.

### Consequences

* Good, because data expands by approximately one Base64 layer and ID lookup
  no longer requires repeated linear list searches.
* Bad, because v1 and v2 endpoints cannot interoperate; both endpoints must
  upgrade.

### Confirmation

See [KlipAroundProtocol.ps1](../../Private/KlipAroundProtocol.ps1),
[sender](../../Public/Send-KlipAround.ps1), and envelope expansion, v1
rejection, and duplicate-message tests in
[KlipAround.Tests.ps1](../../Tests/KlipAround.Tests.ps1).
