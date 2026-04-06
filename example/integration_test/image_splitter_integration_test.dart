import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_splitter/image_splitter.dart';
import 'package:integration_test/integration_test.dart';

// =============================================================================
// Integration tests — exercise the real native code path with real images
// =============================================================================
//
// These run on a real device or simulator. Bundled test assets live in
// example/assets/test_images/ and are loaded via rootBundle, written to
// the device temp directory, and passed to ImageSplitter as local files.
//
// Coverage matrix:
//
//   ┌─────────────────────────┬──────────────────────────────────────────┐
//   │ Asset                   │ Validates                                │
//   ├─────────────────────────┼──────────────────────────────────────────┤
//   │ tall_1000x4096.jpg      │ Boundary: height == max → 1 chunk        │
//   │ tall_1000x4097.jpg      │ Boundary+1: height == max+1 → 2 chunks   │
//   │ tall_1000x5000.jpg      │ Single split: 2 chunks                   │
//   │ tall_1000x12000.jpg     │ Multi-chunk: 3 chunks @ max=4096         │
//   │ tall_1000x12000.png     │ PNG → JPEG re-encode (extension          │
//   │                         │ consistency, EXIF normalisation path)    │
//   │ tall_1000x5000.png      │ Small PNG → single-chunk re-encode       │
//   │ wide_12000x1000.jpg     │ WIDTH_TOO_LARGE error                    │
//   └─────────────────────────┴──────────────────────────────────────────┘
//
// Each test uses a freshly-created ImageSplitter and clears the cache in
// teardown so tests don't pollute each other. The 4096 chunk height is used
// throughout because it's the safest fallback that exercises real splitting.
// =============================================================================

const _testMaxHeight = 4096;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late ImageSplitter splitter;
  final List<String> tempPaths = <String>[];

  setUp(() {
    splitter = ImageSplitter();
  });

  tearDown(() async {
    await splitter.clearCache();
    splitter.dispose();
    for (final path in tempPaths) {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    }
    tempPaths.clear();
  });

  /// Loads a bundled asset, writes it to a temp file, and registers the
  /// path for cleanup. Returns the temp file path the splitter can read.
  Future<String> stage(String assetName) async {
    final bytes = await rootBundle.load('assets/test_images/$assetName');
    final temp = File(
      '${Directory.systemTemp.path}/integration_${DateTime.now().microsecondsSinceEpoch}_$assetName',
    );
    temp.writeAsBytesSync(bytes.buffer.asUint8List());
    tempPaths.add(temp.path);
    return temp.path;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Plugin sanity
  // ─────────────────────────────────────────────────────────────────────────

  group('plugin sanity', () {
    testWidgets('getMaxTextureSize returns at least 4096', (tester) async {
      final size = await splitter.getMaxTextureSize();
      expect(size, greaterThanOrEqualTo(4096),
          reason: 'No real device should report less than 4096');
    });

    testWidgets('clearCache succeeds and returns a non-negative count',
        (tester) async {
      final count = await splitter.clearCache();
      expect(count, greaterThanOrEqualTo(0));
    });

    testWidgets('split rejects empty source', (tester) async {
      await expectLater(
        splitter.split(''),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'INVALID_ARGS')),
      );
    });

    testWidgets('split rejects missing local file', (tester) async {
      final missing = '${Directory.systemTemp.path}/never_exists_xyz.jpg';
      await expectLater(
        splitter.split(missing),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'FILE_NOT_FOUND')),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Boundary conditions: height exactly at / just above max
  // ─────────────────────────────────────────────────────────────────────────

  group('boundary conditions', () {
    testWidgets('1000x4096 (== max) produces exactly 1 chunk', (tester) async {
      final path = await stage('tall_1000x4096.jpg');
      final outcome = await splitter.split(path, maxChunkHeight: _testMaxHeight);

      expect(outcome.paths.length, 1,
          reason: 'height == max should hit single-chunk short-circuit');
      expect(outcome.imageWidth, 1000);
      expect(outcome.chunkHeights, [4096]);
      expect(outcome.totalHeight, 4096);
      expect(File(outcome.paths[0]).existsSync(), isTrue);
    });

    testWidgets('1000x4097 (== max+1) produces exactly 2 chunks',
        (tester) async {
      final path = await stage('tall_1000x4097.jpg');
      final outcome = await splitter.split(path, maxChunkHeight: _testMaxHeight);

      expect(outcome.paths.length, 2,
          reason: 'height == max+1 should split into 2 chunks');
      expect(outcome.imageWidth, 1000);
      expect(outcome.chunkHeights, [4096, 1],
          reason: 'last chunk should be exactly 1px tall');
      expect(outcome.totalHeight, 4097);
      for (final p in outcome.paths) {
        expect(File(p).existsSync(), isTrue);
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Multi-chunk splitting
  // ─────────────────────────────────────────────────────────────────────────

  group('multi-chunk splitting', () {
    testWidgets('1000x5000 splits into 2 chunks (4096 + 904)', (tester) async {
      final path = await stage('tall_1000x5000.jpg');
      final outcome = await splitter.split(path, maxChunkHeight: _testMaxHeight);

      expect(outcome.paths.length, 2);
      expect(outcome.imageWidth, 1000);
      expect(outcome.chunkHeights, [4096, 904]);
      expect(outcome.totalHeight, 5000);
    });

    testWidgets('1000x12000 splits into 3 chunks (4096 + 4096 + 3808)',
        (tester) async {
      final path = await stage('tall_1000x12000.jpg');
      final outcome = await splitter.split(path, maxChunkHeight: _testMaxHeight);

      expect(outcome.paths.length, 3);
      expect(outcome.imageWidth, 1000);
      expect(outcome.chunkHeights, [4096, 4096, 3808]);
      expect(outcome.totalHeight, 12000);
      // All chunk files should exist on disk and be non-empty.
      for (final p in outcome.paths) {
        final f = File(p);
        expect(f.existsSync(), isTrue);
        expect(f.lengthSync(), greaterThan(0));
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // PNG re-encoding (extension consistency, ensures decoder handles non-JPEG)
  // ─────────────────────────────────────────────────────────────────────────

  group('PNG handling', () {
    testWidgets('PNG short-circuit path still produces a JPEG chunk',
        (tester) async {
      final path = await stage('tall_1000x5000.png');
      final outcome = await splitter.split(path, maxChunkHeight: 8192);

      // Height (5000) <= max (8192) → single-chunk short-circuit.
      expect(outcome.paths.length, 1);
      expect(outcome.imageWidth, 1000);
      expect(outcome.chunkHeights, [5000]);

      // Even though the source was PNG, the chunk file is named .jpg AND
      // contains JPEG bytes (re-encoded by ImageSplitter). Sniff the
      // first bytes for the JPEG SOI marker (0xFF 0xD8).
      final bytes = File(outcome.paths[0]).readAsBytesSync();
      expect(bytes.length, greaterThan(2));
      expect(bytes[0], 0xff,
          reason: 'PNG must be re-encoded to JPEG for consistent rendering');
      expect(bytes[1], 0xd8);
    });

    testWidgets('PNG split path produces JPEG chunks', (tester) async {
      final path = await stage('tall_1000x12000.png');
      final outcome = await splitter.split(path, maxChunkHeight: _testMaxHeight);

      expect(outcome.paths.length, 3);
      expect(outcome.chunkHeights, [4096, 4096, 3808]);
      // Verify each chunk is actually JPEG.
      for (final p in outcome.paths) {
        final bytes = File(p).readAsBytesSync();
        expect(bytes[0], 0xff);
        expect(bytes[1], 0xd8);
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Width validation (OV-7)
  // ─────────────────────────────────────────────────────────────────────────

  group('width validation', () {
    testWidgets('12000x1000 throws WIDTH_TOO_LARGE', (tester) async {
      final path = await stage('wide_12000x1000.jpg');
      await expectLater(
        splitter.split(path, maxChunkHeight: _testMaxHeight),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'WIDTH_TOO_LARGE')),
      );
    });

    testWidgets('12000x1000 succeeds when maxChunkHeight >= 12000',
        (tester) async {
      final path = await stage('wide_12000x1000.jpg');
      // With max=16384, width (12000) is within the cap so it should work.
      // Skip if the device's actual texture limit is < 16384.
      final deviceMax = await splitter.getMaxTextureSize();
      if (deviceMax < 16384) {
        return; // device can't handle it; not a failure
      }
      final outcome = await splitter.split(path, maxChunkHeight: 16384);
      expect(outcome.paths.length, 1,
          reason: 'wide image fits in single chunk when max is large enough');
      expect(outcome.imageWidth, 12000);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Cache behaviour
  // ─────────────────────────────────────────────────────────────────────────

  group('cache behaviour', () {
    testWidgets('second call for same source returns fromCache=true',
        (tester) async {
      final path = await stage('tall_1000x5000.jpg');

      final first = await splitter.split(path, maxChunkHeight: _testMaxHeight);
      expect(first.fromCache, isFalse);

      final second = await splitter.split(path, maxChunkHeight: _testMaxHeight);
      expect(second.fromCache, isTrue);
      expect(second.paths, first.paths,
          reason: 'cache hit should return the same chunk paths');
      expect(second.chunkHeights, first.chunkHeights);
    });

    testWidgets('different maxChunkHeight does not collide with cache',
        (tester) async {
      final path = await stage('tall_1000x12000.jpg');

      final at4096 = await splitter.split(path, maxChunkHeight: 4096);
      expect(at4096.paths.length, 3);

      final at8192 = await splitter.split(path, maxChunkHeight: 8192);
      // Different max → different chunk count, must NOT serve from at4096's cache.
      expect(at8192.paths.length, 2,
          reason: 'cache key must include maxChunkHeight');
      expect(at8192.chunkHeights, [8192, 3808]);
    });

    testWidgets('clearCache wipes the cache so next call is fresh',
        (tester) async {
      final path = await stage('tall_1000x5000.jpg');

      await splitter.split(path, maxChunkHeight: _testMaxHeight);
      await splitter.clearCache();

      final after = await splitter.split(path, maxChunkHeight: _testMaxHeight);
      expect(after.fromCache, isFalse,
          reason: 'after clearCache, the next call should re-decode');
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // In-flight deduplication (TODO 3)
  // ─────────────────────────────────────────────────────────────────────────

  group('in-flight deduplication', () {
    testWidgets('concurrent split() calls for the same source share work',
        (tester) async {
      final path = await stage('tall_1000x12000.jpg');

      // Fire 5 concurrent requests. All should resolve to identical paths.
      final futures = List.generate(
        5,
        (_) => splitter.split(path, maxChunkHeight: _testMaxHeight),
      );
      final results = await Future.wait(futures);

      final firstPaths = results.first.paths;
      for (final r in results) {
        expect(r.paths, firstPaths,
            reason: 'all dedup waiters should receive the same chunk paths');
        expect(r.chunkHeights, [4096, 4096, 3808]);
      }
    });
  });
}
