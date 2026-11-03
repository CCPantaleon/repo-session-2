import Foundation
import CryptoKit
import Darwin

public struct IngestError: LocalizedError, Sendable {
    public let message: String
    public let reports: [URL]
    public let destinations: [DestinationProgress]?
    public init(_ message: String, reports: [URL] = [], destinations: [DestinationProgress]? = nil) { self.message = message; self.reports = reports; self.destinations = destinations }
    public var errorDescription: String? { message }
}

func systemError(_ action: String) -> IngestError {
    IngestError("\(action): \(String(cString: strerror(errno)))")
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw IngestError("Import stopped. Incomplete copies have been retained; the camera card was not changed.") }
    }
}

struct FileStamp: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let seconds: Int64
    let nanos: Int64
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; size = s.st_size
        seconds = Int64(s.st_mtimespec.tv_sec); nanos = Int64(s.st_mtimespec.tv_nsec)
    }
}

// All source access is O_RDONLY. Relative traversal rejects links at every component.
// Destination writes are exclusive and anchored to already-open directory descriptors.
final class Directory {
    let fd: Int32
    init(url: URL) throws {
        fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw systemError("Cannot open folder \(url.path)") }
    }
    init(fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }
    func stamp() throws -> FileStamp {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw systemError("Cannot inspect folder") }
        return FileStamp(info)
    }
    func actualURL() throws -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &path) == 0 else { throw systemError("Cannot resolve the opened folder") }
        return URL(fileURLWithPath: String(cString: path)).standardizedFileURL.resolvingSymlinksInPath()
    }
    func child(_ name: String, create: Bool = false) throws -> Directory {
        try validComponent(name)
        if create && mkdirat(fd, name, 0o755) != 0 && errno != EEXIST { throw systemError("Cannot create \(name)") }
        let childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard childFD >= 0 else { throw systemError("Cannot open folder \(name)") }
        return Directory(fd: childFD)
    }
    func parent(of path: String, create: Bool = false) throws -> (Directory, String) {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let leaf = pieces.last else { throw IngestError("Empty file path") }
        var directory = self
        for piece in pieces.dropLast() { directory = try directory.child(piece, create: create) }
        try validComponent(leaf)
        return (directory, leaf)
    }
    func readFile(_ path: String) throws -> Int32 {
        let (directory, leaf) = try parent(of: path)
        let result = openat(directory.fd, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard result >= 0 else { throw systemError("Cannot read \(path)") }
        var info = stat()
        guard fstat(result, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(result); throw IngestError("Source is no longer a regular file: \(path)")
        }
        return result
    }
    func newFile(_ path: String) throws -> Int32 {
        let (directory, leaf) = try parent(of: path, create: true)
        let result = openat(directory.fd, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard result >= 0 else { throw systemError("Cannot create \(path); existing files are never replaced") }
        return result
    }
    func updateFile(_ path: String) throws -> Int32 {
        let (directory, leaf) = try parent(of: path)
        let result = openat(directory.fd, leaf, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard result >= 0 else { throw systemError("Cannot reopen partial file") }
        var info = stat()
        guard fstat(result, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(result); throw IngestError("Partial file is not a private regular file")
        }
        return result
    }
    func contains(_ path: String) throws -> Bool {
        let components = path.split(separator: "/").map(String.init)
        var current = self
        for name in components.dropLast() {
            try validComponent(name)
            if !current.exists(name) { return false }
            current = try current.child(name)
        }
        guard let leaf = components.last else { throw IngestError("Empty path") }
        try validComponent(leaf)
        return current.exists(leaf)
    }
    func moveFile(_ name: String, to directory: Directory, path: String,
                  token: CancellationToken = CancellationToken(), expectedHash: String? = nil,
                  forceCompatible: Bool = false, progress: (Int) -> Void = { _ in }) throws {
        try validComponent(name)
        let (parent, leaf) = try directory.parent(of: path, create: true)
        let journal = name + ".publication.json"
        if !forceCompatible && !exists(journal) {
            if renameatx_np(fd, name, parent.fd, leaf, UInt32(RENAME_EXCL)) == 0 {
                _ = fsync(parent.fd)
                return
            }
            guard errno == ENOTSUP || errno == ENOSYS else {
                throw systemError("Cannot publish file without replacing existing data: \(path)")
            }
        }
        try publishByExclusiveCopy(name, parent: parent, leaf: leaf, path: path,
                                   journal: journal, expectedHash: expectedHash, token: token, progress: progress)
        _ = fsync(parent.fd)
    }

    func resumePendingPublication(_ name: String, to directory: Directory, path: String,
                                  token: CancellationToken, expectedHash: String) throws {
        let journal = name + ".publication.json"
        guard exists(journal) else { return }
        let record = try JSONDecoder().decode(PublicationRecord.self, from: smallData(journal))
        if record.path == path {
            try moveFile(name, to: directory, path: path, token: token, expectedHash: expectedHash)
        } else {
            let prefix = String(name.dropLast(".part".count)) + ".rejected-"
            guard name.hasSuffix(".part"), record.parentPath == (try actualURL().path),
                  record.path.hasPrefix(prefix), UUID(uuidString: String(record.path.dropFirst(prefix.count))) != nil else {
                throw IngestError("Unrecognized pending publication. Partial files were preserved.")
            }
            // Finish preserving an invalid old prefix before starting a fresh copy.
            try moveFile(name, to: self, path: record.path, token: token)
        }
    }

    // exFAT does not implement RENAME_EXCL. Reserve a NEW final file with O_EXCL,
    // record its identity before writing, then copy and independently rehash it.
    // A saved journal permits resuming only that owned file, with a matching prefix.
    // No existing unowned file is ever opened for writing or replaced.
    private func publishByExclusiveCopy(_ name: String, parent: Directory, leaf: String, path: String,
                                        journal: String, expectedHash: String?, token: CancellationToken,
                                        progress: (Int) -> Void) throws {
        try token.check()
        let parentPath = try parent.actualURL().path
        let existing: PublicationRecord? = exists(journal)
            ? try JSONDecoder().decode(PublicationRecord.self, from: smallData(journal)) : nil
        if let existing {
            guard existing.path == path, existing.parentPath == parentPath,
                  expectedHash == nil || existing.sha256 == expectedHash else {
                throw IngestError("Publication record does not match this copy. Existing data was retained.")
            }
        }
        // A crash can occur after removing the staging file but before removing its journal.
        if !exists(name) {
            guard let existing else { throw IngestError("The verified staging file is missing: \(name)") }
            let final = try parent.readFile(leaf); defer { close(final) }
            var info = stat()
            guard fstat(final, &info) == 0, info.st_ino == existing.inode,
                  try stream(final, token: token, consume: { _ in }) == existing.sha256 else {
                throw IngestError("The published file changed. Existing data was preserved: \(path)")
            }
            guard unlinkat(fd, journal, 0) == 0 else { throw systemError("Cannot finish publication record") }
            return
        }
        let input = try readFile(name); defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0 else { throw systemError("Cannot inspect verified staging file") }
        let digest = try stream(input, token: token) { _ in }
        guard expectedHash == nil || digest == expectedHash,
              existing == nil || existing?.sha256 == digest else {
            throw IngestError("Staging file checksum changed before publication: \(path)")
        }
        let output: Int32
        if let existing {
            output = try parent.updateFile(leaf)
            var info = stat()
            guard fstat(output, &info) == 0, info.st_ino == existing.inode else {
                close(output)
                throw IngestError("The unfinished destination was replaced. It will not be modified: \(path)")
            }
        } else {
            let created = openat(parent.fd, leaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard created >= 0 else { throw systemError("Cannot create final file; existing data is never replaced: \(path)") }
            output = created
            do {
                var info = stat()
                guard fstat(output, &info) == 0 else { throw systemError("Cannot inspect new final file") }
                let record = PublicationRecord(path: path, parentPath: parentPath, inode: info.st_ino, sha256: digest)
                try writeNew(journal, data: JSONEncoder().encode(record))
                _ = fsync(parent.fd); _ = fsync(fd)
            } catch { close(output); throw error }
        }
        defer { _ = fsync(output); close(output) }
        let saved = try fileSize(output)
        guard saved <= before.st_size,
              try prefixHash(input, bytes: saved, token: token) == prefixHash(output, bytes: saved, token: token) else {
            throw IngestError("Unfinished publication has changed content. Both copies were retained: \(path)")
        }
        guard lseek(input, saved, SEEK_SET) == saved, lseek(output, saved, SEEK_SET) == saved else {
            throw systemError("Cannot resume final publication")
        }
        var buffer = [UInt8](repeating: 0, count: 8 * 1024 * 1024)
        while true {
            try token.check()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw systemError("Cannot read verified staging file") }
            if count == 0 { break }
            try writeAll(output, data: Data(buffer[0..<count]))
            progress(count)
        }
        var times = [before.st_mtimespec, before.st_mtimespec]
        guard futimens(output, &times) == 0, fsync(output) == 0 else { throw systemError("Cannot flush final publication") }
        if fcntl(output, F_FULLFSYNC) == -1 && errno != ENOTSUP && errno != EINVAL { throw systemError("Cannot flush final drive cache") }
        guard lseek(output, 0, SEEK_SET) == 0,
              try stream(output, token: token, consume: { _ in }) == digest else {
            throw IngestError("Final publication checksum mismatch. Staging data was retained: \(path)")
        }
        try checkStamp(input, expected: FileStamp(before), path: name)
        // Confirm the pathname still refers to the open, verified output.
        let named = try parent.readFile(leaf); defer { close(named) }
        var namedInfo = stat(); var outputInfo = stat()
        guard fstat(named, &namedInfo) == 0, fstat(output, &outputInfo) == 0,
              namedInfo.st_ino == outputInfo.st_ino, namedInfo.st_dev == outputInfo.st_dev else {
            throw IngestError("Final path changed during publication. Staging data was retained: \(path)")
        }
        guard unlinkat(fd, name, 0) == 0 else { throw systemError("Cannot retire verified staging file") }
        guard unlinkat(fd, journal, 0) == 0 else { throw systemError("Cannot finish publication record") }
        _ = fsync(fd)
    }
    func smallData(_ path: String) throws -> Data {
        let file = try readFile(path); defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size <= 1024 * 1024 else { throw IngestError("Invalid job marker") }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = Darwin.read(file, &bytes, bytes.count)
        guard count == bytes.count else { throw IngestError("Cannot read job marker") }
        return Data(bytes)
    }
    func exists(_ name: String) -> Bool {
        var info = stat()
        return fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
    }
    func makeStage(_ name: String) throws -> Directory {
        try validComponent(name)
        guard mkdirat(fd, name, 0o755) == 0 else { throw systemError("Cannot create staging folder") }
        return try child(name)
    }
    func writeNew(_ name: String, data: Data) throws {
        let file = try newFile(name); defer { close(file) }
        try writeAll(file, data: data)
        guard fsync(file) == 0 else { throw systemError("Cannot flush \(name)") }
    }
    func publish(stage: String, final: String) throws {
        guard renameatx_np(fd, stage, fd, final, UInt32(RENAME_EXCL)) == 0 else {
            throw systemError("Cannot publish \(final); staging files were retained")
        }
        _ = fsync(fd)
    }
}

private struct PublicationRecord: Codable {
    let path: String
    let parentPath: String
    let inode: UInt64
    let sha256: String
}

func validComponent(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
        throw IngestError("Unsafe path component")
    }
}

func writeAll(_ fd: Int32, data: Data, startingAt: Int = 0) throws {
    try data.withUnsafeBytes { buffer in
        var offset = startingAt
        while offset < buffer.count {
            let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw systemError("Copy write failed") }
            offset += written
        }
    }
}

func stream(_ fd: Int32, token: CancellationToken, consume: (Data) throws -> Void) throws -> String {
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 8 * 1024 * 1024)
    while true {
        try token.check()
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw systemError("File read failed") }
        if count == 0 { break }
        let data = Data(buffer[0..<count]); hasher.update(data: data); try consume(data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

public func checksum(_ url: URL) throws -> String {
    let directory = try Directory(url: url.deletingLastPathComponent())
    let file = try directory.readFile(url.lastPathComponent); defer { close(file) }
    return try stream(file, token: CancellationToken()) { _ in }
}

func checkStamp(_ fd: Int32, expected: FileStamp, path: String) throws {
    var info = stat()
    guard fstat(fd, &info) == 0, FileStamp(info) == expected else {
        throw IngestError("The source changed after the preview: \(path). Scan the card again.")
    }
}
