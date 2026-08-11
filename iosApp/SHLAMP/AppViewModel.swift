import Foundation
import SwiftUI
import Network
import UserNotifications

@MainActor
final class AppViewModel: ObservableObject {
    @Published var currentUser: CloudUser?
    @Published var dashboard: Dashboard = .empty
    @Published var lamps: [LampRecord] = []
    @Published var nearbyLamps: [NearbyLamp] = []
    @Published var savedWiFiNetworks: [SavedWiFiNetwork] = []
    @Published var controllers: [LampControllerAccess] = []
    @Published var busy = false
    @Published var notice = ""
    @Published var errorMessage = ""
    @Published var cloudStatus = "Not connected"
    @Published var cloudConnected = false
    @Published var bluetoothStatus = "Bluetooth is preparing…"
    @Published var localNetworkStatus = "Local discovery has not started."
    @Published var selectedLampID: String?
    @Published var showingAddLamp = false
    @Published var showingDiagnostics = false
    @Published var setupConnectedLampID = ""
    /// Drives deadline-based timer labels without mutating the device state once
    /// per second. A real device/route update recalibrates the deadline.
    @Published private(set) var liveClock = Date()

    let ble = BLELampManager()
    let local = LocalLampController()

    private let api = CloudAPI()
    private let keychain = KeychainStore()
    private let realtime = CloudRealtimeClient()
    private var session: CloudSession?
    private var localRecords: [String: LampRecord] = [:]
    private var localSnapshots: [String: WiFiLampSnapshot] = [:]
    private var connectedLocalID = ""
    private var refreshTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.smarthandicrafts.shlamp.network")
    private let localStoreKey = "shlamp.ios.localRecords.v2"
    private var manualAddFlowActive = false
    private var transientLocalIDs: Set<String> = []
    private var identityProbePeripheralID: UUID?
    private var identityProbeMatched = false
    private var pendingAutoConnectPeripheralID: UUID?
    private var probedPeripheralIDs: Set<UUID> = []
    private var wifiPathAvailable = false
    private var wifiConfirmedAt: [String: Date] = [:]
    private var localStateReceivedAt: [String: Date] = [:]
    private var bleStateReceivedAt: [String: Date] = [:]
    private var batteryStateReceivedAt: [String: Date] = [:]
    private var cloudStateReceivedAt: [String: Date] = [:]
    private var optimisticStateAt: [String: Date] = [:]
    private var timerDeadlines: [String: Date] = [:]
    private var notificationDeadlines: [String: Date] = [:]
    private var localPollTask: Task<Void, Never>?
    private var localPollInFlight: Set<String> = []
    private var liveClockTask: Task<Void, Never>?
    private var brightnessStreamTasks: [String: Task<Void, Never>] = [:]
    private var pendingBrightnessValues: [String: Int] = [:]
    private var brightnessStreamGeneration: [String: Int] = [:]
    private var localFailureCounts: [String: Int] = [:]

    private let wifiHealthTTL: TimeInterval = 7
    private let localPollInterval: Duration = .seconds(2)

    init() {
        restoreLocalRecords()
        ble.delegate = self
        local.delegate = self
        realtime.delegate = self
        startNetworkMonitor()
        startLiveClock()
        startLocalStatusPolling()
        rebuildLamps()
        Task { await bootstrap() }
    }

    var isSignedIn: Bool { currentUser != nil && session != nil }
    var selectedLamp: LampRecord? { selectedLampID.flatMap { id in lamps.first { $0.id == id || $0.canonicalID == id } } }
    var homeName: String { dashboard.homes.first?.name ?? "My Home" }

    func bootstrap() async {
        guard let saved = keychain.read() else { return }
        session = saved
        busy = true
        defer { busy = false }
        do {
            currentUser = try await withAccessToken { token in try await api.readMe(accessToken: token) }
            try await refreshDashboard(silent: true)
        } catch {
            signOut(message: "Please sign in again.")
        }
    }

    func signIn(email: String, password: String) async {
        await authenticate {
            try await api.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        }
    }

    func register(name: String, email: String, password: String) async {
        await authenticate {
            try await api.register(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
        }
    }

    private func authenticate(_ operation: () async throws -> (CloudUser, CloudSession)) async {
        busy = true
        errorMessage = ""
        defer { busy = false }
        do {
            let (user, newSession) = try await operation()
            try keychain.save(newSession)
            session = newSession
            currentUser = user
            notice = "Welcome, \(user.name.isEmpty ? user.email : user.name)."
            try await refreshDashboard(silent: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestPasswordReset(email: String) async -> PasswordResetResult? {
        busy = true
        errorMessage = ""
        defer { busy = false }
        do { return try await api.requestPasswordReset(email: email) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func confirmPasswordReset(token: String, password: String) async -> Bool {
        busy = true
        errorMessage = ""
        defer { busy = false }
        do { notice = try await api.confirmPasswordReset(token: token, newPassword: password); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }

    func signOut(message: String = "Signed out.") {
        realtime.stop()
        local.stopDiscovery()
        ble.disconnect()
        keychain.clear()
        session = nil
        currentUser = nil
        dashboard = .empty
        localSnapshots.removeAll()
        for key in Array(localRecords.keys) {
            guard var record = localRecords[key] else { continue }
            record.cloudClaimed = false
            localRecords[key] = record
        }
        persistLocalRecords()
        rebuildLamps()
        notice = message
        errorMessage = ""
    }

    func refreshDashboard(silent: Bool = false) async throws {
        if !silent { busy = true }
        defer { if !silent { busy = false } }
        let loaded = try await withAccessToken { token in try await api.loadDashboard(accessToken: token) }
        dashboard = loaded
        for lamp in loaded.lamps {
            cloudStateReceivedAt[lamp.id.uppercased()] = Date()
            registerTimerState(for: lamp, remainingSeconds: lamp.state.timerRemainingSeconds, receivedAt: Date())
        }
        rebuildLamps()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            do { try await refreshDashboard() }
            catch { handle(error) }
        }
    }

    func startConnections() {
        local.startDiscovery()
        if !manualAddFlowActive { ble.startScan() }
        if let token = session?.accessToken {
            realtime.start(token: token, homeID: dashboard.homes.first?.id ?? "default")
        }
    }

    func beginAddLampFlow() {
        manualAddFlowActive = true
        setupConnectedLampID = ""
        transientLocalIDs.removeAll()
        pendingAutoConnectPeripheralID = nil
        identityProbePeripheralID = nil
        identityProbeMatched = false
        ble.startScan()
    }

    func cancelAddLampFlow() {
        manualAddFlowActive = false
        setupConnectedLampID = ""
        transientLocalIDs.forEach { localRecords.removeValue(forKey: $0) }
        transientLocalIDs.removeAll()
        pendingAutoConnectPeripheralID = nil
        identityProbePeripheralID = nil
        identityProbeMatched = false
        if ble.isReady { ble.disconnect() }
        rebuildLamps()
    }

    func connect(_ nearby: NearbyLamp, forSetup: Bool = false) {
        if forSetup {
            manualAddFlowActive = true
            setupConnectedLampID = nearby.lampId.uppercased()
            if knownRecord(for: nearby) == nil {
                transientLocalIDs.insert(nearby.lampId.uppercased())
            }
        }
        connectedLocalID = nearby.lampId.uppercased()
        ble.connect(to: nearby.id)
    }

    func commitLocalLamp(name: String, roomID: String?) -> LampRecord? {
        guard !connectedLocalID.isEmpty else { return nil }
        let localKey = connectedLocalID.uppercased()
        var record = localRecords[localKey] ?? lamps.first(where: {
            $0.id.caseInsensitiveCompare(localKey) == .orderedSame ||
                $0.cloudLampId?.caseInsensitiveCompare(localKey) == .orderedSame
        }) ?? .placeholder(id: localKey)
        record.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? record.name : name
        record.roomId = roomID
        record.roomName = dashboard.homes.flatMap(\.rooms).first(where: { $0.id == roomID })?.name
        localRecords[localKey] = record
        transientLocalIDs.remove(localKey)
        persistLocalRecords()
        rebuildLamps()
        manualAddFlowActive = false
        setupConnectedLampID = localKey
        return lamps.first(where: { $0.canonicalID == record.canonicalID || $0.id == record.id })
    }

    func setRoutePreference(_ lamp: LampRecord, preference: LampRoutePreference) {
        updateLocalRecord(for: lamp) { $0.routePreference = preference }
        notice = "Connection set to \(preference.label)."
        switch preference {
        case .bluetooth:
            if !canUseBLE(lamp) { ble.startScan() }
        case .wifi, .automatic:
            if wifiPathAvailable { local.startDiscovery() }
            if preference == .automatic && !canUseBLE(lamp) { ble.startScan() }
        case .remote:
            rebuildLamps()
        }
    }

    func provisionWiFi(ssid: String, password: String) {
        ble.provisionWiFi(ssid: ssid, password: password)
        notice = "Wi-Fi details sent to the lamp. It may take a few seconds to join the network."
    }

    func claimLamp(lampID: String, claimCode: String, displayName: String, roomID: String?, localLampID: String? = nil) async -> Bool {
        busy = true
        errorMessage = ""
        defer { busy = false }
        do {
            let homeID = dashboard.homes.first?.id ?? "default"
            let claimed = try await withAccessToken { token in
                try await api.claimDevice(
                    accessToken: token,
                    lampId: lampID,
                    claimCode: claimCode,
                    homeId: homeID,
                    roomId: roomID,
                    displayName: displayName.isEmpty ? "SH Lamp" : displayName
                )
            }
            dashboard.lamps.removeAll { $0.id.caseInsensitiveCompare(claimed.id) == .orderedSame }
            dashboard.lamps.append(claimed)
            let localKey = (localLampID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? localLampID!
                : connectedLocalID).uppercased()
            if !localKey.isEmpty {
                var localRecord = localRecords[localKey] ?? .placeholder(id: localKey)
                localRecord.cloudLampId = claimed.id.uppercased()
                localRecord.cloudClaimed = true
                localRecord.name = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? claimed.name : displayName
                localRecord.roomId = roomID
                localRecord.roomName = dashboard.homes.flatMap(\.rooms).first(where: { $0.id == roomID })?.name
                localRecords[localKey] = localRecord
                transientLocalIDs.remove(localKey)
                persistLocalRecords()
            }
            rebuildLamps()
            notice = "\(claimed.name) was added to your account."
            showingAddLamp = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func createRoom(name: String) async -> CloudRoom? {
        do {
            let homeID = dashboard.homes.first?.id ?? "default"
            let room = try await withAccessToken { token in try await api.createRoom(accessToken: token, homeId: homeID, name: name) }
            if let index = dashboard.homes.firstIndex(where: { $0.id == homeID }) { dashboard.homes[index].rooms.append(room) }
            return room
        } catch { handle(error); return nil }
    }

    func setPower(_ lamp: LampRecord, on: Bool) {
        optimistic(lamp.id) {
            $0.state.power = on
            if on && $0.state.brightness == 0 { $0.state.brightness = 20 }
        }
        Task {
            do {
                try await performRouted(
                    lamp: lamp,
                    localAction: { host in try await self.local.sendPower(host: host, on: on) },
                    bleAction: { self.ble.power(on) },
                    cloudAction: {
                        let remoteID = try self.remoteID(for: lamp)
                        try await self.sendCloudCommand(lampID: remoteID, action: "setPower", value: on)
                    }
                )
            } catch { handle(error) }
        }
    }

    func setBrightness(_ lamp: LampRecord, value: Int) {
        let streamKey = lamp.canonicalID.uppercased()
        brightnessStreamGeneration[streamKey, default: 0] += 1
        brightnessStreamTasks[streamKey]?.cancel()
        brightnessStreamTasks[streamKey] = nil
        pendingBrightnessValues.removeValue(forKey: streamKey)

        let requested = clamp(value, 0...100)
        let percent = lamp.state.powerMode == .maximumBackup ? min(requested, 70) : requested
        optimistic(lamp.id) {
            $0.state.brightness = percent
            $0.state.power = percent > 0
        }
        if requested != percent {
            notice = "Limited to 70% by Maximum Backup."
        }
        Task {
            do {
                try await performRouted(
                    lamp: lamp,
                    localAction: { host in try await self.local.sendBrightness(host: host, percent: percent) },
                    bleAction: { self.ble.brightness(percent) },
                    cloudAction: {
                        let remoteID = try self.remoteID(for: lamp)
                        try await self.sendCloudCommand(lampID: remoteID, action: "setBrightness", value: percent)
                    }
                )
            } catch { handle(error) }
        }
    }

    /// Continuous brightness control used while the slider is moving.
    /// UI state updates immediately; transport updates are coalesced so BLE,
    /// local HTTP and cloud are never flooded. The final slider release still
    /// calls `setBrightness` for verified/durable confirmation.
    func streamBrightness(_ lamp: LampRecord, value: Int) {
        let requested = clamp(value, 0...100)
        let percent = lamp.state.powerMode == .maximumBackup ? min(requested, 70) : requested
        optimistic(lamp.id) {
            $0.state.brightness = percent
            $0.state.power = percent > 0
        }

        let key = lamp.canonicalID.uppercased()
        pendingBrightnessValues[key] = percent
        guard brightnessStreamTasks[key] == nil else { return }

        let generation = brightnessStreamGeneration[key, default: 0] + 1
        brightnessStreamGeneration[key] = generation

        brightnessStreamTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.brightnessStreamGeneration[key] == generation {
                    self.brightnessStreamTasks[key] = nil
                }
            }

            while !Task.isCancelled {
                guard let next = self.pendingBrightnessValues.removeValue(forKey: key) else { break }
                await self.sendStreamingBrightness(lamp: lamp, percent: next)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func sendStreamingBrightness(lamp: LampRecord, percent: Int) async {
        let order = routeOrder(for: lamp)
        for route in order {
            switch route {
            case .wifi:
                guard isWiFiHealthy(lamp), let host = lamp.localHost else { continue }
                if (try? await local.sendBrightnessFast(host: host, percent: percent)) != nil { return }
                markWiFiFailure(for: lamp)
            case .bluetooth:
                guard canUseBLE(lamp) else { continue }
                ble.brightness(percent)
                return
            case .cloud:
                guard cloudConnected, let remoteID = try? remoteID(for: lamp) else { continue }
                do {
                    _ = try await realtime.sendCommand(
                        lampID: remoteID,
                        action: "setBrightness",
                        value: percent,
                        live: true
                    )
                    return
                } catch {
                    continue
                }
            case .offline:
                continue
            }
        }
    }

    func setPowerMode(_ lamp: LampRecord, mode: LampPowerMode) {
        updateLocalRecord(for: lamp) {
            $0.state.powerMode = mode
            $0.state.runtimeState = mode == .touchOnly ? .touchOnly : .active
            if mode == .maximumBackup {
                $0.state.brightness = min($0.state.brightness, 70)
            }
        }
        Task {
            do {
                try await performRouted(
                    lamp: lamp,
                    localAction: { host in
                        if let snapshot = try await self.local.sendPowerMode(host: host, mode: mode) {
                            return snapshot
                        }
                        var fallback = self.localSnapshots[lamp.id.uppercased()] ?? WiFiLampSnapshot(
                            lampId: lamp.id, cloudLampId: lamp.cloudLampId, lampName: lamp.name,
                            hostname: "", firmware: lamp.firmware ?? "", power: lamp.state.power,
                            currentBrightness: lamp.state.brightness, targetBrightness: lamp.state.brightness,
                            lastBrightness: max(lamp.state.brightness, 20), fadeMode: lamp.state.fadeMode,
                            timerRemainingSeconds: lamp.state.timerRemainingSeconds, ssid: lamp.wifiSSID ?? "",
                            rssi: lamp.wifiRSSI, ip: "", activeSSID: lamp.wifiSSID ?? "",
                            savedNetworkCount: 0, controllerCount: lamp.controllerCount,
                            bleName: lamp.bleName ?? "", batteryValid: lamp.state.batteryValid,
                            batteryPercent: lamp.state.batteryPercent, batteryVoltageMv: lamp.state.batteryVoltageMv,
                            batteryCharging: lamp.state.batteryCharging, powerMode: mode,
                            runtimeState: mode == .touchOnly ? .touchOnly : .active,
                            host: host
                        )
                        fallback = WiFiLampSnapshot(
                            lampId: fallback.lampId, cloudLampId: fallback.cloudLampId,
                            lampName: fallback.lampName, hostname: fallback.hostname,
                            firmware: fallback.firmware, power: fallback.power,
                            currentBrightness: fallback.currentBrightness,
                            targetBrightness: mode == .maximumBackup ? min(fallback.targetBrightness, 70) : fallback.targetBrightness,
                            lastBrightness: fallback.lastBrightness, fadeMode: fallback.fadeMode,
                            timerRemainingSeconds: fallback.timerRemainingSeconds, ssid: fallback.ssid,
                            rssi: fallback.rssi, ip: fallback.ip, activeSSID: fallback.activeSSID,
                            savedNetworkCount: fallback.savedNetworkCount, controllerCount: fallback.controllerCount,
                            bleName: fallback.bleName, batteryValid: fallback.batteryValid,
                            batteryPercent: fallback.batteryPercent, batteryVoltageMv: fallback.batteryVoltageMv,
                            batteryCharging: fallback.batteryCharging, powerMode: mode,
                            runtimeState: mode == .touchOnly ? .touchOnly : .active,
                            host: fallback.host
                        )
                        return fallback
                    },
                    bleAction: { self.ble.powerMode(mode) },
                    cloudAction: nil
                )
                if mode == .bleOnly {
                    updateLocalRecord(for: lamp) { record in
                        record.state.powerMode = mode
                        record.state.runtimeState = .active
                        record.route = self.canUseBLE(record) ? .bluetooth : .offline
                        record.online = record.route != .offline
                    }
                    if !canUseBLE(lamp) { ble.startScan() }
                } else if mode == .touchOnly {
                    updateLocalRecord(for: lamp) { record in
                        record.state.powerMode = mode
                        record.state.runtimeState = .touchOnly
                        record.route = .offline
                        record.online = false
                    }
                }
                notice = mode == .maximumBackup
                    ? "Maximum Backup enabled. Brightness is limited to 70%."
                    : "\(mode.label) enabled."
            } catch { handle(error) }
        }
    }

    func setFade(_ lamp: LampRecord, mode: Int) {
        let value = clamp(mode, 0...3)
        optimistic(lamp.id) { $0.state.fadeMode = value }
        Task {
            do {
                try await performRouted(
                    lamp: lamp,
                    localAction: { host in try await self.local.sendFade(host: host, mode: value) },
                    bleAction: { self.ble.fade(value) },
                    cloudAction: {
                        let remoteID = try self.remoteID(for: lamp)
                        try await self.sendCloudCommand(lampID: remoteID, action: "setFadeMode", value: value)
                    }
                )
            } catch { handle(error) }
        }
    }

    func setTimer(_ lamp: LampRecord, minutes: Int) {
        let value = [0, 15, 30, 60].contains(minutes) ? minutes : 0
        let seconds = Int64(value * 60)
        optimistic(lamp.id) { $0.state.timerRemainingSeconds = seconds }
        registerTimerState(for: lamp, remainingSeconds: seconds, receivedAt: Date())
        scheduleTimerNotification(for: lamp, remainingSeconds: seconds)
        Task {
            do {
                try await performRouted(
                    lamp: lamp,
                    localAction: { host in try await self.local.sendTimer(host: host, minutes: value) },
                    bleAction: { self.ble.timer(value) },
                    cloudAction: {
                        let remoteID = try self.remoteID(for: lamp)
                        try await self.sendCloudCommand(lampID: remoteID, action: "setTimer", value: value)
                    }
                )
            } catch { handle(error) }
        }
    }

    func identify(_ lamp: LampRecord) {
        Task {
            do {
                try await performRouted(
                    lamp: lamp,
                    localAction: { host in
                        try await self.local.identify(host: host)
                        return try await self.local.readStatus(host: host)
                    },
                    bleAction: { self.ble.identify() },
                    cloudAction: {
                        let remoteID = try self.remoteID(for: lamp)
                        try await self.sendCloudCommand(lampID: remoteID, action: "identify", value: true)
                    }
                )
            } catch { handle(error) }
        }
    }

    func saveSettings(_ lamp: LampRecord, name: String, roomID: String?) async -> Bool {
        busy = true
        errorMessage = ""
        defer { busy = false }
        do {
            if canUseBLE(lamp) { ble.renameLamp(name) }
            if let host = lamp.localHost { _ = try? await local.rename(host: host, name: name) }
            if let remoteID = lamp.cloudLampId ?? (lamp.id.hasPrefix("SH-") ? lamp.id : nil) {
                let updated = try await withAccessToken { token in
                    try await api.updateDevice(accessToken: token, lampId: remoteID, displayName: name, roomId: roomID, updateRoom: true)
                }
                dashboard.lamps.removeAll { $0.id == updated.id }
                dashboard.lamps.append(updated)
            }
            rebuildLamps()
            notice = "Lamp settings saved."
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func releaseLamp(_ lamp: LampRecord) async -> ReleasedLamp? {
        guard let remoteID = lamp.cloudLampId ?? (lamp.id.hasPrefix("SH-") ? lamp.id : nil) else { return nil }
        busy = true
        defer { busy = false }
        do {
            let released = try await withAccessToken { token in try await api.releaseDevice(accessToken: token, lampId: remoteID) }
            dashboard.lamps.removeAll { $0.id.caseInsensitiveCompare(remoteID) == .orderedSame }
            for key in Array(localRecords.keys) {
                guard var localRecord = localRecords[key], localRecord.cloudLampId?.caseInsensitiveCompare(remoteID) == .orderedSame else { continue }
                localRecord.cloudLampId = nil
                localRecord.cloudClaimed = false
                localRecords[key] = localRecord
            }
            persistLocalRecords()
            rebuildLamps()
            notice = "Lamp released. Save the new claim code: \(released.newClaimCode)"
            return released
        } catch { handle(error); return nil }
    }

    private func remoteID(for lamp: LampRecord) throws -> String {
        if lamp.cloudClaimed,
           let cloud = lamp.cloudLampId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cloud.isEmpty,
           dashboard.lamps.contains(where: { $0.id.caseInsensitiveCompare(cloud) == .orderedSame }) {
            return cloud.uppercased()
        }
        let direct = lamp.id.uppercased()
        guard direct.hasPrefix("SH-") && dashboard.lamps.contains(where: {
            $0.id.caseInsensitiveCompare(direct) == .orderedSame
        }) else {
            throw AppError.message("Move closer to the lamp or enable remote access.")
        }
        return direct
    }

    private func performRouted(
        lamp: LampRecord,
        localAction: ((String) async throws -> WiFiLampSnapshot)?,
        bleAction: (() -> Void)?,
        cloudAction: (() async throws -> Void)?
    ) async throws {
        let order = routeOrder(for: lamp)

        var lastFailure: Error?
        for route in order {
            switch route {
            case .wifi:
                guard isWiFiHealthy(lamp), let host = lamp.localHost, let localAction else { continue }
                do {
                    let requestStartedAt = Date()
                    apply(snapshot: try await localAction(host), observedAt: requestStartedAt, authoritative: true)
                    return
                } catch {
                    lastFailure = error
                    markWiFiFailure(for: lamp)
                }
            case .bluetooth:
                guard canUseBLE(lamp), let bleAction else { continue }
                bleAction()
                updateLocalRecord(for: lamp) { $0.route = .bluetooth; $0.online = true }
                return
            case .cloud:
                guard let cloudAction else { continue }
                do {
                    try await cloudAction()
                    updateLocalRecord(for: lamp) { record in
                        if record.route == .offline { record.online = true }
                    }
                    return
                } catch {
                    lastFailure = error
                }
            case .offline:
                continue
            }
        }
        throw lastFailure ?? AppError.message("No available connection could control this lamp.")
    }

    private func routeOrder(for lamp: LampRecord) -> [LampConnectionRoute] {
        switch lamp.routePreference {
        case .remote:
            return [.cloud]
        case .bluetooth:
            return [.bluetooth, .cloud, .wifi]
        case .wifi:
            return [.wifi, .bluetooth, .cloud]
        case .automatic:
            return [.wifi, .bluetooth, .cloud]
        }
    }

    private func markWiFiFailure(for lamp: LampRecord) {
        let key = lamp.id.uppercased()
        wifiConfirmedAt.removeValue(forKey: key)
        let failures = (localFailureCounts[key] ?? 0) + 1
        localFailureCounts[key] = failures
        updateLocalRecord(for: lamp) { record in
            // Keep a remembered host through short network interruptions; only
            // discard it after repeated failures so Bonjour can recover without
            // forcing a full setup flow.
            if failures >= 3 { record.localHost = nil }
            record.route = self.canUseBLE(lamp) ? .bluetooth : .offline
            record.online = record.route != .offline
        }
    }

    private func updateLocalRecord(for lamp: LampRecord, change: (inout LampRecord) -> Void) {
        let keys = [lamp.id.uppercased(), lamp.cloudLampId?.uppercased()].compactMap { $0 }
        let existingKey = localRecords.keys.first { key in
            keys.contains(key) || localRecords[key]?.cloudLampId.map { keys.contains($0.uppercased()) } == true
        }
        let key = existingKey ?? lamp.id.uppercased()
        var record = localRecords[key] ?? lamp
        change(&record)
        localRecords[key] = record
        persistLocalRecords()
        rebuildLamps()
    }

    private func startLiveClock() {
        liveClockTask?.cancel()
        liveClockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.liveClock = Date()
            }
        }
    }

    private func startLocalStatusPolling() {
        localPollTask?.cancel()
        localPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.wifiPathAvailable {
                    let records = self.localRecords.values.filter { $0.localHost != nil }
                    for record in records {
                        guard let host = record.localHost else { continue }
                        let key = record.id.uppercased()
                        guard !self.localPollInFlight.contains(key) else { continue }
                        self.localPollInFlight.insert(key)
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            defer { self.localPollInFlight.remove(key) }
                            let requestStartedAt = Date()
                            if let snapshot = try? await self.local.readStatus(host: host) {
                                self.apply(snapshot: snapshot, observedAt: requestStartedAt)
                            } else {
                                self.noteLocalPollFailure(record)
                            }
                        }
                    }
                }
                try? await Task.sleep(for: self.localPollInterval)
            }
        }
    }

    private func noteLocalPollFailure(_ lamp: LampRecord) {
        let key = lamp.id.uppercased()
        wifiConfirmedAt.removeValue(forKey: key)
        let failures = (localFailureCounts[key] ?? 0) + 1
        localFailureCounts[key] = failures
        guard failures >= 3, var record = localRecords[key] else {
            rebuildLamps()
            return
        }
        record.localHost = nil
        record.route = canUseBLE(record) ? .bluetooth : .offline
        record.online = record.route != .offline
        localRecords[key] = record
        persistLocalRecords()
        rebuildLamps()
    }

    private func isWiFiHealthy(_ lamp: LampRecord, now: Date = Date()) -> Bool {
        guard wifiPathAvailable, lamp.localHost != nil else { return false }
        let keys = [lamp.id.uppercased(), lamp.cloudLampId?.uppercased()].compactMap { $0 }
        guard let last = keys.compactMap({ wifiConfirmedAt[$0] }).max() else { return false }
        return now.timeIntervalSince(last) <= wifiHealthTTL
    }

    private func registerTimerState(for lamp: LampRecord, remainingSeconds: Int64, receivedAt: Date) {
        let keys = [lamp.id.uppercased(), lamp.cloudLampId?.uppercased()].compactMap { $0 }
        if remainingSeconds > 0 {
            let deadline = receivedAt.addingTimeInterval(TimeInterval(remainingSeconds))
            for key in keys { timerDeadlines[key] = deadline }
        } else {
            for key in keys { timerDeadlines.removeValue(forKey: key) }
        }
    }

    func remainingTimerSeconds(for lamp: LampRecord) -> Int64 {
        _ = liveClock // Explicit dependency so SwiftUI refreshes once per second.
        let keys = [lamp.id.uppercased(), lamp.cloudLampId?.uppercased()].compactMap { $0 }
        if let deadline = keys.compactMap({ timerDeadlines[$0] }).max() {
            return max(0, Int64(ceil(deadline.timeIntervalSince(liveClock))))
        }
        return max(0, lamp.state.timerRemainingSeconds)
    }

    private func scheduleTimerNotification(for lamp: LampRecord, remainingSeconds: Int64) {
        let notificationID = "shlamp.timer.\(lamp.canonicalID.uppercased())"
        let center = UNUserNotificationCenter.current()
        if remainingSeconds <= 0 {
            notificationDeadlines.removeValue(forKey: lamp.canonicalID.uppercased())
            center.removePendingNotificationRequests(withIdentifiers: [notificationID])
            return
        }

        let deadline = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        if let existing = notificationDeadlines[lamp.canonicalID.uppercased()],
           abs(existing.timeIntervalSince(deadline)) < 2 { return }
        notificationDeadlines[lamp.canonicalID.uppercased()] = deadline

        Task {
            let settings = await center.notificationSettings()
            var allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if settings.authorizationStatus == .notDetermined {
                allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            }
            guard allowed else { return }

            let content = UNMutableNotificationContent()
            content.title = lamp.name
            content.body = "The auto-off timer has finished."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, TimeInterval(remainingSeconds)), repeats: false)
            center.removePendingNotificationRequests(withIdentifiers: [notificationID])
            try? await center.add(UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger))
        }
    }

    private func sendCloudCommand(lampID: String, action: String, value: Any) async throws {
        if cloudConnected {
            do {
                _ = try await realtime.sendCommand(lampID: lampID, action: action, value: value)
                return
            } catch {
                // The REST queue is a durable fallback if the live socket drops
                // between UI route selection and the actual send.
            }
        }
        _ = try await withAccessToken { token in
            try await api.sendCommand(
                accessToken: token,
                lampId: lampID,
                action: action,
                payload: ["value": value]
            )
        }
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let hasWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.wifiPathAvailable != hasWiFi
                self.wifiPathAvailable = hasWiFi
                guard changed else { return }
                if hasWiFi {
                    self.local.startDiscovery()
                } else {
                    self.local.stopDiscovery()
                    self.wifiConfirmedAt.removeAll()
                    for key in Array(self.localRecords.keys) {
                        guard var record = self.localRecords[key], record.route == .wifi else { continue }
                        record.route = self.canUseBLE(record) ? .bluetooth : .offline
                        record.online = record.route != .offline
                        self.localRecords[key] = record
                    }
                    self.persistLocalRecords()
                    self.rebuildLamps()
                }
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func restoreLocalRecords() {
        guard let data = UserDefaults.standard.data(forKey: localStoreKey),
              let records = try? JSONDecoder().decode([LampRecord].self, from: data) else { return }
        localRecords = Dictionary(uniqueKeysWithValues: records.map { record in
            var restored = record
            restored.route = .offline
            restored.online = false
            // Account ownership is session-scoped and must be proven again by
            // the signed-in user's cloud dashboard. Keep the reported cloud ID,
            // but never trust a persisted Boolean from another account/session.
            restored.cloudClaimed = false
            return (restored.id.uppercased(), restored)
        })
    }

    private func persistLocalRecords() {
        let records = localRecords.values.filter { !transientLocalIDs.contains($0.id.uppercased()) }
        if let data = try? JSONEncoder().encode(Array(records)) {
            UserDefaults.standard.set(data, forKey: localStoreKey)
        }
    }

    private func shouldIdentityProbe(_ nearby: NearbyLamp) -> Bool {
        guard !manualAddFlowActive,
              identityProbePeripheralID == nil,
              !probedPeripheralIDs.contains(nearby.id),
              !ble.isReady else { return false }
        let hasCloudOnlyLamp = dashboard.lamps.contains { cloud in
            !localRecords.values.contains { local in
                local.cloudLampId?.caseInsensitiveCompare(cloud.id) == .orderedSame && local.bleIdentifier != nil
            }
        }
        return hasCloudOnlyLamp
    }

    private func knownRecord(for nearby: NearbyLamp) -> LampRecord? {
        let nearbyID = nearby.lampId.uppercased()
        return lamps.first { lamp in
            lamp.bleIdentifier == nearby.id ||
                lamp.id.uppercased() == nearbyID ||
                lamp.cloudLampId?.uppercased() == nearbyID ||
                (nearbyID.hasPrefix("SH-") && nearbyID.count == 9 && lamp.canonicalID.hasSuffix(String(nearbyID.dropFirst(3))))
        }
    }

    private func withAccessToken<T>(_ operation: (String) async throws -> T) async throws -> T {
        guard var current = session else { throw AppError.unauthorized }
        do { return try await operation(current.accessToken) }
        catch AppError.unauthorized {
            let refreshed = try await api.refresh(refreshToken: current.refreshToken)
            try keychain.save(refreshed)
            session = refreshed
            current = refreshed
            return try await operation(current.accessToken)
        }
    }

    private func canUseBLE(_ lamp: LampRecord) -> Bool {
        guard ble.isBluetoothPoweredOn, ble.isReady else { return false }
        let candidates = [lamp.id.uppercased(), lamp.cloudLampId?.uppercased()].compactMap { $0 }
        return candidates.contains(connectedLocalID.uppercased()) || lamp.bleIdentifier == ble.connectedPeripheralID
    }

    private func optimistic(_ lampID: String, change: (inout LampRecord) -> Void) {
        let now = Date()
        if let index = lamps.firstIndex(where: { $0.id == lampID }) {
            change(&lamps[index])
            optimisticStateAt[lamps[index].id.uppercased()] = now
            optimisticStateAt[lamps[index].canonicalID.uppercased()] = now
        }
        if let index = dashboard.lamps.firstIndex(where: { $0.id == lampID }) { change(&dashboard.lamps[index]) }
        if var local = localRecords[lampID] { change(&local); localRecords[lampID] = local }
    }

    private func apply(snapshot: WiFiLampSnapshot, observedAt: Date = Date(), authoritative: Bool = false) {
        let localID = snapshot.lampId.uppercased()
        let receivedAt = Date()
        let stateObservedAt = authoritative ? receivedAt : observedAt
        localSnapshots[localID] = snapshot
        wifiConfirmedAt[localID] = receivedAt
        localStateReceivedAt[localID] = stateObservedAt
        localFailureCounts[localID] = 0
        if authoritative { optimisticStateAt.removeValue(forKey: localID) }

        let cloudID = snapshot.cloudLampId?.uppercased()
        if let cloudID {
            wifiConfirmedAt[cloudID] = receivedAt
            localStateReceivedAt[cloudID] = stateObservedAt
            localFailureCounts[cloudID] = 0
            if authoritative { optimisticStateAt.removeValue(forKey: cloudID) }
        }
        let existingKey = localRecords.keys.first { key in
            key == localID ||
                localRecords[key]?.id.uppercased() == localID ||
                (cloudID != nil && localRecords[key]?.cloudLampId?.uppercased() == cloudID)
        }
        let key = existingKey ?? localID
        var record = localRecords[key] ?? .placeholder(id: localID, name: snapshot.lampName)
        let previous = record
        record.id = localID
        record.cloudLampId = cloudID ?? record.cloudLampId
        if let cloudID, dashboard.lamps.contains(where: { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame }) {
            record.cloudClaimed = true
        }
        record.name = snapshot.lampName.isEmpty ? record.name : snapshot.lampName
        record.firmware = snapshot.firmware
        record.online = true
        record.localHost = snapshot.host
        record.wifiSSID = snapshot.activeSSID.isEmpty ? snapshot.ssid : snapshot.activeSSID
        record.wifiRSSI = snapshot.rssi
        record.bleName = snapshot.bleName.isEmpty ? record.bleName : snapshot.bleName
        record.controllerCount = snapshot.controllerCount
        record.state = LampState(
            power: snapshot.power,
            brightness: snapshot.targetBrightness,
            fadeMode: snapshot.fadeMode,
            timerRemainingSeconds: snapshot.timerRemainingSeconds,
            batteryValid: snapshot.batteryValid,
            batteryPercent: snapshot.batteryPercent,
            batteryVoltageMv: snapshot.batteryVoltageMv,
            batteryCharging: snapshot.batteryCharging,
            powerMode: snapshot.powerMode,
            runtimeState: snapshot.runtimeState
        )
        registerTimerState(for: record, remainingSeconds: snapshot.timerRemainingSeconds, receivedAt: receivedAt)
        scheduleTimerNotification(for: record, remainingSeconds: snapshot.timerRemainingSeconds)
        let bluetoothPreferred = record.routePreference == .bluetooth && canUseBLE(record)
        record.route = bluetoothPreferred ? .bluetooth : .wifi
        if key != localID { localRecords.removeValue(forKey: key) }
        localRecords[localID] = record
        let metadataChanged = key != localID ||
            previous.cloudLampId != record.cloudLampId ||
            previous.name != record.name ||
            previous.firmware != record.firmware ||
            previous.localHost != record.localHost ||
            previous.wifiSSID != record.wifiSSID ||
            previous.bleName != record.bleName ||
            previous.controllerCount != record.controllerCount
        if metadataChanged { persistLocalRecords() }
        rebuildLamps()
    }

    private func rebuildLamps() {
        var normalizedLocal: [String: LampRecord] = [:]
        for var localRecord in localRecords.values {
            let localKey = localRecord.id.uppercased()
            localRecord.id = localKey
            localRecord.cloudClaimed = localRecord.cloudLampId.map { cloudID in
                dashboard.lamps.contains { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame }
            } ?? false
            if var existing = normalizedLocal[localKey] {
                existing = mergeRecords(existing, localRecord)
                normalizedLocal[localKey] = existing
            } else {
                normalizedLocal[localKey] = localRecord
            }
        }
        localRecords = normalizedLocal

        var cloudByID: [String: LampRecord] = [:]
        for var cloud in dashboard.lamps {
            let cloudID = cloud.id.uppercased()
            cloud.id = cloudID
            cloud.cloudLampId = cloudID
            cloud.cloudClaimed = true
            cloud.route = cloud.online ? .cloud : .offline
            cloudByID[cloudID] = cloud
        }

        var result: [String: LampRecord] = cloudByID
        for local in localRecords.values {
            let cloudKey = local.cloudLampId?.uppercased()
            let destinationKey = cloudKey ?? local.id.uppercased()
            if var combined = cloudKey.flatMap({ result[$0] }) ?? result[local.id.uppercased()] {
                combined = mergeRecords(combined, local)
                combined.route = selectedRoute(for: combined, local: local, cloud: cloudKey.flatMap { cloudByID[$0] })
                combined.online = combined.route != .offline
                result[destinationKey] = combined
                if destinationKey != local.id.uppercased() { result.removeValue(forKey: local.id.uppercased()) }
            } else {
                var onlyLocal = local
                onlyLocal.route = selectedRoute(for: onlyLocal, local: local, cloud: nil)
                onlyLocal.online = onlyLocal.route != .offline
                result[destinationKey] = onlyLocal
            }
        }

        lamps = result.values
            .filter { !transientLocalIDs.contains($0.id.uppercased()) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func mergeRecords(_ primary: LampRecord, _ local: LampRecord) -> LampRecord {
        var merged = primary
        merged.cloudLampId = local.cloudLampId ?? merged.cloudLampId
        merged.cloudClaimed = merged.cloudClaimed || local.cloudClaimed
        merged.name = local.name == "SH Lamp" && merged.name != "SH Lamp" ? merged.name : local.name
        merged.roomId = local.roomId ?? merged.roomId
        merged.roomName = local.roomName ?? merged.roomName
        merged.routePreference = local.routePreference
        merged.bleIdentifier = local.bleIdentifier ?? merged.bleIdentifier
        merged.bleName = local.bleName ?? merged.bleName
        merged.localHost = local.localHost ?? merged.localHost
        merged.wifiSSID = local.wifiSSID ?? merged.wifiSSID
        merged.wifiRSSI = local.wifiRSSI != -127 ? local.wifiRSSI : merged.wifiRSSI
        merged.bleRSSI = local.bleRSSI != -127 ? local.bleRSSI : merged.bleRSSI
        merged.firmware = local.firmware ?? merged.firmware
        merged.controllerCount = max(local.controllerCount, merged.controllerCount)
        let localKeys = [local.id.uppercased(), local.cloudLampId?.uppercased()].compactMap { $0 }
        let cloudKeys = [primary.id.uppercased(), primary.cloudLampId?.uppercased()].compactMap { $0 }
        let localFullStateAt = localKeys.compactMap { key in
            [localStateReceivedAt[key], bleStateReceivedAt[key]].compactMap { $0 }.max()
        }.max()
        let cloudAt = cloudKeys.compactMap { cloudStateReceivedAt[$0] }.max()
        let optimisticAt = (localKeys + cloudKeys).compactMap { optimisticStateAt[$0] }.max()
        let primaryFreshness = [cloudAt, optimisticAt].compactMap { $0 }.max()

        // The newest confirmed/optimistic full state wins. Route preference is
        // used for command transport, not for deciding whether an older state
        // may overwrite a newer state from another transport.
        let localClearsOptimisticHold: Bool
        if let localFullStateAt, let optimisticAt {
            localClearsOptimisticHold = localFullStateAt.timeIntervalSince(optimisticAt) >= 0.75
        } else {
            localClearsOptimisticHold = optimisticAt == nil
        }

        if (isWiFiHealthy(local) || canUseBLE(local)),
           let localFullStateAt,
           localClearsOptimisticHold,
           primaryFreshness == nil || localFullStateAt >= primaryFreshness! {
            merged.state = local.state
        }

        // Battery Level is a separate BLE notification and can legitimately be
        // newer than the rest of the BLE status packet. Merge only battery
        // fields in that case instead of letting a battery notification revive
        // stale power/brightness/timer values.
        if let batteryAt = localKeys.compactMap({ batteryStateReceivedAt[$0] }).max(),
           (primaryFreshness == nil || batteryAt >= primaryFreshness!),
           local.state.batteryValid {
            merged.state.batteryValid = true
            merged.state.batteryPercent = local.state.batteryPercent
            merged.state.batteryVoltageMv = local.state.batteryVoltageMv ?? merged.state.batteryVoltageMv
            merged.state.batteryCharging = local.state.batteryCharging ?? merged.state.batteryCharging
        }
        return merged
    }

    private func selectedRoute(for lamp: LampRecord, local: LampRecord?, cloud: LampRecord?) -> LampConnectionRoute {
        let hasWiFi = local.map { isWiFiHealthy($0) } ?? false
        let hasBLE = local.map(canUseBLE) ?? false
        let linkedCloud = lamp.cloudLampId.flatMap { cloudID in
            dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame })
        }
        let hasCloud = cloud?.online == true || linkedCloud?.online == true

        switch lamp.routePreference {
        case .remote:
            return hasCloud ? .cloud : .offline
        case .bluetooth:
            if hasBLE { return .bluetooth }
            if hasCloud { return .cloud }
            if hasWiFi { return .wifi }
        case .wifi:
            if hasWiFi { return .wifi }
            if hasBLE { return .bluetooth }
            if hasCloud { return .cloud }
        case .automatic:
            if hasWiFi { return .wifi }
            if hasBLE { return .bluetooth }
            if hasCloud { return .cloud }
        }
        return .offline
    }

    private func applyCloudLamp(_ incoming: LampRecord, receivedAt: Date) {
        var lamp = incoming
        let id = lamp.id.uppercased()
        lamp.id = id
        lamp.cloudLampId = id
        lamp.cloudClaimed = true
        lamp.route = lamp.online ? .cloud : .offline

        if let existing = dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            if lamp.name == "SH Lamp" && existing.name != "SH Lamp" { lamp.name = existing.name }
            if lamp.homeId.isEmpty || lamp.homeId == "default" { lamp.homeId = existing.homeId }
            lamp.roomId = lamp.roomId ?? existing.roomId
            lamp.roomName = lamp.roomName ?? existing.roomName
            if lamp.model.isEmpty { lamp.model = existing.model }
            lamp.firmware = lamp.firmware ?? existing.firmware
            lamp.routePreference = existing.routePreference
        }

        cloudStateReceivedAt[id] = receivedAt
        optimisticStateAt.removeValue(forKey: id)
        registerTimerState(for: lamp, remainingSeconds: lamp.state.timerRemainingSeconds, receivedAt: receivedAt)
        scheduleTimerNotification(for: lamp, remainingSeconds: lamp.state.timerRemainingSeconds)
        dashboard.lamps.removeAll { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        dashboard.lamps.append(lamp)
        rebuildLamps()
    }

    private func handle(_ error: Error) {
        if case AppError.unauthorized = error { signOut(message: "Your sign-in expired.") }
        else { errorMessage = error.localizedDescription }
    }
}

extension AppViewModel: BLELampManagerDelegate {
    func bleManager(_ manager: BLELampManager, didUpdateNearby lamps: [NearbyLamp]) {
        nearbyLamps = lamps
        guard !manualAddFlowActive, !manager.isReady, pendingAutoConnectPeripheralID == nil else { return }

        if let known = lamps.first(where: { nearby in
            guard let record = knownRecord(for: nearby) else { return false }
            return record.routePreference != .remote
        }) {
            pendingAutoConnectPeripheralID = known.id
            manager.connect(to: known.id)
            return
        }

        if let candidate = lamps.first(where: shouldIdentityProbe) {
            identityProbePeripheralID = candidate.id
            identityProbeMatched = false
            pendingAutoConnectPeripheralID = candidate.id
            manager.connect(to: candidate.id)
        }
    }

    func bleManager(_ manager: BLELampManager, didChangeStatus status: String) {
        bluetoothStatus = status
    }

    func bleManager(_ manager: BLELampManager, didResolveLocalID localID: String, cloudID: String?) {
        let localKey = localID.uppercased()
        let normalizedCloudID = cloudID?.uppercased()
        connectedLocalID = localKey
        if manualAddFlowActive { setupConnectedLampID = localKey }

        let cloudMatch = normalizedCloudID.flatMap { candidate in
            dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(candidate) == .orderedSame })
        }
        let existing = localRecords[localKey] ?? normalizedCloudID.flatMap { candidate in
            localRecords.values.first(where: { $0.cloudLampId?.caseInsensitiveCompare(candidate) == .orderedSame })
        }

        if identityProbePeripheralID != nil && !manualAddFlowActive {
            identityProbeMatched = cloudMatch != nil || existing != nil
        } else {
            identityProbeMatched = true
        }

        guard manualAddFlowActive || identityProbeMatched || existing != nil else { return }
        var record = existing ?? cloudMatch ?? .placeholder(id: localKey)
        record.id = localKey
        record.cloudLampId = normalizedCloudID ?? record.cloudLampId
        if cloudMatch != nil { record.cloudClaimed = true }
        if manualAddFlowActive && existing == nil && cloudMatch == nil {
            transientLocalIDs.insert(localKey)
        }
        localRecords[localKey] = record
        persistLocalRecords()
        rebuildLamps()
    }

    func bleManager(_ manager: BLELampManager, didConnect lampID: String, peripheralID: UUID, name: String) {
        pendingAutoConnectPeripheralID = nil
        let localKey = (connectedLocalID.isEmpty ? lampID : connectedLocalID).uppercased()

        if identityProbePeripheralID == peripheralID && !identityProbeMatched && !manualAddFlowActive {
            probedPeripheralIDs.insert(peripheralID)
            identityProbePeripheralID = nil
            manager.disconnect()
            manager.startScan()
            return
        }

        identityProbePeripheralID = nil
        identityProbeMatched = false
        connectedLocalID = localKey
        if manualAddFlowActive { setupConnectedLampID = localKey }

        let linkedCloud = localRecords[localKey]?.cloudLampId
        var record = localRecords[localKey]
            ?? linkedCloud.flatMap { cloudID in dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame }) }
            ?? .placeholder(id: localKey)
        record.id = localKey
        record.bleIdentifier = peripheralID
        record.bleName = name
        record.bleRSSI = nearbyLamps.first(where: { $0.id == peripheralID })?.rssi ?? record.bleRSSI
        let keepWiFi = record.routePreference != .bluetooth && isWiFiHealthy(record)
        record.route = keepWiFi ? .wifi : .bluetooth
        record.online = true
        localRecords[localKey] = record
        persistLocalRecords()
        rebuildLamps()
    }

    func bleManager(_ manager: BLELampManager, didDisconnect peripheralID: UUID?) {
        pendingAutoConnectPeripheralID = nil
        if identityProbePeripheralID == peripheralID {
            if let peripheralID { probedPeripheralIDs.insert(peripheralID) }
            identityProbePeripheralID = nil
            identityProbeMatched = false
        }
        for key in Array(localRecords.keys) {
            guard var record = localRecords[key], peripheralID == nil || record.bleIdentifier == peripheralID else { continue }
            record.route = selectedRoute(for: record, local: record, cloud: record.cloudLampId.flatMap { cloudID in
                dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame })
            })
            record.online = record.route != .offline
            localRecords[key] = record
        }
        connectedLocalID = ""
        persistLocalRecords()
        rebuildLamps()
        if !manualAddFlowActive { manager.startScan() }
    }

    func bleManager(_ manager: BLELampManager, didReceive status: BLELampStatus) {
        let key = (status.lampId.isEmpty ? connectedLocalID : status.lampId).uppercased()
        guard !key.isEmpty else { return }
        var record = localRecords[key] ?? .placeholder(id: key)
        let receivedAt = Date()
        bleStateReceivedAt[key] = receivedAt
        optimisticStateAt.removeValue(forKey: key)
        if let cloudID = record.cloudLampId?.uppercased() {
            bleStateReceivedAt[cloudID] = receivedAt
            optimisticStateAt.removeValue(forKey: cloudID)
        }
        let keepWiFi = record.routePreference != .bluetooth && isWiFiHealthy(record)
        record.route = keepWiFi ? .wifi : .bluetooth
        record.online = true
        record.bleRSSI = status.rssi
        record.state.power = status.power
        record.state.brightness = status.targetBrightness
        record.state.fadeMode = status.fadeMode
        record.state.timerRemainingSeconds = status.timerRemainingSeconds
        registerTimerState(for: record, remainingSeconds: status.timerRemainingSeconds, receivedAt: receivedAt)
        scheduleTimerNotification(for: record, remainingSeconds: status.timerRemainingSeconds)
        localRecords[key] = record
        rebuildLamps()
    }

    func bleManager(_ manager: BLELampManager, didReceiveBattery percent: Int, lampID: String) {
        let key = (lampID.isEmpty ? connectedLocalID : lampID).uppercased()
        guard !key.isEmpty else { return }
        var record = localRecords[key] ?? .placeholder(id: key)
        let receivedAt = Date()
        batteryStateReceivedAt[key] = receivedAt
        if let cloudID = record.cloudLampId?.uppercased() { batteryStateReceivedAt[cloudID] = receivedAt }
        record.state.batteryValid = true
        record.state.batteryPercent = clamp(percent, 0...100)
        localRecords[key] = record
        rebuildLamps()
    }

    func bleManager(_ manager: BLELampManager, didReceiveWiFiStatus status: String) {
        bluetoothStatus = status
        if status.contains("CONNECTED") || status.contains("ONLINE") || status.hasPrefix("W:IP:") {
            local.startDiscovery()
        }
    }

    func bleManager(_ manager: BLELampManager, didReceivePowerMode mode: LampPowerMode) {
        let key = connectedLocalID.uppercased()
        guard !key.isEmpty else { return }
        var record = localRecords[key] ?? .placeholder(id: key)
        record.state.powerMode = mode
        record.state.runtimeState = mode == .touchOnly ? .touchOnly : .active
        if mode == .maximumBackup { record.state.brightness = min(record.state.brightness, 70) }
        localRecords[key] = record
        persistLocalRecords()
        rebuildLamps()
    }

    func bleManager(_ manager: BLELampManager, bluetoothPoweredOn: Bool) {
        if bluetoothPoweredOn {
            probedPeripheralIDs.removeAll()
            if !manualAddFlowActive { manager.startScan() }
        } else {
            pendingAutoConnectPeripheralID = nil
            identityProbePeripheralID = nil
            identityProbeMatched = false
            connectedLocalID = ""
            for key in Array(localRecords.keys) {
                guard var record = localRecords[key], record.route == .bluetooth else { continue }
                record.route = selectedRoute(for: record, local: record, cloud: record.cloudLampId.flatMap { cloudID in
                    dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame })
                })
                record.online = record.route != .offline
                localRecords[key] = record
            }
            persistLocalRecords()
            rebuildLamps()
        }
    }

    func bleManager(_ manager: BLELampManager, didReceiveSavedNetworks networks: [SavedWiFiNetwork]) { savedWiFiNetworks = networks }
    func bleManager(_ manager: BLELampManager, didReceiveControllers controllers: [LampControllerAccess]) { self.controllers = controllers }
    func bleManager(_ manager: BLELampManager, didFail message: String) {
        pendingAutoConnectPeripheralID = nil
        errorMessage = message
    }
}

extension AppViewModel: LocalLampControllerDelegate {
    func localController(_ controller: LocalLampController, didDiscover snapshot: WiFiLampSnapshot) { apply(snapshot: snapshot) }
    func localController(_ controller: LocalLampController, didChangeStatus status: String) { localNetworkStatus = status }
}

extension AppViewModel: CloudRealtimeClientDelegate {
    func realtimeClient(_ client: CloudRealtimeClient, didChangeStatus status: String, connected: Bool) {
        cloudStatus = status
        cloudConnected = connected
    }

    func realtimeClient(_ client: CloudRealtimeClient, didReceive object: JSONObject) {
        let type = object.string("type")
        let receivedAt = Date()

        if type == "authOk", let devices = object.array("devices") {
            let liveDevices = devices.compactMap { item -> LampRecord? in
                guard let json = item as? JSONObject else { return nil }
                return api.parseLamp(json)
            }
            if !liveDevices.isEmpty {
                for lamp in liveDevices { applyCloudLamp(lamp, receivedAt: receivedAt) }
            }
            return
        }

        if type == "state" || type == "ack" {
            var envelope = object
            envelope["online"] = true
            if (type == "state" || object.object("state") != nil), let lamp = api.parseLamp(envelope) {
                applyCloudLamp(lamp, receivedAt: receivedAt)
            }
            if type == "ack", object.bool("success") == false {
                let message = firstNonBlank(object.string("error"), "The lamp rejected the cloud command.")
                errorMessage = message
            }
            return
        }

        if type == "deviceOnline" || type == "deviceOffline" {
            let id = object.string("lampId").uppercased()
            guard !id.isEmpty else { return }
            let isOnline = type == "deviceOnline" ? (object.bool("online") ?? true) : false
            if let index = dashboard.lamps.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
                dashboard.lamps[index].online = isOnline
                dashboard.lamps[index].route = isOnline ? .cloud : .offline
                dashboard.lamps[index].lastSeen = ISO8601DateFormatter().string(from: receivedAt)
                rebuildLamps()
            }
            return
        }

        let candidate = object.object("lamp") ?? object.object("device") ?? object.object("data")?.object("lamp") ?? object.object("data")?.object("device")
        if let candidate, let lamp = api.parseLamp(candidate) {
            applyCloudLamp(lamp, receivedAt: receivedAt)
        }
    }
}
