import XCTest
import Foundation
@testable import IngestCore

final class TransferTests: XCTestCase {
    var root: URL!
    var a: URL!
    var b: URL!
    var targets: [URL] = []
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OKCopy-Batch-Test-" + UUID().uuidString)
        a = root.appendingPathComponent("CARD-A"); b = root.appendingPathComponent("CARD-B")
        targets = ["SSD", "Backup", "Third"].map { root.appendingPathComponent($0) }
        for folder in [a!, b!] + targets { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data(repeating: 0x27, count: 17 * 1024 * 1024 + 123).write(to: a.appendingPathComponent("000-large.bin"))
        try Data("same original".utf8).write(to: a.appendingPathComponent("IMG_0001.CR3"))
        try Data("same original".utf8).write(to: b.appendingPathComponent("IMG_0001.CR3"))
        try Data("different original".utf8).write(to: b.appendingPathComponent("IMG_0002.CR3"))
        try Data().write(to: b.appendingPathComponent("empty.xmp"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func plan(_ name: String = "Batch", targetCount: Int = 3, incremental: Bool = true) throws -> BatchPlan {
        try BatchPlanner.prepare(sources: [SourceSelection(snapshot: CardScanner.scan(a)), SourceSelection(snapshot: CardScanner.scan(b))], destinations: Array(targets.prefix(targetCount)), projectName: name, incremental: incremental, date: date)
    }
    func paused(_ plan: BatchPlan) throws -> TransferJob {
        let job = TransferJob(plan: plan); let token = CancellationToken()
        XCTAssertThrowsError(try TransferEngine.execute(job, token: token, progress: { update in
            if update.phase.hasPrefix("Copying") && update.fraction > 0 { token.cancel() }
        }))
        return job
    }

    func testMultipleSourcesThreeDestinationsAndDuplicateDetection() throws {
        let plan = try plan()
        XCTAssertEqual(plan.sources.count, 2); XCTAssertEqual(plan.destinations.count, 3); XCTAssertEqual(plan.duplicateCount, 1)
        for target in targets { XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty) }
        let result = try TransferEngine.execute(TransferJob(plan: plan))
        XCTAssertEqual(result.reports.count, 3); XCTAssertEqual(result.files.count, 5)
        for target in targets {
            for file in plan.files { XCTAssertEqual(try checksum(target.appendingPathComponent(plan.folderName + "/" + file.outputPath)), file.sha256) }
        }
        XCTAssertTrue(result.files.allSatisfy { record in record.destinations.count == 3 && record.destinations.allSatisfy { $0.sha256 == record.sourceSHA256 } })
        XCTAssertTrue(result.html.contains("Identical content at distinct source paths is retained"))
    }

    func testResumeMidFileReusesVerifiedPrefix() throws {
        let plan = try plan(); let job = try paused(plan)
        let first = plan.files[0]
        let part = targets[0].appendingPathComponent(".OKCopy.incomplete-" + job.id.uuidString + "/.OKCopy/Jobs/" + job.id.uuidString + "/" + first.id + ".part")
        let size = (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as! NSNumber).int64Value
        XCTAssertGreaterThan(size, 0); XCTAssertLessThan(size, first.original.bytes)
        let result = try TransferEngine.execute(job)
        XCTAssertEqual(result.files[0].destinations.map(\.resumedBytes), [size, size, size])
        XCTAssertTrue(result.files[0].destinations.allSatisfy { $0.action.contains("resumed") })
        XCTAssertEqual(try checksum(a.appendingPathComponent("000-large.bin")), first.sha256)
    }

    func testWorkingOnlyJobCanResumeWithoutAnyBackup() throws {
        let plan = try plan("Working Only", targetCount: 1)
        let job = try paused(plan)
        let result = try TransferEngine.execute(job)
        XCTAssertEqual(result.reports.count, 1)
        XCTAssertTrue(result.files.allSatisfy { $0.destinations.count == 1 && $0.destinations[0].sha256 == $0.sourceSHA256 })
        XCTAssertGreaterThan(result.files[0].destinations[0].resumedBytes, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: targets[1].path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: targets[2].path).isEmpty)
    }

    func testCorruptPrefixIsRetainedAndRestarted() throws {
        let plan = try plan(); let job = try paused(plan)
        let file = plan.files[0]
        let workspace = targets[0].appendingPathComponent(".OKCopy.incomplete-" + job.id.uuidString + "/.OKCopy/Jobs/" + job.id.uuidString)
        let handle = try FileHandle(forWritingTo: workspace.appendingPathComponent(file.id + ".part"))
        try handle.write(contentsOf: Data([0xFF])); try handle.close()
        let result = try TransferEngine.execute(job)
        XCTAssertEqual(result.files[0].destinations[0].resumedBytes, 0)
        XCTAssertTrue(result.files[0].destinations[0].action.contains("invalid partial"))
        let finalWork = targets[0].appendingPathComponent(plan.folderName + "/.OKCopy/Jobs/" + job.id.uuidString)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: finalWork.path).contains { $0.contains(".rejected-") })
    }

    func testIncrementalReverifiesAndSkipsOnlyMatchingPaths() throws {
        let first = try plan()
        _ = try TransferEngine.execute(TransferJob(plan: first))
        let second = try plan()
        XCTAssertEqual(second.existingCopies, second.files.count * 3)
        let result = try TransferEngine.execute(TransferJob(plan: second))
        XCTAssertTrue(result.files.allSatisfy { $0.destinations.allSatisfy { $0.action == "Verified existing · skipped" } })
        try Data("additional".utf8).write(to: b.appendingPathComponent("NEW.CR3"))
        let third = try plan()
        XCTAssertEqual(third.existingCopies, second.files.count * 3)
        let thirdResult = try TransferEngine.execute(TransferJob(plan: third))
        XCTAssertEqual(thirdResult.files.filter { $0.destinations.contains { $0.action == "Verified · copied" } }.count, 1)
    }

    func testSamePathDifferentContentIsNeverOverwritten() throws {
        let initial = try plan()
        _ = try TransferEngine.execute(TransferJob(plan: initial))
        let original = targets[0].appendingPathComponent(initial.folderName + "/Originals/CARD-B/IMG_0002.CR3")
        let oldHash = try checksum(original)
        try Data("changed camera original".utf8).write(to: b.appendingPathComponent("IMG_0002.CR3"))
        XCTAssertThrowsError(try plan())
        XCTAssertEqual(try checksum(original), oldHash)
    }

    func testTamperedExistingCopyIsDetectedOnResume() throws {
        let plan = try plan(); let job = try paused(plan)
        _ = try TransferEngine.execute(job)
        let copied = targets[0].appendingPathComponent(plan.folderName + "/" + plan.files[0].outputPath)
        try Data("corrupt existing copy".utf8).write(to: copied)
        XCTAssertThrowsError(try TransferEngine.execute(job))
        XCTAssertEqual(try String(contentsOf: copied), "corrupt existing copy")
    }

    func testQueueSurvivesRelaunchAndRunningBecomesPaused() throws {
        let store = TransferQueueStore(directory: root.appendingPathComponent("Journal"))
        var job = TransferJob(plan: try plan()); job.status = .running
        try store.save([job])
        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1); XCTAssertEqual(loaded[0].id, job.id); XCTAssertEqual(loaded[0].status, .paused)
        XCTAssertEqual(loaded[0].plan.files.map(\.sha256), job.plan.files.map(\.sha256))
        var queued = loaded[0]; queued.status = .queued
        try store.save([queued]); XCTAssertEqual(try store.load()[0].status, .queued)
    }

    func testQueueCannotWriteInsideSource() throws {
        let store = TransferQueueStore(directory: a.appendingPathComponent("Journal"))
        XCTAssertThrowsError(try store.save([TransferJob(plan: plan())]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    func testReconnectAfterMissingDestinationResumesSameJob() throws {
        let plan = try plan(); let job = try paused(plan)
        let absent = root.appendingPathComponent("Disconnected")
        try FileManager.default.moveItem(at: targets[1], to: absent)
        XCTAssertThrowsError(try TransferEngine.execute(job))
        try FileManager.default.moveItem(at: absent, to: targets[1])
        let result = try TransferEngine.execute(job)
        XCTAssertGreaterThan(result.files[0].destinations[1].resumedBytes, 0)
    }

    func testDifferentDestinationAtSamePathIsRejected() throws {
        let plan = try plan(); let job = try paused(plan)
        try FileManager.default.moveItem(at: targets[1], to: root.appendingPathComponent("OtherDrive"))
        try FileManager.default.createDirectory(at: targets[1], withIntermediateDirectories: false)
        XCTAssertThrowsError(try TransferEngine.execute(job))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: targets[1].path).isEmpty)
    }

    func testSourceChangeAfterPausePreventsPublication() throws {
        let plan = try plan(); let job = try paused(plan)
        try Data("different original".utf8).write(to: a.appendingPathComponent("000-large.bin"))
        XCTAssertThrowsError(try TransferEngine.execute(job))
        XCTAssertTrue(targets.allSatisfy { !FileManager.default.fileExists(atPath: $0.appendingPathComponent(plan.folderName).path) })
    }

    func testPartialPublicationCanResumeWithoutRewritingCompletedDestination() throws {
        let plan = try plan(); let job = TransferJob(plan: plan); var inserted = false
        XCTAssertThrowsError(try TransferEngine.execute(job, beforeVerification: { _ in
            if !inserted { try FileManager.default.createDirectory(at: self.targets[1].appendingPathComponent(plan.folderName), withIntermediateDirectories: false); inserted = true }
        }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targets[0].appendingPathComponent(plan.folderName).path))
        try FileManager.default.removeItem(at: targets[1].appendingPathComponent(plan.folderName))
        let result = try TransferEngine.execute(job)
        XCTAssertTrue(result.files.allSatisfy { $0.destinations.allSatisfy { $0.action.contains("existing") } })
    }

    func testDuplicateLabelsAndSourceDestinationOverlapRejected() throws {
        let snapA = try CardScanner.scan(a); let snapB = try CardScanner.scan(b)
        XCTAssertThrowsError(try BatchPlanner.prepare(sources: [SourceSelection(snapshot: snapA, label: "A"), SourceSelection(snapshot: snapB, label: "a")], destinations: targets, projectName: "Bad"))
        XCTAssertThrowsError(try BatchPlanner.prepare(sources: [SourceSelection(snapshot: snapA)], destinations: [a], projectName: "Bad"))
        XCTAssertThrowsError(try BatchPlanner.prepare(sources: [SourceSelection(snapshot: snapA)], destinations: [targets[0], targets[0]], projectName: "Bad"))
    }

    func testNonIncrementalModeRejectsExistingProject() throws {
        let first = try plan(); _ = try TransferEngine.execute(TransferJob(plan: first))
        XCTAssertThrowsError(try plan(incremental: false))
    }

    func testDestinationCorruptionStopsBeforeFilePublication() throws {
        let plan = try plan(); let job = TransferJob(plan: plan)
        XCTAssertThrowsError(try TransferEngine.execute(job, beforeVerification: { path in try Data("corrupt".utf8).write(to: path) }))
        XCTAssertTrue(targets.allSatisfy { !FileManager.default.fileExists(atPath: $0.appendingPathComponent(plan.folderName).path) })
        let result = try TransferEngine.execute(job)
        XCTAssertTrue(result.files[0].destinations[0].action.contains("invalid partial"))
    }
}
