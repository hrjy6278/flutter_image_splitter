import 'package:pigeon/pigeon.dart';

// =============================================================================
// Pigeon Interface Definition
// =============================================================================
//
// This file defines the Dart ↔ Native communication interface.
// Code generation command: dart run pigeon --input pigeons/messages.dart
//
// Generated files:
//   - lib/src/messages.g.dart        (Dart)
//   - ios/Classes/Messages.g.swift   (Swift)
//   - android/.../Messages.g.kt      (Kotlin)
// =============================================================================

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    swiftOut: 'ios/Classes/Messages.g.swift',
    kotlinOut:
        'android/src/main/kotlin/io/github/hrjy6278/image_splitter/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'io.github.hrjy6278.image_splitter'),
    swiftOptions: SwiftOptions(),
  ),
)

/// Parameters for a split request.
///
/// [source] supports the following forms:
/// - `http://...` or `https://...` — remote image download
/// - `file:///...` or absolute path — local file split directly (no download)
class SplitRequest {
  SplitRequest({
    required this.source,
    required this.maxChunkHeight,
    this.cachedEtag,
    this.cachedLastModified,
  });

  /// Image source (URL or local file path).
  final String source;

  /// Maximum height (in pixels) of each chunk.
  final int maxChunkHeight;

  /// Previously cached ETag, used for conditional GET. If the server
  /// responds 304 Not Modified, the cache is reused.
  final String? cachedEtag;

  /// Previously cached Last-Modified header, used for conditional GET.
  final String? cachedLastModified;
}

/// Result of a split operation.
class SplitResult {
  SplitResult({
    required this.paths,
    required this.fromCache,
    this.etag,
    this.lastModified,
    required this.chunkHeights,
    required this.imageWidth,
  });

  /// Ordered list of chunk file paths (chunk_0.jpg, chunk_1.jpg, ...).
  final List<String> paths;

  /// Whether the result came from cache (no network or decode work).
  final bool fromCache;

  /// ETag returned by the server, to be passed back on the next request.
  final String? etag;

  /// Last-Modified returned by the server.
  final String? lastModified;

  /// Actual height of each chunk in [paths]. SplitImageView uses this to
  /// compute precise placeholder sizes (no jank when scrolling).
  final List<int> chunkHeights;

  /// Width of the original image. Used by SplitImageView for aspect ratio.
  final int imageWidth;
}

/// Dart → Native call interface.
///
/// Splits large images into smaller chunks using platform-native bitmap decoders.
///
/// ## Why native splitting is needed
///
/// Flutter's Skia/Impeller rendering engine has a GPU texture size limit.
/// The exact value depends on the device — typically between 4096 and 16384
/// pixels. Images exceeding this limit are forcefully downscaled, causing
/// visible distortion. Use [getMaxTextureSize] to query the device's actual
/// limit at runtime instead of hardcoding a value.
///
/// ## Platform implementations
///
/// - **Android**: Uses `BitmapRegionDecoder` for region-based decoding
///   without loading the full image into memory.
/// - **iOS**: Uses `CGImageSource` + `CGImageSourceCreateImageAtIndex` with
///   region cropping. Memory profile matches Android (no full decode upfront).
@HostApi()
abstract class ImageSplitterApi {
  /// Splits an image into chunks of [SplitRequest.maxChunkHeight] or less.
  ///
  /// Error codes:
  /// - `INVALID_ARGS`: Empty source, non-positive maxChunkHeight, or malformed URL
  /// - `WIDTH_TOO_LARGE`: Image width exceeds maxChunkHeight (horizontal split unsupported)
  /// - `DOWNLOAD_ERROR`: Network error, 404, or timeout
  /// - `FILE_NOT_FOUND`: Local file path does not exist
  /// - `DECODE_ERROR`: Unsupported format or corrupt image
  /// - `SPLIT_ERROR`: Error during the split (disk full, IO failure, etc.)
  @async
  SplitResult splitImage(SplitRequest request);

  /// Deletes all cached split images. Returns the number of files deleted.
  @async
  int clearCache();

  /// Queries the device's maximum GPU texture size.
  ///
  /// - Android: GLES `GL_MAX_TEXTURE_SIZE`
  /// - iOS: Metal `MTLDevice.maxTextureSize2D`
  ///
  /// Returns a safe fallback (4096) if the query fails. Use this value as
  /// the default for [SplitRequest.maxChunkHeight] when the caller does not
  /// supply one.
  @async
  int getMaxTextureSize();
}
