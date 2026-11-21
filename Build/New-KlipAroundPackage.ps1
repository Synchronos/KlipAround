[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts')
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path $PSScriptRoot -Parent
$manifestPath = Join-Path $moduleRoot 'KlipAround.psd1'
$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
$nuspecTemplatePath = Join-Path $PSScriptRoot 'KlipAround.nuspec.template'
$outputDirectoryPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$packagePath = Join-Path $outputDirectoryPath ("KlipAround.{0}.nupkg" -f $manifest.Version)
if (Test-Path -LiteralPath $packagePath) {
    throw "Package '$packagePath' already exists. Choose another output directory or remove the existing package."
}
if (-not (Test-Path -LiteralPath $nuspecTemplatePath -PathType Leaf)) {
    throw "Nuspec template '$nuspecTemplatePath' was not found."
}

$sourceCommit = & git -C $moduleRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Could not determine the Git commit for the package repository metadata.'
}

$escapeXml = {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) {
        return ''
    }
    return [System.Security.SecurityElement]::Escape($Value)
}

$nuspecTokenMap = @{
    '__ID__'                = (& $escapeXml ([string]$manifest.Name))
    '__VERSION__'           = (& $escapeXml ([string]$manifest.Version))
    '__AUTHORS__'           = (& $escapeXml ([string]$manifest.Author))
    '__PROJECT_URL__'       = (& $escapeXml ([string]$manifest.ProjectUri))
    '__DESCRIPTION__'       = (& $escapeXml ([string]$manifest.Description))
    '__RELEASE_NOTES__'     = (& $escapeXml ([string]$manifest.ReleaseNotes))
    '__COPYRIGHT__'         = (& $escapeXml ([string]$manifest.Copyright))
    '__TAGS__'              = (& $escapeXml ((@($manifest.Tags) | ForEach-Object { [string]$_ }) -join ' '))
    '__REPOSITORY_URL__'    = 'https://github.com/Synchronos/KlipAround.git'
    '__REPOSITORY_BRANCH__' = (& $escapeXml ("refs/tags/$($manifest.Version)"))
    '__REPOSITORY_COMMIT__' = (& $escapeXml $sourceCommit)
    '__README__'            = 'README.md'
}
$nuspecTemplate = Get-Content -LiteralPath $nuspecTemplatePath -Raw -ErrorAction Stop
$nuspecText = $nuspecTemplate
foreach ($token in $nuspecTokenMap.Keys) {
    $nuspecText = $nuspecText.Replace($token, $nuspecTokenMap[$token])
}
$unresolvedTokens = [regex]::Matches($nuspecText, '__[A-Z0-9_]+__')
if ($unresolvedTokens.Count -gt 0) {
    throw ("Unresolved nuspec template token(s): {0}" -f (($unresolvedTokens | ForEach-Object { $_.Value } | Select-Object -Unique) -join ', '))
}
try {
    [xml]$null = $nuspecText
}
catch {
    throw "Rendered nuspec template is not valid XML: $($_.Exception.Message)"
}

$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('kliparound-package-' + [guid]::NewGuid().ToString('N'))
$stagingModule = Join-Path $stagingRoot 'KlipAround'
try {
    [void](New-Item -ItemType Directory -Path $stagingModule)
    foreach ($file in @('KlipAround.psd1', 'KlipAround.psm1', 'README.md', 'RELEASE-NOTES.md', 'LICENSE')) {
        Copy-Item -LiteralPath (Join-Path $moduleRoot $file) -Destination $stagingModule
    }
    foreach ($directory in @('Private', 'Public', 'Tests')) {
        $source = Join-Path $moduleRoot $directory
        $destination = Join-Path $stagingModule $directory
        [void](New-Item -ItemType Directory -Path $destination)
        Get-ChildItem -LiteralPath $source -Filter '*.ps1' -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $destination
        }
    }
    $helpDestination = Join-Path $stagingModule 'en-US'
    [void](New-Item -ItemType Directory -Path $helpDestination)
    Copy-Item -LiteralPath (Join-Path (Join-Path $moduleRoot 'en-US') 'about_KlipAround.help.txt') -Destination $helpDestination

    $package = Compress-PSResource -Path $stagingModule -DestinationPath $stagingRoot -PassThru -ErrorAction Stop
    $archive = [IO.Compression.ZipFile]::Open($package.FullName, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $archive.GetEntry('KlipAround.nuspec')
        if ($null -eq $entry) {
            throw "Package '$($package.FullName)' is missing 'KlipAround.nuspec'."
        }
        $entry.Delete()
        $stream = $archive.CreateEntry('KlipAround.nuspec').Open()
        try {
            $writer = [System.IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
            try {
                $writer.Write($nuspecText)
            }
            finally {
                $writer.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
    [void](New-Item -ItemType Directory -Path $outputDirectoryPath -Force)
    Move-Item -LiteralPath $package.FullName -Destination $packagePath -ErrorAction Stop
    Get-Item -LiteralPath $packagePath
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction Stop
    }
}
