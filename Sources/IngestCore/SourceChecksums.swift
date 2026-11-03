import Foundation
import Darwin

/// Job-owned, write-once source references for copies started without a review.
enum SourceChecksums {
    static func load(_ id: String, from workspace: Directory) throws -> String? {
        let name = id + ".source-sha256"
        guard workspace.exists(name) else { return nil }
        guard let hash = String(data: try workspace.smallData(name), encoding: .utf8),
              hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
            throw IngestError("Invalid saved source checksum. Partial files were retained.")
        }
        return hash
    }
    static func save(_ id: String, hash: String, in workspace: Directory) throws {
        if let previous = try load(id, from: workspace) {
            guard previous == hash else { throw IngestError("Source content differs from its saved checksum") }
        } else {
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw IngestError("Invalid source checksum") }
            try workspace.writeNew(id + ".source-sha256", data: Data(hash.utf8))
            _ = fsync(workspace.fd)
        }
    }
}
