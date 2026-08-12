import SwiftUI

struct LampControlView: View {
    @EnvironmentObject private var model: AppViewModel
    let lampID: String

    @State private var draftBrightness: Double = 50
    @State private var brightnessDragging = false
    @State private var showingSettings = false
    @State private var showingRoutePicker = false
    @State private var pendingPowerMode: LampPowerMode?
    @State private var isHeaderCollapsed = false
    @State private var fallbackInitialScrollY: CGFloat?
    @State private var selectedFeatureTab: LampFeatureTab = .useful

    private var lamp: LampRecord? {
        model.lamps.first { $0.id == lampID || $0.canonicalID == lampID }
    }

    var body: some View {
        Group {
            if let lamp {
                ZStack(alignment: .top) {
                    trackedScrollView(lamp)

                    if isHeaderCollapsed {
                        compactHeader(lamp)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            .zIndex(20)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: isHeaderCollapsed)
                .animation(.easeInOut(duration: 0.20), value: selectedFeatureTab)
                .background(SHLampTheme.background.ignoresSafeArea())
                .navigationTitle(lamp.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack { LampSettingsView(lampID: lamp.id) }
                }
                .confirmationDialog("Connection route", isPresented: $showingRoutePicker, titleVisibility: .visible) {
                    ForEach(LampRoutePreference.allCases) { preference in
                        Button(preference.label + (lamp.routePreference == preference ? " ✓" : "")) {
                            model.setRoutePreference(lamp, preference: preference)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Automatic uses the best healthy route: Bluetooth or Local Wi-Fi nearby, then Remote when needed.")
                }
                .alert(item: $pendingPowerMode) { mode in
                    Alert(
                        title: Text(mode == .touchOnly ? "Switch to Touch Only?" : "Switch to BLE Only?"),
                        message: Text(powerModeWarning(mode)),
                        primaryButton: .destructive(Text("Switch")) { model.setPowerMode(lamp, mode: mode) },
                        secondaryButton: .cancel()
                    )
                }
                .onAppear {
                    model.focusLamp(lamp)
                    draftBrightness = Double(lamp.state.brightness)
                    isHeaderCollapsed = false
                    fallbackInitialScrollY = nil
                }
                .onDisappear {
                    model.clearLampFocus(lamp)
                }
                .onChange(of: lamp.state.brightness) { _, newValue in
                    // While the user owns the slider, delayed BLE/Wi-Fi/cloud
                    // echoes must not move the thumb underneath their finger.
                    // The final released value is reconciled by AppViewModel.
                    guard !brightnessDragging else { return }
                    draftBrightness = Double(newValue)
                }
                .onChange(of: lamp.state.powerMode) { _, mode in
                    if mode == .maximumBackup { draftBrightness = min(draftBrightness, 70) }
                }
            } else {
                ContentUnavailableView(
                    "Lamp not found",
                    systemImage: "lightbulb.slash",
                    description: Text("Refresh your devices and try again.")
                )
            }
        }
    }

    @ViewBuilder
    private func trackedScrollView(_ lamp: LampRecord) -> some View {
        if #available(iOS 18.0, *) {
            ScrollView(showsIndicators: false) {
                lampScrollContent(lamp, includesFallbackMarker: false)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                return offset > 72
            } action: { _, collapsed in
                guard isHeaderCollapsed != collapsed else { return }
                isHeaderCollapsed = collapsed
            }
        } else {
            ScrollView(showsIndicators: false) {
                lampScrollContent(lamp, includesFallbackMarker: true)
            }
            .onPreferenceChange(LampScrollYPreferenceKey.self) { currentY in
                if fallbackInitialScrollY == nil {
                    fallbackInitialScrollY = currentY
                    isHeaderCollapsed = false
                    return
                }

                let offset = (fallbackInitialScrollY ?? currentY) - currentY
                let collapsed = offset > 72
                guard isHeaderCollapsed != collapsed else { return }
                isHeaderCollapsed = collapsed
            }
        }
    }

    private func lampScrollContent(
        _ lamp: LampRecord,
        includesFallbackMarker: Bool
    ) -> some View {
        VStack(spacing: 14) {
            if includesFallbackMarker {
                fallbackScrollOffsetMarker
            }

            expandedHeader(lamp)
            controlMetrics(lamp)
            brightnessCard(lamp)
            featureTabs

            Group {
                switch selectedFeatureTab {
                case .useful:
                    fadeAndTimerCard(lamp)
                case .advanced:
                    VStack(spacing: 14) {
                        powerModeCard(lamp)
                        connectionCard(lamp)
                    }
                }
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))

            actionCard(lamp)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 28)
    }

    private var fallbackScrollOffsetMarker: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: LampScrollYPreferenceKey.self,
                value: proxy.frame(in: .global).minY
            )
        }
        .frame(height: 1)
    }

    private func expandedHeader(_ lamp: LampRecord) -> some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(lamp.name)
                        .font(.title2.bold())
                        .foregroundStyle(SHLampTheme.textPrimary)
                    Text(lamp.uiRoomName == "Unassigned" ? "SH Lamp" : lamp.uiRoomName)
                        .font(.caption)
                        .foregroundStyle(SHLampTheme.textSecondary)
                }
                Spacer()
                Button { showingRoutePicker = true } label: {
                    StatusPill(
                        text: lamp.route.label,
                        color: lamp.reachable ? SHLampTheme.success : SHLampTheme.offline
                    )
                }
                .buttonStyle(.plain)
            }

            LampHeroRingView(
                isOn: lamp.state.power,
                brightness: Int(draftBrightness),
                batteryPercent: lamp.state.batteryValid ? lamp.state.batteryPercent : nil,
                charging: lamp.state.batteryCharging == true
            )

            VStack(spacing: 3) {
                Text(modeName(brightness: Int(draftBrightness), isOn: lamp.state.power))
                    .font(.headline)
                    .foregroundStyle(SHLampTheme.textPrimary)
                Text(lamp.state.power ? "Brightness set to \(Int(draftBrightness))%" : "Tap power to turn the lamp on")
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textSecondary)
            }

            Button {
                model.setPower(lamp, on: !lamp.state.power)
            } label: {
                ZStack {
                    Circle()
                        .fill(lamp.state.power ? SHLampTheme.primary : Color.white.opacity(0.82))
                        .shadow(color: .black.opacity(0.09), radius: 10, y: 5)
                    Image(systemName: "power")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(lamp.state.power ? Color.white : SHLampTheme.primary)
                }
                .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)
            .disabled(!lamp.uiCanAttemptBasicControl)
            .accessibilityLabel(lamp.state.power ? "Turn lamp off" : "Turn lamp on")
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: lamp.state.power
                            ? [Color(hex: 0xE5FAFB), Color(hex: 0xFFF5DE)]
                            : [Color(hex: 0xEDF4F8), Color(hex: 0xF7F8FB)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(Color.white.opacity(0.10))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.7), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.055), radius: 16, y: 8)
    }

    private func compactHeader(_ lamp: LampRecord) -> some View {
        HStack(spacing: 10) {
            Button { model.setPower(lamp, on: !lamp.state.power) } label: {
                Image(systemName: "power")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(lamp.state.power ? SHLampTheme.primary : SHLampTheme.secondary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!lamp.uiCanAttemptBasicControl)

            VStack(alignment: .leading, spacing: 2) {
                Text(lamp.name)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text("\(Int(draftBrightness))% · \(shortRouteLabel(lamp.route))")
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textSecondary)
            }

            Spacer(minLength: 4)

            Button { showingRoutePicker = true } label: {
                Image(systemName: routeIcon(lamp.route))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(lamp.reachable ? SHLampTheme.success : SHLampTheme.offline)
                    .frame(width: 34, height: 34)
                    .background(SHLampTheme.surfaceSoft, in: Circle())
            }
            .buttonStyle(.plain)

            IPhoneBatteryIndicator(
                percent: lamp.state.batteryValid ? lamp.state.batteryPercent : nil,
                charging: lamp.state.batteryCharging == true,
                compact: true
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.72), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    private var featureTabs: some View {
        Picker("Feature section", selection: $selectedFeatureTab) {
            ForEach(LampFeatureTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(4)
        .background(SHLampTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(SHLampTheme.border, lineWidth: 1)
        )
        .accessibilityLabel("Lamp feature sections")
    }

    private func controlMetrics(_ lamp: LampRecord) -> some View {
        let timerRemaining = model.remainingTimerSeconds(for: lamp)
        return HStack(spacing: 10) {
            ControlMetric(
                title: "Brightness",
                value: "\(Int(draftBrightness))%",
                accent: SHLampTheme.warmDeep,
                surface: SHLampTheme.warmSoft
            )
            ControlMetric(
                title: "Connection",
                value: shortRouteLabel(lamp.route),
                accent: lamp.reachable ? SHLampTheme.success : SHLampTheme.warning,
                surface: lamp.reachable ? SHLampTheme.successSoft : SHLampTheme.warningSoft
            )
            ControlMetric(
                title: "Timer",
                value: timerRemaining > 0 ? formatTimer(timerRemaining) : "Off",
                accent: SHLampTheme.secondary,
                surface: SHLampTheme.secondarySoft
            )
        }
    }

    private func brightnessCard(_ lamp: LampRecord) -> some View {
        let maximum = lamp.state.powerMode == .maximumBackup ? 70 : 100
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Brightness").font(.headline)
                    Text(maximum == 70 ? "Maximum Backup limits output to 70%" : "Drag or use the minus and plus buttons")
                        .font(.caption)
                        .foregroundStyle(maximum == 70 ? SHLampTheme.warning : SHLampTheme.textSecondary)
                }
                Spacer()
                Text("\(Int(draftBrightness))%")
                    .font(.title3.bold())
                    .foregroundStyle(SHLampTheme.primary)
            }

            HStack(spacing: 12) {
                brightnessStepButton(systemName: "minus", amount: -5, lamp: lamp, maximum: maximum)

                Slider(value: $draftBrightness, in: 0...Double(maximum), step: 1) { editing in
                    brightnessDragging = editing
                    if !editing { model.setBrightness(lamp, value: Int(draftBrightness)) }
                }
                .onChange(of: draftBrightness) { _, newValue in
                    if brightnessDragging { model.streamBrightness(lamp, value: Int(newValue)) }
                }
                .tint(SHLampTheme.primary)
                .disabled(!lamp.uiCanAttemptBasicControl)

                brightnessStepButton(systemName: "plus", amount: 5, lamp: lamp, maximum: maximum)
            }

            HStack(spacing: 8) {
                ForEach(Array(Set([20, 60, maximum])).sorted(), id: \.self) { value in
                    let selected = abs(Int(draftBrightness) - value) <= 1
                    Button("\(value)%") {
                        draftBrightness = Double(value)
                        model.setBrightness(lamp, value: value)
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(selected ? Color.white : SHLampTheme.textPrimary)
                    .background(selected ? SHLampTheme.primary : SHLampTheme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(selected ? Color.clear : SHLampTheme.border, lineWidth: 1))
                    .disabled(!lamp.uiCanAttemptBasicControl)
                }
            }
        }
        .shGlassCard(padding: 18, radius: 24)
    }

    private func brightnessStepButton(systemName: String, amount: Int, lamp: LampRecord, maximum: Int) -> some View {
        Button {
            let next = min(maximum, max(0, Int(draftBrightness) + amount))
            draftBrightness = Double(next)
            model.setBrightness(lamp, value: next)
        } label: {
            Image(systemName: systemName)
                .font(.headline.bold())
                .foregroundStyle(SHLampTheme.textPrimary)
                .frame(width: 42, height: 42)
                .background(SHLampTheme.surfaceSoft, in: Circle())
                .overlay(Circle().stroke(SHLampTheme.border.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!lamp.uiCanAttemptBasicControl)
    }

    private func powerModeCard(_ lamp: LampRecord) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Battery Saving Modes").font(.headline)
                    Text(powerModeDescription(lamp.state.powerMode))
                        .font(.caption)
                        .foregroundStyle(SHLampTheme.textSecondary)
                }
                Spacer()
                StatusPill(text: lamp.state.powerMode.label, color: SHLampTheme.primary)
            }

            ForEach(LampPowerMode.allCases) { mode in
                Button {
                    if mode == .bleOnly || mode == .touchOnly { pendingPowerMode = mode }
                    else { model.setPowerMode(lamp, mode: mode) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: powerModeIcon(mode))
                            .foregroundStyle(lamp.state.powerMode == mode ? Color.white : SHLampTheme.primary)
                            .frame(width: 38, height: 38)
                            .background(lamp.state.powerMode == mode ? SHLampTheme.primary : SHLampTheme.primarySoft, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SHLampTheme.textPrimary)
                            Text(powerModeDescription(mode))
                                .font(.caption)
                                .foregroundStyle(SHLampTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: lamp.state.powerMode == mode ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(lamp.state.powerMode == mode ? SHLampTheme.success : SHLampTheme.textDisabled)
                    }
                    .padding(12)
                    .background(SHLampTheme.surfaceSoft, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!lamp.uiSupportsNearbyControls)
            }

            if !lamp.uiSupportsNearbyControls {
                Text("Battery Mode requires Bluetooth or local Wi-Fi. It is unavailable through remote-only control.")
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textSecondary)
            }
        }
        .shCard(padding: 18, radius: 24)
    }

    private func fadeAndTimerCard(_ lamp: LampRecord) -> some View {
        let timerRemaining = model.remainingTimerSeconds(for: lamp)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Fade speed").font(.headline)
                Text("How quickly brightness changes")
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textSecondary)
                Picker(
                    "Fade speed",
                    selection: Binding(
                        get: { lamp.state.fadeMode },
                        set: { model.setFade(lamp, mode: $0) }
                    )
                ) {
                    Text("Instant").tag(0)
                    Text("Fast").tag(1)
                    Text("Normal").tag(2)
                    Text("Slow").tag(3)
                }
                .pickerStyle(.segmented)
                .disabled(!lamp.uiSupportsFadeAndTimer)
            }

            Divider().overlay(SHLampTheme.divider)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Auto-off timer").font(.headline)
                        Text("Stored in the lamp, so it works without internet")
                            .font(.caption)
                            .foregroundStyle(SHLampTheme.textSecondary)
                    }
                    Spacer()
                    if timerRemaining > 0 {
                        Text(formatTimer(timerRemaining))
                            .font(.caption.bold())
                            .foregroundStyle(SHLampTheme.primary)
                    }
                }

                HStack(spacing: 7) {
                    ForEach([0, 15, 30, 60], id: \.self) { minutes in
                        let selected = timerPreset(for: timerRemaining) == minutes
                        Button(minutes == 0 ? "Off" : "\(minutes)m") {
                            model.setTimer(lamp, minutes: minutes)
                        }
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(selected ? Color.white : SHLampTheme.textPrimary)
                        .background(selected ? SHLampTheme.primary : Color.clear, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(selected ? Color.clear : SHLampTheme.border, lineWidth: 1))
                        .disabled(!lamp.uiSupportsFadeAndTimer)
                    }
                }
            }

            if !lamp.uiSupportsFadeAndTimer {
                Text("Fade and timer settings are unavailable while the lamp is unreachable.")
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textSecondary)
            }
        }
        .shCard(padding: 18, radius: 24)
    }

    private func connectionCard(_ lamp: LampRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connection").font(.headline)
                Spacer()
                Button { showingRoutePicker = true } label: {
                    StatusPill(text: lamp.route.label, color: lamp.reachable ? SHLampTheme.success : SHLampTheme.offline)
                }
                .buttonStyle(.plain)
            }

            Button { showingRoutePicker = true } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Route preference")
                            .font(.caption)
                            .foregroundStyle(SHLampTheme.textSecondary)
                        Text(lamp.routePreference.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SHLampTheme.textPrimary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(SHLampTheme.primary)
                }
                .padding(12)
                .background(SHLampTheme.surfaceSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            if let ssid = lamp.wifiSSID, !ssid.isEmpty { LabeledContent("Wi-Fi", value: ssid) }
            if let firmware = lamp.firmware, !firmware.isEmpty { LabeledContent("Firmware", value: firmware) }
            if lamp.state.runtimeState != .unknown {
                LabeledContent("Activity", value: lamp.state.runtimeState.label)
            }
            LabeledContent("Physical ID", value: lamp.id)
            if let cloudID = lamp.cloudLampId, !cloudID.isEmpty { LabeledContent("Cloud ID", value: cloudID) }
        }
        .font(.subheadline)
        .shCard(padding: 18, radius: 24)
    }

    private func actionCard(_ lamp: LampRecord) -> some View {
        VStack(spacing: 0) {
            ActionRow(
                title: "Blink lamp",
                subtitle: lamp.uiCanAttemptBasicControl ? "Identify this lamp" : "Lamp is currently unreachable",
                systemName: "light.beacon.max.fill",
                enabled: lamp.uiCanAttemptBasicControl
            ) { model.identify(lamp) }
            Divider().overlay(SHLampTheme.divider)
            ActionRow(title: "Lamp settings", subtitle: "Rename, remote access and Wi-Fi options", systemName: "gearshape") {
                showingSettings = true
            }
            Divider().overlay(SHLampTheme.divider)
            ActionRow(title: "Connection diagnostics", subtitle: "Check Bluetooth, Wi-Fi and cloud", systemName: "stethoscope") {
                model.showingDiagnostics = true
            }
        }
        .padding(.horizontal, 16)
        .background(SHLampTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(SHLampTheme.border, lineWidth: 1))
    }

    private func modeName(brightness: Int, isOn: Bool) -> String {
        guard isOn else { return "Lamp is off" }
        switch brightness {
        case 0...25: return "Night light"
        case 26...70: return "Relaxed light"
        default: return "Reading light"
        }
    }

    private func shortRouteLabel(_ route: LampConnectionRoute) -> String {
        switch route {
        case .wifi: return "Wi-Fi"
        case .bluetooth: return "BLE"
        case .cloud: return "Remote"
        case .offline: return "Offline"
        }
    }

    private func routeIcon(_ route: LampConnectionRoute) -> String {
        switch route {
        case .wifi: return "wifi"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .cloud: return "cloud.fill"
        case .offline: return "wifi.slash"
        }
    }

    private func powerModeIcon(_ mode: LampPowerMode) -> String {
        switch mode {
        case .balanced: return "scale.3d"
        case .maximumBackup: return "battery.100percent"
        case .bleOnly: return "dot.radiowaves.left.and.right"
        case .touchOnly: return "hand.tap"
        }
    }

    private func powerModeDescription(_ mode: LampPowerMode) -> String {
        switch mode {
        case .balanced: return "Wi-Fi, Bluetooth and remote control with full brightness."
        case .maximumBackup: return "Stronger power saving with brightness limited to 70%."
        case .bleOnly: return "Wi-Fi and remote turn off; nearby Bluetooth remains."
        case .touchOnly: return "All wireless control turns off; physical touch remains."
        }
    }

    private func powerModeWarning(_ mode: LampPowerMode) -> String {
        switch mode {
        case .bleOnly:
            return "Wi-Fi and remote access will become unavailable. Nearby Bluetooth control will remain available."
        case .touchOnly:
            return "All wireless connections will stop. Control will be physical-touch only until the lamp is restarted."
        default:
            return ""
        }
    }

    private func timerPreset(for seconds: Int64) -> Int {
        // Allow a small transport/clock tolerance around the preset boundary.
        // Without this, a freshly-set 15 minute timer can render as 15:01 for
        // one frame and incorrectly highlight the 30m button.
        switch seconds {
        case ...0: return 0
        case ...905: return 15
        case ...1805: return 30
        default: return 60
        }
    }

    private func formatTimer(_ seconds: Int64) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02lld:%02lld", minutes, remainder)
    }
}

private enum LampFeatureTab: String, CaseIterable, Identifiable {
    case useful
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .useful: return "Useful Features"
        case .advanced: return "Advanced Features"
        }
    }
}

private struct LampScrollYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct IPhoneBatteryIndicator: View {
    let percent: Int?
    let charging: Bool
    let compact: Bool

    private var level: CGFloat { CGFloat(min(max(percent ?? 0, 0), 100)) / 100 }
    private var fillColor: Color {
        guard let percent else { return SHLampTheme.textDisabled }
        if charging { return SHLampTheme.success }
        if percent <= 20 { return SHLampTheme.error }
        return SHLampTheme.textPrimary
    }

    var body: some View {
        HStack(spacing: compact ? 5 : 8) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: compact ? 4 : 5, style: .continuous)
                    .stroke(SHLampTheme.textPrimary.opacity(0.72), lineWidth: compact ? 1.3 : 1.6)
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: compact ? 2.5 : 3.5, style: .continuous)
                        .fill(fillColor)
                        .frame(width: max(0, (geometry.size.width - 5) * level))
                        .padding(2.5)
                }
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: compact ? 7 : 9, weight: .bold))
                        .foregroundStyle(level > 0.45 ? Color.white : SHLampTheme.success)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: compact ? 27 : 38, height: compact ? 13 : 18)
            .overlay(alignment: .trailing) {
                Capsule()
                    .fill(SHLampTheme.textPrimary.opacity(0.72))
                    .frame(width: compact ? 2.5 : 3, height: compact ? 6 : 8)
                    .offset(x: compact ? 3.5 : 4)
            }

            Text(percent.map { "\($0)%" } ?? "--")
                .font(compact ? .caption2.bold() : .subheadline.bold())
                .foregroundStyle(fillColor)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percent.map { "Battery \($0) percent" } ?? "Battery unavailable")
    }
}

private struct ControlMetric: View {
    let title: String
    let value: String
    let accent: Color
    let surface: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(SHLampTheme.textSecondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ActionRow: View {
    let title: String
    let subtitle: String
    let systemName: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(SHLampTheme.primarySoft)
                    Image(systemName: systemName)
                        .foregroundStyle(SHLampTheme.primary)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SHLampTheme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(SHLampTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textDisabled)
            }
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }
}

private struct LampHeroRingView: View {
    let isOn: Bool
    let brightness: Int
    let batteryPercent: Int?
    let charging: Bool

    @State private var chargingRotation = 90.0

    private var fraction: Double {
        Double(min(max(batteryPercent ?? 0, 0), 100)) / 100
    }

    private var ringColor: Color {
        guard let batteryPercent else { return SHLampTheme.offline.opacity(0.55) }
        if charging { return SHLampTheme.success }
        if batteryPercent <= 20 { return SHLampTheme.error }
        return SHLampTheme.primary
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.125, to: 0.875)
                .stroke(
                    SHLampTheme.border.opacity(0.62),
                    style: StrokeStyle(lineWidth: 15, lineCap: .round)
                )
                .rotationEffect(.degrees(90))
                .frame(width: 216, height: 216)

            Circle()
                .trim(from: 0.125, to: 0.125 + 0.75 * fraction)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 15, lineCap: .round)
                )
                .rotationEffect(.degrees(90))
                .frame(width: 216, height: 216)
                .animation(.easeInOut(duration: 0.45), value: fraction)

            if charging {
                Circle()
                    .trim(from: 0.125, to: 0.18)
                    .stroke(
                        Color.white.opacity(0.82),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(chargingRotation))
                    .frame(width: 216, height: 216)
            }

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    if charging {
                        Image(systemName: "bolt.fill")
                            .font(.caption.bold())
                            .foregroundStyle(SHLampTheme.success)
                    }
                    Text(batteryPercent.map { "\($0)%" } ?? "--")
                        .font(.headline.bold())
                        .foregroundStyle(ringColor)
                }
                .padding(.top, 2)

                AnimatedLampArtwork(isOn: isOn, brightness: brightness)
                    .frame(width: 150, height: 150)
            }
        }
        .frame(height: 226)
        .task(id: charging) {
            chargingRotation = 90
            guard charging else { return }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                chargingRotation = 450
            }
        }
    }
}

private struct AnimatedLampArtwork: View {
    let isOn: Bool
    let brightness: Int

    private var intensity: CGFloat {
        isOn ? max(0.12, CGFloat(brightness) / 100) : 0
    }

    private var opacityIntensity: Double { Double(intensity) }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            SHLampTheme.warm.opacity(0.34 * opacityIntensity),
                            SHLampTheme.warmSoft.opacity(0.20 * opacityIntensity),
                            .clear
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 75
                    )
                )
                .frame(width: 126 + 24 * intensity, height: 126 + 24 * intensity)
                .blur(radius: 5 + 5 * intensity)

            if isOn {
                LampLightConeShape()
                    .fill(
                        LinearGradient(
                            colors: [SHLampTheme.warm.opacity(0.26 * opacityIntensity), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 90 + 18 * intensity, height: 92)
                    .offset(y: 33)
                    .blur(radius: 3)
            }

            VStack(spacing: 0) {
                LampShadeShape()
                    .fill(
                        LinearGradient(
                            colors: isOn
                                ? [Color.white, SHLampTheme.warmSoft, Color(hex: 0xF4C774)]
                                : [Color(hex: 0xF6F8FA), Color(hex: 0xCED6DF)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 92, height: 58)
                    .overlay(
                        LampShadeShape()
                            .stroke(isOn ? SHLampTheme.warmDeep.opacity(0.45) : SHLampTheme.textDisabled.opacity(0.7), lineWidth: 1.2)
                    )
                    .shadow(color: isOn ? SHLampTheme.warm.opacity(0.28 * opacityIntensity) : .black.opacity(0.05), radius: 8, y: 3)

                Capsule()
                    .fill(isOn ? Color(hex: 0x9A6A24) : Color(hex: 0x7B8794))
                    .frame(width: 6, height: 43)
                    .offset(y: -2)

                Capsule()
                    .fill(isOn ? Color(hex: 0x9A6A24) : Color(hex: 0x7B8794))
                    .frame(width: 52, height: 11)
                    .offset(y: -4)
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
            }

            if isOn {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(SHLampTheme.warm.opacity(0.18 + Double(index) * 0.025))
                        .frame(width: 4 + CGFloat(index), height: 4 + CGFloat(index))
                        .offset(x: CGFloat(index - 2) * 21, y: -55 + CGFloat(index % 2) * 10)
                }
            }
        }
        .animation(.easeInOut(duration: 0.38), value: isOn)
        .animation(.easeInOut(duration: 0.28), value: brightness)
    }
}

private struct LampShadeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.20, y: rect.height * 0.18))
        path.addQuadCurve(
            to: CGPoint(x: rect.width * 0.80, y: rect.height * 0.18),
            control: CGPoint(x: rect.width * 0.50, y: rect.height * 0.02)
        )
        path.addLine(to: CGPoint(x: rect.width * 0.93, y: rect.height * 0.86))
        path.addQuadCurve(
            to: CGPoint(x: rect.width * 0.07, y: rect.height * 0.86),
            control: CGPoint(x: rect.width * 0.50, y: rect.height * 1.02)
        )
        path.closeSubpath()
        return path
    }
}

private struct LampLightConeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.28, y: 0))
        path.addLine(to: CGPoint(x: rect.width * 0.72, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
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
    @State private var showingRemoteAccess = false

    private var lamp: LampRecord? {
        model.lamps.first { $0.id == lampID || $0.canonicalID == lampID }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 14) {
                if let lamp {
                    settingsSection("Lamp details") {
                        VStack(spacing: 12) {
                            TextField("Lamp name", text: $name)
                                .textFieldStyle(.roundedBorder)
                            Picker("Room", selection: $roomID) {
                                Text("Unassigned").tag("")
                                ForEach(model.dashboard.homes.flatMap(\.rooms)) { room in
                                    Text(room.name).tag(room.id)
                                }
                            }
                            .disabled(!lamp.cloudClaimed)
                            if !lamp.cloudClaimed {
                                Text("Link this lamp to your account before assigning a room.")
                                    .font(.caption)
                                    .foregroundStyle(SHLampTheme.textSecondary)
                            }
                            LabeledContent("Lamp ID", value: lamp.canonicalID)
                            LabeledContent("Connection", value: lamp.route.label)
                        }
                    }

                    settingsSection("Nearby actions") {
                        VStack(spacing: 0) {
                            settingsAction("Blink lamp", enabled: lamp.uiCanAttemptBasicControl) { model.identify(lamp) }
                            Divider()
                            settingsAction("Read saved Wi-Fi networks", enabled: (model.ble.isReady && (lamp.bleIdentifier == model.ble.connectedPeripheralID || lamp.route == .bluetooth))) { model.ble.requestSavedWiFiNetworks() }
                            Divider()
                            settingsAction("Read authorized controllers", enabled: (model.ble.isReady && (lamp.bleIdentifier == model.ble.connectedPeripheralID || lamp.route == .bluetooth))) { model.ble.requestControllers() }
                        }
                    }

                    if (model.ble.isReady && (lamp.bleIdentifier == model.ble.connectedPeripheralID || lamp.route == .bluetooth)), !model.savedWiFiNetworks.isEmpty {
                        settingsSection("Saved Wi-Fi") {
                            VStack(spacing: 0) {
                                ForEach(model.savedWiFiNetworks.indices, id: \.self) { index in
                                    let network = model.savedWiFiNetworks[index]
                                    HStack {
                                        Text(network.ssid)
                                        Spacer()
                                        if network.active {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(SHLampTheme.success)
                                        }
                                    }
                                    .padding(.vertical, 10)
                                    if index < model.savedWiFiNetworks.count - 1 { Divider() }
                                }
                            }
                        }
                    }


                    settingsSection("Remote access") {
                        VStack(alignment: .leading, spacing: 12) {
                            if lamp.cloudClaimed, let cloudID = lamp.cloudLampId, !cloudID.isEmpty {
                                HStack {
                                    Label("Connected", systemImage: "checkmark.icloud.fill")
                                        .foregroundStyle(SHLampTheme.success)
                                    Spacer()
                                }
                                LabeledContent("Cloud ID", value: cloudID)
                                Text("This lamp can be controlled away from home when it is online.")
                                    .font(.caption)
                                    .foregroundStyle(SHLampTheme.textSecondary)
                            } else {
                                Text("Link this same physical lamp to your account for control away from home.")
                                    .font(.subheadline)
                                    .foregroundStyle(SHLampTheme.textSecondary)
                                Button {
                                    showingRemoteAccess = true
                                } label: {
                                    Label("Add Remote Access", systemImage: "cloud.badge.plus")
                                }
                                .buttonStyle(.bordered)
                                .tint(SHLampTheme.primary)
                            }
                        }
                    }

                    settingsSection("Ownership") {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Release lamp from account", role: .destructive) {
                                confirmRelease = true
                            }
                            .disabled(!lamp.cloudClaimed)
                            if !lamp.cloudClaimed {
                                Text("This nearby lamp is not currently linked to your account.")
                                    .font(.caption)
                                    .foregroundStyle(SHLampTheme.textSecondary)
                            }
                            if !releasedCode.isEmpty {
                                Text("New claim code: \(releasedCode)")
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if !model.errorMessage.isEmpty {
                    NoticeCard(text: model.errorMessage, error: true)
                }
            }
            .padding(18)
        }
        .background(SHLampTheme.background.ignoresSafeArea())
        .navigationTitle("Lamp Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let lamp else { return }
                    Task {
                        if await model.saveSettings(
                            lamp,
                            name: name,
                            roomID: roomID.isEmpty ? nil : roomID
                        ) {
                            dismiss()
                        }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            }
        }
        .sheet(isPresented: $showingRemoteAccess) {
            NavigationStack { RemoteAccessSheet(lampID: lampID) }
        }
        .onAppear {
            name = lamp?.name ?? ""
            roomID = lamp?.roomId ?? ""
        }
        .alert("Release this lamp?", isPresented: $confirmRelease) {
            Button("Cancel", role: .cancel) {}
            Button("Release", role: .destructive) {
                guard let lamp else { return }
                Task {
                    if let released = await model.releaseLamp(lamp) {
                        releasedCode = released.newClaimCode
                    }
                }
            }
        } message: {
            Text("The lamp will be removed from this account. Save the new claim code before pairing it again.")
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SHLampTheme.textSecondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .shCard(padding: 16, radius: 22)
        }
    }

    private func settingsAction(
        _ title: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .foregroundStyle(enabled ? SHLampTheme.primary : SHLampTheme.textDisabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11)
            .disabled(!enabled)
    }
}


private struct RemoteAccessSheet: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let lampID: String

    @State private var cloudLampID = ""
    @State private var claimCode = ""
    @State private var showingScanner = false
    @State private var localError = ""

    private var lamp: LampRecord? {
        model.lamps.first { $0.id == lampID || $0.canonicalID == lampID }
    }

    private var valid: Bool {
        cloudLampID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .range(of: "^SH-[A-Z0-9]{4,16}$", options: .regularExpression) != nil &&
        !claimCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Enable Remote Access")
                    .font(.title2.bold())
                Text("Scan the code supplied with the lamp or enter its Cloud Lamp ID and claim code. This updates the existing device; it does not create another lamp.")
                    .font(.subheadline)
                    .foregroundStyle(SHLampTheme.textSecondary)

                Button {
                    showingScanner = true
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(PrimaryActionButtonStyle())

                VStack(alignment: .leading, spacing: 7) {
                    Text("Cloud Lamp ID").font(.caption.weight(.semibold)).foregroundStyle(SHLampTheme.textSecondary)
                    TextField("SH-0727182134", text: $cloudLampID)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Claim code").font(.caption.weight(.semibold)).foregroundStyle(SHLampTheme.textSecondary)
                    TextField("Claim code", text: $claimCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }

                if !localError.isEmpty { NoticeCard(text: localError, error: true) }
                if !model.errorMessage.isEmpty { NoticeCard(text: model.errorMessage, error: true) }

                Button {
                    Task {
                        guard let lamp else { return }
                        let success = await model.claimLamp(
                            lampID: cloudLampID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                            claimCode: claimCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                            displayName: lamp.name,
                            roomID: lamp.roomId,
                            localLampID: lamp.id
                        )
                        if success { dismiss() }
                    }
                } label: {
                    HStack {
                        if model.busy { ProgressView().tint(.white) }
                        Text(model.busy ? "Linking…" : "Add Remote Access")
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!valid || model.busy)
            }
            .padding(18)
        }
        .background(SHLampTheme.background.ignoresSafeArea())
        .navigationTitle("Remote Access")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Close") { dismiss() } }
        .sheet(isPresented: $showingScanner) {
            NavigationStack {
                QRScannerView { raw in
                    do {
                        let parsed = try LampQRParser.parse(raw)
                        cloudLampID = parsed.lampId
                        claimCode = parsed.claimCode
                        localError = ""
                    } catch {
                        localError = error.localizedDescription
                    }
                    showingScanner = false
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
}
