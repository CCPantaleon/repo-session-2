import XCTest
import Foundation
import Darwin
import CryptoKit
@testable import IngestCore

final class PipelineTests: XCTestCase {
    private func withSource(_ data: Data, _ body: (Int32) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OKCopy-Pipeline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try data.write(to: root.appendingPathComponent("source"))
        let directory = try Directory(url: root)
        let fd = try directory.readFile("source"); defer { close(fd) }
        try body(fd)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("source")), data)
    }
    func testOrderedBytesAcrossChunkBoundariesAndSHA256() throws {
        var data = Data()
        for index in 0..<37 { data.append(Data(repeating: UInt8(index), count: 1024 * 1024 + 3)) }
        try withSource(data) { fd in
            var copied = Data()
            let digest = try pipelinedStream(fd, token: CancellationToken()) { copied.append($0) }
            XCTAssertEqual(copied, data)
            XCTAssertEqual(digest, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
    }
    func testEmptySource() throws {
        try withSource(Data()) { fd in
            let digest = try pipelinedStream(fd, token: CancellationToken()) { _ in XCTFail("Empty source delivered data") }
            XCTAssertEqual(digest, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        }
    }
    func testCancellationDuringConsumptionJoinsProducer() throws {
        try withSource(Data(repeating: 7, count: 48 * 1024 * 1024)) { fd in
            let token = CancellationToken(); var chunks = 0
            XCTAssertThrowsError(try pipelinedStream(fd, token: token) { _ in chunks += 1; token.cancel() })
            XCTAssertEqual(chunks, 1)
            // Returning means the producer no longer owns/uses the source descriptor.
            XCTAssertEqual(lseek(fd, 0, SEEK_SET), 0)
            XCTAssertEqual(try stream(fd, token: CancellationToken()) { _ in }, SHA256.hash(data: Data(repeating: 7, count: 48 * 1024 * 1024)).map { String(format: "%02x", $0) }.joined())
        }
    }
    func testConsumerFailureWakesBackpressuredProducer() throws {
        try withSource(Data(repeating: 1, count: 64 * 1024 * 1024)) { fd in
            XCTAssertThrowsError(try pipelinedStream(fd, token: CancellationToken()) { _ in
                // Let read-ahead fill while a destination is busy. It must remain bounded.
                Thread.sleep(forTimeInterval: 0.1)
                XCTAssertLessThanOrEqual(lseek(fd, 0, SEEK_CUR), 4 * 8 * 1024 * 1024)
                throw IngestError("Synthetic destination disconnected")
            }) { XCTAssertEqual($0.localizedDescription, "Synthetic destination disconnected") }
        }
    }
    func testReadErrorPropagates() {
        XCTAssertThrowsError(try pipelinedStream(-1, token: CancellationToken()) { _ in XCTFail("Invalid source delivered data") }) {
            XCTAssertTrue($0.localizedDescription.contains("File read failed"))
        }
    }
    func testPreCancelledPipelineDoesNotConsume() throws {
        try withSource(Data([1, 2, 3])) { fd in
            let token = CancellationToken(); token.cancel()
            XCTAssertThrowsError(try pipelinedStream(fd, token: token) { _ in XCTFail("Cancelled pipeline delivered data") })
        }
    }
}
