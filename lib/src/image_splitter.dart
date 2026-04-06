import 'dart:io';

import 'package:flutter/services.dart';

import 'messages.g.dart';

// =============================================================================
// ImageSplitter — Dart-side facade
// =============================================================================
//
// Wraps the Pigeon-generated [ImageSplitterApi] with conveniences:
//
//   - Source detection (URL vs local file path) and validation
//   - Lazy device texture-size probing (cached for the instance lifetime)
//   - In-memory ETag map so subsequent requests for the same URL send a
//     conditional GET to the native side automatically
//   - dispose() to drop the ETag cache (cheap, but rebuilds in StatefulWidget
//     lifecycles can otherwise leak the map across hot restarts)
//
// The native side handles all the heavy work — caching, splitting, threading.
// This file is intentionally thin; nothing here should ever block the UI.
// =============================================================================

/// Outcome of a successful split.
///
/// Contains the chunk file paths plus the metadata needed to render them
/// without re-querying the native side (chunk heights, image width).
class SplitOutcome {
  SplitOutcome({
    required this.paths,
    required this.fromCache,
    required this.chunkHeights,
    required this.imageWidth,
    this.etag,
    this.lastModified,
  });

  /// Ordered list of chunk file paths (top → bottom).
  final List<String> paths;

  /// True if the result came from cache (no network or decode work).
  final bool fromCache;

  /// Per-chunk heights in pixels. `chunkHeights.length == paths.length`.
  ///
  /// Used by `SplitImageView` to compute precise placeholder sizes so the
  /// scroll position is stable while chunks are still loading.
  final List<int> chunkHeights;

  /// Width of the original image in pixels.
  final int imageWidth;

  /// ETag returned by the server, if any. Pass this to the next [split]
  /// call to enable conditional GET (304 → cache hit).
  final String? etag;

  /// Last-Modified header returned by the server.
  final String? lastModified;

  /// Total height summed across all chunks.
  int get totalHeight => chunkHeights.fold(0, (a, b) => a + b);

  /// Aspect ratio (width / height) of the original image.
  double get aspectRatio => imageWidth / totalHeight;
}

/// A native image splitter that bypasses Flutter's GPU texture size limit.
///
/// Splits tall images (e.g., promotional banners, infographics, long
/// screenshots) into JPEG chunks below the device's maximum texture height.
///
/// ## Quick start
///
/// ```dart
/// final splitter = ImageSplitter();
/// final outcome = await splitter.split('https://example.com/long.jpg');
///
/// // Render with the companion widget (recommended):
/// SplitImageView(outcome: outcome)
///
/// // Or render manually:
/// Column(
///   children: [
///     for (final path in outcome.paths)
///       Image.file(File(path), fit: BoxFit.fitWidth),
///   ],
/// )
/// ```
///
/// Always call [dispose] when the splitter is no longer needed (typically
/// in `State.dispose()`). For app-wide use, hold a single instance in a
/// service locator instead of recreating it on every widget rebuild.
///
/// ## Sources
///
/// [split] accepts:
///
/// - `https://...` / `http://...` — remote image (download + cache)
/// - `file:///...` — local file URI
/// - Absolute path (`/path/to/image.jpg`) — local file
///
/// ## Limitations
///
/// - **Vertical split only.** Images wider than the chunk height throw
///   `WIDTH_TOO_LARGE`. Horizontal split is planned for v0.3+.
/// - **JPEG output.** All chunks are saved as JPEG (92% quality).
///   Transparency is not preserved.
class ImageSplitter {
  /// Creates a new [ImageSplitter] instance.
  ImageSplitter() : _api = ImageSplitterApi();

  /// Test-only constructor that lets unit tests inject a mock API.
  ImageSplitter.withApi(ImageSplitterApi api) : _api = api;

  final ImageSplitterApi _api;

  /// Cached device texture size. Populated on first [split] / [getMaxTextureSize]
  /// call and reused thereafter (the value cannot change at runtime).
  int? _cachedMaxTextureSize;

  /// Per-source ETag/Last-Modified cache. Lets repeated [split] calls for
  /// the same URL skip re-downloading when the server responds 304.
  final Map<String, _ConditionalCache> _etagCache =
      <String, _ConditionalCache>{};

  bool _disposed = false;

  /// Splits an image into chunks of [maxChunkHeight] pixels or less.
  ///
  /// [source] is one of:
  /// - HTTP(S) URL — downloaded and cached locally
  /// - `file://` URI — read directly from disk (no download)
  /// - Absolute filesystem path — read directly from disk
  ///
  /// [maxChunkHeight] caps each chunk's height. If omitted, the device's
  /// maximum GPU texture size is queried and used (recommended — hardcoded
  /// values can silently distort on low-end devices with smaller limits).
  ///
  /// Throws [PlatformException] with one of these codes:
  /// - `INVALID_ARGS` — empty source, non-positive height, or malformed URL
  /// - `WIDTH_TOO_LARGE` — image width exceeds `maxChunkHeight`
  /// - `DOWNLOAD_ERROR` — network error, 404, timeout
  /// - `FILE_NOT_FOUND` — local source path does not exist
  /// - `DECODE_ERROR` — unsupported format or corrupt image
  /// - `SPLIT_ERROR` — disk full, IO failure, or other split-time error
  Future<SplitOutcome> split(String source, {int? maxChunkHeight}) async {
    _assertNotDisposed();
    if (source.trim().isEmpty) {
      throw PlatformException(
        code: 'INVALID_ARGS',
        message: 'source must not be empty',
      );
    }

    // Validate sources we recognise. Anything else falls through to the
    // native layer where it will fail with a clearer error.
    final isHttp =
        source.startsWith('http://') || source.startsWith('https://');
    final isFile = source.startsWith('file://') || source.startsWith('/');
    if (!isHttp && !isFile) {
      throw PlatformException(
        code: 'INVALID_ARGS',
        message:
            'source must be an http(s) URL, a file:// URI, or an absolute path. Got: $source',
      );
    }
    if (isFile) {
      final path =
          source.startsWith('file://')
              ? Uri.parse(source).toFilePath()
              : source;
      if (!File(path).existsSync()) {
        throw PlatformException(
          code: 'FILE_NOT_FOUND',
          message: 'Local file does not exist: $path',
        );
      }
    }

    final effectiveMax = maxChunkHeight ?? await getMaxTextureSize();
    if (effectiveMax <= 0) {
      throw PlatformException(
        code: 'INVALID_ARGS',
        message: 'maxChunkHeight must be positive',
      );
    }

    final cached = _etagCache[source];
    final request = SplitRequest(
      source: source,
      maxChunkHeight: effectiveMax,
      cachedEtag: cached?.etag,
      cachedLastModified: cached?.lastModified,
    );

    final result = await _api.splitImage(request);

    // Update the ETag cache for next time.
    if (result.etag != null || result.lastModified != null) {
      _etagCache[source] = _ConditionalCache(
        etag: result.etag,
        lastModified: result.lastModified,
      );
    }

    return SplitOutcome(
      paths: List<String>.from(result.paths),
      fromCache: result.fromCache,
      chunkHeights: result.chunkHeights.map((h) => h.toInt()).toList(),
      imageWidth: result.imageWidth.toInt(),
      etag: result.etag,
      lastModified: result.lastModified,
    );
  }

  /// Queries the device's maximum GPU texture size.
  ///
  /// The value is cached for the lifetime of this [ImageSplitter] instance.
  /// On query failure, returns the safe fallback `4096`.
  Future<int> getMaxTextureSize() async {
    _assertNotDisposed();
    final cached = _cachedMaxTextureSize;
    if (cached != null) return cached;
    final value = await _api.getMaxTextureSize();
    final intValue = value.toInt();
    _cachedMaxTextureSize = intValue;
    return intValue;
  }

  /// Deletes all cached split images. Returns the number of files deleted.
  ///
  /// Also clears the in-memory ETag cache so the next [split] call performs
  /// a fresh download.
  Future<int> clearCache() async {
    _assertNotDisposed();
    _etagCache.clear();
    final count = await _api.clearCache();
    return count.toInt();
  }

  /// Releases per-instance resources (the in-memory ETag cache).
  ///
  /// Native cache files are NOT touched — call [clearCache] for that.
  /// After [dispose], any further calls throw [StateError].
  void dispose() {
    _disposed = true;
    _etagCache.clear();
    _cachedMaxTextureSize = null;
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('ImageSplitter has been disposed');
    }
  }
}

class _ConditionalCache {
  _ConditionalCache({this.etag, this.lastModified});

  final String? etag;
  final String? lastModified;
}
