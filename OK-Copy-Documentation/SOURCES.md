# Sources and provenance

## Scope and date

This documentation describes **OK, Copy 3.7, build 13**, on the source snapshot accompanying the delivered app. Documentation date and external-source retrieval date: **October 30, 2026, Asia/Dubai**. Vendor web documentation can change independently of this repository; comparisons are document-based, not tests of installed competing applications.

The source snapshot and the development validation record take precedence over old prose descriptions. In particular, historical engine notes describing mandatory prehashing or earlier UI/report behavior do not define v3.7.

## Internal evidence map

| Claim area | Primary local evidence |
| --- | --- |
| Version, OS floor and package dependencies | [Info.plist](source/OK-Copy/Info.plist), [Package.swift](source/OK-Copy/Package.swift), [AppVersion.swift](source/OK-Copy/Sources/IngestCore/AppVersion.swift) |
| Source scope and source protection | [Plan.swift](source/OK-Copy/Sources/IngestCore/Plan.swift), [SafeIO.swift](source/OK-Copy/Sources/IngestCore/SafeIO.swift) |
| Layouts, planning and capacity | [BatchPlan.swift](source/OK-Copy/Sources/IngestCore/BatchPlan.swift) |
| Shipping transfer sequence | [ManagedTransfer.swift](source/OK-Copy/Sources/IngestCore/ManagedTransfer.swift), [TransferEngine.swift](source/OK-Copy/Sources/IngestCore/TransferEngine.swift) |
| Bounded queues | [CopyPipeline.swift](source/OK-Copy/Sources/IngestCore/CopyPipeline.swift), [DestinationPipe.swift](source/OK-Copy/Sources/IngestCore/DestinationPipe.swift) |
| Hardware hints and cascading | [StorageScheduler.swift](source/OK-Copy/Sources/IngestCore/StorageScheduler.swift), [CascadingTransfer.swift](source/OK-Copy/Sources/IngestCore/CascadingTransfer.swift) |
| Immutable references and queue restoration | [SourceChecksums.swift](source/OK-Copy/Sources/IngestCore/SourceChecksums.swift), [TransferQueue.swift](source/OK-Copy/Sources/IngestCore/TransferQueue.swift) |
| Reporting and recovery | [BatchReport.swift](source/OK-Copy/Sources/IngestCore/BatchReport.swift), [CopyReports.swift](source/OK-Copy/Sources/IngestCore/CopyReports.swift), [ReportRecovery.swift](source/OK-Copy/Sources/IngestCore/ReportRecovery.swift) |
| Manifest limits and parser behavior | [MediaManifest.swift](source/OK-Copy/Sources/IngestCore/MediaManifest.swift), [XXH64.swift](source/OK-Copy/Sources/IngestCore/XXH64.swift) |
| UI, history, notification and quit behavior | [AppModel.swift](source/OK-Copy/Sources/OKCopy/AppModel.swift), [OKCopyApp.swift](source/OK-Copy/Sources/OKCopy/OKCopyApp.swift) |
| Progress and ETA | [TransferOptions.swift](source/OK-Copy/Sources/IngestCore/TransferOptions.swift), [QueueView.swift](source/OK-Copy/Sources/OKCopy/QueueView.swift) |
| Validation | [Test directory](source/OK-Copy/Tests/IngestCoreTests/), [generated-check tools](source/OK-Copy/Tools/), [development record](evidence/Development-Validation.md) |
| Historical change evidence | [Original retained release notes](evidence/Original-Release-Notes.md), [pre-3.6 review](evidence/Pre-3.6-Review.md) |

## External primary references

- [Hedge: OffShoot verification](https://docs.hedge.video/offshoot/features/verification) — verification modes and documented history-aware checking.
- [Hedge: Stop & Resume](https://docs.hedge.video/offshoot/features/stop-and-resume) — documented restart behavior for partial files.
- [Hedge: Duplicate Detection](https://docs.hedge.video/offshoot/features/duplicate-detect) — documented criteria for skipping and renaming.
- [OWC: Copy That product page](https://www.owc.com/solutions/copy-that) — published copying, reporting and workflow capabilities.
- [OWC: Copy That support](https://software.owc.com/support/copy-that/) — documented releases and file/workflow capabilities.
- [Apple: Finder drag and drop](https://support.apple.com/en-sg/guide/mac-help/mh35852/mac) — general Finder copy/move interaction.
- [Rsync upstream manual](https://download.samba.org/pub/rsync/rsync.1.html) — transfer verification, pre-transfer comparison and version-sensitive options.
- [Apple: copyfile/fcopyfile manual source](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.3) — native copying API semantics.
- [Apple: CryptoKit incremental SHA-256](https://developer.apple.com/documentation/cryptokit/sha256/init%28%29) — incremental hashing API.
- [xxHash project](https://github.com/Cyan4973/xxHash) — non-cryptographic hash family and implementation reference.
- [ASC MHL specification repository](https://github.com/ascmitc/mhl-specification) — standard scope and history/custody context.
- [ASC MHL reference implementation and schema](https://github.com/ascmitc/mhl) — reference project linked by the standard.

No source supports a claim that this app is faster, more field-reliable or universally more secure than the commercial products. No private competitor engine implementation was reviewed. Product pricing and license comparisons are deliberately omitted because no license grant or purchasing requirement was established for this custom application.

## Artifact identity

The machine-readable [provenance manifest](evidence/provenance.json) records SHA-256 values for every included source-snapshot file and the separately delivered release artifacts. These values identify the inspected files; they are not a developer signature or an authenticity service.

| Artifact | SHA-256 |
| --- | --- |
| v3.7 app executable | `3b5cb639bdba44b1a4b63a77db9a233cc1901afb39ef97e71f9cbfaf4585f51e` |
| v3.7 portable app ZIP | `c72bc2d6d8a5ebc4d578349850ea56365424ecd781b543e1b819d86426b4da23` |
| v3.7 source ZIP | `a693406ab7018e2fc97ef54685a970ff2bf42159cf69e6e2e06e6e0b6f6ed3bc` |

The documentation ZIP includes the source snapshot and documentation, not the executable application. The app and source ZIPs remain separate release deliverables. This writing task did not modify or rebuild the v3.7 application.

## Rebuilding the reader

```bash
python3 tools/build.py
```

The build uses Python's standard library, produces `index.html`, and embeds the local SVG diagrams and CSS. No remote font, script, image service or Mermaid CDN is required to read the generated HTML. Editable Mermaid source is supplied for future diagram revisions; it is not a live runtime dependency.
