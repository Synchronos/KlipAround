# KlipAround Protocol Injection Remediation Plan (Working Document)

## Purpose
Track and execute protocol hardening changes for resistance to injected clipboard payloads while minimizing compatibility breakage.

## Scope
Files expected to change:
- `Private/KlipAroundProtocol.ps1`
- `Public/Send-KlipAround.ps1`
- `Public/Receive-KlipAround.ps1`
- `Tests/KlipAround.Tests.ps1`
- `docs/protocol-v2.md`
- `docs/troubleshooting.md` (deferred to Phase 2 docs pass)

## Security goals
1. Prevent unauthenticated peer/session takeover.
2. Prevent spoofed acknowledgments from altering sender state.
3. Reduce parser/decoder resource-exhaustion risk from malformed or oversized payloads.
4. Preserve current file-integrity guarantees and safe file-write behavior.

## Change plan

### Phase 1 — Immediate hardening (no protocol version bump)
**Status:** ✅ Completed (2026-11-23)

**Goal:** Reduce exploitability without breaking current peers.

1. **Envelope and payload guardrails**
   - Add maximum envelope size limit before JSON parse.
   - Add maximum decoded block size enforcement before accepting block bytes.
   - Add explicit sanity checks for metadata (`Length`, `TotalBlocks`, `BlockSize`, sequence ranges).
   - Fail closed with clear errors.

2. **ACK/state-machine validation tightening**
   - Enforce strict `AckNextSeq` bounds (`0 <= AckNextSeq <= TotalBlocks`).
   - Enforce monotonic progress and reject impossible transitions.
   - Validate `ACK_REPORT` fields against active file context.
   - Treat invalid ACKs as protocol errors, not progress.

3. **Observability**
   - Add warnings/errors for repeated invalid protocol messages (rate-limited if needed).
   - Keep diagnostics explicit for troubleshooting and incident analysis.

**Phase 1 implementation notes**
- Implemented envelope pre-parse size limits and decoded block size limits in protocol helpers.
- Implemented stricter receiver-side `HELLO` / `FILE_META` sanity validation and sender-side `ACK_REPORT` invariant validation with fail-closed behavior.
- Added focused Pester coverage for oversized envelopes, block size limits, and invalid ACK bounds/consistency.
- Added rate-limited malformed-message warning paths during message wait/initial handshake handling.

**Phase 1 deviations from original plan**
- **Scope deviation (additional):** Message ID generation was upgraded from GUID to monotonic UUIDv7 (including rollover behavior tests). This was not part of the original Phase 1 injection-hardening scope; it was included to improve ordering/diagnostics and was implemented without protocol wire-format breakage.
- **Scope deviation (deferred docs):** `docs/troubleshooting.md` was listed in planned scope but was not updated during Phase 1 because validation/diagnostic behavior changes were fully documented in protocol docs and tests.

**Phase 1 validation evidence**
- Full Pester suite after Phase 1 and UUIDv7 hardening updates: **65 passed, 0 failed, 5 skipped**.

### Phase 2 — Authenticated mode (opt-in)
**Goal:** Add cryptographic message authenticity while preserving compatibility path.

1. **Shared-key auth design**
   - Add optional `-AuthKey` parameter to sender/receiver.
   - Add per-message HMAC over canonical envelope fields (excluding signature field itself).
   - Add nonce/challenge in `HELLO`/`HELLO_ACK` to bind session start.
   - Define replay protection window and nonce reuse policy.

2. **Authenticated state enforcement**
   - When auth is enabled, reject unsigned or invalid-signature messages.
   - Require authenticated `HELLO` before session binding when `SessionId` is omitted.
   - Ensure ACK/EOF/FIN acceptance requires valid signature and session correlation.
   - Bind peer/session identity at first authenticated `HELLO`; reject later identity rebinding attempts.
   - Refuse unauthenticated downgrade when either endpoint requires authentication.

3. **Docs and compatibility behavior**
   - Document mixed-mode behavior and expected failures.
   - Provide operator guidance for key distribution and rotation.

**Phase 2 acceptance criteria**
1. Authenticated mode rejects forged/tampered/replayed messages across HELLO, metadata, data, ACK, EOF, and FIN flows.
2. Mixed-mode behavior is deterministic and documented (auth-required, auth-optional, unauthenticated peers).
3. Sender/receiver interoperability tests pass for valid authenticated transfers and expected negative paths.

### Phase 3 — Secure-by-default protocol evolution
**Goal:** Move to secure defaults with explicit legacy opt-out.

1. Define next protocol revision behavior:
   - Auth required by default.
   - Legacy unauthenticated mode gated behind explicit switch.
2. Publish migration steps and compatibility matrix.
3. Add deprecation timeline for unauthenticated mode.
4. Define explicit downgrade policy and operator override semantics.

**Phase 3 acceptance criteria**
1. Default configuration requires authenticated sessions.
2. Legacy mode requires explicit operator opt-in and emits clear warnings.
3. Migration documentation covers rollout, fallback, and deprecation milestones.

## Test plan

### New/updated tests
1. Reject oversized envelopes before JSON parse.
2. Reject blocks exceeding allowed decoded size.
3. Reject invalid metadata ranges (`TotalBlocks`, `Length`, sequence overflow).
4. Reject ACKs with out-of-bounds/non-monotonic `AckNextSeq`.
5. Reject ACKs mismatched to current file transfer context.
6. (Phase 2) Reject forged/tampered authenticated messages.
7. (Phase 2) Reject unauthenticated first-HELLO in authenticated mode.

### Regression tests to preserve behavior
1. Successful transfer for valid single/multi-file sessions.
2. Existing overwrite and filename safety checks.
3. Existing hash/length verification and partial-file cleanup paths.

## Rollout sequence
1. Implement and ship Phase 1 first (low compatibility risk).
2. Implement Phase 2 behind opt-in flag; gather usage feedback.
3. Promote authenticated mode to default in next protocol revision (Phase 3).

## Exit criteria
Phase completion requires:
1. Code changes merged with focused tests passing.
2. Updated protocol documentation reflecting implemented behavior.
3. Manual transfer smoke test completed for sender/receiver happy path and at least one negative-path auth/injection test.

## Open decisions
1. Canonicalization format for HMAC input (stable JSON vs explicit field concatenation).
2. Key material format and secure storage guidance for `-AuthKey` (environment variable, secret store, or file-based input policy).
3. Whether to support key identifiers/rotation in-band in protocol messages.
4. Exact compatibility contract and timeline for deprecating unauthenticated mode.
5. Replay window bounds and nonce persistence strategy across process restarts.

## Related architectural decisions
- [0014: Enforce fail-closed protocol validation guardrails](../decisions/0014-enforce-fail-closed-protocol-validation-guardrails.md)
- [0015: Use monotonic UUIDv7 message IDs](../decisions/0015-use-monotonic-uuidv7-message-ids.md)
