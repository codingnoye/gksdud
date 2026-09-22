import AppKit
import ServiceManagement

extension AppDelegate {
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 384, height: 636), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "gksdud"; window.isReleasedWhenClosed = false
        window.delegate = self; window.hidesOnDeactivate = false; window.center()
        let content = window.contentView!
        func column() -> NSStackView {
            let view = NSStackView(); view.orientation = .vertical; view.alignment = .leading; view.spacing = 16
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }
        func full(_ view: NSView, in stack: NSStackView) {
            stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let root = column(); root.spacing = 28; content.addSubview(root)
        inputBadge.contentTintColor = .labelColor; inputBadge.imageScaling = .scaleProportionallyUpOrDown
        inputBadge.widthAnchor.constraint(equalToConstant: 36).isActive = true
        inputBadge.heightAnchor.constraint(equalToConstant: 34).isActive = true
        testInput.stringValue = engine.testInputText; testInput.delegate = self
        testInput.font = .monospacedSystemFont(ofSize: 21, weight: .medium)
        testInput.placeholderString = "한영 전환을 테스트해보세요"
        testInput.setAccessibilityLabel("한영 전환 테스트 입력창")
        testInput.cell?.isScrollable = true; testInput.cell?.wraps = false
        testInput.usesSingleLineMode = true; testInput.lineBreakMode = .byClipping
        testInput.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let inputRow = NSStackView(views: [inputBadge, testInput]); inputRow.spacing = 12; inputRow.alignment = .centerY
        full(inputRow, in: root)
        testInput.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        let host = NSView(); full(host, in: root)
        for _ in 0..<4 {
            let panel = column(); host.addSubview(panel)
            NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo: host.leadingAnchor), panel.trailingAnchor.constraint(equalTo: host.trailingAnchor), panel.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor),
                tabPanels.count == 3 ? panel.centerYAnchor.constraint(equalTo: host.centerYAnchor) : panel.topAnchor.constraint(equalTo: host.topAnchor)])
            tabPanels.append(panel)
        }
        let tabs = NSStackView(); tabs.distribution = .fillEqually; tabs.spacing = 8
        tabs.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(tabs)
        for (index, title) in ["일반", "대소문자", "특수문자", "gksdud"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(changeTab(_:)))
            button.tag = index; button.setButtonType(.toggle); button.bezelStyle = .regularSquare
            button.isBordered = false; button.imagePosition = .imageAbove; button.imageScaling = .scaleProportionallyDown
            button.font = .systemFont(ofSize: 10)
            button.image = index == 0 ? sourceMenuIcon(korean: true) : tabGlyph(["", "Aa", "⌥", "?"][index])
            button.setAccessibilityLabel(title + " 탭")
            tabs.addArrangedSubview(button); tabButtons.append(button)
        }
        let tabLine = NSBox(); tabLine.boxType = .separator
        tabLine.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(tabLine)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(status)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            status.bottomAnchor.constraint(equalTo: tabLine.topAnchor, constant: -8),
            tabLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabLine.bottomAnchor.constraint(equalTo: tabs.topAnchor, constant: -5),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
            tabs.heightAnchor.constraint(equalToConstant: 42)
        ])
        func hint(_ text: String, in panel: NSStackView, indent: CGFloat = 20) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            let container = NSView(); container.addSubview(label)
            if let last = panel.arrangedSubviews.last { panel.setCustomSpacing(6, after: last) }
            full(container, in: panel)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indent), label.trailingAnchor.constraint(equalTo: container.trailingAnchor), label.topAnchor.constraint(equalTo: container.topAnchor), label.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        }
        func separator(in panel: NSStackView) { let line = NSBox(); line.boxType = .separator; full(line, in: panel) }
        func row(_ title: String, _ views: [NSView], in panel: NSStackView) {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 95).isActive = true
            let row = NSStackView(views: [label] + views); row.spacing = 16; row.alignment = .centerY
            panel.addArrangedSubview(row)
        }
        let general = tabPanels[0]
        enabled.target = self; enabled.action = #selector(toggleEnabled); enabled.state = engine.active ? .on : .off
        keyboardWarning.font = .systemFont(ofSize: 11); keyboardWarning.textColor = .systemOrange
        let warningIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "경고")!)
        warningIcon.contentTintColor = .systemOrange
        warningIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        keyboardWarningRow.addArrangedSubview(warningIcon); keyboardWarningRow.addArrangedSubview(keyboardWarning)
        keyboardWarningRow.alignment = .top; keyboardWarningRow.spacing = 5
        let activation = NSStackView(views: [enabled, keyboardWarningRow])
        activation.orientation = .vertical; activation.alignment = .leading; activation.spacing = 6
        full(activation, in: general); keyboardWarningRow.isHidden = true
        pressSwitch.target = self; pressSwitch.action = #selector(togglePressSwitch)
        pressAccess.target = self; pressAccess.action = #selector(requestPressAccess); pressAccess.bezelStyle = .rounded
        let pressRow = NSStackView(views: [pressSwitch, pressAccess]); pressRow.spacing = 16; pressRow.alignment = .centerY
        general.addArrangedSubview(pressRow)
        hint("버튼을 뗄 때가 아닌 누를 때 전환하도록 해 더 빠르게 전환합니다.\n글자 씹힘도 더 개선됩니다.", in: general)
        separator(in: general)
        picker.addItems(withTitles: ["우측 Command ⌘", "우측 Option ⌥", "Caps Lock ⇪", "우측 Control ⌃"])
        picker.selectItem(at: sources.firstIndex(of: engine.source) ?? 0)
        picker.target = self; picker.action = #selector(selectionChanged)
        row("한영 키", [picker], in: general)
        targetPicker.addItems(withTitles: targets.map(\.name)); targetPicker.selectItem(withTitle: engine.target.name)
        targetPicker.target = self; targetPicker.action = #selector(selectionChanged)
        row("내부 전환 키", [targetPicker], in: general)
        hint("시스템의 '이전 입력 소스 선택' 단축키의 값을 변경합니다.\n다른 앱과 겹치지 않는, 기능 없는 키를 골라주세요.", in: general)
        let keyboards = NSButton(title: "대상 키보드 설정", target: self, action: #selector(showKeyboardSettings)); keyboards.bezelStyle = .rounded
        general.addArrangedSubview(keyboards)
        separator(in: general)
        login.target = self; login.action = #selector(toggleLogin)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        showInMenuBar.target = self; showInMenuBar.action = #selector(toggleHidden)
        showInMenuBar.state = engine.defaults.bool(forKey: "hidden") ? .off : .on
        general.addArrangedSubview(login); general.addArrangedSubview(showInMenuBar)
        hint("기존 메뉴바 입력기를 대체합니다.\n⌘+드래그로 위치를 옮길 수 있어요.", in: general)
        iconPicker.addItems(withTitles: ["한 / dud", "한 / A", "KO / EN", "ㅎuㅎ / dud"])
        iconPicker.selectItem(at: iconStyle); iconPicker.target = self; iconPicker.action = #selector(changeIconStyle)
        iconPicker.setAccessibilityLabel("메뉴바 아이콘 조합")
        for preview in [koreanPreview, englishPreview] {
            preview.widthAnchor.constraint(equalToConstant: 22).isActive = true
            preview.heightAnchor.constraint(equalToConstant: 20).isActive = true; preview.contentTintColor = .labelColor
        }
        koreanPreview.setAccessibilityLabel("한국어 아이콘 미리보기")
        englishPreview.setAccessibilityLabel("영어 아이콘 미리보기")
        row("메뉴바 아이콘", [iconPicker, koreanPreview, englishPreview], in: general)
        let caps = tabPanels[1]
        longPressSwitch.target = self; longPressSwitch.action = #selector(toggleLongPress)
        preserveCapsSwitch.target = self; preserveCapsSwitch.action = #selector(togglePreserveCaps)
        caps.addArrangedSubview(longPressSwitch)
        hint("누른 즉시 한영 전환, 길게 유지시 대소문자 전환", in: caps)
        caps.addArrangedSubview(preserveCapsSwitch)
        let symbols = tabPanels[2]
        for (index, title) in ["영어처럼 특수문자 입력", "Option 문자 입력 차단"].enumerated() {
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(changeSpecialMode(_:)))
            button.tag = index + 1; specialButtons.append(button); symbols.addArrangedSubview(button)
            hint(index == 0 ? "한글 상태에서도 ⌥8 → • 처럼 입력합니다." : "⌥+문자를 일반 문자로 입력합니다.", in: symbols)
        }
        specialStatus.font = .systemFont(ofSize: 11); specialStatus.textColor = .secondaryLabelColor
        full(specialStatus, in: symbols)
        let about = tabPanels[3]; about.alignment = .centerX; about.spacing = 18
        let appIcon = NSImageView(image: NSApp.applicationIconImage)
        appIcon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        about.addArrangedSubview(appIcon)
        let name = NSTextField(labelWithString: "gksdud"); name.font = .systemFont(ofSize: 20, weight: .semibold)
        about.setCustomSpacing(12, after: appIcon); about.addArrangedSubview(name)
        updateHeading.font = .systemFont(ofSize: 12); updateHeading.textColor = .secondaryLabelColor; updateHeading.alignment = .center
        about.setCustomSpacing(4, after: name); full(updateHeading, in: about)
        updateScroll.hasVerticalScroller = true; updateScroll.borderType = .bezelBorder
        updateScroll.heightAnchor.constraint(equalToConstant: 132).isActive = true
        updateSummary.isEditable = false; updateSummary.isSelectable = true
        updateSummary.font = .systemFont(ofSize: 12); updateSummary.textColor = .labelColor
        updateSummary.textContainerInset = NSSize(width: 8, height: 8)
        updateSummary.isHorizontallyResizable = false; updateSummary.isVerticallyResizable = true
        updateSummary.autoresizingMask = [.width]; updateSummary.textContainer?.widthTracksTextView = true
        updateScroll.documentView = updateSummary; full(updateScroll, in: about)
        updateButton.target = self; updateButton.action = #selector(performUpdate); updateButton.bezelStyle = .rounded
        checkUpdateButton.target = self; checkUpdateButton.action = #selector(checkForUpdates); checkUpdateButton.bezelStyle = .rounded
        let actions = NSStackView(views: [updateButton, checkUpdateButton]); actions.spacing = 10; about.addArrangedSubview(actions)
        updateStatus.font = .systemFont(ofSize: 11); updateStatus.textColor = .secondaryLabelColor; updateStatus.alignment = .center
        about.setCustomSpacing(8, after: actions); full(updateStatus, in: about)
        about.setCustomSpacing(28, after: updateStatus)
        let project = NSButton(title: "GitHub", target: self, action: #selector(openProject)); project.bezelStyle = .rounded
        if let url = Bundle.main.url(forResource: "github", withExtension: "svg"), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 16, height: 16); image.isTemplate = true
            project.image = image; project.imagePosition = .imageLeading
        }
        let support = NSButton(title: "후원", target: self, action: #selector(openSupport)); support.bezelStyle = .rounded
        support.isHidden = supportURL == nil
        about.addArrangedSubview(NSStackView(views: [project, support]))
        let credit = NSTextField(labelWithString: "© 2026 CodingNoye · codingnoye@gmail.com")
        credit.font = .systemFont(ofSize: 10); credit.textColor = .secondaryLabelColor
        about.addArrangedSubview(credit)
        selectTab(0); updatePressAccess(); refreshSpecialMode(); refreshUpdates(); refreshIconPreviews(); refreshKeyboardState(); updateInputIndicator()
    }
    func tabGlyph(_ text: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 20), flipped: false) { rect in
            let label = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.black])
            let size = label.size(); label.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2)); return true
        }
        image.isTemplate = true; return image
    }
    // Up arrow in a circle, centered in the canvas so it lines up with the other menu icons.
    func updateGlyph(_ canvas: NSSize, color: NSColor? = nil) -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { rect in
            let side = min(rect.width, rect.height, 15), line = max(side / 13, 0.9)
            let box = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            (color ?? .black).set()
            let circle = NSBezierPath(ovalIn: box.insetBy(dx: line / 2 + 0.25, dy: line / 2 + 0.25)); circle.lineWidth = line; circle.stroke()
            let arrow = NSBezierPath(); arrow.lineWidth = line * 1.25; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
            let tip = box.minY + side * 0.74, wing = side * 0.2
            arrow.move(to: NSPoint(x: box.midX, y: box.minY + side * 0.27)); arrow.line(to: NSPoint(x: box.midX, y: tip))
            arrow.move(to: NSPoint(x: box.midX - wing, y: tip - wing)); arrow.line(to: NSPoint(x: box.midX, y: tip))
            arrow.line(to: NSPoint(x: box.midX + wing, y: tip - wing)); arrow.stroke()
            return true
        }
        image.isTemplate = color == nil; return image
    }
    @objc func changeTab(_ sender: NSButton) { selectTab(sender.tag) }
    func selectTab(_ index: Int) {
        guard tabPanels.indices.contains(index) else { return }
        selectedTab = index
        for (i, panel) in tabPanels.enumerated() {
            panel.isHidden = i != index; tabButtons[i].state = i == index ? .on : .off
            tabButtons[i].contentTintColor = i == index || (i == 3 && updates.available != nil) ? .controlAccentColor : .secondaryLabelColor
        }
    }
    @objc func showAbout() { showSettings(); selectTab(3) }
    @objc func checkForUpdates() { installer.clearStatus(); updates.check(force: true) }
    @objc func performUpdate() { if let release = updates.available { installer.start(release) } }
    func installPreparedUpdate(_ prepared: PreparedUpdate) {
        do {
            guard !engine.isUpdatingSettings else { throw UpdateFailure("설정을 적용하고 있습니다. 잠시 후 다시 시도해주세요.") }
            optionInput.cancel()
            try engine.prepareForExit()
            try UpdateInstaller.launchHelper(prepared)
            preparedToRelaunch = true; stopKeyTap(); timer?.invalidate(); updateTimer?.invalidate()
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: prepared.directory)
            installer.fail(error); repair()
        }
    }
    var supportURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GKSDUDSupportURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    @objc func openSupport() { if let url = supportURL { NSWorkspace.shared.open(url) } }
    @objc func openProject() { NSWorkspace.shared.open(URL(string: "https://github.com/codingnoye/gksdud")!) }
    func refreshUpdates() {
        let release = updates.available
        tabButtons.last?.image = release == nil ? tabGlyph("?") : updateGlyph(NSSize(width: 24, height: 20), color: .controlAccentColor)
        selectTab(selectedTab)
        tabButtons.last?.setAccessibilityLabel(release == nil ? "gksdud 탭" : "gksdud 탭, 업데이트 가능")
        for entry in item?.menu?.items ?? [] where entry.action == #selector(showAbout) { entry.isHidden = release == nil }
        let latest = release.map { " → v\($0.versionString)" } ?? ""
        updateHeading.stringValue = "v\(updates.installedVersion)\(latest)"
        updateSummary.string = release?.summary ?? ""
        updateScroll.isHidden = release == nil
        updateButton.isHidden = release == nil
        updateButton.isEnabled = !installer.busy
        checkUpdateButton.isEnabled = !updates.checking && !installer.busy
        if !installer.status.isEmpty { updateStatus.stringValue = installer.status }
        else if updates.checking { updateStatus.stringValue = "업데이트 확인 중…" }
        else if let error = updates.error { updateStatus.stringValue = error }
        else if let date = updates.lastChecked {
            updateStatus.stringValue = "마지막 확인 \(DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short))"
        } else { updateStatus.stringValue = "" }
    }
}
