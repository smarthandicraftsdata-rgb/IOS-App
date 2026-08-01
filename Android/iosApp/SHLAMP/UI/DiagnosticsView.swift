import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Connection check") {
                check("Cloud account", detail: model.cloudStatus, ok: model.currentUser != nil)
                check("Live cloud", detail: model.cloudStatus, ok: model.cloudConnected)
                check("Bluetooth", detail: model.bluetoothStatus, ok: model.ble.isReady || !model.nearbyLamps.isEmpty)
                check("Local Wi-Fi discovery", detail: model.localNetworkStatus, ok: model.lamps.contains { $0.localHost != nil })
            }
            Section("Lamps") {
                if model.lamps.isEmpty { Text("No lamps are registered.") }
                ForEach(model.lamps) { lamp in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(lamp.name).font(.headline); Spacer(); StatusPill(text: lamp.route.label, color: lamp.reachable ? SHLampTheme.success : SHLampTheme.error) }
                        Text(lamp.canonicalID).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(diagnosticText(lamp)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
            Section {
                Button("Run again") { model.startConnections(); model.refresh() }
                Button("Close") { dismiss() }
            }
        }
        .navigationTitle("Connection Check")
        .toolbar { Button("Done") { dismiss() } }
    }

    private func check(_ title: String, detail: String, ok: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? SHLampTheme.success : SHLampTheme.error)
            VStack(alignment: .leading) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func diagnosticText(_ lamp: LampRecord) -> String {
        var parts = [lamp.reachable ? "Reachable" : "Offline"]
        if let host = lamp.localHost { parts.append("Local: \(host)") }
        if lamp.online { parts.append("Cloud online") }
        if let battery = lamp.state.batteryPercent { parts.append("Battery: \(battery)%") }
        return parts.joined(separator: " • ")
    }
}
