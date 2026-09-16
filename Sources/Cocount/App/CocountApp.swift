import AppKit
import CocountCore
import Combine
import SwiftUI

@main
@MainActor
enum CocountApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments = ProcessInfo.processInfo.arguments
    private lazy var store = UsageStore(demo: arguments.contains("--demo") || arguments.contains("--snapshot"))
    private var statusItem: NSStatusItem?
    private var popover: MenuBarPopover?
    private var window: NSWindow?
    private var subscription: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    private var visibilityObserver: NSObjectProtocol?
    private let displayClock = DashboardClock()
    private var probeTask: Task<Void, Never>?
    private var isTerminating = false
    private var canTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if arguments.contains("--probe-local") {
            probeTask = Task {
                do {
                    let started = Date.now
                    let estimator = LocalTokenEstimator()
                    let result = try await estimator.estimate()
                    print("Today local estimate: \(result.tokens.map(String.init) ?? "unavailable"), partial: \(result.isPartial)")
                    print(String(format: "Initial scan: %.2fs", Date.now.timeIntervalSince(started)))
                    let initialIO = await estimator.lastScan
                    print("Initial I/O: \(initialIO.bytesRead) bytes, \(initialIO.fullFiles) files")
                    let cachedStart = Date.now
                    _ = try await estimator.estimate()
                    print(String(format: "Cached scan: %.2fs", Date.now.timeIntervalSince(cachedStart)))
                    let cachedIO = await estimator.lastScan
                    print("Cached I/O: \(cachedIO.bytesRead) bytes, \(cachedIO.cachedFiles) reused, \(cachedIO.appendedFiles) appended")
                    NSApp.terminate(nil)
                } catch { fputs("Local estimate failed\n", stderr); exit(1) }
            }
            return
        }
        if arguments.contains("--probe") {
            probeTask = Task {
                do {
                    let result = try await AppServerUsageProvider().fetch(includeTokens: true)
                    print("Codex: \(UsageFormatting.percent(result.limits.featuredWindow?.remainingPercent)) remaining")
                    print("Windows: \(result.limits.windows.map(\.title).joined(separator: ", "))")
                    print("Token summary: \(result.tokens == nil ? "unavailable" : "available")")
                    print("Reset credits: \(result.resetCredits?.count.map(String.init) ?? "unknown"); expiry rows: \(result.resetCredits?.available.count ?? 0)")
                    NSApp.terminate(nil)
                } catch {
                    fputs("\(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            return
        }
        if let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) {
            renderSnapshot(to: arguments[index + 1])
            NSApp.terminate(nil)
            return
        }

        // A second launch opens the existing app instead of creating duplicate menu items.
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = CocountIcon.menuBarImage
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: .leftMouseDown)
        }
        let controller = NSHostingController(rootView: liveView)
        controller.sizingOptions = [.preferredContentSize]
        popover = MenuBarPopover(contentViewController: controller)
        subscription = store.menuContent.sink { [weak self] content in
            self?.updateStatus(content)
        }
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updatePresentationVisibility() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.displayClock.refresh()
                self?.store.refreshIfNeeded()
            }
        }
        store.start()

        if arguments.contains("--window") { showDevelopmentWindow() }
        else if arguments.contains("--show") { togglePopover() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if popover?.isPresented != true { togglePopover() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        probeTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        displayClock.setVisible(false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if canTerminate { return .terminateNow }
        guard !isTerminating else { return .terminateCancel }
        isTerminating = true
        // Keep the regular run loop alive while Swift tasks finish cleaning up the child.
        // terminateLater enters a nested AppKit loop that can starve main-actor tasks.
        Task {
            await store.shutdown()
            self.canTerminate = true
            sender.terminate(nil)
        }
        return .terminateCancel
    }

    private var liveView: some View {
        LiveDashboardView(store: store, clock: displayClock).fixedSize()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isPresented {
            popover.close()
        } else {
            popover.show(relativeTo: button)
        }
        updatePresentationVisibility()
    }

    private func updatePresentationVisibility() {
        let visible = popover?.isVisible == true || window?.occlusionState.contains(.visible) == true
        displayClock.setVisible(visible)
        let wasVisible = store.isDashboardVisible
        store.setDashboardVisible(visible)
        if visible && !wasVisible { store.refreshIfNeeded() }
    }

    private func updateStatus(_ content: MenuBarContent) {
        let title = NSMutableAttributedString(
            string: content.title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)]
        )
        let percentRange = (title.string as NSString).range(of: "%")
        if percentRange.location != NSNotFound {
            title.addAttributes([.font: NSFont.systemFont(ofSize: 11, weight: .medium)], range: percentRange)
        }
        statusItem?.button?.attributedTitle = title
        statusItem?.button?.setAccessibilityLabel("Co-Count · \(content.title)")
        statusItem?.button?.toolTip = "Co-Count · \(content.isDemo ? "샘플 데이터" : "Codex 남은 한도")"
    }

    private func showDevelopmentWindow() {
        let controller = NSHostingController(rootView: liveView)
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = store.isDemo ? "Co-Count · 디자인 미리 보기" : "Co-Count"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        updatePresentationVisibility()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func renderSnapshot(to path: String) {
        let snapshotDefaults = UserDefaults(suiteName: "local.cocount.snapshot")!
        snapshotDefaults.removePersistentDomain(forName: "local.cocount.snapshot")
        defer { snapshotDefaults.removePersistentDomain(forName: "local.cocount.snapshot") }
        let preview = UsageStore(demo: true, defaults: snapshotDefaults)
        preview.usageCardMode = arguments.contains("--tokens") ? .tokens : .limits
        preview.appearance = arguments.contains("--dark") ? "dark" : "light"
        preview.showSettings = arguments.contains("--settings")
        if let index = arguments.firstIndex(of: "--theme"), arguments.indices.contains(index + 1),
           let preset = ThemePreset(rawValue: arguments[index + 1]) {
            preview.themePreset = preset
        }
        let content = DashboardView(store: preview, constrainHeight: false)
            .environment(\.cocountAnimationsEnabled, false)
            .environment(\.colorScheme, arguments.contains("--dark") ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { fputs("Snapshot failed\n", stderr); exit(1) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        do {
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            try png.write(to: URL(fileURLWithPath: path))
            print(path)
        } catch { fputs("Snapshot write failed\n", stderr); exit(1) }
    }
}
