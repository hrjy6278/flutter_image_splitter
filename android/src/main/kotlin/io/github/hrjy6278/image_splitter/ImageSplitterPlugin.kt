package io.github.hrjy6278.image_splitter

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore

// =============================================================================
// ImageSplitterPlugin — Android entrypoint
// =============================================================================
//
// Request lifecycle (CRITICAL ORDERING — see review issue OV-4):
//
//   splitImage(request)
//       │
//       ▼
//   1. In-flight dedup check
//       │   (same source already being processed? share that future)
//       ▼
//   2. Cache read
//       │   (meta.json + chunk_*.jpg present? if no ETag, return immediately)
//       │   (with ETag/Last-Modified, fall through to conditional GET)
//       ▼
//   3. Semaphore acquire (max 2 concurrent)
//       │   (limits memory peak; serialized requests for same URL already
//       │    handled by dedup, so unrelated work is the only thing waiting)
//       ▼
//   4. Download (with conditional GET) → temp file in temp dir
//       │
//       ▼
//   5. Split into temp dir
//       │
//       ▼
//   6. Atomic rename: temp dir → final cache dir
//       │
//       ▼
//   7. Release semaphore, complete dedup future, return result
//
// Threading:
//   - Pigeon callbacks may be invoked on any thread; we hop to a fixed
//     thread pool (size 4) so the binary messenger thread is not blocked.
//   - Semaphore(2) is the actual concurrency limit — pool just exists to
//     avoid blocking the messenger.
// =============================================================================

class ImageSplitterPlugin : FlutterPlugin, ImageSplitterApi {

    private lateinit var context: Context
    private lateinit var cacheManager: CacheManager
    private val downloader = ImageDownloader()
    private val splitter = ImageSplitter()

    // Pool exists only to free the binary messenger thread; real concurrency
    // is bounded by [semaphore], not by the pool size.
    private val executor = Executors.newFixedThreadPool(4)
    private val semaphore = Semaphore(2)

    // In-flight deduplication: maps source key → in-progress future.
    // Concurrent callers for the same key share one operation.
    private val inFlight = ConcurrentHashMap<String, CompletableFuture<SplitResult>>()

    // Cached texture-size probe result. Probing requires an EGL context, so
    // we do it lazily and cache forever (the value cannot change at runtime).
    @Volatile private var cachedMaxTextureSize: Int? = null

    // =========================================================================
    // FlutterPlugin
    // =========================================================================

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        cacheManager = CacheManager(File(context.cacheDir, "image_splits"))
        ImageSplitterApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ImageSplitterApi.setUp(binding.binaryMessenger, null)
    }

    // =========================================================================
    // ImageSplitterApi
    // =========================================================================

    override fun splitImage(request: SplitRequest, callback: (Result<SplitResult>) -> Unit) {
        val source = request.source
        val maxChunkHeight = request.maxChunkHeight.toInt()
        if (source.isBlank()) {
            callback(Result.failure(FlutterError("INVALID_ARGS", "source must not be empty", null)))
            return
        }
        if (maxChunkHeight <= 0) {
            callback(Result.failure(
                FlutterError("INVALID_ARGS", "maxChunkHeight must be positive", null)
            ))
            return
        }

        // Cache key includes maxChunkHeight because different chunk sizes
        // produce different output sets.
        val key = cacheManager.keyFor("$source|$maxChunkHeight")

        // computeIfAbsent guarantees only one operation runs per key. The
        // returned future is shared with all concurrent callers.
        val future = inFlight.computeIfAbsent(key) { _ ->
            val f = CompletableFuture<SplitResult>()
            executor.execute { runRequest(key, source, maxChunkHeight, request, f) }
            f
        }

        future.whenComplete { result, error ->
            if (error != null) {
                val cause = (error as? java.util.concurrent.CompletionException)?.cause ?: error
                callback(Result.failure(cause as? Throwable ?: RuntimeException(cause)))
            } else {
                callback(Result.success(result))
            }
        }
    }

    private fun runRequest(
        key: String,
        source: String,
        maxChunkHeight: Int,
        request: SplitRequest,
        future: CompletableFuture<SplitResult>,
    ) {
        // Compute the result WITHOUT touching the future. We must remove the
        // entry from inFlight BEFORE completing the future — otherwise the
        // whenComplete listener fires synchronously on the same thread, the
        // Dart caller resumes, fires another split() for the same key, and
        // (because we haven't reached the finally block yet) attaches to the
        // OLD already-completed future, getting the OLD result back.
        //
        // The fix is to keep the in-flight slot reserved until the result
        // (success or failure) is fully materialised, drop the slot, then
        // notify waiters. resolveWaiters-style.
        val resolved: Either = try {
            // Cache fast path (only valid when caller does NOT pass an ETag —
            // when an ETag is present, the caller wants revalidation).
            val cacheHit: SplitResult? = if (
                request.cachedEtag == null && request.cachedLastModified == null
            ) {
                cacheManager.read(key)?.toSplitResult(fromCache = true)
            } else {
                null
            }

            if (cacheHit != null) {
                Either.Success(cacheHit)
            } else {
                semaphore.acquire()
                try {
                    processSource(key, source, maxChunkHeight, request)
                } finally {
                    semaphore.release()
                }
            }
        } catch (t: Throwable) {
            Either.Failure(t)
        }

        // Drop the in-flight slot BEFORE notifying so any subsequent caller
        // for this key starts a fresh request.
        inFlight.remove(key, future)

        when (resolved) {
            is Either.Success -> future.complete(resolved.value)
            is Either.Failure -> future.completeExceptionally(resolved.error)
        }
    }

    private fun processSource(
        key: String,
        source: String,
        maxChunkHeight: Int,
        request: SplitRequest,
    ): Either {
        val tempDir = cacheManager.newTempDirectory(key)
        try {
            val inputFile: File
            val etag: String?
            val lastModified: String?

            if (isLocalSource(source)) {
                val localFile = resolveLocalFile(source)
                if (!localFile.isFile) {
                    cacheManager.discard(tempDir)
                    return Either.Failure(FlutterError(
                        "FILE_NOT_FOUND",
                        "Local file does not exist: ${localFile.absolutePath}",
                        null,
                    ))
                }
                inputFile = localFile
                etag = null
                lastModified = null
            } else {
                val downloadResult = try {
                    downloader.download(
                        url = source,
                        destDir = tempDir,
                        cachedEtag = request.cachedEtag,
                        cachedLastModified = request.cachedLastModified,
                    )
                } catch (e: Exception) {
                    cacheManager.discard(tempDir)
                    return Either.Failure(FlutterError(
                        "DOWNLOAD_ERROR",
                        "Failed to download image: ${e.message}",
                        null,
                    ))
                }

                when (downloadResult) {
                    is ImageDownloader.Result.NotModified -> {
                        cacheManager.discard(tempDir)
                        val entry = cacheManager.read(key)
                            ?: return Either.Failure(FlutterError(
                                "SPLIT_ERROR",
                                "Server returned 304 but cache is missing",
                                null,
                            ))
                        return Either.Success(entry.toSplitResult(fromCache = true))
                    }
                    is ImageDownloader.Result.Downloaded -> {
                        inputFile = downloadResult.file
                        etag = downloadResult.etag
                        lastModified = downloadResult.lastModified
                    }
                }
            }

            val output = splitter.split(inputFile, tempDir, maxChunkHeight)

            val meta = CacheMeta(
                etag = etag,
                lastModified = lastModified,
                chunkHeights = output.chunkHeights,
                imageWidth = output.imageWidth,
            )
            MetaFile.write(File(tempDir, "meta.json"), meta)

            // Remove the original download blob (chunks already written).
            if (!isLocalSource(source)) {
                inputFile.delete()
            }

            val finalDir = cacheManager.commit(tempDir, key)

            val finalPaths = output.chunkHeights.indices
                .map { File(finalDir, "chunk_$it.jpg").absolutePath }

            return Either.Success(SplitResult(
                paths = finalPaths,
                fromCache = false,
                etag = etag,
                lastModified = lastModified,
                chunkHeights = output.chunkHeights.map { it.toLong() },
                imageWidth = output.imageWidth.toLong(),
            ))
        } catch (t: Throwable) {
            cacheManager.discard(tempDir)
            return Either.Failure(
                if (t is FlutterError) t
                else FlutterError("SPLIT_ERROR", t.message ?: t.javaClass.simpleName, null)
            )
        }
    }

    /** Internal sum type for the split pipeline result. */
    private sealed class Either {
        data class Success(val value: SplitResult) : Either()
        data class Failure(val error: Throwable) : Either()
    }

    override fun clearCache(callback: (Result<Long>) -> Unit) {
        executor.execute {
            try {
                callback(Result.success(cacheManager.clearAll()))
            } catch (e: Exception) {
                callback(Result.failure(
                    FlutterError("CLEAR_CACHE_ERROR", e.message, null)
                ))
            }
        }
    }

    override fun getMaxTextureSize(callback: (Result<Long>) -> Unit) {
        executor.execute {
            try {
                val cached = cachedMaxTextureSize
                val value = cached ?: MaxTextureSizeProbe.query().also {
                    cachedMaxTextureSize = it
                }
                callback(Result.success(value.toLong()))
            } catch (_: Exception) {
                callback(Result.success(4096L))
            }
        }
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private fun isLocalSource(source: String): Boolean =
        source.startsWith("file://") || source.startsWith("/")

    private fun resolveLocalFile(source: String): File =
        if (source.startsWith("file://")) {
            File(source.removePrefix("file://"))
        } else {
            File(source)
        }
}

private fun CachedEntry.toSplitResult(fromCache: Boolean): SplitResult = SplitResult(
    paths = paths,
    fromCache = fromCache,
    etag = meta.etag,
    lastModified = meta.lastModified,
    chunkHeights = meta.chunkHeights.map { it.toLong() },
    imageWidth = meta.imageWidth.toLong(),
)
