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

        It 'generates UUIDv7 monotonic message identifiers' {
            $ids = for ($i = 0; $i -lt 64; $i++) {
                (New-KlipAroundMessage -SessionId 'uuidv7' -Role Sender -MessageType HELLO).MessageId
            }

            foreach ($id in $ids) {
                $id | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            }

            for ($i = 1; $i -lt $ids.Count; $i++) {
                ([string]::CompareOrdinal($ids[$i - 1], $ids[$i]) -lt 0) | Should -BeTrue
            }
        }

        It 'rolls UUIDv7 monotonic counters and advances timestamp on overflow' {
            $originalLastTimestampMs = [int64]$script:KlipAroundUuid7LastTimestampMs
            $originalRandA = [int]$script:KlipAroundUuid7RandA
            $originalRandB = [int64]$script:KlipAroundUuid7RandB
            try {
                $baseTimestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 1000

                $script:KlipAroundUuid7LastTimestampMs = $baseTimestamp
                $script:KlipAroundUuid7RandA = 9
                $script:KlipAroundUuid7RandB = $script:KlipAroundUuid7MaxRandB - 1

                [void](New-KlipAroundUuidV7)
                $script:KlipAroundUuid7LastTimestampMs | Should -Be $baseTimestamp
                $script:KlipAroundUuid7RandA | Should -Be 9
                $script:KlipAroundUuid7RandB | Should -Be $script:KlipAroundUuid7MaxRandB

                [void](New-KlipAroundUuidV7)
                $script:KlipAroundUuid7LastTimestampMs | Should -Be $baseTimestamp
                $script:KlipAroundUuid7RandA | Should -Be 10
                $script:KlipAroundUuid7RandB | Should -Be 0

                $script:KlipAroundUuid7RandA = $script:KlipAroundUuid7MaxRandA
                $script:KlipAroundUuid7RandB = $script:KlipAroundUuid7MaxRandB

                $overflowId = New-KlipAroundUuidV7
                $script:KlipAroundUuid7LastTimestampMs | Should -Be ($baseTimestamp + 1)
                $script:KlipAroundUuid7RandA | Should -Be 0
                $script:KlipAroundUuid7RandB | Should -Be 0
                $overflowId | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-7000-8000-000000000000$'
            }
            finally {
                $script:KlipAroundUuid7LastTimestampMs = $originalLastTimestampMs
                $script:KlipAroundUuid7RandA = $originalRandA
                $script:KlipAroundUuid7RandB = $originalRandB
            }
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

        It 'rejects envelopes that exceed the configured size limit' {
            $originalLimit = $script:KlipAroundEnvelopeMaxUtf8Bytes
            try {
                $script:KlipAroundEnvelopeMaxUtf8Bytes = 64
                $payload = @{ Value = ('A' * 128) }
                $message = New-KlipAroundMessage -SessionId 'limit-test' -Role Sender -MessageType HELLO -Payload $payload
                $text = ConvertTo-KlipAroundEnvelope -Message $message
                { ConvertFrom-KlipAroundEnvelope -Text $text } | Should -Throw '*exceeds maximum allowed size*'
            }
            finally {
                $script:KlipAroundEnvelopeMaxUtf8Bytes = $originalLimit
            }
        }

        It 'signs and validates protocol messages in authenticated mode' {
            $message = New-KlipAroundMessage -SessionId 'auth-1' -Role Sender -MessageType HELLO -Payload @{ AuthRequired = $true; AuthSenderNonce = 'sender-nonce' }
            Set-KlipAroundMessageAuthSignature -Message $message -AuthKey 'shared-secret'

            (Test-KlipAroundMessageAuthSignature -Message $message -AuthKey 'shared-secret') | Should -BeTrue
            (Test-KlipAroundMessageAuthSignature -Message $message -AuthKey 'wrong-secret') | Should -BeFalse
        }

        It 'supports authenticated payload canonicalization when payload fields contain null values' {
            $message = New-KlipAroundMessage -SessionId 'auth-null' -Role Sender -MessageType FILE_META -Payload @{
                FileIndex       = 0
                Name            = 'null-field.bin'
                Length          = 16
                TotalBlocks     = 1
                BlockSize       = 16
                OptionalField   = $null
                AuthSenderNonce = 'sender-nonce'
            }

            { Set-KlipAroundMessageAuthSignature -Message $message -AuthKey 'shared-secret' } | Should -Not -Throw
            (Test-KlipAroundMessageAuthSignature -Message $message -AuthKey 'shared-secret') | Should -BeTrue
        }

        It 'supports authenticated payload canonicalization for generic enumerable block payloads' {
            $blocks = [System.Collections.Generic.List[hashtable]]::new()
            [void]$blocks.Add([ordered]@{ Seq = 0; Data = 'AAA=' })
            [void]$blocks.Add([ordered]@{ Seq = 1; Data = 'BBB=' })
            $message = New-KlipAroundMessage -SessionId 'auth-enum' -Role Sender -MessageType DATA_BURST -Payload @{
                FileIndex       = 0
                StartSeq        = 0
                Blocks          = $blocks
                AuthSenderNonce = 'sender-nonce'
            }

            { Set-KlipAroundMessageAuthSignature -Message $message -AuthKey 'shared-secret' } | Should -Not -Throw
            (Test-KlipAroundMessageAuthSignature -Message $message -AuthKey 'shared-secret') | Should -BeTrue
        }

        It 'keeps auth signatures valid when timestamps have trailing-zero ticks after round-trip parsing' {
            $message = New-KlipAroundMessage -SessionId 'auth-ts' -Role Sender -MessageType HELLO -Payload @{
                AuthRequired    = $true
                AuthSenderNonce = 'sender-nonce'
                StartedUtc      = '2026-01-01T00:00:00.1200000Z'
            }
            $message.TimestampUtc = '2026-01-01T00:00:00.4500000Z'
            Set-KlipAroundMessageAuthSignature -Message $message -AuthKey 'shared-secret'

            $parsed = ConvertFrom-KlipAroundEnvelope -Text (ConvertTo-KlipAroundEnvelope -Message $message)
            (Test-KlipAroundMessageAuthSignature -Message $parsed -AuthKey 'shared-secret') | Should -BeTrue
        }

        It 'detects tampered authenticated messages' {
            $message = New-KlipAroundMessage -SessionId 'auth-2' -Role Sender -MessageType FILE_META -Payload @{
                FileIndex       = 0
                Name            = 'sample.bin'
                Length          = 16
                TotalBlocks     = 1
                BlockSize       = 16
                AuthSenderNonce = 'sender-nonce'
            }
            Set-KlipAroundMessageAuthSignature -Message $message -AuthKey 'shared-secret'
            $message.Payload.Name = 'tampered.bin'

            (Test-KlipAroundMessageAuthSignature -Message $message -AuthKey 'shared-secret') | Should -BeFalse
        }

        It 'rejects unsigned messages when authentication is required' {
            $unsigned = New-KlipAroundMessage -SessionId 'auth-required' -Role Sender -MessageType HELLO -Payload @{
                AuthRequired    = $true
                AuthSenderNonce = 'nonce-a'
            }
            $signed = New-KlipAroundMessage -SessionId 'auth-required' -Role Sender -MessageType HELLO -Payload @{
                AuthRequired    = $true
                AuthSenderNonce = 'nonce-a'
            }
            Set-KlipAroundMessageAuthSignature -Message $signed -AuthKey 'shared-secret'

            $script:authRequiredMessages = @($unsigned, $signed)
            $script:authRequiredIndex = 0
            Mock New-KlipAroundClipboardListener { $null }
            Mock Start-Sleep { }
            Mock Get-KlipAroundClipboardText {
                $message = $script:authRequiredMessages[$script:authRequiredIndex]
                $script:authRequiredIndex++
                return ConvertTo-KlipAroundEnvelope -Message $message
            }

            $received = Wait-KlipAroundMessage -SessionId 'auth-required' -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds 1 -AuthKey 'shared-secret' -RequireAuthentication
            $received.MessageId | Should -Be $signed.MessageId
        }

        It 'throttles <InvalidPayload> warnings, resets after valid traffic, and accepts a signed message' -TestCases @(
            @{ InvalidPayload = 'malformed' }
            @{ InvalidPayload = 'invalidly signed' }
        ) {
            param($InvalidPayload)
            $sessionId = 'warning-throttle'
            $script:warningFrames = [System.Collections.Generic.Queue[string]]::new()
            $script:capturedWarnings = [System.Collections.Generic.List[string]]::new()
            for ($i = 1; $i -le 11; $i++) {
                if ($InvalidPayload -eq 'malformed') {
                    $text = "malformed-envelope-$i"
                }
                else {
                    $message = New-KlipAroundMessage -SessionId $sessionId -Role Sender -MessageType HELLO -Payload @{
                        AuthRequired = $true; AuthSenderNonce = 'sender-nonce'
                    }
                    Set-KlipAroundMessageAuthSignature -Message $message -AuthKey 'wrong-secret'
                    $text = ConvertTo-KlipAroundEnvelope -Message $message
                }
                $script:warningFrames.Enqueue($text)
            }
            $rejectedText = $text
            $otherSession = New-KlipAroundMessage -SessionId 'other-session' -Role Sender -MessageType HELLO -Payload @{
                AuthRequired = $true; AuthSenderNonce = 'sender-nonce'
            }
            Set-KlipAroundMessageAuthSignature -Message $otherSession -AuthKey 'shared-secret'
            $script:warningFrames.Enqueue((ConvertTo-KlipAroundEnvelope -Message $otherSession))
            $script:warningFrames.Enqueue($rejectedText)
            $accepted = New-KlipAroundMessage -SessionId $sessionId -Role Sender -MessageType HELLO -Payload @{
                AuthRequired = $true; AuthSenderNonce = 'sender-nonce'
            }
            Set-KlipAroundMessageAuthSignature -Message $accepted -AuthKey 'shared-secret'
            $script:warningFrames.Enqueue((ConvertTo-KlipAroundEnvelope -Message $accepted))

            Mock New-KlipAroundClipboardListener { $null }
            Mock Start-Sleep { }
            Mock Get-KlipAroundPollJitterMilliseconds { 0 }
            Mock Get-KlipAroundClipboardText { $script:warningFrames.Dequeue() }
            Mock Write-Warning {
                param($Message)
                [void]$script:capturedWarnings.Add([string]$Message)
            }

            $received = Wait-KlipAroundMessage -SessionId $sessionId -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds 10 -AuthKey 'shared-secret' -RequireAuthentication

            $received.MessageId | Should -Be $accepted.MessageId
            $kind = if ($InvalidPayload -eq 'malformed') { 'malformed' } else { 'unauthenticated or invalidly signed' }
            @($script:capturedWarnings.ToArray()) | Should -Be @(
                "Ignored 1 $kind clipboard payload(s) while waiting for session '$sessionId'."
                "Ignored 10 $kind clipboard payload(s) while waiting for session '$sessionId'."
                "Ignored 1 $kind clipboard payload(s) while waiting for session '$sessionId'."
            )
            $script:warningFrames.Count | Should -Be 0
            Should -Invoke Get-KlipAroundClipboardText -Times 14 -Exactly
        }

        It 'rejects replayed authentication digests when replay tracking is configured' {
            $replayed = New-KlipAroundMessage -SessionId 'auth-replay' -Role Sender -MessageType HELLO -Payload @{
                AuthRequired    = $true
                AuthSenderNonce = 'nonce-a'
            }
            $accepted = New-KlipAroundMessage -SessionId 'auth-replay' -Role Sender -MessageType HELLO -Payload @{
                AuthRequired    = $true
                AuthSenderNonce = 'nonce-a'
            }
            Set-KlipAroundMessageAuthSignature -Message $replayed -AuthKey 'shared-secret'
            Set-KlipAroundMessageAuthSignature -Message $accepted -AuthKey 'shared-secret'

            $seenAuthDigests = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $seenAuthDigestOrder = New-Object 'System.Collections.Generic.Queue[string]'
            [void]$seenAuthDigests.Add((Get-KlipAroundAuthSignature -Message $replayed))

            $script:authReplayMessages = @($replayed, $accepted)
            $script:authReplayIndex = 0
            Mock New-KlipAroundClipboardListener { $null }
            Mock Start-Sleep { }
            Mock Get-KlipAroundClipboardText {
                $message = $script:authReplayMessages[$script:authReplayIndex]
                $script:authReplayIndex++
                return ConvertTo-KlipAroundEnvelope -Message $message
            }

            $received = Wait-KlipAroundMessage -SessionId 'auth-replay' -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds 1 -AuthKey 'shared-secret' -RequireAuthentication -SeenAuthDigests $seenAuthDigests -SeenAuthDigestOrder $seenAuthDigestOrder
            $received.MessageId | Should -Be $accepted.MessageId
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

        It 'ignores stale monotonic message IDs before dedupe checks' {
            $olderMessage = New-KlipAroundMessage -SessionId 'monotonic' -Role Sender -MessageType HELLO
            $newerMessage = New-KlipAroundMessage -SessionId 'monotonic' -Role Sender -MessageType HELLO
            $acceptedMessage = New-KlipAroundMessage -SessionId 'monotonic' -Role Sender -MessageType HELLO
            $lastAcceptedMessageId = $newerMessage.MessageId
            $seen = [System.Collections.Generic.HashSet[string]]::new()
            $seenOrder = New-Object 'System.Collections.Generic.Queue[string]'
            $script:monotonicMessages = @($olderMessage, $acceptedMessage)
            $script:monotonicIndex = 0
            Mock New-KlipAroundClipboardListener { $null }
            Mock Start-Sleep { }
            Mock Write-Debug { }
            Mock Get-KlipAroundClipboardText {
                $message = $script:monotonicMessages[$script:monotonicIndex]
                $script:monotonicIndex++
                return ConvertTo-KlipAroundEnvelope -Message $message
            }

            $received = Wait-KlipAroundMessage -SessionId 'monotonic' -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds 1 -SeenMessageIds $seen -SeenMessageIdOrder $seenOrder -LastAcceptedMessageId ([ref]$lastAcceptedMessageId) -Debug
            $received.MessageId | Should -Be $acceptedMessage.MessageId
            $lastAcceptedMessageId | Should -Be $acceptedMessage.MessageId
            $seen.Contains($olderMessage.MessageId) | Should -BeFalse
            $seen.Contains($acceptedMessage.MessageId) | Should -BeTrue
            Should -Invoke Write-Debug -Times 1 -Exactly -ParameterFilter { $Message -like '*monotonic watermark*' }
        }

        It 'bounds seen message ID history with configured max count' {
            $messages = @(
                (New-KlipAroundMessage -SessionId 'seen-window' -Role Sender -MessageType HELLO),
                (New-KlipAroundMessage -SessionId 'seen-window' -Role Sender -MessageType HELLO),
                (New-KlipAroundMessage -SessionId 'seen-window' -Role Sender -MessageType HELLO)
            )
            $seen = [System.Collections.Generic.HashSet[string]]::new()
            $seenOrder = New-Object 'System.Collections.Generic.Queue[string]'
            $lastAcceptedMessageId = $null
            Mock New-KlipAroundClipboardListener { $null }
            Mock Start-Sleep { }
            Mock Get-KlipAroundClipboardText {
                return ConvertTo-KlipAroundEnvelope -Message $messages[$script:seenWindowIndex]
            }

            for ($script:seenWindowIndex = 0; $script:seenWindowIndex -lt $messages.Count; $script:seenWindowIndex++) {
                $received = Wait-KlipAroundMessage -SessionId 'seen-window' -ExpectedRole Sender -ExpectedMessageType HELLO -TimeoutSeconds 1 -SeenMessageIds $seen -SeenMessageIdOrder $seenOrder -SeenMessageIdsMaxCount 2 -LastAcceptedMessageId ([ref]$lastAcceptedMessageId)
                $received.MessageId | Should -Be $messages[$script:seenWindowIndex].MessageId
            }

            $seen.Count | Should -Be 2
            $seen.Contains($messages[0].MessageId) | Should -BeFalse
            $seen.Contains($messages[1].MessageId) | Should -BeTrue
            $seen.Contains($messages[2].MessageId) | Should -BeTrue
            $seenOrder.Count | Should -Be 2
            $lastAcceptedMessageId | Should -Be $messages[2].MessageId
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

        It 'rejects blocks whose declared size exceeds allowed maximum' {
            $block = [pscustomobject]@{
                Seq               = 0
                Length            = 4097
                ChecksumAlgorithm = 'SHA256'
                Checksum          = (Get-KlipAroundBlockChecksumHexForByteArray -Bytes ([byte[]](1..4)) -Algorithm SHA256)
                Data              = [Convert]::ToBase64String([byte[]](1..4))
            }
            { Expand-KlipAroundDataBlock -Block $block -ExpectedChecksumAlgorithm SHA256 -MaximumLength 4096 } |
                Should -Throw '*exceeds allowed maximum*'
        }

        It 'rejects malformed data blocks (<Case>)' -TestCases @(
            @{ Case = 'checksum mismatch' }
            @{ Case = 'byte length mismatch' }
            @{ Case = 'invalid declared length' }
            @{ Case = 'checksum algorithm mismatch' }
            @{ Case = 'missing checksum value' }
            @{ Case = 'oversized encoded payload' }
        ) {
            param($Case)
            $block = [pscustomobject](New-KlipAroundDataBlock -Sequence 0 -Bytes ([byte[]]@(1, 2, 3)) -ChecksumAlgorithm CRC32C)
            $expand = { Expand-KlipAroundDataBlock -Block $block -ExpectedChecksumAlgorithm CRC32C }
            switch ($Case) {
                'checksum mismatch' { $block.Checksum = 'deadbeef'; $expected = '*checksum mismatch*' }
                'byte length mismatch' { $block.Length = 5; $expected = '*byte length mismatch*' }
                'invalid declared length' { $block.Length = 'abc'; $expected = '*invalid declared byte length*' }
                'checksum algorithm mismatch' { $expand = { Expand-KlipAroundDataBlock -Block $block -ExpectedChecksumAlgorithm SHA256 }; $expected = '*checksum algorithm mismatch*' }
                'missing checksum value' { $block.Checksum = ''; $expected = '*missing checksum value*' }
                'oversized encoded payload' { $block.Data = 'A' * 64; $block.Length = 10; $expand = { Expand-KlipAroundDataBlock -Block $block -MaximumLength 16 }; $expected = '*encoded payload exceeds allowed maximum size*' }
            }
            $expand | Should -Throw $expected
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
                    return [pscustomobject]@{ MessageType = 'HELLO'; Payload = [pscustomobject]@{ FileCount = 1; BlockSize = 4096; WindowSize = 16 } }
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

        It 'rejects an auth-required HELLO when the receiver has no AuthKey' {
            Mock Wait-KlipAroundMessage {
                return [pscustomobject]@{
                    MessageType = 'HELLO'
                    Payload = [pscustomobject]@{ FileCount = 1; BlockSize = 4096; WindowSize = 16; AuthRequired = $true }
                }
            }
            Mock Publish-KlipAroundMessage { param($Message) return $Message }

            { Receive-KlipAround -DestinationPath $TestDrive -SessionId 'mixed-mode' -Force -TimeoutSeconds 1 } |
                Should -Throw '*requires authentication*not configured with -AuthKey*'
            Should -Invoke Publish-KlipAroundMessage -Times 0 -Exactly
        }

        It 'rejects an authenticated HELLO with AuthRequired explicitly false' {
            Mock Wait-KlipAroundMessage {
                return [pscustomobject]@{
                    MessageType = 'HELLO'
                    Payload = [pscustomobject]@{ FileCount = 1; BlockSize = 4096; WindowSize = 16; AuthRequired = $false; AuthSenderNonce = 'nonce-one' }
                }
            }
            Mock Publish-KlipAroundMessage { param($Message) return $Message }

            { Receive-KlipAround -DestinationPath $TestDrive -SessionId 'auth-recv-flag' -Force -TimeoutSeconds 1 -AuthKey 'secret' } |
                Should -Throw '*AuthRequired=true*'
        }

        It 'rejects an authenticated HELLO that is missing the sender nonce' {
            Mock Wait-KlipAroundMessage {
                return [pscustomobject]@{
                    MessageType = 'HELLO'
                    Payload = [pscustomobject]@{ FileCount = 1; BlockSize = 4096; WindowSize = 16; AuthRequired = $true }
                }
            }
            Mock Publish-KlipAroundMessage { param($Message) return $Message }

            { Receive-KlipAround -DestinationPath $TestDrive -SessionId 'auth-recv-nonce' -Force -TimeoutSeconds 1 -AuthKey 'secret' } |
                Should -Throw '*missing sender nonce context*'
        }

        It 'rejects a sender nonce rebinding attempt after session binding' {
            $script:rebindWaitCount = 0
            Mock Wait-KlipAroundMessage {
                $script:rebindWaitCount++
                if ($script:rebindWaitCount -eq 1) {
                    return [pscustomobject]@{
                        MessageType = 'HELLO'
                        Payload = [pscustomobject]@{ FileCount = 1; BlockSize = 4096; WindowSize = 16; AuthRequired = $true; AuthSenderNonce = 'nonce-one' }
                    }
                }
                return [pscustomobject]@{
                    MessageType = 'FILE_META'
                    Payload = [pscustomobject]@{
                        FileIndex = 0; Name = 'rebind.bin'; Length = 1; Sha256 = ''
                        BlockSize = 4096; TotalBlocks = 1; BlockChecksumAlgorithm = 'SHA256'
                        AuthSenderNonce = 'nonce-two'; AuthReceiverNonce = 'receiver-1'
                    }
                }
            }
            Mock Publish-KlipAroundMessage { param($Message) return $Message }

            { Receive-KlipAround -DestinationPath $TestDrive -SessionId 'auth-recv-rebind' -Force -TimeoutSeconds 1 -AuthKey 'secret' } |
                Should -Throw '*rebinding attempt detected*'
        }

        It 'rejects a <ReceiverNonce> receiver nonce after an authenticated HELLO' -TestCases @(
            @{ ReceiverNonce = 'missing' }
            @{ ReceiverNonce = 'changed' }
        ) {
            param($ReceiverNonce)
            $script:receiverNonceCase = $ReceiverNonce
            $script:boundReceiverNonce = $null
            $script:receiverNonceWaitCount = 0
            Mock Publish-KlipAroundMessage {
                param($Message)
                if ($Message.MessageType -eq 'HELLO_ACK') {
                    $script:boundReceiverNonce = [string]$Message.Payload.AuthReceiverNonce
                }
                return $Message
            }
            Mock Wait-KlipAroundMessage {
                $script:receiverNonceWaitCount++
                if ($script:receiverNonceWaitCount -eq 1) {
                    return [pscustomobject]@{
                        MessageType = 'HELLO'
                        Payload = [pscustomobject]@{
                            FileCount = 0; BlockSize = 4096; WindowSize = 16
                            AuthRequired = $true; AuthSenderNonce = 'sender-nonce'
                        }
                    }
                }
                $payload = @{ FileCount = 0; AuthSenderNonce = 'sender-nonce' }
                if ($script:receiverNonceCase -eq 'changed') {
                    $payload.AuthReceiverNonce = $script:boundReceiverNonce + '-changed'
                }
                return [pscustomobject]@{ MessageType = 'FIN'; Payload = [pscustomobject]$payload }
            }

            { Receive-KlipAround -DestinationPath $TestDrive -SessionId 'receiver-nonce' -Force -TimeoutSeconds 1 -AuthKey 'secret' } |
                Should -Throw '*failed receiver nonce validation*'

            $script:boundReceiverNonce | Should -Not -BeNullOrEmpty
            Should -Invoke Publish-KlipAroundMessage -Times 1 -Exactly -ParameterFilter { $Message.MessageType -eq 'HELLO_ACK' }
            Should -Invoke Publish-KlipAroundMessage -Times 0 -Exactly -ParameterFilter { $Message.MessageType -eq 'FIN_ACK' }
        }

        It 'binds authenticated session-less discovery after <InvalidHello> HELLO with AuthRequired <AuthRequiredField>' -TestCases @(
            @{ InvalidHello = 'unsigned'; AuthRequiredField = 'present' }
            @{ InvalidHello = 'invalidly signed'; AuthRequiredField = 'present' }
            @{ InvalidHello = 'unsigned'; AuthRequiredField = 'omitted' }
        ) {
            param($InvalidHello, $AuthRequiredField)
            $rejected = New-KlipAroundMessage -SessionId 'rejected-session' -Role Sender -MessageType HELLO -Payload @{
                FileCount = 0; BlockSize = 4096; WindowSize = 16
                AuthRequired = $true; AuthSenderNonce = 'rejected-nonce'
            }
            if ($InvalidHello -eq 'invalidly signed') {
                Set-KlipAroundMessageAuthSignature -Message $rejected -AuthKey 'wrong-secret'
            }
            $payload = @{
                FileCount = 0; BlockSize = 4096; WindowSize = 16
                AuthSenderNonce = 'accepted-nonce'
            }
            if ($AuthRequiredField -eq 'present') { $payload.AuthRequired = $true }
            $accepted = New-KlipAroundMessage -SessionId 'authenticated-discovery' -Role Sender -MessageType HELLO -Payload $payload
            Set-KlipAroundMessageAuthSignature -Message $accepted -AuthKey 'shared-secret'
            $script:discoveryFrames = [System.Collections.Generic.Queue[string]]::new()
            $script:discoveryFrames.Enqueue((ConvertTo-KlipAroundEnvelope -Message $rejected))
            $script:discoveryFrames.Enqueue((ConvertTo-KlipAroundEnvelope -Message $accepted))
            Mock Get-KlipAroundClipboardText { $script:discoveryFrames.Dequeue() }
            Mock Start-Sleep { }
            Mock Publish-KlipAroundMessage { param($Message) return $Message }
            Mock Wait-KlipAroundMessage { throw 'End of authenticated discovery fixture.' }

            { Receive-KlipAround -DestinationPath $TestDrive -Force -TimeoutSeconds 5 -AuthKey 'shared-secret' } |
                Should -Throw 'End of authenticated discovery fixture.'

            $script:discoveryFrames.Count | Should -Be 0
            Should -Invoke Publish-KlipAroundMessage -Times 1 -Exactly
            Should -Invoke Publish-KlipAroundMessage -Times 1 -Exactly -ParameterFilter {
                $Message.MessageType -eq 'HELLO_ACK' -and
                $Message.SessionId -eq 'authenticated-discovery' -and
                $Message.Payload.AuthSenderNonce -eq 'accepted-nonce' -and
                -not [string]::IsNullOrWhiteSpace($Message.Payload.AuthReceiverNonce) -and
                $AuthKey -eq 'shared-secret'
            }
            Should -Invoke Wait-KlipAroundMessage -Times 1 -Exactly -ParameterFilter {
                $SessionId -eq 'authenticated-discovery' -and $RequireAuthentication -and $AuthKey -eq 'shared-secret'
            }
        }

        It 'discovers the session from an initial HELLO when no SessionId is provided' {
            $helloMessage = New-KlipAroundMessage -SessionId 'discovered-session' -Role Sender -MessageType HELLO -Payload @{ FileCount = 0; BlockSize = 4096; WindowSize = 16 }
            $helloEnvelope = ConvertTo-KlipAroundEnvelope -Message $helloMessage
            $script:sessionlessReads = 0
            $script:sessionlessWaits = 0
            Mock Get-KlipAroundClipboardText {
                $script:sessionlessReads++
                if ($script:sessionlessReads -eq 1) { return 'not-a-kliparound-envelope' }
                return $helloEnvelope
            }
            Mock Start-Sleep { }
            Mock Publish-KlipAroundMessage { param($Message) return $Message }
            Mock Wait-KlipAroundMessage {
                $script:sessionlessWaits++
                if ($script:sessionlessWaits -eq 1) {
                    return [pscustomobject]@{
                        MessageType = 'FIN'
                        Payload = [pscustomobject]@{ FileCount = 0; AckGraceSeconds = 3 }
                    }
                }
                throw "Timed out waiting for message types 'FIN', 'HELLO' from role 'Sender' in session 'discovered-session'."
            }

            Mock Write-Warning { }

            Receive-KlipAround -DestinationPath $TestDrive -Force -TimeoutSeconds 2

            Should -Invoke Publish-KlipAroundMessage -Times 1 -Exactly -ParameterFilter { $Message.MessageType -eq 'HELLO_ACK' -and $Message.SessionId -eq 'discovered-session' }
            Should -Invoke Publish-KlipAroundMessage -Times 1 -Exactly -ParameterFilter { $Message.MessageType -eq 'FIN_ACK' }
            Should -Invoke Write-Warning -Times 1 -Exactly
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Ignored 1 malformed clipboard payload(s) while waiting for initial HELLO.'
            }
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
                    1 { return [pscustomobject]@{ MessageType = 'HELLO'; Payload = [pscustomobject]@{ FileCount = 1; BlockSize = 4096; WindowSize = 16 } } }
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
                    1 { return [pscustomobject]@{ MessageType = 'HELLO'; Payload = [pscustomobject]@{ FileCount = 1; BlockSize = 4096; WindowSize = 16 } } }
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
                    1 { return [pscustomobject]@{ MessageType = 'HELLO'; Payload = [pscustomobject]@{ FileCount = 1; BlockSize = 4096; WindowSize = 16 } } }
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

        Describe 'Multi-file transfer' -Tag @('Slow', 'TransferMatrix') {
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
                @{ InputMode = 'Authenticated'; Algorithm = 'SHA256'; PrecomputeHash = $false }
                @{ InputMode = 'DropFinalAckAuth'; Algorithm = 'SHA256'; PrecomputeHash = $false }
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

                    $timeout = if ($InputMode -like '*Short') { 1 } elseif ($InputMode -like 'Drop*Auth') { 15 } elseif ($InputMode -like 'Drop*') { 8 } else { 15 }
                    $authKey = if ($InputMode -eq 'Authenticated' -or $InputMode -like '*Auth') { 'matrix-shared-auth-key' } else { $null }
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
                        if ($authKey) {
                            $sendParameters.AuthKey = $authKey
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
                            'Authenticated' {
                                Send-KlipAround -Path $Paths @sendParameters
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
                        $receiveParameters = @{
                            DestinationPath = $Destination
                            SessionId = $SessionId
                            TimeoutSeconds = $timeout
                            Force = ($InputMode -eq 'ForceReplace')
                            PassThru = $true
                        }
                        if ($authKey) {
                            $receiveParameters.AuthKey = $authKey
                        }
                        Receive-KlipAround @receiveParameters
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
        }

        Describe 'Mocked sender protocol' {
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

            It 'rejects ACK_REPORT values that are outside sender bounds' {
                $path = Join-Path $TestDrive 'invalid-ack.bin'
                [IO.File]::WriteAllBytes($path, [byte[]]@(1, 2))
                Mock Publish-KlipAroundMessage { param($Message) return $Message }
                Mock Wait-KlipAroundMessage {
                    if ($ExpectedMessageType -eq 'HELLO_ACK') {
                        return [pscustomobject]@{ Payload = [pscustomobject]@{ Accepted = $true } }
                    }
                    if ($ExpectedMessageType -eq 'FILE_META_ACK') {
                        return [pscustomobject]@{ Payload = [pscustomobject]@{ FileIndex = 0 } }
                    }
                    if ($ExpectedMessageType -eq 'ACK_REPORT') {
                        return [pscustomobject]@{
                            Payload = [pscustomobject]@{
                                FileIndex = 0
                                AckNextSeq = 9
                                TotalBlocks = 1
                                MissingSeqs = @()
                            }
                        }
                    }
                    throw "Unexpected wait for message type '$ExpectedMessageType'."
                }

                { Send-KlipAround -Path $path -TimeoutSeconds 1 -MaxRetries 1 } |
                    Should -Throw '*out of bounds*'
            }

            It 'completes a mocked transfer with SREJ resend and reports results' {
                $path = Join-Path $TestDrive 'sender-state-machine.bin'
                $bytes = New-Object byte[] 8292
                for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = $i % 251 }
                [IO.File]::WriteAllBytes($path, $bytes)

                $script:senderPublished = [System.Collections.Generic.List[hashtable]]::new()
                $script:senderAckCount = 0
                Mock Publish-KlipAroundMessage {
                    param($Message)
                    [void]$script:senderPublished.Add($Message)
                    return $Message
                }
                Mock Wait-KlipAroundMessage {
                    if ($ExpectedMessageType -eq 'HELLO_ACK') {
                        return [pscustomobject]@{ Payload = [pscustomobject]@{ Accepted = $true } }
                    }
                    if ($ExpectedMessageType -eq 'FILE_META_ACK') {
                        return [pscustomobject]@{ Payload = [pscustomobject]@{ FileIndex = 0 } }
                    }
                    if ($ExpectedMessageType -eq 'ACK_REPORT') {
                        $script:senderAckCount++
                        switch ($script:senderAckCount) {
                            1 { return [pscustomobject]@{ Payload = [pscustomobject]@{ FileIndex = 0; AckNextSeq = 1; TotalBlocks = 3; MissingSeqs = @(1) } } }
                            2 { return [pscustomobject]@{ Payload = [pscustomobject]@{ FileIndex = 0; AckNextSeq = 2; TotalBlocks = 3; MissingSeqs = @() } } }
                            default { return [pscustomobject]@{ Payload = [pscustomobject]@{ FileIndex = 0; AckNextSeq = 3; TotalBlocks = 3; MissingSeqs = @() } } }
                        }
                    }
                    if ($ExpectedMessageType -eq 'FILE_EOF_ACK') {
                        return [pscustomobject]@{ Payload = [pscustomobject]@{ FileIndex = 0; Accepted = $true } }
                    }
                    if ($ExpectedMessageType -eq 'FIN_ACK') {
                        return [pscustomobject]@{ Payload = [pscustomobject]@{ ReceivedFiles = 1 } }
                    }
                    throw "Unexpected wait for message type '$ExpectedMessageType'."
                }

                $result = Send-KlipAround -Path $path -SessionId 'sender-sm' -BlockSize 4096 -WindowSize 2 -TimeoutSeconds 5 -PassThru

                $types = @($script:senderPublished | ForEach-Object { $_.MessageType })
                $types | Should -Be @('HELLO', 'FILE_META', 'DATA_BURST', 'DATA_BURST', 'DATA_BURST', 'FILE_EOF', 'FIN')

                $bursts = @($script:senderPublished | Where-Object { $_.MessageType -eq 'DATA_BURST' })
                $bursts[0].Payload.StartSeq | Should -Be 0
                @($bursts[0].Payload.Blocks).Count | Should -Be 2
                $bursts[1].Payload.StartSeq | Should -Be 1
                @($bursts[1].Payload.Blocks).Count | Should -Be 1
                @($bursts[1].Payload.Blocks)[0].Seq | Should -Be 1
                $bursts[2].Payload.StartSeq | Should -Be 2
                @($bursts[2].Payload.Blocks)[0].Seq | Should -Be 2

                $result.FileCount | Should -Be 1
                $result.Files[0].Blocks | Should -Be 3
                $result.Files[0].Sha256 | Should -Be (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            }

            It 'resends a DATA_BURST after an ACK_REPORT wait timeout and completes' {
                $path = Join-Path $TestDrive 'sender-retry.bin'
                [IO.File]::WriteAllBytes($path, [byte[]](1..100))
                $script:retryAckCalls = 0
                Mock Publish-KlipAroundMessage { param($Message) return $Message }
                Mock Wait-KlipAroundMessage {
                    if ($ExpectedMessageType -eq 'HELLO_ACK') { return [pscustomobject]@{ Payload = [pscustomobject]@{ Accepted = $true } } }
                    if ($ExpectedMessageType -eq 'FILE_META_ACK') { return [pscustomobject]@{ Payload = [pscustomobject]@{ FileIndex = 0 } } }
                    if ($ExpectedMessageType -eq 'ACK_REPORT') {
                        $script:retryAckCalls++
                        if ($script:retryAckCalls -eq 1) { throw "Timed out waiting for message types 'ACK_REPORT'." }
                        return [pscustomobject]@{ Payload = [pscustomobject]@{ FileIndex = 0; AckNextSeq = 1; TotalBlocks = 1; MissingSeqs = @() } }
                    }
                    if ($ExpectedMessageType -eq 'FILE_EOF_ACK') { return [pscustomobject]@{ Payload = [pscustomobject]@{ FileIndex = 0 } } }
                    if ($ExpectedMessageType -eq 'FIN_ACK') { return [pscustomobject]@{ Payload = [pscustomobject]@{ ReceivedFiles = 1 } } }
                    throw "Unexpected wait for message type '$ExpectedMessageType'."
                }

                { Send-KlipAround -Path $path -SessionId 'sender-retry' -TimeoutSeconds 4 -MaxRetries 2 } | Should -Not -Throw
                Should -Invoke Publish-KlipAroundMessage -Times 2 -Exactly -ParameterFilter { $Message.MessageType -eq 'DATA_BURST' }
            }

            It 'rejects a HELLO_ACK with a <SenderNonce> sender nonce in authenticated mode' -TestCases @(
                @{ SenderNonce = 'wrong' }
                @{ SenderNonce = 'missing' }
            ) {
                param($SenderNonce)
                $path = Join-Path $TestDrive 'auth-send-nonce.bin'
                [IO.File]::WriteAllBytes($path, [byte[]]@(1, 2))
                $script:senderNonceCase = $SenderNonce
                Mock Publish-KlipAroundMessage { param($Message) return $Message }
                Mock Wait-KlipAroundMessage {
                    $payload = @{ Accepted = $true; AuthReceiverNonce = 'receiver-1' }
                    if ($script:senderNonceCase -eq 'wrong') { $payload.AuthSenderNonce = 'wrong-nonce' }
                    return [pscustomobject]@{ MessageType = 'HELLO_ACK'; Payload = [pscustomobject]$payload }
                }

                { Send-KlipAround -Path $path -SessionId 'auth-send-nonce' -TimeoutSeconds 1 -AuthKey 'secret' } |
                    Should -Throw '*failed sender nonce validation*'
                Should -Invoke Publish-KlipAroundMessage -Times 0 -Exactly -ParameterFilter { $Message.MessageType -eq 'FILE_META' }
            }

            It 'rejects a HELLO_ACK that omits the receiver nonce in authenticated mode' {
                $path = Join-Path $TestDrive 'auth-send-recv-missing.bin'
                [IO.File]::WriteAllBytes($path, [byte[]]@(1, 2))
                $script:senderHelloNonce = $null
                Mock Publish-KlipAroundMessage {
                    param($Message)
                    if ($Message.MessageType -eq 'HELLO') { $script:senderHelloNonce = [string]$Message.Payload.AuthSenderNonce }
                    return $Message
                }
                Mock Wait-KlipAroundMessage {
                    return [pscustomobject]@{ MessageType = 'HELLO_ACK'; Payload = [pscustomobject]@{ Accepted = $true; AuthSenderNonce = $script:senderHelloNonce } }
                }

                { Send-KlipAround -Path $path -SessionId 'auth-send-recv-missing' -TimeoutSeconds 1 -AuthKey 'secret' } |
                    Should -Throw '*missing receiver nonce context*'
            }

            It 'rejects a receiver nonce change after session binding in authenticated mode' {
                $path = Join-Path $TestDrive 'auth-send-recv-change.bin'
                [IO.File]::WriteAllBytes($path, [byte[]]@(1, 2))
                $script:senderHelloNonce2 = $null
                Mock Publish-KlipAroundMessage {
                    param($Message)
                    if ($Message.MessageType -eq 'HELLO') { $script:senderHelloNonce2 = [string]$Message.Payload.AuthSenderNonce }
                    return $Message
                }
                Mock Wait-KlipAroundMessage {
                    if ($ExpectedMessageType -eq 'HELLO_ACK') {
                        return [pscustomobject]@{ MessageType = 'HELLO_ACK'; Payload = [pscustomobject]@{ Accepted = $true; AuthSenderNonce = $script:senderHelloNonce2; AuthReceiverNonce = 'receiver-1' } }
                    }
                    return [pscustomobject]@{ MessageType = 'FILE_META_ACK'; Payload = [pscustomobject]@{ FileIndex = 0; AuthSenderNonce = $script:senderHelloNonce2; AuthReceiverNonce = 'receiver-2' } }
                }

                { Send-KlipAround -Path $path -SessionId 'auth-send-recv-change' -TimeoutSeconds 1 -AuthKey 'secret' } |
                    Should -Throw '*failed receiver nonce validation*'
            }
        }
    }
}
