import Foundation
import CoreBluetooth

@MainActor
protocol BLELampManagerDelegate: AnyObject {
    func bleManager(_ manager: BLELampManager, didUpdateNearby lamps: [NearbyLamp])
    func bleManager(_ manager: BLELampManager, didChangeStatus status: String)
    func bleManager(_ manager: BLELampManager, didResolveLocalID localID: String, cloudID: String?)
    func bleManager(_ manager: BLELampManager, didConnect lampID: String, peripheralID: UUID, name: String)
    func bleManager(_ manager: BLELampManager, didDisconnect peripheralID: UUID?)
    func bleManager(_ manager: BLELampManager, didReceive status: BLELampStatus)
    func bleManager(_ manager: BLELampManager, didReceiveRememberedBrightness percent: Int, lampID: String)
    func bleManager(_ manager: BLELampManager, didReceiveBattery percent: Int, lampID: String)
    func bleManager(_ manager: BLELampManager, didReceiveWiFiStatus status: String)
    func bleManager(_ manager: BLELampManager, didReceivePowerMode mode: LampPowerMode)
    func bleManager(_ manager: BLELampManager, didUpdateRSSI rssi: Int, lampID: String)
    func bleManager(_ manager: BLELampManager, bluetoothPoweredOn: Bool)
    func bleManager(_ manager: BLELampManager, didReceiveSavedNetworks networks: [SavedWiFiNetwork])
    func bleManager(_ manager: BLELampManager, didReceiveControllers controllers: [LampControllerAccess])
    func bleManager(_ manager: BLELampManager, didFail message: String)
}

private struct BLEWriteRequest {
    let characteristic: CBCharacteristic
    let data: Data
}

private final class TextAssembly {
    let expectedLength: Int
    var bytes: [UInt8]
    var received: [Bool]
    var flags = 0
    var secondLength = 0

    init(expectedLength: Int) {
        self.expectedLength = expectedLength
        self.bytes = Array(repeating: 0, count: expectedLength)
        self.received = Array(repeating: false, count: expectedLength)
    }

    var complete: Bool { expectedLength == 0 || received.allSatisfy { $0 } }
}

final class BLELampManager: NSObject {
    weak var delegate: BLELampManagerDelegate?

    private let serviceUUID = CBUUID(string: AppEnvironment.BLE.service)
    private let controlUUID = CBUUID(string: AppEnvironment.BLE.control)
    private let wifiUUID = CBUUID(string: AppEnvironment.BLE.wifi)
    private let identityUUID = CBUUID(string: AppEnvironment.BLE.identity)
    private let batteryServiceUUID = CBUUID(string: AppEnvironment.BLE.batteryService)
    private let batteryLevelUUID = CBUUID(string: AppEnvironment.BLE.batteryLevel)

    private lazy var central = CBCentralManager(delegate: self, queue: DispatchQueue(label: "com.smarthandicrafts.shlamp.ble"))
    private var discovered: [UUID: (peripheral: CBPeripheral, lamp: NearbyLamp)] = [:]
    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var wifiCharacteristic: CBCharacteristic?
    private var identityCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var writeQueue: [BLEWriteRequest] = []
    private var writeInProgress = false
    private var connectedLampID = ""
    private var connectedName = ""
    private var lastRememberedBrightness: Int?
    private var lastRSSI = -127
    private var rssiTask: Task<Void, Never>?
    private var initialStateRequested = false
    private var connectionSetupCompleted = false
    private var scanStopWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var lastStatusRequestAt = Date.distantPast
    // RF5 ordered ACKs are touched by app tasks and CoreBluetooth callbacks.
    // Keep continuation ownership serialized so a timeout/disconnect/ACK race
    // can never resume the same CheckedContinuation twice.
    private let orderedAckLock = NSLock()
    private var orderedAckWaiters: [String: (continuation: CheckedContinuation<Void, Error>, timeout: Task<Void, Never>)] = [:]

    private var savedExpectedCount = 0
    private var savedAssemblies: [Int: TextAssembly] = [:]
    private var controllerExpectedCount = 0
    private var controllerAssemblies: [Int: TextAssembly] = [:]

    override init() {
        super.init()
        _ = central
    }

    var connectedPeripheralID: UUID? { peripheral?.identifier }
    var isBluetoothPoweredOn: Bool { central.state == .poweredOn }
    var isReady: Bool { isBluetoothPoweredOn && peripheral != nil && controlCharacteristic != nil }
    var isConnecting: Bool { isBluetoothPoweredOn && peripheral != nil && controlCharacteristic == nil }
    var isScanning: Bool { central.isScanning }

    func startScan() {
        guard central.state == .poweredOn else {
            publishStatus("Turn on Bluetooth to search for lamps.")
            return
        }
        guard !central.isScanning else { return }
        discovered.removeAll()
        publishNearby()
        central.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        publishStatus("Searching for nearby SH Lamps…")
        scanStopWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopScan() }
        scanStopWorkItem = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: work)
    }

    func stopScan() {
        central.stopScan()
        publishStatus(discovered.isEmpty ? "No nearby lamp found." : "Nearby scan complete.")
    }

    func connect(to peripheralID: UUID) {
        if let item = discovered[peripheralID] {
            beginConnection(
                item.peripheral,
                advertisedName: item.lamp.advertisedName,
                lampID: item.lamp.lampId
            )
            return
        }

        // RF5.2.1: CoreBluetooth identifiers are persistent for the app. A
        // reconnect must not depend on catching a fresh advertisement inside
        // one 10-second scan window.
        if let remembered = central.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            let name = remembered.name ?? "SH Lamp"
            beginConnection(
                remembered,
                advertisedName: name,
                lampID: lampID(fromName: name) ?? ""
            )
            return
        }

        publishStatus("Lamp not cached by Bluetooth yet; scanning again…")
        startScan()
    }

    private func beginConnection(_ target: CBPeripheral, advertisedName: String, lampID: String) {
        if let current = peripheral, current.identifier != target.identifier {
            central.cancelPeripheralConnection(current)
        }
        clearConnection(keepPeripheral: false)

        peripheral = target
        connectedName = advertisedName
        connectedLampID = lampID
        target.delegate = self
        central.connect(target, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        publishStatus("Connecting to \(advertisedName)…")

        connectionTimeoutWorkItem?.cancel()
        let targetID = target.identifier
        let timeout = DispatchWorkItem { [weak self, weak target] in
            guard let self,
                  let target,
                  self.peripheral?.identifier == targetID,
                  !self.isReady else { return }
            self.central.cancelPeripheralConnection(target)
            self.clearConnection(keepPeripheral: false)
            self.publishStatus("Bluetooth reconnect timed out; retrying discovery…")
            Task { @MainActor in
                self.delegate?.bleManager(self, didDisconnect: targetID)
            }
        }
        connectionTimeoutWorkItem = timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + 9, execute: timeout)
    }

    func disconnect() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        clearConnection(keepPeripheral: false)
    }

    func power(_ on: Bool) { writeControl([0x05, on ? 0x01 : 0x00]) }
    func brightness(_ percent: Int) { writeControl([0x02, UInt8(clamp(percent, 0...100))], coalesceBrightness: true) }
    func fade(_ mode: Int) { writeControl([0x03, UInt8(clamp(mode, 0...3))]) }
    func timer(_ minutes: Int) { writeControl([0x04, UInt8([0, 15, 30, 60].contains(minutes) ? minutes : 0)]) }

    /// RF5 compact ordered command. The 20-byte frame fits the default ATT
    /// payload and carries the same controller/session/intent identity used by
    /// LAN and cloud. `commandID` is deterministically derived by the app from
    /// those fields, so the BLE frame does not need to carry a long UUID.
    func sendOrdered(intent: OrderedControlIntent, waitForAck: Bool) async throws {
        guard let characteristic = controlCharacteristic else {
            throw AppError.message("The lamp Bluetooth control is not ready.")
        }
        let packet = try orderedPacket(intent)
        let key = orderedAckKey(intent)

        if !waitForAck {
            if intent.kind == .output {
                writeQueue.removeAll { request in
                    request.characteristic.uuid == characteristic.uuid &&
                    request.data.count >= 2 && request.data[0] == 0x60 && request.data[1] == OrderedIntentKind.output.rawValue
                }
            }
            enqueue(characteristic: characteristic, data: packet, coalesceBrightness: false)
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.3))
                guard !Task.isCancelled, let self else { return }
                self.failOrderedAck(key: key, error: AppError.message("The lamp did not acknowledge the Bluetooth command."))
            }

            orderedAckLock.lock()
            let replaced = orderedAckWaiters.updateValue((continuation, timeout), forKey: key)
            orderedAckLock.unlock()
            if let replaced {
                replaced.timeout.cancel()
                replaced.continuation.resume(throwing: AppError.message("A newer Bluetooth attempt replaced the same ordered command."))
            }
            enqueue(characteristic: characteristic, data: packet, coalesceBrightness: false)
        }
    }

    private func orderedPacket(_ intent: OrderedControlIntent) throws -> Data {
        let hex = intent.controllerID.uppercased()
        guard hex.range(of: "^[0-9A-F]{12}$", options: .regularExpression) != nil else {
            throw AppError.message("Invalid controller identity.")
        }
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x60
        bytes[1] = intent.kind.rawValue
        for index in 0..<6 {
            let start = hex.index(hex.startIndex, offsetBy: index * 2)
            let end = hex.index(start, offsetBy: 2)
            bytes[2 + index] = UInt8(hex[start..<end], radix: 16) ?? 0
        }
        writeUInt32BE(intent.controllerSession, into: &bytes, offset: 8)
        writeUInt32BE(intent.intentSequence, into: &bytes, offset: 12)

        switch intent.kind {
        case .output:
            bytes[16] = UInt8(clamp(intent.value["brightness"] as? Int ?? 0, 0...100))
            bytes[17] = UInt8(clamp(intent.value["rememberedBrightness"] as? Int ?? 20, 1...100))
            bytes[18] = (intent.value["power"] as? Bool) == true ? 0x01 : 0x00
        case .fade:
            bytes[16] = UInt8(clamp(intent.value["fadeMode"] as? Int ?? 0, 0...3))
        case .timer:
            let minutes = intent.value["timerMinutes"] as? Int ?? 0
            bytes[16] = UInt8([0, 15, 30, 60].contains(minutes) ? minutes : 0)
        }
        bytes[19] = crc8(bytes[0..<19])
        return Data(bytes)
    }

    private func orderedAckKey(_ intent: OrderedControlIntent) -> String {
        "\(intent.controllerID)|\(intent.controllerSession)|\(intent.intentSequence)|\(intent.kind.rawValue)"
    }

    private func orderedAckKey(controllerID: String, session: UInt32, sequence: UInt32, kind: UInt8) -> String {
        "\(controllerID)|\(session)|\(sequence)|\(kind)"
    }

    private func writeUInt32BE(_ value: UInt32, into bytes: inout [UInt8], offset: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    private func readUInt32BE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) |
        (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private func crc8<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        bytes.reduce(UInt8(0xA7)) { partial, byte in partial ^ byte }
    }

    private func parseOrderedAck(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count == 20, bytes[0] == 0x61, crc8(bytes[0..<19]) == bytes[19] else { return false }
        let controllerID = bytes[2..<8].map { String(format: "%02X", $0) }.joined()
        let session = readUInt32BE(bytes, offset: 8)
        let sequence = readUInt32BE(bytes, offset: 12)
        let key = orderedAckKey(controllerID: controllerID, session: session, sequence: sequence, kind: bytes[1])
        let status = bytes[16]
        if status <= 2 {
            resolveOrderedAck(key: key)
        } else {
            failOrderedAck(key: key, error: AppError.message("The lamp rejected the ordered Bluetooth command."))
        }
        return true
    }

    private func takeOrderedAckWaiter(key: String) -> (continuation: CheckedContinuation<Void, Error>, timeout: Task<Void, Never>)? {
        orderedAckLock.lock()
        let waiter = orderedAckWaiters.removeValue(forKey: key)
        orderedAckLock.unlock()
        return waiter
    }

    private func resolveOrderedAck(key: String) {
        guard let waiter = takeOrderedAckWaiter(key: key) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: ())
    }

    private func failOrderedAck(key: String, error: Error) {
        guard let waiter = takeOrderedAckWaiter(key: key) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
    }

    func identify() { writeControl([0x07]) }
    func requestStatus(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastStatusRequestAt) >= 1.5 else { return }
        lastStatusRequestAt = now
        writeControl([0x06])
    }
    func powerMode(_ mode: LampPowerMode) { writeControl([0x08, mode.binaryValue]) }
    func requestWiFiStatus() { writeWiFi([0x21]) }
    func retryWiFi() { writeWiFi([0x22]) }
    func requestSavedWiFiNetworks() { writeWiFi([0x25]) }
    func requestControllers() { writeWiFi([0x51]) }

    func selectSavedWiFi(_ ssid: String) {
        if let packet = ssidPacket(command: 0x26, ssid: ssid) { writeWiFi(packet) }
    }

    func deleteSavedWiFi(_ ssid: String) {
        if let packet = ssidPacket(command: 0x27, ssid: ssid) { writeWiFi(packet) }
    }

    func renameLamp(_ name: String) {
        let bytes = Array(name.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard (1...32).contains(bytes.count) else { publishError("Lamp name must contain 1 to 32 bytes."); return }
        writeWiFi([0x40, UInt8(bytes.count)] + bytes)
    }

    func registerController(controllerID: String, label: String) {
        let idBytes = Array(controllerID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16).utf8)
        let labelBytes = Array(String(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppEnvironment.controllerLabel : label).prefix(24).utf8)
        guard (4...16).contains(idBytes.count), !labelBytes.isEmpty else { return }
        writeWiFi([0x50, UInt8(idBytes.count), UInt8(labelBytes.count)] + idBytes + labelBytes)
    }

    func removeController(_ controllerID: String) {
        let bytes = Array(controllerID.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard (4...16).contains(bytes.count) else { return }
        writeWiFi([0x52, UInt8(bytes.count)] + bytes)
    }

    func provisionWiFi(ssid: String, password: String) {
        let ssidBytes = Array(ssid.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let passwordBytes = Array(password.utf8)
        guard (1...32).contains(ssidBytes.count) else { publishError("Wi-Fi name must contain 1 to 32 bytes."); return }
        guard passwordBytes.isEmpty || (8...63).contains(passwordBytes.count) else { publishError("Wi-Fi password must be blank or 8 to 63 bytes."); return }
        guard let peripheral else { publishError("Connect to the lamp first."); return }

        let maxLength = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
        let packet = [UInt8(0x20), UInt8(ssidBytes.count), UInt8(passwordBytes.count)] + ssidBytes + passwordBytes
        if packet.count <= maxLength {
            writeWiFi(packet)
            return
        }

        let payload = ssidBytes + passwordBytes
        let chunkSize = min(17, max(1, maxLength - 3))
        writeWiFi([0x30, UInt8(ssidBytes.count), UInt8(passwordBytes.count)])
        var offset = 0
        while offset < payload.count {
            let length = min(chunkSize, payload.count - offset)
            writeWiFi([0x31, UInt8(offset), UInt8(length)] + Array(payload[offset..<(offset + length)]))
            offset += length
        }
        writeWiFi([0x32])
    }

    private func writeControl(_ bytes: [UInt8], coalesceBrightness: Bool = false) {
        guard let characteristic = controlCharacteristic else { publishError("The lamp Bluetooth control is not ready."); return }
        enqueue(characteristic: characteristic, data: Data(bytes), coalesceBrightness: coalesceBrightness)
    }

    private func writeWiFi(_ bytes: [UInt8]) {
        guard let characteristic = wifiCharacteristic else { publishError("The lamp Wi-Fi setup channel is not ready."); return }
        enqueue(characteristic: characteristic, data: Data(bytes), coalesceBrightness: false)
    }

    private func enqueue(characteristic: CBCharacteristic, data: Data, coalesceBrightness: Bool) {
        if coalesceBrightness {
            writeQueue.removeAll { $0.characteristic.uuid == characteristic.uuid && $0.data.first == 0x02 }
        }
        writeQueue.append(BLEWriteRequest(characteristic: characteristic, data: data))
        dispatchNextWrite()
    }

    private func dispatchNextWrite() {
        guard !writeInProgress, let peripheral, !writeQueue.isEmpty else { return }
        let request = writeQueue.removeFirst()
        writeInProgress = true
        let type: CBCharacteristicWriteType = request.characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(request.data, for: request.characteristic, type: type)
        if type == .withoutResponse {
            writeInProgress = false
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.dispatchNextWrite() }
        }
    }

    private func ssidPacket(command: UInt8, ssid: String) -> [UInt8]? {
        let bytes = Array(ssid.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard (1...32).contains(bytes.count) else { publishError("Wi-Fi name must contain 1 to 32 bytes."); return nil }
        return [command, UInt8(bytes.count)] + bytes
    }

    private func requestInitialState() {
        guard !initialStateRequested else { return }
        initialStateRequested = true
        requestStatus()
        requestWiFiStatus()
    }

    private func clearConnection(keepPeripheral: Bool) {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        controlCharacteristic = nil
        wifiCharacteristic = nil
        identityCharacteristic = nil
        batteryCharacteristic = nil
        writeQueue.removeAll()
        writeInProgress = false
        orderedAckLock.lock()
        let orderedWaiters = Array(orderedAckWaiters.values)
        orderedAckWaiters.removeAll()
        orderedAckLock.unlock()
        orderedWaiters.forEach { item in
            item.timeout.cancel()
            item.continuation.resume(throwing: AppError.message("Bluetooth disconnected before command acknowledgement."))
        }
        initialStateRequested = false
        connectionSetupCompleted = false
        lastStatusRequestAt = .distantPast
        savedAssemblies.removeAll()
        controllerAssemblies.removeAll()
        connectedLampID = ""
        lastRememberedBrightness = nil
        lastRSSI = -127
        rssiTask?.cancel()
        rssiTask = nil
        if !keepPeripheral { peripheral = nil }
    }

    private func parseIdentity(_ raw: String) -> (local: String, cloud: String?)? {
        let tokens = raw.replacingOccurrences(of: "\r", with: "|").replacingOccurrences(of: "\n", with: "|")
            .split(whereSeparator: { "|;,".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        var local: String?
        var cloud: String?
        for token in tokens {
            let upper = token.uppercased()
            if upper.hasPrefix("I:SH-") || upper.hasPrefix("L:SH-") || upper.hasPrefix("LOCAL:SH-") { local = normalizedID(String(token.split(separator: ":", maxSplits: 1).last ?? "")) }
            if upper.hasPrefix("C:SH-") || upper.hasPrefix("CLOUD:SH-") { cloud = normalizedID(String(token.split(separator: ":", maxSplits: 1).last ?? "")) }
        }
        let resolved = local ?? lampID(fromName: connectedName) ?? connectedLampID
        guard resolved.hasPrefix("SH-") else { return nil }
        return (resolved, cloud?.hasPrefix("SH-") == true ? cloud : nil)
    }

    private func normalizedID(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return clean.range(of: "^SH-[A-Z0-9]{4,16}$", options: .regularExpression) != nil ? clean : nil
    }

    private func lampID(fromName name: String) -> String? {
        guard let range = name.range(of: "(?i)^SH Lamp ([0-9A-F]{6})$", options: .regularExpression) else { return normalizedID(name) }
        let matched = String(name[range])
        let suffix = matched.split(separator: " ").last.map(String.init) ?? ""
        return "SH-\(suffix.uppercased())"
    }

    private func parseControlStatus(_ data: Data) {
        if parseOrderedAck(data) { return }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        // RF5.1 additive remembered-brightness notification. It stays separate
        // from the proven legacy status packet so every notification remains
        // within the default 20-byte ATT payload and older apps keep working.
        if let regex = try? NSRegularExpression(pattern: "^L(\\d{3})$"),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let range = Range(match.range(at: 1), in: text),
           let value = Int(text[range]) {
            let remembered = clamp(value, 1...100)
            lastRememberedBrightness = remembered
            let lampID = connectedLampID.isEmpty ? (lampID(fromName: connectedName) ?? "") : connectedLampID
            Task { @MainActor in
                delegate?.bleManager(self, didReceiveRememberedBrightness: remembered, lampID: lampID)
            }
            return
        }

        guard let regex = try? NSRegularExpression(pattern: "^P([01])B(\\d{3})C(\\d{3})F([0-3])T(\\d{5})$"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges == 6 else { return }
        func group(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
        let status = BLELampStatus(
            lampId: connectedLampID,
            power: group(1) == "1",
            targetBrightness: clamp(Int(group(2)) ?? 0, 0...100),
            currentBrightness: clamp(Int(group(3)) ?? 0, 0...100),
            rememberedBrightness: lastRememberedBrightness,
            fadeMode: clamp(Int(group(4)) ?? 2, 0...3),
            timerRemainingSeconds: Int64(max(0, Int(group(5)) ?? 0)),
            rssi: lastRSSI
        )
        Task { @MainActor in delegate?.bleManager(self, didReceive: status) }
    }

    private func parseWiFiNotification(_ data: Data) {
        let bytes = [UInt8](data)
        guard let command = bytes.first else { return }
        switch command {
        case 0xC0:
            savedExpectedCount = bytes.count > 1 ? Int(bytes[1]) : 0
            savedAssemblies.removeAll()
        case 0xC1: parseSavedNetworkChunk(bytes)
        case 0xC2: finishSavedNetworks()
        case 0xD0:
            controllerExpectedCount = bytes.count > 1 ? Int(bytes[1]) : 0
            controllerAssemblies.removeAll()
        case 0xD1: parseControllerChunk(bytes)
        case 0xD2: finishControllers()
        default:
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if text.hasPrefix("W:") {
                    Task { @MainActor in delegate?.bleManager(self, didReceiveWiFiStatus: text) }
                } else if text.hasPrefix("M:"),
                          let mode = LampPowerMode(rawValue: String(text.dropFirst(2)).uppercased()) {
                    Task { @MainActor in delegate?.bleManager(self, didReceivePowerMode: mode) }
                }
            }
        }
    }

    private func parseSavedNetworkChunk(_ bytes: [UInt8]) {
        guard bytes.count >= 7 else { return }
        let index = Int(bytes[1]), total = Int(bytes[2]), flags = Int(bytes[3]), expected = Int(bytes[4]), offset = Int(bytes[5]), length = Int(bytes[6])
        guard expected <= 32, length <= bytes.count - 7, offset + length <= expected else { return }
        savedExpectedCount = total
        let assembly = savedAssemblies[index] ?? TextAssembly(expectedLength: expected)
        guard assembly.expectedLength == expected else { return }
        assembly.flags = flags
        for position in 0..<length {
            assembly.bytes[offset + position] = bytes[7 + position]
            assembly.received[offset + position] = true
        }
        savedAssemblies[index] = assembly
    }

    private func finishSavedNetworks() {
        let networks = savedAssemblies.keys.sorted().compactMap { key -> SavedWiFiNetwork? in
            guard let item = savedAssemblies[key], item.complete,
                  let ssid = String(bytes: item.bytes, encoding: .utf8) else { return nil }
            return SavedWiFiNetwork(ssid: ssid, active: item.flags & 0x01 != 0)
        }.prefix(savedExpectedCount)
        Task { @MainActor in delegate?.bleManager(self, didReceiveSavedNetworks: Array(networks)) }
    }

    private func parseControllerChunk(_ bytes: [UInt8]) {
        guard bytes.count >= 8 else { return }
        let index = Int(bytes[1]), total = Int(bytes[2]), flags = Int(bytes[3]), idLength = Int(bytes[4]), labelLength = Int(bytes[5]), offset = Int(bytes[6]), length = Int(bytes[7])
        let expected = idLength + labelLength
        guard (4...16).contains(idLength), (1...24).contains(labelLength), length <= bytes.count - 8, offset + length <= expected else { return }
        controllerExpectedCount = total
        let assembly = controllerAssemblies[index] ?? TextAssembly(expectedLength: expected)
        guard assembly.expectedLength == expected else { return }
        assembly.flags = flags
        assembly.secondLength = labelLength
        for position in 0..<length {
            assembly.bytes[offset + position] = bytes[8 + position]
            assembly.received[offset + position] = true
        }
        controllerAssemblies[index] = assembly
    }

    private func finishControllers() {
        let controllers = controllerAssemblies.keys.sorted().compactMap { key -> LampControllerAccess? in
            guard let item = controllerAssemblies[key], item.complete else { return nil }
            let idLength = item.expectedLength - item.secondLength
            guard let id = String(bytes: item.bytes.prefix(idLength), encoding: .utf8),
                  let label = String(bytes: item.bytes.suffix(item.secondLength), encoding: .utf8) else { return nil }
            return LampControllerAccess(controllerId: id, label: label, owner: item.flags & 0x01 != 0)
        }.prefix(controllerExpectedCount)
        Task { @MainActor in delegate?.bleManager(self, didReceiveControllers: Array(controllers)) }
    }

    private func publishNearby() {
        let lamps = discovered.values.map(\.lamp).sorted { $0.rssi > $1.rssi }
        Task { @MainActor in delegate?.bleManager(self, didUpdateNearby: lamps) }
    }

    private func publishStatus(_ text: String) { Task { @MainActor in delegate?.bleManager(self, didChangeStatus: text) } }
    private func publishError(_ text: String) { Task { @MainActor in delegate?.bleManager(self, didFail: text) } }
}

extension BLELampManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let status: String
        switch central.state {
        case .poweredOn: status = "Bluetooth is ready."
        case .poweredOff: status = "Bluetooth is off."
        case .unauthorized: status = "Bluetooth permission is required."
        case .unsupported: status = "Bluetooth Low Energy is not supported."
        default: status = "Bluetooth is preparing…"
        }
        publishStatus(status)
        let poweredOn = central.state == .poweredOn
        if !poweredOn, peripheral != nil {
            let disconnectedID = peripheral?.identifier
            clearConnection(keepPeripheral: false)
            Task { @MainActor in delegate?.bleManager(self, didDisconnect: disconnectedID) }
        }
        Task { @MainActor in delegate?.bleManager(self, bluetoothPoweredOn: poweredOn) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "SH Lamp"
        let lampID = lampID(fromName: name) ?? "BLE-\(peripheral.identifier.uuidString.suffix(6))"
        discovered[peripheral.identifier] = (peripheral, NearbyLamp(id: peripheral.identifier, lampId: lampID, advertisedName: name, rssi: RSSI.intValue))
        publishNearby()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Switching A -> B can leave a late callback for A in CoreBluetooth's
        // queue. Never let that callback mutate B's connection state.
        guard self.peripheral?.identifier == peripheral.identifier else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        publishStatus("Reading lamp services…")
        peripheral.discoverServices([serviceUUID, batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        guard self.peripheral?.identifier == id else { return }
        publishError(error?.localizedDescription ?? "Bluetooth connection failed.")
        clearConnection(keepPeripheral: false)
        Task { @MainActor in delegate?.bleManager(self, didDisconnect: id) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        let wasCurrent = self.peripheral?.identifier == id
        if wasCurrent {
            clearConnection(keepPeripheral: false)
            publishStatus(error == nil ? "Bluetooth disconnected." : "Bluetooth connection was lost.")
        }
        // Always identify the disconnected physical lamp so its route can be
        // refreshed; AppViewModel preserves a replacement connection if one
        // has already been selected.
        Task { @MainActor in delegate?.bleManager(self, didDisconnect: id) }
    }
}

extension BLELampManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { publishError(error.localizedDescription); return }
        for service in peripheral.services ?? [] {
            if service.uuid == serviceUUID {
                peripheral.discoverCharacteristics([controlUUID, wifiUUID, identityUUID], for: service)
            } else if service.uuid == batteryServiceUUID {
                peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { publishError(error.localizedDescription); return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case controlUUID: controlCharacteristic = characteristic
            case wifiUUID: wifiCharacteristic = characteristic
            case identityUUID: identityCharacteristic = characteristic
            case batteryLevelUUID: batteryCharacteristic = characteristic
            default: break
            }
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if let identityCharacteristic, identityCharacteristic.properties.contains(.read) {
            peripheral.readValue(for: identityCharacteristic)
        } else {
            finishConnectionSetup(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { publishError(error.localizedDescription); return }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case identityUUID:
            if let raw = String(data: data, encoding: .utf8), let identity = parseIdentity(raw) {
                connectedLampID = identity.local
                Task { @MainActor in delegate?.bleManager(self, didResolveLocalID: identity.local, cloudID: identity.cloud) }
            }
            finishConnectionSetup(peripheral)
        case controlUUID: parseControlStatus(data)
        case wifiUUID: parseWiFiNotification(data)
        case batteryLevelUUID:
            if let value = data.first, value <= 100 {
                let lampID = connectedLampID.isEmpty ? (lampID(fromName: connectedName) ?? "") : connectedLampID
                Task { @MainActor in delegate?.bleManager(self, didReceiveBattery: Int(value), lampID: lampID) }
            }
        default: break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeInProgress = false
        if let error { publishError("Bluetooth write failed: \(error.localizedDescription)") }
        dispatchNextWrite()
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        lastRSSI = RSSI.intValue
        let lampID = connectedLampID
        Task { @MainActor in delegate?.bleManager(self, didUpdateRSSI: RSSI.intValue, lampID: lampID) }
    }

    private func finishConnectionSetup(_ peripheral: CBPeripheral) {
        guard controlCharacteristic != nil, !connectionSetupCompleted else { return }
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        connectionSetupCompleted = true
        if connectedLampID.isEmpty { connectedLampID = lampID(fromName: connectedName) ?? "BLE-\(peripheral.identifier.uuidString.suffix(6))" }
        Task { @MainActor in delegate?.bleManager(self, didConnect: connectedLampID, peripheralID: peripheral.identifier, name: connectedName) }
        peripheral.readRSSI()
        rssiTask?.cancel()
        rssiTask = Task { [weak self, weak peripheral] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, let peripheral, self.peripheral === peripheral else { return }
                peripheral.readRSSI()
            }
        }
        if let batteryCharacteristic, batteryCharacteristic.properties.contains(.read) {
            peripheral.readValue(for: batteryCharacteristic)
        }
        requestInitialState()
        publishStatus("Bluetooth connected.")
    }
}
