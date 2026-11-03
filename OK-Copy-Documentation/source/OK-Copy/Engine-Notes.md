# OK, Copy 3.0 engine notes

Version 3.0 implements the eight-row upgrade checklist in `Upgrade Checklist.md`. `ManagedTransfer` is the shipping coordinator. `TransferEngine.run` retains the startup safety gate and delegates to it. The older single-source engine and v2 transfer implementation remain available internally for regression/reference; they are not the GUI queue path.

The copy path combines a bounded source read/hash pipeline with separate bounded destination writers. One source read fans out each copy chunk. Up to four source workers can run, with transitive hardware grouping. Each source file can verify up to four destinations concurrently; shared storage locks prevent simultaneous write/readback operations on known common resources. The planner still performs a full source SHA-256 baseline; source copy and post-copy reads remain separate verification passes.

Destination failures are independent, while source-integrity failures prohibit declaring the overall project complete. Publication and receipt creation are per destination, and a failed job retains healthy published copies. Cascading treats the completed working copy as the backup source only after fresh identity/inventory/hash checks. Job state and reports distinguish working-stage completion from all-destination completion.

Hardware discovery is best effort via Disk Arbitration and IOKit. Whole disk/container IDs group volumes; physical block-device and USB ancestry add common-resource keys when available. An unknown relationship is not asserted to be independent physical storage. Source groups merge transitively. Fixed-order resource lock acquisition prevents lock-order inversion. Ordinary blocking macOS I/O can delay cancellation.

Manifest export computes SHA-1 alongside destination SHA-256 readback and writes legacy MHL 1.1 and flat ASC MHL 2.0 file inventories. It is not a complete ASC chain/history implementation. SHA-256 continues to control ingest acceptance. The standalone verifier additionally reads MD5 and canonical XXH64 manifests; unsupported algorithms/structures never silently pass.

`fcopyfile` and rsync are still not enabled as ingest backends. They would need to preserve the same source restrictions, private staging, immutable baseline, conflict handling, independent readback, cancellation and recovery policies. The small v2.1 cached comparison is historical evidence only; it does not benchmark v3.0 or predict real card performance. A primitive change alone would not supply this scheduling/recovery system.

References:

- [ASC MHL reference implementation and schema](https://github.com/ascmitc/mhl)
- [ASC MHL specification](https://github.com/ascmitc/mhl-specification)
- [Legacy MHL](https://mediahashlist.org/)
- [XXH64 algorithm specification](https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md)
- [Apple copyfile/fcopyfile](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.3)
- [Rsync manual](https://download.samba.org/pub/rsync/rsync.1.html)
