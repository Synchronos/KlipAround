---
status: accepted
---

# Use xclip for Linux X11 clipboard access

## Context and Problem Statement

KlipAround was extended to Linux PowerShell while retaining an actual shared
clipboard. Linux clipboard cmdlets may fall back to process-local behavior
when the system clipboard is unavailable, which cannot carry a transfer
between endpoints.

## Decision Drivers

* Use the real clipboard and report missing or inaccessible dependencies.
* Bound stalled clipboard operations by the configured timeout.

## Considered Options

* Invoke `xclip` directly for X11 clipboard reads and writes.
* Rely on PowerShell clipboard cmdlets, including their platform-specific
  fallback behavior.

## Decision Outcome

Chosen option: "Invoke `xclip` directly for X11 clipboard reads and writes".
Linux PowerShell 7 uses `xclip` and polling, with an X11 or XWayland display;
subprocess failures and timeouts are surfaced. This extends rather than
replaces the Windows approach in [ADR 0002](0002-use-windows-clipboard-listener-with-polling-fallback.md).

### Consequences

* Good, because failures do not silently become process-local clipboard
  transfers.
* Bad, because `xclip` and an accessible display are prerequisites; native
  Wayland-only and headless sessions without X11 clipboard access are unsupported.

### Confirmation

See [Clipboard.ps1](../../Private/Clipboard.ps1), the
[Linux prerequisites](../../README.md#offline-bootstrap), and Linux clipboard
tests in [KlipAround.Tests.ps1](../../Tests/KlipAround.Tests.ps1).
