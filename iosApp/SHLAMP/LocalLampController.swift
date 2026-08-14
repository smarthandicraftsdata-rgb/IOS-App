import Foundation

@MainActor
protocol LocalLampControllerDelegate: AnyObject {
    func localController(_ controller: LocalLampController, didDiscover snapshot: WiFiLampSnapshot)
    func localController(_ controller: LocalLampController, didReceiveRealtime snapshot: WiFiLampSnapshot)
    func localController(_ controller: LocalLampController, didChangeStatus status: String)
}

final class LocalLampController: NSObject {
    weak var delegate: LocalLampControllerDelegate?

    private let browser = NetServiceBrowser()
    private var resolving: [String: NetService] = [:]
    private var discoveredHosts: Set<String> = []
    private let session: URLSession
    private let controlSession: URLSession
    private var discoveryRunning = false
    private var discoveryRestartTask: Task<Void, Never>?

    // R21A additive realtime transport. HTTP remains the fallback for old
    // firmware and for any WebSocket interruption.
    private let realtimeLock = NSLock()
    private var realtimeTasks: [String: URLSessionWebSocketTask] = [:]
    private var realtimeStartedAt: [String: Date] = [:]
    private var realtimeLastMessageAt: [String: Date] = [:]
    private var realtimeValidatedHosts: Set<String> = []
    private var realtimeHeartbeatTasks: [String: Task<Void, Never>] = [:]
    private var realtimeReconnectTasks: [String: Task<Void, Never>] = [:]
    private var realtimeHostByLampID: [String: String] = [:]
    // Authoritative identity learned from an actual state/ACK on each host.
    // This is separate from the expected identity so a stale DHCP/IP mapping
    // can never be treated as a healthy route for the wrong physical lamp.
    private var realtimeActualLampByHost: [String: String] = [:]
    // RF5.4.1 pre-identity ownership: a remembered/discovered lamp ID reserves
    // one local WebSocket generation before the first state packet arrives.
    // This prevents IP + mDNS aliases from simultaneously opening #1/#2/#3
    // sockets to the same physical ESP during route recovery.
    private var realtimeExpectedLampByHost: [String: String] = [:]
    private var realtimeAckWaiters: [String: (continuation: CheckedContinuation<JSONObject, Error>, timeout: Task<Void, Never>)] = [:]

    override init() {
        let realtimeConfiguration = URLSessionConfiguration.ephemeral
        realtimeConfiguration.timeoutIntervalForRequest = 4
        realtimeConfiguration.timeoutIntervalForResource = 60
        realtimeConfiguration.waitsForConnectivity = false
        session = URLSession(configuration: realtimeConfiguration)

        // RF5.4 control HTTP is a bounded fallback, never a multi-second route
        // owner. A dead LAN endpoint must release the app to BLE/cloud quickly.
        let controlConfiguration = URLSessionConfiguration.ephemeral
        controlConfiguration.timeoutIntervalForRequest = 1.15
        controlConfiguration.timeoutIntervalForResource = 1.5
        controlConfiguration.waitsForConnectivity = false
        controlSession = URLSession(configuration: controlConfiguration)
        super.init()
        browser.delegate = self
    }

    func startDiscovery() {
        guard !discoveryRunning else { return }
        discoveryRunning = true
        discoveredHosts.removeAll()
        browser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")
        publishStatus("Checking the local Wi-Fi for SH Lamps…")
    }

    /// RF5.2.1: force a new Bonjour generation without tearing down healthy
    /// realtime sockets. This clears the per-search host de-duplication cache,
    /// which otherwise could keep a rediscovered lamp invisible after a
    /// transient route failure.
    func restartDiscovery() {
        discoveryRestartTask?.cancel()
        browser.stop()
        resolving.values.forEach { $0.stop() }
        resolving.removeAll()
        discoveredHosts.removeAll()
        discoveryRunning = false

        discoveryRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.startDiscovery()
        }
    }

    func stopDiscovery() {
        discoveryRestartTask?.cancel()
        discoveryRestartTask = nil
        discoveryRunning = false
        browser.stop()
        resolving.values.forEach { $0.stop() }
        resolving.removeAll()
        discoveredHosts.removeAll()
        stopAllRealtime()
    }

    // MARK: - R21A local realtime

    func startRealtime(host: String, expectedLampID: String? = nil) {
        let clean = normalizedRealtimeHost(host)
        guard !clean.isEmpty else { return }
        let expectedKey = expectedLampID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let usableExpectedKey = (expectedKey?.isEmpty == false) ? expectedKey : nil
        let now = Date()

        var staleAliasSocket: URLSessionWebSocketTask?
        var staleAliasHeartbeat: Task<Void, Never>?
        var staleAliasReconnect: Task<Void, Never>?
        realtimeLock.lock()
        let pendingReconnect = realtimeReconnectTasks.removeValue(forKey: clean)
        if let existing = realtimeTasks[clean] {
            if let usableExpectedKey { realtimeExpectedLampByHost[clean] = usableExpectedKey }
            realtimeLock.unlock()
            pendingReconnect?.cancel()
            _ = existing
            return
        }

        // If the physical lamp is already represented by another alias, keep
        // the healthy/starting generation. Only replace an alias that is
        // actually stale. This gate operates BEFORE ESP identity arrives.
        if let usableExpectedKey,
           let otherHost = realtimeExpectedLampByHost.first(where: { host, lamp in
               lamp == usableExpectedKey && host != clean && realtimeTasks[host] != nil
           })?.key {
            let otherLast = realtimeLastMessageAt[otherHost]
            let otherStarted = realtimeStartedAt[otherHost]
            let otherHealthy = realtimeValidatedHosts.contains(otherHost) &&
                otherLast.map { now.timeIntervalSince($0) <= 16 } == true
            let otherStarting = otherStarted.map { now.timeIntervalSince($0) < 6 } == true
            if otherHealthy || otherStarting {
                realtimeLock.unlock()
                pendingReconnect?.cancel()
                return
            }

            staleAliasSocket = realtimeTasks.removeValue(forKey: otherHost)
            realtimeStartedAt.removeValue(forKey: otherHost)
            realtimeLastMessageAt.removeValue(forKey: otherHost)
            realtimeValidatedHosts.remove(otherHost)
            staleAliasHeartbeat = realtimeHeartbeatTasks.removeValue(forKey: otherHost)
            staleAliasReconnect = realtimeReconnectTasks.removeValue(forKey: otherHost)
            realtimeExpectedLampByHost.removeValue(forKey: otherHost)
            realtimeActualLampByHost.removeValue(forKey: otherHost)
            realtimeHostByLampID = realtimeHostByLampID.filter { $0.value != otherHost }
        }
        realtimeLock.unlock()
        pendingReconnect?.cancel()
        staleAliasHeartbeat?.cancel()
        staleAliasReconnect?.cancel()
        staleAliasSocket?.cancel(with: .goingAway, reason: nil)

        guard let url = realtimeURL(host: clean) else { return }
        let socket = session.webSocketTask(with: url)

        realtimeLock.lock()
        // Another caller may have won while the URL was being built. Also
        // re-check expected-lamp ownership to close the small concurrent race.
        let competingExpectedHost = usableExpectedKey.flatMap { lampKey in
            realtimeExpectedLampByHost.first(where: { host, lamp in
                lamp == lampKey && host != clean && realtimeTasks[host] != nil
            })?.key
        }
        if realtimeTasks[clean] != nil || competingExpectedHost != nil {
            realtimeLock.unlock()
            socket.cancel(with: .goingAway, reason: nil)
            return
        }
        realtimeTasks[clean] = socket
        realtimeStartedAt[clean] = now
        if let usableExpectedKey { realtimeExpectedLampByHost[clean] = usableExpectedKey }
        realtimeLock.unlock()

        socket.resume()
        receiveRealtime(host: clean, socket: socket)
        sendRealtimeHello(host: clean, socket: socket)
        startRealtimeHeartbeat(host: clean, socket: socket)
    }

    func stopRealtime(host: String) {
        let clean = normalizedRealtimeHost(host)
        realtimeLock.lock()
        let socket = realtimeTasks.removeValue(forKey: clean)
        realtimeStartedAt.removeValue(forKey: clean)
        realtimeLastMessageAt.removeValue(forKey: clean)
        realtimeValidatedHosts.remove(clean)
        realtimeExpectedLampByHost.removeValue(forKey: clean)
        realtimeActualLampByHost.removeValue(forKey: clean)
        let heartbeat = realtimeHeartbeatTasks.removeValue(forKey: clean)
        let reconnect = realtimeReconnectTasks.removeValue(forKey: clean)
        realtimeHostByLampID = realtimeHostByLampID.filter { $0.value != clean }
        realtimeLock.unlock()
        heartbeat?.cancel()
        reconnect?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    func isRealtimeHealthy(host: String, expectedLampID: String? = nil, now: Date = Date()) -> Bool {
        let clean = normalizedRealtimeHost(host)
        let expected = expectedLampID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        realtimeLock.lock()
        let last = realtimeLastMessageAt[clean]
        let hasTask = realtimeTasks[clean] != nil
        let validated = realtimeValidatedHosts.contains(clean)
        let actualLampID = realtimeActualLampByHost[clean]
        realtimeLock.unlock()
        guard hasTask, validated, let last, now.timeIntervalSince(last) <= 16 else { return false }
        if let expected, !expected.isEmpty {
            return actualLampID == expected
        }
        return actualLampID != nil
    }

    /// Ensure a remembered local endpoint is actively recoverable. A socket
    /// that has not produced authoritative state within six seconds is treated
    /// as half-open and rebuilt instead of waiting indefinitely.
    func recoverRealtime(host: String, expectedLampID: String? = nil, now: Date = Date()) {
        let clean = normalizedRealtimeHost(host)
        guard !clean.isEmpty else { return }

        realtimeLock.lock()
        let socket = realtimeTasks[clean]
        let startedAt = realtimeStartedAt[clean]
        let last = realtimeLastMessageAt[clean]
        let validated = realtimeValidatedHosts.contains(clean)
        let heartbeat = realtimeHeartbeatTasks[clean]
        let reconnect = realtimeReconnectTasks[clean]
        let rememberedExpectedLampID = realtimeExpectedLampByHost[clean]
        let effectiveExpectedLampID = expectedLampID ?? rememberedExpectedLampID
        let expectedKey = effectiveExpectedLampID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let actualLampID = realtimeActualLampByHost[clean]
        let identityMatches = expectedKey?.isEmpty != false || actualLampID == expectedKey
        let healthy = socket != nil && validated && identityMatches && last.map { now.timeIntervalSince($0) <= 16 } == true
        let stillStarting = socket != nil && !validated && startedAt.map { now.timeIntervalSince($0) < 6 } == true

        if healthy || stillStarting {
            realtimeLock.unlock()
            return
        }

        realtimeTasks.removeValue(forKey: clean)
        realtimeStartedAt.removeValue(forKey: clean)
        realtimeLastMessageAt.removeValue(forKey: clean)
        realtimeValidatedHosts.remove(clean)
        realtimeExpectedLampByHost.removeValue(forKey: clean)
        realtimeActualLampByHost.removeValue(forKey: clean)
        realtimeHeartbeatTasks.removeValue(forKey: clean)
        realtimeReconnectTasks.removeValue(forKey: clean)
        realtimeLock.unlock()

        heartbeat?.cancel()
        reconnect?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        startRealtime(host: clean, expectedLampID: effectiveExpectedLampID)
    }

    // RF5 ordered LAN mutation. Protocol v3 adds command IDs plus the same
    // controller/session/intent sequence carried over BLE and cloud. HTTP v3
    // remains an ordered fallback when the realtime socket is unavailable.
    func sendOrderedCommand(
        host: String,
        expectedLampID: String,
        intent: OrderedControlIntent,
        waitForAck: Bool
    ) async throws -> WiFiLampSnapshot? {
        let clean = normalizedRealtimeHost(host)
        let expectedKey = expectedLampID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !expectedKey.isEmpty else {
            throw AppError.message("The local lamp identity is missing.")
        }
        if isRealtimeHealthy(host: clean, expectedLampID: expectedKey), let socket = currentRealtimeSocket(host: clean) {
            do {
                if waitForAck {
                    let ack = try await sendRealtimeOrderedAwaitingAck(host: clean, socket: socket, intent: intent)
                    guard ack.bool("success") != false else {
                        throw AppError.message(firstNonBlank(ack.string("error"), "The lamp rejected the local command."))
                    }
                    if let state = ack.object("state") {
                        let snapshot = try snapshot(from: state, host: normalizedHost(host))
                        guard snapshot.lampId.uppercased() == expectedKey else {
                            stopRealtime(host: clean)
                            throw AppError.message("The local endpoint now belongs to a different lamp.")
                        }
                        return snapshot
                    }
                    let snapshot = try await readStatus(host: host)
                    guard snapshot.lampId.uppercased() == expectedKey else {
                        stopRealtime(host: clean)
                        throw AppError.message("The local endpoint now belongs to a different lamp.")
                    }
                    return snapshot
                } else {
                    try await sendRealtimeOrdered(host: clean, socket: socket, intent: intent)
                    return nil
                }
            } catch {
                // Fall through to the ordered HTTP endpoint with the exact same
                // command ID. Device-side sequence/dedup makes this safe even
                // if the WebSocket frame executed and only its ACK was lost.
            }
        }

        // Never mutate a remembered IP blindly. DHCP can reuse an address for
        // another lamp. A bounded status probe proves the physical identity
        // before the ordered HTTP fallback is allowed to touch GPIO state.
        let identity = try await readStatus(host: host)
        guard identity.lampId.uppercased() == expectedKey else {
            stopRealtime(host: clean)
            throw AppError.message("The remembered local address now belongs to a different lamp.")
        }
        startRealtime(host: clean, expectedLampID: expectedKey)

        let object = try await sendOrderedHTTP(host: host, intent: intent)
        guard object.bool("success") != false else {
            throw AppError.message(firstNonBlank(object.string("error"), "The lamp rejected the local command."))
        }
        if let state = object.object("state") {
            let snapshot = try snapshot(from: state, host: normalizedHost(host))
            guard snapshot.lampId.uppercased() == expectedKey else {
                stopRealtime(host: clean)
                throw AppError.message("The local endpoint changed identity during the command.")
            }
            return snapshot
        }
        if waitForAck {
            let snapshot = try await readStatus(host: host)
            guard snapshot.lampId.uppercased() == expectedKey else {
                stopRealtime(host: clean)
                throw AppError.message("The local endpoint changed identity during the command.")
            }
            return snapshot
        }
        return nil
    }

    private func currentRealtimeSocket(host: String) -> URLSessionWebSocketTask? {
        realtimeLock.lock()
        defer { realtimeLock.unlock() }
        return realtimeTasks[normalizedRealtimeHost(host)]
    }

    private func orderedObject(_ intent: OrderedControlIntent) -> JSONObject {
        [
            "type": "command",
            "protocolVersion": 3,
            "commandId": intent.commandID,
            "action": intent.action,
            "value": intent.value
        ]
    }

    private func sendRealtimeOrdered(host: String, socket: URLSessionWebSocketTask, intent: OrderedControlIntent) async throws {
        let data = try jsonData(orderedObject(intent))
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppError.message("Could not encode the local command.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.send(.string(text)) { [weak self, weak socket] error in
                if let error {
                    if let self, let socket { self.markRealtimeDisconnected(host: host, socket: socket) }
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func sendRealtimeOrderedAwaitingAck(
        host: String,
        socket: URLSessionWebSocketTask,
        intent: OrderedControlIntent
    ) async throws -> JSONObject {
        try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled, let self else { return }
                self.failRealtimeAck(commandID: intent.commandID, error: AppError.message("The lamp did not acknowledge the local command."))
            }
            realtimeLock.lock()
            let replaced = realtimeAckWaiters.updateValue((continuation, timeout), forKey: intent.commandID)
            realtimeLock.unlock()
            if let replaced {
                replaced.timeout.cancel()
                replaced.continuation.resume(throwing: AppError.message("A newer local attempt replaced the same ordered command."))
            }

            Task { [weak self, weak socket] in
                guard let self, let socket else { return }
                do { try await self.sendRealtimeOrdered(host: host, socket: socket, intent: intent) }
                catch { self.failRealtimeAck(commandID: intent.commandID, error: error) }
            }
        }
    }

    private func resolveRealtimeAck(_ object: JSONObject) {
        let commandID = object.string("commandId")
        guard !commandID.isEmpty else { return }
        realtimeLock.lock()
        let waiter = realtimeAckWaiters.removeValue(forKey: commandID)
        realtimeLock.unlock()
        waiter?.timeout.cancel()
        waiter?.continuation.resume(returning: object)
    }

    private func failRealtimeAck(commandID: String, error: Error) {
        realtimeLock.lock()
        let waiter = realtimeAckWaiters.removeValue(forKey: commandID)
        realtimeLock.unlock()
        waiter?.timeout.cancel()
        waiter?.continuation.resume(throwing: error)
    }

    private func sendOrderedHTTP(host: String, intent: OrderedControlIntent) async throws -> JSONObject {
        let clean = normalizedHost(host)
        guard !clean.isEmpty, let url = URL(string: "http://\(clean)/api/command") else {
            throw AppError.message("Lamp address is empty or invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SHLAMP-iOS/1.8.2-RF5.4.2", forHTTPHeaderField: "User-Agent")
        request.httpBody = try jsonData(orderedObject(intent))
        let (data, response) = try await controlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AppError.message(text.isEmpty ? "Ordered local command failed." : text)
        }
        return try parseJSONObject(data)
    }

    private func receiveRealtime(host: String, socket: URLSessionWebSocketTask) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket else { return }

            self.realtimeLock.lock()
            let stillCurrent = self.realtimeTasks[host] === socket
            self.realtimeLock.unlock()
            guard stillCurrent else { return }

            switch result {
            case .failure:
                self.markRealtimeDisconnected(host: host, socket: socket)
            case .success(let message):
                let data: Data?
                switch message {
                case .string(let text): data = text.data(using: .utf8)
                case .data(let value): data = value
                @unknown default: data = nil
                }

                if let data, let object = try? parseJSONObject(data) {
                    self.realtimeLock.lock()
                    self.realtimeLastMessageAt[host] = Date()
                    self.realtimeLock.unlock()
                    self.handleRealtimeObject(object, host: host)
                }
                self.receiveRealtime(host: host, socket: socket)
            }
        }
    }

    private func handleRealtimeObject(_ object: JSONObject, host: String) {
        let type = object.string("type")
        var stateObject: JSONObject?
        let isAck = type.caseInsensitiveCompare("ack") == .orderedSame
        if type.caseInsensitiveCompare("state") == .orderedSame {
            stateObject = object
        } else if isAck {
            stateObject = object.object("state")
        }

        guard let stateObject, let snapshot = try? snapshot(from: stateObject, host: host) else { return }
        let lampKey = snapshot.lampId.uppercased()
        guard !lampKey.isEmpty else { return }

        realtimeLock.lock()
        let expectedLampKey = realtimeExpectedLampByHost[host]
        realtimeLock.unlock()
        if let expectedLampKey, expectedLampKey != lampKey {
            // Stale DHCP / remembered IP protection. Never mark this socket
            // healthy and never let its ACK satisfy the intended lamp. Surface
            // the actual lamp snapshot for discovery, then retire the socket.
            stopRealtime(host: host)
            Task { @MainActor in
                delegate?.localController(self, didDiscover: snapshot)
            }
            return
        }

        var previousHost: String?
        realtimeLock.lock()
        realtimeValidatedHosts.insert(host)
        realtimeLastMessageAt[host] = Date()
        realtimeActualLampByHost[host] = lampKey
        previousHost = realtimeHostByLampID[lampKey]
        realtimeHostByLampID[lampKey] = host
        realtimeExpectedLampByHost[host] = lampKey
        realtimeLock.unlock()

        // Resolve a command only after the socket's physical lamp identity has
        // been validated. This prevents a stale-IP ACK from satisfying another
        // lamp's in-flight command.
        if isAck { resolveRealtimeAck(object) }

        // RF4: a remembered IP, Bonjour hostname and :80 alias can all point to
        // the same ESP. Keep only one realtime socket per lamp after identity is
        // known; the RF2 log showed multiple simultaneous clients (#0/#1/#2).
        // Prefer the already-healthy socket rather than letting a later alias
        // steal ownership and create IP <-> mDNS reconnect oscillation.
        if let previousHost, previousHost != host {
            if isRealtimeHealthy(host: previousHost, expectedLampID: lampKey) {
                stopRealtime(host: host)
                realtimeLock.lock()
                realtimeHostByLampID[lampKey] = previousHost
                realtimeLock.unlock()
                return
            }

            stopRealtime(host: previousHost)
            realtimeLock.lock()
            realtimeHostByLampID[lampKey] = host
            realtimeLock.unlock()
        }

        Task { @MainActor in
            delegate?.localController(self, didReceiveRealtime: snapshot)
        }
    }

    private func sendRealtimeHello(host: String, socket: URLSessionWebSocketTask) {
        let object: JSONObject = ["type": "hello", "protocolVersion": 2]
        guard let data = try? jsonData(object), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // Keep NSLock operations inside synchronous helpers. Async Tasks call
    // these helpers only before/after suspension points; no lock is held
    // across an await and we avoid raw lock()/unlock() inside async contexts.
    private func isCurrentRealtimeSocket(host: String, socket: URLSessionWebSocketTask) -> Bool {
        realtimeLock.lock()
        defer { realtimeLock.unlock() }
        return realtimeTasks[host] === socket
    }

    private func recordRealtimeActivityIfCurrent(host: String, socket: URLSessionWebSocketTask) {
        realtimeLock.lock()
        defer { realtimeLock.unlock() }
        guard realtimeTasks[host] === socket else { return }
        realtimeLastMessageAt[host] = Date()
    }

    private func startRealtimeHeartbeat(host: String, socket: URLSessionWebSocketTask) {
        realtimeLock.lock()
        realtimeHeartbeatTasks[host]?.cancel()
        let task = Task { [weak self, weak socket] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let socket else { return }
                guard self.isCurrentRealtimeSocket(host: host, socket: socket) else { return }

                socket.sendPing { [weak self, weak socket] error in
                    guard let self, let socket else { return }
                    if error == nil {
                        self.recordRealtimeActivityIfCurrent(host: host, socket: socket)
                    } else {
                        self.markRealtimeDisconnected(host: host, socket: socket)
                    }
                }
            }
        }
        realtimeHeartbeatTasks[host] = task
        realtimeLock.unlock()
    }

    private func markRealtimeDisconnected(host: String, socket: URLSessionWebSocketTask) {
        realtimeLock.lock()
        guard realtimeTasks[host] === socket else {
            realtimeLock.unlock()
            return
        }
        realtimeTasks.removeValue(forKey: host)
        realtimeStartedAt.removeValue(forKey: host)
        realtimeLastMessageAt.removeValue(forKey: host)
        realtimeValidatedHosts.remove(host)
        let expectedLampID = realtimeExpectedLampByHost.removeValue(forKey: host)
        realtimeActualLampByHost.removeValue(forKey: host)
        let heartbeat = realtimeHeartbeatTasks.removeValue(forKey: host)
        realtimeLock.unlock()
        heartbeat?.cancel()
        socket.cancel(with: .goingAway, reason: nil)

        // HTTP polling remains active as fallback. Reconnect is deliberately
        // modest so a dead/old firmware endpoint cannot create a tight loop.
        // Track the task so Wi-Fi loss/sign-out can cancel it cleanly.
        let reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.startRealtime(host: host, expectedLampID: expectedLampID)
        }
        realtimeLock.lock()
        realtimeReconnectTasks[host]?.cancel()
        realtimeReconnectTasks[host] = reconnect
        realtimeLock.unlock()
    }

    private func stopAllRealtime() {
        realtimeLock.lock()
        let sockets = Array(realtimeTasks.values)
        let heartbeats = Array(realtimeHeartbeatTasks.values)
        let reconnects = Array(realtimeReconnectTasks.values)
        realtimeTasks.removeAll()
        realtimeStartedAt.removeAll()
        realtimeLastMessageAt.removeAll()
        realtimeValidatedHosts.removeAll()
        realtimeHeartbeatTasks.removeAll()
        realtimeReconnectTasks.removeAll()
        realtimeHostByLampID.removeAll()
        realtimeExpectedLampByHost.removeAll()
        realtimeActualLampByHost.removeAll()
        let waiters = Array(realtimeAckWaiters.values)
        realtimeAckWaiters.removeAll()
        realtimeLock.unlock()
        waiters.forEach { item in
            item.timeout.cancel()
            item.continuation.resume(throwing: AppError.message("Local realtime connection closed."))
        }
        heartbeats.forEach { $0.cancel() }
        reconnects.forEach { $0.cancel() }
        sockets.forEach { $0.cancel(with: .goingAway, reason: nil) }
    }

    private func realtimeURL(host: String) -> URL? {
        let clean = normalizedRealtimeHost(host)
        guard !clean.isEmpty else { return nil }
        let baseHost: String
        if let colon = clean.lastIndex(of: ":"), clean[clean.index(after: colon)...].allSatisfy({ $0.isNumber }) {
            baseHost = String(clean[..<colon])
        } else {
            baseHost = clean
        }
        return URL(string: "ws://\(baseHost):81/")
    }

    // MARK: - Proven HTTP fallback/API

    func readStatus(host: String) async throws -> WiFiLampSnapshot {
        try snapshot(from: try await request(host: host, path: "/api/status"), host: normalizedHost(host))
    }

    func sendPower(host: String, on: Bool) async throws -> WiFiLampSnapshot {
        try await verified(host: host, path: "/api/power?state=\(on ? "on" : "off")") { $0.power == on }
    }

    func sendBrightness(host: String, percent: Int) async throws -> WiFiLampSnapshot {
        let value = clamp(percent, 0...100)
        return try await verified(host: host, path: "/api/brightness?value=\(value)") { snapshot in
            let expected = snapshot.powerMode == .maximumBackup ? min(value, 70) : value
            return snapshot.targetBrightness == expected
        }
    }

    func sendBrightnessFast(host: String, percent: Int) async throws {
        let value = clamp(percent, 0...100)
        _ = try await request(host: host, path: "/api/brightness?value=\(value)")
    }

    func sendPowerMode(host: String, expectedLampID: String, mode: LampPowerMode) async throws -> WiFiLampSnapshot? {
        // RF5.4.2: power-mode can disable Wi-Fi, so identity must be proven
        // BEFORE mutation. Never mutate a remembered DHCP address first and
        // discover afterward that it now belongs to another physical lamp.
        _ = try await verifyPhysicalIdentity(host: host, expectedLampID: expectedLampID)
        let path = "/api/power-mode?mode=\(mode.firmwareValue)"
        if mode == .bleOnly || mode == .touchOnly {
            _ = try await request(host: host, path: path)
            return nil
        }
        return try await verified(host: host, path: path) { snapshot in
            snapshot.lampId.caseInsensitiveCompare(expectedLampID) == .orderedSame && snapshot.powerMode == mode
        }
    }

    func sendFade(host: String, mode: Int) async throws -> WiFiLampSnapshot {
        let value = clamp(mode, 0...3)
        return try await verified(host: host, path: "/api/fade?mode=\(value)") { $0.fadeMode == value }
    }

    func sendTimer(host: String, minutes: Int) async throws -> WiFiLampSnapshot {
        let value = [0, 15, 30, 60].contains(minutes) ? minutes : 0
        return try await verified(host: host, path: "/api/timer?minutes=\(value)") { snapshot in
            value == 0 ? snapshot.timerRemainingSeconds == 0 : (1...Int64(value * 60)).contains(snapshot.timerRemainingSeconds)
        }
    }

    func identify(host: String, expectedLampID: String) async throws {
        _ = try await verifyPhysicalIdentity(host: host, expectedLampID: expectedLampID)
        _ = try await request(host: host, path: "/api/identify")
    }

    func rename(host: String, expectedLampID: String, name: String) async throws -> WiFiLampSnapshot {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw AppError.message("Invalid lamp name.")
        }
        _ = try await verifyPhysicalIdentity(host: host, expectedLampID: expectedLampID)
        return try await verified(host: host, path: "/api/name?value=\(encoded)") { snapshot in
            snapshot.lampId.caseInsensitiveCompare(expectedLampID) == .orderedSame && snapshot.lampName == clean
        }
    }

    func readControllers(host: String) async throws -> [LampControllerAccess] {
        let data = try await request(host: host, path: "/api/controllers")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return array.compactMap { item in
            guard let object = item as? JSONObject else { return nil }
            let id = object.string("controllerId")
            guard !id.isEmpty else { return nil }
            return LampControllerAccess(controllerId: id, label: firstNonBlank(object.string("label"), "Controller"), owner: object.string("role") == "OWNER")
        }
    }

    private func verifyPhysicalIdentity(host: String, expectedLampID: String) async throws -> WiFiLampSnapshot {
        let expected = expectedLampID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !expected.isEmpty else {
            throw AppError.message("The physical lamp identity is unavailable for this local command.")
        }
        let snapshot = try await readStatus(host: host)
        let actual = snapshot.lampId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard actual == expected else {
            throw AppError.message("The remembered local address now belongs to a different lamp.")
        }
        return snapshot
    }

    private func verified(host: String, path: String, verify: (WiFiLampSnapshot) -> Bool) async throws -> WiFiLampSnapshot {
        _ = try await request(host: host, path: path)
        for delay in [0.08, 0.22, 0.45] {
            try? await Task.sleep(for: .seconds(delay))
            if let latest = try? await readStatus(host: host), verify(latest) { return latest }
        }
        throw AppError.message("The lamp did not confirm the local Wi-Fi command.")
    }

    private func request(host: String, path: String) async throws -> Data {
        let clean = normalizedHost(host)
        guard !clean.isEmpty, let url = URL(string: "http://\(clean)\(path)") else {
            throw AppError.message("Lamp address is empty or invalid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SHLAMP-iOS/1.8.2-RF5.4.2", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await controlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AppError.message(text.isEmpty ? "Local lamp request failed." : text)
        }
        return data
    }

    private func snapshot(from data: Data, host: String) throws -> WiFiLampSnapshot {
        try snapshot(from: parseJSONObject(data), host: host)
    }

    private func snapshot(from json: JSONObject, host: String) throws -> WiFiLampSnapshot {
        let lampID = json.string("lampId").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lampID.isEmpty else { throw AppError.message("The lamp firmware did not return lampId.") }
        let cloudID = [json.string("cloudLampId"), json.string("cloudId"), json.string("renderLampId")]
            .map { $0.uppercased() }
            .first { $0.range(of: "^SH-[A-Z0-9]{4,16}$", options: .regularExpression) != nil }
        let batteryPercent = json.int("batteryPercent").map { clamp($0, 0...100) }
        let batteryVoltage = json.int("batteryVoltageMv").flatMap { (2000...5000).contains($0) ? $0 : nil }
        var snapshot = WiFiLampSnapshot(
            lampId: lampID.uppercased(),
            cloudLampId: cloudID,
            lampName: firstNonBlank(json.string("lampName"), lampID),
            hostname: json.string("hostname"),
            firmware: json.string("firmware"),
            power: json.bool("power") ?? false,
            currentBrightness: clamp(json.int("currentBrightness") ?? 0, 0...100),
            targetBrightness: clamp(json.int("targetBrightness") ?? 0, 0...100),
            lastBrightness: clamp(json.int("lastBrightness") ?? 70, 1...100),
            fadeMode: clamp(json.int("fadeMode") ?? 2, 0...3),
            timerRemainingSeconds: Int64(max(0, json.int("timerRemaining") ?? 0)),
            ssid: json.string("ssid"),
            rssi: json.int("rssi") ?? -127,
            ip: json.string("ip"),
            activeSSID: json.string("activeSsid"),
            savedNetworkCount: clamp(json.int("savedNetworkCount") ?? 0, 0...5),
            controllerCount: clamp(json.int("controllerCount") ?? 0, 0...8),
            bleName: json.string("bleName"),
            batteryValid: json.bool("batteryValid") ?? (batteryPercent != nil || batteryVoltage != nil),
            batteryPercent: batteryPercent,
            batteryVoltageMv: batteryVoltage,
            batteryCharging: json.bool("batteryCharging", "isCharging", "charging"),
            powerMode: LampPowerMode(rawValue: json.string("powerMode").uppercased()) ?? .balanced,
            runtimeState: LampRuntimeState(rawValue: json.string("runtimeState").uppercased()) ?? .unknown,
            host: host
        )
        snapshot.stateBootId = json.int("bootId", "stateBootId").map { Int64($0) }
        snapshot.stateBootSequence = json.int("bootSequence", "stateBootSequence").map { Int64($0) }
        snapshot.stateRevision = json.int("stateRevision", "revision").map { Int64($0) }
        return snapshot
    }

    private func normalizedRealtimeHost(_ raw: String) -> String {
        var value = normalizedHost(raw).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        if let colon = value.lastIndex(of: ":"),
           value[value.index(after: colon)...] == "80" {
            value = String(value[..<colon])
        }
        return value
    }

    private func normalizedHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private func publishStatus(_ text: String) {
        Task { @MainActor in delegate?.localController(self, didChangeStatus: text) }
    }
}

extension LocalLampController: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        discoveryRunning = true
        publishStatus("Searching the local network…")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        discoveryRunning = false
        publishStatus("Local discovery could not start.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let name = service.name.lowercased()
        guard name.contains("sh-lamp") || name.contains("sh lamp") else { return }
        let key = "\(service.name)|\(service.type)|\(service.domain)"
        resolving[key] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {}

    func netServiceDidResolveAddress(_ sender: NetService) {
        let key = resolving.first { $0.value === sender }?.key
        if let key { resolving.removeValue(forKey: key) }
        guard let hostName = sender.hostName else { return }
        let host = sender.port == 80 ? hostName : "\(hostName):\(sender.port)"
        guard discoveredHosts.insert(host).inserted else { return }
        // RF5.4.1: resolve identity through the bounded HTTP status probe BEFORE
        // opening port 81. Otherwise IP + mDNS aliases can each create a local
        // WS generation before either has reported its lamp ID.
        Task { [weak self] in
            guard let self, let snapshot = try? await self.readStatus(host: host) else { return }
            await MainActor.run { self.delegate?.localController(self, didDiscover: snapshot) }
            self.startRealtime(host: host, expectedLampID: snapshot.lampId)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        if let key = resolving.first(where: { $0.value === sender })?.key { resolving.removeValue(forKey: key) }
    }
}
