import Foundation
import Darwin

public struct CameraFile: Identifiable, Codable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let bytes: Int64
    let stamp: FileStamp
    public var name: String { (relativePath as NSString).lastPathComponent }
    public var fileExtension: String { (name as NSString).pathExtension.uppercased() }
    public var kind: String {
        switch fileExtension {
        case "CR2", "CR3", "NEF", "ARW", "RAF", "DNG", "ORF", "RW2", "PEF", "RWL", "SRW", "3FR", "IIQ": return "RAW"
        case "JPG", "JPEG", "HEIC", "HEIF", "PNG", "TIF", "TIFF": return "Photo"
        case "MOV", "MP4", "MXF", "MTS", "AVI": return "Video"
        default: return "Other"
        }
    }
}

public struct CardSnapshot: Codable, Sendable {
    public let root: URL
    public let files: [CameraFile]
    let rootStamp: FileStamp
    public let protectedRoot: URL
    let protectsVolume: Bool
    public var excludedPaths: [String]? = nil
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

public enum CardScanner {
    public static func scan(_ url: URL, token: CancellationToken = CancellationToken()) throws -> CardSnapshot {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let directory = try Directory(url: root)
        var files: [CameraFile] = []
        var excluded: [String] = []
        try walk(directory, prefix: "", files: &files, excluded: &excluded, token: token)
        guard !files.isEmpty else { throw IngestError("No files were found in the selected card or folder.") }
        let protection = protectionRoot(root)
        return CardSnapshot(root: root, files: files.sorted { $0.relativePath < $1.relativePath }, rootStamp: try directory.stamp(), protectedRoot: protection.0, protectsVolume: protection.1, excludedPaths: excluded.sorted())
    }
    static func protectionRoot(_ root: URL) -> (URL, Bool) {
        let values = try? root.resourceValues(forKeys: [.volumeURLKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey])
        if let volume = values?.volume, values?.volumeIsRemovable == true || values?.volumeIsEjectable == true || values?.volumeIsInternal == false {
            return (volume.standardizedFileURL.resolvingSymlinksInPath(), true)
        }
        // Preserve the entire card even when only DCIM or a subfolder was selected.
        let parts = root.pathComponents
        if parts.count >= 3 && parts[1] == "Volumes" { return (URL(fileURLWithPath: "/Volumes/" + parts[2]), true) }
        return (root, false)
    }
    private static func walk(_ directory: Directory, prefix: String, files: inout [CameraFile], excluded: inout [String], token: CancellationToken) throws {
        let duplicate = dup(directory.fd)
        guard duplicate >= 0 else { throw systemError("Cannot scan folder") }
        guard let listing = fdopendir(duplicate) else { close(duplicate); throw systemError("Cannot list folder") }
        defer { closedir(listing) }
        while true {
            try token.check()
            errno = 0
            guard let item = readdir(listing) else {
                if errno != 0 { throw systemError("Cannot finish reading folder") }
                break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw IngestError("A filename cannot be represented as UTF-8. This source cannot be imported safely.") }
            if name == "." || name == ".." { continue }
            let path = prefix.isEmpty ? name : prefix + "/" + name
            // Skip only known OS housekeeping, before opening protected directories.
            // Other hidden files (including .env, .git, and AppleDouble sidecars) remain included.
            let rootMetadata: Set<String> = [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100"]
            if name == ".DS_Store" || (prefix.isEmpty && rootMetadata.contains(name)) {
                excluded.append(path); continue
            }
            var info = stat()
            guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw systemError("Cannot inspect \(path)") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: try walk(directory.child(name), prefix: path, files: &files, excluded: &excluded, token: token)
            case S_IFREG: files.append(CameraFile(relativePath: path, bytes: info.st_size, stamp: FileStamp(info)))
            default: throw IngestError("Unsupported link or special file: \(path). The scan was stopped. Select a source containing only regular files and folders.")
            }
        }
    }
}

public struct IngestRequest: Sendable {
    public let snapshot: CardSnapshot
    public let projectName: String
    public let workingRoot: URL
    public let backupRoot: URL?
    public let date: Date
    public init(snapshot: CardSnapshot, projectName: String, workingRoot: URL, backupRoot: URL? = nil, date: Date = Date()) {
        self.snapshot = snapshot; self.projectName = projectName
        self.workingRoot = workingRoot; self.backupRoot = backupRoot; self.date = date
    }
}

public struct IngestPlan: Sendable {
    public let request: IngestRequest
    public let folderName: String
    public let cardName: String
    public let workingProject: URL
    public let backupProject: URL?
    public var destinationProjects: [URL] { [workingProject] + (backupProject.map { [$0] } ?? []) }
    public let warnings: [String]
    public var totalBytes: Int64 { request.snapshot.totalBytes }
}

public enum Planner {
    public static func projectFolderName(_ input: String) throws -> String {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw IngestError("Enter a folder name.") }
        guard input != ".", input != "..", !input.contains("/"), !input.contains(":"),
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), input.utf8.count <= 255 else {
            throw IngestError("Use a folder name up to 255 UTF-8 bytes, without slashes, colons, or control characters. The name will not be changed automatically.")
        }
        return input
    }
    public static func slug(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IngestError("Enter a project name.") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let value = trimmed.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        guard !value.isEmpty, value.utf8.count <= 80 else { throw IngestError("Use a project name with letters or numbers, up to 80 UTF-8 bytes after formatting.") }
        return value
    }

    public static func plan(_ request: IngestRequest) throws -> IngestPlan {
        let folder = try projectFolderName(request.projectName)
        let source = request.snapshot.root
        let working = request.workingRoot.standardizedFileURL.resolvingSymlinksInPath()
        let backup = request.backupRoot?.standardizedFileURL.resolvingSymlinksInPath()
        let destinations = [working] + (backup.map { [$0] } ?? [])
        for target in destinations {
            guard !overlap(request.snapshot.protectedRoot, target) else { throw IngestError("A destination overlaps the protected source. Choose a folder outside the original card or source folder.") }
            let directory = try Directory(url: target)
            if try request.snapshot.protectsVolume && directory.stamp().device == request.snapshot.rootStamp.device {
                throw IngestError("The original camera card cannot be used as a destination, even outside the selected source subfolder.")
            }
        }
        if let backup, overlap(working, backup) { throw IngestError("Working and backup folders cannot be identical or contain one another. Use different folders, or leave backup unselected.") }
        let devices = try destinations.map { try Directory(url: $0).stamp().device }
        for (index, target) in destinations.enumerated() {
            guard !(try Directory(url: target)).exists(folder) else { throw IngestError("\(folder) already exists at \(target.path). Choose a new project name; nothing will be overwritten.") }
            let copiesOnVolume = devices.filter { $0 == devices[index] }.count
            try checkCapacity(target, needed: request.snapshot.totalBytes * Int64(copiesOnVolume))
        }
        let card = (try? slug(source.lastPathComponent)) ?? "Camera-Card"
        var warnings: [String] = []
        if backup == nil {
            warnings.append("No backup selected. Only the working copy will be created and verified.")
        } else if Set(devices).count == 1 {
            warnings.append("Working and backup folders share a filesystem. Both copies will be verified, but this does not protect against drive failure.")
        } else {
            warnings.append("Two destinations selected. Separate volumes may still share physical storage; use a separate device for an independent backup.")
        }
        return IngestPlan(request: request, folderName: folder, cardName: card,
                          workingProject: working.appendingPathComponent(folder), backupProject: backup?.appendingPathComponent(folder), warnings: warnings)
    }

    static func overlap(_ a: URL, _ b: URL) -> Bool {
        let ap = a.pathComponents; let bp = b.pathComponents
        return ap.starts(with: bp) || bp.starts(with: ap)
    }
    static func checkCapacity(_ url: URL, needed: Int64) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeIsReadOnlyKey, .volumeIsLocalKey])
        if values.volumeIsReadOnly == true { throw IngestError("Destination is read-only: \(url.path)") }
        if values.volumeIsLocal == false { throw IngestError("Choose a locally mounted drive, rather than a network destination.") }
        guard let available = values.volumeAvailableCapacity else { throw IngestError("Cannot determine free space at \(url.path)") }
        let reserve: Int64 = 16 * 1024 * 1024
        guard Int64(available) >= needed + reserve else { throw IngestError("Not enough space at \(url.path). Each destination needs \(ByteCountFormatter.string(fromByteCount: needed + reserve, countStyle: .file)) including report headroom.") }
    }
}

