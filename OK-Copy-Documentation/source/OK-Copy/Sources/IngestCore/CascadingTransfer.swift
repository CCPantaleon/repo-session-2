import Foundation
import Darwin

extension BatchPlan {
    func withFiles(_ files: [TransferFile]) -> BatchPlan {
        BatchPlan(hashDuringCopy: hashDuringCopy, options: options, schemaVersion: schemaVersion, projectName: projectName, folderName: folderName,
                  sources: sources, destinations: destinations, files: files, incremental: incremental, createdAt: createdAt,
                  warnings: warnings, existingCopies: existingCopies)
    }
    func subset(destinations: [DestinationIdentity], sources: [SourceSelection]? = nil, files: [TransferFile]? = nil) -> BatchPlan {
        var options = settings; options.cascade = false
        return BatchPlan(hashDuringCopy: hashDuringCopy, options: options, schemaVersion: schemaVersion, projectName: projectName, folderName: folderName,
                         sources: sources ?? self.sources, destinations: destinations, files: files ?? self.files,
                         incremental: incremental, createdAt: createdAt, warnings: warnings, existingCopies: existingCopies)
    }
}

extension TransferJob {
    func using(_ plan: BatchPlan) -> TransferJob { TransferJob(id: id, plan: plan, status: status, lastError: lastError, reports: reports, finishedFiles: finishedFiles) }
}

enum CascadingTransfer {
    static func execute(_ job: TransferJob, token: CancellationToken, progress: @escaping IngestEngine.Progress,
                        monitor: TransferMonitor, beforeVerification: ((URL) throws -> Void)?) throws -> BatchResult {
        var plan = job.plan
        let primary = plan.destinations[0]
        try primary.validate(Directory(url: primary.root))
        let projectURL = plan.projectURL(primary)
        let ready = ".OKCopy/Jobs/\(job.id.uuidString)/Cascade-Ready"
        let primaryWeight = 1.0 / Double(plan.destinations.count)
        let primaryProgress: IngestEngine.Progress = { value in
            progress(IngestProgress(phase: value.phase, path: value.path, completedFiles: value.completedFiles, totalFiles: value.totalFiles, fraction: value.fraction * primaryWeight))
        }
        let backupProgress: IngestEngine.Progress = { value in
            progress(IngestProgress(phase: value.phase, path: value.path, completedFiles: value.completedFiles, totalFiles: value.totalFiles, fraction: primaryWeight + value.fraction * (1 - primaryWeight)))
        }
        var primaryResult: BatchResult?
        let previous = try? Directory(url: projectURL)
        let owner = Data(job.id.uuidString.utf8)
        if previous == nil || (try? previous!.smallData(ready)) != owner {
            primaryResult = try ManagedTransfer.direct(job.using(plan.subset(destinations: [primary])), token: token, progress: primaryProgress,
                                                      monitor: monitor, beforeVerification: beforeVerification)
            let folder = try Directory(url: projectURL)
            try folder.writeNew(ready, data: owner)
        }
        // Even a saved completed primary must pass fresh readback before it is a source.
        let project = try Directory(url: projectURL)
        if plan.hashDuringCopy == true {
            let workspace = try project.child(".OKCopy").child("Jobs").child(job.id.uuidString)
            plan = try plan.withFiles(plan.files.map { file in
                guard let digest = try SourceChecksums.load(file.id, from: workspace) else {
                    throw IngestError("The working copy is missing a saved source checksum. Backups were not started: " + file.outputPath)
                }
                guard file.sha256.isEmpty || file.sha256 == digest else { throw IngestError("Working-copy checksum reference changed") }
                return TransferFile(sourceIndex: file.sourceIndex, original: file.original, outputPath: file.outputPath, sha256: digest, duplicateOf: file.duplicateOf)
            })
        }
        var copiedSources: [SourceSelection] = []
        var mapped: [TransferFile] = []
        for (index, original) in plan.sources.enumerated() {
            let prefix = plan.sourcePrefix(index)
            let root = prefix.isEmpty ? projectURL : projectURL.appendingPathComponent(prefix)
            let expectedSnapshot = CardSnapshot(root: root, files: original.snapshot.files, rootStamp: original.snapshot.rootStamp, protectedRoot: root, protectsVolume: false)
            let scanned = try selectedSnapshot(expectedSnapshot, token: token)
            // A verified working folder is protected, but other folders on that SSD remain allowed.
            let snapshot = CardSnapshot(root: scanned.root, files: scanned.files, rootStamp: scanned.rootStamp, protectedRoot: scanned.root, protectsVolume: false)
            let live = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.relativePath, $0) })
            let expected = plan.files.filter { $0.sourceIndex == index }
            // An incremental project can contain older files; only this immutable job's files are cascaded.
            var selected: [CameraFile] = []
            for file in expected {
                try token.check()
                guard let current = live[file.original.relativePath], current.bytes == file.original.bytes else { throw IngestError("Working copy inventory changed: " + file.outputPath) }
                let fd = try project.readFile(file.outputPath); defer { close(fd) }
                let digest = try stream(fd, token: token) { data in monitor.update(primary.root, phase: "Checking working copy for cascading", verified: Int64(data.count)) }
                guard digest == file.sha256 else { throw IngestError("Working copy checksum mismatch. Backups were not started: " + file.outputPath) }
                selected.append(current)
                mapped.append(TransferFile(sourceIndex: index, original: current, outputPath: file.outputPath, sha256: file.sha256, duplicateOf: file.duplicateOf))
            }
            let subset = CardSnapshot(root: snapshot.root, files: selected.sorted { $0.relativePath < $1.relativePath }, rootStamp: snapshot.rootStamp, protectedRoot: snapshot.protectedRoot, protectsVolume: false)
            copiedSources.append(SourceSelection(snapshot: subset, label: original.label))
        }
        for destination in plan.destinations.dropFirst() {
            for original in plan.sources where Planner.overlap(original.snapshot.protectedRoot, destination.root) {
                throw IngestError("A backup overlaps an original source")
            }
        }
        monitor.update(primary.root, phase: "Working copy verified · backups pending", completed: primaryResult == nil ? plan.files.count : 0)
        monitor.flush()
        progress(IngestProgress(phase: "Working copy verified · backups pending", path: "Camera originals are no longer needed by this job's backup stage.", completedFiles: 0, totalFiles: plan.files.count, fraction: primaryWeight))
        do {
            let backupPlan = plan.subset(destinations: Array(plan.destinations.dropFirst()), sources: copiedSources, files: mapped)
            let backup = try ManagedTransfer.direct(job.using(backupPlan), token: token, progress: backupProgress, monitor: monitor, beforeVerification: beforeVerification, allowAdditionalSourceFiles: true, protectedSources: plan.sources)
            let records = plan.files.compactMap { file -> CopyReceipt? in
                guard let receipt = backup.files.first(where: { $0.outputPath == file.outputPath }) else { return nil }
                let first = primaryResult?.files.first(where: { $0.outputPath == file.outputPath })?.destinations.first ?? DestinationReceipt(root: primary.root, sha256: file.sha256, action: "Verified working copy · cascade source", resumedBytes: 0)
                return CopyReceipt(sourcePath: plan.sources[file.sourceIndex].snapshot.root.appendingPathComponent(file.original.relativePath).path, outputPath: file.outputPath, bytes: file.original.bytes, sourceSHA256: file.sha256, duplicateOf: file.duplicateOf, destinations: [first] + receipt.destinations)
            }
            let html = BatchReport.html(plan, records: records, status: "All selected copies verified", detail: "Cascading: working copy verified first; backups read from that copy and independently verified against the saved source SHA-256.")
            var reports = (primaryResult?.reports ?? []) + backup.reports
            let name = "Cascade-" + job.id.uuidString + "-" + UUID().uuidString
            for destination in plan.destinations {
                let folder = try Directory(url: plan.projectURL(destination))
                let report = try CopyReports.save(plan: plan, name: name + "-" + UUID().uuidString, html: html, json: BatchReport.json(plan, jobID: job.id, records: records, status: "All selected copies verified"), project: folder)
                reports.insert(report, at: 0)
            }
            monitor.update(primary.root, phase: "Verified")
            return BatchResult(reports: reports, html: html, files: records, destinations: monitor.snapshot())
        } catch {
            throw IngestError("Working copy verified; backups are not all verified. " + error.localizedDescription,
                              reports: (primaryResult?.reports ?? []) + ((error as? IngestError)?.reports ?? []), destinations: monitor.snapshot())
        }
    }
}
