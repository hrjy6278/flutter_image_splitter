import Foundation

// =============================================================================
// CacheMeta — persisted alongside chunk files
// =============================================================================
//
// Stored as meta.json in each cache directory. Captures everything needed
// to:
//   1) Verify cache integrity (chunkHeights.count matches file count)
//   2) Send conditional GET on next request (etag, lastModified)
//   3) Render the chunks correctly without re-decoding (chunkHeights, imageWidth)
// =============================================================================

struct CacheMeta {
    let etag: String?
    let lastModified: String?
    let chunkHeights: [Int]
    let imageWidth: Int
}

enum MetaFile {
    static func write(meta: CacheMeta, to path: String) throws {
        var dict: [String: Any] = [
            "imageWidth": meta.imageWidth,
            "chunkHeights": meta.chunkHeights,
        ]
        if let etag = meta.etag { dict["etag"] = etag }
        if let lastModified = meta.lastModified { dict["lastModified"] = lastModified }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func read(from path: String) -> CacheMeta? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let heights = raw["chunkHeights"] as? [Int],
              let width = raw["imageWidth"] as? Int
        else {
            return nil
        }
        return CacheMeta(
            etag: raw["etag"] as? String,
            lastModified: raw["lastModified"] as? String,
            chunkHeights: heights,
            imageWidth: width,
        )
    }
}
