---
status: accepted
---

# Retry and acknowledge transfer messages

## Context and Problem Statement

Clipboard updates or acknowledgments can be lost or delayed. In particular,
loss of an acknowledgment for the last burst or session completion must not
make a successful receive appear to fail immediately.

## Considered Options

* Use bounded retries, cumulative acknowledgments, and selective retransmission.

## Decision Outcome

Chosen option: "Use bounded retries, cumulative acknowledgments, and selective
retransmission". `ACK_REPORT` conveys the next expected sequence and missing
sequences. The sender retries unacknowledged bursts within `MaxRetries`, and
the receiver can re-acknowledge a repeated final burst. After `FIN`, the
receiver remains available for a bounded grace period to acknowledge retries.
This is in-session recovery, not persistent resume after a command exits.

### Consequences

* Good, because transient message or acknowledgment loss need not abort a
  transfer or require resending all acknowledged blocks.
* Bad, because retry limits and timeouts can still terminate a transfer, and
  message identity and duplicate handling add protocol state.

### Confirmation

See [Send-KlipAround.ps1](../../Public/Send-KlipAround.ps1),
[Receive-KlipAround.ps1](../../Public/Receive-KlipAround.ps1), and
fault-injection transfer tests in [KlipAround.Tests.ps1](../../Tests/KlipAround.Tests.ps1).
