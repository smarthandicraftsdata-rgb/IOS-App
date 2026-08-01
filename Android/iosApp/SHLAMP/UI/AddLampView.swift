import SwiftUI

struct AddLampView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var lampID = ""
    @State private var claimCode = ""
    @State private var displayName = "Living Room Lamp"
    @State private var roomID = ""
    @State private var ssid = ""
    @State private var wifiPassword = ""
    @State private var showingScanner = false
    @State private var scanError = ""
    @State private var newRoom = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Add an SH Lamp", systemImage: "lightbulb.led.fill").font(.title2.bold()).foregroundStyle(SHLampTheme.primary)
                    Text("Scan the lamp code, connect over Bluetooth, send Wi-Fi details and claim it to your account.").font(.subheadline).foregroundStyle(SHLampTheme.textSecondary)
                }.padding(.vertical, 6)
            }

            Section("1. Lamp code") {
                Button { showingScanner = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                TextField("Lamp ID (for example SH-0727182134)", text: $lampID).textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Claim code", text: $claimCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                if !scanError.isEmpty { Text(scanError).font(.footnote).foregroundStyle(SHLampTheme.error) }
            }

            Section("2. Nearby Bluetooth lamp") {
                HStack { Text(model.bluetoothStatus).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Search again") { model.ble.startScan() } }
                if model.nearbyLamps.isEmpty { Text("No nearby lamp found yet.").foregroundStyle(.secondary) }
                ForEach(model.nearbyLamps) { nearby in
                    Button {
                        lampID = nearby.lampId.hasPrefix("SH-") ? nearby.lampId : lampID
                        model.connect(nearby)
                    } label: {
                        HStack { Image(systemName: "dot.radiowaves.left.and.right"); VStack(alignment: .leading) { Text(nearby.advertisedName); Text(nearby.lampId).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("\(nearby.rssi) dBm").font(.caption) }
                    }
                }
            }

            Section("3. Connect lamp to Wi-Fi") {
                TextField("2.4 GHz Wi-Fi network", text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Wi-Fi password", text: $wifiPassword)
                Button("Send Wi-Fi details") { model.provisionWiFi(ssid: ssid, password: wifiPassword) }
                    .disabled(ssid.isEmpty || (wifiPassword.count > 0 && wifiPassword.count < 8) || !model.ble.isReady)
                Text("The iPhone does not expose your saved Wi-Fi password, so enter it once here.").font(.caption).foregroundStyle(.secondary)
            }

            Section("4. Name and room") {
                TextField("Lamp name", text: $displayName)
                Picker("Room", selection: $roomID) {
                    Text("Unassigned").tag("")
                    ForEach(model.dashboard.homes.flatMap { $0.rooms }) { room in Text(room.name).tag(room.id) }
                }
                HStack {
                    TextField("New room", text: $newRoom)
                    Button("Create") { Task { if let room = await model.createRoom(name: newRoom) { roomID = room.id; newRoom = "" } } }.disabled(newRoom.isEmpty)
                }
            }

            Section {
                Button {
                    Task {
                        let success = await model.claimLamp(lampID: lampID, claimCode: claimCode, displayName: displayName, roomID: roomID.isEmpty ? nil : roomID)
                        if success { dismiss() }
                    }
                } label: {
                    HStack { if model.busy { ProgressView() }; Text("Add lamp to my account").frame(maxWidth: .infinity) }
                }
                .disabled(lampID.isEmpty || claimCode.isEmpty || displayName.isEmpty || model.busy)
            }

            if !model.errorMessage.isEmpty { Section { Text(model.errorMessage).foregroundStyle(SHLampTheme.error) } }
            if !model.notice.isEmpty { Section { Text(model.notice).foregroundStyle(SHLampTheme.success) } }
        }
        .navigationTitle("Add Lamp")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .onAppear { model.ble.startScan() }
        .sheet(isPresented: $showingScanner) {
            NavigationStack {
                QRScannerView { raw in
                    do {
                        let parsed = try LampQRParser.parse(raw)
                        lampID = parsed.lampId
                        claimCode = parsed.claimCode
                        showingScanner = false
                    } catch { scanError = error.localizedDescription; showingScanner = false }
                } onError: { scanError = $0; showingScanner = false }
                .ignoresSafeArea()
                .navigationTitle("Scan Lamp Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { showingScanner = false } }
            }
        }
    }
}
