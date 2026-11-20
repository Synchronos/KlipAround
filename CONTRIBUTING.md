# Contributing

KlipAround is a PowerShell module. Start with the [README](README.md),
[architecture](docs/architecture.md), and [decision index](docs/decisions/README.md).
Use the [protocol reference](docs/protocol-v2.md) for wire behavior.

## Development setup

Use Windows PowerShell 5.1 or PowerShell 7 on Windows, or PowerShell 7 on Linux.
Keep runtime changes compatible with Windows PowerShell 5.1.

The [CI workflow](.github/workflows/ci.yml) is the authoritative dependency and
validation configuration:

| Tool | Purpose |
| --- | --- |
| Pester 6.2.0 | Module and package tests. |
| PSScriptAnalyzer 1.25.0 | Static analysis in PowerShell 7. |
| Microsoft.PowerShell.PSResourceGet 1.1.0 or later | Package creation in PowerShell 7. |
| Git | Repository provenance in package metadata. |
| Linux `xclip` and X11 or XWayland | Actual Linux clipboard use, not the simulated transfer suite. |

Install missing test/build dependencies using the commands and versions in CI.
Windows PowerShell and PowerShell 7 can have different module search paths:
inspect `$env:PSModulePath` if a dependency installed for one is unavailable
in the other. Do not change system execution policy just to run tests.

From the repository root, import the source and validate the manifest:

```powershell
Test-ModuleManifest -Path .\KlipAround.psd1 -ErrorAction Stop
Import-Module .\KlipAround.psd1 -Force
```

Import registers commands; it does not start a transfer.

## Run the existing checks

Run this in a fresh process for each target PowerShell runtime:

```powershell
Import-Module Pester -RequiredVersion 6.2.0 -ErrorAction Stop
$config = New-PesterConfiguration
$config.Run.Path = '.\Tests\KlipAround.Tests.ps1'
$config.Run.Exit = $true
Invoke-Pester -Configuration $config
```

`Run.Exit` exits that PowerShell process and gives CI a nonzero exit code for
failures. To inspect results interactively instead, leave `Run.Exit` false,
set `Run.PassThru` to true, and inspect `FailedCount` and `SkippedCount`.
Do not treat skipped tests as passed evidence.

In PowerShell 7, also run the CI analysis and packaging checks:

```powershell
$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0
$errors = @(Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error -ErrorAction Stop)
if ($errors.Count -gt 0) {
    $errors | Format-List
    throw "PSScriptAnalyzer found $($errors.Count) error(s)."
}
Import-Module Pester -RequiredVersion 6.2.0
$config = New-PesterConfiguration
$config.Run.Path = '.\Build\New-KlipAroundPackage.Tests.ps1'
$config.Run.Exit = $true
Invoke-Pester -Configuration $config
```

Package tests build under Pester's test directory; they do not publish.
CI gates analyzer errors, not every warning. Do not suppress new warnings
without understanding them or fix unrelated baseline warnings as incidental work.

### Simulated versus native testing

Most transfer cases use a shared in-memory test transport across isolated
PowerShell instances. They cover boundary sizes, checksum modes, input styles,
replacement, and dropped acknowledgments without using the desktop clipboard.
The Windows listener test starts a real listener but is not a real transfer.

The Linux native probe and transfer case are opt-in. Run them only on a
dedicated test X11-compatible display, with no important clipboard contents:

```powershell
$env:KLIPAROUND_TEST_REAL_CLIPBOARD = '1'
try {
    Invoke-Pester -Path .\Tests\KlipAround.Tests.ps1
}
finally {
    Remove-Item Env:\KLIPAROUND_TEST_REAL_CLIPBOARD
}
```

This example assumes the variable was initially unset. If it already has a
value, preserve and restore it instead. These tests overwrite clipboard
contents, do not restore them, and do not certify RDP redirection. See the
[compatibility record](docs/compatibility.md) for evidence and outstanding gaps.

## Change expectations

* Follow the existing public/private script organization and naming.
* Add focused regression cases to the existing test suite for changed behavior.
  Run the smallest relevant checks first, then the release matrix as appropriate.
* Keep source/received paths literal where intended; preserve filename validation,
  explicit overwrite policy, and partial-file cleanup.
* Keep platform adapters separate from protocol logic. Do not replace unavailable
  native clipboard access with a process-local fallback.
* Update comment-based command help and [about help](en-US/about_KlipAround.help.txt)
  when the public interface changes. Update the [README](README.md) and
  [release notes](RELEASE-NOTES.md) for user-visible changes.
* For wire changes, update the [protocol reference](docs/protocol-v2.md) and
  assess compatibility on both endpoints. For architectural changes, add or
  supersede an [ADR](docs/decisions/README.md) and update the
  [arc42 and its embedded C4 views](docs/architecture.md).
* Record actual runtime, test counts, skips, and limitations; do not upgrade a
  support claim based on simulated tests alone.

Documentation-only changes need link, anchor, and diagram checks rather than a
full module test run unless they change executable examples or validation tooling.
Review examples against command help; examples that publish or alter clipboard
contents must be clearly marked.

## Before submitting

Describe the problem, focused changes, validation command/results, and any
remaining gap. Exclude credentials, private paths, raw clipboard envelopes,
generated installers, and temporary outputs. Review `git diff --check` and the
staged diff. Publishing is a separate maintainer action governed by the
[release checklist](docs/releasing.md).
