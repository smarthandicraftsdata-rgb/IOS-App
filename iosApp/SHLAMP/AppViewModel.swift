import Foundation
import SwiftUI
import Network
import UserNotifications


enum OrderedIntentKind: UInt8 {
    case output = 1
    case fade = 2
    case timer = 3

    var commandSuffix: String {
        switch self {
        case .output: return "O"
        case .fade: return "F"
        case .timer: return "T"
        }
    }
}

struct OrderedControlIntent {
    let controllerID: String
    let controllerSession: UInt32
    let intentSequence: UInt32
    let kind: OrderedIntentKind
    let action: String
    let value: JSONObject

    var commandID: String {
        "RF5-\(controllerID)-\(controllerSession)-\(intentSequence)-\(kind.commandSuffix)"
    }
}

/// RF5 command-order identity. The controller token is stable for this app
/// installation. Sequence numbers are leased in blocks so a crash cannot
/// reuse a number that may already be in flight, without writing UserDefaults
/// for every slider frame.
private final class ControllerIntentSequenceStore {
    private let defaults = UserDefaults.standard
    private let controllerKey = "shlamp.rf5.controller.id"
    private let sessionKey = "shlamp.rf5.controller.session"
    private let highWaterKey = "shlamp.rf5.intent.highwater"
    private let leaseSize: UInt32 = 4_096
    private let rolloverLimit: UInt32 = 2_000_000_000

    private(set) var controllerID: String
    private(set) var session: UInt32
    private var nextSequence: UInt32
    private var leaseEnd: UInt32

    init() {
        if let saved = defaults.string(forKey: controllerKey),
           saved.range(of: "^[0-9A-F]{12}$", options: .regularExpression) != nil {
            controllerID = saved
        } else {
            controllerID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
            defaults.set(controllerID, forKey: controllerKey)
        }

        let savedSession = defaults.integer(forKey: sessionKey)
        if savedSession > 0 && savedSession < Int(rolloverLimit) {
            session = UInt32(savedSession)
        } else {
            session = UInt32.random(in: 1...1_500_000_000)
            defaults.set(Int(session), forKey: sessionKey)
        }

        let savedHighWater = max(0, defaults.integer(forKey: highWaterKey))
        let start = UInt32(min(savedHighWater, Int(rolloverLimit - leaseSize - 1)))
        nextSequence = start
        leaseEnd = start
        reserveLeaseIfNeeded(force: true)
    }

    func next(kind: OrderedIntentKind, action: String, valueFields: JSONObject) -> OrderedControlIntent {
        reserveLeaseIfNeeded(force: false)
        nextSequence &+= 1
        if nextSequence == 0 || nextSequence >= rolloverLimit {
            rotateSession()
            nextSequence = 1
        }

        var value = valueFields
        value["protocolVersion"] = 3
        value["controllerId"] = controllerID
        value["controllerSession"] = Int(session)
        value["intentSequence"] = Int(nextSequence)
        value["intentKind"] = kind.commandSuffix

        return OrderedControlIntent(
            controllerID: controllerID,
            controllerSession: session,
            intentSequence: nextSequence,
            kind: kind,
            action: action,
            value: value
        )
    }

    private func reserveLeaseIfNeeded(force: Bool) {
        if !force && nextSequence < leaseEnd { return }
        if nextSequence >= rolloverLimit - leaseSize - 1 {
            rotateSession()
            nextSequence = 0
        }
        leaseEnd = nextSequence + leaseSize
        defaults.set(Int(leaseEnd), forKey: highWaterKey)
        defaults.set(Int(session), forKey: sessionKey)
        defaults.synchronize()
    }

    private func rotateSession() {
        session = session >= rolloverLimit - 1 ? 1 : session + 1
        leaseEnd = 0
        defaults.set(Int(session), forKey: sessionKey)
        defaults.set(0, forKey: highWaterKey)
        defaults.synchronize()
    }
}

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
    private var wifiAttachedAt: Date?
    private var cloudReconcileTask: Task<Void, Never>?
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
    private var localPollCursor = 0
    private var focusedLampCanonicalID: String?
    private var liveClockTask: Task<Void, Never>?
    private var brightnessStreamTasks: [String: Task<Void, Never>] = [:]
    private var pendingBrightnessValues: [String: Int] = [:]
    private var brightnessStreamGeneration: [String: Int] = [:]
    private var pendingStreamingOutputIntents: [String: (intent: OrderedControlIntent, generation: Int)] = [:]
    private var rememberedBrightnessByLamp: [String: Int] = [:]
    private let orderedIntents = ControllerIntentSequenceStore()

    // Short-lived field ownership prevents an older BLE/Wi-Fi/cloud echo from
    // overwriting a control the user has just made. A matching device state
    // clears the hold immediately; otherwise it expires quickly so real
    // external changes are never hidden indefinitely.
    private var pendingPowerHolds: [String: (value: Bool, expiresAt: Date)] = [:]
    private var pendingBrightnessHolds: [String: (value: Int, expiresAt: Date)] = [:]
    private var pendingFadeHolds: [String: (value: Int, expiresAt: Date)] = [:]
    private var pendingTimerHolds: [String: (deadline: Date?, expiresAt: Date)] = [:]

    private var localFailureCounts: [String: Int] = [:]
    // RF4: each logical control field is latest-wins inside the app.
    private var controlIntentGenerations: [String: Int] = [:]
    private var lastCloudMutationAt: [String: Date] = [:]
    private var pendingCloudMutationCommands: [String: String] = [:]
    private var latestCloudMutationCommandByLampID: [String: String] = [:]
    private let cloudToLanFence: TimeInterval = 2.25

    private let wifiHealthTTL: TimeInterval = 7
    private let wifiTransitionGrace: TimeInterval = 12
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

    /// The control screen owns the nearby BLE route for its physical lamp.
    /// This prevents an arbitrary previously-discovered lamp from retaining
    /// the single iPhone BLE connection while the user is controlling another.
    func focusLamp(_ lamp: LampRecord) {
        selectedLampID = lamp.canonicalID
        let focusKey = lamp.canonicalID.uppercased()
        focusedLampCanonicalID = focusKey
        guard lamp.routePreference != .remote, !manualAddFlowActive else { return }

        // RF5: the active control screen owns the BLE route for its physical
        // lamp. A ready connection to a different lamp must not block the
        // focused lamp from being discovered and selected.
        guard !canUseBLE(lamp) else { return }
        pendingAutoConnectPeripheralID = nil

        if let target = nearbyLamps.first(where: { nearby in
            guard let record = knownRecord(for: nearby) else { return false }
            return record.canonicalID.uppercased() == focusKey
        }) {
            pendingAutoConnectPeripheralID = target.id
            ble.connect(to: target.id)
        } else {
            // Preserve any existing healthy link until the focused lamp is
            // actually discovered. canUseBLE() prevents that link from being
            // used to mutate the wrong physical lamp.
            ble.startScan()
        }
    }

    func clearLampFocus(_ lamp: LampRecord) {
        if focusedLampCanonicalID == lamp.canonicalID.uppercased() { focusedLampCanonicalID = nil }
        cancelBrightnessStream(for: lamp)
    }

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
        cloudReconcileTask?.cancel()
        cloudReconcileTask = nil
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
        for host in Set(localRecords.values.compactMap(\.localHost)) {
            local.startRealtime(host: host)
        }
        if !manualAddFlowActive { ble.startScan() }
        if let token = session?.accessToken {
            realtime.start(token: token, homeID: dashboard.homes.first?.id ?? "default")
            scheduleCloudRouteReconciliation()
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

    private func cancelBrightnessStream(for lamp: LampRecord) {
        let key = lamp.canonicalID.uppercased()
        brightnessStreamGeneration[key, default: 0] += 1
        brightnessStreamTasks[key]?.cancel()
        brightnessStreamTasks[key] = nil
        pendingBrightnessValues.removeValue(forKey: key)
        pendingStreamingOutputIntents.removeValue(forKey: key)
    }

    /// RF5.1 resolves the newest merged lamp record before building an ordered
    /// output intent. UI views can hold a value-type LampRecord briefly after a
    /// local/cloud state update; using only that stale copy could overwrite the
    /// ESP's saved brightness with the model default (20%).
    private func freshestLampRecord(for lamp: LampRecord) -> LampRecord {
        let canonical = lamp.canonicalID.uppercased()
        return lamps.first { candidate in
            candidate.canonicalID.uppercased() == canonical ||
            candidate.id.uppercased() == lamp.id.uppercased() ||
            (lamp.cloudLampId != nil && candidate.cloudLampId?.uppercased() == lamp.cloudLampId?.uppercased())
        } ?? lamp
    }

    private func rememberedBrightness(for lamp: LampRecord) -> Int {
        let fresh = freshestLampRecord(for: lamp)
        let keys = [
            lamp.canonicalID.uppercased(),
            lamp.id.uppercased(),
            lamp.cloudLampId?.uppercased(),
            fresh.canonicalID.uppercased(),
            fresh.id.uppercased(),
            fresh.cloudLampId?.uppercased()
        ].compactMap { $0 }
        if let cached = keys.compactMap({ rememberedBrightnessByLamp[$0] }).first {
            return max(1, min(100, cached))
        }
        return max(1, min(100, fresh.state.rememberedBrightness))
    }

    private func makeOutputIntent(_ lamp: LampRecord, power: Bool, brightness requestedBrightness: Int) -> OrderedControlIntent {
        let fresh = freshestLampRecord(for: lamp)
        let key = fresh.canonicalID.uppercased()
        let maximum = fresh.state.powerMode == .maximumBackup ? 70 : 100
        let requested = clamp(requestedBrightness, 0...100)
        let capped = min(requested, maximum)
        let knownRemembered = rememberedBrightness(for: fresh)
        let remembered: Int
        let brightness: Int
        if power {
            brightness = max(1, capped > 0 ? capped : min(knownRemembered, maximum))
            remembered = brightness
        } else {
            brightness = 0
            remembered = max(1, min(100, capped > 0 ? capped : knownRemembered))
        }
        rememberedBrightnessByLamp[key] = remembered
        return orderedIntents.next(
            kind: .output,
            action: "setOutputState",
            valueFields: [
                "power": power,
                "brightness": brightness,
                "rememberedBrightness": remembered
            ]
        )
    }

    func setPower(_ lamp: LampRecord, on: Bool) {
        cancelBrightnessStream(for: lamp)
        let generation = nextControlIntent(for: lamp, field: "output")
        let fresh = freshestLampRecord(for: lamp)
        let savedBrightness = rememberedBrightness(for: fresh)
        let desiredBrightness = on ? max(fresh.state.brightness, savedBrightness) : 0
        let ordered = makeOutputIntent(fresh, power: on, brightness: desiredBrightness)
        let targetBrightness = ordered.value["brightness"] as? Int ?? 0
        let remembered = ordered.value["rememberedBrightness"] as? Int ?? max(targetBrightness, 20)

        setPendingPower(lamp, value: on)
        setPendingBrightness(lamp, value: targetBrightness, lifetime: 3.0)
        optimistic(lamp.id) {
            $0.state.power = on
            $0.state.brightness = targetBrightness
            $0.state.rememberedBrightness = remembered
        }

        Task {
            do {
                try await performOrderedRouted(
                    lamp: lamp,
                    intent: ordered,
                    shouldContinue: { self.isCurrentControlIntent(generation, for: lamp, field: "output") }
                )
            } catch { handle(error) }
        }
    }

    func setBrightness(_ lamp: LampRecord, value: Int) {
        cancelBrightnessStream(for: lamp)
        let generation = nextControlIntent(for: lamp, field: "output")
        let requested = clamp(value, 0...100)
        let maximum = lamp.state.powerMode == .maximumBackup ? 70 : 100
        let percent = min(requested, maximum)
        let ordered = makeOutputIntent(lamp, power: percent > 0, brightness: percent)
        let remembered = ordered.value["rememberedBrightness"] as? Int ?? max(percent, 20)

        setPendingPower(lamp, value: percent > 0)
        setPendingBrightness(lamp, value: percent, lifetime: 3.0)
        optimistic(lamp.id) {
            $0.state.brightness = percent
            $0.state.power = percent > 0
            $0.state.rememberedBrightness = remembered
        }
        if requested != percent {
            notice = "Limited to 70% by Maximum Backup."
        }

        Task {
            do {
                try await performOrderedRouted(
                    lamp: lamp,
                    intent: ordered,
                    shouldContinue: { self.isCurrentControlIntent(generation, for: lamp, field: "output") }
                )
            } catch { handle(error) }
        }
    }

    /// Continuous brightness control. Every slider frame is allocated its
    /// ordering identity at the moment the UI creates it. If OFF or a final
    /// release happens later, its larger sequence makes every already-queued
    /// frame stale on the ESP even if a transport delivers it late.
    func streamBrightness(_ lamp: LampRecord, value: Int) {
        let requested = clamp(value, 0...100)
        let maximum = lamp.state.powerMode == .maximumBackup ? 70 : 100
        let percent = min(requested, maximum)
        let generation = nextControlIntent(for: lamp, field: "output")
        let ordered = makeOutputIntent(lamp, power: percent > 0, brightness: percent)
        let remembered = ordered.value["rememberedBrightness"] as? Int ?? max(percent, 20)

        setPendingBrightness(lamp, value: percent, lifetime: 1.5)
        setPendingPower(lamp, value: percent > 0, lifetime: 1.5)
        optimistic(lamp.id) {
            $0.state.brightness = percent
            $0.state.power = percent > 0
            $0.state.rememberedBrightness = remembered
        }

        let key = lamp.canonicalID.uppercased()
        pendingStreamingOutputIntents[key] = (ordered, generation)
        guard brightnessStreamTasks[key] == nil else { return }

        let taskGeneration = brightnessStreamGeneration[key, default: 0] + 1
        brightnessStreamGeneration[key] = taskGeneration
        brightnessStreamTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.brightnessStreamGeneration[key] == taskGeneration {
                    self.brightnessStreamTasks[key] = nil
                }
            }

            while !Task.isCancelled {
                guard let pending = self.pendingStreamingOutputIntents.removeValue(forKey: key) else { break }
                guard self.isCurrentControlIntent(pending.generation, for: lamp, field: "output") else { continue }
                await self.sendStreamingOrderedIntent(lamp: lamp, intent: pending.intent, generation: pending.generation)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func sendStreamingOrderedIntent(lamp: LampRecord, intent: OrderedControlIntent, generation: Int) async {
        let order = routeOrder(for: lamp)
        for route in order {
            guard isCurrentControlIntent(generation, for: lamp, field: "output") else { return }
            switch route {
            case .wifi:
                guard isWiFiHealthy(lamp), let host = lamp.localHost else { continue }
                do {
                    _ = try await local.sendOrderedCommand(host: host, intent: intent, waitForAck: false)
                    return
                } catch {
                    markWiFiFailure(for: lamp)
                }
            case .bluetooth:
                guard canUseBLE(lamp) else { continue }
                do {
                    try await ble.sendOrdered(intent: intent, waitForAck: false)
                    return
                } catch { continue }
            case .cloud:
                // Intermediate slider frames are intentionally live-only. If
                // the app WebSocket is rebinding, skip these frames; the final
                // released brightness still uses the durable REST/ACK fallback.
                guard cloudConnected, isCloudHealthy(lamp), let remoteID = try? remoteID(for: lamp) else { continue }
                do {
                    _ = try await realtime.sendCommand(
                        lampID: remoteID,
                        action: intent.action,
                        value: intent.value,
                        live: true,
                        commandID: intent.commandID
                    )
                    return
                } catch { continue }
            case .offline:
                continue
            }
        }
    }

    func setPowerMode(_ lamp: LampRecord, mode: LampPowerMode) {
        let intent = nextControlIntent(for: lamp, field: "powerMode")
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
                            lastBrightness: lamp.state.rememberedBrightness, fadeMode: lamp.state.fadeMode,
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
                    cloudAction: nil,
                    shouldContinue: { self.isCurrentControlIntent(intent, for: lamp, field: "powerMode") }
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
        let generation = nextControlIntent(for: lamp, field: "fade")
        let value = clamp(mode, 0...3)
        let ordered = orderedIntents.next(
            kind: .fade,
            action: "setFadeMode",
            valueFields: ["fadeMode": value]
        )
        setPendingFade(lamp, value: value)
        optimistic(lamp.id) { $0.state.fadeMode = value }
        Task {
            do {
                try await performOrderedRouted(
                    lamp: lamp,
                    intent: ordered,
                    shouldContinue: { self.isCurrentControlIntent(generation, for: lamp, field: "fade") }
                )
            } catch { handle(error) }
        }
    }

    func setTimer(_ lamp: LampRecord, minutes: Int) {
        let generation = nextControlIntent(for: lamp, field: "timer")
        let value = [0, 15, 30, 60].contains(minutes) ? minutes : 0
        let ordered = orderedIntents.next(
            kind: .timer,
            action: "setTimer",
            valueFields: ["timerMinutes": value]
        )
        let seconds = Int64(value * 60)
        setPendingTimer(lamp, seconds: seconds)
        optimistic(lamp.id) { $0.state.timerRemainingSeconds = seconds }
        _ = registerTimerState(for: lamp, remainingSeconds: seconds, receivedAt: Date(), isUserInitiated: true)
        scheduleTimerNotification(for: lamp, remainingSeconds: seconds)
        Task {
            do {
                try await performOrderedRouted(
                    lamp: lamp,
                    intent: ordered,
                    shouldContinue: { self.isCurrentControlIntent(generation, for: lamp, field: "timer") }
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

    private func controlIntentKey(for lamp: LampRecord, field: String) -> String {
        "\(lamp.canonicalID.uppercased())|\(field)"
    }

    private func nextControlIntent(for lamp: LampRecord, field: String) -> Int {
        let key = controlIntentKey(for: lamp, field: field)
        let next = (controlIntentGenerations[key] ?? 0) + 1
        controlIntentGenerations[key] = next
        return next
    }

    private func isCurrentControlIntent(_ generation: Int, for lamp: LampRecord, field: String) -> Bool {
        controlIntentGenerations[controlIntentKey(for: lamp, field: field)] == generation
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
        cloudAction: (() async throws -> Void)?,
        shouldContinue: (() -> Bool)? = nil
    ) async throws {
        let order = routeOrder(for: lamp)

        var lastFailure: Error?
        for route in order {
            if let shouldContinue, !shouldContinue() { return }
            switch route {
            case .wifi:
                guard isWiFiHealthy(lamp), let host = lamp.localHost else { continue }

                // R21A Review Fix 1: Local WebSocket is event/state-only.
                // Keep the already-proven HTTP command + verification path
                // until a later protocol phase adds explicit LAN ACK tracking.
                guard let localAction else { continue }
                do {
                    let requestStartedAt = Date()
                    let snapshot = try await localAction(host)
                    if let shouldContinue, !shouldContinue() { return }
                    apply(snapshot: snapshot, observedAt: requestStartedAt, authoritative: true)
                    return
                } catch {
                    if let shouldContinue, !shouldContinue() { return }
                    lastFailure = error
                    markWiFiFailure(for: lamp)
                }
            case .bluetooth:
                guard canUseBLE(lamp), let bleAction else { continue }
                if let shouldContinue, !shouldContinue() { return }
                bleAction()
                updateLocalRecord(for: lamp) { $0.route = .bluetooth; $0.online = true }
                return
            case .cloud:
                guard isCloudHealthy(lamp), let cloudAction else { continue }
                if let shouldContinue, !shouldContinue() { return }
                do {
                    try await cloudAction()
                    if let shouldContinue, !shouldContinue() { return }
                    updateLocalRecord(for: lamp) { record in
                        if record.route == .offline { record.online = true }
                    }
                    return
                } catch {
                    if let shouldContinue, !shouldContinue() { return }
                    lastFailure = error
                }
            case .offline:
                continue
            }
        }
        throw lastFailure ?? AppError.message("No available connection could control this lamp.")
    }

    private func performOrderedRouted(
        lamp: LampRecord,
        intent: OrderedControlIntent,
        shouldContinue: (() -> Bool)? = nil
    ) async throws {
        let order = routeOrder(for: lamp)
        var lastFailure: Error?

        for route in order {
            if let shouldContinue, !shouldContinue() { return }
            switch route {
            case .wifi:
                guard isWiFiHealthy(lamp), let host = lamp.localHost else { continue }
                do {
                    let requestStartedAt = Date()
                    if let snapshot = try await local.sendOrderedCommand(host: host, intent: intent, waitForAck: true) {
                        if let shouldContinue, !shouldContinue() { return }
                        apply(snapshot: snapshot, observedAt: requestStartedAt, authoritative: true)
                    }
                    return
                } catch {
                    if let shouldContinue, !shouldContinue() { return }
                    lastFailure = error
                    markWiFiFailure(for: lamp)
                }

            case .bluetooth:
                guard canUseBLE(lamp) else { continue }
                do {
                    try await ble.sendOrdered(intent: intent, waitForAck: true)
                    if let shouldContinue, !shouldContinue() { return }
                    updateLocalRecord(for: lamp) { $0.route = .bluetooth; $0.online = true }
                    return
                } catch {
                    if let shouldContinue, !shouldContinue() { return }
                    lastFailure = error
                }

            case .cloud:
                guard isCloudHealthy(lamp) else { continue }
                do {
                    let remoteID = try remoteID(for: lamp)
                    try await sendCloudOrderedCommand(lampID: remoteID, intent: intent)
                    if let shouldContinue, !shouldContinue() { return }
                    updateLocalRecord(for: lamp) { record in
                        if record.route == .offline { record.online = true }
                    }
                    return
                } catch {
                    if let shouldContinue, !shouldContinue() { return }
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
            return [.bluetooth, .wifi, .cloud]
        case .wifi:
            return [.wifi, .bluetooth, .cloud]
        case .automatic:
            let preferred = automaticLocalRoute(for: lamp)
            switch preferred {
            case .bluetooth: return [.bluetooth, .wifi, .cloud]
            case .wifi: return [.wifi, .bluetooth, .cloud]
            case .cloud: return [.cloud, .bluetooth, .wifi]
            case .offline: return [.bluetooth, .wifi, .cloud]
            }
        }
    }

    private func isCloudHealthy(_ lamp: LampRecord) -> Bool {
        // RF5.2: the authenticated app WebSocket is the fast realtime path,
        // not the only valid cloud transport. RF5 already has a REST command
        // fallback that waits for the ESP semantic ACK. During an iPhone
        // Wi-Fi/cellular rebind the app WebSocket can be reconnecting for a few
        // seconds while Render still knows the ESP is online. Keep Remote
        // usable in that window instead of incorrectly declaring the lamp
        // Offline and refusing to send the REST fallback.
        guard session != nil else { return false }
        let candidateIDs = [lamp.cloudLampId?.uppercased(), lamp.id.uppercased()].compactMap { $0 }
        guard !candidateIDs.isEmpty else { return false }
        return dashboard.lamps.contains { cloudLamp in
            candidateIDs.contains(cloudLamp.id.uppercased()) && cloudLamp.online
        }
    }

    /// BLE is preferred while it is genuinely healthy. Hysteresis prevents a
    /// lamp near the range boundary from bouncing BLE <-> LAN every few RSSI
    /// samples. Unknown RSSI immediately after connection still prefers BLE.
    private func automaticLocalRoute(for lamp: LampRecord) -> LampConnectionRoute {
        let hasBLE = canUseBLE(lamp)
        let hasWiFi = isWiFiHealthy(lamp)
        guard hasBLE || hasWiFi else {
            return isCloudHealthy(lamp) ? .cloud : .offline
        }
        guard hasBLE else { return .wifi }
        guard hasWiFi else { return .bluetooth }

        let rssi = lamp.bleRSSI
        if rssi <= -120 { return .bluetooth } // waiting for first RSSI read

        if lamp.route == .bluetooth {
            return rssi <= -82 ? .wifi : .bluetooth
        }
        if lamp.route == .wifi {
            return rssi >= -70 ? .bluetooth : .wifi
        }
        return rssi >= -78 ? .bluetooth : .wifi
    }

    private func markWiFiFailure(for lamp: LampRecord) {
        let key = lamp.id.uppercased()
        for stateKey in stateKeys(for: lamp) { wifiConfirmedAt.removeValue(forKey: stateKey) }
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
                    let records = self.localRecords.values
                        .filter { $0.localHost != nil }
                        .sorted { $0.canonicalID < $1.canonicalID }
                    if !records.isEmpty {
                        self.localPollCursor %= records.count
                        let probeCount = min(2, records.count)
                        for offset in 0..<probeCount {
                            let record = records[(self.localPollCursor + offset) % records.count]
                            guard let host = record.localHost else { continue }
                            let key = record.id.uppercased()
                            // Realtime sockets carry state continuously. HTTP is a
                            // bounded rotating liveness confirmation, so dozens of
                            // lamps cannot create a synchronized 2-second poll storm.
                            // RF5.2: protocol-v3 local WebSocket is now an
                            // authenticated-by-identity, ordered, ACKed command
                            // transport. A validated realtime state therefore
                            // proves the current Wi-Fi path by itself; an extra
                            // HTTP status probe is no longer required.
                            if self.local.isRealtimeHealthy(host: host) { continue }
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
                        self.localPollCursor = (self.localPollCursor + probeCount) % records.count
                    }
                }
                try? await Task.sleep(for: self.localPollInterval)
            }
        }
    }

    private func noteLocalPollFailure(_ lamp: LampRecord) {
        let key = lamp.id.uppercased()

        // A live protocol-v3 socket is stronger evidence than a single HTTP
        // timeout. Do not let a transient HTTP miss tear down a working LAN
        // route or erase the remembered host.
        if let host = lamp.localHost, local.isRealtimeHealthy(host: host) {
            localFailureCounts[key] = 0
            rebuildLamps()
            return
        }

        for stateKey in stateKeys(for: lamp) { wifiConfirmedAt.removeValue(forKey: stateKey) }

        // iOS can report the new Wi-Fi path before local HTTP is fully usable.
        // Preserve the known host during that attachment grace period so three
        // 2-second poll misses cannot erase LAN identity while the socket and
        // Bonjour stack are still settling.
        if let attachedAt = wifiAttachedAt, Date().timeIntervalSince(attachedAt) < wifiTransitionGrace {
            rebuildLamps()
            return
        }

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
        guard wifiPathAvailable, let host = lamp.localHost else { return false }
        let keys = stateKeys(for: lamp)
        // RF4: do not cross from Cloud to LAN while a recent cloud mutation can
        // still be in flight. The backend RF4 control TTL is 2 seconds; this
        // small extra margin closes the handover race without delaying normal
        // LAN operation once the transition has settled.
        if let lastCloudMutation = keys.compactMap({ lastCloudMutationAt[$0] }).max(),
           now.timeIntervalSince(lastCloudMutation) < cloudToLanFence {
            return false
        }

        // RF5.2: protocol v3 changed the local WebSocket from Phase-A
        // state-only transport into an ordered command channel with semantic
        // ACK and same-command HTTP fallback. Once the socket has received and
        // validated an authoritative state from this physical lamp, it is a
        // complete proof of LAN reachability on the current phone Wi-Fi path.
        // Requiring a separate HTTP success here was the reason the video could
        // show Offline even while the ESP logged a connected local realtime
        // client.
        if local.isRealtimeHealthy(host: host, now: now) { return true }

        // If realtime is unavailable, retain the bounded HTTP liveness fallback.
        guard let last = keys.compactMap({ wifiConfirmedAt[$0] }).max() else { return false }
        return now.timeIntervalSince(last) <= wifiHealthTTL
    }

    @discardableResult
    private func registerTimerState(
        for lamp: LampRecord,
        remainingSeconds: Int64,
        receivedAt: Date,
        isUserInitiated: Bool = false
    ) -> Bool {
        let keys = stateKeys(for: lamp)
        let now = Date()

        if !isUserInitiated {
            let activeHold = keys.compactMap { pendingTimerHolds[$0] }
                .filter { $0.expiresAt > now }
                .max { $0.expiresAt < $1.expiresAt }

            if let hold = activeHold {
                let matches: Bool
                if let expectedDeadline = hold.deadline {
                    let expected = max(0, Int64(ceil(expectedDeadline.timeIntervalSince(now))))
                    matches = remainingSeconds > 0 && Swift.abs(remainingSeconds - expected) <= 5
                } else {
                    matches = remainingSeconds == 0
                }

                if matches {
                    clearTimerHold(for: lamp)
                } else {
                    // This is an older snapshot/echo from before the user's
                    // latest timer command. Keep the existing deadline until
                    // the matching acknowledgement arrives or the short hold
                    // expires.
                    return false
                }
            } else {
                clearTimerHold(for: lamp)
            }
        }

        if remainingSeconds > 0 {
            let deadline = receivedAt.addingTimeInterval(TimeInterval(remainingSeconds))
            for key in keys { timerDeadlines[key] = deadline }
        } else {
            for key in keys { timerDeadlines.removeValue(forKey: key) }
        }
        return true
    }

    func remainingTimerSeconds(for lamp: LampRecord) -> Int64 {
        _ = liveClock // Explicit dependency so SwiftUI refreshes once per second.
        let keys = stateKeys(for: lamp)
        if let deadline = keys.compactMap({ timerDeadlines[$0] }).max() {
            // Use a fresh clock for the calculation. `liveClock` is only the
            // SwiftUI refresh trigger and can be almost one second behind,
            // which previously allowed a new 15m timer to display as 15:01.
            return max(0, Int64(ceil(deadline.timeIntervalSince(Date()))))
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

    private func sendCloudOrderedCommand(lampID: String, intent: OrderedControlIntent) async throws {
        let normalizedLampID = lampID.uppercased()
        lastCloudMutationAt[normalizedLampID] = Date()
        pendingCloudMutationCommands[intent.commandID] = normalizedLampID
        latestCloudMutationCommandByLampID[normalizedLampID] = intent.commandID

        defer {
            pendingCloudMutationCommands.removeValue(forKey: intent.commandID)
            if latestCloudMutationCommandByLampID[normalizedLampID] == intent.commandID {
                latestCloudMutationCommandByLampID.removeValue(forKey: normalizedLampID)
            }
        }

        // Prefer the authenticated app WebSocket and require the actual ESP ACK.
        // A Render `commandAccepted` frame only proves queueing, not execution.
        if cloudConnected {
            do {
                let ack = try await realtime.sendCommandAwaitingAck(
                    lampID: normalizedLampID,
                    action: intent.action,
                    value: intent.value,
                    commandID: intent.commandID,
                    timeout: 2.4
                )
                if ack.bool("success") == false {
                    throw AppError.message(firstNonBlank(ack.string("error"), "The lamp rejected the cloud command."))
                }
                lastCloudMutationAt.removeValue(forKey: normalizedLampID)
                return
            } catch {
                // Retry the exact same command ID through REST. If the device
                // already executed it and only the app ACK was lost, backend
                // idempotency + ESP deduplication turn this into a status check.
            }
        }

        let ack = try await withAccessToken { token in
            try await api.sendCommandAndWaitForAck(
                accessToken: token,
                lampId: normalizedLampID,
                action: intent.action,
                value: intent.value,
                commandID: intent.commandID,
                timeout: 2.6
            )
        }
        if ack.bool("success") == false {
            throw AppError.message(firstNonBlank(ack.string("error"), "The lamp rejected the cloud command."))
        }
        lastCloudMutationAt.removeValue(forKey: normalizedLampID)
    }

    private func sendCloudCommand(lampID: String, action: String, value: Any) async throws {
        let normalizedLampID = lampID.uppercased()
        let isStateMutation = ["setPower", "setBrightness", "setFadeMode", "setTimer"].contains(action)
        if isStateMutation {
            lastCloudMutationAt[normalizedLampID] = Date()
        }
        if cloudConnected {
            let commandID = UUID().uuidString
            if isStateMutation {
                pendingCloudMutationCommands[commandID] = normalizedLampID
                latestCloudMutationCommandByLampID[normalizedLampID] = commandID
            }
            do {
                _ = try await realtime.sendCommand(
                    lampID: lampID,
                    action: action,
                    value: value,
                    commandID: commandID
                )
                if isStateMutation {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(3))
                        guard let self else { return }
                        self.pendingCloudMutationCommands.removeValue(forKey: commandID)
                        if self.latestCloudMutationCommandByLampID[normalizedLampID] == commandID {
                            self.latestCloudMutationCommandByLampID.removeValue(forKey: normalizedLampID)
                        }
                    }
                }
                return
            } catch {
                pendingCloudMutationCommands.removeValue(forKey: commandID)
                if latestCloudMutationCommandByLampID[normalizedLampID] == commandID {
                    latestCloudMutationCommandByLampID.removeValue(forKey: normalizedLampID)
                }
                // The REST queue is a durable fallback if the live socket drops
                // between UI route selection and the actual send. Keep the short
                // Cloud->LAN fence because this fallback has no live ACK
                // correlation in the current API.
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

    private func scheduleCloudRouteReconciliation() {
        cloudReconcileTask?.cancel()
        guard session != nil else { return }
        cloudReconcileTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            do {
                try await self.refreshDashboard(silent: true)
                return
            } catch {
                // A network interface can still be settling when NWPath first
                // flips. One bounded retry is enough; normal realtime/refresh
                // paths continue after that.
            }
            try? await Task.sleep(for: .seconds(1.7))
            guard !Task.isCancelled else { return }
            try? await self.refreshDashboard(silent: true)
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

                // RF4: explicitly rebind the account WebSocket whenever the
                // iPhone changes between cellular and Wi-Fi. Leaving an old TCP
                // WebSocket attached to the previous interface can otherwise
                // produce several seconds of "cloud disconnected" or a half-dead
                // socket after the route changes.
                if path.status == .satisfied, let currentSession = self.session {
                    self.realtime.start(
                        token: currentSession.accessToken,
                        homeID: self.dashboard.homes.first?.id ?? "default",
                        force: true
                    )
                    // Reconcile the backend's current device-online flags by
                    // REST as well. This is intentionally independent of the
                    // app WebSocket so a half-open/rebinding live socket cannot
                    // leave the UI stuck Offline.
                    self.scheduleCloudRouteReconciliation()
                }

                if hasWiFi {
                    self.wifiAttachedAt = Date()
                    // RF5.2 make-before-break: clear HTTP proof from the old
                    // attachment, but allow a validated protocol-v3 realtime
                    // state to promote LAN immediately on the new Wi-Fi path.
                    self.wifiConfirmedAt.removeAll()
                    let remembered = Array(self.localRecords.values.filter { $0.localHost != nil })
                    for record in remembered {
                        guard let host = record.localHost else { continue }
                        self.local.startRealtime(host: host)
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
                                // Do not throw away a remembered host after one
                                // transition-time miss. The normal polling/failure
                                // policy will retry and fall through to BLE/cloud.
                                self.rebuildLamps()
                            }
                        }
                    }
                    self.local.startDiscovery()
                } else {
                    self.wifiAttachedAt = nil
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
            // Ordering tokens are live-session evidence, not user preferences.
            // Relearn them from the ESP/cloud after launch so a stale persisted
            // boot sequence can never block a freshly reset/reflashed lamp.
            restored.state.stateBootId = nil
            restored.state.stateBootSequence = nil
            restored.state.stateRevision = nil
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

    private func stateKeys(for lamp: LampRecord) -> [String] {
        var keys = [lamp.id.uppercased(), lamp.canonicalID.uppercased()]
        if let cloudID = lamp.cloudLampId?.uppercased() { keys.append(cloudID) }
        var seen: Set<String> = []
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func setPendingPower(_ lamp: LampRecord, value: Bool, lifetime: TimeInterval = 3.0) {
        let hold = (value: value, expiresAt: Date().addingTimeInterval(lifetime))
        for key in stateKeys(for: lamp) { pendingPowerHolds[key] = hold }
    }

    private func setPendingBrightness(_ lamp: LampRecord, value: Int, lifetime: TimeInterval) {
        let hold = (value: value, expiresAt: Date().addingTimeInterval(lifetime))
        for key in stateKeys(for: lamp) { pendingBrightnessHolds[key] = hold }
    }

    private func setPendingFade(_ lamp: LampRecord, value: Int, lifetime: TimeInterval = 3.0) {
        let hold = (value: value, expiresAt: Date().addingTimeInterval(lifetime))
        for key in stateKeys(for: lamp) { pendingFadeHolds[key] = hold }
    }

    private func setPendingTimer(_ lamp: LampRecord, seconds: Int64, lifetime: TimeInterval = 4.0) {
        let deadline = seconds > 0 ? Date().addingTimeInterval(TimeInterval(seconds)) : nil
        let hold = (deadline: deadline, expiresAt: Date().addingTimeInterval(lifetime))
        for key in stateKeys(for: lamp) { pendingTimerHolds[key] = hold }
    }

    private func clearPowerHold(for lamp: LampRecord) {
        for key in stateKeys(for: lamp) { pendingPowerHolds.removeValue(forKey: key) }
    }

    private func clearBrightnessHold(for lamp: LampRecord) {
        for key in stateKeys(for: lamp) { pendingBrightnessHolds.removeValue(forKey: key) }
    }

    private func clearFadeHold(for lamp: LampRecord) {
        for key in stateKeys(for: lamp) { pendingFadeHolds.removeValue(forKey: key) }
    }

    private func clearTimerHold(for lamp: LampRecord) {
        for key in stateKeys(for: lamp) { pendingTimerHolds.removeValue(forKey: key) }
    }

    private func protectedIncomingState(_ incoming: LampState, for lamp: LampRecord, current: LampState) -> LampState {
        var result = incoming
        let now = Date()
        let keys = stateKeys(for: lamp)

        if let hold = keys.compactMap({ pendingBrightnessHolds[$0] })
            .filter({ $0.expiresAt > now })
            .max(by: { $0.expiresAt < $1.expiresAt }) {
            if result.brightness == hold.value {
                clearBrightnessHold(for: lamp)
            } else {
                result.brightness = current.brightness
                // Brightness also determines lamp power in the firmware. Keep
                // the optimistic power value unless a separate explicit power
                // command currently owns that field.
                result.power = current.power
            }
        } else {
            clearBrightnessHold(for: lamp)
        }

        if let hold = keys.compactMap({ pendingPowerHolds[$0] })
            .filter({ $0.expiresAt > now })
            .max(by: { $0.expiresAt < $1.expiresAt }) {
            if result.power == hold.value {
                clearPowerHold(for: lamp)
            } else {
                result.power = current.power
            }
        } else {
            clearPowerHold(for: lamp)
        }

        if let hold = keys.compactMap({ pendingFadeHolds[$0] })
            .filter({ $0.expiresAt > now })
            .max(by: { $0.expiresAt < $1.expiresAt }) {
            if result.fadeMode == hold.value {
                clearFadeHold(for: lamp)
            } else {
                result.fadeMode = current.fadeMode
            }
        } else {
            clearFadeHold(for: lamp)
        }

        return result
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

    private func apply(
        snapshot: WiFiLampSnapshot,
        observedAt: Date = Date(),
        authoritative: Bool = false,
        confirmsWiFiCommandPath: Bool = true
    ) {
        let localID = snapshot.lampId.uppercased()
        let receivedAt = Date()
        let stateObservedAt = authoritative ? receivedAt : observedAt
        localSnapshots[localID] = snapshot
        rememberedBrightnessByLamp[localID] = max(1, min(100, snapshot.lastBrightness))
        local.startRealtime(host: snapshot.host)
        if confirmsWiFiCommandPath {
            wifiConfirmedAt[localID] = receivedAt
            localFailureCounts[localID] = 0
        }
        localStateReceivedAt[localID] = stateObservedAt

        let cloudID = snapshot.cloudLampId?.uppercased()
        if let cloudID {
            rememberedBrightnessByLamp[cloudID] = max(1, min(100, snapshot.lastBrightness))
            if confirmsWiFiCommandPath {
                wifiConfirmedAt[cloudID] = receivedAt
                localFailureCounts[cloudID] = 0
            }
            localStateReceivedAt[cloudID] = stateObservedAt
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
        let currentState = lamps.first(where: { $0.canonicalID == record.canonicalID })?.state ?? record.state
        var incomingState = LampState(
            power: snapshot.power,
            brightness: snapshot.targetBrightness,
            rememberedBrightness: snapshot.lastBrightness,
            fadeMode: snapshot.fadeMode,
            timerRemainingSeconds: snapshot.timerRemainingSeconds,
            batteryValid: snapshot.batteryValid,
            batteryPercent: snapshot.batteryPercent,
            batteryVoltageMv: snapshot.batteryVoltageMv,
            batteryCharging: snapshot.batteryCharging,
            powerMode: snapshot.powerMode,
            runtimeState: snapshot.runtimeState,
            stateBootId: snapshot.stateBootId,
            stateBootSequence: snapshot.stateBootSequence,
            stateRevision: snapshot.stateRevision
        )
        let stateAccepted = shouldAcceptAuthoritativeState(
            incomingState,
            current: currentState
        )
        var timerAccepted = false
        if stateAccepted {
            timerAccepted = registerTimerState(
                for: record,
                remainingSeconds: snapshot.timerRemainingSeconds,
                receivedAt: receivedAt
            )
            if !timerAccepted { incomingState.timerRemainingSeconds = currentState.timerRemainingSeconds }
            record.state = protectedIncomingState(incomingState, for: record, current: currentState)
            if authoritative {
                optimisticStateAt.removeValue(forKey: localID)
                if let cloudID { optimisticStateAt.removeValue(forKey: cloudID) }
            }
        } else {
            record.state = currentState
        }
        if stateAccepted && timerAccepted {
            scheduleTimerNotification(for: record, remainingSeconds: snapshot.timerRemainingSeconds)
        }
        record.route = selectedRoute(for: record, local: record, cloud: record.cloudLampId.flatMap { cloudID in
            dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame })
        })
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

        let localAndPrimaryHaveVersions =
            local.state.stateBootSequence != nil && local.state.stateRevision != nil &&
            merged.state.stateBootSequence != nil && merged.state.stateRevision != nil
        let sameAuthoritativeVersion = localAndPrimaryHaveVersions &&
            local.state.stateBootSequence == merged.state.stateBootSequence &&
            local.state.stateRevision == merged.state.stateRevision &&
            (local.state.stateBootId == nil || merged.state.stateBootId == nil ||
                local.state.stateBootId == merged.state.stateBootId)

        if localAndPrimaryHaveVersions && !sameAuthoritativeVersion {
            // Version ordering wins over transport receipt time. Lower boot
            // sequences are rejected in-session so a delayed older incarnation
            // cannot overwrite a newer authoritative state.
            if shouldAcceptAuthoritativeState(
                local.state,
                current: merged.state
            ) {
                merged.state = local.state
            }
        } else if let localFullStateAt,
                  localClearsOptimisticHold,
                  primaryFreshness == nil || localFullStateAt >= primaryFreshness! {
            // For equal revisions (the timer countdown can change without a
            // logical revision) or legacy firmware, receipt freshness remains
            // the tie-breaker. Route choice itself never decides state age.
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
        // RF5.2: Remote remains usable through the semantic-ACK REST fallback
        // while the app realtime WebSocket is rebinding.
        let hasCloud = isCloudHealthy(lamp)

        switch lamp.routePreference {
        case .remote:
            return hasCloud ? .cloud : .offline
        case .bluetooth:
            if hasBLE { return .bluetooth }
            // A manual Bluetooth preference still falls back locally before
            // going remote, matching routeOrder() and the user's expected
            // BLE -> LAN -> Cloud behavior.
            if hasWiFi { return .wifi }
            if hasCloud { return .cloud }
        case .wifi:
            if hasWiFi { return .wifi }
            if hasBLE { return .bluetooth }
            if hasCloud { return .cloud }
        case .automatic:
            if let local {
                let preferred = automaticLocalRoute(for: local)
                if preferred == .bluetooth && hasBLE { return .bluetooth }
                if preferred == .wifi && hasWiFi { return .wifi }
            }
            if hasBLE { return .bluetooth }
            if hasWiFi { return .wifi }
            if hasCloud { return .cloud }
        }
        return .offline
    }

    private func applyCloudLamp(
        _ incoming: LampRecord,
        receivedAt: Date
    ) {
        var lamp = incoming
        let id = lamp.id.uppercased()
        lamp.id = id
        lamp.cloudLampId = id
        lamp.cloudClaimed = true
        lamp.route = lamp.online ? .cloud : .offline

        let existingDashboard = dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame })
        if let existing = existingDashboard {
            if lamp.name == "SH Lamp" && existing.name != "SH Lamp" { lamp.name = existing.name }
            if lamp.homeId.isEmpty || lamp.homeId == "default" { lamp.homeId = existing.homeId }
            lamp.roomId = lamp.roomId ?? existing.roomId
            lamp.roomName = lamp.roomName ?? existing.roomName
            if lamp.model.isEmpty { lamp.model = existing.model }
            lamp.firmware = lamp.firmware ?? existing.firmware
            lamp.routePreference = existing.routePreference
        }

        let currentState = lamps.first(where: { $0.canonicalID == lamp.canonicalID })?.state
            ?? existingDashboard?.state
            ?? lamp.state
        let reportedTimer = lamp.state.timerRemainingSeconds
        let stateAccepted = shouldAcceptAuthoritativeState(
            lamp.state,
            current: currentState
        )
        var timerAccepted = false
        if stateAccepted {
            timerAccepted = registerTimerState(for: lamp, remainingSeconds: reportedTimer, receivedAt: receivedAt)
            if !timerAccepted { lamp.state.timerRemainingSeconds = currentState.timerRemainingSeconds }
            lamp.state = protectedIncomingState(lamp.state, for: lamp, current: currentState)
            optimisticStateAt.removeValue(forKey: id)
        } else {
            lamp.state = currentState
        }

        if lamp.state.rememberedBrightness > 0 {
            rememberedBrightnessByLamp[lamp.canonicalID.uppercased()] = lamp.state.rememberedBrightness
            rememberedBrightnessByLamp[id] = lamp.state.rememberedBrightness
        }
        cloudStateReceivedAt[id] = receivedAt
        if stateAccepted && timerAccepted { scheduleTimerNotification(for: lamp, remainingSeconds: reportedTimer) }
        dashboard.lamps.removeAll { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        dashboard.lamps.append(lamp)
        rebuildLamps()
    }

    /// R21A authoritative ordering. New firmware supplies a persistent boot
    /// sequence plus a boot-local revision. Older firmware has no metadata and
    /// keeps the proven receipt-time merge behavior.
    private func shouldAcceptAuthoritativeState(
        _ incoming: LampState,
        current: LampState
    ) -> Bool {
        guard let incomingBoot = incoming.stateBootSequence,
              let incomingRevision = incoming.stateRevision,
              let currentBoot = current.stateBootSequence,
              let currentRevision = current.stateRevision else {
            return true
        }

        if incomingBoot > currentBoot { return true }
        if incomingBoot < currentBoot { return false }

        // Same persistent boot sequence: revisions are comparable only inside
        // the same boot incarnation. A different nonce with the same sequence
        // is ambiguous (for example an NVS erase/reset), so reject it in the
        // current app session rather than risk accepting a delayed stale boot.
        // The app intentionally clears persisted ordering metadata at launch,
        // so a relaunch safely establishes the new incarnation.
        if let incomingBootId = incoming.stateBootId,
           let currentBootId = current.stateBootId,
           incomingBootId != currentBootId {
            return false
        }
        return incomingRevision >= currentRevision
    }

    private func handle(_ error: Error) {
        if case AppError.unauthorized = error { signOut(message: "Your sign-in expired.") }
        else { errorMessage = error.localizedDescription }
    }
}

extension AppViewModel: BLELampManagerDelegate {
    func bleManager(_ manager: BLELampManager, didUpdateNearby lamps: [NearbyLamp]) {
        nearbyLamps = lamps
        guard !manualAddFlowActive, pendingAutoConnectPeripheralID == nil else { return }

        // Focus ownership has priority even while BLE is ready for another
        // lamp. This is the deterministic A -> B switching path.
        if let focused = focusedLampCanonicalID,
           let focusedRecord = self.lamps.first(where: { $0.canonicalID.uppercased() == focused }),
           focusedRecord.routePreference != .remote,
           !canUseBLE(focusedRecord),
           let target = lamps.first(where: { nearby in
               guard let record = knownRecord(for: nearby) else { return false }
               return record.canonicalID.uppercased() == focused
           }) {
            pendingAutoConnectPeripheralID = target.id
            manager.connect(to: target.id)
            return
        }

        // Background auto-selection must never steal an already healthy link.
        guard !manager.isReady else { return }

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
        // R21A: connection availability and command-route choice are separate.
        // Re-evaluate through the same hysteresis-aware selector used everywhere
        // else instead of forcing the older Wi-Fi-first behavior here.
        record.route = selectedRoute(
            for: record,
            local: record,
            cloud: record.cloudLampId.flatMap { cloudID in
                dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame })
            }
        )
        record.online = record.route != .offline
        localRecords[localKey] = record
        persistLocalRecords()
        rebuildLamps()
    }

    func bleManager(_ manager: BLELampManager, didDisconnect peripheralID: UUID?) {
        // A delayed disconnect from the lamp we just left must not erase the
        // pending/current ownership of the replacement lamp.
        if manager.connectedPeripheralID == nil || manager.connectedPeripheralID == peripheralID {
            pendingAutoConnectPeripheralID = nil
        }
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
        // CoreBluetooth may deliver A's disconnect after B has already been
        // selected. Preserve B's global identity in that case.
        if manager.connectedPeripheralID == nil {
            connectedLocalID = ""
        }
        persistLocalRecords()
        rebuildLamps()
        if !manualAddFlowActive && manager.connectedPeripheralID == nil { manager.startScan() }
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
        record.bleRSSI = status.rssi
        record.route = selectedRoute(
            for: record,
            local: record,
            cloud: record.cloudLampId.flatMap { cloudID in
                dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame })
            }
        )
        record.online = record.route != .offline

        let currentState = lamps.first(where: { $0.canonicalID == record.canonicalID })?.state ?? record.state
        let timerAccepted = registerTimerState(
            for: record,
            remainingSeconds: status.timerRemainingSeconds,
            receivedAt: receivedAt
        )
        var incomingState = record.state
        incomingState.power = status.power
        incomingState.brightness = status.targetBrightness
        if let reportedRemembered = status.rememberedBrightness {
            let remembered = max(1, min(100, reportedRemembered))
            incomingState.rememberedBrightness = remembered
            rememberedBrightnessByLamp[record.id.uppercased()] = remembered
            rememberedBrightnessByLamp[record.canonicalID.uppercased()] = remembered
            if let cloudID = record.cloudLampId?.uppercased() {
                rememberedBrightnessByLamp[cloudID] = remembered
            }
        } else if status.targetBrightness > 0 {
            // Backward compatibility with older firmware that did not report
            // lastNonZeroBrightness while the lamp was OFF.
            incomingState.rememberedBrightness = status.targetBrightness
            rememberedBrightnessByLamp[record.id.uppercased()] = status.targetBrightness
            rememberedBrightnessByLamp[record.canonicalID.uppercased()] = status.targetBrightness
        }
        incomingState.fadeMode = status.fadeMode
        incomingState.timerRemainingSeconds = timerAccepted ? status.timerRemainingSeconds : currentState.timerRemainingSeconds
        record.state = protectedIncomingState(incomingState, for: record, current: currentState)
        if timerAccepted {
            scheduleTimerNotification(for: record, remainingSeconds: status.timerRemainingSeconds)
        }
        localRecords[key] = record
        rebuildLamps()
    }

    func bleManager(_ manager: BLELampManager, didReceiveRememberedBrightness percent: Int, lampID: String) {
        let key = (lampID.isEmpty ? connectedLocalID : lampID).uppercased()
        guard !key.isEmpty else { return }
        let remembered = max(1, min(100, percent))
        rememberedBrightnessByLamp[key] = remembered

        if var record = localRecords[key] {
            record.state.rememberedBrightness = remembered
            localRecords[key] = record
            rememberedBrightnessByLamp[record.canonicalID.uppercased()] = remembered
            if let cloudID = record.cloudLampId?.uppercased() {
                rememberedBrightnessByLamp[cloudID] = remembered
            }
        }

        if let index = lamps.firstIndex(where: {
            $0.id.caseInsensitiveCompare(key) == .orderedSame ||
            $0.canonicalID.caseInsensitiveCompare(key) == .orderedSame
        }) {
            lamps[index].state.rememberedBrightness = remembered
            rememberedBrightnessByLamp[lamps[index].canonicalID.uppercased()] = remembered
        }
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

    func bleManager(_ manager: BLELampManager, didUpdateRSSI rssi: Int, lampID: String) {
        let key = (lampID.isEmpty ? connectedLocalID : lampID).uppercased()
        guard !key.isEmpty else { return }
        var record = localRecords[key] ?? .placeholder(id: key)
        record.bleRSSI = rssi
        localRecords[key] = record
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
    func localController(_ controller: LocalLampController, didReceiveRealtime snapshot: WiFiLampSnapshot) {
        apply(
            snapshot: snapshot,
            observedAt: Date(),
            authoritative: true,
            confirmsWiFiCommandPath: false
        )
    }
    func localController(_ controller: LocalLampController, didChangeStatus status: String) { localNetworkStatus = status }
}

extension AppViewModel: CloudRealtimeClientDelegate {
    func realtimeClient(_ client: CloudRealtimeClient, didChangeStatus status: String, connected: Bool) {
        cloudStatus = status
        cloudConnected = connected

        // RF5.2: route badges are derived from cloudConnected + current device
        // state. Rebuild immediately on every app-socket transition; previously
        // a reconnect could succeed internally while the visible lamp stayed
        // Offline until some unrelated state event arrived later.
        rebuildLamps()

        if connected {
            scheduleCloudRouteReconciliation()
        } else {
            // An ACK cannot be correlated while this app socket is down. Keep
            // lastCloudMutationAt so the bounded handover fence still protects
            // against a command that may already be in flight, but drop the
            // in-memory ACK correlation entries so they cannot leak.
            pendingCloudMutationCommands.removeAll()
            latestCloudMutationCommandByLampID.removeAll()
        }
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
            // Even an empty device list is authoritative for the just-
            // authenticated account socket. Re-evaluate visible routes now.
            rebuildLamps()
            return
        }

        if type == "state" || type == "ack" {
            var envelope = object
            envelope["online"] = true
            if (type == "state" || object.object("state") != nil), let lamp = api.parseLamp(envelope) {
                applyCloudLamp(lamp, receivedAt: receivedAt)
            }
            if type == "ack" {
                let commandID = object.string("commandId")
                if let lampID = pendingCloudMutationCommands.removeValue(forKey: commandID) {
                    // Only the newest cloud mutation for this lamp may release
                    // the fence. An older ACK can arrive after a newer cloud
                    // command and must not make that newer command look settled.
                    if latestCloudMutationCommandByLampID[lampID] == commandID {
                        latestCloudMutationCommandByLampID.removeValue(forKey: lampID)
                        lastCloudMutationAt.removeValue(forKey: lampID)
                    }
                }
                if object.bool("success") == false {
                    let message = firstNonBlank(object.string("error"), "The lamp rejected the cloud command.")
                    errorMessage = message
                }
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
