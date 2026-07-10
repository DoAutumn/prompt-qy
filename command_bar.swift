// Claude Command Bar — a menu-bar-resident, always-on-top text composer for
// feeding prompts, file paths, selections and screenshots into a terminal
// running Claude Code.
//
// Stages implemented:
//   1. Menu-bar item + always-on-top draggable/resizable editor + double-tap
//      Control to summon/dismiss.
//   2. Grab the frontmost app's selection on summon (AX, then synthesized
//      Cmd+C) + a Send button that pastes+Returns into a chosen Terminal.app tab.
//   3. Drag files onto the editor to insert their paths + a double-tap Option
//      hotkey to insert the Finder selection.
//   4. Watch the screenshot folder and insert the path of new screenshots.
//
// Later stages: history store + settings window (customizable shortcuts/count).
//
// Build via ./build_app.sh.

import Cocoa
import ApplicationServices

// MARK: - Settings

/// A modifier key usable for the double-tap gestures.
enum ModifierChoice: String, CaseIterable {
    case control, option, command, shift

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .shift: return .shift
        }
    }
    /// Left/right key codes for this modifier.
    var keyCodes: Set<UInt16> {
        switch self {
        case .control: return [59, 62]
        case .option: return [58, 61]
        case .command: return [54, 55]
        case .shift: return [56, 60]
        }
    }
    var displayName: String {
        switch self {
        case .control: return "Control (⌃)"
        case .option: return "Option (⌥)"
        case .command: return "Command (⌘)"
        case .shift: return "Shift (⇧)"
        }
    }
}

/// User-customizable preferences, persisted in UserDefaults.
enum Settings {
    private static let d = UserDefaults.standard
    /// Max gap between the two taps to count as a double-tap.
    static let doubleTapInterval: TimeInterval = 0.4

    static var summonModifier: ModifierChoice {
        get { ModifierChoice(rawValue: d.string(forKey: "summonModifier") ?? "") ?? .control }
        set { d.set(newValue.rawValue, forKey: "summonModifier") }
    }
    static var finderModifier: ModifierChoice {
        get { ModifierChoice(rawValue: d.string(forKey: "finderModifier") ?? "") ?? .option }
        set { d.set(newValue.rawValue, forKey: "finderModifier") }
    }
    static var historyLimit: Int {
        get { let v = d.integer(forKey: "historyLimit"); return v > 0 ? v : 50 }
        set { d.set(newValue, forKey: "historyLimit") }
    }
    static var labelWidth: Int {
        get { let v = d.integer(forKey: "labelWidth"); return v > 0 ? v : 40 }
        set { d.set(newValue, forKey: "labelWidth") }
    }
}

// MARK: - History store

/// Keeps the most recent sent messages (capped at `Settings.historyLimit`) so
/// they can be re-loaded into the editor from the menu-bar menu.
enum HistoryStore {
    private static let key = "history"
    private static let d = UserDefaults.standard

    static var items: [String] {
        get { d.stringArray(forKey: key) ?? [] }
        set { d.set(newValue, forKey: key) }
    }

    static func add(_ s: String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var arr = items.filter { $0 != s }   // move duplicates to the front
        arr.insert(s, at: 0)
        if arr.count > Settings.historyLimit { arr = Array(arr.prefix(Settings.historyLimit)) }
        items = arr
    }

    static func clear() { items = [] }
}

// MARK: - Path formatting

/// Wraps paths that contain shell-significant characters in quotes so they
/// paste cleanly into a terminal prompt.
enum PathFormat {
    /// Insert paths verbatim (no shell quoting). The target is Claude Code's
    /// prompt, which resolves paths with spaces fine — quotes would just be noise.
    static func forInsertion(_ path: String) -> String { path }
}

extension String {
    /// Drop trailing newlines so we can append exactly one (selections often
    /// already include the line's trailing newline).
    func trimmingTrailingNewlines() -> String {
        var s = Substring(self)
        while let last = s.last, last == "\n" || last == "\r" { s = s.dropLast() }
        return String(s)
    }
}

// MARK: - AppleScript runner

enum AppleScriptRunner {
    /// Human-readable message from the most recent failed run (for surfacing
    /// permission errors like "not authorized" to the user).
    static var lastError: String?

    /// Run a script and return its string result (scripts here join list
    /// results into newline/tab-delimited text so `stringValue` suffices).
    @discardableResult
    static func run(_ source: String) -> String? {
        lastError = nil
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            lastError = "无法创建 AppleScript"
            return nil
        }
        let out = script.executeAndReturnError(&err)
        if let err = err {
            lastError = (err[NSAppleScript.errorMessage] as? String) ?? "\(err)"
            return nil
        }
        return out.stringValue
    }

    /// Run a script executed for its side effects. `run` returns nil both for a
    /// failure *and* for a script with no result, so success must be read off
    /// `lastError` rather than the return value.
    static func succeeds(_ source: String) -> Bool {
        _ = run(source)
        return lastError == nil
    }
}

// MARK: - Selection reader

/// Reads the current selection from the frontmost application. Tries the
/// Accessibility API first (clean, no clipboard churn); falls back to a
/// synthesized Cmd+C with clipboard save/restore for apps that don't expose
/// AXSelectedText (many Electron apps, terminals).
enum SelectionReader {
    static func grab() -> String? {
        if let t = axSelectedText(), !t.isEmpty { return t }
        return copyViaCmdC()
    }

    private static func axSelectedText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused else { return nil }
        var sel: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel) == .success,
            let s = sel as? String else { return nil }
        return s
    }

    private static func copyViaCmdC() -> String? {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let before = pb.changeCount

        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)  // 'c'
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)

        var result: String?
        for _ in 0..<30 {  // up to ~300ms for the pasteboard to update
            usleep(10_000)
            if pb.changeCount != before {
                result = pb.string(forType: .string)
                break
            }
        }
        // Restore the previous clipboard contents.
        pb.clearContents()
        if let saved = saved { pb.setString(saved, forType: .string) }
        return (result?.isEmpty == false) ? result : nil
    }
}

// MARK: - Finder selection

enum FinderSelection {
    static func paths() -> [String] {
        let script = """
        tell application "Finder"
            set sel to selection
            set out to {}
            repeat with i in sel
                set end of out to POSIX path of (i as alias)
            end repeat
            set AppleScript's text item delimiters to linefeed
            return out as text
        end tell
        """
        guard let out = AppleScriptRunner.run(script), !out.isEmpty else { return [] }
        return out.split(separator: "\n").map(String.init)
    }
}

// MARK: - Terminal.app sender

enum TerminalSender {
    struct Target {
        let windowId: String
        let tabIndex: String
        let label: String
    }

    /// Cap a menu label to a sensible width; the tail (command + window size)
    /// is the least useful part, so truncate from the end.
    static func truncate(_ s: String, max: Int = 40) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }

    /// Enumerate every window/tab of Terminal.app, tagging each with the
    /// processes running in it so the user can tell which one holds Claude.
    static func listTargets() -> [Target] {
        // NB: inside `tell application "Terminal"`, the bareword `tab` resolves
        // to Terminal's *tab class*, not the tab-character constant — so build
        // the field separator explicitly via `character id 9`.
        let script = """
        set fieldSep to (character id 9)
        set rowSep to (character id 10)
        tell application "Terminal"
            set outLines to {}
            set winList to windows
            repeat with wi from 1 to count of winList
                set w to item wi of winList
                set wid to id of w
                set winName to ""
                try
                    set winName to name of w
                end try
                set tabList to tabs of w
                repeat with ti from 1 to count of tabList
                    set t to item ti of tabList
                    set procText to ""
                    try
                        set AppleScript's text item delimiters to " "
                        set procText to (processes of t) as text
                        set AppleScript's text item delimiters to ""
                    end try
                    set end of outLines to (wid as text) & fieldSep & (ti as text) & fieldSep & winName & fieldSep & procText
                end repeat
            end repeat
            set AppleScript's text item delimiters to rowSep
            return outLines as text
        end tell
        """
        guard let out = AppleScriptRunner.run(script), !out.isEmpty else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4 else { return nil }
            let winName = parts[2].trimmingCharacters(in: .whitespaces)
            let procs = parts[3].trimmingCharacters(in: .whitespaces)
            // The window title already carries project/task info; fall back to
            // the id + processes only when it's empty.
            let label: String
            if winName.isEmpty {
                label = procs.isEmpty ? "窗口 \(parts[0])" : "窗口 \(parts[0])  ·  \(procs)"
            } else {
                label = winName
            }
            return Target(windowId: parts[0], tabIndex: parts[1],
                          label: truncate(label, max: Settings.labelWidth))
        }
    }

    /// Put the text on the clipboard, focus the target tab, then paste + Return.
    /// Returns false (with `AppleScriptRunner.lastError` set) if anything failed,
    /// so the caller can keep the text instead of silently dropping it.
    static func send(_ text: String, to target: Target) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Terminal needs a beat to actually come frontmost; paste too early and
        // the synthesized Cmd+V lands in whatever app is still in front.
        let script = """
        tell application "Terminal"
            set targetWin to window id \(target.windowId)
            set selected of tab \(target.tabIndex) of targetWin to true
            set frontmost of targetWin to true
            activate
        end tell
        delay 0.3
        tell application "System Events"
            keystroke "v" using command down
            delay 0.05
            key code 36
        end tell
        """
        return AppleScriptRunner.succeeds(script)
    }
}

// MARK: - Screenshot watcher

/// Watches the macOS screenshot folder and reports newly created image files,
/// so Cmd+Shift+4 captures can drop their path straight into the editor.
final class ScreenshotWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var dir: URL = FileManager.default.homeDirectoryForCurrentUser
    private var seen: Set<String> = []
    private var notified: Set<String> = []  // files already reported, never repeat
    private let onNew: (URL) -> Void

    init(onNew: @escaping (URL) -> Void) {
        self.onNew = onNew
    }

    private static func resolveDir() -> URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location"), !loc.isEmpty {
            return URL(fileURLWithPath: (loc as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
    }

    func start() {
        dir = Self.resolveDir()
        seen = currentImages()
        fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("ScreenshotWatcher: cannot open \(dir.path)")
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler { [weak self] in self?.scan() }
        s.setCancelHandler { [weak self] in
            if let f = self?.fd, f >= 0 { close(f) }
        }
        source = s
        s.resume()
    }

    private func currentImages() -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(items.filter(Self.isImage))
    }

    private static func isImage(_ name: String) -> Bool {
        // Skip the hidden temp file (".截屏….png") macOS writes before renaming
        // the capture to its final visible name — otherwise we'd insert twice.
        guard !name.hasPrefix(".") else { return false }
        let l = name.lowercased()
        return l.hasSuffix(".png") || l.hasSuffix(".jpg") || l.hasSuffix(".jpeg")
    }

    private func scan() {
        let now = currentImages()
        let added = now.subtracting(seen)
        seen = now
        let urls = added.map { dir.appendingPathComponent($0) }
        guard let newest = urls.max(by: { mtime($0) < mtime($1) }) else { return }
        // A single capture can fire multiple vnode events (write + rename +
        // metadata); guarantee we insert each file's path at most once.
        let path = newest.path
        guard !notified.contains(path) else { return }
        // Ignore files merely moved in; only react to fresh captures.
        if Date().timeIntervalSince(mtime(newest)) < 10 {
            notified.insert(path)
            onNew(newest)
        }
    }

    private func mtime(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
            as? Date) ?? .distantPast
    }
}

// MARK: - Screenshot thumbnail preference

/// Toggles macOS's screenshot floating thumbnail. While the thumbnail is shown
/// (the default), the capture is held in memory for ~5s and only written to disk
/// after it dismisses — so our watcher can't insert the path until then.
/// Turning it off makes captures save (and insert) immediately.
enum ScreenshotThumbnail {
    private static let domain = "com.apple.screencapture"
    private static let key = "show-thumbnail"

    /// True when the thumbnail is disabled (i.e. captures save immediately).
    static var isDisabled: Bool {
        guard let v = UserDefaults(suiteName: domain)?.object(forKey: key) as? Bool
        else { return false }  // unset ⇒ thumbnail shown ⇒ not disabled
        return v == false
    }

    static func setDisabled(_ disabled: Bool) {
        UserDefaults(suiteName: domain)?.set(!disabled, forKey: key)
        // Restart SystemUIServer so the screenshot service picks up the change.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["SystemUIServer"]
        try? p.run()
    }
}

// MARK: - Global double-tap monitor

/// Fires when the configured modifier key is pressed twice within `interval`.
/// Observe-only NSEvent monitors; require Accessibility permission.
final class DoubleTapMonitor {
    private let keyCodes: Set<UInt16>
    private let flag: NSEvent.ModifierFlags
    private let interval: TimeInterval
    private let onDoubleTap: () -> Void

    private var lastPress: TimeInterval = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(keyCodes: Set<UInt16>,
         flag: NSEvent.ModifierFlags,
         interval: TimeInterval,
         onDoubleTap: @escaping () -> Void) {
        self.keyCodes = keyCodes
        self.flag = flag
        self.interval = interval
        self.onDoubleTap = onDoubleTap
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in self?.handle(event); return event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard keyCodes.contains(event.keyCode) else { return }
        guard event.modifierFlags.contains(flag) else { return }  // press edge only
        let now = event.timestamp
        if now - lastPress <= interval {
            lastPress = 0
            onDoubleTap()
        } else {
            lastPress = now
        }
    }
}

// MARK: - Editor text view

/// NSTextView that dismisses on Escape and inserts dropped files as (quoted)
/// paths rather than as attachments.
final class EditorTextView: NSTextView {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender) != nil ? .copy : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = fileURLs(from: sender), !urls.isEmpty {
            let joined = urls.map { PathFormat.forInsertion($0.path) }.joined(separator: "\n")
            insertText(joined + "\n", replacementRange: selectedRange())
            return true
        }
        return super.performDragOperation(sender)
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
}

// MARK: - Floating editor panel

final class EditorPanel: NSPanel {
    let textView = EditorTextView()
    private let sendButton = NSButton()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        title = "Claude Command Bar"
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 320, height: 160)
        setFrameAutosaveName("ClaudeCommandBarEditorFrame")

        buildContent()
    }

    override var canBecomeKey: Bool { true }

    /// Escape must hide the panel even when the text view isn't first responder
    /// (e.g. focus landed on the title bar, the Send button, or was dropped when
    /// a popup menu closed). EditorTextView handles the common case; this is the
    /// responder-chain backstop.
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    private func buildContent() {
        let container = NSView()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.onCancel = { [weak self] in self?.orderOut(nil) }
        textView.registerForDraggedTypes([.fileURL])
        scroll.documentView = textView

        sendButton.title = "发送"
        sendButton.bezelStyle = .rounded
        sendButton.setButtonType(.momentaryPushIn)
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = .command
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "⌘↵ 或点「发送」→ 选择终端 · 拖文件插路径 · ⌥⌥ 插 Finder 选中项")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(hint)
        bar.addSubview(sendButton)

        container.addSubview(scroll)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 38),

            hint.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            hint.trailingAnchor.constraint(
                lessThanOrEqualTo: sendButton.leadingAnchor, constant: -8),

            sendButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        contentView = container
    }

    // MARK: Public API

    func showAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(textView)
        // NSApp.activate is asynchronous: if the panel wasn't key yet, AppKit
        // resets the first responder once it becomes key, silently undoing the
        // line above. Re-assert after activation has settled.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isVisible else { return }
            if self.firstResponder !== self.textView {
                self.makeFirstResponder(self.textView)
            }
        }
    }

    func toggle() {
        if isVisible { orderOut(nil) } else { showAndFocus() }
    }

    func insertAtCursor(_ s: String) {
        textView.insertText(s, replacementRange: textView.selectedRange())
    }

    /// Replace the whole editor contents (used when re-loading from history).
    func setText(_ s: String) {
        textView.string = s
        textView.setSelectedRange(NSRange(location: (s as NSString).length, length: 0))
    }

    // MARK: Send flow

    @objc private func sendTapped() {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }
        let targets = TerminalSender.listTargets()
        guard !targets.isEmpty else {
            let alert = NSAlert()
            if let e = AppleScriptRunner.lastError {
                alert.messageText = "无法访问 Terminal.app"
                alert.informativeText =
                    "AppleScript 错误：\(e)\n\n"
                    + "多半是自动化权限：请到「系统设置 → 隐私与安全性 → 自动化」，"
                    + "允许「Claude Command Bar」控制 Terminal 与 System Events。"
            } else {
                alert.messageText = "未找到运行中的 Terminal.app 窗口"
                alert.informativeText = "请先打开一个 Terminal.app 窗口（里面跑着 Claude Code），再发送。"
            }
            alert.runModal()
            return
        }
        if targets.count == 1 {
            deliver(text, to: targets[0])
            return
        }
        // Multiple tabs: let the user pick. NSMenu.popUp spins a nested modal
        // tracking loop, so it must not run inside the event that triggered it —
        // from performKeyEquivalent (Cmd+Return, Command still held) or a button
        // action, the trailing key-up/mouse-up tears the menu straight back down
        // and nothing is delivered. Defer to the next runloop turn.
        DispatchQueue.main.async { [weak self] in self?.presentPicker(text, targets) }
    }

    private func presentPicker(_ text: String, _ targets: [TerminalSender.Target]) {
        let menu = NSMenu()
        for target in targets {
            let item = NSMenuItem(
                title: target.label, action: #selector(pickTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Delivery(text: text, target: target)
            menu.addItem(item)
        }
        guard let content = contentView else {
            menu.popUp(positioning: nil, at: .zero, in: sendButton)
            return
        }
        // Pop up centered over the editor rather than tucked by the Send button.
        // `positioning: nil` — pre-highlighting the first item lets a stray
        // Return key-up select or dismiss it.
        let center = NSPoint(x: content.bounds.midX - 100, y: content.bounds.midY + 60)
        menu.popUp(positioning: nil, at: center, in: content)
    }

    @objc private func pickTarget(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Delivery else { return }
        deliver(d.text, to: d.target)
    }

    private func deliver(_ text: String, to target: TerminalSender.Target) {
        guard TerminalSender.send(text, to: target) else {
            // Keep the text — losing a composed prompt to a silent failure is
            // far worse than an extra dialog.
            let alert = NSAlert()
            alert.messageText = "发送失败"
            alert.informativeText =
                (AppleScriptRunner.lastError ?? "未知错误")
                + "\n\n编辑器内容已保留。若是权限问题，请到「系统设置 → 隐私与安全性 → 自动化」，"
                + "允许「Claude Command Bar」控制 Terminal 与 System Events。"
            alert.runModal()
            return
        }
        HistoryStore.add(text)
        textView.string = ""
        // Sending is the end of the interaction — the panel has nothing left to
        // show, and Terminal is now frontmost anyway. Failures keep it open.
        orderOut(nil)
    }

    /// Boxed payload for the tab-picker menu items.
    private final class Delivery: NSObject {
        let text: String
        let target: TerminalSender.Target
        init(text: String, target: TerminalSender.Target) {
            self.text = text
            self.target = target
        }
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private let onChange: () -> Void
    private let summonPopup = NSPopUpButton()
    private let finderPopup = NSPopUpButton()
    private let historyPopup = NSPopUpButton()
    private let widthPopup = NSPopUpButton()

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func show() {
        if window == nil { build() }
        syncFromSettings()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        for m in ModifierChoice.allCases {
            summonPopup.addItem(withTitle: m.displayName)
            finderPopup.addItem(withTitle: m.displayName)
        }
        for n in [10, 20, 50, 100, 200] { historyPopup.addItem(withTitle: "\(n)") }
        for w in [20, 30, 40, 60, 80] { widthPopup.addItem(withTitle: "\(w)") }
        for popup in [summonPopup, finderPopup, historyPopup, widthPopup] {
            popup.target = self
            popup.action = #selector(changed)
        }

        func row(_ label: String, _ control: NSView) -> [NSView] {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            return [l, control]
        }
        let grid = NSGridView(views: [
            row("双击呼出编辑器：", summonPopup),
            row("双击插入 Finder 选中项：", finderPopup),
            row("历史保留条数：", historyPopup),
            row("菜单标题最大字数：", widthPopup),
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        let note = NSTextField(wrappingLabelWithString:
            "两个双击手势请用不同的修饰键，否则会冲突。改动即时生效。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "设置"
        w.isReleasedWhenClosed = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        w.contentView = content
        window = w
    }

    private func syncFromSettings() {
        summonPopup.selectItem(at: ModifierChoice.allCases.firstIndex(of: Settings.summonModifier) ?? 0)
        finderPopup.selectItem(at: ModifierChoice.allCases.firstIndex(of: Settings.finderModifier) ?? 0)
        historyPopup.selectItem(withTitle: "\(Settings.historyLimit)")
        widthPopup.selectItem(withTitle: "\(Settings.labelWidth)")
    }

    @objc private func changed() {
        Settings.summonModifier = ModifierChoice.allCases[summonPopup.indexOfSelectedItem]
        Settings.finderModifier = ModifierChoice.allCases[finderPopup.indexOfSelectedItem]
        if let n = Int(historyPopup.titleOfSelectedItem ?? "") { Settings.historyLimit = n }
        if let w = Int(widthPopup.titleOfSelectedItem ?? "") { Settings.labelWidth = w }
        onChange()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let panel = EditorPanel()
    private var summonMonitor: DoubleTapMonitor?
    private var finderMonitor: DoubleTapMonitor?
    private var screenshotWatcher: ScreenshotWatcher!
    private lazy var settingsController = SettingsWindowController { [weak self] in
        self?.restartMonitors()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        restartMonitors()

        screenshotWatcher = ScreenshotWatcher { [weak self] url in
            guard let self = self else { return }
            if !self.panel.isVisible { self.panel.showAndFocus() }
            self.panel.insertAtCursor(PathFormat.forInsertion(url.path) + "\n")
        }
        screenshotWatcher.start()

        ensureAccessibilityPermission()
    }

    /// (Re)create the double-tap monitors from the current settings.
    private func restartMonitors() {
        summonMonitor?.stop()
        finderMonitor?.stop()
        let summon = Settings.summonModifier
        summonMonitor = DoubleTapMonitor(
            keyCodes: summon.keyCodes, flag: summon.flag,
            interval: Settings.doubleTapInterval) { [weak self] in self?.onSummon() }
        summonMonitor?.start()
        let finder = Settings.finderModifier
        finderMonitor = DoubleTapMonitor(
            keyCodes: finder.keyCodes, flag: finder.flag,
            interval: Settings.doubleTapInterval) { [weak self] in self?.onFinderPaste() }
        finderMonitor?.start()
    }

    /// An accessory (LSUIElement) app has no menu bar, but a main menu is still
    /// needed for the standard editing key-equivalents (⌘A/⌘C/⌘V/⌘X/⌘Z) to
    /// reach the text view.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let icon = NSImage(contentsOf: url) {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = false  // keep the colored app-icon look
                button.image = icon
            } else {
                button.image = NSImage(
                    systemSymbolName: "text.cursor", accessibilityDescription: "Claude Command Bar")
            }
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuild the menu each time it opens so the history section stays fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = menu.addItem(withTitle: "打开编辑器", action: #selector(showEditor), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())

        let history = HistoryStore.items
        if history.isEmpty {
            let empty = menu.addItem(withTitle: "（暂无历史）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        } else {
            let header = menu.addItem(withTitle: "历史（点击填入编辑器）", action: nil, keyEquivalent: "")
            header.isEnabled = false
            for (i, text) in history.enumerated() {
                let oneLine = text.replacingOccurrences(of: "\n", with: " ")
                let item = menu.addItem(
                    withTitle: TerminalSender.truncate(oneLine, max: 50),
                    action: #selector(pickHistory(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
            }
            menu.addItem(.separator())
            let clear = menu.addItem(withTitle: "清空历史", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
        }
        menu.addItem(.separator())
        let shot = menu.addItem(
            withTitle: "截图后立即插入（关闭悬浮缩略图）",
            action: #selector(toggleScreenshotThumbnail), keyEquivalent: "")
        shot.target = self
        shot.state = ScreenshotThumbnail.isDisabled ? .on : .off
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc private func showEditor() { panel.showAndFocus() }

    @objc private func pickHistory(_ sender: NSMenuItem) {
        let items = HistoryStore.items
        guard sender.tag >= 0, sender.tag < items.count else { return }
        panel.showAndFocus()
        panel.setText(items[sender.tag])
    }

    @objc private func clearHistory() { HistoryStore.clear() }

    @objc private func openSettings() { settingsController.show() }

    /// Toggle macOS's screenshot floating thumbnail so captures save — and get
    /// inserted — immediately instead of after the ~5s preview.
    @objc private func toggleScreenshotThumbnail() {
        ScreenshotThumbnail.setDisabled(!ScreenshotThumbnail.isDisabled)
    }

    /// Double-tap Control always shows/focuses the editor (never hides it —
    /// Escape is the only hide gesture) and inserts the frontmost selection if
    /// there is one.
    private func onSummon() {
        let selection = SelectionReader.grab()
        panel.showAndFocus()
        if let selection = selection {
            let clean = selection.trimmingTrailingNewlines()
            if !clean.isEmpty { panel.insertAtCursor(clean + "\n") }
        }
    }

    /// Double-tap Option: insert the current Finder selection's paths.
    private func onFinderPaste() {
        let paths = FinderSelection.paths()
        guard !paths.isEmpty else { NSSound.beep(); return }
        let joined = paths.map { PathFormat.forInsertion($0) }.joined(separator: "\n")
        panel.showAndFocus()
        panel.insertAtCursor(joined + "\n")
    }

    private func ensureAccessibilityPermission() {
        // Don't use the auto-prompting variant (it re-pops the system dialog on
        // every launch); check silently and guide the user ourselves.
        guard !AXIsProcessTrusted() else { return }
        let alert = NSAlert()
        alert.messageText = "需要「辅助功能」权限"
        alert.informativeText =
            "双击 Control 呼出、读取选中文本都依赖全局键盘监听。\n"
            + "请在「辅助功能」列表中勾选「Claude Command Bar」。若已勾选仍提示，"
            + "请先移除旧条目再重新添加本 App。"
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
