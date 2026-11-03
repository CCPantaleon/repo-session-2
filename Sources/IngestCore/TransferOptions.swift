import Foundation

public enum CopyLayout: String, Codable, CaseIterable, Sendable { case organized, folder, destination }
public enum ReportStorage: String, Codable, Sendable { case app, destination, folder }

public struct TransferOptions: Codable, Sendable {
    public var layout: CopyLayout? = nil
    public var reportStorage: ReportStorage? = nil
    public var reportFolder: URL? = nil
    public var copyLayout: CopyLayout { layout ?? .organized }
    public var reportsLocation: ReportStorage { reportStorage ?? .destination }
    public var cascade: Bool
    public var concurrentSources: Int
    public var manifests: Bool
    public init(cascade: Bool = false, concurrentSources: Int = 2, manifests: Bool = true) {
        self.cascade = cascade; self.concurrentSources = min(4, max(1, concurrentSources)); self.manifests = manifests
    }
}

public struct DestinationProgress: Codable, Sendable, Identifiable {
    public var copySpeed: Double? = nil
    public var verificationSpeed: Double? = nil
    public var elapsedSeconds: Double? = nil
    public var publicationBytes: Int64? = nil
    public var sourceReadBytes: Int64? = nil
    public var updatedAt: Date? = nil
    public var estimatedSecondsRemaining: Double? = nil
    public var root: URL
    public var phase: String = "Waiting"
    public var copiedBytes: Int64 = 0
    public var verifiedBytes: Int64 = 0
    public var totalBytes: Int64
    public var bytesPerSecond: Double = 0
    public var completedFiles: Int = 0
    public var error: String?
    public var storage: String = "Filesystem grouping"
    public var id: String { root.path }
}

// All observers are serialized; UI callbacks must enqueue work rather than block.
final class TransferMonitor: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var values: [DestinationProgress]
    private var started = Date()
    private var budgets: [String: Int64] = [:]
    private var publicationRoots = Set<String>()
    private var samples: [String: (Date, Int64, Int64)] = [:]
    private var credits: [String: Int64] = [:]
    private var rates: [String: RemainingTimeEstimator] = [:]
    private var last = Date.distantPast
    private let callback: @Sendable ([DestinationProgress]) -> Void
    init(plan: BatchPlan, callback: @escaping @Sendable ([DestinationProgress]) -> Void) {
        for target in plan.destinations {
            let compatible = (try? target.root.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming) == false
            if compatible { publicationRoots.insert(target.root.path) }
            budgets[target.root.path] = plan.totalBytes * (compatible ? 7 : 4)
        }
        values = plan.destinations.map { DestinationProgress(root: $0.root, totalBytes: plan.totalBytes) }; self.callback = callback
    }
    func update(_ root: URL, phase: String? = nil, copied: Int64 = 0, verified: Int64 = 0, completed: Int = 0, error: String? = nil, storage: String? = nil, credited: Int64 = 0, sourceRead: Int64 = 0, publication: Int64 = 0) {
        lock.lock(); defer { lock.unlock() }
        guard let i = values.firstIndex(where: { $0.root == root }) else { return }
        values[i].updatedAt = Date()
        values[i].publicationBytes = (values[i].publicationBytes ?? 0) + publication
        values[i].sourceReadBytes = (values[i].sourceReadBytes ?? 0) + sourceRead
        values[i].elapsedSeconds = Date().timeIntervalSince(started)
        let old = samples[root.path] ?? (started, 0, 0)
        let interval = Date().timeIntervalSince(old.0)
        if interval >= 0.5 {
            values[i].copySpeed = Double(values[i].copiedBytes + copied - old.1) / interval
            values[i].verificationSpeed = Double(values[i].verifiedBytes + verified - old.2) / interval
            samples[root.path] = (Date(), values[i].copiedBytes + copied, values[i].verifiedBytes + verified)
        }
        if let phase { values[i].phase = phase }
        values[i].copiedBytes += copied; values[i].verifiedBytes += verified; values[i].completedFiles += completed
        values[i].bytesPerSecond = Double(values[i].copiedBytes + values[i].verifiedBytes) / max(Date().timeIntervalSince(started), 0.001)
        credits[root.path, default: 0] += credited
        var estimator = rates[root.path] ?? RemainingTimeEstimator()
        let work = values[i].copiedBytes + values[i].verifiedBytes + (values[i].sourceReadBytes ?? 0) + (values[i].publicationBytes ?? 0)
        values[i].estimatedSecondsRemaining = estimator.update(bytes: work, remaining: max(0, (budgets[root.path] ?? values[i].totalBytes * 4) - work - credits[root.path, default: 0]), now: Date().timeIntervalSinceReferenceDate)
        rates[root.path] = estimator
        if phase == "Verified" { values[i].estimatedSecondsRemaining = 0 }
        if error != nil || values[i].error != nil || ["Paused", "Incomplete", "Failed", "Working copy verified · backups pending"].contains(phase ?? "") { values[i].estimatedSecondsRemaining = nil }
        if let error { values[i].error = error }
        if let storage { values[i].storage = storage }
        if Date().timeIntervalSince(last) > 0.1 || error != nil || phase == "Verified" || phase == "Working copy verified · backups pending" {
            last = Date(); callback(values)
        }
    }
    func published(_ root: URL, bytes: Int64) {
        if publicationRoots.contains(root.path) { update(root, phase: "Finalizing", publication: bytes * 3) }
    }
    func snapshot() -> [DestinationProgress] { lock.lock(); defer { lock.unlock() }; return values }
    func flush() { lock.lock(); defer { lock.unlock() }; callback(values) }
}

public struct RemainingTimeEstimator {
    private var first: Double?
    private var previousTime: Double?
    private var previousBytes: Int64 = 0
    private var rate: Double = 0
    public init() {}
    public mutating func update(bytes: Int64, remaining: Int64, now: Double) -> Double? {
        guard let previous = previousTime else { first = now; previousTime = now; previousBytes = bytes; return nil }
        guard now >= previous else { self = RemainingTimeEstimator(); return nil }
        let interval = now - previous
        if interval >= 0.5 {
            let measured = Double(max(0, bytes - previousBytes)) / interval
            let weight = 1 - exp(-interval / 8)
            rate = rate == 0 ? measured : rate + weight * (measured - rate)
            previousTime = now; previousBytes = bytes
        }
        guard now - (first ?? now) >= 3, rate > 0, now - (previousTime ?? now) < 10 else { return nil }
        return max(1, Double(remaining) / rate)
    }
}
