import Foundation
import CryptoKit
import Darwin

public enum TransferEngine {
    public static func run(_ job: TransferJob, token: CancellationToken = CancellationToken(), progress: @escaping IngestEngine.Progress = { _ in }, destinations: @escaping @Sendable ([DestinationProgress]) -> Void = { _ in }) throws -> BatchResult {
        guard SafetyCheck.hasPassed else { throw IngestError("The generated-file safety check must pass before starting the queue.") }
        return try ManagedTransfer.execute(job, token: token, progress: progress, destinations: destinations)
    }

    static func execute(_ job: TransferJob, token: CancellationToken = CancellationToken(), progress: @escaping IngestEngine.Progress = { _ in }, beforeVerification: ((URL) throws -> Void)? = nil) throws -> BatchResult {
        try ManagedTransfer.execute(job, token: token, progress: progress, beforeVerification: beforeVerification)
    }

    static func legacyExecute(_ job: TransferJob, token: CancellationToken = CancellationToken(), progress: @escaping IngestEngine.Progress = { _ in },
                        beforeVerification: ((URL) throws -> Void)? = nil) throws -> BatchResult {
        let plan = job.plan
        guard plan.schemaVersion == 2, !plan.files.isEmpty, !plan.sources.isEmpty, !plan.destinations.isEmpty else { throw IngestError("Unsupported or incomplete saved job.") }
        try validComponent(plan.folderName)
        let current = try plan.sources.map { SourceSelection(snapshot: try CardScanner.scan($0.snapshot.root, token: token), label: $0.label) }
        try BatchPlanner.validateLocations(sources: current, destinations: plan.destinations)
        for (i, source) in current.enumerated() {
            let before = plan.sources[i].snapshot.files
            guard source.snapshot.files.map(\.relativePath) == before.map(\.relativePath),
                  source.snapshot.files.map(\.bytes) == before.map(\.bytes) else {
                throw IngestError("The inventory changed for \(source.label). Prepare a new dry run before importing changed card contents.")
            }
            _ = try Planner.slug(source.label)
        }
        for file in plan.files {
            guard current.indices.contains(file.sourceIndex), file.original.bytes >= 0,
                  file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit }),
                  file.outputPath == "Originals/\(current[file.sourceIndex].label)/\(file.original.relativePath)" else {
                throw IngestError("Invalid paths or checksum in saved job.")
            }
            for component in file.outputPath.split(separator: "/", omittingEmptySubsequences: false) { try validComponent(String(component)) }
        }
        var contexts: [TargetContext] = []
        var records: [CopyReceipt] = []
        let liveFiles = current.map { Dictionary(uniqueKeysWithValues: $0.snapshot.files.map { ($0.relativePath, $0) }) }
        var workBytes: Int64 = 0
        let totalWork = max(Double(plan.totalBytes) * Double(plan.destinations.count + 2), 1)
        func update(_ phase: String, _ path: String) {
            progress(IngestProgress(phase: phase, path: path, completedFiles: records.count, totalFiles: plan.files.count,
                fraction: min(Double(workBytes) / totalWork, 0.99)))
        }
        do {
            try token.check()
            // Validate every mounted target before creating the first staging directory.
            for target in plan.destinations { try target.validate(Directory(url: target.root)) }
            for target in plan.destinations { contexts.append(try TargetContext(target: target, plan: plan, sources: current, jobID: job.id)) }
            var remaining = [Int64](repeating: 0, count: contexts.count)
            for (index, context) in contexts.enumerated() {
                for file in plan.files {
                    if try context.project.contains(file.outputPath) { continue }
                    var partial: Int64 = 0
                    let part = file.id + ".part"
                    if context.workspace.exists(part) {
                        let fd = try context.workspace.readFile(part); defer { close(fd) }
                        partial = min(try fileSize(fd), file.original.bytes)
                    }
                    remaining[index] += max(0, file.original.bytes - partial)
                }
            }
            try BatchPlanner.checkCapacity(plan.destinations, remaining: remaining)
            let sourceDirectories = try current.map { try Directory(url: $0.snapshot.root) }
            for file in plan.files {
                try token.check()
                update("Checking saved copies", file.outputPath)
                let live = try liveFiles[file.sourceIndex][file.original.relativePath].unwrap("Source file disappeared")
                guard live.stamp.seconds == file.original.stamp.seconds, live.stamp.nanos == file.original.stamp.nanos else {
                    throw IngestError("Source modification time changed: \(file.outputPath). Run a new dry run.")
                }
                let source = sourceDirectories[file.sourceIndex]
                let sourceFD = try source.readFile(file.original.relativePath); defer { close(sourceFD) }
                try checkStamp(sourceFD, expected: live.stamp, path: file.original.relativePath)
                var pending: [PendingCopy] = []
                var sourcePrefixHashes: [Int64: String] = [:]
                var receipts: [Int: DestinationReceipt] = [:]
                defer { for copy in pending { _ = fsync(copy.fd); close(copy.fd) } }
                for (index, context) in contexts.enumerated() {
                    try token.check()
                    if context.workspace.exists(file.id + ".part.publication.json") {
                        try context.workspace.resumePendingPublication(file.id + ".part", to: context.project, path: file.outputPath, token: token, expectedHash: file.sha256)
                    }
                    if try context.project.contains(file.outputPath) {
                        let fd = try context.project.readFile(file.outputPath); defer { close(fd) }
                        let digest = try stream(fd, token: token) { data in workBytes += Int64(data.count); update("Reverifying existing destination \(index + 1)", file.outputPath) }
                        guard digest == file.sha256 else { throw IngestError("Content conflict at \(context.location.appendingPathComponent(file.outputPath).path). Existing data was preserved.") }
                        receipts[index] = DestinationReceipt(root: context.identity.root, sha256: digest, action: "Verified existing · skipped", resumedBytes: 0)
                        continue
                    }
                    let name = file.id + ".part"
                    var resumed: Int64 = 0
                    var restarted = false
                    if context.workspace.exists(name) {
                        update("Validating saved prefix for destination \(index + 1)", file.outputPath)
                        let good: Bool
                        do {
                            let fd = try context.workspace.readFile(name); defer { close(fd) }
                            resumed = try fileSize(fd)
                            if resumed <= file.original.bytes {
                                let expected: String
                                if let saved = sourcePrefixHashes[resumed] { expected = saved }
                                else { expected = try prefixHash(sourceFD, bytes: resumed, token: token); sourcePrefixHashes[resumed] = expected }
                                good = try expected == prefixHash(fd, bytes: resumed, token: token)
                            } else { good = false }
                        }
                        if !good {
                            try context.workspace.moveFile(name, to: context.workspace, path: file.id + ".rejected-" + UUID().uuidString, token: token)
                            resumed = 0; restarted = true
                        }
                    }
                    let output = context.workspace.exists(name) ? try context.workspace.updateFile(name) : try context.workspace.newFile(name)
                    guard lseek(output, resumed, SEEK_SET) == resumed else { close(output); throw systemError("Cannot seek partial file") }
                    pending.append(PendingCopy(index: index, fd: output, resumed: resumed, restarted: restarted))
                }
                guard lseek(sourceFD, 0, SEEK_SET) == 0 else { throw systemError("Cannot rewind source") }
                var position: Int64 = 0
                var sinceFlush: Int64 = 0
                let groups = Dictionary(grouping: pending, by: { contexts[$0.index].identity.stamp.device }).values.map(Array.init)
                let sourceDigest = try pipelinedStream(sourceFD, token: token) { data in
                    let start = position
                    let failures = WriteFailures()
                    DispatchQueue.concurrentPerform(iterations: groups.count) { groupIndex in
                        for output in groups[groupIndex] {
                            let skip = Int(min(Int64(data.count), max(0, output.resumed - start)))
                            do { try writeAll(output.fd, data: data, startingAt: skip) } catch { failures.record(error.localizedDescription) }
                        }
                    }
                    if let failure = failures.first { throw IngestError(failure) }
                    position += Int64(data.count); sinceFlush += Int64(data.count)
                    if sinceFlush >= 32 * 1024 * 1024 {
                        for output in pending { guard fsync(output.fd) == 0 else { throw systemError("Could not checkpoint partial copy") } }
                        sinceFlush = 0
                    }
                    workBytes += Int64(data.count); update(pending.isEmpty ? "Rechecking source for existing copies" : "Copying · parallel destinations", file.outputPath)
                }
                try checkStamp(sourceFD, expected: live.stamp, path: file.original.relativePath)
                guard sourceDigest == file.sha256, position == file.original.bytes else { throw IngestError("Source checksum changed: \(file.outputPath). Partial copies were retained.") }
                for output in pending {
                    var times = [timespec(tv_sec: Int(file.original.stamp.seconds), tv_nsec: Int(file.original.stamp.nanos)), timespec(tv_sec: Int(file.original.stamp.seconds), tv_nsec: Int(file.original.stamp.nanos))]
                    guard futimens(output.fd, &times) == 0, fsync(output.fd) == 0 else { throw systemError("Could not flush or timestamp the copied file") }
                    if fcntl(output.fd, F_FULLFSYNC) == -1 && errno != ENOTSUP && errno != EINVAL { throw systemError("Could not flush drive cache") }
                    let context = contexts[output.index]
                    let name = file.id + ".part"
                    try beforeVerification?(context.location.appendingPathComponent(".OKCopy/Jobs/\(job.id.uuidString)/" + name))
                    let fd = try context.workspace.readFile(name); defer { close(fd) }
                    let digest = try stream(fd, token: token) { data in workBytes += Int64(data.count); update("Verifying destination \(output.index + 1)", file.outputPath) }
                    guard digest == sourceDigest else { throw IngestError("Destination SHA-256 mismatch: \(context.location.path)/\(file.outputPath). Resume will check and restart the invalid partial file.") }
                    receipts[output.index] = DestinationReceipt(root: context.identity.root, sha256: digest,
                        action: output.restarted ? "Verified · invalid partial retained and restarted" : output.resumed > 0 ? "Verified · resumed" : "Verified · copied", resumedBytes: output.resumed)
                }
                let reread = try source.readFile(file.original.relativePath); defer { close(reread) }
                let second = try stream(reread, token: token) { data in workBytes += Int64(data.count); update("Rechecking source", file.outputPath) }
                try checkStamp(reread, expected: live.stamp, path: file.original.relativePath)
                guard second == file.sha256 else { throw IngestError("The source changed during verification: \(file.outputPath)") }
                try token.check()
                for output in pending {
                    try contexts[output.index].workspace.moveFile(file.id + ".part", to: contexts[output.index].project, path: file.outputPath)
                }
                records.append(CopyReceipt(sourcePath: current[file.sourceIndex].snapshot.root.appendingPathComponent(file.original.relativePath).path,
                    outputPath: file.outputPath, bytes: file.original.bytes, sourceSHA256: file.sha256, duplicateOf: file.duplicateOf,
                    destinations: contexts.indices.compactMap { receipts[$0] }))
                update("File verified at every destination", file.outputPath)
            }
            for (index, source) in current.enumerated() {
                let after = try CardScanner.scan(source.snapshot.root, token: token)
                guard after.files.map(\.relativePath) == source.snapshot.files.map(\.relativePath), after.files.map(\.stamp) == current[index].snapshot.files.map(\.stamp) else {
                    throw IngestError("Source inventory changed before completion: \(source.label)")
                }
            }
            try token.check()
            let html = BatchReport.html(plan, records: records, status: "All selected copies verified", detail: "Every selected destination matched the source SHA-256. Existing identical files were reverified; incomplete files were resumed only after validating their saved prefix. A project ending in .incomplete has not finished publication.")
            let json = try BatchReport.json(plan, jobID: job.id, records: records, status: "Verified")
            // A unique receipt per attempt avoids replacing any earlier report.
            let reportName = "Ingest Reports/" + job.id.uuidString + "-" + UUID().uuidString.prefix(8)
            for context in contexts {
                try context.project.writeNew(reportName + ".html", data: Data(html.utf8))
                try context.project.writeNew(reportName + ".json", data: json)
            }
            for context in contexts { try context.publish() }
            let reports = contexts.map { $0.location.appendingPathComponent(reportName + ".html") }
            progress(IngestProgress(phase: "Import complete · every destination verified", path: "", completedFiles: records.count, totalFiles: records.count, fraction: 1))
            return BatchResult(reports: reports, html: html, files: records)
        } catch {
            let html = BatchReport.html(plan, records: records, status: token.isCancelled ? "Paused · ready to resume" : "Import incomplete", detail: error.localizedDescription + " Verified files and partial copies were retained. Resume this saved job to reverify and continue. No original card files were changed.")
            var reports: [URL] = []
            let name = "Ingest Reports/Incomplete-" + UUID().uuidString + ".html"
            for context in contexts {
                if (try? context.project.writeNew(name, data: Data(html.utf8))) != nil { reports.append(context.location.appendingPathComponent(name)) }
            }
            throw IngestError(error.localizedDescription + "\nResume the saved job after reconnecting its sources and destinations.", reports: reports)
        }
    }
}

final class TargetContext {
    let jobID: UUID
    let identity: DestinationIdentity
    let root: Directory
    let project: Directory
    let workspace: Directory
    let folder: String
    let stage: String
    var isStage: Bool
    private var lockFD: Int32
    var location: URL { (try? project.actualURL()) ?? identity.root.appendingPathComponent(isStage ? stage : folder) }
    init(target: DestinationIdentity, plan: BatchPlan, sources: [SourceSelection], jobID: UUID, supportsExclusiveRename: Bool? = nil) throws {
        self.jobID = jobID
        identity = target; root = try Directory(url: target.root)
        try target.validate(root)
        let actual = try root.actualURL()
        for source in sources {
            guard !Planner.overlap(source.snapshot.protectedRoot, actual) else { throw IngestError("A destination moved into a protected source.") }
            if try source.snapshot.protectsVolume && root.stamp().device == source.snapshot.rootStamp.device { throw IngestError("The original camera card cannot receive writes.") }
        }
        let canRename = supportsExclusiveRename ?? ((try? target.root.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming) ?? true)
        folder = plan.folderName
        let legacyStage = plan.folderName + ".incomplete-" + jobID.uuidString
        stage = legacyStage.utf8.count <= 255 && root.exists(legacyStage) ? legacyStage : ".OKCopy.incomplete-" + jobID.uuidString
        let owner = Data(jobID.uuidString.utf8)
        if plan.usesDestinationRoot {
            project = root; isStage = false
        } else if root.exists(stage) {
            guard canRename else { throw IngestError("This older staged job cannot be published on this filesystem. Keep its partial files and review a new copy using the original source.") }
            project = try root.child(stage); isStage = true
            guard try project.smallData(".OKCopy-Owner") == owner else { throw IngestError("Staging folder belongs to another job.") }
        } else if root.exists(folder) {
            project = try root.child(folder); isStage = false
            if !plan.incremental {
                guard try project.contains(".OKCopy/Jobs/\(jobID.uuidString)/Owner"),
                      try project.smallData(".OKCopy/Jobs/\(jobID.uuidString)/Owner") == owner else {
                    throw IngestError("An existing project cannot be overwritten. Enable incremental copies or use another project name.")
                }
            }
        } else {
            project = try root.makeStage(canRename ? stage : folder); isStage = canRename
            try project.writeNew(".OKCopy-Owner", data: owner)
        }
        let jobs = try project.child(".OKCopy", create: true).child("Jobs", create: true)
        if jobs.exists(jobID.uuidString) {
            workspace = try jobs.child(jobID.uuidString)
            guard try workspace.smallData("Owner") == owner else { throw IngestError("Unrecognized partial-copy workspace. Existing data was preserved.") }
        } else {
            workspace = try jobs.makeStage(jobID.uuidString)
            try workspace.writeNew("Owner", data: owner)
        }
        lockFD = try workspace.readFile("Owner")
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); throw IngestError("This job is already running in another process.") }
        if !workspace.exists("Incomplete") { try workspace.writeNew("Incomplete", data: Data("Copy not yet verified. Consult the app and report for completion.".utf8)) }
    }
    func releaseLock() { if lockFD >= 0 { close(lockFD); lockFD = -1 } }
    deinit { releaseLock() }
    func publish() throws {
        if isStage { try root.publish(stage: stage, final: folder); isStage = false }
        if workspace.exists("Incomplete"), unlinkat(workspace.fd, "Incomplete", 0) != 0 { throw systemError("Cannot clear incomplete-copy marker") }
        _ = fsync(workspace.fd)
    }
}

private struct PendingCopy {
    let index: Int
    let fd: Int32
    let resumed: Int64
    let restarted: Bool
}
private final class WriteFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    func record(_ error: String) { lock.lock(); if message == nil { message = error }; lock.unlock() }
    var first: String? { lock.lock(); defer { lock.unlock() }; return message }
}
func fileSize(_ fd: Int32) throws -> Int64 {
    var info = stat(); guard fstat(fd, &info) == 0 else { throw systemError("Cannot inspect partial file") }; return info.st_size
}
func prefixHash(_ fd: Int32, bytes: Int64, token: CancellationToken) throws -> String {
    guard lseek(fd, 0, SEEK_SET) == 0 else { throw systemError("Cannot read saved prefix") }
    var remaining = bytes
    var buffer = [UInt8](repeating: 0, count: 8 * 1024 * 1024)
    var hash = SHA256()
    while remaining > 0 {
        try token.check()
        let count = Darwin.read(fd, &buffer, min(buffer.count, Int(remaining)))
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw IngestError("Saved partial file or source prefix is unreadable") }
        hash.update(data: Data(buffer[0..<count])); remaining -= Int64(count)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped { guard let value = self else { throw IngestError(message) }; return value }
}
