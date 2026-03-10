import Foundation
import CommonCrypto

enum MTProtoInitParser {
    static func extractDC(from data: Data) -> (dc: Int?, isMedia: Bool?) {
        guard data.count >= 64 else {
            return (nil, nil)
        }

        let key = Data(data[8..<40])
        let iv = Data(data[40..<56])

        guard let keystream = aesCTRKeystream(length: 64, key: key, iv: iv) else {
            return (nil, nil)
        }

        let encryptedTail = Data(data[56..<64])
        let plainTail = xor(encryptedTail, keystream.subdata(in: 56..<64))

        guard plainTail.count >= 6 else {
            return (nil, nil)
        }

        let proto = littleEndianUInt32(plainTail[0], plainTail[1], plainTail[2], plainTail[3])
        let dcRaw = littleEndianInt16(plainTail[4], plainTail[5])

        let validProto = proto == 0xEFEFEFEF || proto == 0xEEEEEEEE || proto == 0xDDDDDDDD
        guard validProto else {
            return (nil, nil)
        }

        let dc = abs(Int(dcRaw))
        guard (1...1000).contains(dc) else {
            return (nil, nil)
        }

        return (dc, dcRaw < 0)
    }

    private static func aesCTRKeystream(length: Int, key: Data, iv: Data) -> Data? {
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }

        guard createStatus == kCCSuccess, let cryptor else {
            return nil
        }
        defer { CCCryptorRelease(cryptor) }

        let input = Data(repeating: 0, count: length)
        var output = Data(repeating: 0, count: length)
        var moved = 0

        let updateStatus = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                CCCryptorUpdate(
                    cryptor,
                    inputBytes.baseAddress,
                    input.count,
                    outputBytes.baseAddress,
                    output.count,
                    &moved
                )
            }
        }

        guard updateStatus == kCCSuccess else {
            return nil
        }

        output.removeSubrange(moved..<output.count)
        return output
    }

    private static func xor(_ lhs: Data, _ rhs: Data) -> Data {
        Data(zip(lhs, rhs).map { $0 ^ $1 })
    }

    private static func littleEndianUInt32(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> UInt32 {
        UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
    }

    private static func littleEndianInt16(_ b0: UInt8, _ b1: UInt8) -> Int16 {
        Int16(bitPattern: UInt16(b0) | (UInt16(b1) << 8))
    }
}
