package io.github.hrjy6278.image_splitter

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

// =============================================================================
// CacheMeta — persisted alongside chunk files
// =============================================================================
//
// Stored as meta.json in each cache directory. Captures everything needed
// to:
//   1) Verify cache integrity (chunkHeights.size matches file count)
//   2) Send conditional GET on next request (etag, lastModified)
//   3) Render the chunks correctly without re-decoding (chunkHeights, imageWidth)
//
// Plain JSON (no Gson dependency) — minimal surface, easy to read in tests.
// =============================================================================

internal data class CacheMeta(
    val etag: String?,
    val lastModified: String?,
    val chunkHeights: List<Int>,
    val imageWidth: Int,
)

internal object MetaFile {
    fun write(file: File, meta: CacheMeta) {
        val json = JSONObject().apply {
            put("etag", meta.etag ?: JSONObject.NULL)
            put("lastModified", meta.lastModified ?: JSONObject.NULL)
            put("imageWidth", meta.imageWidth)
            put("chunkHeights", JSONArray(meta.chunkHeights))
        }
        file.writeText(json.toString())
    }

    fun read(file: File): CacheMeta? {
        if (!file.isFile) return null
        return try {
            val json = JSONObject(file.readText())
            val heightsArr = json.getJSONArray("chunkHeights")
            val heights = (0 until heightsArr.length()).map { heightsArr.getInt(it) }
            CacheMeta(
                etag = json.optString("etag", "").takeIf { it.isNotEmpty() && !json.isNull("etag") },
                lastModified = json.optString("lastModified", "")
                    .takeIf { it.isNotEmpty() && !json.isNull("lastModified") },
                chunkHeights = heights,
                imageWidth = json.getInt("imageWidth"),
            )
        } catch (_: Exception) {
            null
        }
    }
}
