import Foundation
import SwiftUI

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

    init() {
        ble.delegate = self
        local.delegate = self
        realtime.delegate = self
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
        lamps = []
        localRecords.removeAll()
        localSnapshots.removeAll()
        notice = message
        errorMessage = ""
    }

    func refreshDashboard(silent: Bool = false) async throws {
        if !silent { busy = true }
        defer { if !silent { busy = false } }
        let loaded = try await withAccessToken { token in try await api.loadDashboard(accessToken: token) }
        dashboard = loaded
        rebuildLamps()
        startConnections()
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
        ble.startScan()
        if let token = session?.accessToken {
            realtime.start(token: token, homeID: dashboard.homes.first?.id ?? "default")
        }
    }

    func connect(_ nearby: NearbyLamp) {
        connectedLocalID = nearby.lampId
        ble.connect(to: nearby.id)
    }

    func provisionWiFi(ssid: String, password: String) {
        ble.provisionWiFi(ssid: ssid, password: password)
        notice = "Wi-Fi details sent to the lamp. It may take a few seconds to join the network."
    }

    func claimLamp(lampID: String, claimCode: String, displayName: String, roomID: String?) async -> Bool {
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
        optimistic(lamp.id) { $0.state.power = on; if on && $0.state.brightness == 0 { $0.state.brightness = 20 } }
        Task {
            do {
                if canUseBLE(lamp) { ble.power(on); return }
                if let host = lamp.localHost {
                    apply(snapshot: try await local.sendPower(host: host, on: on)); return
                }
                guard let remoteID = lamp.cloudLampId ?? (lamp.id.hasPrefix("SH-") ? lamp.id : nil) else {
                    throw AppError.message("Move closer to the lamp or link it to your account.")
                }
                _ = try await withAccessToken { token in
                    try await api.sendCommand(accessToken: token, lampId: remoteID, action: "setPower", payload: ["power": on, "on": on, "value": on])
                }
                scheduleRefresh()
            } catch { handle(error) }
        }
    }

    func setBrightness(_ lamp: LampRecord, value: Int) {
        let percent = clamp(value, 0...100)
        optimistic(lamp.id) { $0.state.brightness = percent; $0.state.power = percent > 0 }
        Task {
            do {
                if canUseBLE(lamp) { ble.brightness(percent); return }
                if let host = lamp.localHost {
                    apply(snapshot: try await local.sendBrightness(host: host, percent: percent)); return
                }
                guard let remoteID = lamp.cloudLampId ?? (lamp.id.hasPrefix("SH-") ? lamp.id : nil) else {
                    throw AppError.message("Move closer to the lamp or link it to your account.")
                }
                _ = try await withAccessToken { token in
                    try await api.sendCommand(accessToken: token, lampId: remoteID, action: "setBrightness", payload: ["brightness": percent, "value": percent, "power": percent > 0])
                }
                scheduleRefresh()
            } catch { handle(error) }
        }
    }

    func setFade(_ lamp: LampRecord, mode: Int) {
        let value = clamp(mode, 0...3)
        optimistic(lamp.id) { $0.state.fadeMode = value }
        Task {
            do {
                if canUseBLE(lamp) { ble.fade(value); return }
                if let host = lamp.localHost { apply(snapshot: try await local.sendFade(host: host, mode: value)); return }
                throw AppError.message("Fade speed is available when the lamp is nearby.")
            } catch { handle(error) }
        }
    }

    func setTimer(_ lamp: LampRecord, minutes: Int) {
        let value = [0, 15, 30, 60].contains(minutes) ? minutes : 0
        optimistic(lamp.id) { $0.state.timerRemainingSeconds = Int64(value * 60) }
        Task {
            do {
                if canUseBLE(lamp) { ble.timer(value); return }
                if let host = lamp.localHost { apply(snapshot: try await local.sendTimer(host: host, minutes: value)); return }
                throw AppError.message("The auto-off timer is available when the lamp is nearby.")
            } catch { handle(error) }
        }
    }

    func identify(_ lamp: LampRecord) {
        Task {
            do {
                if canUseBLE(lamp) { ble.identify(); return }
                if let host = lamp.localHost { try await local.identify(host: host); return }
                guard let remoteID = lamp.cloudLampId ?? (lamp.id.hasPrefix("SH-") ? lamp.id : nil) else {
                    throw AppError.message("The lamp is not reachable.")
                }
                _ = try await withAccessToken { token in try await api.sendCommand(accessToken: token, lampId: remoteID, action: "identify", payload: ["value": true]) }
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
            rebuildLamps()
            notice = "Lamp released. Save the new claim code: \(released.newClaimCode)"
            return released
        } catch { handle(error); return nil }
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

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            try? await refreshDashboard(silent: true)
        }
    }

    private func canUseBLE(_ lamp: LampRecord) -> Bool {
        guard ble.isReady else { return false }
        let candidates = [lamp.id.uppercased(), lamp.cloudLampId?.uppercased()].compactMap { $0 }
        return candidates.contains(connectedLocalID.uppercased()) || lamp.bleIdentifier == ble.connectedPeripheralID
    }

    private func optimistic(_ lampID: String, change: (inout LampRecord) -> Void) {
        if let index = lamps.firstIndex(where: { $0.id == lampID }) { change(&lamps[index]) }
        if let index = dashboard.lamps.firstIndex(where: { $0.id == lampID }) { change(&dashboard.lamps[index]) }
        if var local = localRecords[lampID] { change(&local); localRecords[lampID] = local }
    }

    private func apply(snapshot: WiFiLampSnapshot) {
        localSnapshots[snapshot.lampId.uppercased()] = snapshot
        var record = localRecords[snapshot.lampId.uppercased()] ?? .placeholder(id: snapshot.lampId, name: snapshot.lampName)
        record.cloudLampId = snapshot.cloudLampId ?? record.cloudLampId
        record.name = snapshot.lampName
        record.firmware = snapshot.firmware
        record.online = true
        record.route = .wifi
        record.localHost = snapshot.host
        record.wifiSSID = snapshot.activeSSID.isEmpty ? snapshot.ssid : snapshot.activeSSID
        record.wifiRSSI = snapshot.rssi
        record.bleName = snapshot.bleName
        record.controllerCount = snapshot.controllerCount
        record.state = LampState(
            power: snapshot.power,
            brightness: snapshot.targetBrightness,
            fadeMode: snapshot.fadeMode,
            timerRemainingSeconds: snapshot.timerRemainingSeconds,
            batteryValid: snapshot.batteryValid,
            batteryPercent: snapshot.batteryPercent,
            batteryVoltageMv: snapshot.batteryVoltageMv,
            batteryCharging: snapshot.batteryCharging
        )
        localRecords[record.id.uppercased()] = record
        rebuildLamps()
    }

    private func rebuildLamps() {
        var result: [String: LampRecord] = [:]
        for cloud in dashboard.lamps {
            result[cloud.id.uppercased()] = cloud
        }
        for local in localRecords.values {
            let key = (local.cloudLampId ?? local.id).uppercased()
            if var cloud = result[key] ?? result[local.id.uppercased()] {
                cloud.bleIdentifier = local.bleIdentifier ?? cloud.bleIdentifier
                cloud.bleName = local.bleName ?? cloud.bleName
                cloud.localHost = local.localHost ?? cloud.localHost
                cloud.wifiSSID = local.wifiSSID ?? cloud.wifiSSID
                cloud.wifiRSSI = local.wifiRSSI
                cloud.bleRSSI = local.bleRSSI
                cloud.firmware = local.firmware ?? cloud.firmware
                cloud.controllerCount = max(local.controllerCount, cloud.controllerCount)
                if local.route == .bluetooth || local.route == .wifi {
                    cloud.route = local.route
                    cloud.state = local.state
                }
                result[key] = cloud
                if key != local.id.uppercased() { result.removeValue(forKey: local.id.uppercased()) }
            } else {
                result[key] = local
            }
        }
        lamps = result.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func handle(_ error: Error) {
        if case AppError.unauthorized = error { signOut(message: "Your sign-in expired.") }
        else { errorMessage = error.localizedDescription }
    }
}

extension AppViewModel: BLELampManagerDelegate {
    func bleManager(_ manager: BLELampManager, didUpdateNearby lamps: [NearbyLamp]) { nearbyLamps = lamps }
    func bleManager(_ manager: BLELampManager, didChangeStatus status: String) { bluetoothStatus = status }

    func bleManager(_ manager: BLELampManager, didResolveLocalID localID: String, cloudID: String?) {
        connectedLocalID = localID
        var record = localRecords[localID.uppercased()] ?? .placeholder(id: localID)
        record.cloudLampId = cloudID ?? record.cloudLampId
        localRecords[localID.uppercased()] = record
        rebuildLamps()
    }

    func bleManager(_ manager: BLELampManager, didConnect lampID: String, peripheralID: UUID, name: String) {
        connectedLocalID = lampID
        var record = localRecords[lampID.uppercased()] ?? .placeholder(id: lampID)
        record.bleIdentifier = peripheralID
        record.bleName = name
        record.route = .bluetooth
        record.online = true
        localRecords[lampID.uppercased()] = record
        rebuildLamps()
        ble.requestStatus()
        ble.requestWiFiStatus()
    }

    func bleManager(_ manager: BLELampManager, didDisconnect peripheralID: UUID?) {
        for key in localRecords.keys {
            if localRecords[key]?.bleIdentifier == peripheralID {
                localRecords[key]?.route = localRecords[key]?.localHost == nil ? .offline : .wifi
            }
        }
        connectedLocalID = ""
        rebuildLamps()
    }

    func bleManager(_ manager: BLELampManager, didReceive status: BLELampStatus) {
        let key = status.lampId.uppercased()
        var record = localRecords[key] ?? .placeholder(id: status.lampId)
        record.route = .bluetooth
        record.online = true
        record.bleRSSI = status.rssi
        record.state.power = status.power
        record.state.brightness = status.targetBrightness
        record.state.fadeMode = status.fadeMode
        record.state.timerRemainingSeconds = status.timerRemainingSeconds
        localRecords[key] = record
        rebuildLamps()
    }

    func bleManager(_ manager: BLELampManager, didReceiveBattery percent: Int, lampID: String) {
        guard !lampID.isEmpty else { return }
        let key = lampID.uppercased()
        var record = localRecords[key] ?? .placeholder(id: lampID)
        record.state.batteryValid = true
        record.state.batteryPercent = clamp(percent, 0...100)
        localRecords[key] = record
        rebuildLamps()
    }

    func bleManager(_ manager: BLELampManager, didReceiveWiFiStatus status: String) {
        bluetoothStatus = status
        if status.contains("CONNECTED") || status.contains("ONLINE") { local.startDiscovery() }
    }

    func bleManager(_ manager: BLELampManager, didReceiveSavedNetworks networks: [SavedWiFiNetwork]) { savedWiFiNetworks = networks }
    func bleManager(_ manager: BLELampManager, didReceiveControllers controllers: [LampControllerAccess]) { self.controllers = controllers }
    func bleManager(_ manager: BLELampManager, didFail message: String) { errorMessage = message }
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
        let candidate = object.object("lamp") ?? object.object("device") ?? object.object("data")?.object("lamp") ?? object.object("data")?.object("device")
        if let candidate, let lamp = api.parseLamp(candidate) {
            dashboard.lamps.removeAll { $0.id.caseInsensitiveCompare(lamp.id) == .orderedSame }
            dashboard.lamps.append(lamp)
            rebuildLamps()
        } else if ["deviceState", "deviceOnline", "deviceOffline", "lampState"].contains(object.string("type")) {
            scheduleRefresh()
        }
    }
}
