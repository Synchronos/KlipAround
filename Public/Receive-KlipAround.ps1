Set-StrictMode -Version Latest

<#
.SYNOPSIS
Receives files using the KlipAround reliable windowed clipboard protocol.

.DESCRIPTION
Receive-KlipAround is the receiver side of a two-party transfer and must run concurrently
with Send-KlipAround in another clipboard-connected session/machine.

.PARAMETER DestinationPath
Folder where received files are written.

.PARAMETER TimeoutSeconds
Per-message timeout while waiting for sender messages.

.PARAMETER Force
Replace existing destination files after the received content has been verified.

.PARAMETER SessionId
Optional specific session id to receive. If omitted, accepts the first HELLO and binds to it.

.PARAMETER PassThru
Returns written files.
#>
function Receive-KlipAround {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath = (Get-Location).Path,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 90,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [string]$SessionId,

        [Parameter()]
        [switch]$PassThru
    )

    $destResolved = @(Resolve-Path -LiteralPath $DestinationPath -ErrorAction Stop)
    if ($destResolved.Count -ne 1) {
        throw "Destination '$DestinationPath' resolves to more than one path."
    }
    $destFolder = $destResolved[0].Path
    if (-not (Test-Path -LiteralPath $destFolder -PathType Container)) {
        throw "Destination '$destFolder' is not a folder."
    }

    $sentIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $seenMessageIds = New-Object 'System.Collections.Generic.HashSet[string]'
    $receivedFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $overallProgressId = 4200
    $fileProgressId = 4201
    $processedFiles = 0
    $completedFileIndexes = New-Object 'System.Collections.Generic.HashSet[int]'
    $expectedFileCount = 0

    try {
        if ([string]::IsNullOrWhiteSpace($SessionId)) {
            $helloAny = $null
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while ((Get-Date) -lt $deadline -and -not $helloAny) {
                try {
                    $remainingMilliseconds = [int][Math]::Max(250, [Math]::Ceiling(($deadline - (Get-Date)).TotalMilliseconds))
                    $text = Get-KlipAroundClipboardText -TimeoutMilliseconds $remainingMilliseconds
                }
                catch [System.InvalidOperationException] {
                    throw
                }
                catch {
                    Start-Sleep -Milliseconds 250
                    continue
                }

                try {
                    $msg = ConvertFrom-KlipAroundEnvelope -Text $text
                    Write-KlipAroundDebugEnvelope -Direction Receive -Text $text
                    if ($msg.Role -eq 'Sender' -and $msg.MessageType -eq 'HELLO') {
                        $helloAny = $msg
                        break
                    }
                }
                catch {
                    Start-Sleep -Milliseconds 250
                }
            }

            if (-not $helloAny) {
                throw "Timed out waiting for initial HELLO from sender."
            }
            $SessionId = [string]$helloAny.SessionId
            [void]$seenMessageIds.Add([string]$helloAny.MessageId)
            $hello = $helloAny
        }
        else {
            $hello = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds $TimeoutSeconds -IgnoreMessageIds $sentIds -SeenMessageIds $seenMessageIds
        }

        $expectedFileCount = [int]$hello.Payload.FileCount
        $helloAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType HELLO_ACK -Payload @{
            Accepted = $true
            ReceiverHost = $env:COMPUTERNAME
        }
        $published = Publish-KlipAroundMessage -Message $helloAck -TimeoutSeconds $TimeoutSeconds
        [void]$sentIds.Add($published.MessageId)

        $done = $false
        $dataWaitSeconds = [Math]::Min(3600, $TimeoutSeconds + 1)
        while (-not $done) {
            $next = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Sender -ExpectedMessageType @('HELLO', 'FILE_META', 'FILE_EOF', 'FIN') -TimeoutSeconds $TimeoutSeconds -IgnoreMessageIds $sentIds -SeenMessageIds $seenMessageIds
            if ($next.MessageType -eq 'HELLO') {
                $helloAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType HELLO_ACK -Payload @{
                    Accepted = $true
                    ReceiverHost = $env:COMPUTERNAME
                }
                $published = Publish-KlipAroundMessage -Message $helloAck -TimeoutSeconds $TimeoutSeconds
                [void]$sentIds.Add($published.MessageId)
                continue
            }
            if ($next.MessageType -eq 'FIN') {
                $finAckGraceSeconds = [Math]::Min(3600, $TimeoutSeconds + 2)
                if ($next.Payload.PSObject.Properties.Name -contains 'AckGraceSeconds') {
                    $advertisedGrace = 0
                    if (-not [int]::TryParse([string]$next.Payload.AckGraceSeconds, [ref]$advertisedGrace) -or
                        $advertisedGrace -lt 3 -or $advertisedGrace -gt 3600) {
                        throw 'Invalid FIN acknowledgement grace period.'
                    }
                    $finAckGraceSeconds = $advertisedGrace
                }
                $finAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType FIN_ACK -Payload @{
                    ReceivedFiles = $receivedFiles.Count
                }
                $published = Publish-KlipAroundMessage -Message $finAck -TimeoutSeconds $TimeoutSeconds
                [void]$sentIds.Add($published.MessageId)

                $graceDeadline = (Get-Date).AddSeconds($finAckGraceSeconds)
                while ((Get-Date) -lt $graceDeadline) {
                    try {
                        $followUp = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Sender -ExpectedMessageType @('FIN', 'HELLO') -TimeoutSeconds 2 -IgnoreMessageIds $sentIds -SeenMessageIds $seenMessageIds
                    }
                    catch {
                        $isWaitTimeout = $_.Exception.Message -like "Timed out waiting for message types*"
                        if ($isWaitTimeout) {
                            continue
                        }
                        throw
                    }

                    if ($followUp.MessageType -eq 'HELLO') {
                        $helloAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType HELLO_ACK -Payload @{
                            Accepted = $true
                            ReceiverHost = $env:COMPUTERNAME
                        }
                        $published = Publish-KlipAroundMessage -Message $helloAck -TimeoutSeconds $TimeoutSeconds
                        [void]$sentIds.Add($published.MessageId)
                        continue
                    }

                    $finAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType FIN_ACK -Payload @{
                        ReceivedFiles = $receivedFiles.Count
                    }
                    $published = Publish-KlipAroundMessage -Message $finAck -TimeoutSeconds $TimeoutSeconds
                    [void]$sentIds.Add($published.MessageId)
                }

                $done = $true
                break
            }
            if ($next.MessageType -eq 'FILE_EOF') {
                $dupFileIndex = [int]$next.Payload.FileIndex
                if ($completedFileIndexes.Contains($dupFileIndex)) {
                    $eofAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType FILE_EOF_ACK -Payload @{
                        FileIndex = $dupFileIndex
                        Accepted  = $true
                    }
                    $published = Publish-KlipAroundMessage -Message $eofAck -TimeoutSeconds $TimeoutSeconds
                    [void]$sentIds.Add($published.MessageId)
                    continue
                }

                throw "Received unexpected FILE_EOF for file index $dupFileIndex before FILE_META."
            }

            $fileIndex = [int]$next.Payload.FileIndex
            $fileName = [string]$next.Payload.Name
            $fileLength = [int64]$next.Payload.Length
            $fileSha256FromMeta = [string]$next.Payload.Sha256
            $blockSize = [int]$next.Payload.BlockSize
            $totalBlocks = [int]$next.Payload.TotalBlocks
            $blockChecksumAlgorithm = if ($next.Payload.PSObject.Properties.Name -contains 'BlockChecksumAlgorithm' -and -not [string]::IsNullOrWhiteSpace([string]$next.Payload.BlockChecksumAlgorithm)) {
                [string]$next.Payload.BlockChecksumAlgorithm
            }
            else {
                'CRC32C'
            }
            $processedFiles = [Math]::Max($processedFiles, $fileIndex + 1)

            if ($completedFileIndexes.Contains($fileIndex)) {
                $metaAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType FILE_META_ACK -Payload @{
                    FileIndex = $fileIndex
                    Accepted  = $true
                }
                $published = Publish-KlipAroundMessage -Message $metaAck -TimeoutSeconds $TimeoutSeconds
                [void]$sentIds.Add($published.MessageId)
                continue
            }

            if ([string]::IsNullOrWhiteSpace($fileName) -or $fileName -in @('.', '..') -or
                [IO.Path]::IsPathRooted($fileName) -or $fileName.IndexOfAny([char[]]@('\', '/')) -ge 0 -or
                $fileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                throw "Invalid received file name '$fileName'. Only file names without directory components are allowed."
            }
            $targetPath = Join-Path -Path $destFolder -ChildPath $fileName
            if ((Test-Path -LiteralPath $targetPath -PathType Leaf) -and -not $Force) {
                throw "Target file '$targetPath' already exists. Use -Force to overwrite."
            }

            Write-Progress -Id $overallProgressId -Activity 'KlipAround receive' -Status "Receiving file $($fileIndex + 1) of ${expectedFileCount}: $fileName" -PercentComplete ([int](($fileIndex / [double][Math]::Max(1,$expectedFileCount)) * 100))

            $tempPath = $targetPath + '.' + [guid]::NewGuid().ToString('N') + '.kliparound.part'
            $stream = [System.IO.File]::Open($tempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $streamHasher = [System.Security.Cryptography.SHA256]::Create()
            $streamedFileHash = $null
            try {
                $metaAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType FILE_META_ACK -Payload @{
                    FileIndex = $fileIndex
                    Accepted  = $true
                }
                $published = Publish-KlipAroundMessage -Message $metaAck -TimeoutSeconds $TimeoutSeconds
                [void]$sentIds.Add($published.MessageId)

                $expectedSeq = 0
                $outOfOrderBlocks = New-Object 'System.Collections.Generic.Dictionary[int,byte[]]'
                while ($expectedSeq -lt $totalBlocks) {
                    $burst = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Sender -ExpectedMessageType @('DATA_BURST', 'HELLO', 'FILE_META') -TimeoutSeconds $dataWaitSeconds -IgnoreMessageIds $sentIds -SeenMessageIds $seenMessageIds
                    if ($burst.MessageType -eq 'HELLO') {
                        $helloAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType HELLO_ACK -Payload @{
                            Accepted = $true
                            ReceiverHost = $env:COMPUTERNAME
                        }
                        $published = Publish-KlipAroundMessage -Message $helloAck -TimeoutSeconds $TimeoutSeconds
                        [void]$sentIds.Add($published.MessageId)
                        continue
                    }
                    if ($burst.MessageType -eq 'FILE_META') {
                        $metaFileIndex = [int]$burst.Payload.FileIndex
                        if ($metaFileIndex -ne $fileIndex) {
                            throw "Received FILE_META for file index $metaFileIndex while receiving file index $fileIndex."
                        }
                        $metaAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType FILE_META_ACK -Payload @{
                            FileIndex = $metaFileIndex
                            Accepted  = $true
                        }
                        $published = Publish-KlipAroundMessage -Message $metaAck -TimeoutSeconds $TimeoutSeconds
                        [void]$sentIds.Add($published.MessageId)
                        continue
                    }
                    if ([int]$burst.Payload.FileIndex -ne $fileIndex) {
                        throw "Received DATA_BURST for file index $($burst.Payload.FileIndex), expected $fileIndex."
                    }

                    $blocks = @($burst.Payload.Blocks | Sort-Object Seq)
                    $maxSeqSeen = -1
                    $explicitMissing = New-Object 'System.Collections.Generic.HashSet[int]'
                    foreach ($block in $blocks) {
                        $seq = [int]$block.Seq
                        if ($seq -lt $expectedSeq) {
                            continue
                        }
                        if ($seq -gt $maxSeqSeen) {
                            $maxSeqSeen = $seq
                        }
                        if ($outOfOrderBlocks.ContainsKey($seq)) {
                            continue
                        }
                        try {
                            $bytes = Expand-KlipAroundDataBlock -Block $block -ExpectedChecksumAlgorithm $blockChecksumAlgorithm
                            $outOfOrderBlocks[$seq] = $bytes
                        }
                        catch {
                            [void]$explicitMissing.Add($seq)
                        }
                    }

                    while ($outOfOrderBlocks.ContainsKey($expectedSeq)) {
                        $bytes = $outOfOrderBlocks[$expectedSeq]
                        if (($expectedSeq + 1) -eq $totalBlocks) {
                            [void]$streamHasher.TransformFinalBlock($bytes, 0, $bytes.Length)
                        }
                        else {
                            [void]$streamHasher.TransformBlock($bytes, 0, $bytes.Length, $null, 0)
                        }
                        $stream.Write($bytes, 0, $bytes.Length)
                        [void]$outOfOrderBlocks.Remove($expectedSeq)
                        $expectedSeq++
                    }

                    $missingSeqs = New-Object System.Collections.Generic.List[int]
                    if ($maxSeqSeen -ge $expectedSeq) {
                        for ($seq = $expectedSeq; $seq -le $maxSeqSeen; $seq++) {
                            if (-not $outOfOrderBlocks.ContainsKey($seq)) {
                                [void]$missingSeqs.Add($seq)
                            }
                        }
                    }
                    foreach ($missingSeq in $explicitMissing) {
                        if ($missingSeq -ge $expectedSeq -and -not $missingSeqs.Contains($missingSeq)) {
                            [void]$missingSeqs.Add($missingSeq)
                        }
                    }

                    $ack = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType ACK_REPORT -Payload @{
                        FileIndex   = $fileIndex
                        AckNextSeq  = $expectedSeq
                        TotalBlocks = $totalBlocks
                        MissingSeqs = @($missingSeqs.ToArray() | Sort-Object -Unique)
                    }
                    $published = Publish-KlipAroundMessage -Message $ack -TimeoutSeconds $TimeoutSeconds
                    [void]$sentIds.Add($published.MessageId)

                    $percent = [int](($expectedSeq / [double][Math]::Max(1,$totalBlocks)) * 100)
                    Write-Progress -Id $fileProgressId -ParentId $overallProgressId -Activity "Receiving $fileName" -Status "Block $expectedSeq of $totalBlocks written ($blockChecksumAlgorithm)" -PercentComplete $percent
                }

                if ($null -eq $streamHasher.Hash) {
                    throw "Streaming SHA-256 hash was not finalized for '$fileName'."
                }
                $streamedFileHash = -join ($streamHasher.Hash | ForEach-Object { $_.ToString('X2') })
            }
            finally {
                Write-Progress -Id $fileProgressId -ParentId $overallProgressId -Activity "Receiving $fileName" -Completed
                $streamHasher.Dispose()
                $stream.Dispose()
            }

            do {
                $eof = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Sender -ExpectedMessageType @('FILE_EOF', 'DATA_BURST') -TimeoutSeconds $dataWaitSeconds -IgnoreMessageIds $sentIds -SeenMessageIds $seenMessageIds
                if ($eof.MessageType -eq 'DATA_BURST') {
                    if ([int]$eof.Payload.FileIndex -ne $fileIndex) {
                        throw "Received DATA_BURST for file index $($eof.Payload.FileIndex), expected $fileIndex."
                    }
                    $ack = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType ACK_REPORT -Payload @{
                        FileIndex   = $fileIndex
                        AckNextSeq  = $totalBlocks
                        TotalBlocks = $totalBlocks
                        MissingSeqs = @()
                    }
                    $published = Publish-KlipAroundMessage -Message $ack -TimeoutSeconds $TimeoutSeconds
                    [void]$sentIds.Add($published.MessageId)
                }
            } while ($eof.MessageType -eq 'DATA_BURST')
            if ([int]$eof.Payload.FileIndex -ne $fileIndex) {
                throw "Received FILE_EOF for file index $($eof.Payload.FileIndex), expected $fileIndex."
            }
            $fileSha256FromEof = [string]$eof.Payload.Sha256
            if (-not [string]::IsNullOrWhiteSpace($fileSha256FromMeta) -and -not [string]::IsNullOrWhiteSpace($fileSha256FromEof) -and $fileSha256FromMeta -ne $fileSha256FromEof) {
                throw "FILE_META and FILE_EOF SHA-256 mismatch for '$fileName'."
            }
            $expectedFileSha256 = if (-not [string]::IsNullOrWhiteSpace($fileSha256FromEof)) { $fileSha256FromEof } else { $fileSha256FromMeta }
            if ([string]::IsNullOrWhiteSpace($expectedFileSha256)) {
                throw "Missing expected SHA-256 for '$fileName'."
            }

            $tempInfo = Get-Item -LiteralPath $tempPath -ErrorAction Stop
            if ($tempInfo.Length -ne $fileLength) {
                throw "Received length mismatch for '$fileName'. Expected $fileLength, got $($tempInfo.Length)."
            }
            if ($streamedFileHash -ne $expectedFileSha256) {
                throw "Received hash mismatch for '$fileName'."
            }

            if ($Force -and [IO.File]::Exists($targetPath)) {
                [IO.File]::Replace($tempPath, $targetPath, [System.Management.Automation.Language.NullString]::Value)
            }
            else {
                [IO.File]::Move($tempPath, $targetPath)
            }
            $fileInfo = Get-Item -LiteralPath $targetPath -ErrorAction Stop
            [void]$receivedFiles.Add($fileInfo)

            $eofAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType FILE_EOF_ACK -Payload @{
                FileIndex = $fileIndex
                Accepted  = $true
            }
            $published = Publish-KlipAroundMessage -Message $eofAck -TimeoutSeconds $TimeoutSeconds
            [void]$sentIds.Add($published.MessageId)
            [void]$completedFileIndexes.Add($fileIndex)
        }

        if ($PassThru) {
            return $receivedFiles.ToArray()
        }
    }
    finally {
        Write-Progress -Id $fileProgressId -ParentId $overallProgressId -Activity 'Receiving file' -Completed
        Write-Progress -Id $overallProgressId -Activity 'KlipAround receive' -Completed
    }
}
