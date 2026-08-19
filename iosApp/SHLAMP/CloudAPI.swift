import Foundation

struct HTTPResult {
    let status: Int
    let data: Data
    let path: String
}

final class CloudAPI {
    private let baseURL: URL
    private let session: URLSession
    private let controlSession: URLSession

    init(baseURL: URL = AppEnvironment.cloudBaseURL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)

        // Commands must never inherit a 20-30 second ordinary API wait. This
        // session is used only by the same-ID semantic-ACK control hedge.
        let controlConfiguration = URLSessionConfiguration.ephemeral
        controlConfiguration.timeoutIntervalForRequest = 1.15
        controlConfiguration.timeoutIntervalForResource = 1.5
        controlConfiguration.waitsForConnectivity = false
        self.controlSession = URLSession(configuration: controlConfiguration)
    }

    func signIn(email: String, password: String) async throws -> (CloudUser, CloudSession) {
        let result = try await request(
            method: "POST",
            path: "/api/auth/login",
            body: ["email": email, "password": password]
        )
        return try parseAuth(result.data)
    }

    func register(name: String, email: String, password: String) async throws -> (CloudUser, CloudSession) {
        let body: JSONObject = [
            "displayName": name,
            "name": name,
            "fullName": name,
            "email": email,
            "password": password
        ]
        return try parseAuth(try await request(method: "POST", path: "/api/auth/register", body: body).data)
    }

    func requestPasswordReset(email: String) async throws -> PasswordResetResult {
        let result = try await request(
            method: "POST",
            path: "/api/auth/password-reset/request",
            body: ["email": email]
        )
        let root = try parseJSONObject(result.data)
        return PasswordResetResult(
            message: firstNonBlank(root.string("message"), "If an account exists for this email, a reset code has been sent."),
            debugResetToken: root.string("debugResetToken").isEmpty ? nil : root.string("debugResetToken")
        )
    }

    func confirmPasswordReset(token: String, newPassword: String) async throws -> String {
        let result = try await request(
            method: "POST",
            path: "/api/auth/password-reset/confirm",
            body: ["token": token, "newPassword": newPassword]
        )
        let root = try parseJSONObject(result.data)
        return firstNonBlank(root.string("message"), "Password reset completed. Sign in with your new password.")
    }

    func refresh(refreshToken: String) async throws -> CloudSession {
        let result = try await request(
            method: "POST",
            path: "/api/auth/refresh",
            body: ["refreshToken": refreshToken],
            acceptErrors: true
        )
        guard (200...299).contains(result.status) else { throw AppError.unauthorized }
        return try parseSession(try parseJSONObject(result.data))
    }

    func readMe(accessToken: String) async throws -> CloudUser {
        let result = try await request(
            method: "GET",
            path: "/api/me",
            token: accessToken,
            acceptErrors: true
        )
        if result.status == 401 || result.status == 403 { throw AppError.unauthorized }
        guard (200...299).contains(result.status) else { throw try error(from: result) }
        let root = try parseJSONObject(result.data)
        let user = root.object("user") ?? root.object("data")?.object("user") ?? root
        return parseUser(user)
    }

    func loadDashboard(accessToken: String) async throws -> Dashboard {
        var homes: [CloudHome] = []
        var lamps: [LampRecord] = []
        var errors: [String] = []

        func fetchFirst(_ paths: [String]) async throws -> Dashboard? {
            for path in paths {
                let result = try await request(method: "GET", path: path, token: accessToken, acceptErrors: true)
                if result.status == 401 || result.status == 403 { throw AppError.unauthorized }
                if (200...299).contains(result.status) { return try parseDashboard(result.data) }
                if result.status != 404 { errors.append("\(path): \((try? error(from: result).localizedDescription) ?? "Request failed")") }
            }
            return nil
        }

        if let first = try await fetchFirst(["/api/homes", "/api/me/homes", "/api/home"]) {
            homes = mergeHomes(homes, first.homes)
            lamps = mergeLamps(lamps, first.lamps)
        }
        if let second = try await fetchFirst(["/api/devices", "/api/lamps", "/api/me/devices", "/api/me/lamps"]) {
            homes = mergeHomes(homes, second.homes)
            lamps = mergeLamps(lamps, second.lamps)
        }

        if homes.isEmpty, let homeID = lamps.first(where: { !$0.homeId.isEmpty })?.homeId {
            homes = [CloudHome(id: homeID, name: "My Home", rooms: [])]
        }
        if homes.isEmpty && lamps.isEmpty && !errors.isEmpty {
            throw AppError.message(errors[0])
        }
        if homes.isEmpty { homes = [CloudHome(id: "default", name: "My Home", rooms: [])] }
        return Dashboard(homes: homes, lamps: lamps)
    }

    func readDevice(accessToken: String, lampId: String) async throws -> LampRecord {
        let id = lampId.uppercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? lampId
        let result = try await request(method: "GET", path: "/api/devices/\(id)/state", token: accessToken, acceptErrors: true)
        if result.status == 401 || result.status == 403 { throw AppError.unauthorized }
        guard (200...299).contains(result.status) else { throw try error(from: result) }
        let root = try parseJSONObject(result.data)
        let device = root.object("device") ?? root.object("data")?.object("device") ?? root
        guard let lamp = parseLamp(device) else { throw AppError.message("The cloud did not return a valid lamp state.") }
        return lamp
    }

    func createRoom(accessToken: String, homeId: String, name: String) async throws -> CloudRoom {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !clean.isEmpty else { throw AppError.message("Room name is required.") }
        let encoded = homeId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? homeId
        let result = try await request(method: "POST", path: "/api/homes/\(encoded)/rooms", body: ["name": clean], token: accessToken, acceptErrors: true)
        if result.status == 401 || result.status == 403 { throw AppError.unauthorized }
        guard (200...299).contains(result.status) else { throw try error(from: result) }
        let root = try parseJSONObject(result.data)
        let room = root.object("room") ?? root.object("data")?.object("room") ?? root
        return CloudRoom(
            id: firstNonBlank(room.string("id"), room.string("roomId"), room.string("uuid")),
            homeId: firstNonBlank(room.string("homeId"), homeId),
            name: firstNonBlank(room.string("name"), clean)
        )
    }

    func claimDevice(
        accessToken: String,
        lampId: String,
        claimCode: String,
        homeId: String,
        roomId: String?,
        displayName: String
    ) async throws -> LampRecord {
        var body: JSONObject = [
            "lampId": lampId.uppercased(),
            "claimCode": claimCode.trimmingCharacters(in: .whitespacesAndNewlines),
            "homeId": homeId,
            "displayName": String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        ]
        body["roomId"] = roomId?.isEmpty == false ? roomId! : NSNull()
        let result = try await request(method: "POST", path: "/api/devices/claim", body: body, token: accessToken, acceptErrors: true)
        if result.status == 401 || result.status == 403 { throw AppError.unauthorized }
        guard (200...299).contains(result.status) else { throw try error(from: result) }
        let root = try parseJSONObject(result.data)
        guard let device = root.object("device") ?? root.object("data")?.object("device"),
              let lamp = parseLamp(device, fallbackHomeId: homeId) else {
            throw AppError.message("The server did not return the claimed lamp.")
        }
        return lamp
    }

    func updateDevice(accessToken: String, lampId: String, displayName: String?, roomId: String?, updateRoom: Bool) async throws -> LampRecord {
        var body: JSONObject = [:]
        if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["displayName"] = String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        }
        if updateRoom { body["roomId"] = roomId?.isEmpty == false ? roomId! : NSNull() }
        guard !body.isEmpty else { throw AppError.message("No lamp changes were provided.") }
        let id = lampId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? lampId
        let result = try await request(method: "PATCH", path: "/api/devices/\(id)", body: body, token: accessToken, acceptErrors: true)
        if result.status == 401 || result.status == 403 { throw AppError.unauthorized }
        guard (200...299).contains(result.status) else { throw try error(from: result) }
        let root = try parseJSONObject(result.data)
        guard let device = root.object("device") ?? root.object("data")?.object("device"),
              let lamp = parseLamp(device) else { throw AppError.message("The updated lamp response was incomplete.") }
        return lamp
    }

    func releaseDevice(accessToken: String, lampId: String) async throws -> ReleasedLamp {
        let id = lampId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? lampId
        let result = try await request(method: "DELETE", path: "/api/devices/\(id)", token: accessToken, acceptErrors: true)
        if result.status == 401 || result.status == 403 { throw AppError.unauthorized }
        guard (200...299).contains(result.status) else { throw try error(from: result) }
        let root = try parseJSONObject(result.data)
        let data = root.object("data") ?? [:]
        let credentials = root.object("credentials") ?? data.object("credentials") ?? [:]
        let code = firstNonBlank(root.string("newClaimCode"), data.string("newClaimCode"), credentials.string("claimCode")).uppercased()
        guard code.range(of: "^[A-Z0-9]{6,32}$", options: .regularExpression) != nil else {
            throw AppError.message("The lamp was released, but the server did not return a valid new claim code.")
        }
        return ReleasedLamp(lampId: firstNonBlank(root.string("lampId"), data.string("lampId"), lampId), newClaimCode: code)
    }

    func sendCommand(accessToken: String, lampId: String, action: String, payload: JSONObject = [:]) async throws -> String {
        let commandID = UUID().uuidString
        var body: JSONObject = [
            "commandId": commandID,
            "idempotencyKey": commandID,
            "action": action,
            "type": action,
            "payload": payload,
            "value": payload["value"] ?? NSNull()
        ]
        payload.forEach { if body[$0.key] == nil { body[$0.key] = $0.value } }
        let id = lampId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? lampId
        let paths = [
            "/api/devices/\(id)/commands", "/api/lamps/\(id)/commands",
            "/api/devices/\(id)/command", "/api/lamps/\(id)/command"
        ]
        var lastError = "Cloud command endpoint was not found."
        for path in paths {
            let result = try await request(method: "POST", path: path, body: body, token: accessToken, acceptErrors: true, controlPath: true)
            if result.status == 401 || result.status == 403 { throw AppError.unauthorized }
            if (200...299).contains(result.status) {
                guard !result.data.isEmpty, let root = try? parseJSONObject(result.data) else { return "Command queued." }
                let command = root.object("command") ?? root.object("data")?.object("command") ?? root
                return firstNonBlank(root.string("message"), command.string("message"), "Command \(firstNonBlank(command.string("status"), "queued")).")
            }
            if result.status != 404 { lastError = (try? error(from: result).localizedDescription) ?? "Cloud command failed." }
        }
        throw AppError.message(lastError)
    }

    /// RF5 REST fallback with semantic ACK verification. HTTP 202 only means
    /// Render accepted/queued the command; this method polls the command status
    /// endpoint until the ESP ACKs, rejects, or the bounded control TTL expires.
    func sendCommandAndWaitForAck(
        accessToken: String,
        lampId: String,
        action: String,
        value: JSONObject,
        commandID: String,
        timeout: TimeInterval
    ) async throws -> JSONObject {
        let id = lampId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? lampId
        let encodedCommandID = commandID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? commandID
        let body: JSONObject = [
            "commandId": commandID,
            "action": action,
            "value": value
        ]
        let submit = try await request(
            method: "POST",
            path: "/api/devices/\(id)/commands",
            body: body,
            token: accessToken,
            acceptErrors: true,
            controlPath: true
        )
        if submit.status == 401 || submit.status == 403 { throw AppError.unauthorized }
        guard (200...299).contains(submit.status) else { throw try error(from: submit) }

        let deadline = Date().addingTimeInterval(timeout)
        var delay: Duration = .milliseconds(90)
        while Date() < deadline {
            if !Task.isCancelled { try? await Task.sleep(for: delay) }
            let result = try await request(
                method: "GET",
                path: "/api/devices/\(id)/commands/\(encodedCommandID)",
                token: accessToken,
                acceptErrors: true,
                controlPath: true
            )
            if result.status == 401 || result.status == 403 { throw AppError.unauthorized }
            if result.status == 404 {
                delay = .milliseconds(140)
                continue
            }
            guard (200...299).contains(result.status) else { throw try error(from: result) }
            let root = try parseJSONObject(result.data)
            let status = root.string("status").uppercased()
            if status == "ACKNOWLEDGED" {
                var ack = root
                ack["type"] = "ack"
                ack["success"] = true
                return ack
            }
            if status == "FAILED" || status == "EXPIRED" {
                var ack = root
                ack["type"] = "ack"
                ack["success"] = false
                if ack.string("error").isEmpty { ack["error"] = firstNonBlank(root.string("errorMessage"), "The cloud command did not complete.") }
                return ack
            }
            delay = .milliseconds(140)
        }
        throw AppError.message("The lamp did not acknowledge the REST cloud command in time.")
    }

    private func request(method: String, path: String, body: JSONObject? = nil, token: String? = nil, acceptErrors: Bool = false, controlPath: Bool = false) async throws -> HTTPResult {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw AppError.message("Invalid cloud URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = controlPath ? 1.15 : 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("SHLAMP-iOS/2.0.0-RF6.0", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try jsonData(body) }
        let activeSession = controlPath ? controlSession : session
        let (data, response) = try await activeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.message("Cloud server did not return HTTP.") }
        let result = HTTPResult(status: http.statusCode, data: data, path: path)
        if !acceptErrors && !(200...299).contains(http.statusCode) { throw try error(from: result) }
        return result
    }

    private func error(from result: HTTPResult) throws -> AppError {
        if result.status == 401 || result.status == 403 { return .unauthorized }
        let message: String
        if let root = try? parseJSONObject(result.data) {
            message = firstNonBlank(root.string("message"), root.string("error"), root.object("error")?.string("message") ?? "")
        } else {
            message = String(data: result.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return .message(message.isEmpty ? "Cloud request failed with HTTP \(result.status)." : message)
    }

    private func parseAuth(_ data: Data) throws -> (CloudUser, CloudSession) {
        let root = try parseJSONObject(data)
        guard let userObject = root.object("user") ?? root.object("data")?.object("user") else {
            throw AppError.message("The cloud response did not contain a user.")
        }
        return (parseUser(userObject), try parseSession(root))
    }

    private func parseUser(_ json: JSONObject) -> CloudUser {
        CloudUser(
            id: firstNonBlank(json.string("id"), json.string("userId"), json.string("uuid")),
            name: firstNonBlank(json.string("displayName"), json.string("name"), json.string("fullName")),
            email: json.string("email")
        )
    }

    private func parseSession(_ root: JSONObject) throws -> CloudSession {
        let session = root.object("session") ?? root.object("data")?.object("session") ?? root
        let access = firstNonBlank(session.string("accessToken"), session.string("access_token"), root.string("accessToken"), root.string("token"))
        let refresh = firstNonBlank(session.string("refreshToken"), session.string("refresh_token"), root.string("refreshToken"))
        guard !access.isEmpty, !refresh.isEmpty else { throw AppError.message("The cloud response did not contain both session tokens.") }
        return CloudSession(accessToken: access, refreshToken: refresh)
    }

    private func parseDashboard(_ data: Data, fallbackHomeId: String = "") throws -> Dashboard {
        guard !data.isEmpty else { return .empty }
        let root = try parseJSONObject(data)
        let containers = [root, root.object("data") ?? [:], root.object("result") ?? [:]]
        var homes: [CloudHome] = []
        var lamps: [LampRecord] = []

        for container in containers {
            for key in ["homes", "items"] {
                for item in container.array(key) ?? [] {
                    if let object = item as? JSONObject, let home = parseHome(object) { homes.append(home) }
                }
            }
            for key in ["lamps", "devices", "items"] {
                for item in container.array(key) ?? [] {
                    if let object = item as? JSONObject, let lamp = parseLamp(object, fallbackHomeId: fallbackHomeId) { lamps.append(lamp) }
                }
            }
        }
        if let home = root.object("home"), let parsed = parseHome(home) { homes.append(parsed) }
        if let lamp = root.object("lamp") ?? root.object("device"), let parsed = parseLamp(lamp, fallbackHomeId: fallbackHomeId) { lamps.append(parsed) }
        return Dashboard(homes: mergeHomes([], homes), lamps: mergeLamps([], lamps))
    }

    private func parseHome(_ json: JSONObject) -> CloudHome? {
        let id = firstNonBlank(json.string("id"), json.string("homeId"), json.string("uuid"))
        guard !id.isEmpty else { return nil }
        let rooms = (json.array("rooms") ?? []).compactMap { item -> CloudRoom? in
            guard let room = item as? JSONObject else { return nil }
            let roomID = firstNonBlank(room.string("id"), room.string("roomId"), room.string("uuid"))
            guard !roomID.isEmpty else { return nil }
            return CloudRoom(id: roomID, homeId: firstNonBlank(room.string("homeId"), id), name: firstNonBlank(room.string("name"), "Room"))
        }
        return CloudHome(id: id, name: firstNonBlank(json.string("name"), "My Home"), rooms: rooms)
    }

    func parseLamp(_ json: JSONObject, fallbackHomeId: String = "") -> LampRecord? {
        let id = firstNonBlank(json.string("lampId"), json.string("deviceId"), json.string("serial"), json.string("id")).uppercased()
        guard !id.isEmpty else { return nil }
        let stateJSON = json.object("state") ?? json.object("lastState") ?? [:]
        // Prisma exposes persisted device telemetry as `rawJson`; live protocol
        // events expose it as `raw`. Accept both so dashboard REST and WebSocket
        // state are parsed identically.
        let rawJSON = stateJSON.object("raw") ?? stateJSON.object("rawJson") ?? json.object("raw") ?? json.object("rawJson") ?? [:]
        let brightness = clamp(stateJSON.int("brightness", "currentBrightness", "targetBrightness") ?? json.int("brightness") ?? 0, 0...100)
        let power = stateJSON.bool("power", "on") ?? json.bool("power") ?? (brightness > 0)
        let batteryPercent = [stateJSON.int("batteryPercent", "battery", "batteryLevel"), rawJSON.int("batteryPercent", "battery"), json.int("batteryPercent", "battery", "batteryLevel")].compactMap { $0 }.first.map { clamp($0, 0...100) }
        let batteryVoltage = [stateJSON.int("batteryVoltageMv", "batteryMv"), rawJSON.int("batteryVoltageMv", "batteryMv"), json.int("batteryVoltageMv", "batteryMv")].compactMap { $0 }.first.flatMap { (2000...5000).contains($0) ? $0 : nil }
        let batteryValid = stateJSON.bool("batteryValid") ?? rawJSON.bool("batteryValid") ?? json.bool("batteryValid") ?? (batteryPercent != nil || batteryVoltage != nil)
        let roomObject = json.object("room") ?? [:]
        let powerModeRaw = firstNonBlank(
            stateJSON.string("powerMode", "batteryMode"),
            rawJSON.string("powerMode", "batteryMode"),
            json.string("powerMode", "batteryMode")
        ).uppercased()
        let runtimeStateRaw = firstNonBlank(
            stateJSON.string("runtimeState", "powerRuntimeState"),
            rawJSON.string("runtimeState", "powerRuntimeState"),
            json.string("runtimeState", "powerRuntimeState")
        ).uppercased()
        let reportedTimer = Int64(max(0, stateJSON.int("timerRemainingSeconds", "timerRemaining") ?? json.int("timerRemainingSeconds") ?? 0))
        let stateTimestamp = firstNonBlank(
            stateJSON.string("updatedAt", "stateUpdatedAt", "receivedAt"),
            json.string("stateUpdatedAt", "updatedAt", "lastSeen", "lastSeenAt")
        )
        let adjustedTimer = adjustedTimerRemaining(reportedTimer, stateTimestamp: stateTimestamp)
        let stateBootId = [stateJSON.int("bootId", "stateBootId"), rawJSON.int("bootId", "stateBootId"), json.int("bootId", "stateBootId")].compactMap { $0 }.first.map { Int64($0) }
        let stateBootSequence = [stateJSON.int("bootSequence", "stateBootSequence"), rawJSON.int("bootSequence", "stateBootSequence"), json.int("bootSequence", "stateBootSequence")].compactMap { $0 }.first.map { Int64($0) }
        let stateRevision = [stateJSON.int("stateRevision", "revision"), rawJSON.int("stateRevision", "revision"), json.int("stateRevision", "revision")].compactMap { $0 }.first.map { Int64($0) }
        let rememberedBrightness = clamp(
            stateJSON.int("rememberedBrightness", "lastBrightness")
                ?? rawJSON.int("rememberedBrightness", "lastBrightness")
                ?? json.int("rememberedBrightness", "lastBrightness")
                ?? max(brightness, 20),
            1...100
        )
        let state = LampState(
            power: power,
            brightness: brightness,
            rememberedBrightness: rememberedBrightness,
            fadeMode: clamp(stateJSON.int("fadeMode", "fade") ?? json.int("fadeMode") ?? 2, 0...3),
            timerRemainingSeconds: adjustedTimer,
            batteryValid: batteryValid,
            batteryPercent: batteryValid ? batteryPercent : nil,
            batteryVoltageMv: batteryValid ? batteryVoltage : nil,
            batteryCharging: batteryValid ? (stateJSON.bool("batteryCharging", "isCharging", "charging") ?? rawJSON.bool("batteryCharging", "isCharging", "charging") ?? json.bool("batteryCharging", "isCharging", "charging")) : nil,
            powerMode: LampPowerMode(rawValue: powerModeRaw) ?? .balanced,
            runtimeState: LampRuntimeState(rawValue: runtimeStateRaw) ?? .unknown,
            stateBootId: stateBootId,
            stateBootSequence: stateBootSequence,
            stateRevision: stateRevision
        )
        let online = json.bool("online", "isOnline") ?? (json.string("status").lowercased() == "online")
        return LampRecord(
            id: id,
            cloudLampId: id.hasPrefix("SH-") ? id : nil,
            cloudClaimed: true,
            homeId: firstNonBlank(json.string("homeId"), json.object("home")?.string("id", "homeId") ?? "", fallbackHomeId),
            roomId: firstNonBlank(json.string("roomId"), roomObject.string("id", "roomId")).nilIfEmpty,
            roomName: firstNonBlank(roomObject.string("name"), json.string("roomName")).nilIfEmpty,
            name: firstNonBlank(json.string("name"), json.string("displayName"), json.string("label"), "SH Lamp"),
            model: firstNonBlank(json.string("model"), json.string("productModel"), json.string("firmwareVersion")),
            firmware: json.string("firmwareVersion").nilIfEmpty,
            online: online,
            lastSeen: firstNonBlank(json.string("lastSeen"), json.string("lastSeenAt"), json.string("updatedAt")).nilIfEmpty,
            route: online ? .cloud : .offline,
            bleIdentifier: nil,
            bleName: nil,
            localHost: nil,
            wifiSSID: nil,
            wifiRSSI: -127,
            bleRSSI: -127,
            controllerCount: 0,
            state: state
        )
    }

    /// A cloud snapshot can be several seconds or minutes old. The ESP reports
    /// remaining timer seconds at the moment of the snapshot, so subtract the
    /// age of that snapshot before presenting it to the live UI.
    private func adjustedTimerRemaining(_ reported: Int64, stateTimestamp: String) -> Int64 {
        guard reported > 0, !stateTimestamp.isEmpty else { return reported }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: stateTimestamp) ?? ISO8601DateFormatter().date(from: stateTimestamp)
        guard let date else { return reported }
        let elapsed = max(0, Int64(Date().timeIntervalSince(date)))
        return max(0, reported - elapsed)
    }

    private func mergeHomes(_ existing: [CloudHome], _ incoming: [CloudHome]) -> [CloudHome] {
        var map = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for home in incoming where !home.id.isEmpty {
            if let old = map[home.id] {
                let rooms = Dictionary(uniqueKeysWithValues: (old.rooms + home.rooms).map { ($0.id, $0) }).values.sorted { $0.name < $1.name }
                map[home.id] = CloudHome(id: home.id, name: home.name.isEmpty ? old.name : home.name, rooms: rooms)
            } else { map[home.id] = home }
        }
        return map.values.sorted { $0.name < $1.name }
    }

    private func mergeLamps(_ existing: [LampRecord], _ incoming: [LampRecord]) -> [LampRecord] {
        var map = Dictionary(uniqueKeysWithValues: existing.map { ($0.id.uppercased(), $0) })
        for lamp in incoming { map[lamp.id.uppercased()] = lamp }
        return map.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
