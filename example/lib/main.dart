import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_splitter/image_splitter.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Image Splitter Example')),
        body: const ImageSplitDemo(),
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
  final _urlController = TextEditingController();

  SplitOutcome? _outcome;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _splitter.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _split() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
      _outcome = null;
    });

    try {
      final outcome = await _splitter.split(url);
      setState(() {
        _outcome = outcome;
        _loading = false;
      });
    } on PlatformException catch (e) {
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    hintText: 'Enter image URL',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _loading ? null : _split,
                child: const Text('Split'),
              ),
            ],
          ),
        ),
        if (_loading) const CircularProgressIndicator.adaptive(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        if (_outcome != null)
          Expanded(
            child: SplitImageView.scrollable(outcome: _outcome!),
          ),
      ],
    );
  }
}
