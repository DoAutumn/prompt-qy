import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettingsTab(model: model)
                    .tabItem { Label("通用", systemImage: "gearshape") }

                ClipboardSettingsTab(model: model)
                    .tabItem { Label("剪贴板", systemImage: "doc.on.clipboard") }

                NotesSettingsTab(model: model)
                    .tabItem { Label("笔记", systemImage: "book") }
            }
            .frame(minWidth: 540, minHeight: 520)
            .padding(.top, 8)

            Text("版本 \(model.appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
        }
    }
}

// MARK: - 通用

private struct GeneralSettingsTab: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        Form {
            Section("截图") {
                HStack {
                    Text(model.screenshotDisplayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.screenshotFullPath)
                    Spacer(minLength: 8)
                    Button("选择…") { model.chooseScreenshotPath() }
                }
                Text("截图路径写入系统设置，改动即时生效。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("常用短语") {
                TextEditor(text: $model.phrasesText)
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .frame(minHeight: 72, maxHeight: 120)
                Text("每行一条。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("快捷键") {
                ShortcutRow(name: "打开编辑器", key: "双击\(Settings.summonModifier.symbol)")
                ShortcutRow(name: "打开文件", key: "双击\(Settings.openModifier.symbol)")
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .onChange(of: model.phrasesText) { _ in model.commitPhrases() }
    }
}

// MARK: - 剪贴板

private struct ClipboardSettingsTab: View {
    @ObservedObject var model: SettingsFormModel

    private static let textLimitOptions = [20, 50, 100, 200, 500]
    private static let imageLimitOptions = [10, 20, 50, 100]

    var body: some View {
        Form {
            Section("历史") {
                Picker("文字历史", selection: $model.clipboardTextLimit) {
                    ForEach(Self.textLimitOptions, id: \.self) { n in
                        Text("\(n) 条").tag(n)
                    }
                }
                Picker("图片历史", selection: $model.clipboardImageLimit) {
                    ForEach(Self.imageLimitOptions, id: \.self) { n in
                        Text("\(n) 条").tag(n)
                    }
                }
                Text("图片原图落盘，列表仅缩略图。固定项不计入条数上限；「清空」不会去掉固定项（需 ⌘⌫ 或清空全部）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("快捷键") {
                ShortcutRow(name: "呼出面板", key: "⌘⇧C")
                ShortcutRow(name: "复制选中", key: "↩")
                ShortcutRow(name: "插入编辑器", key: "⌥↩")
                ShortcutRow(name: "删除选中", key: "⌫")
                ShortcutRow(name: "删除固定项", key: "⌘⌫")
                ShortcutRow(name: "固定 / 取消", key: "⌥P")
                ShortcutRow(name: "清空未固定", key: "⌥⌫")
                ShortcutRow(name: "清空全部", key: "⌥⇧⌫")
                ShortcutRow(name: "打开设置", key: "⌘,")
                ShortcutRow(name: "关闭面板", key: "Esc")
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .onChange(of: model.clipboardTextLimit) { _ in model.commitClipboardLimits() }
        .onChange(of: model.clipboardImageLimit) { _ in model.commitClipboardLimits() }
    }
}

// MARK: - 笔记

private struct NotesSettingsTab: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        Form {
            Section("笔记库") {
                HStack {
                    Text(model.vaultDisplayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.vaultFullPath)
                    Spacer(minLength: 8)
                    Button("选择…") { model.chooseVaultPath() }
                }
            }

            Section("排除目录") {
                TextEditor(text: $model.excludesText)
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .frame(minHeight: 72, maxHeight: 120)
                Text("排除目录每行一个，默认 .obsidian、.trash。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("快捷键") {
                ShortcutRow(name: "打开笔记", key: "双击\(Settings.searchModifier.symbol)")
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .onChange(of: model.excludesText) { _ in model.commitExcludes() }
    }
}

// MARK: - Shared

private struct ShortcutRow: View {
    let name: String
    let key: String

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(key)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Model

final class SettingsFormModel: ObservableObject {
    let onChange: () -> Void

    @Published var clipboardTextLimit: Int
    @Published var clipboardImageLimit: Int
    @Published var phrasesText: String
    @Published var excludesText: String
    @Published var screenshotDisplayPath: String
    @Published var screenshotFullPath: String
    @Published var vaultDisplayPath: String
    @Published var vaultFullPath: String

    private var suppressCommit = false

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        clipboardTextLimit = Settings.clipboardTextLimit
        clipboardImageLimit = Settings.clipboardImageLimit
        phrasesText = Settings.quickPhrases.joined(separator: "\n")
        excludesText = Settings.notesExcludeDirs.joined(separator: "\n")
        screenshotDisplayPath = ScreenshotLocation.displayPath
        screenshotFullPath = ScreenshotLocation.url.path
        vaultFullPath = Settings.notesVaultPath
        vaultDisplayPath = Self.displayPath(Settings.notesVaultPath)
    }

    func reload() {
        suppressCommit = true
        clipboardTextLimit = Settings.clipboardTextLimit
        clipboardImageLimit = Settings.clipboardImageLimit
        phrasesText = Settings.quickPhrases.joined(separator: "\n")
        excludesText = Settings.notesExcludeDirs.joined(separator: "\n")
        screenshotDisplayPath = ScreenshotLocation.displayPath
        screenshotFullPath = ScreenshotLocation.url.path
        vaultFullPath = Settings.notesVaultPath
        vaultDisplayPath = Self.displayPath(Settings.notesVaultPath)
        suppressCommit = false
    }

    func commitClipboardLimits() {
        guard !suppressCommit else { return }
        Settings.clipboardTextLimit = clipboardTextLimit
        Settings.clipboardImageLimit = clipboardImageLimit
        ClipboardStore.applyLimits()
        onChange()
    }

    func commitPhrases() {
        guard !suppressCommit else { return }
        let lines = phrasesText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Settings.quickPhrases = lines
    }

    func commitExcludes() {
        guard !suppressCommit else { return }
        let lines = excludesText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Settings.notesExcludeDirs = lines
    }

    func chooseScreenshotPath() {
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
        screenshotDisplayPath = ScreenshotLocation.displayPath
        screenshotFullPath = ScreenshotLocation.url.path
        onChange()
    }

    func chooseVaultPath() {
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
        vaultFullPath = url.path
        vaultDisplayPath = Self.displayPath(url.path)
        onChange()
    }

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
