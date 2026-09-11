import CocountCore
import SwiftUI

struct QuotaCard: View {
    @Environment(\.cocountTheme) private var theme
    let limits: RateLimitBucket
    let now: Date
    let history: PeriodHistory
    let credits: [ResetCredit]
    @Binding var calendarFocus: Date?
    private var window: UsageWindow? { limits.featuredWindow }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(spacing: 8) {
                        UsageRing(remaining: window?.remainingPercent,
                                  timeRemaining: window.flatMap(UsagePeriod.init(window:))?.remainingFraction(at: now))
                        VStack(spacing: 5) {
                            HStack(spacing: 5) {
                                Text("\(window?.title ?? "사용 한도") Codex")
                                    .font(.system(size: 12, weight: .bold))
                                if let plan = limits.planType {
                                    Text(plan.capitalized)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 5).padding(.vertical, 3)
                                        .foregroundStyle(theme.accent)
                                        .background(theme.track, in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            Label(UsageFormatting.countdown(to: window?.resetDate, now: now), systemImage: "arrow.clockwise")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.time)
                                .fixedSize(horizontal: false, vertical: true)
                            if let reset = window?.resetDate {
                                Text(reset, format: .dateTime.month().day().weekday().hour().minute())
                                    .font(.system(size: 9)).foregroundStyle(theme.muted)
                                    .lineLimit(1).minimumScaleFactor(0.9)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    PeriodCalendarView(periods: history.periods, credits: credits, now: now, focus: $calendarFocus)
                }
                if let other = limits.otherWindow {
                    Rectangle().fill(theme.border).frame(height: 1)
                    VStack(spacing: 6) {
                        HStack {
                            Text("\(other.title) 한도").foregroundStyle(theme.muted)
                            Spacer()
                            Text("\(UsageFormatting.percent(other.remainingPercent)) 남음")
                                .fontWeight(.semibold).foregroundStyle(theme.tint(for: other.remainingPercent))
                        }
                        .font(.system(size: 11))
                        GeometryReader { proxy in
                            Capsule().fill(theme.track)
                            Capsule().fill(theme.tint(for: other.remainingPercent))
                                .frame(width: proxy.size.width * (other.remainingPercent ?? 0) / 100)
                        }
                        .frame(height: 5)
                        .accessibilityLabel("\(other.title) 한도 \(UsageFormatting.percent(other.remainingPercent)) 남음")
                        Text(UsageFormatting.countdown(to: other.resetDate, now: now))
                            .font(.system(size: 10)).foregroundStyle(theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

}

private struct UsageRing: View {
    @Environment(\.cocountTheme) private var theme
    let remaining: Double?
    let timeRemaining: Double?
    var body: some View {
        ZStack {
            Circle().stroke(theme.track, lineWidth: 7)
            Circle()
                .trim(from: 0, to: (remaining ?? 0) / 100)
                .stroke(theme.tint(for: remaining), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle().stroke(theme.time.opacity(0.12), lineWidth: 2.5).padding(8)
            Circle().trim(from: 0, to: timeRemaining ?? 0)
                .stroke(theme.time, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90)).padding(8)
            VStack(spacing: 3) {
                Text(UsageFormatting.percent(remaining))
                    .font(.system(size: 21, weight: .bold, design: .rounded)).monospacedDigit()
                Text("남음").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(theme.tint(for: remaining))
        }
        .frame(width: 78, height: 78)
        .padding(4)
        .accessibilityElement(children: .ignore)
        .help("바깥 원: 사용 한도 · 안쪽 시간 링: 전체 기간 중 남은 시간 \(UsageFormatting.percent(timeRemaining.map { $0 * 100 }))")
        .accessibilityLabel("사용 한도 \(UsageFormatting.percent(remaining)) 남음, 시간 \(UsageFormatting.percent(timeRemaining.map { $0 * 100 })) 남음")
    }
}
