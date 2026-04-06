package io.github.hrjy6278.image_splitter

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Matrix
import android.graphics.Rect
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

// =============================================================================
// ImageSplitter — pure splitting logic, no IO/threading concerns
// =============================================================================
//
// Input: a local file containing the source image bytes (already downloaded
// or supplied by the caller).
//
// Output: a list of JPEG chunk files in [outDir], plus per-chunk metadata.
//
// Pipeline:
//
//   File ─▶ Read EXIF orientation
//        ─▶ inJustDecodeBounds → width, height
//        ─▶ Reject if width > maxChunkHeight (WIDTH_TOO_LARGE)
//        ─▶ height ≤ max ──▶ Save full image (re-encoded with EXIF applied)
//                         └▶ Single chunk_0.jpg
//        ─▶ height > max ──▶ BitmapRegionDecoder loop
//                         ├▶ Decode rect [0..width, y..y+chunkH]
//                         ├▶ Apply EXIF rotation if needed
//                         ├▶ Compress to JPEG 92%
//                         ├▶ Recycle bitmap
//                         └▶ chunk_0.jpg, chunk_1.jpg, ...
//
// EXIF handling: ExifInterface reads the orientation tag. If non-zero, every
// chunk is rotated to match the user-visible orientation. This guarantees
// consistency between the no-split and split paths.
//
// JPEG quality: 92% — balances visual quality (text/edges) against file size.
// =============================================================================

internal class ImageSplitter {

    data class Output(
        val paths: List<String>,
        val chunkHeights: List<Int>,
        val imageWidth: Int,
    )

    fun split(sourceFile: File, outDir: File, maxChunkHeight: Int): Output {
        val orientation = readOrientation(sourceFile)

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        FileInputStream(sourceFile).use { BitmapFactory.decodeStream(it, null, bounds) }
        val rawWidth = bounds.outWidth
        val rawHeight = bounds.outHeight
        if (rawWidth <= 0 || rawHeight <= 0) {
            throw FlutterError("DECODE_ERROR", "Failed to decode image dimensions", null)
        }

        // Width validation must consider that EXIF rotation may swap axes.
        val (oriented_w, oriented_h) = applyRotationToDims(rawWidth, rawHeight, orientation)
        if (oriented_w > maxChunkHeight) {
            throw FlutterError(
                "WIDTH_TOO_LARGE",
                "Image width ($oriented_w) exceeds maxChunkHeight ($maxChunkHeight). " +
                    "Horizontal split is not supported in this version.",
                null,
            )
        }

        // ─── Short-circuit: image fits in one chunk ───
        if (oriented_h <= maxChunkHeight) {
            val full = BitmapFactory.decodeFile(sourceFile.absolutePath)
                ?: throw FlutterError("DECODE_ERROR", "Failed to decode image", null)
            val rotated = applyRotation(full, orientation)
            val outFile = File(outDir, "chunk_0.jpg")
            FileOutputStream(outFile).use { out ->
                rotated.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            }
            val height = rotated.height
            if (rotated !== full) full.recycle()
            rotated.recycle()
            return Output(
                paths = listOf(outFile.absolutePath),
                chunkHeights = listOf(height),
                imageWidth = oriented_w,
            )
        }

        // ─── Region-based split ───
        @Suppress("DEPRECATION")
        val decoder = BitmapRegionDecoder.newInstance(sourceFile.absolutePath, false)
            ?: throw FlutterError("DECODE_ERROR", "Failed to create BitmapRegionDecoder", null)

        try {
            val paths = mutableListOf<String>()
            val heights = mutableListOf<Int>()

            // Loop in raw (pre-rotation) coordinates so the decoder rect maps
            // directly to the file. Rotation is applied per-chunk after decode.
            // For non-rotated images, oriented_h == rawHeight so this is identical
            // to the simple loop. For 90/270 rotation, we slice along the raw
            // dimension that becomes "height" after rotation.
            val needsAxisSwap = orientation == ExifInterface.ORIENTATION_ROTATE_90 ||
                orientation == ExifInterface.ORIENTATION_ROTATE_270 ||
                orientation == ExifInterface.ORIENTATION_TRANSPOSE ||
                orientation == ExifInterface.ORIENTATION_TRANSVERSE

            // The dimension we slice along (in raw coords) is whichever raw axis
            // becomes the vertical axis after rotation.
            val sliceDimension = if (needsAxisSwap) rawWidth else rawHeight
            var pos = 0
            var index = 0
            while (pos < sliceDimension) {
                // Clamp the chunk size to never exceed the remaining pixels.
                val sliceSize = minOf(maxChunkHeight, sliceDimension - pos)
                val rect = if (needsAxisSwap) {
                    Rect(pos, 0, pos + sliceSize, rawHeight)
                } else {
                    Rect(0, pos, rawWidth, pos + sliceSize)
                }
                val chunk: Bitmap = decoder.decodeRegion(rect, null)
                    ?: throw FlutterError(
                        "SPLIT_ERROR",
                        "Region decode returned null at pos=$pos size=$sliceSize",
                        null,
                    )
                val rotated = applyRotation(chunk, orientation)
                val outFile = File(outDir, "chunk_$index.jpg")
                FileOutputStream(outFile).use { out ->
                    rotated.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
                }
                paths.add(outFile.absolutePath)
                heights.add(rotated.height)
                if (rotated !== chunk) rotated.recycle()
                chunk.recycle()
                pos += sliceSize
                index++
            }
            return Output(paths = paths, chunkHeights = heights, imageWidth = oriented_w)
        } finally {
            decoder.recycle()
        }
    }

    private fun readOrientation(file: File): Int = try {
        ExifInterface(file.absolutePath).getAttributeInt(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.ORIENTATION_NORMAL,
        )
    } catch (_: Exception) {
        ExifInterface.ORIENTATION_NORMAL
    }

    private fun applyRotation(src: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f); matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f); matrix.postScale(-1f, 1f)
            }
            else -> return src
        }
        return Bitmap.createBitmap(src, 0, 0, src.width, src.height, matrix, true)
    }

    private fun applyRotationToDims(w: Int, h: Int, orientation: Int): Pair<Int, Int> = when (orientation) {
        ExifInterface.ORIENTATION_ROTATE_90,
        ExifInterface.ORIENTATION_ROTATE_270,
        ExifInterface.ORIENTATION_TRANSPOSE,
        ExifInterface.ORIENTATION_TRANSVERSE -> h to w
        else -> w to h
    }

    companion object {
        private const val JPEG_QUALITY = 92
    }
}
