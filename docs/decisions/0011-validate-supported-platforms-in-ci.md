---
status: accepted
---

# Validate supported PowerShell platforms in CI

## Context and Problem Statement

The module supports Windows PowerShell 5.1 and PowerShell 7 on Windows and
Linux. Platform-specific clipboard and packaging behavior makes a single local
test environment insufficient for routine regression checks.

## Considered Options

* Run a GitHub Actions matrix across the supported PowerShell environments.

## Decision Outcome

Chosen option: "Run a GitHub Actions matrix across the supported PowerShell
environments". The workflow validates the manifest and runs Pester on Windows
PowerShell 5.1, Windows PowerShell 7, and Linux PowerShell 7. PowerShell 7 jobs
also run packaging tests and check PSScriptAnalyzer errors.

### Consequences

* Good, because supported runtime regressions are checked on pushes and pull
  requests, independently of a developer's local platform.
* Bad, because CI depends on Gallery-hosted test tooling and does not by itself
  prove real clipboard or Remote Desktop behavior. Native Linux clipboard tests
  are opt-in.

### Confirmation

See [ci.yml](../../.github/workflows/ci.yml) and the
[Linux test instructions](../../README.md#offline-bootstrap).
