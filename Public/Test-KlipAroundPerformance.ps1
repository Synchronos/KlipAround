Set-StrictMode -Version Latest

function Get-KlipAroundMedian {
    param([double[]]$SortedValues)

    if ($SortedValues.Count -eq 0) {
        return 0.0
    }
    $middle = [int][Math]::Floor($SortedValues.Count / 2.0)
    if ($SortedValues.Count % 2 -eq 1) {
        return $SortedValues[$middle]
    }
    return ($SortedValues[$middle - 1] + $SortedValues[$middle]) / 2.0
}

<#
.SYNOPSIS
Runs a local performance benchmark matrix for KlipAround block and window sizing.

.DESCRIPTION
Test-KlipAroundPerformance executes controlled local transfers using Receive-KlipAround and
Send-KlipAround over the current clipboard link, sweeping block and window combinations.

It returns per-run metrics and a summary recommendation based on median throughput and
successful completion rate.

.PARAMETER BlockSizesKB
Block sizes (KB) to benchmark.

.PARAMETER WindowSizes
Window sizes (blocks per burst) to benchmark.

.PARAMETER BlockChecksumAlgorithms
Per-block checksum algorithms to benchmark (`CRC32C`, `SHA256`).

.PARAMETER Iterations
Runs per block/window combination.

.PARAMETER TestFileSizeMB
Benchmark payload size in megabytes.

.PARAMETER TimeoutSeconds
Per-transfer timeout.

.PARAMETER DestinationPath
Optional parent folder for a unique benchmark directory. Defaults to a temporary folder.

.PARAMETER KeepArtifacts
Keeps generated benchmark files/folders.

.PARAMETER OutputCsvPath
Optional CSV path for per-run metrics.

.EXAMPLE
Test-KlipAroundPerformance

.EXAMPLE
Test-KlipAroundPerformance -BlockSizesKB 64,128,256,512 -WindowSizes 2,4,8 -BlockChecksumAlgorithms CRC32C,SHA256 -Iterations 5 -OutputCsvPath C:\Temp\kliparound-benchmark.csv
#>
function Test-KlipAroundPerformance {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [int[]]$BlockSizesKB = @(64, 128, 256, 512),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [int[]]$WindowSizes = @(1, 2, 4, 8),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('CRC32C', 'SHA256')]
        [string[]]$BlockChecksumAlgorithms = @('CRC32C'),

        [Parameter()]
        [ValidateRange(1, 50)]
        [int]$Iterations = 3,

        [Parameter()]
        [ValidateRange(1, 4096)]
        [int]$TestFileSizeMB = 64,

        [Parameter()]
        [ValidateRange(10, 7200)]
        [int]$TimeoutSeconds = 180,

        [Parameter()]
        [string]$DestinationPath,

        [Parameter()]
        [switch]$KeepArtifacts,

        [Parameter()]
        [string]$OutputCsvPath
    )

    foreach ($size in $BlockSizesKB) {
        if ($size -lt 4 -or $size -gt 1024) {
            throw "BlockSizesKB value '$size' is outside supported Send-KlipAround block range (4..1024 KB)."
        }
    }
    foreach ($window in $WindowSizes) {
        if ($window -lt 1 -or $window -gt 64) {
            throw "WindowSizes value '$window' is outside supported range (1..64)."
        }
    }

    $benchmarkId = [guid]::NewGuid().ToString('N')
    $basePath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("KlipAroundBenchmark-{0}" -f $benchmarkId)
    $sourcePath = Join-Path -Path $basePath -ChildPath 'source'
    $receiveRoot = if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
        Join-Path -Path $basePath -ChildPath 'received'
    }
    else {
        $destinationRoot = (Resolve-Path -LiteralPath $DestinationPath -ErrorAction Stop).Path
        Join-Path -Path $destinationRoot -ChildPath ("KlipAroundBenchmark-{0}" -f $benchmarkId)
    }
    $modulePath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'KlipAround.psd1'
    $modulePath = (Resolve-Path -Path $modulePath -ErrorAction Stop).Path

    New-Item -Path $sourcePath -ItemType Directory -Force | Out-Null
    New-Item -Path $receiveRoot -ItemType Directory -ErrorAction Stop | Out-Null

    $testFile = Join-Path -Path $sourcePath -ChildPath ("benchmark-{0}MB.bin" -f $TestFileSizeMB)
    $fileBytes = [int64]$TestFileSizeMB * 1MB
    Write-Verbose "Generating benchmark payload file: $testFile ($fileBytes bytes)"
    $writer = [IO.File]::Open($testFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $buffer = New-Object byte[] 1048576
            $remaining = $fileBytes
            while ($remaining -gt 0) {
                $chunk = [int][Math]::Min([int64]$buffer.Length, $remaining)
                $rng.GetBytes($buffer)
                $writer.Write($buffer, 0, $chunk)
                $remaining -= $chunk
            }
        }
        finally {
            $rng.Dispose()
        }
    }
    finally {
        $writer.Dispose()
    }

    $sourceHash = (Get-FileHash -Algorithm SHA256 -Path $testFile -ErrorAction Stop).Hash
    $results = New-Object System.Collections.Generic.List[object]

    $totalRuns = $BlockSizesKB.Count * $WindowSizes.Count * $BlockChecksumAlgorithms.Count * $Iterations
    $runNumber = 0
    $progressId = 4300

    try {
        foreach ($blockKb in $BlockSizesKB) {
            foreach ($window in $WindowSizes) {
                foreach ($blockChecksumAlgorithm in $BlockChecksumAlgorithms) {
                    for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
                        $runNumber++
                        $status = "Run $runNumber/$totalRuns - Block ${blockKb}KB, Window $window, Checksum $blockChecksumAlgorithm, Iteration $iteration"
                        Write-Progress -Id $progressId -Activity 'KlipAround benchmark' -Status $status -PercentComplete ([int](($runNumber / [double]$totalRuns) * 100))
                        Write-Verbose $status

                        $sessionId = [guid]::NewGuid().ToString()
                        $runFolder = Join-Path -Path $receiveRoot -ChildPath ("B{0}-W{1}-C{2}-I{3}-{4}" -f $blockKb, $window, $blockChecksumAlgorithm, $iteration, $sessionId)
                        New-Item -Path $runFolder -ItemType Directory -ErrorAction Stop | Out-Null
                        $targetFile = Join-Path -Path $runFolder -ChildPath (Split-Path -Path $testFile -Leaf)

                        $receiverJob = Start-Job -ScriptBlock {
                            param($ModulePath, $SessionId, $RunFolder, $TimeoutSeconds)
                            Import-Module $ModulePath -Force -ErrorAction Stop
                            Receive-KlipAround -SessionId $SessionId -DestinationPath $RunFolder -Force -TimeoutSeconds $TimeoutSeconds -PassThru | Out-Null
                        } -ArgumentList $modulePath, $sessionId, $runFolder, $TimeoutSeconds

                        Start-Sleep -Milliseconds 400

                        $sendElapsedMs = $null
                        $succeeded = $false
                        $match = $false
                        $errorText = $null

                        try {
                            $sw = [Diagnostics.Stopwatch]::StartNew()
                            [void](Send-KlipAround -SessionId $sessionId -Path $testFile -BlockSize ($blockKb * 1024) -WindowSize $window -BlockChecksumAlgorithm $blockChecksumAlgorithm -TimeoutSeconds $TimeoutSeconds -PassThru -ErrorAction Stop)
                            $sw.Stop()
                            $sendElapsedMs = [int64]$sw.ElapsedMilliseconds

                            $jobDone = Wait-Job -Id $receiverJob.Id -Timeout ($TimeoutSeconds + 30)
                            if (-not $jobDone) {
                                throw "Receiver did not complete within timeout for Block ${blockKb}KB Window $window Checksum $blockChecksumAlgorithm."
                            }

                            $jobState = (Get-Job -Id $receiverJob.Id).State
                            if ($jobState -ne 'Completed') {
                                $jobError = Receive-Job -Id $receiverJob.Id -ErrorAction SilentlyContinue -ErrorVariable recvErr | Out-String
                                if (-not [string]::IsNullOrWhiteSpace($jobError)) {
                                    throw "Receiver job failed ($jobState): $jobError"
                                }
                                throw "Receiver job ended in state '$jobState'."
                            }
                            [void](Receive-Job -Id $receiverJob.Id -ErrorAction SilentlyContinue)

                            if (-not (Test-Path -Path $targetFile -PathType Leaf)) {
                                throw "Expected received file '$targetFile' was not created."
                            }
                            $targetHash = (Get-FileHash -Algorithm SHA256 -Path $targetFile -ErrorAction Stop).Hash
                            $match = ($targetHash -eq $sourceHash)
                            if (-not $match) {
                                throw 'Received file hash mismatch.'
                            }

                            $succeeded = $true
                        }
                        catch {
                            $errorText = $_.Exception.Message
                        }
                        finally {
                            if ($receiverJob) {
                                try {
                                    if ((Get-Job -Id $receiverJob.Id -ErrorAction SilentlyContinue).State -eq 'Running') {
                                        Stop-Job -Id $receiverJob.Id -Force -ErrorAction SilentlyContinue | Out-Null
                                    }
                                }
                                catch {}
                                Remove-Job -Id $receiverJob.Id -Force -ErrorAction SilentlyContinue
                            }
                        }

                        $throughput = if ($succeeded -and $sendElapsedMs -gt 0) {
                            [Math]::Round(($fileBytes / 1MB) / ($sendElapsedMs / 1000.0), 3)
                        }
                        else {
                            0.0
                        }

                        $results.Add([pscustomobject]@{
                                TimestampUtc            = (Get-Date).ToUniversalTime()
                                BlockSizeKB             = $blockKb
                                WindowSize              = $window
                                BlockChecksumAlgorithm  = $blockChecksumAlgorithm
                                Iteration               = $iteration
                                FileSizeMB              = $TestFileSizeMB
                                SessionId               = $sessionId
                                Succeeded               = $succeeded
                                HashMatch               = $match
                                SendElapsedMs           = if ($sendElapsedMs) { $sendElapsedMs } else { 0 }
                                ThroughputMBps          = $throughput
                                Error                   = $errorText
                                ReceiveFolderPath       = $runFolder
                            }) | Out-Null
                    }
                }
            }
        }
    }
    finally {
        Write-Progress -Id $progressId -Activity 'KlipAround benchmark' -Completed
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputCsvPath)) {
        $csvResolvedParent = Split-Path -Path $OutputCsvPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($csvResolvedParent) -and -not (Test-Path -Path $csvResolvedParent -PathType Container)) {
            New-Item -Path $csvResolvedParent -ItemType Directory -Force | Out-Null
        }
        $results.ToArray() | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force
    }

    $summary = $results.ToArray() | Group-Object -Property BlockSizeKB,WindowSize,BlockChecksumAlgorithm | ForEach-Object {
        $rows = @($_.Group)
        $successRows = @($rows | Where-Object { $_.Succeeded })
        $throughputs = @($successRows | ForEach-Object { [double]$_.ThroughputMBps } | Sort-Object)
        $median = Get-KlipAroundMedian -SortedValues $throughputs

        [pscustomobject]@{
            BlockSizeKB          = [int]$rows[0].BlockSizeKB
            WindowSize           = [int]$rows[0].WindowSize
            BlockChecksumAlgorithm = [string]$rows[0].BlockChecksumAlgorithm
            Runs                 = $rows.Count
            Successes            = $successRows.Count
            SuccessRate          = [Math]::Round(($successRows.Count / [double][Math]::Max(1, $rows.Count)) * 100, 2)
            MedianThroughputMBps = [Math]::Round($median, 3)
            AvgThroughputMBps    = if ($successRows.Count -gt 0) { [Math]::Round((($successRows | Measure-Object -Property ThroughputMBps -Average).Average), 3) } else { 0.0 }
        }
    } | Sort-Object -Property @{ Expression = 'SuccessRate'; Descending = $true }, @{ Expression = 'MedianThroughputMBps'; Descending = $true }, @{ Expression = 'BlockSizeKB'; Descending = $false }, @{ Expression = 'WindowSize'; Descending = $false }, @{ Expression = 'BlockChecksumAlgorithm'; Descending = $false }

    $recommended = $summary | Select-Object -First 1

    $output = [pscustomobject]@{
        BenchmarkId   = $benchmarkId
        ModulePath    = $modulePath
        SourceFile    = $testFile
        SourceSizeMB  = $TestFileSizeMB
        Iterations    = $Iterations
        BlockSizesKB  = $BlockSizesKB
        WindowSizes   = $WindowSizes
        BlockChecksumAlgorithms = $BlockChecksumAlgorithms
        Results       = $results.ToArray()
        Summary       = $summary
        Recommendation = $recommended
        CsvPath       = $OutputCsvPath
    }

    if (-not $KeepArtifacts) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($DestinationPath)) {
                Remove-Item -LiteralPath $receiveRoot -Recurse -Force -ErrorAction Stop
            }
            Remove-Item -LiteralPath $basePath -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not remove benchmark artifacts: $($_.Exception.Message)"
        }
    }

    return $output
}
