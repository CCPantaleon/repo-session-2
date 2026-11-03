import Foundation
import Darwin

public struct IngestProgress: Sendable {
    public let phase: String
    public let path: String
    public let completedFiles: Int
    public let totalFiles: Int
    public let fraction: Double
}

public struct FileVerification: Codable, Sendable {
    public let path: String
    public let bytes: Int64
    public var sourceSHA256: String?
    public var workingSHA256: String?
    public var backupSHA256: String?
    public var status: String
}

public struct IngestResult: Sendable {
    public let dryRun: Bool
    public let html: String
    public let reports: [URL]
    public let files: [FileVerification]
}

public enum IngestEngine {
    public typealias Progress = @Sendable (IngestProgress) -> Void

    public static func dryRun(_ request: IngestRequest, token: CancellationToken = CancellationToken(), progress: @escaping Progress = { _ in }) throws -> IngestResult {
        let plan = try Planner.plan(request)
        let source = try checkedSource(plan)
        var records: [FileVerification] = []
        var bytes: Int64 = 0
        for file in request.snapshot.files {
            try token.check()
            let fd = try source.readFile(file.relativePath); defer { close(fd) }
            try checkStamp(fd, expected: file.stamp, path: file.relativePath)
            let digest = try stream(fd, token: token) { data in
                bytes += Int64(data.count)
                progress(IngestProgress(phase: "Reading source · dry run", path: file.relativePath, completedFiles: records.count,
                    totalFiles: request.snapshot.files.count, fraction: Double(bytes) / Double(max(plan.totalBytes, 1))))
            }
            try checkStamp(fd, expected: file.stamp, path: file.relativePath)
            records.append(FileVerification(path: file.relativePath, bytes: file.bytes, sourceSHA256: digest, status: "Source readable · not copied"))
        }
        try ensureSameInventory(plan, token: token)
        let html = Report.html(plan: plan, records: records, status: "Dry run complete", detail: "No camera files were copied. No project folders were created. Destination writes have not been tested. Review the selected destinations below.")
        progress(IngestProgress(phase: "Dry run complete", path: "", completedFiles: records.count, totalFiles: records.count, fraction: 1))
        return IngestResult(dryRun: true, html: html, reports: [], files: records)
    }

    public static func importFiles(_ request: IngestRequest, token: CancellationToken = CancellationToken(), progress: @escaping Progress = { _ in }) throws -> IngestResult {
        guard SafetyCheck.hasPassed else { throw IngestError("Run the sample safety check successfully before enabling real imports.") }
        let plan = try Planner.plan(request)
        return try execute(plan, token: token, progress: progress)
    }

    // Internal entry point is used only by synthetic fixture tests. The public import
    // path always checks the process-local self-test gate.
    static func execute(_ plan: IngestPlan, token: CancellationToken = CancellationToken(), progress: @escaping Progress = { _ in },
                        beforeVerification: ((URL, URL) throws -> Void)? = nil) throws -> IngestResult {
        let refreshed = try Planner.plan(plan.request)
        guard refreshed.folderName == plan.folderName else { throw IngestError("The project plan changed. Run the preview again.") }
        let source = try checkedSource(plan)
        let destinationRoots = try plan.destinationProjects.map { try Directory(url: $0.deletingLastPathComponent()) }
        let sourceURL = try source.actualURL()
        for root in destinationRoots {
            let actual = try root.actualURL()
            guard !Planner.overlap(sourceURL, actual), !Planner.overlap(plan.request.snapshot.protectedRoot, actual) else {
                throw IngestError("A destination now overlaps the protected source. Nothing was written.")
            }
            if try plan.request.snapshot.protectsVolume && root.stamp().device == plan.request.snapshot.rootStamp.device {
                throw IngestError("The original camera card cannot be used as a destination. Nothing was written.")
            }
        }
        let stageName = ".OKCopy.incomplete-" + UUID().uuidString
        var roots: [Directory] = []
        var locations: [URL] = []
        var records: [FileVerification] = []
        var bytes: Int64 = 0
        let count = plan.request.snapshot.files.count
        var verifiedCount = 0
        let copyLabel = destinationRoots.count == 2 ? "both destinations" : "working destination"
        func update(_ phase: String, _ path: String) {
            progress(IngestProgress(phase: phase, path: path, completedFiles: verifiedCount,
                totalFiles: count, fraction: min(Double(bytes) / max(Double(plan.totalBytes) * Double(destinationRoots.count + 2), 1), 1)))
        }
        do {
            try token.check()
            for root in destinationRoots {
                roots.append(try root.makeStage(stageName))
            }
            locations = plan.destinationProjects.map { $0.deletingLastPathComponent().appendingPathComponent(stageName) }
            for file in plan.request.snapshot.files {
                try token.check()
                records.append(FileVerification(path: file.relativePath, bytes: file.bytes, status: "Incomplete"))
                let index = records.count - 1
                let sourceFD = try source.readFile(file.relativePath); defer { close(sourceFD) }
                try checkStamp(sourceFD, expected: file.stamp, path: file.relativePath)
                let path = "Originals/\(plan.cardName)/\(file.relativePath)"
                var outputs: [Int32] = []
                defer { outputs.forEach { close($0) } }
                for root in roots { outputs.append(try root.newFile(path)) }
                update("Copying to \(copyLabel)", file.relativePath)
                let sourceHash = try stream(sourceFD, token: token) { data in
                    for output in outputs { try writeAll(output, data: data) }
                    bytes += Int64(data.count); update("Copying to \(copyLabel)", file.relativePath)
                }
                records[index].sourceSHA256 = sourceHash
                try checkStamp(sourceFD, expected: file.stamp, path: file.relativePath)
                for output in outputs {
                    guard fsync(output) == 0 else { throw systemError("Could not flush copied data to disk") }
                    // macOS asks the device to flush its hardware cache when supported.
                    if fcntl(output, F_FULLFSYNC) == -1 && errno != ENOTSUP && errno != EINVAL { throw systemError("Could not flush the drive cache") }
                    var times = [timespec(tv_sec: Int(file.stamp.seconds), tv_nsec: Int(file.stamp.nanos)), timespec(tv_sec: Int(file.stamp.seconds), tv_nsec: Int(file.stamp.nanos))]
                    guard futimens(output, &times) == 0 else { throw systemError("Could not preserve original modification time") }
                }
                if let beforeVerification, locations.count == 2 { try beforeVerification(locations[0].appendingPathComponent(path), locations[1].appendingPathComponent(path)) }
                for (i, root) in roots.enumerated() {
                    let copyFD = try root.readFile(path); defer { close(copyFD) }
                    let hash = try stream(copyFD, token: token) { data in
                        bytes += Int64(data.count); update(i == 0 ? "Verifying working copy" : "Verifying backup copy", file.relativePath)
                    }
                    if i == 0 { records[index].workingSHA256 = hash } else { records[index].backupSHA256 = hash }
                    guard hash == sourceHash else { throw IngestError("SHA-256 mismatch in the \(i == 0 ? "working" : "backup") copy: \(file.relativePath). Copies remain incomplete.") }
                }
                let checkFD = try source.readFile(file.relativePath); defer { close(checkFD) }
                try checkStamp(checkFD, expected: file.stamp, path: file.relativePath)
                let secondHash = try stream(checkFD, token: token) { data in
                    bytes += Int64(data.count); update("Rechecking source", file.relativePath)
                }
                try checkStamp(checkFD, expected: file.stamp, path: file.relativePath)
                guard sourceHash == secondHash else { throw IngestError("The source changed during copying: \(file.relativePath). Scan the card again.") }
                records[index].status = "Verified"
                verifiedCount += 1
            }
            try ensureSameInventory(plan, token: token)
            try token.check()
            update("Writing ingest reports", "")
            // Reports truthfully distinguish byte verification from final publication.
            let html = Report.html(plan: plan, records: records, status: "All copies verified", detail: "Every file at each selected destination matched the source SHA-256. \(plan.backupProject == nil ? "No backup was selected or created." : "Working and backup copies were verified.") Project publication is confirmed by the absence of .incomplete in each folder name. Original card contents were not changed.")
            let json = try Report.manifest(plan: plan, records: records, status: "All copies verified")
            for root in roots {
                try root.writeNew("Ingest Report.html", data: Data(html.utf8))
                try root.writeNew("Checksums.json", data: json)
            }
            for (index, root) in destinationRoots.enumerated() {
                try root.publish(stage: stageName, final: plan.folderName)
                locations[index] = plan.destinationProjects[index]
            }
            progress(IngestProgress(phase: "Import complete · \(destinationRoots.count) \(destinationRoots.count == 1 ? "copy" : "copies") verified", path: "", completedFiles: count, totalFiles: count, fraction: 1))
            return IngestResult(dryRun: false, html: html, reports: locations.map { $0.appendingPathComponent("Ingest Report.html") }, files: records)
        } catch {
            // Preserve evidence and partial copies. Never remove anything automatically.
            if locations.isEmpty {
                locations = plan.destinationProjects.prefix(roots.count).map { $0.deletingLastPathComponent().appendingPathComponent(stageName) }
            }
            let detail = error.localizedDescription
            let html = Report.html(plan: plan, records: records, status: "Import incomplete", detail: detail + " Do not treat this as a completed import. Partial copies are retained.")
            var reports: [URL] = []
            for (i, root) in roots.enumerated() {
                if (try? root.writeNew("Failure Report.html", data: Data(html.utf8))) != nil {
                    reports.append(locations[i].appendingPathComponent("Failure Report.html"))
                }
            }
            throw IngestError(detail + (roots.isEmpty ? "" : "\nRetained folders:\n" + locations.map(\.path).joined(separator: "\n")), reports: reports)
        }
    }

    private static func checkedSource(_ plan: IngestPlan) throws -> Directory {
        let root = try Directory(url: plan.request.snapshot.root)
        let stamp = try root.stamp()
        guard stamp.device == plan.request.snapshot.rootStamp.device, stamp.inode == plan.request.snapshot.rootStamp.inode else {
            throw IngestError("The selected card was replaced or disconnected. Select it again.")
        }
        return root
    }
    private static func ensureSameInventory(_ plan: IngestPlan, token: CancellationToken) throws {
        let current = try CardScanner.scan(plan.request.snapshot.root, token: token)
        guard current.rootStamp.device == plan.request.snapshot.rootStamp.device,
              current.rootStamp.inode == plan.request.snapshot.rootStamp.inode,
              current.files.map(\.relativePath) == plan.request.snapshot.files.map(\.relativePath),
              current.files.map(\.stamp) == plan.request.snapshot.files.map(\.stamp) else {
            throw IngestError("Card contents changed during the operation. The import cannot be marked complete.")
        }
    }
}
