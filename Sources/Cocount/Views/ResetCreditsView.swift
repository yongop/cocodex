import CocountCore
import SwiftUI

struct ResetCreditsView: View {
    @Environment(\.cocountTheme) private var theme
    let summary: ResetCredits?
    let now: Date
    @Binding var calendarFocus: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary {
                if summary.available.count > 3 {
                    ScrollView { creditRows(summary.available) }.frame(height: 112)
                } else {
                    creditRows(summary.available)
                }
                if summary.count == 0 {
                    Text("사용 가능한 초기화권이 없어요.").font(.system(size: 11)).foregroundStyle(theme.muted)
                } else if summary.credits == nil || summary.available.count < (summary.count ?? 0) {
                    Text("일부 초기화권의 만료 정보가 아직 제공되지 않았어요.")
                        .font(.system(size: 10)).foregroundStyle(theme.muted)
                }
            } else {
                Text("초기화권 정보를 받지 못했어요.").font(.system(size: 11)).foregroundStyle(theme.muted)
            }
        }
    }

    private func creditRows(_ credits: [ResetCredit]) -> some View {
        VStack(spacing: 6) {
            ForEach(credits) { credit in
                Button { calendarFocus = credit.expiryDate } label: {
                    creditRow(credit)
                }
                .buttonStyle(.plain)
                .disabled(credit.expiryDate == nil)
                .help("한 칸 = 24시간 · 색이 채워진 블록은 남은 시간 · 클릭하면 만료일을 달력에서 표시")
            }
        }
    }

    private func creditRow(_ credit: ResetCredit) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "ticket.fill").font(.system(size: 12)).foregroundStyle(theme.companion)
            Text(credit.expiryDate.map { "초기화권 만료 \(Self.expiryFormatter.string(from: $0))" } ?? "초기화권 만료 없음")
                .font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1)
            Spacer(minLength: 4)
            Text(credit.remainingLabel(at: now)).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(credit.expiryDate.map { $0 <= now } == true ? theme.danger : theme.companion)
                .monospacedDigit().fixedSize()
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background {
            Canvas { context, size in
                let blocks = credit.dayBlocks(at: now)
                guard !blocks.isEmpty else { return }
                let step = size.width / Double(blocks.count)
                let gap = min(1.5, step * 0.15)
                for (index, remaining) in blocks.enumerated() {
                    let rect = CGRect(x: Double(index) * step, y: 0, width: step - gap, height: size.height)
                    context.fill(Path(rect), with: .color(theme.companionSoft.opacity(0.35)))
                    let fill = CGRect(x: rect.minX, y: 0, width: rect.width * remaining, height: rect.height)
                    context.fill(Path(fill), with: .color(theme.companionSoft))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.companion.opacity(0.16)))
        .accessibilityElement(children: .combine)
    }

    private static var expiryFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }
}
