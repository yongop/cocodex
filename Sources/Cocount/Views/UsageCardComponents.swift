import SwiftUI

/// Shared header for switching between quota and token units.
struct UsageCardHeader: View {
    @Environment(\.cocountTheme) private var theme
    @Binding var mode: UsageCardMode
    var basis: String?
    var changeBasis: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("사용된")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.muted)
                    .padding(.trailing, 2)
                ForEach([UsageCardMode.tokens, .limits], id: \.self) { option in
                    if option == .limits {
                        Text("/")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.muted.opacity(0.6))
                            .accessibilityHidden(true)
                    }
                    Button {
                        guard mode != option else { return }
                        mode = option
                    } label: {
                        Text(option == .tokens ? "토큰" : "한도")
                            .font(.system(size: 11, weight: mode == option ? .semibold : .medium))
                            .frame(width: 36, height: 22)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(UsageModeButtonStyle(selected: mode == option))
                    .help(mode == option ? "\(option.title) 표시 중" : "\(option.title)으로 전환")
                    .accessibilityLabel(option.title)
                    .accessibilityHint("사용량 표시 방식을 선택합니다")
                    .accessibilityAddTraits(mode == option ? .isSelected : [])
                }
            }
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("사용량 표시 방식")

            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if let basis, let changeBasis {
                    Button(action: changeBasis) {
                        HStack(spacing: 4) {
                            Text("\(basis) 기준")
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 8, weight: .medium))
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(theme.track, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("클릭하여 한도 기준 전환 · 선택한 한도 전체 = 100%")
                    .accessibilityLabel("\(basis) 기준, 클릭하여 한도 기준 전환")
                }
                Text("최근 7일").font(.system(size: 9)).foregroundStyle(theme.muted)
            }
        }
        .padding(.bottom, 3)
    }
}

private struct UsageModeButtonStyle: ButtonStyle {
    @Environment(\.cocountTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cocountAnimationsEnabled) private var animationsEnabled
    @State private var isHovered = false
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected || isHovered ? theme.accent : theme.muted)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? theme.track : isHovered ? theme.track.opacity(0.65) : theme.subtle)
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { isHovered = $0 }
            .animation(reduceMotion || !animationsEnabled ? nil : .easeOut(duration: 0.12), value: isHovered)
    }
}

/// The same seven-day bar layout serves both units; callers own selection and accessibility.
struct UsageDayBar: View {
    @Environment(\.cocountTheme) private var theme
    let day: Date
    let dateLabel: String
    let value: Double?
    let maximum: Double
    let valueLabel: String
    let isToday: Bool
    var isSelected = false
    let isHovered: Bool

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(value == nil ? theme.subtle : isToday ? theme.companion : theme.soft)
                .frame(height: max(3, (value ?? 0) / maximum * 42))
                .overlay(alignment: .top) {
                    Text(valueLabel)
                        .font(.system(size: 8, weight: .medium)).monospacedDigit()
                        .foregroundStyle(isToday ? theme.companion : theme.muted)
                        .fixedSize().offset(y: -12).opacity(isHovered ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .frame(height: 42, alignment: .bottom).padding(.top, 12)
            VStack(spacing: 2) {
                Text(isToday ? "오늘" : day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 9, weight: isToday || isSelected ? .semibold : .regular))
                Text(dateLabel)
                    .font(.system(size: 8)).monospacedDigit().opacity(isHovered ? 1 : 0)
            }
            .foregroundStyle(isToday ? theme.companion : theme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}
