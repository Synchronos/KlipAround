---
status: accepted
---

# Require explicit consent before overwriting the clipboard in transport probes

## Context and Problem Statement

The transport preflight writes test data to the clipboard. A text snapshot is
not sufficient to restore images, files, rich text, or multiple clipboard
formats reliably.

## Considered Options

* Require explicit permission before replacing the clipboard and do not claim
  to restore it.
* Snapshot and restore clipboard text.

## Decision Outcome

Chosen option: "Require explicit permission before replacing the clipboard and
do not claim to restore it". `Test-KlipAroundTransport` does not access the
clipboard without `-NoRestoreClipboard`; with that switch, it performs the
round trip and leaves the probe on the clipboard.

### Consequences

* Good, because a default probe cannot silently destroy non-text clipboard data.
* Bad, because callers must explicitly opt in and the original clipboard
  contents are not restored after an authorized probe.

### Confirmation

See [Test-KlipAroundTransport.ps1](../../Public/Test-KlipAroundTransport.ps1),
the [recommended workflow](../../README.md#recommended-workflow), and
consent and error tests in [KlipAround.Tests.ps1](../../Tests/KlipAround.Tests.ps1).
