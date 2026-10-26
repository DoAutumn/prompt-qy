import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsFormModel
    private var clickMonitor: Any?

    init(onChange: @escaping () -> Void) {
        let model = SettingsFormModel(onChange: onChange)
        self.model = model
        let hostingController = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.minSize = NSSize(width: 540, height: 560)
        // Same chrome as NotchTerm (visible titlebar, empty title — TabView owns the header).
        window.title = ""
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.setFrameAutosaveName("PromptQy.SettingsWindow.v1")
        window.setContentSize(NSSize(width: 560, height: 600))
        window.center()
        window.orderOut(nil)

        super.init(window: window)
        window.delegate = self
        installClickMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }

    func show() {
        guard let window else { return }
        model.reload()
        window.appearance = Self.systemWindowAppearance()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }

    /// Click non-text controls to resign TextEditor focus (SwiftUI Form won't).
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window == window else { return event }
            let point = event.locationInWindow
            let hit = window.contentView?.hitTest(point)
            if !Self.isTextInput(hit) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private static func isTextInput(_ view: NSView?) -> Bool {
        var current = view
        while let node = current {
            if node is NSTextView || node is NSTextField {
                return true
            }
            current = node.superview
        }
        return false
    }

    /// Resolve aqua / darkAqua from system preference so settings don't inherit
    /// the menu-bar's dark effective appearance (LSUIElement).
    private static func systemWindowAppearance() -> NSAppearance {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return NSAppearance(named: dark ? .darkAqua : .aqua)
            ?? NSAppearance.currentDrawing()
    }
}
