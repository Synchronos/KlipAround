# Compatibility and validation record

This record distinguishes intended support, automated coverage, and actual
transport verification. It is not a certification of every terminal or remote
desktop product. The baseline below is KlipAround 1.0.1.

## Supported configurations

| Environment | Intended support and prerequisites | Evidence boundary |
| --- | --- | --- |
| Windows PowerShell 5.1 on Windows | Access to the desktop text clipboard. Listener with polling fallback. | Module CI on Windows Server 2022 and bundled tests against the published package. |
| PowerShell 7 on Windows | Access to the desktop text clipboard. Listener with polling fallback. | Module, package, and analyzer CI on Windows Server 2022; bundled published-package tests. |
| PowerShell 7 on Linux | `xclip` on PATH and an accessible X11 or XWayland display. | Module, package, and analyzer CI on Ubuntu 24.04; normal CI uses simulated transfers, not a configured native X11 display. |
| Native Wayland-only | Unsupported without an X11-compatible clipboard path. | No native Wayland adapter. |
| Headless session without a desktop clipboard | Unsupported. | Terminal copy/paste UI is not a substitute for OS clipboard access by the process. |
| macOS | No support commitment. | Not in the documented runtime platform set or CI matrix. |

Both endpoints must use protocol v2; v1 is incompatible. Transfers cannot
resume after a command exits. See [protocol semantics](protocol-v2.md) and
[operational troubleshooting](troubleshooting.md).

## Terminal and transport evidence

| Scenario | Status | What is and is not established |
| --- | --- | --- |
| Simulated two-party transfer | Automated coverage | Tests exercise boundary-sized files, both checksums, pipeline/path inputs, replacement, and dropped acknowledgments. Native clipboard calls are replaced for these cases. |
| Windows change listener | Automated coverage | A Windows-only test starts and disposes an operational listener. This does not establish a native end-to-end file transfer. |
| Native Linux clipboard probe and transfer | Opt-in coverage, not verified by the baseline runs | Dedicated tests require `KLIPAROUND_TEST_REAL_CLIPBOARD=1` and an accessible test X11 display. They overwrite clipboard contents. |
| Windows native two-process file transfer | Unverified by the recorded release validation | Requires dedicated execution against the actual desktop clipboard. |
| Clipboard-enabled RDP between endpoints | Unverified by the recorded release validation | A local probe or simulated test does not establish remote two-way redirection. |
| VS Code integrated terminal or PowerShell Integrated Console | No separate certification | Listener fallback is implemented; the record does not establish native end-to-end success for each terminal, extension, or remote-host combination. |
| Network-isolated bootstrap installation | Partially covered | Tests install/import the embedded payload without fetching module files; the recorded host was not established to be network-isolated. |

## Recorded 1.0.1 release validation

Recorded during the 2026-11-19 release session (Pacific time; 2026-11-20 UTC).
This is historical evidence, not a fresh execution of those tests for later
documentation changes.

* Source commit: `21155c252e9bf49fb08f56ccc14f897b79af0b7c`.
* Version tag: `1.0.1`, resolving to that commit.
* Published archive: `KlipAround.1.0.1.nupkg`.
* Download method: `Save-PSResource` from PSGallery, with a pre-created
  destination directory.
* Published and retained candidate archives had identical SHA-256:
  `4ACAB3867070A34B57179C1143BD8D658074221B637BDE7F67DBD52BA4588429`.
* Isolated extraction and normal saved-module layout imported successfully;
  exports, aliases, help, and package metadata were checked.
* The earlier verification recorded no analyzer errors and one existing
  unused-variable warning.

| Published-package test runtime | Passed | Failed | Skipped | Exit code |
| --- | ---: | ---: | ---: | ---: |
| PowerShell 7.7.0 on Windows | 59 | 0 | 5 | 0 |
| Windows PowerShell 5.1 | 58 | 0 | 6 | 0 |

The initial Windows PowerShell test attempt could not discover Pester; a
retry using the existing Pester 6.2.0 manifest by explicit path passed. The
counts above are the successful reruns, not evidence that setup never failed.
The historical summary did not retain an itemized explanation for every skip;
none should be counted as a pass.

[CI run 44669216687](https://github.com/Synchronos/KlipAround/actions/runs/44669216687)
ran against the same source commit. All three matrix jobs succeeded:

* Windows Server 2022 with Windows PowerShell.
* Windows Server 2022 with PowerShell 7.
* Ubuntu 24.04 with PowerShell 7.

The run began at `2026-11-20T03:39:35Z`. Linux evidence is source-checkout CI,
not a Linux execution of the downloaded Gallery archive. Native Linux
clipboard tests were not enabled, and real clipboard/RDP transfers were not
exercised in the recorded package validation.

### Retained published archives

| Version | SHA-256 |
| --- | --- |
| 1.0.0 | `083811154A1D4F5A40B9577C566B9E6908A69225504BF0CB161BF971027C10A7` |
| 1.0.1 | `4ACAB3867070A34B57179C1143BD8D658074221B637BDE7F67DBD52BA4588429` |

The local retained hashes and CI result were rechecked while writing this
record. That check did not redownload packages, rerun runtime tests, alter
Gallery listings, or access the clipboard.

## Adding validation evidence

Use the [contributor commands](../CONTRIBUTING.md#run-the-existing-checks) for
automated checks and the [release checklist](releasing.md) for publication
verification. Add a dated record rather than replacing an older result with
a broader unsupported claim.

For native transport testing, use disposable non-sensitive source files and
isolated destination folders. Explicitly authorize clipboard overwrite before
running probes or tests. Record:

* Exact module version, source commit, and archive hash if testing a package.
* Date with time zone, OS/runtime versions on both endpoints, terminal types,
  desktop/display type, redirection product/settings, and endpoint topology.
* Exact sanitized commands, file sizes (including empty and block-boundary
  cases), algorithms, overwrite policy, and whether listener fallback occurred.
* Destination length and independent SHA-256 comparison to the source,
  completion/error outcomes, and any partial-file residue.
* Automated command exit codes and passed/failed/skipped counts; reasons for
  skips or unavailable transport paths.

Do not include credentials, personal metadata, raw envelopes, or private
filesystem paths. A benchmark is environment-specific evidence, not a
universal throughput or maximum-file-size guarantee.
