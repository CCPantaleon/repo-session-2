# Validation and qualification

## Evidence available for v3.7

The development record reports **67 XCTest tests, zero failures**, plus **113 generated-file checks**. The latter comprise 16 runtime safety checks, 26 application-workflow checks, 32 filesystem/publication checks and 39 immediate-copy checks. These are separate reported groups, not a percentage guarantee of coverage or a measure of failure probability.

The final v3.7 GUI inspection confirmed separated toolbar controls with individual accessibility names and a newly generated Verified report heading. Its isolated sample used two generated sources, three destinations and seven files. Local signature checks, property-list checks, archive verification, and comparison between packaged source and delivered source passed.

This documentation task inspected the recorded results and source. It did not rerun a new hardware benchmark or expand the app's qualification claims.

## What the tests establish

| Area | Recorded coverage | What it does not establish |
| --- | --- | --- |
| Hashing | Known-answer checks, destination corruption and changed-source detection | Media provenance or future integrity |
| Paths and source protection | Source/destination overlap, symlinks, conflicting output data and exclusions | Protection from other processes or malicious privileged users |
| Basic transfers | Hidden/empty regular files, multiple sources/targets and incremental reuse | Full metadata backup or every filesystem/driver |
| Interruption | Cancel tokens, saved partials, invalid-prefix preservation, queue restore | A physical USB disconnect or arbitrary power failure on every device |
| Compatible publication | Journal interruption, final-path replacement and prefix corruption fixtures | Universal exFAT controller/firmware behavior |
| Cascading | Working copy checks, backup failure, source removed after primary readiness | Sustained card-release timings or fastest overall mode |
| Manifest verification | Round trips, unsafe paths, missing files, unsupported hashes, malformed structures | Complete ASC history validation or every vendor's interchange behavior |
| Report recovery | Pending receipt exports after the generated source is removed; repeat retry is a no-op | Recovery when no pending payload was written |
| App workflow | Review/start/queue, unrelated jobs preserved by selected Resume | Exhaustive UI/accessibility or every human interaction sequence |

The test sources and four generated-check tools are retained in the source snapshot. Historical validation notes are archived in `evidence/Development-Validation.md`; build outputs are not a substitute for reviewing the assertions themselves.

## Suggested disposable-data qualification matrix

Run these on generated or explicitly disposable files, keeping a trusted SHA-256 reference outside the test targets. Record the exact app build, macOS version, device/firmware, reader, cable/hub, filesystem and options.

| Scenario | Exercise | Acceptance evidence |
| --- | --- | --- |
| Internal SSD only | One source folder, one destination, all layouts | Every intended regular file matches; reports reopen after app restart |
| Independent drives | Two or three destinations, mixed APFS/exFAT | Each expected destination verifies; identity and shared-storage advisories are understood |
| Actual readers | SD through built-in slot; SD and CFexpress A/B through the Ulanzi reader | Inventory, transfer and readback match references without sustained errors |
| Large media | Representative multi-gigabyte files plus mixed sidecars | No unexplained hash mismatch; measured memory, elapsed time and speeds recorded |
| Many small files | Representative large file counts | Preparation/report time and memory remain acceptable to the operator |
| Controlled pause | Stop during copy, verification and compatible publication | Original references unchanged; resume validates retained data and completes |
| Disconnect | Remove one disposable target mid-copy; reconnect original target | Healthy target completes; failed target does not report success; retry preserves valid data |
| Low space | Fill a disposable target toward its planned capacity | Clear failure; original unchanged; healthy destinations and recovery data retained |
| App/process interruption | Interrupt a disposable job and relaunch | Running state restores paused; no automatic copying; full/prefix rechecks occur |
| Forced sleep/power interruption | Only in a controlled test environment | Record actual recovery, journal and flush behavior; do not infer results from a cancel-token test |
| Report storage unavailable | Lose the selected report folder after media verification | Verified media retained; eligible export-only retry succeeds without the source |
| UI qualification | Keyboard-only, VoiceOver, contrast, light/dark, small display and native report resize | Every action is reachable, labeled and visually legible |
| Distribution | Trusted signed/notarized archive on a clean target Mac | Installation, launch, volume access and notification behavior are recorded |

Do not use valuable originals to discover failure behavior. A test pass applies to the tested combination and conditions, not every future card or driver.

## No benchmark chart is justified yet

This repository deliberately uses architecture and lifecycle diagrams instead of a speed leaderboard. There are no controlled measurements supporting a faster-than-OffShoot/Copy-That/Finder/rsync chart. A defensible benchmark would equalize verification modes, metadata scope, report settings, cache state, topology, file distributions and failure criteria. Report source-release time separately from whole-job completion and destination verification time.

## Release acceptance statement

The available evidence supports describing v3.7 as a tested development implementation for the stated local regular-file workflow. Physical hardware qualification, full manual accessibility/appearance testing, Developer ID/notarization and clean-Mac distribution remain open. The source-included design is inspectable, but no independent security audit or commercial-grade reliability certification has been completed.
