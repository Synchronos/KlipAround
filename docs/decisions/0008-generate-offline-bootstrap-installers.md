---
status: accepted
---

# Generate self-contained offline bootstrap installers

## Context and Problem Statement

An endpoint may have neither Internet access nor a file share, but may be able
to receive a script as text. It still needs the essential module files and an
installation into the intended PowerShell scope.

## Decision Drivers

* Install without downloading files or requiring a separate archive.
* Avoid silently overwriting an existing installation.

## Considered Options

* Generate a standalone PowerShell installer with an embedded compressed,
  Base64-encoded module archive.

## Decision Outcome

Chosen option: "Generate a standalone PowerShell installer with an embedded
compressed, Base64-encoded module archive". The installer checks an embedded
SHA-256 hash, validates archive entries, stages a versioned installation, and
supports `CurrentUser` and `AllUsers`. Existing same-version installations
require `-Force`; an unversioned installation is rejected rather than replaced.
The hash detects corruption but does not authenticate the script.

### Consequences

* Good, because an offline endpoint can install from one transferable text file.
* Bad, because the script is larger than the module archive and must be obtained
  from a trusted source; the destination still needs supported PowerShell.

### Confirmation

See [New-KlipAroundBootstrap.ps1](../../Public/New-KlipAroundBootstrap.ps1),
the [offline bootstrap instructions](../../README.md#offline-bootstrap), and
installer tests in [KlipAround.Tests.ps1](../../Tests/KlipAround.Tests.ps1).
