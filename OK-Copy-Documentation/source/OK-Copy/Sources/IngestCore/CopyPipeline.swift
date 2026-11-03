import Foundation

// Read/hash on one worker while the caller writes the preceding chunk. Backpressure
// caps queued data at two 8 MiB chunks, independent of file size or target count.
// The caller retains descriptor ownership; we join the worker before returning.
func pipelinedStream(_ fd: Int32, token: CancellationToken, consume: (Data) throws -> Void) throws -> String {
    let channel = CopyChannel()
    let worker = DispatchGroup()
    worker.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        defer { worker.leave() }
        do {
            let digest = try stream(fd, token: token) { try channel.send($0, token: token) }
            channel.finish(.success(digest))
        } catch { channel.finish(.failure(error)) }
    }
    defer { channel.abort(); worker.wait() }
    while let chunk = try channel.receive(token: token) {
        try token.check()
        try consume(chunk)
    }
    try token.check()
    return try channel.digest()
}

private final class CopyChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var result: Result<String, Error>?
    private var aborted = false
    private let capacity = 2

    func send(_ data: Data, token: CancellationToken) throws {
        condition.lock(); defer { condition.unlock() }
        while chunks.count == capacity && !aborted {
            try token.check()
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        try token.check()
        guard !aborted else { throw IngestError("Copy pipeline stopped") }
        chunks.append(data); condition.broadcast()
    }
    func receive(token: CancellationToken) throws -> Data? {
        condition.lock(); defer { condition.unlock() }
        while chunks.isEmpty && result == nil && !aborted {
            try token.check()
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        try token.check()
        if case .failure(let error) = result { throw error }
        guard !chunks.isEmpty else { return nil }
        let data = chunks.removeFirst(); condition.broadcast(); return data
    }
    func finish(_ result: Result<String, Error>) {
        condition.lock(); self.result = result; condition.broadcast(); condition.unlock()
    }
    func digest() throws -> String {
        condition.lock(); defer { condition.unlock() }
        guard let result else { throw IngestError("Copy pipeline ended without a checksum") }
        return try result.get()
    }
    func abort() {
        condition.lock(); aborted = true; chunks.removeAll(); condition.broadcast(); condition.unlock()
    }
}
