import Foundation

/// Local OCR status and installation (/runtime/status, /runtime/install). Streamed through
/// URLSessionDataDelegate, not bytes(for:).lines. Event names must match RuntimeEvent in
/// api/sse.py; unknown events are dropped silently.
final class RuntimeClient: NSObject, @unchecked Sendable {

    /// The fields the UI needs; per-tier details stay in the backend.
    struct Status: Equatable {
        var available: Bool
        /// override / component / legacy
        var tier: String?
        var root: String?
        /// legacy deployment complete, no component yet: can be migrated offline
        var migratable: Bool
        /// Why the override set in Settings doesn't work. Installing won't help (the backend answers 409),
        /// so the UI asks to clear the field.
        var overrideProblem: String?

        init(available: Bool, tier: String? = nil, root: String? = nil, migratable: Bool = false,
             overrideProblem: String? = nil) {
            self.available = available
            self.tier = tier
            self.root = root
            self.migratable = migratable
            self.overrideProblem = overrideProblem
        }

        init?(json: [String: Any]) {
            guard let available = json["available"] as? Bool else { return nil }
            let active = json["active"] as? [String: Any]
            let candidates = json["candidates"] as? [[String: Any]] ?? []
            let override = candidates.first { $0["tier"] as? String == "override" }
            self.init(available: available, tier: active?["tier"] as? String,
                      root: active?["root"] as? String,
                      migratable: json["migratable"] as? Bool ?? false,
                      overrideProblem: available ? nil : override?["problem"] as? String)
        }
    }

    enum Method: String {
        case download, migrate
    }

    enum Event: Equatable {
        case meta(jobID: String, method: String)
        case step(index: Int, total: Int, key: String, label: String)
        /// nil `unit` means bytes; the pip step counts packages
        case progress(key: String, done: Int, total: Int, unit: String?, source: String)
        /// download source switched (upstream down or slow); must be visible
        case source(key: String, from: String, to: String, reason: String)
        case log(String)
        case heartbeat(elapsed: Double)
        case done(root: String, tier: String?, elapsed: Double)
        case failed(code: String, message: String)
    }

    private let base: URL
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var continuation: AsyncStream<Event>.Continuation?
    private var buffer = Data()
    private var errorBody = Data()
    private var httpStatus = 200
    private let lock = NSLock()

    init(base: URL) {
        self.base = base
        super.init()
        let config = URLSessionConfiguration.ephemeral
        // heartbeats keep it alive; a full install on a slow network can take over an hour
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 6 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit { session?.invalidateAndCancel() }

    func status() async throws -> Status {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(backend: base.appendingPathComponent("runtime/status")))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = Status(json: json)
        else { throw OCRError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        return status
    }

    /// Failures are events too (`.failed`), never thrown, so the UI has one way to finish.
    func install(method: Method) -> AsyncStream<Event> {
        AsyncStream { continuation in
            self.continuation = continuation
            var request = URLRequest(backend: base.appendingPathComponent("runtime/install"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["method": method.rawValue])
            let task = session.dataTask(with: request)
            self.task = task
            continuation.onTermination = { [weak task] _ in task?.cancel() }
            task.resume()
        }
    }

    func cancel(jobID: String) async {
        var request = URLRequest(backend: base.appendingPathComponent("runtime/install/\(jobID)/cancel"))
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Framing

    private func drain() {
        let separator = Data("\n\n".utf8)
        while let range = buffer.range(of: separator) {
            let frame = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let text = String(data: frame, encoding: .utf8), let event = Self.decode(frame: text) {
                continuation?.yield(event)
            }
        }
    }

    /// Static so checks can feed it the event names straight from sse.py.
    static func decode(frame: String) -> Event? {
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
            return .meta(jobID: d["job_id"] as? String ?? "", method: d["method"] as? String ?? "")
        case "step":
            return .step(index: d["index"] as? Int ?? 0, total: d["total"] as? Int ?? 0,
                         key: d["key"] as? String ?? "", label: d["label"] as? String ?? "")
        case "progress":
            return .progress(key: d["key"] as? String ?? "", done: d["done"] as? Int ?? 0,
                             total: d["total"] as? Int ?? 0, unit: d["unit"] as? String,
                             source: d["source"] as? String ?? "")
        case "source":
            return .source(key: d["key"] as? String ?? "", from: d["from"] as? String ?? "",
                           to: d["to"] as? String ?? "", reason: d["reason"] as? String ?? "")
        case "log":
            return .log(d["message"] as? String ?? "")
        case "heartbeat":
            return .heartbeat(elapsed: d["elapsed"] as? Double ?? 0)
        case "done":
            return .done(root: d["root"] as? String ?? "", tier: d["tier"] as? String,
                         elapsed: d["elapsed"] as? Double ?? 0)
        case "error":
            return .failed(code: d["code"] as? String ?? "UNKNOWN", message: d["message"] as? String ?? L("未知错误", "Unknown error"))
        default:
            return nil
        }
    }
}

// MARK: - URLSessionDataDelegate

extension RuntimeClient: URLSessionDataDelegate {

    /// A non-200 body is a JSON error, not SSE (usually 409: already installing, or an override is
    /// set). Framing it as SSE would silently parse nothing.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.withLock { httpStatus = code }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        if httpStatus != 200 {
            errorBody.append(data)
            return
        }
        buffer.append(data)
        drain()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if httpStatus != 200 {
            let detail = (try? JSONSerialization.jsonObject(with: errorBody) as? [String: Any])?["detail"] as? String
            continuation?.yield(.failed(code: "HTTP_\(httpStatus)", message: detail ?? L("服务端返回 \(httpStatus)", "The service returned \(httpStatus)")))
        } else if let error, (error as NSError).code != NSURLErrorCancelled {
            continuation?.yield(.failed(code: "CONNECTION", message: error.localizedDescription))
        }
        continuation?.finish()
        continuation = nil
        buffer.removeAll()
        errorBody.removeAll()
        httpStatus = 200
    }
}
