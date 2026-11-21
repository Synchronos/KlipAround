@{
    RootModule        = 'KlipAround.psm1'
    ModuleVersion     = '1.0.2'
    GUID              = '7a99dca2-8543-4c40-98f4-a21868895a3e'
    Author            = 'James Coe'
    CompanyName       = 'Community'
    Copyright         = '(c) James Coe. All rights reserved.'
    Description       = 'KlipAround is a PowerShell module that implements a reliable, HDLC-inspired file transfer protocol over the clipboard.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Send-KlipAround',
        'Receive-KlipAround',
        'New-KlipAroundBootstrap',
        'Test-KlipAroundTransport',
        'Test-KlipAroundPerformance'
    )
    CmdletsToExport   = @()
    VariablesToExport = '*'
    AliasesToExport   = @(
        'Send-KlipAroundClip',
        'Receive-KlipAroundClip'
    )

    PrivateData = @{
        PSData = @{
            Tags       = @('Clipboard', 'Transfer', 'PowerShell', 'HDLC', 'KlipAround', 'PSEdition_Desktop', 'PSEdition_Core', 'Windows', 'Linux')
            LicenseUri = 'https://github.com/Synchronos/KlipAround/blob/main/LICENSE'
            ProjectUri = 'https://github.com/Synchronos/KlipAround'
            ReleaseNotes = 'https://github.com/Synchronos/KlipAround/blob/1.0.2/RELEASE-NOTES.md'
        }
    }
}
