import Foundation

@MainActor
protocol CloudRealtimeClientDelegate: AnyObject {
    func realtimeClient(_ client: CloudRealtimeClient, didChangeStatus status: String, connected: Bool)
    func realtimeClient(_ client: CloudRealtimeClient, didReceive object: JSONObject)
}

final class CloudRealtimeClient: NSObject, URLSessionWebSocketDelegate {
    weak var delegate: CloudRealtimeClientDelegate?

    private let baseURL: URL
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private var stopped = true
    private var token = ""
    private var homeID = ""
    private var candidates: [URL] = []
    private var candidateIndex = 0
    private var reconnectAttempt = 0
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private let ackLock = NSLock()
    private var ackWaiters: [String: (lampID: String, continuation: CheckedContinuation<JSONObject, Error>, timeout: Task<Void, Never>)] = [:]

    init(baseURL: URL = AppEnvironment.cloudBaseURL) {
        self.baseURL = baseURL
    }

    func start(token: String, homeID: String, force: Bool = false) {
        if !force, !stopped, self.token == token, self.homeID == homeID, task != nil { return }
        stop(closeOnly: true)
        stopped = false
        self.token = token
        self.homeID = homeID
        self.candidates = makeCandidates()
        candidateIndex = 0
        connectNext()
    }

    func stop() { stop(closeOnly: false) }

    /// Sends a command through the already-authenticated app WebSocket.
    /// Intermediate slider traffic uses `liveCommand` so it is not persisted
    /// as a database command on every drag update. The final slider value and
    /// all discrete controls continue to use the durable `command` path.
    func sendCommand(
        lampID: String,
        action: String,
        value: Any,
        live: Bool = false,
        commandID: String = UUID().uuidString
    ) async throws -> String {
        let object: JSONObject = [
            "type": live ? "liveCommand" : "command",
            "lampId": lampID,
            "commandId": commandID,
            "action": action,
            "value": value
        ]
        try await sendJSONObject(object)
        return commandID
    }

    /// Sends one durable command and completes only when the authenticated ESP
    /// returns its semantic ACK. Render `commandAccepted` is deliberately not
    /// treated as execution success.
    func sendCommandAwaitingAck(
        lampID: String,
        action: String,
        value: Any,
        commandID: String,
        timeout: TimeInterval = 2.4
    ) async throws -> JSONObject {
        let expectedLampID = lampID.uppercased()
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self else { return }
                self.failAck(commandID: commandID, error: AppError.message("The lamp did not acknowledge the cloud command."))
            }

            ackLock.lock()
            let replaced = ackWaiters.updateValue((expectedLampID, continuation, timeoutTask), forKey: commandID)
            ackLock.unlock()
            if let replaced {
                replaced.timeout.cancel()
                replaced.continuation.resume(throwing: AppError.message("A newer cloud attempt replaced the same ordered command."))
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.sendCommand(
                        lampID: lampID,
                        action: action,
                        value: value,
                        live: false,
                        commandID: commandID
                    )
                } catch {
                    self.failAck(commandID: commandID, error: error)
                }
            }
        }
    }

    private func resolveAck(_ object: JSONObject) {
        let commandID = object.string("commandId")
        guard !commandID.isEmpty else { return }

        ackLock.lock()
        guard let waiter = ackWaiters[commandID] else {
            ackLock.unlock()
            return
        }
        let reportedLampID = object.string("lampId").uppercased()
        if !reportedLampID.isEmpty && reportedLampID != waiter.lampID {
            ackLock.unlock()
            // Wrong-device ACKs are not allowed to satisfy another lamp's
            // command even if a command ID is accidentally reused.
            return
        }
        ackWaiters.removeValue(forKey: commandID)
        ackLock.unlock()
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: object)
    }

    private func failAck(commandID: String, error: Error) {
        ackLock.lock()
        let waiter = ackWaiters.removeValue(forKey: commandID)
        ackLock.unlock()
        waiter?.timeout.cancel()
        waiter?.continuation.resume(throwing: error)
    }

    private func failAllAcks(_ error: Error) {
        ackLock.lock()
        let waiters = Array(ackWaiters.values)
        ackWaiters.removeAll()
        ackLock.unlock()
        for waiter in waiters {
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    func requestState(lampID: String) async throws -> String {
        try await sendCommand(lampID: lampID, action: "requestState", value: NSNull())
    }

    private func stop(closeOnly: Bool) {
        if !closeOnly { stopped = true }
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failAllAcks(AppError.message("Live cloud connection closed before command acknowledgement."))
    }

    private func connectNext() {
        guard !stopped, task == nil else { return }
        guard candidateIndex < candidates.count else {
            scheduleReconnect("Live cloud reconnecting…")
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        let url = candidates[candidateIndex]
        candidateIndex += 1
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("SHLAMP-iOS/1.7.4-RF5", forHTTPHeaderField: "User-Agent")
        Task { @MainActor in delegate?.realtimeClient(self, didChangeStatus: "Connecting live cloud…", connected: false) }
        let newTask = session.webSocketTask(with: request)
        task = newTask
        newTask.resume()
        receiveLoop(newTask)
    }

    private func sendJSONObject(_ object: JSONObject) async throws {
        guard !stopped, let socket = task else {
            throw AppError.message("Live cloud is not connected.")
        }
        let data = try jsonData(object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppError.message("Could not encode the live cloud command.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.send(.string(text)) { [weak self, weak socket] error in
                if let error {
                    if let self, let socket { self.handleSocketFailure(socket, status: "Live cloud reconnecting…") }
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket, self.task === socket, !self.stopped else { return }
            switch result {
            case .failure:
                self.handleSocketFailure(socket, status: "Live cloud reconnecting…")
            case .success(let message):
                let text: String
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(data: data, encoding: .utf8) ?? ""
                @unknown default: text = ""
                }
                if let data = text.data(using: .utf8), let object = try? parseJSONObject(data) {
                    let type = object.string("type")
                    if type.caseInsensitiveCompare("ack") == .orderedSame {
                        self.resolveAck(object)
                    }
                    if type.caseInsensitiveCompare("authOk") == .orderedSame,
                       object.string("connection").caseInsensitiveCompare("app") == .orderedSame {
                        self.reconnectAttempt = 0
                        Task { @MainActor in self.delegate?.realtimeClient(self, didChangeStatus: "Live cloud connected.", connected: true) }
                    }
                    Task { @MainActor in self.delegate?.realtimeClient(self, didReceive: object) }
                }
                self.receiveLoop(socket)
            }
        }
    }

    private func scheduleReconnect(_ status: String) {
        guard !stopped else { return }
        task = nil
        reconnectTask?.cancel()
        Task { @MainActor in delegate?.realtimeClient(self, didChangeStatus: status, connected: false) }
        let exponent = min(reconnectAttempt, 4)
        let delay = min(1.5 * pow(2.0, Double(exponent)), 20.0)
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.reconnectTask = nil
            self.candidateIndex = 0
            self.connectNext()
        }
    }

    private func handleSocketFailure(_ socket: URLSessionWebSocketTask, status: String) {
        guard task === socket, !stopped else { return }
        task = nil
        pingTask?.cancel()
        pingTask = nil
        socket.cancel(with: .goingAway, reason: nil)
        failAllAcks(AppError.message("Live cloud connection changed before command acknowledgement."))
        if candidateIndex < candidates.count {
            connectNext()
        } else {
            scheduleReconnect(status)
        }
    }

    private func makeCandidates() -> [URL] {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        // The coordinated Render backend exposes exactly /ws/app. Keeping a
        // non-existent legacy /api/ws/app candidate adds an unnecessary failed
        // handshake to every genuine reconnect episode.
        return ["/ws/app"].compactMap { path in
            var copy = components
            copy?.path = path
            return copy?.url
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard task === webSocketTask, !stopped else { return }
        let auth: JSONObject = ["type": "auth", "token": token]
        if let data = try? jsonData(auth), let text = String(data: data, encoding: .utf8) {
            webSocketTask.send(.string(text)) { _ in }
        }
        Task { @MainActor in delegate?.realtimeClient(self, didChangeStatus: "Authenticating cloud account…", connected: false) }
        pingTask?.cancel()
        pingTask = Task { [weak self, weak webSocketTask] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, let webSocketTask, self.task === webSocketTask else { return }
                webSocketTask.sendPing { [weak self, weak webSocketTask] error in
                    guard let self, let webSocketTask else { return }
                    if error != nil {
                        self.handleSocketFailure(webSocketTask, status: "Live cloud reconnecting…")
                    }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard task === webSocketTask else { return }
        handleSocketFailure(webSocketTask, status: "Live cloud reconnecting…")
    }
}
