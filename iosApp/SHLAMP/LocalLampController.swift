import Foundation

@MainActor
protocol LocalLampControllerDelegate: AnyObject {
    func localController(_ controller: LocalLampController, didDiscover snapshot: WiFiLampSnapshot)
    func localController(_ controller: LocalLampController, didChangeStatus status: String)
}

final class LocalLampController: NSObject {
    weak var delegate: LocalLampControllerDelegate?

    private let browser = NetServiceBrowser()
    private var resolving: [String: NetService] = [:]
    private var discoveredHosts: Set<String> = []
    private let session: URLSession
    private var discoveryRunning = false

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
    }

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

    /// Low-latency slider transport. Intermediate drag values intentionally do
    /// not run the multi-read verification loop; the final value still uses
    /// `sendBrightness` and is verified by the lamp.
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
        request.setValue("SHLAMP-iOS/1.6.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AppError.message(text.isEmpty ? "Local lamp request failed." : text)
        }
        return data
    }

    private func snapshot(from data: Data, host: String) throws -> WiFiLampSnapshot {
        let json = try parseJSONObject(data)
        let lampID = json.string("lampId").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lampID.isEmpty else { throw AppError.message("The lamp firmware did not return lampId.") }
        let cloudID = [json.string("cloudLampId"), json.string("cloudId"), json.string("renderLampId")]
            .map { $0.uppercased() }
            .first { $0.range(of: "^SH-[A-Z0-9]{4,16}$", options: .regularExpression) != nil }
        let batteryPercent = json.int("batteryPercent").map { clamp($0, 0...100) }
        let batteryVoltage = json.int("batteryVoltageMv").flatMap { (2000...5000).contains($0) ? $0 : nil }
        return WiFiLampSnapshot(
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
