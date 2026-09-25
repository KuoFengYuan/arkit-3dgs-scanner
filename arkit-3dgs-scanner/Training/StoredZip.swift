// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Compression
import Foundation

/// Minimal ZIP archives for SOG bundles, whose files sit at the archive root. The system's
/// directory zipping (`NSFileCoordinator` for uploading) adds the folder as a top-level entry,
/// which SOG readers do not expect. Entries are written stored (WebP is already compressed);
/// reading also accepts deflated entries from other tools.
nonisolated enum StoredZip {
    enum ZipError: LocalizedError {
        case damaged, unsupported, missing(String)
        var errorDescription: String? {
            switch self {
            case .damaged, .unsupported, .missing: return L10n.text("3DGS 模型檔案不完整")
            }
        }
    }

    /// An archive of `entries` (name, bytes) in order, stored without compression.
    static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for (name, data) in entries {
            let nameBytes = Array(name.utf8)
            let crc = CRC32.checksum(data)
            let offset = UInt32(out.count)
            out.appendLE32(0x0403_4B50)
            out.appendLE16(20); out.appendLE16(0x0800); out.appendLE16(0)   // version, UTF-8 names, stored
            out.appendLE16(0); out.appendLE16(0x21)                           // time, date (1980-01-01)
            out.appendLE32(crc); out.appendLE32(UInt32(data.count)); out.appendLE32(UInt32(data.count))
            out.appendLE16(UInt16(nameBytes.count)); out.appendLE16(0)
            out.append(contentsOf: nameBytes)
            out.append(data)
            central.appendLE32(0x0201_4B50)
            central.appendLE16(20); central.appendLE16(20); central.appendLE16(0x0800); central.appendLE16(0)
            central.appendLE16(0); central.appendLE16(0x21)
            central.appendLE32(crc); central.appendLE32(UInt32(data.count)); central.appendLE32(UInt32(data.count))
            central.appendLE16(UInt16(nameBytes.count)); central.appendLE16(0); central.appendLE16(0)
            central.appendLE16(0); central.appendLE16(0); central.appendLE32(0)
            central.appendLE32(offset)
            central.append(contentsOf: nameBytes)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.appendLE32(0x0605_4B50)
        out.appendLE16(0); out.appendLE16(0)
        out.appendLE16(UInt16(entries.count)); out.appendLE16(UInt16(entries.count))
        out.appendLE32(UInt32(central.count)); out.appendLE32(centralOffset)
        out.appendLE16(0)
        return out
    }

    /// Every entry of an archive by name (directories skipped). Checks each entry's CRC.
    static func entries(_ archive: Data) throws -> [String: Data] {
        let bytes = [UInt8](archive)
        func u16(_ o: Int) throws -> Int {
            guard o >= 0, o + 2 <= bytes.count else { throw ZipError.damaged }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int {
            guard o >= 0, o + 4 <= bytes.count else { throw ZipError.damaged }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        // The end-of-central-directory record is within the last 64 KiB (comment included).
        var eocd = -1
        var o = bytes.count - 22
        while o >= max(0, bytes.count - 22 - 65_535) {
            if try u32(o) == 0x0605_4B50 { eocd = o; break }
            o -= 1
        }
        guard eocd >= 0 else { throw ZipError.damaged }
        let count = try u16(eocd + 10)
        var entry = try u32(eocd + 16)
        var result: [String: Data] = [:]
        for _ in 0..<count {
            guard try u32(entry) == 0x0201_4B50 else { throw ZipError.damaged }
            let method = try u16(entry + 10)
            let crc = UInt32(try u32(entry + 16))
            let compressed = try u32(entry + 20), size = try u32(entry + 24)
            let nameLength = try u16(entry + 28), extraLength = try u16(entry + 30), commentLength = try u16(entry + 32)
            let local = try u32(entry + 42)
            guard entry + 46 + nameLength <= bytes.count else { throw ZipError.damaged }
            let name = String(decoding: bytes[(entry + 46)..<(entry + 46 + nameLength)], as: UTF8.self)
            entry += 46 + nameLength + extraLength + commentLength
            guard !name.hasSuffix("/") else { continue }
            guard try u32(local) == 0x0403_4B50 else { throw ZipError.damaged }
            let start = local + 30 + (try u16(local + 26)) + (try u16(local + 28))
            guard start >= 0, start + compressed <= bytes.count else { throw ZipError.damaged }
            let stored = Data(bytes[start..<(start + compressed)])
            let data: Data
            switch method {
            case 0: data = stored
            case 8: data = try inflate(stored, size: size)
            default: throw ZipError.unsupported
            }
            guard data.count == size, CRC32.checksum(data) == crc else { throw ZipError.damaged }
            result[name] = data
        }
        return result
    }

    /// Raw DEFLATE (the ZIP method 8 payload) via the Compression framework.
    static func inflate(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: size)
        let written = data.withUnsafeBytes { src in
            compression_decode_buffer(&out, size, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written == size else { throw ZipError.damaged }
        return Data(out)
    }
}

/// CRC-32 (IEEE 802.3), as ZIP stores it.
nonisolated enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for b in raw.bindMemory(to: UInt8.self) { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

nonisolated extension Data {
    mutating func appendLE16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
