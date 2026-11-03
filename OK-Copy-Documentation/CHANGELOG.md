# Changelog and release notes

This chapter separates release history from the current operating specification. Later entries supersede earlier behavior. Dates and build numbers are stated only where available in the retained delivery records. Early milestones are a reconstruction, not a recovered complete version-control history.

## 3.7 — build 13 · October 30, 2026

- Added horizontal spacing around Transfer Queue, Verify Manifest and Activity while retaining distinct accessible toolbar controls.
- Capitalized the new successful destination receipt heading as Verified, with existing green styling.
- Retained the engine and recovery behavior from 3.6 build 12. Historical saved reports retain their original content.
- Recorded 67 XCTest tests and all 113 generated-file checks passing; final GUI sample confirmed the heading and spacing. Package/source/archive checks passed.

## 3.6 — build 12 · October 30, 2026

### Progress, feedback and reports

- Modeled source reads/rereads, destination copying/readback and compatible-publication work in progress and estimates.
- Mapped cascading progress across the working and backup stages. Initial backup ETA extrapolates from the working-drive rate until actual backup measurements exist.
- Added separate recent write/readback speeds and elapsed time; stopped jobs display zero current speed.
- Added explicit missing/unverified rows to copy reports. Verified results use green and failures/unverified results use red, with separate light/dark colors.
- Changed the then-current destination success label to lowercase verified; version 3.7 capitalizes it.
- Replaced the fixed report sheet with a native resizable report window and saved frame/minimum size.
- Added destination paths to history and collapsed full output paths behind a disclosure control.
- Added optional macOS completion/error notifications, subject to permission.
- Improved partial-success counts and named destinations needing attention, including a verified cascading primary.
- Added more specific source/destination removal accessibility labels.

### Recovery

- Added Retry Report Export for eligible frozen pending HTML/JSON receipts, without reading originals or copying media again.
- Recovery validates destination identity, source protection and workspace ownership, takes a job lock, and retires pending metadata after export.
- Extended the recovery fixture to remove its generated source before export, demonstrating source-independent report recovery.
- Manifest-generation failures still require Resume. A recovered receipt still describes the original event, not a fresh verification of current media.

### Qualification

- Recorded 67 XCTest tests and 113 generated checks passing, plus an isolated GUI sample.
- Real reader/drive interruption tests, comprehensive accessibility/appearance testing and notarized distribution remained outstanding.

## 3.6 — build 11 · October 30, 2026

This was the first stabilization pass responding to the final review.

- Corrected direct-layout report URLs and HTML destination paths; reports remain reopenable after queue restoration.
- Restricted Resume to the selected job instead of implicitly starting unrelated queued jobs.
- Cleared restored ETAs and expired stale live estimates.
- Surfaced unrecognized manifest checksum fields and rejected foreign checksum namespaces.
- Centralized version branding for HTML/JSON/MHL and introduced readable project/date transfer report names.
- Published a verified project before issuing its success receipt; distinguished report/export problems from failed file verification.
- Credited existing matching files in overall progress.
- Added report history with Open, Export, Reverify and Finder actions; retained standalone verification HTML where it can be saved outside the verified source.
- Added inline validation, safe layout/report preferences, compact destination paths, copyable output paths and destination reveal actions.
- Added activity-scoped idle-sleep protection and an explicit Pause and Quit flow.
- Added report-storage preflight checks and shared-resource advisories without requiring independent physical drives.
- Avoided optional SHA-1/MD5 computation where not requested.

At this intermediate build, ETA and report-only recovery were less complete than build 12. Do not read its older release-note limitations as the final v3.7 feature specification.

## 3.5 — build 10 · October 29, 2026

- Added live folder diagrams for organized, named-folder and direct-destination layouts, including source labels and configured report/manifest placement.
- Used the three requested layout labels.
- Removed Try Sample Copy from the sidebar while retaining it in the File menu.
- Removed the top read-only shield/lock control; the underlying source-protection policy remained.
- Styled Transfer Queue, Verify Manifest and Activity as matching text controls and corrected accessibility labels.
- This was interface-only work on the 3.4 engine; validation included optimized build, isolated GUI inspection, runtime safety checks and package checks.

## 3.4 — October 29, 2026

- Used the user-supplied self-contained 3.3 app as the development baseline.
- Added three folder layouts, including no-Originals and direct-destination copying, with source-folder separation for multiple sources.
- Added app-local report defaults and custom/destination report placement.
- Added smoothed per-destination remaining-time estimates with warm-up and reuse credits; later releases expanded the work model.
- Changed the subtitle to Verified Copying Tool and introduced the overlapping-pages icon.
- Used text toolbar actions and a clearer optional Review Copy workflow.
- Recorded 64 XCTest tests and 112 generated checks, plus an isolated direct-copy sample with two sources and three destinations.

The exact build identifier is not independently established by the archived materials used here. No public release/tag is implied.

## 3.3 — build 8 · supplied baseline

The installed self-contained app supplied from another machine identified itself as 3.3, build 8. Its package carried the full source. Retained source/documentation established these behaviors:

- Immediate Start Copy with optional Review, rather than mandatory prehash review for each job.
- Source checksum capture during copying with write-once saved references for resume.
- Exact project names instead of automatic date/slug formatting for the visible project folder.
- Narrow macOS housekeeping exclusions.
- Compatible publication for filesystems lacking protected exclusive rename.
- Start Copy running the newly prepared job while older queued jobs remain waiting.
- Optional MHL export off by default in the GUI.
- Self-contained packaging with no Xcode runtime requirement.

The exact implementation dates on that other machine are not reconstructed here.

## Earlier engineering milestones — reconstructed

| Milestone | Retained evidence | Historical significance |
| --- | --- | --- |
| Initial photography ingest / Fieldwork naming | Development discussion and later artifacts | Source-preserving ingest, preview, project organization, working/backup copies, checksums, HTML reporting and sample/dry-run operation |
| OK, Copy / verified ingest naming | Subsequent development record | Generalized wording and recognition that one internal/working destination is valid |
| Queue and recovery work | Legacy source and regression fixtures | Multiple sources/targets, incremental reuse, duplicate-content reporting and saved partial state |
| 2.1 engine exploration | Historical cached comparison tool | Evaluated copying primitives; does not establish current performance or an enabled alternate backend |
| 3.0 coordination upgrade | Preserved engine notes and acceptance checklist | Independent destination queues/failures, cascading, controlled source concurrency, concurrent readback, topology hints, per-drive status and flat MHL support |

No complete authoritative 1.x–3.2 release ledger or source-control tags were provided. Exact dates, build identifiers, feature attribution or public release status for those versions should not be invented. The original retained release notes and validation narrative are included under `evidence/` for traceability.
