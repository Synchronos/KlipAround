# KlipAround

KlipAround is a PowerShell module that implements a reliable, HDLC-inspired file transfer protocol over the clipboard.

It is designed for half-duplex clipboard links (including Remote Desktop clipboard redirection), where sender and receiver exchange control/data messages turn-by-turn.

Transfers support empty files and files whose final block contains a single byte.

See the [release notes](RELEASE-NOTES.md) for changes by version.

## Design goals

KlipAround is intentionally optimized for clipboard-driven transfer rather than serial/modem interoperability. The protocol goals are:

1. **Reliability over lossy clipboard timing**  
   Use explicit request/acknowledgment phases, sequence numbers, and bounded retries so transfers complete correctly even when clipboard updates are delayed.

2. **Half-duplex correctness first**  
   Treat clipboard transport as a shared single-lane link: one side publishes, the other side responds, with deterministic turn-taking and no duplex assumptions.

3. **Integrity at block and file scope**  
   Detect corruption early with per-block checksums (SHA256 by default) and validate end-to-end correctness with per-file SHA-256 before final acceptance.

4. **Large-file practicality**  
   Support multi-megabyte to large binary transfers through configurable block sizing and a windowed burst model (`DATA_BURST` / `ACK_REPORT`) tuned for clipboard behavior.

5. **Operability and observability**  
   Provide predictable diagnostics (`-Verbose`, `-Debug`), progress bars, and a transport preflight (`Test-KlipAroundTransport`) so users can validate and troubleshoot real sessions.

6. **PowerShell-native usability**  
   Keep interaction model simple and scriptable with explicit sender/receiver cmdlets and standard `Get-Help` support.

## Exported cmdlets

Primary cmdlets:

- `Send-KlipAround`
- `Receive-KlipAround`
- `New-KlipAroundBootstrap`
- `Test-KlipAroundTransport`
- `Test-KlipAroundPerformance`

Compatibility aliases:

- `Send-KlipAroundClip` -> `Send-KlipAround`
- `Receive-KlipAroundClip` -> `Receive-KlipAround`

## Protocol summary

KlipAround uses explicit message types:

1. `HELLO` / `HELLO_ACK`
2. `FILE_META` / `FILE_META_ACK`
3. `DATA_BURST` / `ACK_REPORT` (windowed block transfer)
4. `FILE_EOF` / `FILE_EOF_ACK`
5. `FIN` / `FIN_ACK`

Each clipboard payload is a text envelope:

- `-----BEGIN KLIPAROUND/2-----`
- JSON content containing Base64-encoded data blocks
- `-----END KLIPAROUND/2-----`

Protocol version 2 is not compatible with version 1. Upgrade both endpoints before
transferring files.

Data integrity:

- SHA-256 per data block by default (or CRC32C when selected)
- SHA-256 per file

Selective retransmission:

- `ACK_REPORT` includes cumulative `AckNextSeq` and optional `MissingSeqs`.
- Sender prioritizes retransmit of `MissingSeqs` (SREJ-style) before sending new sequences.
- If an acknowledgment is lost, the sender retries the burst up to `MaxRetries`.
- After `FIN`, the receiver remains available briefly to acknowledge retried completion messages.
- An interrupted command cannot resume a transfer after it exits.

## Installation

From the module folder:

```powershell
Import-Module .\KlipAround.psd1 -Force
```

### Release package

From a source checkout, use PowerShell with Microsoft.PowerShell.PSResourceGet
1.1.0 or later to create a clean, local NuGet package:

```powershell
.\Build\New-KlipAroundPackage.ps1
```

The package is written to `artifacts` and includes the module, help, README,
license, and tests; smoke-test artifacts are excluded. The build does not publish to a
repository and refuses to overwrite an existing package. Supply
`-OutputDirectory` to choose another location.

### Offline bootstrap

On a machine with KlipAround installed, create a self-contained installer:

```powershell
New-KlipAroundBootstrap -Path .\Install-KlipAround.ps1
```

Transfer the generated script to the offline machine, for example by copying
its text through a shared clipboard. On Windows:

```powershell
Get-Content -Raw .\Install-KlipAround.ps1 | Set-Clipboard
```

Paste the text into a `.ps1` file on the destination, then run:

```powershell
.\Install-KlipAround.ps1 -Scope CurrentUser
```

Use `-Scope AllUsers` for a system-wide installation; this normally requires
administrator privileges on Windows or appropriate write permissions on Linux.
The installer uses the default module directory for the PowerShell edition
running it and installs into a versioned `KlipAround` directory. Run it in
each PowerShell edition that needs its own module directory. If `PSModulePath`
has been customized, you may need to add the directory or import the installed
manifest by its full path.

An existing installation of the same version is left unchanged unless you run
the installer with `-Force`. Other version directories are preserved. An
unversioned installation must be moved or removed first. The generator also
requires `-Force` to replace an existing bootstrap script.

The script contains a compressed ZIP archive encoded as MIME-style Base64 and
verifies its SHA-256 hash before installing. The hash detects accidental
corruption; it does not authenticate the script. Only run bootstrap scripts
from sources you trust. The offline machine needs a supported PowerShell
installation. Using KlipAround for transfers on Linux also requires the
`xclip` and X11 prerequisites described below.

On Linux, use PowerShell 7 with `xclip` installed and an accessible X11 display
(or XWayland). KlipAround uses `xclip` directly and polls for clipboard changes.
Native Wayland-only sessions and headless SSH sessions without an X11 clipboard
are not supported. Both endpoints must have access to a shared clipboard, such
as through clipboard-enabled remote desktop redirection.
Clipboard reads and writes are bounded by the transfer timeout. A read started
near a message deadline may finish up to one polling interval later. A stalled
`xclip` process is stopped and reported as an error.

Linux clipboard integration tests are opt-in because they overwrite clipboard
contents. Run them only against a dedicated test X11 display:

```powershell
$env:KLIPAROUND_TEST_REAL_CLIPBOARD = '1'
Invoke-Pester -Path ./Tests/KlipAround.Tests.ps1
```

## Recommended workflow

1. Start receiver on destination machine/session.
2. Start sender on source machine/session.
3. Keep both commands running until transfer completes.

### 1) Validate transport link

```powershell
Test-KlipAroundTransport -ProbeClipboardBytes 20000000 -NoRestoreClipboard
```

The probe overwrites the clipboard and cannot restore its previous contents.
Without `-NoRestoreClipboard`, it does not access the clipboard and reports
that explicit permission is required.

### 2) Receiver side

```powershell
Receive-KlipAround -DestinationPath C:\Temp\Inbox -TimeoutSeconds 120 -Verbose
```

### 3) Sender side

```powershell
Send-KlipAround -Path C:\Temp\A.bin,C:\Temp\B.iso -WindowSize 16 -BlockSize 131072 -BlockChecksumAlgorithm SHA256 -TimeoutSeconds 120 -Verbose
```

## Important parameters

### Send-KlipAround

- `-Path`: file paths, including pipeline input; an existing literal filename takes
  precedence over wildcard expansion when it contains wildcard characters
- `-WindowSize` (default `16`): blocks per burst before waiting for ACK
- `-BlockSize` (default `131072`): bytes per block
- `-BlockChecksumAlgorithm` (default `SHA256`): per-block checksum (`CRC32C` or `SHA256`)
- `-PrecomputeHash`: precompute file SHA-256 before transfer (legacy behavior, extra file read)
- `-TimeoutSeconds` (default `90`): response timeout
- `-MaxRetries` (default `5`): retries before failure
- `-SessionId`: optional explicit session identity

### Receive-KlipAround

- `-DestinationPath`: output folder
- `-TimeoutSeconds` (default `90`)
- `-Force`: overwrite existing files
- `-SessionId`: optional explicit session identity

## Diagnostics

- Use `-Verbose` for state/progress details.
- Use `-Debug` to display raw clipboard envelope messages.
- Both sender and receiver display progress bars for overall and per-file transfer.
- Clipboard listener and benchmark job cleanup failures are reported as warnings.

## Get-Help topics

```powershell
Get-Help about_KlipAround
Get-Help Send-KlipAround -Full
Get-Help Receive-KlipAround -Full
Get-Help New-KlipAroundBootstrap -Full
Get-Help Test-KlipAroundTransport -Full
Get-Help Test-KlipAroundPerformance -Full
```

## Benchmarking block and window sizes

Use `Test-KlipAroundPerformance` to run a local benchmark matrix and get a recommendation.

```powershell
Test-KlipAroundPerformance -BlockSizesKB 64,128,256,512 -WindowSizes 1,2,4,8 -BlockChecksumAlgorithms CRC32C,SHA256 -Iterations 5 -OutputCsvPath C:\Temp\kliparound-benchmark.csv
```

Each benchmark uses a new, uniquely named directory under the destination so it
does not overwrite pre-existing files.

## License

KlipAround is licensed under the [MIT License](./LICENSE).
