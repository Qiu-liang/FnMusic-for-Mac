import Foundation
import OSLog

// No UI dependencies. All JSON, artwork and media reads share this transport.
enum APIError: Error, LocalizedError, Equatable, Sendable {
    case invalidServer, network, http(Int), business(Int), decoding, unexpectedContent, sessionExpired
    case invalidRange, unsupportedAudio, keychain(Int32), unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidServer: "请输入 http:// 或 https:// 开头的服务器地址（不含用户名、密码或查询参数）。"
        case .network: "无法连接服务器，请检查网络与服务器地址。"
        case .http(let status): "服务器返回 HTTP \(status)。"
        case .business(let code): "服务器拒绝请求（业务码 \(code)）。"
        case .decoding: "服务器数据格式与当前 API 契约不兼容。"
        case .unexpectedContent: "服务器返回了非预期内容，请确认地址指向飞牛音乐服务。"
        case .sessionExpired: "登录会话已失效，请重新登录。"
        case .invalidRange: "服务器未返回有效的音频字节范围，无法安全定位播放。"
        case .unsupportedAudio: "当前音频无法原生播放。尚未启用未经验证的转码接口。"
        case .keychain(let status): "无法访问钥匙串（\(status)）。"
        case .unavailable(let explanation): explanation
        }
    }
}

enum CachePolicy: Sendable {
    case network
    case memory(maxAge: TimeInterval)
}

struct APIRequest: Sendable {
    enum Method: String, Sendable { case get = "GET", post = "POST" }
    var path: String
    var method: Method = .get
    var query: [String: String] = [:]
    var body: Data?
    var authenticated = true
    var cachePolicy: CachePolicy = .network

    static func post<Body: Encodable>(
        _ path: String, body: Body, authenticated: Bool = true
    ) throws -> APIRequest {
        APIRequest(path: path, method: .post, body: try JSONEncoder().encode(body), authenticated: authenticated)
    }
}

struct APIEnvelope<Value: Decodable>: Decodable {
    let code: Int
    let msg: String?
    let data: Value?
}
private struct BusinessStatus: Decodable { let code: Int }
struct EmptyBody: Codable, Sendable {}
struct MediaChunk: Sendable {
    let data: Data
    let mimeType: String
    let totalLength: Int64
    let rangeStart: Int64
    let supportsRanges: Bool
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Even same-host redirects may change scheme/port. Require the user to
        // configure the final origin rather than risk forwarding credentials.
        completionHandler(nil)
    }
}

actor APIClient {
    let origin: URL
    private var token: String?
    private let session: URLSession
    private let ownsSession: Bool
    private var isClosed = false
    private var invalidation: (@Sendable () async -> Void)?
    private struct CachedJSON { let date: Date; let data: Data }
    private var jsonCache: [URL: CachedJSON] = [:]
    private let logger = Logger(subsystem: "dev.fnmusic.mac", category: "API")

    static func serverURL(_ text: String) throws -> URL {
        guard var components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              ["", "/", "/music", "/music/"].contains(components.path) else { throw APIError.invalidServer }
        components.scheme = scheme
        components.path = ""
        guard let url = components.url else { throw APIError.invalidServer }
        return url
    }

    init(origin: URL, token: String? = nil, session: URLSession? = nil) {
        self.origin = origin
        self.token = token
        self.ownsSession = session == nil
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 90
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCache = nil
            self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    func setToken(_ value: String?) { token = value; jsonCache.removeAll() }
    func clearCache() { jsonCache.removeAll() }
    func close() {
        guard !isClosed else { return }
        isClosed = true
        token = nil
        jsonCache.removeAll()
        invalidation = nil
        if ownsSession { session.invalidateAndCancel() }
    }

    /// Seal the old transport immediately. The only new transport carrying the
    /// captured token is scoped to the user's explicit logout request.
    func logoutTransport() -> APIClient? {
        let previousToken = token
        close()
        guard let previousToken else { return nil }
        return APIClient(origin: origin, token: previousToken)
    }
    func hasSession() -> Bool { !isClosed && token?.isEmpty == false }
    func onSessionInvalidated(_ handler: @escaping @Sendable () async -> Void) { invalidation = handler }

    func url(for request: APIRequest) throws -> URL {
        guard request.path.hasPrefix("/"), !request.path.contains(".."),
              !request.path.contains("?"), !request.path.contains("#"),
              var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidServer
        }
        components.path = "/music/api/v1" + request.path
        components.queryItems = request.query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw APIError.invalidServer }
        return url
    }

    private func makeRequest(_ spec: APIRequest, accept: String) throws -> URLRequest {
        guard !isClosed else { throw CancellationError() }
        var request = URLRequest(url: try url(for: spec))
        request.httpMethod = spec.method.rawValue
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body = spec.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if spec.authenticated {
            guard let token, !token.isEmpty,
                  !token.contains("\r"), !token.contains("\n"), !token.contains(";") else {
                throw APIError.sessionExpired
            }
            request.setValue("music-token=\(token)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    func value<Value: Decodable & Sendable>(_ spec: APIRequest, as: Value.Type = Value.self) async throws -> Value {
        let request = try makeRequest(spec, accept: "application/json")
        if spec.method == .get, case .memory(let age) = spec.cachePolicy,
           let url = request.url, let cached = jsonCache[url], Date().timeIntervalSince(cached.date) < age,
           let value = try? JSONDecoder().decode(APIEnvelope<Value>.self, from: cached.data).data {
            try Task.checkCancellation()
            return value
        }
        let (data, response) = try await send(request, retry: spec.method == .get)
        try await validate(data, response: response, json: true)
        if spec.method == .post { jsonCache.removeAll() }
        if spec.method == .get, case .memory = spec.cachePolicy, let url = request.url, data.count <= 1_048_576 {
            while jsonCache.count >= 48 || jsonCache.values.reduce(0, { $0 + $1.data.count }) + data.count > 8_388_608 {
                guard let oldest = jsonCache.min(by: { $0.value.date < $1.value.date })?.key else { break }
                jsonCache.removeValue(forKey: oldest)
            }
            jsonCache[url] = CachedJSON(date: Date(), data: data)
        }
        do {
            let envelope = try JSONDecoder().decode(APIEnvelope<Value>.self, from: data)
            guard let value = envelope.data else { throw APIError.decoding }
            return value
        } catch let error as APIError { throw error }
        catch { throw APIError.decoding }
    }

    /// Mutations may return null or undocumented data. Validate the envelope
    /// without inventing a success payload. Never automatically retry a POST.
    func perform(_ spec: APIRequest) async throws {
        let (data, response) = try await send(try makeRequest(spec, accept: "application/json"), retry: false)
        try await validate(data, response: response, json: true)
        jsonCache.removeAll()
    }

    func cover(id: String, size: Int) async throws -> Data {
        let spec = APIRequest(path: "/static/cover", query: ["coverId": id, "size": String(size)])
        let (data, response) = try await send(try makeRequest(spec, accept: "image/*"), retry: true)
        try await validate(data, response: response, json: false)
        guard response.mimeType?.hasPrefix("image/") == true else { throw APIError.unexpectedContent }
        return data
    }

    func stream(guid: String, offset: Int64, length: Int) async throws -> MediaChunk {
        guard offset >= 0, length > 0, length <= 2_097_152 else { throw APIError.invalidRange }
        let spec = APIRequest(path: "/track/stream", query: ["guid": guid])
        var request = try makeRequest(spec, accept: "audio/*, application/octet-stream")
        let (end, overflow) = offset.addingReportingOverflow(Int64(length) - 1)
        guard !overflow else { throw APIError.invalidRange }
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await sendMediaRange(request, limit: length)
        try await validate(data, response: response, json: false)
        let mime = response.mimeType ?? "application/octet-stream"
        guard mime.hasPrefix("audio/") || ["application/octet-stream", "video/mp4"].contains(mime) else {
            throw APIError.unexpectedContent
        }
        guard response.statusCode == 206,
              let range = response.value(forHTTPHeaderField: "Content-Range"),
              let parsed = Self.parseContentRange(range), parsed.start == offset,
              parsed.end - parsed.start + 1 == Int64(data.count) else { throw APIError.invalidRange }
        return MediaChunk(data: data, mimeType: mime, totalLength: parsed.total, rangeStart: parsed.start, supportsRanges: true)
    }

    /// Inspect headers before buffering: a server ignoring Range must not cause
    /// the entire audio file to be downloaded into memory.
    private func sendMediaRange(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw APIError.network }
            if http.statusCode == 401 {
                try await validate(Data(), response: http, json: false)
            }
            let isJSON = http.mimeType?.contains("json") == true
            if !isJSON && http.statusCode != 206 {
                if !(200..<300).contains(http.statusCode) { throw APIError.http(http.statusCode) }
                throw APIError.invalidRange
            }
            let cap = isJSON ? 65_536 : limit
            var data = Data()
            data.reserveCapacity(min(cap, 524_288))
            for try await byte in bytes {
                if data.count >= cap { throw APIError.invalidRange }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw APIError.network
        }
    }

    static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/")
        guard parts.count == 2, let total = Int64(parts[1]), total > 0 else { return nil }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }

    private func send(_ request: URLRequest, retry: Bool) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...(retry ? 1 : 0) {
            try Task.checkCancellation()
            guard !isClosed else { throw CancellationError() }
            do {
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse else { throw APIError.network }
                let cap = request.value(forHTTPHeaderField: "Accept") == "image/*" ? 20_971_520 : 33_554_432
                if response.expectedContentLength > Int64(cap) {
                    throw APIError.unavailable("服务器响应超过客户端安全大小上限。")
                }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < cap else { throw APIError.unavailable("服务器响应超过客户端安全大小上限。") }
                    data.append(byte)
                }
                try Task.checkCancellation()
                guard !isClosed else { throw CancellationError() }
                #if DEBUG
                logger.debug("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.path ?? "", privacy: .public) HTTP \(http.statusCode)")
                #endif
                return (data, http)
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                if retry && attempt == 0 && [.timedOut, .networkConnectionLost].contains(error.code) {
                    try await Task.sleep(for: .milliseconds(350))
                    continue
                }
                throw APIError.network
            }
        }
        throw APIError.network
    }

    private func validate(_ data: Data, response: HTTPURLResponse, json: Bool) async throws {
        if response.statusCode == 401 {
            token = nil
            await invalidation?()
            throw APIError.sessionExpired
        }
        guard (200..<300).contains(response.statusCode) else { throw APIError.http(response.statusCode) }
        let isJSON = response.mimeType?.lowercased().contains("json") == true
        if json && !isJSON { throw APIError.unexpectedContent }
        if isJSON {
            guard let status = try? JSONDecoder().decode(BusinessStatus.self, from: data) else { throw APIError.decoding }
            #if DEBUG
            logger.debug("business code = \(status.code)")
            #endif
            if status.code == 99999 {
                token = nil
                await invalidation?()
                throw APIError.sessionExpired
            }
            guard [0, 200].contains(status.code) else { throw APIError.business(status.code) }
            if !json { throw APIError.unexpectedContent }
        }
    }
}
