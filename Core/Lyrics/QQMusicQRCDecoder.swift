import Foundation
import zlib

// Ported for lyric decoding from apoint123/qrc-decoder (MIT License).
// Copyright (c) 2025 apoint123. See LICENSES/qrc-decoder-MIT.txt.
// QQ's block cipher resembles DES but differs in its key byte order and key schedule.
enum QQMusicQRCDecoder {
    static func decode(_ hex: String) -> String? {
        guard hex.count <= 2_000_000, hex.count.isMultiple(of: 16) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        let characters = Array(hex.utf8)
        for i in stride(from: 0, to: characters.count, by: 2) {
            guard let high = digit(characters[i]), let low = digit(characters[i + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        let schedules = [
            schedule(Array("!@#)(NHL".utf8), decrypt: true),
            schedule(Array("123ZXC!@".utf8), decrypt: false),
            schedule(Array("!@#)(*$%".utf8), decrypt: true)
        ]
        var plain: [UInt8] = []
        plain.reserveCapacity(bytes.count)
        for i in stride(from: 0, to: bytes.count, by: 8) {
            var block = Array(bytes[i..<(i + 8)])
            for keys in schedules { block = crypt(block, keys: keys) }
            plain.append(contentsOf: block)
        }

        // QRC contains zlib-compressed XML, padded to an eight-byte boundary.
        var outputSize = max(4096, plain.count * 4)
        while outputSize <= 2_000_000 {
            var output = [UInt8](repeating: 0, count: outputSize)
            var length = uLongf(outputSize)
            let status = output.withUnsafeMutableBufferPointer { destination in
                plain.withUnsafeBufferPointer { source in
                    uncompress(destination.baseAddress, &length, source.baseAddress, uLong(source.count))
                }
            }
            if status == Z_OK {
                let result = Array(output.prefix(Int(length)))
                let withoutBOM = result.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(result.dropFirst(3)) : result
                return String(bytes: withoutBOM, encoding: .utf8)
            }
            guard status == Z_BUF_ERROR else { return nil }
            outputSize *= 2
        }
        return nil
    }

    private static func digit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func schedule(_ key: [UInt8], decrypt: Bool) -> [UInt64] {
        func keyBits(_ table: [Int]) -> UInt64 {
            table.reduce(0) { bits, position in
                let byte = (position >> 5) * 4 + 3 - ((position & 31) >> 3)
                let bit = (key[byte] >> (7 - (position & 7))) & 1
                return (bits << 1) | UInt64(bit)
            }
        }
        var c = keyBits(keyPermC) << 4
        var d = keyBits(keyPermD) << 4
        var result = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            let shift = keyShifts[i]
            c = ((c << shift) | (c >> (28 - shift))) & 0xFFFF_FFF0
            d = ((d << shift) | (d >> (28 - shift))) & 0xFFFF_FFF0
            var subkey: UInt64 = 0
            for position in keyCompression {
                let bit = position < 28 ? (c >> (31 - position)) & 1 : (d >> (31 - (position - 27))) & 1
                subkey = (subkey << 1) | bit
            }
            result[decrypt ? 15 - i : i] = subkey
        }
        return result
    }

    private static func crypt(_ input: [UInt8], keys: [UInt64]) -> [UInt8] {
        let value = input.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let initial = permute(value, using: initialPermutation, width: 64)
        var left = UInt32(truncatingIfNeeded: initial >> 32)
        var right = UInt32(truncatingIfNeeded: initial)
        for i in 0..<15 {
            let next = left ^ round(right, key: keys[i])
            left = right
            right = next
        }
        left ^= round(right, key: keys[15])
        let final = permute((UInt64(left) << 32) | UInt64(right), using: finalPermutation, width: 64)
        return (0..<8).map { UInt8(truncatingIfNeeded: final >> (56 - $0 * 8)) }
    }

    private static func round(_ value: UInt32, key: UInt64) -> UInt32 {
        let expanded = permute(UInt64(value), using: expansion, width: 32) ^ key
        var substituted: UInt32 = 0
        for i in 0..<8 {
            let six = Int((expanded >> (42 - i * 6)) & 0x3F)
            let index = (six & 0x20) | ((six & 0x1F) >> 1) | ((six & 1) << 4)
            substituted = (substituted << 4) | UInt32(sBoxes[i][index])
        }
        return UInt32(truncatingIfNeeded: permute(UInt64(substituted), using: pBox, width: 32))
    }

    private static func permute(_ input: UInt64, using table: [Int], width: Int) -> UInt64 {
        table.reduce(UInt64(0)) { ($0 << 1) | ((input >> (width - $1)) & 1) }
    }

    // Tables below are from the MIT-licensed qrc-decoder implementation.
    private static let keyPermC: [Int] = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35]
    private static let keyPermD: [Int] = [62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3]
    private static let keyShifts: [Int] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    private static let keyCompression: [Int] = [13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31]
    private static let expansion: [Int] = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1]
    private static let pBox: [Int] = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25]
    private static let sBoxes: [[Int]] = [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ]
    private static let initialPermutation: [Int] = [34, 42, 50, 58, 2, 10, 18, 26, 36, 44, 52, 60, 4, 12, 20, 28, 38, 46, 54, 62, 6, 14, 22, 30, 40, 48, 56, 64, 8, 16, 24, 32, 33, 41, 49, 57, 1, 9, 17, 25, 35, 43, 51, 59, 3, 11, 19, 27, 37, 45, 53, 61, 5, 13, 21, 29, 39, 47, 55, 63, 7, 15, 23, 31]
    private static let finalPermutation: [Int] = [37, 5, 45, 13, 53, 21, 61, 29, 38, 6, 46, 14, 54, 22, 62, 30, 39, 7, 47, 15, 55, 23, 63, 31, 40, 8, 48, 16, 56, 24, 64, 32, 33, 1, 41, 9, 49, 17, 57, 25, 34, 2, 42, 10, 50, 18, 58, 26, 35, 3, 43, 11, 51, 19, 59, 27, 36, 4, 44, 12, 52, 20, 60, 28]

}
