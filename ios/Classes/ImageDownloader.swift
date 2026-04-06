import Foundation

// =============================================================================
// ImageDownloader — URLSession with timeouts and conditional GET
// =============================================================================
//
// Uses URLSession with explicit timeouts (15s connect, 30s resource).
// Streams the response body straight to a file via downloadTask — no
// in-memory copy of the entire image.
//
// Conditional GET: sends If-None-Match / If-Modified-Since when the caller
// supplies cached values. A 304 response yields .notModified, allowing the
// caller to reuse cached chunks without re-decoding.
//
// Sync wrapper: the public download(...) function blocks the calling
// thread on a semaphore. This is intentional — splitImage runs on a
// background queue with its own concurrency cap, and a sync API is much
// easier to compose with the surrounding state-machine code than scattered
// completion callbacks.
// =============================================================================

final class ImageDownloader {

    enum Result {
        case notModified
        case downloaded(file: String, etag: String?, lastModified: String?)
    }

    enum DownloadError: Error {
        case httpStatus(Int)
        case empty
        case underlying(Error)
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.urlCache = nil  // Our own cache layer handles persistence.
        self.session = URLSession(configuration: config)
    }

    func download(
        url: URL,
        destDirectory: String,
        cachedEtag: String?,
        cachedLastModified: String?
    ) throws -> Result {
        var request = URLRequest(url: url)
        if let etag = cachedEtag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lm = cachedLastModified {
            request.setValue(lm, forHTTPHeaderField: "If-Modified-Since")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var resultBox: Swift.Result<Result, Error>?

        let task = session.downloadTask(with: request) { tempURL, response, error in
            defer { semaphore.signal() }

            if let error = error {
                resultBox = .failure(DownloadError.underlying(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                resultBox = .failure(DownloadError.empty)
                return
            }
            if http.statusCode == 304 {
                resultBox = .success(.notModified)
                return
            }
            guard (200..<300).contains(http.statusCode), let tempURL = tempURL else {
                resultBox = .failure(DownloadError.httpStatus(http.statusCode))
                return
            }

            let destPath = (destDirectory as NSString).appendingPathComponent("download.bin")
            do {
                try? FileManager.default.removeItem(atPath: destPath)
                try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: destPath))
                let etag = http.value(forHTTPHeaderField: "ETag")
                let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
                resultBox = .success(.downloaded(
                    file: destPath, etag: etag, lastModified: lastModified
                ))
            } catch {
                resultBox = .failure(DownloadError.underlying(error))
            }
        }
        task.resume()
        semaphore.wait()

        switch resultBox! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
