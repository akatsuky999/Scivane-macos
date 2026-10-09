import Foundation

/// SSE client for the recognition streams (local OCR and cloud transcription). URLSessionDataDelegate
/// rather than bytes(for:).lines, which goes silent after the 200 on this path.
final class OCRClient: NSObject, @unchecked Sendable {

    /// The same events for local OCR (/ocr) and cloud transcription (/transcribe); transcription
    /// also reports usage, failed pages and a stable failure code.
    enum Event {
        case meta(jobID: String, pages: Int, filename: String)
        /// dense pages take over ten seconds; get the UI moving first
        case progress(page: Int, total: Int, elapsed: Double)
        /// keep-alive while idle; also drives the timer in the UI
        case heartbeat(page: Int, total: Int, elapsed: Double)
        case page(index: Int, total: Int, markdown: String, elapsed: Double, usage: AgentUsage?)
        case done(markdown: String, text: String, elapsed: Double, cancelled: Bool,
                  failedPages: [Int], usage: AgentUsage?)
        case failed(String, code: String?)
    }

    private let base: URL
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation?
    private var buffer = Data()
    private let lock = NSLock()

    init(base: URL) {
        self.base = base
        super.init()
        let config = URLSessionConfiguration.ephemeral
        // a fallback only: heartbeats keep it alive, and a large document can take tens of minutes
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 6 * 3600
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit { session?.invalidateAndCancel() }

    func recognise(path: String) -> AsyncThrowingStream<Event, Error> {
        stream("ocr", body: ["path": path])
    }

    /// Cloud transcription with a model card; same events, so the run queue treats both alike.
    func transcribe(path: String, provider: String) -> AsyncThrowingStream<Event, Error> {
        stream("transcribe", body: ["path": path, "provider": provider])
    }

    private func stream(_ path: String, body: [String: String]) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation

            var request = URLRequest(backend: base.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let task = session.dataTask(with: request)
            self.task = task
            continuation.onTermination = { [weak task] _ in task?.cancel() }
            task.resume()
        }
    }

    func cancel(jobID: String) async {
        var request = URLRequest(backend: base.appendingPathComponent("cancel/\(jobID)"))
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
    }

    func stop() {
        task?.cancel()
        continuation?.finish()
    }

    // MARK: - Framing

    /// Frames end with a blank line; an incomplete one stays buffered for the next chunk.
    private func drain() {
        let separator = Data("\n\n".utf8)
        while let range = buffer.range(of: separator) {
            let frame = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let text = String(data: frame, encoding: .utf8) else { continue }
            if let event = Self.decode(frame: text) {
                continuation?.yield(event)
            }
        }
    }

    private static func decode(frame: String) -> Event? {
        var name = ""
        var payload = ""
        for line in frame.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("event:") {
                name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                payload += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !name.isEmpty, let data = payload.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        switch name {
        case "meta":
            return .meta(jobID: d["job_id"] as? String ?? "",
                         pages: d["pages"] as? Int ?? 0,
                         filename: d["filename"] as? String ?? "")
        case "progress":
            return .progress(page: d["page"] as? Int ?? 0,
                             total: d["total"] as? Int ?? 0,
                             elapsed: d["elapsed"] as? Double ?? 0)
        case "heartbeat":
            return .heartbeat(page: d["page"] as? Int ?? 0,
                              total: d["total"] as? Int ?? 0,
                              elapsed: d["elapsed"] as? Double ?? 0)
        case "page":
            return .page(index: d["index"] as? Int ?? 0,
                         total: d["total"] as? Int ?? 0,
                         markdown: d["markdown"] as? String ?? "",
                         elapsed: d["elapsed"] as? Double ?? 0,
                         usage: (d["usage"] as? [String: Any]).map(AgentUsage.init))
        case "done":
            return .done(markdown: d["markdown"] as? String ?? "",
                         text: d["text"] as? String ?? "",
                         elapsed: d["elapsed"] as? Double ?? 0,
                         cancelled: d["cancelled"] as? Bool ?? false,
                         failedPages: d["failed_pages"] as? [Int] ?? [],
                         usage: (d["usage"] as? [String: Any]).map(AgentUsage.init))
        case "error":
            return .failed(d["message"] as? String ?? L("未知错误", "Unknown error"),
                           code: d["code"] as? String)
        default:
            return nil
        }
    }
}

// MARK: - URLSessionDataDelegate

extension OCRClient: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            continuation?.finish(throwing: OCRError.http(code))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        drain()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}

enum OCRError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(let code): return L("后端返回 HTTP \(code)", "The backend returned HTTP \(code)")
        }
    }
}
