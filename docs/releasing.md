# Release checklist

This is a manual maintainer procedure, not an automated publishing pipeline.
Run PowerShell examples from the repository root in the same **PowerShell 7**
session unless noted. Publishing requires explicit maintainer authorization
and Gallery credentials. Nothing in this document authorizes a release.

The [package builder](../Build/New-KlipAroundPackage.ps1) stages files and
generates a package. It does **not** check for a clean checkout, enforce that
the version tag matches `HEAD`, run tests, push Git refs, or publish.

## 1. Prepare and validate

- [ ] Choose a new version. Do not overwrite or rebuild an already-published
  version as a replacement release; publish a new version for changed bytes.
- [ ] Update `ModuleVersion` and the tagged `ReleaseNotes` URL in the
  [manifest](../KlipAround.psd1), the [release notes](../RELEASE-NOTES.md),
  and version-specific expectations in the
  [package tests](../Build/New-KlipAroundPackage.Tests.ps1).
- [ ] Review public help, [README](../README.md), architecture, protocol, and
  compatibility claims for the release's changes. Record unverified native
  clipboard or RDP scenarios rather than implying they passed.
- [ ] Run the checks in [CONTRIBUTING](../CONTRIBUTING.md) across the
  [CI matrix](../.github/workflows/ci.yml). Resolve failures and review skips.
- [ ] Commit and review all intended release changes. Confirm CI succeeded
  for that exact commit, not merely an earlier commit on the branch.
- [ ] Use a new version tag. Never move a published release tag as part of
  the routine release procedure.

The examples below derive the version from the manifest rather than naming a
specific future release:

```powershell
$ErrorActionPreference = 'Stop'
$repoRoot = (Get-Location).Path
$version = (Test-ModuleManifest -Path .\KlipAround.psd1 -ErrorAction Stop).Version.ToString()
$sourceCommit = git rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot determine HEAD.' }
$changes = @(git status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the working tree.' }
if ($changes.Count -gt 0) { throw 'Commit or otherwise resolve working-tree changes before release.' }
```

Once the release commit is approved, create its annotated tag if it does not
already exist. If a tag exists, inspect it; do not force replacement:

```powershell
git tag -a $version $sourceCommit -m "KlipAround $version"
if ($LASTEXITCODE -ne 0) { throw 'Tag creation failed; inspect existing refs before proceeding.' }
```

Validate the local tag and inspect the release notes URL before building:

```powershell
$tagCommit = git rev-parse "refs/tags/${version}^{commit}"
if ($LASTEXITCODE -ne 0 -or $tagCommit -ne $sourceCommit) {
    throw 'Version tag does not resolve to the release commit.'
}
```

Push the approved release branch and tag as separate, explicit operations
according to the repository's review process. Confirm the remote tag resolves
to the same commit and that the tagged release-notes URL is reachable before
publishing. Do not use a force push to resolve a mismatch.

## 2. Build once and inspect the exact archive

Use a unique candidate directory; never delete a published archive to make
the builder accept its output path:

```powershell
Import-Module Microsoft.PowerShell.PSResourceGet -MinimumVersion 1.1.0 -ErrorAction Stop
$candidateDirectory = Join-Path $repoRoot (
    'artifacts\candidate-' + $version + '-' + [guid]::NewGuid().ToString('N')
)
$package = & .\Build\New-KlipAroundPackage.ps1 -OutputDirectory $candidateDirectory
$candidateHash = (Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256).Hash
$package.FullName
$candidateHash
```

- [ ] Open the archive read-only and inspect its contents and generated
  `KlipAround.nuspec`, not a guessed source nuspec.
  The build renders this entry from [Build/KlipAround.nuspec.template](../Build/KlipAround.nuspec.template)
  with current manifest and repository values.
- [ ] Confirm the explicit file set: module manifest/loader, public/private
  scripts, module tests, about help, README, release notes, and license.
  The repository's `docs` and build tooling are not currently packaged;
  documentation under `docs` is maintained in the source repository.
- [ ] Check package identity/version, SPDX `MIT` license expression, packaged
  `README.md` readme, repository project URL, and raw tagged release-notes URL.
  Deprecated `owners` and `licenseUrl` fields should be absent.
- [ ] Check repository provenance: type `git`, canonical `.git` URL,
  `branch="refs/tags/<version>"`, and commit equal to `$sourceCommit`.
- [ ] Extract the archive into a new temporary directory, import its manifest
  in a fresh process, check exported commands/help, and run its bundled module
  tests using the contributor procedure. Record each runtime and test result.
- [ ] Recheck the checkout and tag before publication. Keep the candidate's
  SHA-256 and exact bytes; do not replace them with a later rebuild.

## 3. Publish only the validated package

After explicit approval, publish the nupkg rather than repackaging the source
with `-Path`. Enter the API key interactively; never paste it into source,
documentation, a command literal, or a public log:

```powershell
if ((Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256).Hash -ne $candidateHash) {
    throw 'Candidate bytes changed after validation.'
}
$galleryApiKey = Read-Host -Prompt 'PowerShell Gallery API key' -MaskInput
try {
    Publish-PSResource -NupkgPath $package.FullName -Repository PSGallery `
        -ApiKey $galleryApiKey -ErrorAction Stop
}
finally {
    Remove-Variable galleryApiKey
}
```

Removing the variable is credential hygiene, not a guarantee of erasing
process memory. Use the organization's approved secret-handling mechanism
instead when one exists.

## 4. Verify the publication independently

Allow for Gallery indexing delay. Explicitly create the download directory:
`Save-PSResource -Path` can fail when its target directory does not exist.

```powershell
$verificationPath = Join-Path ([IO.Path]::GetTempPath()) (
    'kliparound-verify-' + [guid]::NewGuid().ToString('N')
)
$null = New-Item -ItemType Directory -Path $verificationPath -ErrorAction Stop
Save-PSResource -Name KlipAround -Version $version -Repository PSGallery `
    -AsNupkg -Path $verificationPath -TrustRepository -ErrorAction Stop
$downloads = @(Get-ChildItem -LiteralPath $verificationPath -Filter '*.nupkg' -File)
if ($downloads.Count -ne 1) { throw 'Expected exactly one downloaded package.' }
$downloadHash = (Get-FileHash -LiteralPath $downloads[0].FullName -Algorithm SHA256).Hash
if ($downloadHash -ne $candidateHash) { throw 'Published package differs from the validated candidate.' }
```

- [ ] Inspect metadata and contents from the **downloaded** package.
- [ ] Extract/import it and run its bundled tests in fresh supported
  PowerShell processes. Ensure tests target the download, not the checkout.
- [ ] Verify normal `Save-PSResource` installation layout in another newly
  created directory, imports, all five functions, both aliases, and help.
- [ ] Inspect the actual Gallery page: version, README, license, project link,
  and release-notes rendering. XML correctness alone is not rendering evidence.
- [ ] Update the [compatibility and validation record](compatibility.md) with
  version, source commit, package hash, date/time zone, runtime versions,
  commands, exit codes, test counts/skips, CI link, and native-transport gaps.
- [ ] Retain the exact published package and its hash. If archiving it elsewhere,
  verify the copy's hash before removing an intermediate candidate.

Only after the new version is independently verified should a maintainer
consider unlisting a prior version through the Gallery's package management
interface. Unlisting is a separate authorized action; retain that version's
archive, source tag, and validation evidence.

If publication verification fails, stop and investigate rather than moving
the tag or overwriting archives. Correct an already-published defective
release with a new version and clear release notes.

## 5. Targeted cleanup

Remove only specifically identified verification directories and intermediate
candidates created for this release after preserving the evidence and published
bytes. Do not bulk-delete `artifacts`, use a recursive wildcard cleanup, or
remove another version's retained archive.
