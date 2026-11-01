import Compression
import Foundation

public enum ZipError: Error, CustomStringConvertible {
    case notAZip
    case unsupported(String)
    case corrupt(String)

    public var description: String {
        switch self {
        case .notAZip: "not a ZIP/.docx file"
        case .unsupported(let s): "unsupported ZIP feature: \(s)"
        case .corrupt(let s): "corrupt ZIP: \(s)"
        }
    }
}

/// Minimal ZIP reader/writer for .docx packages (store + deflate, no ZIP64,
/// no encryption). Entries that aren't modified are written back with their
/// original compressed bytes, so untouched parts stay byte-identical.
public struct ZipArchive: Sendable {
    public struct Entry: Sendable {
        public var name: String
        var method: UInt16
        var crc: UInt32
        var compressed: Data
        var uncompressedSize: UInt32
        var modTime: UInt16
        var modDate: UInt16
    }

    public private(set) var entries: [Entry]

    public init(data: Data) throws {
        let b = [UInt8](data)
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }

        // End of central directory: scan back from the end (comment ≤ 64 KB).
        guard b.count >= 22 else { throw ZipError.notAZip }
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 22 - 65_535) {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = Int(u16(eocd + 10))
        var p = Int(u32(eocd + 16))
        guard count != 0xFFFF, p != 0xFFFF_FFFF else { throw ZipError.unsupported("ZIP64") }

        var entries: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x0201_4b50 else { throw ZipError.corrupt("central directory") }
            let flags = u16(p + 8)
            if flags & 1 != 0 { throw ZipError.unsupported("encryption") }
            let method = u16(p + 10)
            let nameLen = Int(u16(p + 28)), extraLen = Int(u16(p + 30)), commentLen = Int(u16(p + 32))
            let local = Int(u32(p + 42))
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            let compSize = Int(u32(p + 20))
            guard local + 30 <= b.count, u32(local) == 0x0403_4b50 else { throw ZipError.corrupt("local header for \(name)") }
            let start = local + 30 + Int(u16(local + 26)) + Int(u16(local + 28))
            guard start + compSize <= b.count else { throw ZipError.corrupt("data for \(name)") }
            entries.append(Entry(name: name, method: method, crc: u32(p + 16), compressed: Data(b[start..<(start + compSize)]),
                                 uncompressedSize: u32(p + 24), modTime: u16(p + 12), modDate: u16(p + 14)))
            p += 46 + nameLen + extraLen + commentLen
        }
        self.entries = entries
    }

    public var names: [String] { entries.map(\.name) }

    public func data(_ name: String) throws -> Data? {
        guard let e = entries.first(where: { $0.name == name }) else { return nil }
        switch e.method {
        case 0: return e.compressed
        case 8: return try Self.inflate(e.compressed, size: Int(e.uncompressedSize))
        default: throw ZipError.unsupported("compression method \(e.method)")
        }
    }

    /// Replaces (or adds) an entry, deflating the new contents.
    public mutating func set(_ name: String, _ contents: Data) throws {
        let deflated = try Self.deflate(contents)
        let useDeflate = deflated.count < contents.count
        let entry = Entry(name: name, method: useDeflate ? 8 : 0, crc: Self.crc32(contents),
                          compressed: useDeflate ? deflated : contents, uncompressedSize: UInt32(contents.count),
                          modTime: entries.first { $0.name == name }?.modTime ?? 0, modDate: entries.first { $0.name == name }?.modDate ?? 0x21)
        if let i = entries.firstIndex(where: { $0.name == name }) { entries[i] = entry } else { entries.append(entry) }
    }

    public func serialized() -> Data {
        var out = Data(), central = Data()
        func put16(_ d: inout Data, _ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put32(_ d: inout Data, _ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        for e in entries {
            let offset = UInt32(out.count)
            let name = Data(e.name.utf8)
            put32(&out, 0x0403_4b50); put16(&out, 20); put16(&out, 0x0800); put16(&out, e.method)
            put16(&out, e.modTime); put16(&out, e.modDate); put32(&out, e.crc)
            put32(&out, UInt32(e.compressed.count)); put32(&out, e.uncompressedSize)
            put16(&out, UInt16(name.count)); put16(&out, 0); out.append(name); out.append(e.compressed)

            put32(&central, 0x0201_4b50); put16(&central, 20); put16(&central, 20); put16(&central, 0x0800); put16(&central, e.method)
            put16(&central, e.modTime); put16(&central, e.modDate); put32(&central, e.crc)
            put32(&central, UInt32(e.compressed.count)); put32(&central, e.uncompressedSize)
            put16(&central, UInt16(name.count)); put16(&central, 0); put16(&central, 0); put16(&central, 0); put16(&central, 0)
            put32(&central, 0); put32(&central, offset); central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        put32(&out, 0x0605_4b50); put16(&out, 0); put16(&out, 0)
        put16(&out, UInt16(entries.count)); put16(&out, UInt16(entries.count))
        put32(&out, UInt32(central.count)); put32(&out, cdOffset); put16(&out, 0)
        return out
    }

    // MARK: Codecs

    static func inflate(_ data: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt("inflate produced \(written) of \(size) bytes") }
        return out
    }

    static func deflate(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        let capacity = data.count + data.count / 10 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw ZipError.corrupt("deflate failed") }
        return out.prefix(written)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
