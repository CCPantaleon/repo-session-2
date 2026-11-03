import Foundation

// Seed-zero XXH64, canonical big-endian hex, for reading external MHLs only.
// Algorithm: https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
// SHA-256 remains the ingest integrity algorithm.
struct XXH64 {
    private static let p1: UInt64 = 0x9E3779B185EBCA87
    private static let p2: UInt64 = 0xC2B2AE3D27D4EB4F
    private static let p3: UInt64 = 0x165667B19E3779F9
    private static let p4: UInt64 = 0x85EBCA77C2B2AE63
    private static let p5: UInt64 = 0x27D4EB2F165667C5
    private var v1 = p1 &+ p2, v2 = p2, v3: UInt64 = 0, v4 = 0 &- p1
    private var length: UInt64 = 0
    private var tail: [UInt8] = []
    private static func rotate(_ x: UInt64, _ n: Int) -> UInt64 { (x << n) | (x >> (64 - n)) }
    private static func round(_ a: UInt64, _ lane: UInt64) -> UInt64 { rotate(a &+ (lane &* p2), 31) &* p1 }
    private mutating func stripe(_ bytes: UnsafeRawBufferPointer, offset: Int) {
        v1 = Self.round(v1, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
        v2 = Self.round(v2, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)))
        v3 = Self.round(v3, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 16, as: UInt64.self)))
        v4 = Self.round(v4, UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 24, as: UInt64.self)))
    }
    mutating func update(_ data: Data) {
        length &+= UInt64(data.count)
        data.withUnsafeBytes { raw in
            var offset = 0
            if !tail.isEmpty {
                let count = min(32 - tail.count, raw.count)
                tail.append(contentsOf: raw.prefix(count)); offset = count
                if tail.count == 32 { let block = tail; block.withUnsafeBytes { stripe($0, offset: 0) }; tail.removeAll(keepingCapacity: true) }
                else { return }
            }
            while offset + 32 <= raw.count { stripe(raw, offset: offset); offset += 32 }
            tail.append(contentsOf: raw[offset..<raw.count])
        }
    }
    func hex() -> String {
        var hash: UInt64
        if length >= 32 {
            hash = Self.rotate(v1, 1) &+ Self.rotate(v2, 7) &+ Self.rotate(v3, 12) &+ Self.rotate(v4, 18)
            for value in [v1, v2, v3, v4] { hash = (hash ^ Self.round(0, value)) &* Self.p1 &+ Self.p4 }
        } else { hash = Self.p5 }
        hash &+= length
        tail.withUnsafeBytes { raw in
            var offset = 0
            while offset + 8 <= raw.count {
                hash ^= Self.round(0, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
                hash = Self.rotate(hash, 27) &* Self.p1 &+ Self.p4; offset += 8
            }
            if offset + 4 <= raw.count {
                hash ^= UInt64(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) &* Self.p1
                hash = Self.rotate(hash, 23) &* Self.p2 &+ Self.p3; offset += 4
            }
            while offset < raw.count { hash ^= UInt64(raw[offset]) &* Self.p5; hash = Self.rotate(hash, 11) &* Self.p1; offset += 1 }
        }
        hash ^= hash >> 33; hash &*= Self.p2; hash ^= hash >> 29; hash &*= Self.p3; hash ^= hash >> 32
        return String(format: "%016llx", hash)
    }
}
