Set-StrictMode -Version Latest

function Get-KlipAroundCrc32CHexForByteArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $crcMask = [uint64]4294967295
    $byteMask = [uint64]255
    $crcTableVar = Get-Variable -Name KlipAroundCrc32cTable -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $crcTableVar -or $null -eq $crcTableVar.Value) {
        $poly = [Convert]::ToUInt64('82F63B78', 16)
        $table = New-Object 'System.UInt32[]' 256
        for ($i = 0; $i -lt 256; $i++) {
            $crc = [uint64]$i
            for ($j = 0; $j -lt 8; $j++) {
                if (($crc -band [uint64]1) -ne [uint64]0) {
                    $crc = (($crc -shr 1) -bxor $poly) -band $crcMask
                }
                else {
                    $crc = ($crc -shr 1) -band $crcMask
                }
            }
            $table[$i] = [uint32]$crc
        }
        $script:KlipAroundCrc32cTable = $table
    }

    $crcValue = $crcMask
    $crcTable = $script:KlipAroundCrc32cTable
    foreach ($b in $Bytes) {
        $index = [int](($crcValue -bxor [uint64]$b) -band $byteMask)
        $crcValue = (($crcValue -shr 8) -bxor [uint64]$crcTable[$index]) -band $crcMask
    }
    $crcValue = (-bnot $crcValue) -band $crcMask
    return ([uint32]$crcValue).ToString('X8')
}

function Get-KlipAroundSha256HexForByteArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($Bytes)
    }
    finally {
        $sha.Dispose()
    }

    return -join ($hashBytes | ForEach-Object { $_.ToString('X2') })
}

function Get-KlipAroundBlockChecksumHexForByteArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [Parameter()]
        [ValidateSet('CRC32C', 'SHA256')]
        [string]$Algorithm = 'CRC32C'
    )

    switch ($Algorithm) {
        'CRC32C' { return (Get-KlipAroundCrc32CHexForByteArray -Bytes $Bytes) }
        'SHA256' { return (Get-KlipAroundSha256HexForByteArray -Bytes $Bytes) }
        default { throw "Unsupported block checksum algorithm '$Algorithm'." }
    }
}

function Get-KlipAroundSha256HexForFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    return (Get-FileHash -LiteralPath $resolved -Algorithm SHA256 -ErrorAction Stop).Hash
}
