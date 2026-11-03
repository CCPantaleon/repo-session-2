import Foundation
import CryptoKit
import Darwin

public struct VerificationFinding: Sendable {
    public let path: String
    public let status: String
    public let detail: String
}
public struct VerificationSummary: Sendable {
    public let findings: [VerificationFinding]
    public var passed: Bool { !findings.isEmpty && findings.allSatisfy { $0.status == "Verified" } }
    public var html: String {
        let rows = findings.map { "<tr><td>\(Report.escape($0.path))</td><td style='color: \($0.status == "Verified" ? "#228844" : "#cc3333")'>\(Report.escape($0.status))</td><td>\(Report.escape($0.detail))</td></tr>" }.joined()
        return "<!doctype html><html><head><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'\"><style>body{font:14px -apple-system;padding:32px}td,th{padding:12px;text-align:left;border-bottom:1px solid #aaa;overflow-wrap:anywhere}table{width:100%}</style></head><body><h1>OK, Copy · Standalone verification</h1><h2 style='color: \(passed ? "#228844" : "#cc3333")'>\(passed ? "All listed files verified" : "Needs attention")</h2><p>Read-only verification of listed data forks. Unlisted files and unsupported hashes are not certified. No source files were changed.</p><table><tr><th>Path</th><th>Status</th><th>Detail</th></tr>\(rows)</table></body></html>"
    }
}

public enum MediaManifest {
    struct Entry { let path: String; let size: Int64?; let hashes: [String: String] }
    static func export(plan: BatchPlan, project: Directory, records: [CopyReceipt], target: URL, token: CancellationToken) throws {
        try token.check()
        let stamp = ISO8601DateFormatter().string(from: Date())
        var legacy: [String] = []; var asc: [String] = []
        for file in plan.files {
            guard let receipt = records.first(where: { $0.outputPath == file.outputPath })?.destinations.first(where: { $0.root == target }),
                  let sha1 = receipt.sha1 else { throw IngestError("A verified SHA-1 is required for interoperable manifest export") }
            let path = xml(file.outputPath)
            legacy.append("<hash><file>\(path)</file><size>\(file.original.bytes)</size><sha1>\(sha1)</sha1></hash>")
            asc.append("<hash><path size=\"\(file.original.bytes)\">\(path)</path><sha1 action=\"verified\" hashdate=\"\(stamp)\">\(sha1)</sha1></hash>")
        }
        let id = UUID().uuidString
        // Flat manifests at project root: paths resolve unambiguously from that folder.
        let old = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><hashlist version=\"1.1\"><creatorinfo><name>OK, Copy</name><creationdate>\(stamp)</creationdate></creatorinfo>\(legacy.joined())</hashlist>"
        let modern = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><hashlist xmlns=\"urn:ASC:MHL:v2.0\" version=\"2.0\"><creatorinfo><creationdate>\(stamp)</creationdate><hostname>\(xml(ProcessInfo.processInfo.hostName))</hostname><tool version=\"\(AppVersion.current)\">OK, Copy</tool><comment>Flat manifest of this job's verified originals; SHA-256 receipts use the report location selected for this job. No chain-of-custody history is claimed.</comment></creatorinfo><processinfo><process>flatten</process></processinfo><hashes>\(asc.joined())</hashes></hashlist>"
        try project.writeNew("OKCopy-" + id + "-legacy.mhl", data: Data(old.utf8))
        try project.writeNew("OKCopy-" + id + "-asc.mhl", data: Data(modern.utf8))
    }
    static func xml(_ value: String) -> String { Report.escape(value).replacingOccurrences(of: "'", with: "&apos;") }

    public static func verify(manifest: URL, root: URL, token: CancellationToken = CancellationToken(), progress: @escaping IngestEngine.Progress = { _ in }) throws -> VerificationSummary {
        let directory = try Directory(url: manifest.deletingLastPathComponent())
        let fd = try directory.readFile(manifest.lastPathComponent); defer { close(fd) }
        guard try fileSize(fd) <= 128 * 1024 * 1024 else { throw IngestError("Manifest is too large (128 MiB limit)") }
        var data = Data()
        _ = try stream(fd, token: token) { data.append($0) }
        let entries = try parse(data)
        let base = try Directory(url: root)
        var findings: [VerificationFinding] = []
        for entry in entries {
            try token.check()
            progress(IngestProgress(phase: "Verifying manifest", path: entry.path, completedFiles: findings.count, totalFiles: entries.count, fraction: Double(findings.count) / Double(max(1, entries.count))))
            do {
                guard !entry.path.hasPrefix("/"), !entry.path.contains("\\") else { throw IngestError("Unsafe manifest path") }
                for component in entry.path.split(separator: "/", omittingEmptySubsequences: false) { try validComponent(String(component)) }
                let input = try base.readFile(entry.path); defer { close(input) }
                var info = stat(); guard fstat(input, &info) == 0 else { throw systemError("Cannot inspect file") }
                let before = FileStamp(info)
                if let size = entry.size, size != before.size { throw IngestError("File size mismatch") }
                var sha1 = Insecure.SHA1(); var md5 = Insecure.MD5(); var xxh = XXH64()
                let useXXH = entry.hashes.keys.contains { ["xxh64", "xxhash64", "xxhash64be"].contains($0) }
                let sha256 = try stream(input, token: token) { chunk in if entry.hashes["sha1"] != nil { sha1.update(data: chunk) }; if entry.hashes["md5"] != nil { md5.update(data: chunk) }; if useXXH { xxh.update(chunk) } }
                try checkStamp(input, expected: before, path: entry.path)
                let calculated = ["sha256": sha256, "sha1": hex(sha1.finalize()), "md5": hex(md5.finalize()), "xxh64": xxh.hex(), "xxhash64": xxh.hex(), "xxhash64be": xxh.hex()]
                let unsupported = entry.hashes.keys.filter { calculated[$0] == nil }
                guard !entry.hashes.isEmpty else { throw IngestError("No supported checksum listed") }
                for (algorithm, expected) in entry.hashes {
                    if let actual = calculated[algorithm], actual != expected.lowercased() { throw IngestError(algorithm.uppercased() + " mismatch") }
                }
                if !unsupported.isEmpty {
                    findings.append(VerificationFinding(path: entry.path, status: "Unsupported", detail: "Not fully verified: " + unsupported.sorted().joined(separator: ", ")))
                } else { findings.append(VerificationFinding(path: entry.path, status: "Verified", detail: entry.hashes.keys.sorted().joined(separator: ", "))) }
            } catch {
                if token.isCancelled { throw error }
                findings.append(VerificationFinding(path: entry.path, status: "Failed", detail: error.localizedDescription))
            }
        }
        progress(IngestProgress(phase: "Manifest verification finished", path: "", completedFiles: entries.count, totalFiles: entries.count, fraction: 1))
        return VerificationSummary(findings: findings)
    }
    static func parse(_ data: Data) throws -> [Entry] {
        // Reject DTD/entity declarations before XML parsing, including non-UTF8 bypasses.
        guard let text = String(data: data, encoding: .utf8), !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw IngestError("Only UTF-8 manifests without DTDs or entities are supported") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = object["files"] as? [[String: Any]], object["algorithm"] as? String == "SHA-256" else { throw IngestError("Unsupported JSON receipt") }
            let entries = try files.map { file -> Entry in
                guard let path = file["outputPath"] as? String, let hash = file["sourceSHA256"] as? String else { throw IngestError("Incomplete JSON receipt") }
                return Entry(path: path, size: (file["bytes"] as? NSNumber)?.int64Value, hashes: ["sha256": hash])
            }
            return try validated(entries)
        }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), root.localName == "hashlist", ["1.0", "1.1", "2.0"].contains(root.attribute(forName: "version")?.stringValue ?? "") else { throw IngestError("Unsupported MHL document") }
        let version = root.attribute(forName: "version")?.stringValue
        if version == "2.0", root.uri != "urn:ASC:MHL:v2.0" { throw IngestError("Invalid ASC MHL namespace") }
        let container = version == "2.0" ? root.mhlChildren( "hashes", namespace: root.uri).first : root
        guard let container else { throw IngestError("MHL has no file hashes") }
        // Directory hashes and references require history validation; never silently pass them.
        if !(root.mhlChildren( "references", namespace: root.uri).isEmpty) || !(container.mhlChildren( "directoryhash", namespace: root.uri).isEmpty) {
            throw IngestError("This manifest contains directory hashes or history references. Export a flat file manifest for standalone verification.")
        }
        if let process = root.mhlChildren("processinfo", namespace: root.uri).first, !process.mhlChildren("roothash", namespace: root.uri).isEmpty {
            throw IngestError("Root directory hash verification requires a history-aware verifier. Export a flat file manifest.")
        }
        let entries = try container.mhlChildren( "hash", namespace: root.uri).map { node -> Entry in
            let pathElement = node.mhlChildren( version == "2.0" ? "path" : "file", namespace: root.uri).first
            guard let path = pathElement?.stringValue else { throw IngestError("MHL file path missing") }
            let size = version == "2.0" ? pathElement?.attribute(forName: "size")?.stringValue : node.mhlChildren( "size", namespace: root.uri).first?.stringValue
            if let size, Int64(size) == nil || Int64(size)! < 0 { throw IngestError("Invalid file size in manifest") }
            var hashes: [String: String] = [:]
            for child in node.children ?? [] {
                guard let element = child as? XMLElement, let name = element.localName else { continue }
                if !["file", "path", "size", "lastmodificationdate", "creationdate"].contains(name) {
                    guard (element.uri ?? "") == (root.uri ?? "") else { throw IngestError("Foreign checksum namespace") }
                    guard hashes[name] == nil else { throw IngestError("Duplicate hash field") }
                    hashes[name] = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return Entry(path: path, size: size.flatMap(Int64.init), hashes: hashes)
        }
        return try validated(entries)
    }
    private static func validated(_ entries: [Entry]) throws -> [Entry] {
        var paths = Set<String>()
        guard !entries.isEmpty else { throw IngestError("Manifest contains no files") }
        for entry in entries {
            guard paths.insert(BatchPlanner.fold(entry.path)).inserted else { throw IngestError("Duplicate manifest path") }
            for (algorithm, hash) in entry.hashes {
                if let length = ["sha1": 40, "sha256": 64, "md5": 32, "xxh64": 16, "xxhash64": 16, "xxhash64be": 16][algorithm] {
                    guard hash.count == length, hash.allSatisfy({ $0.isHexDigit }) else { throw IngestError("Invalid " + algorithm + " checksum") }
                }
            }
        }
        return entries
    }
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
}

private extension XMLElement {
    func mhlChildren(_ name: String, namespace: String?) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { ($0.localName ?? $0.name) == name && ($0.uri ?? "") == (namespace ?? "") }
    }
}
