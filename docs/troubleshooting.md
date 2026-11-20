# Troubleshooting

Use this guide with the [command help](../README.md#get-help-topics) and
[compatibility record](compatibility.md). It describes KlipAround 1.0.1.

## Before diagnosing a transfer

* Transfers, probes, and benchmarks overwrite clipboard contents. Save anything
  important elsewhere first, stop unrelated transfers, and avoid copying text
  while a transfer runs. A probe cannot restore the previous clipboard.
* Use trusted endpoints and a trusted clipboard connection. Base64 is not
  encryption; session IDs and checksums do not authenticate the other endpoint.
* Start with `-Verbose`. `-Debug` can expose file contents and host/user metadata
  in raw envelopes. Do not post raw debug logs without reviewing and redacting
  them. Use a disposable, non-sensitive test file for diagnosis.
* A failed command cannot resume. Check which files already completed before
  restarting; a multi-file transfer is not an all-or-nothing transaction.

## Check the environment

The following commands inspect the current process without reading the clipboard:

```powershell
$PSVersionTable
Get-Module KlipAround | Select-Object Name, Version, Path
Get-Command Send-KlipAround, Receive-KlipAround |
    Select-Object Name, Source, Version
```

Confirm both endpoints use protocol v2. A session ID is a correlation value,
not a secret. If supplied explicitly, use the same value on both endpoints.
Create the destination directory before starting the receiver.

### Optional clipboard probe

Only when you explicitly accept replacing the clipboard, and before starting
either transfer command:

```powershell
Test-KlipAroundTransport -ProbeClipboardBytes 4096 -NoRestoreClipboard |
    Format-List
```

Inspect `Succeeded`, `RoundTripMatch`, and `Message`; the command returns a
result object even when the probe fails. Without `-NoRestoreClipboard`, it
performs no clipboard access.

The probe reads back text in the calling session. Success proves local
read/write access, **not** that another desktop session receives those updates.
Before a real transfer, use disposable text to check manual clipboard sharing
in both directions. That manual check also replaces clipboard contents.

## Symptoms and recovery

| Symptom | Check | Recovery |
| --- | --- | --- |
| Timeout waiting for initial `HELLO` or `HELLO_ACK` | Are both commands running in clipboard-connected sessions? Is clipboard redirection enabled? Do explicit session IDs match? | Stop the failed attempt. Verify sharing in both directions, then start the receiver followed promptly by the sender. Increase timeouts on both sides only if the connection works but is slow. |
| Timeout waiting for `FILE_META_ACK`, `ACK_REPORT`, or `FILE_EOF_ACK` | Look at the other endpoint's first error; it may have rejected a filename, an existing target, or a filesystem operation. Also check clipboard size limits and competing writes. | Fix the peer error first. For size-sensitive links, try a smaller block and window. Do not treat more retries as a fix for a broken clipboard connection. |
| Listener startup, failure, or no-signal verbose message | The Windows listener may be unavailable or may not report changes. | Polling fallback is intentional. Continue if progress resumes; if it still times out, check actual clipboard sharing. There is no public switch to force listener mode. FIN-grace follow-up waits already use polling-only mode and report a lower-noise verbose message instead of listener fallback chatter. |
| Commands stall in a VS Code terminal | Identify whether this is a local terminal, the PowerShell extension's Integrated Console, or a remote terminal, and which desktop clipboard it can access. | Keep transfer commands in separate concurrently running sessions. Compare with a standalone PowerShell process in the same desktop session. A terminal's copy/paste UI does not itself establish shared OS clipboard access between hosts. |
| `Set-Clipboard` or `Get-Clipboard` unavailable | Check that the command is running in a supported Windows PowerShell environment, or Linux PowerShell 7 with `xclip`. | Use a supported runtime and platform prerequisites. Do not substitute an in-memory clipboard: it cannot connect separate processes. |
| Linux reports `xclip` missing | Inspect `Get-Command xclip -ErrorAction SilentlyContinue`. | Install `xclip` using the host's package manager, then confirm access to the intended X11-compatible display. |
| Linux reports `DISPLAY` unset or inaccessible, or `xclip failed` | Inspect `$env:DISPLAY` and display access permissions. | Run in the intended X11 or XWayland desktop session with legitimate display access. Setting `DISPLAY` to an arbitrary value does not grant access. Native Wayland-only and headless sessions without X11 clipboard access are unsupported. |
| `xclip Read` or `Write` times out | The display or clipboard owner may be unresponsive. | Restore display access, then retry with a disposable file. KlipAround bounds these operations and stops its stalled subprocess; do not kill processes by name. |
| Destination does not resolve or is not a folder | The receiver requires an existing directory. | Create or select the correct directory and check write permissions before restarting. |
| Target file already exists | Compare it with the source; it may be a completed file from an earlier attempt. | Use a new destination or intentionally authorize replacement with `-Force`. Never add `-Force` just to suppress an unexplained error. |
| Invalid received filename | The receiver rejects rooted paths, directory components, and names invalid on its platform. | Rename the source file to a name valid on the destination platform. Do not weaken path validation. |
| File hash or length mismatch | Check source stability, clipboard interference, and the peer's errors. | Leave the source unchanged for the whole transfer and restart. The receiver does not promote an unverified partial file, even with `-Force`. |
| Cleanup warning mentions a partial file | A handle, permission, or filesystem failure prevented cleanup. | Stop both commands and confirm the exact named file belongs to this failed attempt before removing it. Do not bulk-delete `*.part` files or other sessions' partials. |
| Sender finished but receiver remains running briefly | The receiver waits after `FIN` to re-acknowledge a retried completion message. | Allow the completion grace period. Do not assume the pause means more file data is being transferred. |

### Conservative transfer settings

This example deliberately replaces the clipboard. Use two PowerShell sessions
sharing the intended link, an existing destination, and a disposable source.
The same session ID is entered on both endpoints:

```powershell
# Receiver session
Receive-KlipAround -DestinationPath C:\Temp\Inbox -SessionId 'diagnostic-1' `
    -TimeoutSeconds 120 -Verbose
```

```powershell
# Sender session
Send-KlipAround -Path C:\Temp\sample.bin -SessionId 'diagnostic-1' `
    -BlockSize 4096 -WindowSize 1 -TimeoutSeconds 120 -Verbose
```

These settings are diagnostic starting points, not throughput recommendations.
Use platform-appropriate existing paths on Linux.

## Offline installation issues

* **Same version already installed:** replacement requires `-Force` on the
  generated installer. Other version directories are retained.
* **Unversioned installation found:** inspect and preserve it before moving or
  removing it; the installer intentionally refuses to overwrite it.
* **Access denied:** prefer `CurrentUser` unless a system-wide install is
  required and authorized.
* **Import cannot find the installed module:** run the installer in the
  PowerShell edition that will use it; check `$env:PSModulePath`, or import the
  installed manifest by its full path. The installer does not install PowerShell,
  `xclip`, or clipboard redirection.
* **Payload hash or archive validation fails:** obtain a fresh installer from
  a trusted source. Do not edit out its validation checks. Its hash detects
  corruption, not an untrusted script author.

## Reporting a reproducible issue

Include module and PowerShell versions, operating systems, terminal types,
whether the sessions are local or remote, the clipboard-redirection product,
sanitized parameters, file sizes, the first error from each endpoint, and
whether manual two-way sharing worked. State whether listener fallback occurred.
Avoid usernames, private paths, file contents, and raw envelopes in public reports.
