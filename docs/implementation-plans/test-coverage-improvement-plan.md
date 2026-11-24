# KlipAround Test Coverage Improvement Plan (Working Document)

## Purpose
Close behavior and assertion gaps identified from coverage and source inspection.
The original 2026-11-23 baseline was **905/1428 lines (63.4%)**. Phase 1 measured
**1087/1436 lines (75.7%)**; the first Phase 2 batch now measures
**1102/1436 lines (76.7%)**. Coverage guides
test selection; a high percentage alone does not establish protocol correctness.

## Scope
Files expected to change:
- [Module tests](../../Tests/KlipAround.Tests.ps1) (behavioral improvements).
- [Coverage runner](../../Build/Invoke-KlipAroundTests.ps1),
  [runner tests](../../Build/Invoke-KlipAroundTests.Tests.ps1), and
  [contributor instructions](../../CONTRIBUTING.md) (instrumentation and usage).
- This document (status, evidence summary, and gap classification).

Tests and documentation are the primary scope. If a regression test reveals a
production defect, record expected versus actual behavior, the minimal fix, and
validation as a deviation. Do not weaken assertions or increase timeouts merely
to obtain a passing run.

## Measurement caveats (read before interpreting coverage numbers)
1. **Execution is not assertion:** A covered line can lack a meaningful check;
   an uncovered line can run in an uninstrumented child runspace. Inspect both
   source and tests before classifying a gap.
2. **Tracer scope:** The canonical runner is sequential and uses Pester's
   profiler-based tracer. Transfer-matrix child runspaces and benchmark jobs are
   not measured by this run. Their tests still provide behavioral evidence.
3. **Import-time artifacts:** Module discovery/import can precede tracing.
   Script-level initialization may therefore appear uncovered. Do not remove
   these files from the denominator just to improve the percentage.
4. **Different units:** JaCoCo reports line/instruction counts; Pester's console
   summary uses commands. The latest run has **1372/1858 covered commands
   (73.84%)**, including **486 missed-command CSV records**. CSV commands may
   contain embedded newlines; physical CSV line counts are not command counts.
5. **No branch measurement:** This XML contains no branch counters. The absence
   of counters means branch coverage is unavailable, not zero or complete.
6. **Comparable evidence:** Source changes increased the line denominator from
   1428 to 1436. Record runtime, source revision/worktree state, filters, and
   instrumentation with each run; do not compare filtered or cross-platform
   results as if they were identical full-suite baselines.

## Current evidence and status
Reviewed on **2026-11-24**. The latest retained module reports are:
- [JaCoCo coverage](../../TestResults/phase2-auth/coverage.xml).
- [Missed commands](../../TestResults/phase2-auth/missed-commands.csv).
- [NUnit3 results](../../TestResults/phase2-auth/test-results.xml).

These are ignored, replaceable local artifacts, not committed release evidence.
The full run used **PowerShell 7.7.0 on Windows / Pester 6.2.0**, without filters
or native-clipboard opt-in.
The module run spans **2026-11-24 08:32:40Z to 08:37:37Z** and contains
**105 cases: 100 passed, 0 failed, 5 skipped**. The runner's recorded process exit
code was **0**. Source state was commit `ff656bd` plus the uncommitted Phase 2
test changes; no production source changed in this batch.
The 18 selected auth/discovery/sender cases also passed on both PowerShell 7
and Windows PowerShell 5.1, with exit code 0. The runner's five regression
tests passed separately during its implementation and were not rerun here.

| Module source | Covered / total lines | Coverage |
| --- | ---: | ---: |
| `Public/Receive-KlipAround.ps1` | 246/351 | 70.1% |
| `Private/KlipAroundProtocol.ps1` | 296/368 | 80.4% |
| `Public/Send-KlipAround.ps1` | 276/331 | 83.4% |
| `Private/Clipboard.ps1` | 48/95 | 50.5% |
| `Public/Test-KlipAroundPerformance.ps1` | 122/153 | 79.7% |
| `KlipAround.psm1` | 0/12 | 0.0% |
| `Public/New-KlipAroundBootstrap.ps1` | 59/66 | 89.4% |
| `Private/Hashing.ps1` | 28/32 | 87.5% |
| `Public/Test-KlipAroundTransport.ps1` | 27/28 | 96.4% |
| **Total** | **1102/1436** | **76.7%** |

The five skips are two Linux-only stalled-xclip cases and three opt-in native
Linux display/clipboard cases. Do not count them as passes or assume Windows
results establish Linux/RDP behavior. The NUnit root says `Skipped` despite 100
passed cases; interpret case counts and failure records alongside the runner
exit code, rather than treating that label as "nothing ran."

The legacy root `coverage-report.md` is absent in the current worktree. This
plan retains its historical baseline; current summaries use the runner artifacts.
Do not recreate the legacy report as a prerequisite for further test work.

| Phase | Current status |
| --- | --- |
| 1 | Delivered and validated; residual assertions explicitly carried into Phase 2. |
| 2 | In progress: auth assertions and sender-test tag separation delivered; receiver recovery and helper work remain. |
| 3 | Runner, usage documentation, and runner tests implemented; evidence procedure below applies now. |
| 4 | Classification refined below; platform validation and final disposition remain pending. |

## Coverage goals
1. Every auth-enforcement throw path (nonce validation, mixed-mode, rebinding) has a direct
   negative test.
2. The sender retransmission/ACK state machine has in-process assertions on published message
   order and retry behavior.
3. Documented user entry points (session-less receiver start) are tested.
4. Remaining regions are classified as testable gaps, measurement limitations,
   pending platform checks, or explicit deferrals with rationale.

## Testing strategy and execution order
- **App type:** PowerShell CLI using a clipboard-based messaging protocol;
  containers and browser testing are not applicable.
- **Reuse:** Extend the existing Pester suite and in-memory transport harness.
  Keep real protocol/checksum/auth helpers under test; mock clipboard access and
  scripted waits only where appropriate for the contract being asserted.
- **Critical journeys:** authenticated/unauthenticated transfer; selective
  retransmission and corruption recovery; malformed/auth-context rejection;
  session-less binding; platform-specific transport failure and cleanup.
- **Isolation:** Use `TestDrive`, fresh sessions, and deterministic payloads.
  Restore changed environment variables and dispose streams/processes in cleanup.
  Native integration requires separate consent and dedicated endpoints; mocked
  clipboard transport is not equivalent evidence.
- **Order:** Phase 3 tooling is already available. Work through Phase 2 in risk
  order; its groups can be implemented independently when fixtures permit.
  Re-run the unfiltered suite and coverage after Phase 2, then finalize Phase 4
  classifications. No tooling or final-classification work blocks starting Phase 2.

## Change plan

### Phase 1 — Untested protocol logic (high risk ÷ effort)
**Status:** ✅ Delivered (2026-11-23); see residual assertions below.

**Original targets:** Add in-process sender-state assertions, auth negatives,
session-less receiver discovery, and block-expansion error cases. The acceptance
review below distinguishes delivery from remaining assertions.

1. **Sender full state machine with mocked waits**
   ([`Send-KlipAround`](../../Public/Send-KlipAround.ps1))
   - Extend the existing mocked `Wait-KlipAroundMessage`/`Publish-KlipAroundMessage` harness
     to script a complete transfer: `HELLO_ACK` → `FILE_META_ACK` → partial `ACK_REPORT`
     with `MissingSeqs` → completing `ACK_REPORT` → `FILE_EOF_ACK` → `FIN_ACK`.
   - Assert published message-type order, SREJ resend of exactly the missing sequences,
     window advance, final `PassThru` file/block totals, and streamed hash.
   - One additional case: `ACK_REPORT` timeout on first attempt, success on retry
     (covers the burst retry loop without exhausting `MaxRetries`).

2. **Auth assertion negative paths**
   ([sender](../../Public/Send-KlipAround.ps1),
   [receiver](../../Public/Receive-KlipAround.ps1))
   - Sender: mocked `HELLO_ACK` with wrong/missing `AuthSenderNonce` → throws sender nonce
     validation error; mocked follow-up message with changed `AuthReceiverNonce` → throws
     receiver nonce validation error.
   - Receiver: mocked second sender message with a different `AuthSenderNonce` → throws
     rebinding rejection; mocked authenticated `HELLO` with `AuthRequired` absent/false →
     throws auth-required-HELLO error.

3. **Session-less receiver start**
   ([`Receive-KlipAround`](../../Public/Receive-KlipAround.ps1))
   - Mock `Get-KlipAroundClipboardText` to serve a valid sender `HELLO` envelope; call
     `Receive-KlipAround` without `-SessionId`; assert session binding to the HELLO's
     session and normal progression to `HELLO_ACK`.
   - Negative case: malformed clipboard payloads first, then a valid HELLO — assert the
     malformed-payload warning counter does not abort discovery.

4. **[`Expand-KlipAroundDataBlock`](../../Private/KlipAroundProtocol.ps1) error branches**
   - Single `-TestCases` table: checksum mismatch, declared-length vs actual mismatch,
     unsupported/unexpected checksum algorithm, oversize declared length.

**Phase 1 acceptance review**
- Sender state-machine, retry, discovery, and the implemented rejection cases
  pass; the exact published message-type sequence is asserted.
- The original "all listed throw paths" criterion was broader than the delivered
  assertions. Missing sender nonce at the sender, missing/wrong receiver nonce at
  the receiver, and absent `AuthRequired` are not all directly tested yet.
  Phase 2 carries these forward; Phase 1 delivery is not an all-auth-path sign-off.
  The Phase 2 kickoff below adds the nonce cases and records existing
  omitted-flag acceptance without tightening authentication policy.

**Phase 1 implementation notes**
- Added **10 `It` definitions / 15 expanded cases**: sender state machine and
  ACK-timeout retry, three sender auth negatives, three receiver auth negatives,
  session-less discovery, and a six-case malformed-block table. The mixed-mode
  rejection test predates Phase 1 and is not one of these additions.
- Sender assertions check publish order, retransmitted sequences, window
  progress, file/block counts, and streamed SHA-256. Cache reuse is exercised,
  but cache-hit/hash-helper invocation counts are not independently asserted.
- The discovery case feeds malformed text before a valid unauthenticated HELLO.
  It asserts HELLO_ACK/FIN_ACK publication, not warning contents or rate limiting.
- The block table checks checksum/length mismatch, invalid declared length,
  expected-algorithm mismatch, missing checksum, and oversized encoded content.
  Declared-length maximum enforcement already had a separate test.

**Phase 1 deviations from original plan**
- **Production fix (strict-mode safe property access):** The auth assertion scriptblocks in
  `Send-KlipAround.ps1` and `Receive-KlipAround.ps1` read `AuthSenderNonce`/`AuthReceiverNonce`
  directly; under `Set-StrictMode`, messages genuinely missing those properties threw
  `PropertyNotFound` instead of the intended diagnostic errors, making the friendly
  "missing nonce" paths unreachable. Changed to guarded `PSObject.Properties.Name` lookups so
  the documented validation errors fire. Behavior for well-formed messages is unchanged.

**Phase 1 validation evidence**
- Full Pester suite after Phase 1: **92 passed, 0 failed, 5 skipped** (previously 77 passed).

### Phase 2 — Remaining protocol assertions and focused unit tests
**Status:** 🟨 In progress (2026-11-24); auth kickoff validated.

**Goal:** Prioritize remaining receiver/auth contracts over inexpensive
percentage gains. Extend existing tests where practical; do not multiply every
case across the whole transfer matrix.

1. **Complete auth-enforcement assertions (first priority)**
   - Sender: absent `AuthSenderNonce` in HELLO_ACK, complementing the existing
     wrong-value case.
   - Receiver: missing and incorrect `AuthReceiverNonce` after a valid HELLO;
     use the correct bound sender nonce so the intended validation is reached.
   - Authenticated HELLO: distinguish omitted `AuthRequired` from explicit
     `false`. The kickoff preserves existing acceptance of omission when
     signature/nonces are valid, while explicit `false` still rejects in
     authenticated mode. Authentication remains opt-in under
     [MADR 0017](../decisions/0017-decline-auth-required-by-default-evolution.md).
     That decision does not itself specify the omitted-field rule; no new
     wire-policy tightening is introduced by this test-improvement batch.
   - Session-less auth discovery: unsigned/invalidly signed HELLO followed by a
     valid signed HELLO, then verify the bound session and echoed nonce context.
     Capture and assert the existing malformed-discovery warning separately.
   - In `Wait-KlipAroundMessage`, feed malformed/invalidly signed envelopes
     before a valid message. Assert warning throttling and eventual acceptance
     with deterministic polling mocks, rather than suppressing warnings.

2. **Receiver ordering, corruption recovery, and metadata guardrails**
   - Deliver a valid burst in reverse order to exercise sorting.
   - Deliver a sequence gap, then the missing block; assert exact
     `AckNextSeq`/`MissingSeqs`, ordered output bytes, final length/hash, and no
     duplicate writes when an already-buffered block is repeated.
   - Corrupt one block checksum and retransmit it correctly. Assert a selective
     rejection followed by successful completion; helper-only throws do not
     establish receiver recovery.
   - Use a small metadata rejection table for invalid file index/negative
     length, HELLO/FILE_META block-size mismatch, and inconsistent total blocks.
     Assert no FILE_META_ACK or destination replacement on rejection.

3. **Real publish and wire-round-trip auth behavior**
   - Call `Publish-KlipAroundMessage` with only the clipboard primitive mocked;
     it remains **0/6 measured lines** because current state-machine tests mock
     publication entirely.
   - Parse the captured envelope and verify its HMAC with the configured key;
     verify that unauthenticated publication has no auth metadata.
   - Extend existing canonicalization regressions to verify after envelope
     serialization/parsing, not only against the original object. Cover null
     fields and empty/singleton/multiple block collections without collapsing
     array shape. Keep the existing deterministic timestamp regression.

4. **ACK invariants and bounded replay history**
   - Extend the existing out-of-bounds ACK case with wrong file/total-block
     context, regressing progress, and missing sequences outside valid bounds.
     Assert no premature EOF/FIN after a rejected ACK.
   - Configure a small supported auth-digest history limit and accept enough
     signed messages to trigger eviction. Assert the bound and oldest removal
     from both set and queue while retained digests remain replay-rejected.
     Keep this independent of monotonic-ID filtering so rejection is attributed
     to the correct mechanism.

5. **Nonce contract (lower priority, not a 0%-coverage gap)**
   - `New-KlipAroundAuthNonce` now has **5/5 measured lines** through in-process
     auth tests. Add a focused decoding/length assertion for a non-default
     supported size if the generation contract needs a direct regression.
     Do not treat random uniqueness sampling or framework `ValidateRange`
     behavior as a substitute for meaningful protocol tests.

**Test organization**
- **Completed in the kickoff:** mocked sender tests now have their own
  `Mocked sender protocol` group outside the `TransferMatrix` parent. Excluding
  the matrix no longer excludes these in-process state-machine/auth assertions.
  The actual transfer matrix retains its tags and cases.
- Keep fixtures schema-complete (including `MessageType`) and use real signing,
  parsing, and checksum helpers where those contracts are under test. Avoid
  mocks at the very boundary the test claims to validate.

**Phase 2 kickoff delivery**
- Eight additional expanded cases: missing sender nonce at the sender,
  missing/changed receiver nonce after HELLO, three signed session-less
  discovery cases, and two warning-throttling/reset cases.
- Discovery rejects unsigned or incorrectly signed HELLO before accepting a
  correctly signed HELLO. Assertions verify the selected session, echoed
  sender nonce, receiver nonce, and authenticated follow-up wait. A deliberate
  fixture exception stops immediately after binding; these are not claimed
  as complete authenticated transfers. The full transfer matrix remains the
  separate end-to-end regression evidence.
- The omitted-flag discovery case records compatibility; the explicit-false
  rejection test was renamed to describe its actual input.
- The existing unauthenticated malformed-first discovery test now asserts its
  warning text/count instead of discarding warnings.
- Real parsing/signature validation and mocked polling establish warnings at
  invalid counts 1 and 10, reset after valid traffic from another session, and
  eventual acceptance of the valid intended-session message.
- Focused validation: **18/0/0** on PowerShell 7 and Windows PowerShell 5.1.
  The initial 5.1 attempt could not discover Pester; exposing the existing
  module directory inside that process resolved it without installation.
- Tag-isolation check: **10/0/0**, exit **0**, for `Mocked sender protocol`
  with `TransferMatrix` excluded.
- Full coverage validation: **100/0/5**, exit **0**, **1102/1436 lines (76.7%)**;
  instruction/command coverage **1372/1858 (73.84%)**, **486** missed commands.
  An interrupted first attempt was discarded and rerun to completion.
- Remaining: receiver ordering/corruption/metadata cases (item 2), direct
  publishing and wire-round-trip tests (item 3), ACK/replay bounds (item 4),
  and any justified focused nonce-contract test (item 5).

**Phase 2 exit criteria**
- Listed protocol cases assert externally observable rejection, recovery, or
  bounded state, rather than merely executing the lines.
- Real publication and receiver sorting/recovery are measured in-process.
- Any newly exposed defect has a focused regression and documented disposition.
- Targeted tests and the unfiltered module suite pass with exit code 0; record
  skips and per-file coverage changes using Phase 3's procedure.

### Phase 3 — Reproducible coverage runner and evidence
**Status:** ✅ Runner implemented; evidence summary updated (2026-11-24).

**Goal:** Make the coverage metric stable and honest.

Use a fresh process from the checkout root. The canonical full run includes the
matrix and uses no test filters:

```powershell
pwsh -NoProfile -File .\Build\Invoke-KlipAroundTests.ps1
```

Default outputs are the three report names under `TestResults`. Preserve
comparison runs with `-OutputDirectory` rather than overwriting evidence;
the current evidence links above point to the separate `phase2-auth` run:

```powershell
pwsh -NoProfile -File .\Build\Invoke-KlipAroundTests.ps1 -OutputDirectory .\TestResults\phase2-auth
```

The runner fails on test/discovery failure, no runnable tests, or absent
coverage. Its displayed coverage target is informational, not an enforced gate.
Do not add an arbitrary percentage gate until behavior gaps and platform
baselines are understood.

**Coverage runner implementation**
- Added `Build/Invoke-KlipAroundTests.ps1` using Pester 6.2.0 configuration,
  detailed console output, module-only coverage, JaCoCo XML, NUnit3 results,
  and a missed-command CSV under `TestResults` by default.
- The default run includes the transfer matrix; optional filters select partial
  runs. Child-runspace and import-time measurement limitations are documented in
  `CONTRIBUTING.md`.
- Validation: default runner completed with **92 passed, 0 failed, 5 skipped**
  and exit code 0; generated JaCoCo reports **1087/1436 lines (75.7%)**. Five
  runner regression tests passed, including failure and empty-selection handling.
  Focused coverage runs passed on PowerShell 7 and Windows PowerShell 5.1
  (the latter required exposing the existing Pester installation through its
  process-local `PSModulePath`).

**Evidence procedure for subsequent work**
1. Run targeted names during implementation, then the unfiltered runner for
   each completed phase. A filtered success is not a full-suite result.
2. Record PowerShell/Pester versions, operating system, commit plus dirty-tree
   state, exact command/filters, native-clipboard opt-in state, and exit code.
   The Phase 1 baseline predates its commit; the Phase 2 kickoff baseline is
   `ff656bd` plus uncommitted tests. Do not attribute either solely to a commit.
3. Record per-case pass/fail/skip counts and reasons, plus JaCoCo totals and
   per-file changes. Update this document's current evidence summary.
4. Run the separate runner regression suite after runner changes, using the
   documented contributor command. Packaging tests and analyzer checks remain
   separate checks; the module coverage runner does not certify them.
5. Repeat full module tests on the supported Windows PowerShell 5.1,
   PowerShell 7 on Windows, and PowerShell 7 on Linux CI matrix before claiming
   cross-platform validation. The recorded full coverage run is PowerShell 7
   on Windows; a focused Windows PowerShell 5.1 smoke test is not a full baseline.

### Phase 4 — Classify residual gaps, do not blanket-waive them
**Status:** 🟨 Classification drafted; platform evidence and final review pending.

**Goal:** Distinguish missing assertions, tracer limitations, platform coverage,
and deliberately deferred native checks. Reassess after Phase 2.

| Area | Disposition / next evidence |
| --- | --- |
| Receiver ordering, ACK validation, replay bounds | Actionable remaining Phase 2 tests; not accepted gaps. |
| Auth enforcement/discovery | Kickoff assertions added; preserve opt-in authentication and retain full authenticated transfer regressions. |
| Module import-time lines | Instrumentation limitation; existing import tests still matter. |
| Transfer runspaces and benchmark jobs | Measurement limitation, not permission to omit behavioral assertions. |
| Clipboard wrapper functions | Unit-test routing, missing commands, empty reads, and error propagation with native commands mocked; do not require real clipboard access for these checks. |
| Native clipboard/RDP transfers | Deferred environment validation; use explicit consent and dedicated test endpoints. The simulated matrix replaces clipboard primitives and does not establish native transport coverage. |
| Linux xclip subprocesses | Existing stalled-process tests are skipped on this Windows run. Require Linux execution evidence; not a blanket accepted gap. |
| Listener compilation/fallback | Fresh-process setup is possible; defer brittle compiler-failure simulation unless justified by risk. A cached type or failed compiler is a different condition from absent assertions. |
| Remaining benchmark/bootstrap/error paths | Review concrete missed commands after higher-risk tests; accept/defer with a reason rather than assuming entire helpers are covered. |

Final review must map material missed regions to an asserted contract, a named
platform test, a measurement limitation, or an explicit deferral. Native tests
must never be enabled automatically in a shared environment.

## Expected outcome
- Auth-enforcement and receiver recovery contracts gain direct positive/negative
  assertions without sacrificing end-to-end transfer coverage.
- Material uncovered regions have a documented disposition.
- Coverage changes are measured honestly: Phase 1 was 75.7%; the Phase 2
  kickoff is 76.7%, with the production line denominator unchanged.
  The earlier roughly-85% forecast was not supported by a line-by-line estimate
  and is withdrawn; behavioral exit criteria govern completion.

## Validation
- Full Pester suite green after each phase, with the recorded process exit code.
- Re-run coverage after Phase 2 and update current metrics and gap dispositions.
- Plan-only revisions do not imply a fresh test execution.

## Status log
- 2026-11-23: Plan created from coverage analysis of `coverage.xml`
  (905/1428 lines, 63.4%). No phases started.
- 2026-11-23: Phase 1 delivered — 10 new definitions / 15 expanded cases
  (97 total), full suite 92/0/5. One production deviation: strict-mode-safe
  nonce property access in auth assertions. Residual assertions are now listed
  under Phase 2.
- 2026-11-24: Reconciled the plan with supplied reports and current tests: 75.7%
  line coverage, 72.87% command coverage, 504 missed commands, no branch counters.
  Corrected Phase 1 assertion/count claims, recognized the implemented runner,
  reprioritized Phase 2, and refined residual-gap classification. Reports were
  inspected, not regenerated; the legacy summary's deletion was preserved.
- 2026-11-24: Committed/pushed Phase 1, runner, and plan as `ff656bd`, then
  began Phase 2. Auth/discovery assertions add eight cases; mocked sender tests
  are no longer matrix-tagged. MADR 0017 remains in force with no production
  authentication-policy changes. Full suite **100/0/5**, line coverage
  **76.7%**, focused tests **18/0/0** on PowerShell 7 and Windows PowerShell 5.1.
