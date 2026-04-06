package io.github.hrjy6278.image_splitter

import java.io.File
import java.security.MessageDigest

// =============================================================================
// CacheManager
// =============================================================================
//
// Atomic cache directory layout:
//
//   <cacheRoot>/image_splits/<sha16>/
//     ├── chunk_0.jpg
//     ├── chunk_1.jpg
//     ├── ...
//     └── meta.json    (etag, last-modified, chunk heights, image width)
//
// Atomicity: writes happen in a sibling temp directory and are renamed into
// place once the entire chunk set is committed. A reader that sees the
// final directory is guaranteed to see a complete set — no .complete sentinel
// needed because the directory itself is the commit unit.
//
// Cache-key collision note: SHA-256(URL) truncated to 16 hex chars = 64 bits.
// Birthday-collision probability is ~2^32, which is fine for a per-app cache
// but not for adversarial input. Cache invalidation is handled by ETag /
// Last-Modified, not the key itself.
// =============================================================================

internal class CacheManager(private val rootDir: File) {

    init {
        rootDir.mkdirs()
    }

    fun keyFor(source: String): String = sha256(source).take(16)

    fun directoryFor(key: String): File = File(rootDir, key)

    /**
     * Allocates a fresh temp directory for in-progress writes. The caller
     * MUST commit it via [commit] (renames into place) or discard it via
     * [discard] (removes it).
     */
    fun newTempDirectory(key: String): File {
        val temp = File(rootDir, ".tmp_${key}_${System.nanoTime()}")
        if (temp.exists()) temp.deleteRecursively()
        temp.mkdirs()
        return temp
    }

    /**
     * Atomically promotes [tempDir] to the canonical location for [key].
     * If a previous cache exists, it is replaced. Returns the final directory.
     */
    fun commit(tempDir: File, key: String): File {
        val finalDir = directoryFor(key)
        if (finalDir.exists()) finalDir.deleteRecursively()
        // File.renameTo on the same filesystem is atomic on POSIX.
        if (!tempDir.renameTo(finalDir)) {
            // Fallback: copy + delete (rare; happens across filesystems).
            tempDir.copyRecursively(finalDir, overwrite = true)
            tempDir.deleteRecursively()
        }
        return finalDir
    }

    fun discard(tempDir: File) {
        if (tempDir.exists()) tempDir.deleteRecursively()
    }

    fun read(key: String): CachedEntry? {
        val dir = directoryFor(key)
        if (!dir.isDirectory) return null
        val meta = MetaFile.read(File(dir, "meta.json")) ?: return null
        val chunkPaths = meta.chunkHeights.indices
            .map { File(dir, "chunk_$it.jpg") }
        if (chunkPaths.any { !it.isFile }) return null
        return CachedEntry(
            paths = chunkPaths.map { it.absolutePath },
            meta = meta
        )
    }

    fun clearAll(): Long {
        if (!rootDir.exists()) return 0
        var count = 0L
        rootDir.walkBottomUp().forEach { f ->
            if (f.isFile) count++
            f.delete()
        }
        rootDir.mkdirs()
        return count
    }

    private fun sha256(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(input.toByteArray())
            .joinToString("") { "%02x".format(it) }
    }
}

internal data class CachedEntry(
    val paths: List<String>,
    val meta: CacheMeta,
)
