import AppKit
import Carbon

// Input sources beside Korean and English. The Korean/English key goes round a list (cycle), or a key of its own
// goes to one more source and back (separate). Either way only the system shortcut switches.
enum AddedSourceMode: Int { case cycle, separate }

func isKorean(_ source: InputSourceIdentity) -> Bool { source.language.hasPrefix("ko") }
func isEnglish(_ source: InputSourceIdentity) -> Bool { source.language.hasPrefix("en") }

// Recently selected input sources, most recent first: the second is where the system shortcut goes.
struct SourceHistory {
    private(set) var ids: [String] = []
    init(_ ids: [String] = []) { self.ids = ids }
    // Unknown unless the first entry is the current source.
    func previous(of current: String) -> String? { ids.first == current && ids.count > 1 ? ids[1] : nil }
    mutating func note(_ id: String) {
        ids.removeAll { $0 == id }; ids.insert(id, at: 0)
        if ids.count > 16 { ids.removeLast() }
    }
    // Falls back to the first candidate, in the order macOS lists them.
    func mostRecent(_ candidates: [InputSourceIdentity]) -> InputSourceIdentity? {
        ids.lazy.compactMap { id in candidates.first { $0.id == id } }.first ?? candidates.first
    }
}

// With added sources, this app's own selections notify too, so a notification for the source already handled is skipped.
// Sources are noted while they are off as well: the first notification after they turn on is not taken for a repeat.
struct SourceNotifications {
    private(set) var last: String?
    mutating func handles(_ id: String?, addedSources: Bool) -> Bool {
        defer { last = id }
        return !addedSources || id != last
    }
}

// macOS keeps its recent sources in its preferences, naming an input mode, an input method or a keyboard layout.
// An entry that matches no enabled source ends the list, since the entries after it would be out of place.
struct SourceInfo { let id: String; let mode: String?; let bundle: String?; let layout: Bool }
func systemHistory(_ entries: [[String: Any]], sources: [SourceInfo]) -> [String] {
    func letters(_ text: Substring) -> String { text.filter { $0.isLetter || $0.isNumber } }
    var ids: [String] = []
    for entry in entries {
        let bundle = entry["Bundle ID"] as? String
        let match: SourceInfo?
        if let mode = entry["Input Mode"] as? String { match = sources.first { $0.mode == mode && $0.bundle == bundle } }
        else if let name = entry["KeyboardLayout Name"] as? String {
            match = sources.first { $0.layout && $0.id.split(separator: ".").last.map(letters) == letters(Substring(name)) }
        } else { match = sources.first { !$0.layout && $0.mode == nil && $0.bundle == bundle } }
        guard let match else { break }
        ids.append(match.id)
    }
    return ids
}

// What is selected from the background before the system shortcut switches, and whether that can cost the syllable in
// progress. A keyboard layout selected from the background reaches the frontmost app as soon as it looks, dropping an
// input method's composition, while an input method does not reach it at all. So the shortcut alone goes from an input
// method to a layout, which needs that layout as its previous source; it is set up on the way into the input method.
// `next` is where the Korean/English key goes from the target.
struct SwitchPlan: Equatable { var selections: [String]; var risky: Bool }
func switchPlan(current: InputSourceIdentity, target: InputSourceIdentity, next: String?, previous: String?,
                isLayout: (String) -> Bool) -> SwitchPlan {
    // Selected last, it becomes the shortcut's previous source once the switch lands.
    let wanted = next.flatMap { !isLayout(target.id) && isLayout($0) && $0 != current.id ? $0 : nil } ?? current.id
    func plan(_ last: String) -> [String] { previous == target.id && last == current.id ? [] : [target.id, last] }
    func risky(_ ids: [String]) -> Bool { !isLayout(current.id) && ids.contains { $0 != current.id && isLayout($0) } }
    var selections = plan(wanted)
    // Korean keeps its syllable; the layout after the target waits.
    if risky(selections) && isKorean(current) { selections = plan(current.id) }
    return SwitchPlan(selections: selections, risky: risky(selections))
}
// When a switch is due and macOS still shows where it started, its target layout is selected again. Once it has landed,
// a return there is chosen afterwards and stays.
func reselectsTarget(landed: Bool, current: String?, origin: String, targetIsLayout: Bool) -> Bool {
    !landed && current == origin && targetIsLayout
}
// Back to back, the first of two selections can be lost while a third-party input method such as WeChat's is current or
// selected, and the shortcut then goes to an older source. Apple's need no wait; compatibility mode waits for any.
func waitsBetweenSelections(bundles: [String?], always: Bool) -> Bool {
    always || bundles.contains { $0.map { !$0.hasPrefix("com.apple.") } ?? false }
}

// The badge of an input source other than Korean or English: its language code of up to three letters, or without one
// its place among the sources, up to 10. Past that the badge stays empty.
func sourceBadgeLabel(_ language: String, position: Int?) -> String {
    let code = language.prefix { $0 != "-" && $0 != "_" }
    if (2...3).contains(code.count) && code.allSatisfy({ $0.isASCII && $0.isLetter }) { return code.uppercased() }
    return position.flatMap { (1...10).contains($0) ? String($0) : nil } ?? ""
}

// Korean first, then English, then the rest in the order macOS lists them.
func defaultCycle(_ enabled: [InputSourceIdentity]) -> [String] {
    (enabled.filter(isKorean) + enabled.filter(isEnglish) + enabled.filter { !isKorean($0) && !isEnglish($0) }).map(\.id)
}

// Where a switch goes; nil leaves it to the system shortcut alone. `enabled` are the sources macOS offers now,
// so saved ones that are gone are skipped.
func addedSourceTarget(separateKey: Bool, current: InputSourceIdentity, mode: AddedSourceMode, cycle: [String],
                       separate: String?, enabled: [InputSourceIdentity], history: SourceHistory) -> InputSourceIdentity? {
    let hangul = enabled.filter { isKorean($0) || isEnglish($0) }
    switch mode {
    case .cycle:
        guard !separateKey else { return nil }
        let members = cycle.compactMap { id in enabled.first { $0.id == id } }
        guard members.count > 1 else { return nil }
        // Another layout of a listed language takes that one's place; from elsewhere the list resumes where it was left.
        let exact = members.firstIndex { $0.id == current.id }
        guard let index = exact ?? members.firstIndex(where: { $0.language == current.language }) else { return history.mostRecent(members) }
        return members[(index + 1) % members.count]
    case .separate:
        let foreign = separate.flatMap { id in enabled.first { $0.id == id } }
        if separateKey {
            guard let foreign else { return nil }
            return current.id == foreign.id ? history.mostRecent(hangul) : foreign
        }
        if isKorean(current) { return history.mostRecent(enabled.filter(isEnglish)) }
        if isEnglish(current) { return history.mostRecent(enabled.filter(isKorean)) }
        return history.mostRecent(hangul)
    }
}

extension AppDelegate {
    var addedSourcesActive: Bool { engine.active && !engine.paused && engine.addedSourcesEnabled && engine.accessibilityTrusted() }
    var separateKeyActive: Bool { addedSourcesActive && engine.addedSourceMode == .separate }
    // The tap takes the separate key's F-key only while the separate key is mapped to it. When another mapping already
    // sends that F-key, the separate key is not applied and its presses stay that mapping's.
    func takesSeparateKey(_ code: Int64) -> Bool {
        if separateGate.held.contains(code) { return true }
        guard code == Int64(engine.separateTarget.keyCode), separateKeyActive, let key = engine.separateKey, sources.contains(key) else { return false }
        return engine.keyboards.result.extraBlocked == 0
    }
    // The separate key when it is a Space combination. A Korean/English combination wins over it.
    var separateCombo: UInt64? {
        guard separateKeyActive, let key = engine.separateKey, spaceCombos.contains(key), !engine.chosenCombos.contains(key) else { return nil }
        return key
    }
    // Keyboard input sources macOS offers now, in its order. Read again when macOS reports a change, not on every key.
    func enabledSources() -> [InputSourceIdentity] { loadSources().list }
    private func loadSources() -> (list: [InputSourceIdentity], layouts: Set<String>) {
        if let sourceCache { return sourceCache }
        let filter = [kTISPropertyInputSourceIsEnabled as String: true, kTISPropertyInputSourceIsSelectCapable as String: true,
                      kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        var list: [InputSourceIdentity] = [], layouts: Set<String> = []
        for source in TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? [] {
            guard let identity = Self.sourceIdentity(source) else { continue }
            list.append(identity)
            if let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType),
               Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String == kTISTypeKeyboardLayout as String { layouts.insert(identity.id) }
        }
        sourceCache = (list, layouts)
        return (list, layouts)
    }
    func isLayout(_ id: String) -> Bool {
        let sources = loadSources()
        return sources.list.contains { $0.id == id } ? sources.layouts.contains(id) : Self.isLayout(id)
    }
    // Where switching is headed: a switch waiting for the one on its way, or that one until it lands.
    var logicalSource: InputSourceIdentity? {
        if let target = queuedSwitch?.target { return target }
        if let id = switchLanding, let source = enabledSources().first(where: { $0.id == id }) { return source }
        return currentSource
    }
    var cycleOrder: [String] { engine.cycleSources ?? defaultCycle(enabledSources()) }
    func addedTarget(separateKey: Bool, from current: InputSourceIdentity) -> InputSourceIdentity? {
        addedSourceTarget(separateKey: separateKey, current: current, mode: engine.addedSourceMode, cycle: cycleOrder,
                          separate: engine.separateSource, enabled: enabledSources(), history: sourceHistory)
    }
    // The Korean/English key. Without added input sources it sends the system shortcut alone, as before.
    func switchHangul(_ pulse: (CGEvent, CGEvent)) {
        guard addedSourcesActive, let current = logicalSource, let target = addedTarget(separateKey: false, from: current) else {
            postSwitchPulse(pulse); return
        }
        switchSource(to: target, from: current, pulse: pulse)
    }
    // False when there is nothing to switch with, so a Space goes back to the app.
    func switchSeparate() -> Bool {
        guard separateKeyActive, let current = logicalSource, let target = addedTarget(separateKey: true, from: current),
              let pulse = nativeSwitchPulse(keyCode: engine.target.keyCode, marker: nativePulseMarker) else { return false }
        rememberCapsBeforeSwitch()
        switchSource(to: target, from: current, pulse: pulse)
        return true
    }
    func switchToEnglish(_ pulse: (CGEvent, CGEvent)) -> Bool {
        guard let current = logicalSource, let english = sourceHistory.mostRecent(enabledSources().filter(isEnglish)) else { return false }
        switchSource(to: english, from: current, pulse: pulse)
        return true
    }
    static func isLayout(_ id: String) -> Bool {
        guard let source = sourceForID(id), let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        return Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String == kTISTypeKeyboardLayout as String
    }
    static func bundleID(_ id: String) -> String? {
        sourceForID(id).flatMap { TISGetInputSourceProperty($0, kTISPropertyBundleID) }.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }
    func plannedSwitch(to target: InputSourceIdentity, from current: InputSourceIdentity) -> SwitchPlan {
        var landed = sourceHistory; landed.note(current.id); landed.note(target.id)
        // A command can switch without added sources, when the Korean/English key goes between Korean and English as a
        // separate key's sources do.
        let added = addedSourcesActive
        let next = addedSourceTarget(separateKey: false, current: target, mode: added ? engine.addedSourceMode : .separate, cycle: cycleOrder,
                                     separate: added ? engine.separateSource : nil, enabled: enabledSources(), history: landed)
        return switchPlan(current: current, target: target, next: next?.id, previous: sourceHistory.previous(of: current.id), isLayout: isLayout)
    }
    // Only the system shortcut switches, as without added sources. Sources selected from here first only set where it goes.
    // Pressed again before a switch lands, `current` is where it is headed: the shortcut alone follows it at once, but
    // selections would reorder the recent sources under it, so that switch waits for it to land. Only the last one waits.
    func switchSource(to target: InputSourceIdentity, from current: InputSourceIdentity, pulse: (CGEvent, CGEvent)) {
        if let landing = switchLanding {
            if target.id == landing { queuedSwitch = nil; return }
            guard queuedSwitch == nil, plannedSwitch(to: target, from: current).selections.isEmpty else {
                queuedSwitch = (target, pulse); holdKeys = true; return
            }
            postSwitchPulse(pulse)
            sourceHistory.note(target.id)
            expectLanding(target, origin: current.id)
            return
        }
        guard target.id != current.id else { return }
        let plan = plannedSwitch(to: target, from: current)
        let waits = plan.selections.count > 1
            && waitsBetweenSelections(bundles: ([current.id] + plan.selections).map(Self.bundleID), always: engine.addedSourcesCompatible)
        var failed = false
        for (index, id) in plan.selections.enumerated() {
            if index > 0 && waits { usleep(50_000) }
            guard let source = Self.sourceForID(id), TISSelectInputSource(source) == noErr else { failed = true; break }
            sourceHistory.note(id)
        }
        addedSources.showError(failed ? "입력 소스를 전환하지 못했습니다." : nil)
        // The frontmost app can see the selections before the shortcut's switch reaches it.
        if !plan.selections.isEmpty { holdKeys = true }
        postSwitchPulse(pulse)
        // Where it lands, as long as the shortcut switches.
        sourceHistory.note(target.id)
        expectLanding(target, origin: plan.selections.last ?? current.id)
    }
    // Until the switch lands the icon keeps showing where it started, not the sources selected on the way. If the shortcut
    // does not switch, a layout selected on the way may already have reached the frontmost app while macOS shows another
    // source; selecting the target layout makes them agree.
    func expectLanding(_ target: InputSourceIdentity, origin: String) {
        switchLanding = target.id
        landingGeneration += 1
        let generation = landingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.landingGeneration == generation else { return }
            let landed = self.switchLanding == nil
            self.switchLanding = nil
            if reselectsTarget(landed: landed, current: self.currentSource?.id, origin: origin, targetIsLayout: self.isLayout(target.id)),
               let source = Self.sourceForID(target.id) { _ = TISSelectInputSource(source) }
            self.updateInputIndicator()
            self.runQueuedSwitch()
        }
    }
    // The switch that waited for the last one to land; once none is on its way, the keys held meanwhile go on. macOS
    // reports the switch a moment before the frontmost app's input method is ready, so they wait a little longer.
    func runQueuedSwitch() {
        if let queued = queuedSwitch {
            queuedSwitch = nil
            if let current = currentSource { switchSource(to: queued.target, from: current, pulse: queued.pulse) }
        }
        guard switchLanding == nil, holdKeys else { return }
        let generation = landingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, self.landingGeneration == generation, self.switchLanding == nil else { return }
            self.releaseHeldKeys()
        }
    }
    // Bounded: past it the keys go on in whatever source is current.
    func holdKey(_ event: CGEvent) {
        if let copy = event.copy() { heldKeys.append(copy) }
        if heldKeys.count >= 128 { releaseHeldKeys() }
    }
    // In order, marked so the tap lets them through.
    func releaseHeldKeys() {
        holdKeys = false
        let keys = heldKeys
        heldKeys = []
        for key in keys { key.setIntegerValueField(.eventSourceUserData, value: nativePulseMarker); key.post(tap: .cghidEventTap) }
    }
    // The recent sources macOS keeps, as far as they are known; otherwise only the current one.
    func seedSourceHistory() {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        let entries = CFPreferencesCopyAppValue("AppleInputSourceHistory" as CFString, domain) as? [[String: Any]] ?? []
        let filter = [kTISPropertyInputSourceIsEnabled as String: true, kTISPropertyInputSourceIsSelectCapable as String: true,
                      kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        let infos = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []).compactMap { source -> SourceInfo? in
            func text(_ key: CFString) -> String? { TISGetInputSourceProperty(source, key).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } }
            guard let id = text(kTISPropertyInputSourceID) else { return nil }
            return SourceInfo(id: id, mode: text(kTISPropertyInputModeID), bundle: text(kTISPropertyBundleID),
                              layout: text(kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String)
        }
        let ids = systemHistory(entries, sources: infos), current = currentSource?.id
        sourceHistory = SourceHistory(ids.first == current ? ids : current.map { [$0] } ?? [])
    }
    func sourceIcon(_ source: InputSourceIdentity) -> NSImage {
        isKorean(source) || isEnglish(source) ? sourceMenuIcon(korean: isKorean(source))
            : badgeImage(label: sourceBadgeLabel(source.language, position: sourcePosition(source.id)), filled: false)
    }
    // Counted in the cycle's order, which starts as Korean, English, then the rest; a source outside it follows that
    // default order.
    func sourcePosition(_ id: String) -> Int? {
        if let index = cycleOrder.firstIndex(of: id) { return index + 1 }
        return defaultCycle(enabledSources()).firstIndex(of: id).map { $0 + 1 }
    }
    static func sourceTitle(_ id: String) -> String {
        let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource]
        return list?.first.flatMap { TISGetInputSourceProperty($0, kTISPropertyLocalizedName) }
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? id
    }
    // The menu lists the added sources after Korean and English.
    var menuSources: [InputSourceIdentity] {
        guard engine.addedSourcesEnabled else { return [] }
        let enabled = enabledSources()
        let ids = engine.addedSourceMode == .cycle ? cycleOrder : engine.separateSource.map { [$0] } ?? []
        return ids.compactMap { id in enabled.first { $0.id == id } }.filter { !isKorean($0) && !isEnglish($0) }
    }
    func refreshAddedMenuItems(_ menu: NSMenu) {
        for entry in menu.items where entry.action == #selector(selectAddedSource(_:)) { menu.removeItem(entry) }
        guard let english = menu.items.firstIndex(where: { $0.action == #selector(selectEnglish) }) else { return }
        for (offset, source) in menuSources.enumerated() {
            let entry = NSMenuItem(title: Self.sourceTitle(source.id), action: #selector(selectAddedSource(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = source.id; entry.image = sourceIcon(source)
            menu.insertItem(entry, at: english + 1 + offset)
        }
    }
    @objc func selectAddedSource(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let source = Self.sourceForID(id) { rememberCapsBeforeSwitch(); _ = TISSelectInputSource(source) }
        updateInputIndicator()
    }
    func addedSourcesChanged() {
        cancelLongPress(); sourceCache = nil; seedSourceHistory(); engine.refreshSystemFKeys()
        ensureKeyTap(); repair()
        releaseKoreanCapsLock()
        addedSources.refresh(force: true)
        updateInputIndicator()
    }
    // A Korean/English key can also be the separate key; it stays a Korean/English key once confirmed. False keeps the old keys.
    func confirmSeparateKey(_ keys: [UInt64]? = nil) -> Bool {
        guard engine.usesSeparateKey, let key = engine.separateKey, engine.separateKeyIsHangulKey(keys) else { return true }
        let alert = NSAlert(); alert.messageText = "\(sourceName(key))은 입력 소스 추가의 전환 키입니다."
        alert.informativeText = "한영 키로 바꾸면 전환 키가 해제됩니다."
        alert.addButton(withTitle: "변경"); alert.addButton(withTitle: "취소")
        return runAlert(alert) == .alertFirstButtonReturn
    }
    // Only once the key is saved as a Korean/English key, so a later warning that cancels the change keeps it.
    func releaseSeparateKey() {
        guard engine.usesSeparateKey, engine.separateKeyIsHangulKey() else { return }
        engine.separateKey = nil
        addedSources.refresh(force: true)
    }
}

// The 입력 소스 추가 section of the extras tab.
final class AddedSourcesSettings: NSObject {
    unowned let owner: AppDelegate
    private var engine: Engine { owner.engine }
    let enable = NSButton(checkboxWithTitle: "활성화", target: nil, action: nil)
    let compatible = NSButton(checkboxWithTitle: "호환성 모드", target: nil, action: nil)
    let modePicker = NSPopUpButton()
    let keyPicker = NSPopUpButton()
    let sourcePicker = NSPopUpButton()
    let addPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    let list = NSStackView()
    let warning = NSTextField(wrappingLabelWithString: "")
    private let cycleRows = NSStackView(), separateRows = NSStackView()
    private var labels: [NSTextField] = []
    private var signature = ""
    private var error: String?
    static let rowHeight: CGFloat = 26

    init(owner: AppDelegate) { self.owner = owner; super.init() }

    // One view in the panel, so the spacing after it does not depend on which rows are hidden.
    // Rows follow the settings window: a 95-point title, then the control.
    func install(in panel: NSStackView) {
        func row(_ title: String, _ view: NSView, top: Bool = false) -> NSStackView {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 95).isActive = true
            labels.append(label)
            let row = NSStackView(views: [label, view]); row.spacing = 16; row.alignment = top ? .top : .centerY
            return row
        }
        let section = NSStackView(); section.orientation = .vertical; section.alignment = .leading; section.spacing = 12
        enable.target = self; enable.action = #selector(toggle)
        modePicker.addItems(withTitles: ["순회", "분리"])
        modePicker.item(at: 0)?.toolTip = "한영 키로 목록 순서대로 전환합니다."
        modePicker.item(at: 1)?.toolTip = "전환 키로 선택한 입력 소스와 한/영 사이를 전환합니다."
        modePicker.target = self; modePicker.action = #selector(changeMode)
        let box = NSBox(); box.boxType = .custom; box.titlePosition = .noTitle
        box.cornerRadius = 6; box.borderWidth = 1; box.borderColor = .separatorColor; box.fillColor = .controlBackgroundColor
        box.contentViewMargins = NSSize(width: 0, height: 2)
        list.orientation = .vertical; list.spacing = 0; list.alignment = .leading
        list.translatesAutoresizingMaskIntoConstraints = false
        box.contentView!.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor), list.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor),
            list.topAnchor.constraint(equalTo: box.contentView!.topAnchor), list.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: 224)
        ])
        box.setAccessibilityLabel("순회 순서")
        addPicker.addItem(withTitle: "추가"); addPicker.target = self; addPicker.action = #selector(add)
        addPicker.setAccessibilityLabel("순회할 입력 소스 추가")
        cycleRows.orientation = .vertical; cycleRows.alignment = .leading; cycleRows.spacing = 8
        cycleRows.addArrangedSubview(row("순서", box, top: true))
        cycleRows.addArrangedSubview(row("", addPicker))
        keyPicker.target = self; keyPicker.action = #selector(changeKey); keyPicker.setAccessibilityLabel("전환 키")
        sourcePicker.target = self; sourcePicker.action = #selector(changeSource); sourcePicker.setAccessibilityLabel("전환할 입력 소스")
        separateRows.orientation = .vertical; separateRows.alignment = .leading; separateRows.spacing = 12
        separateRows.addArrangedSubview(row("전환 키", keyPicker))
        separateRows.addArrangedSubview(row("입력 소스", sourcePicker))
        warning.font = .systemFont(ofSize: 11); warning.textColor = .systemOrange
        compatible.target = self; compatible.action = #selector(toggleCompatible)
        compatible.toolTip = "WeChat 입력기 등 서드파티 입력기 사용 중 전환이 다른 입력 소스로 가면 켜주세요."
        for view in [enable, row("전환 방식", modePicker), cycleRows, separateRows, row("", compatible), warning] { section.addArrangedSubview(view) }
        warning.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        panel.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        refresh(force: true)
    }
    // Shown until the next switch succeeds; typing focus stays where it is.
    func showError(_ message: String?) {
        guard error != message else { return }
        error = message; refresh(force: true)
    }
    // Repair calls this every second, so the rows are rebuilt only when something they show changed.
    func refresh(force: Bool = false) {
        guard force || owner.window?.isVisible == true else { return }
        let trusted = engine.accessibilityTrusted(), on = engine.addedSourcesEnabled, enabled = owner.enabledSources()
        let cycle = owner.cycleOrder
        // Built in steps: as one literal it exceeds the type-checker time limit on older Swift (macos-15 CI).
        var parts: [String] = [String(trusted), String(on), String(engine.addedSourceMode.rawValue), cycle.joined(separator: ",")]
        let separateKey: String = engine.separateKey.map { String($0) } ?? ""
        parts += [engine.separateSource ?? "", separateKey, enabled.map(\.id).joined(separator: ",")]
        parts += [String(engine.separateKeyIsHangulKey()), String(engine.keyboards.result.extraBlocked), String(owner.iconStyle), error ?? ""]
        parts += [String(engine.addedSourcesCompatible)]
        let state = parts.joined(separator: "|")
        guard force || state != signature else { return }
        signature = state
        enable.state = on ? .on : .off
        enable.isEnabled = trusted
        enable.toolTip = trusted ? nil : accessibilityHint
        let usable = trusted && on
        for label in labels { label.textColor = usable ? .labelColor : .disabledControlTextColor }
        modePicker.selectItem(at: engine.addedSourceMode.rawValue)
        cycleRows.isHidden = engine.addedSourceMode != .cycle
        separateRows.isHidden = engine.addedSourceMode != .separate
        // Cycle: the saved order, with sources macOS no longer offers dimmed.
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, id) in cycle.enumerated() {
            let source = enabled.first { $0.id == id }
            list.addArrangedSubview(cycleRow(id, source: source, index: index, count: cycle.count, usable: usable))
        }
        addPicker.removeAllItems(); addPicker.addItem(withTitle: "추가")
        for source in enabled where !cycle.contains(source.id) {
            addPicker.addItem(withTitle: AppDelegate.sourceTitle(source.id))
            addPicker.lastItem?.representedObject = source.id; addPicker.lastItem?.image = owner.sourceIcon(source)
        }
        // Separate: one key and one input source that is neither Korean nor English.
        keyPicker.removeAllItems(); keyPicker.addItem(withTitle: "선택 안 함")
        for key in hangulKeys {
            if key == spaceCombos.first { keyPicker.menu?.addItem(.separator()) }
            keyPicker.addItem(withTitle: sourceName(key)); keyPicker.lastItem?.representedObject = NSNumber(value: key)
        }
        if let key = engine.separateKey { keyPicker.selectItem(withTitle: sourceName(key)) } else { keyPicker.selectItem(at: 0) }
        sourcePicker.removeAllItems(); sourcePicker.addItem(withTitle: "선택 안 함")
        let foreign = enabled.filter { !isKorean($0) && !isEnglish($0) }
        for source in foreign {
            sourcePicker.addItem(withTitle: AppDelegate.sourceTitle(source.id))
            sourcePicker.lastItem?.representedObject = source.id; sourcePicker.lastItem?.image = owner.sourceIcon(source)
        }
        if let id = engine.separateSource, !foreign.contains(where: { $0.id == id }) {
            // Saved, but macOS no longer offers it.
            sourcePicker.addItem(withTitle: AppDelegate.sourceTitle(id)); sourcePicker.lastItem?.representedObject = id
            sourcePicker.lastItem?.isEnabled = false
        }
        let saved = engine.separateSource.flatMap { id in sourcePicker.itemArray.first { $0.representedObject as? String == id } }
        if let saved { sourcePicker.select(saved) } else { sourcePicker.selectItem(at: 0) }
        sourcePicker.autoenablesItems = false; keyPicker.autoenablesItems = false
        compatible.state = engine.addedSourcesCompatible ? .on : .off
        for control in [modePicker, keyPicker, sourcePicker, compatible] { control.isEnabled = usable }
        addPicker.isEnabled = usable && addPicker.numberOfItems > 1
        // Only states the user has to act on.
        let members = cycle.filter { id in enabled.contains { $0.id == id } }
        warning.stringValue = !usable ? "" : error ?? (engine.addedSourceMode == .cycle
            ? (members.count < 2 ? "순회할 입력 소스를 2개 이상 선택해주세요." : "")
            : engine.separateKeyIsHangulKey() ? "전환 키가 한영 키와 겹칩니다. 다른 키를 선택해주세요."
            : engine.separateSource.map { id in !foreign.contains { $0.id == id } } == true ? "선택한 입력 소스를 사용할 수 없습니다. 시스템 설정에서 추가해주세요."
            : engine.keyboards.result.extraBlocked > 0 ? "\(engine.separateTarget.name)이 다른 키 매핑에서 사용 중이라 전환 키를 적용하지 못했습니다." : "")
        warning.isHidden = warning.stringValue.isEmpty
    }
    private func cycleRow(_ id: String, source: InputSourceIdentity?, index: Int, count: Int, usable: Bool) -> NSView {
        let icon = NSImageView(image: source.map(owner.sourceIcon) ?? owner.badgeImage(label: sourceBadgeLabel("", position: index + 1), filled: false))
        icon.contentTintColor = source == nil || !usable ? .disabledControlTextColor : .labelColor
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true; icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let name = NSTextField(labelWithString: AppDelegate.sourceTitle(id))
        name.lineBreakMode = .byTruncatingTail; name.textColor = source == nil || !usable ? .disabledControlTextColor : .labelColor
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); name.toolTip = name.stringValue
        func button(_ symbol: String, _ label: String, _ action: Selector, enabled: Bool) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
            button.isBordered = false; button.tag = index; button.isEnabled = usable && enabled
            button.setAccessibilityLabel("\(name.stringValue) \(label)")
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            return button
        }
        let row = NSStackView(views: [icon, name, NSView(),
            button("chevron.up", "위로", #selector(moveUp(_:)), enabled: index > 0),
            button("chevron.down", "아래로", #selector(moveDown(_:)), enabled: index < count - 1),
            button("minus.circle", "삭제", #selector(remove(_:)), enabled: count > 2)])
        row.spacing = 6; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        row.widthAnchor.constraint(equalToConstant: 224).isActive = true
        return row
    }
    private func save(_ change: () -> Void) { change(); owner.addedSourcesChanged() }
    @objc func toggleCompatible() { save { engine.defaults.set(compatible.state == .on, forKey: "addedSourcesCompatibility") } }
    @objc func toggle() {
        if enable.state == .on, engine.addedSourceMode == .separate, let key = engine.separateKey, !confirmKey(key) { refresh(force: true); return }
        save { engine.defaults.set(enable.state == .on, forKey: "addedSources") }
    }
    @objc func changeMode() {
        let mode = AddedSourceMode(rawValue: modePicker.indexOfSelectedItem) ?? .cycle
        // The separate key takes a key away from the keyboard, so the same warnings as choosing it apply.
        if mode == .separate, let key = engine.separateKey, !confirmKey(key) { refresh(force: true); return }
        save { engine.defaults.set(mode.rawValue, forKey: "addedSourceMode") }
    }
    private func edit(_ change: (inout [String]) -> Void) { var order = owner.cycleOrder; change(&order); save { engine.cycleSources = order } }
    @objc private func moveUp(_ sender: NSButton) { edit { if sender.tag > 0 { $0.swapAt(sender.tag, sender.tag - 1) } } }
    @objc private func moveDown(_ sender: NSButton) { edit { if sender.tag < $0.count - 1 { $0.swapAt(sender.tag, sender.tag + 1) } } }
    @objc private func remove(_ sender: NSButton) { edit { if $0.count > 2 { $0.remove(at: sender.tag) } } }
    @objc private func add() {
        guard let id = addPicker.selectedItem?.representedObject as? String else { return }
        edit { if !$0.contains(id) { $0.append(id) } }
    }
    // The whole order at once, from the command line.
    func setCycle(_ order: [String]) { save { engine.cycleSources = order } }
    @objc func changeSource() { save { engine.separateSource = sourcePicker.selectedItem?.representedObject as? String } }
    @objc func changeKey() {
        let key = (keyPicker.selectedItem?.representedObject as? NSNumber)?.uint64Value
        guard let key else { save { engine.separateKey = nil }; return }
        guard !(engine.defaultSources.contains(key) || engine.keyboards.maps(key, default: engine.defaultSources)) else {
            let alert = NSAlert(); alert.messageText = "\(sourceName(key))은 한영 키로 사용 중입니다."
            alert.informativeText = "다른 키를 선택해주세요."
            _ = owner.runAlert(alert); refresh(force: true); return
        }
        guard confirmKey(key) else { refresh(force: true); return }
        save { engine.separateKey = key }
    }
    // Caps Lock stops being Caps Lock, a system shortcut on the same Space combination stops working, and another app's
    // mapping of the key is replaced. False keeps the old key.
    private func confirmKey(_ key: UInt64) -> Bool {
        guard owner.confirmCapsLockKey(key == sources[2], as: "전환 키") else { return false }
        if engine.systemShortcutUses(key) {
            let alert = NSAlert(); alert.messageText = "\(sourceName(key))은 시스템 단축키에서 사용 중입니다."
            alert.informativeText = "전환 키로 쓰면 그 단축키는 동작하지 않습니다."
            alert.addButton(withTitle: "변경"); alert.addButton(withTitle: "취소")
            guard owner.runAlert(alert) == .alertFirstButtonReturn else { return false }
        }
        guard sources.contains(key), engine.separateKeyConflict(key) else { return true }
        let alert = NSAlert(); alert.messageText = "\(sourceName(key))에 다른 매핑이 있습니다."
        alert.informativeText = "선택한 키를 입력 소스 전환 전용으로 바꿉니다. 다른 앱에서도 이 키의 재매핑을 꺼주세요. 기존 매핑은 해제 시 복원됩니다."
        alert.addButton(withTitle: "변경"); alert.addButton(withTitle: "취소")
        return owner.runAlert(alert) == .alertFirstButtonReturn
    }
}
