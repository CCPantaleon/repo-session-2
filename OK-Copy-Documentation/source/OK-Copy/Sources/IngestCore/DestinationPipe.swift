import Foundation

/// A private bounded queue per destination. Failure closes only this writer.
final class DestinationPipe: @unchecked Sendable {
    private let condition = NSCondition()
    private var chunks: [(Data, Int64)] = []
    private var ended = false
    private var failure: Error?
    private let group = DispatchGroup()
    private let token: CancellationToken
    init(token: CancellationToken, write: @escaping (Data, Int64) throws -> Void) {
        self.token = token; group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.group.leave() }
            do { while let (data, position) = try self.next() { try token.check(); try write(data, position) } }
            catch { self.fail(error) }
        }
    }
    func send(_ data: Data, at position: Int64) throws {
        condition.lock(); defer { condition.unlock() }
        while chunks.count >= 2 && failure == nil && !ended {
            try token.check(); _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        try token.check()
        if let failure { throw failure }
        guard !ended else { throw IngestError("Destination writer stopped") }
        chunks.append((data, position)); condition.broadcast()
    }
    private func next() throws -> (Data, Int64)? {
        condition.lock(); defer { condition.unlock() }
        while chunks.isEmpty && !ended && failure == nil {
            try token.check(); _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        try token.check()
        if let failure { throw failure }
        if chunks.isEmpty { return nil }
        let chunk = chunks.removeFirst(); condition.broadcast(); return chunk
    }
    func fail(_ error: Error) { condition.lock(); failure = error; ended = true; chunks.removeAll(); condition.broadcast(); condition.unlock() }
    func finish() throws {
        condition.lock(); ended = true; condition.broadcast(); condition.unlock(); group.wait()
        condition.lock(); let error = failure; condition.unlock(); if let error { throw error }
    }
    func abortAndJoin() { fail(IngestError("Destination writer paused")); group.wait() }
}
