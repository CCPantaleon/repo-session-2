# OK, Copy 3.5 — final draft review

Reviewed October 29, 2026. This is an audit, not a new build. The delivered application and its source have not been changed.

## Recommendation

Do one focused stabilization pass before calling this the final draft. Fix the four reproduced defects below, improve the accuracy of status and reports, and qualify the resulting build on disposable data using actual SD/CFexpress readers and destination drives. Additional copy engines and major new features are not required for this pass.

## What was checked

- Delivered bundle: version 3.5, build 10, Apple silicon, macOS 14 minimum. Local signature verification passed.
- Embedded source matches the delivered source. The isolated GUI preview has identical executable content after removing the different signing identities from temporary comparison copies.
- Reran all 64 XCTest tests against the delivered source: zero failures.
- Reran the delivered executable's 16 built-in safety checks: all passed.
- Visually inspected the main interface and queue, and completed an isolated generated-file GUI copy: two sources, three destinations, seven files, all destinations verified.
- Added a separate audit harness outside the delivered source to reproduce gaps not covered by the current tests. Original sample content checksums remained unchanged.
- The application currently in `/Applications/OK, Copy.app` is still version 3.3, build 8. These findings concern the delivered 3.5 build in this outputs folder.

No real camera originals were transferred. Physical disconnects, power loss, large cards, sustained reader speeds, and all supported macOS versions were not tested in this review.

## Four reproduced defects to fix before the final draft

### 1. Direct-destination report paths are wrong

With direct layout and destination-local reports, the copy succeeds and the report is physically saved to `Destination/Ingest Reports`. However, the result returned to the app points to `Destination/ProjectName/Ingest Reports`, which does not exist. This breaks later report opening from the queue. The HTML destination summary also appends a project folder even when direct layout created none.

Evidence: `TargetContext.location` in `Sources/IngestCore/TransferEngine.swift:208`; result report construction in `ManagedTransfer.swift:147`; HTML destination summary in `BatchReport.swift:34`. The audit confirmed matching copied bytes, a real report in the correct directory, and a nonexistent returned report URL.

Fix: use the layout-aware project location consistently for live paths, published paths, reports, and diagnostics. Add integration coverage for every layout × report-location combination, including reopening reports after a queue reload.

### 2. Resume starts unrelated queued jobs

Clicking Resume on one paused job marks it queued and calls Start Queue. An earlier queued job runs before the selected job; other queued jobs can also run afterward. This differs from Start Copy's deliberate behavior of running only the newly selected job.

Evidence: `Sources/OKCopy/AppModel.swift:307`. The audit saved an older unstarted job followed by a paused job, resumed only the second, and observed both complete.

Fix: Resume should run only the chosen job. Keep Start Queue as the explicit action for running the whole queue. Test preceding and following queued jobs, including an unavailable earlier job.

### 3. Paused jobs can retain a live-looking ETA after restart

Queue restoration changes a previously running job's phase to `Paused · recheck on resume` and clears its speed, but retains its saved ETA. The queue formatter recognizes only the exact string `Paused`, so it can display a time remaining for a job that is not running.

Evidence: `Sources/IngestCore/TransferQueue.swift:75` and `Sources/OKCopy/QueueView.swift:85`. The audit restored a running job with a 120-second estimate and confirmed the paused result still contained that estimate.

Fix: clear estimates on restore and gate ETA presentation by job state. Prefer typed phases to matching display strings. Separately, expire estimates during stalls and account for source rereads, cascading stages, and compatible final publication. The current estimate models destination write/readback work, not every stage of the job.

### 4. Manifest verification silently ignores some unrecognized checksum fields

A manifest containing a correct SHA-256 field and an unhandled SHA-512 field passes verification; the unhandled field disappears during parsing. The SHA-256 check is genuinely performed, but the result does not disclose the ignored checksum.

Evidence: `Sources/IngestCore/MediaManifest.swift:114`. The audit used a correct SHA-256 plus an all-zero SHA-512 field and received `passed == true` with only `sha256` listed.

Fix: distinguish known metadata from supported and unsupported checksum fields. Explicitly report unsupported fields and validate XML namespaces. Add mixed supported/unsupported fixtures; retain the existing rejection of unsupported-only manifests and history structures. Do not imply full ASC history validation.

## Status and reporting improvements

1. **Make reports reflect the current app and layout.** JSON and HTML still identify the app as 3.3, while ASC export identifies its tool as 3.0 and says receipts are in Ingest Reports even when they are stored elsewhere. Use one version source and describe the actual report location. Report names should contain a readable project name/date in addition to a unique identifier.
2. **Separate copy integrity, final publication, and report-save results.** The engine currently saves a success-labelled receipt before publishing the project; report/export failures also become general destination failures. Clearly distinguish “files verified,” “publication pending,” and “report could not be saved,” preserve the actual recovery location, and allow retrying report export without confusing it with failed file verification. Fault-injection tests should cover report storage becoming unavailable and publication collisions.
3. **Make progress describe all work.** Existing-file reverification updates destination counters but not the overall work counter, so incremental jobs can appear stalled before jumping to completion. Display copy and verification progress separately, credit reused work consistently, and show finalization explicitly. “Avg I/O” combines writes and readbacks; distinguish current copy speed, verification speed, and total elapsed time.
4. **Show partial success clearly.** Use a summary such as “2 of 3 destinations verified; reconnect Backup.” Keep healthy results visible and provide per-destination reports and reveal actions. Explain that retry currently rechecks healthy destinations as well as retrying the failed one.

## Interface polish

- Keep the new folder previews and text toolbar controls. The interface is coherent at the inspected window size.
- Reduce the right panel's vertical density. With three destinations, folder structure and lower options require substantial scrolling. Compact destination cards, keep the layout preview prominent, and put detailed paths behind expansion/tooltips while retaining accessibility.
- Add plain-language inline validation near invalid project/source labels and missing report-folder choices. Explain why Start Copy is unavailable instead of relying only on a disabled button.
- Hide or explain the source-label field when one-source flat layouts do not use it. Show a representative output path that can be copied.
- Replace or supplement “Show Saved Reports” with a report list showing project, date, destinations, outcome, Open, Export, and Reverify. Currently it simply reveals the app's report directory, and standalone verification results are only displayed in memory.
- Remember safe layout/report preferences. Revalidate any remembered locations; never automatically start old jobs or treat a reconnected drive with the same name as the same device.
- Add a clear completion/failure notification and an explicit “Pause and Quit” flow. The current termination handler cancels work and cancels quitting, without completing the quit automatically.
- Test minimum window size, smaller laptop displays, light mode, increased contrast, keyboard navigation, and VoiceOver. Icon-only remove/reorder actions should have specific spoken labels. The toolbar's explicit accessibility names are already present.

## Reliability and performance work worth doing

- Add an activity-scoped idle-sleep prevention assertion, released on pause/completion/failure. Do not promise to override lid-close or forced sleep. Test suspend/resume and low-disk-space conditions on disposable data.
- Preflight report storage and show shared-physical-device advisories before starting, without making multiple independent drives a requirement.
- Compute optional interoperability hashes only when requested. The ingest readback currently calculates SHA-1 even when MHL export is disabled; standalone verification always computes SHA-1 and MD5 as well as SHA-256. Avoid unnecessary hash work while retaining authoritative ingest SHA-256 verification. Benchmark before claiming a speed improvement.
- Test sustained large-file and many-small-file transfers with the built-in SD reader and Ulanzi DC04, SD and CFexpress A/B, APFS and exFAT destinations, one and multiple destinations, cascading, disconnect/reconnect, and crash recovery. Use generated/disposable data for interruption tests. Existing generated tests cannot establish field reliability or throughput parity with a commercial application.
- Before distributing beyond this development setup, use Developer ID signing/notarization and test the downloaded archive on a clean Mac. The current build is self-contained but locally/ad-hoc signed and Apple-silicon-only.

## Scope to keep clear

This is verified copying of regular file contents. It is not a complete Finder replacement or a whole-Mac backup utility: links are rejected; empty directories, resource forks, Finder tags, and other metadata are not comprehensively preserved. Network destinations are currently rejected. Card-health telemetry and full ASC MHL chain-of-custody support are not implemented. These can remain out of scope for a good final draft if the app explains them accurately.

Do not add another copy engine merely to expand the feature list. First correct the reproduced behavior, make status trustworthy, and measure the current engine on the user's actual hardware.
