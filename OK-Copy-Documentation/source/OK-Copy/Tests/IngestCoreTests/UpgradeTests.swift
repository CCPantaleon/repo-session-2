import XCTest
import Foundation
import Darwin
@testable import IngestCore

final class UpgradeTests: XCTestCase {
    var root: URL!
    var source: URL!
    var targets: [URL] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OKCopy-v3-" + UUID().uuidString)
        source = root.appendingPathComponent("Camera")
        targets = ["Working", "Backup", "Third"].map { root.appendingPathComponent($0) }
        for folder in [source!] + targets { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("original & untouched".utf8).write(to: source.appendingPathComponent("file & photo.jpg"))
        try Data(repeating: 27, count: 1024 * 1024 + 5).write(to: source.appendingPathComponent("video.mov"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func plan(cascade: Bool = false) throws -> BatchPlan {
        try BatchPlanner.prepare(sources: [SourceSelection(snapshot: CardScanner.scan(source))], destinations: targets, projectName: "Upgrade", options: TransferOptions(cascade: cascade))
    }
    func testOneCorruptDestinationDoesNotBlockHealthyCopiesAndRetrySkipsThem() throws {
        let plan = try plan(); let job = TransferJob(plan: plan)
        XCTAssertThrowsError(try ManagedTransfer.execute(job, beforeVerification: { url in
            if url.path.hasPrefix(self.targets[1].path + "/") { try Data("broken".utf8).write(to: url) }
        })) { error in
            let values = (error as? IngestError)?.destinations ?? []
            XCTAssertEqual(values.filter { $0.phase == "Verified" }.count, 2)
            XCTAssertTrue(values.contains { $0.root == plan.destinations[1].root && $0.error != nil })
        }
        for i in [0, 2] { XCTAssertTrue(FileManager.default.fileExists(atPath: targets[i].appendingPathComponent(plan.folderName).path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: targets[1].appendingPathComponent(plan.folderName).path))
        let resumed = try ManagedTransfer.execute(job)
        for file in resumed.files {
            XCTAssertTrue(file.destinations[0].action.contains("existing")); XCTAssertTrue(file.destinations[2].action.contains("existing"))
        }
        XCTAssertTrue(resumed.files[0].destinations[1].action.contains("invalid partial"))
    }
    func testInitiallyAbsentDestinationDoesNotBlockHealthyCopies() throws {
        let plan = try plan(); let job = TransferJob(plan: plan)
        let disconnected = root.appendingPathComponent("Disconnected")
        try FileManager.default.moveItem(at: targets[1], to: disconnected)
        XCTAssertThrowsError(try ManagedTransfer.execute(job))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targets[0].appendingPathComponent(plan.folderName).path))
        try FileManager.default.moveItem(at: disconnected, to: targets[1])
        let result = try ManagedTransfer.execute(job)
        XCTAssertEqual(result.files.count, 2)
        XCTAssertTrue(result.files.allSatisfy { $0.destinations[0].action.contains("existing") })
    }
    func testCascadeReleasesOriginalAndResumesWithCardAbsent() throws {
        let plan = try plan(cascade: true); let job = TransferJob(plan: plan)
        let disconnected = root.appendingPathComponent("CardRemoved")
        let missingBackup = root.appendingPathComponent("BackupRemoved")
        try FileManager.default.moveItem(at: targets[1], to: missingBackup)
        let release = TestFlag()
        XCTAssertThrowsError(try ManagedTransfer.execute(job, progress: { value in
            if value.phase == "Working copy verified · backups pending" && release.claim() {
                try! FileManager.default.moveItem(at: self.source, to: disconnected)
            }
        })) { XCTAssertTrue($0.localizedDescription.contains("Working copy verified")) }
        XCTAssertTrue(release.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targets[2].appendingPathComponent(plan.folderName).path))
        try FileManager.default.moveItem(at: missingBackup, to: targets[1])
        let result = try ManagedTransfer.execute(job)
        XCTAssertEqual(result.files.count, 2); XCTAssertTrue(result.files.allSatisfy { $0.destinations.count == 3 })
        XCTAssertTrue(result.destinations!.allSatisfy { $0.phase == "Verified" })
    }
    func testCascadeRefusesChangedWorkingCopyOnResume() throws {
        let plan = try plan(cascade: true); let job = TransferJob(plan: plan)
        _ = try ManagedTransfer.execute(job)
        let damaged = targets[0].appendingPathComponent(plan.folderName + "/" + plan.files[0].outputPath)
        try Data(repeating: 1, count: Int(plan.files[0].original.bytes)).write(to: damaged)
        XCTAssertThrowsError(try ManagedTransfer.execute(job)) { XCTAssertTrue($0.localizedDescription.contains("checksum mismatch")) }
    }
    func testCascadePrimaryFailureDoesNotStartBackups() throws {
        let plan = try plan(cascade: true)
        XCTAssertThrowsError(try ManagedTransfer.execute(TransferJob(plan: plan), beforeVerification: { url in try Data("bad".utf8).write(to: url) }))
        for target in targets.dropFirst() { XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty) }
    }
    func testManifestRoundTripAndCorruptionDetection() throws {
        let plan = try plan(); let result = try ManagedTransfer.execute(TransferJob(plan: plan))
        let project = targets[0].appendingPathComponent(plan.folderName)
        let manifests = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mhl" }
        XCTAssertEqual(manifests.count, 2)
        for manifest in manifests { XCTAssertTrue(try MediaManifest.verify(manifest: manifest, root: project).passed) }
        let json = result.reports[0].deletingPathExtension().appendingPathExtension("json")
        XCTAssertTrue(try MediaManifest.verify(manifest: json, root: project).passed)
        try Data("damage".utf8).write(to: project.appendingPathComponent(plan.files[0].outputPath))
        for manifest in manifests { XCTAssertFalse(try MediaManifest.verify(manifest: manifest, root: project).passed) }
    }
    func testManifestRejectsTraversalEntitiesDuplicatePathsAndUnsupportedHashes() throws {
        let manifest = root.appendingPathComponent("test.mhl")
        let sha = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        try Data("<hashlist version='1.1'><hash><file>../outside</file><sha1>\(sha)</sha1></hash></hashlist>".utf8).write(to: manifest)
        XCTAssertFalse(try MediaManifest.verify(manifest: manifest, root: source).passed)
        XCTAssertThrowsError(try MediaManifest.parse(Data("<!DOCTYPE hashlist [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><hashlist version='1.1'/>".utf8)))
        XCTAssertThrowsError(try MediaManifest.parse(Data("<hashlist version='1.1'><hash><file>a</file><sha1>\(sha)</sha1></hash><hash><file>a</file><sha1>\(sha)</sha1></hash></hashlist>".utf8)))
        try Data("<hashlist version='1.1'><hash><file>video.mov</file><xxh3>abcd</xxh3></hash></hashlist>".utf8).write(to: manifest)
        let summary = try MediaManifest.verify(manifest: manifest, root: source)
        XCTAssertFalse(summary.passed); XCTAssertEqual(summary.findings[0].status, "Unsupported")
    }
    func testManifestMissingFilesSymlinksAndCancelledVerification() throws {
        let manifest = root.appendingPathComponent("test.mhl")
        let sha = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        try Data("<hashlist version='1.1'><hash><file>missing</file><sha1>\(sha)</sha1></hash></hashlist>".utf8).write(to: manifest)
        XCTAssertFalse(try MediaManifest.verify(manifest: manifest, root: source).passed)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("missing").path, withDestinationPath: "/etc/passwd")
        XCTAssertFalse(try MediaManifest.verify(manifest: manifest, root: source).passed)
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try MediaManifest.verify(manifest: manifest, root: source, token: token))
    }
    func testSourceGroupingMergesSharedHardwareTransitively() {
        XCTAssertEqual(ManagedTransfer.groupedSources([["disk:A"], ["disk:B"], ["disk:A", "hub:1"], ["hub:1"]]), [[1], [0, 2, 3]])
        XCTAssertEqual(ManagedTransfer.groupedSources([["disk:A"], ["disk:B"]]), [[0], [1]])
    }
    func testQueuePersistsOptionsAndPerDestinationStatus() throws {
        var job = TransferJob(plan: try plan(cascade: true))
        job.destinationProgress = [DestinationProgress(root: targets[0], phase: "Verified", copiedBytes: 10, verifiedBytes: 10, totalBytes: 10)]
        let store = TransferQueueStore(directory: root.appendingPathComponent("Queue")); try store.save([job])
        let restored = try store.load()[0]
        XCTAssertTrue(restored.plan.settings.cascade); XCTAssertEqual(restored.destinationProgress?.first?.phase, "Verified")
    }
    func testOldPlansDecodeWithSafeDefaultOptions() throws {
        let encoder = JSONEncoder(); let data = try encoder.encode(plan())
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]; json.removeValue(forKey: "options")
        let restored = try JSONDecoder().decode(BatchPlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(restored.settings.cascade); XCTAssertEqual(restored.settings.concurrentSources, 2)
    }
    func testWriterFailureDoesNotStopAnotherWriter() throws {
        let token = CancellationToken(); let lock = NSLock(); var bytes = 0
        let bad = DestinationPipe(token: token) { _, _ in throw IngestError("Disconnected") }
        let good = DestinationPipe(token: token) { data, _ in lock.lock(); bytes += data.count; lock.unlock() }
        defer { bad.abortAndJoin(); good.abortAndJoin() }
        try? bad.send(Data([1]), at: 0)
        for i in 0..<8 { try good.send(Data(repeating: 1, count: 10), at: Int64(i * 10)) }
        XCTAssertThrowsError(try bad.finish()); try good.finish(); XCTAssertEqual(bytes, 80)
    }
}

private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return set }
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if set { return false }; set = true; return true }
}

extension UpgradeTests {
    func testIndependentSourcesActuallyRunConcurrentlyWithLimitTwo() throws {
        let second = root.appendingPathComponent("SecondCamera")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try Data("second card".utf8).write(to: second.appendingPathComponent("other.jpg"))
        let plan = try BatchPlanner.prepare(sources: [SourceSelection(snapshot: CardScanner.scan(source)), SourceSelection(snapshot: CardScanner.scan(second))], destinations: targets, projectName: "Concurrency", options: TransferOptions(concurrentSources: 2))
        let scheduler = StorageScheduler(urls: plan.sources.map { $0.snapshot.root } + plan.destinations.map(\.root), discover: { StorageLocation(keys: [$0.path], description: "Simulated independent device") })
        let probe = ConcurrencyProbe()
        let monitor = TransferMonitor(plan: plan, callback: { _ in })
        let result = try ManagedTransfer.direct(TransferJob(plan: plan), token: CancellationToken(), progress: { _ in }, monitor: monitor, beforeVerification: nil, storage: scheduler, sourceLifecycle: { _, started in
            if started { probe.enter(); probe.arrival.signal(); _ = probe.arrival.wait(timeout: .now() + 0.1); Thread.sleep(forTimeInterval: 0.05) }
            else { probe.leave() }
        })
        XCTAssertEqual(probe.maximum, 2); XCTAssertEqual(result.files.count, 3)
    }
    func testSchedulerSerializesSharedDisksAndAllowsIndependentReadback() {
        let a = URL(fileURLWithPath: "/sample-a"), b = URL(fileURLWithPath: "/sample-b")
        for shared in [true, false] {
            let scheduler = StorageScheduler(urls: [a, b], discover: { StorageLocation(keys: [shared ? "physical-disk" : $0.path], description: "test") })
            let probe = ConcurrencyProbe()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                scheduler.access(index == 0 ? a : b) { probe.enter(); Thread.sleep(forTimeInterval: 0.05); probe.leave() }
            }
            XCTAssertEqual(probe.maximum, shared ? 1 : 2)
        }
    }
    func testDestinationQueueBackpressureAndAbortWakeBlockedProducer() throws {
        let entered = DispatchSemaphore(value: 0); let release = DispatchSemaphore(value: 0)
        let pipe = DestinationPipe(token: CancellationToken()) { _, _ in entered.signal(); _ = release.wait(timeout: .now() + 3) }
        try pipe.send(Data([0]), at: 0); XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        try pipe.send(Data([1]), at: 1); try pipe.send(Data([2]), at: 2)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { defer { finished.signal() }; do { try pipe.send(Data([3]), at: 3); XCTFail("Blocked producer should fail") } catch { } }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
        pipe.fail(IngestError("Synthetic disconnect"))
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        release.signal(); pipe.abortAndJoin()
    }
    func testCascadeIncrementalCanCopySubsetWithoutIncludingOldProjectFiles() throws {
        let first = try plan(cascade: true); _ = try ManagedTransfer.execute(TransferJob(plan: first))
        // Camera has only a new file on a subsequent card with the same label.
        try FileManager.default.removeItem(at: source.appendingPathComponent("file & photo.jpg"))
        try FileManager.default.removeItem(at: source.appendingPathComponent("video.mov"))
        try Data("new original".utf8).write(to: source.appendingPathComponent("new.jpg"))
        let second = try plan(cascade: true)
        let result = try ManagedTransfer.execute(TransferJob(plan: second))
        XCTAssertEqual(result.files.count, 1)
        for target in targets { XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(second.folderName + "/" + first.files[0].outputPath).path)) }
    }
}
private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var high = 0
    let arrival = DispatchSemaphore(value: 0)
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return high }
    func enter() { lock.lock(); active += 1; high = max(high, active); lock.unlock() }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
}

extension UpgradeTests {
    func testXXH64KnownAnswersAndStreamingBoundaries() {
        for (text, expected) in [("", "ef46db3751d8e999"), ("a", "d24ec4f1a98c6e5b"), ("abc", "44bc2cf5ad770999")] {
            var hash = XXH64(); hash.update(Data(text.utf8)); XCTAssertEqual(hash.hex(), expected)
        }
        let data = Data((0..<65537).map { UInt8($0 % 251) })
        var whole = XXH64(); whole.update(data)
        for chunk in [1, 7, 31, 32, 33, 1024, 8192] {
            var split = XXH64()
            for start in stride(from: 0, to: data.count, by: chunk) { split.update(data.subdata(in: start..<min(data.count, start + chunk))) }
            XCTAssertEqual(split.hex(), whole.hex())
        }
    }
    func testExternalXXH64ManifestVerification() throws {
        let manifest = root.appendingPathComponent("external.mhl")
        try Data("abc".utf8).write(to: source.appendingPathComponent("external.bin"))
        try Data("<hashlist version='1.1'><hash><file>external.bin</file><size>3</size><xxhash64be>44bc2cf5ad770999</xxhash64be></hash></hashlist>".utf8).write(to: manifest)
        XCTAssertTrue(try MediaManifest.verify(manifest: manifest, root: source).passed)
        try Data("abd".utf8).write(to: source.appendingPathComponent("external.bin"))
        XCTAssertFalse(try MediaManifest.verify(manifest: manifest, root: source).passed)
    }
}
