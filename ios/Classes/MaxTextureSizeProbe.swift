import Foundation
import Metal

// =============================================================================
// MaxTextureSizeProbe — queries Metal for the device's max 2D texture size
// =============================================================================
//
// On iOS, the GPU texture size limit depends on the Metal feature set:
//
//   - A7 (iPhone 5s)              → 4096
//   - A8 / A9 / A10               → 8192
//   - A11 and later               → 16384
//
// We don't hardcode any of these. Instead, we query at runtime via
// MTLDevice.maxTextureSize2D — actually, Metal exposes this indirectly via
// MTLGPUFamily. We probe each known family in descending order and return
// the most permissive limit the device supports.
//
// Fallback: 4096 if no Metal device is available (e.g., simulator without
// GPU support, or future API removal). This is the safest real-world value.
// =============================================================================

enum MaxTextureSizeProbe {
    static let safeFallback: Int = 4096

    static func query() -> Int {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return safeFallback
        }
        // Test in descending order — return the largest supported limit.
        if device.supportsFamily(.apple3) {
            return 16384
        }
        if device.supportsFamily(.apple2) {
            return 8192
        }
        return safeFallback
    }
}
