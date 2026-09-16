import Combine
import Foundation
import SwiftUI

/// Both dashboard hosts share one minute clock. Hidden dashboards retain their
/// view state, but no display timer runs until a window is visible again.
@MainActor
final class DashboardClock: ObservableObject {
    @Published private(set) var now = Date.now
    @Published private(set) var isVisible = false
    private var timer: Timer?

    func setVisible(_ visible: Bool) {
        guard visible != (timer != nil) else { return }
        isVisible = visible
        if visible {
            now = .now
            let nextMinute = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 60) + 1) * 60)
            let timer = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        guard timer != nil else { return }
        now = .now
    }
}

struct LiveDashboardView: View {
    let store: UsageStore
    @ObservedObject var clock: DashboardClock

    var body: some View {
        DashboardView(store: store, now: clock.now)
            .environment(\.cocountDashboardVisible, clock.isVisible)
    }
}

private struct DashboardVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var cocountDashboardVisible: Bool {
        get { self[DashboardVisibleKey.self] }
        set { self[DashboardVisibleKey.self] = newValue }
    }
}
