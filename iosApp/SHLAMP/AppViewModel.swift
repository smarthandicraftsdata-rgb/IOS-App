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
    let deliveryAttempt: UInt8

    var commandID: String {
        let base = "RF5-\(controllerID)-\(controllerSession)-\(intentSequence)-\(kind.commandSuffix)"
        return deliveryAttempt == 0 ? base : "\(base)-R\(deliveryAttempt)"
    }

    /// RF5.4.3 Cloud-final reliability: a transport retry gets a fresh command
    /// ID but keeps the exact controller/session/sequence/value. If the first
    /// delivery actually reached the ESP and only its ACK was lost, the ESP's
    /// ordered gate returns DUPLICATE without a second physical mutation. If
    /// the first delivery never reached the ESP, the retry may apply normally.
    func reissuedForTransportRetry(_ attempt: UInt8) -> OrderedControlIntent {
        OrderedControlIntent(
            controllerID: controllerID,
            controllerSession: controllerSession,
            intentSequence: intentSequence,
            kind: kind,
            action: action,
            value: value,
            deliveryAttempt: attempt
        )
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
            value: value,
            deliveryAttempt: 0
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
    private struct RouteHealthState {
        var consecutiveFailures = 0
        var lastAckAt: Date?
        var lastAckLatencyMs: Double?
        var degradedUntil: Date?
    }

    private enum OrderedRouteAttemptOutcome: Sendable {
        case success(LampConnectionRoute)
        case failure(String)
        case skipped
    }

    private enum CloudAttemptOutcome: Sendable {
        case success
        case failure(String)
    }
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
    // RF5.4.3-R3.1: The default NWPath can legitimately prefer cellular even
    // while an authenticated Local WS remains alive on Wi-Fi. Track Wi-Fi as
    // an independently usable interface so route-health does not collapse to
    // Offline merely because iOS changed its default internet route.
    private let wifiInterfaceMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let pathQueue = DispatchQueue(label: "com.smarthandicrafts.shlamp.network")
    private let wifiInterfaceQueue = DispatchQueue(label: "com.smarthandicrafts.shlamp.network.wifi")
    private let localStoreKey = "shlamp.ios.localRecords.v2"
    private var manualAddFlowActive = false
    private var transientLocalIDs: Set<String> = []
    private var identityProbePeripheralID: UUID?
    private var identityProbeMatched = false
    private var pendingAutoConnectPeripheralID: UUID?
    private var probedPeripheralIDs: Set<UUID> = []
    private var wifiPathAvailable = false
    private var wifiInterfaceAvailable = false
    private var wifiAttachedAt: Date?
    private var cloudReconcileTask: Task<Void, Never>?
    private var cloudSessionRefreshTask: Task<CloudSession, Error>?
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
    private var connectionRecoveryTask: Task<Void, Never>?
    private var lastBLERecoveryAttemptAt = Date.distantPast
    private var lastLocalDiscoveryRefreshAt = Date.distantPast
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
    private var routeHealth: [String: RouteHealthState] = [:]
    private let routeHedgeDelayMs = 120 // R3.3: hedge only BLE<->LAN; Cloud is a fallback, never a parallel local-route competitor
    // RF5.4.3: only the latest logical intent is allowed to recover. Each
    // recovery attempt keeps the same ordered sequence/value but uses a fresh
    // command ID, so a timed-out/expired Render row cannot permanently strand
    // a final OFF or slider-release value. A newer user intent increments the
    // field generation and immediately cancels these retries.
    private let durableDeliveryRetryDelaysMs = [0, 450, 1_100] // R3.3: give ESP/Render time to drain before final-intent transport retries

    private let wifiHealthTTL: TimeInterval = 30 // R3.3: validated LAN lease survives brief Local-WS/cloud handover churn
    private let wifiTransitionGrace: TimeInterval = 12
    private let localPollInterval: Duration = .seconds(2)
    private let connectionRecoveryInterval: Duration = .seconds(2)
    private let localDiscoveryRecoveryCadence: TimeInterval = 8
    private let bleRecoveryCadence: TimeInterval = 4

    init() {
        restoreLocalRecords()
        ble.delegate = self
        local.delegate = self
        realtime.delegate = self
        startNetworkMonitor()
        startLiveClock()
        startLocalStatusPolling()
        startConnectionRecoverySupervisor()
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
        cloudSessionRefreshTask?.cancel()
        cloudSessionRefreshTask = nil
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
        for record in localRecords.values {
            guard let host = record.localHost else { continue }
            local.startRealtime(host: host, expectedLampID: record.physicalLocalIDNormalized)
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

    private var localWiFiAvailable: Bool {
        wifiPathAvailable || wifiInterfaceAvailable
    }

    func setRoutePreference(_ lamp: LampRecord, preference: LampRoutePreference) {
        updateLocalRecord(for: lamp) { $0.routePreference = preference }
        notice = "Connection set to \(preference.label)."
        switch preference {
        case .bluetooth:
            if !canUseBLE(lamp) { ble.startScan() }
        case .wifi, .automatic:
            if localWiFiAvailable { local.startDiscovery() }
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
            (lamp.physicalLocalIDNormalized != nil && candidate.physicalLocalIDNormalized == lamp.physicalLocalIDNormalized) ||
            (lamp.cloudIDNormalized != nil && candidate.cloudIDNormalized == lamp.cloudIDNormalized)
        } ?? lamp
    }

    private func rememberedBrightness(for lamp: LampRecord) -> Int {
        let fresh = freshestLampRecord(for: lamp)
        let keys = [
            lamp.canonicalID.uppercased(),
            lamp.id.uppercased(),
            lamp.physicalLocalIDNormalized,
            lamp.cloudIDNormalized,
            fresh.canonicalID.uppercased(),
            fresh.id.uppercased(),
            fresh.physicalLocalIDNormalized,
            fresh.cloudIDNormalized
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
                    generation: generation,
                    field: "output"
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
                    generation: generation,
                    field: "output"
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
                let usedRoute = await self.sendStreamingOrderedIntent(lamp: lamp, intent: pending.intent, generation: pending.generation)
                // RF5.3: Cloud slider traffic crosses TLS + Render + the ESP device
                // socket. Four live frames/second is visually smooth while avoiding
                // the burst that previously destabilized the device WebSocket. LAN
                // and BLE keep the original 10 Hz responsiveness. The release value
                // is still sent immediately by setBrightness() as a durable command.
                let frameDelayMs = usedRoute == .cloud ? 250 : 100
                try? await Task.sleep(for: .milliseconds(frameDelayMs))
            }
        }
    }

    private func sendStreamingOrderedIntent(lamp: LampRecord, intent: OrderedControlIntent, generation: Int) async -> LampConnectionRoute? {
        let order = routeOrder(for: lamp)
        for route in order {
            guard isCurrentControlIntent(generation, for: lamp, field: "output") else { return nil }
            switch route {
            case .wifi:
                guard isWiFiHealthy(lamp), let host = lamp.localHost,
                      let expectedPhysicalID = lamp.physicalLocalIDNormalized else { continue }
                do {
                    _ = try await local.sendOrderedCommand(host: host, expectedLampID: expectedPhysicalID, intent: intent, waitForAck: false)
                    return .wifi
                } catch {
                    markWiFiFailure(for: lamp)
                }
            case .bluetooth:
                guard canUseBLE(lamp) else { continue }
                do {
                    try await ble.sendOrdered(intent: intent, waitForAck: false)
                    return .bluetooth
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
                    return .cloud
                } catch { continue }
            case .offline:
                continue
            }
        }
        return nil
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
                        guard let expectedPhysicalID = lamp.physicalLocalIDNormalized else {
                            throw AppError.message("The physical lamp identity is unavailable for local Wi-Fi control.")
                        }
                        if let snapshot = try await self.local.sendPowerMode(host: host, expectedLampID: expectedPhysicalID, mode: mode) {
                            return snapshot
                        }
                        let physicalID = expectedPhysicalID
                        var fallback = self.localSnapshots[physicalID] ?? WiFiLampSnapshot(
                            lampId: physicalID, cloudLampId: lamp.cloudIDNormalized, lampName: lamp.name,
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
                    generation: generation,
                    field: "fade"
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
                    generation: generation,
                    field: "timer"
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
                        guard let expectedPhysicalID = lamp.physicalLocalIDNormalized else {
                            throw AppError.message("The physical lamp identity is unavailable for local identification.")
                        }
                        try await self.local.identify(host: host, expectedLampID: expectedPhysicalID)
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
            if let host = lamp.localHost, let expectedPhysicalID = lamp.physicalLocalIDNormalized {
                _ = try? await local.rename(host: host, expectedLampID: expectedPhysicalID, name: name)
            }
            if let remoteID = lamp.cloudIDNormalized {
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
        guard let remoteID = lamp.cloudIDNormalized else { return nil }
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
        guard lamp.cloudClaimed,
              let cloud = lamp.cloudIDNormalized,
              dashboard.lamps.contains(where: { $0.id.caseInsensitiveCompare(cloud) == .orderedSame }) else {
            throw AppError.message("Move closer to the lamp or enable remote access.")
        }
        return cloud
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

    private func refreshPendingHoldForRetry(_ lamp: LampRecord, intent: OrderedControlIntent) {
        switch intent.kind {
        case .output:
            if let power = intent.value["power"] as? Bool {
                setPendingPower(lamp, value: power, lifetime: 3.0)
            }
            if let brightness = intent.value["brightness"] as? Int {
                setPendingBrightness(lamp, value: clamp(brightness, 0...100), lifetime: 3.0)
            }
        case .fade:
            if let mode = intent.value["fadeMode"] as? Int {
                setPendingFade(lamp, value: clamp(mode, 0...3), lifetime: 3.0)
            }
        case .timer:
            if let minutes = intent.value["timerMinutes"] as? Int {
                setPendingTimer(lamp, seconds: Int64(max(0, minutes) * 60), lifetime: 4.0)
            }
        }
    }

    /// RF5.4.3 retries DELIVERY failures, never semantic/programming failures.
    /// COMMAND_EXPIRED is deliberately retryable: the retry gets a fresh
    /// transport commandId/TTL while preserving the exact ordered
    /// controller/session/sequence/value. The ESP therefore applies it only if
    /// the original delivery never committed, returns DUPLICATE if it did, and
    /// returns STALE if a newer user intent has already won.
    private func shouldRetryOrderedDelivery(after error: Error) -> Bool {
        if case AppError.unauthorized = error { return false }
        return shouldRetryOrderedDelivery(message: error.localizedDescription)
    }

    private func shouldRetryOrderedDelivery(message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return true }

        // These are semantic/identity/input failures. Retrying the same intent
        // cannot make them valid and would only add traffic or hide a real bug.
        let nonRetryableMarkers = [
            "STALE_INTENT",
            "ORDERING_METADATA_INVALID",
            "INVALID_INTENT_KIND",
            "INVALID_OUTPUT_STATE",
            "INVALID_POWER_VALUE",
            "INVALID_BRIGHTNESS",
            "INVALID_FADE_MODE",
            "INVALID_TIMER",
            "COMMAND_ID_INVALID",
            "ACTION_MISSING",
            "ACTION_NOT_SUPPORTED",
            "TYPE_MISSING",
            "WRONG_DEVICE",
            "WRONG_LAMP",
            "DIFFERENT LAMP",
            "UNAUTHORIZED",
            "FORBIDDEN",
            "INVALID CONTROLLER",
            "INVALID LAMP"
        ]
        if nonRetryableMarkers.contains(where: normalized.contains) { return false }

        // Explicit expiry and all transport/ACK timeout/disconnect failures are
        // recoverable while this is still the newest field generation.
        return true
    }

    private func performOrderedRouted(
        lamp: LampRecord,
        intent: OrderedControlIntent,
        generation: Int,
        field: String
    ) async throws {
        var lastError: Error?

        for attemptIndex in durableDeliveryRetryDelaysMs.indices {
            guard isCurrentControlIntent(generation, for: lamp, field: field) else { return }

            let delayMs = durableDeliveryRetryDelaysMs[attemptIndex]
            if delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled,
                      isCurrentControlIntent(generation, for: lamp, field: field) else { return }
            }

            let deliveryIntent = attemptIndex == 0
                ? intent
                : intent.reissuedForTransportRetry(UInt8(attemptIndex))

            if attemptIndex > 0 {
                // Keep optimistic UI ownership alive while the newest command
                // is actively recovering. Matching authoritative ACK/state
                // clears these holds immediately; a newer user intent cancels
                // this recovery through the generation guard above.
                refreshPendingHoldForRetry(lamp, intent: deliveryIntent)
                print("RF5.4.3 CMD retry id=\(deliveryIntent.commandID) baseSeq=\(intent.intentSequence) attempt=\(attemptIndex)")
            }

            do {
                try await performOrderedRoutedSingleAttempt(
                    lamp: lamp,
                    intent: deliveryIntent,
                    generation: generation,
                    field: field
                )
                return
            } catch {
                lastError = error
                guard isCurrentControlIntent(generation, for: lamp, field: field) else { return }
                guard shouldRetryOrderedDelivery(after: error) else { throw error }
            }
        }

        throw lastError ?? AppError.message("No available connection could control this lamp.")
    }

    private func performOrderedRoutedSingleAttempt(
        lamp: LampRecord,
        intent: OrderedControlIntent,
        generation: Int,
        field: String
    ) async throws {
        guard isCurrentControlIntent(generation, for: lamp, field: field) else { return }
        let currentLamp = freshestLampRecord(for: lamp)
        let orderedRoutes = routeOrder(for: currentLamp).filter { $0 != .offline }
        guard !orderedRoutes.isEmpty else {
            throw AppError.message("No available connection could control this lamp.")
        }

        let commandStartedAt = Date()
        print("RF5.4.3-R3.3 CMD app_create id=\(intent.commandID) seq=\(intent.intentSequence) action=\(intent.action) lamp=\(lamp.canonicalID)")

        // R3.3 physical architecture:
        // 1) BLE and LAN may hedge each other using the SAME logical command.
        // 2) Cloud NEVER runs in parallel with a usable local route.
        // This prevents a Cloud fault/backpressure episode from dragging a
        // healthy same-network lamp into Offline or doubling device ingress.
        let localPriority = orderedRoutes.filter { $0 == .bluetooth || $0 == .wifi }
        let initiallyUsableLocal = localPriority.filter { routeCanBeAttempted($0, lamp: currentLamp) }

        var lastFailure = "No available connection could control this lamp."

        if !initiallyUsableLocal.isEmpty {
            let localOutcome = await withTaskGroup(
                of: OrderedRouteAttemptOutcome.self,
                returning: OrderedRouteAttemptOutcome.self
            ) { group in
                for (index, route) in initiallyUsableLocal.enumerated() {
                    let delayMs = index * routeHedgeDelayMs
                    group.addTask { [weak self] in
                        guard let self else { return .skipped }
                        if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
                        guard !Task.isCancelled else { return .skipped }
                        let stillCurrent = await self.isCurrentControlIntent(generation, for: lamp, field: field)
                        guard stillCurrent else { return .skipped }
                        let liveLamp = await self.freshestLampRecord(for: lamp)
                        guard await self.routeCanBeAttempted(route, lamp: liveLamp) else { return .skipped }
                        do {
                            return .success(try await self.attemptOrderedRoute(route, lamp: lamp, intent: intent))
                        } catch {
                            return .failure(error.localizedDescription)
                        }
                    }
                }

                var localFailure = "No local route acknowledged the command."
                while let result = await group.next() {
                    switch result {
                    case .success:
                        group.cancelAll()
                        return result
                    case .failure(let message):
                        if !message.isEmpty { localFailure = message }
                    case .skipped:
                        break
                    }
                }
                return .failure(localFailure)
            }

            guard isCurrentControlIntent(generation, for: lamp, field: field) else { return }
            if case .success(let route) = localOutcome {
                print("RF5.4.3-R3.3 CMD app_done id=\(intent.commandID) route=\(route.rawValue) total=\(Int(Date().timeIntervalSince(commandStartedAt) * 1000))ms")
                updateLocalRecord(for: lamp) { record in
                    record.route = route
                    record.online = true
                }
                return
            }
            if case .failure(let message) = localOutcome, !message.isEmpty {
                lastFailure = message
            }
        }

        // Cloud is a second-stage fallback only. If LAN/BLE is working, this
        // branch is never entered and Cloud cannot interfere with local control
        // or the displayed route.
        guard isCurrentControlIntent(generation, for: lamp, field: field) else { return }
        if orderedRoutes.contains(.cloud) {
            let liveLamp = freshestLampRecord(for: lamp)
            if routeCanBeAttempted(.cloud, lamp: liveLamp) {
                do {
                    let route = try await attemptOrderedRoute(.cloud, lamp: lamp, intent: intent)
                    print("RF5.4.3-R3.3 CMD app_done id=\(intent.commandID) route=\(route.rawValue) total=\(Int(Date().timeIntervalSince(commandStartedAt) * 1000))ms")
                    updateLocalRecord(for: lamp) { record in
                        record.route = route
                        record.online = true
                    }
                    return
                } catch {
                    lastFailure = error.localizedDescription
                }
            }
        }

        throw AppError.message(lastFailure)
    }

    private func attemptOrderedRoute(
        _ route: LampConnectionRoute,
        lamp: LampRecord,
        intent: OrderedControlIntent
    ) async throws -> LampConnectionRoute {
        let target = freshestLampRecord(for: lamp)
        let startedAt = Date()
        print("RF5.4.3 CMD app_send id=\(intent.commandID) route=\(route.rawValue) action=\(intent.action)")
        do {
            switch route {
            case .wifi:
                guard isWiFiHealthy(target), let host = target.localHost else {
                    throw AppError.message("Local Wi-Fi is not currently reachable.")
                }
                guard let expectedPhysicalID = target.physicalLocalIDNormalized else {
                    throw AppError.message("The physical lamp identity is not available for Local Wi-Fi control.")
                }
                let requestStartedAt = Date()
                if let snapshot = try await local.sendOrderedCommand(host: host, expectedLampID: expectedPhysicalID, intent: intent, waitForAck: true) {
                    apply(snapshot: snapshot, observedAt: requestStartedAt, authoritative: true)
                }
            case .bluetooth:
                guard canUseBLE(target) else {
                    throw AppError.message("Bluetooth is not ready for this lamp.")
                }
                try await ble.sendOrdered(intent: intent, waitForAck: true)
            case .cloud:
                guard isCloudHealthy(target) else {
                    throw AppError.message("Remote cloud route is not currently reachable.")
                }
                let remoteID = try remoteID(for: target)
                try await sendCloudOrderedCommand(lampID: remoteID, intent: intent)
            case .offline:
                throw AppError.message("Offline is not a control route.")
            }
            noteRouteSuccess(route, lamp: target, startedAt: startedAt)
            print("RF5.4.3 CMD app_ack id=\(intent.commandID) route=\(route.rawValue) rtt=\(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
            return route
        } catch {
            print("RF5.4.3 CMD app_fail id=\(intent.commandID) route=\(route.rawValue) after=\(Int(Date().timeIntervalSince(startedAt) * 1000))ms error=\(error.localizedDescription)")
            noteRouteFailure(route, lamp: target)
            if route == .wifi { markWiFiFailure(for: target) }
            throw error
        }
    }

    private func routeOrder(for lamp: LampRecord) -> [LampConnectionRoute] {
        let base: [LampConnectionRoute]
        switch lamp.routePreference {
        case .remote:
            // Strict Remote preference remains Cloud-only by user choice.
            return [.cloud]
        case .bluetooth:
            base = [.bluetooth, .wifi, .cloud]
        case .wifi:
            base = [.wifi, .bluetooth, .cloud]
        case .automatic:
            // Production priority is semantic-health BLE > LAN > Cloud. RSSI is
            // diagnostic information, not a reason to abandon an ACK-healthy
            // BLE path. Circuit-breaker failures below can still demote it.
            base = [.bluetooth, .wifi, .cloud]
        }

        // A route that has missed two semantic ACKs is moved behind healthy
        // alternatives for a short probe window, rather than forcing every new
        // command to pay the same timeout. It is not permanently disabled.
        let now = Date()
        let healthy = base.filter { !isRouteCircuitOpen($0, lamp: lamp, now: now) }
        let degraded = base.filter { isRouteCircuitOpen($0, lamp: lamp, now: now) }
        return healthy + degraded
    }

    private func routeCanBeAttempted(_ route: LampConnectionRoute, lamp: LampRecord) -> Bool {
        switch route {
        case .bluetooth: return canUseBLE(lamp)
        case .wifi: return isWiFiHealthy(lamp)
        case .cloud: return isCloudHealthy(lamp)
        case .offline: return false
        }
    }

    private func routeHealthKey(_ route: LampConnectionRoute, lamp: LampRecord) -> String {
        "\(lamp.canonicalID.uppercased())|\(route.rawValue)"
    }

    private func isRouteCircuitOpen(_ route: LampConnectionRoute, lamp: LampRecord, now: Date = Date()) -> Bool {
        guard let until = routeHealth[routeHealthKey(route, lamp: lamp)]?.degradedUntil else { return false }
        return until > now
    }

    private func noteRouteSuccess(_ route: LampConnectionRoute, lamp: LampRecord, startedAt: Date) {
        let key = routeHealthKey(route, lamp: lamp)
        var health = routeHealth[key] ?? RouteHealthState()
        health.consecutiveFailures = 0
        health.lastAckAt = Date()
        health.lastAckLatencyMs = Date().timeIntervalSince(startedAt) * 1000
        health.degradedUntil = nil
        routeHealth[key] = health
    }

    private func noteRouteFailure(_ route: LampConnectionRoute, lamp: LampRecord) {
        let key = routeHealthKey(route, lamp: lamp)
        var health = routeHealth[key] ?? RouteHealthState()
        health.consecutiveFailures += 1
        if health.consecutiveFailures >= 2 {
            let cooldown: TimeInterval
            switch route {
            case .bluetooth: cooldown = 2
            case .wifi: cooldown = 3
            case .cloud: cooldown = 5
            case .offline: cooldown = 0
            }
            health.degradedUntil = Date().addingTimeInterval(cooldown)
        }
        routeHealth[key] = health
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
        guard let cloudID = lamp.cloudIDNormalized else { return false }
        return dashboard.lamps.contains { cloudLamp in
            cloudLamp.id.caseInsensitiveCompare(cloudID) == .orderedSame && cloudLamp.online
        }
    }

    // RF5.4 automatic routing uses fixed semantic-health priority:
    // BLE > Local Wi-Fi > Cloud. RSSI remains available for diagnostics.

    private func markWiFiFailure(for lamp: LampRecord) {
        let key = lamp.id.uppercased()
        let failures = (localFailureCounts[key] ?? 0) + 1
        localFailureCounts[key] = failures

        // RF5.4.3-R3.3 physical fix: one transient Local-WS/HTTP miss must not
        // erase the last proven LAN lease and make the card say Offline merely
        // because Cloud is also down. Only revoke the lease after three
        // consecutive local failures AND no validated realtime socket remains.
        let realtimeStillHealthy: Bool
        if let host = lamp.localHost {
            realtimeStillHealthy = local.isRealtimeHealthy(
                host: host,
                expectedLampID: lamp.physicalLocalIDNormalized
            )
        } else {
            realtimeStillHealthy = false
        }
        if failures >= 3 && !realtimeStillHealthy {
            for stateKey in stateKeys(for: lamp) { wifiConfirmedAt.removeValue(forKey: stateKey) }
        }

        updateLocalRecord(for: lamp) { record in
            // RF5.2.1: a remembered host is identity/recovery metadata, not a
            // liveness bit. Never erase it merely because transient LAN probes
            // failed; doing so stopped all future direct recovery while the
            // iPhone and ESP were still on the same Wi-Fi.
            _ = failures
            record.route = self.selectedRoute(
                for: record,
                local: record,
                cloud: record.cloudLampId.flatMap { cloudID in
                    self.dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame })
                }
            )
            record.online = record.route != .offline
        }
    }

    private func updateLocalRecord(for lamp: LampRecord, change: (inout LampRecord) -> Void) {
        let keys = [lamp.id.uppercased(), lamp.physicalLocalIDNormalized, lamp.cloudIDNormalized].compactMap { $0 }
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
                if self.localWiFiAvailable {
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
                            if self.local.isRealtimeHealthy(host: host, expectedLampID: record.physicalLocalIDNormalized) { continue }
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
        if let host = lamp.localHost, local.isRealtimeHealthy(host: host, expectedLampID: lamp.physicalLocalIDNormalized) {
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

        // RF5.2.1: keep the last-known hostname/IP indefinitely. It is needed
        // by the recovery supervisor to reopen the protocol-v3 socket even
        // after Bonjour or an HTTP probe temporarily misses the lamp.
        record.route = selectedRoute(
            for: record,
            local: record,
            cloud: record.cloudLampId.flatMap { cloudID in
                dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame })
            }
        )
        record.online = record.route != .offline
        localRecords[key] = record
        persistLocalRecords()
        rebuildLamps()
    }

    private func startConnectionRecoverySupervisor() {
        connectionRecoveryTask?.cancel()
        connectionRecoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.manualAddFlowActive {
                    self.recoverOfflineConnections()
                }
                try? await Task.sleep(for: self.connectionRecoveryInterval)
            }
        }
    }

    private func recoverOfflineConnections(now: Date = Date()) {
        let localCandidates = localRecords.values
            .filter { $0.routePreference != .remote }
            .sorted { $0.canonicalID < $1.canonicalID }

        // LAN recovery is independent of Cloud. When the phone and lamp are on
        // the same Wi-Fi, keep reopening the known protocol-v3 endpoint and
        // periodically refresh Bonjour even if Render is completely offline.
        if localWiFiAvailable {
            for record in localCandidates.prefix(2) {
                guard let host = record.localHost, !isWiFiHealthy(record, now: now) else { continue }
                local.recoverRealtime(host: host, expectedLampID: record.physicalLocalIDNormalized)
            }

            if localCandidates.contains(where: { !isWiFiHealthy($0, now: now) }),
               now.timeIntervalSince(lastLocalDiscoveryRefreshAt) >= localDiscoveryRecoveryCadence {
                lastLocalDiscoveryRefreshAt = now
                local.restartDiscovery()
            }
        }

        guard ble.isBluetoothPoweredOn else { return }

        let focusedRecord = focusedLampCanonicalID.flatMap { focused in
            localCandidates.first(where: { $0.canonicalID.uppercased() == focused })
        }
        let target: LampRecord?
        if let focusedRecord, !canUseBLE(focusedRecord) {
            target = focusedRecord
        } else if !ble.isReady {
            target = localCandidates.first(where: { !canUseBLE($0) })
        } else {
            target = nil
        }

        guard let target, !ble.isConnecting,
              now.timeIntervalSince(lastBLERecoveryAttemptAt) >= bleRecoveryCadence else { return }
        lastBLERecoveryAttemptAt = now

        // CoreBluetooth can reconnect a known UUID directly even when the
        // 10-second scan window missed its advertisement. If no identifier has
        // been learned yet, restart scanning. This makes BLE self-healing
        // instead of depending on one onAppear scan.
        if let peripheralID = target.bleIdentifier {
            pendingAutoConnectPeripheralID = peripheralID
            ble.connect(to: peripheralID)
        } else {
            pendingAutoConnectPeripheralID = nil
            ble.startScan()
        }
    }

    private func isWiFiHealthy(_ lamp: LampRecord, now: Date = Date()) -> Bool {
        guard let host = lamp.localHost, lamp.physicalLocalIDNormalized != nil else { return false }
        let keys = stateKeys(for: lamp)
        // RF5.4: there is deliberately NO Cloud→LAN time fence. Every ordered
        // route carries the same controller/session/sequence identity, so an
        // older delayed Cloud delivery is rejected by the ESP. A healthy LAN
        // route must be usable immediately instead of waiting 2.25 seconds.

        // RF5.2: protocol v3 changed the local WebSocket from Phase-A
        // state-only transport into an ordered command channel with semantic
        // ACK and same-command HTTP fallback. Once the socket has received and
        // validated an authoritative state from this physical lamp, it is a
        // complete proof of LAN reachability on the current phone Wi-Fi path.
        // Requiring a separate HTTP success here was the reason the video could
        // show Offline even while the ESP logged a connected local realtime
        // client.
        if local.isRealtimeHealthy(host: host, expectedLampID: lamp.physicalLocalIDNormalized, now: now) { return true }

        // A validated Local WS is stronger evidence than the phone's default
        // route. If no realtime proof exists, only then require an available
        // Wi-Fi interface before trusting bounded HTTP liveness evidence.
        guard localWiFiAvailable else { return false }

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

        // RF5.4.3-R3.3: do not fire WS and REST for the same Cloud command in
        // parallel. Hardware logs showed this producing repeated Prisma
        // commandId collisions and unnecessary ingress pressure. Prefer the
        // authenticated realtime socket; only if it fails, send the SAME ID
        // through REST. ESP/Render idempotency still protects the ACK-lost case.
        if cloudConnected {
            do {
                try await sendCloudWebSocketOrderedCommand(
                    lampID: normalizedLampID,
                    intent: intent
                )
                lastCloudMutationAt.removeValue(forKey: normalizedLampID)
                return
            } catch {
                // Continue immediately to bounded REST semantic-ACK fallback.
            }
        }

        try await sendCloudRESTOrderedCommand(lampID: normalizedLampID, intent: intent)
        lastCloudMutationAt.removeValue(forKey: normalizedLampID)
    }

    private func sendCloudWebSocketOrderedCommand(lampID: String, intent: OrderedControlIntent) async throws {
        let startedAt = Date()
        let ack = try await realtime.sendCommandAwaitingAck(
            lampID: lampID,
            action: intent.action,
            value: intent.value,
            commandID: intent.commandID,
            timeout: 0.60
        )
        if ack.bool("success") == false {
            throw AppError.message(firstNonBlank(ack.string("error"), "The lamp rejected the cloud command."))
        }
        print("RF5.4.3 CMD cloud_ws_ack id=\(intent.commandID) rtt=\(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
    }

    private func sendCloudRESTOrderedCommand(lampID: String, intent: OrderedControlIntent) async throws {
        let startedAt = Date()
        let ack = try await withAccessToken { token in
            try await api.sendCommandAndWaitForAck(
                accessToken: token,
                lampId: lampID,
                action: intent.action,
                value: intent.value,
                commandID: intent.commandID,
                timeout: 1.6
            )
        }
        if ack.bool("success") == false {
            throw AppError.message(firstNonBlank(ack.string("error"), "The lamp rejected the cloud command."))
        }
        print("RF5.4.3 CMD cloud_rest_ack id=\(intent.commandID) rtt=\(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
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

    private func activateLocalWiFiRecovery() {
        wifiAttachedAt = Date()
        // R3.3 physical fix: do NOT erase the last validated LAN lease merely
        // because the Wi-Fi monitor emitted a fresh attachment event. iOS can
        // bounce path/interface callbacks while the same authenticated Local WS
        // is reconnecting. The 30-second TTL + three-failure revocation below
        // bounds stale evidence without manufacturing an Offline gap.
        let remembered = Array(localRecords.values.filter { $0.localHost != nil })
        for record in remembered {
            guard let host = record.localHost else { continue }
            local.startRealtime(host: host, expectedLampID: record.physicalLocalIDNormalized)
            let key = record.id.uppercased()
            guard !localPollInFlight.contains(key) else { continue }
            localPollInFlight.insert(key)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.localPollInFlight.remove(key) }
                let requestStartedAt = Date()
                if let snapshot = try? await self.local.readStatus(host: host) {
                    self.apply(snapshot: snapshot, observedAt: requestStartedAt)
                } else {
                    // Do not throw away a remembered host after one transition-time
                    // miss. Normal realtime/poll recovery keeps trying independently.
                    self.rebuildLamps()
                }
            }
        }
        local.restartDiscovery()
    }

    private func deactivateLocalWiFiIfUnavailable() {
        // Never tear down a validated realtime route just because iOS selected
        // cellular as its default internet route. Only stop discovery / downgrade
        // when neither the default path nor the dedicated Wi-Fi monitor sees Wi-Fi.
        guard !localWiFiAvailable else { return }
        wifiAttachedAt = nil
        local.stopDiscovery()
        wifiConfirmedAt.removeAll()
        for key in Array(localRecords.keys) {
            guard var record = localRecords[key], record.route == .wifi else { continue }
            let cloud = record.cloudLampId.flatMap { cloudID in
                dashboard.lamps.first(where: { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame })
            }
            record.route = self.selectedRoute(for: record, local: record, cloud: cloud)
            record.online = record.route != .offline
            localRecords[key] = record
        }
        persistLocalRecords()
        rebuildLamps()
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
                // iPhone changes between cellular and Wi-Fi. The Cloud route is
                // governed by the default internet path; LAN is governed separately
                // by the dedicated Wi-Fi monitor + validated Local WS.
                if path.status == .satisfied, let currentSession = self.session {
                    self.realtime.start(
                        token: currentSession.accessToken,
                        homeID: self.dashboard.homes.first?.id ?? "default",
                        force: true
                    )
                    self.scheduleCloudRouteReconciliation()
                }

                if hasWiFi {
                    self.activateLocalWiFiRecovery()
                } else {
                    self.deactivateLocalWiFiIfUnavailable()
                }
            }
        }
        pathMonitor.start(queue: pathQueue)

        wifiInterfaceMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.wifiInterfaceAvailable != available
                self.wifiInterfaceAvailable = available
                guard changed else { return }
                if available {
                    self.activateLocalWiFiRecovery()
                } else {
                    self.deactivateLocalWiFiIfUnavailable()
                }
            }
        }
        wifiInterfaceMonitor.start(queue: wifiInterfaceQueue)
    }

    private func restoreLocalRecords() {
        guard let data = UserDefaults.standard.data(forKey: localStoreKey),
              let records = try? JSONDecoder().decode([LampRecord].self, from: data) else { return }
        localRecords = Dictionary(uniqueKeysWithValues: records.map { record in
            var restored = record
            // RF5.4.2 migration: RF5.4.1 persisted local records used `id` as
            // the physical ESP/BLE identity even when cloudLampId was linked.
            restored.normalizePersistedLocalIdentity()
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
            return (restored.physicalLocalIDNormalized ?? restored.id.uppercased(), restored)
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
                lamp.physicalLocalIDNormalized == nearbyID ||
                (nearbyID.hasPrefix("SH-") && nearbyID.count == 9 &&
                    lamp.physicalLocalIDNormalized?.hasSuffix(String(nearbyID.dropFirst(3))) == true)
        }
    }

    private func refreshCloudSession() async throws -> CloudSession {
        if let existing = cloudSessionRefreshTask {
            return try await existing.value
        }
        guard session != nil else { throw AppError.unauthorized }

        let task = Task { @MainActor [weak self] () throws -> CloudSession in
            guard let self, let current = self.session else { throw AppError.unauthorized }
            let refreshed = try await self.api.refresh(refreshToken: current.refreshToken)
            try self.keychain.save(refreshed)
            self.session = refreshed

            // Access tokens are deliberately short-lived. A REST refresh must
            // also rotate the account WebSocket immediately; otherwise the
            // realtime client can keep reconnecting forever with the old JWT.
            self.realtime.start(
                token: refreshed.accessToken,
                homeID: self.dashboard.homes.first?.id ?? "default",
                force: true
            )
            return refreshed
        }
        cloudSessionRefreshTask = task
        do {
            let refreshed = try await task.value
            cloudSessionRefreshTask = nil
            return refreshed
        } catch {
            cloudSessionRefreshTask = nil
            throw error
        }
    }

    private func withAccessToken<T>(_ operation: (String) async throws -> T) async throws -> T {
        guard let current = session else { throw AppError.unauthorized }
        do { return try await operation(current.accessToken) }
        catch AppError.unauthorized {
            let refreshed = try await refreshCloudSession()
            return try await operation(refreshed.accessToken)
        }
    }

    private func canUseBLE(_ lamp: LampRecord) -> Bool {
        guard ble.isBluetoothPoweredOn, ble.isReady else { return false }
        let connectedPhysical = connectedLocalID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let expectedPhysical = lamp.physicalLocalIDNormalized, expectedPhysical == connectedPhysical { return true }
        return lamp.bleIdentifier != nil && lamp.bleIdentifier == ble.connectedPeripheralID && lamp.physicalLocalIDNormalized != nil
    }

    private func stateKeys(for lamp: LampRecord) -> [String] {
        var keys = [lamp.id.uppercased(), lamp.canonicalID.uppercased()]
        if let physicalID = lamp.physicalLocalIDNormalized { keys.append(physicalID) }
        if let cloudID = lamp.cloudIDNormalized { keys.append(cloudID) }
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
        local.startRealtime(host: snapshot.host, expectedLampID: snapshot.lampId)
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
        record.physicalLocalID = localID
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
            let localKey = (localRecord.physicalLocalIDNormalized ?? localRecord.id.uppercased())
            localRecord.id = localKey
            localRecord.physicalLocalID = localKey
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
            cloud.physicalLocalID = nil
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
        merged.physicalLocalID = local.physicalLocalIDNormalized ?? local.id.uppercased()
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
        let localKeys = [local.physicalLocalIDNormalized, local.id.uppercased(), local.cloudIDNormalized].compactMap { $0 }
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
            let healthLamp = local ?? lamp
            if hasBLE && !isRouteCircuitOpen(.bluetooth, lamp: healthLamp) { return .bluetooth }
            if hasWiFi && !isRouteCircuitOpen(.wifi, lamp: healthLamp) { return .wifi }
            if hasCloud && !isRouteCircuitOpen(.cloud, lamp: lamp) { return .cloud }
            // Never manufacture an Offline gap merely because a route is in a
            // short circuit-breaker cooldown. Keep the best connected fallback
            // visible while its health probe recovers.
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
        lamp.physicalLocalID = nil
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
        record.physicalLocalID = localKey
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
        record.physicalLocalID = localKey
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

    func realtimeClientNeedsAccessTokenRefresh(_ client: CloudRealtimeClient) {
        guard session != nil else { return }
        cloudConnected = false
        cloudStatus = "Refreshing cloud session…"
        rebuildLamps()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.refreshCloudSession()
            } catch {
                self.signOut(message: "Your sign-in expired. Please sign in again.")
            }
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
                    // A transient semantic delivery rejection such as
                    // COMMAND_EXPIRED is handled by performOrderedRouted() with
                    // a fresh-ID/same-sequence retry. Do not flash the old error
                    // into the UI while that newest intent is actively
                    // recovering. A non-retryable rejection is still surfaced
                    // immediately, and exhausted retries are surfaced by the
                    // caller's normal error path.
                    if !shouldRetryOrderedDelivery(message: message) {
                        errorMessage = message
                    }
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
