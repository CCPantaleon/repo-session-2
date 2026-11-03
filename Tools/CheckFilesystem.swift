import Foundation
import Darwin

@main
struct CheckFilesystem {
    static var checks = 0
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw IngestError("FAILED: " + message) }
        checks += 1; print("PASS: " + message)
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        var failed = false
        do { try body() } catch { failed = true }
        try require(failed, message)
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OKCopy-Filesystem-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        let target = root.appendingPathComponent("Target")
        let work = root.appendingPathComponent("Workspace")
        for p in [source, target, work, source.appendingPathComponent(".git"), source.appendingPathComponent("Nested/.fseventsd")] {
            try fm.createDirectory(at: p, withIntermediateDirectories: true)
        }
        for name in [".env", ".git/config", "._sidecar", "Nested/normal.txt", "Nested/.fseventsd/user-file"] {
            try Data(name.utf8).write(to: source.appendingPathComponent(name))
        }
        for name in [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100"] {
            let url = source.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("OS bookkeeping".utf8).write(to: url.appendingPathComponent("entry"))
            _ = chmod(url.path, 0)
        }
        for name in [".DS_Store", "Nested/.DS_Store"] { try Data("Finder data".utf8).write(to: source.appendingPathComponent(name)) }
        let scan = try CardScanner.scan(source)
        try require(scan.files.count == 5, "Only known housekeeping entries are excluded")
        try require(scan.files.contains { $0.relativePath == ".env" } && scan.files.contains { $0.relativePath == ".git/config" }, "Ordinary hidden files and folders remain included")
        try require(scan.files.contains { $0.relativePath == "._sidecar" }, "AppleDouble sidecars remain included")
        try require(scan.files.contains { $0.relativePath == "Nested/.fseventsd/user-file" }, "Root housekeeping names are not excluded from ordinary nested folders")
        try require(scan.excludedPaths?.count == 7, "Excluded entries are listed, including protected directories and nested Finder metadata")
        let name = "102926 PMO-AIO UAE Codes"
        let plan = try BatchPlanner.prepare(sources: [SourceSelection(snapshot: scan)], destinations: [target], projectName: name)
        try require(plan.folderName == name, "Exact requested folder name is preserved")
        try require(plan.warnings.contains { $0.contains(".fseventsd") }, "Review report discloses excluded housekeeping")
        try require(try Planner.projectFolderName("Take 2 (Final) + Notes & refs #1") == "Take 2 (Final) + Notes & refs #1", "Typed punctuation and spaces are preserved")
        try require(try Planner.projectFolderName("  Exact  Name  ") == "  Exact  Name  ", "Folder names are not silently trimmed")
        try rejects("Path traversal is rejected without rewriting") { _ = try Planner.projectFolderName("../Elsewhere") }
        try rejects("Empty folder names are rejected") { _ = try Planner.projectFolderName("   ") }
        try rejects("Overlong names are rejected") { _ = try Planner.projectFolderName(String(repeating: "x", count: 256)) }
        let job = TransferJob(plan: plan)
        let compatible = try TargetContext(target: plan.destinations[0], plan: plan, sources: plan.sources, jobID: job.id, supportsExclusiveRename: false)
        try require(compatible.location.lastPathComponent == name && !compatible.isStage, "Compatible destination uses the exact folder name while copying")
        try require(compatible.workspace.exists("Incomplete"), "Compatible copy is marked incomplete until verification finishes")
        try compatible.publish()
        try require(!compatible.workspace.exists("Incomplete"), "Completion clears the incomplete marker")
        compatible.releaseLock()
        let workspace = try Directory(url: work)
        let destination = try Directory(url: target)
        let data = Data((0..<(20 * 1024 * 1024)).map { UInt8($0 % 251) })
        try workspace.writeNew("payload.part", data: data)
        let hash = try checksum(work.appendingPathComponent("payload.part"))
        let pause = CancellationToken()
        try rejects("Compatible publication can pause after writing a prefix") {
            try workspace.moveFile("payload.part", to: destination, path: "published.bin", token: pause, expectedHash: hash, forceCompatible: true, progress: { _ in pause.cancel() })
        }
        try require(workspace.exists("payload.part") && workspace.exists("payload.part.publication.json"), "Pause retains verified staging data and its ownership journal")
        let prefix = try Data(contentsOf: target.appendingPathComponent("published.bin"))
        try require(prefix.count > 0 && prefix.count < data.count, "Paused final file contains only the written prefix")
        try workspace.moveFile("payload.part", to: destination, path: "published.bin", expectedHash: hash, forceCompatible: true)
        try require(try Data(contentsOf: target.appendingPathComponent("published.bin")) == data, "Compatible publication resumes and verifies the complete file")
        try require(!workspace.exists("payload.part") && !workspace.exists("payload.part.publication.json"), "Successful publication retires staging data and journal")
        try workspace.writeNew("collision.part", data: Data("new".utf8))
        try destination.writeNew("existing.txt", data: Data("existing".utf8))
        try rejects("Compatible publication refuses an existing destination") {
            try workspace.moveFile("collision.part", to: destination, path: "existing.txt", forceCompatible: true)
        }
        try require(try Data(contentsOf: target.appendingPathComponent("existing.txt")) == Data("existing".utf8), "Existing destination contents are unchanged")
        try fm.createSymbolicLink(at: target.appendingPathComponent("link.txt"), withDestinationURL: target.appendingPathComponent("existing.txt"))
        try rejects("Compatible publication refuses a destination symlink") {
            try workspace.moveFile("collision.part", to: destination, path: "link.txt", forceCompatible: true)
        }
        try workspace.writeNew("replaced.part", data: data)
        let interrupted = CancellationToken()
        try rejects("Prepare a second interrupted publication") {
            try workspace.moveFile("replaced.part", to: destination, path: "replaced.bin", token: interrupted, forceCompatible: true, progress: { _ in interrupted.cancel() })
        }
        try fm.moveItem(at: target.appendingPathComponent("replaced.bin"), to: target.appendingPathComponent("owned-prefix.bin"))
        try destination.writeNew("replaced.bin", data: Data("another file".utf8))
        try rejects("Resume refuses a final file replaced by another file") {
            try workspace.moveFile("replaced.part", to: destination, path: "replaced.bin", forceCompatible: true)
        }
        try require(try Data(contentsOf: target.appendingPathComponent("replaced.bin")) == Data("another file".utf8), "Replaced file is preserved")
        try workspace.writeNew("corrupt.part", data: data)
        let interruptedAgain = CancellationToken()
        try rejects("Prepare an interrupted publication for corruption check") {
            try workspace.moveFile("corrupt.part", to: destination, path: "corrupt.bin", token: interruptedAgain, forceCompatible: true, progress: { _ in interruptedAgain.cancel() })
        }
        let corruptFD = try destination.updateFile("corrupt.bin")
        try writeAll(corruptFD, data: Data("bad".utf8)); close(corruptFD)
        try rejects("Resume refuses a modified saved prefix") { try workspace.moveFile("corrupt.part", to: destination, path: "corrupt.bin", forceCompatible: true) }
        try require(workspace.exists("corrupt.part"), "Corruption preserves the verified staging copy")
        try workspace.writeNew("rejection.part", data: data)
        let rejectPause = CancellationToken()
        let rejectedName = "rejection.rejected-" + UUID().uuidString
        try rejects("Preserving an invalid prefix can be interrupted") {
            try workspace.moveFile("rejection.part", to: workspace, path: rejectedName, token: rejectPause, forceCompatible: true, progress: { _ in rejectPause.cancel() })
        }
        try workspace.resumePendingPublication("rejection.part", to: destination, path: "original.bin", token: CancellationToken(), expectedHash: String(repeating: "0", count: 64))
        try require(!workspace.exists("rejection.part") && workspace.exists(rejectedName), "Interrupted invalid-prefix preservation resumes without blocking the next copy")
        let secondPlan = try BatchPlanner.prepare(sources: [SourceSelection(snapshot: scan)], destinations: [target], projectName: "Native folder with spaces")
        let secondJob = TransferJob(plan: secondPlan)
        let native = try TargetContext(target: secondPlan.destinations[0], plan: secondPlan, sources: secondPlan.sources, jobID: secondJob.id)
        try require(native.stage.hasPrefix(".OKCopy.incomplete-") && !native.stage.contains(secondPlan.folderName), "Native staging is hidden and does not append extras to the requested name")
        native.releaseLock()
        for name in [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100"] { _ = chmod(source.appendingPathComponent(name).path, 0o700) }
        print("ALL \(checks) FILESYSTEM CHECKS PASSED")
    }
}
