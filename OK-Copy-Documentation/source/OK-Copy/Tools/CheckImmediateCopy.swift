import Foundation
import Darwin

@main
struct CheckImmediateCopy {
    static var count = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw IngestError("FAILED: " + name) }
        count += 1; print("PASS: " + name)
    }
    static func rejects(_ name: String, _ body: () throws -> Void) throws {
        var error: Error?
        do { try body() } catch let caught { error = caught }
        try check(error != nil, name)
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OKCopy-Immediate-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        for url in [source, a, b] { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
        let payload = Data(repeating: 0x57, count: 17 * 1024 * 1024 + 43)
        try Data("hidden data".utf8).write(to: source.appendingPathComponent(".env"))
        try Data("hidden data".utf8).write(to: source.appendingPathComponent("duplicate.txt"))
        try payload.write(to: source.appendingPathComponent("sample.bin"))
        let selection = SourceSelection(snapshot: try CardScanner.scan(source), label: "Source")
        let baseline = try selection.snapshot.files.map { try checksum(source.appendingPathComponent($0.relativePath)) }
        func plan(_ name: String, cascade: Bool = false, targets: [URL]? = nil) throws -> BatchPlan {
            try BatchPlanner.prepare(sources: [selection], destinations: targets ?? [a, b], projectName: name,
                                     options: TransferOptions(cascade: cascade, manifests: true), hashDuringCopy: true)
        }
        let immediate = try plan("Exact name + spaces")
        try check(immediate.schemaVersion == 3 && immediate.hashDuringCopy == true, "Immediate plans explicitly use the new streaming format")
        try check(immediate.files.allSatisfy { $0.sha256.isEmpty }, "Immediate planning does not hash source contents")
        try check(try fm.contentsOfDirectory(atPath: a.path).isEmpty, "Immediate planning creates no destination files")
        let job = TransferJob(plan: immediate)
        let queue = TransferQueueStore(directory: root.appendingPathComponent("Queue"))
        try queue.save([job])
        let restored = try queue.load()
        try check(restored.first?.plan.hashDuringCopy == true, "Unreviewed queued plans survive restart")
        let result = try TransferEngine.execute(restored[0])
        try check(result.files.count == 3 && result.files.allSatisfy { $0.sourceSHA256.count == 64 && $0.destinations.count == 2 }, "Immediate copies have full SHA-256 receipts for both destinations")
        try check(result.files.filter { $0.duplicateOf != nil }.count == 1, "Immediate copies detect duplicate content while copying")
        for target in [a, b] {
            let folder = target.appendingPathComponent(immediate.folderName)
            let workspace = try Directory(url: folder.appendingPathComponent(".OKCopy/Jobs/" + job.id.uuidString))
            for (i, file) in immediate.files.enumerated() {
                try check(try checksum(folder.appendingPathComponent(file.outputPath)) == baseline[i], "Published file matches source: " + target.lastPathComponent + "/" + file.original.relativePath)
                try check(try SourceChecksums.load(file.id, from: workspace) == baseline[i], "Immutable checksum reference saved: " + target.lastPathComponent + "/" + file.original.relativePath)
            }
            let manifests = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mhl" }
            try check(manifests.count == 2, "Optional manifests emitted for immediate copy at " + target.lastPathComponent)
            for manifest in manifests { try check(try MediaManifest.verify(manifest: manifest, root: folder).passed, "Immediate-copy manifest independently verifies") }
        }
        let repeated = try TransferEngine.execute(TransferJob(plan: plan("Exact name + spaces")))
        try check(repeated.files.allSatisfy { $0.destinations.allSatisfy { $0.action.contains("existing") } }, "Immediate incremental copy verifies and skips matching files")

        let conflictFolder = a.appendingPathComponent("Conflict/Originals/Source")
        try fm.createDirectory(at: conflictFolder, withIntermediateDirectories: true)
        let untouched = Data("existing content".utf8)
        try untouched.write(to: conflictFolder.appendingPathComponent(".env"))
        try rejects("Immediate copy detects conflicting existing data") { _ = try TransferEngine.execute(TransferJob(plan: plan("Conflict"))) }
        try check(try Data(contentsOf: conflictFolder.appendingPathComponent(".env")) == untouched, "Conflicting data is never overwritten")
        try check(fm.fileExists(atPath: b.appendingPathComponent("Conflict/Originals/Source/sample.bin").path), "A healthy destination finishes despite another destination's conflict")

        let pausedPlan = try plan("Paused immediate")
        let pausedJob = TransferJob(plan: pausedPlan)
        let pause = CancellationToken()
        try rejects("Immediate copy can pause before finishing") {
            _ = try TransferEngine.execute(pausedJob, token: pause, progress: { value in
                if value.phase.hasPrefix("Copying") && value.fraction > 0 { pause.cancel() }
            })
        }
        let resumed = try TransferEngine.execute(pausedJob)
        try check(resumed.files.count == 3 && resumed.files.allSatisfy { $0.sourceSHA256.count == 64 }, "Immediate copy resumes and verifies every file")

        let frozenSource = root.appendingPathComponent("Frozen Source")
        try fm.createDirectory(at: frozenSource, withIntermediateDirectories: false)
        let original = Data(repeating: 0x35, count: 1024 * 1024)
        let frozenFile = frozenSource.appendingPathComponent("frozen.bin")
        try original.write(to: frozenFile)
        let frozenSelection = SourceSelection(snapshot: try CardScanner.scan(frozenSource), label: "Frozen")
        let frozenPlan = try BatchPlanner.prepare(sources: [frozenSelection], destinations: [a], projectName: "Frozen references", options: TransferOptions(manifests: false), hashDuringCopy: true)
        let frozenJob = TransferJob(plan: frozenPlan)
        let cancelAtVerify = CancellationToken()
        try rejects("Pause after source reference is saved") {
            _ = try TransferEngine.execute(frozenJob, token: cancelAtVerify, beforeVerification: { _ in cancelAtVerify.cancel() })
        }
        let stage = a.appendingPathComponent(".OKCopy.incomplete-" + frozenJob.id.uuidString)
        let frozenWorkspace = try Directory(url: stage.appendingPathComponent(".OKCopy/Jobs/" + frozenJob.id.uuidString))
        let saved = try SourceChecksums.load(frozenPlan.files[0].id, from: frozenWorkspace)
        try check(saved?.count == 64, "A source reference exists before publication")
        let writer = open(frozenFile.path, O_WRONLY)
        guard writer >= 0 else { throw IngestError("Cannot open fixture") }
        try writeAll(writer, data: Data(repeating: 0x61, count: original.count))
        let stamp = frozenSelection.snapshot.files[0].stamp
        var times = [timespec(tv_sec: Int(stamp.seconds), tv_nsec: Int(stamp.nanos)), timespec(tv_sec: Int(stamp.seconds), tv_nsec: Int(stamp.nanos))]
        guard futimens(writer, &times) == 0 else { close(writer); throw IngestError("Cannot restore fixture time") }
        close(writer)
        try rejects("Resume rejects changed content even when size and modification time are unchanged") { _ = try TransferEngine.execute(frozenJob) }
        try check(try SourceChecksums.load(frozenPlan.files[0].id, from: frozenWorkspace) == saved, "Resume never replaces the original checksum reference")
        try check(!fm.fileExists(atPath: a.appendingPathComponent(frozenPlan.folderName).path), "Changed-source copy is not published")

        let cascadePlan = try plan("Immediate cascade", cascade: true)
        let cascadeJob = TransferJob(plan: cascadePlan)
        let cascaded = try TransferEngine.execute(cascadeJob)
        try check(cascaded.files.count == 3 && cascaded.files.allSatisfy { $0.sourceSHA256.count == 64 && $0.destinations.count == 2 }, "Immediate cascading verifies every destination against resolved source hashes")
        let heldSource = root.appendingPathComponent("Source offline")
        try fm.moveItem(at: source, to: heldSource)
        let withoutSource = try TransferEngine.execute(cascadeJob)
        try check(withoutSource.files.count == 3, "Completed working-copy cascade resumes without the original source")
        let corruptedWorking = a.appendingPathComponent(cascadePlan.folderName + "/Originals/Source/.env")
        try Data("corruption!".utf8).write(to: corruptedWorking)
        try rejects("Cascade checks saved original hashes before using a changed working copy") { _ = try TransferEngine.execute(cascadeJob) }
        try fm.moveItem(at: heldSource, to: source)
        let finalHashes = try selection.snapshot.files.map { try checksum(source.appendingPathComponent($0.relativePath)) }
        try check(finalHashes == baseline, "Original source fixtures stay unchanged")
        print("ALL \(count) IMMEDIATE-COPY CHECKS PASSED")
    }
}
