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
private final class KeyboardListDocument: NSView {
    override var isFlipped: Bool { true }
}

final class KeyboardSettingsController: NSObject {
    let manager: KeyboardManager
    let changed: () -> Void
    let window: NSWindow
    private let defaultSwitch = NSSwitch()
    private let rows = NSStackView()
    private var lastRows = ""
    private var controls: [String: KeyboardModeControl] = [:]
    init(manager: KeyboardManager, changed: @escaping () -> Void) {
        self.manager = manager; self.changed = changed
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 430), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = "대상 키보드 설정"
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let title = NSTextField(labelWithString: "대상 키보드 설정")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let defaultTitle = NSTextField(labelWithString: "기본값")
        defaultTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let subtitle = NSTextField(labelWithString: "새로운 키보드와 Default로 설정한 키보드에 적용합니다.")
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [defaultTitle, subtitle])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
        defaultSwitch.target = self; defaultSwitch.action = #selector(defaultChanged)
        defaultSwitch.setAccessibilityLabel("새로운 키보드에 적용하는 기본값")
        let defaultRow = NSStackView(views: [labels, NSView(), defaultSwitch])
        defaultRow.alignment = .centerY; defaultRow.spacing = 16
        let separator = NSBox(); separator.boxType = .separator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        let document = KeyboardListDocument(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows); scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        let footnote = NSTextField(labelWithString: "On · Off는 기본값보다 우선합니다. 연결이 끊겨도 설정은 유지됩니다.")
        footnote.font = .systemFont(ofSize: 11); footnote.textColor = .secondaryLabelColor
        let done = NSButton(title: "완료", target: self, action: #selector(close))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        for view in [title, defaultRow, separator, scroll, footnote, done] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            defaultRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 22),
            defaultRow.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            defaultRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            separator.topAnchor.constraint(equalTo: defaultRow.bottomAnchor, constant: 18),
            separator.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: defaultRow.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: defaultRow.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footnote.topAnchor, constant: -14),
            footnote.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            footnote.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -16),
            done.trailingAnchor.constraint(equalTo: defaultRow.trailingAnchor),
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
        defaultSwitch.state = manager.defaultEnabled ? .on : .off
        for keyboard in manager.keyboards {
            controls[keyboard.key]?.selectedSegment = KeyboardMode.allCases.firstIndex(of: keyboard.mode)!
        }
        let signature = manager.keyboards.map { "\($0.key)|\($0.name)|\($0.detail)|\(manager.connected.contains($0.key))" }.joined(separator: "\n")
        guard signature != lastRows || rows.arrangedSubviews.isEmpty else { return }
        lastRows = signature
        controls = [:]
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        if manager.keyboards.isEmpty {
            let empty = NSTextField(labelWithString: "키보드가 연결되면 여기에 표시됩니다.")
            empty.textColor = .secondaryLabelColor
            rows.addArrangedSubview(empty); empty.heightAnchor.constraint(equalToConstant: 70).isActive = true
        }
        for keyboard in manager.keyboards {
            let connected = manager.connected.contains(keyboard.key)
            let title = NSTextField(labelWithString: keyboard.name)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.textColor = connected ? .labelColor : .disabledControlTextColor
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            title.toolTip = keyboard.name
            let detail = NSTextField(labelWithString: "\(connected ? "연결됨" : "연결 안 됨") · \(keyboard.detail)")
            detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let labels = NSStackView(views: [title, detail])
            labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
            let control = KeyboardModeControl(labels: ["On", "Default", "Off"], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
            control.keyboardKey = keyboard.key
            controls[keyboard.key] = control
            control.segmentStyle = .rounded; control.controlSize = .small
            control.selectedSegment = KeyboardMode.allCases.firstIndex(of: keyboard.mode)!
            control.setWidth(38, forSegment: 0); control.setWidth(62, forSegment: 1); control.setWidth(38, forSegment: 2)
            control.setAccessibilityLabel("\(keyboard.name) 적용 설정")
            control.setToolTip("항상 적용", forSegment: 0)
            control.setToolTip("기본값 따르기", forSegment: 1)
            control.setToolTip("적용하지 않음", forSegment: 2)
            let row = NSStackView(views: [labels, NSView(), control])
            row.alignment = .centerY; row.spacing = 12
            rows.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: rows.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: 66),
                labels.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -174),
                title.widthAnchor.constraint(equalTo: labels.widthAnchor),
                detail.widthAnchor.constraint(equalTo: labels.widthAnchor)
            ])
            let line = NSBox(); line.boxType = .separator; rows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }
    @objc private func defaultChanged() {
        manager.defaultEnabled = defaultSwitch.state == .on
        changed(); refresh()
    }
    @objc private func modeChanged(_ sender: KeyboardModeControl) {
        guard KeyboardMode.allCases.indices.contains(sender.selectedSegment) else { return }
        manager.setMode(KeyboardMode.allCases[sender.selectedSegment], for: sender.keyboardKey)
        changed(); refresh()
    }
    @objc private func close() { window.sheetParent?.endSheet(window); window.orderOut(nil) }
}
