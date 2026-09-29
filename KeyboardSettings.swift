import AppKit

// Separate colored overlay keeps the input-source image a native menu-bar template.
final class WarningBadgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25)).fill()
        let text = NSAttributedString(string: "!", attributes: [
            .font: NSFont.systemFont(ofSize: 7, weight: .bold), .foregroundColor: NSColor.white
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

// Picks one Korean/English key from the menu. Its last item edits several keys in a sheet,
// and once several are chosen a click opens that sheet directly.
final class SourcePicker: NSPopUpButton {
    var onChange: (([UInt64]?) -> Void)?
    private(set) var selection: [UInt64]?
    // Per-keyboard pickers start with a Default item that follows these keys.
    private var defaultKeys: [UInt64]?

    init(controlSize size: NSControl.ControlSize = .regular) {
        super.init(frame: .zero, pullsDown: false)
        controlSize = size; font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
        target = self; action = #selector(choose)
    }
    required init?(coder: NSCoder) { fatalError() }
    private static func title(_ keys: [UInt64]) -> String {
        keys.count > 1 ? "\(sourceName(keys[0])) +\(keys.count - 1)" : sourceName(keys[0])
    }
    func show(_ keys: [UInt64]?, default defaultKeys: [UInt64]? = nil) {
        // Saved data may hold no keys or unknown ones; those show as no choice.
        let keys = keys.flatMap(selectable)
        selection = keys; self.defaultKeys = defaultKeys
        removeAllItems()
        if let defaultKeys { addItem(withTitle: "기본값 (\(Self.title(defaultKeys)))") }
        addItems(withTitles: sourceNames)
        menu?.addItem(.separator())
        addItem(withTitle: "다중 한영 키")
        guard let keys else { selectItem(at: 0); return }
        if keys.count > 1 { lastItem?.title = Self.title(keys); selectItem(at: numberOfItems - 1) }
        else { selectItem(withTitle: Self.title(keys)) }
    }
    override func mouseDown(with event: NSEvent) {
        if (selection?.count ?? 0) > 1 { editMultiple() } else { super.mouseDown(with: event) }
    }
    @objc private func choose() {
        let index = indexOfSelectedItem, offset = defaultKeys == nil ? 0 : 1
        if index == numberOfItems - 1 { editMultiple(); return }
        commit(index < offset ? nil : [sources[index - offset]])
    }
    private func editMultiple() {
        show(selection, default: defaultKeys)
        guard let parent = window else { return }
        let sheet = MultiSourceSheet(checked: selection ?? defaultKeys ?? [])
        // Keep the picker until the sheet ends: a table reload can drop its row meanwhile.
        parent.beginSheet(sheet.window) { [self] response in
            let checked = sheet.checked
            // The sheet opens with the Default keys checked; returning them unchanged keeps following Default.
            guard response == .OK, selection != nil || checked != defaultKeys else { return }
            // Checking nothing drops back to one key: a keyboard follows Default, the global key keeps its first key.
            let single = defaultKeys == nil ? selection.map { Array($0.prefix(1)) } : nil
            commit(checked.isEmpty ? single : checked)
        }
    }
    private func commit(_ keys: [UInt64]?) {
        guard keys != selection else { return }
        show(keys, default: defaultKeys)
        onChange?(keys)
    }
}

final class MultiSourceSheet: NSObject {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 0), styleMask: [.titled], backing: .buffered, defer: false)
    private var boxes: [NSButton] = []
    var checked: [UInt64] { zip(sources, boxes).filter { $0.1.state == .on }.map(\.0) }

    init(checked: [UInt64]) {
        super.init()
        let title = NSTextField(labelWithString: "다중 한영 키")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        boxes = zip(sources, sourceNames).map { key, name in
            let box = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            box.state = checked.contains(key) ? .on : .off
            return box
        }
        let list = NSStackView(views: [title] + boxes)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 8
        list.setCustomSpacing(12, after: title)
        let done = NSButton(title: "완료", target: self, action: #selector(finish))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        let cancel = NSButton(title: "취소", target: self, action: #selector(discard))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let content = window.contentView!
        for view in [list, cancel, done] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            done.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 18),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            cancel.centerYAnchor.constraint(equalTo: done.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -12),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
        window.setContentSize(NSSize(width: 240, height: content.fittingSize.height))
    }
    @objc private func finish() { window.sheetParent?.endSheet(window, returnCode: .OK) }
    // Cancel keeps the saved keys.
    @objc private func discard() { window.sheetParent?.endSheet(window, returnCode: .cancel) }
}

private final class KeyboardModeControl: NSSegmentedControl {
    var keyboardKey = ""
}
final class KeyboardSettingsController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let engine: Engine
    private var manager: KeyboardManager { engine.keyboards }
    let sourcesChanged: ([UInt64]) -> Void
    // Warns about the given keyboards under the saved settings; false means the user cancelled.
    let confirm: (Set<String>) -> Bool
    let changed: () -> Void
    let window: NSWindow
    private let defaultControl = NSSegmentedControl(labels: ["Off", "On"], trackingMode: .selectOne, target: nil, action: nil)
    private let defaultSourcePicker = SourcePicker(controlSize: .small)
    private let defaultHint = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "키보드 없음")
    private let modes: [KeyboardMode] = [.off, .default, .on]
    private var keyboards: [SavedKeyboard] = []
    private var lastRows = ""
    private var controls: [String: KeyboardModeControl] = [:]
    private var sourcePickers: [String: SourcePicker] = [:]

    init(engine: Engine, sourcesChanged: @escaping ([UInt64]) -> Void, confirm: @escaping (Set<String>) -> Bool,
         changed: @escaping () -> Void) {
        self.engine = engine; self.sourcesChanged = sourcesChanged; self.confirm = confirm; self.changed = changed
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 446), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = "고급 설정"
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let title = NSTextField(labelWithString: "고급 설정")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let defaultTitle = NSTextField(labelWithString: "기본값")
        defaultTitle.font = .systemFont(ofSize: 13, weight: .medium)
        defaultHint.font = .systemFont(ofSize: 11)
        defaultHint.textColor = .secondaryLabelColor
        defaultControl.target = self; defaultControl.action = #selector(defaultChanged)
        defaultControl.segmentStyle = .rounded; defaultControl.controlSize = .small
        defaultControl.setWidth(66, forSegment: 0); defaultControl.setWidth(66, forSegment: 1)
        defaultControl.setAccessibilityLabel("기본값")
        let defaultLabels = NSStackView(views: [defaultTitle, defaultHint])
        defaultLabels.orientation = .vertical; defaultLabels.alignment = .leading; defaultLabels.spacing = 2
        let defaultRow = NSStackView(views: [defaultLabels, NSView(), defaultControl])
        defaultRow.alignment = .centerY
        defaultSourcePicker.onChange = { [weak self] keys in
            if let keys { self?.sourcesChanged(keys) }
            self?.refresh()
        }
        defaultSourcePicker.setAccessibilityLabel("기본 한영 키")
        let sourceTitle = NSTextField(labelWithString: "기본 한영 키")
        sourceTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let sourceRow = NSStackView(views: [sourceTitle, NSView(), defaultSourcePicker])
        sourceRow.alignment = .centerY
        let listTitle = NSTextField(labelWithString: "키보드별 설정")
        listTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("keyboard"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .fullWidth
        table.rowHeight = 42
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("대상 키보드")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = table
        let list = NSBox()
        list.boxType = .custom; list.titlePosition = .noTitle
        list.cornerRadius = 7; list.borderWidth = 1
        list.borderColor = .separatorColor; list.fillColor = .controlBackgroundColor
        list.contentViewMargins = .zero
        let listContent = list.contentView!
        scroll.translatesAutoresizingMaskIntoConstraints = false
        listContent.addSubview(scroll)
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        listContent.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: listContent.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: listContent.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: listContent.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: listContent.bottomAnchor, constant: -1),
            emptyLabel.centerXAnchor.constraint(equalTo: listContent.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listContent.centerYAnchor)
        ])
        let done = NSButton(title: "완료", target: self, action: #selector(close))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        for view in [title, defaultRow, sourceRow, listTitle, list, done] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            defaultRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            defaultRow.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: 22),
            defaultRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -48),
            sourceRow.topAnchor.constraint(equalTo: defaultRow.bottomAnchor, constant: 12),
            sourceRow.leadingAnchor.constraint(equalTo: defaultRow.leadingAnchor),
            sourceRow.trailingAnchor.constraint(equalTo: defaultRow.trailingAnchor),
            defaultSourcePicker.widthAnchor.constraint(equalTo: defaultControl.widthAnchor),
            listTitle.topAnchor.constraint(equalTo: sourceRow.bottomAnchor, constant: 18),
            listTitle.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 2),
            list.topAnchor.constraint(equalTo: listTitle.bottomAnchor, constant: 8),
            list.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            list.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -18),
            done.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
        reload()
    }
    func show(on parent: NSWindow) {
        reload()
        if window.sheetParent == nil { parent.beginSheet(window) }
    }
    // Repair calls this every second; a hidden window catches up when it is shown.
    func refresh() { if window.isVisible { reload() } }
    private func reload() {
        defaultControl.selectedSegment = manager.defaultEnabled ? 1 : 0
        defaultHint.stringValue = manager.defaultEnabled
            ? "기본적으로 모든 키보드에 적용됩니다."
            : "On으로 설정한 키보드에만 적용됩니다."
        defaultSourcePicker.show(engine.defaultSources)
        keyboards = manager.keyboards
        for keyboard in keyboards {
            controls[keyboard.key]?.selectedSegment = modes.firstIndex(of: keyboard.mode)!
            sourcePickers[keyboard.key]?.show(keyboard.sources, default: engine.defaultSources)
        }
        let signature = keyboards.map { "\($0.key)|\($0.name)|\(manager.connected.contains($0.key))" }.joined(separator: "\n")
        emptyLabel.isHidden = !keyboards.isEmpty
        guard signature != lastRows || table.numberOfRows != keyboards.count else { return }
        lastRows = signature
        controls = [:]; sourcePickers = [:]
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { keyboards.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let keyboard = keyboards[row]
        let connected = manager.connected.contains(keyboard.key)
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableColumn?.width ?? tableView.bounds.width, height: tableView.rowHeight))
        cell.autoresizingMask = [.width]
        let name = NSTextField(labelWithString: keyboard.name)
        name.font = .systemFont(ofSize: 12)
        name.textColor = connected ? .labelColor : .disabledControlTextColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.toolTip = keyboard.name
        cell.textField = name
        let control = KeyboardModeControl(labels: ["Off", "Default", "On"], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        control.keyboardKey = keyboard.key
        controls[keyboard.key] = control
        control.segmentStyle = .rounded; control.controlSize = .small
        control.selectedSegment = modes.firstIndex(of: keyboard.mode)!
        control.setWidth(36, forSegment: 0); control.setWidth(60, forSegment: 1); control.setWidth(36, forSegment: 2)
        control.setAccessibilityLabel("\(keyboard.name) 적용 설정")
        // NSTableView owns the cell frame. Autoresize its contents with that frame so
        // each row uses the full column width, independent of the name's intrinsic size.
        control.sizeToFit()
        control.setFrameOrigin(NSPoint(x: cell.bounds.width - control.frame.width - 12, y: (cell.bounds.height - control.frame.height) / 2))
        control.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        let picker = SourcePicker(controlSize: .small)
        sourcePickers[keyboard.key] = picker
        picker.show(keyboard.sources, default: engine.defaultSources)
        picker.onChange = { [weak self] keys in
            guard let self else { return }
            let saved = manager.known[keyboard.key]?.sources
            update([keyboard.key], change: { self.manager.setSources(keys, for: keyboard.key) }, undo: { self.manager.setSources(saved, for: keyboard.key) })
        }
        picker.setAccessibilityLabel("\(keyboard.name) 한영 키")
        picker.sizeToFit()
        picker.frame = NSRect(x: control.frame.minX - 192, y: (cell.bounds.height - picker.frame.height) / 2,
                              width: 180, height: picker.frame.height)
        picker.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        name.sizeToFit()
        name.frame = NSRect(x: 12, y: (cell.bounds.height - name.frame.height) / 2,
                            width: max(0, picker.frame.minX - 28), height: name.frame.height)
        name.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        cell.addSubview(name); cell.addSubview(picker); cell.addSubview(control)
        return cell
    }
    // Saves first so the warning checks the new settings; a cancelled warning undoes the change.
    private func update(_ affected: Set<String>, change: () -> Void, undo: () -> Void) {
        change()
        if confirm(affected) { changed() } else { undo() }
        refresh()
    }
    @objc private func defaultChanged() {
        let enabled = defaultControl.selectedSegment == 1, saved = manager.defaultEnabled
        // Turning Default on applies to every keyboard left on Default.
        update(Set(manager.known.values.filter { $0.mode == .default }.map(\.key)),
               change: { manager.defaultEnabled = enabled }, undo: { manager.defaultEnabled = saved })
    }
    @objc private func modeChanged(_ sender: KeyboardModeControl) {
        let key = sender.keyboardKey
        guard modes.indices.contains(sender.selectedSegment), let saved = manager.known[key]?.mode else { return }
        let mode = modes[sender.selectedSegment]
        update([key], change: { manager.setMode(mode, for: key) }, undo: { manager.setMode(saved, for: key) })
    }
    @objc private func close() { window.sheetParent?.endSheet(window); window.orderOut(nil) }
}
