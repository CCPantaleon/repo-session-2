import Foundation
import Darwin

@main struct CompareEngines {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: root.path) else { throw IngestError("Benchmark folder must be new") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let dir = try Directory(url: root)
        let source = try dir.newFile("generated-source.bin")
        for i in 0..<32 { try writeAll(source, data: Data(repeating: UInt8(i), count: 4 * 1024 * 1024)) }
        guard fsync(source) == 0 else { throw systemError("flush") }; close(source)
        let baseline = try checksum(root.appendingPathComponent("generated-source.bin"))
        print("128 MiB generated file; internal SSD; warm caches; copy + flush + destination SHA-256 + source reread SHA-256; seconds")
        for round in 0..<3 {
            let engines = round == 1 ? ["fcopyfile", "pipeline", "serial"] : ["serial", "pipeline", "fcopyfile"]
            for engine in engines {
                let src = try dir.readFile("generated-source.bin"); defer { close(src) }
                let name = "\(engine)-\(round).bin"
                let dst = try dir.newFile(name); defer { close(dst) }
                let begin = DispatchTime.now().uptimeNanoseconds
                if engine == "fcopyfile" {
                    guard fcopyfile(src, dst, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else { throw systemError("fcopyfile") }
                } else {
                    let digest: String
                    if engine == "pipeline" { digest = try pipelinedStream(src, token: CancellationToken()) { try writeAll(dst, data: $0) } }
                    else { digest = try stream(src, token: CancellationToken()) { try writeAll(dst, data: $0) } }
                    guard digest == baseline else { throw IngestError("Stream mismatch") }
                }
                guard fsync(dst) == 0 else { throw systemError("flush") }
                if fcntl(dst, F_FULLFSYNC) == -1 && errno != ENOTSUP && errno != EINVAL { throw systemError("full flush") }
                guard try checksum(root.appendingPathComponent(name)) == baseline,
                    try checksum(root.appendingPathComponent("generated-source.bin")) == baseline else { throw IngestError("Verification mismatch") }
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000_000
                print("\(round + 1) \(engine): \(String(format: "%.3f", seconds)) verified")
            }
        }
    }
}
