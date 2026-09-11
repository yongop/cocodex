import AppKit
import QuartzCore

/// Keeps AppKit's anchoring and transient dismissal, with a short, interruptible fade.
@MainActor
final class MenuBarPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var transitionID = 0
    private(set) var isPresented = false

    init(contentViewController: NSViewController) {
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = contentViewController

        // Build and lay out the SwiftUI hierarchy before the first menu-bar click.
        contentViewController.view.layoutSubtreeIfNeeded()
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard !isPresented else { return }
        isPresented = true
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // show() is synchronous with native animation disabled, so this runs
            // before the first frame is displayed, including on the first opening.
            popover.contentViewController?.view.window?.alphaValue = 0
        }
        guard let window = popover.contentViewController?.view.window else {
            isPresented = false
            return
        }
        window.ignoresMouseEvents = false
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        fade(window, to: 1, duration: 0.14)
    }

    func close() {
        guard isPresented else { return }
        isPresented = false
        guard let window = popover.contentViewController?.view.window else {
            popover.close()
            return
        }
        window.ignoresMouseEvents = true
        fade(window, to: 0, duration: 0.10)
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // Outside clicks and Escape take the same path as the status-item button.
        close()
        return false
    }

    func popoverDidClose(_ notification: Notification) {
        transitionID += 1
        isPresented = false
    }

    private func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval) {
        transitionID += 1
        let id = transitionID
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.alphaValue = alpha
            if !isPresented { popover.close() }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: alpha == 1 ? .easeOut : .easeIn)
            window.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            // A second click can reverse the fade. An older completion must never
            // close a panel that the user has already opened again.
            Task { @MainActor in
                guard let self, self.transitionID == id else { return }
                if !self.isPresented { self.popover.close() }
            }
        }
    }
}
