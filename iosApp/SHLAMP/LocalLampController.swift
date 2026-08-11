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
    private var discoveryRunning = false

    // R21A additive realtime transport. HTTP remains the fallback for old
    // firmware and for any WebSocket interruption.
    private let realtimeLock = NSLock()
    private var realtimeTasks: [String: URLSessionWebSocketTask] = [:]
    private var realtimeLastMessageAt: [String: Date] = [:]
    private var realtimeValidatedHosts: Set<String> = []
    private var realtimeHeartbeatTasks: [String: Task<Void, Never>] = [:]
    private var realtimeReconnectTasks: [String: Task<Void, Never>] = [:]

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
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

    func stopDiscovery() {
        discoveryRunning = false
        browser.stop()
        resolving.values.forEach { $0.stop() }
        resolving.removeAll()
        stopAllRealtime()
    }

    // MARK: - R21A local realtime

    func startRealtime(host: String) {
        let clean = normalizedHost(host)
        guard !clean.isEmpty else { return }

        realtimeLock.lock()
        let pendingReconnect = realtimeReconnectTasks.removeValue(forKey: clean)
        let existing = realtimeTasks[clean]
        realtimeLock.unlock()
        pendingReconnect?.cancel()
        if existing != nil { return }

        guard let url = realtimeURL(host: clean) else { return }
        let socket = session.webSocketTask(with: url)

        realtimeLock.lock()
        // Another caller may have won while the URL was being built.
        if realtimeTasks[clean] != nil {
            realtimeLock.unlock()
            socket.cancel(with: .goingAway, reason: nil)
            return
        }
        realtimeTasks[clean] = socket
        realtimeLock.unlock()

        socket.resume()
        receiveRealtime(host: clean, socket: socket)
        sendRealtimeHello(host: clean, socket: socket)
        startRealtimeHeartbeat(host: clean, socket: socket)
    }

    func stopRealtime(host: String) {
        let clean = normalizedHost(host)
        realtimeLock.lock()
        let socket = realtimeTasks.removeValue(forKey: clean)
        realtimeLastMessageAt.removeValue(forKey: clean)
        realtimeValidatedHosts.remove(clean)
        let heartbeat = realtimeHeartbeatTasks.removeValue(forKey: clean)
        let reconnect = realtimeReconnectTasks.removeValue(forKey: clean)
        realtimeLock.unlock()
        heartbeat?.cancel()
        reconnect?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    func isRealtimeHealthy(host: String, now: Date = Date()) -> Bool {
        let clean = normalizedHost(host)
        realtimeLock.lock()
        let last = realtimeLastMessageAt[clean]
        let hasTask = realtimeTasks[clean] != nil
        let validated = realtimeValidatedHosts.contains(clean)
        realtimeLock.unlock()
        guard hasTask, validated, let last else { return false }
        return now.timeIntervalSince(last) <= 16
    }

    // R21A Review Fix 1 intentionally keeps this socket state/event-only.
    // Local commands continue through the proven HTTP API until a later phase
    // adds explicit WebSocket command ACK correlation and idempotent retry.

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
        if type.caseInsensitiveCompare("state") == .orderedSame {
            stateObject = object
        } else if type.caseInsensitiveCompare("ack") == .orderedSame {
            stateObject = object.object("state")
        }

        guard let stateObject, let snapshot = try? snapshot(from: stateObject, host: host) else { return }
        realtimeLock.lock()
        realtimeValidatedHosts.insert(host)
        realtimeLastMessageAt[host] = Date()
        realtimeLock.unlock()
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
        realtimeLastMessageAt.removeValue(forKey: host)
        realtimeValidatedHosts.remove(host)
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
            self.startRealtime(host: host)
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
        realtimeLastMessageAt.removeAll()
        realtimeValidatedHosts.removeAll()
        realtimeHeartbeatTasks.removeAll()
        realtimeReconnectTasks.removeAll()
        realtimeLock.unlock()
        heartbeats.forEach { $0.cancel() }
        reconnects.forEach { $0.cancel() }
        sockets.forEach { $0.cancel(with: .goingAway, reason: nil) }
    }

    private func realtimeURL(host: String) -> URL? {
        let clean = normalizedHost(host)
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

    func sendPowerMode(host: String, mode: LampPowerMode) async throws -> WiFiLampSnapshot? {
        let path = "/api/power-mode?mode=\(mode.firmwareValue)"
        if mode == .bleOnly || mode == .touchOnly {
            _ = try await request(host: host, path: path)
            return nil
        }
        return try await verified(host: host, path: path) { $0.powerMode == mode }
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

    func identify(host: String) async throws {
        _ = try await request(host: host, path: "/api/identify")
    }

    func rename(host: String, name: String) async throws -> WiFiLampSnapshot {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw AppError.message("Invalid lamp name.")
        }
        return try await verified(host: host, path: "/api/name?value=\(encoded)") { $0.lampName == clean }
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
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SHLAMP-iOS/1.7.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
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
        startRealtime(host: host)
        Task {
            if let snapshot = try? await readStatus(host: host) {
                await MainActor.run { delegate?.localController(self, didDiscover: snapshot) }
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        if let key = resolving.first(where: { $0.value === sender })?.key { resolving.removeValue(forKey: key) }
    }
}
