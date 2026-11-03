import XCTest
import Foundation
@testable import IngestCore

final class LayoutTests: XCTestCase {
    func fixture(_ body: (URL, URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OKCopy-Layout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("Source"), dst = root.appendingPathComponent("Destination"), reports = root.appendingPathComponent("Reports")
        for folder in [src, dst, reports] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("original".utf8).write(to: src.appendingPathComponent("photo.raw"))
        try body(root, src, dst, reports)
    }
    func testLayoutsAndReportExportWithoutOriginals() throws {
        for layout in [CopyLayout.folder, .destination] {
            try fixture { _, src, dst, reports in
                var options = TransferOptions(manifests: false); options.layout = layout; options.reportStorage = .folder; options.reportFolder = reports
                let plan = try BatchPlanner.prepare(sources: [SourceSelection(snapshot: CardScanner.scan(src))], destinations: [dst], projectName: "Exact Name", options: options, hashDuringCopy: true)
                XCTAssertEqual(plan.files[0].outputPath, "photo.raw")
                let result = try TransferEngine.execute(TransferJob(plan: plan))
                let project = layout == .destination ? dst : dst.appendingPathComponent("Exact Name")
                XCTAssertEqual(try checksum(project.appendingPathComponent("photo.raw")), result.files[0].sourceSHA256)
                XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Originals").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Ingest Reports").path))
                XCTAssertTrue(result.reports.allSatisfy { $0.path.hasPrefix(reports.path + "/") })
            }
        }
    }
    func testDirectCascadeResumeWithOriginalAbsent() throws {
        try fixture { root, src, dst, reports in
            let backup = root.appendingPathComponent("Backup"); try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
            var options = TransferOptions(cascade: true, manifests: false); options.layout = .destination; options.reportStorage = .folder; options.reportFolder = reports
            let plan = try BatchPlanner.prepare(sources: [SourceSelection(snapshot: CardScanner.scan(src))], destinations: [dst, backup], projectName: "Direct", options: options, hashDuringCopy: true)
            let job = TransferJob(plan: plan); _ = try TransferEngine.execute(job)
            try FileManager.default.moveItem(at: src, to: root.appendingPathComponent("Removed"))
            let result = try TransferEngine.execute(job)
            XCTAssertEqual(result.files[0].destinations.count, 2)
            XCTAssertEqual(try checksum(dst.appendingPathComponent("photo.raw")), try checksum(backup.appendingPathComponent("photo.raw")))
        }
    }
    func testMultiSourceDirectUsesLabelsAndConflictsPreserved() throws {
        try fixture { root, src, dst, reports in
            let second = root.appendingPathComponent("Second"); try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
            try Data("second".utf8).write(to: second.appendingPathComponent("photo.raw"))
            var options = TransferOptions(manifests: false); options.layout = .destination; options.reportStorage = .folder; options.reportFolder = reports
            let sources = try [src, second].map { SourceSelection(snapshot: try CardScanner.scan($0)) }
            let plan = try BatchPlanner.prepare(sources: sources, destinations: [dst], projectName: "Direct", options: options)
            XCTAssertEqual(plan.files.map(\.outputPath), ["Source/photo.raw", "Second/photo.raw"])
            _ = try TransferEngine.execute(TransferJob(plan: plan))
            try Data("conflict".utf8).write(to: dst.appendingPathComponent("Source/photo.raw"))
            XCTAssertThrowsError(try TransferEngine.execute(TransferJob(plan: plan)))
            XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("Source/photo.raw")), "conflict")
        }
    }
    func testReportFolderCannotBeSource() throws {
        try fixture { _, src, dst, _ in
            var options = TransferOptions(); options.reportStorage = .folder; options.reportFolder = src
            XCTAssertThrowsError(try BatchPlanner.prepare(sources: [SourceSelection(snapshot: CardScanner.scan(src))], destinations: [dst], projectName: "Safe", options: options))
        }
    }
    func testETARequiresWarmupAndAdaptsToRate() {
        var estimator = RemainingTimeEstimator()
        XCTAssertNil(estimator.update(bytes: 0, remaining: 1000, now: 0))
        XCTAssertNil(estimator.update(bytes: 100, remaining: 900, now: 1))
        let first = estimator.update(bytes: 300, remaining: 700, now: 3)!
        XCTAssertEqual(first, 7, accuracy: 0.1)
        let slow = estimator.update(bytes: 310, remaining: 690, now: 8)!
        XCTAssertGreaterThan(slow, first)
        XCTAssertNil(estimator.update(bytes: 310, remaining: 690, now: 7)) // monotonic clocks cannot move backwards
    }
}
