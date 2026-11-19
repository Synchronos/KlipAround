Set-StrictMode -Version Latest

<#
.SYNOPSIS
Runs a clipboard transport preflight probe for KlipAround.

.DESCRIPTION
Test-KlipAroundTransport writes probe text to the clipboard and reads it back to
verify that clipboard transport is operational in the current environment.

Use this command before starting sender/receiver on different computers or across RDP.

.PARAMETER ProbeClipboardBytes
Approximate UTF-8 byte count used for the roundtrip probe.

.PARAMETER NoRestoreClipboard
Leaves the probe text on the clipboard. By default, the original clipboard text is restored.

.EXAMPLE
Test-KlipAroundTransport

.EXAMPLE
Test-KlipAroundTransport -ProbeClipboardBytes 20000000
#>
function Test-KlipAroundTransport {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(256, 134217728)]
        [int]$ProbeClipboardBytes = 4096,

        [Parameter()]
        [switch]$NoRestoreClipboard
    )

    $sessionName = [Environment]::GetEnvironmentVariable('SESSIONNAME')
    $isRemoteDesktop = -not [string]::IsNullOrWhiteSpace($sessionName) -and $sessionName.StartsWith('RDP-', [StringComparison]::OrdinalIgnoreCase)

    $originalClipboardText = $null
    $hadOriginalClipboard = $false
    try {
        $originalClipboardText = Get-KlipAroundClipboardText
        $hadOriginalClipboard = $true
    }
    catch {
        Write-Verbose 'Could not read existing clipboard text before probe.'
    }

    $prefix = "[KLIPAROUND-PROBE][$([guid]::NewGuid().ToString('N'))]"
    $prefixBytes = [Text.Encoding]::UTF8.GetByteCount($prefix)
    $fillByteCount = [Math]::Max(0, $ProbeClipboardBytes - $prefixBytes)
    $probeText = if ($fillByteCount -gt 0) { $prefix + ('A' * $fillByteCount) } else { $prefix }
    $probeByteCount = [Text.Encoding]::UTF8.GetByteCount($probeText)

    $echoText = $null
    $roundTripMatch = $false
    $errorMessage = $null
    try {
        Set-KlipAroundClipboardText -Text $probeText
        $echoText = Get-KlipAroundClipboardText
        $roundTripMatch = ($echoText -ceq $probeText)
    }
    catch {
        $errorMessage = $_.Exception.Message
    }
    finally {
        if (-not $NoRestoreClipboard -and $hadOriginalClipboard) {
            Set-KlipAroundClipboardText -Text $originalClipboardText
        }
    }

    [pscustomobject]@{
        Succeeded           = ([string]::IsNullOrWhiteSpace($errorMessage) -and $roundTripMatch)
        SessionName         = $sessionName
        IsRemoteDesktop     = $isRemoteDesktop
        ProbeBytesRequested = $ProbeClipboardBytes
        ProbeBytesWritten   = $probeByteCount
        ProbeBytesRead      = if ($echoText) { [Text.Encoding]::UTF8.GetByteCount($echoText) } else { 0 }
        RoundTripMatch      = $roundTripMatch
        Message             = if ($errorMessage) { $errorMessage } else { if ($roundTripMatch) { 'Clipboard roundtrip succeeded.' } else { 'Clipboard roundtrip mismatch.' } }
        TimestampUtc        = (Get-Date).ToUniversalTime()
    }
}
