Describe 'KlipAround release package' {
    BeforeAll {
        $script:projectRoot = Split-Path $PSScriptRoot -Parent
        $script:buildScript = Join-Path $PSScriptRoot 'New-KlipAroundPackage.ps1'
    }

    It 'packages the module, help, documentation, and tests without smoke artifacts' {
        $output = Join-Path $TestDrive 'package'
        $package = & $script:buildScript -OutputDirectory $output
        $package | Should -Not -BeNullOrEmpty
        $archive = [IO.Compression.ZipFile]::OpenRead($package.FullName)
        try {
            $required = @('KlipAround.psd1', 'KlipAround.psm1', 'README.md', 'RELEASE-NOTES.md', 'LICENSE', 'en-US/about_KlipAround.help.txt')
            foreach ($directory in @('Private', 'Public', 'Tests')) {
                $required += @(Get-ChildItem -LiteralPath (Join-Path $script:projectRoot $directory) -Filter '*.ps1' -File | ForEach-Object {
                    "$directory/$($_.Name)"
                })
            }
            foreach ($name in $required) {
                $entry = $archive.GetEntry($name)
                $entry | Should -Not -BeNullOrEmpty
                $stream = $entry.Open()
                try {
                    $actual = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
                }
                finally {
                    $stream.Dispose()
                }
                $actual | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:projectRoot $name) -Algorithm SHA256).Hash
            }
            @($archive.Entries | Where-Object FullName -Match '^smoke/').Count | Should -Be 0

            $reader = [IO.StreamReader]::new($archive.GetEntry('KlipAround.nuspec').Open())
            try {
                [xml]$nuspec = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
            $nuspec.package.metadata.projectUrl | Should -Be 'https://github.com/Synchronos/KlipAround'
            $nuspec.package.metadata.readme | Should -Be 'README.md'
            $nuspec.package.metadata.releaseNotes | Should -Be 'https://github.com/Synchronos/KlipAround/blob/1.0.3/RELEASE-NOTES.md'
            $metadata = $nuspec.package.metadata
            $metadata.license.type | Should -Be 'expression'
            $metadata.license.InnerText | Should -Be 'MIT'
            $metadata.SelectSingleNode("*[local-name()='licenseUrl']") | Should -BeNullOrEmpty
            $metadata.SelectSingleNode("*[local-name()='owners']") | Should -BeNullOrEmpty
            $metadata.repository.type | Should -Be 'git'
            $metadata.repository.url | Should -Be 'https://github.com/Synchronos/KlipAround.git'
            $metadata.repository.branch | Should -Be "refs/tags/$($metadata.version)"
            $sourceCommit = & git -C $script:projectRoot rev-parse HEAD
            if ($LASTEXITCODE -ne 0) { throw 'Could not read the expected source commit.' }
            $metadata.repository.commit | Should -Be $sourceCommit
        }
        finally {
            $archive.Dispose()
        }
    }

    It 'does not overwrite an existing package' {
        $output = Join-Path $TestDrive 'existing'
        $package = & $script:buildScript -OutputDirectory $output
        $originalHash = (Get-FileHash -LiteralPath $package.FullName).Hash
        { & $script:buildScript -OutputDirectory $output } | Should -Throw '*already exists*'
        (Get-FileHash -LiteralPath $package.FullName).Hash | Should -Be $originalHash
    }
}
