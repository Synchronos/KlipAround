---
status: accepted
---

# Use a half-duplex clipboard protocol in a PowerShell module

## Context and Problem Statement

Files need to move between sessions where a shared clipboard, including Remote
Desktop clipboard redirection, may be the available communication channel.
Clipboard updates are shared, replace prior contents, and can be delayed.

## Decision Drivers

* Transfer multiple files reliably over a text clipboard without requiring a
  separate network service.
* Detect corruption and provide PowerShell-native commands.

## Considered Options

* Use a half-duplex, acknowledgment-driven clipboard protocol.

## Decision Outcome

Chosen option: "Use a half-duplex, acknowledgment-driven clipboard protocol".
Sender and receiver exchange `HELLO`, file metadata, windowed data bursts,
acknowledgments, file completion, and session completion messages. Files are
split into sequenced blocks; block checksums and a whole-file SHA-256 hash
detect corruption. File hashes are computed incrementally during transfer by
default; the sender also offers `-PrecomputeHash`. The commands operate as
functions in a PowerShell module.
The design is HDLC-inspired, not a serial/modem interoperability protocol.

### Consequences

* Good, because it works with a shared text clipboard and exposes scriptable
  commands for multiple files.
* Bad, because the clipboard is a single shared lane, both commands must remain
  running, and an interrupted command cannot resume after it exits.

### Confirmation

See the [protocol summary](../../README.md#protocol-summary),
[sender](../../Public/Send-KlipAround.ps1),
[receiver](../../Public/Receive-KlipAround.ps1), and transfer cases in
[KlipAround.Tests.ps1](../../Tests/KlipAround.Tests.ps1).
