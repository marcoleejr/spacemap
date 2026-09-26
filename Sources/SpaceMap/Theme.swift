import SpaceMapCore
import SwiftUI

extension Color {
    /// Adaptive color from a light/dark hex pair. The system resolves it live,
    /// so the whole product follows the macOS appearance without restarts.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let lightMode = appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            let hex = lightMode ? light : dark
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }))
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// SpaceMap's own survey-station world: deep-space ink in the dark, warm paper
/// in the light, one signal-cyan accent, and a nebula category palette that
/// belongs to this product alone.
enum Theme {
    static let background = Color(light: 0xF1EFE7, dark: 0x0F131B)
    static let surface = Color(light: 0xFAF9F4, dark: 0x161B26)
    static let raised = Color(light: 0xE8E5D8, dark: 0x232B3D)
    static let sunken = Color(light: 0xE3DFD1, dark: 0x0B0E14)
    static let text = Color(light: 0x1C2331, dark: 0xE6EBF5)
    static let secondary = Color(light: 0x5D6779, dark: 0x93A0B8)
    static let line = Color(light: 0xD8D3C2, dark: 0x2B3448)
    static let accent = Color(light: 0x0B7D94, dark: 0x4CC3D9)
    static let danger = Color(light: 0xB3402E, dark: 0xE0806F)

    static func category(_ category: DiskCategory) -> Color {
        switch category {
        case .reclaimable: Color(hex: 0xC96A2C)
        case .code: Color(hex: 0x4C9BE8)
        case .agentScratch: Color(hex: 0xC05AA0)
        case .toolchains: Color(hex: 0x35A37B)
        case .synced: Color(hex: 0x2FA8BE)
        case .git: Color(hex: 0xDF5B57)
        case .media: Color(hex: 0x8E6FD8)
        case .documents: Color(hex: 0x8A93A6)
        case .cache: Color(hex: 0xD9A83C)
        }
    }
}

/// The SpaceMap orbit mark: a survey ring circling a treemap fragment.
/// Drawn, never copied: no four-squares grid, no borrowed palette.
struct SpaceMark: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(Theme.accent, lineWidth: max(1.5, size * 0.07))
                .frame(width: size, height: size)
            HStack(spacing: size * 0.06) {
                VStack(spacing: size * 0.06) {
                    RoundedRectangle(cornerRadius: size * 0.04)
                        .fill(Theme.category(.media))
                        .frame(width: size * 0.2, height: size * 0.3)
                    RoundedRectangle(cornerRadius: size * 0.04)
                        .fill(Theme.category(.toolchains))
                        .frame(width: size * 0.2, height: 18 * size / 100)
                }
                VStack(spacing: size * 0.06) {
                    RoundedRectangle(cornerRadius: size * 0.04)
                        .fill(Theme.category(.reclaimable))
                        .frame(width: size * 0.34, height: size * 0.2)
                    RoundedRectangle(cornerRadius: size * 0.04)
                        .fill(Theme.category(.code))
                        .frame(width: size * 0.34, height: size * 0.28)
                }
            }
            Circle()
                .fill(Theme.category(.cache))
                .frame(width: size * 0.16, height: size * 0.16)
                .offset(x: size * 0.42, y: -size * 0.42)
        }
        .frame(width: size * 1.15, height: size * 1.15)
        .accessibilityHidden(true)
    }
}
