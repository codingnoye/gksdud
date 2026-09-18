import AppKit

// Separate colored overlay keeps the input-source image a native menu-bar template.
final class WarningBadgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25)).fill()
        let text = NSAttributedString(string: "i", attributes: [
            .font: NSFont.systemFont(ofSize: 7, weight: .bold), .foregroundColor: NSColor.white
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

private final class KeyboardModeControl: NSSegmentedControl {
    var keyboardKey = ""
}
final class KeyboardSettingsController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let manager: KeyboardManager
    let changed: () -> Void
    let window: NSWindow
    private let defaultControl = NSSegmentedControl(labels: ["Off", "On"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "키보드 없음")
    private let modes: [KeyboardMode] = [.off, .default, .on]
    private var keyboards: [SavedKeyboard] = []
    private var lastRows = ""
    private var controls: [String: KeyboardModeControl] = [:]

    init(manager: KeyboardManager, changed: @escaping () -> Void) {
        self.manager = manager; self.changed = changed
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 310), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = "대상 키보드 설정"
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let title = NSTextField(labelWithString: "대상 키보드 설정")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let defaultTitle = NSTextField(labelWithString: "기본값")
        defaultTitle.font = .systemFont(ofSize: 13, weight: .medium)
        defaultControl.target = self; defaultControl.action = #selector(defaultChanged)
        defaultControl.segmentStyle = .rounded; defaultControl.controlSize = .small
        defaultControl.setWidth(66, forSegment: 0); defaultControl.setWidth(66, forSegment: 1)
        defaultControl.setAccessibilityLabel("기본값")
        let defaultRow = NSStackView(views: [defaultTitle, NSView(), defaultControl])
        defaultRow.alignment = .centerY

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
        for view in [title, defaultRow, list, done] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            defaultRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            defaultRow.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: 22),
            defaultRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -48),
            defaultRow.heightAnchor.constraint(equalToConstant: 28),
            list.topAnchor.constraint(equalTo: defaultRow.bottomAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            list.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -18),
            done.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
        refresh()
    }
    func show(on parent: NSWindow) {
        refresh()
        if window.sheetParent == nil { parent.beginSheet(window) }
    }
    func refresh() {
        defaultControl.selectedSegment = manager.defaultEnabled ? 1 : 0
        keyboards = manager.keyboards
        for keyboard in keyboards {
            controls[keyboard.key]?.selectedSegment = modes.firstIndex(of: keyboard.mode)!
        }
        let signature = keyboards.map { "\($0.key)|\($0.name)|\(manager.connected.contains($0.key))" }.joined(separator: "\n")
        emptyLabel.isHidden = !keyboards.isEmpty
        guard signature != lastRows || table.numberOfRows != keyboards.count else { return }
        lastRows = signature
        controls = [:]
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
        name.sizeToFit()
        name.frame = NSRect(x: 12, y: (cell.bounds.height - name.frame.height) / 2,
                            width: max(0, control.frame.minX - 28), height: name.frame.height)
        name.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        cell.addSubview(name); cell.addSubview(control)
        return cell
    }
    @objc private func defaultChanged() {
        manager.defaultEnabled = defaultControl.selectedSegment == 1
        changed(); refresh()
    }
    @objc private func modeChanged(_ sender: KeyboardModeControl) {
        guard modes.indices.contains(sender.selectedSegment) else { return }
        manager.setMode(modes[sender.selectedSegment], for: sender.keyboardKey)
        changed(); refresh()
    }
    @objc private func close() { window.sheetParent?.endSheet(window); window.orderOut(nil) }
}
