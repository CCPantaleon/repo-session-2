import XCTest
import Foundation
@testable import IngestCore

final class StabilizationTests: XCTestCase {
    func testDirectReportsAndRestoredQueuePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source"), dest = root.appendingPathComponent("Dest")
        for d in [source, dest] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("original".utf8).write(to: source.appendingPathComponent("file"))
        var options = TransferOptions(manifests: false); options.layout = .destination; options.reportStorage = .destination
        let plan = try BatchPlanner.prepare(sources: [SourceSelection(snapshot: CardScanner.scan(source))], destinations: [dest], projectName: "NoWrapper", options: options, hashDuringCopy: true)
        let result = try TransferEngine.execute(TransferJob(plan: plan))
        XCTAssertTrue(result.reports.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertFalse(result.html.contains(dest.appendingPathComponent("NoWrapper").path))
        var job = TransferJob(plan: plan); job.status = .running; job.reports = result.reports
        job.destinationProgress = [DestinationProgress(estimatedSecondsRemaining: 120, root: dest, phase: "Copying", totalBytes: 8)]
        let store = TransferQueueStore(directory: root.appendingPathComponent("Queue")); try store.save([job])
        let restored = try store.load()[0]
        XCTAssertEqual(restored.status, .paused); XCTAssertNil(restored.destinationProgress![0].estimatedSecondsRemaining)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.reports[0].path))
    }
    func testReportFailureRetainsPublishedVerifiedCopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Source"), dest = root.appendingPathComponent("Dest"), reports = root.appendingPathComponent("Reports")
        for d in [source, dest, reports] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let original = source.appendingPathComponent("file"); try Data("original".utf8).write(to: original)
        var options = TransferOptions(manifests: false); options.reportStorage = .folder; options.reportFolder = reports
        let plan = try BatchPlanner.prepare(sources: [SourceSelection(snapshot: CardScanner.scan(source))], destinations: [dest], projectName: "Project", options: options, hashDuringCopy: true)
        let job = TransferJob(plan: plan)
        XCTAssertThrowsError(try TransferEngine.execute(job, beforeVerification: { _ in try? fm.removeItem(at: reports) })) { error in
            XCTAssertTrue((error as? IngestError)?.destinations?.first?.phase.hasPrefix("Verified") == true)
        }
        XCTAssertEqual(try checksum(original), try checksum(dest.appendingPathComponent("Project/Originals/Source/file")))
        try fm.createDirectory(at: reports, withIntermediateDirectories: false)
        try fm.removeItem(at: source)
        let recovered = try TransferEngine.retryReports(job)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: recovered[0].path))
        XCTAssertTrue(try TransferEngine.retryReports(job).isEmpty)
    }
    func testMixedUnknownHashIsNeverFullyVerified() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"); try Data("original".utf8).write(to: file)
        let hash = try checksum(file), manifest = root.appendingPathComponent("test.mhl")
        try Data("<hashlist version='1.1'><hash><file>file</file><sha256>\(hash)</sha256><sha512>0000</sha512></hash></hashlist>".utf8).write(to: manifest)
        let result = try MediaManifest.verify(manifest: manifest, root: root)
        XCTAssertFalse(result.passed); XCTAssertEqual(result.findings[0].status, "Unsupported")
    }
}
