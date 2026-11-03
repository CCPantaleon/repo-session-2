import Foundation
import Darwin
import CryptoKit

/// Coordinates independent destination writers without weakening the immutable plan.
enum ManagedTransfer {
    static func execute(_ job: TransferJob, token: CancellationToken = CancellationToken(),
                        progress: @escaping IngestEngine.Progress = { _ in },
                        destinations: @escaping @Sendable ([DestinationProgress]) -> Void = { _ in },
                        beforeVerification: ((URL) throws -> Void)? = nil) throws -> BatchResult {
        let monitor = TransferMonitor(plan: job.plan, callback: destinations)
        defer { monitor.flush() }
        if job.plan.settings.cascade && job.plan.destinations.count > 1 {
            return try CascadingTransfer.execute(job, token: token, progress: progress, monitor: monitor, beforeVerification: beforeVerification)
        }
        return try direct(job, token: token, progress: progress, monitor: monitor, beforeVerification: beforeVerification)
    }

    static func direct(_ job: TransferJob, token: CancellationToken, progress: @escaping IngestEngine.Progress,
                       monitor: TransferMonitor, beforeVerification: ((URL) throws -> Void)?, allowAdditionalSourceFiles: Bool = false, protectedSources: [SourceSelection] = [], storage: StorageScheduler? = nil, sourceLifecycle: @escaping @Sendable (Int, Bool) -> Void = { _, _ in }) throws -> BatchResult {
        let plan = job.plan
        guard (plan.schemaVersion == 2 || (plan.schemaVersion == 3 && plan.hashDuringCopy == true)), !plan.files.isEmpty, !plan.sources.isEmpty, !plan.destinations.isEmpty,
              (1...4).contains(plan.settings.concurrentSources) else { throw IngestError("Invalid saved transfer plan") }
        try validComponent(plan.folderName)
        let current = try plan.sources.map { source -> SourceSelection in
            let scanned = try (allowAdditionalSourceFiles ? selectedSnapshot(source.snapshot, token: token) : CardScanner.scan(source.snapshot.root, token: token))
            let snapshot = allowAdditionalSourceFiles ? CardSnapshot(root: scanned.root, files: scanned.files, rootStamp: scanned.rootStamp, protectedRoot: scanned.root, protectsVolume: false) : scanned
            return SourceSelection(snapshot: snapshot, label: source.label)
        }
        var labels = Set<String>()
        for (i, source) in current.enumerated() {
            let expectedPaths = Set(plan.sources[i].snapshot.files.map(\.relativePath))
            let compared = allowAdditionalSourceFiles ? source.snapshot.files.filter { expectedPaths.contains($0.relativePath) } : source.snapshot.files
            guard try Planner.slug(source.label) == source.label, labels.insert(BatchPlanner.fold(source.label)).inserted,
                  compared.map(\.relativePath) == plan.sources[i].snapshot.files.map(\.relativePath),
                  compared.map(\.bytes) == plan.sources[i].snapshot.files.map(\.bytes) else {
                throw IngestError("The source inventory changed. Prepare a new dry run.")
            }
        }
        var names = Set<String>()
        for file in plan.files {
            guard current.indices.contains(file.sourceIndex),
                  (file.sha256.count == 64 && file.sha256.allSatisfy({ $0.isHexDigit })) || (plan.schemaVersion == 3 && plan.hashDuringCopy == true && file.sha256.isEmpty),
                  file.outputPath == plan.expectedPath(file.sourceIndex, file.original.relativePath),
                  names.insert(BatchPlanner.fold(file.outputPath)).inserted else { throw IngestError("Invalid saved paths or hashes") }
            for component in file.outputPath.split(separator: "/", omittingEmptySubsequences: false) { try validComponent(String(component)) }
        }
        guard plan.files.count == plan.sources.reduce(0, { $0 + $1.snapshot.files.count }) else { throw IngestError("Incomplete saved source inventory") }
        for (i, target) in plan.destinations.enumerated() {
            for other in plan.destinations.dropFirst(i + 1) where Planner.overlap(target.root, other.root) { throw IngestError("Destination folders overlap") }
        }
        let scheduler = storage ?? StorageScheduler(urls: current.map { $0.snapshot.root } + plan.destinations.map(\.root))
        let state = ManagedState(plan: plan, progress: progress)
        var targets: [ManagedTarget] = []
        defer { targets.forEach { $0.context.releaseLock() } }
        for identity in plan.destinations {
            do {
                try token.check()
                try BatchPlanner.validateLocations(sources: current + protectedSources, destinations: [identity])
                let context = try TargetContext(target: identity, plan: plan, sources: current + protectedSources, jobID: job.id)
                targets.append(ManagedTarget(context))
                monitor.update(identity.root, phase: "Ready", storage: scheduler.location(identity.root).description)
            } catch {
                state.error(identity.root.path + ": " + error.localizedDescription)
                monitor.update(identity.root, phase: token.isCancelled ? "Paused" : "Failed", error: error.localizedDescription)
            }
        }
        guard !targets.isEmpty else { try token.check(); throw IngestError(state.errors.joined(separator: "\n")) }
        // Recheck aggregate free space at execution/resume, allowing other volumes to continue.
        let volumeGroups = Dictionary(grouping: targets, by: { $0.context.identity.stamp.device })
        for group in volumeGroups.values {
            do {
                var remaining: [Int64] = []
                for target in group {
                    var bytes: Int64 = 0
                    var pendingFiles: [TransferFile] = []
                    for file in plan.files where try !target.context.project.contains(file.outputPath) || target.context.workspace.exists(file.id + ".part.publication.json") {
                        pendingFiles.append(file)
                        let name = file.id + ".part"
                        var prefix: Int64 = 0
                        if target.context.workspace.exists(name) {
                            let fd = try target.context.workspace.readFile(name); defer { close(fd) }
                            prefix = min(file.original.bytes, try fileSize(fd))
                        }
                        bytes += max(0, file.original.bytes - prefix)
                    }
                    if (try? target.root.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming) == false {
                        bytes += BatchPlanner.publicationOverhead(files: pendingFiles, concurrentSources: plan.settings.concurrentSources)
                    }
                    remaining.append(bytes)
                }
                try BatchPlanner.checkCapacity(group.map { $0.context.identity }, remaining: remaining)
            } catch { for target in group { target.fail(error, monitor: monitor) }; state.error(error.localizedDescription) }
        }
        // Source tasks on shared discovered resources are placed in one serial group.
        let sourceGroups = groupedSources(current.map { scheduler.location($0.snapshot.root).keys })
        let operations = OperationQueue(); operations.maxConcurrentOperationCount = plan.settings.concurrentSources
        let hookLock = NSLock()
        let contexts = targets
        for group in sourceGroups {
            operations.addOperation {
                for sourceIndex in group {
                    do {
                        sourceLifecycle(sourceIndex, true)
                        defer { sourceLifecycle(sourceIndex, false) }
                        let selection = current[sourceIndex]
                        let directory = try Directory(url: selection.snapshot.root)
                        let live = Dictionary(uniqueKeysWithValues: selection.snapshot.files.map { ($0.relativePath, $0) })
                        for file in plan.files where file.sourceIndex == sourceIndex {
                            try token.check()
                            guard contexts.contains(where: { !$0.failed }) else { throw IngestError("No writable destinations remain") }
                            guard let original = live[file.original.relativePath], original.stamp.seconds == file.original.stamp.seconds,
                                  original.stamp.nanos == file.original.stamp.nanos else { throw IngestError("Source modification time changed: " + file.outputPath) }
                            try copy(file, source: directory, live: original, targets: contexts, scheduler: scheduler, token: token,
                                     state: state, monitor: monitor, beforeVerification: { url in
                                         hookLock.lock(); defer { hookLock.unlock() }; try beforeVerification?(url)
                                     })
                        }
                        let after = try (allowAdditionalSourceFiles ? selectedSnapshot(selection.snapshot, token: token) : CardScanner.scan(selection.snapshot.root, token: token))
                        guard after.files.map(\.relativePath) == selection.snapshot.files.map(\.relativePath),
                              after.files.map(\.stamp) == selection.snapshot.files.map(\.stamp) else { throw IngestError("Source changed before completion: " + selection.label) }
                    } catch { state.sourceError(error.localizedDescription) }
                }
            }
        }
        operations.waitUntilAllOperationsAreFinished()
        let records = state.records
        let reportPlan = state.resolvedPlan
        var reports: [URL] = []
        let reportName = ((try? Planner.slug(plan.projectName)) ?? "Copy") + "-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString
        for target in targets {
            let complete = !token.isCancelled && !state.sourceFailed && !target.failed && target.completed == plan.files.count
            do {
                if complete && plan.settings.manifests {
                    monitor.update(target.root, phase: "Writing interoperable manifests")
                    try MediaManifest.export(plan: reportPlan, project: target.context.project, records: records, target: target.root, token: token)
                }
                if complete {
                    monitor.update(target.root, phase: "Publishing verified project")
                    try target.context.publish()
                    monitor.update(target.root, phase: "Verified")
                }
                let status = complete ? "Verified" : token.isCancelled ? "Paused · ready to resume" : "Destination incomplete"
                let html = BatchReport.html(reportPlan, records: records, status: status,
                    detail: "Destination: \(target.root.path). This receipt does not imply that other destinations succeeded. " + state.errors.joined(separator: " "))
                let receiptData = try BatchReport.json(reportPlan, jobID: job.id, records: records, status: status)
                if complete && !target.context.workspace.exists("PendingReport.json") {
                    try target.context.workspace.writeNew("PendingReport.json", data: JSONEncoder().encode(PendingReport(name: reportName, html: html, json: receiptData)))
                }
                let savedReport = try CopyReports.save(plan: reportPlan, name: reportName, html: html, json: receiptData, project: target.context.project)
                if complete { _ = unlinkat(target.context.workspace.fd, "PendingReport.json", 0); _ = fsync(target.context.workspace.fd) }

                if !complete { monitor.update(target.root, phase: token.isCancelled ? "Paused" : "Incomplete", error: target.message) }
                reports.append(plan.settings.reportsLocation == .destination ? target.context.location.appendingPathComponent("Ingest Reports/" + reportName + ".html") : savedReport)
            } catch {
                if complete && !target.context.isStage {
                    monitor.update(target.root, phase: "Verified · report/export needs attention", error: error.localizedDescription)
                    state.error(target.root.path + ": Files verified; report/export could not finish. " + error.localizedDescription)
                } else { target.fail(error, monitor: monitor); state.error(target.root.path + ": " + error.localizedDescription) }
            }
        }
        monitor.flush()
        if token.isCancelled || state.sourceFailed || !state.errors.isEmpty || targets.contains(where: { $0.failed || $0.completed != plan.files.count }) {
            throw IngestError((token.isCancelled ? "Paused. " : "Some destinations need attention. ") + state.errors.joined(separator: "\n") + "\nHealthy copies and partial files were retained. Resume to reverify and retry.", reports: reports, destinations: monitor.snapshot())
        }
        let html = BatchReport.html(reportPlan, records: records, status: "All selected copies verified", detail: "Every requested destination passed independent SHA-256 readback. Source files were not modified.")
        progress(IngestProgress(phase: "Import complete · every destination verified", path: "", completedFiles: records.count, totalFiles: records.count, fraction: 1))
        return BatchResult(reports: reports, html: html, files: records, destinations: monitor.snapshot())
    }

    private static func copy(_ file: TransferFile, source: Directory, live: CameraFile, targets: [ManagedTarget],
                             scheduler: StorageScheduler, token: CancellationToken, state: ManagedState, monitor: TransferMonitor,
                             beforeVerification: @escaping (URL) throws -> Void) throws {
        let sourceFD = try source.readFile(file.original.relativePath); defer { close(sourceFD) }
        try checkStamp(sourceFD, expected: live.stamp, path: file.outputPath)
        var copies: [ManagedCopy] = []
        var verified: [(ManagedTarget, DestinationReceipt)] = []
        defer { for copy in copies { copy.pipe?.abortAndJoin(); _ = fsync(copy.fd); close(copy.fd) } }
        var expectedHash: String? = file.sha256.isEmpty ? nil : file.sha256
        for target in targets where !target.failed {
            if let saved = try SourceChecksums.load(file.id, from: target.context.workspace) {
                guard expectedHash == nil || expectedHash == saved else { throw IngestError("Saved source checksums disagree: " + file.outputPath) }
                expectedHash = saved
            }
        }
        var prefixes: [Int64: String] = [:]
        for target in targets where !target.failed {
            do {
                try token.check()
                let context = target.context
                if context.workspace.exists(file.id + ".part.publication.json") {
                    monitor.update(target.root, phase: "Resuming final publication")
                    guard let expectedHash else { throw IngestError("Missing source checksum for an unfinished publication: " + file.outputPath) }
                    try context.workspace.resumePendingPublication(file.id + ".part", to: context.project, path: file.outputPath, token: token, expectedHash: expectedHash)
                }
                if try context.project.contains(file.outputPath) {
                    let fd = try context.project.readFile(file.outputPath); defer { close(fd) }
                    var sha1 = Insecure.SHA1()
                    let digest = try scheduler.access(target.root) { try stream(fd, token: token) { data in if state.needsManifest { sha1.update(data: data) }; monitor.update(target.root, phase: "Reverifying existing copy", verified: Int64(data.count)) } }
                    guard expectedHash == nil || digest == expectedHash else { throw IngestError("Content conflict: \(file.outputPath). Existing data was preserved.") }
                    monitor.update(target.root, credited: file.original.bytes)
                    state.work(file.original.bytes * 2, phase: "Reverifying existing copies", path: file.outputPath)
                    verified.append((target, DestinationReceipt(root: target.root, sha256: digest, action: "Verified existing · skipped", resumedBytes: 0, sha1: state.needsManifest ? MediaManifest.hex(sha1.finalize()) : nil)))
                    continue
                }
                let name = file.id + ".part"
                var resumed: Int64 = 0; var restarted = false
                if context.workspace.exists(name) {
                    monitor.update(target.root, phase: "Checking saved prefix")
                    let fd = try context.workspace.readFile(name); defer { close(fd) }
                    resumed = try fileSize(fd)
                    var good = resumed <= file.original.bytes
                    if good {
                        let expected: String
                        if let saved = prefixes[resumed] { expected = saved }
                        else { expected = try prefixHash(sourceFD, bytes: resumed, token: token); prefixes[resumed] = expected }
                        good = try scheduler.access(target.root) { try prefixHash(fd, bytes: resumed, token: token) == expected }
                    }
                    if !good { try context.workspace.moveFile(name, to: context.workspace, path: file.id + ".rejected-" + UUID().uuidString, token: token); resumed = 0; restarted = true }
                }
                let fd = context.workspace.exists(name) ? try context.workspace.updateFile(name) : try context.workspace.newFile(name)
                guard lseek(fd, resumed, SEEK_SET) == resumed else { close(fd); throw systemError("Cannot seek saved copy") }
                monitor.update(target.root, credited: resumed)
                let copy = ManagedCopy(target: target, fd: fd, resumed: resumed, restarted: restarted)
                var sinceFlush: Int64 = 0
                copy.pipe = DestinationPipe(token: token) { data, start in
                    guard !target.failed else { throw IngestError("Destination failed in another source transfer") }
                    let skip = Int(min(Int64(data.count), max(0, resumed - start)))
                    try scheduler.access(target.root) {
                        try writeAll(fd, data: data, startingAt: skip)
                        sinceFlush += Int64(data.count - skip)
                        if sinceFlush >= 32 * 1024 * 1024 {
                            guard fsync(fd) == 0 else { throw systemError("Could not checkpoint partial file") }; sinceFlush = 0
                        }
                    }
                    monitor.update(target.root, phase: "Copying", copied: Int64(data.count - skip))
                    state.work(Int64(data.count - skip), phase: "Copying · independent destinations", path: file.outputPath)
                }
                copies.append(copy)
            } catch {
                if token.isCancelled { throw error }
                target.fail(error, monitor: monitor); state.error(target.root.path + ": " + error.localizedDescription)
            }
        }
        guard lseek(sourceFD, 0, SEEK_SET) == 0 else { throw systemError("Cannot rewind source") }
        var position: Int64 = 0
        let digest = try pipelinedStream(sourceFD, token: token) { data in
            for copy in copies where !copy.target.failed {
                do { try copy.pipe!.send(data, at: position) }
                catch {
                    if token.isCancelled { throw error }
                    copy.target.fail(error, monitor: monitor); state.error(copy.target.root.path + ": " + error.localizedDescription)
                }
            }
            for target in targets where !target.failed { monitor.update(target.root, sourceRead: Int64(data.count)) }
            state.work(Int64(data.count) * Int64(targets.filter { !$0.failed }.count), phase: "Reading sources", path: file.outputPath)
            position += Int64(data.count)
        }
        for copy in copies {
            do { try copy.pipe!.finish() }
            catch {
                if token.isCancelled { throw error }
                copy.target.fail(error, monitor: monitor); state.error(copy.target.root.path + ": " + error.localizedDescription)
            }
        }
        try checkStamp(sourceFD, expected: live.stamp, path: file.outputPath)
        guard expectedHash == nil || digest == expectedHash, position == file.original.bytes else { throw IngestError("Source checksum changed: " + file.outputPath) }
        // Freeze each streamed source hash before final-file publication.
        for target in targets where !target.failed {
            do { try SourceChecksums.save(file.id, hash: digest, in: target.context.workspace) }
            catch { target.fail(error, monitor: monitor); state.error(target.root.path + ": " + error.localizedDescription) }
        }
        for (target, receipt) in verified where !target.failed && receipt.sha256 != digest {
            let error = IngestError("Content conflict: \(file.outputPath). Existing data was preserved.")
            target.fail(error, monitor: monitor); state.error(target.root.path + ": " + error.localizedDescription)
        }
        let resolvedFile = state.resolve(file, hash: digest)
        // Independent target readbacks overlap only when the scheduler permits it.
        let resultLock = NSLock()
        let verification = OperationQueue(); verification.maxConcurrentOperationCount = 4
        for copy in copies where !copy.target.failed {
            verification.addOperation {
                let target = copy.target
                do {
                    try token.check()
                    var times = [timespec(tv_sec: Int(file.original.stamp.seconds), tv_nsec: Int(file.original.stamp.nanos)), timespec(tv_sec: Int(file.original.stamp.seconds), tv_nsec: Int(file.original.stamp.nanos))]
                    guard futimens(copy.fd, &times) == 0, fsync(copy.fd) == 0 else { throw systemError("Cannot timestamp or flush copied file") }
                    if fcntl(copy.fd, F_FULLFSYNC) == -1 && errno != ENOTSUP && errno != EINVAL { throw systemError("Cannot flush drive cache") }
                    let name = file.id + ".part"
                    try beforeVerification(target.context.location.appendingPathComponent(".OKCopy/Jobs/\(target.context.jobID.uuidString)/" + name))
                    let fd = try target.context.workspace.readFile(name); defer { close(fd) }
                    var sha1 = Insecure.SHA1()
                    let actual = try scheduler.access(target.root) { try stream(fd, token: token) { data in
                        if state.needsManifest { sha1.update(data: data) }
                        monitor.update(target.root, phase: "Verifying", verified: Int64(data.count))
                        state.work(Int64(data.count), phase: "Verifying destinations", path: file.outputPath)
                    } }
                    guard actual == digest else { throw IngestError("Destination SHA-256 mismatch: " + file.outputPath) }
                    let receipt = DestinationReceipt(root: target.root, sha256: actual, action: copy.restarted ? "Verified · invalid partial retained and restarted" : copy.resumed > 0 ? "Verified · resumed" : "Verified · copied", resumedBytes: copy.resumed, sha1: state.needsManifest ? MediaManifest.hex(sha1.finalize()) : nil)
                    resultLock.lock(); verified.append((target, receipt)); resultLock.unlock()
                } catch { target.fail(error, monitor: monitor); state.error(target.root.path + ": " + error.localizedDescription) }
            }
        }
        verification.waitUntilAllOperationsAreFinished()
        let reread = try source.readFile(file.original.relativePath); defer { close(reread) }
        let second = try stream(reread, token: token) { data in
            for target in targets where !target.failed { monitor.update(target.root, phase: "Rechecking source", sourceRead: Int64(data.count)) }
            state.work(Int64(data.count) * Int64(targets.filter { !$0.failed }.count), phase: "Rechecking source", path: file.outputPath)
        }
        try checkStamp(reread, expected: live.stamp, path: file.outputPath)
        guard second == digest else { throw IngestError("Source changed during readback: " + file.outputPath) }
        try token.check()
        for (target, receipt) in verified where !target.failed {
            do {
                if !receipt.action.contains("existing") {
                    monitor.update(target.root, phase: "Publishing verified file")
                    try target.context.workspace.moveFile(file.id + ".part", to: target.context.project, path: file.outputPath, token: token, expectedHash: digest)
                }
                monitor.published(target.root, bytes: file.original.bytes)
                if (try? target.root.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming) == false { state.work(file.original.bytes * 3, phase: "Finalizing verified copy", path: file.outputPath) }
                state.record(resolvedFile, receipt: receipt); target.finishFile()
                monitor.update(target.root, phase: "File verified", completed: 1)
            } catch { target.fail(error, monitor: monitor); state.error(target.root.path + ": " + error.localizedDescription) }
        }
    }

    static func groupedSources(_ keys: [[String]]) -> [[Int]] {
        var groups: [[Int]] = []
        for i in keys.indices {
            var combined = [i]
            var resources = Set(keys[i])
            var changed = true
            while changed {
                changed = false
                for j in groups.indices.reversed() where groups[j].contains(where: { !resources.isDisjoint(with: keys[$0]) }) {
                    let members = groups.remove(at: j); combined += members; members.forEach { resources.formUnion(keys[$0]) }; changed = true
                }
            }
            groups.append(combined.sorted())
        }
        return groups
    }
}

private final class ManagedCopy {
    let target: ManagedTarget; let fd: Int32; let resumed: Int64; let restarted: Bool
    var pipe: DestinationPipe?
    init(target: ManagedTarget, fd: Int32, resumed: Int64, restarted: Bool) { self.target = target; self.fd = fd; self.resumed = resumed; self.restarted = restarted }
}
private final class ManagedTarget: @unchecked Sendable {
    let context: TargetContext
    private let lock = NSLock()
    private var failure: String?
    private var count = 0
    var root: URL { context.identity.root }
    init(_ context: TargetContext) { self.context = context }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return failure != nil }
    var message: String? { lock.lock(); defer { lock.unlock() }; return failure }
    var completed: Int { lock.lock(); defer { lock.unlock() }; return count }
    func finishFile() { lock.lock(); count += 1; lock.unlock() }
    func fail(_ error: Error, monitor: TransferMonitor) {
        lock.lock(); if failure == nil { failure = error.localizedDescription }; let text = failure; lock.unlock()
        monitor.update(root, phase: "Failed", error: text)
    }
}
private final class ManagedState: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    var needsManifest: Bool { plan.settings.manifests }
    private let plan: BatchPlan
    private let progress: IngestEngine.Progress
    private var entries: [String: [URL: DestinationReceipt]] = [:]
    private var resolved: [String: TransferFile] = [:]
    private var seenHashes: [String: String] = [:]
    private var messages: [String] = []
    private var sourceFailure = false
    private var bytes: Int64 = 0
    private let expectedWork: Double
    init(plan: BatchPlan, progress: @escaping IngestEngine.Progress) { self.plan = plan; self.progress = progress; expectedWork = Double(plan.totalBytes) * Double(plan.destinations.reduce(0) { sum, target in sum + (((try? target.root.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming) == false) ? 7 : 4) }) }
    func error(_ text: String) { lock.lock(); if !messages.contains(text) { messages.append(text) }; lock.unlock() }
    func sourceError(_ text: String) { lock.lock(); sourceFailure = true; lock.unlock(); error(text) }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return messages }
    var sourceFailed: Bool { lock.lock(); defer { lock.unlock() }; return sourceFailure }
    func resolve(_ file: TransferFile, hash: String) -> TransferFile {
        lock.lock(); defer { lock.unlock() }
        let key = "\(file.original.bytes):\(hash)"
        let duplicate = file.duplicateOf ?? (file.sha256.isEmpty ? seenHashes[key] : nil)
        if seenHashes[key] == nil { seenHashes[key] = file.outputPath }
        let value = TransferFile(sourceIndex: file.sourceIndex, original: file.original, outputPath: file.outputPath, sha256: hash, duplicateOf: duplicate)
        resolved[file.id] = value
        return value
    }
    var resolvedPlan: BatchPlan {
        lock.lock(); defer { lock.unlock() }
        return plan.withFiles(plan.files.map { resolved[$0.id] ?? $0 })
    }
    func record(_ file: TransferFile, receipt: DestinationReceipt) { lock.lock(); entries[file.outputPath, default: [:]][receipt.root] = receipt; lock.unlock() }
    func work(_ amount: Int64, phase: String, path: String) {
        lock.lock(); defer { lock.unlock() }; bytes += amount
        progress(IngestProgress(phase: phase, path: path, completedFiles: entries.count, totalFiles: plan.files.count, fraction: min(0.99, Double(bytes) / max(1, expectedWork))))
    }
    var records: [CopyReceipt] {
        lock.lock(); defer { lock.unlock() }
        return plan.files.compactMap { original in
            let file = resolved[original.id] ?? original
            guard let destinations = entries[file.outputPath] else { return nil }
            return CopyReceipt(sourcePath: plan.sources[file.sourceIndex].snapshot.root.appendingPathComponent(file.original.relativePath).path, outputPath: file.outputPath, bytes: file.original.bytes, sourceSHA256: file.sha256, duplicateOf: file.duplicateOf, destinations: plan.destinations.compactMap { destinations[$0.root] })
        }
    }
}

func selectedSnapshot(_ expected: CardSnapshot, token: CancellationToken) throws -> CardSnapshot {
    let directory = try Directory(url: expected.root)
    let files = try expected.files.map { original -> CameraFile in
        try token.check()
        let fd = try directory.readFile(original.relativePath); defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw systemError("Cannot inspect working copy") }
        return CameraFile(relativePath: original.relativePath, bytes: info.st_size, stamp: FileStamp(info))
    }
    return CardSnapshot(root: expected.root, files: files, rootStamp: try directory.stamp(), protectedRoot: expected.root, protectsVolume: false)
}
