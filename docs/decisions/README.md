# Decisions

This directory contains KlipAround's architectural decision records (ADRs).

Records `0001` onward reconstruct earlier decisions from the implementation,
documentation, Git history, and available development-session history. Their
numbers follow the best-supported decision chronology, not the date the
records were written. `0000` remains the existing convention for using MADR;
it is not evidence that the convention predates the reconstructed decisions.
When several changes were made together, their relative ordering is
approximate. Original decision dates and alternatives are omitted when not
established by the available evidence.

| ADR | Decision |
| --- | --- |
| [0000](0000-use-markdown-architectural-decision-records.md) | Use MADR 4.0 |
| [0001](0001-use-half-duplex-clipboard-transport.md) | Use a half-duplex clipboard protocol in a PowerShell module |
| [0002](0002-use-windows-clipboard-listener-with-polling-fallback.md) | Use a Windows clipboard listener with polling fallback |
| [0003](0003-use-xclip-for-linux-clipboard.md) | Use xclip for Linux X11 clipboard access |
| [0004](0004-validate-and-stage-received-files.md) | Validate and stage received files |
| [0005](0005-retry-and-acknowledge-transfer-messages.md) | Retry and acknowledge transfer messages |
| [0006](0006-use-versioned-single-base64-framing.md) | Use versioned, single-Base64 framing and hash-based message tracking |
| [0007](0007-optimize-crc32c-in-powershell.md) | Optimize CRC32C in PowerShell |
| [0008](0008-generate-offline-bootstrap-installers.md) | Generate offline bootstrap installers |
| [0009](0009-build-isolated-gallery-packages.md) | Build isolated Gallery packages |
| [0010](0010-require-consent-for-clipboard-probes.md) | Require consent for clipboard probes |
| [0011](0011-validate-supported-platforms-in-ci.md) | Validate supported platforms in CI |
| [0012](0012-publish-versioned-documentation-and-provenance.md) | Publish versioned documentation and provenance metadata |
| [0013](0013-include-tests-in-gallery-packages-for-validation.md) | Include tests in Gallery packages for release validation |

Use [adr-template.md](adr-template.md) for new records. See
[MADR](https://adr.github.io/madr/) and
[architectural decision records](https://adr.github.io/) for background.