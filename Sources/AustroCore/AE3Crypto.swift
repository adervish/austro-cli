#if canImport(CommonCrypto)
import Foundation
import CommonCrypto
import CryptoKit
import Compression

/// Decrypts AE300 Wizard `.ae3` files: AES-192-CBC (fixed IV, PKCS7) then GZip,
/// reproducing Wizard's `CryptedCompression` + `PasswordDeriveBytes` (PBKDF1).
/// The passphrase is supplied by the caller — never embedded in source.
public enum AE3Crypto {

    public enum CryptoError: Error, LocalizedError {
        case decryptFailed, notGzip, inflateFailed
        public var errorDescription: String? {
            switch self {
            case .decryptFailed: "AES decryption failed (wrong passphrase?)."
            case .notGzip: "Decrypted data is not a GZip stream."
            case .inflateFailed: "GZip decompression failed."
            }
        }
    }

    // Fixed IV and PBKDF1 salt from CryptedCompression.cs.
    private static let iv: [UInt8] = [16,17,18,19,20,21,22,23,24,25,10,11,12,13,14,15]
    private static let salt: [UInt8] = [16,17,18,19,20,21,22,23,24,25,10,11,12]
    private static let iterations = 100

    /// `.NET PasswordDeriveBytes(passphrase, salt).GetBytes(24)` — PBKDF1/SHA1 with
    /// the Microsoft extension (prefix of ASCII '0' bytes per 20-byte block).
    public static func deriveKey(passphrase: String, length: Int = 24) -> [UInt8] {
        func sha1(_ bytes: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: Data(bytes))) }
        var base = sha1(Array(passphrase.utf8) + salt)          // SHA1(pw || salt)
        for _ in 1..<(iterations - 1) { base = sha1(base) }     // + (iterations-2) more
        var out: [UInt8] = []
        var prefix = 0
        while out.count < length {
            // Blocks after the first prepend the ASCII decimal counter ("1", "2", …).
            let block: [UInt8] = prefix == 0 ? sha1(base) : sha1(Array(String(prefix).utf8) + base)
            out.append(contentsOf: block)
            prefix += 1
        }
        return Array(out.prefix(length))
    }

    /// Full `.ae3` → decrypted XML bytes.
    public static func decryptAE3(_ data: Data, passphrase: String) throws -> Data {
        let key = deriveKey(passphrase: passphrase)
        let plain = try aesCBCDecrypt(Array(data), key: key, iv: iv)
        return try gunzip(plain)
    }

    /// XML bytes → `.ae3` (GZip then AES-192-CBC), the inverse of `decryptAE3`.
    /// Produces a file Wizard and our own decoder can both read.
    public static func encryptAE3(xml: Data, passphrase: String) throws -> Data {
        let gz = gzip(Array(xml))
        let key = deriveKey(passphrase: passphrase)
        return Data(try aesCBCEncrypt(Array(gz), key: key, iv: iv))
    }

    private static func aesCBCEncrypt(_ plain: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, plain, plain.count, &out, out.count, &moved
        )
        guard status == kCCSuccess else { throw CryptoError.decryptFailed }
        return Array(out.prefix(moved))
    }

    /// Standard gzip wrapper (10-byte header, FLG=0) around raw DEFLATE from Compression.
    private static func gzip(_ data: [UInt8]) -> Data {
        let cap = data.count + 64 * 1024 + 64
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = data.withUnsafeBufferPointer {
            compression_encode_buffer(dst, cap, $0.baseAddress!, $0.count, nil, COMPRESSION_ZLIB)
        }
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])  // gzip header
        out.append(dst, count: n)
        var crc = crc32(data).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    private static func aesCBCDecrypt(_ cipher: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, cipher, cipher.count, &out, out.count, &moved
        )
        guard status == kCCSuccess else { throw CryptoError.decryptFailed }
        return Array(out.prefix(moved))
    }

    /// Inflate a GZip stream (strip 10-byte header + 8-byte trailer, raw DEFLATE via Compression).
    private static func gunzip(_ data: [UInt8]) throws -> Data {
        guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B else { throw CryptoError.notGzip }
        let isize = Int(data[data.count - 4]) | Int(data[data.count - 3]) << 8
            | Int(data[data.count - 2]) << 16 | Int(data[data.count - 1]) << 24
        let deflate = Array(data[10..<(data.count - 8)])
        let capacity = isize > 0 ? isize : deflate.count * 12 + 65536
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let n = deflate.withUnsafeBufferPointer { src in
            compression_decode_buffer(dst, capacity, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
        guard n > 0 else { throw CryptoError.inflateFailed }
        return Data(bytes: dst, count: n)
    }
}
#endif
