import AppKit
import ServiceManagement

extension AppDelegate {
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 492, height: 744), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "gksdud"; window.isReleasedWhenClosed = false
        window.delegate = self; window.hidesOnDeactivate = false; window.center()
        let content = window.contentView!
        func column() -> NSStackView {
            let view = NSStackView(); view.orientation = .vertical; view.alignment = .leading; view.spacing = 14
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }
        let root = column(); content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)
        ])
        func full(_ view: NSView, in stack: NSStackView) {
            stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let tabs = NSStackView(); tabs.distribution = .fillEqually; tabs.spacing = 8
        full(tabs, in: root)
        for (index, title) in ["일반", "대소문자", "특수문자", "gksdud"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(changeTab(_:)))
            button.tag = index; button.setButtonType(.toggle); button.bezelStyle = .regularSquare
            button.isBordered = false; button.imagePosition = .imageAbove; button.imageScaling = .scaleProportionallyDown
            button.image = index == 0 ? sourceMenuIcon(korean: true) : tabGlyph(["", "Aa", "⌥", "?"][index])
            button.setAccessibilityLabel(title + " 탭")
            button.heightAnchor.constraint(equalToConstant: 62).isActive = true
            tabs.addArrangedSubview(button); tabButtons.append(button)
        }
        updateTabBadge.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "업데이트 가능")
        updateTabBadge.contentTintColor = .controlAccentColor; updateTabBadge.translatesAutoresizingMaskIntoConstraints = false
        tabButtons[3].addSubview(updateTabBadge)
        NSLayoutConstraint.activate([
            updateTabBadge.trailingAnchor.constraint(equalTo: tabButtons[3].trailingAnchor, constant: -12),
            updateTabBadge.topAnchor.constraint(equalTo: tabButtons[3].topAnchor, constant: 3),
            updateTabBadge.widthAnchor.constraint(equalToConstant: 14), updateTabBadge.heightAnchor.constraint(equalToConstant: 14)
        ])
        let line = NSBox(); line.boxType = .separator; full(line, in: root)
        inputBadge.contentTintColor = .labelColor; inputBadge.imageScaling = .scaleProportionallyUpOrDown
        inputBadge.widthAnchor.constraint(equalToConstant: 36).isActive = true
        inputBadge.heightAnchor.constraint(equalToConstant: 34).isActive = true
        testInput.stringValue = engine.testInputText; testInput.delegate = self
        testInput.font = .monospacedSystemFont(ofSize: 21, weight: .medium)
        testInput.placeholderString = "한영 전환과 특수문자를 테스트해보세요"
        testInput.setAccessibilityLabel("한영 전환과 특수문자 테스트 입력창")
        testInput.cell?.isScrollable = true
        let inputRow = NSStackView(views: [inputBadge, testInput]); inputRow.spacing = 12; inputRow.alignment = .centerY
        full(inputRow, in: root)
        testInput.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        enabled.target = self; enabled.action = #selector(toggleEnabled); enabled.state = engine.active ? .on : .off
        pressAccess.target = self; pressAccess.action = #selector(requestPressAccess); pressAccess.bezelStyle = .rounded
        let activation = NSStackView(views: [enabled, pressAccess]); activation.spacing = 18; activation.alignment = .centerY
        root.addArrangedSubview(activation)
        keyboardWarning.font = .systemFont(ofSize: 11); keyboardWarning.textColor = .systemOrange
        let warningIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "경고")!)
        warningIcon.contentTintColor = .systemOrange
        warningIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        keyboardWarningRow.addArrangedSubview(warningIcon); keyboardWarningRow.addArrangedSubview(keyboardWarning)
        keyboardWarningRow.alignment = .top; keyboardWarningRow.spacing = 5
        full(keyboardWarningRow, in: root); keyboardWarningRow.isHidden = true
        let host = NSView(); full(host, in: root)
        host.heightAnchor.constraint(equalToConstant: 454).isActive = true
        for _ in 0..<4 {
            let panel = column(); panel.spacing = 13; host.addSubview(panel)
            NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo: host.leadingAnchor), panel.trailingAnchor.constraint(equalTo: host.trailingAnchor), panel.topAnchor.constraint(equalTo: host.topAnchor), panel.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor)])
            tabPanels.append(panel)
        }
        func hint(_ text: String, in panel: NSStackView) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
            full(label, in: panel)
        }
        func separator(in panel: NSStackView) { let line = NSBox(); line.boxType = .separator; full(line, in: panel) }
        func row(_ title: String, _ views: [NSView], in panel: NSStackView) {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 96).isActive = true
            let row = NSStackView(views: [label] + views); row.spacing = 12; row.alignment = .centerY
            panel.addArrangedSubview(row)
        }
        let general = tabPanels[0]
        pressSwitch.target = self; pressSwitch.action = #selector(togglePressSwitch); general.addArrangedSubview(pressSwitch)
        hint("한영 키를 누르는 순간 전환합니다.", in: general)
        picker.addItems(withTitles: ["우측 Command ⌘", "우측 Option ⌥", "Caps Lock ⇪"])
        picker.selectItem(at: sources.firstIndex(of: engine.source) ?? 0)
        picker.target = self; picker.action = #selector(selectionChanged)
        row("한영 키", [picker], in: general)
        targetPicker.addItems(withTitles: targets.map(\.name)); targetPicker.selectItem(withTitle: engine.target.name)
        targetPicker.target = self; targetPicker.action = #selector(selectionChanged)
        row("내부 전환 키", [targetPicker], in: general)
        hint("다른 앱에서 사용하지 않는 키를 골라주세요.", in: general)
        let keyboards = NSButton(title: "대상 키보드 설정", target: self, action: #selector(showKeyboardSettings)); keyboards.bezelStyle = .rounded
        general.addArrangedSubview(keyboards)
        separator(in: general)
        login.target = self; login.action = #selector(toggleLogin)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        showInMenuBar.target = self; showInMenuBar.action = #selector(toggleHidden)
        showInMenuBar.state = engine.defaults.bool(forKey: "hidden") ? .off : .on
        general.addArrangedSubview(login); general.addArrangedSubview(showInMenuBar)
        hint("메뉴바 아이콘은 ⌘+드래그로 옮길 수 있어요.", in: general)
        iconPicker.addItems(withTitles: ["한 / dud", "한 / A", "KO / EN", "ㅎuㅎ / dud"])
        iconPicker.selectItem(at: iconStyle); iconPicker.target = self; iconPicker.action = #selector(changeIconStyle)
        for preview in [koreanPreview, englishPreview] {
            preview.widthAnchor.constraint(equalToConstant: 22).isActive = true
            preview.heightAnchor.constraint(equalToConstant: 20).isActive = true; preview.contentTintColor = .labelColor
        }
        row("메뉴바 아이콘", [iconPicker, koreanPreview, englishPreview], in: general)
        let caps = tabPanels[1]
        longPressSwitch.target = self; longPressSwitch.action = #selector(toggleLongPress)
        preserveCapsSwitch.target = self; preserveCapsSwitch.action = #selector(togglePreserveCaps)
        caps.addArrangedSubview(longPressSwitch)
        hint("한영 키를 0.5초 누르면 영어로 전환하고 대소문자를 바꿉니다.", in: caps)
        caps.addArrangedSubview(preserveCapsSwitch)
        hint("한글로 전환하기 전의 영문 대소문자 상태를 기억합니다.", in: caps)
        let symbols = tabPanels[2]
        hint("Option 키의 문자 입력 방식을 선택하세요.", in: symbols)
        for (index, title) in ["없음", "영어처럼 특수문자 입력 (실험적)", "Option 문자 입력 차단"].enumerated() {
            let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(changeSpecialMode(_:)))
            button.tag = index; specialButtons.append(button); symbols.addArrangedSubview(button)
        }
        hint("⌥+문자와 ⌥⇧+문자를 영어로 입력한 뒤 한글로 돌아옵니다.\n예: ⌥⇧9 → ·, ⌥8 → •, ⌥2 → ™", in: symbols)
        separator(in: symbols)
        hint("방향키·Delete·Return과 ⌘·Control 단축키는 유지됩니다.\n오른쪽 Option을 한영 키로 쓰면 왼쪽 Option을 사용하세요.\n특수문자 설정은 모든 키보드에 적용됩니다.", in: symbols)
        specialStatus.font = .systemFont(ofSize: 12); specialStatus.textColor = .secondaryLabelColor
        full(specialStatus, in: symbols)
        let about = tabPanels[3]
        let version = NSTextField(labelWithString: "gksdud \(updates.installedVersion)")
        version.font = .systemFont(ofSize: 21, weight: .semibold); about.addArrangedSubview(version)
        updateHeading.font = .systemFont(ofSize: 14, weight: .semibold); full(updateHeading, in: about)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 148).isActive = true
        updateSummary.isEditable = false; updateSummary.isSelectable = true
        updateSummary.font = .systemFont(ofSize: 13); updateSummary.textColor = .labelColor
        updateSummary.textContainerInset = NSSize(width: 8, height: 8)
        updateSummary.isHorizontallyResizable = false; updateSummary.isVerticallyResizable = true
        updateSummary.autoresizingMask = [.width]; updateSummary.textContainer?.widthTracksTextView = true
        scroll.documentView = updateSummary; full(scroll, in: about)
        updateButton.target = self; updateButton.action = #selector(performUpdate); updateButton.bezelStyle = .rounded
        checkUpdateButton.target = self; checkUpdateButton.action = #selector(checkForUpdates); checkUpdateButton.bezelStyle = .rounded
        let actions = NSStackView(views: [updateButton, checkUpdateButton]); actions.spacing = 10; about.addArrangedSubview(actions)
        updateStatus.font = .systemFont(ofSize: 11); updateStatus.textColor = .secondaryLabelColor; full(updateStatus, in: about)
        separator(in: about)
        let project = NSButton(title: "GitHub", target: self, action: #selector(openProject)); project.bezelStyle = .rounded
        let license = NSButton(title: "MIT 라이선스", target: self, action: #selector(showLicense)); license.bezelStyle = .rounded
        let support = NSButton(title: "후원", target: self, action: #selector(openSupport)); support.bezelStyle = .rounded
        support.isHidden = supportURL == nil
        about.addArrangedSubview(NSStackView(views: [project, license, support]))
        hint("© 2026 CodingNoye · codingnoye@gmail.com", in: about)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(status)
        NSLayoutConstraint.activate([status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), root.bottomAnchor.constraint(lessThanOrEqualTo: status.topAnchor, constant: -12)])
        selectTab(0); updatePressAccess(); refreshSpecialMode(); refreshUpdates(); refreshIconPreviews(); refreshKeyboardState(); updateInputIndicator()
    }
    func tabGlyph(_ text: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 25), flipped: false) { rect in
            let label = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 21, weight: .medium), .foregroundColor: NSColor.black])
            let size = label.size(); label.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2)); return true
        }
        image.isTemplate = true; return image
    }
    @objc func changeTab(_ sender: NSButton) { selectTab(sender.tag) }
    func selectTab(_ index: Int) {
        guard tabPanels.indices.contains(index) else { return }
        selectedTab = index
        for (i, panel) in tabPanels.enumerated() {
            panel.isHidden = i != index; tabButtons[i].state = i == index ? .on : .off
            tabButtons[i].contentTintColor = i == index ? .controlAccentColor : .secondaryLabelColor
        }
    }
    @objc func showAbout() { selectTab(3); showSettings() }
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
    @objc func showLicense() {
        let alert = NSAlert(); alert.messageText = "MIT License"
        alert.informativeText = Bundle.main.url(forResource: "LICENSE", withExtension: nil).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "MIT License · © 2026 CodingNoye"
        alert.beginSheetModal(for: window)
    }
    func refreshUpdates() {
        let release = updates.available
        updateTabBadge.isHidden = release == nil
        tabButtons.last?.setAccessibilityLabel(release == nil ? "gksdud 탭" : "gksdud 탭, 업데이트 가능")
        for entry in item?.menu?.items ?? [] where entry.action == #selector(showAbout) {
            entry.isHidden = release == nil
            entry.title = release.map { "업데이트 가능 · \($0.tag_name)" } ?? "업데이트 가능"
        }
        updateHeading.stringValue = release.map { "\($0.tag_name) 업데이트 가능" } ?? (updates.lastChecked == nil ? "새 버전을 확인해보세요" : "최신 버전을 사용 중입니다")
        updateSummary.string = release?.summary ?? "새로운 정식 릴리스가 있으면 이곳에 요약을 표시합니다."
        updateButton.isHidden = release == nil; checkUpdateButton.isEnabled = !updates.checking
        updateButton.isEnabled = !installer.busy
        checkUpdateButton.isEnabled = !updates.checking && !installer.busy
        if !installer.status.isEmpty { updateStatus.stringValue = installer.status }
        else if updates.checking { updateStatus.stringValue = "업데이트 확인 중…" }
        else if let error = updates.error { updateStatus.stringValue = error }
        else if let date = updates.lastChecked {
            updateStatus.stringValue = "마지막 확인: \(DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)) · 하루 한 번 자동 확인"
        } else { updateStatus.stringValue = "하루 한 번 새 정식 릴리스를 확인합니다." }
    }
}
