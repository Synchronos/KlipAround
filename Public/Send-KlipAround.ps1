Set-StrictMode -Version Latest

<#
.SYNOPSIS
Sends files using the KlipAround reliable windowed clipboard protocol.

.DESCRIPTION
Send-KlipAround is the sender side of a two-party transfer. It exchanges control/data
messages over the clipboard with a concurrently running Receive-KlipAround process on
the other machine/session.

.PARAMETER Path
One or more file paths to transfer. Existing literal paths take precedence over wildcard expansion.

.PARAMETER BlockSize
Bytes per data block in a DATA_BURST payload. Default is 131072 (128 KiB).

.PARAMETER WindowSize
Number of data blocks sent in each burst before awaiting ACK_REPORT. Default is 16.

.PARAMETER TimeoutSeconds
Per-message timeout while waiting for receiver responses.

.PARAMETER MaxRetries
Maximum retries for a timed-out or unadvanced ACK before failing transfer.

.PARAMETER BlockChecksumAlgorithm
Checksum algorithm for per-block integrity. Defaults to SHA256.

.PARAMETER PrecomputeHash
Computes each file SHA-256 before data transfer (legacy behavior). By default, SHA-256 is
computed incrementally while blocks are sent to avoid an extra full file read.

.PARAMETER SessionId
Optional session identifier. Defaults to a new GUID.

.PARAMETER AuthKey
Optional shared authentication key. When provided, sender messages include an HMAC signature
and authenticated nonce context.

.PARAMETER PassThru
Returns transfer summary details.
#>
function Send-KlipAround {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path,

        [Parameter()]
        [ValidateRange(4096, 1048576)]
        [int]$BlockSize = 131072,

        [Parameter()]
        [ValidateRange(1, 64)]
        [int]$WindowSize = 16,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 90,

        [Parameter()]
        [ValidateRange(1, 20)]
        [int]$MaxRetries = 5,

        [Parameter()]
        [ValidateSet('CRC32C', 'SHA256')]
        [string]$BlockChecksumAlgorithm = 'SHA256',

        [Parameter()]
        [switch]$PrecomputeHash,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SessionId = ([guid]::NewGuid().ToString()),

        [Parameter()]
        [string]$AuthKey,

        [Parameter()]
        [switch]$PassThru
    )

    begin {
        $files = New-Object System.Collections.Generic.List[string]
    }

    process {
        foreach ($candidate in $Path) {
            $resolved = @(if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                Resolve-Path -LiteralPath $candidate -ErrorAction Stop
            }
            else {
                Resolve-Path -Path $candidate -ErrorAction Stop
            })
            if ($resolved.Count -eq 0) {
                throw "Path '$candidate' did not resolve to a file."
            }
            foreach ($entry in $resolved) {
                if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) {
                    throw "Path '$($entry.Path)' is not a file."
                }
                if (-not $files.Contains($entry.Path)) {
                    [void]$files.Add($entry.Path)
                }
            }
        }
    }

    end {
        if ($files.Count -eq 0) {
            throw 'No files resolved for transfer.'
        }

        $sentMessageIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $sentMessageIdOrder = New-Object 'System.Collections.Generic.Queue[string]'
        $sentMessageIdsMaxCount = 4096
        $seenMessageIds = New-Object 'System.Collections.Generic.HashSet[string]'
        $seenMessageIdOrder = New-Object 'System.Collections.Generic.Queue[string]'
        $lastAcceptedMessageId = $null
        $overallProgressId = 4100
        $fileProgressId = 4101
        $results = New-Object System.Collections.Generic.List[object]
        $authEnabled = -not [string]::IsNullOrWhiteSpace($AuthKey)
        $senderAuthNonce = if ($authEnabled) { New-KlipAroundAuthNonce } else { $null }
        $receiverAuthNonce = $null
        $seenAuthDigests = if ($authEnabled) { [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) } else { $null }
        $seenAuthDigestOrder = if ($authEnabled) { New-Object 'System.Collections.Generic.Queue[string]' } else { $null }
        $seenAuthDigestsMaxCount = 4096
        $readBlockBySequence = {
            param(
                [Parameter(Mandatory)]
                [System.IO.FileStream]$Stream,

                [Parameter(Mandatory)]
                [int]$Sequence,

                [Parameter(Mandatory)]
                [int]$BlockSize,

                [Parameter(Mandatory)]
                [int64]$FileLength
            )

            $offset = [int64]$Sequence * $BlockSize
            if ($offset -gt $FileLength) {
                throw "Sequence $Sequence resolves past EOF."
            }

            $bytesToRead = [int][Math]::Min([int64]$BlockSize, [Math]::Max([int64]0, $FileLength - $offset))
            if ($bytesToRead -eq 0) {
                return ,([byte[]]@())
            }

            $buffer = New-Object byte[] $bytesToRead
            $Stream.Position = $offset
            $totalRead = 0
            while ($totalRead -lt $bytesToRead) {
                $readCount = $Stream.Read($buffer, $totalRead, $bytesToRead - $totalRead)
                if ($readCount -le 0) {
                    break
                }
                $totalRead += $readCount
            }

            if ($totalRead -ne $bytesToRead) {
                throw "Could not read block sequence $Sequence from source file."
            }

            return ,$buffer
        }
        $trackSentMessageId = {
            param([Parameter(Mandatory)][string]$MessageId)
            if ($sentMessageIds.Add($MessageId)) {
                $sentMessageIdOrder.Enqueue($MessageId)
                while ($sentMessageIdOrder.Count -gt $sentMessageIdsMaxCount) {
                    $expiredId = $sentMessageIdOrder.Dequeue()
                    [void]$sentMessageIds.Remove($expiredId)
                }
            }
        }
        $publishAndTrackMessage = {
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
                $Message.Payload.AuthSenderNonce = $senderAuthNonce
                if (-not [string]::IsNullOrWhiteSpace($receiverAuthNonce)) {
                    $Message.Payload.AuthReceiverNonce = $receiverAuthNonce
                }
            }

            $publishedMessage = Publish-KlipAroundMessage -Message $Message -TimeoutSeconds $PublishTimeoutSeconds -AuthKey $AuthKey
            & $trackSentMessageId $publishedMessage.MessageId
        }
        $assertAuthenticatedReceiverMessage = {
            param(
                [Parameter(Mandatory)]
                $Message
            )

            if (-not $authEnabled) {
                return
            }

            $actualSenderNonce = [string]$Message.Payload.AuthSenderNonce
            if ([string]::IsNullOrWhiteSpace($actualSenderNonce) -or $actualSenderNonce -ne $senderAuthNonce) {
                throw "Authenticated message '$($Message.MessageType)' failed sender nonce validation."
            }

            $actualReceiverNonce = [string]$Message.Payload.AuthReceiverNonce
            if ([string]::IsNullOrWhiteSpace($actualReceiverNonce)) {
                throw "Authenticated message '$($Message.MessageType)' is missing receiver nonce context."
            }
            if ([string]::IsNullOrWhiteSpace($receiverAuthNonce)) {
                Set-Variable -Name receiverAuthNonce -Value $actualReceiverNonce -Scope 1
            }
            elseif ($actualReceiverNonce -ne $receiverAuthNonce) {
                throw "Authenticated message '$($Message.MessageType)' failed receiver nonce validation."
            }
        }
        try {
            $helloPayload = @{
                FileCount   = $files.Count
                WindowSize  = $WindowSize
                BlockSize   = $BlockSize
                SenderHost  = $env:COMPUTERNAME
                SenderUser  = [Environment]::UserName
                StartedUtc  = (Get-Date).ToUniversalTime().ToString('o')
            }
            if ($authEnabled) {
                $helloPayload.AuthRequired = $true
            }
            $helloAck = $null
            $helloWait = [System.Diagnostics.Stopwatch]::StartNew()
            while ($helloWait.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
                $hello = New-KlipAroundMessage -SessionId $SessionId -Role Sender -MessageType HELLO -Payload $helloPayload
                & $publishAndTrackMessage $hello $TimeoutSeconds

                $remainingSeconds = [int][Math]::Ceiling($TimeoutSeconds - $helloWait.Elapsed.TotalSeconds)
                if ($remainingSeconds -lt 1) {
                    break
                }
                $attemptTimeoutSeconds = [Math]::Min(10, $remainingSeconds)

                try {
                    $helloAck = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Receiver -ExpectedMessageType HELLO_ACK -TimeoutSeconds $attemptTimeoutSeconds -IgnoreMessageIds $sentMessageIds -SeenMessageIds $seenMessageIds -SeenMessageIdOrder $seenMessageIdOrder -LastAcceptedMessageId ([ref]$lastAcceptedMessageId) -AuthKey $AuthKey -RequireAuthentication:$authEnabled -SeenAuthDigests $seenAuthDigests -SeenAuthDigestOrder $seenAuthDigestOrder -SeenAuthDigestsMaxCount $seenAuthDigestsMaxCount
                    break
                }
                catch {
                    $isWaitTimeout = $_.Exception.Message -like "Timed out waiting for message types*"
                    if (-not $isWaitTimeout) {
                        throw
                    }
                    Write-Verbose "No HELLO_ACK yet. Re-sending HELLO."
                }
            }
            $helloWait.Stop()

            if ($null -eq $helloAck) {
                throw "Timed out waiting for HELLO_ACK in session '$SessionId'."
            }
            if ($helloAck.Payload.Accepted -ne $true) {
                throw "Receiver rejected HELLO for session '$SessionId'."
            }
            & $assertAuthenticatedReceiverMessage $helloAck

            for ($fileIndex = 0; $fileIndex -lt $files.Count; $fileIndex++) {
                $filePath = $files[$fileIndex]
                $fileInfo = Get-Item -LiteralPath $filePath -ErrorAction Stop
                $fileHash = $null
                if ($PrecomputeHash) {
                    $fileHash = Get-KlipAroundSha256HexForFile -Path $filePath
                }
                $totalBlocks = [int][Math]::Ceiling($fileInfo.Length / [double]$BlockSize)
                if ($totalBlocks -eq 0) {
                    $totalBlocks = 1
                }

                Write-Progress -Id $overallProgressId -Activity 'KlipAround send' -Status "Preparing file $($fileIndex + 1) of $($files.Count): $($fileInfo.Name)" -PercentComplete ([int](($fileIndex / [double]$files.Count) * 100))

                $metaPayload = @{
                    FileIndex              = $fileIndex
                    Name                   = $fileInfo.Name
                    Length                 = [int64]$fileInfo.Length
                    Sha256                 = $fileHash
                    BlockSize              = $BlockSize
                    TotalBlocks            = $totalBlocks
                    BlockChecksumAlgorithm = $BlockChecksumAlgorithm
                }
                $metaAck = $null
                $metaWait = [System.Diagnostics.Stopwatch]::StartNew()
                while ($metaWait.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
                    $meta = New-KlipAroundMessage -SessionId $SessionId -Role Sender -MessageType FILE_META -Payload $metaPayload
                    & $publishAndTrackMessage $meta $TimeoutSeconds

                    $remainingSeconds = [int][Math]::Ceiling($TimeoutSeconds - $metaWait.Elapsed.TotalSeconds)
                    if ($remainingSeconds -lt 1) {
                        break
                    }
                    $attemptTimeoutSeconds = [Math]::Min(10, $remainingSeconds)

                    try {
                        $metaAck = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Receiver -ExpectedMessageType FILE_META_ACK -TimeoutSeconds $attemptTimeoutSeconds -IgnoreMessageIds $sentMessageIds -SeenMessageIds $seenMessageIds -SeenMessageIdOrder $seenMessageIdOrder -LastAcceptedMessageId ([ref]$lastAcceptedMessageId) -AuthKey $AuthKey -RequireAuthentication:$authEnabled -SeenAuthDigests $seenAuthDigests -SeenAuthDigestOrder $seenAuthDigestOrder -SeenAuthDigestsMaxCount $seenAuthDigestsMaxCount
                        break
                    }
                    catch {
                        $isWaitTimeout = $_.Exception.Message -like "Timed out waiting for message types*"
                        if (-not $isWaitTimeout) {
                            throw
                        }
                        Write-Verbose "No FILE_META_ACK yet for file index $fileIndex. Re-sending FILE_META."
                    }
                }
                $metaWait.Stop()

                if ($null -eq $metaAck) {
                    throw "Timed out waiting for FILE_META_ACK for file index $fileIndex in session '$SessionId'."
                }
                & $assertAuthenticatedReceiverMessage $metaAck
                if ([int]$metaAck.Payload.FileIndex -ne $fileIndex) {
                    throw "Unexpected FILE_META_ACK for file index $($metaAck.Payload.FileIndex), expected $fileIndex."
                }

                $stream = [System.IO.File]::OpenRead($filePath)
                $streamHasher = if (-not $PrecomputeHash) { [System.Security.Cryptography.SHA256]::Create() } else { $null }
                $streamedFileHash = $null
                try {
                    $nextSeq = 0
                    $pendingSrejSeqs = [System.Collections.Generic.HashSet[int]]::new($WindowSize)
                    $blockCache = [System.Collections.Generic.Dictionary[int,hashtable]]::new($WindowSize * 2)
                    $hashedUntilSeq = 0
                    $lastAckSignature = $null
                    $retries = 0
                    $lastFileProgressPercent = -1
                    while ($nextSeq -lt $totalBlocks) {
                        $sequencesToSend = [System.Collections.Generic.List[int]]::new($WindowSize)
                        if ($pendingSrejSeqs.Count -gt 0) {
                            $sortedPending = New-Object 'System.Int32[]' $pendingSrejSeqs.Count
                            $pendingSrejSeqs.CopyTo($sortedPending)
                            [Array]::Sort($sortedPending)
                            foreach ($pendingSeq in $sortedPending) {
                                if ($sequencesToSend.Count -ge $WindowSize) {
                                    break
                                }
                                [void]$sequencesToSend.Add([int]$pendingSeq)
                            }
                        }
                        else {
                            for ($i = 0; $i -lt $WindowSize -and $nextSeq + $i -lt $totalBlocks; $i++) {
                                [void]$sequencesToSend.Add([int]($nextSeq + $i))
                            }
                        }

                        $blocks = [System.Collections.Generic.List[hashtable]]::new($sequencesToSend.Count)
                        foreach ($sequence in $sequencesToSend) {
                            if ($blockCache.ContainsKey($sequence)) {
                                [void]$blocks.Add($blockCache[$sequence])
                                continue
                            }

                            $payload = & $readBlockBySequence -Stream $stream -Sequence $sequence -BlockSize $BlockSize -FileLength $fileInfo.Length
                            if (-not $PrecomputeHash) {
                                if ($sequence -ne $hashedUntilSeq) {
                                    throw "Unexpected hash sequence state at block $sequence."
                                }
                                if (($sequence + 1) -eq $totalBlocks) {
                                    [void]$streamHasher.TransformFinalBlock($payload, 0, $payload.Length)
                                }
                                else {
                                    [void]$streamHasher.TransformBlock($payload, 0, $payload.Length, $null, 0)
                                }
                                $hashedUntilSeq++
                            }

                            $block = New-KlipAroundDataBlock -Sequence $sequence -Bytes $payload -ChecksumAlgorithm $BlockChecksumAlgorithm
                            $blockCache[$sequence] = $block
                            [void]$blocks.Add($block)
                        }

                        if ($blocks.Count -eq 0) {
                            throw "Unexpected empty block burst at sequence $nextSeq."
                        }

                        $burstPayload = @{
                            FileIndex = $fileIndex
                            StartSeq  = [int]$sequencesToSend[0]
                            Blocks    = $blocks
                        }
                        $ack = $null
                        $ackWaitSeconds = [Math]::Max(1, [int][Math]::Floor($TimeoutSeconds / 2.0))
                        for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
                            $burst = New-KlipAroundMessage -SessionId $SessionId -Role Sender -MessageType DATA_BURST -Payload $burstPayload
                            & $publishAndTrackMessage $burst $TimeoutSeconds
                            try {
                                $ack = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Receiver -ExpectedMessageType ACK_REPORT -TimeoutSeconds $ackWaitSeconds -IgnoreMessageIds $sentMessageIds -SeenMessageIds $seenMessageIds -SeenMessageIdOrder $seenMessageIdOrder -LastAcceptedMessageId ([ref]$lastAcceptedMessageId) -AuthKey $AuthKey -RequireAuthentication:$authEnabled -SeenAuthDigests $seenAuthDigests -SeenAuthDigestOrder $seenAuthDigestOrder -SeenAuthDigestsMaxCount $seenAuthDigestsMaxCount
                                break
                            }
                            catch {
                                if ($_.Exception.Message -notlike 'Timed out waiting for message types*' -or $attempt -eq $MaxRetries) {
                                    throw
                                }
                                Write-Verbose "No ACK_REPORT for file index $fileIndex. Re-sending DATA_BURST."
                            }
                        }
                        & $assertAuthenticatedReceiverMessage $ack
                        if ([int]$ack.Payload.FileIndex -ne $fileIndex) {
                            throw "Unexpected ACK_REPORT for file index $($ack.Payload.FileIndex), expected $fileIndex."
                        }

                        $ackTotalBlocks = [int]$ack.Payload.TotalBlocks
                        if ($ackTotalBlocks -ne $totalBlocks) {
                            throw "ACK_REPORT total block count $ackTotalBlocks does not match expected $totalBlocks for file index $fileIndex."
                        }

                        $ackNextSeq = [int]$ack.Payload.AckNextSeq
                        if ($ackNextSeq -lt 0 -or $ackNextSeq -gt $totalBlocks) {
                            throw "ACK_REPORT next sequence $ackNextSeq is out of bounds for file index $fileIndex."
                        }
                        if ($ackNextSeq -lt $nextSeq) {
                            throw "ACK_REPORT next sequence $ackNextSeq regressed from $nextSeq for file index $fileIndex."
                        }

                        $srejMissingSeqs = @()
                        if ($ack.Payload.PSObject.Properties.Name -contains 'MissingSeqs' -and $null -ne $ack.Payload.MissingSeqs) {
                            $parsedMissingSet = [System.Collections.Generic.HashSet[int]]::new()
                            foreach ($rawMissingSeq in $ack.Payload.MissingSeqs) {
                                [void]$parsedMissingSet.Add([int]$rawMissingSeq)
                            }
                            $parsedMissingSeqs = New-Object 'System.Int32[]' $parsedMissingSet.Count
                            $parsedMissingSet.CopyTo($parsedMissingSeqs)
                            [Array]::Sort($parsedMissingSeqs)

                            $hasInvalidMissingSeq = $false
                            foreach ($missingSeq in $parsedMissingSeqs) {
                                if ($missingSeq -lt $ackNextSeq -or $missingSeq -ge $totalBlocks) {
                                    $hasInvalidMissingSeq = $true
                                    break
                                }
                            }
                            if ($hasInvalidMissingSeq) {
                                throw "ACK_REPORT contains out-of-range missing sequences for file index $fileIndex."
                            }
                            $srejMissingSeqs = $parsedMissingSeqs
                        }

                        if ($ackNextSeq -gt $nextSeq) {
                            $nextSeq = $ackNextSeq
                        }
                        foreach ($pendingSeq in @($pendingSrejSeqs)) {
                            if ($pendingSeq -lt $nextSeq) {
                                [void]$pendingSrejSeqs.Remove($pendingSeq)
                            }
                        }
                        foreach ($cachedSeq in @($blockCache.Keys)) {
                            if ($cachedSeq -lt $nextSeq) {
                                [void]$blockCache.Remove($cachedSeq)
                            }
                        }
                        foreach ($missingSeq in $srejMissingSeqs) {
                            if ($missingSeq -ge $nextSeq) {
                                [void]$pendingSrejSeqs.Add($missingSeq)
                            }
                        }

                        $signature = "$nextSeq|$($srejMissingSeqs -join ',')"
                        if ($signature -eq $lastAckSignature) {
                            $retries++
                            if ($retries -gt $MaxRetries) {
                                throw "ACK did not advance beyond sequence $nextSeq after $MaxRetries retries."
                            }
                        }
                        else {
                            $retries = 0
                            $lastAckSignature = $signature
                        }

                        $percent = [int](($nextSeq / [double]$totalBlocks) * 100)
                        if ($percent -ne $lastFileProgressPercent) {
                            Write-Progress -Id $fileProgressId -ParentId $overallProgressId -Activity "Sending $($fileInfo.Name)" -Status "Block $nextSeq of $totalBlocks acknowledged ($BlockChecksumAlgorithm)" -PercentComplete $percent
                            $lastFileProgressPercent = $percent
                        }
                    }

                    if (-not $PrecomputeHash) {
                        if ($null -eq $streamHasher.Hash) {
                            throw "Streaming SHA-256 hash was not finalized for '$($fileInfo.Name)'."
                        }
                        $streamedFileHash = -join ($streamHasher.Hash | ForEach-Object { $_.ToString('X2') })
                    }
                }
                finally {
                    Write-Progress -Id $fileProgressId -ParentId $overallProgressId -Activity "Sending $($fileInfo.Name)" -Completed
                    if ($streamHasher) {
                        $streamHasher.Dispose()
                    }
                    $stream.Dispose()
                }

                if (-not $PrecomputeHash) {
                    $fileHash = $streamedFileHash
                }

                $eofPayload = @{
                    FileIndex = $fileIndex
                    Length    = [int64]$fileInfo.Length
                    Sha256    = $fileHash
                }

                $eofAck = $null
                $eofWait = [System.Diagnostics.Stopwatch]::StartNew()
                while ($eofWait.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
                    $eof = New-KlipAroundMessage -SessionId $SessionId -Role Sender -MessageType FILE_EOF -Payload $eofPayload
                    & $publishAndTrackMessage $eof $TimeoutSeconds

                    $remainingSeconds = [int][Math]::Ceiling($TimeoutSeconds - $eofWait.Elapsed.TotalSeconds)
                    if ($remainingSeconds -lt 1) {
                        break
                    }
                    $attemptTimeoutSeconds = [Math]::Min(10, $remainingSeconds)

                    try {
                        $eofAck = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Receiver -ExpectedMessageType FILE_EOF_ACK -TimeoutSeconds $attemptTimeoutSeconds -IgnoreMessageIds $sentMessageIds -SeenMessageIds $seenMessageIds -SeenMessageIdOrder $seenMessageIdOrder -LastAcceptedMessageId ([ref]$lastAcceptedMessageId) -AuthKey $AuthKey -RequireAuthentication:$authEnabled -SeenAuthDigests $seenAuthDigests -SeenAuthDigestOrder $seenAuthDigestOrder -SeenAuthDigestsMaxCount $seenAuthDigestsMaxCount
                        break
                    }
                    catch {
                        $isWaitTimeout = $_.Exception.Message -like "Timed out waiting for message types*"
                        if (-not $isWaitTimeout) {
                            throw
                        }
                        Write-Verbose "No FILE_EOF_ACK yet for file index $fileIndex. Re-sending FILE_EOF."
                    }
                }
                $eofWait.Stop()

                if ($null -eq $eofAck) {
                    throw "Timed out waiting for FILE_EOF_ACK for file index $fileIndex in session '$SessionId'."
                }
                & $assertAuthenticatedReceiverMessage $eofAck
                if ([int]$eofAck.Payload.FileIndex -ne $fileIndex) {
                    throw "Unexpected FILE_EOF_ACK for file index $($eofAck.Payload.FileIndex), expected $fileIndex."
                }

                [void]$results.Add([pscustomobject]@{
                        FileIndex = $fileIndex
                        Path      = $filePath
                        Name      = $fileInfo.Name
                        Length    = [int64]$fileInfo.Length
                        Sha256    = $fileHash
                        Blocks    = $totalBlocks
                    })
            }

            $finRetrySeconds = [Math]::Min(2, $TimeoutSeconds)
            $finPayload = @{
                FileCount       = $files.Count
                AckGraceSeconds = [Math]::Min($TimeoutSeconds, ($MaxRetries + 1) * $finRetrySeconds) + 2
            }
            $finAck = $null
            $finWait = [System.Diagnostics.Stopwatch]::StartNew()
            $finRetries = 0
            while ($finWait.Elapsed.TotalSeconds -lt $TimeoutSeconds -and $finRetries -le $MaxRetries) {
                $fin = New-KlipAroundMessage -SessionId $SessionId -Role Sender -MessageType FIN -Payload $finPayload
                & $publishAndTrackMessage $fin $TimeoutSeconds

                $remainingSeconds = [int][Math]::Ceiling($TimeoutSeconds - $finWait.Elapsed.TotalSeconds)
                if ($remainingSeconds -lt 1) {
                    break
                }
                $attemptTimeoutSeconds = [Math]::Min($finRetrySeconds, $remainingSeconds)

                try {
                    $finAck = Wait-KlipAroundMessage -SessionId $SessionId -ExpectedRole Receiver -ExpectedMessageType FIN_ACK -TimeoutSeconds $attemptTimeoutSeconds -IgnoreMessageIds $sentMessageIds -SeenMessageIds $seenMessageIds -SeenMessageIdOrder $seenMessageIdOrder -LastAcceptedMessageId ([ref]$lastAcceptedMessageId) -AuthKey $AuthKey -RequireAuthentication:$authEnabled -SeenAuthDigests $seenAuthDigests -SeenAuthDigestOrder $seenAuthDigestOrder -SeenAuthDigestsMaxCount $seenAuthDigestsMaxCount
                    break
                }
                catch {
                    $isWaitTimeout = $_.Exception.Message -like "Timed out waiting for message types*"
                    if (-not $isWaitTimeout) {
                        throw
                    }
                    $finRetries++
                    Write-Verbose "No FIN_ACK yet. Re-sending FIN."
                }
            }
            $finWait.Stop()

            if ($null -eq $finAck) {
                throw "Timed out waiting for FIN_ACK in session '$SessionId'."
            }
            & $assertAuthenticatedReceiverMessage $finAck

            if ($PassThru) {
                return [pscustomobject]@{
                    SessionId  = $SessionId
                    FileCount  = $results.Count
                    BlockSize  = $BlockSize
                    WindowSize = $WindowSize
                    BlockChecksumAlgorithm = $BlockChecksumAlgorithm
                    Files      = $results.ToArray()
                }
            }
        }
        finally {
            Write-Progress -Id $fileProgressId -ParentId $overallProgressId -Activity 'Sending file' -Completed
            Write-Progress -Id $overallProgressId -Activity 'KlipAround send' -Completed
        }
    }
}
