<#
.SYNOPSIS
Runs the module tests with Pester 6.2.0 and detailed code coverage.

.DESCRIPTION
Measures module source only and writes JaCoCo coverage, NUnit3 test results,
and a CSV of missed commands. Run in a fresh PowerShell process. Test failures,
empty selections, and missing coverage data raise terminating errors.

.PARAMETER OutputDirectory
Report directory. Defaults to TestResults in the checkout. Reports are replaced
on each run; use a different directory to preserve an earlier run.

.PARAMETER TagFilter
Includes tests with these Pester tags.

.PARAMETER ExcludeTagFilter
Excludes tests with these Pester tags. No tags are excluded by default.

.PARAMETER FullNameFilter
Includes tests whose full names match these Pester wildcard patterns.

.EXAMPLE
pwsh -NoProfile -File .\Build\Invoke-KlipAroundTests.ps1

.EXAMPLE
.\Build\Invoke-KlipAroundTests.ps1 -FullNameFilter '*authenticated*' -OutputDirectory .\TestResults\auth
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestResults'),

    [string[]]$TagFilter = @(),

    [string[]]$ExcludeTagFilter = @(),

    [string[]]$FullNameFilter = @()
)

$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 6.2.0 -ErrorAction Stop

$projectRoot = Split-Path $PSScriptRoot -Parent
$outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $outputPath -Force -ErrorAction Stop

$config = New-PesterConfiguration
$config.Run.Path = @(Join-Path $projectRoot 'Tests\KlipAround.Tests.ps1')
$config.Run.RepoRoot = $projectRoot
$config.Run.Parallel = $false
$config.Run.PassThru = $true
$config.Run.Exit = $false
$config.Run.Throw = $false
$config.Filter.Tag = $TagFilter
$config.Filter.ExcludeTag = $ExcludeTagFilter
$config.Filter.FullName = $FullNameFilter
$config.Output.Verbosity = 'Detailed'
$config.Output.StackTraceVerbosity = 'Full'
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = @(
    Join-Path $projectRoot 'KlipAround.psm1'
    Join-Path $projectRoot 'Private\*.ps1'
    Join-Path $projectRoot 'Public\*.ps1'
)
$config.CodeCoverage.ExcludeTests = $true
$config.CodeCoverage.UseBreakpoints = $false
$config.CodeCoverage.ReportRoot = $projectRoot
$config.CodeCoverage.OutputFormat = 'JaCoCo'
$config.CodeCoverage.OutputPath = Join-Path $outputPath 'coverage.xml'
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnit3'
$config.TestResult.OutputPath = Join-Path $outputPath 'test-results.xml'

$result = Invoke-Pester -Configuration $config
$pesterExitCode = $LASTEXITCODE

if ($null -eq $result.CodeCoverage -or $result.CodeCoverage.CommandsAnalyzedCount -eq 0) {
    throw "Pester did not produce module coverage data. Inspect test output and reports in '$outputPath'."
}

$result.CodeCoverage.CommandsMissed |
    Select-Object File, Function, Line, EndLine, StartColumn, EndColumn, Command |
    Export-Csv -LiteralPath (Join-Path $outputPath 'missed-commands.csv') -NoTypeInformation -Encoding UTF8

Write-Host "Reports: $outputPath"
if ($pesterExitCode -ne 0 -or $result.Result -eq 'Failed') {
    throw "Pester failed: $($result.FailedCount) failed test(s). Inspect '$outputPath' for details."
}
if (($result.PassedCount + $result.FailedCount) -eq 0) {
    throw 'No tests ran. Check the test filters and skipped tests.'
}

$result
