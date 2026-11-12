// PromptQy — a menu-bar-resident, always-on-top text composer for
// feeding prompts, file paths, selections and screenshots into a terminal
// running Claude Code.
//
// Stages implemented:
//   1. Menu-bar item + always-on-top draggable/resizable editor + double-tap
//      Control to summon/dismiss.
//   2. Grab the frontmost app's selection on summon (AX, then synthesized
//      Cmd+C) + a Send button that pastes+Returns into a chosen Terminal.app,
//      iTerm2, Otty, or Ghostty tab.
//   3. Drag files onto the editor to insert their paths.
//   4. Watch the screenshot folder and insert the path of new screenshots.
//   5. Push-to-talk dictation: hold a key (default right Option) to stream
//      speech recognition into the editor via SFSpeechRecognizer.
//   6. Quick phrases: preset text snippets in the menu bar, one-click insert
//      with ⌃1–⌃9 keyboard shortcuts; editable in Settings.
//   7. Double-tap Option to search Obsidian .md / .sheet notes: floating Spotlight-like
//      panel with Markdown preview (select/copy, jump to first match); vault
//      path + exclude dirs configurable in Settings.
//   8. Clipboard history (⌘⇧C): text + images (original on disk, thumbs in list);
//      Enter copies; ⌥↵ inserts into editor.
//
// Build via ./build_app.sh.

import Cocoa
import ApplicationServices
import Speech
import AVFoundation
import WebKit
import IOKit.pwr_mgt
import IOKit.pwr_mgt

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

    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        case .shift: return "⇧"
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
    /// Keep the Mac awake (no idle sleep / display sleep) while PromptQy runs.
    /// Manual lock / Sleep still work. Persists across relaunches.
    static var preventAutoSleep: Bool {
        get { d.bool(forKey: "preventAutoSleep") }
        set { d.set(newValue, forKey: "preventAutoSleep") }
    }

    /// Poll interval for pasteboard `changeCount` (seconds).
    static var clipboardCheckInterval: TimeInterval { 0.5 }
    /// Max unpinned text clips retained.
    static var clipboardTextLimit: Int {
        get { let v = d.integer(forKey: "clipboardTextLimit"); return v > 0 ? v : 100 }
        set { d.set(newValue, forKey: "clipboardTextLimit") }
    }
    /// Max unpinned image clips retained.
    static var clipboardImageLimit: Int {
        get { let v = d.integer(forKey: "clipboardImageLimit"); return v > 0 ? v : 20 }
        set { d.set(newValue, forKey: "clipboardImageLimit") }
    }
    /// Soft cap on unpinned image payload bytes on disk (~200 MB).
    static var clipboardImageDiskBudget: Int { 200 * 1024 * 1024 }
    static var clipboardMaxTextBytes: Int { 256 * 1024 }
    static var clipboardMaxImageBytes: Int { 10 * 1024 * 1024 }

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

// MARK: - Sleep prevention

/// Idle-only assertions: blocks automatic sleep + display sleep, but still
/// allows the user to lock the screen or choose Sleep from the Apple menu.
enum SleepPrevention {
    private static var systemAssertion: IOPMAssertionID = 0
    private static var displayAssertion: IOPMAssertionID = 0
    private static var holding = false

    /// Apply preference and take / drop assertions.
    static func setEnabled(_ enabled: Bool) {
        Settings.preventAutoSleep = enabled
        if enabled { acquire() } else { release() }
    }

    /// Re-acquire after launch when the preference is still on.
    static func restoreIfNeeded() {
        if Settings.preventAutoSleep { acquire() }
    }

    static func release() {
        if systemAssertion != 0 {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = 0
        }
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
        holding = false
    }

    private static func acquire() {
        guard !holding else { return }
        let reason = "PromptQy 阻止系统自动休眠" as CFString
        var sys: IOPMAssertionID = 0
        var disp: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &sys) == kIOReturnSuccess {
            systemAssertion = sys
        }
        if IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &disp) == kIOReturnSuccess {
            displayAssertion = disp
        }
        holding = systemAssertion != 0 || displayAssertion != 0
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
        ClipboardGate.withPaused {
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
            ClipboardMonitor.shared.syncChangeCount()
            return (result?.isEmpty == false) ? result : nil
        }
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

/// The terminals we can drive. Terminal.app / iTerm2 / Otty share a
/// focus-then-⌘V-Return path; Ghostty uses its native `input text` API
/// (1.3.0+) and only differs in how windows / tabs / splits are addressed.
enum TerminalApp: String, CaseIterable {
    case terminal
    case iterm
    case otty
    case ghostty

    var bundleId: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .otty: return "io.appmakes.otty"
        case .ghostty: return "com.mitchellh.ghostty"
        }
    }

    var displayName: String {
        switch self {
        case .terminal: return "终端.app"
        case .iterm: return "iTerm2"
        case .otty: return "Otty"
        case .ghostty: return "Ghostty"
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
        /// iTerm2 / Ghostty splits: session or terminal id. Empty for
        /// Terminal.app / Otty, which have no equivalent.
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
        case .ghostty:
            // Ghostty (1.3.0+): windows → tabs → terminals (splits). Window
            // ids are opaque strings; no `bounds` in its scripting suite.
            body = """
                    set winName to ""
                    try
                        set winName to name of w
                    end try
                    set tabList to tabs of w
                    repeat with ti from 1 to count of tabList
                        set tabRef to item ti of tabList
                        set termList to terminals of tabRef
                        repeat with si from 1 to count of termList
                            set termRef to item si of termList
                            set rowName to ""
                            try
                                set rowName to name of termRef
                            end try
                            if rowName is "" then
                                try
                                    set rowName to name of tabRef
                                end try
                            end if
                            if rowName is "" then set rowName to winName
                            set end of outLines to wid & fieldSep & (wi as text) & fieldSep & (ti as text) & fieldSep & (si as text) & fieldSep & (id of termRef) & fieldSep & geo & fieldSep & rowName
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

    /// Escape a Swift string for embedding inside an AppleScript `"..."` literal.
    private static func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Select the target window/tab/pane. Keystrokes are posted separately —
    /// this script only moves focus inside the terminal app.
    ///
    /// Focusing differs: Terminal.app selects a tab and raises the window by
    /// property; iTerm2 has a `select` verb that walks window → tab → pane;
    /// Ghostty focuses by stable app-level `terminal id`. (iTerm2 also has
    /// `write text`, which needs no focus at all — but it replays embedded
    /// newlines as Return presses, so a multi-line prompt would submit itself
    /// line by line. Pasting keeps it intact, because the terminal wraps a
    /// real ⌘V in bracketed paste.)
    private static func focusTab(_ target: Target) -> Bool {
        // Ghostty: app-level `terminal id` is stable across tab reorder;
        // `focus` also raises the window (no window-id / select tab prelude).
        if target.app == .ghostty {
            let script = """
            tell application id "\(target.app.bundleId)"
                set targetTerm to terminal id "\(escapeAS(target.sessionId))"
                focus targetTerm
            end tell
            """
            return AppleScriptRunner.succeeds(script)
        }

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
            select session id "\(escapeAS(target.sessionId))" of tab \(target.tabIndex) of targetWin
            """
        case .ghostty:
            preconditionFailure("Ghostty focus is handled above")
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

    /// Deliver `text` to `target`. Ghostty uses its native `input text` +
    /// `send key "enter"` (no clipboard / HID). Everyone else still goes
    /// clipboard → focus → ⌘V → Return.
    ///
    /// Returns false (with `AppleScriptRunner.lastError` set) if anything failed,
    /// so the caller can keep the text instead of silently dropping it.
    ///
    /// For the clipboard path, caller must already have resigned our own key
    /// focus (`orderOut` + `NSApp.deactivate`); otherwise the terminal can
    /// never become the LaunchServices-frontmost app and the paste vanishes
    /// into us.
    static func send(_ text: String, to target: Target) -> Bool {
        if target.app == .ghostty {
            return sendViaGhostty(text, to: target)
        }
        return sendViaClipboardPaste(text, to: target)
    }

    /// Ghostty 1.3.0+: address the split by stable terminal id and inject
    /// text directly. `focus` raises its window; no LS-frontmost / HID needed.
    private static func sendViaGhostty(_ text: String, to target: Target) -> Bool {
        guard target.app.isRunning else {
            AppleScriptRunner.lastError = "\(target.app.displayName) 已退出"
            return false
        }
        let script = """
        tell application id "\(target.app.bundleId)"
            set targetTerm to terminal id "\(escapeAS(target.sessionId))"
            focus targetTerm
            input text "\(escapeAS(text))" to targetTerm
            send key "enter" to targetTerm
        end tell
        """
        return AppleScriptRunner.succeeds(script)
    }

    /// Shared path for Terminal.app / iTerm2 / Otty: clipboard + HID paste.
    private static func sendViaClipboardPaste(_ text: String, to target: Target) -> Bool {
        return ClipboardGate.withPaused {
            let pb = NSPasteboard.general
            pb.clearContents()
            guard pb.setString(text, forType: .string) else {
                AppleScriptRunner.lastError = "无法写入剪贴板"
                return false
            }
            pb.setString("", forType: .promptqyClipboard)
            ClipboardMonitor.shared.syncChangeCount()

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
                pb.setString("", forType: .promptqyClipboard)
                ClipboardMonitor.shared.syncChangeCount()
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
/// Engine + recognizer are created on first `startRecording()` so idle launch
/// does not pull AVFoundation/Speech stacks into RAM.
final class VoiceRecognizer: NSObject, SFSpeechRecognizerDelegate {
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private let locale: Locale

    /// Called on the main thread with partial (in-progress) transcription.
    var onPartialResult: ((String) -> Void)?
    /// Called on the main thread with the final transcription.
    var onFinalResult: ((String) -> Void)?
    /// Called when recording state changes (started / stopped).
    var onStateChange: ((Bool) -> Void)?
    /// Called on error (permission denied, network, etc.).
    var onError: ((String) -> Void)?

    var isRecording: Bool { audioEngine?.isRunning ?? false }

    init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
        super.init()
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

    /// Allocate recognizer + audio engine on first use.
    private func prepare() throws -> (SFSpeechRecognizer, AVAudioEngine) {
        if speechRecognizer == nil {
            guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
                throw NSError(domain: "VoiceRecognizer", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "当前系统不支持语音识别"])
            }
            recognizer.delegate = self
            speechRecognizer = recognizer
        }
        guard let speechRecognizer else {
            throw NSError(domain: "VoiceRecognizer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "当前系统不支持语音识别"])
        }
        if audioEngine == nil {
            audioEngine = AVAudioEngine()
        }
        guard let audioEngine else {
            throw NSError(domain: "VoiceRecognizer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法初始化音频引擎"])
        }
        return (speechRecognizer, audioEngine)
    }

    func startRecording() throws {
        let (speechRecognizer, audioEngine) = try prepare()

        // Cancel any previous task and leftover tap (e.g. after a failed start).
        recognitionTask?.cancel()
        recognitionTask = nil
        removeTapIfNeeded()

        // Tapping inputNode triggers the system microphone permission prompt.
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Create a fresh recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(
            with: request
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
        tapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            onStateChange?(true)
        } catch {
            // start() failed — tear down the tap so the next attempt can install.
            removeTapIfNeeded()
            self.recognitionRequest = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            throw error
        }
    }

    func stopRecording() {
        if let audioEngine, audioEngine.isRunning { audioEngine.stop() }
        removeTapIfNeeded()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        // Don't cancel the task — let it deliver final results.
        onStateChange?(false)
    }

    /// Abort entirely (e.g. on permission error). Cancels task, tears down audio.
    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        if let audioEngine, audioEngine.isRunning { audioEngine.stop() }
        removeTapIfNeeded()
        recognitionRequest = nil
        onStateChange?(false)
    }

    private func removeTapIfNeeded() {
        guard tapInstalled, let audioEngine else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    // MARK: SFSpeechRecognizerDelegate

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer,
                          availabilityDidChange available: Bool) {
        if !available {
            DispatchQueue.main.async { [weak self] in
                self?.onError?("语音识别服务暂不可用")
            }
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

    override func orderOut(_ sender: Any?) {
        // Esc / ⌘W while holding the dictation key must not leave the mic open.
        voiceRecognizer.cancel()
        dictationPendingRange = nil
        updateRecordingIndicator(false)
        super.orderOut(sender)
    }

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

    /// Best-effort read for preview/search. Edit path must use `loadBodyForEdit`.
    func loadBody() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Strict UTF-8 read for the in-panel editor — never invent an empty body.
    func loadBodyForEdit() -> (text: String?, error: String?) {
        do {
            return (try String(contentsOf: url, encoding: .utf8), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

/// Scans an Obsidian vault for `.md` and `.sheet` (Spreadsheets plugin) files.
/// Fine for ~hundreds of notes — no persistent index. Also creates / saves
/// Markdown notes for the in-panel editor (`.sheet` stays read-only).
enum MarkdownVault {
    private static let noteExtensions: Set<String> = ["md", "markdown", "sheet"]
    static let rootPlaceholder = "（库根目录）"

    static var rootURL: URL {
        URL(fileURLWithPath: Settings.notesVaultPath, isDirectory: true)
    }

    static func isEditableMarkdown(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    static func search(
        query: String,
        vaultPath: String? = nil,
        excludes: [String]? = nil,
        isCancelled: (() -> Bool)? = nil
    ) -> [NoteHit] {
        let vault = vaultPath ?? Settings.notesVaultPath
        let excludes = excludes ?? Settings.notesExcludeDirs
        let root = URL(fileURLWithPath: vault, isDirectory: true)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let qLower = q.lowercased()

        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        var hits: [NoteHit] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if isCancelled?() == true { return [] }
            // Symlinks can resolve outside the vault — skip (match create/write).
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                var isLinkDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isLinkDir)
                if isLinkDir.boolValue { enumerator?.skipDescendants() }
                continue
            }
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
            let ext = url.pathExtension.lowercased()
            guard noteExtensions.contains(ext) else { continue }

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
            let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let haystack = ext == "sheet" ? SheetHTML.searchableText(from: raw) : raw
            guard haystack.lowercased().contains(qLower) else { continue }
            hits.append(NoteHit(url: url, relativePath: rel, title: title, rank: 1))
        }

        if isCancelled?() == true { return [] }
        return hits.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.title.localizedCaseInsensitiveCompare($1.title) != .orderedSame {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            // Same basename: .md before .sheet for a stable order.
            return $0.url.pathExtension.localizedCaseInsensitiveCompare($1.url.pathExtension)
                == .orderedAscending
        }
    }

    /// Cache key = vault path + excludes; guarded for background ⌘N walks.
    private static let subdirectoryCacheLock = NSLock()
    private static var subdirectoryCache: (vaultPath: String, excludes: [String], dirs: [String])?

    static func invalidateSubdirectoryCache() {
        subdirectoryCacheLock.lock()
        subdirectoryCache = nil
        subdirectoryCacheLock.unlock()
    }

    /// Relative directory paths under the vault (nested), honouring excludes.
    /// Retries at most twice if Settings move mid-walk (avoids unbounded recursion).
    static func listSubdirectories() -> [String] {
        var lastUncached: [String]?
        for _ in 0..<3 {
            let vaultPath = Settings.notesVaultPath
            let excludes = Settings.notesExcludeDirs
            subdirectoryCacheLock.lock()
            if let cached = subdirectoryCache,
               cached.vaultPath == vaultPath,
               cached.excludes == excludes {
                let dirs = cached.dirs
                subdirectoryCacheLock.unlock()
                return dirs
            }
            subdirectoryCacheLock.unlock()

            // Walk the same path we keyed — don't re-read Settings.notesVaultPath mid-walk.
            let root = URL(fileURLWithPath: vaultPath, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else {
                subdirectoryCacheLock.lock()
                let stillCurrent = Settings.notesVaultPath == vaultPath
                    && Settings.notesExcludeDirs == excludes
                if stillCurrent {
                    subdirectoryCache = (vaultPath, excludes, [])
                }
                subdirectoryCacheLock.unlock()
                if stillCurrent { return [] }
                continue
            }

            var dirs: [String] = []
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                // Symlink dirs can resolve outside the vault — never offer them in ⌘N.
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    enumerator?.skipDescendants()
                    continue
                }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                guard isDir.boolValue else { continue }
                let rel = relativePath(url, root: root)
                if shouldExclude(name: url.lastPathComponent, relative: rel, excludes: excludes) {
                    enumerator?.skipDescendants()
                    continue
                }
                if !rel.isEmpty { dirs.append(rel) }
            }
            let sorted = dirs.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            subdirectoryCacheLock.lock()
            // Settings moved during the walk — don't publish under the wrong key.
            guard Settings.notesVaultPath == vaultPath,
                  Settings.notesExcludeDirs == excludes else {
                subdirectoryCacheLock.unlock()
                lastUncached = sorted
                continue
            }
            subdirectoryCache = (vaultPath, excludes, sorted)
            subdirectoryCacheLock.unlock()
            return sorted
        }
        return lastUncached ?? []
    }

    /// Normalize a combo / typed subdirectory. Empty = vault root.
    /// On failure returns `(nil, message)`.
    static func normalizeRelativeDir(_ raw: String) -> (dir: String?, error: String?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == rootPlaceholder { s = "" }
        s = s.replacingOccurrences(of: "\\", with: "/")
        while s.hasPrefix("./") { s = String(s.dropFirst(2)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if s.isEmpty { return ("", nil) }
        if s.hasPrefix("/") || s.contains(":") {
            return (nil, "子目录须为笔记库内的相对路径")
        }
        let parts = s.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return (nil, "子目录路径无效（不能包含 ..）")
        }
        // Same policy as titles / `.skipsHiddenFiles` search — hidden segments
        // would create notes that vanish on the next listing.
        if parts.contains(where: { $0.hasPrefix(".") }) {
            return (nil, "子目录不能包含以 . 开头的路径组件")
        }
        return (parts.joined(separator: "/"), nil)
    }

    /// Strip path junk from a note title; drop a trailing `.md` / `.markdown`.
    /// On failure returns `(nil, message)`.
    static func normalizeTitle(_ raw: String) -> (title: String?, error: String?) {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".markdown", ".md"] where t.lowercased().hasSuffix(ext) {
            t = String(t.dropLast(ext.count))
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.isEmpty { return (nil, "请输入标题") }
        if t.contains("/") || t.contains("\\") || t.contains(":") {
            return (nil, "标题不能包含路径分隔符")
        }
        if t == "." || t == ".." { return (nil, "标题无效") }
        // Enumerators use `.skipsHiddenFiles` — a leading-dot title would create
        // a note that appears once via ensureHit, then vanishes from search.
        if t.hasPrefix(".") { return (nil, "标题不能以 . 开头") }
        return (t, nil)
    }

    enum CreateError: Error {
        case conflict(URL)
        case message(String)
    }

    /// Create an empty `.md` under `relativeDir` (created if needed).
    /// `vaultPath` / `excludes` pin Settings for the whole create (may race).
    static func createMarkdownNote(
        title: String,
        relativeDir: String,
        vaultPath: String? = nil,
        excludes: [String]? = nil
    ) -> Result<NoteHit, CreateError> {
        let titleNorm = normalizeTitle(title)
        if let err = titleNorm.error { return .failure(.message(err)) }
        guard let name = titleNorm.title else { return .failure(.message("请输入标题")) }

        let dirNorm = normalizeRelativeDir(relativeDir)
        if let err = dirNorm.error { return .failure(.message(err)) }
        let dir = dirNorm.dir ?? ""

        let vault = vaultPath ?? Settings.notesVaultPath
        let root = URL(fileURLWithPath: vault, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return .failure(.message("笔记库路径不存在：\(root.path)"))
        }
        let excludes = excludes ?? Settings.notesExcludeDirs
        let fileRel = dir.isEmpty ? "\(name).md" : "\(dir)/\(name).md"
        if shouldExclude(name: "\(name).md", relative: fileRel, excludes: excludes)
            || (!dir.isEmpty && shouldExclude(
                name: (dir as NSString).lastPathComponent, relative: dir, excludes: excludes)) {
            return .failure(.message("不能在排除目录中创建笔记（当前排除：\(excludes.joined(separator: "、"))）"))
        }
        let folder = dir.isEmpty ? root : root.appendingPathComponent(dir, isDirectory: true)
        // Containment BEFORE createDirectory — otherwise a symlink parent can
        // mkdir outside the vault.
        guard isInsideVault(folder, root: root) else {
            return .failure(.message("子目录解析后不在笔记库内（请检查符号链接）"))
        }
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
        } catch {
            return .failure(.message("无法创建目录：\(error.localizedDescription)"))
        }
        guard isInsideVault(folder, root: root) else {
            return .failure(.message("子目录解析后不在笔记库内（请检查符号链接）"))
        }
        let url = folder.appendingPathComponent("\(name).md")
        guard isInsideVault(url, root: root) else {
            return .failure(.message("目标路径不在笔记库内"))
        }
        // Exclusive create — do not replace an existing note (TOCTOU-safe).
        do {
            try Data().write(to: url, options: .withoutOverwriting)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                return .failure(.conflict(url))
            }
            return .failure(.message("无法创建文件：\(error.localizedDescription)"))
        }
        invalidateSubdirectoryCache()
        let rel = relativePath(url, root: root)
        return .success(NoteHit(url: url, relativePath: rel, title: name, rank: 0))
    }

    /// Drop a just-created empty `.md` if the panel hid before opening it.
    /// `vaultPath` pins the library root when Settings may have moved.
    static func removeEmptyCreatedNoteIfAbandoned(
        _ url: URL,
        vaultPath: String? = nil
    ) {
        let root: URL = {
            if let vaultPath, !vaultPath.isEmpty {
                return URL(fileURLWithPath: vaultPath, isDirectory: true)
            }
            return rootURL
        }()
        guard isEditableMarkdown(url), isInsideVault(url, root: root) else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        guard size == 0 else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Atomic UTF-8 write. Returns an error message on failure.
    /// `vaultPathOverride` keeps a mid-edit session writable if Settings changed
    /// the vault root underneath the open note.
    static func write(body: String, to url: URL, vaultPathOverride: String? = nil) -> String? {
        guard isEditableMarkdown(url) else {
            return "只能保存 Markdown（.md / .markdown）笔记"
        }
        let root: URL = {
            if let override = vaultPathOverride, !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return rootURL
        }()
        guard isInsideVault(url, root: root) else {
            return "目标路径不在笔记库内"
        }
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func contentModificationDate(of url: URL) -> Date? {
        // Prefer FileManager — URL resourceValues can return a stale cached mtime
        // right after our own write, which made the next ⌘S false-conflict.
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    static func firstMatch(in body: String, matching needle: String) -> String? {
        let n = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        let lower = body.lowercased()
        guard let range = lower.range(of: n.lowercased()) else { return nil }
        return String(body[range])
    }

    /// True when `url` resolves under `root` after following symlinks.
    /// For not-yet-created paths, resolves the deepest existing ancestor then
    /// re-appends the remaining components (so `vault/link/x` → outside fails).
    private static func isInsideVault(_ url: URL, root: URL) -> Bool {
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard let resolved = resolveAgainstExistingAncestors(url) else { return false }
        return path(resolved.path, isUnder: rootResolved.path)
    }

    private static func path(_ full: String, isUnder prefix: String) -> Bool {
        if full == prefix { return true }
        let boundary = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return full.hasPrefix(boundary)
    }

    private static func resolveAgainstExistingAncestors(_ url: URL) -> URL? {
        let fm = FileManager.default
        var probe = url.standardizedFileURL
        var missing: [String] = []
        while !fm.fileExists(atPath: probe.path) {
            let name = probe.lastPathComponent
            guard !name.isEmpty, name != "/", name != ".", name != ".." else { return nil }
            missing.insert(name, at: 0)
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { return nil }
            probe = parent
        }
        var resolved = probe.resolvingSymlinksInPath().standardizedFileURL
        for name in missing {
            resolved.appendPathComponent(name)
            if fm.fileExists(atPath: resolved.path) {
                resolved = resolved.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        return resolved
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let full = url.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path
        if full == prefix { return "" }
        let boundary = prefix.hasSuffix("/") ? prefix : prefix + "/"
        if full.hasPrefix(boundary) {
            return String(full.dropFirst(boundary.count))
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

// SheetHTML + MarkdownHTML live in Shared/ (also used by Quick Look extensions).

// MARK: - Notes search panel (Spotlight-like)

/// Spotlight-style search field: hugs committed text; while editing, keeps a
/// stable minimum width so IME 拼音 composition is never interrupted by Auto
/// Layout resizing the field editor (that was committing letter 1 when letter 2
/// arrived). ↑/↓ / Esc via `control:doCommandBy` only — never override keyDown.
private final class NotesSearchField: NSTextField {
    var onContentSizeMayChange: (() -> Void)?

    /// Width reserved for the whole time the field is first-responder / editing.
    /// Must fit a typical 拼音 syllable without mid-composition resize.
    private let editingFloor: CGFloat = 200
    private let rightMargin: CGFloat = 8
    private var lastSize: NSSize?
    private var isEditing = false

    override var stringValue: String {
        didSet {
            guard !isEditing else { return }
            lastSize = sizeForText(stringValue)
            invalidateIntrinsicContentSize()
        }
    }

    private func sizeForText(_ string: String) -> NSSize {
        let font = self.font ?? NSFont.systemFont(ofSize: 15)
        let width = NSAttributedString(string: string, attributes: [.font: font]).size().width
        var size = super.intrinsicContentSize
        size.width = max(4, width + (string.isEmpty ? 0 : rightMargin))
        return size
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        isEditing = true
        // One synchronous widen *before* any marked text. Do not resize again
        // until committed text changes — resizing mid-IME commits 拼音.
        var size = super.intrinsicContentSize
        size.width = max(lastSize?.width ?? 0, editingFloor)
        lastSize = size
        invalidateIntrinsicContentSize()
        onContentSizeMayChange?()
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        isEditing = false
        lastSize = sizeForText(stringValue)
        invalidateIntrinsicContentSize()
        onContentSizeMayChange?()
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        // Only runs for *committed* text (上屏), not for marked 拼音.
        let needed = sizeForText(stringValue).width
        var size = super.intrinsicContentSize
        size.width = max(editingFloor, needed)
        lastSize = size
        invalidateIntrinsicContentSize()
        onContentSizeMayChange?()
    }

    override var intrinsicContentSize: NSSize {
        if isEditing {
            var size = super.intrinsicContentSize
            let committed = sizeForText(stringValue).width
            size.width = max(editingFloor, committed, lastSize?.width ?? editingFloor)
            return size
        }
        return lastSize ?? sizeForText(stringValue)
    }
}

/// Empty area after the auto-growing field. Drag moves the panel; click
/// focuses the search field — same split Spotlight uses.
private final class NotesSearchDragArea: NSView {
    var onActivate: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = NSEvent.mouseLocation
        let origin = window.frame.origin
        var dragging = false
        // Bound the tracking loop — a missing mouseUp must not hang forever.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard window.isVisible,
                  let next = window.nextEvent(
                    matching: [.leftMouseUp, .leftMouseDragged],
                    until: deadline,
                    inMode: .eventTracking,
                    dequeue: true
                  ) else { break }
            if next.type == .leftMouseUp {
                if !dragging { onActivate?() }
                break
            }
            let now = NSEvent.mouseLocation
            let dx = now.x - start.x
            let dy = now.y - start.y
            if dragging || hypot(dx, dy) >= 4 {
                dragging = true
                window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
            }
        }
    }
}

/// Magnifying-glass that does not steal hits from the header.
private final class NotesSearchIconView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private enum NotesAlertAccessoryAssoc {
    static var titleDelegate: UInt8 = 0
    static var dirDelegate: UInt8 = 0
}

/// Soft search-bar style row for the new-note alert — same language as the
/// notes panel header: no bezel, no focus ring, just text on a quiet fill.
private final class NotesAlertFieldRow: NSView {
    let textField = NSTextField(string: "")
    private var menuButton: NotesAlertDirMenuButton?
    private let fieldPadX: CGFloat = 10
    private let menuW: CGFloat = 22

    init(frame frameRect: NSRect, showsDirMenu: Bool) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 8
        if #available(macOS 11.0, *) {
            layer?.cornerCurve = .continuous
        }
        updateFill(focused: false)

        textField.isBordered = false
        textField.isBezeled = false
        textField.focusRingType = .none
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.isEditable = true
        textField.isSelectable = true
        textField.font = .systemFont(ofSize: 13, weight: .regular)
        textField.lineBreakMode = .byClipping
        textField.cell?.isScrollable = true
        (textField.cell as? NSTextFieldCell)?.usesSingleLineMode = true
        textField.translatesAutoresizingMaskIntoConstraints = true
        addSubview(textField)

        if showsDirMenu {
            let menu = NotesAlertDirMenuButton(
                frame: NSRect(x: 0, y: 0, width: menuW, height: 18))
            menu.dirField = textField
            menuButton = menu
            addSubview(menu)
        }

        layoutFields()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        layoutFields()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill(focused: textField.currentEditor() != nil)
    }

    func configureDirMenu(dirs: [String], rootTitle: String) {
        menuButton?.configure(dirs: dirs, rootTitle: rootTitle)
    }

    func markFocused(_ focused: Bool) {
        updateFill(focused: focused)
        if focused {
            (textField.currentEditor() as? NSTextView)?.focusRingType = .none
            (textField.currentEditor() as? NSTextView)?.drawsBackground = false
        }
    }

    private func layoutFields() {
        let h = bounds.height
        let menu = menuButton
        let textW = menu == nil
            ? bounds.width - fieldPadX * 2
            : bounds.width - fieldPadX * 2 - menuW - 4
        textField.frame = NSRect(
            x: fieldPadX,
            y: (h - 18) / 2,
            width: max(40, textW),
            height: 18)
        if let menu {
            menu.frame = NSRect(
                x: bounds.width - fieldPadX - menuW,
                y: (h - 18) / 2,
                width: menuW,
                height: 18)
        }
    }

    private func updateFill(focused: Bool) {
        // Quiet fill like a search well — never a stroked box.
        let base = NSColor.black.withAlphaComponent(focused ? 0.07 : 0.045)
        let adapted = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if dark {
                return NSColor.white.withAlphaComponent(focused ? 0.14 : 0.08)
            }
            return base
        }
        layer?.backgroundColor = adapted.cgColor
        layer?.borderWidth = 0
    }
}

/// Tracks focus so the soft row can nudge its fill — no system outline.
private final class NotesAlertRowFieldDelegate: NSObject, NSTextFieldDelegate {
    weak var row: NotesAlertFieldRow?

    func controlTextDidBeginEditing(_ obj: Notification) {
        row?.markFocused(true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        row?.markFocused(false)
    }
}

/// Chevron-only pull-down that fills a sibling dir field. No own chrome.
private final class NotesAlertDirMenuButton: NSPopUpButton {
    weak var dirField: NSTextField?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect, pullsDown: true)
        finishSetup()
    }

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: true)
        finishSetup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func finishSetup() {
        autoenablesItems = false
        focusRingType = .none
        isBordered = false
        if let cell = cell as? NSPopUpButtonCell {
            cell.arrowPosition = .noArrow
            cell.imagePosition = .imageOnly
            cell.focusRingType = .none
            cell.backgroundColor = .clear
        }
        target = self
        action = #selector(menuPicked(_:))
    }

    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func drawFocusRingMask() {}

    func configure(dirs: [String], rootTitle: String) {
        removeAllItems()
        addItem(withTitle: "")
        if let img = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "选择子目录")
        {
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            let configured = img.withSymbolConfiguration(cfg)
            item(at: 0)?.image = configured
            item(at: 0)?.image?.isTemplate = true
        }
        addItem(withTitle: rootTitle)
        item(at: 1)?.representedObject = rootTitle
        for dir in dirs {
            addItem(withTitle: dir)
            lastItem?.representedObject = dir
        }
        selectItem(at: 0)
    }

    @objc private func menuPicked(_ sender: NSPopUpButton) {
        defer { selectItem(at: 0) }
        let idx = indexOfSelectedItem
        guard idx > 0 else { return }
        let value = (item(at: idx)?.representedObject as? String) ?? item(at: idx)?.title
        guard let value, !value.isEmpty else { return }
        dirField?.stringValue = value
    }
}

/// Soft amber unsaved marker shown beside a note title in the list.
private final class NotesDirtyDotView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3
        updateColor()
        toolTip = "未保存"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 6, height: 6) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        // Warm amber that stays readable on both selection fills and plain rows.
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.92).cgColor
    }
}

/// Notes-panel source editor: Esc asks the panel to confirm/close
/// (but not while 拼音 / IME marked text is composing).
private final class NotesEditorTextView: NSTextView {
    var onCancel: (() -> Void)?

    /// Explicit TextKit 1 stack — default TextKit 2 on macOS 13+ has caret /
    /// focus regressions inside floating panels (no insertion point, no typing).
    override convenience init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(
            width: max(frameRect.width, 1),
            height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        self.init(frame: frameRect, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            return
        }
        onCancel?()
    }
}

/// Opaque rounded chrome. Vibrancy + WKWebView fights corner clipping and
/// washes out body text — solid fill keeps both readable and clean.
private final class NotesPanelChrome: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 8
        if #available(macOS 11.0, *) {
            layer?.cornerCurve = .continuous
        }
        updateFill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

/// Always-on-top notes browser: query → list → Markdown preview (select/copy),
/// plus in-panel Markdown edit / create (⌘E / ⌘S / ⌘N). `.sheet` stays
/// preview-only. Chrome mirrors Spotlight: borderless floating panel, custom
/// search row, light status strip.
final class NotesSearchPanel: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, WKNavigationDelegate, NSSplitViewDelegate, NSTextViewDelegate {
    /// Keep WebKit around briefly after hide so rapid re-open stays snappy.
    private static let webViewTeardownDelay: TimeInterval = 15

    private enum PaneMode {
        case preview
        case edit
    }

    private let searchField = NotesSearchField()
    private let tableView = NSTableView()
    /// Created on first show; torn down after the panel stays hidden.
    private var previewWeb: WKWebView?
    private var previewPane: NSView!
    private var editorScroll: NSScrollView?
    private var editorView: NSTextView?
    private var webViewTeardownWork: DispatchWorkItem?
    private let statusLabel = NSTextField(labelWithString: "")
    private let placeholderLabel = NSTextField(labelWithString: "搜索文件名或正文…")
    private var splitView: NSSplitView!
    private var hits: [NoteHit] = []
    private var searchWork: DispatchWorkItem?
    private var searchGeneration = 0
    /// Jump text tied to the load that produced the current document.
    private var pendingJump: (token: Int, text: String?)?
    private var loadToken = 0
    private var currentQuery = ""
    /// Vault / excludes that produced the current `hits` list.
    private var resultsVaultPath = ""
    private var resultsExcludes: [String] = []
    /// Settings changed while editing / ⌘N — refresh after leaving that session.
    private var settingsChangedDuringEdit = false
    private var didApplyInitialSplit = false
    private var splitInitRetries = 0
    /// Per-note match hint folded into the bottom status line.
    private var matchHint = ""
    /// Last previewed note + query — skip redundant WKWebView reloads.
    private var previewedPath: String?
    private var previewedQuery: String?
    private var paneMode: PaneMode = .preview
    private var editingURL: URL?
    /// Vault root captured when edit began — survives Settings vault changes.
    private var editingVaultPath: String?
    private var loadedEditText = ""
    /// mtime at successful load/save — cheap precheck before content compare on ⌘S.
    private var loadedEditMTime: Date?
    /// False until a successful `loadBodyForEdit` lands — blocks save/wipe.
    private var editContentReady = false
    /// Set on first edit after load; avoids full-string compares on every keystroke.
    private var editHasEdits = false
    private var editLoadToken = 0
    /// Prevents stacked ⌘N alerts while the directory walk / create is in flight.
    private var isPresentingNewNote = false
    /// Bumped on hide and each ⌘N start — drops stale dir-walk / create callbacks.
    private var newNotePresentationToken = 0
    /// Bumped to cancel a post-create search→enterEdit that lost the race.
    private var newNoteCompletionToken = 0
    /// Coalesces deferred dirty→select so rapid clicks do not stack alerts.
    private var pendingDirtySelectRow: Int?
    private var isDirty: Bool {
        paneMode == .edit && editContentReady && editHasEdits
    }

    private enum SaveOutcome {
        case saved
        case reloaded
        case cancelled
        case failed
    }

    /// App quit / external close: prompt if the in-panel editor is dirty.
    @discardableResult
    func confirmDiscardOrSaveIfNeeded() -> Bool {
        resolveDirtyIfNeeded()
    }

    /// Settings vault/excludes changed — refresh listing when not mid-edit.
    func handleSettingsChanged() {
        MarkdownVault.invalidateSubdirectoryCache()
        if paneMode == .edit || isPresentingNewNote {
            settingsChangedDuringEdit = true
            return
        }
        guard isVisible else { return }
        runSearch(currentQuery)
    }

    private func listNeedsRefreshAgainstSettings() -> Bool {
        settingsChangedDuringEdit
            || resultsVaultPath != Settings.notesVaultPath
            || resultsExcludes != Settings.notesExcludeDirs
    }

    private static func sameNoteURL(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        minSize = NSSize(width: 520, height: 320)
        setFrameAutosaveName("PromptQyNotesSearchFrame")
        buildContent()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { requestClose() }
    override func close() { requestClose() }

    /// Esc / ⌘W / red light: confirm unsaved edits, then hide.
    private func requestClose() {
        guard resolveDirtyIfNeeded() else { return }
        leaveEditMode(showPreviewAfter: false)
        hidePanel()
    }

    private func hidePanel() {
        // End editing so NotesSearchField.isEditing / lastSize reset; otherwise
        // a later `stringValue = ""` is ignored while isEditing stays true.
        if searchField.currentEditor() != nil {
            endEditing(for: searchField)
        }
        makeFirstResponder(nil)
        releasePreviewResources()
        super.orderOut(nil)
    }

    override func orderOut(_ sender: Any?) {
        // External callers (and hidePanel) land here; if still dirty, confirm.
        if isVisible, isDirty {
            guard resolveDirtyIfNeeded() else { return }
            leaveEditMode(showPreviewAfter: false)
        }
        if searchField.currentEditor() != nil {
            endEditing(for: searchField)
        }
        makeFirstResponder(nil)
        releasePreviewResources()
        super.orderOut(sender)
    }

    /// Drop list bodies and schedule WebKit teardown while the panel is hidden.
    private func releasePreviewResources() {
        searchWork?.cancel()
        searchWork = nil
        searchGeneration += 1
        loadToken += 1
        pendingJump = nil
        previewedPath = nil
        previewedQuery = nil
        paneMode = .preview
        editingURL = nil
        editingVaultPath = nil
        loadedEditText = ""
        loadedEditMTime = nil
        editContentReady = false
        editHasEdits = false
        editLoadToken += 1
        newNotePresentationToken += 1
        newNoteCompletionToken += 1
        isPresentingNewNote = false
        pendingDirtySelectRow = nil
        resultsVaultPath = ""
        resultsExcludes = []
        settingsChangedDuringEdit = false
        editorView?.string = ""
        editorScroll?.isHidden = true
        previewWeb?.isHidden = false
        setSearchFieldInteractionEnabled(true)
        hits = []
        tableView.reloadData()
        matchHint = ""
        statusLabel.stringValue = ""
        previewWeb?.stopLoading()
        scheduleWebViewTeardown()
    }

    private func scheduleWebViewTeardown() {
        webViewTeardownWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.teardownPreviewWeb()
        }
        webViewTeardownWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.webViewTeardownDelay, execute: work)
    }

    private func cancelWebViewTeardown() {
        webViewTeardownWork?.cancel()
        webViewTeardownWork = nil
    }

    /// Release the WKWebView so WebKit content/GPU/network processes can exit.
    private func teardownPreviewWeb() {
        webViewTeardownWork = nil
        loadToken += 1
        pendingJump = nil
        previewedPath = nil
        previewedQuery = nil
        guard let web = previewWeb else { return }
        web.stopLoading()
        web.navigationDelegate = nil
        web.removeFromSuperview()
        previewWeb = nil
    }

    /// Create or reuse the preview WKWebView (host-side WebKit cost).
    @discardableResult
    private func ensurePreviewWeb() -> WKWebView {
        if let web = previewWeb { return web }
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 12.0, *) {
            web.underPageBackgroundColor = .windowBackgroundColor
        }
        web.setValue(false, forKey: "drawsBackground")
        web.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        web.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        web.setContentHuggingPriority(.defaultLow, for: .vertical)
        web.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        previewPane.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: previewPane.topAnchor),
            web.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor),
        ])
        previewWeb = web
        return web
    }

    func showAndFocus() {
        cancelWebViewTeardown()
        ensurePreviewWeb()
        if !isVisible { center() }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Already editing: re-summon must not clear the query / tear down the
        // session (in-flight runSearch("") used to wipe unsaved work).
        if paneMode == .edit {
            focusNotesEditor()
            return
        }

        // Fresh open: drop a stale subdirectory cache so ⌘N sees new folders.
        MarkdownVault.invalidateSubdirectoryCache()
        searchField.stringValue = ""
        runSearch("")
        // Finish chrome layout before focusing so the first IME keystroke
        // does not collide with an initial Auto Layout pass.
        contentView?.layoutSubtreeIfNeeded()
        applyInitialSplitIfNeeded()
        // Defer first-responder + input-context activation to the next turn;
        // synchronous focus on cold launch often eats the first 拼音 letter.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.makeFirstResponder(self.searchField)
            (self.searchField.currentEditor() as? NSTextView)?.inputContext?.activate()
            NSTextInputContext.current?.activate()
            self.updateSearchPlaceholder()
        }
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
        let searchIcon = NotesSearchIconView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "搜索")
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.backgroundColor = .clear
        searchField.font = .systemFont(ofSize: 15, weight: .regular)
        searchField.lineBreakMode = .byClipping
        searchField.cell?.isScrollable = true
        (searchField.cell as? NSTextFieldCell)?.usesSingleLineMode = true
        searchField.onContentSizeMayChange = { [weak self] in self?.updateSearchPlaceholder() }
        searchField.translatesAutoresizingMaskIntoConstraints = false
        // Hug content so empty space is real chrome (Spotlight pattern).
        searchField.setContentHuggingPriority(.required, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.required, for: .horizontal)

        placeholderLabel.font = .systemFont(ofSize: 15, weight: .regular)
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.drawsBackground = false
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        let dragArea = NotesSearchDragArea()
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        dragArea.onActivate = { [weak self] in
            guard let self else { return }
            self.makeKeyAndOrderFront(nil)
            // Editing owns focus — don't yank it to the frozen search field.
            if self.paneMode == .edit {
                self.focusNotesEditor()
                return
            }
            self.makeFirstResponder(self.searchField)
        }

        // Equal top/bottom padding so the row is vertically centered.
        let searchHeader = NSView()
        searchHeader.translatesAutoresizingMaskIntoConstraints = false
        searchHeader.addSubview(searchIcon)
        searchHeader.addSubview(placeholderLabel)
        searchHeader.addSubview(searchField)
        searchHeader.addSubview(dragArea)

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
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.selectionHighlightStyle = .regular

        let listScroll = NSScrollView()
        listScroll.documentView = tableView
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .noBorder
        listScroll.drawsBackground = false
        listScroll.backgroundColor = .clear
        // Split-view children must use frame-based layout (autoresizingMask).
        // Auto Layout width constraints on them fight the divider and snap back.
        listScroll.translatesAutoresizingMaskIntoConstraints = true
        listScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        listScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // WKWebView is created lazily in ensurePreviewWeb() — keep an empty
        // pane here so the split layout is stable before first show.
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        pane.translatesAutoresizingMaskIntoConstraints = true
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor.clear.cgColor
        pane.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewPane = pane

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.autosaveName = "PromptQyNotesSplit"
        split.wantsLayer = true
        split.layer?.backgroundColor = NSColor.clear.cgColor
        split.addSubview(listScroll)
        split.addSubview(pane)
        // List holds its width when the window resizes; preview absorbs the slack.
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 1)
        split.translatesAutoresizingMaskIntoConstraints = false
        splitView = split

        statusLabel.font = .systemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.required, for: .vertical)
        statusLabel.lineBreakMode = .byTruncatingMiddle

        let headerSep = NSBox()
        headerSep.boxType = .separator
        headerSep.translatesAutoresizingMaskIntoConstraints = false

        let footerSep = NSBox()
        footerSep.boxType = .separator
        footerSep.translatesAutoresizingMaskIntoConstraints = false

        let root = NotesPanelChrome(frame: NSRect(x: 0, y: 0, width: 720, height: 440))
        root.autoresizingMask = [.width, .height]
        root.addSubview(searchHeader)
        root.addSubview(headerSep)
        root.addSubview(split)
        root.addSubview(footerSep)
        root.addSubview(statusLabel)
        contentView = root

        NSLayoutConstraint.activate([
            searchHeader.topAnchor.constraint(equalTo: root.topAnchor),
            searchHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchHeader.heightAnchor.constraint(equalToConstant: 48),

            searchIcon.leadingAnchor.constraint(equalTo: searchHeader.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: searchField.firstBaselineAnchor, constant: -5),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),

            // Field hugs text; trailing side is the drag area (Spotlight).
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            searchField.topAnchor.constraint(equalTo: searchHeader.topAnchor, constant: 14),
            searchField.bottomAnchor.constraint(equalTo: searchHeader.bottomAnchor, constant: -14),
            searchField.widthAnchor.constraint(lessThanOrEqualTo: searchHeader.widthAnchor, constant: -80),

            placeholderLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            dragArea.leadingAnchor.constraint(equalTo: searchField.trailingAnchor),
            dragArea.trailingAnchor.constraint(equalTo: searchHeader.trailingAnchor),
            dragArea.topAnchor.constraint(equalTo: searchHeader.topAnchor),
            dragArea.bottomAnchor.constraint(equalTo: searchHeader.bottomAnchor),

            headerSep.topAnchor.constraint(equalTo: searchHeader.bottomAnchor),
            headerSep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerSep.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            split.topAnchor.constraint(equalTo: headerSep.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: footerSep.topAnchor),

            footerSep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerSep.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: footerSep.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
    }

    private func refreshStatusLine(emptyMessage: String? = nil) {
        if let emptyMessage {
            statusLabel.stringValue = emptyMessage
            return
        }
        if paneMode == .edit {
            var parts: [String]
            if !editContentReady {
                parts = ["加载中…"]
            } else {
                parts = [isDirty ? "未保存" : "编辑中"]
                parts.append("⌘S 保存")
            }
            parts.append("⌘E 预览")
            parts.append("⌘N 新建")
            parts.append("Esc 关闭")
            statusLabel.stringValue = parts.joined(separator: " · ")
            return
        }
        guard !hits.isEmpty else {
            statusLabel.stringValue = "⌘N 新建 · Esc 关闭"
            return
        }
        var parts = ["\(hits.count) 条"]
        if !matchHint.isEmpty { parts.append(matchHint) }
        if selectedHit.map({ MarkdownVault.isEditableMarkdown($0.url) }) == true {
            parts.append("⌘E 编辑")
        }
        parts.append("⌘N 新建")
        parts.append("Esc 关闭")
        statusLabel.stringValue = parts.joined(separator: " · ")
    }

    private var selectedHit: NoteHit? {
        let row = tableView.selectedRow
        guard row >= 0, row < hits.count else { return nil }
        return hits[row]
    }

    /// Refresh the unsaved dot on the row currently being edited.
    private func reloadDirtyIndicatorInList() {
        guard let editingURL,
              let row = hits.firstIndex(where: { Self.sameNoteURL($0.url, editingURL) })
        else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0))
    }

    /// Editing owns the right pane — keep the query field frozen so it cannot
    /// diverge from `currentQuery` / the result list.
    private func setSearchFieldInteractionEnabled(_ enabled: Bool) {
        searchField.isEditable = enabled
        searchField.isSelectable = enabled
        if !enabled {
            if searchField.currentEditor() != nil {
                endEditing(for: searchField)
            }
            if searchField.stringValue != currentQuery {
                searchField.stringValue = currentQuery
                updateSearchPlaceholder()
            }
        }
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
        updateSearchPlaceholder()
        // Editing owns the right pane — searching would eject the session.
        // Leave edit (⌘E) before typing a new query.
        guard paneMode != .edit else { return }
        // Width refresh is already handled in NotesSearchField.textDidChange.
        let q = searchField.stringValue
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch(q) }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func updateSearchPlaceholder() {
        // Only depend on committed text. Do not query hasMarkedText / toggle
        // visibility during 拼音 — that layout side-effect commits letter 1
        // when letter 2 is typed.
        let alpha: CGFloat = searchField.stringValue.isEmpty ? 1 : 0
        if placeholderLabel.alphaValue != alpha {
            placeholderLabel.alphaValue = alpha
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // While 拼音 is composing, let the IME keep arrow / navigation keys.
        if textView.hasMarkedText() { return false }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(by: -1); return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(by: 1); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            requestClose(); return true
        }
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              let chars = event.charactersIgnoringModifiers?.lowercased(),
              chars.count == 1 else {
            return super.performKeyEquivalent(with: event)
        }
        switch chars {
        case "e":
            toggleEditMode(); return true
        case "s":
            if paneMode == .edit { _ = saveCurrentEdit(); return true }
        case "n":
            presentNewNoteDialog(); return true
        default:
            break
        }
        return super.performKeyEquivalent(with: event)
    }

    private func runSearch(_ query: String) {
        searchGeneration += 1
        let gen = searchGeneration
        let previousQuery = currentQuery
        let searchingWhileEditing = paneMode == .edit
        currentQuery = query
        // Sample vault + excludes together so list content matches resultsExcludes.
        let vault = Settings.notesVaultPath
        let excludes = Settings.notesExcludeDirs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = MarkdownVault.search(
                query: query, vaultPath: vault, excludes: excludes,
                isCancelled: { [weak self] in
                    guard let self else { return true }
                    return gen != self.searchGeneration
                })
            DispatchQueue.main.async {
                guard let self = self, gen == self.searchGeneration else { return }
                // A search that started in preview must not land on an edit
                // session begun while it was in flight (`enterEditMode` bumps
                // searchGeneration; this is the belt-and-suspenders check).
                if self.paneMode == .edit, !searchingWhileEditing {
                    return
                }
                if self.paneMode == .edit {
                    guard self.resolveDirtyIfNeeded() else {
                        self.currentQuery = previousQuery
                        if self.searchField.currentEditor() != nil {
                            self.endEditing(for: self.searchField)
                        }
                        self.searchField.stringValue = previousQuery
                        self.updateSearchPlaceholder()
                        return
                    }
                    self.leaveEditMode(showPreviewAfter: false)
                }
                self.applySearchResults(
                    results, vaultPath: vault, excludes: excludes)
            }
        }
    }

    private func applySearchResults(
        _ results: [NoteHit],
        vaultPath: String,
        excludes: [String],
        selectURL: URL? = nil,
        ensureHit: NoteHit? = nil
    ) {
        var results = results
        if let ensureHit,
           !results.contains(where: { Self.sameNoteURL($0.url, ensureHit.url) }) {
            results.insert(ensureHit, at: 0)
        }
        hits = results
        resultsVaultPath = vaultPath
        resultsExcludes = excludes
        settingsChangedDuringEdit = false
        tableView.reloadData()
        previewedPath = nil  // force preview refresh for new results
        if results.isEmpty {
            clearPreview()
            let exists = FileManager.default.fileExists(atPath: vaultPath)
            refreshStatusLine(emptyMessage: exists
                ? "无匹配结果 · ⌘N 新建 · Esc 关闭"
                : "笔记库路径不存在：\(vaultPath)")
            return
        }
        let index: Int = {
            if let selectURL,
               let i = results.firstIndex(where: { Self.sameNoteURL($0.url, selectURL) }) {
                return i
            }
            return 0
        }()
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        // selectRowIndexes is a no-op when the row was already selected,
        // so selectionDidChange may not fire — always show once here.
        showPreview(for: index)
        refreshStatusLine()
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

    // MARK: Edit / create

    /// Save / Don't Save / Cancel. Returns false if the user cancelled.
    @discardableResult
    private func resolveDirtyIfNeeded() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "笔记有未保存的更改"
        alert.informativeText = "要在离开前保存吗？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Reloaded from disk also clears local dirty — allow navigation to proceed.
            switch saveCurrentEdit() {
            case .saved, .reloaded: return true
            case .cancelled, .failed: return false
            }
        case .alertSecondButtonReturn:
            if let editorView {
                resetEditorBuffer(editorView, text: loadedEditText)
            }
            editHasEdits = false
            reloadDirtyIndicatorInList()
            return true
        default:
            return false
        }
    }

    /// Replace editor text and drop undo history so ⌘Z cannot leak across notes.
    private func resetEditorBuffer(_ editor: NSTextView, text: String) {
        editor.breakUndoCoalescing()
        editor.undoManager?.removeAllActions()
        editor.string = text
        editor.breakUndoCoalescing()
        editor.undoManager?.removeAllActions()
    }

    private func toggleEditMode() {
        if paneMode == .edit {
            guard resolveDirtyIfNeeded() else { return }
            leaveEditMode(showPreviewAfter: true)
            return
        }
        // ⌘N directory walk / create I/O owns the session — don't re-enter edit.
        if isPresentingNewNote {
            NSSound.beep()
            return
        }
        guard let hit = selectedHit else {
            NSSound.beep()
            return
        }
        guard MarkdownVault.isEditableMarkdown(hit.url) else {
            NSSound.beep()
            return
        }
        enterEditMode(for: hit)
    }

    private func enterEditMode(for hit: NoteHit) {
        // Post-create open is allowed after finishNewNotePresentation; block only
        // while the ⌘N alert / create I/O still holds the flag.
        if isPresentingNewNote { return }
        // Drop in-flight search/preview so they cannot tear down this session.
        searchGeneration += 1
        loadToken += 1
        editLoadToken += 1
        newNoteCompletionToken += 1
        let token = editLoadToken
        let url = hit.url

        let editor = ensureEditor()
        // Keep selectable so the view can accept first responder; only lock
        // editing until UTF-8 load commits (avoids wiped keystrokes + no dirty).
        editor.isEditable = false
        editor.isSelectable = true
        resetEditorBuffer(editor, text: "")
        loadedEditText = ""
        loadedEditMTime = nil
        editContentReady = false
        editHasEdits = false
        editingURL = url
        // Prefer the vault that produced this hit list (survives Settings races).
        editingVaultPath = resultsVaultPath.isEmpty
            ? Settings.notesVaultPath : resultsVaultPath
        paneMode = .edit
        setSearchFieldInteractionEnabled(false)
        previewWeb?.isHidden = true
        editorScroll?.isHidden = false
        layoutNotesEditorGeometry()
        previewedPath = nil
        refreshStatusLine()
        reloadDirtyIndicatorInList()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = hit.loadBodyForEdit()
            let mtime = MarkdownVault.contentModificationDate(of: url)
            DispatchQueue.main.async {
                guard let self else { return }
                guard token == self.editLoadToken,
                      self.paneMode == .edit,
                      self.editingURL.map({ Self.sameNoteURL($0, url) }) == true else { return }
                if let err = loaded.error, loaded.text == nil {
                    self.leaveEditMode(showPreviewAfter: true)
                    let alert = NSAlert()
                    alert.messageText = "无法打开笔记"
                    alert.informativeText =
                        "未能以 UTF-8 读取文件，已取消编辑以免覆盖原文。\n\n\(err)"
                    alert.runModal()
                    return
                }
                let body = loaded.text ?? ""
                self.resetEditorBuffer(editor, text: body)
                editor.isEditable = true
                editor.isSelectable = true
                self.loadedEditText = body
                self.loadedEditMTime = mtime
                self.editContentReady = true
                self.editHasEdits = false
                self.refreshStatusLine()
                self.focusNotesEditor()
            }
        }
    }

    /// Size the text container to the clip view so empty/short notes still fill
    /// the pane (otherwise clicks miss the document view on macOS 14).
    private func layoutNotesEditorGeometry() {
        guard let scroll = editorScroll, let editor = editorView else { return }
        scroll.layoutSubtreeIfNeeded()
        let clip = scroll.contentView.bounds.size
        let width = max(clip.width, 1)
        let height = max(clip.height, 1)
        editor.minSize = NSSize(width: 0, height: height)
        editor.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(
            width: width, height: CGFloat.greatestFiniteMagnitude)
        if editor.frame.width != width {
            editor.setFrameSize(NSSize(
                width: width, height: max(editor.frame.height, height)))
        }
    }

    /// Focus the notes editor after layout / key-window settle. Synchronous
    /// `makeFirstResponder` right after unhiding often fails on macOS 14.x
    /// (no caret, keystrokes go nowhere).
    private func focusNotesEditor() {
        guard paneMode == .edit, editContentReady, editorView != nil else { return }
        if !isKeyWindow {
            makeKeyAndOrderFront(nil)
        }
        layoutNotesEditorGeometry()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.paneMode == .edit,
                  self.editContentReady,
                  let editor = self.editorView else { return }
            if !self.isKeyWindow {
                self.makeKeyAndOrderFront(nil)
            }
            editor.isEditable = true
            editor.isSelectable = true
            _ = self.makeFirstResponder(editor)
            let length = (editor.string as NSString).length
            let sel = editor.selectedRange()
            if sel.location > length || sel.location + sel.length > length {
                editor.setSelectedRange(NSRange(location: 0, length: 0))
            }
            editor.inputContext?.activate()
            NSTextInputContext.current?.activate()
            editor.updateInsertionPointStateAndRestartTimer(true)
        }
    }

    private func leaveEditMode(showPreviewAfter: Bool) {
        let row = tableView.selectedRow
        editLoadToken += 1
        pendingDirtySelectRow = nil
        paneMode = .preview
        editingURL = nil
        editingVaultPath = nil
        loadedEditText = ""
        loadedEditMTime = nil
        editContentReady = false
        editHasEdits = false
        if let editorView {
            editorView.isEditable = false
            editorView.isSelectable = true
            resetEditorBuffer(editorView, text: "")
        }
        editorScroll?.isHidden = true
        previewWeb?.isHidden = false
        setSearchFieldInteractionEnabled(true)
        refreshStatusLine()
        tableView.reloadData()
        if isVisible {
            makeFirstResponder(searchField)
        }
        // Vault/excludes may have changed under an edit session — drop stale hits
        // before the user can re-⌘E an old-path note against the new root.
        if isVisible, listNeedsRefreshAgainstSettings() {
            settingsChangedDuringEdit = false
            runSearch(currentQuery)
            return
        }
        if showPreviewAfter, row >= 0 {
            previewedPath = nil
            showPreview(for: row)
        }
    }

    /// True when on-disk text differs from the last loaded/saved buffer.
    /// mtime is a cheap precheck; content compare strips UTF-8 BOM (String load does).
    private func diskDivergedFromLoadedEdit(url: URL) -> Bool {
        if let known = loadedEditMTime,
           let current = MarkdownVault.contentModificationDate(of: url),
           current == known {
            return false
        }
        guard let diskData = try? Data(contentsOf: url) else {
            // Unreadable disk → treat as diverged so we don't silently overwrite.
            return true
        }
        let payload: Data = diskData.starts(with: [0xEF, 0xBB, 0xBF])
            ? Data(diskData.dropFirst(3))
            : diskData
        guard let diskText = String(data: payload, encoding: .utf8) else { return true }
        return diskText != loadedEditText
    }

    /// Prompt when the on-disk note changed under us. `.overwrite` proceeds to write.
    private func promptExternalEditConflict() -> SaveOutcome? {
        let alert = NSAlert()
        alert.messageText = "文件已被其他程序修改"
        alert.informativeText = "磁盘上的内容与打开时不一致。要覆盖、重新加载，还是取消？"
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "重新加载")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return nil  // overwrite — caller writes
        case .alertSecondButtonReturn:
            reloadCurrentEditFromDisk()
            return .reloaded
        default:
            return .cancelled
        }
    }

    @discardableResult
    private func saveCurrentEdit() -> SaveOutcome {
        guard paneMode == .edit, let url = editingURL, let editorView else {
            return .failed
        }
        guard editContentReady else {
            let alert = NSAlert()
            alert.messageText = "无法保存"
            alert.informativeText = "笔记仍在加载或未能读入，请稍候再试或取消编辑。"
            alert.runModal()
            return .failed
        }
        let text = editorView.string
        // Editor matches our baseline — still check disk before adopting mtime.
        // Refreshing mtime alone (without content check) let an external writer's
        // mtime poison the baseline and skip conflict UI on the next real save.
        if text == loadedEditText {
            if !diskDivergedFromLoadedEdit(url: url) {
                editHasEdits = false
                loadedEditMTime = MarkdownVault.contentModificationDate(of: url)
                refreshStatusLine()
                reloadDirtyIndicatorInList()
                return .saved
            }
            if let outcome = promptExternalEditConflict() {
                return outcome
            }
            // Overwrite with unchanged editor text — fall through to write.
            if diskDivergedFromLoadedEdit(url: url),
               let outcome = promptExternalEditConflict() {
                return outcome
            }
        } else if diskDivergedFromLoadedEdit(url: url) {
            // Only prompt when disk content actually differs from our baseline.
            if let outcome = promptExternalEditConflict() {
                return outcome
            }
            // Overwrite chosen — verify once more after the modal (TOCTOU).
            if diskDivergedFromLoadedEdit(url: url),
               let outcome = promptExternalEditConflict() {
                return outcome
            }
        }
        if let err = MarkdownVault.write(
            body: text, to: url, vaultPathOverride: editingVaultPath)
        {
            let alert = NSAlert()
            alert.messageText = "保存失败"
            alert.informativeText = err
            alert.runModal()
            return .failed
        }
        // Prefer the bytes that actually landed (handles any write normalization).
        if let onDisk = try? String(contentsOf: url, encoding: .utf8) {
            loadedEditText = onDisk
            if editorView.string != onDisk {
                let ranges = editorView.selectedRanges
                resetEditorBuffer(editorView, text: onDisk)
                editorView.selectedRanges = ranges
            }
        } else {
            loadedEditText = text
        }
        loadedEditMTime = MarkdownVault.contentModificationDate(of: url)
        editHasEdits = false
        previewedPath = nil
        refreshStatusLine()
        reloadDirtyIndicatorInList()
        return .saved
    }

    /// Replace the editor buffer with the on-disk UTF-8 body (external conflict).
    private func reloadCurrentEditFromDisk() {
        guard paneMode == .edit, let url = editingURL, let editorView else { return }
        let loaded = NoteHit(
            url: url,
            relativePath: url.lastPathComponent,
            title: url.deletingPathExtension().lastPathComponent,
            rank: 0
        ).loadBodyForEdit()
        if let err = loaded.error, loaded.text == nil {
            let alert = NSAlert()
            alert.messageText = "无法重新加载"
            alert.informativeText = err
            alert.runModal()
            return
        }
        let body = loaded.text ?? ""
        resetEditorBuffer(editorView, text: body)
        loadedEditText = body
        loadedEditMTime = MarkdownVault.contentModificationDate(of: url)
        editHasEdits = false
        refreshStatusLine()
        reloadDirtyIndicatorInList()
    }

    private func ensureEditor() -> NSTextView {
        if let editorView { return editorView }
        let scroll = NSScrollView(frame: previewPane.bounds)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let initial = scroll.contentSize.width > 0
            ? scroll.contentSize
            : previewPane.bounds.size
        let tv = NotesEditorTextView(frame: NSRect(
            x: 0, y: 0,
            width: max(initial.width, 1),
            height: max(initial.height, 1)))
        tv.delegate = self
        tv.onCancel = { [weak self] in self?.requestClose() }
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.minSize = NSSize(width: 0, height: max(initial.height, 1))
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true

        scroll.documentView = tv
        previewPane.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: previewPane.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor),
        ])
        editorScroll = scroll
        editorView = tv
        layoutNotesEditorGeometry()
        return tv
    }

    func textDidChange(_ notification: Notification) {
        guard paneMode == .edit,
              notification.object as AnyObject === editorView else { return }
        if editContentReady {
            let current = editorView?.string ?? ""
            if !editHasEdits {
                if current != loadedEditText {
                    editHasEdits = true
                    reloadDirtyIndicatorInList()
                }
            } else {
                // Already dirty — skip full compare unless length matches (undo→clean).
                if current.utf8.count == loadedEditText.utf8.count,
                   current == loadedEditText {
                    editHasEdits = false
                    reloadDirtyIndicatorInList()
                }
            }
        }
        refreshStatusLine()
    }

    /// Clears the ⌘N-in-flight flag. When `refreshIfNeeded`, consumes a deferred
    /// Settings change (Cancel / abandoned create) so the listing does not stay stale.
    private func finishNewNotePresentation(token: Int, refreshIfNeeded: Bool = true) {
        guard token == newNotePresentationToken else { return }
        isPresentingNewNote = false
        guard refreshIfNeeded,
              isVisible,
              paneMode != .edit,
              listNeedsRefreshAgainstSettings() else { return }
        settingsChangedDuringEdit = false
        runSearch(currentQuery)
    }

    /// If Settings moved under a create I/O, re-list with live vault/excludes.
    private func refreshListingAfterDeferredSettingsChange() {
        guard isVisible, paneMode != .edit, listNeedsRefreshAgainstSettings() else { return }
        settingsChangedDuringEdit = false
        runSearch(currentQuery)
    }

    private func presentNewNoteDialog(
        prefillTitle: String = "",
        prefillDir: String = "",
        conflictMessage: String? = nil
    ) {
        if isPresentingNewNote { return }
        if isDirty {
            guard resolveDirtyIfNeeded() else { return }
            leaveEditMode(showPreviewAfter: true)
        } else if paneMode == .edit {
            leaveEditMode(showPreviewAfter: true)
        }

        isPresentingNewNote = true
        newNotePresentationToken += 1
        let token = newNotePresentationToken
        // Directory walk off the main thread (cached after the first pass).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dirs = MarkdownVault.listSubdirectories()
            DispatchQueue.main.async {
                guard let self else { return }
                guard token == self.newNotePresentationToken, self.isVisible else {
                    self.finishNewNotePresentation(token: token)
                    return
                }
                self.showNewNoteAlert(
                    dirs: dirs,
                    prefillTitle: prefillTitle,
                    prefillDir: prefillDir,
                    conflictMessage: conflictMessage,
                    token: token)
            }
        }
    }

    private func showNewNoteAlert(
        dirs: [String],
        prefillTitle: String,
        prefillDir: String,
        conflictMessage: String?,
        token: Int
    ) {
        guard token == newNotePresentationToken, isVisible else {
            finishNewNotePresentation(token: token)
            return
        }
        // Dir walk was async — user may have re-entered edit; clear again.
        if paneMode == .edit {
            guard resolveDirtyIfNeeded() else {
                finishNewNotePresentation(token: token)
                return
            }
            leaveEditMode(showPreviewAfter: true)
        }

        let alert = NSAlert()
        alert.messageText = "新建笔记"
        alert.informativeText = conflictMessage
            ?? "创建 Markdown 文件（.md）。子目录可手填相对路径，不存在时会自动创建。"
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        // Esc → 取消 (second button).
        alert.buttons[1].keyEquivalent = "\u{1b}"

        // Soft search-bar rows (same idea as the notes panel header field).
        let width: CGFloat = 300
        let fieldH: CGFloat = 32
        let fieldGap: CGFloat = 8
        let accessoryH = fieldH + fieldGap + fieldH

        let titleRow = NotesAlertFieldRow(
            frame: NSRect(x: 0, y: fieldH + fieldGap, width: width, height: fieldH),
            showsDirMenu: false)
        titleRow.textField.placeholderString = "标题"
        titleRow.textField.stringValue = prefillTitle
        let titleDelegate = NotesAlertRowFieldDelegate()
        titleDelegate.row = titleRow
        titleRow.textField.delegate = titleDelegate

        let dirRow = NotesAlertFieldRow(
            frame: NSRect(x: 0, y: 0, width: width, height: fieldH),
            showsDirMenu: true)
        dirRow.textField.placeholderString = "子目录（可手填相对路径）"
        let initialDir = prefillDir.isEmpty ? MarkdownVault.rootPlaceholder : prefillDir
        dirRow.textField.stringValue = initialDir
        dirRow.configureDirMenu(dirs: dirs, rootTitle: MarkdownVault.rootPlaceholder)
        let dirDelegate = NotesAlertRowFieldDelegate()
        dirDelegate.row = dirRow
        dirRow.textField.delegate = dirDelegate

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: accessoryH))
        accessory.addSubview(titleRow)
        accessory.addSubview(dirRow)
        // Keep delegates alive for the modal lifetime.
        objc_setAssociatedObject(
            accessory, &NotesAlertAccessoryAssoc.titleDelegate,
            titleDelegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(
            accessory, &NotesAlertAccessoryAssoc.dirDelegate,
            dirDelegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = titleRow.textField

        let response = alert.runModal()
        guard token == newNotePresentationToken else { return }
        guard response == .alertFirstButtonReturn else {
            finishNewNotePresentation(token: token)
            return
        }

        let title = titleRow.textField.stringValue
        let dirRaw = dirRow.textField.stringValue
        // Pin vault + excludes for create→open so mid-flight Settings changes
        // cannot attach the new file to a mismatched library snapshot.
        let createVault = Settings.notesVaultPath
        let createExcludes = Settings.notesExcludeDirs
        // Disk I/O off the main thread; keep isPresentingNewNote until done.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = MarkdownVault.createMarkdownNote(
                title: title,
                relativeDir: dirRaw,
                vaultPath: createVault,
                excludes: createExcludes)
            DispatchQueue.main.async {
                guard let self else {
                    if case .success(let hit) = result {
                        MarkdownVault.removeEmptyCreatedNoteIfAbandoned(
                            hit.url, vaultPath: createVault)
                    }
                    return
                }
                switch result {
                case .success(let hit):
                    guard token == self.newNotePresentationToken, self.isVisible else {
                        MarkdownVault.removeEmptyCreatedNoteIfAbandoned(
                            hit.url, vaultPath: createVault)
                        self.finishNewNotePresentation(token: token)
                        return
                    }
                    // Success opens the editor next — skip cancel-path refresh here.
                    self.finishNewNotePresentation(token: token, refreshIfNeeded: false)
                    self.beginEditingCreatedNote(
                        hit, vaultPath: createVault, excludes: createExcludes)
                case .failure(.conflict(_)):
                    guard token == self.newNotePresentationToken, self.isVisible else {
                        self.finishNewNotePresentation(token: token)
                        return
                    }
                    self.showNewNoteAlert(
                        dirs: dirs,
                        prefillTitle: title,
                        prefillDir: dirRaw == MarkdownVault.rootPlaceholder ? "" : dirRaw,
                        conflictMessage: "已存在同名笔记，请更换标题后再创建。",
                        token: token)
                case .failure(.message(let msg)):
                    guard token == self.newNotePresentationToken, self.isVisible else {
                        self.finishNewNotePresentation(token: token)
                        return
                    }
                    let err = NSAlert()
                    err.messageText = "无法创建笔记"
                    err.informativeText = msg
                    err.runModal()
                    guard token == self.newNotePresentationToken, self.isVisible else {
                        self.finishNewNotePresentation(token: token)
                        return
                    }
                    self.showNewNoteAlert(
                        dirs: dirs,
                        prefillTitle: title,
                        prefillDir: dirRaw == MarkdownVault.rootPlaceholder ? "" : dirRaw,
                        conflictMessage: nil,
                        token: token)
                }
            }
        }
    }

    /// After exclusive create: refresh the empty query list and open the editor.
    private func beginEditingCreatedNote(
        _ hit: NoteHit,
        vaultPath: String,
        excludes: [String]
    ) {
        // Clear query only after results land — avoids empty-query + stale list
        // if the user Cancels a late dirty prompt.
        searchGeneration += 1
        let gen = searchGeneration
        newNoteCompletionToken += 1
        let createToken = newNoteCompletionToken
        // Prefer live Settings when they moved during create I/O (excludes-only).
        let listVault = Settings.notesVaultPath
        let listExcludes = Settings.notesExcludeDirs
        let searchVault: String
        let searchExcludes: [String]
        if listVault == vaultPath {
            searchVault = listVault
            searchExcludes = listExcludes
        } else {
            searchVault = vaultPath
            searchExcludes = excludes
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = MarkdownVault.search(
                query: "", vaultPath: searchVault, excludes: searchExcludes,
                isCancelled: { [weak self] in
                    guard let self else { return true }
                    return gen != self.searchGeneration
                        || createToken != self.newNoteCompletionToken
                })
            DispatchQueue.main.async {
                guard let self else {
                    MarkdownVault.removeEmptyCreatedNoteIfAbandoned(
                        hit.url, vaultPath: vaultPath)
                    return
                }
                guard gen == self.searchGeneration,
                      createToken == self.newNoteCompletionToken,
                      self.isVisible else {
                    // Hidden before open → drop the empty file. Token/gen mismatch
                    // while still visible means another session took over; keep it.
                    if !self.isVisible {
                        MarkdownVault.removeEmptyCreatedNoteIfAbandoned(
                            hit.url, vaultPath: vaultPath)
                    }
                    return
                }
                // Library root moved during create I/O — drop the empty orphan in
                // the old vault, then refresh the new listing (no ensureHit).
                if Settings.notesVaultPath != vaultPath {
                    MarkdownVault.removeEmptyCreatedNoteIfAbandoned(
                        hit.url, vaultPath: vaultPath)
                    self.settingsChangedDuringEdit = false
                    self.runSearch(self.currentQuery)
                    return
                }
                // Cancel = stay on current edit; keep the newly created file on disk.
                guard self.resolveDirtyIfNeeded() else {
                    self.refreshListingAfterDeferredSettingsChange()
                    return
                }
                if self.paneMode == .edit {
                    self.leaveEditMode(showPreviewAfter: false)
                }
                if self.searchField.currentEditor() != nil {
                    self.endEditing(for: self.searchField)
                }
                self.searchField.stringValue = ""
                self.currentQuery = ""
                self.updateSearchPlaceholder()
                // Live excludes if Settings moved; vault is still the create root.
                let applyExcludes = Settings.notesExcludeDirs
                let applyResults: [NoteHit]
                if applyExcludes == searchExcludes {
                    applyResults = results
                } else {
                    // Excludes changed again while search was in flight — one sync
                    // pass is enough for the empty-query listing (no body reads).
                    applyResults = MarkdownVault.search(
                        query: "", vaultPath: vaultPath, excludes: applyExcludes)
                }
                self.applySearchResults(
                    applyResults,
                    vaultPath: vaultPath,
                    excludes: applyExcludes,
                    selectURL: hit.url,
                    ensureHit: hit)
                self.enterEditMode(for: hit)
            }
        }
    }

    private func clearPreview() {
        pendingJump = nil
        loadToken += 1
        previewedPath = nil
        previewedQuery = nil
        matchHint = ""
        guard let web = previewWeb else { return }
        web.stopLoading()
        web.loadHTMLString("<html><body style='background:transparent'></body></html>", baseURL: nil)
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

        let web = ensurePreviewWeb()
        loadToken += 1
        let token = loadToken
        pendingJump = (token, nil)

        // Read + render off the main thread so large notes don't hitch ↑↓.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let body = hit.loadBody()
            let isSheet = hit.url.pathExtension.lowercased() == "sheet"
            let rawHaystack = isSheet ? SheetHTML.searchableText(from: body) : body
            let haystack = isSheet ? rawHaystack : MarkdownHTML.searchHaystack(from: rawHaystack)
            let matchText = MarkdownVault.firstMatch(in: haystack, matching: q)
            let count = MarkdownHTML.matchCount(in: haystack, query: q)
            let bodyHTML = isSheet ? SheetHTML.render(body) : MarkdownHTML.render(body)
            let page = DocumentPreviewPage.wrap(
                bodyHTML: bodyHTML, title: hit.title,
                includeSearchJump: true, chrome: .panel)
            let base = hit.url.deletingLastPathComponent()
            DispatchQueue.main.async {
                guard let self = self, token == self.loadToken else { return }
                guard self.previewWeb === web else { return }
                if q.isEmpty {
                    self.matchHint = ""
                } else {
                    self.matchHint = count > 0 ? "本篇 \(count) 处" : "仅文件名"
                }
                self.refreshStatusLine()
                self.pendingJump = (token, matchText)
                web.loadHTMLString(page, baseURL: base)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let pending = pendingJump, pending.token == loadToken else { return }
        let payload = Self.jsStringLiteral(pending.text ?? "")
        webView.evaluateJavaScript("window.pqJumpTo && window.pqJumpTo(\(payload))") { _, _ in }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .other || navigationAction.navigationType == .reload {
            decisionHandler(.allow)
            return
        }
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
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
                title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                title.translatesAutoresizingMaskIntoConstraints = false
                let dirty = NotesDirtyDotView()
                dirty.identifier = NSUserInterfaceItemIdentifier("NotesDirtyDot")
                dirty.isHidden = true
                dirty.setContentHuggingPriority(.required, for: .horizontal)
                dirty.setContentCompressionResistancePriority(.required, for: .horizontal)
                dirty.translatesAutoresizingMaskIntoConstraints = false
                let titleRow = NSStackView(views: [title, dirty])
                titleRow.identifier = NSUserInterfaceItemIdentifier("NotesTitleRow")
                titleRow.orientation = .horizontal
                titleRow.alignment = .centerY
                titleRow.spacing = 6
                titleRow.translatesAutoresizingMaskIntoConstraints = false
                let sub = NSTextField(labelWithString: "")
                sub.identifier = NSUserInterfaceItemIdentifier("NotesSubdir")
                sub.font = .systemFont(ofSize: 11)
                sub.textColor = .secondaryLabelColor
                sub.lineBreakMode = .byTruncatingMiddle
                sub.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(titleRow)
                c.addSubview(sub)
                c.textField = title
                NSLayoutConstraint.activate([
                    dirty.widthAnchor.constraint(equalToConstant: 6),
                    dirty.heightAnchor.constraint(equalToConstant: 6),
                    titleRow.topAnchor.constraint(equalTo: c.topAnchor, constant: 8),
                    titleRow.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
                    titleRow.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
                    sub.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 3),
                    sub.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
                    sub.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
                    sub.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -8),
                ])
                return c
            }()
        let hit = hits[row]
        let ext = hit.url.pathExtension.lowercased()
        // Same basename may exist as both .md and .sheet — show extension for sheets.
        cell.textField?.stringValue = ext == "sheet" ? "\(hit.title).sheet" : hit.title
        let dir = (hit.relativePath as NSString).deletingLastPathComponent
        let subLabel = cell.subviews
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "NotesSubdir" }
            ?? (cell.subviews.last as? NSTextField)
        subLabel?.stringValue = dir.isEmpty ? "（库根目录）" : dir
        let showDirty = isDirty
            && editingURL.map({ Self.sameNoteURL($0, hit.url) }) == true
        let dirtyDot = (cell.subviews
            .compactMap { $0 as? NSStackView }
            .first { $0.identifier?.rawValue == "NotesTitleRow" })?
            .arrangedSubviews
            .compactMap { $0 as? NotesDirtyDotView }
            .first
        dirtyDot?.isHidden = !showDirty
        cell.toolTip = hit.relativePath
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard paneMode == .edit else { return true }
        if row >= 0, row < hits.count,
           let editingURL,
           Self.sameNoteURL(hits[row].url, editingURL) {
            return true
        }
        // Never runModal inside AppKit's selection machinery — defer the dirty
        // prompt and intentional select to the next main-queue turn.
        if isDirty {
            let alreadyQueued = pendingDirtySelectRow != nil
            pendingDirtySelectRow = row
            if !alreadyQueued {
                DispatchQueue.main.async { [weak self] in
                    self?.flushPendingDirtySelect()
                }
            }
            return false
        }
        return true
    }

    /// Deferred from `shouldSelectRow` so Save / Don't Save / Cancel is not nested
    /// in the table's selection run loop.
    private func flushPendingDirtySelect() {
        let row = pendingDirtySelectRow
        pendingDirtySelectRow = nil
        guard let row, isVisible, paneMode == .edit else { return }
        guard row >= 0, row < hits.count else { return }
        if let editingURL, Self.sameNoteURL(hits[row].url, editingURL) { return }
        guard resolveDirtyIfNeeded() else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < hits.count else { return }
        let hit = hits[row]
        if paneMode == .edit {
            if MarkdownVault.isEditableMarkdown(hit.url) {
                let same = editingURL.map { Self.sameNoteURL(hit.url, $0) } ?? false
                if !same {
                    enterEditMode(for: hit)
                }
            } else {
                leaveEditMode(showPreviewAfter: true)
            }
        } else {
            showPreview(for: row)
            refreshStatusLine()
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let panel = EditorPanel()
    /// Built on first notes-search open so launch stays free of WebKit.
    private var notesPanel: NotesSearchPanel?
    private lazy var clipboardPanel: ClipboardPanel = {
        let p = ClipboardPanel()
        p.onInsertIntoEditor = { [weak self] text in
            guard let self else { return }
            self.panel.showAndFocus()
            self.panel.insertAtCursor(text + "\n")
        }
        p.onOpenSettings = { [weak self] in
            self?.settingsController.show()
        }
        return p
    }()
    /// Carbon hotkey for ⌘⇧C (survives other apps being frontmost).
    private var clipboardHotKey: GlobalHotKey?
    private var summonMonitor: DoubleTapMonitor?
    private var searchMonitor: DoubleTapMonitor?
    private var openMonitor: DoubleTapMonitor?
    private var phrasesKeyMonitors: [Any] = []
    private var screenshotWatcher: ScreenshotWatcher!
    private lazy var settingsController = SettingsWindowController { [weak self] in
        self?.restartMonitors()
        ClipboardMonitor.shared.restart()
        // Path may have changed via the screenshot-location picker.
        self?.screenshotWatcher.start()
        // Vault / excludes may have changed — refresh notes panel when idle.
        self?.notesPanel?.handleSettingsChanged()
    }

    private func notesSearchPanel() -> NotesSearchPanel {
        if let notesPanel { return notesPanel }
        let panel = NotesSearchPanel()
        notesPanel = panel
        return panel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        setupPhrasesShortcuts()
        setupClipboardHotkey()
        restartMonitors()
        ClipboardMonitor.shared.start()

        screenshotWatcher = ScreenshotWatcher { [weak self] url in
            guard let self = self else { return }
            // Don't activate — stealing focus mid-rename makes Finder re-show
            // its "replace existing file?" dialog a second time.
            if !self.panel.isVisible { self.panel.showWithoutActivating() }
            self.panel.insertAtCursor(PathFormat.forInsertion(url.path) + "\n")
        }
        screenshotWatcher.start()
        SleepPrevention.restoreIfNeeded()

        ensureAccessibilityPermission()
        ensureSpeechPermission()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Notes panel may hold unsaved edits that Esc/orderOut would prompt for.
        if let panel = notesPanel, !panel.confirmDiscardOrSaveIfNeeded() {
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Drop assertions on quit; preference stays so the next launch restores.
        SleepPrevention.release()
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

    /// Global ⌘⇧C via Carbon (same class of API Maccy/KeyboardShortcuts use).
    /// If registration fails, another app (e.g. Maccy) likely owns the chord.
    private func setupClipboardHotkey() {
        clipboardHotKey = .commandShiftC { [weak self] in
            self?.clipboardPanel.toggle()
        }
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
        statusItem.isVisible = true
        if let button = statusItem.button {
            // Template silhouette; must include @2x/@3x reps — loading only the
            // 1x PNG via file URL upscales on Retina and looks blurry/jagged.
            if let icon = Self.loadMenuBarIcon() {
                button.image = icon
                button.imagePosition = .imageOnly
            } else {
                button.title = "Qy"
            }
            button.toolTip = "PromptQy"
            button.appearsDisabled = false
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Build a multi-representation template image (18pt) so Retina uses @2x/@3x.
    private static func loadMenuBarIcon() -> NSImage? {
        let point = NSSize(width: 18, height: 18)
        // NSImage(named:) pairs MenuBarIcon.png + @2x/@3x when both are in Resources.
        if let named = NSImage(named: "MenuBarIcon"), named.isValid {
            named.size = point
            named.isTemplate = true
            return named
        }
        let image = NSImage(size: point)
        let files: [(String, CGFloat)] = [
            ("MenuBarIcon", 1),
            ("MenuBarIcon@2x", 2),
            ("MenuBarIcon@3x", 3),
        ]
        for (name, scale) in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = NSSize(
                width: CGFloat(rep.pixelsWide) / scale,
                height: CGFloat(rep.pixelsHigh) / scale)
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else {
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let img = NSImage(contentsOf: url) {
                img.size = point
                img.isTemplate = true
                return img
            }
            return NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "PromptQy")
        }
        image.isTemplate = true
        image.size = point
        return image
    }

    /// Rebuild the menu each time it opens so the history section stays fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = menu.addItem(withTitle: "打开编辑器", action: #selector(showEditor), keyEquivalent: "")
        open.target = self
        let notes = menu.addItem(withTitle: "搜索Obsidian笔记", action: #selector(showNotesSearch), keyEquivalent: "")
        notes.target = self
        let clips = menu.addItem(
            withTitle: "剪贴板历史",
            action: #selector(showClipboardHistory), keyEquivalent: "c")
        clips.keyEquivalentModifierMask = [.command, .shift]
        clips.target = self
        let shot = menu.addItem(
            withTitle: "截图后立即保存",
            action: #selector(toggleScreenshotThumbnail), keyEquivalent: "")
        shot.target = self
        shot.state = ScreenshotThumbnail.isDisabled ? .on : .off
        let awake = menu.addItem(
            withTitle: "阻止系统自动休眠",
            action: #selector(togglePreventAutoSleep), keyEquivalent: "")
        awake.target = self
        awake.state = Settings.preventAutoSleep ? .on : .off
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
        let settings = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc private func showEditor() { panel.showAndFocus() }

    @objc private func showNotesSearch() { notesSearchPanel().showAndFocus() }

    @objc private func showClipboardHistory() { clipboardPanel.showAndFocus() }

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

    @objc private func togglePreventAutoSleep() {
        SleepPrevention.setEnabled(!Settings.preventAutoSleep)
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
        notesSearchPanel().showAndFocus()
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
            "双击 Control 呼出、读取选中文本、⌘⇧C 剪贴板历史都依赖权限。\n"
            + "请在「辅助功能」列表中勾选「PromptQy」。若已勾选仍无效，"
            + "请先移除旧条目再重新添加本 App；并确认没有其它 App（如 Maccy）占用 ⌘⇧C。"
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

// Explicit entry — `@main` on AppDelegate + NSApplicationMain does not always
// wire the delegate when Info.plist has no nib/storyboard, leaving an idle
// process with no menu-bar item.
@main
enum PromptQyMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
