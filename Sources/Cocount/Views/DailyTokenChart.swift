import AppKit
import QuartzCore
import CocountCore
import SwiftUI

struct DailyTokenChart: View {
    @Environment(\.cocountTheme) private var theme
    let estimate: TodayTokenEstimate?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let values = estimate?.tenMinuteBins(on: now)
            let maximum = Double(max(1, values?.max() ?? 0))
            let nextInterval = TodayTokenEstimate.tenMinuteIndex(at: now) + 1
            VStack(alignment: .leading, spacing: 2) {
                GeometryReader { geometry in
                    let nextBarStart = min(geometry.size.width,
                                           (geometry.size.width + 1) * Double(nextInterval) / 144)
                    ZStack(alignment: .bottomLeading) {
                        Rectangle().fill(theme.border).frame(height: 1)
                            .overlay(alignment: .topLeading) {
                                ForEach(0..<5) { index in
                                    Rectangle().fill(theme.muted.opacity(0.5))
                                        .frame(width: 1, height: 4)
                                        .offset(x: (geometry.size.width - 1) * Double(index) / 4, y: 1)
                                }
                            }
                        HStack(alignment: .bottom, spacing: 1) {
                            ForEach(0..<144, id: \.self) { index in
                                let amount = values?[index] ?? 0
                                Rectangle()
                                    .fill(theme.accent.opacity(0.45))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: amount > 0 ? max(2, Double(amount) / maximum * 25.2) : 0)
                                    .frame(height: 28, alignment: .bottom)
                                    .contentShape(Rectangle())
                                    .help("\(timeLabel(index))–\(timeLabel(index + 1)): \(values == nil ? "미집계" : amount.formatted() + " 토큰 (추정)")")
                            }
                        }
                        // Align the dot's left edge with the next bar, including the 1pt bar spacing.
                        NextIntervalDot()
                            .offset(x: nextBarStart, y: 2.5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 30.1)
                .padding(.bottom, 4)
                HStack {
                    Text("00")
                    Spacer()
                    Text("24")
                }
                .font(.system(size: 8)).monospacedDigit()
                .foregroundStyle(theme.muted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("오늘 00시부터 24시까지 10분별 토큰 사용 추정. 다음 기록 구간 \(timeLabel(nextInterval)). \(values == nil ? "미집계" : "총 " + (values?.reduce(0, +).formatted() ?? "0") + " 토큰")")
        }
    }

    private func timeLabel(_ interval: Int) -> String {
        String(format: "%02d:%02d", interval / 6, interval % 6 * 10)
    }
}

struct NextIntervalDot: View {
    @Environment(\.cocountTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cocountAnimationsEnabled) private var animationsEnabled
    private var animated: Bool { !reduceMotion && animationsEnabled }

    var body: some View {
        Circle()
            .fill(Color(hex: theme.scheme == .dark ? 0xF2ABB0 : 0xE99A9F))
            .opacity(animated ? 0.4 : 1)
            .overlay {
                if animated { CompositedIntervalDot(isDark: theme.scheme == .dark) }
            }
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

/// Animate opacity in the compositor, without invalidating the SwiftUI chart every frame.
private struct CompositedIntervalDot: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> IntervalDotView { IntervalDotView() }
    func updateNSView(_ view: IntervalDotView, context: Context) {
        view.wantsLayer = true
        view.layer?.backgroundColor = (isDark
            ? NSColor(srgbRed: 242 / 255, green: 171 / 255, blue: 176 / 255, alpha: 1)
            : NSColor(srgbRed: 233 / 255, green: 154 / 255, blue: 159 / 255, alpha: 1)).cgColor
        view.layer?.cornerRadius = 3
        view.updateAnimation()
    }
}

private final class IntervalDotView: NSView {
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                  object: window)
        layer?.removeAnimation(forKey: "pulse")
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(updateAnimation),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updateAnimation()
    }

    @objc func updateAnimation() {
        guard window?.occlusionState.contains(.visible) == true else {
            layer?.removeAnimation(forKey: "pulse")
            return
        }
        guard layer?.animation(forKey: "pulse") == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 1.4
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(animation, forKey: "pulse")
    }
}

// ImageRenderer cannot render NSViewRepresentable. Snapshots use the same static SwiftUI dot.
private struct CocountAnimationsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var cocountAnimationsEnabled: Bool {
        get { self[CocountAnimationsKey.self] }
        set { self[CocountAnimationsKey.self] = newValue }
    }
}
