import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connection Check")
                        .font(.largeTitle.bold())
                        .foregroundStyle(SHLampTheme.textPrimary)
                    Text("One working route is enough to control a lamp.")
                        .font(.subheadline)
                        .foregroundStyle(SHLampTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                summaryCard

                SectionHeader("Phone and account")
                DiagnosticCard(title: "Cloud account", detail: model.cloudStatus, ok: model.currentUser != nil, systemName: "person.crop.circle")
                DiagnosticCard(title: "Live cloud", detail: model.cloudStatus, ok: model.cloudConnected, systemName: "cloud")
                DiagnosticCard(title: "Bluetooth", detail: model.bluetoothStatus, ok: model.ble.isReady || !model.nearbyLamps.isEmpty, systemName: "antenna.radiowaves.left.and.right")
                DiagnosticCard(title: "Local Wi-Fi discovery", detail: model.localNetworkStatus, ok: model.lamps.contains { $0.localHost != nil }, systemName: "wifi")

                SectionHeader("Lamps")
                if model.lamps.isEmpty {
                    NoticeCard(text: "No lamps are registered.", error: false)
                } else {
                    ForEach(model.lamps) { lamp in
                        lampDiagnosticCard(lamp)
                    }
                }

                Button {
                    model.startConnections()
                    model.refresh()
                } label: {
                    Label("Run again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryActionButtonStyle())

                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(SHLampTheme.primary)
                    .frame(maxWidth: .infinity)
            }
            .padding(18)
        }
        .background(SHLampTheme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
    }

    private var summaryCard: some View {
        let working = model.lamps.filter(\.reachable).count
        let hasNoLamps = model.lamps.isEmpty
        let allGood = !hasNoLamps && working == model.lamps.count
        let accent = hasNoLamps ? SHLampTheme.primary : (allGood ? SHLampTheme.success : SHLampTheme.warning)
        let surface = hasNoLamps ? SHLampTheme.primarySoft : (allGood ? SHLampTheme.successSoft : SHLampTheme.warningSoft)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.78))
                    Image(systemName: hasNoLamps ? "lightbulb.led" : (allGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                        .font(.title2)
                        .foregroundStyle(accent)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hasNoLamps ? "No lamps to check" : (allGood ? "Connections look ready" : "Some routes need attention"))
                        .font(.title3.bold())
                        .foregroundStyle(SHLampTheme.textPrimary)
                    Text(hasNoLamps ? "Add a lamp to begin checking." : "\(working) of \(model.lamps.count) lamps currently have a working route.")
                        .font(.subheadline)
                        .foregroundStyle(SHLampTheme.textSecondary)
                }
            }
            Text("Bluetooth, local Wi-Fi and cloud are backup routes. A lamp does not need all three at the same time.")
                .font(.caption)
                .foregroundStyle(SHLampTheme.textSecondary)
        }
        .padding(18)
        .background(surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(accent.opacity(0.2), lineWidth: 1))
    }

    private func lampDiagnosticCard(_ lamp: LampRecord) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(lamp.name).font(.headline).foregroundStyle(SHLampTheme.textPrimary)
                    Text(lamp.canonicalID).font(.caption.monospaced()).foregroundStyle(SHLampTheme.textSecondary)
                }
                Spacer()
                StatusPill(text: lamp.route.label, color: lamp.reachable ? SHLampTheme.success : SHLampTheme.error)
            }

            HStack(spacing: 8) {
                routeMiniStatus("BLE", active: lamp.route == .bluetooth || lamp.bleIdentifier != nil)
                routeMiniStatus("Wi-Fi", active: lamp.route == .wifi || lamp.localHost != nil)
                routeMiniStatus("Cloud", active: lamp.route == .cloud || lamp.online)
            }

            Text(diagnosticText(lamp))
                .font(.caption)
                .foregroundStyle(SHLampTheme.textSecondary)
        }
        .shCard(padding: 15, radius: 21)
    }

    private func routeMiniStatus(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(active ? SHLampTheme.success : SHLampTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(active ? SHLampTheme.successSoft : SHLampTheme.surfaceSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func diagnosticText(_ lamp: LampRecord) -> String {
        var parts = [lamp.reachable ? "Reachable" : "Offline"]
        if let host = lamp.localHost { parts.append("Local: \(host)") }
        if lamp.online { parts.append("Cloud online") }
        if lamp.state.batteryValid, let battery = lamp.state.batteryPercent { parts.append("Battery: \(battery)%") }
        return parts.joined(separator: " • ")
    }
}

private struct DiagnosticCard: View {
    let title: String
    let detail: String
    let ok: Bool
    let systemName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ok ? SHLampTheme.successSoft : SHLampTheme.warningSoft)
                Image(systemName: systemName)
                    .foregroundStyle(ok ? SHLampTheme.success : SHLampTheme.warning)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(SHLampTheme.textPrimary)
                Text(detail).font(.caption).foregroundStyle(SHLampTheme.textSecondary)
            }
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? SHLampTheme.success : SHLampTheme.warning)
        }
        .shCard(padding: 14, radius: 20)
    }
}
