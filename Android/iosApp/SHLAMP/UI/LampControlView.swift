import SwiftUI

struct LampControlView: View {
    @EnvironmentObject private var model: AppViewModel
    let lampID: String
    @State private var draftBrightness = 0.0
    @State private var showingSettings = false

    private var lamp: LampRecord? { model.lamps.first { $0.id == lampID || $0.canonicalID == lampID } }

    var body: some View {
        Group {
            if let lamp {
                ScrollView {
                    VStack(spacing: 18) {
                        hero(lamp)
                        brightnessCard(lamp)
                        batteryCard(lamp)
                        fadeCard(lamp)
                        timerCard(lamp)
                        connectionCard(lamp)
                        Button { model.identify(lamp) } label: {
                            Label("Blink lamp", systemImage: "light.beacon.max.fill").frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered).tint(SHLampTheme.primary)
                    }.padding(18)
                }
                .background(SHLampTheme.background)
                .navigationTitle(lamp.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button { showingSettings = true } label: { Image(systemName: "gearshape") } }
                .sheet(isPresented: $showingSettings) { NavigationStack { LampSettingsView(lampID: lamp.id) } }
                .onAppear { draftBrightness = Double(lamp.state.brightness) }
                .onChange(of: lamp.state.brightness) { _, new in draftBrightness = Double(new) }
            } else {
                ContentUnavailableView("Lamp not found", systemImage: "lightbulb.slash", description: Text("Refresh your devices and try again."))
            }
        }
    }

    private func hero(_ lamp: LampRecord) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(lamp.state.power ? SHLampTheme.warmSoft : SHLampTheme.surfaceSoft).frame(width: 150, height: 150)
                Circle().fill(lamp.state.power ? SHLampTheme.warm.opacity(Double(lamp.state.brightness) / 220 + 0.08) : .clear).frame(width: 118, height: 118).blur(radius: 12)
                Image(systemName: lamp.state.power ? "lightbulb.led.fill" : "lightbulb.led")
                    .font(.system(size: 70)).foregroundStyle(lamp.state.power ? SHLampTheme.warmDeep : SHLampTheme.textSecondary)
            }
            HStack {
                VStack(alignment: .leading) {
                    Text(lamp.state.power ? "Lamp is on" : "Lamp is off").font(.title2.bold())
                    Text(lamp.roomName ?? lamp.id).font(.subheadline).foregroundStyle(SHLampTheme.textSecondary)
                }
                Spacer()
                Button { model.setPower(lamp, on: !lamp.state.power) } label: {
                    Image(systemName: "power").font(.title2.bold()).frame(width: 54, height: 54)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(lamp.state.power ? SHLampTheme.primary : SHLampTheme.textSecondary)
            }
        }.shCard()
    }

    private func brightnessCard(_ lamp: LampRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("Brightness", systemImage: "sun.max.fill").font(.headline); Spacer(); Text("\(Int(draftBrightness))%").font(.title3.bold()) }
            Slider(value: $draftBrightness, in: 0...100, step: 1) { editing in
                if !editing { model.setBrightness(lamp, value: Int(draftBrightness)) }
            }.tint(SHLampTheme.warmDeep)
            HStack {
                ForEach([20, 60, 100], id: \.self) { value in
                    Button("\(value)%") { draftBrightness = Double(value); model.setBrightness(lamp, value: value) }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                }
            }
        }.shCard()
    }

    @ViewBuilder
    private func batteryCard(_ lamp: LampRecord) -> some View {
        if lamp.state.batteryValid || lamp.state.batteryPercent != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Battery", systemImage: lamp.state.batteryCharging == true ? "battery.100percent.bolt" : "battery.75percent").font(.headline)
                    Spacer()
                    Text(lamp.state.batteryPercent.map { "\($0)%" } ?? "Reading…").font(.title3.bold())
                }
                if let percent = lamp.state.batteryPercent {
                    ProgressView(value: Double(percent), total: 100).tint(percent < 20 ? SHLampTheme.error : SHLampTheme.success)
                }
                HStack {
                    if let mv = lamp.state.batteryVoltageMv { Text(String(format: "%.2f V", Double(mv) / 1000)).font(.caption).foregroundStyle(SHLampTheme.textSecondary) }
                    Spacer()
                    Text(lamp.state.batteryCharging == true ? "Charging" : "On battery").font(.caption.weight(.semibold)).foregroundStyle(lamp.state.batteryCharging == true ? SHLampTheme.success : SHLampTheme.textSecondary)
                }
            }.shCard()
        }
    }

    private func fadeCard(_ lamp: LampRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Fade speed", systemImage: "waveform.path.ecg").font(.headline)
            Picker("Fade speed", selection: Binding(get: { lamp.state.fadeMode }, set: { model.setFade(lamp, mode: $0) })) {
                Text("Instant").tag(0); Text("Fast").tag(1); Text("Smooth").tag(2); Text("Slow").tag(3)
            }.pickerStyle(.segmented)
            Text("Fade control is available over Bluetooth or local Wi-Fi.").font(.caption).foregroundStyle(SHLampTheme.textSecondary)
        }.shCard()
    }

    private func timerCard(_ lamp: LampRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Auto-off timer", systemImage: "timer").font(.headline); Spacer(); if lamp.state.timerRemainingSeconds > 0 { Text(formatTimer(lamp.state.timerRemainingSeconds)).font(.caption.bold()) } }
            HStack {
                ForEach([0, 15, 30, 60], id: \.self) { minutes in
                    Button(minutes == 0 ? "Off" : "\(minutes)m") { model.setTimer(lamp, minutes: minutes) }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                }
            }
        }.shCard()
    }

    private func connectionCard(_ lamp: LampRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Connection", systemImage: "antenna.radiowaves.left.and.right").font(.headline); Spacer(); StatusPill(text: lamp.route.label, color: lamp.reachable ? SHLampTheme.success : SHLampTheme.offline) }
            if let ssid = lamp.wifiSSID { LabeledContent("Wi-Fi", value: ssid) }
            if let firmware = lamp.firmware, !firmware.isEmpty { LabeledContent("Firmware", value: firmware) }
            LabeledContent("Lamp ID", value: lamp.canonicalID)
        }.font(.subheadline).shCard()
    }

    private func formatTimer(_ seconds: Int64) -> String {
        let minutes = seconds / 60, remainder = seconds % 60
        return String(format: "%02lld:%02lld", minutes, remainder)
    }
}

struct LampSettingsView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let lampID: String
    @State private var name = ""
    @State private var roomID = ""
    @State private var releasedCode = ""
    @State private var confirmRelease = false

    private var lamp: LampRecord? { model.lamps.first { $0.id == lampID } }

    var body: some View {
        Form {
            if let lamp {
                Section("Lamp details") {
                    TextField("Lamp name", text: $name)
                    Picker("Room", selection: $roomID) {
                        Text("Unassigned").tag("")
                        ForEach(model.dashboard.homes.flatMap { $0.rooms }) { room in Text(room.name).tag(room.id) }
                    }
                    LabeledContent("Lamp ID", value: lamp.canonicalID)
                    LabeledContent("Connection", value: lamp.route.label)
                }
                Section("Nearby actions") {
                    Button("Blink lamp") { model.identify(lamp) }
                    Button("Read saved Wi-Fi networks") { model.ble.requestSavedWiFiNetworks() }
                    Button("Read authorized controllers") { model.ble.requestControllers() }
                }
                if !model.savedWiFiNetworks.isEmpty {
                    Section("Saved Wi-Fi") {
                        ForEach(model.savedWiFiNetworks) { network in
                            HStack { Text(network.ssid); Spacer(); if network.active { Image(systemName: "checkmark.circle.fill").foregroundStyle(SHLampTheme.success) } }
                        }
                    }
                }
                Section {
                    Button("Release lamp from account", role: .destructive) { confirmRelease = true }
                    if !releasedCode.isEmpty { Text("New claim code: \(releasedCode)").font(.footnote.monospaced()).textSelection(.enabled) }
                }
            }
            if !model.errorMessage.isEmpty { Section { Text(model.errorMessage).foregroundStyle(SHLampTheme.error) } }
        }
        .navigationTitle("Lamp Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let lamp else { return }
                    Task { if await model.saveSettings(lamp, name: name, roomID: roomID.isEmpty ? nil : roomID) { dismiss() } }
                }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            }
        }
        .onAppear { name = lamp?.name ?? ""; roomID = lamp?.roomId ?? "" }
        .alert("Release this lamp?", isPresented: $confirmRelease) {
            Button("Cancel", role: .cancel) {}
            Button("Release", role: .destructive) {
                guard let lamp else { return }
                Task { if let released = await model.releaseLamp(lamp) { releasedCode = released.newClaimCode } }
            }
        } message: { Text("The lamp will be removed from this account. Save the new claim code before pairing it again.") }
    }
}
