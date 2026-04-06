import Flutter
import UIKit
import Foundation

// =============================================================================
// ImageSplitterPlugin — iOS entrypoint
// =============================================================================
//
// Request lifecycle (CRITICAL ORDERING — see review issue OV-4):
//
//   splitImage(request)
//       │
//       ▼
//   1. Input validation
//       ▼
//   2. In-flight dedup check
//       │   (same source key already running? attach to existing future)
//       ▼
//   3. Cache read fast path
//       │   (no ETag → return immediately if cache hit)
//       ▼
//   4. Concurrency gate (DispatchSemaphore, value 2)
//       │   (limits memory peak)
//       ▼
//   5. Download (conditional GET) → temp file in temp dir
//       ▼
//   6. ImageSplitter.split → chunks in temp dir
//       ▼
//   7. Atomic move: temp dir → final cache dir
//       ▼
//   8. Resolve dedup waiters, return result
//
// Threading: each request runs on a single global concurrent queue
// (.userInitiated). The semaphore is what actually caps concurrency.
// =============================================================================

public class ImageSplitterPlugin: NSObject, FlutterPlugin, ImageSplitterApi {

    private let cacheManager: CacheManager
    private let downloader = ImageDownloader()
    private let splitter = ImageSplitter()

    private let queue = DispatchQueue(
        label: "com.tommyfuture.image_splitter.work",
        qos: .userInitiated,
        attributes: .concurrent
    )
    // value=2 mirrors the Android Semaphore(2) — keeps memory peak bounded.
    private let concurrencyGate = DispatchSemaphore(value: 2)

    // In-flight dedup. Concurrent callers for the same key share the same
    // promise. Mutated only on [stateQueue] for thread safety.
    private var inFlight: [String: [(Result<SplitResult, Error>) -> Void]] = [:]
    private let stateQueue = DispatchQueue(label: "com.tommyfuture.image_splitter.state")

    // Cached Metal probe result. The value can never change at runtime.
    private var cachedMaxTextureSize: Int?

    public override init() {
        let cacheRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("image_splits")
        self.cacheManager = CacheManager(rootDirectory: cacheRoot)
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = ImageSplitterPlugin()
        ImageSplitterApiSetup.setUp(
            binaryMessenger: registrar.messenger(),
            api: instance
        )
    }

    // =========================================================================
    // ImageSplitterApi
    // =========================================================================

    func splitImage(
        request: SplitRequest,
        completion: @escaping (Result<SplitResult, Error>) -> Void
    ) {
        let source = request.source
        let maxChunkHeight = Int(request.maxChunkHeight)

        guard !source.isEmpty else {
            completion(.failure(PigeonError(
                code: "INVALID_ARGS",
                message: "source must not be empty",
                details: nil
            )))
            return
        }
        guard maxChunkHeight > 0 else {
            completion(.failure(PigeonError(
                code: "INVALID_ARGS",
                message: "maxChunkHeight must be positive",
                details: nil
            )))
            return
        }

        // Cache key includes maxChunkHeight because different chunk sizes
        // produce different output sets.
        let key = cacheManager.key(for: "\(source)|\(maxChunkHeight)")

        // Step 2: in-flight dedup. computeIfAbsent semantics — only the
        // first caller for a given key triggers actual work.
        let isFirst: Bool = stateQueue.sync {
            if inFlight[key] != nil {
                inFlight[key]?.append(completion)
                return false
            } else {
                inFlight[key] = [completion]
                return true
            }
        }
        if !isFirst { return }

        queue.async { [weak self] in
            guard let self = self else {
                // Plugin was deallocated mid-flight. Notify all waiters so
                // their Futures complete instead of hanging forever.
                let error = PigeonError(
                    code: "SPLIT_ERROR",
                    message: "Plugin deallocated before request completed",
                    details: nil
                )
                completion(.failure(error))
                return
            }
            self.runRequest(key: key, source: source, maxChunkHeight: maxChunkHeight, request: request)
        }
    }

    private func runRequest(
        key: String,
        source: String,
        maxChunkHeight: Int,
        request: SplitRequest
    ) {
        // Step 3: cache fast path (only when caller did NOT pass an ETag).
        if request.cachedEtag == nil && request.cachedLastModified == nil,
           let entry = cacheManager.read(key: key) {
            resolveWaiters(key: key, result: .success(entry.toSplitResult(fromCache: true)))
            return
        }

        // Step 4: bound concurrency before doing any heavy work.
        concurrencyGate.wait()
        defer { concurrencyGate.signal() }

        let result = processSource(
            key: key, source: source, maxChunkHeight: maxChunkHeight, request: request
        )
        resolveWaiters(key: key, result: result)
    }

    private func resolveWaiters(key: String, result: Result<SplitResult, Error>) {
        let waiters: [(Result<SplitResult, Error>) -> Void] = stateQueue.sync {
            let list = inFlight[key] ?? []
            inFlight.removeValue(forKey: key)
            return list
        }
        for waiter in waiters {
            waiter(result)
        }
    }

    private func processSource(
        key: String,
        source: String,
        maxChunkHeight: Int,
        request: SplitRequest
    ) -> Result<SplitResult, Error> {
        let tempDir: String
        do {
            tempDir = try cacheManager.newTempDirectory(for: key)
        } catch {
            return .failure(PigeonError(
                code: "SPLIT_ERROR",
                message: "Failed to create temp dir: \(error)",
                details: nil
            ))
        }

        let inputFile: String
        let etag: String?
        let lastModified: String?

        if isLocalSource(source) {
            let path = resolveLocalPath(source)
            guard FileManager.default.fileExists(atPath: path) else {
                cacheManager.discard(tempDir: tempDir)
                return .failure(PigeonError(
                    code: "FILE_NOT_FOUND",
                    message: "Local file does not exist: \(path)",
                    details: nil
                ))
            }
            inputFile = path
            etag = nil
            lastModified = nil
        } else {
            guard let url = URL(string: source) else {
                cacheManager.discard(tempDir: tempDir)
                return .failure(PigeonError(
                    code: "INVALID_ARGS",
                    message: "Invalid URL: \(source)",
                    details: nil
                ))
            }
            do {
                let downloadResult = try downloader.download(
                    url: url,
                    destDirectory: tempDir,
                    cachedEtag: request.cachedEtag,
                    cachedLastModified: request.cachedLastModified
                )
                switch downloadResult {
                case .notModified:
                    cacheManager.discard(tempDir: tempDir)
                    guard let entry = cacheManager.read(key: key) else {
                        return .failure(PigeonError(
                            code: "SPLIT_ERROR",
                            message: "Server returned 304 but cache is missing",
                            details: nil
                        ))
                    }
                    return .success(entry.toSplitResult(fromCache: true))
                case .downloaded(let file, let e, let lm):
                    inputFile = file
                    etag = e
                    lastModified = lm
                }
            } catch {
                cacheManager.discard(tempDir: tempDir)
                return .failure(PigeonError(
                    code: "DOWNLOAD_ERROR",
                    message: "Failed to download image: \(error)",
                    details: nil
                ))
            }
        }

        // Split the image into chunks.
        let output: ImageSplitter.Output
        do {
            output = try splitter.split(
                sourceFile: inputFile,
                outDirectory: tempDir,
                maxChunkHeight: maxChunkHeight
            )
        } catch ImageSplitter.SplitError.widthTooLarge(let w, let max) {
            cacheManager.discard(tempDir: tempDir)
            return .failure(PigeonError(
                code: "WIDTH_TOO_LARGE",
                message: "Image width (\(w)) exceeds maxChunkHeight (\(max)). " +
                         "Horizontal split is not supported in this version.",
                details: nil
            ))
        } catch ImageSplitter.SplitError.decodeError(let msg) {
            cacheManager.discard(tempDir: tempDir)
            return .failure(PigeonError(code: "DECODE_ERROR", message: msg, details: nil))
        } catch ImageSplitter.SplitError.splitError(let msg) {
            cacheManager.discard(tempDir: tempDir)
            return .failure(PigeonError(code: "SPLIT_ERROR", message: msg, details: nil))
        } catch {
            cacheManager.discard(tempDir: tempDir)
            return .failure(PigeonError(
                code: "SPLIT_ERROR",
                message: "\(error)",
                details: nil
            ))
        }

        // Persist metadata.
        let meta = CacheMeta(
            etag: etag,
            lastModified: lastModified,
            chunkHeights: output.chunkHeights,
            imageWidth: output.imageWidth
        )
        do {
            try MetaFile.write(
                meta: meta,
                to: (tempDir as NSString).appendingPathComponent("meta.json")
            )
        } catch {
            cacheManager.discard(tempDir: tempDir)
            return .failure(PigeonError(
                code: "SPLIT_ERROR",
                message: "Failed to write meta: \(error)",
                details: nil
            ))
        }

        // Remove the original download blob (chunks already written).
        if !isLocalSource(source) {
            try? FileManager.default.removeItem(atPath: inputFile)
        }

        // Atomic commit.
        let finalDir: String
        do {
            finalDir = try cacheManager.commit(tempDir: tempDir, key: key)
        } catch {
            cacheManager.discard(tempDir: tempDir)
            return .failure(PigeonError(
                code: "SPLIT_ERROR",
                message: "Failed to commit cache: \(error)",
                details: nil
            ))
        }

        // Rewrite paths to point at the final location.
        let finalPaths = (0..<output.chunkHeights.count).map {
            (finalDir as NSString).appendingPathComponent("chunk_\($0).jpg")
        }

        return .success(SplitResult(
            paths: finalPaths,
            fromCache: false,
            etag: etag,
            lastModified: lastModified,
            chunkHeights: output.chunkHeights.map { Int64($0) },
            imageWidth: Int64(output.imageWidth)
        ))
    }

    func clearCache(completion: @escaping (Result<Int64, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(.success(0))
                return
            }
            do {
                let count = try self.cacheManager.clearAll()
                completion(.success(count))
            } catch {
                completion(.failure(PigeonError(
                    code: "CLEAR_CACHE_ERROR",
                    message: "\(error)",
                    details: nil
                )))
            }
        }
    }

    func getMaxTextureSize(completion: @escaping (Result<Int64, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(.success(4096))
                return
            }
            let value = self.stateQueue.sync { () -> Int in
                if let cached = self.cachedMaxTextureSize {
                    return cached
                }
                let probed = MaxTextureSizeProbe.query()
                self.cachedMaxTextureSize = probed
                return probed
            }
            completion(.success(Int64(value)))
        }
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private func isLocalSource(_ source: String) -> Bool {
        return source.hasPrefix("file://") || source.hasPrefix("/")
    }

    private func resolveLocalPath(_ source: String) -> String {
        if source.hasPrefix("file://") {
            return URL(string: source)?.path ?? String(source.dropFirst("file://".count))
        }
        return source
    }
}

private extension CachedEntry {
    func toSplitResult(fromCache: Bool) -> SplitResult {
        return SplitResult(
            paths: paths,
            fromCache: fromCache,
            etag: meta.etag,
            lastModified: meta.lastModified,
            chunkHeights: meta.chunkHeights.map { Int64($0) },
            imageWidth: Int64(meta.imageWidth)
        )
    }
}
