import SwiftUI

struct ThemePicker: View {
    @Environment(\.cocountTheme) private var theme
    @Binding var selection: ThemePreset

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("컬러 프리셋").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(selection.subtitle).font(.system(size: 10)).foregroundStyle(theme.muted)
            }
            HStack(spacing: 6) {
                ForEach(ThemePreset.allCases) { preset in
                    presetButton(preset)
                }
            }
            Text("선택하면 바로 적용되고, 다음에도 그대로 유지돼요.")
                .font(.system(size: 10)).foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func presetButton(_ preset: ThemePreset) -> some View {
        let preview = Theme(preset: preset, scheme: theme.scheme)
        let selected = selection == preset
        return Button { selection = preset } label: {
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        preview.canvas.frame(width: geometry.size.width * 0.6)
                        preview.soft.frame(width: geometry.size.width * 0.3)
                        preview.accent
                    }
                }
                .frame(height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(preview.border))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(preview.card, preview.accent)
                            .padding(3)
                    }
                }
                Text(preset.name).font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .frame(height: 14)
                    .foregroundStyle(selected ? theme.accent : theme.text)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(selected ? theme.track : theme.card, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .strokeBorder(selected ? theme.accent : theme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .help(preset.subtitle)
        .accessibilityLabel("\(preset.name) 컬러 프리셋")
        .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
