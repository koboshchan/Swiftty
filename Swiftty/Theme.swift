import SwiftUI

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

    static let swCanvas = Color(hex: 0x030303)
    static let swSidebar = Color(hex: 0x080808)
    static let swChrome = Color(hex: 0x0B0B0B)
    static let swPanel = Color(hex: 0x0D0D0D)
    static let swRaised = Color(hex: 0x191919)
    static let swLine = Color(hex: 0x202020)
    static let swText = Color(hex: 0xD6D6D6)
    static let swMuted = Color(hex: 0x8A8A8A)
    static let swDim = Color(hex: 0x5C5C5C)
    static let swMint = Color(hex: 0xA8F56C)
    static let swBlue = Color(hex: 0x27C7F2)
    static let swAmber = Color(hex: 0xE2D66D)
    static let swCoral = Color(hex: 0xFF7168)
    static let swViolet = Color(hex: 0xD18AFF)
    static let swTerminalCyan = Color(hex: 0x00B8E6)
    static let swTerminalYellow = Color(hex: 0xE1D773)
    static let swTerminalGreen = Color(hex: 0xA8F56C)
    static let swTerminalRed = Color(hex: 0xFF665D)
    static let swTerminalBlue = Color(hex: 0x25B4E8)
}

struct PillLabel: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 0.5))
    }
}

struct SmallIconButton: View {
    let systemName: String
    let help: String
    var tint: Color = .swMuted
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 25, height: 25)
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
