import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_image_splitter/flutter_image_splitter.dart';

// =============================================================================
// SplitImageView — widget tests
// =============================================================================
//
// We can't easily render a real JPEG in unit tests (no asset bundle, no
// real image bytes), so these tests focus on layout invariants:
//
//   1. Each chunk gets a SizedBox with the precisely computed display height
//   2. The total widget height equals sum(chunkHeight) * scale
//   3. The error builder is invoked when a file is missing
//   4. The scrollable variant wraps in a SingleChildScrollView
//
// We use a tiny on-disk JPEG (a 1x1 pixel) to satisfy Image.file's loader.
// =============================================================================

// Smallest possible valid JPEG (1x1 pixel, white). Hex source taken from
// the JPEG Wikipedia article — verified bytes.
final Uint8List _tinyJpeg = Uint8List.fromList([
  0xff,
  0xd8,
  0xff,
  0xe0,
  0x00,
  0x10,
  0x4a,
  0x46,
  0x49,
  0x46,
  0x00,
  0x01,
  0x01,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
  0x00,
  0xff,
  0xdb,
  0x00,
  0x43,
  0x00,
  0x08,
  0x06,
  0x06,
  0x07,
  0x06,
  0x05,
  0x08,
  0x07,
  0x07,
  0x07,
  0x09,
  0x09,
  0x08,
  0x0a,
  0x0c,
  0x14,
  0x0d,
  0x0c,
  0x0b,
  0x0b,
  0x0c,
  0x19,
  0x12,
  0x13,
  0x0f,
  0x14,
  0x1d,
  0x1a,
  0x1f,
  0x1e,
  0x1d,
  0x1a,
  0x1c,
  0x1c,
  0x20,
  0x24,
  0x2e,
  0x27,
  0x20,
  0x22,
  0x2c,
  0x23,
  0x1c,
  0x1c,
  0x28,
  0x37,
  0x29,
  0x2c,
  0x30,
  0x31,
  0x34,
  0x34,
  0x34,
  0x1f,
  0x27,
  0x39,
  0x3d,
  0x38,
  0x32,
  0x3c,
  0x2e,
  0x33,
  0x34,
  0x32,
  0xff,
  0xc0,
  0x00,
  0x0b,
  0x08,
  0x00,
  0x01,
  0x00,
  0x01,
  0x01,
  0x01,
  0x11,
  0x00,
  0xff,
  0xc4,
  0x00,
  0x1f,
  0x00,
  0x00,
  0x01,
  0x05,
  0x01,
  0x01,
  0x01,
  0x01,
  0x01,
  0x01,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  0x02,
  0x03,
  0x04,
  0x05,
  0x06,
  0x07,
  0x08,
  0x09,
  0x0a,
  0x0b,
  0xff,
  0xc4,
  0x00,
  0xb5,
  0x10,
  0x00,
  0x02,
  0x01,
  0x03,
  0x03,
  0x02,
  0x04,
  0x03,
  0x05,
  0x05,
  0x04,
  0x04,
  0x00,
  0x00,
  0x01,
  0x7d,
  0x01,
  0x02,
  0x03,
  0x00,
  0x04,
  0x11,
  0x05,
  0x12,
  0x21,
  0x31,
  0x41,
  0x06,
  0x13,
  0x51,
  0x61,
  0x07,
  0x22,
  0x71,
  0x14,
  0x32,
  0x81,
  0x91,
  0xa1,
  0x08,
  0x23,
  0x42,
  0xb1,
  0xc1,
  0x15,
  0x52,
  0xd1,
  0xf0,
  0x24,
  0x33,
  0x62,
  0x72,
  0x82,
  0xff,
  0xda,
  0x00,
  0x08,
  0x01,
  0x01,
  0x00,
  0x00,
  0x3f,
  0x00,
  0xfb,
  0xd0,
  0xff,
  0xd9,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File chunk0;
  late File chunk1;
  late File chunk2;

  setUp(() {
    final tempDir = Directory.systemTemp.createTempSync(
      'split_image_view_test',
    );
    chunk0 = File('${tempDir.path}/chunk_0.jpg')..writeAsBytesSync(_tinyJpeg);
    chunk1 = File('${tempDir.path}/chunk_1.jpg')..writeAsBytesSync(_tinyJpeg);
    chunk2 = File('${tempDir.path}/chunk_2.jpg')..writeAsBytesSync(_tinyJpeg);
  });

  testWidgets('renders one SizedBox per chunk with computed height', (
    tester,
  ) async {
    final outcome = SplitOutcome(
      paths: [chunk0.path, chunk1.path, chunk2.path],
      fromCache: false,
      chunkHeights: [400, 400, 200],
      imageWidth: 200,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100, // → scale 0.5, total display height = 500
              child: SplitImageView(outcome: outcome),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final sizedBoxes =
        tester
            .widgetList<SizedBox>(find.byType(SizedBox))
            .where((s) => s.height != null && s.width == 100)
            .toList();
    // Three SizedBox wrappers (one per chunk), heights 200, 200, 100.
    expect(sizedBoxes.map((s) => s.height), [200.0, 200.0, 100.0]);
  });

  testWidgets('total column height equals sum of scaled chunk heights', (
    tester,
  ) async {
    final outcome = SplitOutcome(
      paths: [chunk0.path, chunk1.path],
      fromCache: false,
      chunkHeights: [600, 400],
      imageWidth: 200,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100, // scale 0.5 → 300 + 200 = 500
              child: SplitImageView(outcome: outcome),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final column = tester.getSize(find.byType(Column).first);
    expect(column.height, 500.0);
  });

  testWidgets('scrollable variant wraps in SingleChildScrollView', (
    tester,
  ) async {
    final outcome = SplitOutcome(
      paths: [chunk0.path],
      fromCache: false,
      chunkHeights: [100],
      imageWidth: 200,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SplitImageView.scrollable(outcome: outcome)),
      ),
    );
    await tester.pump();
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('errorBuilder is invoked for missing files', (tester) async {
    final outcome = SplitOutcome(
      paths: ['/tmp/definitely_missing_xyz.jpg'],
      fromCache: false,
      chunkHeights: [100],
      imageWidth: 200,
    );

    var errorReceivedFor = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SplitImageView(
            outcome: outcome,
            errorBuilder: (context, index, error) {
              errorReceivedFor = index;
              return const Text('CUSTOM_ERROR');
            },
          ),
        ),
      ),
    );
    // Image.file resolves through the async file image stream. Use
    // runAsync so the test scheduler actually services the file IO.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('CUSTOM_ERROR'), findsOneWidget);
    expect(errorReceivedFor, 0);
  });
}
