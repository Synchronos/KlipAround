---
status: accepted
---

# Include tests in Gallery packages for release validation

## Context and Problem Statement

The release process validates the exact `.nupkg` bytes that will be published
and later downloaded from the PowerShell Gallery. Validation must prove not
only that metadata is correct, but that package contents remain runnable and
behaviorally correct after packaging and distribution.

## Considered Options

* Exclude tests from the package and validate only from the repository checkout.
* Include module tests in the package and run validation against extracted
  package contents.

## Decision Outcome

Chosen option: "Include module tests in the package and run validation against
extracted package contents", because release validation must target the package
artifact itself rather than a proxy representation from the source checkout.

### Consequences

* Good, because maintainers can verify published/downloaded package bytes with
  the same test suite used during release preparation.
* Good, because packaging regressions in file inclusion, load paths, and
  module behavior are detectable from the artifact under test.
* Bad, because package size grows and packaging tests must stay aligned with
  the expected in-package test set.

### Confirmation

See [New-KlipAroundPackage.ps1](../../Build/New-KlipAroundPackage.ps1),
[New-KlipAroundPackage.Tests.ps1](../../Build/New-KlipAroundPackage.Tests.ps1),
and [releasing.md](../releasing.md). Packaging tests assert the `Tests`
directory is present in the `.nupkg`, and the release checklist requires
extracting and running bundled tests against the built and downloaded package.
