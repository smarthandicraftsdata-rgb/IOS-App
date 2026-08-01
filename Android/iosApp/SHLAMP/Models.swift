import Foundation

enum LampConnectionRoute: String, Codable, CaseIterable {
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
    var fadeMode = 2
    var timerRemainingSeconds: Int64 = 0
    var batteryValid = false
    var batteryPercent: Int?
    var batteryVoltageMv: Int?
    var batteryCharging: Bool?
}

struct LampRecord: Identifiable, Codable, Equatable {
    var id: String
    var cloudLampId: String?
    var homeId: String
    var roomId: String?
    var roomName: String?
    var name: String
    var model: String
    var firmware: String?
    var online: Bool
    var lastSeen: String?
    var route: LampConnectionRoute
    var bleIdentifier: UUID?
    var bleName: String?
    var localHost: String?
    var wifiSSID: String?
    var wifiRSSI: Int
    var bleRSSI: Int
    var controllerCount: Int
    var state: LampState

    var canonicalID: String {
        (cloudLampId?.isEmpty == false ? cloudLampId! : id).uppercased()
    }

    var reachable: Bool { route != .offline || online }

    static func placeholder(id: String, name: String = "SH Lamp") -> LampRecord {
        LampRecord(
            id: id.uppercased(), cloudLampId: nil, homeId: "default", roomId: nil,
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
    let host: String
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
