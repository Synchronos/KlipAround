@{
    RootModule        = 'KlipAround.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '7a99dca2-8543-4c40-98f4-a21868895a3e'
    Author            = 'James Coe'
    CompanyName       = 'Community'
    Copyright         = '(c) James Coe. All rights reserved.'
    Description       = 'HDLC-inspired reliable clipboard file transfer protocol for PowerShell.'
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
        }
    }
}
