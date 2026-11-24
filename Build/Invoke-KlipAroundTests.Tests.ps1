Describe 'KlipAround coverage runner' {
    BeforeAll {
        $runner = Join-Path $PSScriptRoot 'Invoke-KlipAroundTests.ps1'
    }

    BeforeEach {
        $output = Join-Path $TestDrive 'reports'
        $runnerState = @{ Configuration = $null; ExitCode = 0; Result = [pscustomobject]@{
            Result = 'Passed'
            PassedCount = 1
            FailedCount = 0
            CodeCoverage = [pscustomobject]@{
                CommandsAnalyzedCount = 2
                CommandsMissed = @(
                    [pscustomobject]@{
                        File = 'source.ps1'; Function = 'Test-Example'
                        Line = 12; EndLine = 13; StartColumn = 1; EndColumn = 5
                        Command = 'throw "example"'
                    }
                )
            }
        } }
        Mock Invoke-Pester -MockWith ({
            param($Configuration)
            $runnerState.Configuration = $Configuration
            $global:LASTEXITCODE = $runnerState.ExitCode
            return $runnerState.Result
        }.GetNewClosure())
    }

    It 'forwards filters, measures module source, and exports missed command locations' {
        $result = & $runner -OutputDirectory $output -TagFilter 'Slow' -ExcludeTagFilter 'TransferMatrix' -FullNameFilter '*nonce*'

        $result.Result | Should -Be 'Passed'
        $config = $runnerState.Configuration
        $config.Filter.Tag.Value | Should -Be @('Slow')
        $config.Filter.ExcludeTag.Value | Should -Be @('TransferMatrix')
        $config.Filter.FullName.Value | Should -Be @('*nonce*')
        $config.CodeCoverage.OutputPath.Value | Should -Be (Join-Path $output 'coverage.xml')
        $config.CodeCoverage.Path.Value.Count | Should -Be 3
        $config.Run.Path.Value | Should -Be @(Join-Path (Split-Path $PSScriptRoot -Parent) 'Tests\KlipAround.Tests.ps1')
        $missed = @(Import-Csv -LiteralPath (Join-Path $output 'missed-commands.csv'))
        $missed.Count | Should -Be 1
        $missed[0].Line | Should -Be '12'
        $missed[0].Command | Should -Be 'throw "example"'
    }

    It 'reports discovery failures even when no individual test failed' {
        $runnerState.Result.Result = 'Failed'
        { & $runner -OutputDirectory $output } | Should -Throw '*Pester failed*'
        Test-Path -LiteralPath (Join-Path $output 'missed-commands.csv') | Should -BeTrue
    }

    It 'rejects a selection with no runnable tests' {
        $runnerState.Result.PassedCount = 0
        { & $runner -OutputDirectory $output -FullNameFilter '*no-such-test*' } |
            Should -Throw '*No tests ran*'
    }

    It 'does not ignore a nonzero Pester exit code' {
        $runnerState.ExitCode = 1
        { & $runner -OutputDirectory $output } | Should -Throw '*Pester failed*'
    }

    It 'rejects a run without measured source commands' {
        $runnerState.Result.CodeCoverage.CommandsAnalyzedCount = 0
        { & $runner -OutputDirectory $output } |
            Should -Throw '*did not produce module coverage data*'
    }
}
