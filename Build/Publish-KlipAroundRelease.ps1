[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,

    [Parameter()]
    [string]$Version,

    [Parameter()]
    [string]$Repository = 'PSGallery',

    [Parameter()]
    [switch]$SkipVerification
)

$ErrorActionPreference = 'Stop'

$resolvedPackagePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackagePath)
if (-not (Test-Path -LiteralPath $resolvedPackagePath -PathType Leaf)) {
    throw "Package '$resolvedPackagePath' was not found."
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $fileName = [IO.Path]::GetFileName($resolvedPackagePath)
    $match = [regex]::Match($fileName, '^KlipAround\.(?<version>\d+\.\d+\.\d+)\.nupkg$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        $Version = $match.Groups['version'].Value
    }
    else {
        throw 'Could not infer release version from package file name. Pass -Version explicitly.'
    }
}

$candidateHash = (Get-FileHash -LiteralPath $resolvedPackagePath -Algorithm SHA256).Hash
Write-Host "Candidate package: $resolvedPackagePath"
Write-Host "Candidate SHA256: $candidateHash"

if (-not $PSCmdlet.ShouldProcess("$Repository/$Version", "Publish package '$resolvedPackagePath'")) {
    return
}

$galleryApiKey = Read-Host -Prompt "$Repository API key" -MaskInput
try {
    Publish-PSResource -NupkgPath $resolvedPackagePath -Repository $Repository `
        -ApiKey $galleryApiKey -ErrorAction Stop
}
finally {
    Remove-Variable galleryApiKey -ErrorAction SilentlyContinue
}

if ($SkipVerification) {
    Write-Warning 'Publication verification was skipped by request.'
    return [pscustomobject]@{
        Version         = $Version
        Repository      = $Repository
        CandidatePath   = $resolvedPackagePath
        CandidateSha256 = $candidateHash
        Verified        = $false
    }
}

$verificationPath = Join-Path ([IO.Path]::GetTempPath()) (
    'kliparound-verify-' + [guid]::NewGuid().ToString('N')
)
$null = New-Item -ItemType Directory -Path $verificationPath -ErrorAction Stop
try {
    Save-PSResource -Name KlipAround -Version $Version -Repository $Repository `
        -AsNupkg -Path $verificationPath -TrustRepository -ErrorAction Stop

    $downloads = @(Get-ChildItem -LiteralPath $verificationPath -Filter '*.nupkg' -File)
    if ($downloads.Count -ne 1) {
        throw "Expected exactly one downloaded package, found $($downloads.Count)."
    }

    $downloadPath = $downloads[0].FullName
    $downloadHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
    Write-Host "Downloaded package: $downloadPath"
    Write-Host "Downloaded SHA256: $downloadHash"
    if ($downloadHash -ne $candidateHash) {
        throw 'Published package differs from the validated candidate.'
    }
}
finally {
    if (Test-Path -LiteralPath $verificationPath) {
        Remove-Item -LiteralPath $verificationPath -Recurse -Force -ErrorAction Stop
    }
}

[pscustomobject]@{
    Version         = $Version
    Repository      = $Repository
    CandidatePath   = $resolvedPackagePath
    CandidateSha256 = $candidateHash
    Verified        = $true
}
