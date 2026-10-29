import AppKit

/// Maccy-like floating clipboard popup.
final class ClipboardPanel: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// Item / search chip radius (Maccy Popup.cornerRadius).
    fileprivate static let itemCorner: CGFloat = 4
    /// Content inset from panel edge (Maccy Popup.horizontalPadding).
    fileprivate static let contentInset: CGFloat = 5
    /// Outer panel radius = item corner + inset so curvature matches inset rows.
    fileprivate static let cornerRadius: CGFloat = itemCorner + contentInset
    fileprivate static let itemHeight: CGFloat = 22
    /// Text padding inside a row (Maccy ListItemView uses ~10 without app icons).
    fileprivate static let textInset: CGFloat = 10
    private static let vPad: CGFloat = 5
    private static let sepPad: CGFloat = 6
    /// Match Maccy Defaults.windowSize (450×800).
    private static let defaultWidth: CGFloat = 450
    private static let defaultHeight: CGFloat = 800

    private enum Row {
        case item(ClipboardStore.Item)
        case separator
    }

    /// Clear clip root — never put cornerRadius on NSVisualEffectView itself
    /// (that leaks the white square corners).
    private let rootView = NSView()
    private let effectView = NSVisualEffectView()
    private let appTitleLabel = NSTextField(labelWithString: "PromptQy")
    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    private let clearSearchButton = NSButton()
    private let searchChrome = NSView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let footerClear = FooterRowView()
    private let footerPrefs = FooterRowView()
    private let tipController = SelectionTooltipController()
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var scrollObserver: NSObjectProtocol?
    private var rows: [Row] = []
    private var filterWork: DispatchWorkItem?
    /// Index into `rows`; `-1` means nothing selected (open state).
    private var selectedRow = -1
    private var optionHeld = false
    /// Hover must not steal the open-time default selection until the pointer moves.
    private var hoverArmed = false
    private var openMouseLocation: NSPoint?

    var onInsertIntoEditor: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultHeight),
            styleMask: [.nonactivatingPanel, .resizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        if #available(macOS 11.0, *) {
            titlebarSeparatorStyle = .none
        }
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        minSize = NSSize(width: 320, height: 280)
        // Position-only persistence; size is forced on each open.
        setFrameAutosaveName("PromptQyClipboardHistoryFrame.v6")

        buildContent()
        applyRoundedCorners()
        observeScrollForHover()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isKeyWindow else { return event }
            return self.handleLocalEvent(event)
        }
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        stopMouseMonitor()
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { closePanel() }
    override func close() { closePanel() }

    override func mouseExited(with event: NSEvent) {
        clearHoverSelection()
    }

    override func resignKey() {
        super.resignKey()
        if isVisible { closePanel() }
    }

    private func closePanel() {
        tipController.hide()
        stopMouseMonitor()
        hoverArmed = false
        openMouseLocation = nil
        if searchField.currentEditor() != nil { endEditing(for: searchField) }
        makeFirstResponder(nil)
        ClipboardStore.clearThumbnailCache()
        orderOut(nil)
    }

    func toggle() {
        if isVisible { closePanel() } else { showAndFocus() }
    }

    func showAndFocus() {
        searchField.stringValue = ""
        clearSearchButton.isHidden = true
        reload(query: "", selectFirstUnpinned: true)
        // Always enforce Maccy-sized frame — autosave only keeps origin.
        var f = frame
        f.size.width = Self.defaultWidth
        f.size.height = Self.defaultHeight
        setFrame(f, display: false)
        if !isVisible {
            positionNearMouse()
        }
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(searchField)
        applyRoundedCorners()
        // Snapshot after layout so idle cursor over the list does not re-select.
        hoverArmed = false
        openMouseLocation = NSEvent.mouseLocation
        startMouseMonitor()
    }

    /// Track pointer while open so empty list space / panel exit clears highlight
    /// (cell tracking alone misses “keyboard-selected → move into blank”).
    private func startMouseMonitor() {
        stopMouseMonitor()
        acceptsMouseMovedEvents = true
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            // Same-row moves must not restart the tip delay.
            self?.syncHoverFromMouseLocation(refreshTipIfSameRow: false)
            return event
        }
    }

    /// Arm hover only after a real pointer move from the open-time location.
    @discardableResult
    private func armHoverIfMouseMoved() -> Bool {
        if hoverArmed { return true }
        let now = NSEvent.mouseLocation
        if let origin = openMouseLocation {
            let dx = abs(now.x - origin.x)
            let dy = abs(now.y - origin.y)
            if dx < 3, dy < 3 { return false }
        }
        hoverArmed = true
        openMouseLocation = nil
        return true
    }

    private func stopMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        acceptsMouseMovedEvents = false
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let size = frame.size
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main else {
            center()
            return
        }
        let visible = screen.visibleFrame
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(origin)
    }

    /// Maccy FloatingPanel: round `contentView` + theme-frame superview only.
    /// Never round/mask `NSVisualEffectView` — that leaves white square corners.
    private func applyRoundedCorners() {
        let radius = Self.cornerRadius
        for view in [contentView, contentView?.superview].compactMap({ $0 }) {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.cornerRadius = radius
            view.layer?.masksToBounds = true
            if #available(macOS 10.15, *) {
                view.layer?.cornerCurve = .continuous
            }
        }
        invalidateShadow()
    }

    private func buildContent() {
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: rootView.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
        ])
        contentView = rootView

        // Maccy ListHeaderView: app name left of search, secondary color.
        appTitleLabel.font = .systemFont(ofSize: 13)
        appTitleLabel.textColor = .secondaryLabelColor
        appTitleLabel.setContentHuggingPriority(.required, for: .horizontal)
        appTitleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        appTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        searchChrome.wantsLayer = true
        searchChrome.layer?.cornerRadius = Self.itemCorner
        // Maccy SearchFieldView: Color.secondary @ 0.1 — gray wash, not white.
        searchChrome.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor
        searchChrome.translatesAutoresizingMaskIntoConstraints = false

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        searchIcon.imageScaling = .scaleProportionallyUpOrDown
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.font = .systemFont(ofSize: 13)
        searchField.placeholderAttributedString = NSAttributedString(
            string: "搜索",
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.4),
                .font: NSFont.systemFont(ofSize: 13),
            ]
        )
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        clearSearchButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "清除")
        clearSearchButton.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        clearSearchButton.isBordered = false
        clearSearchButton.imagePosition = .imageOnly
        clearSearchButton.target = self
        clearSearchButton.action = #selector(clearSearch)
        clearSearchButton.isHidden = true
        clearSearchButton.translatesAutoresizingMaskIntoConstraints = false

        searchChrome.addSubview(searchIcon)
        searchChrome.addSubview(searchField)
        searchChrome.addSubview(clearSearchButton)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = Self.itemHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activatePrimary)
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        footerClear.configure(title: "清空", shortcut: "⌥⌫")
        footerClear.onActivate = { [weak self] in self?.activateClearFooter() }
        footerClear.translatesAutoresizingMaskIntoConstraints = false

        footerPrefs.configure(title: "设置…", shortcut: "⌘,")
        footerPrefs.onActivate = { [weak self] in
            self?.closePanel()
            self?.onOpenSettings?()
        }
        footerPrefs.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(appTitleLabel)
        effectView.addSubview(searchChrome)
        effectView.addSubview(scrollView)
        effectView.addSubview(divider)
        effectView.addSubview(footerClear)
        effectView.addSubview(footerPrefs)

        // Whole-panel exit (search / footer / empty list) — cell tracking alone
        // does not fire when the pointer leaves from non-row chrome.
        rootView.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil))

        let inset = Self.contentInset
        // List title text sits at inset + textInset; align "PromptQy" to that.
        let titleLeading = inset + Self.textInset
        NSLayoutConstraint.activate([
            appTitleLabel.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: titleLeading),
            appTitleLabel.centerYAnchor.constraint(equalTo: searchChrome.centerYAnchor),

            searchChrome.topAnchor.constraint(equalTo: effectView.topAnchor, constant: Self.vPad + 4),
            searchChrome.leadingAnchor.constraint(equalTo: appTitleLabel.trailingAnchor, constant: 8),
            // Match list/footer text trailing (inset + textInset).
            searchChrome.trailingAnchor.constraint(
                equalTo: effectView.trailingAnchor, constant: -(inset + Self.textInset)),
            searchChrome.heightAnchor.constraint(equalToConstant: 23),

            searchIcon.leadingAnchor.constraint(equalTo: searchChrome.leadingAnchor, constant: 6),
            searchIcon.centerYAnchor.constraint(equalTo: searchChrome.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 11),
            searchIcon.heightAnchor.constraint(equalToConstant: 11),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 5),
            searchField.trailingAnchor.constraint(equalTo: clearSearchButton.leadingAnchor, constant: -2),
            searchField.centerYAnchor.constraint(equalTo: searchChrome.centerYAnchor),

            clearSearchButton.trailingAnchor.constraint(equalTo: searchChrome.trailingAnchor, constant: -5),
            clearSearchButton.centerYAnchor.constraint(equalTo: searchChrome.centerYAnchor),
            clearSearchButton.widthAnchor.constraint(equalToConstant: 14),
            clearSearchButton.heightAnchor.constraint(equalToConstant: 14),

            scrollView.topAnchor.constraint(equalTo: searchChrome.bottomAnchor, constant: Self.sepPad),
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: inset),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -inset),
            scrollView.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -Self.sepPad),

            divider.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: inset),
            divider.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -inset),
            divider.bottomAnchor.constraint(equalTo: footerClear.topAnchor, constant: -Self.sepPad),

            footerClear.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: inset),
            footerClear.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -inset),
            footerClear.heightAnchor.constraint(equalToConstant: Self.itemHeight),
            footerClear.bottomAnchor.constraint(equalTo: footerPrefs.topAnchor),

            footerPrefs.leadingAnchor.constraint(equalTo: footerClear.leadingAnchor),
            footerPrefs.trailingAnchor.constraint(equalTo: footerClear.trailingAnchor),
            footerPrefs.heightAnchor.constraint(equalToConstant: Self.itemHeight),
            footerPrefs.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -Self.vPad),
        ])
    }

    @objc private func clearSearch() {
        searchField.stringValue = ""
        clearSearchButton.isHidden = true
        reload(query: "")
        makeFirstResponder(searchField)
    }

    private func rebuildRows(from items: [ClipboardStore.Item]) {
        let pinned = items.filter(\.pinned)
        let unpinned = items.filter { !$0.pinned }
        var next: [Row] = pinned.map { .item($0) }
        if !pinned.isEmpty && !unpinned.isEmpty {
            next.append(.separator)
        }
        next.append(contentsOf: unpinned.map { .item($0) })
        rows = next
    }

    private func reload(query: String, selectFirstUnpinned: Bool = false) {
        let items = ClipboardStore.filtered(query: query)
        rebuildRows(from: items)
        tableView.reloadData()
        tableView.sizeLastColumnToFit()
        if selectFirstUnpinned, let row = firstUnpinnedItemRow() {
            selectedRow = row
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            selectedRow = -1
            tableView.deselectAll(nil)
        }
        updateFooterLabels()
        tipController.hide()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tableView.sizeLastColumnToFit()
            self.updateSelectionVisuals()
            if selectFirstUnpinned, self.selectedRow >= 0 {
                self.tableView.scrollRowToVisible(self.selectedRow)
                self.showTooltipForSelection()
            }
        }
    }

    private func firstItemRow() -> Int? {
        rows.firstIndex {
            if case .item = $0 { return true }
            return false
        }
    }

    /// First history item below the pinned section (skip pins + separator).
    private func firstUnpinnedItemRow() -> Int? {
        rows.firstIndex {
            if case .item(let item) = $0 { return !item.pinned }
            return false
        }
    }

    private func pinnedItemsInOrder() -> [ClipboardStore.Item] {
        rows.compactMap {
            if case .item(let item) = $0, item.pinned { return item }
            return nil
        }
    }

    private func updateFooterLabels() {
        if optionHeld {
            // Bulk wipe including pinned.
            footerClear.configure(title: "清空全部", shortcut: "⌥⇧⌫")
        } else if let item = selectedItem(), item.pinned {
            // Dedicated affordance: pinned are protected from plain ⌫ / 清空.
            footerClear.configure(title: "删除固定", shortcut: "⌘⌫")
        } else {
            footerClear.configure(title: "清空", shortcut: "⌥⌫")
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let q = searchField.stringValue
        clearSearchButton.isHidden = q.isEmpty
        filterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload(query: q) }
        filterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: - Keys

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            optionHeld = flags.contains(.option)
            updateFooterLabels()
            return event
        }

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.keyCode

        // ⌘1…⌘9 (main row + keypad) → paste that pinned item.
        if flags == .command, let pinIndex = Self.commandDigitIndex(keyCode: key, event: event) {
            activatePinned(at: pinIndex)
            return nil
        }

        if key == 36 || key == 76 { // Return
            if flags.contains(.option) {
                activateInsert()
            } else {
                activatePrimary()
            }
            return nil
        }
        if key == 51 || key == 117 { // Delete / Forward Delete
            // ⌥⌫ → clear unpinned; ⌥⇧⌫ → clear all (incl. pinned).
            // ⌘⌫ → delete selected (works on pinned).
            // Plain ⌫ → delete selected unpinned only (pinned need ⌘⌫ / footer).
            if flags.contains(.option) {
                clearHistory(includingPinned: flags.contains(.shift))
                return nil
            }
            if flags.contains(.command) {
                if selectedItem() != nil {
                    deleteSelected()
                    return nil
                }
            } else if let item = selectedItem() {
                if item.pinned {
                    NSSound.beep()
                    return nil
                }
                deleteSelected()
                return nil
            }
        }
        if key == 125 { moveSelection(1); return nil }
        if key == 126 { moveSelection(-1); return nil }
        if key == 35 && flags.contains(.option) {
            togglePin(); return nil
        }
        if key == 43 && flags == .command {
            closePanel()
            onOpenSettings?()
            return nil
        }

        // Typing while list is focused → feed the search field.
        if flags.isEmpty || flags == [.shift],
           searchField.currentEditor() == nil,
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let ch = chars.unicodeScalars.first,
           (CharacterSet.alphanumerics.contains(ch)
            || CharacterSet.punctuationCharacters.contains(ch)
            || CharacterSet.symbols.contains(ch)
            || ch == " ") {
            searchField.stringValue += chars
            clearSearchButton.isHidden = false
            makeFirstResponder(searchField)
            searchField.currentEditor()?.selectedRange = NSRange(
                location: (searchField.stringValue as NSString).length, length: 0)
            controlTextDidChange(Notification(name: NSText.didChangeNotification, object: searchField))
            return nil
        }
        return event
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        var next = selectedRow
        if next < 0 {
            // First arrow from empty selection.
            next = delta > 0 ? (firstItemRow() ?? -1) : lastItemRow() ?? -1
            if next < 0 { return }
        } else {
            while true {
                next += delta
                if next < 0 || next >= rows.count { return }
                if case .separator = rows[next] { continue }
                break
            }
        }
        selectedRow = next
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
        updateSelectionVisuals()
        showTooltipForSelection()
    }

    private func lastItemRow() -> Int? {
        rows.indices.reversed().first {
            if case .item = rows[$0] { return true }
            return false
        }
    }

    private func selectedItem() -> ClipboardStore.Item? {
        guard selectedRow >= 0, selectedRow < rows.count else { return nil }
        if case .item(let item) = rows[selectedRow] { return item }
        return nil
    }

    private func tipContent(for item: ClipboardStore.Item) -> SelectionTooltipController.Content? {
        switch item.kind {
        case .image:
            // Tip uses a large decode of the original — list thumbs are only ~128px.
            if let img = ClipboardStore.tooltipImage(for: item) {
                return .image(img)
            }
            let fallback = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? nil : .text(fallback)
        case .text:
            let text = (ClipboardStore.loadText(item) ?? item.preview)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Path-only clips (legacy / mis-captured Finder copies) → show file image.
            if ClipboardMonitor.isImageFilePath(text),
               let img = NSImage(contentsOf: URL(fileURLWithPath: (text as NSString).expandingTildeInPath)) {
                return .image(img)
            }
            return .text(text)
        }
    }

    private func showTooltipForSelection() {
        guard let item = selectedItem(), let content = tipContent(for: item) else {
            tipController.hide()
            return
        }
        let anchor = tableView.rowView(atRow: selectedRow, makeIfNecessary: true) ?? tableView
        tipController.show(content, relativeTo: anchor, parent: self, source: .keyboard)
    }

    private func showTooltipForHover(item: ClipboardStore.Item, anchor: NSView) {
        guard let content = tipContent(for: item) else {
            tipController.hide(source: .hover)
            return
        }
        tipController.show(content, relativeTo: anchor, parent: self, source: .hover)
    }

    @objc private func activatePrimary() {
        guard let item = selectedItem() else { return }
        let flags = NSEvent.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.contains(.option) {
            activateInsert()
            return
        }
        ClipboardPasteboard.copy(item)
        closePanel()
    }

    /// 0-based index for ⌘1…⌘9 from main digit keys or numeric keypad.
    private static func commandDigitIndex(keyCode: UInt16, event: NSEvent) -> Int? {
        // Main keyboard 1…9 (ANSI).
        let main: [UInt16: Int] = [
            18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8,
        ]
        // Keypad 1…9.
        let pad: [UInt16: Int] = [
            83: 0, 84: 1, 85: 2, 86: 3, 87: 4, 88: 5, 89: 6, 91: 7, 92: 8,
        ]
        if let i = main[keyCode] ?? pad[keyCode] { return i }
        // Layout-agnostic fallback (also covers some IME / remapped cases).
        guard let ch = event.charactersIgnoringModifiers?.first,
              let n = Int(String(ch)), (1...9).contains(n) else { return nil }
        return n - 1
    }

    private func activatePinned(at index: Int) {
        let pinned = pinnedItemsInOrder()
        guard index < pinned.count else {
            NSSound.beep()
            return
        }
        ClipboardPasteboard.copy(pinned[index])
        closePanel()
    }

    private func activateInsert() {
        guard let item = selectedItem() else { return }
        switch item.kind {
        case .text:
            guard let text = ClipboardStore.loadText(item) else { return }
            ClipboardStore.touch(item.id)
            onInsertIntoEditor?(text)
        case .image:
            ClipboardPasteboard.copy(item)
            onInsertIntoEditor?("[图片已复制到剪贴板]")
        }
        closePanel()
    }

    private func deleteSelected() {
        guard let item = selectedItem() else { return }
        let row = selectedRow
        tipController.hide()
        ClipboardStore.delete(item.id)
        reload(query: searchField.stringValue)
        // After delete, keep a nearby selection if possible.
        if !rows.isEmpty {
            var next = min(row, rows.count - 1)
            while next >= 0, next < rows.count, case .separator = rows[next] {
                next -= 1
            }
            if next < 0 { next = firstItemRow() ?? -1 }
            selectedRow = next
            if selectedRow >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
                updateSelectionVisuals()
                showTooltipForSelection()
            }
        }
        updateFooterLabels()
    }

    private func togglePin() {
        guard let item = selectedItem() else { return }
        ClipboardStore.setPinned(item.id, pinned: !item.pinned)
        reload(query: searchField.stringValue)
        updateFooterLabels()
    }

    /// Footer click: 删除固定 / 清空 / 清空全部 depending on modifiers + selection.
    private func activateClearFooter() {
        if optionHeld {
            clearHistory(includingPinned: true)
        } else if let item = selectedItem(), item.pinned {
            deleteSelected()
        } else {
            clearHistory(includingPinned: false)
        }
    }

    /// `includingPinned == false`: clear unpinned only.
    /// `includingPinned == true`: wipe everything (footer “清空全部”).
    private func clearHistory(includingPinned: Bool? = nil) {
        tipController.hide()
        let wipePinned = includingPinned ?? optionHeld
        if wipePinned {
            for item in ClipboardStore.allItems() {
                ClipboardStore.delete(item.id)
            }
        } else {
            ClipboardStore.clearUnpinned()
        }
        reload(query: searchField.stringValue)
        updateFooterLabels()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .separator = rows[row] { return 12 }
        return Self.itemHeight
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .separator = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .separator = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .separator = rows[row] {
            let id = NSUserInterfaceItemIdentifier("SepRow")
            return (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableRowView) ?? {
                let r = NSTableRowView()
                r.identifier = id
                return r
            }()
        }
        let id = NSUserInterfaceItemIdentifier("ClipRow")
        return (tableView.makeView(withIdentifier: id, owner: nil) as? ClipRowView) ?? {
            let r = ClipRowView()
            r.identifier = id
            return r
        }()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .separator:
            let id = NSUserInterfaceItemIdentifier("SepCell")
            if let existing = tableView.makeView(withIdentifier: id, owner: nil) {
                return existing
            }
            let wrap = NSView()
            wrap.identifier = id
            let box = NSBox()
            box.boxType = .separator
            box.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(box)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                box.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                box.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            ])
            return wrap
        case .item(let item):
            let id = NSUserInterfaceItemIdentifier("ClipCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ClipCellView) ?? ClipCellView()
            cell.identifier = id
            // Pinned rows are always contiguous at the top, so index == row.
            let pinShortcut: String? = item.pinned && row < 9 ? "⌘\(row + 1)" : nil
            cell.configure(item: item, selected: row == selectedRow, pinShortcut: pinShortcut)
            cell.onHover = { [weak self, weak cell] hovering in
                guard let self, let cell else { return }
                // Ignore enter/exit from the panel appearing under a still cursor.
                guard self.armHoverIfMouseMoved() else { return }
                if hovering {
                    self.selectRowFromHover(cell)
                } else {
                    // Re-hit-test: moving to another row selects it; leaving the
                    // list / empty area below the last item clears highlight.
                    // (Stale exits during scroll are corrected by the same path.)
                    self.syncHoverFromMouseLocation()
                }
            }
            return cell
        }
    }

    /// During scroll, tracking areas often miss mouseExited/Entered — re-hit-test.
    private func observeScrollForHover() {
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.syncHoverFromMouseLocation(refreshTipIfSameRow: true)
        }
    }

    private func syncHoverFromMouseLocation(refreshTipIfSameRow: Bool = false) {
        guard isVisible else { return }
        guard armHoverIfMouseMoved() else { return }
        let screen = NSEvent.mouseLocation
        // Outside the panel, or over search / footer / empty list space → clear.
        guard NSMouseInRect(screen, frame, false) else {
            clearHoverSelection()
            return
        }
        guard let win = tableView.window else { return }
        let winPoint = win.convertPoint(fromScreen: screen)
        let tablePoint = tableView.convert(winPoint, from: nil)
        let row = tableView.row(at: tablePoint)
        guard row >= 0, row < rows.count, case .item(let item) = rows[row],
              tableView.bounds.contains(tablePoint) else {
            clearHoverSelection()
            return
        }
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipCellView else {
            return
        }
        if selectedRow != row {
            selectRowFromHover(cell)
        } else if refreshTipIfSameRow {
            showTooltipForHover(item: item, anchor: cell)
        }
    }

    /// Drop list highlight when the pointer leaves items (empty area / panel exit).
    private func clearHoverSelection() {
        // Keep the open-time / keyboard selection until the user moves the mouse.
        guard hoverArmed else { return }
        tipController.hide(source: .hover)
        guard selectedRow >= 0 else { return }
        selectedRow = -1
        tableView.deselectAll(nil)
        updateSelectionVisuals()
    }

    /// Maccy-style: hover moves selection so the row gets accent fill.
    /// Highlight is driven only by selection — never by a sticky isHovered flag
    /// (scroll leaves mouseExited unfired and would keep multiple rows blue).
    private func selectRowFromHover(_ cell: ClipCellView) {
        let row = tableView.row(for: cell)
        guard row >= 0, row < rows.count, case .item(let item) = rows[row] else { return }
        if selectedRow != row {
            selectedRow = row
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            updateSelectionVisuals()
            showTooltipForHover(item: item, anchor: cell)
            updateFooterLabels()
        } else {
            cell.setSelected(true)
            showTooltipForHover(item: item, anchor: cell)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0, case .separator = rows[row] { return }
        selectedRow = row
        updateSelectionVisuals()
        if row >= 0 {
            showTooltipForSelection()
        } else {
            tipController.hide()
        }
    }

    private func updateSelectionVisuals() {
        for i in 0..<rows.count {
            guard case .item = rows[i] else { continue }
            let on = i == selectedRow
            if let cell = tableView.view(atColumn: 0, row: i, makeIfNecessary: true) as? ClipCellView {
                cell.setSelected(on)
            }
            if let row = tableView.rowView(atRow: i, makeIfNecessary: true) as? ClipRowView {
                row.setSelected(on)
            }
        }
        footerClear.setSelected(false)
        footerPrefs.setSelected(false)
        updateFooterLabels()
    }
}

// MARK: - Fast tooltip (↑↓ + hover); style matches the main panel

private enum TooltipSource {
    case keyboard
    case hover
}

private final class SelectionTooltipController {
    enum Content {
        case text(String)
        case image(NSImage)
    }

    private var window: NSPanel?
    private var work: DispatchWorkItem?
    private var activeSource: TooltipSource?
    private let delay: TimeInterval = 0.15
    private static let maxTextWidth: CGFloat = 360
    private static let maxImageSide: CGFloat = 520
    private static let pad: CGFloat = 10

    func hide() {
        work?.cancel()
        work = nil
        activeSource = nil
        window?.orderOut(nil)
        window = nil
    }

    /// Hide only if the currently shown tip came from `source` (so keyboard tip
    /// isn't cleared by an unrelated hover exit).
    func hide(source: TooltipSource) {
        if activeSource == nil || activeSource == source {
            hide()
        }
    }

    func show(
        _ content: Content,
        relativeTo view: NSView,
        parent: NSWindow,
        source: TooltipSource
    ) {
        work?.cancel()
        let work = DispatchWorkItem { [weak self, weak view, weak parent] in
            guard let self, let view, let parent else { return }
            self.present(content, relativeTo: view, parent: parent, source: source)
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func present(
        _ content: Content,
        relativeTo view: NSView,
        parent: NSWindow,
        source: TooltipSource
    ) {
        window?.orderOut(nil)
        window = nil

        // Same as main panel: NEVER round NSVisualEffectView itself — that
        // leaves white square corners. Size the vibrancy first, then wrap in
        // a clear root and round contentView + theme-frame superview.
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active

        switch content {
        case .text(let text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .labelColor
            label.drawsBackground = false
            label.preferredMaxLayoutWidth = Self.maxTextWidth - Self.pad * 2
            label.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: effect.topAnchor, constant: Self.pad),
                label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -Self.pad),
                label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: Self.pad),
                label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -Self.pad),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxTextWidth - Self.pad * 2),
            ])
        case .image(let image):
            let fitted = Self.fittedSize(for: image, maxSide: Self.maxImageSide)
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: effect.topAnchor, constant: Self.pad),
                imageView.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -Self.pad),
                imageView.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: Self.pad),
                imageView.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -Self.pad),
                imageView.widthAnchor.constraint(equalToConstant: fitted.width),
                imageView.heightAnchor.constraint(equalToConstant: fitted.height),
            ])
        }
        let size = effect.fittingSize
        effect.frame = NSRect(origin: .zero, size: size)
        effect.autoresizingMask = [.width, .height]

        let root = NSView(frame: effect.frame)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(effect)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = root
        panel.isReleasedWhenClosed = false
        Self.applyRoundedCorners(to: panel)

        let host = view.window ?? parent
        let inWindow = view.convert(view.bounds, to: nil)
        let rowScreen = host.convertToScreen(inWindow)
        let parentScreen = parent.frame

        var origin = NSPoint(
            x: parentScreen.maxX + 8,
            y: rowScreen.midY - size.height / 2
        )
        let screen = parent.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if origin.x + size.width > visible.maxX - 4 {
                origin.x = parentScreen.minX - size.width - 8
            }
            origin.y = min(
                max(origin.y, visible.minY + 4),
                visible.maxY - size.height - 4
            )
        }
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
        // Theme frame may appear after first layout — re-apply once visible.
        DispatchQueue.main.async {
            Self.applyRoundedCorners(to: panel)
            panel.invalidateShadow()
        }
        window = panel
        activeSource = source
    }

    private static func applyRoundedCorners(to panel: NSPanel) {
        let radius = ClipboardPanel.cornerRadius
        for view in [panel.contentView, panel.contentView?.superview].compactMap({ $0 }) {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.cornerRadius = radius
            view.layer?.masksToBounds = true
            if #available(macOS 10.15, *) {
                view.layer?.cornerCurve = .continuous
            }
        }
    }

    private static func fittedSize(for image: NSImage, maxSide: CGFloat) -> NSSize {
        let src = image.size
        guard src.width > 0, src.height > 0 else {
            return NSSize(width: maxSide, height: maxSide)
        }
        let scale = min(1, min(maxSide / src.width, maxSide / src.height))
        return NSSize(width: max(1, (src.width * scale).rounded()), height: max(1, (src.height * scale).rounded()))
    }
}

// MARK: - Row chrome

private final class ClipRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    func setSelected(_ on: Bool) { needsDisplay = true }
}

private final class ClipCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let pinView = NSImageView()
    private let fill = NSView()
    private var isSelected = false
    private var titleTrailingToShortcut: NSLayoutConstraint!
    private var titleTrailingToPin: NSLayoutConstraint!
    private var titleTrailingPlain: NSLayoutConstraint!
    var onHover: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        fill.wantsLayer = true
        fill.layer?.cornerRadius = ClipboardPanel.itemCorner
        if #available(macOS 10.15, *) {
            fill.layer?.cornerCurve = .continuous
        }
        fill.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.isHidden = true

        let pin = NSImage(
            systemSymbolName: "pin.fill",
            accessibilityDescription: "已固定")
        pinView.image = pin
        pinView.contentTintColor = .secondaryLabelColor
        pinView.imageScaling = .scaleProportionallyUpOrDown
        pinView.isHidden = true
        pinView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(fill)
        addSubview(titleLabel)
        addSubview(shortcutLabel)
        addSubview(pinView)
        textField = titleLabel

        // title … ⌘1 📌  /  title … 📌  /  title
        titleTrailingToShortcut = titleLabel.trailingAnchor.constraint(
            equalTo: shortcutLabel.leadingAnchor, constant: -6)
        titleTrailingToPin = titleLabel.trailingAnchor.constraint(
            equalTo: pinView.leadingAnchor, constant: -6)
        titleTrailingPlain = titleLabel.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -ClipboardPanel.textInset)

        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ClipboardPanel.textInset),
            titleTrailingPlain,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            shortcutLabel.trailingAnchor.constraint(equalTo: pinView.leadingAnchor, constant: -4),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            pinView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ClipboardPanel.textInset),
            pinView.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinView.widthAnchor.constraint(equalToConstant: 10),
            pinView.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func configure(item: ClipboardStore.Item, selected: Bool, pinShortcut: String? = nil) {
        titleLabel.stringValue = item.preview
        let pinned = item.pinned
        pinView.isHidden = !pinned
        let showShortcut = pinned && pinShortcut != nil
        if let pinShortcut, showShortcut {
            shortcutLabel.stringValue = pinShortcut
            shortcutLabel.isHidden = false
        } else {
            shortcutLabel.stringValue = ""
            shortcutLabel.isHidden = true
        }
        // Deactivate first so title never has two trailing constraints at once.
        titleTrailingToShortcut.isActive = false
        titleTrailingToPin.isActive = false
        titleTrailingPlain.isActive = false
        if showShortcut {
            titleTrailingToShortcut.isActive = true
        } else if pinned {
            titleTrailingToPin.isActive = true
        } else {
            titleTrailingPlain.isActive = true
        }
        setSelected(selected)
    }

    func setSelected(_ on: Bool) {
        isSelected = on
        applyChrome()
    }

    private func applyChrome() {
        // Selection alone drives highlight. A separate hover flag sticks when
        // scroll skips mouseExited and paints multiple blue rows.
        if isSelected {
            fill.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            titleLabel.textColor = .white
            shortcutLabel.textColor = NSColor.white.withAlphaComponent(0.55)
            pinView.contentTintColor = .white
        } else {
            fill.layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = .labelColor
            shortcutLabel.textColor = .tertiaryLabelColor
            pinView.contentTintColor = .secondaryLabelColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

private final class FooterRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    var onActivate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ClipboardPanel.itemCorner
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(shortcutLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ClipboardPanel.textInset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ClipboardPanel.textInset),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func configure(title: String, shortcut: String) {
        titleLabel.stringValue = title
        shortcutLabel.stringValue = shortcut
    }

    func setSelected(_ on: Bool) {
        layer?.backgroundColor = on
            ? NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            : nil
        titleLabel.textColor = on ? .white : .labelColor
        shortcutLabel.textColor = on ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
    }

    override func mouseEntered(with event: NSEvent) { setSelected(true) }
    override func mouseExited(with event: NSEvent) { setSelected(false) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    @objc private func clicked() { onActivate?() }
}
