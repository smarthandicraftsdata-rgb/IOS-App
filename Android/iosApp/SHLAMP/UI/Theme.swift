import SwiftUI

enum SHLampTheme {
    static let background = Color(hex: 0xF3F6FA)
    static let backgroundTop = Color(hex: 0xE8F7FA)
    static let surface = Color.white
    static let surfaceSoft = Color(hex: 0xEEF3F7)
    static let border = Color(hex: 0xDCE4EB)
    static let textPrimary = Color(hex: 0x182230)
    static let textSecondary = Color(hex: 0x667085)
    static let primary = Color(hex: 0x078CA4)
    static let primarySoft = Color(hex: 0xDDF5F7)
    static let secondary = Color(hex: 0x6E63E8)
    static let secondarySoft = Color(hex: 0xEFEDFF)
    static let warm = Color(hex: 0xFFB74D)
    static let warmDeep = Color(hex: 0xE88E18)
    static let warmSoft = Color(hex: 0xFFF3D8)
    static let success = Color(hex: 0x24A36F)
    static let successSoft = Color(hex: 0xE1F5EC)
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
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(SHLampTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(SHLampTheme.border.opacity(0.75), lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 12, y: 5)
    }
}

extension View {
    func shCard(padding: CGFloat = 18) -> some View { modifier(CardModifier(padding: padding)) }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

struct BrandHeader: View {
    var subtitle: String = "Smart lighting, simply connected"
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(SHLampTheme.primary)
                Image(systemName: "lightbulb.led.fill").foregroundStyle(.white).font(.title2)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("SH Lamp").font(.title2.bold()).foregroundStyle(SHLampTheme.textPrimary)
                Text(subtitle).font(.caption).foregroundStyle(SHLampTheme.textSecondary)
            }
            Spacer()
        }
    }
}
