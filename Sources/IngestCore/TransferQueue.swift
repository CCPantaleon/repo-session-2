import Foundation
import Darwin

public enum TransferStatus: String, Codable, Sendable {
    case queued, running, paused, failed, completed
}

public struct TransferJob: Identifiable, Codable, Sendable {
    public var destinationProgress: [DestinationProgress]? = nil
    public let id: UUID
    public let plan: BatchPlan
    public var status: TransferStatus
    public var lastError: String?
    public var reports: [URL]
    public var finishedFiles: Int
    public init(plan: BatchPlan) {
        id = UUID(); self.plan = plan; status = .queued; reports = []; finishedFiles = 0
    }
    init(id: UUID, plan: BatchPlan, status: TransferStatus, lastError: String?, reports: [URL], finishedFiles: Int) {
        self.id = id; self.plan = plan; self.status = status; self.lastError = lastError; self.reports = reports; self.finishedFiles = finishedFiles
    }
}

/// Queue metadata is small and replaceable; immutable plans are written once.
/// No saved byte offset or completed flag is trusted by the transfer engine.
public final class TransferQueueStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory.standardizedFileURL.resolvingSymlinksInPath() }
    private struct Entry: Codable {
        var destinationProgress: [DestinationProgress]? = nil
        let id: UUID
        let status: TransferStatus
        let lastError: String?
        let reports: [URL]
        let finishedFiles: Int
    }
    public func save(_ jobs: [TransferJob]) throws {
        lock.lock(); defer { lock.unlock() }
        for job in jobs {
            for source in job.plan.sources where Planner.overlap(source.snapshot.protectedRoot, directory.resolvingSymlinksInPath()) {
                throw IngestError("Queue storage overlaps a protected source. Choose a narrower source folder.")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for job in jobs {
            let file = directory.appendingPathComponent(job.id.uuidString + ".plan.json")
            if !FileManager.default.fileExists(atPath: file.path) {
                try encoder.encode(job.plan).write(to: file, options: .withoutOverwriting)
                try flush(file)
            }
        }
        let entries = jobs.map { Entry(destinationProgress: $0.destinationProgress, id: $0.id, status: $0.status, lastError: $0.lastError, reports: $0.reports, finishedFiles: $0.finishedFiles) }
        let queue = directory.appendingPathComponent("Queue.json")
        try encoder.encode(entries).write(to: queue, options: .atomic)
        try flush(queue)
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }
    public func load() throws -> [TransferJob] {
        lock.lock(); defer { lock.unlock() }
        let url = directory.appendingPathComponent("Queue.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        let entries = try decoder.decode([Entry].self, from: Data(contentsOf: url))
        return try entries.map { entry in
            let plan = try decoder.decode(BatchPlan.self, from: Data(contentsOf: directory.appendingPathComponent(entry.id.uuidString + ".plan.json")))
            var job = TransferJob(id: entry.id, plan: plan, status: entry.status == .running ? .paused : entry.status,
                lastError: entry.status == .running ? "The app stopped during this job. Resume to reverify saved data and continue." : entry.lastError,
                reports: entry.reports, finishedFiles: entry.finishedFiles)
            job.destinationProgress = entry.destinationProgress?.map { value in
                var restored = value
                restored.estimatedSecondsRemaining = nil
                if entry.status == .running && restored.phase != "Verified" && restored.phase != "Failed" {
                    restored.phase = "Paused · recheck on resume"; restored.bytesPerSecond = 0
                }
                return restored
            }
            return job
        }
    }
    private func flush(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize()
    }
}

public struct CopyReceipt: Codable, Sendable {
    public let sourcePath: String
    public let outputPath: String
    public let bytes: Int64
    public let sourceSHA256: String
    public let duplicateOf: String?
    public let destinations: [DestinationReceipt]
}

public struct DestinationReceipt: Codable, Sendable {
    public let root: URL
    public let sha256: String
    public let action: String
    public let resumedBytes: Int64
    public var sha1: String? = nil
}

public struct BatchResult: Sendable {
    public let reports: [URL]
    public let html: String
    public let files: [CopyReceipt]
    public var destinations: [DestinationProgress]? = nil
}
