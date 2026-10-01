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
        // Otherwise AppKit may focus a selectable hint label first.
        window.initialFirstResponder = testInput
        let inputRow = NSStackView(views: [inputBadge, testInput]); inputRow.spacing = 12; inputRow.alignment = .centerY
        full(inputRow, in: root)
        testInput.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        let host = NSView(); full(host, in: root)
        for _ in 0..<5 {
            let panel = column(); host.addSubview(panel)
            NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo: host.leadingAnchor), panel.trailingAnchor.constraint(equalTo: host.trailingAnchor), panel.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor),
                tabPanels.count == 4 ? panel.centerYAnchor.constraint(equalTo: host.centerYAnchor) : panel.topAnchor.constraint(equalTo: host.topAnchor)])
            tabPanels.append(panel)
        }
        let tabs = NSStackView(); tabs.distribution = .fillEqually; tabs.spacing = 8
        tabs.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(tabs)
        for (index, title) in ["일반", "대소문자", "특수문자", "추가기능", "gksdud"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(changeTab(_:)))
            button.tag = index; button.setButtonType(.toggle); button.bezelStyle = .regularSquare
            button.isBordered = false; button.imagePosition = .imageAbove; button.imageScaling = .scaleProportionallyDown
            button.font = .systemFont(ofSize: 10)
            button.image = index == 0 ? sourceMenuIcon(korean: true) : tabGlyph(["", "Aa", "⌥", "+", "?"][index])
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
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; settingLabels.append((label, .secondaryLabelColor))
            label.translatesAutoresizingMaskIntoConstraints = false
            let container = NSView(); container.addSubview(label)
            if let last = panel.arrangedSubviews.last { panel.setCustomSpacing(6, after: last) }
            full(container, in: panel)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indent), label.trailingAnchor.constraint(equalTo: container.trailingAnchor), label.topAnchor.constraint(equalTo: container.topAnchor), label.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        }
        func separator(in panel: NSStackView) { let line = NSBox(); line.boxType = .separator; full(line, in: panel) }
        func heading(_ text: String, in panel: NSStackView) {
            let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 13, weight: .semibold)
            panel.addArrangedSubview(label); settingLabels.append((label, .labelColor))
        }
        func row(_ title: String, _ views: [NSView], in panel: NSStackView) {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 95).isActive = true
            settingLabels.append((label, .labelColor))
            let row = NSStackView(views: [label] + views); row.spacing = 16; row.alignment = .centerY
            panel.addArrangedSubview(row)
        }
        // Fewer rows than the other tabs, so they spread out: activation, then login and the menu bar, then the keys.
        let general = tabPanels[0]; general.spacing = 20
        pressAccess.target = self; pressAccess.action = #selector(requestPressAccess); pressAccess.bezelStyle = .rounded
        pressAccessRequired.font = .systemFont(ofSize: 11); pressAccessRequired.textColor = .systemOrange
        let accessRow = NSStackView(views: [pressAccess, pressAccessRequired]); accessRow.spacing = 8; accessRow.alignment = .centerY
        general.addArrangedSubview(accessRow)
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
        general.setCustomSpacing(28, after: activation)
        login.target = self; login.action = #selector(toggleLogin)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        showInMenuBar.target = self; showInMenuBar.action = #selector(toggleHidden)
        showInMenuBar.state = engine.defaults.bool(forKey: "hidden") ? .off : .on
        general.addArrangedSubview(login); general.addArrangedSubview(showInMenuBar)
        // Under 메뉴바에 표시, and only with it.
        replaceInputMenu.target = self; replaceInputMenu.action = #selector(toggleReplaceInputMenu)
        replaceInputMenu.translatesAutoresizingMaskIntoConstraints = false
        let replaceRow = NSView(); replaceRow.addSubview(replaceInputMenu)
        NSLayoutConstraint.activate([replaceInputMenu.leadingAnchor.constraint(equalTo: replaceRow.leadingAnchor, constant: 20),
            replaceInputMenu.topAnchor.constraint(equalTo: replaceRow.topAnchor), replaceInputMenu.bottomAnchor.constraint(equalTo: replaceRow.bottomAnchor)])
        hint("⌘+드래그로 위치를 옮길 수 있어요.", in: general)
        general.setCustomSpacing(12, after: general.arrangedSubviews.last!); full(replaceRow, in: general)
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
        general.setCustomSpacing(32, after: general.arrangedSubviews.last!)
        separator(in: general)
        general.setCustomSpacing(32, after: general.arrangedSubviews.last!)
        picker.show(engine.defaultSources)
        picker.onChange = { [weak self] _ in self?.selectionChanged() }
        row("한영 키", [picker], in: general)
        let keyboards = advancedButton; keyboards.target = self; keyboards.action = #selector(showKeyboardSettings); keyboards.bezelStyle = .rounded
        general.setCustomSpacing(8, after: general.arrangedSubviews.last!)
        row("", [keyboards], in: general)
        // Shown in the advanced settings sheet.
        targetPicker.addItems(withTitles: targets.map(\.name)); targetPicker.selectItem(withTitle: engine.target.name)
        targetPicker.target = self; targetPicker.action = #selector(selectionChanged)
        let caps = tabPanels[1]
        heading("대소문자", in: caps)
        longPressSwitch.target = self; longPressSwitch.action = #selector(toggleFeature(_:))
        preserveCapsSwitch.target = self; preserveCapsSwitch.action = #selector(toggleFeature(_:))
        caps.addArrangedSubview(longPressSwitch)
        hint("누른 즉시 한영 전환, 길게 유지시 대소문자 전환", in: caps)
        caps.addArrangedSubview(preserveCapsSwitch)
        koreanCapsSwitch.target = self; koreanCapsSwitch.action = #selector(toggleFeature(_:))
        caps.addArrangedSubview(koreanCapsSwitch)
        let symbols = tabPanels[2]
        heading("특수문자", in: symbols)
        for (index, title) in ["영어처럼 특수문자 입력", "Option 문자 입력 차단"].enumerated() {
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(changeSpecialMode(_:)))
            button.tag = index + 1; specialButtons.append(button); symbols.addArrangedSubview(button)
            hint(index == 0 ? "한글 상태에서도 ⌥8 → • 처럼 입력합니다." : "⌥+문자를 일반 문자로 입력합니다.", in: symbols)
        }
        specialStatus.font = .systemFont(ofSize: 11); specialStatus.textColor = .secondaryLabelColor
        full(specialStatus, in: symbols)
        let extras = tabPanels[3]
        heading("입력 소스 추가 (beta)", in: extras)
        addedSources.install(in: extras)
        separator(in: extras)
        heading("기타", in: extras)
        escapeSwitch.target = self; escapeSwitch.action = #selector(toggleFeature(_:))
        extras.addArrangedSubview(escapeSwitch)
        let about = tabPanels[4]; about.alignment = .centerX; about.spacing = 18
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
        func link(_ title: String, icon: String, template: Bool = true, action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded
            if let url = Bundle.main.url(forResource: icon, withExtension: "svg"), let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 16, height: 16 * image.size.height / image.size.width); image.isTemplate = template
                button.image = image; button.imagePosition = .imageLeading
            }
            return button
        }
        let project = link("GitHub", icon: "github", action: #selector(openProject)); about.addArrangedSubview(project)
        about.setCustomSpacing(28, after: project); separator(in: about)
        let supportTitle = NSTextField(labelWithString: "후원하기"); supportTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        about.setCustomSpacing(20, after: about.arrangedSubviews.last!); about.addArrangedSubview(supportTitle)
        let supportNote = NSTextField(wrappingLabelWithString: "후원해주시면 큰 힘이 됩니다!\nApp Store 등록에 사용하겠습니다.")
        supportNote.font = .systemFont(ofSize: 11); supportNote.textColor = .secondaryLabelColor; supportNote.alignment = .center
        about.setCustomSpacing(6, after: supportTitle); about.addArrangedSubview(supportNote)
        about.setCustomSpacing(12, after: supportNote); about.addArrangedSubview(link("Fairy", icon: "fairy", template: false, action: #selector(openSupport)))
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
            tabButtons[i].contentTintColor = i == index || (i == tabPanels.count - 1 && updates.available != nil) ? .controlAccentColor : .secondaryLabelColor
        }
    }
    @objc func showAbout() { showSettings(); selectTab(tabPanels.count - 1) }
    @objc func checkForUpdates() { installer.clearStatus(); updates.check(force: true) }
    @objc func performUpdate() { if let release = updates.available { installer.start(release) } }
    func installPreparedUpdate(_ prepared: PreparedUpdate) {
        do {
            guard !engine.isUpdatingSettings else { throw UpdateFailure("설정을 적용하고 있습니다. 잠시 후 다시 시도해주세요.") }
            optionInput.cancel()
            try engine.restoreSystem()
            try UpdateInstaller.launchHelper(prepared)
            preparedToRelaunch = true; stopKeyTap(); timer?.invalidate(); updateTimer?.invalidate()
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: prepared.directory)
            installer.fail(error)
            do { try engine.resume() } catch { report(error) }
            repair()
        }
    }
    @objc func openSupport() { NSWorkspace.shared.open(URL(string: "https://fairy.hada.io/@gksdud")!) }
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
