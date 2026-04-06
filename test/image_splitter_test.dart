import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_splitter/image_splitter.dart';
import 'package:image_splitter/src/messages.g.dart';

import 'fake_api.dart';

// =============================================================================
// ImageSplitter — Dart-side unit tests
// =============================================================================
//
// Strategy: inject a [FakeImageSplitterApi] via [ImageSplitter.withApi] so we
// can exercise the Dart facade in isolation, without touching native code.
// The fake records every call and lets each test stage its own outcome.
//
// What we cover:
//   - Empty / blank source rejection
//   - Unsupported scheme rejection
//   - Local file existence check
//   - ETag round-trip (cached on first call, sent on second call)
//   - dispose() invariants (subsequent calls throw StateError)
//   - getMaxTextureSize is queried once and cached
//   - clearCache() clears the in-memory ETag map AND calls native
// =============================================================================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ImageSplitter — input validation', () {
    test('rejects empty source', () async {
      final fake = FakeImageSplitterApi();
      final splitter = ImageSplitter.withApi(fake);
      await expectLater(
        splitter.split(''),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'INVALID_ARGS',
          ),
        ),
      );
      expect(
        fake.splitCalls,
        isEmpty,
        reason: 'native should not be invoked for empty source',
      );
    });

    test('rejects whitespace-only source', () async {
      final fake = FakeImageSplitterApi();
      final splitter = ImageSplitter.withApi(fake);
      await expectLater(
        splitter.split('   '),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'INVALID_ARGS',
          ),
        ),
      );
    });

    test('rejects unsupported scheme', () async {
      final fake = FakeImageSplitterApi();
      final splitter = ImageSplitter.withApi(fake);
      await expectLater(
        splitter.split('ftp://example.com/foo.jpg'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'INVALID_ARGS',
          ),
        ),
      );
    });

    test('rejects local file that does not exist', () async {
      final fake = FakeImageSplitterApi();
      final splitter = ImageSplitter.withApi(fake);
      await expectLater(
        splitter.split('/tmp/definitely_does_not_exist_xyz.jpg'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'FILE_NOT_FOUND',
          ),
        ),
      );
      expect(fake.splitCalls, isEmpty);
    });

    test('accepts existing local file', () async {
      final tempFile = File(
        '${Directory.systemTemp.path}/'
        'image_splitter_test_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      tempFile.writeAsBytesSync([0xff, 0xd8, 0xff, 0xd9]); // tiny JPEG bytes
      addTearDown(() {
        if (tempFile.existsSync()) tempFile.deleteSync();
      });

      final fake =
          FakeImageSplitterApi()
            ..stagedResult = SplitResult(
              paths: ['/cache/chunk_0.jpg'],
              fromCache: false,
              chunkHeights: [100],
              imageWidth: 200,
            );
      final splitter = ImageSplitter.withApi(fake);
      final outcome = await splitter.split(tempFile.path);
      expect(outcome.paths, ['/cache/chunk_0.jpg']);
      expect(fake.splitCalls.single.source, tempFile.path);
    });
  });

  group('ImageSplitter — ETag round-trip', () {
    test(
      'first call sends no etag; second call sends the etag from first response',
      () async {
        final fake =
            FakeImageSplitterApi()
              ..stagedResult = SplitResult(
                paths: ['/cache/chunk_0.jpg'],
                fromCache: false,
                etag: 'W/"abc123"',
                lastModified: 'Mon, 01 Jan 2024 00:00:00 GMT',
                chunkHeights: [4096],
                imageWidth: 1024,
              );
        final splitter = ImageSplitter.withApi(fake);

        // First call: no cached etag.
        final first = await splitter.split('https://example.com/img.jpg');
        expect(first.etag, 'W/"abc123"');
        expect(fake.splitCalls[0].cachedEtag, isNull);

        // Stage a "not modified" response for the second call. The native
        // side decides whether to actually return cached chunks; we just verify
        // the Dart side passes the etag through.
        fake.stagedResult = SplitResult(
          paths: ['/cache/chunk_0.jpg'],
          fromCache: true,
          etag: 'W/"abc123"',
          lastModified: 'Mon, 01 Jan 2024 00:00:00 GMT',
          chunkHeights: [4096],
          imageWidth: 1024,
        );

        // Second call: cached etag should be sent.
        await splitter.split('https://example.com/img.jpg');
        expect(fake.splitCalls[1].cachedEtag, 'W/"abc123"');
        expect(
          fake.splitCalls[1].cachedLastModified,
          'Mon, 01 Jan 2024 00:00:00 GMT',
        );
      },
    );

    test('clearCache wipes the in-memory etag map', () async {
      final fake =
          FakeImageSplitterApi()
            ..stagedResult = SplitResult(
              paths: ['/cache/chunk_0.jpg'],
              fromCache: false,
              etag: 'etag-1',
              chunkHeights: [100],
              imageWidth: 200,
            );
      final splitter = ImageSplitter.withApi(fake);
      await splitter.split('https://example.com/img.jpg');
      expect(fake.splitCalls[0].cachedEtag, isNull);

      await splitter.split('https://example.com/img.jpg');
      expect(fake.splitCalls[1].cachedEtag, 'etag-1');

      await splitter.clearCache();

      // After clearing, the etag should be gone.
      await splitter.split('https://example.com/img.jpg');
      expect(
        fake.splitCalls[2].cachedEtag,
        isNull,
        reason: 'clearCache must reset the etag map',
      );
    });
  });

  group('ImageSplitter — texture-size caching', () {
    test('queries getMaxTextureSize once and reuses the value', () async {
      final fake =
          FakeImageSplitterApi()
            ..stagedMaxTextureSize = 8192
            ..stagedResult = SplitResult(
              paths: ['/cache/chunk_0.jpg'],
              fromCache: false,
              chunkHeights: [100],
              imageWidth: 200,
            );
      final splitter = ImageSplitter.withApi(fake);

      await splitter.split('https://example.com/a.jpg');
      await splitter.split('https://example.com/b.jpg');

      expect(
        fake.maxTextureSizeCalls,
        1,
        reason: 'texture probe must be cached for the instance lifetime',
      );
      // Both split calls should have used the cached value as maxChunkHeight.
      expect(fake.splitCalls[0].maxChunkHeight, 8192);
      expect(fake.splitCalls[1].maxChunkHeight, 8192);
    });

    test('honours explicit maxChunkHeight without probing', () async {
      final fake =
          FakeImageSplitterApi()
            ..stagedResult = SplitResult(
              paths: ['/cache/chunk_0.jpg'],
              fromCache: false,
              chunkHeights: [100],
              imageWidth: 200,
            );
      final splitter = ImageSplitter.withApi(fake);

      await splitter.split('https://example.com/a.jpg', maxChunkHeight: 4096);
      expect(
        fake.maxTextureSizeCalls,
        0,
        reason: 'should not probe when caller supplies an explicit value',
      );
      expect(fake.splitCalls[0].maxChunkHeight, 4096);
    });
  });

  group('ImageSplitter — dispose', () {
    test('split() throws after dispose', () async {
      final splitter = ImageSplitter.withApi(FakeImageSplitterApi());
      splitter.dispose();
      expect(
        () => splitter.split('https://example.com/x.jpg'),
        throwsA(isA<StateError>()),
      );
    });

    test('clearCache() throws after dispose', () async {
      final splitter = ImageSplitter.withApi(FakeImageSplitterApi());
      splitter.dispose();
      expect(() => splitter.clearCache(), throwsA(isA<StateError>()));
    });

    test('getMaxTextureSize() throws after dispose', () async {
      final splitter = ImageSplitter.withApi(FakeImageSplitterApi());
      splitter.dispose();
      expect(() => splitter.getMaxTextureSize(), throwsA(isA<StateError>()));
    });
  });

  group('SplitOutcome', () {
    test('totalHeight sums all chunk heights', () {
      final outcome = SplitOutcome(
        paths: ['a', 'b', 'c'],
        fromCache: false,
        chunkHeights: [4096, 4096, 1500],
        imageWidth: 1024,
      );
      expect(outcome.totalHeight, 9692);
    });

    test('aspectRatio = imageWidth / totalHeight', () {
      final outcome = SplitOutcome(
        paths: ['a'],
        fromCache: false,
        chunkHeights: [2000],
        imageWidth: 1000,
      );
      expect(outcome.aspectRatio, closeTo(0.5, 1e-9));
    });
  });
}
