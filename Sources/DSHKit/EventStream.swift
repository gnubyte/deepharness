import Foundation

/// One decoded downstream frame: the MuxFrame/HostFrame payload plus the
/// rpcId that carried it. rpcId matters because answerable frames
/// (approval/question requested) echo it back on the response.
public struct Frame: Sendable {
    public let rpcId: RpcId
    public let method: String
    public let payload: JSONValue

    /// The frame's own discriminant, e.g. `session/event`, `host/session-added`.
    public var type: String? { payload["type"]?.stringValue }
    public var sessionId: String? { payload["sessionId"]?.stringValue }

    /// For `session/event` frames: the wrapped SessionEvent.
    public var event: JSONValue? { payload["event"] }
    /// Host-computed render intent riding alongside a `tool/call` or
    /// `tool/result`. Never persisted, so it may differ between deliveries.
    public var view: JSONValue? { payload["view"] }
    /// For `session/event` frames: the SessionEvent's own type, e.g. `assistant/chunk`.
    public var eventType: String? { event?["type"]?.stringValue }
    public var seq: Int? { event?["seq"]?.intValue }
}

/// Which downstream stream to open.
public enum StreamKind: String, Sendable {
    /// All-session aggregated stream: session events, approvals, questions, queue, projections.
    case mux = "events.mux"
    /// Host-level stream: session create/destroy, running-status flips, workspaces.
    case host = "events.host"
}

/// A reconnecting WebSocket carrier for one downstream stream.
///
/// The contract states reconnection semantics plainly: `since` is unimplemented
/// in v1, so recovery is "reopen the stream + refetch history". This type
/// therefore reconnects the socket and signals `.reconnected` so the caller can
/// re-baseline, rather than pretending to resume a cursor.
public actor EventStream {
    public enum Signal: Sendable {
        case frame(Frame)
        /// The socket dropped and was re-established; refetch history to re-baseline.
        case reconnected
        /// Terminal failure after retries were exhausted or the stream was stopped.
        case closed(Error?)
    }

    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var running = false
    private let decoder = JSONDecoder()
    /// Consecutive failed connections before the stream reports itself closed.
    /// With the capped backoff this is roughly half a minute of retrying.
    private let maxAttempts = 6

    public init(baseURL: URL, kind: StreamKind, session: URLSession = .shared) {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = "/api/\(kind.rawValue)"
        self.url = comps.url!
        self.session = session
    }

    /// Open the stream and yield signals until `stop()` or an unrecoverable failure.
    public func signals() -> AsyncStream<Signal> {
        AsyncStream { continuation in
            let pump = Task { await self.pump(continuation) }
            continuation.onTermination = { _ in
                pump.cancel()
                Task { await self.stop() }
            }
        }
    }

    public func stop() {
        running = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func pump(_ continuation: AsyncStream<Signal>.Continuation) async {
        running = true
        var attempt = 0
        var hasConnectedOnce = false

        while running && !Task.isCancelled {
            let socket = session.webSocketTask(with: url)
            self.task = socket
            socket.resume()

            // `resume()` only schedules the handshake — it proves nothing about
            // reachability. Announcing a reconnect here would fire on every
            // failed retry, and each one costs the caller a full re-baseline.
            var delivered = false

            do {
                while running && !Task.isCancelled {
                    let message = try await socket.receive()

                    // The first successful receive is the earliest honest
                    // evidence this socket works. Reset the backoff here, not
                    // at the top of the loop, so repeated failures actually
                    // escalate instead of pinning the delay at its minimum.
                    if !delivered {
                        delivered = true
                        attempt = 0
                        if hasConnectedOnce { continuation.yield(.reconnected) }
                        hasConnectedOnce = true
                    }

                    guard let text = Self.text(of: message) else { continue }
                    guard let data = text.data(using: .utf8) else { continue }
                    // Non-frame traffic (heartbeats, unknown shapes) is skipped
                    // rather than fatal: the contract is still moving.
                    guard let frame = try? decoder.decode(ServerRequestFrame.self, from: data) else { continue }
                    continuation.yield(.frame(Frame(rpcId: frame.rpcId, method: frame.method, payload: frame.payload)))
                }
            } catch {
                if !running || Task.isCancelled { break }
                attempt += 1
                if attempt > maxAttempts {
                    continuation.yield(.closed(error))
                    continuation.finish()
                    return
                }
                // Exponential backoff, capped — a harness restart should be
                // ridden out, but a harness that is simply gone must not be
                // hammered.
                let delay = min(pow(2.0, Double(attempt)) * 0.25, 8.0)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        continuation.yield(.closed(nil))
        continuation.finish()
    }

    private static func text(of message: URLSessionWebSocketTask.Message) -> String? {
        switch message {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8)
        @unknown default: return nil
        }
    }
}
