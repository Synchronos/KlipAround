Set-StrictMode -Version Latest

$privateScripts = Get-ChildItem -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'Private') -Filter '*.ps1' -File -ErrorAction Stop
foreach ($script in $privateScripts) {
    . $script.FullName
}

$publicScripts = Get-ChildItem -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'Public') -Filter '*.ps1' -File -ErrorAction Stop
foreach ($script in $publicScripts) {
    . $script.FullName
}

Set-Alias -Name Send-KlipAroundClip -Value Send-KlipAround -Scope Script
Set-Alias -Name Receive-KlipAroundClip -Value Receive-KlipAround -Scope Script

Export-ModuleMember -Function @(
    'Send-KlipAround',
    'Receive-KlipAround',
    'New-KlipAroundBootstrap',
    'Test-KlipAroundTransport',
    'Test-KlipAroundPerformance'
 ) -Alias @(
    'Send-KlipAroundClip',
    'Receive-KlipAroundClip'
)
