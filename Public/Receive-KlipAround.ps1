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

.PARAMETER AuthKey
Optional shared authentication key. When provided, receiver requires signed messages
and enforces authenticated nonce context.

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
        [string]$AuthKey,

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
    $sentIdOrder = New-Object 'System.Collections.Generic.Queue[string]'
    $sentIdsMaxCount = 4096
    $seenMessageIds = New-Object 'System.Collections.Generic.HashSet[string]'
    $seenMessageIdOrder = New-Object 'System.Collections.Generic.Queue[string]'
    $lastAcceptedMessageId = $null
    $receivedFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $overallProgressId = 4200
    $fileProgressId = 4201
    $processedFiles = 0
    $completedFileIndexes = New-Object 'System.Collections.Generic.HashSet[int]'
    $expectedFileCount = 0
    $tempPath = $null
    $trackSentId = {
        param([Parameter(Mandatory)][string]$MessageId)
        if ($sentIds.Add($MessageId)) {
            $sentIdOrder.Enqueue($MessageId)
            while ($sentIdOrder.Count -gt $sentIdsMaxCount) {
                $expiredId = $sentIdOrder.Dequeue()
                [void]$sentIds.Remove($expiredId)
            }
        }
    }
    $publishAndTrack = {
        param(
            [Parameter(Mandatory)]
            [hashtable]$Message,

            [Parameter(Mandatory)]
            [int]$PublishTimeoutSeconds
        )

        if ($authEnabled) {
            if ($null -eq $Message.Payload) {
                $Message.Payload = @{}
            }
            if ($Message.Payload -isnot [System.Collections.IDictionary]) {
                throw "Authenticated mode requires dictionary payloads for message type '$($Message.MessageType)'."
            }
            if (-not [string]::IsNullOrWhiteSpace($senderAuthNonce)) {
                $Message.Payload.AuthSenderNonce = $senderAuthNonce
            }
            if (-not [string]::IsNullOrWhiteSpace($receiverAuthNonce)) {
                $Message.Payload.AuthReceiverNonce = $receiverAuthNonce
            }
        }

        $publishedMessage = Publish-KlipAroundMessage -Message $Message -TimeoutSeconds $PublishTimeoutSeconds -AuthKey $AuthKey
        & $trackSentId $publishedMessage.MessageId
    }
    $authEnabled = -not [string]::IsNullOrWhiteSpace($AuthKey)
    $senderAuthNonce = $null
    $receiverAuthNonce = if ($authEnabled) { New-KlipAroundAuthNonce } else { $null }
    $seenAuthDigests = if ($authEnabled) { [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) } else { $null }
    $seenAuthDigestOrder = if ($authEnabled) { New-Object 'System.Collections.Generic.Queue[string]' } else { $null }
    $seenAuthDigestsMaxCount = 4096
    $assertAuthenticatedSenderMessage = {
        param(
            [Parameter(Mandatory)]
            $Message
        )

        if (-not $authEnabled) {
            if ($Message.Payload.PSObject.Properties.Name -contains 'AuthRequired' -and $Message.Payload.AuthRequired -eq $true) {
                throw "Sender requires authentication for session '$SessionId', but receiver is not configured with -AuthKey."
            }
            return
        }

        if ($Message.Payload.PSObject.Properties.Name -contains 'AuthRequired' -and $Message.Payload.AuthRequired -ne $true -and $Message.MessageType -eq 'HELLO') {
            throw "Authenticated mode requires HELLO payload to set AuthRequired=true."
        }

        $actualSenderNonce = ''
        if ($Message.Payload.PSObject.Properties.Name -contains 'AuthSenderNonce') {
            $actualSenderNonce = [string]$Message.Payload.AuthSenderNonce
        }
        if ([string]::IsNullOrWhiteSpace($actualSenderNonce)) {
            throw "Authenticated message '$($Message.MessageType)' is missing sender nonce context."
        }
        if ([string]::IsNullOrWhiteSpace($senderAuthNonce)) {
            Set-Variable -Name senderAuthNonce -Value $actualSenderNonce -Scope 1
        }
        elseif ($actualSenderNonce -ne $senderAuthNonce) {
            throw "Authenticated sender nonce rebinding attempt detected for session '$SessionId'."
        }

        if ($Message.MessageType -ne 'HELLO') {
            $actualReceiverNonce = ''
            if ($Message.Payload.PSObject.Properties.Name -contains 'AuthReceiverNonce') {
                $actualReceiverNonce = [string]$Message.Payload.AuthReceiverNonce
            }
            if ([string]::IsNullOrWhiteSpace($actualReceiverNonce) -or $actualReceiverNonce -ne $receiverAuthNonce) {
                throw "Authenticated message '$($Message.MessageType)' failed receiver nonce validation."
            }
        }
    }

    try {
        if ([string]::IsNullOrWhiteSpace($SessionId)) {
            $helloAny = $null
            $helloStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $helloTimeoutMilliseconds = $TimeoutSeconds * 1000
            $malformedHelloCount = 0
            while ($helloStopwatch.ElapsedMilliseconds -lt $helloTimeoutMilliseconds -and -not $helloAny) {
                try {
                    $remainingMilliseconds = [int][Math]::Max(250, $helloTimeoutMilliseconds - $helloStopwatch.ElapsedMilliseconds)
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
                    $malformedHelloCount = 0
                    if ($msg.Role -eq 'Sender' -and $msg.MessageType -eq 'HELLO') {
                        if ($authEnabled -and -not (Test-KlipAroundMessageAuthSignature -Message $msg -AuthKey $AuthKey)) {
                            Start-Sleep -Milliseconds 250
                            continue
                        }
                        & $assertAuthenticatedSenderMessage $msg
                        $helloAny = $msg
                        break
                    }
                }
                catch {
                    $malformedHelloCount++
                    if ($malformedHelloCount -eq 1 -or ($malformedHelloCount % 10) -eq 0) {
                        Write-Warning "Ignored $malformedHelloCount malformed clipboard payload(s) while waiting for initial HELLO."
                    }
                    Start-Sleep -Milliseconds 250
                }
            }

            if (-not $helloAny) {
                throw "Timed out waiting for initial HELLO from sender."
            }
            $SessionId = [string]$helloAny.SessionId
            $helloAnyMessageId = [string]$helloAny.MessageId
            if ($seenMessageIds.Add($helloAnyMessageId)) {
                $seenMessageIdOrder.Enqueue($helloAnyMessageId)
            }
            $lastAcceptedMessageId = $helloAnyMessageId
            $hello = $helloAny
        }
        else {
            $hello = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds $TimeoutSeconds -IgnoreMessageIds $sentIds -SeenMessageIds $seenMessageIds -SeenMessageIdOrder $seenMessageIdOrder -LastAcceptedMessageId ([ref]$lastAcceptedMessageId) -AuthKey $AuthKey -RequireAuthentication:$authEnabled -SeenAuthDigests $seenAuthDigests -SeenAuthDigestOrder $seenAuthDigestOrder -SeenAuthDigestsMaxCount $seenAuthDigestsMaxCount
        }
        & $assertAuthenticatedSenderMessage $hello

        $expectedFileCount = [int]$hello.Payload.FileCount
        if ($expectedFileCount -lt 0) {
            throw "Invalid HELLO file count '$($hello.Payload.FileCount)'."
        }
        $expectedWindowSize = 16
        if ($hello.Payload.PSObject.Properties.Name -contains 'WindowSize') {
            $expectedWindowSize = [int]$hello.Payload.WindowSize
            if ($expectedWindowSize -lt 1 -or $expectedWindowSize -gt 64) {
                throw "Invalid HELLO window size '$($hello.Payload.WindowSize)'."
            }
        }
        $expectedBlockSize = 131072
        if ($hello.Payload.PSObject.Properties.Name -contains 'BlockSize') {
            $expectedBlockSize = [int]$hello.Payload.BlockSize
            if ($expectedBlockSize -lt 4096 -or $expectedBlockSize -gt 1048576) {
                throw "Invalid HELLO block size '$($hello.Payload.BlockSize)'."
            }
        }
        $helloAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType HELLO_ACK -Payload @{
            Accepted = $true
            ReceiverHost = $env:COMPUTERNAME
        }
        & $publishAndTrack $helloAck $TimeoutSeconds

        $done = $false
        $dataWaitSeconds = [Math]::Min(3600, $TimeoutSeconds + 1)
        while (-not $done) {
            $next = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Sender -ExpectedMessageType @('HELLO', 'FILE_META', 'FILE_EOF', 'FIN') -TimeoutSeconds $TimeoutSeconds -IgnoreMessageIds $sentIds -SeenMessageIds $seenMessageIds -SeenMessageIdOrder $seenMessageIdOrder -LastAcceptedMessageId ([ref]$lastAcceptedMessageId) -AuthKey $AuthKey -RequireAuthentication:$authEnabled -SeenAuthDigests $seenAuthDigests -SeenAuthDigestOrder $seenAuthDigestOrder -SeenAuthDigestsMaxCount $seenAuthDigestsMaxCount
            & $assertAuthenticatedSenderMessage $next
            if ($next.MessageType -eq 'HELLO') {
                $helloAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType HELLO_ACK -Payload @{
                    Accepted = $true
                    ReceiverHost = $env:COMPUTERNAME
                }
                & $publishAndTrack $helloAck $TimeoutSeconds
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
                & $publishAndTrack $finAck $TimeoutSeconds

                Write-Verbose "FIN grace idle wait (polling)."
                $graceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $graceTimeoutMilliseconds = $finAckGraceSeconds * 1000
                while ($graceStopwatch.ElapsedMilliseconds -lt $graceTimeoutMilliseconds) {
                    try {
                        $followUp = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Sender -ExpectedMessageType @('FIN', 'HELLO') -TimeoutSeconds 2 -IgnoreMessageIds $sentIds -SeenMessageIds $seenMessageIds -SeenMessageIdOrder $seenMessageIdOrder -LastAcceptedMessageId ([ref]$lastAcceptedMessageId) -DisableClipboardListener -AuthKey $AuthKey -RequireAuthentication:$authEnabled -SeenAuthDigests $seenAuthDigests -SeenAuthDigestOrder $seenAuthDigestOrder -SeenAuthDigestsMaxCount $seenAuthDigestsMaxCount
                    }
                    catch {
                        $isWaitTimeout = $_.Exception.Message -like "Timed out waiting for message types*"
                        if ($isWaitTimeout) {
                            continue
                        }
                        throw
                    }
                    & $assertAuthenticatedSenderMessage $followUp

                    if ($followUp.MessageType -eq 'HELLO') {
                        $helloAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType HELLO_ACK -Payload @{
                            Accepted = $true
                            ReceiverHost = $env:COMPUTERNAME
                        }
                        & $publishAndTrack $helloAck $TimeoutSeconds
                        continue
                    }

                    $finAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType FIN_ACK -Payload @{
                        ReceivedFiles = $receivedFiles.Count
                    }
                    & $publishAndTrack $finAck $TimeoutSeconds
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
                    & $publishAndTrack $eofAck $TimeoutSeconds
                    continue
                }

                throw "Received unexpected FILE_EOF for file index $dupFileIndex before FILE_META."
            }

            $fileIndex = [int]$next.Payload.FileIndex
            if ($fileIndex -lt 0 -or $fileIndex -ge $expectedFileCount) {
                throw "Invalid FILE_META file index $fileIndex for expected file count $expectedFileCount."
            }
            $fileName = [string]$next.Payload.Name
            $fileLength = [int64]$next.Payload.Length
            if ($fileLength -lt 0) {
                throw "Invalid FILE_META length '$($next.Payload.Length)' for file index $fileIndex."
            }
            $fileSha256FromMeta = [string]$next.Payload.Sha256
            $blockSize = [int]$next.Payload.BlockSize
            if ($blockSize -lt 4096 -or $blockSize -gt 1048576) {
                throw "Invalid FILE_META block size $blockSize for file index $fileIndex."
            }
            if ($blockSize -ne $expectedBlockSize) {
                throw "FILE_META block size $blockSize does not match HELLO block size $expectedBlockSize."
            }
            $totalBlocks = [int]$next.Payload.TotalBlocks
            if ($totalBlocks -lt 1) {
                throw "Invalid FILE_META total block count '$($next.Payload.TotalBlocks)' for file index $fileIndex."
            }
            $computedTotalBlocks = [int][Math]::Max(1, [Math]::Ceiling($fileLength / [double]$blockSize))
            if ($computedTotalBlocks -ne $totalBlocks) {
                throw "FILE_META total block count $totalBlocks does not match expected $computedTotalBlocks for file index $fileIndex."
            }
            $blockChecksumAlgorithm = if ($next.Payload.PSObject.Properties.Name -contains 'BlockChecksumAlgorithm' -and -not [string]::IsNullOrWhiteSpace([string]$next.Payload.BlockChecksumAlgorithm)) {
                [string]$next.Payload.BlockChecksumAlgorithm
            }
            else {
                'CRC32C'
            }
            if ($blockChecksumAlgorithm -notin @('CRC32C', 'SHA256')) {
                throw "Invalid FILE_META block checksum algorithm '$blockChecksumAlgorithm' for file index $fileIndex."
            }
            $processedFiles = [Math]::Max($processedFiles, $fileIndex + 1)

            if ($completedFileIndexes.Contains($fileIndex)) {
                $metaAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType FILE_META_ACK -Payload @{
                    FileIndex = $fileIndex
                    Accepted  = $true
                }
                & $publishAndTrack $metaAck $TimeoutSeconds
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

            $candidateTempPath = $targetPath + '.' + [guid]::NewGuid().ToString('N') + '.kliparound.part'
            $stream = [System.IO.File]::Open($candidateTempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $tempPath = $candidateTempPath
            $streamHasher = $null
            $streamedFileHash = $null
            try {
                $streamHasher = [System.Security.Cryptography.SHA256]::Create()
                $metaAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType FILE_META_ACK -Payload @{
                    FileIndex = $fileIndex
                    Accepted  = $true
                }
                & $publishAndTrack $metaAck $TimeoutSeconds

                $expectedSeq = 0
                $outOfOrderBlocks = [System.Collections.Generic.Dictionary[int,byte[]]]::new($expectedWindowSize)
                $lastFileProgressPercent = -1
                while ($expectedSeq -lt $totalBlocks) {
                    $burst = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Sender -ExpectedMessageType @('DATA_BURST', 'HELLO', 'FILE_META') -TimeoutSeconds $dataWaitSeconds -IgnoreMessageIds $sentIds -SeenMessageIds $seenMessageIds -SeenMessageIdOrder $seenMessageIdOrder -LastAcceptedMessageId ([ref]$lastAcceptedMessageId) -AuthKey $AuthKey -RequireAuthentication:$authEnabled -SeenAuthDigests $seenAuthDigests -SeenAuthDigestOrder $seenAuthDigestOrder -SeenAuthDigestsMaxCount $seenAuthDigestsMaxCount
                    & $assertAuthenticatedSenderMessage $burst
                    if ($burst.MessageType -eq 'HELLO') {
                        $helloAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType HELLO_ACK -Payload @{
                            Accepted = $true
                            ReceiverHost = $env:COMPUTERNAME
                        }
                        & $publishAndTrack $helloAck $TimeoutSeconds
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
                        & $publishAndTrack $metaAck $TimeoutSeconds
                        continue
                    }
                    if ([int]$burst.Payload.FileIndex -ne $fileIndex) {
                        throw "Received DATA_BURST for file index $($burst.Payload.FileIndex), expected $fileIndex."
                    }

                    $blocks = @($burst.Payload.Blocks)
                    if ($blocks.Count -lt 1 -or $blocks.Count -gt $expectedWindowSize) {
                        throw "Received DATA_BURST with invalid block count $($blocks.Count). Expected between 1 and $expectedWindowSize."
                    }
                    $isMonotonic = $true
                    $previousSeq = [int]::MinValue
                    foreach ($candidateBlock in $blocks) {
                        $candidateSeq = [int]$candidateBlock.Seq
                        if ($candidateSeq -lt $previousSeq) {
                            $isMonotonic = $false
                            break
                        }
                        $previousSeq = $candidateSeq
                    }
                    if (-not $isMonotonic) {
                        $sortedBlockSeqs = New-Object 'System.Int32[]' $blocks.Count
                        $sortedBlocks = New-Object 'System.Object[]' $blocks.Count
                        for ($blockIndex = 0; $blockIndex -lt $blocks.Count; $blockIndex++) {
                            $sortedBlockSeqs[$blockIndex] = [int]$blocks[$blockIndex].Seq
                            $sortedBlocks[$blockIndex] = $blocks[$blockIndex]
                        }
                        [Array]::Sort($sortedBlockSeqs, $sortedBlocks)
                        $blocks = @($sortedBlocks)
                    }

                    $maxSeqSeen = -1
                    $explicitMissing = [System.Collections.Generic.HashSet[int]]::new($expectedWindowSize)
                    foreach ($block in $blocks) {
                        $seq = [int]$block.Seq
                        if ($seq -lt 0 -or $seq -ge $totalBlocks) {
                            [void]$explicitMissing.Add($seq)
                            continue
                        }
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
                            $bytes = Expand-KlipAroundDataBlock -Block $block -ExpectedChecksumAlgorithm $blockChecksumAlgorithm -MaximumLength $blockSize
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

                    $missingSeqs = [System.Collections.Generic.List[int]]::new($expectedWindowSize)
                    if ($maxSeqSeen -ge $expectedSeq) {
                        for ($seq = $expectedSeq; $seq -le $maxSeqSeen; $seq++) {
                            if (-not $outOfOrderBlocks.ContainsKey($seq)) {
                                [void]$missingSeqs.Add($seq)
                            }
                        }
                    }
                    foreach ($missingSeq in $explicitMissing) {
                        if ($missingSeq -ge $expectedSeq -and -not $missingSeqs.Contains($missingSeq)) {
                            if ($missingSeq -ge $totalBlocks) {
                                continue
                            }
                            [void]$missingSeqs.Add($missingSeq)
                        }
                    }

                    $ack = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType ACK_REPORT -Payload @{
                        FileIndex   = $fileIndex
                        AckNextSeq  = $expectedSeq
                        TotalBlocks = $totalBlocks
                        MissingSeqs = @($missingSeqs.ToArray() | Sort-Object -Unique)
                    }
                    & $publishAndTrack $ack $TimeoutSeconds

                    $percent = [int](($expectedSeq / [double][Math]::Max(1,$totalBlocks)) * 100)
                    if ($percent -ne $lastFileProgressPercent) {
                        Write-Progress -Id $fileProgressId -ParentId $overallProgressId -Activity "Receiving $fileName" -Status "Block $expectedSeq of $totalBlocks written ($blockChecksumAlgorithm)" -PercentComplete $percent
                        $lastFileProgressPercent = $percent
                    }
                }

                if ($null -eq $streamHasher.Hash) {
                    throw "Streaming SHA-256 hash was not finalized for '$fileName'."
                }
                $streamedFileHash = -join ($streamHasher.Hash | ForEach-Object { $_.ToString('X2') })
            }
            finally {
                Write-Progress -Id $fileProgressId -ParentId $overallProgressId -Activity "Receiving $fileName" -Completed
                try {
                    if ($streamHasher) { $streamHasher.Dispose() }
                }
                finally {
                    $stream.Dispose()
                }
            }

            do {
                $eof = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Sender -ExpectedMessageType @('FILE_EOF', 'DATA_BURST') -TimeoutSeconds $dataWaitSeconds -IgnoreMessageIds $sentIds -SeenMessageIds $seenMessageIds -SeenMessageIdOrder $seenMessageIdOrder -LastAcceptedMessageId ([ref]$lastAcceptedMessageId) -AuthKey $AuthKey -RequireAuthentication:$authEnabled -SeenAuthDigests $seenAuthDigests -SeenAuthDigestOrder $seenAuthDigestOrder -SeenAuthDigestsMaxCount $seenAuthDigestsMaxCount
                & $assertAuthenticatedSenderMessage $eof
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
                    & $publishAndTrack $ack $TimeoutSeconds
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
            $tempPath = $null
            $fileInfo = Get-Item -LiteralPath $targetPath -ErrorAction Stop
            [void]$receivedFiles.Add($fileInfo)

            $eofAck = New-KlipAroundMessage -SessionId $SessionId -Role Receiver -MessageType FILE_EOF_ACK -Payload @{
                FileIndex = $fileIndex
                Accepted  = $true
            }
            & $publishAndTrack $eofAck $TimeoutSeconds
            [void]$completedFileIndexes.Add($fileIndex)
        }

        if ($PassThru) {
            return $receivedFiles.ToArray()
        }
    }
    finally {
        if ($null -ne $tempPath -and [IO.File]::Exists($tempPath)) {
            try {
                [IO.File]::Delete($tempPath)
            }
            catch {
                Write-Warning "Could not remove partial file '$tempPath': $($_.Exception.Message)"
            }
        }
        Write-Progress -Id $fileProgressId -ParentId $overallProgressId -Activity 'Receiving file' -Completed
        Write-Progress -Id $overallProgressId -Activity 'KlipAround receive' -Completed
    }
}
