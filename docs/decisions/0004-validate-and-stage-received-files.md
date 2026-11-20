---
status: accepted
---

# Validate and stage received files before replacing destinations

## Context and Problem Statement

Received metadata is supplied by the other endpoint. Unsafe names, incomplete
transfers, or failed integrity checks must not overwrite arbitrary paths or
destroy an existing destination file.

## Considered Options

* Validate names and write to a unique temporary file before promoting it.

## Decision Outcome

Chosen option: "Validate names and write to a unique temporary file before
promoting it". The receiver rejects path components before acknowledging file
metadata, creates a unique partial file with `CreateNew`, checks its length
and hash, and moves or replaces the target only after verification. Existing
targets require `-Force`. Failed partial files are removed where possible;
cleanup errors are reported.

### Consequences

* Good, because untrusted file names cannot select an outside path and a failed
  transfer does not replace an existing target.
* Bad, because temporary disk space is required and cleanup can fail due to
  filesystem or permission errors.

### Confirmation

See [Receive-KlipAround.ps1](../../Public/Receive-KlipAround.ps1) and the
received-file-name, failed-transfer, and replacement tests in
[KlipAround.Tests.ps1](../../Tests/KlipAround.Tests.ps1). Partial-file cleanup
was added after the initial staging decision.
