# flutter_image_splitter

A Flutter plugin that splits tall images into memory-efficient chunks using platform-native bitmap decoders.

## Problem

Flutter's GPU rendering engine (Skia/Impeller) has a maximum texture height limit. The exact value depends on the device, typically between **4096 and 16384 pixels**. Images taller than this limit are forcefully downscaled, causing visible distortion — especially noticeable with promotional banners, infographics, and long screenshots.

**No Dart-side workaround exists** (not `BoxFit`, `cacheHeight`, or any image package). The limitation is at the GPU texture level.

## Solution

This plugin decodes and splits images **natively** (bypassing Flutter's texture limit), saves each chunk as a JPEG file, and exposes a companion widget that renders the chunks as if they were a single image.

| Platform | Decoder | Memory profile |
|----------|---------|----------------|
| Android | `BitmapRegionDecoder` | Only the current chunk in memory |
| iOS | `CGImageSource` + region crop | Memory-mapped source, per-chunk allocation |

## Installation

```yaml
dependencies:
  flutter_image_splitter: ^0.2.0
```

## Quick start

```dart
import 'package:flutter_image_splitter/flutter_image_splitter.dart';

final splitter = ImageSplitter();

// Split an image. maxChunkHeight defaults to the device's max GPU texture size.
final outcome = await splitter.split('https://example.com/tall-banner.jpg');

// Render with the companion widget (recommended).
SplitImageView(outcome: outcome)
```

When you no longer need the splitter, release per-instance state:

```dart
@override
void dispose() {
  splitter.dispose();
  super.dispose();
}
```

## Sources

`split()` accepts:

- `https://...` / `http://...` — remote image (downloaded and cached)
- `file:///...` — local file URI
- Absolute filesystem path (`/path/to/image.jpg`)

## Rendering

`SplitImageView` is a companion widget that renders a `SplitOutcome` with the per-chunk display heights computed up-front. This eliminates the layout-shift jank you'd see if you wired the chunks into a `ListView` directly.

```dart
// Standalone, scrollable page body:
SplitImageView.scrollable(outcome: outcome)

// Nested inside an existing scroller (e.g., a SliverList sibling):
SplitImageView(outcome: outcome)
```

You can also render manually if you need full control:

```dart
Column(
  children: [
    for (int i = 0; i < outcome.paths.length; i++)
      SizedBox(
        width: width,
        height: outcome.chunkHeights[i] * (width / outcome.imageWidth),
        child: Image.file(File(outcome.paths[i]), fit: BoxFit.fill),
      ),
  ],
)
```

## Caching

The plugin keeps a per-source cache in the app's temporary directory:

- **Cache key:** SHA-256 hash of the source URL plus `maxChunkHeight` (different chunk sizes don't collide).
- **Atomic commits:** writes happen in a sibling temp directory and are renamed into place. Crashes mid-split never leave partial chunk sets.
- **ETag / Last-Modified:** when the server provides them, repeated requests send `If-None-Match` / `If-Modified-Since`. A `304` response reuses the cache without re-decoding.
- **Manual invalidation:** call `splitter.clearCache()` to wipe everything.

```dart
final deletedCount = await splitter.clearCache();
```

## Concurrency

- Up to **2 concurrent splits** across the plugin (configurable in a future release). This caps memory peaks while still allowing independent images to download in parallel.
- **In-flight deduplication:** if two callers ask for the same source at the same time, only one operation runs and the result is shared.

## Custom chunk height

By default the plugin queries the device's actual GPU texture limit. You can override this:

```dart
final outcome = await splitter.split(
  imageUrl,
  maxChunkHeight: 4096,
);
```

Smaller chunks reduce per-frame memory at the cost of more files.

## Error handling

```dart
try {
  final outcome = await splitter.split(imageUrl);
} on PlatformException catch (e) {
  print('Error: ${e.code} - ${e.message}');
}
```

| Error code | Cause | Recovery |
|-----------|-------|----------|
| `INVALID_ARGS` | Empty source, non-positive height, malformed URL | Check input values |
| `WIDTH_TOO_LARGE` | Image width exceeds `maxChunkHeight` (horizontal split unsupported) | Use a larger `maxChunkHeight` or wait for v0.3 |
| `DOWNLOAD_ERROR` | Network error, 404, timeout | Retry or check URL |
| `FILE_NOT_FOUND` | Local source path does not exist | Check the path |
| `DECODE_ERROR` | Unsupported format, corrupt image | Verify format |
| `SPLIT_ERROR` | Disk full, IO failure, internal error | Free up space, retry |

## Supported formats

Any format supported by the platform's native image decoder:

- **JPEG**, **PNG**, **WebP**, **GIF** (first frame), **BMP**, **HEIF/HEIC** (iOS)

EXIF orientation is normalised across both the no-split and split paths, so iPhone photos taken in portrait render upright regardless of which path is taken.

## Limitations

- **Vertical split only.** Images wider than `maxChunkHeight` throw `WIDTH_TOO_LARGE`. Horizontal split is planned for v0.3+.
- **JPEG output.** Chunks are always saved as JPEG (92% quality). Transparency is not preserved.
- **No streaming.** The full image is downloaded before splitting begins.

## Platform requirements

- **Android:** minSdk 24+
- **iOS:** 13.0+
- **Flutter:** 3.3.0+

## License

See [LICENSE](LICENSE).
