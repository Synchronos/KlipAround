Set-StrictMode -Version Latest

$script:KlipAroundProtocol = 'KlipAround/2'
$script:KlipAroundMarkers = @{
    Begin = '-----BEGIN KLIPAROUND/2-----'
    End   = '-----END KLIPAROUND/2-----'
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
        MessageId    = [guid]::NewGuid().ToString()
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
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

    $normalized = $Text -replace "`r`n", "`n"
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
        [System.Collections.Generic.HashSet[string]]$SeenMessageIds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $maxPollMilliseconds = [Math]::Max($PollMilliseconds, $MinPollMilliseconds)
    $currentPollMilliseconds = $MinPollMilliseconds
    $lastClipboardText = $null
    $haveLastClipboardText = $false
    $clipboardListener = $null
    $useClipboardListener = $false
    $listenerTimeoutStreak = 0
    $maxListenerTimeoutStreak = 8
    $readClipboardImmediately = $true

    $sleepWithJitter = {
        param([int]$BaseMilliseconds)
        $jitter = Get-Random -Minimum -10 -Maximum 11
        $sleepFor = $BaseMilliseconds + $jitter
        if ($sleepFor -lt 10) { $sleepFor = 10 }
        if ($sleepFor -gt $maxPollMilliseconds) { $sleepFor = $maxPollMilliseconds }
        Start-Sleep -Milliseconds $sleepFor
    }

    $increasePoll = {
        param([double]$Factor)
        $next = [int][Math]::Ceiling($currentPollMilliseconds * $Factor)
        if ($next -lt $MinPollMilliseconds) { $next = $MinPollMilliseconds }
        if ($next -gt $maxPollMilliseconds) { $next = $maxPollMilliseconds }
        return $next
    }

    try {
        $clipboardListener = New-KlipAroundClipboardListener
        if ($null -ne $clipboardListener) {
            $useClipboardListener = $true
            Write-Verbose "Using clipboard event listener for session '$SessionId'."
        }
    }
    catch {
        $useClipboardListener = $false
    }

    $invokeWaitBackoff = {
        param([double]$Factor)
        if ($useClipboardListener) {
            return
        }

        & $sleepWithJitter $currentPollMilliseconds
        $currentPollMilliseconds = [int](& $increasePoll $Factor)
    }

    try {
        while ((Get-Date) -lt $deadline) {
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
            try {
                # Give a read started near the deadline one polling interval to finish.
                $minimumReadMilliseconds = [Math]::Min($maxPollMilliseconds, $TimeoutSeconds * 1000)
                $remainingMilliseconds = [int][Math]::Max($minimumReadMilliseconds, [Math]::Ceiling(($deadline - (Get-Date)).TotalMilliseconds))
                $text = Get-KlipAroundClipboardText -TimeoutMilliseconds $remainingMilliseconds
            }
            catch [System.InvalidOperationException] {
                throw
            }
            catch {
                & $invokeWaitBackoff 1.35
                continue
            }

            if ($haveLastClipboardText -and $text -ceq $lastClipboardText) {
                & $invokeWaitBackoff 1.35
                continue
            }

            $lastClipboardText = $text
            $haveLastClipboardText = $true
            $currentPollMilliseconds = $MinPollMilliseconds

            try {
                $msg = ConvertFrom-KlipAroundEnvelope -Text $text
                Write-KlipAroundDebugEnvelope -Direction Receive -Text $text
            }
            catch {
                & $invokeWaitBackoff 1.25
                continue
            }

            $messageId = [string]$msg.MessageId

            if ($null -ne $IgnoreMessageIds -and $IgnoreMessageIds.Contains($messageId)) {
                & $invokeWaitBackoff 1.2
                continue
            }
            if ($null -ne $SeenMessageIds -and $SeenMessageIds.Contains($messageId)) {
                & $invokeWaitBackoff 1.2
                continue
            }
            if ($msg.SessionId -ne $SessionId) {
                & $invokeWaitBackoff 1.2
                continue
            }
            if ($msg.Role -ne $ExpectedRole) {
                & $invokeWaitBackoff 1.2
                continue
            }
            if ($ExpectedMessageType -notcontains [string]$msg.MessageType) {
                & $invokeWaitBackoff 1.2
                continue
            }

            if ($null -ne $SeenMessageIds) {
                [void]$SeenMessageIds.Add($messageId)
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
        [string]$ExpectedChecksumAlgorithm
    )

    $bytes = [Convert]::FromBase64String([string]$Block.Data)
    if ($bytes.Length -ne [int]$Block.Length) {
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
