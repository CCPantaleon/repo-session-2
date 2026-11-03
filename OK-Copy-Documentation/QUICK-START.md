# Beginner's quick start

This guide uses the controls in OK, Copy 3.7. Start with generated samples so you can learn the interface before selecting a real card.

## 1. Prepare the Mac and folders

Use an Apple silicon Mac running macOS 14 or later. The packaged app runs without Xcode or a separately installed Swift toolchain. Quit an older copy before launching the new build. The development release is locally signed and is not notarized; if deployment is blocked, obtain a trusted distribution build from the maintainer rather than disabling system-wide security.

For a real transfer, connect your reader and intended destinations. Create destination folders in Finder first if needed: the destination picker selects existing folders. One destination on the internal SSD is supported. A second independent drive gives a different kind of protection from a second folder on the same drive.

Close applications that might still be recording into or editing the selected source. OK, Copy protects its own source access; it does not prevent another application or the operating system from using a mounted card.

## 2. Try a harmless sample

1. Launch OK, Copy and wait for Safety checks passed.
2. Choose File > Try Sample Copy. This generates sample files and temporary destination folders; it does not use your selected camera originals.
3. Inspect the two sample sources on the left and the destinations on the right.
4. Read the folder diagram to see what will be created. If preferences restored another layout, select Organized: Originals > Source Folders for this exercise.
5. Choose Review Copy if you want to inspect a dry-run report first. It is optional.
6. Choose Start Copy. The Transfer Queue opens and shows each destination's copy and verification progress.
7. Wait for Completed and Verified results, then open Report.

New successful destination reports display Verified in green. Missing/unverified results and failures appear in red with text explaining the condition. The report opens in its own resizable window.

A sample safety check and Try Sample Copy serve different purposes. The automatic safety check tests generated fixtures before enabling normal copying. Try Sample Copy is an interactive demonstration that lets you learn the same controls used for actual jobs.

## 3. Select real sources

Choose Add Folders… on the left, or select a detected external volume under Connected Drives. You can select several source folders. An external volume with a DCIM folder is labeled as a detected camera folder; that is a folder heuristic, not proof of the device model or health.

Adding your own source after the sample replaces the sample selections. Check the source path, file count and total size. Expand File preview for a thumbnail where Quick Look supports it. Use the source list to switch between sources.

**Filter files only filters the displayed list. It does not exclude files from the job.** The app copies the selected folders' included regular files. Select a narrower source folder if you need a narrower operation.

A source label identifies the source's output folder when that layout uses one. Labels must be unique and valid formatted identifiers. If a source name contains spaces, the proposed label may use hyphens. For one-source flat layouts the label is unused in the visible mapping, although the planner still validates it.

## 4. Choose destinations and layout

Choose Add Destination… and select one or more existing folders. Read the actual paths, not just volume names. The app allows an internal destination, a working SSD, or several local destinations. It rejects destinations that overlap a protected source or one another. A selected external source volume is protected as a whole; another folder on that same volume is not a valid destination.

| Folder layout | One-source result | Multi-source result |
| --- | --- | --- |
| Organized: Originals > Source Folders | `Destination/Project/Originals/CARD-A/files` | A labeled source folder for each source beneath Originals |
| Into Folder | `Destination/Project/files` | `Destination/Project/CARD-A/files` and separate source folders |
| Directly into destination folder | `Destination/files` | `Destination/CARD-A/files` and separate source folders |

For layouts with a project folder, enter the exact folder name you want. No automatic date prefix is added. Slashes, colons, control characters, dot-only names, and names exceeding 255 UTF-8 bytes are rejected. The diagram follows the selected layout and report/manifest options. Expand Output paths if you want to copy the intended root paths as text.

The same structure is used at every selected destination. A folder's appearance in Finder does not mean verification has finished; some layouts/filesystems make final paths visible while the job is still running.

## 5. Choose where reports go

| Reports option | Behavior |
| --- | --- |
| Keep in app | Default for new GUI jobs; HTML/JSON are stored under the user's Application Support folder |
| Selected report folder | Choose Desktop, Documents or another existing folder for report files |
| Destination folders | Store HTML/JSON in Ingest Reports under each mapped project/destination root |

Report placement does not change where media files go. A custom report folder must be selected again after relaunch; the app remembers safe layout/app-versus-destination report preferences, not every chosen path.

Optional MHL export is under Camera options. Enable Export MHL + ASC MHL only if you need those interchange files. SHA-256 copy verification and HTML/JSON reports are present without that option. Exported ASC MHL is a flat inventory, not a complete custody history.

## 6. Review, copy now, or queue

| Action | What happens |
| --- | --- |
| Review Copy | Hashes sources and checks planned reuse/conflicts without writing destination media |
| Start Copy | Prepares if needed, saves the job and runs that job immediately |
| Add to Queue | Saves a prepared job without starting it |
| Start Queue | Runs queued jobs in order, one job at a time |
| Resume | Rechecks and runs the selected paused/failed job; unrelated queued jobs remain unstarted |

Review is useful when you want a conflict report before any destination files are written. It usually takes additional reading time; skipping it does not disable verification. With Skip verified matching files enabled, existing intended files are rehashed before being reused. Different content at the same path is a conflict, not an instruction to overwrite it.

Start Copy can be disabled while required choices are missing or sample safety checks have not passed. Read the inline explanation. If planning still reports an invalid label, collision, read-only destination or space problem, correct the named choice before retrying.

## 7. Read progress correctly

The queue shows written/readback bytes, separate copy and verification bars, recent copy/readback speeds, average combined I/O, elapsed time, phase and errors. Current speeds become zero after a job stops; historical average I/O is a different metric.

An estimate needs a warm-up period. It includes modeled source reads and publication work, but can change with hardware contention, read errors, caching and finalization. Cascading initially estimates backup work from the working destination's rate. A future unstarted queue has no promised completion time.

A success count applies to actual destination outcomes. “2 of 3 destinations verified” means the healthy copies should remain available while the third needs attention. Read each destination's error; do not treat a general queue failure as proof that every copy is corrupt.

## 8. Stop, reconnect and resume

Choose Stop/Pause Queue to request a safe stop. Blocking device I/O may delay the response. Wait for the paused state before disconnecting a drive when possible. If you quit while work is active, choose Pause and Quit to let the app finish stopping before it exits.

After interruption, restore the original source and destination locations, then use Resume on the affected job. The app rechecks existing full files and saved partial prefixes; it does not trust the old percentage. A replaced destination with the same name may be rejected because its identity differs. Do not rename/move private workspaces to trick the identity check.

When cascading has reached Working copy verified · backups pending, the backup stage can use the verified working copy. The card is no longer needed by that job's backup stage, but the working destination must stay available and pass its checks. This is not an instruction to erase the card.

Forget removes the queue entry only. It does not delete destination files or retained partials. Keep the job and its hidden `.OKCopy` data while recovery may still be needed.

## 9. Open, export or reverify a report

Choose Show Saved Reports. History shows project, date, destinations and outcome, with Open, Export…, Reverify… and Show in Finder actions. It discovers app-local reports and locations referenced by saved jobs; it is not a search of every drive.

Open displays the saved event in a resizable window. Export saves an HTML copy to a chosen location; that action does not necessarily export the companion JSON receipt. Preserve the JSON too if you want the app's structured SHA-256 re-verification input. Optional MHL files are another interchange route.

To check files now, use Verify Manifest… at the top, or Reverify… for an eligible history item. Select an MHL/JSON receipt and the folder from which its listed relative paths resolve—normally the project root, or the selected destination root for direct copying. Selecting the Ingest Reports folder as the content root is usually incorrect.

Reverification only certifies listed data forks it can check. Unsupported entries, missing files or hash mismatches require attention. Historical Verified reports do not become current verification merely because you open them again.

## 10. Recover a report-only failure

If the media is verified but report export failed, reconnect the report location and use Retry Report Export on the failed job. An eligible frozen pending receipt can export without reading the original card or copying media again. No pending record means there is nothing for that particular recovery action to export.

Manifest-generation failures and incomplete media copies need Resume rather than report-only recovery. If you need current integrity evidence after an export retry, run Reverify separately: the recovered report describes the original verification event.

## Common problems

| Message or observation | Meaning and response |
| --- | --- |
| Preview unavailable | Quick Look cannot preview that format here; the regular file can still be copied |
| Unsupported link or special file | This source contains something outside the app's file scope; select an appropriate narrower folder |
| Content conflict | An intended destination path has different data; use a different project/label instead of overwriting it |
| Destination identity changed | The original destination/path could not be validated; restore it rather than selecting a look-alike |
| Not enough space | Each destination needs its copy plus headroom; compatible publication can temporarily need another active-file allocation |
| Reports cannot be saved on source | Report storage must be outside protected originals |
| No external drives connected | Use Add Folders for internal folders or check the physical connection; the app does not require an external drive |
| A completed folder still has `.OKCopy` | Recovery metadata is retained; its presence is not itself an error |
| Notifications do not appear | Enable Completion notifications and allow macOS permission; OS notification settings also apply |

## Working vocabulary

**Source:** the selected original folder/card. **Destination:** a selected folder receiving a copy. **Project:** a named output root when the layout creates one. **Checksum:** a content-derived fingerprint. **Readback:** a separate read of written destination data. **Incremental:** reusing matching intended paths and adding new files. **Cascading:** creating backups from the verified working destination. **Receipt:** saved evidence of a verification event. **Manifest:** a machine-readable list of paths and checksums.
