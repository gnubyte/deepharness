import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - The local API server
//
// Other programs on this Mac may want the harness's default model — a script,
// an editor plugin, a cron job — without each configuring its own provider.
// This server exposes a small, OpenAI-shaped endpoint on 127.0.0.1 that always
// routes to whatever the harness currently has as its main model, live: change
// the model in the app and the next request follows.
//
//   GET  /health               → {"status":"ok","model":"…"}
//   GET  /v1/models            → OpenAI-style list (one entry: the default)
//   POST /v1/chat/completions  → OpenAI-style completion
//
// The socket is bound to 127.0.0.1 with the BSD layer — nothing off this
// machine can even reach the port, and it needs no authentication. (NWListener
// cannot bind a listener to a single address; BSD sockets can.)

/// An OpenAI-compatible endpoint over the harness's default model.
public final class LocalAPIServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listenSocket: Int32 = -1
    private var running = false
    private var _lastError: String?
    private var acceptQueue: DispatchQueue?

    /// The port to bind; `0` picks a free one.
    public let requestedPort: UInt16
    /// Returns the profile to serve per request — the app hands in a closure
    /// that reads the live configuration, so model changes apply at once.
    private let provider: @Sendable () -> ProviderProfile?

    public private(set) var boundPort: UInt16?

    public var isRunning: Bool { lock.withLock { running } }
    public var lastError: String? { lock.withLock { _lastError } }

    public init(port: UInt16, provider: @escaping @Sendable () -> ProviderProfile?) {
        self.requestedPort = port
        self.provider = provider
    }

    // MARK: Lifecycle

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }

        // The listening socket: loopback IPv4 only.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServerError.cannotBind("socket() failed: errno \(errno)")
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requestedPort.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.cannotBind("could not bind 127.0.0.1:\(requestedPort) — errno \(errno)")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw ServerError.cannotBind("listen() failed — errno \(errno)")
        }
        // Which port did we actually get (a 0 request picks a free one)?
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &len)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw ServerError.cannotBind("getsockname failed — errno \(errno)")
        }
        self.listenSocket = fd
        self.running = true
        self.boundPort = UInt16(bigEndian: bound.sin_port)

        // Accept on a serial queue; each connection is handled on its own.
        let queue = DispatchQueue(label: "dsh.api.server", target: .global())
        self.acceptQueue = queue
        let serverFD = fd
        let provider = self.provider
        queue.async { [weak self] in
            while true {
                guard let self, self.isRunning else { break }
                var clientAddr = sockaddr()
                var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
                let client = accept(serverFD, &clientAddr, &clientLen)
                guard client >= 0 else {
                    // EINTR/ECONNABORTED are ordinary; anything persistent ends the loop.
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    break
                }
                // Refuse anything not arriving from the loopback interface.
                if clientAddr.sa_family == sa_family_t(AF_INET) {
                    let remote = withUnsafeBytes(of: clientAddr.sa_data) { raw -> UInt32 in
                        // sa_data[2..5] holds the big-endian IPv4 address.
                        let bytes = raw.bindMemory(to: UInt8.self)
                        return UInt32(bytes[2]) << 24 | UInt32(bytes[3]) << 16
                            | UInt32(bytes[4]) << 8 | UInt32(bytes[5])
                    }
                    if remote >> 24 != 127 {
                        close(client)
                        continue
                    }
                }
                let handler = ConnectionHandler(socket: client, provider: provider)
                Task.detached {
                    await handler.handle()
                }
            }
        }
    }

    public func stop() {
        lock.lock()
        let fd = self.listenSocket
        self.listenSocket = -1
        self.running = false
        self.boundPort = nil
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    public enum ServerError: LocalizedError {
        case cannotBind(String)
        public var errorDescription: String? {
            switch self {
            case .cannotBind(let why): return "The local API server couldn't start: \(why)"
            }
        }
    }

    /// One accepted connection: read the request (headers + Content-Length
    /// body), route it, write the response, close. Bounded at ~10 MB so a
    /// malformed length can't exhaust memory.
    struct ConnectionHandler: Sendable {
        let socket: Int32
        let provider: @Sendable () -> ProviderProfile?

        static let maxRequestBytes = 10 << 20

        func handle() async {
            defer { Darwin.close(socket) }
            var buffer = Data()
            // Read until the full header block has arrived.
            while LocalAPIServer.splitHTTP(buffer) == nil {
                guard buffer.count < Self.maxRequestBytes else { return }
                guard let chunk = readChunk() else { return }
                buffer.append(chunk)
            }
            guard let (head, body) = LocalAPIServer.splitHTTP(buffer) else { return }
            var request = HTTPRequest(head: head, body: body)
            // Drain the declared body when it arrives across reads.
            while request.body.count < request.contentLength {
                guard request.body.count < Self.maxRequestBytes else { return }
                guard let chunk = readChunk() else { return }
                buffer.append(chunk)
                guard let (newHead, newBody) = LocalAPIServer.splitHTTP(buffer) else { return }
                request = HTTPRequest(head: newHead, body: newBody)
            }
            let response = await LocalAPIServer.route(request: request, provider: provider)
            response.withUnsafeBytes { raw in
                var offset = 0
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                while offset < response.count {
                    let sent = Darwin.send(socket, base + offset, response.count - offset, 0)
                    if sent <= 0 { break }
                    offset += sent
                }
            }
        }

        /// One recv; nil when the peer closed or errored.
        private func readChunk() -> Data? {
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = Darwin.recv(socket, &chunk, chunk.count, 0)
            guard n > 0 else { return nil }
            return Data(chunk[0..<n])
        }
    }

    /// Split a buffered request into head + body once the full header block
    /// (and ideally the body) has arrived. Nil = keep buffering.
    static func splitHTTP(_ buffer: Data) -> (head: Data, body: Data)? {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: marker) else { return nil }
        let head = buffer[..<range.lowerBound]
        let body = buffer[range.upperBound...]
        return (Data(head), Data(body))
    }
    struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        init(head: Data, body: Data) {
            let text = String(decoding: head, as: UTF8.self)
            var lines = text.components(separatedBy: "\r\n")
            let requestLine = lines.first ?? ""
            let parts = requestLine.split(separator: " ").map(String.init)
            method = parts.first ?? ""
            path = parts.count > 1 ? parts[1] : "/"
            lines.removeFirst()
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
            self.headers = headers
            self.body = body
        }

        var contentLength: Int { Int(headers["content-length"] ?? "0") ?? 0 }
    }

    // MARK: Handlers

    static func response(_ status: String, _ contentType: String, _ body: Data) -> Data {
        Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            + body
    }

    static func json(_ status: String, _ object: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return response(status, "application/json", data)
    }

    /// Route one request. Static so it is testable without a socket.
    static func route(request: HTTPRequest, provider: @Sendable () -> ProviderProfile?) async -> Data {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        switch (request.method, path) {
        case ("GET", "/health"):
            let model = provider()?.model
            return json("200 OK", ["status": "ok", "model": model as Any? ?? NSNull(), "server": "dsh"])
        case ("GET", "/v1/models"):
            guard let profile = provider() else {
                return json("503 Service Unavailable", ["error": ["message": "No model is configured.", "type": "server_error"]])
            }
            return json("200 OK", [
                "object": "list",
                "data": [["id": profile.model, "object": "model", "owned_by": "dsh"]],
            ])
        case ("POST", "/v1/chat/completions"):
            return await handleCompletion(request, provider)
        case (_, "/health"), (_, "/v1/models"), (_, "/v1/chat/completions"):
            return json("405 Method Not Allowed", ["error": ["message": "Wrong method for \(path)", "type": "invalid_request_error"]])
        default:
            return json("404 Not Found", ["error": ["message": "Unknown path \(path)", "type": "invalid_request_error"]])
        }
    }

    /// The completion endpoint: translate OpenAI's request shape to the
    /// harness's LLMRequest and stream the answer back (buffered or SSE).
    static func handleCompletion(_ request: HTTPRequest, _ provider: @Sendable () -> ProviderProfile?) async -> Data {
        guard let profile = provider() else {
            return json("503 Service Unavailable", ["error": ["message": "No model is configured.", "type": "server_error"]])
        }
        struct CompletionRequest: Decodable {
            struct Part: Decodable { var type: String?; var text: String? }
            struct Message: Decodable {
                var role: String?
                var content: FlexContent?
            }
            /// `content` is a string or an array of typed parts.
            struct FlexContent: Decodable {
                var text: String?
                var parts: [Part]?
                init(from decoder: Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    if let s = try? c.decode(String.self) { text = s; parts = nil; return }
                    parts = try? c.decode([Part].self)
                    text = nil
                }
                var flattened: String {
                    if let text { return text }
                    return (parts ?? []).compactMap { $0.text }.joined(separator: "\n")
                }
            }
            var model: String?
            var messages: [Message]?
            var stream: Bool?
            var temperature: Double?
            var max_tokens: Int?
            var system: String?
        }
        guard let parsed = try? JSONDecoder().decode(CompletionRequest.self, from: request.body) else {
            return json("400 Bad Request", ["error": ["message": "Body is not a chat completion request.", "type": "invalid_request_error"]])
        }
        let incoming = (parsed.messages ?? []).map { message -> LLMMessage in
            switch message.role {
            case "assistant": return .assistant(message.content?.flattened ?? "")
            case "system": return .system(message.content?.flattened ?? "")
            default: return .user(message.content?.flattened ?? "")
            }
        }
        // A top-level `system` (some clients send it) becomes the system prompt.
        var systemPrompt = parsed.system ?? ""
        var messages = incoming
        if let firstSystem = messages.first, firstSystem.role == .system {
            if systemPrompt.isEmpty { systemPrompt = firstSystem.content ?? "" }
            messages.removeFirst()
        }
        let llmRequest = LLMRequest(systemPrompt: systemPrompt, messages: messages, tools: [],
                                    model: profile.model, temperature: parsed.temperature,
                                    maxTokens: parsed.max_tokens, thinking: nil)
        let client = ProviderClients.make(profile)
        let id = "chatcmpl-dsh-\(UUID().uuidString.prefix(8))"
        let created = Int(Date().timeIntervalSince1970)

        var text = ""
        var usage: LLMUsage?
        do {
            for try await event in client.stream(llmRequest) {
                if case .text(let delta) = event { text += delta }
                if case .done(_, _, let u, _) = event { usage = u }
            }
        } catch {
            return json("502 Bad Gateway", [
                "error": ["message": "The model call failed: \(error.localizedDescription)", "type": "server_error"],
            ])
        }

        if parsed.stream == true {
            var buffer = Data()
            buffer += Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8)
            // Chunk the finished text in slices, the SSE shape clients expect.
            for start in stride(from: 0, to: text.count, by: 256) {
                let end = min(start + 256, text.count)
                let slice = String(Array(text)[start..<end])
                let chunk: [String: Any] = [
                    "id": id, "object": "chat.completion.chunk", "created": created, "model": profile.model,
                    "choices": [["index": 0, "delta": ["content": slice], "finish_reason": NSNull()]],
                ]
                if let data = try? JSONSerialization.data(withJSONObject: chunk) {
                    buffer += Data("data: ".utf8) + data + Data("\n\n".utf8)
                }
            }
            let final: [String: Any] = [
                "id": id, "object": "chat.completion.chunk", "created": created, "model": profile.model,
                "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: final) {
                buffer += Data("data: ".utf8) + data + Data("\n\ndata: [DONE]\n\n".utf8)
            }
            return buffer
        }

        let promptTokens = usage?.promptTokens ?? (systemPrompt.count + messages.map { ($0.content ?? "").count }.reduce(0, +)) / 4
        let completionTokens = usage?.completionTokens ?? (text.count / 4)
        return json("200 OK", [
            "id": id, "object": "chat.completion", "created": created, "model": profile.model,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": text],
                "finish_reason": "stop",
            ]],
            "usage": ["prompt_tokens": promptTokens, "completion_tokens": completionTokens,
                      "total_tokens": promptTokens + completionTokens],
        ])
    }
}
