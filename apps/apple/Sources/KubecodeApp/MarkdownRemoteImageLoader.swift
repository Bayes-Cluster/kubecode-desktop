import AppKit
import Foundation
import KubecodeMarkdown
import KubecodeKit

struct MarkdownProjectResourceContext: Sendable {
    let identity: String
    let projectID: String
    let client: RuntimeClient

    func data(for path: String) async -> Data? {
        try? await client.readAsset(projectID: projectID, path: path)
    }
}

actor MarkdownRemoteImageLoader {
    static let shared = MarkdownRemoteImageLoader()

    private let session: URLSession
    private let redirectDelegate: MarkdownImageRedirectDelegate
    private var cache: [URL: Data] = [:]
    private var cacheOrder: [URL] = []
    private var cacheBytes = 0
    private let maximumCacheBytes = 32 * 1_024 * 1_024

    init() {
        let redirectDelegate = MarkdownImageRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        self.redirectDelegate = redirectDelegate
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    func data(for url: URL) async -> Data? {
        if let cached = cache[url] {
            touch(url)
            return cached
        }

        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  response.url?.scheme?.lowercased() == "https",
                  response.mimeType?.lowercased().hasPrefix("image/") == true,
                  response.expectedContentLength <= Int64(MarkdownResourcePolicy.maximumRemoteImageBytes)
                    || response.expectedContentLength == -1
            else { return nil }

            var value = Data()
            value.reserveCapacity(max(0, min(
                Int(response.expectedContentLength),
                MarkdownResourcePolicy.maximumRemoteImageBytes
            )))
            for try await byte in bytes {
                guard value.count < MarkdownResourcePolicy.maximumRemoteImageBytes else { return nil }
                value.append(byte)
            }
            guard !value.isEmpty else { return nil }
            insert(value, for: url)
            return value
        } catch {
            return nil
        }
    }

    private func insert(_ data: Data, for url: URL) {
        if let previous = cache.updateValue(data, forKey: url) {
            cacheBytes -= previous.count
        }
        cacheBytes += data.count
        touch(url)
        while cacheBytes > maximumCacheBytes, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                cacheBytes -= removed.count
            }
        }
    }

    private func touch(_ url: URL) {
        cacheOrder.removeAll { $0 == url }
        cacheOrder.append(url)
    }
}

private final class MarkdownImageRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirectCounts: [Int: Int] = [:]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let count = redirectCounts[task.taskIdentifier, default: 0] + 1
        redirectCounts[task.taskIdentifier] = count
        lock.unlock()

        guard count <= 3,
              MarkdownResourcePolicy.remoteImageURL(request.url?.absoluteString) != nil
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        lock.lock()
        redirectCounts.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }
}

@MainActor
enum MarkdownRemoteImageDecoder {
    static func image(from data: Data) -> NSImage? {
        let representations = NSBitmapImageRep.imageReps(with: data)
        guard !representations.isEmpty,
              representations.allSatisfy({ representation in
                  let width = representation.pixelsWide
                  let height = representation.pixelsHigh
                  guard width > 0, height > 0 else { return false }
                  return width <= MarkdownResourcePolicy.maximumDecodedImagePixels / height
              })
        else { return nil }
        return NSImage(data: data)
    }
}
