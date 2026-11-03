# OK, Copy 3.7

Verified Copying Tool. Self-contained Apple silicon app for macOS 14+. See Release Notes.md for this stabilization release, implemented changes and remaining hardware qualification.

# Version 3.5 interface update

Folder layout now has a live tree preview using your folder name, source labels, source count, report storage and optional manifest settings. Layout names are **Organized: Originals > Source Folders**, **Into Folder**, and **Directly into destination folder**.

**Try Sample Copy** is available from the macOS **File** menu; its sidebar button was removed. The informational read-only shield was removed from the top toolbar. Transfer Queue, Verify Manifest and Activity use matching bordered buttons. Source protection and the copy engine are unchanged.

---

# Version 3.4 update

The app remains self-contained for Apple silicon, macOS 14+. Xcode is needed only to build or modify it.

- Branding: **Verified Copying Tool**, with overlapping-page icon and text toolbar buttons.
- **Folder layout** chooses organized (`Name/Originals/Source/...`), named folder without Originals (`Name/...` for one source), or direct destination (`Destination/...` for one source). Multiple sources keep label folders to prevent collisions. Conflicts are preserved, never overwritten. Recovery metadata stays in hidden `.OKCopy` folders.
- **Reports** defaults to app storage (`~/Library/Application Support/OKCopy/Reports`). Choose a custom report folder (Desktop/Documents supported) or destination reports before reviewing/starting. Saved reports remain accessible through queue history. MHL exports remain a separate optional setting.
- **Time remaining** estimates the current job and each destination from a smoothed measured I/O rate after warm-up, including copy and readback work, with credits for verified prefixes/existing copies. It is approximate: source rereads, final publication, shared devices, cascading and stalls can extend completion. Future queued jobs are not guessed before measurement. Completed/paused/failed states take precedence over estimates.
- **Review Copy** is optional and adds an upfront hash/read pass. **Start Copy** captures source hashes during copying and still rereads/verifies destinations and source content.
- **Verify Manifest** is read-only re-verification of existing copied files against a checksum manifest or receipt; no copy is required.
- **Try Sample Copy** is an optional practice workflow using generated data. Automatic startup safety checks still run independently.
- **Sources read-only** describes this app's source access, not a hardware or system-wide write lock.

Old queued jobs keep their recorded layout/report policy. New layout/report choices apply to new jobs and invalidate any prior review. Reports are stored outside the app bundle so app updates preserve them.

---

# OK, Copy 3.3 — Copy & Verify

Native macOS 14+ utility for verified folder and drive copying, with SHA-256 verification, multiple sources/destinations, persistent queues, verified resume, incremental copies, duplicate detection, and optional camera manifests. The supplied app runs on Apple silicon. Source can also be built on Intel with Swift command-line tools.

## Copy folders and drives

Choose **Add Folders…** under **From**, then **Add Destination…** under **To**. Source and destination folders may be on your Mac or connected storage. Internal SSD to external SSD, external SSD to internal storage, and separate external drives are supported. Each copy is read back and verified with SHA-256.

The top-level folder uses exactly the text you enter, including spaces and punctuation supported by macOS. No date prefix or automatic hyphen substitution is added. Invalid names are rejected with an explanation instead of rewritten. Inside it, files are organized as `Originals/<source-label>/…`, with reports alongside. The **Folder layout** preview shows the result before copying.

Two non-overlapping folders on internal storage can be used. A selected source on external storage protects its entire volume, so copying between folders on the same external volume remains blocked. Source and destination paths must not contain one another.

Only regular file contents are copied. Original relative paths and modification times are preserved; empty directories, resource forks, extended attributes, Finder tags, original permissions and creation times are not copied. Symbolic links and special files stop the scan.

## Start copying; review is optional

1. Select source folders, destination folders, and the exact copy name.
2. Choose **Start Copy** to begin after brief path and space checks, or **Add to Queue** to save it for later. Startup safety checks must have passed.
3. The immediate path reads file metadata during planning, then hashes source data as it is copied. Each completed source hash is saved as a write-once reference in the job workspace before files are published. Every destination is read back and verified; source content is rechecked too.
4. Optionally, choose **Review Copy** first for a complete source hash and existing-destination conflict preview without creating destination files. Starting after a review uses that reviewed plan.
5. Watch each destination in **Transfer Queue**. Completion requires verification, not just a full progress bar.

Changing inputs invalidates the previous plan. You can start again directly or run another optional review. Filtering changes the visible list only, not which files are copied.

**Skip verified matching files** rehashes existing files and skips only matches. Without a review, conflicts are detected as each file is reached; earlier files may already have copied. Conflicting data is preserved, never overwritten. Starting one copy does not start older queued jobs.

The interface, icon, and reports use purple accents.

## Optional settings

**Camera options** contains **Export MHL + ASC MHL**, off by default. Enabling it adds legacy MHL and flat ASC MHL manifests. SHA-256 verification and HTML/JSON reports are always included.

**Advanced options** contains cascading and concurrent-source settings. With cascading enabled, destination 1 is the working copy; remaining destinations read from it only after verification. Replace or remove/re-add destinations to choose the first destination. Sources sharing detected storage are grouped even when concurrency is set higher.

## Start with samples

Choose **Try Sample Copy** to generate two source folders and three temporary destinations. Choose **Start Copy**, or use **Review Copy** first if you want a preview. Sample jobs are restricted to generated storage. Sixteen generated-file safety checks must pass before any queue can run.

Queue execution is explicit and never starts automatically on launch.

## Direct copying and failure isolation

The source copy pass reads each chunk once and distributes it to an independent writer for each destination. Each writer has a queue capped at two 8 MiB chunks, plus active buffers. Writers can absorb short stalls independently. Sustained slowness eventually applies backpressure; unlimited run-ahead would require unlimited memory or additional storage.

Sources on independent detected storage can run concurrently, up to the selected limit. Destination readback uses up to four workers per active source file. Shared storage locks serialize writes and readback that would contend on the same discovered resources.

A failed/missing destination is isolated. Healthy destinations continue copying and verifying, then publish their own completed project. The overall job remains **Failed** until every requested destination succeeds. Later queued jobs wait for attention. Use **Resume** after reconnecting the original devices; healthy existing files are rehashed and skipped, and failed copies are retried from validated partial prefixes. A source integrity failure prevents the overall project from being declared complete.

## Cascading

Cascading first copies and verifies all selected originals to destination 1. Only then do backups read from that working copy. Its identity, inventory and SHA-256 are checked again before it becomes the backup source. The saved source SHA-256 remains the reference throughout.

**Working copy verified · backups pending** means the card is no longer needed by this job's backup stage. It does not mean all requested backups exist, and it is not a statement that deleting the card is safe. The app never deletes or ejects it automatically. **All selected copies verified** appears only when every requested destination has finished verification and publication.

After the working stage is complete, a cascading job can resume with the original card absent. The original working destination must be present and match its saved identity and all expected hashes. A changed or missing working file stops the cascade. A saved ready marker alone is never treated as proof of integrity. Incremental cascades copy only this job's selected originals and preserve older files already in the project.

## Progress, pause and recovery

The queue shows each destination's phase, written bytes, read-back bytes, average I/O rate, discovered storage grouping and errors. Counters describe the current attempt. Read-back bytes may exceed the source size when an additional verification pass is required. Average I/O includes writes plus verification reads; it is not a benchmark of raw card speed. A full progress bar alone does not indicate success—read the destination and job status.

**Pause Queue** requests cancellation at a safe read/write boundary. Outstanding OS disk calls must return before pausing can finish. Verified originals and partial files are retained. Quitting during work requests a pause; quit again after it finishes.

Queue data lives in `~/Library/Application Support/OKCopy/Queue`. Plans are immutable, per-file streamed checksum references are saved before publication, and queue metadata is saved atomically, and per-destination state is persisted. Jobs interrupted by app exit restore as paused, never running automatically. **Forget** removes the queue entry only; copied data remains.

Resume trusts actual disk contents, not saved offsets or completed flags. It hashes partial prefixes against the source before appending, independently rehashes existing files, and retains invalid partials under `.rejected-…` names before restarting them. Sources that differ from their recorded metadata or saved checksum require a new plan. Source-card files are never changed.

## Hardware scheduling

Read-only Disk Arbitration and IOKit discovery groups filesystems, whole disks/containers, physical block-storage ancestors and USB-device/hub ancestry when macOS exposes them. Shared groups limit concurrent work. Discovery is best effort: opaque RAID, virtual/network storage, multiple containers, and some bridges may conceal physical relationships. Unavailable details fall back to filesystem grouping. This is not a complete bandwidth map, a card-health assessment, or a promise to saturate a particular reader.

## Reports and manifests

On volumes supporting protected renames, new projects start in a hidden `.OKCopy.incomplete-…` staging folder and appear under the exact requested name after verification. On volumes without that operation, including the connected exFAT drives, the exact named folder is created immediately with an incomplete marker in the hidden job workspace. Each final file is created exclusively, copied from the verified staging file, and rehashed before the staging file is retired. This additional write/read costs time and temporary free space; the plan checks capacity for the extra active files. A journal supports resuming an interrupted final publication, but never permits overwriting an unowned existing file. Completion is determined by the app and reports, not by the presence of the named folder. Incremental projects receive individually verified new files as work progresses; an incomplete job can therefore have some valid new files already present. Each attempt writes a uniquely named HTML/JSON receipt where possible. Completed cascading jobs also write an overall HTML receipt to every selected destination.

```text
Your exact folder name/
  Originals/CARD-A/...
  Originals/CARD-B/...
  Ingest Reports/[attempt].html
  Ingest Reports/[attempt].json
  OKCopy-[id]-legacy.mhl
  OKCopy-[id]-asc.mhl
  .OKCopy/Jobs/[job-id]/...
```

The two root-level MHL files list this job's verified original paths relative to the project root. The legacy file uses MHL 1.1; the modern file is a **flat ASC MHL 2.0 manifest**, validated against the official ASC XSD. The exporter does not create or modify an `ascmhl` history chain, directory hashes, nested histories or digital signatures, and it does not claim a chain of custody. Existing third-party manifests are never modified. Compatibility with every commercial application has not been qualified.

## Standalone verification

Choose **Verify Manifest…**, select an MHL file or an OK, Copy SHA-256 JSON receipt, then select the folder from which its paths resolve (normally the project root). Verification is read-only and shows a report in the app.

Supported comparisons: SHA-256, SHA-1, MD5 and seed-zero canonical XXH64 (including the `xxhash64be` spelling used in legacy media manifests). Unsupported algorithms such as C4 and XXH3/XXH128 are explicitly reported as unsupported and never counted as a successful full verification. Directory hashes, root hashes and history references require a history-aware tool and are rejected with an explanation. Unsafe paths, symlinks, duplicate file entries, DTD/entity declarations and malformed supported hashes are rejected. UTF-8 manifest size is limited to 128 MiB.

The verifier checks listed data forks. It does not certify unlisted files, media decodability, provenance, signatures or remaining card lifespan. SHA-256 ingest receipts remain available for stronger collision resistance than legacy compatibility algorithms.

## Safety and scope

Regular source files—including ordinary hidden files, video, sidecars and empty files—are included. Known macOS housekeeping is excluded: `.DS_Store` at any depth, and `.fseventsd`, `.Spotlight-V100`, `.Trashes`, `.TemporaryItems`, and `.DocumentRevisions-V100` at the selected source root. The source list, activity log, and review report disclose exclusions. Other hidden files, including `.env`, `.git`, and `._` sidecars, remain included. Original relative paths and modification times are preserved. Identical content at different paths is detected and recorded, but every path is retained. Duplicate detection is scoped to selected sources and intended destination paths, not a whole-drive cleanup tool.

Source files are opened read-only. Source links/special files are rejected. Destination traversal is anchored to directory descriptors, rejects symlinks, and uses exclusive creation/publication. Selected removable/external camera volumes are wholly protected even when a subfolder was selected. App-owned partial workspaces use ownership markers and process locks. No source deletion, repair, format or sanitization functionality exists.

Checksums cover data forks. Resource forks, extended attributes, Finder tags, empty directories, original permissions and creation times are not copied. No APFS clones or hard links are used as independent backups. OS caches can serve rereads; flushed writes and matching readback hashes cannot guarantee future physical-media durability.

## Build and tests

```sh
./build-app.sh
"../OK, Copy.app/Contents/MacOS/OKCopy" --self-test
```

No external packages/network access are needed to build. The XCTest suite requires full Xcode. With only Command Line Tools installed, use `OKCOPY_SKIP_TESTS=1 bash build-app.sh`; the sixteen built-in safety checks, twenty-four copy-workflow checks, thirty-two filesystem checks, and thirty-nine immediate-copy checks still run, but the XCTest suite is skipped. `OKCOPY_BUILD_DIR` can redirect caches/build intermediates. The script tests, builds, generates the icon, locally signs, verifies the signature, and runs sixteen safety checks, twenty-four copy-workflow checks, thirty-two filesystem checks, and thirty-nine immediate-copy checks. The app is locally signed, not Developer ID signed or notarized for public distribution.

See `../Release Notes.md` for this UI update and validation. Actual 500GB shoots, physical reader/drive hot unplug, power loss and throughput on your SD/CFexpress hardware remain hardware qualification work. The tests and GUI validation use generated data only.

## Upgrading from 3.0 or 3.1

Saved jobs keep their original immutable names and plans. For a failed old job containing macOS housekeeping, select the source again and create a newly reviewed copy. The old incomplete folders are preserved; this update does not delete them. A legacy staging folder on a volume without exclusive rename support requires a newly reviewed job.

The filesystem regression checks exercise compatible publication, interruption and resume, existing-file and symlink protection, replaced-file rejection, exact names, and narrow metadata exclusions using generated local files. Physical-drive tests require separate permission and are not implied by these checks.

## Portable app

The portable release contains one OK, Copy.app, including its executable, icon, full source, and documentation. It runs on Apple silicon Macs with macOS 14 or later using macOS system frameworks; no Xcode, Swift installation, or package manager is needed to run it. Source is inside Contents/Resources/Development/OK-Copy. Copy the source outside the app before editing or rebuilding, since editing a signed bundle invalidates its signature. Developer tools are needed only to modify the source.

Immediate-copy jobs use plan format 3; reviewed and legacy jobs retain format 2. Use v3.3 or later to run immediate-copy jobs. The app's runtime queue remains user data in Application Support and is not part of the portable bundle.
