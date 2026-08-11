import SwiftUI

enum SHLampTheme {
    static let background = Color(hex: 0xF3F6FA)
    static let backgroundTop = Color(hex: 0xE7F7FA)
    static let surface = Color.white
    static let surfaceRaised = Color(hex: 0xFBFDFE)
    static let surfaceSoft = Color(hex: 0xEEF3F7)
    static let surfaceTint = Color(hex: 0xF2FBFC)
    static let border = Color(hex: 0xDCE4EB)
    static let divider = Color(hex: 0xE9EEF3)
    static let textPrimary = Color(hex: 0x182230)
    static let textSecondary = Color(hex: 0x667085)
    static let textDisabled = Color(hex: 0xAAB3C0)
    static let primary = Color(hex: 0x078CA4)
    static let primaryDeep = Color(hex: 0x056D80)
    static let primarySoft = Color(hex: 0xDDF5F7)
    static let secondary = Color(hex: 0x6E63E8)
    static let secondarySoft = Color(hex: 0xEFEDFF)
    static let warm = Color(hex: 0xFFB74D)
    static let warmDeep = Color(hex: 0xE88E18)
    static let warmSoft = Color(hex: 0xFFF3D8)
    static let success = Color(hex: 0x24A36F)
    static let successSoft = Color(hex: 0xE1F5EC)
    static let warning = Color(hex: 0xD58B20)
    static let warningSoft = Color(hex: 0xFFF4D9)
    static let info = Color(hex: 0x3974D7)
    static let infoSoft = Color(hex: 0xE8F0FF)
    static let error = Color(hex: 0xD94B55)
    static let errorSoft = Color(hex: 0xFFE9EB)
    static let offline = Color(hex: 0x98A2B3)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 18
    var radius: CGFloat = 24
    var glass = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                if glass {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(Color.white.opacity(0.48))
                        )
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(SHLampTheme.surface)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(glass ? Color.white.opacity(0.72) : SHLampTheme.border.opacity(0.82), lineWidth: 1)
            )
            .shadow(color: .black.opacity(glass ? 0.055 : 0.045), radius: glass ? 16 : 12, y: glass ? 8 : 5)
    }
}

extension View {
    func shCard(padding: CGFloat = 18, radius: CGFloat = 24) -> some View {
        modifier(CardModifier(padding: padding, radius: radius, glass: false))
    }

    func shGlassCard(padding: CGFloat = 18, radius: CGFloat = 26) -> some View {
        modifier(CardModifier(padding: padding, radius: radius, glass: true))
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct BrandLogoView: View {
    var size: CGFloat = 54
    var tint: Color? = SHLampTheme.textPrimary

    var body: some View {
        Image("BrandLogo")
            .resizable()
            .renderingMode(tint == nil ? .original : .template)
            .scaledToFit()
            .foregroundStyle(tint ?? Color.primary)
            .frame(width: size, height: size)
            .accessibilityLabel("Smart Handicrafts logo")
    }
}

struct BrandHeader: View {
    var subtitle: String = "Smart Handicrafts® connected lighting"

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.white.opacity(0.72))
                BrandLogoView(size: 35)
            }
            .frame(width: 52, height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("Smart Handicrafts®")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(SHLampTheme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var action: String? = nil
    var onAction: (() -> Void)? = nil

    init(
        _ title: String,
        subtitle: String? = nil,
        action: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.onAction = onAction
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(SHLampTheme.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(SHLampTheme.textSecondary)
                }
            }
            Spacer()
            if let action, let onAction {
                Button(action: onAction) { Text(action) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SHLampTheme.primary)
            }
        }
    }
}

struct RoundIconButton: View {
    let systemName: String
    var filled = false
    var loading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(filled ? SHLampTheme.primary : SHLampTheme.surface)
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(filled ? Color.white : SHLampTheme.textPrimary)
                }
            }
            .frame(width: 42, height: 42)
            .overlay(Circle().stroke(filled ? Color.clear : SHLampTheme.border.opacity(0.8), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var color: Color = SHLampTheme.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(color.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
    }
}

struct NoticeCard: View {
    let text: String
    let error: Bool

    var body: some View {
        Label(text, systemImage: error ? "exclamationmark.triangle.fill" : "info.circle.fill")
            .font(.footnote)
            .foregroundStyle(error ? SHLampTheme.error : SHLampTheme.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(error ? SHLampTheme.errorSoft : SHLampTheme.primarySoft)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension LampRecord {
    var uiRoomName: String {
        roomName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unassigned"
    }

    /// Power and brightness can be attempted over BLE, local Wi-Fi or the claimed cloud route.
    var uiCanAttemptBasicControl: Bool {
        reachable || cloudClaimed
    }

    /// Fade and timer commands are implemented only for nearby BLE/local-Wi-Fi routes.
    var uiSupportsNearbyControls: Bool {
        route == .bluetooth || route == .wifi
    }

    /// Fade and timer are supported over BLE, local Wi-Fi and the claimed
    /// cloud route. Battery/power-mode changes remain nearby-only because the
    /// current cloud firmware protocol does not expose power-mode commands.
    var uiSupportsFadeAndTimer: Bool {
        uiCanAttemptBasicControl
    }
}

extension Bundle {
    var shLampVersionLabel: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "SH Lamp iOS \(version) (\(build))"
    }
}
