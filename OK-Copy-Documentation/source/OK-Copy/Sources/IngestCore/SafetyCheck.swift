import Foundation

public struct SafetyCheckResult: Sendable {
    public let checks: [String]
    public let completedAt: Date
}

public enum SafetyCheck {
    private static let lock = NSLock()
    private static var passed = false
    public static var hasPassed: Bool { lock.lock(); defer { lock.unlock() }; return passed }

    public static func run() throws -> SafetyCheckResult {
        lock.lock(); passed = false; lock.unlock()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OKCopy-Safety-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // This tree is generated exclusively for this check; no selected card is used.
        defer { try? fm.removeItem(at: root) }
        let card = root.appendingPathComponent("SAMPLE-CARD")
        let working = root.appendingPathComponent("Working")
        let backup = root.appendingPathComponent("Backup")
        for url in [card.appendingPathComponent("DCIM/100TEST"), working, backup] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data("abc".utf8).write(to: card.appendingPathComponent("DCIM/100TEST/TEST.CR3"))
        try Data(repeating: 0xA7, count: 1_100_003).write(to: card.appendingPathComponent("DCIM/100TEST/TEST.MOV"))
        try Data("<xmp>synthetic sample</xmp>".utf8).write(to: card.appendingPathComponent("DCIM/100TEST/TEST.XMP"))
        try Data().write(to: card.appendingPathComponent("EMPTY.DAT"))
        try Data("hidden".utf8).write(to: card.appendingPathComponent(".hidden"))
        let snapshot = try CardScanner.scan(card)
        let baseline = try snapshot.files.map { try checksum(card.appendingPathComponent($0.relativePath)) }
        var checks: [String] = []
        guard baseline[snapshot.files.firstIndex(where: { $0.name == "TEST.CR3" })!] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" else { throw IngestError("SHA-256 known-answer test failed") }
        checks.append("SHA-256 known-answer test")
        func request(_ name: String, _ target: URL? = nil) -> IngestRequest {
            IngestRequest(snapshot: snapshot, projectName: name, workingRoot: target ?? working, backupRoot: backup)
        }
        let dry = try IngestEngine.dryRun(request("Dry Run"))
        guard dry.dryRun, dry.files.count == 5, try fm.contentsOfDirectory(atPath: working.path).isEmpty,
              try fm.contentsOfDirectory(atPath: backup.path).isEmpty else { throw IngestError("Dry-run isolation test failed") }
        checks.append("Dry run creates no destination files")
        let copied = try IngestEngine.execute(Planner.plan(request("Sample Copy")))
        guard copied.files.count == 5, copied.files.allSatisfy({ $0.status == "Verified" && $0.sourceSHA256 == $0.workingSHA256 && $0.sourceSHA256 == $0.backupSHA256 }),
              copied.reports.count == 2, copied.reports.allSatisfy({ fm.fileExists(atPath: $0.path) }) else { throw IngestError("Dual-copy verification test failed") }
        checks.append("Two complete copies, hidden files, empty files, and HTML reports")
        let single = try IngestEngine.execute(Planner.plan(IngestRequest(snapshot: snapshot, projectName: "Working Only", workingRoot: working)))
        guard single.reports.count == 1, single.files.allSatisfy({ $0.status == "Verified" && $0.sourceSHA256 == $0.workingSHA256 && $0.backupSHA256 == nil }) else { throw IngestError("Working-only import test failed") }
        checks.append("Working-only import on the internal filesystem; backup optional")
        try expectFailure("Existing project protection") { _ = try Planner.plan(request("Sample Copy")) }
        checks.append("Existing project cannot be overwritten")
        try expectFailure("Source overlap protection") { _ = try Planner.plan(request("Unsafe", card)) }
        checks.append("Destination cannot overlap the source")
        let cancelled = CancellationToken(); cancelled.cancel()
        try expectFailure("Cancellation") { _ = try IngestEngine.execute(Planner.plan(request("Cancelled")), token: cancelled) }
        checks.append("Cancellation stops before destination writes")
        try expectFailure("Corruption detection") {
            _ = try IngestEngine.execute(Planner.plan(request("Corruption")), beforeVerification: { work, _ in
                try Data("deliberately corrupted test copy".utf8).write(to: work)
            })
        }
        guard !(fm.fileExists(atPath: try Planner.plan(request("Corruption")).workingProject.path)) else { throw IngestError("Corrupted copy was published") }
        checks.append("Corrupted copy rejected and never published")
        let secondCard = root.appendingPathComponent("SECOND-CARD")
        let third = root.appendingPathComponent("Third-Copy")
        for url in [secondCard, third] { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
        try Data("abc".utf8).write(to: secondCard.appendingPathComponent("DUPLICATE.CR3"))
        let selections = [SourceSelection(snapshot: snapshot), SourceSelection(snapshot: try CardScanner.scan(secondCard))]
        let batch = try BatchPlanner.prepare(sources: selections, destinations: [working, backup, third], projectName: "Resumable Sample")
        guard batch.duplicateCount == 1 else { throw IngestError("Content duplicate detection failed") }
        let pause = CancellationToken()
        var job = TransferJob(plan: batch)
        try expectFailure("Resumable interruption") {
            _ = try TransferEngine.execute(job, token: pause, progress: { update in if update.phase.hasPrefix("Copying") && update.fraction > 0 { pause.cancel() } })
        }
        let journal = TransferQueueStore(directory: root.appendingPathComponent("Queue"))
        job.status = .running; try journal.save([job])
        let restored = try journal.load()
        guard restored.first?.status == .paused, restored.first?.id == job.id else { throw IngestError("Persistent queue recovery failed") }
        checks.append("Persistent queue restores interrupted jobs as paused")
        let resumed = try TransferEngine.execute(restored[0])
        guard resumed.reports.count == 3, resumed.files.allSatisfy({ $0.destinations.count == 3 && $0.destinations.allSatisfy({ $0.sha256.count == 64 }) }), resumed.files.contains(where: { $0.destinations.contains(where: { $0.resumedBytes > 0 }) }) else {
            throw IngestError("Multi-source, multi-destination resume test failed")
        }
        checks.append("Multiple sources and three destinations resume verified prefixes")
        let incremental = try BatchPlanner.prepare(sources: selections, destinations: [working, backup, third], projectName: "Resumable Sample", date: batch.createdAt)
        guard incremental.existingCopies == incremental.files.count * 3, incremental.duplicateCount == 1 else { throw IngestError("Incremental checksum detection failed") }
        let skipped = try TransferEngine.execute(TransferJob(plan: incremental))
        guard skipped.files.allSatisfy({ $0.destinations.allSatisfy({ $0.action == "Verified existing · skipped" }) }) else { throw IngestError("Verified incremental skip failed") }
        checks.append("Incremental copies reverify matching files; duplicates retain their paths")
        let isolated = try BatchPlanner.prepare(sources: selections, destinations: [working, backup], projectName: "Isolated Failure")
        try expectFailure("Independent destination failure") {
            _ = try TransferEngine.execute(TransferJob(plan: isolated), beforeVerification: { url in
                if url.path.hasPrefix(isolated.destinations[1].root.path + "/") { try Data("synthetic damaged backup".utf8).write(to: url) }
            })
        }
        guard fm.fileExists(atPath: working.appendingPathComponent(isolated.folderName).path),
              !fm.fileExists(atPath: backup.appendingPathComponent(isolated.folderName).path) else { throw IngestError("Healthy destination did not finish independently") }
        checks.append("Failed backup does not prevent a healthy destination from finishing")
        let cascade = try BatchPlanner.prepare(sources: selections, destinations: [working, backup], projectName: "Cascade Safety", options: TransferOptions(cascade: true))
        let cascaded = try TransferEngine.execute(TransferJob(plan: cascade))
        guard cascaded.files.count == cascade.files.count, cascaded.files.allSatisfy({ $0.destinations.count == 2 }) else { throw IngestError("Cascading verification failed") }
        checks.append("Cascading verifies the working copy before creating backups")
        let project = working.appendingPathComponent(cascade.folderName)
        let manifests = try fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mhl" }
        guard manifests.count == 2 else { throw IngestError("Manifest export failed") }
        for manifest in manifests { guard try MediaManifest.verify(manifest: manifest, root: project).passed else { throw IngestError("Manifest round-trip verification failed") } }
        checks.append("Legacy MHL and flat ASC MHL independently reverify generated originals")
        var xxh = XXH64(); xxh.update(Data("abc".utf8))
        guard xxh.hex() == "44bc2cf5ad770999" else { throw IngestError("XXH64 compatibility check failed") }
        checks.append("XXH64 known-answer test for external manifests")
        let after = try CardScanner.scan(card)
        let finalHashes = try after.files.map { try checksum(card.appendingPathComponent($0.relativePath)) }
        guard after.files.map(\.relativePath) == snapshot.files.map(\.relativePath), after.files.map(\.stamp) == snapshot.files.map(\.stamp), baseline == finalHashes else {
            throw IngestError("Source preservation test failed")
        }
        checks.append("Source names, sizes, timestamps, and SHA-256 unchanged")
        lock.lock(); passed = true; lock.unlock()
        return SafetyCheckResult(checks: checks, completedAt: Date())
    }

    static func expectFailure(_ label: String, action: () throws -> Void) throws {
        var failed = false
        do { try action() } catch { failed = true }
        guard failed else { throw IngestError("Safety check failed: \(label)") }
    }
}
