//
//  MacFanApp.swift
//  Mac Fan
//
//  Menu bar fan control for Apple Silicon MacBooks.
//
//  AppKit entry point: macOS 26 renders MenuBarExtra labels once and never
//  re-renders their transforms, which froze the spinning fan icon. So the
//  status item is a plain NSStatusItem whose image we redraw ourselves
//  (rotating SF-symbol fan + temperature text), with the SwiftUI panel
//  hosted in an NSPopover and the curve editor in its own NSWindow.
//

import Combine
import MacFanCore
import SwiftUI

@main
final class AppMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var state: AppState!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var curveWindow: NSWindow?
    private var cancellable: AnyCancellable?
    private var detailCancellable: AnyCancellable?
    private var normalPopoverSize: NSSize?
    private var redrawScheduled = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Prevent duplicate instances
        let bundleID = Bundle.main.bundleIdentifier ?? "com.macfan.app"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            NSLog("Mac Fan: another instance already running — quitting")
            NSApp.terminate(nil)
            return
        }

        state = AppState()
        state.openCurveEditor = { [weak self] in self?.showCurveEditor() }

        // Content is created on open and torn down on close — a retained
        // hosting view would keep re-rendering at 12 fps while fans spin,
        // even with the popover closed.
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        redrawStatusItem()

        // Redraw the status item whenever anything published changes
        // (rotation ticks at 12 fps while fans run, poll updates every 2 s).
        // Coalesced: objectWillChange fires pre-mutation, the async hop reads post-mutation.
        cancellable = state.objectWillChange.sink { [weak self] _ in
            guard let self, !self.redrawScheduled else { return }
            self.redrawScheduled = true
            DispatchQueue.main.async {
                self.redrawScheduled = false
                self.redrawStatusItem()
            }
        }

        detailCancellable = state.$expandedDetail
            .removeDuplicates()
            .sink { [weak self] detail in
                self?.resizePopover(for: detail)
            }

    }

    func applicationWillTerminate(_ notification: Notification) {
        // Hand fans back to Apple so the daemon doesn't hold stale settings
        try? DaemonClient().auto()
    }

    // MARK: - Status Item

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            normalPopoverSize = nil
            popover.contentViewController = NSHostingController(
                rootView: PanelView().environmentObject(state))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            normalPopoverSize = popover.contentSize
            popover.contentViewController?.view.window?.makeKey()
            state.setMonitoringActive(true)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Detail monitors get substantially more vertical room while preserving
    /// the exact dashboard size to restore when the user taps Back.
    private func resizePopover(for detail: SystemDetailKind?) {
        guard popover.isShown else { return }

        if detail != nil {
            let normalSize = normalPopoverSize ?? popover.contentSize
            normalPopoverSize = normalSize

            let screen = statusItem.button?.window?.screen ?? NSScreen.main
            let availableHeight = max(420, (screen?.visibleFrame.height ?? 800) - 24)
            let detailHeight = max(normalSize.height, min(760, availableHeight))
            popover.contentSize = NSSize(width: normalSize.width, height: detailHeight)
        } else if let normalSize = normalPopoverSize {
            popover.contentSize = normalSize
        }
    }

    private func redrawStatusItem() {
        guard let button = statusItem.button else { return }

        var tempText: String?
        if let tempC = state.menuBarTemp {
            let display = state.useFahrenheit ? tempC * 9 / 5 + 32 : tempC
            tempText = "\(Int(display.rounded()))°"
        }

        button.image = Self.renderStatusImage(
            rotation: CGFloat(state.rotation),
            tempText: tempText,
            failsafe: state.failsafe
        )
        button.imagePosition = .imageOnly
    }

    /// Compose the menu bar image: rotated fan glyph + temperature text.
    /// Template image, so it adapts to menu bar appearance automatically.
    private static func renderStatusImage(
        rotation: CGFloat, tempText: String?, failsafe: Bool
    ) -> NSImage {
        let height: CGFloat = 22
        let iconBox: CGFloat = 16

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.black,
        ]
        let text = tempText.map { NSAttributedString(string: $0, attributes: attributes) }
        let textSize = text?.size() ?? .zero
        let spacing: CGFloat = text == nil ? 0 : 3
        let width = iconBox + spacing + ceil(textSize.width)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let symbolName = failsafe ? "exclamationmark.triangle.fill" : "fanblades.fill"
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Fan")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)),
            let ctx = NSGraphicsContext.current?.cgContext
        {
            let size = symbol.size
            ctx.saveGState()
            ctx.translateBy(x: iconBox / 2, y: height / 2)
            if !failsafe {
                ctx.rotate(by: -rotation * .pi / 180)
            }
            symbol.draw(in: NSRect(
                x: -size.width / 2, y: -size.height / 2,
                width: size.width, height: size.height))
            ctx.restoreGState()
        }

        text?.draw(at: NSPoint(
            x: iconBox + spacing,
            y: (height - textSize.height) / 2))

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Curve Editor Window

    private func showCurveEditor() {
        popover.performClose(nil)

        if curveWindow == nil {
            let hosting = NSHostingController(
                rootView: CurveEditorView().environmentObject(state))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Fan Curves"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 560))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            curveWindow = window
        }
        curveWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

}

// MARK: - Teardown of hidden UI

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        state.setMonitoringActive(false)
        state.expandedDetail = nil
        popover.contentViewController = nil
        normalPopoverSize = nil
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === curveWindow {
            curveWindow = nil
        }
    }
}
