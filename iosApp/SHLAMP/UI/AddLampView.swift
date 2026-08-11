import SwiftUI

private enum SetupConnectionChoice {
    case bluetoothOnly
    case wifi
}

private enum LampCodeScanPurpose {
    case remoteAccess
}

struct AddLampView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var connectionChoice: SetupConnectionChoice?
    @State private var selectedNearbyID: UUID?
    @State private var displayName = "Living Room Lamp"
    @State private var roomID = ""
    @State private var ssid = ""
    @State private var wifiPassword = ""
    @State private var wifiSent = false
    @State private var newRoom = ""
    @State private var addedLampID = ""
    @State private var didCommit = false
    @State private var remoteAccessOnly = false
    @State private var showingRemoteForm = false
    @State private var cloudLampID = ""
    @State private var claimCode = ""
    @State private var showingScanner = false
    @State private var scanPurpose: LampCodeScanPurpose = .remoteAccess
    @State private var localError = ""

    private let stepNames = ["Find", "Choose", "Wi-Fi", "Name", "Complete"]

    private var selectedNearby: NearbyLamp? {
        model.nearbyLamps.first { $0.id == selectedNearbyID }
    }

    private var resolvedLocalID: String {
        let resolved = model.setupConnectedLampID.isEmpty ? (selectedNearby?.lampId ?? "") : model.setupConnectedLampID
        return resolved.uppercased()
    }

    private var addedLamp: LampRecord? {
        model.lamps.first { lamp in
            lamp.id.caseInsensitiveCompare(addedLampID) == .orderedSame ||
                lamp.canonicalID.caseInsensitiveCompare(addedLampID) == .orderedSame
        }
    }

    private var normalizedCloudLampID: String {
        cloudLampID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private var normalizedClaimCode: String {
        claimCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private var cloudLampIDIsValid: Bool {
        normalizedCloudLampID.range(of: "^SH-[A-Z0-9]{4,16}$", options: .regularExpression) != nil
    }

    private var claimCodeIsValid: Bool {
        !normalizedClaimCode.isEmpty && normalizedClaimCode.utf8.count <= 64
    }

    private var wifiCredentialsAreValid: Bool {
        let ssidCount = ssid.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
        let passwordCount = wifiPassword.utf8.count
        return (1...32).contains(ssidCount) && (passwordCount == 0 || (8...63).contains(passwordCount))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 14) {
                wizardHeader
                setupHero

                switch step {
                case 0: findStep
                case 1: chooseStep
                case 2: wifiStep
                case 3: nameStep
                default: completeStep
                }

                if !localError.isEmpty { NoticeCard(text: localError, error: true) }
                if !model.errorMessage.isEmpty { NoticeCard(text: model.errorMessage, error: true) }
                if !model.notice.isEmpty { NoticeCard(text: model.notice, error: false) }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 30)
        }
        .background(SHLampTheme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .onAppear {
            model.errorMessage = ""
            if !remoteAccessOnly { model.beginAddLampFlow() }
        }
        .onDisappear {
            if !didCommit && !remoteAccessOnly { model.cancelAddLampFlow() }
        }
        .onChange(of: ssid) { _, _ in wifiSent = false }
        .onChange(of: wifiPassword) { _, _ in wifiSent = false }
        .sheet(isPresented: $showingScanner) {
            NavigationStack {
                QRScannerView { raw in
                    do {
                        let parsed = try LampQRParser.parse(raw)
                        switch scanPurpose {
                        case .remoteAccess:
                            cloudLampID = parsed.lampId
                            claimCode = parsed.claimCode
                            showingRemoteForm = true
                        }
                        localError = ""
                        showingScanner = false
                    } catch {
                        localError = error.localizedDescription
                        showingScanner = false
                    }
                } onError: {
                    localError = $0
                    showingScanner = false
                }
                .ignoresSafeArea()
                .navigationTitle("Scan Lamp Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { showingScanner = false } }
            }
        }
    }

    private var wizardHeader: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    if step == 0 || remoteAccessOnly { dismiss() }
                    else if step == 4 && didCommit { dismiss() }
                    else { step = max(0, step - 1) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .frame(width: 42, height: 42)
                        .background(SHLampTheme.surface, in: Circle())
                        .overlay(Circle().stroke(SHLampTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(remoteAccessOnly ? "Add Remote Access" : "Add Lamp")
                        .font(.title2.bold())
                        .foregroundStyle(SHLampTheme.textPrimary)
                    Text(remoteAccessOnly ? "Link a lamp to your account" : "Step \(step + 1) of 5 · \(stepNames[step])")
                        .font(.caption)
                        .foregroundStyle(SHLampTheme.textSecondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SHLampTheme.primary)
            }

            if !remoteAccessOnly {
                HStack(spacing: 7) {
                    ForEach(0..<5, id: \.self) { index in
                        Capsule()
                            .fill(index <= step ? SHLampTheme.primary : SHLampTheme.border)
                            .frame(height: 5)
                            .animation(.easeInOut(duration: 0.25), value: step)
                    }
                }
            }
        }
    }

    private var setupHero: some View {
        HStack(spacing: 15) {
            ZStack {
                Circle().fill(step == 0 ? SHLampTheme.primarySoft : SHLampTheme.warmSoft)
                MiniLampGlyph(isOn: step > 0)
                    .frame(width: 54, height: 54)
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 5) {
                Text(heroTitle)
                    .font(.title3.bold())
                    .foregroundStyle(SHLampTheme.textPrimary)
                Text(heroSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(SHLampTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                StatusPill(text: remoteAccessOnly ? "Remote" : stepNames[step], color: SHLampTheme.primary)
            }
            Spacer()
        }
        .shGlassCard(padding: 18, radius: 28)
    }

    private var heroTitle: String {
        if remoteAccessOnly { return "Enable control from anywhere" }
        switch step {
        case 0: return "Find your lamp"
        case 1: return "Choose how to add it"
        case 2: return "Connect lamp to Wi-Fi"
        case 3: return "Name your lamp"
        default: return "Lamp added successfully"
        }
    }

    private var heroSubtitle: String {
        if remoteAccessOnly { return "Scan the lamp code or enter its Lamp ID and claim code." }
        switch step {
        case 0: return "Keep the lamp switched on and close to your iPhone."
        case 1: return "Selecting a lamp only verifies it. Nothing is saved until you confirm."
        case 2: return "Wi-Fi connects the lamp to your router. Remote access is a separate optional step."
        case 3: return "Choose a clear name and optionally place the lamp in a room."
        default: return "Open the lamp now or enable remote access for control away from home."
        }
    }

    private var findStep: some View {
        VStack(spacing: 14) {
            setupCard(title: "Nearby lamps", subtitle: model.bluetoothStatus) {
                HStack {
                    Text(model.nearbyLamps.isEmpty ? "No nearby lamp found yet." : "Select the physical lamp you want to verify.")
                        .font(.caption)
                        .foregroundStyle(SHLampTheme.textSecondary)
                    Spacer()
                    Button("Search again") { model.ble.startScan() }
                        .font(.caption.weight(.semibold))
                }

                if model.nearbyLamps.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Searching nearby…")
                            .font(.subheadline)
                            .foregroundStyle(SHLampTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    ForEach(model.nearbyLamps) { nearby in
                        NearbyLampRow(nearby: nearby, selected: selectedNearbyID == nearby.id) {
                            selectedNearbyID = nearby.id
                            displayName = nearby.advertisedName
                            model.connect(nearby, forSetup: true)
                            localError = ""
                            step = 1
                        }
                    }
                }
            }

            setupCard(title: "Already installed?", subtitle: "Add remote access without setting up Bluetooth or Wi-Fi again.") {
                Button {
                    remoteAccessOnly = true
                    showingRemoteForm = true
                    step = 4
                    model.cancelAddLampFlow()
                } label: {
                    Label("Add with Lamp ID and claim code", systemImage: "cloud.badge.plus")
                }
                .buttonStyle(.bordered)
                .tint(SHLampTheme.primary)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var chooseStep: some View {
        VStack(spacing: 14) {
            setupCard(title: "Is this your lamp?", subtitle: model.bluetoothStatus) {
                if let selectedNearby {
                    NearbyLampRow(nearby: selectedNearby, selected: true) {
                        model.connect(selectedNearby, forSetup: true)
                    }
                }

                LabeledContent("Physical lamp ID", value: resolvedLocalID.isEmpty ? "Reading…" : resolvedLocalID)
                    .font(.subheadline)

                Text("The lamp has not been added to Devices yet.")
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textSecondary)
            }

            setupCard(title: "Choose connection", subtitle: "You can add Wi-Fi and remote access later from Lamp Settings.") {
                Button {
                    connectionChoice = .bluetoothOnly
                    step = 3
                } label: {
                    setupChoiceLabel(
                        title: "Add with Bluetooth only",
                        subtitle: "Nearby control without entering Wi-Fi details",
                        icon: "dot.radiowaves.left.and.right"
                    )
                }
                .buttonStyle(.plain)
                .disabled(!model.ble.isReady)

                Button {
                    connectionChoice = .wifi
                    step = 2
                } label: {
                    setupChoiceLabel(
                        title: "Connect to Wi-Fi",
                        subtitle: "Local control on your home network; remote access remains optional",
                        icon: "wifi"
                    )
                }
                .buttonStyle(.plain)
                .disabled(!model.ble.isReady)
            }
        }
    }

    private var wifiStep: some View {
        VStack(spacing: 14) {
            setupCard(title: "Home Wi-Fi", subtitle: "Use a 2.4 GHz network supported by the lamp.") {
                setupField("Wi-Fi network", text: $ssid, capitalization: .never)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Wi-Fi password")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SHLampTheme.textSecondary)
                    SecureField("Wi-Fi password", text: $wifiPassword)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 13)
                        .background(SHLampTheme.surfaceSoft, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }

                Button {
                    guard wifiCredentialsAreValid, model.ble.isReady else { return }
                    model.provisionWiFi(
                        ssid: ssid.trimmingCharacters(in: .whitespacesAndNewlines),
                        password: wifiPassword
                    )
                    wifiSent = true
                } label: {
                    Label(wifiSent ? "Send Wi-Fi details again" : "Send Wi-Fi details", systemImage: "wifi")
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!wifiCredentialsAreValid || !model.ble.isReady)

                Text("Wi-Fi credentials connect the lamp to the router. A claim code is not required for local Wi-Fi control.")
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textSecondary)
            }

            Button("Continue to name lamp") { step = 3 }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!wifiSent)
        }
    }

    private var nameStep: some View {
        VStack(spacing: 14) {
            setupCard(title: "Name your lamp", subtitle: "The lamp will be added only when you press the button below.") {
                setupField("Lamp name", text: $displayName, capitalization: .words)

                Picker("Room", selection: $roomID) {
                    Text("Unassigned").tag("")
                    ForEach(model.dashboard.homes.flatMap(\.rooms)) { room in
                        Text(room.name).tag(room.id)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 10) {
                    setupField("New room", text: $newRoom, capitalization: .words)
                    Button("Create") {
                        Task {
                            if let room = await model.createRoom(name: newRoom) {
                                roomID = room.id
                                newRoom = ""
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(SHLampTheme.primary)
                    .disabled(newRoom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Button {
                guard let record = model.commitLocalLamp(
                    name: displayName,
                    roomID: roomID.isEmpty ? nil : roomID
                ) else {
                    localError = "The lamp identity is not ready. Reconnect to the nearby lamp and try again."
                    return
                }
                addedLampID = record.id
                didCommit = true
                if let cloudID = record.cloudLampId, !cloudID.isEmpty { cloudLampID = cloudID }
                localError = ""
                step = 4
            } label: {
                Label(
                    connectionChoice == .bluetoothOnly ? "Add Bluetooth Lamp" : "Add Wi-Fi Lamp",
                    systemImage: "checkmark.circle.fill"
                )
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvedLocalID.isEmpty)
        }
    }

    private var completeStep: some View {
        VStack(spacing: 14) {
            if !remoteAccessOnly {
                setupCard(title: "Lamp added", subtitle: "Bluetooth and local Wi-Fi are routes to this one physical device.") {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(SHLampTheme.success)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(addedLamp?.name ?? displayName)
                                .font(.headline)
                            Text(addedLamp?.id ?? addedLampID)
                                .font(.caption.monospaced())
                                .foregroundStyle(SHLampTheme.textSecondary)
                        }
                        Spacer()
                    }

                    Button("Open Lamp") {
                        model.selectedLampID = addedLamp?.canonicalID ?? addedLampID
                        dismiss()
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                }
            }

            if addedLamp?.cloudClaimed == true && !remoteAccessOnly {
                setupCard(title: "Remote access", subtitle: "This lamp is already linked to your account.") {
                    Label("Connected", systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(SHLampTheme.success)
                    LabeledContent("Cloud ID", value: addedLamp?.cloudLampId ?? "")
                }
            } else {
                setupCard(
                    title: "Remote access",
                    subtitle: remoteAccessOnly
                        ? "A valid claim code is required to link ownership."
                        : "Optional: control this same lamp while away from home."
                ) {
                    if !showingRemoteForm {
                        Button {
                            showingRemoteForm = true
                        } label: {
                            Label("Enable Remote Access", systemImage: "cloud.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .tint(SHLampTheme.primary)
                    } else {
                        Button {
                            scanPurpose = .remoteAccess
                            showingScanner = true
                        } label: {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.bordered)
                        .tint(SHLampTheme.primary)

                        setupField("Cloud Lamp ID", text: $cloudLampID, capitalization: .characters)
                        setupField("Claim code", text: $claimCode, capitalization: .characters)

                        Button {
                            Task {
                                guard cloudLampIDIsValid, claimCodeIsValid else {
                                    localError = "Enter a valid Lamp ID and claim code."
                                    return
                                }
                                let success = await model.claimLamp(
                                    lampID: normalizedCloudLampID,
                                    claimCode: normalizedClaimCode,
                                    displayName: displayName,
                                    roomID: roomID.isEmpty ? nil : roomID
                                )
                                if success {
                                    didCommit = true
                                    localError = ""
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if model.busy { ProgressView().tint(.white) }
                                Text(model.busy ? "Linking…" : "Add Remote Access")
                            }
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(!cloudLampIDIsValid || !claimCodeIsValid || model.busy)
                    }
                }
            }

            if !remoteAccessOnly {
                Button("Not now") { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(SHLampTheme.primary)
            }
        }
    }

    private func setupChoiceLabel(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(SHLampTheme.primary)
                .frame(width: 44, height: 44)
                .background(SHLampTheme.primarySoft, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SHLampTheme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(SHLampTheme.textDisabled)
        }
        .padding(13)
        .background(SHLampTheme.surfaceSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(SHLampTheme.border, lineWidth: 1))
    }

    private func setupCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(SHLampTheme.textPrimary)
                Text(subtitle).font(.caption).foregroundStyle(SHLampTheme.textSecondary)
            }
            content()
        }
        .shCard(padding: 18, radius: 24)
    }

    private func setupField(
        _ title: String,
        text: Binding<String>,
        capitalization: TextInputAutocapitalization
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SHLampTheme.textSecondary)
            TextField(title, text: text)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .padding(.horizontal, 13)
                .padding(.vertical, 13)
                .background(SHLampTheme.surfaceSoft, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }
}

private struct NearbyLampRow: View {
    let nearby: NearbyLamp
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(selected ? SHLampTheme.primarySoft : SHLampTheme.surfaceSoft)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(selected ? SHLampTheme.primary : SHLampTheme.textSecondary)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(nearby.advertisedName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SHLampTheme.textPrimary)
                    Text(nearby.lampId)
                        .font(.caption.monospaced())
                        .foregroundStyle(SHLampTheme.textSecondary)
                }
                Spacer()
                Text("\(nearby.rssi) dBm")
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textSecondary)
                Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(selected ? SHLampTheme.success : SHLampTheme.textDisabled)
            }
            .padding(12)
            .background(selected ? SHLampTheme.primarySoft.opacity(0.55) : SHLampTheme.surfaceSoft.opacity(0.65), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(selected ? SHLampTheme.primary.opacity(0.32) : SHLampTheme.border.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
