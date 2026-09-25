// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation

/// Lossless WebP (VP8L, RFC 9649) encoder for RGBA8 images. ImageIO reads WebP but cannot
/// write it, and SOG model files are lossless WebP textures.
///
/// A small subset of the format: an optional predictor transform (every block predicts from
/// the left pixel, which suits Morton-ordered splat data laid out row by row), one prefix code
/// group, no colour cache and no backward references. Each image is tried with and without the
/// predictor and the smaller stream is kept. Decoders read it like any VP8L file.
nonisolated enum WebPLossless {
    enum EncodeError: Error { case badSize }

    /// RIFF/WebP file for `rgba` (width × height pixels, 4 bytes each, row-major).
    static func encode(rgba: [UInt8], width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, rgba.count == width * height * 4 else { throw EncodeError.badSize }
        var argb = [UInt32](repeating: 0, count: width * height)
        var opaque = true
        for i in 0..<argb.count {
            let r = UInt32(rgba[4 * i]), g = UInt32(rgba[4 * i + 1]), b = UInt32(rgba[4 * i + 2]), a = UInt32(rgba[4 * i + 3])
            argb[i] = a << 24 | r << 16 | g << 8 | b
            if a != 255 { opaque = false }
        }
        let plain = stream(argb, width: width, height: height, predictor: false, opaque: opaque)
        let predicted = stream(argb, width: width, height: height, predictor: true, opaque: opaque)
        let body = predicted.count < plain.count ? predicted : plain
        var file = Data()
        let chunk = body.count + (body.count & 1)
        file.append(contentsOf: Array("RIFF".utf8)); file.appendLE32(UInt32(4 + 8 + chunk))
        file.append(contentsOf: Array("WEBP".utf8)); file.append(contentsOf: Array("VP8L".utf8)); file.appendLE32(UInt32(body.count))
        file.append(body)
        if body.count & 1 == 1 { file.append(0) }
        return file
    }

    /// The VP8L bitstream (signature, header, transforms, entropy-coded image).
    static func stream(_ argb: [UInt32], width: Int, height: Int, predictor: Bool, opaque: Bool) -> Data {
        var w = BitWriter()
        w.write(0x2F, 8)
        w.write(UInt32(width - 1), 14)
        w.write(UInt32(height - 1), 14)
        w.write(opaque ? 0 : 1, 1)
        w.write(0, 3)
        var pixels = argb
        if predictor {
            // Predictor transform, mode 1 (left) in every block. The top-left pixel predicts
            // from opaque black, the first row from the left and the first column from above.
            let bits = 9
            w.write(1, 1); w.write(0, 2); w.write(UInt32(bits - 2), 3)
            let bw = (width + (1 << bits) - 1) >> bits, bh = (height + (1 << bits) - 1) >> bits
            writeImage(&w, [UInt32](repeating: 1 << 8, count: bw * bh), mainImage: false)
            for y in stride(from: height - 1, through: 0, by: -1) {
                for x in stride(from: width - 1, through: 0, by: -1) {
                    let i = y * width + x
                    let prediction: UInt32 = x == 0 && y == 0 ? 0xFF00_0000 : (x == 0 ? argb[i - width] : argb[i - 1])
                    pixels[i] = subtractPixels(argb[i], prediction)
                }
            }
        }
        w.write(0, 1)                              // no further transforms
        writeImage(&w, pixels, mainImage: true)
        return w.finish()
    }

    static func subtractPixels(_ a: UInt32, _ b: UInt32) -> UInt32 {
        var out: UInt32 = 0
        for shift in [0, 8, 16, 24] as [UInt32] {
            let d = ((a >> shift) & 0xFF) &- ((b >> shift) & 0xFF)
            out |= (d & 0xFF) << shift
        }
        return out
    }

    /// Entropy-coded image: no colour cache, one prefix code group, literals only.
    static func writeImage(_ w: inout BitWriter, _ pixels: [UInt32], mainImage: Bool) {
        w.write(0, 1)                              // no colour cache
        if mainImage { w.write(0, 1) }            // no meta prefix codes
        var green = [Int](repeating: 0, count: 256 + 24), red = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256), alpha = [Int](repeating: 0, count: 256)
        for p in pixels {
            green[Int((p >> 8) & 0xFF)] += 1; red[Int((p >> 16) & 0xFF)] += 1
            blue[Int(p & 0xFF)] += 1; alpha[Int(p >> 24)] += 1
        }
        let codes = [green, red, blue, alpha, [Int](repeating: 0, count: 40)].map { PrefixCode(counts: $0) }
        for code in codes { code.writeDefinition(&w) }
        let g = codes[0], r = codes[1], b = codes[2], a = codes[3]
        for p in pixels {
            g.write(&w, Int((p >> 8) & 0xFF)); r.write(&w, Int((p >> 16) & 0xFF))
            b.write(&w, Int(p & 0xFF)); a.write(&w, Int(p >> 24))
        }
    }

    // MARK: Bits

    /// LSB-first bit packing, as VP8L reads it.
    struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var accumulator: UInt64 = 0
        private var used = 0

        mutating func write(_ value: UInt32, _ count: Int) {
            guard count > 0 else { return }
            accumulator |= UInt64(value & UInt32((UInt64(1) << count) - 1)) << used
            used += count
            while used >= 8 {
                bytes.append(UInt8(accumulator & 0xFF))
                accumulator >>= 8
                used -= 8
            }
        }

        mutating func finish() -> Data {
            if used > 0 { bytes.append(UInt8(accumulator & 0xFF)); accumulator = 0; used = 0 }
            return Data(bytes)
        }
    }

    // MARK: Prefix codes

    /// A canonical prefix (Huffman) code of at most 15 bits. One or two symbols below 256
    /// use VP8L's simple code, which needs no bits per symbol for a single symbol.
    struct PrefixCode {
        let lengths: [Int]
        let codes: [UInt32]       // bit-reversed, ready for LSB-first writing
        let used: [Int]

        init(counts: [Int]) {
            used = counts.indices.filter { counts[$0] > 0 }
            if used.count <= 1 {
                // The simple code of one symbol has zero-length codes.
                lengths = [Int](repeating: 0, count: counts.count)
                codes = [UInt32](repeating: 0, count: counts.count)
                return
            }
            lengths = Self.limitedLengths(counts, limit: 15)
            codes = Self.canonicalCodes(lengths)
        }

        var isSimple: Bool { used.count <= 1 || (used.count == 2 && used.allSatisfy { $0 < 256 }) }

        func write(_ w: inout BitWriter, _ symbol: Int) {
            guard used.count > 1 else { return }
            if isSimple { w.write(symbol == used[0] ? 0 : 1, 1); return }
            w.write(codes[symbol], lengths[symbol])
        }

        func writeDefinition(_ w: inout BitWriter) {
            if isSimple {
                // Simple code: 1 bit set, symbol count - 1, then 1 or 8 bits per symbol.
                let symbols = used.isEmpty ? [0] : used
                w.write(1, 1)
                w.write(UInt32(symbols.count - 1), 1)
                if symbols[0] < 2 { w.write(0, 1); w.write(UInt32(symbols[0]), 1) } else { w.write(1, 1); w.write(UInt32(symbols[0]), 8) }
                if symbols.count == 2 { w.write(UInt32(symbols[1]), 8) }
                return
            }
            w.write(0, 1)
            // Run-length coded code lengths (0-15 literal, 16 repeat previous, 17/18 zero runs).
            var tokens: [(symbol: Int, extra: UInt32, bits: Int)] = []
            var i = 0
            var previous = 8
            while i < lengths.count {
                let value = lengths[i]
                var run = 1
                while i + run < lengths.count && lengths[i + run] == value { run += 1 }
                if value == 0 {
                    var left = run
                    while left > 0 {
                        if left >= 11 { let n = min(left, 138); tokens.append((18, UInt32(n - 11), 7)); left -= n }
                        else if left >= 3 { tokens.append((17, UInt32(left - 3), 3)); left = 0 }
                        else { tokens.append((0, 0, 0)); left -= 1 }
                    }
                } else {
                    var left = run
                    if value != previous { tokens.append((value, 0, 0)); left -= 1; previous = value }
                    while left > 0 {
                        if left >= 3 { let n = min(left, 6); tokens.append((16, UInt32(n - 3), 2)); left -= n }
                        else { tokens.append((value, 0, 0)); left -= 1 }
                    }
                }
                i += run
            }
            var counts = [Int](repeating: 0, count: 19)
            for t in tokens { counts[t.symbol] += 1 }
            var lengthLengths = Self.limitedLengths(counts, limit: 7)
            if counts.filter({ $0 > 0 }).count == 1 {
                // A single code-length symbol still needs a complete code: add a dummy one.
                let only = counts.firstIndex { $0 > 0 }!
                lengthLengths = [Int](repeating: 0, count: 19)
                lengthLengths[only] = 1
                lengthLengths[only == 0 ? 1 : 0] = 1
            }
            let lengthCodes = Self.canonicalCodes(lengthLengths)
            let order = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
            var count = order.count
            while count > 4 && lengthLengths[order[count - 1]] == 0 { count -= 1 }
            w.write(UInt32(count - 4), 4)
            for k in 0..<count { w.write(UInt32(lengthLengths[order[k]]), 3) }
            w.write(0, 1)                          // max_symbol = alphabet size
            for t in tokens {
                w.write(lengthCodes[t.symbol], lengthLengths[t.symbol])
                if t.bits > 0 { w.write(t.extra, t.bits) }
            }
        }

        /// Huffman code lengths, capped at `limit` by flattening small counts until it fits.
        static func limitedLengths(_ counts: [Int], limit: Int) -> [Int] {
            var floor = 0
            while true {
                let lengths = huffmanLengths(counts.map { $0 > 0 ? max($0, floor) : 0 })
                if (lengths.max() ?? 0) <= limit { return lengths }
                floor = max(1, floor * 2)
            }
        }

        static func huffmanLengths(_ counts: [Int]) -> [Int] {
            var lengths = [Int](repeating: 0, count: counts.count)
            let symbols = counts.indices.filter { counts[$0] > 0 }
            if symbols.count == 1 { lengths[symbols[0]] = 1; return lengths }
            guard symbols.count > 1 else { return lengths }
            // Nodes: leaves first, then internal nodes; parent links give the depths.
            var weight = symbols.map { counts[$0] }
            var parent = [Int](repeating: -1, count: 2 * symbols.count - 1)
            var heap = Array(0..<symbols.count)
            func less(_ a: Int, _ b: Int) -> Bool { weight[a] != weight[b] ? weight[a] < weight[b] : a < b }
            func siftDown(_ start: Int) {
                var i = start
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < heap.count && less(heap[l], heap[m]) { m = l }
                    if r < heap.count && less(heap[r], heap[m]) { m = r }
                    if m == i { return }
                    heap.swapAt(i, m); i = m
                }
            }
            func pop() -> Int {
                let top = heap[0]
                heap[0] = heap[heap.count - 1]; heap.removeLast()
                if !heap.isEmpty { siftDown(0) }
                return top
            }
            func push(_ node: Int) {
                heap.append(node)
                var i = heap.count - 1
                while i > 0 && less(heap[i], heap[(i - 1) / 2]) { heap.swapAt(i, (i - 1) / 2); i = (i - 1) / 2 }
            }
            for i in stride(from: heap.count / 2 - 1, through: 0, by: -1) { siftDown(i) }
            while heap.count > 1 {
                let a = pop(), b = pop()
                let node = weight.count
                weight.append(weight[a] + weight[b])
                parent[a] = node; parent[b] = node
                push(node)
            }
            for (k, symbol) in symbols.enumerated() {
                var depth = 0, n = k
                while parent[n] >= 0 { n = parent[n]; depth += 1 }
                lengths[symbol] = depth
            }
            return lengths
        }

        /// Canonical codes (shorter first, then by symbol), bit-reversed for LSB-first output.
        static func canonicalCodes(_ lengths: [Int]) -> [UInt32] {
            let maxLength = lengths.max() ?? 0
            var countPerLength = [Int](repeating: 0, count: maxLength + 1)
            for l in lengths where l > 0 { countPerLength[l] += 1 }
            var next = [UInt32](repeating: 0, count: maxLength + 2)
            var code: UInt32 = 0
            if maxLength > 0 {
                for bits in 1...maxLength {
                    code = (code + UInt32(countPerLength[bits - 1])) << 1
                    next[bits] = code
                }
            }
            var codes = [UInt32](repeating: 0, count: lengths.count)
            for (symbol, length) in lengths.enumerated() where length > 0 {
                let c = next[length]
                next[length] += 1
                var reversed: UInt32 = 0
                for bit in 0..<length where c & (1 << UInt32(bit)) != 0 { reversed |= 1 << UInt32(length - 1 - bit) }
                codes[symbol] = reversed
            }
            return codes
        }
    }
}

nonisolated extension Data {
    mutating func appendLE32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
