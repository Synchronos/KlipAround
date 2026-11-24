---
status: accepted
---

# Add optional `-AuthKey` authenticated protocol mode

## Context and Problem Statement

KlipAround protocol messages travel over a shared clipboard channel where other
participants can overwrite or inject payloads. Phase 1 tightened fail-closed
validation, but unauthenticated sessions could still accept structurally valid
messages from non-participating peers. We needed message authenticity checks and
deterministic replay/mixed-mode behavior without breaking existing deployments
that rely on unauthenticated transfers.

## Considered Options

* Keep protocol validation only (no message authentication).
* Require authentication for every transfer by default.
* Add an optional shared-key authenticated mode (`-AuthKey`) with explicit
  mixed-mode rejection behavior.

## Decision Outcome

Chosen option: "Add an optional shared-key authenticated mode (`-AuthKey`) with
explicit mixed-mode rejection behavior".

The protocol now supports an authenticated session mode where each accepted
message carries HMAC-SHA256 signature metadata in `Payload.Auth`. Signature
validation uses canonicalized envelope fields and excludes only
`Payload.Auth.Signature` from digest input. The mode also binds sender/receiver
nonces across handshake and subsequent messages and rejects replayed auth
digests within a bounded window.

Unauthenticated mode remains supported for compatibility when `-AuthKey` is not
specified.

### Consequences

* Good, because authenticated sessions can reject unsigned, tampered, and
  replayed messages that otherwise match protocol shape.
* Good, because compatibility is preserved: existing scripts can continue to run
  without `-AuthKey` while enabling stronger guarantees when both peers opt in.
* Good, because mixed-mode behavior is deterministic (`AuthRequired`,
  signature-validation requirements, and nonce binding checks).
* Bad, because operational complexity increases: both endpoints must share the
  same secret and troubleshoot key mismatch/nonce-binding failures.
* Bad, because message processing costs increase due to per-message canonical
  digest generation and signature verification.

### Confirmation

Implementation and protocol behavior are documented and verified in:

* Protocol/auth helpers and authenticated wait/publish flow:
  [Private/KlipAroundProtocol.ps1](../../Private/KlipAroundProtocol.ps1)
* Sender authenticated session flow:
  [Public/Send-KlipAround.ps1](../../Public/Send-KlipAround.ps1)
* Receiver authenticated session flow:
  [Public/Receive-KlipAround.ps1](../../Public/Receive-KlipAround.ps1)
* Auth signature, unsigned-message rejection, and replay-digest tests:
  [Tests/KlipAround.Tests.ps1](../../Tests/KlipAround.Tests.ps1)
* Wire-level behavior and troubleshooting guidance:
  [docs/protocol-v2.md](../protocol-v2.md) and
  [docs/troubleshooting.md](../troubleshooting.md)
