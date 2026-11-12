import AppKit
import Carbon
import UniformTypeIdentifiers

struct AppSourceRule: Codable, Equatable {
    var bundleID: String
    var name: String
    var sourceID: String
}


struct AppSourceRules {
    let defaults: UserDefaults
    var enabled: Bool {
        get { defaults.bool(forKey: "appSourcesEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "appSourcesEnabled") }
    }
    var rules: [AppSourceRule] {
        get {
            guard let data = defaults.data(forKey: "appSources"), let rules = try? JSONDecoder().decode([AppSourceRule].self, from: data) else { return [] }
            return rules
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "appSources") }
    }
    func set(_ rule: AppSourceRule) {
        var list = rules.filter { $0.bundleID != rule.bundleID }
        list.append(rule)
        rules = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func remove(_ bundleID: String) { rules = rules.filter { $0.bundleID != bundleID } }
}

// Only app activation requests a default. Source changes and window changes within the app never request one.
struct AppSourceFocus {
    // The lock screen, and the other Mac under Universal Control, take the front without the user leaving the app.
    static let passing: Set<String> = ["com.apple.loginwindow", universalControlID]
    private(set) var pid: pid_t?
    private(set) var generation = 0
    private var away = false
    private var left: pid_t?
    mutating func activate(_ pid: pid_t, frontmost: pid_t, passing: Bool = false) -> Int? {
        if passing {
            if !away { away = true; left = self.pid }
            generation += 1
            return nil
        }
        guard pid == frontmost else { return nil }
        // Coming back to the app is not a switch to it: the source it was left in stays.
        let back = away && left == pid
        away = false
        self.pid = pid; generation += 1
        return back ? nil : generation
    }
    // The app in front when this starts had no activation to see.
    mutating func begin(_ pid: pid_t?) { if self.pid == nil { self.pid = pid } }
    mutating func cancel() { generation += 1 }
    func accepts(_ generation: Int, pid: pid_t) -> Bool { self.generation == generation && self.pid == pid }
}

extension AppDelegate {
    var appSourceRules: AppSourceRules { AppSourceRules(defaults: engine.defaults) }
    // The sources switching goes between: the managed ones left on, or Korean and English when they are not managed.
    var appSourceChoices: [InputSourceIdentity] {
        engine.addedSourcesEnabled ? activeSources() : enabledSources().filter { isKorean($0) || isEnglish($0) }
    }
    // Secure input does not stop it: the shortcut still switches, and any app can leave secure input on for days.
    var appSourcesActive: Bool {
        appSourceRules.enabled && engine.active && !engine.paused && engine.accessibilityTrusted() && !engine.sessionAway()
    }
    func appSourceActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier, bundle = app.bundleIdentifier
        guard let frontmost = frontmostPID(),
              let generation = appSourceFocus.activate(pid, frontmost: frontmost, passing: bundle.map(AppSourceFocus.passing.contains) ?? false),
              bundle != Bundle.main.bundleIdentifier, let bundle else { return }
        applyAppSource(bundle, pid: pid, generation: generation)
    }
    private func applyAppSource(_ bundle: String, pid: pid_t, generation: Int, from: InputSourceIdentity? = nil, retries: Int = 2) {
        // Rapid A -> B -> A can deliver all three notices after A is already frontmost. Coalesce them before sending
        // a shortcut: two switches sent during activation can toggle back even after the first reports its landing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.appSourceFocus.accepts(generation, pid: pid), self.frontmostPID() == pid, self.appSourcesActive,
                  let rule = self.appSourceRules.rules.first(where: { $0.bundleID == bundle }) else { return }
            self.appSourcesSettings.showError(nil, bundleID: bundle)
            // A source no longer in use waits, shown as such in the app's row.
            guard let target = self.appSourceChoices.first(where: { $0.id == rule.sourceID }) else { return }
            guard let current = from ?? self.logicalSource, current.id != target.id,
                  let pulse = nativeSwitchPulse(keyCode: self.engine.target.keyCode, marker: self.nativePulseMarker) else { return }
            self.cancelLongPress()
            self.rememberCapsBeforeSwitch()
            let attempt = self.landingGeneration
            let switched = self.switchSource(to: target, from: current, pulse: pulse, owner: pid)
            guard !switched, self.frontmostPID() == pid else { return }
            // A click stops a switch that is still selecting its sources, which is not a failure. Clicked within the
            // app, such as the second of a double click, it starts over from the same source, as the selections may
            // be half made. Once the shortcut is sent it is not sent again: one sent to a busy app is still waiting
            // there, and a second would bring the source back.
            if attempt != self.landingGeneration {
                if retries > 0, let again = self.appSourceFocus.activate(pid, frontmost: pid) {
                    self.applyAppSource(bundle, pid: pid, generation: again, from: current, retries: retries - 1)
                }
                return
            }
            self.appSourcesSettings.showError("입력 소스를 전환하지 못했습니다.", bundleID: bundle)
        }
    }
}

private final class AppSourcePicker: NSPopUpButton { var bundleID = "" }

final class AppSourcesSettings: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    unowned let owner: AppDelegate
    let enable = NSButton(checkboxWithTitle: "활성화", target: nil, action: nil)
    let edit = NSButton(title: "앱별 설정", target: nil, action: nil)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
    let table = NSTableView()
    let add = NSButton(title: "+", target: nil, action: nil)
    let remove = NSButton(title: "−", target: nil, action: nil)
    private var errors: [String: String] = [:]
    private var rows: [AppSourceRule] = []
    private var signature = ""
    private var installed = false

    init(owner: AppDelegate) { self.owner = owner; super.init() }
    func install(in panel: NSStackView) {
        enable.target = self; enable.action = #selector(toggle)
        edit.target = self; edit.action = #selector(showSheet); edit.bezelStyle = .rounded
        let section = NSStackView(views: [enable, edit]); section.orientation = .vertical; section.alignment = .leading; section.spacing = 8
        section.setCustomSpacing(10, after: enable)
        panel.addArrangedSubview(section)
        buildSheet(); installed = true; refresh(force: true)
    }
    // The list looks like the keyboards in the advanced settings.
    private func buildSheet() {
        window.title = "앱별 설정"; window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "앱별 설정")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil; table.style = .fullWidth; table.rowHeight = 42; table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false; table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("앱별 입력 소스")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let list = NSBox(); list.boxType = .custom; list.titlePosition = .noTitle
        list.cornerRadius = 7; list.borderWidth = 1; list.borderColor = .separatorColor; list.fillColor = .controlBackgroundColor
        list.contentViewMargins = .zero
        scroll.translatesAutoresizingMaskIntoConstraints = false; list.contentView!.addSubview(scroll)
        add.target = self; add.action = #selector(addApp); add.bezelStyle = .rounded; add.setAccessibilityLabel("앱 추가")
        remove.target = self; remove.action = #selector(removeApp); remove.bezelStyle = .rounded; remove.setAccessibilityLabel("선택한 앱 삭제")
        let buttons = NSStackView(views: [add, remove]); buttons.spacing = 4
        let done = NSButton(title: "완료", target: self, action: #selector(closeSheet)); done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        let content = window.contentView!
        for view in [title, list, buttons, done] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: list.contentView!.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: list.contentView!.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: list.contentView!.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: list.contentView!.bottomAnchor, constant: -1),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            list.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            list.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            list.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -18),
            buttons.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            buttons.centerYAnchor.constraint(equalTo: done.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
    }
    // Repair calls this every second; a hidden window catches up within a second of being shown.
    func refresh(force: Bool = false) {
        guard installed, force || owner.window?.isVisible == true else { return }
        let trusted = owner.engine.accessibilityTrusted()
        let on = owner.appSourceRules.enabled
        enable.state = on ? .on : .off; enable.isEnabled = trusted; edit.isEnabled = trusted && on
        add.isEnabled = trusted
        let rules = owner.appSourceRules.rules
        let signature = "\(rules)\(owner.appSourceChoices.map(\.id))\(errors)\(trusted)"
        if self.signature != signature {
            // The table keeps a selection by row, and a new app can sort in above it.
            let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].bundleID : nil
            self.signature = signature; rows = rules; table.reloadData()
            if let selected { select(selected) }
        }
        remove.isEnabled = trusted && rows.indices.contains(table.selectedRow)
    }
    private func select(_ bundleID: String) {
        guard let row = rows.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    func showError(_ message: String?, bundleID: String) { errors[bundleID] = message; refresh() }
    @objc func toggle() {
        owner.appSourceRules.enabled = enable.state == .on
        owner.appSourceFocus.cancel(); errors.removeAll()
        refresh(force: true)
    }
    @objc func showSheet() { refresh(force: true); owner.window.beginSheet(window) }
    @objc func closeSheet() { owner.window.endSheet(window); window.orderOut(nil) }
    @objc func addApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = "추가"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
            if self.rows.contains(where: { $0.bundleID == id }) { self.select(id); return }
            let choices = self.owner.appSourceChoices
            guard let source = choices.first(where: { $0.id == self.owner.currentSource?.id }) ?? choices.first else { return }
            // As Finder shows it, which is with ".app" when Finder shows all extensions.
            let shown = FileManager.default.displayName(atPath: url.path)
            let name = shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
            self.owner.appSourceRules.set(AppSourceRule(bundleID: id, name: name, sourceID: source.id))
            self.refresh(force: true); self.select(id)
        }
    }
    @objc func removeApp() {
        guard rows.indices.contains(table.selectedRow) else { return }
        let id = rows[table.selectedRow].bundleID
        owner.appSourceRules.remove(id); errors[id] = nil; owner.appSourceFocus.cancel(); refresh(force: true)
    }
    @objc private func changeSource(_ sender: AppSourcePicker) {
        guard let id = sender.selectedItem?.representedObject as? String,
              var rule = rows.first(where: { $0.bundleID == sender.bundleID }) else { return }
        rule.sourceID = id; owner.appSourceRules.set(rule)
        errors[rule.bundleID] = nil; owner.appSourceFocus.cancel(); refresh(force: true)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { remove.isEnabled = owner.engine.accessibilityTrusted() && rows.indices.contains(table.selectedRow) }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let rule = rows[row], cell = NSTableCellView()
        let name = NSTextField(labelWithString: rule.name); name.font = .systemFont(ofSize: 12); name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); name.toolTip = rule.bundleID
        cell.textField = name
        let labels = NSStackView(views: [name]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 1
        if let error = errors[rule.bundleID] {
            let warning = NSTextField(labelWithString: error); warning.font = .systemFont(ofSize: 10); warning.textColor = .systemOrange
            warning.lineBreakMode = .byTruncatingTail; warning.toolTip = error; labels.addArrangedSubview(warning)
        }
        let picker = AppSourcePicker(); picker.bundleID = rule.bundleID
        // Without this the menu enables the item again as it opens.
        picker.autoenablesItems = false
        picker.controlSize = .small; picker.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        let sources = owner.appSourceChoices
        for source in sources {
            picker.addItem(withTitle: AppDelegate.sourceTitle(source.id)); picker.lastItem?.representedObject = source.id
        }
        // Chosen earlier and no longer in use: kept, and applied again once it is back.
        if !sources.contains(where: { $0.id == rule.sourceID }) {
            picker.addItem(withTitle: "\(AppDelegate.sourceTitle(rule.sourceID))(비활성)"); picker.lastItem?.representedObject = rule.sourceID; picker.lastItem?.isEnabled = false
        }
        picker.select(picker.itemArray.first { $0.representedObject as? String == rule.sourceID })
        picker.target = self; picker.action = #selector(changeSource(_:)); picker.isEnabled = owner.engine.accessibilityTrusted()
        picker.setAccessibilityLabel("\(rule.name) 입력 소스")
        for view in [labels, picker] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12), labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: picker.leadingAnchor, constant: -16),
            picker.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12), picker.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            picker.widthAnchor.constraint(equalToConstant: 200)
        ])
        return cell
    }
}

#if TESTS
func runAppSourceTests() {
    let name = "io.gksdud.app-source-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let rules = AppSourceRules(defaults: defaults)
    precondition(!rules.enabled && rules.rules.isEmpty)
    let blender = AppSourceRule(bundleID: "org.blenderfoundation.blender", name: "Blender", sourceID: "com.apple.keylayout.ABC")
    rules.set(blender); rules.enabled = true
    let reloaded = AppSourceRules(defaults: UserDefaults(suiteName: name)!)
    precondition(reloaded.enabled && reloaded.rules == [blender], "Rules and activation survive restart")
    var changed = blender; changed.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
    rules.set(changed)
    precondition(rules.rules == [changed], "A new choice updates the app instead of adding a duplicate")
    rules.set(AppSourceRule(bundleID: "com.example.Removed", name: "Removed", sourceID: "com.example.DisabledSource"))
    precondition(rules.rules.count == 2, "Unavailable apps and input sources retain their rules")
    rules.remove(blender.bundleID)
    precondition(rules.rules.count == 1 && rules.rules[0].bundleID == "com.example.Removed")
    defaults.set(Data("bad-data".utf8), forKey: "appSources")
    precondition(rules.rules.isEmpty, "Malformed saved rules do not crash or select a source")

    var focus = AppSourceFocus()
    var first = focus.activate(101, frontmost: 101)!
    precondition(focus.accepts(first, pid: 101))
    let repeated = focus.activate(101, frontmost: 101)!
    precondition(!focus.accepts(first, pid: 101) && focus.accepts(repeated, pid: 101),
        "A reentry still applies when the intervening app's notice arrived after it lost focus")
    first = repeated
    precondition(focus.activate(102, frontmost: 101) == nil && focus.accepts(first, pid: 101), "A late notice for an app no longer focused cannot cancel the current request")
    let next = focus.activate(102, frontmost: 102)!
    precondition(!focus.accepts(first, pid: 101) && focus.accepts(next, pid: 102), "Moving even to an unregistered app invalidates the old request")
    let returned = focus.activate(101, frontmost: 101)!
    precondition(!focus.accepts(first, pid: 101) && focus.accepts(returned, pid: 101), "A -> B -> A must not revive A's first request")
    focus.cancel()
    precondition(!focus.accepts(returned, pid: 101), "Disabling or changing a rule cancels its scheduled application")
    let entered = focus.activate(101, frontmost: 101)!
    precondition(focus.activate(55, frontmost: 55, passing: true) == nil && !focus.accepts(entered, pid: 101), "Locking drops a request on its way")
    precondition(focus.activate(101, frontmost: 101) == nil, "Unlocking returns to the app without asking for its source again")
    precondition(focus.activate(101, frontmost: 101) != nil, "The next entry asks as usual")
    _ = focus.activate(55, frontmost: 101, passing: true)
    precondition(focus.activate(102, frontmost: 102) != nil, "Another app after the lock screen is a switch to it")
    var started = AppSourceFocus()
    started.begin(101)
    _ = started.activate(55, frontmost: 55, passing: true)
    precondition(started.activate(101, frontmost: 101) == nil, "Unlocked into the app that was in front before this one started")
    _ = started.activate(55, frontmost: 55, passing: true)
    precondition(started.activate(102, frontmost: 102) != nil, "The app in front was quit from the Force Quit window: the next one is a switch to it")
    var unknown = AppSourceFocus()
    _ = unknown.activate(55, frontmost: 55, passing: true)
    precondition(unknown.activate(101, frontmost: 101) != nil, "With no app known to have been in front, there is none to come back to")

    let engine = Engine(defaults: defaults, discover: { [] })
    engine.accessibilityTrusted = { true }; engine.sessionAway = { false }
    let delegate = AppDelegate(engine: engine)
    defaults.set(false, forKey: "active")
    precondition(!delegate.appSourcesActive)
    rules.enabled = true; defaults.set(true, forKey: "active")
    precondition(delegate.appSourcesActive)
    engine.paused = true; precondition(!delegate.appSourcesActive); engine.paused = false
    engine.sessionAway = { true }; precondition(!delegate.appSourcesActive); engine.sessionAway = { false }
    engine.accessibilityTrusted = { false }; precondition(!delegate.appSourcesActive); engine.accessibilityTrusted = { true }
    // A switch made by hand, or the tap going away, drops the app's source on its way.
    var waiting = delegate.appSourceFocus.activate(7, frontmost: 7)!
    delegate.rememberCapsBeforeSwitch()
    precondition(!delegate.appSourceFocus.accepts(waiting, pid: 7))
    waiting = delegate.appSourceFocus.activate(7, frontmost: 7)!
    delegate.stopKeyTap()
    precondition(!delegate.appSourceFocus.accepts(waiting, pid: 7))
    // An app's source is chosen among Korean and English, or with the sources managed, among the ones left on.
    let korean = InputSourceIdentity(id: "com.apple.inputmethod.Korean.2SetKorean", language: "ko"),
        abc = InputSourceIdentity(id: "com.apple.keylayout.ABC", language: "en"),
        japanese = InputSourceIdentity(id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", language: "ja")
    delegate.sourceCache = (list: [korean, abc, japanese], layouts: [abc.id])
    precondition(delegate.appSourceChoices.map(\.id) == [korean.id, abc.id])
    defaults.set(true, forKey: "addedSources"); engine.disabledSources = [abc.id]
    precondition(delegate.appSourceChoices.map(\.id) == [korean.id, japanese.id])
    print("PASS: app source rule persistence, replacement and removal, unavailable sources, focus reentry, stale activation cancellation, the lock screen, pause/permission/session guards, the sources offered")
}
#endif
