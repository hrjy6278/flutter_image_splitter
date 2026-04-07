import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_splitter/flutter_image_splitter.dart';

const _assetPath = 'assets/test_images/tall_1000x12000.jpg';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Image Splitter — Before / After'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Before'),
                Tab(text: 'After'),
              ],
            ),
          ),
          body: const ImageSplitDemo(),
        ),
      ),
    );
  }
}

class ImageSplitDemo extends StatefulWidget {
  const ImageSplitDemo({super.key});

  @override
  State<ImageSplitDemo> createState() => _ImageSplitDemoState();
}

class _ImageSplitDemoState extends State<ImageSplitDemo> {
  final _splitter = ImageSplitter();

  SplitOutcome? _outcome;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _splitter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // Stage the bundled asset to a temp file so the native splitter can
      // read it as a regular file path.
      final bytes = await rootBundle.load(_assetPath);
      final tempFile = File(
        '${Directory.systemTemp.path}/example_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await tempFile.writeAsBytes(bytes.buffer.asUint8List());

      final outcome = await _splitter.split(tempFile.path);
      if (!mounted) return;
      setState(() => _outcome = outcome);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _error = '${e.code}: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(_error!, style: const TextStyle(color: Colors.red)),
      );
    }

    return TabBarView(
      children: [
        _BeforeTab(),
        _AfterTab(outcome: _outcome),
      ],
    );
  }
}

class _BeforeTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          color: Colors.red.shade50,
          child: const Text(
            'Image.asset (raw) — distorted by GPU texture limit',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Image.asset(_assetPath),
          ),
        ),
      ],
    );
  }
}

class _AfterTab extends StatelessWidget {
  const _AfterTab({required this.outcome});

  final SplitOutcome? outcome;

  @override
  Widget build(BuildContext context) {
    if (outcome == null) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          color: Colors.green.shade50,
          child: Text(
            'SplitImageView (chunked) — ${outcome!.chunkHeights.length} chunks, '
            'full ${outcome!.imageWidth}×${outcome!.totalHeight}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: SplitImageView.scrollable(outcome: outcome!),
        ),
      ],
    );
  }
}
