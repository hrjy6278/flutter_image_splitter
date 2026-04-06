import 'dart:io';

import 'package:flutter/material.dart';

import 'image_splitter.dart';

// =============================================================================
// SplitImageView — companion widget for ImageSplitter
// =============================================================================
//
// Renders a [SplitOutcome] as a vertically-scrolling stack of images. Each
// chunk is given a precise placeholder size up-front so the layout never
// jumps as chunks load — this is the difference that makes split rendering
// feel like a single image instead of a janky list.
//
// Layout strategy:
//
//   ┌─────────────────────────┐
//   │ chunk_0 (precise size)  │ ← decoded immediately
//   ├─────────────────────────┤
//   │ chunk_1 (precise size)  │ ← decoded as it scrolls into view
//   ├─────────────────────────┤
//   │ ...                     │
//   └─────────────────────────┘
//
// The widget uses [SizedBox] wrappers around each [Image.file] so the slot
// has a known height before the image is decoded. This eliminates the
// scroll-jump that would otherwise happen when ListView's auto-sizing
// kicks in.
//
// Seam minimisation: each chunk is rendered with [BoxFit.fitWidth] and
// [FilterQuality.high]. Adjacent chunks share an exact pixel boundary
// because the original splitting was done on integer pixel offsets — no
// sub-pixel interpolation creates visible seams.
//
// Two rendering modes:
//   - SplitImageView (default) — non-scrollable, fits inside a parent scroller
//   - SplitImageView.scrollable — wraps in a SingleChildScrollView
//
// Use the non-scrollable variant when nesting inside a CustomScrollView /
// ListView; use the scrollable variant for standalone "infographic" pages.
// =============================================================================

class SplitImageView extends StatelessWidget {
  /// Creates a non-scrollable split image. Wrap in a parent scroller (e.g.,
  /// `SingleChildScrollView`, `CustomScrollView`) to enable scrolling.
  const SplitImageView({
    super.key,
    required this.outcome,
    this.width,
    this.filterQuality = FilterQuality.high,
    this.errorBuilder,
  }) : _scrollable = false;

  /// Creates a scrollable split image suitable as a standalone page body.
  const SplitImageView.scrollable({
    super.key,
    required this.outcome,
    this.width,
    this.filterQuality = FilterQuality.high,
    this.errorBuilder,
  }) : _scrollable = true;

  /// The split outcome from [ImageSplitter.split].
  final SplitOutcome outcome;

  /// Display width. Defaults to the parent constraint's max width.
  final double? width;

  /// Filter quality for each chunk. High is recommended to minimise seams.
  final FilterQuality filterQuality;

  /// Optional builder for the per-chunk error state. Called with the
  /// failing chunk index and the error.
  final Widget Function(BuildContext, int chunkIndex, Object error)? errorBuilder;

  final bool _scrollable;

  @override
  Widget build(BuildContext context) {
    final body = _Body(
      outcome: outcome,
      width: width,
      filterQuality: filterQuality,
      errorBuilder: errorBuilder,
    );
    if (_scrollable) {
      return SingleChildScrollView(child: body);
    }
    return body;
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.outcome,
    required this.width,
    required this.filterQuality,
    required this.errorBuilder,
  });

  final SplitOutcome outcome;
  final double? width;
  final FilterQuality filterQuality;
  final Widget Function(BuildContext, int, Object)? errorBuilder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final renderWidth = width ?? constraints.maxWidth;
        // The display height for each chunk is the chunk's pixel height
        // scaled by (renderWidth / imageWidth). Computing this once here
        // (instead of relying on Image's intrinsic measurement) prevents
        // any layout shift when the bitmap finishes decoding.
        final scale = renderWidth / outcome.imageWidth;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < outcome.paths.length; i++)
              SizedBox(
                width: renderWidth,
                height: outcome.chunkHeights[i] * scale,
                child: Image.file(
                  File(outcome.paths[i]),
                  fit: BoxFit.fill,
                  filterQuality: filterQuality,
                  // gaplessPlayback: keep the previous frame visible during
                  // file changes (e.g., cache invalidation + refresh).
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stack) {
                    if (errorBuilder != null) {
                      return errorBuilder!(context, i, error);
                    }
                    return _DefaultChunkError(index: i, error: error);
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DefaultChunkError extends StatelessWidget {
  const _DefaultChunkError({required this.index, required this.error});

  final int index;
  final Object error;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Chunk $index failed to load',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ),
      ),
    );
  }
}
