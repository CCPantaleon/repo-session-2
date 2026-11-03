# OK, Copy 3.7 — build 13 validation

October 30, 2026, Asia/Dubai.

- 67 XCTest tests passed, zero failures. All 113 generated safety/workflow/filesystem/immediate-copy checks passed.
- Optimized release built successfully. Visual GUI inspection confirmed gaps between the three toolbar buttons; separate accessibility names remain correct.
- A fresh isolated sample verified seven files at three destinations. Opening its report confirmed the heading **Verified** with capital V.
- This release only changes toolbar spacing, the successful receipt label and release version metadata. Earlier hardware/notarization qualification limitations still apply.

---

# OK, Copy 3.6 build 12 validation

October 30, 2026, Asia/Dubai.

- 67 XCTest tests passed, zero failures; 113 generated safety/workflow/filesystem/immediate-copy checks passed.
- Export recovery is tested with its source removed: the pending receipt exports successfully without an original card and a second retry is a no-op.
- Measured progress now includes source reads/rereads, per-destination copying/readback, and compatible publication work. Cascading progress is mapped across primary/backup stages. Pending backup ETA uses the working-copy rate until measured backup rates are available; this is an explicit approximation, not a benchmarked guarantee.
- Live speed fields track recent write/readback samples; elapsed time is recorded and displayed. Restored/paused jobs do not display live ETAs.
- Isolated GUI generated-file sample: two sources, three destinations, seven files, all verified. Report heading is verified with a green tint; native report window has resizable style and minimum-size/frame restoration. A later contrast-only CSS adjustment and partial-success wording were rebuilt after the full checks.
- No real originals modified. Real reader, unplug/power-loss, large transfer and full manual accessibility/appearance qualification are not complete.
- No valid codesigning identity found. Developer ID/notarization and clean-Mac distribution qualification remain outstanding. Installed Applications app unchanged.

Earlier records below describe historical builds and are superseded by this entry where implementation differs.

---

# OK, Copy 3.6 validation

October 30, 2026, Asia/Dubai. Build 11.

- 67 XCTest tests passed, zero failures. New regression coverage checks direct-destination report URLs after queue reload, paused ETA clearing, mixed supported/unknown manifest checksums, report storage disappearing during a copy, and retry preserving/reusing the published verified files.
- 113 generated checks passed: 16 runtime safety, 26 app workflow, 32 publication/filesystem, 39 immediate-copy. The workflow explicitly checks that Resume leaves unrelated queued jobs unstarted.
- Optimized self-contained build completed. Final toolbar-only changes were rebuilt afterward.
- Isolated GUI copy completed seven generated files from two sources to three destinations. Separate copy/verification progress, destination reveal actions and saved report history were inspected.
- No real originals were transferred. Hardware interruption, forced sleep, sustained throughput, physical-reader ETA accuracy, and clean-Mac qualification remain outstanding.
- Estimates explicitly cover destination I/O. Full phase-aware end-to-end ETA, separate instantaneous read/write speed displays, and export-only retry remain follow-up work; Resume retries exports after reverifying existing files. Typed phase migration and comprehensive accessibility/appearance coverage are also not complete.
- The app remains Apple-silicon-only and locally signed. Developer ID signing/notarization requires owner credentials. The installed Applications copy was not replaced.

Previous validation follows for history.

---

# OK, Copy 3.5 interface validation

The release compiled successfully. Isolated GUI inspection confirmed:

- Live organized, Into Folder and direct-destination trees; actual source labels and folder names are shown.
- Single-source Into Folder shows files immediately beneath the named folder; multiple sources retain their source folders.
- Exact requested menu labels are present; report/manifest rows follow the configured options.
- Try Sample Copy is absent from the sidebar and available in File.
- The top read-only shield is absent.
- Three matching bordered toolbar buttons display Transfer Queue, Verify Manifest and Activity, with correct accessibility names. Activity opens the expected panel.
- The preview passed all sixteen automatic startup safety checks.

This release changes interface code only. The copy engine retains the 3.4 validation below. No new real-media transfers were performed. The signed release and both ZIP archives are verified after packaging.

---

# OK, Copy 3.4 validation

Based on the user-supplied installed 3.3 app and its embedded source. Validated October 29, 2026, Asia/Dubai.

- 64 XCTest tests passed, zero failures. Includes five new layout/report/ETA tests. An inherited HTML-escaping test was updated to use a valid exact folder name; slash-containing names are separately checked for rejection, preserving the 3.3 naming rules.
- 112 generated-file checks passed: 16 startup safety, 25 app-model workflow, 32 filesystem/publication, 39 immediate-copy checks.
- New tests cover no-Originals layouts, direct destination publication, source-label separation, unchanged conflict data, external report placement/source-overlap rejection, direct-root cascading/resume without the original source, and ETA warm-up/rate adjustment/clock reset.
- UI preview used a separate bundle ID and temporary queue. It completed an immediate copy with two generated sources and three destinations, direct destination layout, manifests off and app-local reports. Filesystem inspection confirmed source folders and hidden .OKCopy metadata at destination roots, without Originals or Ingest Reports. The app archive successfully saved reports in Application Support.
- Toolbar text buttons, Verified Copying Tool subtitle and selectable layout/report controls were visually checked. The app icon uses overlapping pages on the existing purple background.
- Both release ZIPs passed archive verification; the app passed local signature verification. Runtime dependencies are macOS system frameworks/libraries; no Xcode is needed to run. Full source and notes are embedded in Resources/Development.

ETA is an approximation from smoothed measured copy/readback I/O, with warm-up and reuse credits. Final publication, source rereads, cascading stages, OS stalls and changing shared-device throughput can extend it. No whole-queue ETA is invented for unstarted jobs. Physical reader ETA accuracy and throughput have not been benchmarked.

Only generated data was transferred. No camera originals were imported, formatted, deleted, or changed. Real-card hot unplug, power loss, and very large transfer qualification remain outstanding. The app is locally signed, not Developer ID notarized. Earlier sample reports in this folder are historical version-3.0 examples; the current source/docs/app are 3.4.
