---
status: accepted
---

# Build isolated PowerShell Gallery packages

## Context and Problem Statement

Publishing directly from a working directory risks including development or
smoke-test artifacts. Release packages need essential module files, help,
documentation, tests, and license terms without overwriting an earlier build.

## Considered Options

* Stage an explicit file set and build a NuGet package locally before publishing.

## Decision Outcome

Chosen option: "Stage an explicit file set and build a NuGet package locally
before publishing". The build validates the module manifest, copies selected
files into a temporary staging directory, creates a `.nupkg`, and refuses to
overwrite an existing package. Publishing is a separate action. A subsequent
licensing change added the MIT license to both Gallery packages and offline
bootstrap installers.

### Consequences

* Good, because package contents can be tested independently of the working
  tree and publishing credentials.
* Bad, because changes to the runtime file layout must be reflected in the
  explicit staging list and packaging tests.

### Confirmation

See [New-KlipAroundPackage.ps1](../../Build/New-KlipAroundPackage.ps1),
[package tests](../../Build/New-KlipAroundPackage.Tests.ps1), and
[installation documentation](../../README.md#release-package).
Later metadata refinements are recorded in
[ADR 0012](0012-publish-versioned-documentation-and-provenance.md).
