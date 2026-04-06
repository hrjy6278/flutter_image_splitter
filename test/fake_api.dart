import 'package:flutter_image_splitter/src/messages.g.dart';

// =============================================================================
// FakeImageSplitterApi — test double for the Pigeon-generated host API
// =============================================================================
//
// Records every call so tests can assert on the request payload, and
// returns whatever the test stages via [stagedResult] / [stagedMaxTextureSize].
//
// We extend [ImageSplitterApi] directly instead of using mockito because:
//   1) Pigeon-generated classes are simple enough that hand-writing a fake
//      is shorter than the mockito boilerplate.
//   2) Test failures are more obvious — you can read the fake's source.
//   3) No build_runner step required.
// =============================================================================

class FakeImageSplitterApi extends ImageSplitterApi {
  FakeImageSplitterApi() : super();

  /// All [splitImage] calls in arrival order.
  final List<SplitRequest> splitCalls = <SplitRequest>[];

  /// Number of times [getMaxTextureSize] was called.
  int maxTextureSizeCalls = 0;

  /// Number of times [clearCache] was called.
  int clearCacheCalls = 0;

  /// Result returned by the next [splitImage] call.
  SplitResult? stagedResult;

  /// Value returned by [getMaxTextureSize].
  int stagedMaxTextureSize = 4096;

  /// Value returned by [clearCache].
  int stagedClearCount = 0;

  @override
  Future<SplitResult> splitImage(SplitRequest request) async {
    splitCalls.add(request);
    final staged = stagedResult;
    if (staged == null) {
      throw StateError('FakeImageSplitterApi.stagedResult was not set');
    }
    return staged;
  }

  @override
  Future<int> clearCache() async {
    clearCacheCalls++;
    return stagedClearCount;
  }

  @override
  Future<int> getMaxTextureSize() async {
    maxTextureSizeCalls++;
    return stagedMaxTextureSize;
  }
}
