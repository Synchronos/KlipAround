Set-StrictMode -Version Latest

$script:KlipAroundProtocol = 'KlipAround/2'
$script:KlipAroundMarkers = @{
    Begin = '-----BEGIN KLIPAROUND/2-----'
    End   = '-----END KLIPAROUND/2-----'
}
$script:KlipAroundEnvelopeMaxUtf8Bytes = 100MB
$script:KlipAroundMaxBlockBytes = 1MB
$script:KlipAroundUuid7StateLock = [object]::new()
$script:KlipAroundUuid7Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$script:KlipAroundUuid7LastTimestampMs = -1L
$script:KlipAroundUuid7RandA = 0
$script:KlipAroundUuid7RandB = 0L
$script:KlipAroundUuid7MaxRandA = 0x0FFF
$script:KlipAroundUuid7MaxRandB = 0x3FFFFFFFFFFFFFFF
$script:KlipAroundPollJitterLock = [object]::new()
$script:KlipAroundPollJitterRng = [System.Random]::new()

function Get-KlipAroundPollJitterMilliseconds {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns an in-memory jitter value for wait-loop backoff.') ]
    param()

    [System.Threading.Monitor]::Enter($script:KlipAroundPollJitterLock)
    try {
        return $script:KlipAroundPollJitterRng.Next(-10, 11)
    }
    finally {
        [System.Threading.Monitor]::Exit($script:KlipAroundPollJitterLock)
    }
}

function New-KlipAroundUuidV7 {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Generates an in-memory identifier.') ]
    param()

    $timestampMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $randA = 0
    $randB = 0L
    $randomBytes = $null

    [System.Threading.Monitor]::Enter($script:KlipAroundUuid7StateLock)
    try {
        $lastTimestampMs = [int64]$script:KlipAroundUuid7LastTimestampMs
        if ($timestampMs -gt $lastTimestampMs) {
            $randomBytes = New-Object byte[] 10
            $script:KlipAroundUuid7Rng.GetBytes($randomBytes)
            $randA = (([int]$randomBytes[0] -shl 8) -bor [int]$randomBytes[1]) -band $script:KlipAroundUuid7MaxRandA
            $randB = (([int64]($randomBytes[2] -band 0x3F)) -shl 56) -bor
                     (([int64]$randomBytes[3]) -shl 48) -bor
                     (([int64]$randomBytes[4]) -shl 40) -bor
                     (([int64]$randomBytes[5]) -shl 32) -bor
                     (([int64]$randomBytes[6]) -shl 24) -bor
                     (([int64]$randomBytes[7]) -shl 16) -bor
                     (([int64]$randomBytes[8]) -shl 8) -bor
                     [int64]$randomBytes[9]
        }
        else {
            $timestampMs = $lastTimestampMs
            $randA = [int]$script:KlipAroundUuid7RandA
            $randB = [int64]$script:KlipAroundUuid7RandB
            if ($randB -lt $script:KlipAroundUuid7MaxRandB) {
                $randB++
            }
            elseif ($randA -lt $script:KlipAroundUuid7MaxRandA) {
                $randA++
                $randB = 0L
            }
            else {
                $timestampMs++
                $randA = 0
                $randB = 0L
            }
        }

        $script:KlipAroundUuid7LastTimestampMs = $timestampMs
        $script:KlipAroundUuid7RandA = $randA
        $script:KlipAroundUuid7RandB = $randB
    }
    finally {
        [System.Threading.Monitor]::Exit($script:KlipAroundUuid7StateLock)
    }

    $timestampHex = $timestampMs.ToString('x12')
    $timeHigh = $timestampHex.Substring(0, 8)
    $timeMid = $timestampHex.Substring(8, 4)
    $verAndRandA = ((0x7 -shl 12) -bor ($randA -band $script:KlipAroundUuid7MaxRandA)).ToString('x4')
    $variantAndRandBTop = (0x80 -bor (($randB -shr 56) -band 0x3F)).ToString('x2')
    $randBRest = ($randB -band 0x00FFFFFFFFFFFFFF).ToString('x14')
    $clockSeqAndNode = "$variantAndRandBTop$randBRest"

    return "$timeHigh-$timeMid-$verAndRandA-$($clockSeqAndNode.Substring(0,4))-$($clockSeqAndNode.Substring(4,12))"
}

function New-KlipAroundMessage {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory protocol message.')]
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [ValidateSet('Sender', 'Receiver')]
        [string]$Role,

        [Parameter(Mandatory)]
        [ValidateSet('HELLO', 'HELLO_ACK', 'FILE_META', 'FILE_META_ACK', 'DATA_BURST', 'ACK_REPORT', 'FILE_EOF', 'FILE_EOF_ACK', 'FIN', 'FIN_ACK', 'ERROR')]
        [string]$MessageType,

        [Parameter()]
        [hashtable]$Payload = @{}
    )

    return [ordered]@{
        Protocol     = $script:KlipAroundProtocol
        SessionId    = $SessionId
        Role         = $Role
        MessageType  = $MessageType
        MessageId    = New-KlipAroundUuidV7
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        Payload      = $Payload
    }
}

function ConvertTo-KlipAroundEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Message
    )

    $json = $Message | ConvertTo-Json -Depth 20 -Compress
    return @(
        $script:KlipAroundMarkers.Begin
        $json
        $script:KlipAroundMarkers.End
    ) -join [Environment]::NewLine
}

function ConvertFrom-KlipAroundEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $envelopeByteCount = [Text.Encoding]::UTF8.GetByteCount($Text)
    if ($envelopeByteCount -gt $script:KlipAroundEnvelopeMaxUtf8Bytes) {
        throw "KlipAround envelope exceeds maximum allowed size ($script:KlipAroundEnvelopeMaxUtf8Bytes bytes)."
    }

    $normalized = $Text.Replace("`r`n", "`n")
    $beginIndex = $normalized.IndexOf($script:KlipAroundMarkers.Begin, [StringComparison]::Ordinal)
    if ($beginIndex -lt 0) {
        throw 'Clipboard payload is not a KlipAround envelope.'
    }

    $bodyStart = $beginIndex + $script:KlipAroundMarkers.Begin.Length
    $endIndex = $normalized.IndexOf("`n$($script:KlipAroundMarkers.End)", $bodyStart, [StringComparison]::Ordinal)
    if ($endIndex -lt 0) {
        throw 'Clipboard payload is not a KlipAround envelope.'
    }
    $body = $normalized.Substring($bodyStart, $endIndex - $bodyStart).Trim()
    if ([string]::IsNullOrWhiteSpace($body)) {
        throw 'KlipAround envelope payload is empty.'
    }

    try {
        $obj = $body | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to parse KlipAround envelope: $($_.Exception.Message)"
    }

    if ($obj.Protocol -ne $script:KlipAroundProtocol) {
        throw "Unsupported protocol '$($obj.Protocol)'. Expected '$script:KlipAroundProtocol'."
    }

    return $obj
}

function Write-KlipAroundDebugEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Send', 'Receive')]
        [string]$Direction,

        [Parameter(Mandatory)]
        [string]$Text
    )

    $byteCount = [Text.Encoding]::UTF8.GetByteCount($Text)
    Write-Debug "[$Direction] BEGIN KLIPAROUND MESSAGE ($byteCount UTF-8 bytes)"
    Write-Debug $Text
    Write-Debug "[$Direction] END KLIPAROUND MESSAGE"
}

function Publish-KlipAroundMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Message,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 60
    )

    $envelope = ConvertTo-KlipAroundEnvelope -Message $Message
    Write-KlipAroundDebugEnvelope -Direction Send -Text $envelope
    Set-KlipAroundClipboardText -Text $envelope -TimeoutMilliseconds ($TimeoutSeconds * 1000)
    return $Message
}

function Wait-KlipAroundMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [ValidateSet('Sender', 'Receiver')]
        [string]$ExpectedRole,

        [Parameter(Mandatory)]
        [string[]]$ExpectedMessageType,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 60,

        [Parameter()]
        [ValidateRange(50, 5000)]
        [int]$PollMilliseconds = 250,

        [Parameter()]
        [ValidateRange(10, 1000)]
        [int]$MinPollMilliseconds = 40,

        [Parameter()]
        [System.Collections.Generic.HashSet[string]]$IgnoreMessageIds,

        [Parameter()]
        [System.Collections.Generic.HashSet[string]]$SeenMessageIds,

        [Parameter()]
        [System.Collections.Generic.Queue[string]]$SeenMessageIdOrder,

        [Parameter()]
        [ValidateRange(1, 500000)]
        [int]$SeenMessageIdsMaxCount = 4096,

        [Parameter()]
        [ref]$LastAcceptedMessageId,

        [Parameter()]
        [switch]$DisableClipboardListener
    )

    $timeoutMilliseconds = [double]$TimeoutSeconds * 1000
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $emitDebug = ($DebugPreference -ne [System.Management.Automation.ActionPreference]::SilentlyContinue)
    $maxPollMilliseconds = [Math]::Max($PollMilliseconds, $MinPollMilliseconds)
    $currentPollMilliseconds = $MinPollMilliseconds
    $expectedMessageTypeSet = [System.Collections.Generic.HashSet[string]]::new($ExpectedMessageType, [StringComparer]::Ordinal)
    $expectedMessageTypesText = $ExpectedMessageType -join ','
    $lastClipboardText = $null
    $haveLastClipboardText = $false
    $clipboardListener = $null
    $useClipboardListener = $false
    $listenerTimeoutStreak = 0
    $maxListenerTimeoutStreak = 8
    $readClipboardImmediately = $true
    $invalidEnvelopeCount = 0
    $invokePollingBackoff = {
        param([double]$Factor = 1.2)
        if (-not $useClipboardListener) {
            $jitter = Get-KlipAroundPollJitterMilliseconds
            $sleepFor = $currentPollMilliseconds + $jitter
            if ($sleepFor -lt 10) { $sleepFor = 10 }
            if ($sleepFor -gt $maxPollMilliseconds) { $sleepFor = $maxPollMilliseconds }
            Start-Sleep -Milliseconds $sleepFor

            $nextPollMilliseconds = [int][Math]::Ceiling($currentPollMilliseconds * $Factor)
            if ($nextPollMilliseconds -lt $MinPollMilliseconds) { $nextPollMilliseconds = $MinPollMilliseconds }
            if ($nextPollMilliseconds -gt $maxPollMilliseconds) { $nextPollMilliseconds = $maxPollMilliseconds }
            $currentPollMilliseconds = $nextPollMilliseconds
        }
    }

    if (-not $DisableClipboardListener) {
        try {
            $clipboardListener = New-KlipAroundClipboardListener
            if ($null -ne $clipboardListener) {
                $useClipboardListener = $true
                Write-Verbose "Using clipboard event listener for session '$SessionId'."
            }
        }
        catch {
            $useClipboardListener = $false
            Write-Verbose "Could not initialize clipboard event listener for session '$SessionId'; falling back to polling. $($_.Exception.Message)"
        }
    }

    try {
        while ($stopwatch.Elapsed.TotalMilliseconds -lt $timeoutMilliseconds) {
            if ($useClipboardListener -and -not $readClipboardImmediately) {
                $waitMilliseconds = [Math]::Max(20, [Math]::Min($currentPollMilliseconds, $maxPollMilliseconds))
                $clipboardChanged = $false
                try {
                    $clipboardChanged = $clipboardListener.WaitForChange($waitMilliseconds)
                }
                catch {
                    $useClipboardListener = $false
                    Write-Verbose "Clipboard event listener failed; falling back to polling for session '$SessionId'."
                }

                if (-not $clipboardChanged -and $useClipboardListener) {
                    $listenerTimeoutStreak++
                    if ($listenerTimeoutStreak -ge $maxListenerTimeoutStreak) {
                        $useClipboardListener = $false
                        $currentPollMilliseconds = $MinPollMilliseconds
                        Write-Verbose "Clipboard event listener did not signal changes; falling back to polling for session '$SessionId'."
                    }
                    else {
                        continue
                    }
                }
                elseif ($clipboardChanged) {
                    $listenerTimeoutStreak = 0
                }
            }

            $readClipboardImmediately = $false

            $text = $null
            # Give a read started near the deadline one polling interval to finish.
            $minimumReadMilliseconds = [Math]::Min($maxPollMilliseconds, $TimeoutSeconds * 1000)
            $remainingTimeoutMilliseconds = [Math]::Ceiling($timeoutMilliseconds - $stopwatch.Elapsed.TotalMilliseconds)
            $remainingMilliseconds = [int][Math]::Max($minimumReadMilliseconds, $remainingTimeoutMilliseconds)
            try {
                $text = Get-KlipAroundClipboardText -TimeoutMilliseconds $remainingMilliseconds
            }
            catch [System.InvalidOperationException] {
                throw
            }
            catch {
                & $invokePollingBackoff 1.35
                continue
            }

            if ($haveLastClipboardText -and $text -ceq $lastClipboardText) {
                & $invokePollingBackoff 1.35
                continue
            }

            $lastClipboardText = $text
            $haveLastClipboardText = $true
            $currentPollMilliseconds = $MinPollMilliseconds

            try {
                $msg = ConvertFrom-KlipAroundEnvelope -Text $text
            }
            catch [System.Management.Automation.RuntimeException] {
                $invalidEnvelopeCount++
                if ($invalidEnvelopeCount -eq 1 -or ($invalidEnvelopeCount % 10) -eq 0) {
                    Write-Warning "Ignored $invalidEnvelopeCount malformed clipboard payload(s) while waiting for session '$SessionId'."
                }
                & $invokePollingBackoff 1.25
                continue
            }
            catch {
                throw
            }

            Write-KlipAroundDebugEnvelope -Direction Receive -Text $text
            $invalidEnvelopeCount = 0

            $messageId = [string]$msg.MessageId

            if ($null -ne $LastAcceptedMessageId -and
                -not [string]::IsNullOrWhiteSpace([string]$LastAcceptedMessageId.Value) -and
                [string]::CompareOrdinal($messageId, [string]$LastAcceptedMessageId.Value) -le 0) {
                if ($emitDebug) {
                    Write-Debug ("[Receive] Ignoring message id '{0}': monotonic watermark '{1}' already accepted." -f $messageId, [string]$LastAcceptedMessageId.Value)
                }
                & $invokePollingBackoff 1.2
                continue
            }

            $duplicateReason = $null
            if ($null -ne $IgnoreMessageIds -and $IgnoreMessageIds.Contains($messageId)) {
                $duplicateReason = 'message is probably self-published.'
            }
            elseif ($null -ne $SeenMessageIds -and $SeenMessageIds.Contains($messageId)) {
                $duplicateReason = 'duplicate message already processed.'
            }
            if ($null -ne $duplicateReason) {
                if ($emitDebug) {
                    Write-Debug ("[Receive] Ignoring message id '{0}': {1}" -f $messageId, $duplicateReason)
                }
                & $invokePollingBackoff 1.2
                continue
            }
            if ($msg.SessionId -ne $SessionId) {
                if ($emitDebug) {
                    Write-Debug ("[Receive] Ignoring message id '{0}': session mismatch. Expected '{1}', got '{2}'." -f $messageId, $SessionId, [string]$msg.SessionId)
                }
                & $invokePollingBackoff 1.2
                continue
            }
            if ($msg.Role -ne $ExpectedRole) {
                if ($emitDebug) {
                    Write-Debug ("[Receive] Ignoring message id '{0}': role mismatch. Expected '{1}', got '{2}'." -f $messageId, $ExpectedRole, [string]$msg.Role)
                }
                & $invokePollingBackoff 1.2
                continue
            }
            if (-not $expectedMessageTypeSet.Contains([string]$msg.MessageType)) {
                if ($emitDebug) {
                    Write-Debug ("[Receive] Ignoring message id '{0}': message type mismatch. Expected '{1}', got '{2}'." -f $messageId, $expectedMessageTypesText, [string]$msg.MessageType)
                }
                & $invokePollingBackoff 1.2
                continue
            }

            if ($null -ne $SeenMessageIds) {
                if ($SeenMessageIds.Add($messageId)) {
                    if ($null -ne $SeenMessageIdOrder) {
                        $SeenMessageIdOrder.Enqueue($messageId)
                        while ($SeenMessageIdOrder.Count -gt $SeenMessageIdsMaxCount) {
                            $expiredId = $SeenMessageIdOrder.Dequeue()
                            [void]$SeenMessageIds.Remove($expiredId)
                        }
                    }
                }
            }
            if ($null -ne $LastAcceptedMessageId) {
                $LastAcceptedMessageId.Value = $messageId
            }

            return $msg
        }
    }
    finally {
        if ($null -ne $clipboardListener) {
            try {
                $clipboardListener.Dispose()
            }
            catch {
                Write-Warning "Could not dispose the clipboard listener for session '$SessionId': $($_.Exception.Message)"
            }
        }
    }

    throw "Timed out waiting for message types '$($ExpectedMessageType -join ',')' from role '$ExpectedRole' in session '$SessionId'."
}

function New-KlipAroundDataBlock {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory data block.')]
    param(
        [Parameter(Mandatory)]
        [int]$Sequence,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [Parameter()]
        [ValidateSet('CRC32C', 'SHA256')]
        [string]$ChecksumAlgorithm = 'CRC32C'
    )

    return @{
        Seq               = $Sequence
        Length            = $Bytes.Length
        ChecksumAlgorithm = $ChecksumAlgorithm
        Checksum          = Get-KlipAroundBlockChecksumHexForByteArray -Bytes $Bytes -Algorithm $ChecksumAlgorithm
        Data              = [Convert]::ToBase64String($Bytes)
    }
}

function Expand-KlipAroundDataBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Block,

        [Parameter()]
        [ValidateSet('CRC32C', 'SHA256')]
        [string]$ExpectedChecksumAlgorithm,

        [Parameter()]
        [ValidateRange(0, 1048576)]
        [int]$MaximumLength = $script:KlipAroundMaxBlockBytes
    )

    $declaredLength = 0
    if (-not [int]::TryParse([string]$Block.Length, [ref]$declaredLength) -or $declaredLength -lt 0) {
        throw "Block $($Block.Seq) has invalid declared byte length."
    }
    if ($declaredLength -gt $MaximumLength) {
        throw "Block $($Block.Seq) byte length $declaredLength exceeds allowed maximum of $MaximumLength bytes."
    }

    $base64Data = [string]$Block.Data
    $maxBase64Length = [int]([Math]::Ceiling($MaximumLength / 3.0) * 4) + 8
    if ($base64Data.Length -gt $maxBase64Length) {
        throw "Block $($Block.Seq) encoded payload exceeds allowed maximum size."
    }

    $bytes = [Convert]::FromBase64String($base64Data)
    if ($bytes.Length -ne $declaredLength) {
        throw "Block $($Block.Seq) byte length mismatch."
    }

    $algorithm = 'CRC32C'
    if ($Block.PSObject.Properties.Name -contains 'ChecksumAlgorithm' -and -not [string]::IsNullOrWhiteSpace([string]$Block.ChecksumAlgorithm)) {
        $algorithm = [string]$Block.ChecksumAlgorithm
    }
    elseif ($Block.PSObject.Properties.Name -contains 'Sha256') {
        $algorithm = 'SHA256'
    }

    if ($PSBoundParameters.ContainsKey('ExpectedChecksumAlgorithm') -and $ExpectedChecksumAlgorithm -ne $algorithm) {
        throw "Block $($Block.Seq) checksum algorithm mismatch. Expected $ExpectedChecksumAlgorithm, got $algorithm."
    }

    $expected = if ($algorithm -eq 'SHA256' -and ($Block.PSObject.Properties.Name -contains 'Sha256')) {
        [string]$Block.Sha256
    }
    else {
        [string]$Block.Checksum
    }

    if ([string]::IsNullOrWhiteSpace($expected)) {
        throw "Block $($Block.Seq) missing checksum value."
    }

    $actual = Get-KlipAroundBlockChecksumHexForByteArray -Bytes $bytes -Algorithm $algorithm
    if ($actual -ne $expected) {
        throw "Block $($Block.Seq) checksum mismatch."
    }

    return ,$bytes
}
