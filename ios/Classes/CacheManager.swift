import Foundation
import CommonCrypto

// =============================================================================
// CacheManager — atomic cache directory layout
// =============================================================================
//
// Each cache entry lives in its own directory:
//
//   <root>/<sha16>/
//     ├── chunk_0.jpg
//     ├── chunk_1.jpg
//     └── meta.json
//
// Writes happen in a sibling temp directory and are renamed into place once
// the entire chunk set is committed. Readers always see complete sets — no
// .complete sentinel needed because the directory itself is the commit unit.
//
// Cache-key collision note: SHA-256(URL) truncated to 16 hex = 64 bits.
// Birthday collision is ~2^32, fine for a per-app cache. Cache invalidation
// is handled via ETag/Last-Modified, not the key itself.
// =============================================================================

final class CacheManager {

    let rootDirectory: String

    init(rootDirectory: String) {
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(
            atPath: rootDirectory,
            withIntermediateDirectories: true
        )
    }

    func key(for source: String) -> String {
        return String(sha256(source).prefix(16))
    }

    func directory(for key: String) -> String {
        return (rootDirectory as NSString).appendingPathComponent(key)
    }

    /// Allocates a fresh temp directory for in-progress writes. The caller
    /// MUST commit it via `commit(_:key:)` or discard it via `discard(_:)`.
    func newTempDirectory(for key: String) throws -> String {
        let temp = (rootDirectory as NSString)
            .appendingPathComponent(".tmp_\(key)_\(Int(Date().timeIntervalSince1970 * 1000))")
        let fm = FileManager.default
        if fm.fileExists(atPath: temp) {
            try? fm.removeItem(atPath: temp)
        }
        try fm.createDirectory(atPath: temp, withIntermediateDirectories: true)
        return temp
    }

    /// Atomically moves [tempDir] into the canonical location for [key].
    /// On the same volume this is a single rename(2) syscall.
    func commit(tempDir: String, key: String) throws -> String {
        let finalDir = directory(for: key)
        let fm = FileManager.default
        if fm.fileExists(atPath: finalDir) {
            try fm.removeItem(atPath: finalDir)
        }
        try fm.moveItem(atPath: tempDir, toPath: finalDir)
        return finalDir
    }

    func discard(tempDir: String) {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    func read(key: String) -> CachedEntry? {
        let dir = directory(for: key)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let metaPath = (dir as NSString).appendingPathComponent("meta.json")
        guard let meta = MetaFile.read(from: metaPath) else { return nil }

        let chunkPaths: [String] = (0..<meta.chunkHeights.count).map {
            (dir as NSString).appendingPathComponent("chunk_\($0).jpg")
        }
        for path in chunkPaths {
            if !fm.fileExists(atPath: path) { return nil }
        }
        return CachedEntry(paths: chunkPaths, meta: meta)
    }

    @discardableResult
    func clearAll() throws -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDirectory) else { return 0 }
        var count: Int64 = 0
        let enumerator = fm.enumerator(atPath: rootDirectory)
        while let entry = enumerator?.nextObject() as? String {
            let full = (rootDirectory as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                count += 1
            }
        }
        try fm.removeItem(atPath: rootDirectory)
        try fm.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true)
        return count
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

struct CachedEntry {
    let paths: [String]
    let meta: CacheMeta
}
