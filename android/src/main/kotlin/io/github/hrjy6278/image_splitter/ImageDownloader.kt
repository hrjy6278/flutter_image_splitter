package io.github.hrjy6278.image_splitter

import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

// =============================================================================
// ImageDownloader
// =============================================================================
//
// Wraps OkHttp with explicit timeouts and conditional GET (ETag /
// Last-Modified) support. Streams the response body straight to a file —
// no in-memory byte-array duplicate of the image.
//
// Why OkHttp instead of HttpURLConnection:
//   - Connection pooling reduces handshake overhead for repeated downloads
//   - Built-in support for redirects, timeouts, gzip
//   - Sane defaults; HUC has a long history of edge cases
//
// Timeout values (15s connect, 30s read) chosen to balance:
//   - Mobile networks can be slow on first byte
//   - But hanging forever blocks the semaphore for other callers
// =============================================================================

internal class ImageDownloader {

    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .callTimeout(60, TimeUnit.SECONDS)
        .build()

    /**
     * Result of a download attempt.
     *
     * - [NotModified]: server returned 304; cache should be reused as-is.
     * - [Downloaded]: bytes were saved to [file]; [etag]/[lastModified]
     *   should be persisted in cache metadata.
     */
    sealed class Result {
        object NotModified : Result()
        data class Downloaded(
            val file: File,
            val etag: String?,
            val lastModified: String?,
        ) : Result()
    }

    /**
     * Streams [url] into a temp file inside [destDir]. If [cachedEtag] or
     * [cachedLastModified] is provided, sends a conditional GET — a 304
     * response yields [Result.NotModified] without downloading any bytes.
     *
     * @throws IOException on network failure or non-2xx response.
     */
    fun download(
        url: String,
        destDir: File,
        cachedEtag: String?,
        cachedLastModified: String?,
    ): Result {
        val requestBuilder = Request.Builder().url(url)
        if (cachedEtag != null) requestBuilder.header("If-None-Match", cachedEtag)
        if (cachedLastModified != null) {
            requestBuilder.header("If-Modified-Since", cachedLastModified)
        }

        client.newCall(requestBuilder.build()).execute().use { response ->
            if (response.code == 304) return Result.NotModified
            if (!response.isSuccessful) {
                throw IOException("HTTP ${response.code}: ${response.message}")
            }
            val body = response.body ?: throw IOException("Empty response body")
            val tempFile = File(destDir, "download.bin")
            body.byteStream().use { input ->
                tempFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            return Result.Downloaded(
                file = tempFile,
                etag = response.header("ETag"),
                lastModified = response.header("Last-Modified"),
            )
        }
    }
}
