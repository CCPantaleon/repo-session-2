import Foundation
import IngestCore

@main
@MainActor
struct CheckCopyWorkflow {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "CopyWorkflow", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS: " + message)
    }
    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(45)
        while !condition() {
            if Date() > deadline { throw NSError(domain: "CopyWorkflow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for model"]) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OKCopy-Workflow-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Documents")
        let destA = root.appendingPathComponent("Destination-A")
        let destB = root.appendingPathComponent("Destination-B")
        for url in [source.appendingPathComponent("Nested"), destA, destB] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let payload = Data("A folder copy with no camera files.\n".utf8)
        try payload.write(to: source.appendingPathComponent("Nested/notes.txt"))
        try Data([0, 1, 2, 3, 255]).write(to: source.appendingPathComponent("data.bin"))
        let queue = root.appendingPathComponent("Queue")
        let model = AppModel(queueDirectory: queue)
        try await waitUntil { !model.safetyRunning }
        try require(model.safety != nil, "Built-in safety checks pass")
        try require(model.reportStorage == .app, "New copies default to keeping reports in the app")
        let reports = root.appendingPathComponent("Reports")
        try fm.createDirectory(at: reports, withIntermediateDirectories: false)
        model.reportStorage = .folder; model.reportFolder = reports
        try require(!model.exportManifests, "Camera manifest export is optional and off by default")
        model.addSources([source], sample: false)
        try await waitUntil { !model.busy }
        try require(model.projectName == "Documents", "Copy name derives from the selected folder")
        model.destinations = [destA, destB]
        model.invalidate()
        model.reviewCopy()
        try await waitUntil { !model.busy }
        try require(model.canCopy, "Review enables Start Copy for ordinary folders")
        let emptyA = try fm.contentsOfDirectory(atPath: destA.path).isEmpty
        try require(emptyA, "Review does not write to destination A")
        let emptyB = try fm.contentsOfDirectory(atPath: destB.path).isEmpty
        try require(emptyB, "Review does not write to destination B")
        model.queuePrepared()
        try require(model.jobs.count == 1 && model.jobs[0].status == .queued && !model.queueRunning, "Add to Queue saves without starting")
        model.projectName = "Immediate Copy"
        model.invalidate()
        model.reviewCopy()
        try await waitUntil { !model.busy }
        try require(model.canCopy, "Second copy is ready")
        model.copyPrepared()
        try await waitUntil { !model.queueRunning }
        try require(model.jobs.count == 2 && model.jobs[0].status == .queued && model.jobs[1].status == .completed, "Start Copy runs only the new job and leaves the older job queued")
        let folder = model.jobs[1].plan.folderName
        for dest in [destA, destB] {
            let copied = try Data(contentsOf: dest.appendingPathComponent(folder + "/Originals/Documents/Nested/notes.txt"))
            try require(copied == payload, "Ordinary nested files match at " + dest.lastPathComponent)
            let names = try fm.contentsOfDirectory(atPath: dest.appendingPathComponent(folder).path)
            try require(!names.contains { $0.hasSuffix(".mhl") }, "Optional MHL manifests absent at " + dest.lastPathComponent)
        }
        model.projectName = "Invalid Review"
        model.invalidate()
        try require(model.phase == "Ready to copy" && model.fraction == 0, "Changing a completed copy clears its old completion status")
        model.reviewCopy()
        try await waitUntil { !model.busy }
        try require(model.canCopy, "A valid review exists before invalidating source")
        let link = source.appendingPathComponent("unsupported-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source.appendingPathComponent("data.bin"))
        model.reviewCopy()
        try await waitUntil { !model.busy }
        try require(!model.canCopy && !model.inspected && model.errorMessage != nil, "A failed repeated review clears the stale prepared plan")
        try fm.removeItem(at: link)
        model.projectName = "With Manifests"
        model.exportManifests = true
        model.invalidate()
        model.reviewCopy()
        try await waitUntil { !model.busy }
        try require(model.canCopy, "Optional camera settings can be reviewed")
        model.copyPrepared()
        try await waitUntil { !model.queueRunning }
        try require(model.jobs.last?.status == .completed, "Copy with camera manifests completes")
        let manifestFolder = model.jobs.last!.plan.folderName
        let manifestNames = try fm.contentsOfDirectory(atPath: destA.appendingPathComponent(manifestFolder).path)
        try require(manifestNames.filter { $0.hasSuffix(".mhl") }.count == 2, "Optional camera settings export both MHL formats")
        let restored = try TransferQueueStore(directory: queue).load()
        try require(restored.count == 3 && restored[0].status == .queued && restored[1].status == .completed && restored[2].status == .completed, "Queue state persists with the unstarted job intact")
        model.projectName = "Immediate without review"
        model.exportManifests = false
        model.invalidate()
        try require(model.canStart && !model.inspected, "Start Copy is available without a review")
        model.startCopy()
        try await waitUntil { !model.hasActiveWork }
        try require(model.jobs.count == 4 && model.jobs.last?.status == .completed, "Unreviewed Start Copy completes automatically")
        try require(model.jobs[0].status == .queued && model.jobs.last?.plan.hashDuringCopy == true, "Immediate copy leaves older jobs queued and hashes during copying")
        model.projectName = "Queued without review"
        model.invalidate()
        model.queueCopy()
        try await waitUntil { !model.hasActiveWork }
        try require(model.jobs.count == 5 && model.jobs.last?.status == .queued, "Add to Queue also works without a review")
        // Resume must leave unrelated older and later queued jobs untouched.
        let selected = model.jobs.count - 1
        model.jobs[selected].status = .paused
        model.resumeJob(model.jobs[selected].id)
        try await waitUntil { !model.hasActiveWork }
        try require(model.jobs[0].status == .queued && model.jobs[selected].status == .completed, "Resume runs only the selected job")
        print("ALL WORKFLOW CHECKS PASSED")
    }
}
