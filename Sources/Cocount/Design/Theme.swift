import SwiftUI

/// 60% quiet surfaces, 30% pastel supporting areas, 10% focused accents.
/// The proportions describe visual hierarchy, not a fixed count of screen pixels.
struct Theme {
    static let radius: CGFloat = 16
    static let width: CGFloat = 392
    static let pagePadding: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let metricWidth: CGFloat = 160

    let preset: ThemePreset
    let scheme: ColorScheme
    private var palette: ThemePalette { preset.palette(dark: scheme == .dark) }

    var canvas: Color { Color(hex: palette.canvas) }
    var card: Color { Color(hex: palette.card) }
    var soft: Color { Color(hex: palette.soft) }
    var accent: Color { Color(hex: palette.accent) }
    var companion: Color { Color(hex: palette.companion) }
    var companionSoft: Color { Color(hex: palette.companionSoft) }
    var time: Color { Color(hex: palette.time) }
    var text: Color { Color(hex: palette.text) }
    var muted: Color { Color(hex: palette.muted) }
    var border: Color { accent.opacity(scheme == .dark ? 0.18 : 0.13) }
    var track: Color { soft.opacity(scheme == .dark ? 0.55 : 0.40) }
    var elapsed: Color { soft.opacity(scheme == .dark ? 0.50 : 0.45) }
    var subtle: Color { muted.opacity(0.07) }
    var previousPeriod: Color { muted.opacity(0.25) }
    var olderPeriod: Color { muted.opacity(0.13) }
    var danger: Color { Color(hex: scheme == .dark ? 0xF2A1A8 : 0xB23E4C) }
    var warning: Color { Color(hex: scheme == .dark ? 0xEAC08B : 0x865B2F) }

    func tint(for remaining: Double?) -> Color {
        guard let remaining else { return muted }
        return remaining <= 10 ? danger : accent
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(preset: .sage, scheme: .light)
}

extension EnvironmentValues {
    var cocountTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

struct Card<Content: View>: View {
    @Environment(\.cocountTheme) private var theme
    var verticalPadding: CGFloat = Theme.cardPadding
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, Theme.cardPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(theme.border))
    }
}

struct IconButton: View {
    @Environment(\.cocountTheme) private var theme
    let symbol: String
    let label: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .foregroundStyle(selected ? theme.accent : theme.muted)
                .background(selected ? theme.track : theme.subtle, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
