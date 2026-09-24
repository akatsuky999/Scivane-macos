import Foundation

/// 本地 OCR 组件的状态与安装（`/runtime/status`、`/runtime/install`）。
///
/// 流用 URLSessionDataDelegate 收，**不用 `bytes(for:).lines`** —— 那个 API 在这条链路上
/// 拿到 200 之后彻底静默。事件名是跨语言契约，定义在 `api/sse.py`
/// 的 `RuntimeEvent`：两边的名字必须一起改，对不上的事件会被静静丢掉。
final class RuntimeClient: NSObject, @unchecked Sendable {

    /// `/runtime/status` 里界面要用的那几项。其余字段（每一档缺什么）留在后端。
    struct Status: Equatable {
        var available: Bool
        /// 在用的那一档：override / component / legacy
        var tier: String?
        var root: String?
        /// 旧部署齐、组件还没有 —— 可以不联网地迁过来
        var migratable: Bool
        /// 设置页里指定了位置（覆盖档）却用不了时，那一档的问题。此时装组件也没用 ——
        /// 覆盖档设了就只看它，后端会拒绝安装（409），所以界面要说「先清掉那一栏」
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
        /// `unit` 为空表示字节；pip 那一步是「包」
        case progress(key: String, done: Int, total: Int, unit: String?, source: String)
        /// 换了下载来源 —— 上游不通或太慢换镜像时发，界面要让人看得见
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
        // 有心跳保活；整个安装在慢网络上可能要一个多小时
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

    /// 流式安装。**失败也走流**（`.failed`），不抛 —— 界面只需要处理一种收尾。
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

    // MARK: - 分帧

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

    /// 一帧 SSE → 事件。静态的，验证脚本直接拿 sse.py 里的事件名喂它。
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

    /// 非 200 的响应体是一段 JSON 错误，不是 SSE（最常见的是 409：已经有一个在装、
    /// 或者设了覆盖档）。当成 SSE 去分帧只会静静地什么都解析不出来 —— 同 AgentClient。
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
