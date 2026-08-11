import SwiftUI

struct LampCard: View {
    let lamp: LampRecord

    private var routeColor: Color {
        switch lamp.route {
        case .bluetooth, .wifi: return SHLampTheme.success
        case .cloud: return SHLampTheme.secondary
        case .offline: return SHLampTheme.offline
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MiniLampGlyph(isOn: lamp.state.power)
                    .frame(width: 40, height: 40)
                Spacer()
                if let battery = lamp.state.batteryPercent, lamp.state.batteryValid {
                    CompactBatteryIndicator(
                        percent: battery,
                        charging: lamp.state.batteryCharging == true
                    )
                }
                StatusPill(text: routeLabel, color: routeColor)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text(lamp.name)
                    .font(.headline)
                    .foregroundStyle(SHLampTheme.textPrimary)
                    .lineLimit(1)
                Text(lamp.uiRoomName == "Unassigned" ? "SH Lamp" : lamp.uiRoomName)
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textSecondary)
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(SHLampTheme.surfaceSoft)
                    Capsule()
                        .fill(lamp.state.power ? SHLampTheme.warm : SHLampTheme.offline)
                        .frame(width: proxy.size.width * CGFloat(lamp.state.brightness) / 100)
                }
            }
            .frame(height: 5)
            .padding(.trailing, 58)

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lamp.state.power ? "On" : "Off")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(lamp.state.power ? SHLampTheme.primary : SHLampTheme.textSecondary)
                    Text("\(lamp.state.brightness)% brightness")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(lamp.state.power ? SHLampTheme.warmDeep : SHLampTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 58)
            .frame(minHeight: 46, alignment: .leading)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 204, maxHeight: 220, alignment: .topLeading)
        .aspectRatio(1, contentMode: .fit)
        .background(
            lamp.state.power ? SHLampTheme.surfaceTint : SHLampTheme.surface,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(lamp.state.power ? SHLampTheme.primary.opacity(0.24) : SHLampTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(lamp.state.power ? 0.055 : 0.025), radius: 8, y: 4)
    }

    private var routeLabel: String {
        switch lamp.route {
        case .wifi: return "Wi-Fi"
        case .bluetooth: return "BLE"
        case .cloud: return "Remote"
        case .offline: return "Offline"
        }
    }
}


struct LampGridCell: View {
    @EnvironmentObject private var model: AppViewModel
    let lamp: LampRecord

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationLink(value: lamp.id) {
                LampCard(lamp: lamp)
            }
            .buttonStyle(.plain)

            Button {
                model.setPower(lamp, on: !lamp.state.power)
            } label: {
                ZStack {
                    Circle()
                        .fill(lamp.state.power ? SHLampTheme.primary : SHLampTheme.surfaceSoft)
                    Image(systemName: "power")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(lamp.state.power ? Color.white : SHLampTheme.textPrimary)
                }
                .frame(width: 42, height: 42)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!lamp.uiCanAttemptBasicControl)
            .opacity(lamp.uiCanAttemptBasicControl ? 1 : 0.55)
            .padding(13)
            .accessibilityLabel(lamp.state.power ? "Turn off \(lamp.name)" : "Turn on \(lamp.name)")
        }
    }
}

struct MiniLampGlyph: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle().fill(isOn ? SHLampTheme.warmSoft : SHLampTheme.surfaceSoft)
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? SHLampTheme.warm : SHLampTheme.textDisabled)
                    .frame(width: 18, height: 20)
                Capsule()
                    .fill(isOn ? SHLampTheme.warmDeep : SHLampTheme.textDisabled)
                    .frame(width: 12, height: 3)
                Capsule()
                    .fill(isOn ? SHLampTheme.warmDeep : SHLampTheme.textDisabled)
                    .frame(width: 8, height: 3)
            }
        }
    }
}

struct CompactBatteryIndicator: View {
    let percent: Int
    let charging: Bool

    private var accent: Color {
        if charging { return SHLampTheme.success }
        if percent <= 20 { return SHLampTheme.error }
        return SHLampTheme.textSecondary
    }

    var body: some View {
        HStack(spacing: 3) {
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
            }
            Text("\(percent)%")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(accent.opacity(0.1), in: Capsule())
    }
}
