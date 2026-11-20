$moduleManifest = Join-Path -Path $PSScriptRoot -ChildPath '..\KlipAround.psd1'
Import-Module $moduleManifest -Force

Describe 'KlipAround envelope and block helpers' {
    InModuleScope KlipAround {
        It 'round-trips protocol envelope text' {
            $message = New-KlipAroundMessage -SessionId 'session-1' -Role Sender -MessageType HELLO -Payload @{ Value = 'X' }
            $text = ConvertTo-KlipAroundEnvelope -Message $message
            $parsed = ConvertFrom-KlipAroundEnvelope -Text $text

            $parsed.Protocol | Should -Be 'KlipAround/2'
            $parsed.SessionId | Should -Be 'session-1'
            $parsed.Role | Should -Be 'Sender'
            $parsed.MessageType | Should -Be 'HELLO'
            $parsed.Payload.Value | Should -Be 'X'
        }

        It 'keeps payload expansion near one Base64 layer' {
            $bytes = New-Object byte[] 262144
            $block = New-KlipAroundDataBlock -Sequence 0 -Bytes $bytes -ChecksumAlgorithm SHA256
            $message = New-KlipAroundMessage -SessionId 'size-test' -Role Sender -MessageType DATA_BURST -Payload @{ Blocks = @($block) }
            $text = ConvertTo-KlipAroundEnvelope -Message $message
            [Text.Encoding]::UTF8.GetByteCount($text) | Should -BeLessThan ([int][Math]::Ceiling($bytes.Length * 4.0 / 3.0) + 1024)
            $parsed = ConvertFrom-KlipAroundEnvelope -Text $text
            $decoded = Expand-KlipAroundDataBlock -Block $parsed.Payload.Blocks[0] -ExpectedChecksumAlgorithm SHA256
            $decoded.Length | Should -Be $bytes.Length
        }

        It 'preserves marker text and non-ASCII characters inside JSON strings' {
            $value = "name-----END KLIPAROUND/2-----`n$([char]0x03BB)"
            $message = New-KlipAroundMessage -SessionId 'markers' -Role Sender -MessageType HELLO -Payload @{ Value = $value }
            $parsed = ConvertFrom-KlipAroundEnvelope -Text (ConvertTo-KlipAroundEnvelope -Message $message)
            $parsed.Payload.Value | Should -BeExactly $value
        }

        It 'rejects legacy version 1 envelopes' {
            $oldJson = '{"Protocol":"KlipAround/1"}'
            $oldBody = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($oldJson))
            $oldEnvelope = "-----BEGIN KLIPAROUND-----`n$oldBody`n-----END KLIPAROUND-----"
            { ConvertFrom-KlipAroundEnvelope -Text $oldEnvelope } | Should -Throw '*not a KlipAround envelope*'
        }

        It 'ignores sent and previously seen message IDs' {
            $ignoredMessage = New-KlipAroundMessage -SessionId 'dedup' -Role Sender -MessageType HELLO
            $seenMessage = New-KlipAroundMessage -SessionId 'dedup' -Role Sender -MessageType HELLO
            $newMessage = New-KlipAroundMessage -SessionId 'dedup' -Role Sender -MessageType HELLO
            $ignored = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $seen = [System.Collections.Generic.HashSet[string]]::new()
            [void]$ignored.Add($ignoredMessage.MessageId.ToUpperInvariant())
            [void]$seen.Add($seenMessage.MessageId)
            $script:dedupMessages = @($ignoredMessage, $seenMessage, $newMessage)
            $script:dedupIndex = 0
            Mock New-KlipAroundClipboardListener { $null }
            Mock Start-Sleep { }
            Mock Write-Debug { }
            Mock Get-KlipAroundClipboardText {
                $message = $script:dedupMessages[$script:dedupIndex]
                $script:dedupIndex++
                return ConvertTo-KlipAroundEnvelope -Message $message
            }

            $received = Wait-KlipAroundMessage -SessionId 'dedup' -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds 1 -IgnoreMessageIds $ignored -SeenMessageIds $seen -Debug
            $received.MessageId | Should -Be $newMessage.MessageId
            $seen.Contains($newMessage.MessageId) | Should -BeTrue
            $ignored.Count | Should -Be 1
            Should -Invoke Write-Debug -Times 1 -Exactly -ParameterFilter { $Message -like '*probably self-published*' }
            Should -Invoke Write-Debug -Times 1 -Exactly -ParameterFilter { $Message -like '*duplicate message already processed*' }
        }

        It 'round-trips data block with checksum verification' {
            $bytes = [byte[]](1..50)
            $block = New-KlipAroundDataBlock -Sequence 2 -Bytes $bytes
            $decoded = Expand-KlipAroundDataBlock -Block ([pscustomobject]$block)
            [Convert]::ToBase64String($decoded) | Should -Be ([Convert]::ToBase64String($bytes))
        }

        It 'supports SHA256 block checksum mode' {
            $bytes = [byte[]](50..99)
            $block = New-KlipAroundDataBlock -Sequence 4 -Bytes $bytes -ChecksumAlgorithm SHA256
            $decoded = Expand-KlipAroundDataBlock -Block ([pscustomobject]$block) -ExpectedChecksumAlgorithm SHA256
            [Convert]::ToBase64String($decoded) | Should -Be ([Convert]::ToBase64String($bytes))
        }

        It 'matches CRC32C check values on cold and cached tables' {
            $script:KlipAroundCrc32cTable = $null
            $vectors = @(
                @{ Bytes = [byte[]]@(); Expected = '00000000' }
                @{ Bytes = [byte[]]@(0); Expected = '527D5351' }
                @{ Bytes = [byte[]](,255 * 32); Expected = '62A8AB43' }
                @{ Bytes = [byte[]](0..31); Expected = '46DD794E' }
                @{ Bytes = [Text.Encoding]::ASCII.GetBytes('123456789'); Expected = 'E3069283' }
            )
            foreach ($vector in $vectors) {
                Get-KlipAroundCrc32CHexForByteArray -Bytes $vector.Bytes | Should -BeExactly $vector.Expected
            }
        }

        It 'preserves empty and single-byte blocks with <Algorithm> checksums' -TestCases @(
            @{ Algorithm = 'SHA256' }
            @{ Algorithm = 'CRC32C' }
        ) {
            param($Algorithm)

            foreach ($bytes in @([byte[]]@(), [byte[]]@(42))) {
                $block = New-KlipAroundDataBlock -Sequence 0 -Bytes $bytes -ChecksumAlgorithm $Algorithm
                $decoded = Expand-KlipAroundDataBlock -Block ([pscustomobject]$block) -ExpectedChecksumAlgorithm $Algorithm
                ($decoded -is [byte[]]) | Should -BeTrue
                [Convert]::ToBase64String($decoded) | Should -Be ([Convert]::ToBase64String($bytes))
            }
        }
    }
}

Describe 'Module import paths' {
    It 'exports commands when the module path contains wildcard characters' {
        $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $moduleCopy = Join-Path (Get-Item -LiteralPath $TestDrive).FullName 'module-[literal]'
        [void][IO.Directory]::CreateDirectory($moduleCopy)
        foreach ($item in @('KlipAround.psd1', 'KlipAround.psm1', 'Private', 'Public')) {
            Copy-Item -LiteralPath (Join-Path $sourceRoot $item) -Destination $moduleCopy -Recurse
        }
        $runspace = [powershell]::Create()
        try {
            $null = $runspace.AddCommand('Import-Module').AddParameter('Name', (Join-Path $moduleCopy 'KlipAround.psd1')).AddParameter('PassThru', $true)
            $module = @($runspace.Invoke())
            if ($runspace.HadErrors) { throw ($runspace.Streams.Error | Out-String) }
            $module.Count | Should -Be 1
            foreach ($name in @('Send-KlipAround', 'Receive-KlipAround', 'New-KlipAroundBootstrap', 'Test-KlipAroundTransport', 'Test-KlipAroundPerformance')) {
                $module[0].ExportedFunctions.ContainsKey($name) | Should -BeTrue
            }
        }
        finally {
            $runspace.Dispose()
        }
    }
}

Describe 'Offline bootstrap installer' {
    BeforeEach {
        $script:bootstrapTestRoot = Join-Path (Get-Item -LiteralPath $TestDrive).FullName ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:bootstrapTestRoot)
        $script:bootstrapPath = Join-Path $script:bootstrapTestRoot 'install-kliparound.ps1'
        $script:originalProgramFiles = $env:ProgramFiles
        $script:originalHome = $HOME
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $env:ProgramFiles = Join-Path $script:bootstrapTestRoot 'program-files'
            $editionFolder = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
            $script:bootstrapScope = 'AllUsers'
            $script:moduleBase = Join-Path (Join-Path $env:ProgramFiles $editionFolder) 'Modules'
        }
        else {
            Set-Variable -Name HOME -Scope Global -Value $script:bootstrapTestRoot -Force
            $script:bootstrapScope = 'CurrentUser'
            $script:moduleBase = Join-Path $script:bootstrapTestRoot '.local/share/powershell/Modules'
        }
    }

    AfterEach {
        $env:ProgramFiles = $script:originalProgramFiles
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            Set-Variable -Name HOME -Scope Global -Value $script:originalHome -Force
        }
    }

    It 'installs the essential module files without external dependencies' {
        $created = New-KlipAroundBootstrap -Path $script:bootstrapPath
        $created.FullName | Should -Be $script:bootstrapPath
        $installed = & $script:bootstrapPath -Scope $script:bootstrapScope
        $installed.Scope | Should -Be $script:bootstrapScope
        $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $sourceManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $sourceRoot 'KlipAround.psd1')
        $installed.Version | Should -Be ([version]$sourceManifest.ModuleVersion).ToString()
        $installed.Path | Should -Be (Join-Path (Join-Path $script:moduleBase 'KlipAround') $installed.Version)

        $relativeFiles = @('KlipAround.psd1', 'KlipAround.psm1', 'LICENSE', 'en-US/about_KlipAround.help.txt')
        foreach ($directory in @('Private', 'Public')) {
            $relativeFiles += @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot $directory) -Filter '*.ps1' -File | ForEach-Object { "$directory/$($_.Name)" })
        }
        foreach ($relativeFile in $relativeFiles) {
            $source = Join-Path $sourceRoot $relativeFile
            $destination = Join-Path $installed.Path $relativeFile
            (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        }
        Test-Path -LiteralPath (Join-Path $installed.Path 'Tests') | Should -BeFalse
        $runspace = [powershell]::Create()
        try {
            $null = $runspace.AddCommand('Import-Module').AddParameter('Name', (Join-Path $installed.Path 'KlipAround.psd1')).AddParameter('PassThru', $true)
            $module = @($runspace.Invoke())
            if ($runspace.HadErrors) { throw ($runspace.Streams.Error | Out-String) }
            $module.Count | Should -Be 1
            $module[0].ExportedFunctions.ContainsKey('New-KlipAroundBootstrap') | Should -BeTrue
            $module[0].ExportedFunctions.ContainsKey('Send-KlipAround') | Should -BeTrue
            $module[0].ExportedFunctions.ContainsKey('Receive-KlipAround') | Should -BeTrue
            $runspace.Commands.Clear()
            $nextBootstrap = Join-Path $script:bootstrapTestRoot 'next-installer.ps1'
            $null = $runspace.AddCommand('New-KlipAroundBootstrap').AddParameter('Path', $nextBootstrap)
            [void]$runspace.Invoke()
            if ($runspace.HadErrors) { throw ($runspace.Streams.Error | Out-String) }
            Test-Path -LiteralPath $nextBootstrap | Should -BeTrue
        }
        finally {
            $runspace.Dispose()
        }
    }

    It 'requires Force to replace the same installed version and preserves other versions' {
        New-KlipAroundBootstrap -Path $script:bootstrapPath | Out-Null
        $installed = & $script:bootstrapPath -Scope $script:bootstrapScope
        $oldFile = Join-Path $installed.Path 'old-file.txt'
        [IO.File]::WriteAllText($oldFile, 'old')
        $otherVersion = Join-Path (Split-Path $installed.Path -Parent) '2.0.0'
        [void](New-Item -ItemType Directory -Path $otherVersion)
        $otherFile = Join-Path $otherVersion 'keep.txt'
        [IO.File]::WriteAllText($otherFile, 'keep')

        { & $script:bootstrapPath -Scope $script:bootstrapScope } | Should -Throw '*already exists*'
        [IO.File]::ReadAllText($oldFile) | Should -Be 'old'
        $replacement = & $script:bootstrapPath -Scope $script:bootstrapScope -Force
        $replacement.Path | Should -Be $installed.Path
        Test-Path -LiteralPath $oldFile | Should -BeFalse
        [IO.File]::ReadAllText($otherFile) | Should -Be 'keep'
    }

    It 'rejects a corrupt payload before creating an installation' {
        New-KlipAroundBootstrap -Path $script:bootstrapPath | Out-Null
        $text = [IO.File]::ReadAllText($script:bootstrapPath)
        $text = $text.Replace('$expectedHash = ''', '$expectedHash = ''0')
        [IO.File]::WriteAllText($script:bootstrapPath, $text, [Text.Encoding]::ASCII)
        { & $script:bootstrapPath -Scope $script:bootstrapScope } | Should -Throw '*integrity check*'
        Test-Path -LiteralPath (Join-Path $script:moduleBase 'KlipAround') | Should -BeFalse
    }

    It 'refuses an unversioned installation even with Force' {
        New-KlipAroundBootstrap -Path $script:bootstrapPath | Out-Null
        $folder = Join-Path $script:moduleBase 'KlipAround'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $existing = Join-Path $folder 'KlipAround.psd1'
        [IO.File]::WriteAllText($existing, 'keep')
        { & $script:bootstrapPath -Scope $script:bootstrapScope -Force } | Should -Throw '*unversioned KlipAround installation*'
        [IO.File]::ReadAllText($existing) | Should -Be 'keep'
    }

    It 'does not overwrite a bootstrap file without Force' {
        [IO.File]::WriteAllText($script:bootstrapPath, 'existing')
        { New-KlipAroundBootstrap -Path $script:bootstrapPath } | Should -Throw '*already exists*'
        [IO.File]::ReadAllText($script:bootstrapPath) | Should -Be 'existing'
        New-KlipAroundBootstrap -Path $script:bootstrapPath -Force | Out-Null
        [IO.File]::ReadAllText($script:bootstrapPath) | Should -Match '\$expectedHash'
    }

    It 'does not write into module script directories or when using WhatIf' {
        $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $unsafe = Join-Path (Join-Path $sourceRoot 'Public') ('install-' + [guid]::NewGuid().ToString('N') + '.ps1')
        { New-KlipAroundBootstrap -Path $unsafe } | Should -Throw "*cannot be written inside*"
        Test-Path -LiteralPath $unsafe | Should -BeFalse
        New-KlipAroundBootstrap -Path $script:bootstrapPath -WhatIf
        Test-Path -LiteralPath $script:bootstrapPath | Should -BeFalse
    }
}

Describe 'Received file names' {
    InModuleScope KlipAround {
        It 'rejects directory components in <FileName> before acknowledging metadata' -TestCases @(
            @{ FileName = '..\outside.bin' }
            @{ FileName = '../outside.bin' }
            @{ FileName = 'C:\outside.bin' }
            @{ FileName = '/outside.bin' }
            @{ FileName = '..' }
        ) {
            param($FileName)
            $script:receiveTestFileName = $FileName
            $script:receiveTestWaitCount = 0
            Mock Wait-KlipAroundMessage {
                $script:receiveTestWaitCount++
                if ($script:receiveTestWaitCount -eq 1) {
                    return [pscustomobject]@{ MessageType = 'HELLO'; Payload = [pscustomobject]@{ FileCount = 1 } }
                }
                return [pscustomobject]@{
                    MessageType = 'FILE_META'
                    Payload = [pscustomobject]@{
                        FileIndex = 0; Name = $script:receiveTestFileName; Length = 1
                        Sha256 = ''; BlockSize = 4096; TotalBlocks = 1; BlockChecksumAlgorithm = 'SHA256'
                    }
                }
            }
            Mock Publish-KlipAroundMessage { param($Message) return $Message }

            { Receive-KlipAround -DestinationPath $TestDrive -SessionId 'test' -Force -TimeoutSeconds 1 } |
                Should -Throw '*Invalid received file name*'
            Should -Invoke Publish-KlipAroundMessage -Times 1 -Exactly
        }

        It 'preserves an existing file when a forced transfer fails verification' {
            $target = Join-Path $TestDrive 'existing.bin'
            [IO.File]::WriteAllText($target, 'original')
            $otherPartial = Join-Path $TestDrive 'existing.bin.preserved.kliparound.part'
            [IO.File]::WriteAllText($otherPartial, 'keep')
            $script:receiveTestWaitCount = 0
            Mock Wait-KlipAroundMessage {
                $script:receiveTestWaitCount++
                switch ($script:receiveTestWaitCount) {
                    1 { return [pscustomobject]@{ MessageType = 'HELLO'; Payload = [pscustomobject]@{ FileCount = 1 } } }
                    2 { return [pscustomobject]@{ MessageType = 'FILE_META'; Payload = [pscustomobject]@{ FileIndex = 0; Name = 'existing.bin'; Length = 1; Sha256 = ''; BlockSize = 4096; TotalBlocks = 1; BlockChecksumAlgorithm = 'SHA256' } } }
                    3 {
                        $block = New-KlipAroundDataBlock -Sequence 0 -Bytes ([byte[]]@(42)) -ChecksumAlgorithm SHA256
                        return [pscustomobject]@{ MessageType = 'DATA_BURST'; Payload = [pscustomobject]@{ FileIndex = 0; Blocks = @([pscustomobject]$block) } }
                    }
                    4 { return [pscustomobject]@{ MessageType = 'FILE_EOF'; Payload = [pscustomobject]@{ FileIndex = 0; Sha256 = 'incorrect' } } }
                }
            }
            Mock Publish-KlipAroundMessage { param($Message) return $Message }

            { Receive-KlipAround -DestinationPath $TestDrive -SessionId 'test' -Force -TimeoutSeconds 1 } |
                Should -Throw '*hash mismatch*'
            [IO.File]::ReadAllText($target) | Should -Be 'original'
            [IO.File]::ReadAllText($otherPartial) | Should -Be 'keep'
            @(Get-ChildItem -LiteralPath $TestDrive -Filter 'existing.bin.*.kliparound.part').Count | Should -Be 1
        }

        It 'removes its partial file when a transfer times out' {
            $script:receiveTestWaitCount = 0
            Mock Wait-KlipAroundMessage {
                $script:receiveTestWaitCount++
                switch ($script:receiveTestWaitCount) {
                    1 { return [pscustomobject]@{ MessageType = 'HELLO'; Payload = [pscustomobject]@{ FileCount = 1 } } }
                    2 { return [pscustomobject]@{ MessageType = 'FILE_META'; Payload = [pscustomobject]@{ FileIndex = 0; Name = 'timeout.bin'; Length = 1; Sha256 = ''; BlockSize = 4096; TotalBlocks = 1; BlockChecksumAlgorithm = 'SHA256' } } }
                    default { throw 'Simulated timeout' }
                }
            }
            Mock Publish-KlipAroundMessage { param($Message) return $Message }
            { Receive-KlipAround -DestinationPath $TestDrive -SessionId 'test' -TimeoutSeconds 1 } |
                Should -Throw '*Simulated timeout*'
            @(Get-ChildItem -LiteralPath $TestDrive -Filter 'timeout.bin.*.kliparound.part').Count | Should -Be 0
        }

        It 'atomically replaces an existing file after successful verification' {
            $target = Join-Path $TestDrive 'replace.bin'
            [IO.File]::WriteAllText($target, 'original')
            $script:receiveTestWaitCount = 0
            $script:replacementHash = Get-KlipAroundBlockChecksumHexForByteArray -Bytes ([byte[]]@(42)) -Algorithm SHA256
            Mock Wait-KlipAroundMessage {
                $script:receiveTestWaitCount++
                switch ($script:receiveTestWaitCount) {
                    1 { return [pscustomobject]@{ MessageType = 'HELLO'; Payload = [pscustomobject]@{ FileCount = 1 } } }
                    2 { return [pscustomobject]@{ MessageType = 'FILE_META'; Payload = [pscustomobject]@{ FileIndex = 0; Name = 'replace.bin'; Length = 1; Sha256 = ''; BlockSize = 4096; TotalBlocks = 1; BlockChecksumAlgorithm = 'SHA256' } } }
                    3 {
                        $block = New-KlipAroundDataBlock -Sequence 0 -Bytes ([byte[]]@(42)) -ChecksumAlgorithm SHA256
                        return [pscustomobject]@{ MessageType = 'DATA_BURST'; Payload = [pscustomobject]@{ FileIndex = 0; Blocks = @([pscustomobject]$block) } }
                    }
                    4 { return [pscustomobject]@{ MessageType = 'FILE_EOF'; Payload = [pscustomobject]@{ FileIndex = 0; Sha256 = $script:replacementHash } } }
                    5 { return [pscustomobject]@{ MessageType = 'FIN'; Payload = [pscustomobject]@{ AckGraceSeconds = 3 } } }
                    default {
                        Start-Sleep -Seconds 4
                        throw 'Timed out waiting for message types'
                    }
                }
            }
            Mock Publish-KlipAroundMessage { param($Message) return $Message }

            Receive-KlipAround -DestinationPath $TestDrive -SessionId 'test' -Force -TimeoutSeconds 1
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) | Should -Be ([Convert]::ToBase64String([byte[]]@(42)))
        }
    }
}

Describe 'Benchmark safety and statistics' {
    InModuleScope KlipAround {
        It 'calculates odd and even medians' {
            Get-KlipAroundMedian -SortedValues @(1, 2, 3) | Should -Be 2
            Get-KlipAroundMedian -SortedValues @(1, 2, 3, 4) | Should -Be 2.5
            Get-KlipAroundMedian -SortedValues @(1, 2, 3, 4, 5, 6, 7) | Should -Be 4
        }

        It 'does not overwrite pre-existing files in the destination' {
            $oldRun = Join-Path $TestDrive 'B4-W1-CCRC32C-I1'
            $null = New-Item -Path $oldRun -ItemType Directory
            $existing = Join-Path $oldRun 'benchmark-1MB.bin'
            [IO.File]::WriteAllText($existing, 'keep')
            Mock Start-Job { [pscustomobject]@{ Id = 123 } }
            Mock Send-KlipAround { throw 'Simulated transfer failure' }
            Mock Get-Job { [pscustomobject]@{ State = 'Completed' } }
            Mock Remove-Job { }

            $result = Test-KlipAroundPerformance -DestinationPath $TestDrive -BlockSizesKB 4 -WindowSizes 1 -Iterations 1 -TestFileSizeMB 1 -TimeoutSeconds 10
            [IO.File]::ReadAllText($existing) | Should -Be 'keep'
            $result.Results[0].ReceiveFolderPath | Should -Not -Be $oldRun
            Test-Path -LiteralPath $result.Results[0].ReceiveFolderPath | Should -BeFalse
            $result.Results[0].Succeeded | Should -BeFalse
        }

        It 'reports job cleanup failures without losing the transfer failure' {
            Mock Start-Job { [pscustomobject]@{ Id = 123 } }
            Mock Send-KlipAround { throw 'Simulated transfer failure' }
            Mock Get-Job { [pscustomobject]@{ State = 'Running' } }
            Mock Stop-Job { throw 'Simulated stop failure' }
            Mock Remove-Job { throw 'Simulated remove failure' }

            $warnings = @()
            $result = Test-KlipAroundPerformance -DestinationPath $TestDrive -BlockSizesKB 4 -WindowSizes 1 -Iterations 1 -TestFileSizeMB 1 -TimeoutSeconds 10 -WarningAction SilentlyContinue -WarningVariable warnings
            $result.Results[0].Succeeded | Should -BeFalse
            $result.Results[0].Error | Should -Match 'Simulated transfer failure'
            ($warnings | Out-String) | Should -Match 'Simulated stop failure'
            ($warnings | Out-String) | Should -Match 'Simulated remove failure'
            Should -Invoke Remove-Job -Times 1 -Exactly
        }
    }
}

Describe 'Test-KlipAroundTransport' {
    InModuleScope KlipAround {
        BeforeEach {
            $script:kliparoundTestClipboardText = 'ORIGINAL'
            Mock Set-KlipAroundClipboardText {
                param([string]$Text)
                $script:kliparoundTestClipboardText = $Text
            }
            Mock Get-KlipAroundClipboardText {
                return $script:kliparoundTestClipboardText
            }
        }

        It 'does not access the clipboard without explicit permission' {
            $result = Test-KlipAroundTransport -ProbeClipboardBytes 4096
            $result.Succeeded | Should -BeFalse
            $result.Message | Should -Match '-NoRestoreClipboard'
            $result.ProbeBytesWritten | Should -Be 0
            Should -Invoke Set-KlipAroundClipboardText -Times 0 -Exactly
            Should -Invoke Get-KlipAroundClipboardText -Times 0 -Exactly
            $script:kliparoundTestClipboardText | Should -Be 'ORIGINAL'
        }

        It 'runs and leaves the probe on the clipboard with explicit permission' {
            $result = Test-KlipAroundTransport -ProbeClipboardBytes 4096 -NoRestoreClipboard
            $result.Succeeded | Should -Be $true
            $result.RoundTripMatch | Should -Be $true
            $script:kliparoundTestClipboardText | Should -Match '^\[KLIPAROUND-PROBE\]'
        }

        It 'reports clipboard errors after an authorized probe' {
            Mock Set-KlipAroundClipboardText { throw 'Clipboard unavailable' }
            $result = Test-KlipAroundTransport -ProbeClipboardBytes 4096 -NoRestoreClipboard
            $result.Succeeded | Should -BeFalse
            $result.Message | Should -Match 'Clipboard unavailable'
        }
    }
}

Describe 'Linux clipboard errors' {
    InModuleScope KlipAround {
        It 'reports when xclip is unavailable' {
            if ($PSVersionTable.PSEdition -eq 'Desktop') {
                Set-ItResult -Skipped -Because 'The xclip subprocess requires PowerShell Core on Linux.'
                return
            }
            $originalPath = $env:PATH
            $originalDisplay = $env:DISPLAY
            try {
                $env:PATH = $TestDrive
                $env:DISPLAY = ':test'
                { Invoke-KlipAroundXclip -Operation Read } | Should -Throw '*requires xclip on PATH*'
            }
            finally {
                $env:PATH = $originalPath
                $env:DISPLAY = $originalDisplay
            }
        }

        It 'reports when the X11 display is unavailable' {
            $originalDisplay = $env:DISPLAY
            try {
                $env:DISPLAY = ''
                { Invoke-KlipAroundXclip -Operation Read } | Should -Throw '*DISPLAY is not set*'
            }
            finally {
                $env:DISPLAY = $originalDisplay
            }
        }

        It 'times out and stops stalled xclip <Operation> operations' -TestCases @(
            @{ Operation = 'Read' }
            @{ Operation = 'Write' }
        ) {
            param($Operation)
            if ($PSVersionTable.PSEdition -ne 'Core' -or -not $IsLinux) {
                Set-ItResult -Skipped -Because 'The xclip subprocess runs on Linux.'
                return
            }

            $fakeDirectory = Join-Path $TestDrive "fake-xclip-$Operation"
            [void](New-Item -ItemType Directory -Path $fakeDirectory)
            $fakeXclip = Join-Path $fakeDirectory 'xclip'
            [IO.File]::WriteAllText($fakeXclip, "#!/bin/sh`necho `$`$ > `"`$KLIPAROUND_TEST_XCLIP_PID`"`nexec sleep 30`n")
            & chmod +x $fakeXclip
            if ($LASTEXITCODE -ne 0) { throw 'Could not make the xclip test executable.' }
            $originalPath = $env:PATH
            $originalDisplay = $env:DISPLAY
            $originalPidFile = $env:KLIPAROUND_TEST_XCLIP_PID
            try {
                $env:PATH = "${fakeDirectory}:$originalPath"
                $env:DISPLAY = ':test'
                $env:KLIPAROUND_TEST_XCLIP_PID = Join-Path $fakeDirectory 'pid'
                $timer = [Diagnostics.Stopwatch]::StartNew()
                { Invoke-KlipAroundXclip -Operation $Operation -Text ('x' * 4194304) -TimeoutMilliseconds 500 } |
                    Should -Throw "*xclip $Operation timed out*"
                $timer.Elapsed.TotalSeconds | Should -BeLessThan 5
                $childId = [int][IO.File]::ReadAllText($env:KLIPAROUND_TEST_XCLIP_PID)
                Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            }
            finally {
                $env:PATH = $originalPath
                $env:DISPLAY = $originalDisplay
                $env:KLIPAROUND_TEST_XCLIP_PID = $originalPidFile
            }
        }

        It 'surfaces clipboard failures while waiting for a message' {
            Mock New-KlipAroundClipboardListener { $null }
            Mock Get-KlipAroundClipboardText { throw [System.InvalidOperationException]::new('Clipboard unavailable') }
            { Wait-KlipAroundMessage -SessionId 'test' -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds 1 } |
                Should -Throw '*Clipboard unavailable*'
        }

        It 'skips listener initialization when disabled for low-noise waits' {
            Mock New-KlipAroundClipboardListener { throw 'listener should not be called' }
            Mock Start-Sleep { }
            Mock Get-KlipAroundClipboardText { throw 'Clipboard is empty.' }

            { Wait-KlipAroundMessage -SessionId 'test' -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds 1 -DisableClipboardListener } |
                Should -Throw '*Timed out waiting for message types*'
            Should -Invoke New-KlipAroundClipboardListener -Times 0 -Exactly
        }

        It 'reports listener disposal failures while preserving the received message' {
            $script:disposalTestListener = [pscustomobject]@{}
            $script:disposalTestListener | Add-Member -MemberType ScriptMethod -Name Dispose -Value { throw 'Simulated disposal failure' }
            $script:disposalTestMessage = New-KlipAroundMessage -SessionId 'test' -Role Sender -MessageType HELLO
            Mock New-KlipAroundClipboardListener { $script:disposalTestListener }
            Mock Get-KlipAroundClipboardText { ConvertTo-KlipAroundEnvelope -Message $script:disposalTestMessage }

            $warnings = @()
            $received = Wait-KlipAroundMessage -SessionId 'test' -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds 1 -WarningAction SilentlyContinue -WarningVariable warnings
            $received.MessageId | Should -Be $script:disposalTestMessage.MessageId
            ($warnings | Out-String) | Should -Match 'Simulated disposal failure'
        }

        It 'preserves a clipboard failure when listener disposal also fails' {
            $script:disposalTestListener = [pscustomobject]@{}
            $script:disposalTestListener | Add-Member -MemberType ScriptMethod -Name Dispose -Value { throw 'Simulated disposal failure' }
            Mock New-KlipAroundClipboardListener { $script:disposalTestListener }
            Mock Get-KlipAroundClipboardText { throw [System.InvalidOperationException]::new('Clipboard unavailable') }

            $warnings = @()
            $failure = $null
            try {
                Wait-KlipAroundMessage -SessionId 'test' -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds 1 -WarningAction SilentlyContinue -WarningVariable warnings
            }
            catch {
                $failure = $_
            }
            $failure.Exception.Message | Should -Be 'Clipboard unavailable'
            ($warnings | Out-String) | Should -Match 'Simulated disposal failure'
        }

        It 'allows a polling interval for a clipboard read near the message deadline' {
            $script:timeoutBudgets = @()
            Mock New-KlipAroundClipboardListener { $null }
            Mock Start-Sleep { }
            Mock Get-KlipAroundClipboardText {
                $script:timeoutBudgets += $TimeoutMilliseconds
                if ($TimeoutMilliseconds -lt 250) {
                    throw [System.InvalidOperationException]::new('Clipboard read budget is too short')
                }
                throw 'Clipboard is empty.'
            }

            { Wait-KlipAroundMessage -SessionId 'test' -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds 1 } |
                Should -Throw '*Timed out waiting for message types*'
            $script:timeoutBudgets.Count | Should -BeGreaterThan 0
            ($script:timeoutBudgets | Measure-Object -Minimum).Minimum | Should -BeGreaterOrEqual 250
        }

        It 'surfaces clipboard failures when receiving an initial HELLO' {
            Mock Get-KlipAroundClipboardText { throw [System.InvalidOperationException]::new('Clipboard unavailable') }
            { Receive-KlipAround -DestinationPath $TestDrive -TimeoutSeconds 1 } |
                Should -Throw '*Clipboard unavailable*'
        }

        It 'reports an inaccessible X11 display without falling back to an internal clipboard' {
            if ($PSVersionTable.PSEdition -ne 'Core' -or -not $IsLinux -or $env:KLIPAROUND_TEST_REAL_CLIPBOARD -ne '1') {
                Set-ItResult -Skipped -Because 'A dedicated Linux X11 clipboard must be explicitly enabled.'
                return
            }

            $originalDisplay = $env:DISPLAY
            try {
                $env:DISPLAY = ':65530'
                $result = Test-KlipAroundTransport -ProbeClipboardBytes 256 -NoRestoreClipboard
                $result.Succeeded | Should -BeFalse
                $result.Message | Should -Match 'xclip failed'
                { Receive-KlipAround -DestinationPath $TestDrive -TimeoutSeconds 1 } |
                    Should -Throw '*xclip failed*'
            }
            finally {
                $env:DISPLAY = $originalDisplay
            }
        }

        It 'round-trips the native Linux clipboard' {
            if ($PSVersionTable.PSEdition -ne 'Core' -or -not $IsLinux -or $env:KLIPAROUND_TEST_REAL_CLIPBOARD -ne '1') {
                Set-ItResult -Skipped -Because 'A dedicated Linux X11 clipboard must be explicitly enabled.'
                return
            }

            $result = Test-KlipAroundTransport -ProbeClipboardBytes 4096 -NoRestoreClipboard
            $result.Succeeded | Should -BeTrue
            $result.RoundTripMatch | Should -BeTrue
        }
    }
}

Describe 'KlipAround clipboard listener' {
    InModuleScope KlipAround {
        It 'starts an operational listener on Windows' {
            if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
                Set-ItResult -Skipped -Because 'The clipboard listener is Windows-only.'
                return
            }

            $listener = New-KlipAroundClipboardListener
            $listener | Should -Not -BeNull
            try {
                $listener.IsOperational | Should -BeTrue
            }
            finally {
                $listener.Dispose()
            }
        }

        Describe 'Multi-file transfer' {
            It 'transfers boundary-sized files with <InputMode>, <Algorithm> and PrecomputeHash=<PrecomputeHash>' -TestCases @(
                @{ InputMode = 'NativeLinuxClipboard'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'Parameter'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'Parameter'; Algorithm = 'SHA256'; PrecomputeHash = $true }
                @{ InputMode = 'Parameter'; Algorithm = 'CRC32C'; PrecomputeHash = $false }
                @{ InputMode = 'Parameter'; Algorithm = 'CRC32C'; PrecomputeHash = $true }
                @{ InputMode = 'PipelineStrings'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'PipelinePathProperty'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'PipelineFullNameProperty'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'PipelineFiles'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'PipelineLiteralName'; Algorithm = 'SHA256'; PrecomputeHash = $true }
                @{ InputMode = 'ParameterLiteralName'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'WildcardPath'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'ForceReplace'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'DropFirstAck'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'DropFinalAck'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'DropFirstAckShort'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'DropFinalAckShort'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'DropFinAck'; Algorithm = 'SHA256'; PrecomputeHash = $false }
            ) {
                param($InputMode, $Algorithm, $PrecomputeHash)

                if ($InputMode -eq 'NativeLinuxClipboard' -and
                    ($PSVersionTable.PSEdition -ne 'Core' -or -not $IsLinux -or $env:KLIPAROUND_TEST_REAL_CLIPBOARD -ne '1')) {
                    Set-ItResult -Skipped -Because 'A dedicated Linux X11 clipboard must be explicitly enabled.'
                    return
                }

                $source = Join-Path $TestDrive "source-$InputMode-$Algorithm-$PrecomputeHash"
                $destination = Join-Path $TestDrive "destination-$InputMode-$Algorithm-$PrecomputeHash"
                $null = New-Item -ItemType Directory -Path $source, $destination
                $sizes = if ($InputMode -like 'Drop*') { @(8193) } elseif ($InputMode -eq 'NativeLinuxClipboard') { @(0, 1, 4097) } else { @(0, 1, 4095, 4096, 4097, 8193) }
                $paths = @(
                    foreach ($size in $sizes) {
                        $name = if ($InputMode -like '*LiteralName' -and $size -eq 4095) { 'size-[4095].bin' } else { "size-$size.bin" }
                        $path = Join-Path $source $name
                        $bytes = New-Object byte[] $size
                        for ($i = 0; $i -lt $size; $i++) {
                            $bytes[$i] = $i % 251
                        }
                        [IO.File]::WriteAllBytes($path, $bytes)
                        if ($InputMode -eq 'ForceReplace') {
                            [IO.File]::WriteAllText((Join-Path $destination $name), 'previous contents')
                        }
                        $path
                    }
                )

                $clipboard = [hashtable]::Synchronized(@{ Text = ''; DropCount = 0 })
                $ready = [System.Threading.ManualResetEventSlim]::new($false)
                $senderReady = [System.Threading.ManualResetEventSlim]::new($false)
                $sessionId = [guid]::NewGuid().ToString()
                $manifest = (Resolve-Path (Join-Path $PSScriptRoot '..\KlipAround.psd1')).Path
                $runTransfer = {
                    param($Manifest, $Clipboard, $Ready, $SenderReady, $SessionId, $Paths, $Destination, $IsSender, $Algorithm, $PrecomputeHash, $InputMode)

                    $ErrorActionPreference = 'Stop'
                    $ProgressPreference = 'SilentlyContinue'
                    Import-Module $Manifest -Force
                    if ($InputMode -ne 'NativeLinuxClipboard') {
                        & (Get-Module KlipAround) {
                            param($SharedClipboard, $Mode, $ReceiverReady, $IsSenderRunspace)
                            $script:testClipboard = $SharedClipboard
                            $script:testInputMode = $Mode
                            $script:testReceiverReady = $ReceiverReady
                            $script:testIsSender = $IsSenderRunspace
                            function script:Get-KlipAroundClipboardText {
                                if ([string]::IsNullOrWhiteSpace($script:testClipboard.Text)) {
                                    throw 'Clipboard is empty.'
                                }
                                return $script:testClipboard.Text
                            }
                            function script:Set-KlipAroundClipboardText {
                                param([string]$Text)
                                if ($script:testInputMode -like 'Drop*') {
                                    $message = ConvertFrom-KlipAroundEnvelope -Text $Text
                                    $drop = switch ($script:testInputMode) {
                                        { $_ -like 'DropFirstAck*' } { $message.MessageType -eq 'ACK_REPORT' -and $message.Payload.AckNextSeq -eq 2 -and $script:testClipboard.DropCount -eq 0 }
                                        { $_ -like 'DropFinalAck*' } { $message.MessageType -eq 'ACK_REPORT' -and $message.Payload.AckNextSeq -eq 3 -and $script:testClipboard.DropCount -eq 0 }
                                        'DropFinAck' { $message.MessageType -eq 'FIN_ACK' -and $script:testClipboard.DropCount -lt 2 }
                                    }
                                    if ($drop) {
                                        $script:testClipboard.DropCount++
                                        return
                                    }
                                }
                                $script:testClipboard.Text = $Text
                            }
                            function script:New-KlipAroundClipboardListener {
                                if (-not $script:testIsSender) { $script:testReceiverReady.Set() }
                                return $null
                            }
                        } $Clipboard $InputMode $Ready $IsSender
                    }

                    $timeout = if ($InputMode -like '*Short') { 1 } elseif ($InputMode -like 'Drop*') { 8 } else { 15 }
                    if ($IsSender) {
                        $SenderReady.Set()
                        if (-not $Ready.Wait(10000)) { throw 'Receiver did not become ready.' }
                        $sendParameters = @{
                            SessionId = $SessionId
                            BlockSize = 4096
                            WindowSize = 2
                            TimeoutSeconds = $timeout
                            BlockChecksumAlgorithm = $Algorithm
                            PrecomputeHash = $PrecomputeHash
                            PassThru = $true
                        }
                        switch ($InputMode) {
                            'Parameter' {
                                Send-KlipAround -Path $Paths @sendParameters
                            }
                            'PipelineStrings' {
                                ($Paths + $Paths[0]) | Send-KlipAround @sendParameters
                            }
                            'PipelinePathProperty' {
                                ($Paths + $Paths[0]) | ForEach-Object { [pscustomobject]@{ Path = $_ } } |
                                    Send-KlipAround @sendParameters
                            }
                            'PipelineFullNameProperty' {
                                ($Paths + $Paths[0]) | ForEach-Object { [pscustomobject]@{ FullName = $_ } } |
                                    Send-KlipAround @sendParameters
                            }
                            'PipelineFiles' {
                                Get-Item -LiteralPath ($Paths + $Paths[0]) | Send-KlipAround @sendParameters
                            }
                            'PipelineLiteralName' {
                                Get-Item -LiteralPath ($Paths + $Paths[0]) | Send-KlipAround @sendParameters
                            }
                            'ParameterLiteralName' {
                                Send-KlipAround -Path $Paths @sendParameters
                            }
                            'WildcardPath' {
                                Send-KlipAround -Path (Join-Path (Split-Path $Paths[0]) '*.bin') @sendParameters
                            }
                            'ForceReplace' {
                                Send-KlipAround -Path $Paths @sendParameters
                            }
                            'NativeLinuxClipboard' {
                                ($Paths + $Paths[0]) | Send-KlipAround @sendParameters
                            }
                            { $_ -like 'Drop*' } {
                                Send-KlipAround -Path $Paths @sendParameters
                            }
                            default { throw "Unknown input mode: $InputMode" }
                        }
                    }
                    else {
                        if (-not $SenderReady.Wait(10000)) { throw 'Sender did not initialize.' }
                        if ($InputMode -eq 'NativeLinuxClipboard') { $Ready.Set() }
                        Receive-KlipAround -DestinationPath $Destination -SessionId $SessionId -TimeoutSeconds $timeout -Force:($InputMode -eq 'ForceReplace') -PassThru
                    }
                }

                $receiver = [powershell]::Create()
                $senderPowerShell = [powershell]::Create()
                try {
                    $null = $receiver.AddScript($runTransfer.ToString()).AddArgument($manifest).AddArgument($clipboard).AddArgument($ready).AddArgument($senderReady).AddArgument($sessionId).AddArgument($paths).AddArgument($destination).AddArgument($false).AddArgument($Algorithm).AddArgument($PrecomputeHash).AddArgument($InputMode)
                    $receiveAsync = $receiver.BeginInvoke()
                    $null = $senderPowerShell.AddScript($runTransfer.ToString()).AddArgument($manifest).AddArgument($clipboard).AddArgument($ready).AddArgument($senderReady).AddArgument($sessionId).AddArgument($paths).AddArgument($destination).AddArgument($true).AddArgument($Algorithm).AddArgument($PrecomputeHash).AddArgument($InputMode)
                    $sendAsync = $senderPowerShell.BeginInvoke()
                    if (-not $ready.Wait(10000)) {
                        throw 'Receiver did not initialize within 10 seconds.'
                    }

                    $sendWaitMilliseconds = if ($InputMode -eq 'NativeLinuxClipboard') { 180000 } else { 60000 }
                    if (-not $sendAsync.AsyncWaitHandle.WaitOne($sendWaitMilliseconds)) {
                        throw "Sender did not complete within $($sendWaitMilliseconds / 1000) seconds."
                    }
                    try {
                        $sendResult = @($senderPowerShell.EndInvoke($sendAsync))
                    }
                    catch {
                        throw "Sender failed: $($_.Exception.Message)`n$($senderPowerShell.Streams.Error | Out-String)"
                    }
                    if (-not $receiveAsync.AsyncWaitHandle.WaitOne(30000)) {
                        throw 'Receiver did not complete within 30 seconds.'
                    }
                    try {
                        $receiveResult = @($receiver.EndInvoke($receiveAsync))
                    }
                    catch {
                        throw "Receiver failed: $($_.Exception.Message)`n$($receiver.Streams.Error | Out-String)"
                    }

                    $sendResult.Count | Should -Be 1
                    $sendResult[0].FileCount | Should -Be $paths.Count
                    $sendResult[0].Files.Count | Should -Be $paths.Count
                    $receiveResult.Count | Should -Be $paths.Count
                    if ($InputMode -like 'Drop*') {
                        $clipboard.DropCount | Should -Be $(if ($InputMode -eq 'DropFinAck') { 2 } else { 1 })
                    }
                    for ($index = 0; $index -lt $paths.Count; $index++) {
                        $path = $paths[$index]
                        if ($InputMode -eq 'WildcardPath') {
                            @($sendResult[0].Files | Where-Object Path -eq $path).Count | Should -Be 1
                        }
                        else {
                            $sendResult[0].Files[$index].Path | Should -Be $path
                        }
                        $receivedPath = Join-Path $destination (Split-Path $path -Leaf)
                        Test-Path -LiteralPath $receivedPath -PathType Leaf | Should -BeTrue
                        (Get-FileHash -LiteralPath $receivedPath -Algorithm SHA256).Hash |
                            Should -Be (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                    }
                }
                finally {
                    if ($senderPowerShell.InvocationStateInfo.State -eq 'Running') { $senderPowerShell.Stop() }
                    if ($receiver.InvocationStateInfo.State -eq 'Running') { $receiver.Stop() }
                    $senderPowerShell.Dispose()
                    $receiver.Dispose()
                    $ready.Dispose()
                    $senderReady.Dispose()
                }
            }

            It 'rejects an empty pipeline without publishing a message' {
                Mock Publish-KlipAroundMessage { throw 'Unexpected publication.' }

                { @() | Send-KlipAround -TimeoutSeconds 1 } |
                    Should -Throw '*No files resolved for transfer*'
                Should -Invoke Publish-KlipAroundMessage -Times 0 -Exactly
            }

            It 'rejects a missing piped path before starting a transfer' {
                Mock Publish-KlipAroundMessage { throw 'Unexpected publication.' }
                $validPath = Join-Path $TestDrive 'valid-pipeline-file.bin'
                $missingPath = Join-Path $TestDrive 'missing-pipeline-file.bin'
                [IO.File]::WriteAllBytes($validPath, [byte[]]@(1, 2))

                { @($validPath, $missingPath) | Send-KlipAround -TimeoutSeconds 1 } |
                    Should -Throw '*missing-pipeline-file.bin*'
                Should -Invoke Publish-KlipAroundMessage -Times 0 -Exactly
            }

            It 'stops after the configured number of unacknowledged burst retries' {
                $path = Join-Path $TestDrive 'unacknowledged.bin'
                [IO.File]::WriteAllBytes($path, [byte[]]@(1, 2))
                Mock Publish-KlipAroundMessage { param($Message) return $Message }
                Mock Wait-KlipAroundMessage {
                    if ($ExpectedMessageType -eq 'HELLO_ACK') {
                        return [pscustomobject]@{ Payload = [pscustomobject]@{ Accepted = $true } }
                    }
                    if ($ExpectedMessageType -eq 'FILE_META_ACK') {
                        return [pscustomobject]@{ Payload = [pscustomobject]@{ FileIndex = 0 } }
                    }
                    throw "Timed out waiting for message types 'ACK_REPORT'."
                }

                { Send-KlipAround -Path $path -TimeoutSeconds 1 -MaxRetries 2 } |
                    Should -Throw '*Timed out waiting for message types*'
                Should -Invoke Publish-KlipAroundMessage -Times 3 -Exactly -ParameterFilter { $Message.MessageType -eq 'DATA_BURST' }
            }
        }
    }
}
