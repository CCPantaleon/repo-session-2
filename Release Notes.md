# OK, Copy 3.7 — build 13

October 30, 2026.

- Added horizontal spacing around each top toolbar button, preserving separate accessible controls.
- New successful destination reports display **Verified**, retaining the green result styling.
- Retains the transfer engine and recovery behavior from 3.6 build 12. Earlier saved reports retain their original contents.

---

# OK, Copy 3.6 — build 12 follow-up

October 30, 2026. Includes the earlier stabilization work below plus:

- Successful destination receipts now say **verified**. Verified result cells use green; failed/unverified cells and unsuccessful verification summaries use red. Dark and light report colors are defined separately.
- Missing destination receipts are explicitly listed as Not verified rather than silently omitted from the table.
- Reports open in an independent native, resizable window, with a minimum size and remembered frame.
- Overall progress accounts for source reads/rereads and publication work, including reused copies. Cascading progress advances across stages rather than resetting.
- Remaining-time estimates model source reads, copy/readback and compatible final publication. Before backups have measured speeds, cascading estimates use the working-drive throughput and conservative sequential backup work. These remain approximations, particularly on shared devices or stalled hardware; metadata/report finalization has no promised countdown.
- Separate recent copy and verification speeds plus elapsed time are displayed; stopped jobs show zero current speed.
- Report history includes destination paths. Output paths can be expanded on demand to reduce inspector crowding.
- **Retry Report Export** exports frozen pending HTML/JSON receipts without reading the original card or recopying media. Recovery takes the job lock, validates destination identity/source protection, and removes its pending marker only after export. It records the original verification event; use Reverify to certify the files' current state. Manifest-generation failures still require Resume.
- Completion notifications can be enabled explicitly, subject to macOS notification permission. Dock attention remains available.
- Partial-success details include verified destination counts and names requiring attention. Cascading includes its verified working copy in that count.
- Additional accessibility labels identify individual source/destination removal actions.

Validation: 67 XCTest tests and 113 generated checks passed. The report-recovery test deletes its generated source before retrying export, demonstrating that export-only recovery does not require the original. A new isolated GUI sample verified two generated sources at three destinations and displayed the revised green verified report in its native window.

Outstanding qualification: comprehensive manual VoiceOver, keyboard-only, contrast/light-mode and smaller-display coverage; large sustained real SD/CFexpress/APFS/exFAT transfers, physical disconnect/reconnect and forced sleep/power loss; clean-Mac distribution testing. No valid signing identity is available on this machine, so Developer ID signing and notarization could not be performed. No suitable connected camera media was available for hardware qualification. The app remains locally signed and Apple-silicon-only.

Existing historical reports retain their saved contents. Newly generated reports use the new formatting. The installed Applications copy has not been replaced.

---

# OK, Copy 3.6 — stabilization draft

October 30, 2026 · build 11 · Apple silicon · macOS 14+

- Correct direct-destination report URLs, HTML paths and report reopening after queue restoration.
- Resume runs only the selected job; Start Queue runs the queue.
- Clear restored estimates and expire stale live estimates. Show separate copy/readback progress; label destination I/O estimates explicitly.
- Surface unsupported manifest fields and reject foreign checksum namespaces. Retain SHA-256 verification and flat-manifest scope.
- Use a shared app version for HTML/JSON/MHL branding; readable project/date report names.
- Publish the verified project before issuing a success receipt. Distinguish verified data with report/export errors and retain retry information.
- Credit existing matching files in overall progress.
- Add report history with Open, Export, Reverify and Finder actions. Persist standalone verification HTML when outside the verified source.
- Validate source labels, names and missing choices inline. Remember safe layout/report preferences, with custom report folders requiring selection again.
- Compact destination paths, add copyable output paths and destination reveal actions. Explain unused source labels in flat layouts.
- Add active-work idle-sleep protection, attention requests for completion/errors, and Pause and Quit with deferred termination after work stops.
- Preflight report capacity/writability and advise about destinations sharing detected hardware without requiring multiple drives.
- Avoid optional SHA-1/MD5 calculation where not requested. No measured performance claim.

Remaining qualification: real SD/CFexpress readers, APFS/exFAT hardware, forced sleep/power loss, sustained large transfers, all supported macOS versions, complete VoiceOver/light/contrast/small-display validation, and a clean-Mac install. Developer ID/notarization requires the owner's signing credentials; this deliverable remains locally signed and self-contained.

Estimates cover destination I/O rather than a guarantee of total remaining job time. Source rereads and compatible publication add work. Report export errors are recoverable by Resume, which independently rechecks existing copies before retrying exports. There is no separate export-only recovery engine or full ASC chain-of-custody support. Report history discovers app-local reports and reports referenced by saved jobs. Attention requests use the Dock rather than requiring notification permission.
