# Clipboard protocol v2

This is an implementation-grounded wire reference for KlipAround 1.0.1, not a
claim that every possible input is schema-validated. The implementation is in
[protocol helpers](../Private/KlipAroundProtocol.ps1),
[sender](../Public/Send-KlipAround.ps1), and
[receiver](../Public/Receive-KlipAround.ps1). Architecture and rationale remain
in the [arc42](architecture.md) and [ADRs](decisions/README.md).

## Transport and compatibility

Two concurrently running endpoints take turns replacing and reading a shared
text clipboard. There is no queue, socket, or retained message history.
Clipboard redirection, if needed, is external to KlipAround.

Both endpoints must speak v2. There is no v1 negotiation or fallback, peer
authentication, encryption, or persistent resume state. Use only trusted peers
and a trusted clipboard channel. A session ID filters traffic; it is not an
authorization token.

## Framing and envelope

The publisher emits these three lines, using the platform newline:

```text
-----BEGIN KLIPAROUND/2-----
{"Protocol":"KlipAround/2","SessionId":"example","Role":"Sender","MessageType":"HELLO","MessageId":"c9df74f0-8040-4b79-8126-405220272340","TimestampUtc":"2026-11-20T05:00:00.0000000Z","Payload":{"FileCount":1,"WindowSize":16,"BlockSize":131072,"SenderHost":"example-host","SenderUser":"example-user","StartedUtc":"2026-11-20T05:00:00.0000000Z"}}
-----END KLIPAROUND/2-----
```

The JSON is compact and is **not** itself Base64-encoded. Only block data is
Base64. JSON property order is not significant. The parser normalizes CRLF to
LF, locates the begin marker and the subsequent newline-prefixed end marker,
trims the intervening JSON, parses it, and checks `Protocol`. It tolerates
surrounding text; publishers should emit just the envelope.

| Field | Publisher representation | Meaning |
| --- | --- | --- |
| `Protocol` | String `KlipAround/2` | Wire version, separate from module version. |
| `SessionId` | String; sender defaults to a GUID | Transfer correlation identity. |
| `Role` | `Sender` or `Receiver` | Publishing endpoint's role. |
| `MessageType` | String from the table below | State-machine operation. |
| `MessageId` | New GUID string for each publication | Duplicate and self-message filtering. Retries use new IDs. |
| `TimestampUtc` | UTC round-trip-format string | Diagnostic timestamp; not a replay deadline or ordering guarantee. |
| `Payload` | JSON object | Message-specific data. |

The envelope parser is not a complete schema validator. The transfer commands
read and validate fields as needed; do not depend on malformed inputs being
accepted or on every unexpected field being rejected.

## Message payloads

Indexes and sequence numbers are zero-based. Lengths and block sizes are byte
counts before Base64 encoding. Hashes are hexadecimal strings.

| Message | Role | Fields emitted by 1.0.1 |
| --- | --- | --- |
| `HELLO` | Sender | `FileCount`, `WindowSize`, `BlockSize`, `SenderHost`, `SenderUser`, `StartedUtc`. Host/user fields are descriptive metadata, not trusted identity. |
| `HELLO_ACK` | Receiver | `Accepted: true`, `ReceiverHost`. |
| `FILE_META` | Sender | `FileIndex`, `Name` (basename only), `Length`, `Sha256`, `BlockSize`, `TotalBlocks`, `BlockChecksumAlgorithm`. `Sha256` is null until EOF by default, or populated with `-PrecomputeHash`. |
| `FILE_META_ACK` | Receiver | `FileIndex`, `Accepted: true`. |
| `DATA_BURST` | Sender | `FileIndex`, `StartSeq` (smallest sequence in this burst), `Blocks` array. The receiver uses each block's `Seq`, not `StartSeq`, to place it. |
| `ACK_REPORT` | Receiver | `FileIndex`, `AckNextSeq`, `TotalBlocks`, `MissingSeqs` array. |
| `FILE_EOF` | Sender | `FileIndex`, `Length`, `Sha256` (whole-file SHA-256). |
| `FILE_EOF_ACK` | Receiver | `FileIndex`, `Accepted: true`, sent after file verification and promotion. |
| `FIN` | Sender | `FileCount`, `AckGraceSeconds`. |
| `FIN_ACK` | Receiver | `ReceivedFiles` (number promoted). |
| `ERROR` | Either role in the message constructor | Reserved: current transfer commands do not publish or handle this as an error-exchange mechanism. Errors are reported locally; the peer may time out. |

`Accepted` and count fields are not a general negotiation mechanism. The sender
checks `HELLO_ACK.Accepted` and matching file indexes on file acknowledgments,
but does not validate all other acknowledgment fields. The receiver validates
received file length against `FILE_META.Length`, not `FILE_EOF.Length`, and
uses the hello count for progress rather than enforcing a final count match.
New implementations should send consistent values, not rely on these omissions.

### Data blocks and checksums

| Field | Meaning |
| --- | --- |
| `Seq` | Block sequence within the current file. |
| `Length` | Decoded block byte count, including zero for an empty file. |
| `ChecksumAlgorithm` | `SHA256` or `CRC32C`. Public sender default: `SHA256`. |
| `Checksum` | Checksum of the decoded bytes. |
| `Data` | Standard Base64 encoding of those bytes. |

SHA-256 is emitted as 64 uppercase hexadecimal characters. CRC32C is the
Castagnoli CRC with reflected polynomial `82F63B78`, initial value `FFFFFFFF`,
and final complement, emitted as eight uppercase hexadecimal characters.
The ASCII bytes of `123456789` produce CRC32C `E3069283`; empty bytes produce
`00000000`. See [hashing helpers](../Private/Hashing.ps1) and
[test vectors](../Tests/KlipAround.Tests.ps1).

For compatibility within v2, the receiver defaults missing file-level
`BlockChecksumAlgorithm` to `CRC32C`. The block decoder uses
`ChecksumAlgorithm` when supplied, otherwise infers `SHA256` if a `Sha256`
property exists, otherwise defaults to `CRC32C`. A block `Sha256` property
takes precedence over `Checksum` in SHA-256 mode. The decoder requires its
algorithm to match the file-level expectation. New publishers should emit
explicit algorithm and checksum fields.

The decoder validates Base64, decoded length, and checksum. A failed block
decode becomes a missing sequence request rather than immediate file acceptance.
The whole file is always checked with SHA-256, regardless of block algorithm.

The public sender accepts block sizes from 4096 through 1048576 bytes and
windows from 1 through 64 blocks. A burst includes Base64 expansion plus JSON
and framing overhead; these parameter limits are not clipboard capacity
guarantees.

## Transfer states

1. **Session start:** sender republishes `HELLO` until `HELLO_ACK`. A receiver
   without an explicit session ID binds to the first parsed sender `HELLO`;
   with one specified, it waits for a matching session.
2. **File start:** for each file, sender publishes `FILE_META` and waits for
   `FILE_META_ACK`. Receiver validates the basename, checks overwrite policy,
   opens a unique partial file with `CreateNew`, then acknowledges.
3. **Data:** sender publishes up to `WindowSize` blocks in one `DATA_BURST`,
   then waits for `ACK_REPORT`. Receiver buffers valid out-of-order blocks,
   writes and hashes contiguous blocks, then acknowledges cumulative progress.
4. **File completion:** when all blocks are acknowledged, sender publishes
   `FILE_EOF`. Receiver compares metadata/EOF hashes when both exist, requires
   an expected hash, checks the staged file's length and streamed SHA-256,
   promotes it, and publishes `FILE_EOF_ACK`.
5. **Session completion:** after all files, sender publishes `FIN`; receiver
   publishes `FIN_ACK` and waits briefly to answer retried completion messages.

Files are sequential, not interleaved. The sender emits
`TotalBlocks = max(1, ceil(Length / BlockSize))`. An empty file therefore has
one zero-length block, with `Seq: 0` and `Data: ""`.

### Acknowledgment semantics

`AckNextSeq` is the next sequence needed to extend the contiguous prefix.
All lower sequences have been written. `AckNextSeq == TotalBlocks` means all
blocks are written, **not** that the file has passed final verification.

`MissingSeqs` lists holes or rejected blocks observed in a burst; it is not
necessarily every unsent block. For example, with sequences 0 and 2 received
and sequence 1 missing, the receiver replies with `AckNextSeq: 1` and
`MissingSeqs: [1]`, retaining block 2.

The sender filters missing sequences to the interval from `AckNextSeq`
through `TotalBlocks - 1`, sorts and deduplicates them, and prioritizes those
retransmissions over new blocks. It caches unacknowledged blocks and drops
cache entries below cumulative progress. Retries do not hash the same source
block again.

## Timing, retries, and duplicates

These are current implementation rules, not a guaranteed wall-clock transfer
deadline. Let `T` be a command's `TimeoutSeconds`, and `R` the sender's
`MaxRetries`. Endpoints have independent timeout settings.

| Phase | Current rule |
| --- | --- |
| `HELLO`, `FILE_META`, `FILE_EOF` acknowledgments | Sender uses an elapsed-time budget of `T` per phase and waits at most 10 seconds per attempt, bounded by the remaining budget. These loops are not capped by `R`. |
| Burst acknowledgment | At most `R + 1` publications of the same burst payload, each with a fresh message ID; each wait uses `max(1, floor(T / 2))` seconds. |
| Repeated acknowledgment without progress | Sender tracks the signature of cumulative progress plus missing sequences and fails when the repeated-signature counter exceeds `R`. |
| Receiver data and EOF waits | Uses `min(3600, T + 1)` seconds per wait; other main waits use `T`. |
| `FIN` acknowledgment | Sender retries at intervals of at most `min(2, T)` seconds, bounded by both its elapsed `T` budget and `R + 1` publications. |
| Completion grace | Sender advertises `min(T, (R + 1) * min(2, T)) + 2` seconds. Receiver accepts an advertised integer from 3 through 3600, otherwise throws. If omitted, it uses `min(3600, T + 2)`. Follow-up waits are two seconds each and may extend past the grace boundary. During these FIN-grace follow-up waits, the receiver uses polling-only message waits to avoid listener no-signal fallback noise. |

Clipboard operations and scheduling add time. Linux subprocess operations are
bounded; a read started near a message deadline can finish up to one polling
interval later. Windows clipboard commands do not provide the same
subprocess timeout enforcement.

The wait helper ignores unchanged clipboard text, its own sent message IDs,
already-consumed IDs, and messages with the wrong session, role, or expected
type. Malformed envelopes are skipped while waiting. Recognized fatal Linux
clipboard errors propagate rather than being silently replaced by local data.

New IDs allow semantic retries to reach the receiver. Depending on its state,
the receiver re-acknowledges `HELLO`, repeated metadata, already-written blocks,
the final burst while awaiting EOF, EOF for a completed file, and `FIN` during
the completion grace period. This is not a general replay service after the
commands exit or after the grace period expires.

## Failures and filesystem effects

* Unsafe names, unauthorized overwrite, or filesystem errors stop the receiver.
  Directory components and rooted names are rejected before metadata acceptance.
* A failed length/hash check leaves an existing destination unchanged.
  `-Force` permits replacement only after verification, not bypassing it.
* The receiver disposes file handles and attempts to remove its own unpromoted
  partial on failure. Cleanup failure produces a warning; abrupt process
  termination may prevent cleanup.
* Completed files remain if a later file or final acknowledgment fails.
  Missing `FILE_EOF_ACK` or `FIN_ACK` does not prove that no file was received.
* Neither timestamps nor checksums protect against a malicious clipboard
  participant. The receiver's first-hello binding is not peer authentication.
