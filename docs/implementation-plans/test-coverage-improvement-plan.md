# KlipAround Test Coverage Improvement Plan (Working Document)

## Purpose
Close genuine test coverage gaps identified from the 2026-11-23 coverage run (63.4% lines overall)
while avoiding brittle tests for paths that are platform-gated, consent-gated, or
uninstrumentable by design.

## Scope
Files expected to change:
- `Tests/KlipAround.Tests.ps1` (all phases)
- `coverage-report.md` (Phase 4 — accepted-gaps documentation)

No production code changes are planned. If a test reveals a defect, the fix is tracked as a
deviation note in this document.

## Measurement caveats (read before interpreting coverage numbers)
1. **Tracer-blind execution:** The transfer matrix runs `Send-KlipAround`/`Receive-KlipAround`
   in child runspaces, and benchmark receivers run in background jobs. Pester's coverage
   tracer only instruments the primary runspace, so those executions are invisible to the
   metric. Measured coverage is a floor, not actual exercised coverage.
2. **Import-time artifacts:** `KlipAround.psm1` and script-level initialization lines report
   0% because module import precedes instrumentation. These are not real gaps.
3. The gaps targeted below are paths with **no assertions in any process** — the metric is a
   finding aid; the goal is asserted behavior, not a percentage.

## Coverage goals
1. Every auth-enforcement throw path (nonce validation, mixed-mode, rebinding) has a direct
   negative test.
2. The sender retransmission/ACK state machine has in-process assertions on published message
   order and retry behavior.
3. Documented user entry points (session-less receiver start) are tested.
4. Remaining untested regions are explicitly classified as accepted gaps with rationale.

## Change plan

### Phase 1 — Untested protocol logic (high risk ÷ effort)
**Status:** ⬜ Not started

**Goal:** First-ever assertions for the sender state machine, auth enforcement throws, the
session-less receiver entry point, and block-expansion error branches.

1. **Sender full state machine with mocked waits** (`Send-KlipAround.ps1` ~437–612)
   - Extend the existing mocked `Wait-KlipAroundMessage`/`Publish-KlipAroundMessage` harness
     to script a complete transfer: `HELLO_ACK` → `FILE_META_ACK` → partial `ACK_REPORT`
     with `MissingSeqs` → completing `ACK_REPORT` → `FILE_EOF_ACK` → `FIN_ACK`.
   - Assert published message-type order, SREJ resend of exactly the missing sequences,
     window advance, and final `PassThru` result shape.
   - One additional case: `ACK_REPORT` timeout on first attempt, success on retry
     (covers the burst retry loop without exhausting `MaxRetries`).

2. **Auth assertion negative paths** (sender ~219–232, receiver ~132–150)
   - Sender: mocked `HELLO_ACK` with wrong/missing `AuthSenderNonce` → throws sender nonce
     validation error; mocked follow-up message with changed `AuthReceiverNonce` → throws
     receiver nonce validation error.
   - Receiver: mocked second sender message with a different `AuthSenderNonce` → throws
     rebinding rejection; mocked authenticated `HELLO` with `AuthRequired` absent/false →
     throws auth-required-HELLO error.

3. **Session-less receiver start** (`Receive-KlipAround.ps1` ~170–206)
   - Mock `Get-KlipAroundClipboardText` to serve a valid sender `HELLO` envelope; call
     `Receive-KlipAround` without `-SessionId`; assert session binding to the HELLO's
     session and normal progression to `HELLO_ACK`.
   - Negative case: malformed clipboard payloads first, then a valid HELLO — assert the
     malformed-payload warning counter does not abort discovery.

4. **`Expand-KlipAroundDataBlock` error branches** (`KlipAroundProtocol.ps1` ~791–833)
   - Single `-TestCases` table: checksum mismatch, declared-length vs actual mismatch,
     unsupported/unexpected checksum algorithm, oversize declared length.

**Phase 1 exit criteria**
- All listed throw paths asserted with `Should -Throw` on their specific messages.
- Sender happy-path test asserts the exact published message-type sequence.
- Full suite green.

### Phase 2 — Cheap unit fills
**Status:** ⬜ Not started

**Goal:** Close small 0%-coverage helpers that run only in child runspaces today.

1. **`New-KlipAroundAuthNonce`** — assert base64 round-trip to the configured byte length,
   uniqueness across calls, and `ValidateRange` rejection of out-of-range lengths.
2. **Real `Publish-KlipAroundMessage` body** — with mocked `Set-KlipAroundClipboardText`:
   asserts signing occurs when `-AuthKey` is provided (payload gains `Auth.Signature`),
   no `Auth` node otherwise, and the message is returned.
3. **Receiver out-of-order burst buffering + explicit-missing SREJ**
   (`Receive-KlipAround.ps1` ~390–435) — mocked `Wait` sequence delivering a burst with a
   sequence gap; assert the `ACK_REPORT` lists the missing sequence and the buffered block
   is applied after the gap fills.

**Phase 2 exit criteria**
- Targeted helpers no longer at 0% in an instrumented run.
- Full suite green.

### Phase 3 — Optional instrumentation improvement
**Status:** ⬜ Optional / decide after Phases 1–2

**Goal:** Make the coverage metric stable and honest.

1. Add a documented coverage invocation (CI or contributor docs) that runs the suite with
   `CodeCoverage` configured, excluding the tracer-blind matrix tag if metric stability is
   preferred (`-ExcludeTagFilter TransferMatrix`), OR keep the matrix in and document the
   floor semantics.
2. Regenerate `coverage-report.md` from that canonical invocation.

### Phase 4 — Accepted gaps (document, do not chase)
**Status:** ⬜ Not started

**Goal:** Record intentional non-coverage so future audits don't re-litigate.

Add an "Accepted gaps" section to `coverage-report.md` covering:
- **Windows clipboard natives** (`Get/Set-KlipAroundClipboardText` real bodies): consent-gated
  by design (ADR 0010); exercised indirectly by matrix runspaces and opt-in probes.
- **xclip stall/kill and Linux display paths**: Linux-only; partially covered by the
  existing Linux-gated tests and CI leg.
- **Clipboard listener type compile fallback** (`Initialize-KlipAroundClipboardListenerType`):
  `Add-Type` is once-per-process; fallback requires a broken compiler environment.
- **`Test-KlipAroundPerformance` job internals**: out-of-process by design; in-process
  statistics/cleanup logic already tested.
- **Import-time script lines**: instrumentation artifact.

## Expected outcome
- Measured line coverage rises from ~63% to roughly 85% after Phases 1–2.
- Every ADR 0016 auth-enforcement branch carries a direct negative assertion.
- Remaining uncovered lines are classified, not unknown.

## Validation
- Full Pester suite green after each phase.
- One coverage re-run after Phase 2 to confirm targeted regions moved; update
  `coverage-report.md` numbers.

## Status log
- 2026-11-23: Plan created from coverage analysis of `coverage.xml`
  (905/1428 lines, 63.4%). No phases started.
