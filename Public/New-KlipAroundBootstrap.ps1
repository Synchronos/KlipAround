Set-StrictMode -Version Latest

<#
.SYNOPSIS
Creates a self-contained offline installer for the KlipAround module.

.DESCRIPTION
Packs the files required by the currently loaded module into a compressed ZIP
archive, encodes it as Base64, and embeds it in a standalone PowerShell script.
The generated script installs the module without downloading any files.

.PARAMETER Path
Path for the generated .ps1 file. Its parent directory must already exist.

.PARAMETER Force
Replace an existing bootstrap script at Path.

.EXAMPLE
New-KlipAroundBootstrap -Path .\Install-KlipAround.ps1

.EXAMPLE
.\Install-KlipAround.ps1 -Scope AllUsers -Force
#>
function New-KlipAroundBootstrap {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [switch]$Force
    )

    $moduleRoot = Split-Path -Path $PSScriptRoot -Parent
    $outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ([IO.Path]::GetExtension($outputPath) -ine '.ps1') {
        throw 'The bootstrap output path must have a .ps1 extension.'
    }

    $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    foreach ($directory in @('Public', 'Private')) {
        $scriptDirectory = [IO.Path]::GetFullPath((Join-Path $moduleRoot $directory)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ([IO.Path]::GetFullPath($outputPath).StartsWith($scriptDirectory, $pathComparison)) {
            throw "The bootstrap cannot be written inside the module's $directory directory."
        }
    }

    if ([IO.File]::Exists($outputPath) -and -not $Force) {
        throw "Bootstrap script '$outputPath' already exists. Use -Force to replace it."
    }
    if (-not $PSCmdlet.ShouldProcess($outputPath, 'Create offline KlipAround bootstrap script')) {
        return
    }

    $manifestPath = Join-Path $moduleRoot 'KlipAround.psd1'
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
    $moduleVersion = ([version]$manifest.ModuleVersion).ToString()
    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in @('KlipAround.psd1', 'KlipAround.psm1')) {
        [void]$files.Add([pscustomobject]@{ Path = (Join-Path $moduleRoot $name); Entry = $name })
    }
    foreach ($directory in @('Private', 'Public')) {
        $directoryPath = Join-Path $moduleRoot $directory
        $scripts = @(Get-ChildItem -LiteralPath $directoryPath -Filter '*.ps1' -File -ErrorAction Stop | Sort-Object Name)
        if ($scripts.Count -eq 0) {
            throw "The module's $directory directory contains no scripts."
        }
        foreach ($script in $scripts) {
            [void]$files.Add([pscustomobject]@{ Path = $script.FullName; Entry = "$directory/$($script.Name)" })
        }
    }
    [void]$files.Add([pscustomobject]@{
        Path = (Join-Path (Join-Path $moduleRoot 'en-US') 'about_KlipAround.help.txt')
        Entry = 'en-US/about_KlipAround.help.txt'
    })

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $memory = [IO.MemoryStream]::new()
    try {
        $archive = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($file in $files) {
                $entry = $archive.CreateEntry($file.Entry, [IO.Compression.CompressionLevel]::Optimal)
                $inputStream = [IO.File]::OpenRead($file.Path)
                try {
                    $entryStream = $entry.Open()
                    try {
                        $inputStream.CopyTo($entryStream)
                    }
                    finally {
                        $entryStream.Dispose()
                    }
                }
                finally {
                    $inputStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
        $archiveBytes = $memory.ToArray()
    }
    finally {
        $memory.Dispose()
    }

    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = -join ($hasher.ComputeHash($archiveBytes) | ForEach-Object { $_.ToString('X2') })
    }
    finally {
        $hasher.Dispose()
    }
    $payload = [Convert]::ToBase64String($archiveBytes, [Base64FormattingOptions]::InsertLineBreaks)
    $template = @'
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser',

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$version = '__KLIPAROUND_VERSION__'
$expectedHash = '__KLIPAROUND_HASH__'
$payload = '
__KLIPAROUND_PAYLOAD__
'

try {
    $bytes = [Convert]::FromBase64String($payload)
}
catch {
    throw "The embedded KlipAround payload is not valid Base64: $($_.Exception.Message)"
}
$hasher = [Security.Cryptography.SHA256]::Create()
try {
    $actualHash = -join ($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('X2') })
}
finally {
    $hasher.Dispose()
}
if ($actualHash -ne $expectedHash) {
    throw 'The embedded KlipAround payload failed its SHA-256 integrity check.'
}

$runningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if ($runningOnWindows) {
    $editionFolder = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
    $base = if ($Scope -eq 'CurrentUser') {
        [Environment]::GetFolderPath('MyDocuments')
    }
    else {
        $env:ProgramFiles
    }
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw "Cannot determine the module directory for scope '$Scope'."
    }
    $moduleBase = Join-Path (Join-Path $base $editionFolder) 'Modules'
}
elseif ($Scope -eq 'CurrentUser') {
    if ([string]::IsNullOrWhiteSpace($HOME)) {
        throw "Cannot determine the home directory for scope '$Scope'."
    }
    $moduleBase = Join-Path $HOME '.local/share/powershell/Modules'
}
else {
    $moduleBase = '/usr/local/share/powershell/Modules'
}

$moduleFolder = Join-Path $moduleBase 'KlipAround'
$target = Join-Path $moduleFolder $version
if (Test-Path -LiteralPath (Join-Path $moduleFolder 'KlipAround.psd1')) {
    throw "An unversioned KlipAround installation exists in '$moduleFolder'. Move or remove it before installing."
}
if (Test-Path -LiteralPath $target) {
    if (-not $Force) {
        throw "KlipAround version '$version' already exists at '$target'. Use -Force to replace it."
    }
    $existing = Get-Item -LiteralPath $target -Force
    if (-not $existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Cannot replace '$target': it is not an ordinary directory."
    }
}
if (-not $PSCmdlet.ShouldProcess($target, "Install KlipAround for $Scope")) {
    return
}

Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
[void][IO.Directory]::CreateDirectory($moduleFolder)
$staging = Join-Path $moduleFolder ('.bootstrap-' + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $moduleFolder ('.backup-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($staging)
try {
    $memory = [IO.MemoryStream]::new($bytes, $false)
    try {
        $archive = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Read)
        try {
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName -notmatch '^(KlipAround\.psd1|KlipAround\.psm1|(?:Private|Public)/[^/\\]+\.ps1|en-US/about_KlipAround\.help\.txt)$') {
                    throw "Unexpected file in KlipAround payload: '$($entry.FullName)'."
                }
                $parts = $entry.FullName.Split('/')
                $destination = $staging
                foreach ($part in $parts) {
                    $destination = Join-Path $destination $part
                }
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
                $inputStream = $entry.Open()
                try {
                    $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try {
                        $inputStream.CopyTo($outputStream)
                    }
                    finally {
                        $outputStream.Dispose()
                    }
                }
                finally {
                    $inputStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $memory.Dispose()
    }

    $manifestPath = Join-Path $staging 'KlipAround.psd1'
    $rootModulePath = Join-Path $staging 'KlipAround.psm1'
    if (-not [IO.File]::Exists($manifestPath) -or -not [IO.File]::Exists($rootModulePath)) {
        throw 'The KlipAround payload is missing its module manifest or root module.'
    }
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    if (([version]$manifest.ModuleVersion).ToString() -ne $version -or $manifest.RootModule -ne 'KlipAround.psm1') {
        throw 'The KlipAround payload does not match the bootstrap module version.'
    }

    $movedExisting = $false
    try {
        if (Test-Path -LiteralPath $target) {
            if (-not $Force) {
                throw "KlipAround version '$version' already exists at '$target'. Use -Force to replace it."
            }
            $existing = Get-Item -LiteralPath $target -Force
            if (-not $existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Cannot replace '$target': it is not an ordinary directory."
            }
            [IO.Directory]::Move($target, $backup)
            $movedExisting = $true
        }
        [IO.Directory]::Move($staging, $target)
    }
    catch {
        $installError = $_
        if ($movedExisting) {
            try {
                [IO.Directory]::Move($backup, $target)
            }
            catch {
                throw "Installation failed: $($installError.Exception.Message). Restore the previous installation from '$backup': $($_.Exception.Message)"
            }
        }
        throw $installError
    }

    if ($movedExisting) {
        try {
            Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Installed KlipAround, but could not remove the previous installation at '$backup': $($_.Exception.Message)"
        }
    }
    [pscustomobject]@{
        Name = 'KlipAround'
        Version = $version
        Scope = $Scope
        Path = $target
    }
}
finally {
    if ([IO.Directory]::Exists($staging)) {
        try {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not remove the temporary installation directory '$staging': $($_.Exception.Message)"
        }
    }
}
'@
    $bootstrap = $template.Replace('__KLIPAROUND_VERSION__', $moduleVersion).Replace('__KLIPAROUND_HASH__', $hash).Replace('__KLIPAROUND_PAYLOAD__', $payload)
    $outputDirectory = [IO.Path]::GetDirectoryName($outputPath)
    $temporaryPath = Join-Path $outputDirectory ('.kliparound-bootstrap-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $writer = [IO.StreamWriter]::new($stream, [Text.Encoding]::ASCII)
            try {
                $writer.Write($bootstrap)
            }
            finally {
                $writer.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
        if ([IO.File]::Exists($outputPath)) {
            if (-not $Force) {
                throw "Bootstrap script '$outputPath' already exists. Use -Force to replace it."
            }
            [IO.File]::Replace($temporaryPath, $outputPath, [System.Management.Automation.Language.NullString]::Value)
        }
        else {
            [IO.File]::Move($temporaryPath, $outputPath)
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            try {
                [IO.File]::Delete($temporaryPath)
            }
            catch {
                Write-Warning "Could not remove temporary bootstrap file '$temporaryPath': $($_.Exception.Message)"
            }
        }
    }
    return Get-Item -LiteralPath $outputPath
}
