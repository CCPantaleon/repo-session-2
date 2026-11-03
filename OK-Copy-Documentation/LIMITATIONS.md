# Current limitations

This section is specific to OK, Copy 3.7, build 13. A capability being implemented is different from its being qualified on every filesystem, reader and failure scenario. These limits define the current product rather than promising a future feature date.

## Platform and distribution

- The delivered app is Apple-silicon-only and requires macOS 14 or later. Intel, Windows, Linux and mobile platforms are not supported by this artifact.
- It is locally/ad-hoc signed, not Developer ID notarized. The development machine had no valid signing identity available. Clean-Mac installation and Gatekeeper behavior are not fully qualified.
- Source is included, but a public repository, open-source license, commercial support agreement, update service or maintenance guarantee is not established.
- The executable has a self-test entrypoint, not a documented headless/automation import API.

## File, folder and metadata scope

| Area | Current limit | Practical implication |
| --- | --- | --- |
| Input granularity | Source selection is folder-based | The search filter changes the view, not the transfer inventory |
| File contents | Regular data forks are copied and hashed | This is not a whole-Mac backup or complete Finder replacement |
| Metadata | Modification times are handled; creation times, ACLs, ownership, permissions, resource forks and extended attributes are not comprehensively preserved | Applications depending on those attributes need a different or separately qualified workflow |
| Empty directories | Not recreated merely because they exist on the source | The copied directory tree can omit empty folders |
| Links and special files | Rejected rather than transparently followed or reproduced | Source folders containing symlinks, aliases represented as links, devices, sockets or similar special entries can stop scanning |
| Hidden files | Ordinary hidden regular files are included; an explicit housekeeping set is skipped | “All originals” means the enumerated scope, not a raw device image |
| Case/path collisions | Conservative normalized case-insensitive collision checks | Some layouts possible on a case-sensitive filesystem are deliberately rejected |
| Media validity | No codec-level validation of every image/frame | A checksum-matching video may still have been damaged before copying |

A Finder alias that is an ordinary regular file is subject to regular-file behavior; it is not automatically equivalent to a Unix symlink. File type and representation matter. No special promise is made for application bundles, cloud placeholders, sparse files or virtualized/provider-managed filesystems merely because some of their contents appear as regular files.

## Storage and topology

Network destinations are explicitly rejected by the planner. This is not a NAS-tuning or remote-sync application. Support for a locally mounted volume depends on the filesystem/driver permitting the required operations; “local” is not a blanket compatibility certificate for every device or bridge.

External/removable sources are protected at volume scope. Copying from one folder to another folder on that protected external volume is therefore rejected even when the folders do not overlap. Internal-folder source protection can be narrower. The restriction favors preserving original media over offering every generic file-copy arrangement.

Disk Arbitration/IOKit discovery is best effort. A reported shared disk/USB ancestor is useful, but an absent relationship does not prove independence. RAID, APFS arrangements, virtual disks, reader bridges and hubs can obscure topology. The scheduler does not build a complete transport bandwidth map, predict thermal throttling, or prove that backups use separate physical fault domains.

The app has no implemented card-lifespan, bad-block or wear telemetry dashboard. SD, CFexpress A and CFexpress B are filesystem sources here; use through a built-in SDXC slot or Ulanzi DC04 has not been comprehensively qualified. Hash equality is not a health or remaining-life assessment.

## Verification and authenticity

SHA-256 is mandatory for ingest acceptance, but the reference must come from somewhere. Immediate jobs establish it during the first copy read; an unstarted immediate job has no preexisting content baseline capable of detecting a same-size, same-time change before that read. Review can establish an earlier baseline, at the cost of another source read.

Independent destination readback is an explicit second read operation. It is not a guarantee that macOS evicted its cache or that the device physically reread every cell. Flush calls also depend on filesystem, kernel and hardware behavior. There is no formal proof of crash consistency or survival of arbitrary power loss.

Receipts and source-reference files are not digitally signed or protected by a hardware trust anchor. A privileged or compromised process can tamper with local data and metadata. The application is not an adversarial forensic acquisition system or a hardware write blocker. It does not encrypt the copied files or reports.

Standalone verification checks the listed files, not the absence of extra files or the correctness of every possible manifest field/history. It supports the app's SHA-256 JSON receipts and selected flat MHL structures. Inputs must be UTF-8, within the 128 MiB limit, and contain safe paths. SHA-512, C4, XXH3/XXH128 and other unsupported algorithms do not become supported because a manifest names them.

## ASC MHL and interoperability

Export is legacy MHL 1.1 and flat ASC MHL 2.0. The application does not create/validate a complete ASC chain, history graph, nested histories, directory/root hashes or digital signatures. Full chain-of-custody compliance is not claimed. One recorded XSD validation and local round trips do not establish interchange compatibility with every production application or every standards revision.

Ingest SHA-256 and exported SHA-1 serve different roles. Legacy SHA-1/MD5 comparison support is interoperability support, not a recommendation for new authenticity/security protocols. XXH64 support is not a cryptographic authenticity claim.

## Performance, memory and estimates

- No controlled head-to-head throughput or reliability benchmark against OffShoot, Copy That, Finder or rsync has been completed.
- Mandatory extra reads and compatible final publication can be slower than a copy operation that does less verification. Optional Review adds work.
- Queues are bounded per channel, but file inventories, manifests and receipts grow with file count. Very large numbers of small files can use substantial memory and preparation time.
- Direct fan-out still waits for the slowest sustained writer once its queue fills. Cascading changes where work happens rather than eliminating the work.
- Source concurrency is limited to four and source groups can be serialized. Destination readback concurrency is limited per active file and constrained by discovered shared locks.
- Current-speed values are recent samples, not literally instantaneous hardware measurements. Average I/O combines different work from raw copy speed.
- ETA is a modeled approximation. It includes source reads/rereads and coarse publication credits, but extra prefix checks, preparation, report/manifests, storage stalls and changing topology/rates can extend it. Cascading initially extrapolates backup speeds from the working drive. Unstarted jobs do not have a reliable whole-queue countdown.

## Queue and interruption recovery

One queue job runs at a time. A failed job stops the queue after healthy destinations have had a chance to finish. There is no unattended policy engine that automatically chooses another backup destination or skips failed jobs forever.

Cancellation is cooperative. Waiting for blocked macOS device I/O can delay Stop or Pause and Quit. An idle-sleep assertion does not override lid-close, forced sleep, shutdown, device power loss or every OS policy.

Resume requires the saved plan and expected locations/identities. There is no general UI to relocate an immutable job to a new mount path, replace a lost destination with another drive, or edit its file mapping in place. Changed source inventories require a newly prepared plan. Healthy files are reverified on resume; this costs reading time.

Cascading can continue without the original card only after the primary reached its ready state and retained its reference data. It cannot reconstruct originals from an unverified, missing or changed working copy. Partial, rejected and hidden recovery files can consume space. Forget does not clean them up, and deleting them can remove recovery/report-export options.

Eligible report-only recovery replays a frozen HTML/JSON payload; it does not prove present-day file integrity, regenerate missing MHLs, or recover a receipt that was never saved. Its pending payload limit is 128 MiB. Reverify is the distinct action for a current check.

## Reports and interface

History discovers app-local reports and report locations referenced by retained jobs. It is not a global indexed catalog of every report on all attached disks. Moving/removing report files or forgetting jobs can affect discoverability. Recovered report names can use a generic recovery identifier, and historical reports keep their original formatting and wording.

History Export saves the selected HTML report; it is not a complete media-plus-manifest archival package. Companion JSON/MHL files need to be preserved separately where required. Reports can disclose full paths, filenames, digests and workstation information; there is no built-in redaction or access-control management.

Quick Look previews depend on macOS and installed format support. There are no bundled professional camera SDKs or guaranteed thumbnails for every RAW/video format. The green/red presentation is accompanied by text, but full VoiceOver, keyboard-only, increased-contrast, light-mode and small-display coverage remains unfinished.

Native notification delivery depends on user permission and macOS notification policy. The app cannot guarantee a visible banner under Focus or other system restrictions.

## Qualification still required

The 67 tests and 113 generated-file checks are useful evidence of modeled scenarios. They do not replace real SD/CFexpress, APFS/exFAT, many-small-file, disk-full, thermal, physical disconnect/reconnect, sleep and forced-power-loss tests with disposable data. Sustained performance and recovery need qualification on the actual Mac, reader, cables, hubs and destinations used in production.

These outstanding tests and Developer ID/notarization are current limitations, not completed features. See [Validation](VALIDATION.md) for a practical qualification plan and the distinction between simulation and real hardware evidence.
