[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts')
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path $PSScriptRoot -Parent
$manifestPath = Join-Path $moduleRoot 'KlipAround.psd1'
$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
$outputDirectoryPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$packagePath = Join-Path $outputDirectoryPath ("KlipAround.{0}.nupkg" -f $manifest.Version)
if (Test-Path -LiteralPath $packagePath) {
    throw "Package '$packagePath' already exists. Choose another output directory or remove the existing package."
}

$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('kliparound-package-' + [guid]::NewGuid().ToString('N'))
$stagingModule = Join-Path $stagingRoot 'KlipAround'
try {
    [void](New-Item -ItemType Directory -Path $stagingModule)
    foreach ($file in @('KlipAround.psd1', 'KlipAround.psm1', 'README.md', 'LICENSE')) {
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

    [void](New-Item -ItemType Directory -Path $outputDirectoryPath -Force)
    Compress-PSResource -Path $stagingModule -DestinationPath $outputDirectoryPath -PassThru -ErrorAction Stop
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction Stop
    }
}
