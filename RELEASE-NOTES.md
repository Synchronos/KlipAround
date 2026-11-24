# KlipAround release notes

## 1.0.3

- Hardened protocol validation paths from Phase 1 of the injection remediation plan and added stricter ACK/metadata guardrails.
- Message IDs now use monotonic UUIDv7 generation with deterministic rollover coverage in tests.
- Optimized UUIDv7 generation throughput by reusing script-scope RNG state, reducing lock scope, and tightening formatting allocations.
- Added monotonic-ID-aware protocol fast paths: stale-message watermark checks and bounded seen-message tracking in wait handling.
- Simplified duplicate-message handling in protocol waits and bounded sender/receiver self-message ID tracking to prevent unbounded growth.
- Optimized sender/receiver hot paths with lower-overhead timeout/progress/update loops while preserving wire behavior.
- Reduced protocol wait-loop overhead by centralizing poll backoff jitter generation in a lightweight in-process helper.
- Refined protocol wait-loop exception scoping by narrowing parse/read try blocks, surfacing listener initialization fallback diagnostics, and rethrowing unexpected envelope-processing exceptions.
- Implemented opt-in authenticated mode (`-AuthKey`) with per-message HMAC signatures, nonce-bound session context, deterministic mixed-mode rejection behavior, and replay-digest filtering in wait handling.
- Release notes metadata links to [RELEASE-NOTES.md for the `1.0.3` Git tag](https://github.com/Synchronos/KlipAround/blob/1.0.3/RELEASE-NOTES.md).

## 1.0.2

- Receiver FIN-grace waits now use polling-only mode to reduce listener fallback noise while preserving protocol behavior.
- Added debug ignore-reason diagnostics for self-published, duplicate, and mismatch messages in protocol waits.
- Improved wait-loop timing reliability by using monotonic stopwatch timeouts (immune to wall-clock jumps) and UTC timestamp generation.
- Release notes metadata links to [RELEASE-NOTES.md for the `1.0.2` Git tag](https://github.com/Synchronos/KlipAround/blob/1.0.2/RELEASE-NOTES.md).

## 1.0.1

- Documentation metadata references the packaged `README.md`; the project URL points to the GitHub repository.
- Release notes metadata links to [RELEASE-NOTES.md for the `1.0.1` Git tag](https://raw.githubusercontent.com/Synchronos/KlipAround/refs/tags/1.0.1/RELEASE-NOTES.md).
- Package metadata uses the SPDX `MIT` license expression and records the Git repository, release tag, and source commit. The deprecated license URL and owners fields are omitted from the nuspec.
- Included these release notes in the package. Clipboard transfer behavior is unchanged from `1.0.0`.

## 1.0.0

- Initial PowerShell Gallery release. Send and receive files over a shared clipboard, including through Remote Desktop clipboard redirection. Transfers use bounded retries, per-block checksums, and SHA-256 verification before accepting a file.
- Supports Windows PowerShell 5.1 and PowerShell 7 on Windows. On Linux, PowerShell 7 requires `xclip` and an accessible X11 or XWayland display.
- Includes an offline bootstrap generator that lets you install the module without Internet or file-share access.
- The transport probe requires `-NoRestoreClipboard` because it replaces the clipboard contents without restoring them.
