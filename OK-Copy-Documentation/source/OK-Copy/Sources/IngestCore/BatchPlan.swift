import Foundation
import CryptoKit
import Darwin

public struct SourceSelection: Identifiable, Codable, Sendable {
    public let id: UUID
    public let snapshot: CardSnapshot
    public var label: String
    public init(snapshot: CardSnapshot, label: String? = nil) {
        self.id = UUID(); self.snapshot = snapshot
        self.label = label ?? ((try? Planner.slug(snapshot.root.lastPathComponent)) ?? "Camera-Card")
    }
}

public struct TransferFile: Identifiable, Codable, Sendable {
    public let sourceIndex: Int
    public let original: CameraFile
    public let outputPath: String
    public let sha256: String
    public let duplicateOf: String?
    public var id: String { SHA256.hash(data: Data(outputPath.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public struct DestinationIdentity: Codable, Sendable {
    public let root: URL
    let stamp: FileStamp
    let volumeUUID: String?
    init(_ url: URL) throws {
        root = url.standardizedFileURL.resolvingSymlinksInPath()
        stamp = try Directory(url: root).stamp()
        volumeUUID = try root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }
    func validate(_ directory: Directory) throws {
        let current = try directory.stamp()
        let uuid = try root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        guard current.inode == stamp.inode,
              volumeUUID != nil ? uuid == volumeUUID : current.device == stamp.device else {
            throw IngestError("The destination identity changed: \(root.path). Reconnect the original destination before resuming.")
        }
    }
}

public struct BatchPlan: Codable, Sendable {
    public var hashDuringCopy: Bool? = nil
    public var options: TransferOptions? = nil
    public var settings: TransferOptions { options ?? TransferOptions() }
    public let schemaVersion: Int
    public let projectName: String
    public let folderName: String
    public let sources: [SourceSelection]
    public let destinations: [DestinationIdentity]
    public let files: [TransferFile]
    public let incremental: Bool
    public let createdAt: Date
    public let warnings: [String]
    public let existingCopies: Int
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.original.bytes } }
    public var duplicateCount: Int { files.filter { $0.duplicateOf != nil }.count }
}

extension BatchPlan {
    var usesDestinationRoot: Bool { settings.copyLayout == .destination }
    func sourcePrefix(_ index: Int) -> String { Self.sourcePrefix(settings.copyLayout, sources.count, sources[index].label) }
    static func sourcePrefix(_ layout: CopyLayout, _ count: Int, _ label: String) -> String {
        layout == .organized ? "Originals/" + label : count > 1 ? label : ""
    }
    func expectedPath(_ index: Int, _ relative: String) -> String {
        let prefix = sourcePrefix(index); return prefix.isEmpty ? relative : prefix + "/" + relative
    }
    func projectURL(_ target: DestinationIdentity) -> URL { usesDestinationRoot ? target.root : target.root.appendingPathComponent(folderName) }
}

public enum BatchPlanner {
    public static func prepare(sources: [SourceSelection], destinations: [URL], projectName: String,
                               incremental: Bool = true, options: TransferOptions = TransferOptions(), date: Date = Date(), hashDuringCopy: Bool = false, token: CancellationToken = CancellationToken(),
                               progress: @escaping IngestEngine.Progress = { _ in }) throws -> BatchPlan {
        guard !sources.isEmpty, !destinations.isEmpty else { throw IngestError("Choose at least one source and one destination.") }
        let folder = try Planner.projectFolderName(projectName)
        if options.reportsLocation == .folder {
            guard let reportFolder = options.reportFolder else { throw IngestError("Choose a report folder") }
            let actual = try Directory(url: reportFolder).actualURL()
            for source in sources where Planner.overlap(source.snapshot.protectedRoot, actual) { throw IngestError("Report storage overlaps a protected source") }
        }
        if options.reportsLocation != .destination {
            let reportRoot = (options.reportsLocation == .folder ? options.reportFolder! : CopyReports.appFolder).standardizedFileURL.resolvingSymlinksInPath()
            for source in sources where Planner.overlap(reportRoot, source.snapshot.protectedRoot) { throw IngestError("Report storage overlaps a protected source") }
            var existing = reportRoot
            while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
            try Planner.checkCapacity(existing, needed: 0)
            guard access(existing.path, W_OK) == 0 else { throw IngestError("Report storage is not writable: " + existing.path) }
        }
        let identities = try destinations.map(DestinationIdentity.init)
        try validateLocations(sources: sources, destinations: identities)
        var labels = Set<String>()
        var refreshed: [SourceSelection] = []
        for source in sources {
            let label = try Planner.slug(source.label)
            guard label == source.label, labels.insert(fold(label)).inserted else {
                throw IngestError("Each source needs a unique card label using letters, numbers, hyphens, or underscores. Labels are used in the project folder.")
            }
            let snapshot = try CardScanner.scan(source.snapshot.root, token: token)
            refreshed.append(SourceSelection(snapshot: snapshot, label: label))
        }
        try validateLocations(sources: refreshed, destinations: identities)
        let total = refreshed.reduce(Int64(0)) { $0 + $1.snapshot.totalBytes }
        let count = refreshed.reduce(0) { $0 + $1.snapshot.files.count }
        var readBytes: Int64 = 0
        var files: [TransferFile] = []
        var seenHashes: [String: String] = [:]
        var outputNames = Set<String>()
        var pathKinds: [String: Bool] = [:]
        for (sourceIndex, source) in refreshed.enumerated() {
            let directory = try Directory(url: source.snapshot.root)
            for file in source.snapshot.files {
                try token.check()
                let prefix = BatchPlan.sourcePrefix(options.copyLayout, refreshed.count, source.label)
                let output = prefix.isEmpty ? file.relativePath : prefix + "/" + file.relativePath
                guard output.split(separator: "/").first != ".OKCopy", output != ".OKCopy-Owner",
                      !(options.reportsLocation == .destination && output.split(separator: "/").first == "Ingest Reports") else { throw IngestError("A source path conflicts with copy bookkeeping: " + output) }
                guard outputNames.insert(fold(output)).inserted else { throw IngestError("Two source paths collide on a destination: \(output)") }
                let components = output.split(separator: "/").map(String.init)
                for index in components.indices {
                    let key = fold(components[...index].joined(separator: "/"))
                    let isDirectory = index != components.count - 1
                    if let previous = pathKinds[key], previous != isDirectory {
                        throw IngestError("A file and folder would collide on a destination: \(output)")
                    }
                    pathKinds[key] = isDirectory
                }
                var hash = ""
                if !hashDuringCopy {
                    let fd = try directory.readFile(file.relativePath); defer { close(fd) }
                    try checkStamp(fd, expected: file.stamp, path: file.relativePath)
                    hash = try stream(fd, token: token) { data in
                        readBytes += Int64(data.count)
                        progress(IngestProgress(phase: "Dry run · hashing source", path: source.label + "/" + file.relativePath,
                            completedFiles: files.count, totalFiles: count, fraction: 0.8 * Double(readBytes) / Double(max(total, 1))))
                    }
                    try checkStamp(fd, expected: file.stamp, path: file.relativePath)
                }
                let key = "\(file.bytes):\(hash)"
                files.append(TransferFile(sourceIndex: sourceIndex, original: file, outputPath: output, sha256: hash, duplicateOf: hashDuringCopy ? nil : seenHashes[key]))
                if !hashDuringCopy && seenHashes[key] == nil { seenHashes[key] = output }
            }
        }
        var required = [Int64](repeating: 0, count: identities.count)
        var existingCopies = 0
        for (index, target) in identities.enumerated() {
            try token.check()
            let root = try Directory(url: target.root)
            if options.copyLayout == .destination || root.exists(folder) {
                guard incremental || options.copyLayout == .destination else { throw IngestError("\(folder) already exists. Enable incremental copies or choose another project name.") }
                let project = options.copyLayout == .destination ? root : try root.child(folder)
                for (fileIndex, file) in files.enumerated() {
                    if try project.contains(file.outputPath) {
                        if !incremental && options.copyLayout == .destination { throw IngestError("A file already exists at the destination. Enable incremental copies to reverify it.") }
                        if hashDuringCopy { continue }
                        progress(IngestProgress(phase: "Dry run · checking existing copies", path: file.outputPath, completedFiles: files.count, totalFiles: count, fraction: 0.8 + 0.19 * Double(index * files.count + fileIndex) / Double(max(identities.count * files.count, 1))))
                        let fd = try project.readFile(file.outputPath); defer { close(fd) }
                        guard try hashFile(fd, token: token) == file.sha256 else {
                            throw IngestError("Content conflict at \(target.root.appendingPathComponent(folder + "/" + file.outputPath).path). Existing data will not be replaced. Choose a different project or source label.")
                        }
                        existingCopies += 1
                    } else { required[index] += file.original.bytes }
                }
            } else { required[index] = total }
        }
        for index in identities.indices where required[index] > 0 {
            if (try? identities[index].root.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming) == false {
                required[index] += publicationOverhead(files: files, concurrentSources: options.concurrentSources)
            }
        }
        try checkCapacity(identities, remaining: required)
        var warnings: [String] = []
        if hashDuringCopy { warnings.append("Review was skipped. Source checksums are captured during copying; existing files are checked when reached. Files are never overwritten.") }
        for source in refreshed where !(source.snapshot.excludedPaths ?? []).isEmpty {
            warnings.append("Skipped macOS housekeeping in \(source.label): " + source.snapshot.excludedPaths!.joined(separator: ", ") + ". Other hidden files are included.")
        }
        for target in identities {
            if (try? target.root.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming) == false {
                warnings.append("\(target.root.lastPathComponent) uses compatible publishing: the named folder appears while copying, and each final file receives an additional verified write. Completion is confirmed in the app and reports.")
            }
        }
        let topology = StorageScheduler(urls: identities.map(\.root))
        for (i, first) in identities.enumerated() {
            for second in identities.dropFirst(i + 1) where !Set(topology.location(first.root).keys).isDisjoint(with: topology.location(second.root).keys) {
                warnings.append("Destination folders may share a disk or connection. Both copies are allowed; use independent devices for drive-failure protection.")
            }
        }
        if identities.count == 1 { warnings.append("One destination selected. No additional backup will be created.") }
        if Set(identities.map { $0.stamp.device }).count < identities.count {
            warnings.append("Some destination folders share a filesystem. They do not provide independent drive-failure protection.")
        }
        if files.contains(where: { $0.duplicateOf != nil }) {
            warnings.append("Identical content was detected at different source paths. All original paths will be retained; matching existing destination files will be reverified and skipped.")
        }
        return BatchPlan(hashDuringCopy: hashDuringCopy ? true : nil, options: options, schemaVersion: hashDuringCopy ? 3 : 2, projectName: projectName, folderName: folder, sources: refreshed, destinations: identities,
            files: files, incremental: incremental, createdAt: date, warnings: warnings, existingCopies: existingCopies)
    }

    static func validateLocations(sources: [SourceSelection], destinations: [DestinationIdentity]) throws {
        guard !sources.isEmpty, !destinations.isEmpty else { throw IngestError("Sources and destinations are required.") }
        for (i, source) in sources.enumerated() {
            for other in sources.dropFirst(i + 1) where Planner.overlap(source.snapshot.root, other.snapshot.root) {
                throw IngestError("Sources cannot be identical or contain one another.")
            }
            for target in destinations {
                let directory = try Directory(url: target.root)
                let actual = try directory.actualURL()
                guard !Planner.overlap(source.snapshot.protectedRoot, actual) else { throw IngestError("A destination overlaps a protected source: \(actual.path)") }
                if try source.snapshot.protectsVolume && directory.stamp().device == source.snapshot.rootStamp.device {
                    throw IngestError("An original camera card cannot be used as a destination.")
                }
            }
        }
        for (i, target) in destinations.enumerated() {
            for other in destinations.dropFirst(i + 1) where Planner.overlap(target.root, other.root) {
                throw IngestError("Destination folders cannot be identical or contain one another.")
            }
        }
    }
    static func publicationOverhead(files: [TransferFile], concurrentSources: Int) -> Int64 {
        Dictionary(grouping: files, by: \.sourceIndex).values
            .map { $0.map { $0.original.bytes }.max() ?? 0 }
            .sorted(by: >).prefix(concurrentSources).reduce(0, +)
    }
    static func checkCapacity(_ destinations: [DestinationIdentity], remaining: [Int64]) throws {
        for (index, target) in destinations.enumerated() {
            let device = target.stamp.device
            let amount = destinations.indices.filter { destinations[$0].stamp.device == device }.reduce(Int64(0)) { $0 + remaining[$1] }
            try Planner.checkCapacity(destinations[index].root, needed: amount)
        }
    }
    static func fold(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
}

func hashFile(_ fd: Int32, token: CancellationToken) throws -> String {
    guard lseek(fd, 0, SEEK_SET) == 0 else { throw systemError("Cannot rewind file") }
    return try stream(fd, token: token) { _ in }
}
