---
status: accepted
---

# Optimize CRC32C in PowerShell without compiled checksum code

## Context and Problem Statement

The CRC32C byte loop was a performance bottleneck. A compiled implementation
was considered, but an optimization without compiled checksum code was desired.

## Considered Options

* Hoist repeated conversions and table-lookup work out of the PowerShell loop.
* Replace the checksum loop with compiled code.

## Decision Outcome

Chosen option: "Hoist repeated conversions and table-lookup work out of the
PowerShell loop". CRC32C remains available alongside SHA-256; public transfer
commands default to SHA-256 for block checksums, and the whole file is checked
with SHA-256. This decision concerns the checksum implementation, not the
Windows clipboard listener's compiled code.

### Consequences

* Good, because CRC32C improves without introducing a compiled checksum
  dependency or dropping Windows PowerShell 5.1 support.
* Bad, because a PowerShell loop can still be slower than a native
  implementation; throughput depends on the environment and workload.

### Confirmation

See [Hashing.ps1](../../Private/Hashing.ps1), CRC32C vector and transfer tests
in [KlipAround.Tests.ps1](../../Tests/KlipAround.Tests.ps1), and the
[benchmark command](../../Public/Test-KlipAroundPerformance.ps1).
