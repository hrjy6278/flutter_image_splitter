import Foundation
import ImageIO
import CoreGraphics
import UIKit

// =============================================================================
// ImageSplitter — pure splitting logic, no IO/threading concerns
// =============================================================================
//
// Pipeline:
//
//   File ─▶ CGImageSourceCreateWithURL  (no full decode yet)
//        ─▶ Read CGImageProperties      (orientation, width, height)
//        ─▶ Reject if width > maxChunkHeight (WIDTH_TOO_LARGE)
//        ─▶ height ≤ max ──▶ Decode full image at full size
//                         ├▶ Apply EXIF orientation
//                         └▶ JPEG 92%, save chunk_0.jpg
//        ─▶ height > max ──▶ Region loop
//                         ├▶ For each slice:
//                         │   - Create thumbnail at full size (CGImageSourceCreateImageAtIndex
//                         │     with kCGImageSourceShouldCacheImmediately = false)
//                         │   - Crop to slice rect
//                         │   - Wrap in UIImage with correct orientation
//                         │   - JPEG-encode and save
//                         │   - Release CGImage immediately
//                         └▶ chunk_0.jpg, chunk_1.jpg, ...
//
// Memory: CGImageSource lazily holds the file mapping. Each cropped CGImage
// references the parent's pixel storage; only the JPEG encode pass actually
// allocates a chunk-sized buffer. Release happens at the end of each loop
// iteration via Swift's ARC.
//
// EXIF: applied uniformly across the no-split and split paths so the same
// URL never produces inconsistently rotated output. The fix-up uses
// UIImage(cgImage:scale:orientation:) and re-renders into a fresh CGImage
// when needed.
// =============================================================================

final class ImageSplitter {

    struct Output {
        let paths: [String]
        let chunkHeights: [Int]
        let imageWidth: Int
    }

    enum SplitError: Error {
        case decodeError(String)
        case widthTooLarge(Int, Int)
        case splitError(String)
    }

    private static let jpegQuality: CGFloat = 0.92

    func split(sourceFile: String, outDirectory: String, maxChunkHeight: Int) throws -> Output {
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: sourceFile) as CFURL, nil
        ) else {
            throw SplitError.decodeError("Failed to create CGImageSource for \(sourceFile)")
        }

        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = props[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        else {
            throw SplitError.decodeError("Failed to read image properties")
        }

        let exifOrientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let uiOrientation = uiImageOrientation(fromExif: exifOrientation)

        // Width validation must consider that EXIF rotation may swap axes.
        let (orientedWidth, orientedHeight) = orientedDims(
            pixelWidth, pixelHeight, exifOrientation
        )
        if orientedWidth > maxChunkHeight {
            throw SplitError.widthTooLarge(orientedWidth, maxChunkHeight)
        }

        // ─── Short-circuit: image fits in one chunk ───
        if orientedHeight <= maxChunkHeight {
            guard let cg = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: false
            ] as CFDictionary) else {
                throw SplitError.decodeError("Failed to decode full image")
            }
            let oriented = renderOriented(cg, orientation: uiOrientation)
            let outPath = (outDirectory as NSString).appendingPathComponent("chunk_0.jpg")
            try writeJPEG(oriented, to: outPath)
            return Output(
                paths: [outPath],
                chunkHeights: [oriented.height],
                imageWidth: orientedWidth,
            )
        }

        // ─── Region-based split ───
        // Decode the full image once (memory-mapped via CGImageSource), then
        // crop slices. Cropping does not allocate; only the JPEG encode does.
        guard let fullCG = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary) else {
            throw SplitError.decodeError("Failed to decode source image")
        }

        // Apply EXIF orientation up-front so all subsequent slicing is in
        // user-visible coordinates.
        let oriented = renderOriented(fullCG, orientation: uiOrientation)

        var paths: [String] = []
        var heights: [Int] = []
        var pos = 0
        var index = 0

        while pos < oriented.height {
            // Clamp slice size to remaining pixels — this prevents the
            // integer-overflow / out-of-bounds class of cropping(to:) failures.
            let sliceHeight = min(maxChunkHeight, oriented.height - pos)
            let rect = CGRect(x: 0, y: pos, width: oriented.width, height: sliceHeight)

            guard let chunk = oriented.cropping(to: rect) else {
                throw SplitError.splitError(
                    "cropping(to:) returned nil at pos=\(pos) size=\(sliceHeight)"
                )
            }
            let outPath = (outDirectory as NSString).appendingPathComponent("chunk_\(index).jpg")
            try writeJPEG(chunk, to: outPath)
            paths.append(outPath)
            heights.append(sliceHeight)
            pos += sliceHeight
            index += 1
        }

        return Output(paths: paths, chunkHeights: heights, imageWidth: orientedWidth)
    }

    // -------------------------------------------------------------------------
    // EXIF / orientation helpers
    // -------------------------------------------------------------------------

    private func uiImageOrientation(fromExif exif: UInt32) -> UIImage.Orientation {
        switch exif {
        case 1: return .up
        case 2: return .upMirrored
        case 3: return .down
        case 4: return .downMirrored
        case 5: return .leftMirrored
        case 6: return .right
        case 7: return .rightMirrored
        case 8: return .left
        default: return .up
        }
    }

    private func orientedDims(_ w: Int, _ h: Int, _ exif: UInt32) -> (Int, Int) {
        // 5..8 swap the axes.
        switch exif {
        case 5, 6, 7, 8: return (h, w)
        default: return (w, h)
        }
    }

    /// Re-renders [cg] with EXIF orientation baked in. For .up images this
    /// is a no-op (returns the original). For rotated/flipped images this
    /// allocates a new bitmap context.
    private func renderOriented(_ cg: CGImage, orientation: UIImage.Orientation) -> CGImage {
        if orientation == .up { return cg }
        let ui = UIImage(cgImage: cg, scale: 1.0, orientation: orientation)
        let renderer = UIGraphicsImageRenderer(size: ui.size)
        let normalized = renderer.image { _ in ui.draw(at: .zero) }
        return normalized.cgImage ?? cg
    }

    // -------------------------------------------------------------------------
    // JPEG encode
    // -------------------------------------------------------------------------

    private func writeJPEG(_ cg: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(
            url, "public.jpeg" as CFString, 1, nil
        ) else {
            throw SplitError.splitError("Failed to create JPEG destination")
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: ImageSplitter.jpegQuality
        ]
        CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw SplitError.splitError("Failed to finalize JPEG")
        }
    }
}
