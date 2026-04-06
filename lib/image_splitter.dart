/// A Flutter plugin that splits tall images into memory-efficient chunks
/// using platform-native bitmap decoders.
///
/// Solves Flutter's GPU texture height limit (typically 4096–16384px,
/// depending on device) that causes distortion when rendering very tall
/// images such as promotional banners, infographics, and long screenshots.
///
/// ## Quick start
///
/// ```dart
/// import 'package:image_splitter/image_splitter.dart';
///
/// final splitter = ImageSplitter();
/// final outcome = await splitter.split('https://example.com/tall-image.jpg');
///
/// // Recommended: use the companion widget for jank-free rendering.
/// SplitImageView(outcome: outcome)
/// ```
///
/// See [ImageSplitter] for the full API.
library;

export 'src/image_splitter.dart';
export 'src/split_image_view.dart';
