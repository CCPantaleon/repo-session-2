import XCTest
import Foundation
import Darwin
@testable import IngestCore

final class IngestTests: XCTestCase {
    var root: URL!
    var card: URL!
    var working: URL!
    var backup: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OKCopy-Unit-" + UUID().uuidString)
        card = root.appendingPathComponent("CARD")
        working = root.appendingPathComponent("SSD")
        backup = root.appendingPathComponent("BACKUP")
        for url in [card.appendingPathComponent("DCIM/100CAM"), working!, backup!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data("abc".utf8).write(to: card.appendingPathComponent("DCIM/100CAM/IMG_0001.CR3"))
        try Data(repeating: 0x39, count: 2_100_123).write(to: card.appendingPathComponent("DCIM/100CAM/IMG_0001.MOV"))
        try Data().write(to: card.appendingPathComponent("EMPTY"))
        try Data("metadata".utf8).write(to: card.appendingPathComponent(".hidden"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func request(_ name: String = "Test Project") throws -> IngestRequest {
        IngestRequest(snapshot: try CardScanner.scan(card), projectName: name, workingRoot: working, backupRoot: backup, date: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testDryRunDoesNotWriteDestinationsOrSource() throws {
        let before = try CardScanner.scan(card)
        let hashes = try before.files.map { try checksum(card.appendingPathComponent($0.relativePath)) }
        let result = try IngestEngine.dryRun(request())
        XCTAssertTrue(result.dryRun)
        XCTAssertEqual(result.files.count, 4)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: working.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backup.path).isEmpty)
        let after = try CardScanner.scan(card)
        XCTAssertEqual(before.files.map(\.stamp), after.files.map(\.stamp))
        XCTAssertEqual(hashes, try after.files.map { try checksum(card.appendingPathComponent($0.relativePath)) })
        XCTAssertTrue(result.html.contains("not copied"))
        XCTAssertFalse(result.html.contains("<script"))
    }

    func testBothCopiesMatchAndManifestIsComplete() throws {
        let req = try request(); let plan = try Planner.plan(req)
        let sourceHashes = try req.snapshot.files.map { try checksum(card.appendingPathComponent($0.relativePath)) }
        let result = try IngestEngine.execute(plan)
        XCTAssertFalse(result.dryRun)
        XCTAssertEqual(result.reports.count, 2)
        for project in plan.destinationProjects {
            for (index, file) in req.snapshot.files.enumerated() {
                let url = project.appendingPathComponent("Originals/CARD/" + file.relativePath)
                XCTAssertEqual(try checksum(url), sourceHashes[index])
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let mtime = (attrs[.modificationDate] as! Date).timeIntervalSince1970
                XCTAssertEqual(mtime, Double(file.stamp.seconds) + Double(file.stamp.nanos) / 1e9, accuracy: 0.001)
            }
            let data = try Data(contentsOf: project.appendingPathComponent("Checksums.json"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((json["files"] as? [Any])?.count, 4)
            XCTAssertEqual(json["algorithm"] as? String, "SHA-256")
        }
        XCTAssertEqual(try CardScanner.scan(card).files.map(\.stamp), req.snapshot.files.map(\.stamp))
    }

    func testChecksumMatchesKnownAnswer() throws {
        XCTAssertEqual(try checksum(card.appendingPathComponent("DCIM/100CAM/IMG_0001.CR3")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try checksum(card.appendingPathComponent("EMPTY")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testExistingProjectCannotBeOverwritten() throws {
        let plan = try Planner.plan(request())
        try FileManager.default.createDirectory(at: plan.workingProject, withIntermediateDirectories: false)
        let sentinel = plan.workingProject.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertThrowsError(try Planner.plan(request()))
        XCTAssertEqual(try String(contentsOf: sentinel), "keep")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backup.path).isEmpty)
    }

    func testDestinationOverlapRejected() throws {
        let snap = try CardScanner.scan(card)
        for target in [card!, card.appendingPathComponent("DCIM"), root!] {
            XCTAssertThrowsError(try Planner.plan(IngestRequest(snapshot: snap, projectName: "Unsafe", workingRoot: target, backupRoot: backup)))
        }
        XCTAssertThrowsError(try Planner.plan(IngestRequest(snapshot: snap, projectName: "Unsafe", workingRoot: working, backupRoot: working)))
    }

    func testSymlinkDestinationCannotBypassOverlapCheck() throws {
        let link = root.appendingPathComponent("ALIAS")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: card)
        XCTAssertThrowsError(try Planner.plan(IngestRequest(snapshot: CardScanner.scan(card), projectName: "Unsafe", workingRoot: link, backupRoot: backup)))
    }

    func testSymlinksInSourceRejected() throws {
        try FileManager.default.createSymbolicLink(at: card.appendingPathComponent("linked"), withDestinationURL: working)
        XCTAssertThrowsError(try CardScanner.scan(card))
    }

    func testSpecialFilesRejectedWithoutBlocking() throws {
        XCTAssertEqual(mkfifo(card.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertThrowsError(try CardScanner.scan(card))
    }

    func testModifiedSourceRejectedBeforeCopy() throws {
        let plan = try Planner.plan(request())
        try Data("changed".utf8).write(to: card.appendingPathComponent(".hidden"))
        XCTAssertThrowsError(try IngestEngine.execute(plan))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.workingProject.path))
    }

    func testFileAddedDuringCopyPreventsPublication() throws {
        let plan = try Planner.plan(request())
        var injected = false
        XCTAssertThrowsError(try IngestEngine.execute(plan, beforeVerification: { _, _ in
            if !injected { try Data("new".utf8).write(to: self.card.appendingPathComponent("NEW.JPG")); injected = true }
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.workingProject.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.backupProject!.path))
    }

    func testCorruptionRetainsFailureReportsAndNoFinalFolder() throws {
        let plan = try Planner.plan(request())
        do {
            _ = try IngestEngine.execute(plan, beforeVerification: { _, backup in try Data("damaged".utf8).write(to: backup) })
            XCTFail("Corruption must fail")
        } catch let error as IngestError {
            XCTAssertTrue(error.message.contains("SHA-256 mismatch"))
            XCTAssertEqual(error.reports.count, 2)
            for report in error.reports { XCTAssertTrue(try String(contentsOf: report).contains("Import incomplete")) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.workingProject.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.backupProject!.path))
    }

    func testCancellationBeforeImportLeavesNoFolders() throws {
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try IngestEngine.execute(Planner.plan(request()), token: token))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: working.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backup.path).isEmpty)
    }

    func testCancellationDuringCopyRetainsIncompleteState() throws {
        let token = CancellationToken(); let plan = try Planner.plan(request())
        XCTAssertThrowsError(try IngestEngine.execute(plan, token: token, progress: { value in
            if value.fraction > 0 { token.cancel() }
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.workingProject.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: working.path).allSatisfy { $0.contains(".incomplete-") })
    }

    func testPublishRaceDoesNotOverwriteProject() throws {
        let plan = try Planner.plan(request()); var inserted = false
        XCTAssertThrowsError(try IngestEngine.execute(plan, beforeVerification: { _, _ in
            if !inserted { try FileManager.default.createDirectory(at: plan.backupProject!, withIntermediateDirectories: false); inserted = true }
        }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: plan.backupProject!.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.workingProject.appendingPathComponent("Failure Report.html").path))
    }

    func testEscapedHTMLAndSafeProjectName() throws {
        let name = "<script>alert('x')"
        let result = try IngestEngine.dryRun(request(name))
        XCTAssertFalse(result.html.contains("<script>"))
        XCTAssertTrue(result.html.contains("&lt;script&gt;"))
        XCTAssertThrowsError(try IngestEngine.dryRun(request("Folder/Name")))
        XCTAssertEqual(try Planner.projectFolderName("Coastal Light"), "Coastal Light")
        XCTAssertEqual(try Planner.slug("  Coastal / Light  "), "Coastal-Light")
        XCTAssertThrowsError(try Planner.slug("../.."))
        XCTAssertThrowsError(try Planner.slug("  "))
    }

    func testSameFilesystemDualDestinationImportIsAllowed() throws {
        _ = try SafetyCheck.run()
        let req = try request()
        let plan = try Planner.plan(req)
        XCTAssertTrue(plan.warnings.joined().contains("share a filesystem"))
        let result = try IngestEngine.importFiles(req)
        XCTAssertEqual(result.reports.count, 2)
        XCTAssertTrue(result.files.allSatisfy { $0.sourceSHA256 == $0.workingSHA256 && $0.sourceSHA256 == $0.backupSHA256 })
    }

    func testWorkingOnlyImportOnInternalFilesystemIsAllowed() throws {
        _ = try SafetyCheck.run()
        let req = IngestRequest(snapshot: try CardScanner.scan(card), projectName: "Working Only", workingRoot: working)
        let plan = try Planner.plan(req)
        XCTAssertNil(plan.backupProject)
        let dry = try IngestEngine.dryRun(req)
        XCTAssertTrue(dry.html.contains("No backup selected"))
        let result = try IngestEngine.importFiles(req)
        XCTAssertEqual(result.reports.count, 1)
        XCTAssertTrue(result.files.allSatisfy { $0.status == "Verified" && $0.sourceSHA256 == $0.workingSHA256 && $0.backupSHA256 == nil })
        XCTAssertTrue(result.html.contains("No backup was selected or created"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backup.path).isEmpty)
        let json = try Data(contentsOf: plan.workingProject.appendingPathComponent("Checksums.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["backupSelected"] as? Bool, false)
        XCTAssertEqual(object["destinationCount"] as? Int, 1)
    }

    func testReadOnlySourceCanBeCopied() throws {
        let req = try request()
        let originals = req.snapshot.files.map { file -> URL in
            let url = card.appendingPathComponent(file.relativePath); XCTAssertEqual(chmod(url.path, 0o444), 0); return url
        }
        defer { for url in originals { _ = chmod(url.path, 0o644) } }
        let result = try IngestEngine.execute(Planner.plan(req))
        XCTAssertTrue(result.files.allSatisfy { $0.status == "Verified" })
    }

    func testWholeCameraVolumeRemainsProtected() throws {
        let scanned = try CardScanner.scan(card)
        let protected = CardSnapshot(root: scanned.root, files: scanned.files, rootStamp: scanned.rootStamp, protectedRoot: scanned.root, protectsVolume: true)
        let req = IngestRequest(snapshot: protected, projectName: "Unsafe", workingRoot: working)
        XCTAssertThrowsError(try Planner.plan(req))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: working.path).isEmpty)
    }
}
