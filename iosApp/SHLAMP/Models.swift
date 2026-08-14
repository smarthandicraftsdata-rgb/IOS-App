import Foundation

enum LampConnectionRoute: String, Codable, CaseIterable, Sendable {
    case offline
    case bluetooth
    case wifi
    case cloud

    var label: String {
        switch self {
        case .offline: return "Offline"
        case .bluetooth: return "Bluetooth"
        case .wifi: return "Local Wi-Fi"
        case .cloud: return "Cloud"
        }
    }
}

enum LampRoutePreference: String, Codable, CaseIterable, Identifiable {
    case automatic
    case wifi
    case bluetooth
    case remote

    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .wifi: return "Local Wi-Fi"
        case .bluetooth: return "Bluetooth"
        case .remote: return "Remote"
        }
    }
}

enum LampPowerMode: String, Codable, CaseIterable, Identifiable {
    case balanced = "BALANCED"
    case maximumBackup = "MAX_BACKUP"
    case bleOnly = "BLE_ONLY"
    case touchOnly = "TOUCH_ONLY"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .balanced: return "Balanced"
        case .maximumBackup: return "Maximum Backup"
        case .bleOnly: return "BLE Only"
        case .touchOnly: return "Touch Only"
        }
    }
    var firmwareValue: String { rawValue.lowercased() }
    var binaryValue: UInt8 {
        switch self {
        case .balanced: return 0
        case .maximumBackup: return 1
        case .bleOnly: return 2
        case .touchOnly: return 3
        }
    }
}

enum LampRuntimeState: String, Codable, CaseIterable {
    case active = "ACTIVE"
    case lampOnIdle = "LAMP_ON_IDLE"
    case offRecent = "OFF_RECENT"
    case offLong = "OFF_LONG"
    case touchOnly = "TOUCH_ONLY"
    case unknown = "UNKNOWN"

    var label: String {
        switch self {
        case .active: return "Active"
        case .lampOnIdle: return "Lamp on idle"
        case .offRecent: return "Off recently"
        case .offLong: return "Long idle"
        case .touchOnly: return "Touch only"
        case .unknown: return "Status unavailable"
        }
    }
}

struct CloudUser: Codable, Equatable {
    let id: String
    let name: String
    let email: String
}

struct CloudSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
}

struct CloudRoom: Identifiable, Codable, Equatable {
    let id: String
    let homeId: String
    let name: String
}

struct CloudHome: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    var rooms: [CloudRoom]
}

struct LampState: Codable, Equatable {
    var power = false
    var brightness = 0
    var rememberedBrightness = 20
    var fadeMode = 2
    var timerRemainingSeconds: Int64 = 0
    var batteryValid = false
    var batteryPercent: Int?
    var batteryVoltageMv: Int?
    var batteryCharging: Bool?
    var powerMode: LampPowerMode = .balanced
    var runtimeState: LampRuntimeState = .unknown
    // R21A optional authoritative ordering metadata. Older firmware/cloud
    // responses omit these fields and continue to use receipt-time freshness.
    var stateBootId: Int64? = nil
    var stateBootSequence: Int64? = nil
    var stateRevision: Int64? = nil

    private enum CodingKeys: String, CodingKey {
        case power, brightness, rememberedBrightness, fadeMode, timerRemainingSeconds
        case batteryValid, batteryPercent, batteryVoltageMv, batteryCharging
        case powerMode, runtimeState, stateBootId, stateBootSequence, stateRevision
    }

    init(
        power: Bool = false,
        brightness: Int = 0,
        rememberedBrightness: Int = 20,
        fadeMode: Int = 2,
        timerRemainingSeconds: Int64 = 0,
        batteryValid: Bool = false,
        batteryPercent: Int? = nil,
        batteryVoltageMv: Int? = nil,
        batteryCharging: Bool? = nil,
        powerMode: LampPowerMode = .balanced,
        runtimeState: LampRuntimeState = .unknown,
        stateBootId: Int64? = nil,
        stateBootSequence: Int64? = nil,
        stateRevision: Int64? = nil
    ) {
        self.power = power
        self.brightness = brightness
        self.rememberedBrightness = max(1, min(100, rememberedBrightness))
        self.fadeMode = fadeMode
        self.timerRemainingSeconds = timerRemainingSeconds
        self.batteryValid = batteryValid
        self.batteryPercent = batteryPercent
        self.batteryVoltageMv = batteryVoltageMv
        self.batteryCharging = batteryCharging
        self.powerMode = powerMode
        self.runtimeState = runtimeState
        self.stateBootId = stateBootId
        self.stateBootSequence = stateBootSequence
        self.stateRevision = stateRevision
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        power = try values.decodeIfPresent(Bool.self, forKey: .power) ?? false
        brightness = try values.decodeIfPresent(Int.self, forKey: .brightness) ?? 0
        rememberedBrightness = max(1, min(100, try values.decodeIfPresent(Int.self, forKey: .rememberedBrightness) ?? max(brightness, 20)))
        fadeMode = try values.decodeIfPresent(Int.self, forKey: .fadeMode) ?? 2
        timerRemainingSeconds = try values.decodeIfPresent(Int64.self, forKey: .timerRemainingSeconds) ?? 0
        batteryValid = try values.decodeIfPresent(Bool.self, forKey: .batteryValid) ?? false
        batteryPercent = try values.decodeIfPresent(Int.self, forKey: .batteryPercent)
        batteryVoltageMv = try values.decodeIfPresent(Int.self, forKey: .batteryVoltageMv)
        batteryCharging = try values.decodeIfPresent(Bool.self, forKey: .batteryCharging)
        powerMode = try values.decodeIfPresent(LampPowerMode.self, forKey: .powerMode) ?? .balanced
        runtimeState = try values.decodeIfPresent(LampRuntimeState.self, forKey: .runtimeState) ?? .unknown
        stateBootId = try values.decodeIfPresent(Int64.self, forKey: .stateBootId)
        stateBootSequence = try values.decodeIfPresent(Int64.self, forKey: .stateBootSequence)
        stateRevision = try values.decodeIfPresent(Int64.self, forKey: .stateRevision)
    }
}

struct LampRecord: Identifiable, Codable, Equatable {
    /// RF5.4.2: physical identity exposed by ESP /api/status.lampId and BLE.
    /// This must never be replaced by the Render/account ID when records merge.
    var physicalLocalID: String?
    var id: String
    var cloudLampId: String?
    var cloudClaimed = false
    var homeId: String
    var roomId: String?
    var roomName: String?
    var name: String
    var model: String
    var firmware: String?
    var online: Bool
    var lastSeen: String?
    var route: LampConnectionRoute
    var routePreference: LampRoutePreference = .automatic
    var bleIdentifier: UUID?
    var bleName: String?
    var localHost: String?
    var wifiSSID: String?
    var wifiRSSI: Int
    var bleRSSI: Int
    var controllerCount: Int
    var state: LampState

    private enum CodingKeys: String, CodingKey {
        case physicalLocalID, id, cloudLampId, cloudClaimed, homeId, roomId, roomName, name, model
        case firmware, online, lastSeen, route, routePreference, bleIdentifier, bleName
        case localHost, wifiSSID, wifiRSSI, bleRSSI, controllerCount, state
    }

    init(
        id: String,
        physicalLocalID: String? = nil,
        cloudLampId: String? = nil,
        cloudClaimed: Bool = false,
        homeId: String,
        roomId: String? = nil,
        roomName: String? = nil,
        name: String,
        model: String,
        firmware: String? = nil,
        online: Bool,
        lastSeen: String? = nil,
        route: LampConnectionRoute,
        routePreference: LampRoutePreference = .automatic,
        bleIdentifier: UUID? = nil,
        bleName: String? = nil,
        localHost: String? = nil,
        wifiSSID: String? = nil,
        wifiRSSI: Int,
        bleRSSI: Int,
        controllerCount: Int,
        state: LampState
    ) {
        self.physicalLocalID = physicalLocalID
        self.id = id
        self.cloudLampId = cloudLampId
        self.cloudClaimed = cloudClaimed
        self.homeId = homeId
        self.roomId = roomId
        self.roomName = roomName
        self.name = name
        self.model = model
        self.firmware = firmware
        self.online = online
        self.lastSeen = lastSeen
        self.route = route
        self.routePreference = routePreference
        self.bleIdentifier = bleIdentifier
        self.bleName = bleName
        self.localHost = localHost
        self.wifiSSID = wifiSSID
        self.wifiRSSI = wifiRSSI
        self.bleRSSI = bleRSSI
        self.controllerCount = controllerCount
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        physicalLocalID = try values.decodeIfPresent(String.self, forKey: .physicalLocalID)
        id = try values.decode(String.self, forKey: .id)
        cloudLampId = try values.decodeIfPresent(String.self, forKey: .cloudLampId)
        cloudClaimed = try values.decodeIfPresent(Bool.self, forKey: .cloudClaimed) ?? false
        homeId = try values.decodeIfPresent(String.self, forKey: .homeId) ?? "default"
        roomId = try values.decodeIfPresent(String.self, forKey: .roomId)
        roomName = try values.decodeIfPresent(String.self, forKey: .roomName)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "SH Lamp"
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        firmware = try values.decodeIfPresent(String.self, forKey: .firmware)
        online = try values.decodeIfPresent(Bool.self, forKey: .online) ?? false
        lastSeen = try values.decodeIfPresent(String.self, forKey: .lastSeen)
        route = try values.decodeIfPresent(LampConnectionRoute.self, forKey: .route) ?? .offline
        routePreference = try values.decodeIfPresent(LampRoutePreference.self, forKey: .routePreference) ?? .automatic
        bleIdentifier = try values.decodeIfPresent(UUID.self, forKey: .bleIdentifier)
        bleName = try values.decodeIfPresent(String.self, forKey: .bleName)
        localHost = try values.decodeIfPresent(String.self, forKey: .localHost)
        wifiSSID = try values.decodeIfPresent(String.self, forKey: .wifiSSID)
        wifiRSSI = try values.decodeIfPresent(Int.self, forKey: .wifiRSSI) ?? -127
        bleRSSI = try values.decodeIfPresent(Int.self, forKey: .bleRSSI) ?? -127
        controllerCount = try values.decodeIfPresent(Int.self, forKey: .controllerCount) ?? 0
        state = try values.decodeIfPresent(LampState.self, forKey: .state) ?? LampState()
    }

    /// Stable app/UI identity. A linked Cloud ID remains canonical for account views,
    /// while transport-specific code must use physicalLocalIDNormalized/cloudIDNormalized.
    var canonicalID: String {
        (cloudLampId?.isEmpty == false ? cloudLampId! : id).uppercased()
    }

    var physicalLocalIDNormalized: String? {
        if let value = physicalLocalID?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value.uppercased()
        }
        // Backward compatibility for persisted RF5.4.1 local records. A local-only
        // record's `id` was the physical ID. Never apply this fallback to a merged
        // Cloud record because its `id` can be the Render ID.
        if cloudLampId == nil {
            let value = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value.uppercased()
        }
        return nil
    }

    var cloudIDNormalized: String? {
        if let value = cloudLampId?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value.uppercased()
        }
        // Dashboard/cloud-only records are normalized with cloudLampId in
        // AppViewModel.rebuildLamps/applyCloudLamp before routing.
        return nil
    }

    /// RF5.4.2 migration for records loaded from the local-device store.
    /// RF5.4.1 stored the physical ESP ID in `id` even after cloudLampId was linked.
    /// Dashboard/cloud records must never call this helper.
    mutating func normalizePersistedLocalIdentity() {
        let explicit = physicalLocalID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let physical = (explicit?.isEmpty == false ? explicit! : id).uppercased()
        physicalLocalID = physical
        id = physical
    }

    var reachable: Bool { route != .offline || online }

    static func placeholder(id: String, name: String = "SH Lamp") -> LampRecord {
        LampRecord(
            id: id.uppercased(), physicalLocalID: id.uppercased(), cloudLampId: nil, homeId: "default", roomId: nil,
            roomName: nil, name: name, model: "", firmware: nil, online: false,
            lastSeen: nil, route: .offline, bleIdentifier: nil, bleName: nil,
            localHost: nil, wifiSSID: nil, wifiRSSI: -127, bleRSSI: -127,
            controllerCount: 0, state: LampState()
        )
    }
}

struct Dashboard: Equatable {
    var homes: [CloudHome]
    var lamps: [LampRecord]

    static let empty = Dashboard(
        homes: [CloudHome(id: "default", name: "My Home", rooms: [])],
        lamps: []
    )
}

struct NearbyLamp: Identifiable, Equatable {
    let id: UUID
    var lampId: String
    var advertisedName: String
    var rssi: Int
}

struct SavedWiFiNetwork: Identifiable, Equatable {
    var id: String { ssid }
    let ssid: String
    let active: Bool
}

struct LampControllerAccess: Identifiable, Equatable {
    var id: String { controllerId }
    let controllerId: String
    let label: String
    let owner: Bool
}

struct BLELampStatus: Equatable {
    let lampId: String
    let power: Bool
    let targetBrightness: Int
    let currentBrightness: Int
    /// RF5.1 firmware reports the device's actual saved non-zero brightness.
    /// Nil keeps compatibility with older firmware status packets.
    let rememberedBrightness: Int?
    let fadeMode: Int
    let timerRemainingSeconds: Int64
    let rssi: Int
}

struct WiFiLampSnapshot: Equatable {
    let lampId: String
    let cloudLampId: String?
    let lampName: String
    let hostname: String
    let firmware: String
    let power: Bool
    let currentBrightness: Int
    let targetBrightness: Int
    let lastBrightness: Int
    let fadeMode: Int
    let timerRemainingSeconds: Int64
    let ssid: String
    let rssi: Int
    let ip: String
    let activeSSID: String
    let savedNetworkCount: Int
    let controllerCount: Int
    let bleName: String
    let batteryValid: Bool
    let batteryPercent: Int?
    let batteryVoltageMv: Int?
    let batteryCharging: Bool?
    let powerMode: LampPowerMode
    let runtimeState: LampRuntimeState
    let host: String
    var stateBootId: Int64? = nil
    var stateBootSequence: Int64? = nil
    var stateRevision: Int64? = nil
}

struct LampQRPayload: Equatable {
    let lampId: String
    let claimCode: String
    let model: String
}

struct PasswordResetResult {
    let message: String
    let debugResetToken: String?
}

struct ReleasedLamp {
    let lampId: String
    let newClaimCode: String
}

enum AppError: LocalizedError {
    case message(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .unauthorized: return "Your cloud session expired. Please sign in again."
        }
    }
}
