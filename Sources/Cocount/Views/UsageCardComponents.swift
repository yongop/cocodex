import SwiftUI

/// Shared header for switching between quota and token units.
struct UsageCardHeader: View {
    @Environment(\.cocountTheme) private var theme
    @Binding var mode: UsageCardMode
    var basis: String?
    var changeBasis: (() -> Void)?

    var body: some View {
        HStack {
            Button { mode = mode == .limits ? .tokens : .limits } label: {
                Label(mode.title, systemImage: "chart.bar.xaxis")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .help("클릭하여 \(mode == .limits ? "토큰 사용" : "한도 사용")으로 전환")
            .accessibilityLabel("\(mode.title), 클릭하여 표시 전환")
            Spacer()
            if let basis {
                Button { changeBasis?() } label: {
                    Text("\(basis) 기준").font(.system(size: 10)).foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                .help("클릭하여 한도 기준 전환 · 선택한 한도 전체 = 100%")
            }
            Text("최근 7일").font(.system(size: 10)).foregroundStyle(theme.muted)
        }
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
