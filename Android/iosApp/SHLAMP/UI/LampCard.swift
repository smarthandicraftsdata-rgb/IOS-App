import SwiftUI

struct LampCard: View {
    @EnvironmentObject private var model: AppViewModel
    let lamp: LampRecord

    private var routeColor: Color {
        switch lamp.route {
        case .bluetooth, .wifi: return SHLampTheme.success
        case .cloud: return SHLampTheme.primary
        case .offline: return SHLampTheme.offline
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                ZStack {
                    Circle().fill(lamp.state.power ? SHLampTheme.warmSoft : SHLampTheme.surfaceSoft)
                    Image(systemName: lamp.state.power ? "lightbulb.led.fill" : "lightbulb.led")
                        .font(.title2)
                        .foregroundStyle(lamp.state.power ? SHLampTheme.warmDeep : SHLampTheme.textSecondary)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(lamp.name).font(.headline).foregroundStyle(SHLampTheme.textPrimary).lineLimit(1)
                    Text(lamp.roomName ?? lamp.id).font(.caption).foregroundStyle(SHLampTheme.textSecondary).lineLimit(1)
                }
                Spacer()
                Toggle("Power", isOn: Binding(
                    get: { lamp.state.power },
                    set: { model.setPower(lamp, on: $0) }
                ))
                .labelsHidden().tint(SHLampTheme.primary)
            }

            HStack {
                StatusPill(text: lamp.route.label, color: routeColor)
                if let battery = lamp.state.batteryPercent, lamp.state.batteryValid {
                    Label("\(battery)%", systemImage: lamp.state.batteryCharging == true ? "battery.100percent.bolt" : batterySymbol(battery))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(battery < 20 ? SHLampTheme.error : SHLampTheme.textSecondary)
                }
                Spacer()
                Text("\(lamp.state.brightness)%").font(.caption.bold()).foregroundStyle(SHLampTheme.textSecondary)
            }

            ProgressView(value: Double(lamp.state.brightness), total: 100)
                .tint(lamp.state.power ? SHLampTheme.warmDeep : SHLampTheme.offline)
        }
        .shCard(padding: 16)
    }

    private func batterySymbol(_ value: Int) -> String {
        switch value {
        case 0..<15: return "battery.0percent"
        case 15..<40: return "battery.25percent"
        case 40..<65: return "battery.50percent"
        case 65..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
