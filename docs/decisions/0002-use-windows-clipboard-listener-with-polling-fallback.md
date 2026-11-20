---
status: accepted
---

# Use a Windows clipboard listener with polling fallback

## Context and Problem Statement

Waiting for new clipboard messages must work in Windows PowerShell and
PowerShell 7, including hosts such as the VS Code terminal where listener
initialization can fail.

## Considered Options

* Use a Windows clipboard change listener, falling back to polling when it
  cannot initialize or operate.

## Decision Outcome

Chosen option: "Use a Windows clipboard change listener, falling back to
polling". A background Windows Forms listener reports clipboard changes when
available; the protocol can continue polling if it is unavailable. Listener
initialization supplies the required assemblies for the active PowerShell
runtime.

### Consequences

* Good, because a listener can avoid needless polling while fallback preserves
  operation in incompatible hosts.
* Bad, because the module has Windows-specific runtime-compiled listener code
  and polling can add latency.

### Confirmation

See [Clipboard.ps1](../../Private/Clipboard.ps1),
[KlipAroundProtocol.ps1](../../Private/KlipAroundProtocol.ps1), and the
listener and error tests in [KlipAround.Tests.ps1](../../Tests/KlipAround.Tests.ps1).
