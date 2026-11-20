# KlipAround release notes

## 1.0.2

- Receiver FIN-grace waits now use polling-only mode to reduce listener fallback noise while preserving protocol behavior.
- Added debug ignore-reason diagnostics for self-published, duplicate, and mismatch messages in protocol waits.
- Improved wait-loop timing reliability by using monotonic stopwatch timeouts (immune to wall-clock jumps) and UTC timestamp generation.

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
