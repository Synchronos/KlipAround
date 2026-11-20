---
status: accepted
---

# Publish versioned documentation and repository provenance metadata

## Context and Problem Statement

Gallery packages need a project home, documentation, release notes, license,
and traceable source. NuGet's `readme` field expects a path within the package,
whereas `releaseNotes` is text and may contain a link.

## Considered Options

* Keep the repository as the project URL, package the README, link to tagged
  release notes, and record NuGet repository and SPDX license metadata.
* Use the raw README URL as the project URL.

## Decision Outcome

Chosen option: "Keep the repository as the project URL, package the README,
link to tagged release notes, and record NuGet repository and SPDX license
metadata". `ProjectUri` names the project home; the `.nuspec` `readme` field
names packaged `README.md`; `releaseNotes` contains a raw URL for the tagged
`RELEASE-NOTES.md`. The generated package records an MIT SPDX expression and
Git repository, release tag, and source commit, without deprecated `.nuspec`
`owners` or `licenseUrl` fields. The module manifest retains `LicenseUri` for
PowerShell Gallery metadata.

### Consequences

* Good, because the project home, packaged documentation, and release source
  have distinct meanings and the release notes can be tied to a tag.
* Bad, because external links and tags must remain available, and building from
  an uncommitted working tree can make the recorded commit differ from packaged
  content. The build obtains `HEAD`; it does not enforce a clean working tree
  or verify that the tag points to that commit.
* Neutral, because Gallery rendering of NuGet README and linked release notes
  is separate from the metadata's presence.

### Confirmation

See [KlipAround.psd1](../../KlipAround.psd1),
[New-KlipAroundPackage.ps1](../../Build/New-KlipAroundPackage.ps1), and
[package tests](../../Build/New-KlipAroundPackage.Tests.ps1). For a release,
build from the committed tagged source and verify the resulting provenance.
