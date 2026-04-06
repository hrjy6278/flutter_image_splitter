package io.github.hrjy6278.image_splitter

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20

// =============================================================================
// MaxTextureSizeProbe
// =============================================================================
//
// Queries GL_MAX_TEXTURE_SIZE by spinning up a throwaway EGL context.
// This is the only reliable way to know the device's actual GPU texture
// limit — Skia documentation hardcodes 8192 but real devices range from
// 4096 (older Mali, Adreno 3xx) to 16384+ (modern Adreno, Mali-G).
//
// The EGL context is created on a 1x1 pbuffer surface, queried, then torn
// down. Total cost is a few milliseconds. Result should be cached by the
// caller — do not call this on a hot path.
//
// Fallback: returns 4096 (the most conservative real-world value) if any
// EGL step fails. This guarantees correctness even if the probe breaks on
// some weird device, at the cost of more chunks than necessary.
// =============================================================================

internal object MaxTextureSizeProbe {

    private const val SAFE_FALLBACK = 4096

    fun query(): Int = try {
        probe()
    } catch (_: Throwable) {
        SAFE_FALLBACK
    }

    private fun probe(): Int {
        val display: EGLDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) return SAFE_FALLBACK

        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) {
            return SAFE_FALLBACK
        }

        try {
            val configAttribs = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            if (!EGL14.eglChooseConfig(display, configAttribs, 0, configs, 0, 1, numConfigs, 0) ||
                numConfigs[0] == 0
            ) {
                return SAFE_FALLBACK
            }
            val config = configs[0] ?: return SAFE_FALLBACK

            val contextAttribs = intArrayOf(
                EGL14.EGL_CONTEXT_CLIENT_VERSION, 2,
                EGL14.EGL_NONE,
            )
            val context: EGLContext = EGL14.eglCreateContext(
                display, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0
            )
            if (context == EGL14.EGL_NO_CONTEXT) return SAFE_FALLBACK

            val pbufferAttribs = intArrayOf(
                EGL14.EGL_WIDTH, 1,
                EGL14.EGL_HEIGHT, 1,
                EGL14.EGL_NONE,
            )
            val surface: EGLSurface = EGL14.eglCreatePbufferSurface(
                display, config, pbufferAttribs, 0
            )
            if (surface == EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroyContext(display, context)
                return SAFE_FALLBACK
            }

            try {
                if (!EGL14.eglMakeCurrent(display, surface, surface, context)) {
                    return SAFE_FALLBACK
                }
                val out = IntArray(1)
                GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, out, 0)
                val value = out[0]
                EGL14.eglMakeCurrent(
                    display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT
                )
                return if (value > 0) value else SAFE_FALLBACK
            } finally {
                EGL14.eglDestroySurface(display, surface)
                EGL14.eglDestroyContext(display, context)
            }
        } finally {
            EGL14.eglTerminate(display)
        }
    }
}
