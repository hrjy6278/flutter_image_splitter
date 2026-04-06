## 0.2.1

- Shortened `pubspec.yaml` description to fit pub.dev's 180-character limit (was 189 chars). Restores the 10 pub points lost on the "Provide a valid pubspec.yaml" check. No code changes.

## 0.2.0

### Breaking changes

- `ImageSplitter.split()` now returns `SplitOutcome` instead of `List<String>`. The new type carries the chunk paths plus per-chunk heights, image width, and ETag metadata for cache revalidation.
- `maxChunkHeight` is now optional. When omitted, the device's actual GPU texture limit is queried via Metal (iOS) or `GL_MAX_TEXTURE_SIZE` (Android) instead of being hardcoded to 8192.
- Pigeon-generated platform interfaces now use `SplitRequest` / `SplitResult` value types. Direct callers of the generated API need to migrate.

### New features

- **`SplitImageView` companion widget.** Renders a `SplitOutcome` with precise per-chunk placeholder heights so the layout never jumps as chunks decode. Two variants: `SplitImageView` (non-scrollable, for nesting) and `SplitImageView.scrollable` (standalone).
- **Local file support.** `split()` now accepts `file://` URIs and absolute filesystem paths in addition to HTTP(S) URLs. Local sources skip the download step entirely.
- **ETag / Last-Modified caching.** Repeated requests for the same URL send conditional GET. A 304 response reuses the cached chunks without re-decoding.
- **In-flight deduplication.** Concurrent `split()` calls for the same source share a single download + decode operation instead of duplicating work.
- **EXIF orientation normalisation.** Images with EXIF rotation tags now render in their visible orientation regardless of whether the split path was taken. iPhone photos no longer come out sideways.
- **Atomic cache commits.** Writes happen in a temp directory and are renamed into place. Crashes mid-split no longer leave partial chunk sets in the cache.
- **Concurrency cap.** Up to 2 concurrent splits across the plugin. Prevents memory peaks from N parallel large images.
- **Width validation.** Images wider than `maxChunkHeight` now throw `WIDTH_TOO_LARGE` instead of silently producing distorted output. Horizontal split is planned for a future release.

### Bug fixes

- iOS: `cropping(to:)` no longer silently skips chunks on failure. Failures now throw `SPLIT_ERROR`.
- iOS: `[weak self]` guard in `splitImage` no longer causes Futures to hang when the plugin is deallocated mid-flight.
- iOS: Fully replaced `UIImage(data:)` with `CGImageSource`-based loading. Memory usage now matches Android — region-based decoding instead of full-image decode.
- Android: HTTP downloads now have explicit timeouts (15s connect, 30s read). Hung servers no longer block subsequent requests.
- Android: Replaced raw `URL.readBytes()` with OkHttp streaming to a file. Eliminates the duplicate-byte-array memory cost.
- Cache key now incorporates `maxChunkHeight`. Different chunk heights for the same source no longer collide.
- SHA-256 truncation comment corrected: birthday-collision probability is `2^32`, not `2^64`.

### Internal

- `dispose()` added to `ImageSplitter` for releasing per-instance state (in-memory ETag cache, texture-size cache).
- Comprehensive Dart unit tests via a hand-written `FakeImageSplitterApi`.
- Widget tests for `SplitImageView` covering placeholder sizing, scroll behaviour, and the error builder path.
- Integration test scaffold for the example app.
- GitHub Actions CI: format check, analyze, test, Pigeon-up-to-date check, dry-run publish, Android + iOS example builds.
- GitHub Actions release workflow: tag-driven publish to pub.dev with version-tag verification.

## 0.1.0

- Initial release
- Native image splitting for Android (BitmapRegionDecoder) and iOS (CGImage.cropping)
- SHA-256 based caching
- Cache management API (`clearCache`)
- Type-safe platform communication via Pigeon
