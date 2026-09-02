// PromptQy — a menu-bar-resident, always-on-top text composer for
// feeding prompts, file paths, selections and screenshots into a terminal
// running Claude Code.
//
// Stages implemented:
//   1. Menu-bar item + always-on-top draggable/resizable editor + double-tap
//      Control to summon/dismiss.
//   2. Grab the frontmost app's selection on summon (AX, then synthesized
//      Cmd+C) + a Send button that pastes+Returns into a chosen Terminal.app,
//      iTerm2, or Otty tab.
//   3. Drag files onto the editor to insert their paths.
//   4. Watch the screenshot folder and insert the path of new screenshots.
//   5. Push-to-talk dictation: hold a key (default right Option) to stream
//      speech recognition into the editor via SFSpeechRecognizer.
//   6. Quick phrases: preset text snippets in the menu bar, one-click insert
//      with ⌃1–⌃9 keyboard shortcuts; editable in Settings.
//   7. Double-tap Option to search Obsidian/.md notes: floating Spotlight-like
//      panel with Markdown preview (select/copy, jump to first match); vault
//      path + exclude dirs configurable in Settings.
//
// Build via ./build_app.sh.

import Cocoa
import ApplicationServices
import Speech
import AVFoundation
import WebKit

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
    static var searchModifier: ModifierChoice {
        get { ModifierChoice(rawValue: d.string(forKey: "searchModifier") ?? "") ?? .option }
        set { d.set(newValue.rawValue, forKey: "searchModifier") }
    }
    static var openModifier: ModifierChoice {
        get { ModifierChoice(rawValue: d.string(forKey: "openModifier") ?? "") ?? .command }
        set { d.set(newValue.rawValue, forKey: "openModifier") }
    }
    /// Root folder of the Markdown notes vault (e.g. Obsidian iCloud path).
    static var notesVaultPath: String {
        get {
            if let s = d.string(forKey: "notesVaultPath"), !s.isEmpty { return s }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Mobile Documents/iCloud~md~obsidian/Documents").path
        }
        set { d.set(newValue, forKey: "notesVaultPath") }
    }
    /// Relative directory names/paths to skip while indexing notes.
    static var notesExcludeDirs: [String] {
        get {
            guard let raw = d.string(forKey: "notesExcludeDirs") else {
                return [".obsidian", ".trash"]
            }
            return raw.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set { d.set(newValue.joined(separator: "\n"), forKey: "notesExcludeDirs") }
    }
    static var historyLimit: Int {
        get { let v = d.integer(forKey: "historyLimit"); return v > 0 ? v : 50 }
        set { d.set(newValue, forKey: "historyLimit") }
    }
    static var labelWidth: Int {
        get { let v = d.integer(forKey: "labelWidth"); return v > 0 ? v : 40 }
        set { d.set(newValue, forKey: "labelWidth") }
    }
    /// Which terminal to send to. `nil` means auto: offer whichever are running.
    static var terminalApp: TerminalApp? {
        get { TerminalApp(rawValue: d.string(forKey: "terminalApp") ?? "") }
        set { d.set(newValue?.rawValue ?? "auto", forKey: "terminalApp") }
    }
    /// Key code to hold for push-to-talk dictation. 0x3D = right Option (default).
    static var dictationKeyCode: UInt16 {
        get { let v = d.integer(forKey: "dictationKeyCode"); return v != 0 ? UInt16(v) : 0x3D }
        set { d.set(Int(newValue), forKey: "dictationKeyCode") }
    }
    /// Quick phrases shown in the menu bar for one-click insertion.
    /// Stored as a newline-separated string in UserDefaults so it's easy to edit
    /// in the settings panel with a plain text view.
    static var quickPhrases: [String] {
        get {
            let raw = d.string(forKey: "quickPhrases") ?? ""
            let lines = raw.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !lines.isEmpty { return lines }
            return [
                "如果有任何疑问先向我提问",
                "请用中文回答",
                "不要过度设计，保持简洁",
            ]
        }
        set { d.set(newValue.joined(separator: "\n"), forKey: "quickPhrases") }
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

// MARK: - External editor

/// Opens paths in Sublime Text. Sublime ships a different bundle id per major
/// version, and installs that predate the App Store build have none of them —
/// so probe the ids, then the conventional install path, and only give up after
/// that.
enum ExternalEditor {
    static let displayName = "Sublime Text"
    private static let bundleIDs = ["com.sublimetext.4", "com.sublimetext.3", "com.sublimetext"]
    private static let fallbackPath = "/Applications/Sublime Text.app"

    static var appURL: URL? {
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        return FileManager.default.fileExists(atPath: fallbackPath)
            ? URL(fileURLWithPath: fallbackPath) : nil
    }

    /// Returns false when Sublime Text isn't installed (nothing is opened).
    static func open(_ paths: [String]) -> Bool {
        guard let app = appURL else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(
            paths.map { URL(fileURLWithPath: $0) },
            withApplicationAt: app,
            configuration: config)
        return true
    }
}

// MARK: - Terminal sender

/// The terminals we can drive. Both are scripted the same way — focus a tab,
/// then paste + Return — and only differ in how their windows are addressed.
enum TerminalApp: String, CaseIterable {
    case terminal
    case iterm
    case otty

    var bundleId: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .otty: return "io.appmakes.otty"
        }
    }

    var displayName: String {
        switch self {
        case .terminal: return "终端.app"
        case .iterm: return "iTerm2"
        case .otty: return "Otty"
        }
    }

    /// `tell application id …` *launches* the app if it isn't running, so every
    /// enumeration must be gated on this — otherwise merely pressing Send would
    /// boot up whichever terminal the user deliberately left closed.
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }
}

enum TerminalSender {
    struct Target {
        let app: TerminalApp
        let windowId: String
        let tabIndex: String
        /// iTerm2 splits a tab into panes and each is a separate destination.
        /// Empty for Terminal.app, which has no equivalent.
        let sessionId: String
        let label: String
    }

    /// One window/tab/pane as the enumeration scripts report it, before the
    /// labels are worked out (which needs the whole list for context).
    private struct Row {
        let app: TerminalApp
        let windowId: String
        let windowIndex: Int
        let tabIndex: Int
        let paneIndex: Int
        let sessionId: String
        let bounds: NSRect?
        let name: String
    }

    /// Cap a menu label to a sensible width; the tail (command + window size)
    /// is the least useful part, so truncate from the end.
    static func truncate(_ s: String, max: Int = 40) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }

    /// Targets across every terminal the user allows, ready for the picker.
    /// Honours the `terminalApp` setting; in auto mode both are offered.
    static func listTargets() -> [Target] {
        let wanted = Settings.terminalApp.map { [$0] } ?? TerminalApp.allCases
        var rows: [Row] = []
        var firstError: String?
        for app in wanted where app.isRunning {
            rows += enumerate(app)
            // One terminal failing (usually an un-granted automation prompt)
            // shouldn't hide the other's tabs — but keep the message around in
            // case *nothing* turned up and the user needs to know why.
            if firstError == nil { firstError = AppleScriptRunner.lastError }
        }
        AppleScriptRunner.lastError = rows.isEmpty ? firstError : nil
        return label(rows)
    }

    private static func enumerate(_ app: TerminalApp) -> [Row] {
        // NB: inside a `tell application` block the bareword `tab` resolves to
        // the app's *tab class*, not the tab character — so build the field
        // separator explicitly via `character id 9`.
        //
        // Both scripts emit the same 10 columns, with the free-text name last
        // so a stray tab in it can't shift the other fields.
        let body: String
        switch app {
        case .terminal, .otty:
            body = """
                    set winName to ""
                    try
                        set winName to name of w
                    end try
                    set tabList to tabs of w
                    set tabCount to count of tabList
                    repeat with ti from 1 to count of tabList
                        set t to item ti of tabList
                        set procText to ""
                        try
                            set AppleScript's text item delimiters to " "
                            set procText to (processes of t) as text
                            set AppleScript's text item delimiters to ""
                        end try
                        -- Terminal has no per-tab title: `custom title` is the
                        -- literal default ("终端") and `title displays custom
                        -- title` is true regardless, so both are useless. The
                        -- window name is what Claude Code sets — but it tracks
                        -- only the *selected* tab, so it can be trusted to name
                        -- a tab only when the window holds exactly one. Past
                        -- that, the running processes are all that is per-tab.
                        set rowName to ""
                        if tabCount is 1 then set rowName to winName
                        if rowName is "" then set rowName to procText
                        if rowName is "" then set rowName to winName
                        set end of outLines to wid & fieldSep & (wi as text) & fieldSep & (ti as text) & fieldSep & "1" & fieldSep & "" & fieldSep & geo & fieldSep & rowName
                    end repeat
            """
        case .iterm:
            body = """
                    set tabList to tabs of w
                    repeat with ti from 1 to count of tabList
                        set sesList to sessions of (item ti of tabList)
                        repeat with si from 1 to count of sesList
                            set s to item si of sesList
                            set rowName to ""
                            try
                                set rowName to name of s
                            end try
                            set end of outLines to wid & fieldSep & (wi as text) & fieldSep & (ti as text) & fieldSep & (si as text) & fieldSep & (id of s) & fieldSep & geo & fieldSep & rowName
                        end repeat
                    end repeat
            """
        }
        let script = """
        set fieldSep to (character id 9)
        set rowSep to (character id 10)
        tell application id "\(app.bundleId)"
            set outLines to {}
            set winList to windows
            repeat with wi from 1 to count of winList
                set w to item wi of winList
                set wid to (id of w) as text
                -- `bounds` is the only geometry both apps agree on; iTerm2's
                -- `frame`/`position` raise -10000. Coordinates are global with
                -- the origin at the top-left of the primary screen.
                set bl to 0
                set bt to 0
                set br to 0
                set bb to 0
                try
                    set {bl, bt, br, bb} to bounds of w
                end try
                set geo to (bl as text) & fieldSep & (bt as text) & fieldSep & (br as text) & fieldSep & (bb as text)
        \(body)
            end repeat
            set AppleScript's text item delimiters to rowSep
            return outLines as text
        end tell
        """
        guard let out = AppleScriptRunner.run(script), !out.isEmpty else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let p = line.components(separatedBy: "\t")
            guard p.count >= 10,
                  let wi = Int(p[1]), let ti = Int(p[2]), let si = Int(p[3]) else { return nil }
            var bounds: NSRect?
            if let l = Double(p[5]), let t = Double(p[6]),
               let r = Double(p[7]), let b = Double(p[8]), r > l, b > t {
                bounds = NSRect(x: l, y: t, width: r - l, height: b - t)
            }
            return Row(app: app, windowId: p[0], windowIndex: wi, tabIndex: ti, paneIndex: si,
                       sessionId: p[4], bounds: bounds,
                       name: p[9...].joined(separator: " ").trimmingCharacters(in: .whitespaces))
        }
    }

    /// Which display a window sits on, for labelling. Nil on a single-screen
    /// setup, where naming the screen would be noise.
    private static func screenName(_ bounds: NSRect?) -> String? {
        let screens = NSScreen.screens
        guard screens.count > 1, let bounds = bounds, let primary = screens.first else { return nil }
        // AppleScript reports top-left-origin coordinates; NSScreen frames are
        // bottom-left-origin off the primary screen. Flip before hit-testing.
        let center = NSPoint(x: bounds.midX, y: primary.frame.maxY - bounds.midY)
        return screens.first { $0.frame.contains(center) }?.localizedName
    }

    /// Name each target, adding only the qualifiers that are actually needed to
    /// tell it apart: with one window and one tab, "窗口 1 · 标签 1" is noise.
    private static func label(_ rows: [Row]) -> [Target] {
        let windowsPerApp = Dictionary(grouping: rows, by: { $0.app })
            .mapValues { Set($0.map(\.windowId)).count }
        let tabsPerWindow = Dictionary(grouping: rows, by: { $0.windowId })
            .mapValues { Set($0.map(\.tabIndex)).count }
        let panesPerTab = Dictionary(grouping: rows, by: { "\($0.windowId)/\($0.tabIndex)" })
            .mapValues { $0.count }

        return rows.map { r in
            var name = r.name
            if name.isEmpty { name = "窗口 \(r.windowId)" }
            var quals: [String] = []
            if windowsPerApp[r.app, default: 1] > 1 { quals.append("窗口 \(r.windowIndex)") }
            if tabsPerWindow[r.windowId, default: 1] > 1 { quals.append("标签 \(r.tabIndex)") }
            if panesPerTab["\(r.windowId)/\(r.tabIndex)", default: 1] > 1 {
                quals.append("分屏 \(r.paneIndex)")
            }
            if let screen = screenName(r.bounds) { quals.append(screen) }
            // Truncate the free-text name only — the qualifiers are what make
            // the entry distinguishable, so they must survive.
            var label = truncate(name, max: Settings.labelWidth)
            if !quals.isEmpty { label += "  ·  " + quals.joined(separator: " · ") }
            return Target(app: r.app, windowId: r.windowId, tabIndex: "\(r.tabIndex)",
                          sessionId: r.sessionId, label: label)
        }
    }

    /// Send is usually triggered by ⌘↵, so the user is often still physically
    /// holding ⌘ (and maybe ⇧/⌥) when we synthesize the paste. A lingering ⌘
    /// turns our Return into ⌘↵ — which Claude Code won't submit — and can
    /// corrupt the ⌘V too. Wait for every modifier to come back up; fail rather
    /// than proceeding while they're still down (the old timeout-and-continue
    /// path was a silent source of "sent but empty" reports).
    private static func waitForModifiersReleased(timeout: TimeInterval = 1.2) -> Bool {
        let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSEvent.modifierFlags.intersection(watched).isEmpty { return true }
            usleep(10_000)
        }
        return NSEvent.modifierFlags.intersection(watched).isEmpty
    }

    /// Select the target window/tab/pane. Keystrokes are posted separately —
    /// this script only moves focus inside the terminal app.
    ///
    /// Focusing differs: Terminal.app selects a tab and raises the window by
    /// property; iTerm2 has a `select` verb that walks window → tab → pane.
    /// (iTerm2 also has `write text`, which needs no focus at all — but it
    /// replays embedded newlines as Return presses, so a multi-line prompt
    /// would submit itself line by line. Pasting keeps it intact, because
    /// the terminal wraps a real ⌘V in bracketed paste.)
    private static func focusTab(_ target: Target) -> Bool {
        let focus: String
        switch target.app {
        case .terminal:
            focus = """
            set selected of tab \(target.tabIndex) of targetWin to true
            set frontmost of targetWin to true
            """
        case .otty:
            // Otty's AppleScript matches Terminal.app but rejects
            // `frontmost of window`; activate (below in send()) raises it.
            focus = """
            set selected of tab \(target.tabIndex) of targetWin to true
            """
        case .iterm:
            focus = """
            select targetWin
            select tab \(target.tabIndex) of targetWin
            select session id "\(target.sessionId)" of tab \(target.tabIndex) of targetWin
            """
        }
        let script = """
        tell application id "\(target.app.bundleId)"
            set targetWin to window id \(target.windowId)
            try
                set miniaturized of targetWin to false
            end try
        \(focus)
        end tell
        """
        return AppleScriptRunner.succeeds(script)
    }

    /// Wait until LaunchServices agrees the target owns the front. System
    /// Events' `frontmost of process` (AX) can flip true while *we* are still
    /// the LaunchServices-active app — and synthetic keystrokes follow LS, not
    /// AX. Polling the wrong frontness is how pastes silently land in our own
    /// floating editor (⌘V into text we already hold → no visible change →
    /// caller clears the prompt thinking it succeeded).
    private static func waitUntilFrontmost(_ app: TerminalApp, timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app.bundleId {
                return true
            }
            usleep(20_000)
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app.bundleId
    }

    /// Post a key chord through the HID tap so it reaches whichever app is
    /// actually frontmost (same path SelectionReader uses for ⌘C).
    private static func postKey(_ virtualKey: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Put the text on the clipboard, focus the target tab, then paste + Return.
    /// Returns false (with `AppleScriptRunner.lastError` set) if anything failed,
    /// so the caller can keep the text instead of silently dropping it.
    ///
    /// Caller must already have resigned our own key focus (`orderOut` +
    /// `NSApp.deactivate`); otherwise the terminal can never become the
    /// LaunchServices-frontmost app and the paste vanishes into us.
    static func send(_ text: String, to target: Target) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            AppleScriptRunner.lastError = "无法写入剪贴板"
            return false
        }

        guard waitForModifiersReleased() else {
            AppleScriptRunner.lastError =
                "修饰键仍按着（⌘/⌥/⌃/⇧）。请松开后再发送，否则粘贴/回车会被改写。"
            return false
        }

        guard focusTab(target) else { return false }

        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: target.app.bundleId).first else {
            AppleScriptRunner.lastError = "\(target.app.displayName) 已退出"
            return false
        }
        // IgnoringOtherApps is required for an LSUIElement sender: without it,
        // activate is a no-op when another "real" app is already active.
        running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        guard waitUntilFrontmost(target.app) else {
            AppleScriptRunner.lastError =
                "\(target.app.displayName) 窗口未能切到前台，内容已保留，请重试。"
            return false
        }

        // Tab selection + activate both settle asynchronously; a short beat
        // after LS-frontmost keeps ⌘V from landing on a half-focused pane.
        usleep(100_000)

        // Clipboard can be stolen between setString and paste (clipboard
        // managers, other monitors). Refuse rather than pasting the wrong thing
        // and then clearing the editor.
        guard pb.string(forType: .string) == text else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            AppleScriptRunner.lastError =
                "剪贴板在发送前被其他程序改写，内容已保留，请重试。"
            return false
        }

        // 0x09 = 'v', 0x24 = Return. HID tap, not System Events keystroke —
        // the latter has no target and races the same AX/LS frontmost split.
        postKey(0x09, flags: .maskCommand)

        // Bracketed paste needs a moment before Return, else Claude Code sees
        // an empty submit and the paste arrives after. Scale lightly with size.
        let pasteSettle = UInt32(min(500_000, 60_000 + text.utf8.count * 20))
        usleep(pasteSettle)

        postKey(0x24, flags: [])
        return true
    }
}

// MARK: - Screenshot watcher

/// Watches the macOS screenshot folder and reports newly written image files,
/// so Cmd+Shift+4 captures can drop their path straight into the editor.
///
/// Directory vnode events miss in-place overwrites of an existing filename, so
/// a short poll also compares mtimes against a per-path baseline. A brief
/// per-path debounce absorbs mtime jitter from a single capture (vnode + poll)
/// so a new filename inserts only once.
final class ScreenshotWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pollTimer: Timer?
    private var dir: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Last mtime we reported (or seeded at start) per path; pruned against
    /// the current directory listing so it cannot grow without bound.
    private var lastNotifiedMtime: [String: Date] = [:]
    /// When we last inserted each path; used to debounce multi-event captures.
    private var lastNotifiedAt: [String: Date] = [:]
    /// Ignore further mtime bumps for the same path within this window so one
    /// new capture inserts once; later overwrites still notify after it ends.
    private let notifyDebounce: TimeInterval = 3
    private let onNew: (URL) -> Void

    init(onNew: @escaping (URL) -> Void) {
        self.onNew = onNew
    }

    /// Stop watching. Safe to call when not started.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        source?.setEventHandler {}
        source?.setCancelHandler {}
        source?.cancel()
        source = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    /// (Re)start watching `ScreenshotLocation.url`. Call after the save path
    /// changes so new captures are still picked up.
    func start() {
        stop()
        dir = ScreenshotLocation.url
        // Seed baselines for files already on disk so we only react to later
        // writes (including overwrites of the same name).
        lastNotifiedMtime = [:]
        lastNotifiedAt = [:]
        for name in currentImages() {
            let url = dir.appendingPathComponent(name)
            lastNotifiedMtime[url.path] = mtime(url)
        }
        fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("ScreenshotWatcher: cannot open \(dir.path)")
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler { [weak self] in self?.scan() }
        source = s
        s.resume()
        // In-place overwrite does not always dirty the directory vnode; poll
        // mtimes so same-name rewrites still insert their path.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.scan()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
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
        // Drop entries for files that no longer exist in the folder.
        let livePaths = Set(now.map { dir.appendingPathComponent($0).path })
        lastNotifiedMtime = lastNotifiedMtime.filter { livePaths.contains($0.key) }
        lastNotifiedAt = lastNotifiedAt.filter { livePaths.contains($0.key) }

        // React to fresh writes — both new filenames and overwrites of existing
        // ones. Ignore files merely moved/copied in (stale mtime).
        let candidates = now.compactMap { name -> URL? in
            let url = dir.appendingPathComponent(name)
            let path = url.path
            let mod = mtime(url)
            guard Date().timeIntervalSince(mod) < 10 else { return nil }
            // Same capture often bumps mtime several times (write + rename +
            // metadata + poll). Absorb those without a second insert.
            if let notifiedAt = lastNotifiedAt[path],
               Date().timeIntervalSince(notifiedAt) < notifyDebounce {
                if mod > (lastNotifiedMtime[path] ?? .distantPast) {
                    lastNotifiedMtime[path] = mod
                }
                return nil
            }
            if let last = lastNotifiedMtime[path], mod <= last { return nil }
            return url
        }
        guard let newest = candidates.max(by: { mtime($0) < mtime($1) }) else { return }
        let path = newest.path
        let mod = mtime(newest)
        lastNotifiedMtime[path] = mod
        lastNotifiedAt[path] = Date()
        onNew(newest)
    }

    private func mtime(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
            as? Date) ?? .distantPast
    }
}

// MARK: - Screenshot preferences (system `com.apple.screencapture`)

/// Shared reload for screencapture prefs. Writing the domain alone is not
/// enough — SystemUIServer caches the values until restarted.
private enum ScreenshotPrefs {
    static let domain = "com.apple.screencapture"

    static func reloadService() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["SystemUIServer"]
        try? p.run()
        // Newer macOS keeps a separate UI helper that also caches location.
        let ui = Process()
        ui.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        ui.arguments = ["screencaptureui"]
        try? ui.run()
    }
}

/// macOS ⌘⇧3 / ⌘⇧4 save directory. Persisted in the system screencapture
/// domain (survives reboot); we read/write it and restart the screenshot
/// service so the change applies immediately.
enum ScreenshotLocation {
    private static let key = "location"

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
    }

    static var url: URL {
        if let loc = UserDefaults(suiteName: ScreenshotPrefs.domain)?
            .string(forKey: key), !loc.isEmpty {
            return URL(fileURLWithPath: (loc as NSString).expandingTildeInPath)
        }
        return defaultURL
    }

    /// Home-relative display form (`~/Desktop/...`) for the settings row.
    static var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        if p == home { return "~" }
        if p.hasPrefix(home + "/") {
            return "~" + p.dropFirst(home.count)
        }
        return p
    }

    /// Write the system screenshot location. Returns false if `url` is not an
    /// existing directory. Survives reboot via the screencapture defaults domain.
    @discardableResult
    static func setURL(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        UserDefaults(suiteName: ScreenshotPrefs.domain)?.set(resolved.path, forKey: key)
        UserDefaults(suiteName: ScreenshotPrefs.domain)?.synchronize()
        ScreenshotPrefs.reloadService()
        return true
    }
}

/// Toggles macOS's screenshot floating thumbnail. While the thumbnail is shown
/// (the default), the capture is held in memory for ~5s and only written to disk
/// after it dismisses — so our watcher can't insert the path until then.
/// Turning it off makes captures save (and insert) immediately.
enum ScreenshotThumbnail {
    private static let key = "show-thumbnail"

    /// True when the thumbnail is disabled (i.e. captures save immediately).
    static var isDisabled: Bool {
        guard let v = UserDefaults(suiteName: ScreenshotPrefs.domain)?
            .object(forKey: key) as? Bool
        else { return false }  // unset ⇒ thumbnail shown ⇒ not disabled
        return v == false
    }

    static func setDisabled(_ disabled: Bool) {
        UserDefaults(suiteName: ScreenshotPrefs.domain)?.set(!disabled, forKey: key)
        ScreenshotPrefs.reloadService()
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
    private var monitors: [Any] = []

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
        stop()  // avoid stacking monitors if start() is called twice
        add(.flagsChanged) { [weak self] event in self?.handle(event) }
        // A modifier held down for a shortcut produces a press edge too, so ⌘C
        // then ⌘V (or ⌃C twice in a terminal), and ⌘-clicking two files in
        // Finder, both look exactly like a deliberate double-tap. A key or click
        // in between proves the taps weren't standalone — break the streak.
        // Without this, Command is unusable as a gesture: ⌘-click is how you
        // multi-select the very files this gesture is meant to open.
        add([.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in self?.lastPress = 0
        }
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ handle: @escaping (NSEvent) -> Void) {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: {
            handle($0)
            return $0
        }) {
            monitors.append(l)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
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

// MARK: - Voice recognizer

/// Thin wrapper around SFSpeechRecognizer + AVAudioEngine for real-time,
/// streaming dictation. Supports push-to-talk via partial/final callbacks.
final class VoiceRecognizer: NSObject, SFSpeechRecognizerDelegate {
    private let speechRecognizer: SFSpeechRecognizer
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Called on the main thread with partial (in-progress) transcription.
    var onPartialResult: ((String) -> Void)?
    /// Called on the main thread with the final transcription.
    var onFinalResult: ((String) -> Void)?
    /// Called when recording state changes (started / stopped).
    var onStateChange: ((Bool) -> Void)?
    /// Called on error (permission denied, network, etc.).
    var onError: ((String) -> Void)?

    var isRecording: Bool { audioEngine.isRunning }

    init(locale: Locale = Locale(identifier: "zh-CN")) {
        speechRecognizer = SFSpeechRecognizer(locale: locale)!
        super.init()
        speechRecognizer.delegate = self
    }

    /// Request speech-recognition authorization. Must be called before recording.
    /// The system also prompts for microphone permission on first use of
    /// AVAudioEngine.inputNode.
    static func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    static var permissionStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    func startRecording() throws {
        // Cancel any previous task
        recognitionTask?.cancel()
        recognitionTask = nil

        // Tapping inputNode triggers the system microphone permission prompt.
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Create a fresh recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "VoiceRecognizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建语音识别请求"])
        }
        recognitionRequest.shouldReportPartialResults = true
        // Disable automatic punctuation on macOS — Chinese output often
        // inserts unwanted full-width punctuation mid-phrase.
        if #available(macOS 15, *) {
            // macOS 15 added taskHint; default (.unspecified) is fine.
        }

        recognitionTask = speechRecognizer.recognitionTask(
            with: recognitionRequest
        ) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { self.onError?(error.localizedDescription) }
                return
            }
            if let result = result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    DispatchQueue.main.async { self.onFinalResult?(text) }
                } else {
                    DispatchQueue.main.async { self.onPartialResult?(text) }
                }
            }
        }

        // Feed audio buffers into the recognition request.
        inputNode.installTap(onBus: 0, bufferSize: 1024,
                             format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        onStateChange?(true)
    }

    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        // Don't cancel the task — let it deliver final results.
        onStateChange?(false)
    }

    /// Abort entirely (e.g. on permission error). Cancels task, tears down audio.
    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest = nil
        onStateChange?(false)
    }

    // MARK: SFSpeechRecognizerDelegate

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer,
                          availabilityDidChange available: Bool) {
        if !available { onError?("语音识别服务暂不可用") }
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
    private let voiceRecognizer = VoiceRecognizer()
    private var dictationMonitor: Any?
    /// Range in the text view that holds the current partial dictation result,
    /// so successive partials can replace it in-place.
    private var dictationPendingRange: NSRange?
    private var recordingDot: NSView!       // red pulsing dot
    private var recordingLabel: NSTextField! // "录音中…"
    private var hintLabel: NSTextField!      // idle hint text

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        title = "PromptQy"
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 320, height: 160)
        setFrameAutosaveName("ClaudeCommandBarEditorFrame")

        buildContent()
        setupDictation()
    }

    override var canBecomeKey: Bool { true }

    /// Escape must hide the panel even when the text view isn't first responder
    /// (e.g. focus landed on the title bar, the Send button, or was dropped when
    /// a popup menu closed). EditorTextView handles the common case; this is the
    /// responder-chain backstop.
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    /// ⌘W (and the red traffic-light) should hide, not destroy — the panel is
    /// reused across summons (`isReleasedWhenClosed = false`).
    override func close() { orderOut(nil) }

    private func buildContent() {
        let container = NSView()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        textView.autoresizingMask = [.width]
        textView.isRichText = false
        // Off by default on a bare NSTextView: without it nothing is registered
        // with the undo manager and the Edit menu's ⌘Z is a no-op.
        textView.allowsUndo = true
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

        // Recording indicator: red dot + label, shown only while recording.
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        recordingDot = dot

        recordingLabel = NSTextField(labelWithString: "录音中…")
        recordingLabel.font = .systemFont(ofSize: 10)
        recordingLabel.textColor = .systemRed
        recordingLabel.translatesAutoresizingMaskIntoConstraints = false

        let recordStack = NSStackView(views: [dot, recordingLabel])
        recordStack.orientation = .horizontal
        recordStack.spacing = 4
        recordStack.alignment = .centerY
        recordStack.translatesAutoresizingMaskIntoConstraints = false
        recordStack.isHidden = true

        hintLabel = NSTextField(labelWithString: "⌘↵ 发送 · 拖文件插路径 · 按住右 ⌥ 语音录入")
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(recordStack)
        bar.addSubview(hintLabel)
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

            recordStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            recordStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            hintLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            hintLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            hintLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: sendButton.leadingAnchor, constant: -8),

            sendButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
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

    /// Show the floating editor without activating the app. Used when a
    /// screenshot path is auto-inserted so Finder's "Replace?" rename dialog
    /// is not interrupted (and shown again).
    func showWithoutActivating() {
        orderFrontRegardless()
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

    // MARK: Dictation (push-to-talk)

    private func setupDictation() {
        voiceRecognizer.onPartialResult = { [weak self] text in
            self?.applyDictationPartial(text)
        }
        voiceRecognizer.onFinalResult = { [weak self] text in
            self?.applyDictationFinal(text)
        }
        voiceRecognizer.onError = { [weak self] msg in
            self?.onDictationError(msg)
        }
        voiceRecognizer.onStateChange = { [weak self] recording in
            self?.updateRecordingIndicator(recording)
        }

        // Local monitor: fires when PromptQy is the active app (editor focused).
        // We watch both flagsChanged (for modifier keys like right Option) and
        // keyDown/keyUp (for regular keys like F4/F5).  When a key is configured
        // as a modifier we must use flagsChanged because modifiers don't send
        // keyDown/keyUp to the responder chain.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        dictationMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            guard let self = self else { return event }
            let target = Settings.dictationKeyCode

            // Modifier keys only send flagsChanged — keyDown/keyUp never fire.
            if event.type == .flagsChanged, event.keyCode == target,
               self.isModifierKey(target) {
                let pressed = event.modifierFlags.contains(self.flag(for: target))
                if pressed { self.startDictation() }
                else       { self.stopDictation() }
                return event  // modifiers are non-consumable; let them flow
            }

            // Regular keys: keyDown starts, keyUp stops. Consume so the editor
            // doesn't insert the character.
            if event.type == .keyDown, event.keyCode == target,
               !event.isARepeat, !self.isModifierKey(target) {
                self.startDictation()
                return nil  // swallow the key
            }
            if event.type == .keyUp, event.keyCode == target,
               !self.isModifierKey(target) {
                self.stopDictation()
                return nil  // swallow the key
            }

            return event
        }
    }

    /// Start recording. No-op if already recording.
    private func startDictation() {
        guard !voiceRecognizer.isRecording else { return }
        dictationPendingRange = nil
        do {
            try voiceRecognizer.startRecording()
        } catch {
            voiceRecognizer.onError?(error.localizedDescription)
        }
    }

    private func stopDictation() {
        guard voiceRecognizer.isRecording else { return }
        voiceRecognizer.stopRecording()
    }

    /// Insert (or replace) a partial transcription at the cursor.
    private func applyDictationPartial(_ text: String) {
        guard !text.isEmpty else { return }
        let tv = textView
        if let range = dictationPendingRange,
           range.location + range.length <= (tv.string as NSString).length {
            tv.replaceCharacters(in: range, with: text)
        } else {
            let cursor = tv.selectedRange().location
            tv.insertText(text, replacementRange: tv.selectedRange())
            dictationPendingRange = NSRange(location: cursor, length: 0)
        }
        dictationPendingRange = NSRange(
            location: dictationPendingRange!.location,
            length: (text as NSString).length)
        // Keep cursor after the inserted text.
        let end = dictationPendingRange!.location + dictationPendingRange!.length
        tv.setSelectedRange(NSRange(location: end, length: 0))
    }

    /// Finalize the dictation — replace any pending partial with the final text.
    private func applyDictationFinal(_ text: String) {
        guard !text.isEmpty else { dictationPendingRange = nil; return }
        if let range = dictationPendingRange,
           range.location + range.length <= (textView.string as NSString).length {
            textView.replaceCharacters(in: range, with: text)
        } else {
            textView.insertText(text, replacementRange: textView.selectedRange())
        }
        dictationPendingRange = nil
    }

    private func onDictationError(_ msg: String) {
        dictationPendingRange = nil
        voiceRecognizer.cancel()
        // Don't show an alert for transient network errors — just let the user
        // try again. Only surface hard failures (permission, no recognizer).
        let hard = msg.contains("permission") || msg.contains("授权")
            || msg.contains("not authorized") || msg.contains("不可用")
        guard hard else { return }
        let alert = NSAlert()
        alert.messageText = "语音录入失败"
        alert.informativeText = msg
            + "\n\n请到「系统设置 → 隐私与安全性 → 语音识别」授权 PromptQy。"
        alert.runModal()
    }

    /// Show/hide the recording indicator with a pulsing red dot.
    private func updateRecordingIndicator(_ recording: Bool) {
        guard let dot = recordingDot,
              let hint = hintLabel,
              let stack = dot.superview as? NSStackView else { return }
        stack.isHidden = !recording
        hint.isHidden = recording

        if recording {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.15
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer?.add(pulse, forKey: "pulse")
        } else {
            dot.layer?.removeAnimation(forKey: "pulse")
        }
    }

    /// Whether the given key code belongs to a modifier key.
    private func isModifierKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55,   // Command (left, right)
             56, 60,   // Shift (left, right)
             58, 61,   // Option (left, right)
             59, 62,   // Control (left, right)
             63:       // fn
            return true
        default:
            return false
        }
    }

    /// Map a modifier key code to its NSEvent.ModifierFlags value.
    private func flag(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        default:     return []
        }
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
            // Name what was actually looked at: "no window found" is baffling
            // when the setting quietly pinned the search to the other terminal.
            let scope = Settings.terminalApp.map { $0.displayName }
                ?? TerminalApp.allCases.map { $0.displayName }.joined(separator: " / ")
            let alert = NSAlert()
            if let e = AppleScriptRunner.lastError {
                alert.messageText = "无法访问 \(scope)"
                alert.informativeText =
                    "AppleScript 错误：\(e)\n\n"
                    + "多半是自动化权限：请到「系统设置 → 隐私与安全性 → 自动化」，"
                    + "允许「PromptQy」控制终端与 System Events。"
            } else {
                alert.messageText = "未找到运行中的 \(scope) 窗口"
                alert.informativeText =
                    "请先打开一个 \(scope) 窗口（里面跑着 Claude Code），再发送。"
                    + (Settings.terminalApp == nil ? ""
                       : "\n\n当前设置只发送到 \(scope)，可在设置中改为「自动」。")
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
        // Only head the list with app names when both terminals are in it —
        // with one, every row would carry the same redundant banner.
        let grouped = Set(targets.map(\.app)).count > 1
        var currentApp: TerminalApp?
        for target in targets {
            if grouped && target.app != currentApp {
                if currentApp != nil { menu.addItem(.separator()) }
                let header = NSMenuItem(title: target.app.displayName, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                currentApp = target.app
            }
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
        // Resign key focus *before* activating the terminal. Our floating
        // panel otherwise stays the LaunchServices-active app while System
        // Events already reports the terminal as AX-frontmost — synthetic
        // keystrokes follow LS, land in our own editor (⌘V into text we
        // already hold → looks like a no-op), and we used to clear the prompt
        // thinking the paste succeeded.
        orderOut(nil)
        NSApp.deactivate()

        guard TerminalSender.send(text, to: target) else {
            // Keep the text — losing a composed prompt to a silent failure is
            // far worse than an extra dialog.
            showAndFocus()
            setText(text)
            let alert = NSAlert()
            alert.messageText = "发送失败"
            alert.informativeText =
                (AppleScriptRunner.lastError ?? "未知错误")
                + "\n\n编辑器内容已保留。若是权限问题，请到「系统设置 → 隐私与安全性 → 自动化」，"
                + "允许「PromptQy」控制 \(target.app.displayName) 与 System Events。"
            alert.runModal()
            return
        }
        HistoryStore.add(text)
        textView.string = ""
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

// MARK: - Markdown notes search

/// One hit from the vault. `rank` 0 = filename match (preferred), 1 = body only.
/// Body text is loaded on demand for preview — search only keeps metadata so a
/// large vault does not pin every note in RAM.
struct NoteHit {
    let url: URL
    let relativePath: String
    let title: String
    let rank: Int

    func loadBody() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// Scans a Markdown vault (Obsidian etc.) for `.md` files. Fine for ~hundreds
/// of notes — no persistent index.
enum MarkdownVault {
    static func search(query: String) -> [NoteHit] {
        let root = URL(fileURLWithPath: Settings.notesVaultPath, isDirectory: true)
        let excludes = Settings.notesExcludeDirs
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let qLower = q.lowercased()

        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        var hits: [NoteHit] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let name = url.lastPathComponent
                if shouldExclude(name: name, relative: relativePath(url, root: root), excludes: excludes) {
                    enumerator?.skipDescendants()
                }
                continue
            }
            // iCloud placeholder: "Note.md.icloud"
            if url.pathExtension.lowercased() == "icloud" { continue }
            guard url.pathExtension.lowercased() == "md" else { continue }

            let rel = relativePath(url, root: root)
            if shouldExclude(name: url.lastPathComponent, relative: rel, excludes: excludes) {
                continue
            }

            let title = url.deletingPathExtension().lastPathComponent

            if q.isEmpty {
                // Listing only — no file I/O.
                hits.append(NoteHit(url: url, relativePath: rel, title: title, rank: 0))
                continue
            }

            let nameHit = title.lowercased().contains(qLower)
                || rel.lowercased().contains(qLower)
            if nameHit {
                hits.append(NoteHit(url: url, relativePath: rel, title: title, rank: 0))
                continue
            }

            // Body match: read once to decide membership, discard the text.
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            guard body.lowercased().contains(qLower) else { continue }
            hits.append(NoteHit(url: url, relativePath: rel, title: title, rank: 1))
        }

        return hits.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func firstMatch(in body: String, matching needle: String) -> String? {
        let n = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        let lower = body.lowercased()
        guard let range = lower.range(of: n.lowercased()) else { return nil }
        return String(body[range])
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let full = url.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path
        if full.hasPrefix(prefix) {
            let drop = prefix.count + (prefix.hasSuffix("/") ? 0 : 1)
            return String(full.dropFirst(drop))
        }
        return url.lastPathComponent
    }

    private static func shouldExclude(name: String, relative: String, excludes: [String]) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        for raw in excludes {
            let ex = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard !ex.isEmpty else { continue }
            if name == ex { return true }
            if parts.contains(ex) { return true }
            if relative == ex || relative.hasPrefix(ex + "/") { return true }
        }
        return false
    }
}

/// Lightweight Markdown → HTML for the notes preview. Covers the Obsidian basics
/// (headings, emphasis, code, lists, links, wikilinks) and passes through raw
/// HTML blocks (Obsidian often stores tables as `<table>…</table>`).
enum MarkdownHTML {
    static func render(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whole-note HTML (e.g. Obsidian HTML tables) — don't escape tags.
        if trimmed.hasPrefix("<") {
            return stripScripts(text)
        }

        var fences: [String] = []
        text = replaceFences(in: text, store: &fences)

        var html: [String] = []
        var listKind: String? = nil  // "ul" | "ol"
        var para: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0

        func flushPara() {
            guard !para.isEmpty else { return }
            // Obsidian-style hard breaks. Inline each line first — joining with
            // "<br>" before escape() would turn the tag into literal text.
            let body = para.map { inline($0) }.joined(separator: "<br>")
            html.append("<p>" + body + "</p>")
            para.removeAll()
        }
        func flushList() {
            if let k = listKind {
                html.append("</\(k)>")
                listKind = nil
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.isEmpty {
                flushPara()
                flushList()
                i += 1
                continue
            }

            // Raw HTML block (table / div / …) — Obsidian embeds these as-is.
            if let tag = htmlBlockTag(trimmedLine) {
                flushPara()
                flushList()
                var block = [line]
                let close = "</\(tag)>"
                if !trimmedLine.lowercased().contains(close) && !isVoidHTMLTag(tag) {
                    i += 1
                    while i < lines.count {
                        block.append(lines[i])
                        if lines[i].lowercased().contains(close) { break }
                        i += 1
                    }
                }
                html.append(stripScripts(block.joined(separator: "\n")))
                i += 1
                continue
            }

            if let fenceIdx = fencePlaceholderIndex(trimmedLine) {
                flushPara()
                flushList()
                html.append("<pre><code>\(fences[fenceIdx])</code></pre>")
                i += 1
                continue
            }

            if let heading = heading(trimmedLine) {
                flushPara()
                flushList()
                html.append(heading)
                i += 1
                continue
            }

            if let m = trimmedLine.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flushPara()
                if listKind != "ul" {
                    flushList()
                    html.append("<ul>")
                    listKind = "ul"
                }
                let item = String(trimmedLine[m.upperBound...])
                html.append("<li>\(inline(item))</li>")
                i += 1
                continue
            }
            if let m = trimmedLine.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flushPara()
                if listKind != "ol" {
                    flushList()
                    html.append("<ol>")
                    listKind = "ol"
                }
                let item = String(trimmedLine[m.upperBound...])
                html.append("<li>\(inline(item))</li>")
                i += 1
                continue
            }
            if trimmedLine.hasPrefix("> ") || trimmedLine == ">" {
                flushPara()
                flushList()
                let quote = trimmedLine.hasPrefix("> ") ? String(trimmedLine.dropFirst(2)) : ""
                html.append("<blockquote><p>\(inline(quote))</p></blockquote>")
                i += 1
                continue
            }
            if trimmedLine.hasPrefix("---") && trimmedLine.allSatisfy({ $0 == "-" || $0 == " " }) {
                flushPara()
                flushList()
                html.append("<hr>")
                i += 1
                continue
            }

            flushList()
            para.append(trimmedLine)
            i += 1
        }
        flushPara()
        flushList()
        return html.joined(separator: "\n")
    }

    /// Count non-overlapping case-insensitive occurrences of `query` in `body`.
    /// For HTML notes, tags are stripped so the count matches visible text.
    static func matchCount(in body: String, query: String) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        let haystack: String
        if body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            haystack = body.replacingOccurrences(
                of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        } else {
            haystack = body
        }
        let lower = haystack.lowercased()
        let n = needle.lowercased()
        var count = 0
        var start = lower.startIndex
        while let r = lower.range(of: n, range: start..<lower.endIndex) {
            count += 1
            start = r.upperBound
        }
        return count
    }

    private static func htmlBlockTag(_ line: String) -> String? {
        // Match opening tags Obsidian commonly embeds as whole blocks.
        let pattern = #"^<(table|div|section|article|details|aside|figure|blockquote|ul|ol|pre|iframe|p)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              m.numberOfRanges > 1 else { return nil }
        return (line as NSString).substring(with: m.range(at: 1)).lowercased()
    }

    private static func isVoidHTMLTag(_ tag: String) -> Bool {
        ["br", "hr", "img", "input", "meta", "link"].contains(tag)
    }

    private static func stripScripts(_ html: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"<script\b[^>]*>[\s\S]*?</script>"#,
            options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        return re.stringByReplacingMatches(
            in: html, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    private static func replaceFences(in text: String, store: inout [String]) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var i = 0
        while i < lines.count {
            if lines[i].hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                store.append(escape(code.joined(separator: "\n")))
                out.append("%%FENCE\(store.count - 1)%%")
                if i < lines.count { i += 1 }
                continue
            }
            out.append(lines[i])
            i += 1
        }
        return out.joined(separator: "\n")
    }

    private static func fencePlaceholderIndex(_ line: String) -> Int? {
        guard line.hasPrefix("%%FENCE"), line.hasSuffix("%%") else { return nil }
        let inner = line.dropFirst(7).dropLast(2)
        return Int(inner)
    }

    private static func heading(_ line: String) -> String? {
        var n = 0
        for ch in line {
            if ch == "#" { n += 1 } else { break }
        }
        guard (1...6).contains(n) else { return nil }
        let rest = line.dropFirst(n)
        guard rest.first == " " || rest.isEmpty else { return nil }
        let title = rest.drop(while: { $0 == " " })
        return "<h\(n)>\(inline(String(title)))</h\(n)>"
    }

    private static func inline(_ s: String) -> String {
        var t = escape(s)
        // Wikilinks [[note]] / [[note|label]]
        t = replace(t, pattern: #"\[\[([^\]|]+)\|([^\]]+)\]\]"#) { "<span class=\"wiki\">\($0[2])</span>" }
        t = replace(t, pattern: #"\[\[([^\]]+)\]\]"#) { "<span class=\"wiki\">\($0[1])</span>" }
        // Links [text](url)
        t = replace(t, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) {
            "<a href=\"\($0[2])\">\($0[1])</a>"
        }
        // Inline code
        t = replace(t, pattern: #"`([^`]+)`"#) { "<code>\($0[1])</code>" }
        // Strikethrough ~~ ~~
        t = replace(t, pattern: #"~~([^~]+)~~"#) { "<del>\($0[1])</del>" }
        // Bold ** ** / __ __
        t = replace(t, pattern: #"\*\*([^*]+)\*\*"#) { "<strong>\($0[1])</strong>" }
        t = replace(t, pattern: #"__([^_]+)__"#) { "<strong>\($0[1])</strong>" }
        // Italic: only when * / _ are flanked by word boundaries — avoid
        // mangling shell globs (`du -sh *`) and identifiers (`current_user`).
        t = replace(t, pattern: #"(?<!\w)\*([^*]+)\*(?!\w)"#) { "<em>\($0[1])</em>" }
        t = replace(t, pattern: #"(?<!\w)_([^_]+)_(?!\w)"#) { "<em>\($0[1])</em>" }
        return t
    }

    private static func replace(
        _ input: String,
        pattern: String,
        _ build: ([String]) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        var out = ""
        var cursor = 0
        for m in matches {
            let full = m.range
            out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            var groups = [ns.substring(with: full)]
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += build(groups)
            cursor = full.location + full.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Notes search panel (Spotlight-like)

/// Search field that forwards ↑/↓ to the results list.
private final class NotesSearchField: NSSearchField {
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: onMoveUp?()
        case 125: onMoveDown?()
        default: super.keyDown(with: event)
        }
    }
}

/// Always-on-top notes browser: query → list → Markdown preview (select/copy),
/// jumping to the first body match when present.
final class NotesSearchPanel: NSPanel, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, WKNavigationDelegate, NSSplitViewDelegate {
    private let searchField = NotesSearchField()
    private let tableView = NSTableView()
    private let previewWeb: WKWebView = {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        return w
    }()
    private let matchCountLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var splitView: NSSplitView!
    private var hits: [NoteHit] = []
    private var searchWork: DispatchWorkItem?
    private var searchGeneration = 0
    private var pendingJump: String?
    private var loadToken = 0
    private var currentQuery = ""
    private var didApplyInitialSplit = false
    private var splitInitRetries = 0
    /// Last previewed note + query — skip redundant WKWebView reloads.
    private var previewedPath: String?
    private var previewedQuery: String?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        title = "搜索笔记"
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 520, height: 320)
        setFrameAutosaveName("PromptQyNotesSearchFrame")
        buildContent()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func close() { orderOut(nil) }

    override func orderOut(_ sender: Any?) {
        releasePreviewResources()
        super.orderOut(sender)
    }

    /// Drop list bodies / WebKit document while the panel is hidden.
    private func releasePreviewResources() {
        searchWork?.cancel()
        searchWork = nil
        searchGeneration += 1
        loadToken += 1
        pendingJump = nil
        previewedPath = nil
        previewedQuery = nil
        hits = []
        tableView.reloadData()
        matchCountLabel.stringValue = ""
        statusLabel.stringValue = ""
        previewWeb.stopLoading()
        previewWeb.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    func showAndFocus() {
        if !isVisible { center() }
        searchField.stringValue = ""
        runSearch("")
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(searchField)
        applyInitialSplitIfNeeded()
    }

    private func applyInitialSplitIfNeeded() {
        guard !didApplyInitialSplit, let split = splitView else { return }
        contentView?.layoutSubtreeIfNeeded()
        let total = split.bounds.width
        guard total > 0 else {
            splitInitRetries += 1
            guard splitInitRetries < 10 else { return }
            DispatchQueue.main.async { [weak self] in self?.applyInitialSplitIfNeeded() }
            return
        }
        // Prefer a restored autosave divider when present; only seed once if
        // both panes look collapsed/uninitialized.
        let left = split.subviews.first?.frame.width ?? 0
        if left < 80 || left > total - 80 {
            split.setPosition(min(280, max(200, total * 0.32)), ofDividerAt: 0)
        }
        didApplyInitialSplit = true
    }

    private func buildContent() {
        searchField.placeholderString = "搜索文件名或正文…"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.onMoveUp = { [weak self] in self?.moveSelection(by: -1) }
        searchField.onMoveDown = { [weak self] in self?.moveSelection(by: 1) }
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        col.title = "笔记"
        col.width = 220
        col.minWidth = 120
        col.maxWidth = 10_000
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.target = self
        tableView.action = #selector(tableClicked)
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.selectionHighlightStyle = .regular

        let listScroll = NSScrollView()
        listScroll.documentView = tableView
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .noBorder
        listScroll.drawsBackground = false
        // Split-view children must use frame-based layout (autoresizingMask).
        // Auto Layout width constraints on them fight the divider and snap back.
        listScroll.translatesAutoresizingMaskIntoConstraints = true
        listScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        listScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        previewWeb.navigationDelegate = self
        previewWeb.translatesAutoresizingMaskIntoConstraints = false
        // Wide HTML tables report a huge intrinsic width; don't let that drive the split.
        previewWeb.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        previewWeb.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        previewWeb.setContentHuggingPriority(.defaultLow, for: .vertical)
        previewWeb.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        matchCountLabel.font = .systemFont(ofSize: 11)
        matchCountLabel.textColor = .secondaryLabelColor
        matchCountLabel.alignment = .left
        matchCountLabel.lineBreakMode = .byTruncatingTail
        matchCountLabel.translatesAutoresizingMaskIntoConstraints = false
        matchCountLabel.stringValue = ""
        matchCountLabel.setContentHuggingPriority(.required, for: .vertical)

        let previewPane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        previewPane.translatesAutoresizingMaskIntoConstraints = true
        previewPane.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewPane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewPane.addSubview(previewWeb)
        previewPane.addSubview(matchCountLabel)
        NSLayoutConstraint.activate([
            previewWeb.topAnchor.constraint(equalTo: previewPane.topAnchor),
            previewWeb.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            previewWeb.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            previewWeb.bottomAnchor.constraint(equalTo: matchCountLabel.topAnchor, constant: -4),

            matchCountLabel.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor, constant: 10),
            matchCountLabel.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor, constant: -10),
            matchCountLabel.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor, constant: -6),
            matchCountLabel.heightAnchor.constraint(equalToConstant: 16),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.autosaveName = "PromptQyNotesSplit"
        split.addSubview(listScroll)
        split.addSubview(previewPane)
        // List holds its width when the window resizes; preview absorbs the slack.
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 1)
        split.translatesAutoresizingMaskIntoConstraints = false
        splitView = split

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(searchField)
        root.addSubview(split)
        root.addSubview(statusLabel)
        contentView = root

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            split.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        160  // min list width
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.width - 220  // min preview width
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as AnyObject === searchField else { return }
        let q = searchField.stringValue
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch(q) }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(by: -1); return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(by: 1); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            orderOut(nil); return true
        }
        return false
    }

    private func runSearch(_ query: String) {
        searchGeneration += 1
        let gen = searchGeneration
        currentQuery = query
        let vault = Settings.notesVaultPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = MarkdownVault.search(query: query)
            DispatchQueue.main.async {
                guard let self = self, gen == self.searchGeneration else { return }
                self.hits = results
                self.tableView.reloadData()
                self.previewedPath = nil  // force preview refresh for new results
                if results.isEmpty {
                    self.clearPreview()
                    let exists = FileManager.default.fileExists(atPath: vault)
                    self.statusLabel.stringValue = exists
                        ? "无匹配结果"
                        : "笔记库路径不存在：\(vault)"
                } else {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    // selectRowIndexes is a no-op when row 0 was already selected,
                    // so selectionDidChange may not fire — always show once here.
                    self.showPreview(for: 0)
                    self.statusLabel.stringValue = "\(results.count) 条 · Esc 关闭 · 预览中可框选复制"
                }
            }
        }
    }

    private func moveSelection(by delta: Int) {
        guard !hits.isEmpty else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let next = max(0, min(hits.count - 1, current + delta))
        guard next != tableView.selectedRow else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
        // Preview via selectionDidChange.
    }

    @objc private func tableClicked() {
        // Selection change drives preview; nothing else needed.
    }

    private func clearPreview() {
        pendingJump = nil
        loadToken += 1
        previewedPath = nil
        previewedQuery = nil
        matchCountLabel.stringValue = ""
        previewWeb.stopLoading()
        previewWeb.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    private func showPreview(for row: Int) {
        guard row >= 0, row < hits.count else {
            clearPreview()
            return
        }
        let hit = hits[row]
        let q = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = hit.url.path
        if previewedPath == path, previewedQuery == q { return }
        previewedPath = path
        previewedQuery = q

        // Load body only for the selected note.
        let body = hit.loadBody()
        let matchText = MarkdownVault.firstMatch(in: body, matching: q)
        let count = MarkdownHTML.matchCount(in: body, query: q)
        if q.isEmpty {
            matchCountLabel.stringValue = ""
        } else {
            matchCountLabel.stringValue = count > 0
                ? "本篇命中 \(count) 处"
                : "本篇正文无命中（仅文件名匹配）"
        }
        pendingJump = matchText
        loadToken += 1
        let token = loadToken
        let bodyHTML = MarkdownHTML.render(body)
        let page = Self.wrapHTML(bodyHTML, title: hit.title)
        // Defer load slightly so rapid ↑↓ doesn't race unfinished navigations.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, token == self.loadToken else { return }
            self.previewWeb.loadHTMLString(page, baseURL: hit.url.deletingLastPathComponent())
        }
    }

    private static func wrapHTML(_ body: String, title: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(MarkdownHTMLEscape.escape(title))</title>
        <style>
          :root { color-scheme: light dark; }
          html, body {
            margin: 0; padding: 0;
            font: 13px/1.55 -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
            background: Canvas;
            color: CanvasText;
          }
          body { padding: 14px 16px 28px; overflow-wrap: anywhere; word-break: break-word; }
          h1,h2,h3,h4,h5,h6 { line-height: 1.25; margin: 1.1em 0 0.4em; }
          h1 { font-size: 1.45em; } h2 { font-size: 1.25em; } h3 { font-size: 1.1em; }
          p, ul, ol, blockquote, pre { margin: 0.55em 0; }
          p { white-space: normal; }
          ul, ol { padding-left: 1.4em; }
          code, pre {
            font-family: ui-monospace, Menlo, monospace;
            font-size: 0.92em;
          }
          code {
            background: rgba(127,127,127,0.15);
            padding: 0.1em 0.35em;
            border-radius: 3px;
          }
          pre {
            background: rgba(127,127,127,0.12);
            padding: 10px 12px;
            border-radius: 6px;
            overflow-x: auto;
            white-space: pre-wrap;
          }
          pre code { background: none; padding: 0; }
          blockquote {
            margin-left: 0; padding: 0.2em 0.8em;
            border-left: 3px solid rgba(127,127,127,0.45);
            color: gray;
          }
          table {
            border-collapse: collapse;
            width: 100%;
            font-size: 12px;
            margin: 0.4em 0 1em;
          }
          th, td {
            border: 1px solid rgba(127,127,127,0.35);
            padding: 6px 8px;
            vertical-align: top;
            text-align: left;
            overflow-wrap: anywhere;
            word-break: break-word;
          }
          th { background: rgba(127,127,127,0.12); font-weight: 600; }
          a { color: #0a84ff; }
          .wiki {
            color: #0a84ff;
            border-bottom: 1px dashed rgba(10,132,255,0.5);
          }
          hr { border: none; border-top: 1px solid rgba(127,127,127,0.35); margin: 1em 0; }
          mark.pq-hit {
            background: #ffe58a;
            color: inherit;
            padding: 0 1px;
            border-radius: 2px;
          }
          @media (prefers-color-scheme: dark) {
            mark.pq-hit { background: #8a6d1a; color: #fff8d6; }
            a, .wiki { color: #64b5ff; }
            th { background: rgba(255,255,255,0.08); }
          }
        </style>
        </head>
        <body>
        <article>\(body)</article>
        <script>
        window.pqJumpTo = function(q) {
          if (!q) { window.scrollTo(0, 0); return; }
          document.querySelectorAll('mark.pq-hit').forEach(function(m) {
            m.replaceWith(document.createTextNode(m.textContent || ''));
          });
          var needle = q.toLowerCase();
          var first = null;
          function highlightNode(node) {
            var text = node.nodeValue || '';
            var lower = text.toLowerCase();
            var idx = lower.indexOf(needle);
            if (idx < 0) return false;
            var frag = document.createDocumentFragment();
            var cursor = 0;
            while (idx >= 0) {
              if (idx > cursor) frag.appendChild(document.createTextNode(text.slice(cursor, idx)));
              var mark = document.createElement('mark');
              mark.className = 'pq-hit';
              mark.textContent = text.slice(idx, idx + q.length);
              frag.appendChild(mark);
              if (!first) first = mark;
              cursor = idx + q.length;
              idx = lower.indexOf(needle, cursor);
            }
            if (cursor < text.length) frag.appendChild(document.createTextNode(text.slice(cursor)));
            node.parentNode.replaceChild(frag, node);
            return true;
          }
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
          var nodes = [];
          while (walker.nextNode()) nodes.push(walker.currentNode);
          nodes.forEach(highlightNode);
          if (first) first.scrollIntoView({block: 'center', inline: 'nearest'});
        };
        </script>
        </body>
        </html>
        """
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let payload = Self.jsStringLiteral(pendingJump ?? "")
        webView.evaluateJavaScript("window.pqJumpTo && window.pqJumpTo(\(payload))") { _, _ in }
    }

    /// JSON string literal suitable for embedding in `evaluateJavaScript`.
    /// Top-level String is not a valid JSON root — wrap in an array first.
    private static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let wrapped = String(data: data, encoding: .utf8),
              wrapped.count >= 2 else { return "\"\"" }
        return String(wrapped.dropFirst().dropLast())
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("NoteCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                c.identifier = id
                let title = NSTextField(labelWithString: "")
                title.tag = 1
                title.font = .systemFont(ofSize: 13, weight: .medium)
                title.lineBreakMode = .byTruncatingTail
                title.translatesAutoresizingMaskIntoConstraints = false
                let sub = NSTextField(labelWithString: "")
                sub.tag = 2
                sub.font = .systemFont(ofSize: 11)
                sub.textColor = .secondaryLabelColor
                sub.lineBreakMode = .byTruncatingMiddle
                sub.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(title)
                c.addSubview(sub)
                c.textField = title
                NSLayoutConstraint.activate([
                    title.topAnchor.constraint(equalTo: c.topAnchor, constant: 8),
                    title.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
                    title.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
                    sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
                    sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                    sub.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                    sub.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -8),
                ])
                return c
            }()
        let hit = hits[row]
        cell.textField?.stringValue = hit.title
        let dir = (hit.relativePath as NSString).deletingLastPathComponent
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = dir.isEmpty ? "（库根目录）" : dir
        cell.toolTip = hit.relativePath
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 { showPreview(for: row) }
    }
}

/// Shared HTML escaping for the preview wrapper (avoids depending on MarkdownHTML's private API).
private enum MarkdownHTMLEscape {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSObject {
    /// Both grid columns are pinned so the rows line up and the block keeps its
    /// own width. Left to size themselves, the label column hugs weakly, the grid
    /// stretches to the full content width and the extra space lands inside the
    /// (trailing-aligned) label column — which shoves the whole block right.
    /// Control column width; label column hugs its text (no fixed empty gutter).
    private static let controlWidth: CGFloat = 240
    private static let margin: CGFloat = 16

    private var window: NSWindow?
    private let onChange: () -> Void
    private let terminalPopup = NSPopUpButton()
    private let summonPopup = NSPopUpButton()
    private let searchPopup = NSPopUpButton()
    private let openPopup = NSPopUpButton()
    private let historyPopup = NSPopUpButton()
    private let widthPopup = NSPopUpButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let choosePathButton = NSButton(title: "选择…", target: nil, action: nil)
    private let vaultLabel = NSTextField(labelWithString: "")
    private let chooseVaultButton = NSButton(title: "选择…", target: nil, action: nil)
    private var phrasesTextView: NSTextView!
    private var excludesTextView: NSTextView!

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func show() {
        let isFirstShow = window == nil
        if isFirstShow { build() }
        syncFromSettings()
        if isFirstShow { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        for m in ModifierChoice.allCases {
            summonPopup.addItem(withTitle: m.displayName)
            searchPopup.addItem(withTitle: m.displayName)
            openPopup.addItem(withTitle: m.displayName)
        }
        for n in [10, 20, 50, 100, 200] { historyPopup.addItem(withTitle: "\(n)") }
        for w in [20, 30, 40, 60, 80] { widthPopup.addItem(withTitle: "\(w)") }
        // Index 0 is auto; the rest track `TerminalApp.allCases` positionally.
        terminalPopup.addItem(withTitle: "自动")
        for app in TerminalApp.allCases { terminalPopup.addItem(withTitle: app.displayName) }
        let popups = [terminalPopup, summonPopup, searchPopup, openPopup, historyPopup, widthPopup]
        for popup in popups {
            popup.target = self
            popup.action = #selector(changed)
            // Without a fixed width every popup sizes to its own title, so the
            // column jumps around as the selection changes ("Control (^)" is
            // narrower than "Option (⌥)").
            popup.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        }

        pathLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = ScreenshotLocation.url.path
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        choosePathButton.bezelStyle = .rounded
        choosePathButton.target = self
        choosePathButton.action = #selector(chooseScreenshotPath)
        choosePathButton.setContentHuggingPriority(.required, for: .horizontal)

        let pathRow = NSStackView(views: [pathLabel, choosePathButton])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8
        pathRow.alignment = .centerY
        pathRow.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true

        vaultLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        vaultLabel.lineBreakMode = .byTruncatingMiddle
        vaultLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseVaultButton.bezelStyle = .rounded
        chooseVaultButton.target = self
        chooseVaultButton.action = #selector(chooseVaultPath)
        chooseVaultButton.setContentHuggingPriority(.required, for: .horizontal)
        let vaultRow = NSStackView(views: [vaultLabel, chooseVaultButton])
        vaultRow.orientation = .horizontal
        vaultRow.spacing = 8
        vaultRow.alignment = .centerY
        vaultRow.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true

        // Phrases editor: a small scrollable text view, one phrase per line.
        let phrasesScroll = NSScrollView()
        phrasesTextView = NSTextView()
        phrasesTextView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        phrasesTextView.isRichText = false
        phrasesTextView.isAutomaticQuoteSubstitutionEnabled = false
        phrasesTextView.isAutomaticDashSubstitutionEnabled = false
        phrasesTextView.allowsUndo = true
        phrasesTextView.textContainerInset = NSSize(width: 4, height: 4)
        phrasesScroll.documentView = phrasesTextView
        phrasesScroll.hasVerticalScroller = true
        phrasesScroll.hasHorizontalScroller = false
        phrasesScroll.borderType = .bezelBorder
        phrasesScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        phrasesScroll.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(phrasesChanged),
            name: NSText.didChangeNotification, object: phrasesTextView)

        let excludesScroll = NSScrollView()
        excludesTextView = NSTextView()
        excludesTextView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        excludesTextView.isRichText = false
        excludesTextView.isAutomaticQuoteSubstitutionEnabled = false
        excludesTextView.isAutomaticDashSubstitutionEnabled = false
        excludesTextView.allowsUndo = true
        excludesTextView.textContainerInset = NSSize(width: 4, height: 4)
        excludesScroll.documentView = excludesTextView
        excludesScroll.hasVerticalScroller = true
        excludesScroll.hasHorizontalScroller = false
        excludesScroll.borderType = .bezelBorder
        excludesScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        excludesScroll.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(excludesChanged),
            name: NSText.didChangeNotification, object: excludesTextView)

        func row(_ label: String, _ control: NSView) -> [NSView] {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            return [l, control]
        }
        func makeGrid(_ rows: [[NSView]], footnote: String) -> NSView {
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 12
            grid.columnSpacing = 8
            grid.rowAlignment = .none
            for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }
            // Hug label text — a fixed column width left a large empty gutter.
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 1).xPlacement = .leading
            grid.column(at: 1).width = Self.controlWidth
            grid.setContentHuggingPriority(.required, for: .horizontal)

            let note = NSTextField(wrappingLabelWithString: footnote)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.alignment = .center
            note.preferredMaxLayoutWidth = Self.controlWidth + 100
            note.translatesAutoresizingMaskIntoConstraints = false

            let stack = NSStackView(views: [grid, note])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 14
            stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
            stack.translatesAutoresizingMaskIntoConstraints = false
            // Pin to the top of the tab so short pages (手势 / 笔记) don't float
            // to the vertical middle of the fixed-height tab view.
            let wrap = NSView()
            wrap.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                stack.topAnchor.constraint(equalTo: wrap.topAnchor),
                stack.bottomAnchor.constraint(
                    lessThanOrEqualTo: wrap.bottomAnchor),
                note.widthAnchor.constraint(equalTo: grid.widthAnchor),
            ])
            return wrap
        }

        let generalTab = makeGrid([
            row("目标终端：", terminalPopup),
            row("历史条数：", historyPopup),
            row("菜单标题字数：", widthPopup),
            row("截图保存路径：", pathRow),
            row("常用语：", phrasesScroll),
        ], footnote: "截图路径写入系统设置（com.apple.screencapture），重启后仍生效。改动即时生效。")

        let gestureTab = makeGrid([
            row("呼出编辑器：", summonPopup),
            row("搜索笔记：", searchPopup),
            row("打开文件：", openPopup),
        ], footnote: "均为双击对应修饰键。三个手势请用不同修饰键，否则会冲突。")

        let notesTab = makeGrid([
            row("笔记库路径：", vaultRow),
            row("排除目录：", excludesScroll),
        ], footnote: "排除目录每行一个，默认 .obsidian、.trash。双击 Option（可在「手势」中改）打开搜索。")

        let tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        let tabs: [(String, NSView)] = [
            ("通用", generalTab),
            ("手势", gestureTab),
            ("笔记", notesTab),
        ]
        for (title, view) in tabs {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = view
            tabView.addTabViewItem(item)
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let versionLabel = NSTextField(labelWithString: "版本 \(version)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .center
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [tabView, versionLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(
            top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let tabWidth = Self.controlWidth + 120 + 8 + 28
        tabView.widthAnchor.constraint(equalToConstant: tabWidth).isActive = true
        // Tall enough for the largest tab (通用) without jumping when switching.
        tabView.heightAnchor.constraint(equalToConstant: 320).isActive = true

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: tabWidth + Self.margin * 2, height: 400),
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
        content.layoutSubtreeIfNeeded()
        w.setContentSize(NSSize(
            width: tabWidth + Self.margin * 2,
            height: content.fittingSize.height))
        window = w
    }

    private func syncFromSettings() {
        summonPopup.selectItem(at: ModifierChoice.allCases.firstIndex(of: Settings.summonModifier) ?? 0)
        searchPopup.selectItem(at: ModifierChoice.allCases.firstIndex(of: Settings.searchModifier) ?? 0)
        openPopup.selectItem(at: ModifierChoice.allCases.firstIndex(of: Settings.openModifier) ?? 0)
        historyPopup.selectItem(withTitle: "\(Settings.historyLimit)")
        widthPopup.selectItem(withTitle: "\(Settings.labelWidth)")
        terminalPopup.selectItem(at: Settings.terminalApp
            .flatMap { TerminalApp.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        pathLabel.stringValue = ScreenshotLocation.displayPath
        pathLabel.toolTip = ScreenshotLocation.url.path
        vaultLabel.stringValue = displayPath(Settings.notesVaultPath)
        vaultLabel.toolTip = Settings.notesVaultPath
        excludesTextView.string = Settings.notesExcludeDirs.joined(separator: "\n")
        phrasesTextView.string = Settings.quickPhrases.joined(separator: "\n")
    }

    @objc private func changed() {
        Settings.summonModifier = ModifierChoice.allCases[summonPopup.indexOfSelectedItem]
        Settings.searchModifier = ModifierChoice.allCases[searchPopup.indexOfSelectedItem]
        Settings.openModifier = ModifierChoice.allCases[openPopup.indexOfSelectedItem]
        if let n = Int(historyPopup.titleOfSelectedItem ?? "") { Settings.historyLimit = n }
        if let w = Int(widthPopup.titleOfSelectedItem ?? "") { Settings.labelWidth = w }
        let i = terminalPopup.indexOfSelectedItem
        Settings.terminalApp = i > 0 ? TerminalApp.allCases[i - 1] : nil
        onChange()
    }

    @objc private func phrasesChanged() {
        let lines = phrasesTextView.string.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Settings.quickPhrases = lines
    }

    @objc private func excludesChanged() {
        let lines = excludesTextView.string.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Settings.notesExcludeDirs = lines
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    @objc private func chooseVaultPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择"
        panel.message = "选择 Obsidian / Markdown 笔记库根目录"
        panel.directoryURL = URL(fileURLWithPath: Settings.notesVaultPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.notesVaultPath = url.path
        vaultLabel.stringValue = displayPath(url.path)
        vaultLabel.toolTip = url.path
        onChange()
    }

    @objc private func chooseScreenshotPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择 ⌘⇧3 / ⌘⇧4 截图的保存文件夹（写入系统设置，重启后仍生效）"
        panel.directoryURL = ScreenshotLocation.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ScreenshotLocation.setURL(url) else {
            let alert = NSAlert()
            alert.messageText = "无法设置截图路径"
            alert.informativeText = "请选择一个已存在且可访问的文件夹。"
            alert.runModal()
            return
        }
        pathLabel.stringValue = ScreenshotLocation.displayPath
        pathLabel.toolTip = ScreenshotLocation.url.path
        onChange()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let panel = EditorPanel()
    private let notesPanel = NotesSearchPanel()
    private var summonMonitor: DoubleTapMonitor?
    private var searchMonitor: DoubleTapMonitor?
    private var openMonitor: DoubleTapMonitor?
    private var phrasesKeyMonitors: [Any] = []
    private var screenshotWatcher: ScreenshotWatcher!
    private lazy var settingsController = SettingsWindowController { [weak self] in
        self?.restartMonitors()
        // Path may have changed via the screenshot-location picker.
        self?.screenshotWatcher.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        setupPhrasesShortcuts()
        restartMonitors()

        screenshotWatcher = ScreenshotWatcher { [weak self] url in
            guard let self = self else { return }
            // Don't activate — stealing focus mid-rename makes Finder re-show
            // its "replace existing file?" dialog a second time.
            if !self.panel.isVisible { self.panel.showWithoutActivating() }
            self.panel.insertAtCursor(PathFormat.forInsertion(url.path) + "\n")
        }
        screenshotWatcher.start()

        ensureAccessibilityPermission()
        ensureSpeechPermission()
    }

    /// (Re)create the double-tap monitors from the current settings.
    private func restartMonitors() {
        summonMonitor?.stop()
        searchMonitor?.stop()
        openMonitor?.stop()
        let summon = Settings.summonModifier
        summonMonitor = DoubleTapMonitor(
            keyCodes: summon.keyCodes, flag: summon.flag,
            interval: Settings.doubleTapInterval) { [weak self] in self?.onSummon() }
        summonMonitor?.start()
        let search = Settings.searchModifier
        searchMonitor = DoubleTapMonitor(
            keyCodes: search.keyCodes, flag: search.flag,
            interval: Settings.doubleTapInterval) { [weak self] in self?.onNotesSearch() }
        searchMonitor?.start()
        let open = Settings.openModifier
        openMonitor = DoubleTapMonitor(
            keyCodes: open.keyCodes, flag: open.flag,
            interval: Settings.doubleTapInterval) { [weak self] in self?.onOpenInEditor() }
        openMonitor?.start()
    }

    /// Global ⌘1–⌘9 shortcuts for quick phrases. A global monitor can only
    /// observe (not consume) events, so the frontmost app also receives the
    /// key press — ⌘1 still switches to the first tab in a browser, for example.
    private func setupPhrasesShortcuts() {
        // Main-keyboard digit key codes for 1–9.
        let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let globalHandler: (NSEvent) -> Void = { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .control,
                  let idx = digitKeyCodes.firstIndex(of: event.keyCode),
                  !event.isARepeat else { return }
            self?.pickPhraseByIndex(idx)
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: globalHandler) {
            phrasesKeyMonitors.append(g)
        }
        // Local monitor: consume the event when PromptQy is active so the text
        // view doesn't receive a stray character.
        let localHandler: (NSEvent) -> NSEvent? = { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .control,
                  let idx = digitKeyCodes.firstIndex(of: event.keyCode),
                  !event.isARepeat else { return event }
            self?.pickPhraseByIndex(idx)
            return nil
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: localHandler) {
            phrasesKeyMonitors.append(l)
        }
    }

    private func pickPhraseByIndex(_ idx: Int) {
        let phrases = Settings.quickPhrases
        guard idx < phrases.count else { return }
        panel.showAndFocus()
        panel.insertAtCursor(phrases[idx] + "\n")
    }

    /// An accessory (LSUIElement) app has no menu bar, but a main menu is still
    /// needed for the standard editing key-equivalents (⌘A/⌘C/⌘V/⌘X/⌘Z/⌘W) to
    /// reach the text view / key window.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        // Routes ⌘W to the key window's performClose: → EditorPanel.close().
        fileMenu.addItem(
            withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

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
                    systemSymbolName: "text.cursor", accessibilityDescription: "PromptQy")
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
        let notes = menu.addItem(withTitle: "搜索笔记…", action: #selector(showNotesSearch), keyEquivalent: "")
        notes.target = self
        menu.addItem(.separator())

        let phrases = Settings.quickPhrases
        if !phrases.isEmpty {
            let phraseHeader = menu.addItem(withTitle: "常用语（点击插入）", action: nil, keyEquivalent: "")
            phraseHeader.isEnabled = false
            for (i, phrase) in phrases.enumerated() {
                let title = phrase.count > 50 ? String(phrase.prefix(47)) + "…" : phrase
                let key = i < 9 ? "\(i + 1)" : ""
                let item = menu.addItem(
                    withTitle: title,
                    action: #selector(pickPhrase(_:)), keyEquivalent: key)
                item.keyEquivalentModifierMask = i < 9 ? .control : []
                item.target = self
                item.tag = i
            }
            menu.addItem(.separator())
        }

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

    @objc private func showNotesSearch() { notesPanel.showAndFocus() }

    @objc private func pickPhrase(_ sender: NSMenuItem) {
        let phrases = Settings.quickPhrases
        guard sender.tag >= 0, sender.tag < phrases.count else { return }
        panel.showAndFocus()
        panel.insertAtCursor(phrases[sender.tag] + "\n")
    }

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

    /// Double-tap Option: open the notes search panel.
    private func onNotesSearch() {
        notesPanel.showAndFocus()
    }

    /// Double-tap Command: open the current Finder selection in Sublime Text.
    /// Deliberately does not touch the editor panel — this gesture is about the
    /// file, not about composing a prompt.
    private func onOpenInEditor() {
        let paths = FinderSelection.paths()
        guard !paths.isEmpty else { NSSound.beep(); return }
        guard ExternalEditor.open(paths) else {
            let alert = NSAlert()
            alert.messageText = "未找到 \(ExternalEditor.displayName)"
            alert.informativeText =
                "双击「打开文件」手势用 \(ExternalEditor.displayName) 打开 Finder 中选中的文件，"
                + "请先安装它（或把它放到 /Applications）。"
            alert.runModal()
            return
        }
    }

    private func ensureAccessibilityPermission() {
        // Don't use the auto-prompting variant (it re-pops the system dialog on
        // every launch); check silently and guide the user ourselves.
        guard !AXIsProcessTrusted() else { return }
        let alert = NSAlert()
        alert.messageText = "需要「辅助功能」权限"
        alert.informativeText =
            "双击 Control 呼出、读取选中文本都依赖全局键盘监听。\n"
            + "请在「辅助功能」列表中勾选「PromptQy」。若已勾选仍提示，"
            + "请先移除旧条目再重新添加本 App。"
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    /// Request speech-recognition permission on first launch.
    /// Microphone permission is prompted by the system on first use of
    /// AVAudioEngine.inputNode, so we don't need to pre-request it.
    private func ensureSpeechPermission() {
        let status = VoiceRecognizer.permissionStatus
        guard status == .notDetermined else { return }
        VoiceRecognizer.requestPermission { granted in
            if !granted {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "语音识别权限被拒绝"
                    alert.informativeText =
                        "语音录入功能需要「语音识别」权限。\n"
                        + "请到「系统设置 → 隐私与安全性 → 语音识别」中开启「PromptQy」。"
                    alert.addButton(withTitle: "打开隐私设置")
                    alert.addButton(withTitle: "稍后")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
                    }
                }
            }
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
