import AppKit

func runSettingsReentrancyTests() throws {
    let suite = "io.gksdud.reentrancy-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "active")
    let original: [String: Any] = ["enabled": true, "value": ["type": "standard", "parameters": [32, 49, 262144]]]
    var keys: [String: Any] = ["60": original]
    var engine: Engine!
    var insideActivation = false, reentered = false, failActivation = false
    var timerTicks = 0
    var repairError: Error?
    let store = ShortcutPreferences(read: { keys }, write: { keys = $0 }, activate: {
        if insideActivation { reentered = true; return }
        insideActivation = true
        defer { insideActivation = false }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            timerTicks += 1
            do { try engine.repair() } catch { repairError = error }
        }
        defer { timer.invalidate() }
        // Use the same run-loop-pumping wait as activateSettings, without changing macOS settings.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.15"]
        try process.run(); process.waitUntilExit()
        if failActivation { throw KeyboardError.verification }
    })
    engine = Engine(defaults: defaults, discover: { [] }, shortcutPreferences: store)
    for _ in 0..<3 {
        let beforeApply = timerTicks
        // Engine.apply calls shortcut before committing active=true; exercise that interval.
        try engine.shortcut(target: targets[6])
        precondition(timerTicks > beforeApply && repairError == nil, "Actual run-loop timer must exercise periodic repair")
        precondition(Engine.ownsShortcut(keys["60"], keyCode: 80), "Periodic repair must not undo activation in progress")
        precondition(defaults.bool(forKey: "shortcutBackedUp") && Engine.sameShortcut(defaults.object(forKey: "originalShortcut"), original))
        precondition(!engine.isUpdatingSettings && !reentered)
        defaults.set(true, forKey: "active")
        try engine.repair()
        precondition(Engine.ownsShortcut(keys["60"], keyCode: 80))

        let beforeRestore = timerTicks
        try engine.restore()
        precondition(timerTicks > beforeRestore && !reentered, "Periodic repair must not recursively enter restoration")
        precondition(!engine.active && !engine.isUpdatingSettings && !defaults.bool(forKey: "shortcutBackedUp"))
        precondition(Engine.sameShortcut(keys["60"], original))
    }
    failActivation = true
    // The full apply path must release its outer guard if activation fails, before it reaches menu settings.
    do { _ = try engine.apply(sources: [sources[0]], target: targets[6]); preconditionFailure("Expected activation failure") } catch {}
    precondition(!engine.active && !engine.isUpdatingSettings && defaults.bool(forKey: "shortcutBackedUp"))
    failActivation = false
    try engine.repair()
    precondition(Engine.sameShortcut(keys["60"], original) && !defaults.bool(forKey: "shortcutBackedUp"))
    precondition(repairError == nil && !reentered)
    print("PASS: real timer during process wait, activation backup preservation, nonrecursive restore, failure recovery")
}

func runShortcutRestoreTests() throws {
    func entry(_ code: Int = 80, flags: Int = 0, enabled: Bool = true) -> [String: Any] {
        ["enabled": enabled, "value": ["type": "standard", "parameters": [65535, code, flags]]]
    }
    let suite = "io.gksdud.shortcut-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let otherEntry = entry(49, flags: 262144)
    var keys: [String: Any] = ["61": otherEntry]
    var failWrite = false, failActivation = false
    var activations = 0
    let store = ShortcutPreferences(read: { keys }, write: { value in
        if failWrite { throw KeyboardError.write }
        keys = value
    }, activate: {
        activations += 1
        if failActivation { throw KeyboardError.verification }
    })
    let engine = Engine(defaults: defaults, discover: { [] }, shortcutPreferences: store)
    let fn = Int(CGEventFlags.maskSecondaryFn.rawValue)

    // Exercise the actual disable path with both macOS representations and different baselines.
    for flags in [0, fn] {
        for original: [String: Any]? in [nil, entry(enabled: false), entry(49, flags: 262144)] {
            keys["60"] = original
            try engine.shortcut(target: targets[6])
            keys["60"] = entry(flags: flags)
            try engine.restore()
            precondition(Engine.sameShortcut(keys["60"], original), "Disable must restore even after macOS normalizes F19")
            precondition(Engine.sameShortcut(keys["61"], otherEntry), "Leave unrelated shortcuts unchanged")
            precondition(!defaults.bool(forKey: "shortcutBackedUp"))
        }
    }

    // A user edit after activation must survive disable, including disabled or modified F19.
    for edited in [entry(flags: fn | 1048576), entry(flags: 262144), entry(enabled: false), entry(79)] {
        keys["60"] = nil
        try engine.shortcut(target: targets[6])
        keys["60"] = edited
        let before = activations
        try engine.restore()
        precondition(Engine.sameShortcut(keys["60"], edited) && activations == before)
    }

    // Removing the setting and applying again must not reuse an older F19 baseline.
    keys["60"] = entry(flags: fn)
    try engine.shortcut(target: targets[6])
    keys["60"] = nil
    try engine.shortcut(target: targets[6])
    keys["60"] = entry(flags: fn)
    try engine.restore()
    precondition(keys["60"] == nil, "External removal replaces the stale baseline")

    keys["60"] = otherEntry
    try engine.shortcut(target: targets[6])
    keys["60"] = entry(flags: fn)
    try engine.shortcut(target: targets[5])
    keys["60"] = entry(79, flags: fn)
    try engine.restore()
    precondition(Engine.sameShortcut(keys["60"], otherEntry), "Changing the target retains the first baseline")

    // Old installations have no managedShortcutKeyCode; their normalized shortcut still restores.
    defaults.set(true, forKey: "shortcutBackedUp")
    defaults.set(otherEntry, forKey: "originalShortcut")
    keys["60"] = entry(flags: fn)
    try engine.restore()
    precondition(Engine.sameShortcut(keys["60"], otherEntry))

    keys["60"] = nil
    try engine.shortcut(target: targets[6])
    failWrite = true
    do { try engine.restore(); preconditionFailure("Write failure must be reported") } catch {}
    precondition(defaults.bool(forKey: "shortcutBackedUp"))
    failWrite = false; failActivation = true
    do { try engine.restore(); preconditionFailure("Activation failure must be reported") } catch {}
    precondition(keys["60"] == nil && defaults.bool(forKey: "shortcutBackedUp"))
    failActivation = false
    let before = activations
    try engine.restore()
    precondition(activations == before + 1 && !defaults.bool(forKey: "shortcutBackedUp"), "Retry failed activation before clearing the backup")
    print("PASS: normalized F-key shortcut restoration, disabled/missing baselines, user edits, target changes, legacy backups, restore retry")
}

final class TestKeyboard: KeyboardDevice {
    let registryID: String
    let name: String
    let identity: KeyboardIdentity
    var mappings: [Mapping]
    var failWrite = false
    var failRead = false
    var ignoreWrite = false
    var reverseReadback = false
    var afterWrite: (() -> Void)?
    var writes = 0
    init(_ id: String, name: String = "Test Keyboard", serial: String = "one", mappings: [Mapping] = []) {
        registryID = id; self.name = name; self.mappings = mappings
        identity = KeyboardIdentity(properties: ["Product": name, "VendorID": "1", "ProductID": "2", "SerialNumber": serial])
    }
    func readMappings() throws -> [Mapping] {
        if failRead { throw KeyboardError.read }
        return reverseReadback ? Array(mappings.reversed()) : mappings
    }
    func writeMappings(_ value: [Mapping]) throws {
        writes += 1
        if failWrite { throw KeyboardError.write }
        if !ignoreWrite { mappings = value }
        afterWrite?()
    }
}

func runKeyboardTests() {
    func mapping(_ source: UInt64, _ target: UInt64) -> Mapping { [srcKey: NSNumber(value: source), dstKey: NSNumber(value: target)] }
    let command = sources[0], option = sources[1]
    let suiteName = "io.gksdud.keyboard-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = TestKeyboard("1", mappings: [mapping(option, targets[5].usage)])
    var devices: [KeyboardDevice] = [first]
    var enumerationFails = false
    let discover: () throws -> [KeyboardDevice] = {
        if enumerationFails { throw KeyboardError.enumeration }
        return devices
    }
    let manager = KeyboardManager(defaults: defaults, discover: discover)
    func repair(_ source: UInt64 = command, _ target: UInt64 = f19, active: Bool = true) -> KeyboardReconcileResult {
        manager.reconcile(sources: [source], target: target, active: active)
    }
    precondition(manager.defaultEnabled)
    precondition(repair().applied == 1)
    precondition(first.mappings.contains(mapping(option, targets[5].usage)))
    precondition(first.mappings.contains(mapping(command, f19)))
    _ = repair(); precondition(first.writes == 1, "Unchanged hardware must not be rewritten")

    manager.defaultEnabled = false
    _ = repair()
    precondition(first.mappings == [mapping(option, targets[5].usage)], "Default Off restores only owned mapping")
    manager.setMode(.on, for: first.identity.key)
    precondition(repair().applied == 1, "Explicit On overrides default Off")
    manager.defaultEnabled = true; manager.setMode(.off, for: first.identity.key)
    precondition(repair().applied == 0 && first.mappings.count == 1, "Explicit Off overrides default On")
    devices = []; _ = repair()
    precondition(manager.known.count == 1 && manager.connected.isEmpty, "Keep disconnected rows")
    let reconnected = TestKeyboard("2")
    devices = [reconnected]
    precondition(repair().applied == 0 && reconnected.writes == 0, "New registry ID retains Off")
    let restarted = KeyboardManager(defaults: defaults, discover: discover)
    precondition(restarted.known[first.identity.key]?.mode == .off, "Preferences survive process restart")
    manager.setMode(.default, for: first.identity.key)
    precondition(repair().applied == 1)

    let virtual = TestKeyboard("3", name: "Karabiner DriverKit VirtualHIDKeyboard 1.8.0", serial: "virtual")
    devices.append(virtual)
    precondition(repair().applied == 2 && virtual.mappings == [mapping(command, f19)], "Discover new keyboards after startup")
    manager.defaultEnabled = false
    let newOff = TestKeyboard("4", serial: "new-off")
    devices.append(newOff); _ = repair()
    precondition(newOff.writes == 0, "New keyboards inherit default Off")
    manager.defaultEnabled = true
    virtual.failWrite = true
    let partial = repair()
    precondition(partial.applied == 2 && partial.pending == 1, "One failure must not stop later devices")
    precondition(manager.warning == nil)
    _ = repair(); precondition(manager.warning == nil)
    _ = repair(); precondition(manager.warning != nil, "Warn after three consecutive failures")
    virtual.failWrite = false
    _ = repair(); precondition(manager.warning == nil && virtual.mappings == [mapping(command, f19)])

    // A failed readback can mean the write succeeded. Off must still undo it.
    virtual.afterWrite = { virtual.failRead = true }
    _ = repair(command, targets[7].usage)
    virtual.afterWrite = nil; virtual.failRead = false
    manager.setMode(.off, for: virtual.identity.key)
    _ = repair(command, targets[7].usage)
    precondition(virtual.mappings.isEmpty, "Undo the pending destination after a failed verification")
    manager.setMode(.on, for: virtual.identity.key)
    virtual.ignoreWrite = true
    _ = repair(); _ = repair(); _ = repair()
    precondition(manager.warning != nil, "Successful setter with wrong readback is still a failure")
    devices.removeAll { $0.registryID == virtual.registryID }
    _ = repair(); precondition(manager.warning == nil, "Disconnected devices must not leave warnings")
    virtual.ignoreWrite = false

    // Reconnect during a pass: the next fresh scan must discover the replacement.
    let disappearing = TestKeyboard("5", serial: "disappearing")
    disappearing.failWrite = true
    var scans = 0
    let disappearanceManager = KeyboardManager(defaults: defaults) {
        scans += 1
        return scans == 1 ? [disappearing, newOff] : [newOff]
    }
    let disappeared = disappearanceManager.reconcile(sources: [command], target: f19, active: true)
    precondition(disappeared.pending == 0 && disappearanceManager.failures.isEmpty)

    enumerationFails = true
    _ = repair(); _ = repair(); _ = repair()
    precondition(manager.warning != nil && manager.result.pending == 1)
    enumerationFails = false; _ = repair()
    precondition(manager.warning == nil, "Enumeration recovery clears only its own warning")

    _ = repair(option, targets[7].usage)
    precondition(!reconnected.mappings.contains { $0[srcKey]?.uint64Value == command })
    precondition(reconnected.mappings.contains(mapping(option, targets[7].usage)))
    _ = repair(option, targets[7].usage, active: false)
    precondition(reconnected.mappings.isEmpty)
    precondition(newOff.mappings.isEmpty)
    reconnected.mappings = [mapping(command, targets[4].usage), mapping(option, targets[5].usage)]
    reconnected.reverseReadback = true
    _ = repair()
    precondition(manager.warning == nil)
    manager.setMode(.off, for: reconnected.identity.key)
    _ = repair()
    precondition(reconnected.mappings.contains(mapping(command, targets[4].usage)), "Off restores existing external mapping")
    let capsLock = sources[2], leftOption: UInt64 = 0x7000000e2
    let plain = TestKeyboard("7", serial: "plain"), custom = TestKeyboard("8", serial: "custom", mappings: [mapping(capsLock, leftOption)])
    devices = [plain, custom]; _ = repair()
    manager.setSources([option, capsLock], for: custom.identity.key); _ = repair()
    func same(_ lhs: [Mapping], _ rhs: [Mapping]) -> Bool { KeyboardManager.canonical(lhs) == KeyboardManager.canonical(rhs) }
    precondition(plain.mappings == [mapping(command, f19)] && same(custom.mappings, [mapping(option, f19), mapping(capsLock, f19)]),
        "A keyboard's own keys all switch, and only on that keyboard")
    precondition(KeyboardManager(defaults: defaults, discover: discover).known[custom.identity.key]?.sources == [option, capsLock], "A keyboard's keys survive restart")
    manager.setSources(nil, for: custom.identity.key); _ = repair()
    precondition(same(custom.mappings, [mapping(command, f19), mapping(capsLock, leftOption)]), "Default restores each key's original mapping")
    _ = manager.reconcile(sources: [command, option], target: f19, active: true)
    precondition(same(plain.mappings, [mapping(command, f19), mapping(option, f19)]), "Several global keys apply together")
    _ = manager.reconcile(sources: [command, option], target: f19, active: false)
    precondition(plain.mappings.isEmpty && custom.mappings == [mapping(capsLock, leftOption)])
    let growing = TestKeyboard("9", serial: "growing")
    devices = [growing]; _ = repair()
    growing.mappings.append(mapping(leftOption, f19))
    manager.setSources([command, option], for: growing.identity.key); _ = repair()
    precondition(growing.mappings.contains(mapping(command, f19)) && !growing.mappings.contains(mapping(option, f19)),
        "A conflict is found before any write, so the working key stays mapped")
    growing.mappings.removeAll { $0 == mapping(leftOption, f19) }
    var writes = growing.writes; _ = repair()
    precondition(same(growing.mappings, [mapping(command, f19), mapping(option, f19)]) && growing.writes == writes + 1, "Adding a key is one write")
    manager.setSources([option], for: growing.identity.key)
    writes = growing.writes; _ = repair()
    precondition(growing.mappings == [mapping(option, f19)] && growing.writes == writes + 1, "Dropping a key restores it in the same write")
    manager.records = [growing.registryID: ["source": "x,\(option)", "original": "none,\(leftOption)", "target": String(f19)]]
    _ = repair(active: false)
    precondition(growing.mappings == [mapping(option, leftOption)], "An unreadable undo entry must not shift the others")
    manager.setSources([], for: growing.identity.key)
    precondition(manager.known[growing.identity.key]?.sources == nil, "Saving no keys means Default")
    let unverified = TestKeyboard("10", serial: "unverified")
    devices = [unverified]; _ = repair()
    manager.setSources([command, option], for: unverified.identity.key); _ = repair()
    unverified.afterWrite = { unverified.failRead = true }
    _ = repair(command, targets[7].usage)
    unverified.afterWrite = nil; unverified.failRead = false
    manager.setSources([command], for: unverified.identity.key)
    precondition(repair(command, targets[7].usage).applied == 1 && unverified.mappings == [mapping(command, targets[7].usage)],
        "A key dropped after a failed readback is ours, not a conflict")
    let savedSuite = "io.gksdud.saved-keys-tests.\(UUID().uuidString)"
    let savedDefaults = UserDefaults(suiteName: savedSuite)!
    defer { savedDefaults.removePersistentDomain(forName: savedSuite) }
    for (saved, expected): ([UInt64], [UInt64]) in [([], [command]), ([1], [command]), ([1, capsLock, option], [option, capsLock])] {
        let keyboard = SavedKeyboard(key: plain.identity.key, name: plain.name, detail: "", mode: .on, sources: saved)
        savedDefaults.set(try! JSONEncoder().encode([keyboard.key: keyboard]), forKey: "knownKeyboards")
        precondition(KeyboardManager(defaults: savedDefaults, discover: { [plain] }).sources(for: plain, default: [command]) == expected,
            "Saved keys that are empty or unknown fall back to the global keys")
    }
    let legacy = try! JSONDecoder().decode(SavedKeyboard.self, from: Data(#"{"key":"k","name":"n","detail":"d","mode":"on"}"#.utf8))
    precondition(legacy.sources == nil, "Older saved keyboards follow the global keys")

    let a = KeyboardIdentity(properties: ["Product": "Keyboard", "VendorID": "2", "ProductID": "4", "SerialNumber": "S", "LocationID": "1"])
    let b = KeyboardIdentity(properties: ["Product": "Keyboard", "VendorID": "2", "ProductID": "4", "SerialNumber": "S", "LocationID": "2"])
    precondition(a.key == b.key, "Serial identity survives a port change")
    let v1 = KeyboardIdentity(properties: ["Product": "Karabiner DriverKit VirtualHIDKeyboard 1.8.0"])
    let v2 = KeyboardIdentity(properties: ["Product": "Karabiner DriverKit VirtualHIDKeyboard 1.9.0"])
    precondition(v1.key == v2.key, "Virtual keyboard version changes preserve preference")
    let conflicting = TestKeyboard("6", serial: "conflict", mappings: [mapping(option, f19)])
    devices = [conflicting]
    _ = repair(); _ = repair(); _ = repair()
    precondition(manager.warning != nil && conflicting.writes == 0, "Do not claim a destination used by another mapping")
    conflicting.mappings = []
    _ = repair(); precondition(manager.warning == nil)
    manager.setMode(.off, for: conflicting.identity.key)
    conflicting.failWrite = true
    _ = repair(); _ = repair(); _ = repair()
    precondition(manager.warning != nil && manager.records[conflicting.registryID] != nil, "Failed undo keeps its backup and warns")
    conflicting.failWrite = false
    _ = repair()
    precondition(manager.warning == nil && conflicting.mappings.isEmpty && manager.records[conflicting.registryID] == nil)
    defaults.set("old-boot", forKey: "keyboardRecordsBoot")
    defaults.set(["stale": ["source": String(command), "target": String(f19)]], forKey: "records")
    let afterBoot = KeyboardManager(defaults: defaults, discover: discover, bootSession: "new-boot")
    precondition(afterBoot.records.isEmpty && afterBoot.known[conflicting.identity.key]?.mode == .off,
        "Reboot drops connection-specific undo records but preserves keyboard choices")
    print("PASS: keyboard discovery/replacement, default and overrides, persistent disconnected choices, partial failure isolation, warning recovery, verified undo, identity stability")
}

func runRightControlTests() {
    func mapping(_ source: UInt64, _ target: UInt64) -> Mapping { [srcKey: NSNumber(value: source), dstKey: NSNumber(value: target)] }
    let rightControl: UInt64 = 0x7000000e4, leftControl: UInt64 = 0x7000000e0
    let suite = "io.gksdud.right-control-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let original = [mapping(leftControl, 0x7000000e2), mapping(rightControl, 0x7000000e3)]
    let keyboard = TestKeyboard("control", mappings: original)
    let engine = Engine(defaults: defaults, discover: { [keyboard] })
    precondition(engine.defaultSources == [sources[0]], "The default remains right Command")
    precondition(sources.contains(rightControl), "Right Control must be selectable")
    for target in targets {
        defaults.set(target.name, forKey: "target")
        defaults.set(String(sources[0]), forKey: "source")
        precondition((try! engine.reconcile()) == 1)
        defaults.set(String(rightControl), forKey: "source")
        precondition((try! engine.reconcile()) == 1)
        precondition(keyboard.mappings.count == 2 && keyboard.mappings.contains(mapping(rightControl, target.usage)),
            "Changing to right Control removes the previous owned mapping")
        precondition(keyboard.mappings.contains(original[0]), "Left Control mapping must stay unchanged")
        let restarted = Engine(defaults: defaults, discover: { [keyboard] })
        precondition(restarted.defaultSources == [rightControl] && restarted.target.name == target.name)
        let writes = keyboard.writes
        precondition((try! restarted.reconcile()) == 1 && keyboard.writes == writes, "Restart keeps the selected mapping")
        defaults.set(String(sources[1]), forKey: "source")
        precondition((try! restarted.reconcile()) == 1)
        precondition(original.allSatisfy { keyboard.mappings.contains($0) }, "Changing away restores the original Control mapping")
        defaults.set(String(rightControl), forKey: "source")
        _ = try! restarted.reconcile()
        defaults.set(false, forKey: "active")
        _ = try! restarted.reconcile()
        precondition(keyboard.mappings.count == original.count && original.allSatisfy { keyboard.mappings.contains($0) },
            "Disable restores both original Control mappings")
        defaults.set(true, forKey: "active")
    }
    print("PASS: right Control across F13-F20, left Control preservation, source changes, saved selection, restart, disable restoration")
}

// Renders native UI against fake devices; never opens a real HID client or applies system settings.
func renderKeyboardUI(to directory: String) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let suiteName = "io.gksdud.ui-preview.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let builtIn = TestKeyboard("preview-1", name: "Apple Internal Keyboard / Trackpad", serial: "builtin")
    let virtual = TestKeyboard("preview-2", name: "Karabiner DriverKit VirtualHIDKeyboard 1.8.0", serial: "virtual")
    let disconnected = TestKeyboard("preview-3", name: "SP109 Wireless Keyboard", serial: "external")
    var devices: [KeyboardDevice] = [builtIn, virtual, disconnected]
    let engine = Engine(defaults: defaults, discover: { devices })
    _ = engine.keyboards.reconcile(sources: [sources[0]], target: f19, active: true)
    engine.keyboards.setMode(.on, for: virtual.identity.key)
    engine.keyboards.setMode(.off, for: disconnected.identity.key)
    devices = [builtIn, virtual]
    virtual.mappings = []; virtual.failWrite = true
    for _ in 0..<3 { _ = engine.keyboards.reconcile(sources: [sources[0]], target: f19, active: true) }
    let previewRelease = AppRelease(tag_name: "v9.0.0", html_url: "https://github.com/codingnoye/gksdud/releases/tag/v9.0.0", body: "## 요약\n- 설정을 일반·대소문자·특수문자·gksdud 탭으로 나눴습니다.\n- 한글에서도 Option 특수문자를 입력할 수 있습니다.\n- 새 버전이 나오면 메뉴에서 알려드립니다.\n\n## 설치\n요약에 나타나면 안 됩니다.", draft: false, prerelease: false)
    defaults.set(try JSONEncoder().encode(previewRelease), forKey: "updates.release")
    let delegate = AppDelegate(engine: engine)
    delegate.updates = UpdateChecker(defaults: defaults)
    delegate.buildWindow()
    delegate.window.makeFirstResponder(nil)
    delegate.updateMenu()
    defer { if let item = delegate.item { NSStatusBar.system.removeStatusItem(item) } }
    // Wired like AppDelegate, except that the test answers warnings and repair always applies.
    var allowChanges = true, checked: [(keyboards: Set<String>, conflict: UInt64?)] = []
    let settings = KeyboardSettingsController(engine: engine, sourcesChanged: { delegate.picker.show($0); delegate.selectionChanged() }, confirm: {
        checked.append(($0, engine.conflict(engine.defaultSources, target: engine.target, only: $0))); return allowChanges
    }) {
        _ = engine.keyboards.reconcile(sources: engine.defaultSources, target: engine.target.usage, active: true)
        delegate.refreshKeyboardState()
    }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    if let button = delegate.item?.button {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        button.layoutSubtreeIfNeeded()
        precondition(delegate.warningBadge.superview === button && !delegate.warningBadge.isHidden)
        precondition(button.bounds.contains(delegate.warningBadge.frame), "Warning badge must fit inside the menu-bar button")
        if let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
            button.cacheDisplay(in: button.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("menubar-warning.png"))
        }
    }
    func save(_ view: NSView, _ name: String) throws {
        let visible = view.window?.isVisible == true
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        view.window?.orderFront(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw KeyboardError.read }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        if !visible { view.window?.orderOut(nil) }
    }
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        delegate.window.appearance = NSAppearance(named: appearance)
        settings.window.appearance = NSAppearance(named: appearance)
        for tab in 0..<4 {
            delegate.tabButtons[tab].performClick(nil)
            precondition(delegate.selectedTab == tab && !delegate.tabPanels[tab].isHidden)
            precondition(delegate.tabPanels.filter { !$0.isHidden }.count == 1)
            try save(delegate.window.contentView!, "tab-\(tab)-\(name).png")
        }
        delegate.selectTab(0)
        try save(delegate.window.contentView!, "settings-\(name).png")
        try save(settings.window.contentView!, "keyboards-\(name).png")
    }
    precondition(delegate.tabButtons[3].contentTintColor == .controlAccentColor && delegate.tabButtons[0].contentTintColor == .controlAccentColor)
    precondition(delegate.tabButtons[1].contentTintColor == .secondaryLabelColor)
    let updateEntry = delegate.item!.menu!.items[1]
    precondition(updateEntry.action == #selector(AppDelegate.showAbout) && !updateEntry.isHidden)
    delegate.showAbout()
    precondition(delegate.selectedTab == 3 && !delegate.updateButton.isHidden)
    precondition(!delegate.updateSummary.string.contains("요약에 나타나면"))
    delegate.updates = UpdateChecker(defaults: defaults, installedVersion: "9.0.0")
    delegate.refreshUpdates()
    precondition(delegate.tabButtons[3].accessibilityLabel() == "gksdud 탭" && delegate.updateButton.isHidden && updateEntry.isHidden)
    defaults.set(false, forKey: "active")
    delegate.resetSelection()
    for (title, usage): (String, UInt64) in [("우측 Command ⌘", 0x7000000e7), ("우측 Option ⌥", 0x7000000e6),
                                          ("Caps Lock ⇪", 0x700000039), ("우측 Control ⌃", 0x7000000e4)] {
        delegate.picker.selectItem(withTitle: title)
        precondition(delegate.picker.sendAction(delegate.picker.action, to: delegate.picker.target))
        precondition(engine.defaultSources == [usage], "The selected label must save the matching HID key")
        delegate.picker.selectItem(at: 0)
        delegate.resetSelection()
        precondition(delegate.picker.titleOfSelectedItem == title, "Saved key selection must be restored")
    }
    delegate.selectTab(0)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        delegate.window.appearance = NSAppearance(named: appearance)
        try save(delegate.window.contentView!, "right-control-\(name).png")
    }
    print("PASS: source picker actions and saved selection for right Command, right Option, Caps Lock and right Control")
    for mode in [1, 2, 1] {
        // Exercise real checkbox actions with activation off so no live tap is installed.
        delegate.specialButtons[mode - 1].performClick(nil)
        precondition(delegate.specialMode.rawValue == mode)
        precondition(delegate.specialButtons.map(\.state) == (mode == 1 ? [.on, .off] : [.off, .on]))
    }
    delegate.specialButtons[0].performClick(nil)
    precondition(delegate.specialMode == .none && delegate.specialButtons.allSatisfy { $0.state == .off })
    delegate.selectTab(0)
    // Kept on screen like the open sheet in the app; a hidden window skips periodic refreshes.
    settings.window.orderFront(nil)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func setSegment(_ control: NSSegmentedControl, _ segment: Int) { control.selectedSegment = segment; _ = control.sendAction(control.action, to: control.target) }
    let ui = descendants(settings.window.contentView!)
    let toggle = ui.compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 2 }!
    setSegment(toggle, 0)
    precondition(!engine.keyboards.defaultEnabled)
    let segments = ui.compactMap { $0 as? NSSegmentedControl }.filter { $0.segmentCount == 3 }
    let virtualControl = segments[1]
    setSegment(virtualControl, 0)
    precondition(engine.keyboards.known[virtual.identity.key]?.mode == .off)
    precondition(engine.keyboards.warning == nil && delegate.keyboardWarningRow.isHidden && delegate.warningBadge.isHidden)
    precondition(virtualControl.superview != nil, "Mode changes must preserve the focused native control")
    setSegment(segments[2], 2)
    precondition(engine.keyboards.known[disconnected.identity.key]?.mode == .on, "Disconnected rows remain editable")
    devices.append(disconnected)
    settings.changed()
    settings.refresh()
    precondition(disconnected.mappings.contains { $0[srcKey]?.uint64Value == sources[3] && $0[dstKey]?.uint64Value == f19 }, "Reconnected keyboards follow the global key")
    settings.window.layoutIfNeeded()
    let rows = descendants(settings.window.contentView!)
    func picker(_ label: String) -> SourcePicker { rows.compactMap { $0 as? SourcePicker }.first { $0.accessibilityLabel() == label }! }
    func modeControl(_ keyboard: TestKeyboard) -> NSSegmentedControl {
        rows.compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == "\(keyboard.name) 적용 설정" }!
    }
    func choose(_ picker: SourcePicker, _ index: Int) { picker.selectItem(at: index); _ = picker.sendAction(picker.action, to: picker.target) }
    // Opens the multi-key sheet from the picker's last item, toggles keys by title and presses a sheet button.
    func toggleMultiple(_ picker: SourcePicker, _ titles: [String], press button: String = "완료") {
        let parent = picker.window!
        choose(picker, picker.numberOfItems - 1)
        let buttons = descendants(parent.attachedSheet!.contentView!).compactMap { $0 as? NSButton }
        for title in titles + [button] { buttons.first { $0.title == title }!.performClick(nil) }
        precondition(parent.attachedSheet == nil)
    }
    let defaultPicker = picker("기본 한영 키"), detachedPicker = picker("\(disconnected.name) 한영 키"), builtInPicker = picker("\(builtIn.name) 한영 키")
    precondition(defaultPicker.titleOfSelectedItem == sourceNames[3] && detachedPicker.itemTitles.first == "기본값 (\(sourceNames[3]))"
        && detachedPicker.itemTitles.last == "다중 한영 키", "Rows start with Default, labeled with the global key, and end with multiple keys")
    choose(detachedPicker, 3)
    precondition(engine.keyboards.known[disconnected.identity.key]?.sources == [sources[2]] && engine.defaultSources == [sources[3]])
    precondition(checked.last?.keyboards == [disconnected.identity.key], "Per-keyboard keys are checked")
    let foreign: Mapping = [srcKey: NSNumber(value: sources[1]), dstKey: NSNumber(value: targets[5].usage)]
    disconnected.mappings.append(foreign)
    allowChanges = false
    choose(detachedPicker, 2)
    precondition(checked.last?.conflict == sources[1] && engine.keyboards.known[disconnected.identity.key]?.sources == [sources[2]]
        && detachedPicker.titleOfSelectedItem == sourceNames[2], "The warning checks the new key, and cancelling it keeps the saved key")
    precondition(engine.targetInUse(engine.defaultSources, target: targets[5], only: [disconnected.identity.key])
        && !engine.targetInUse(engine.defaultSources, target: targets[5], only: [builtIn.identity.key]), "Target collisions are checked per keyboard")
    disconnected.mappings.removeAll { $0 == foreign }
    virtual.mappings = [foreign]
    allowChanges = true
    choose(picker("\(virtual.name) 한영 키"), 2)
    precondition(checked.last?.keyboards == [virtual.identity.key] && checked.last?.conflict == nil
        && engine.keyboards.known[virtual.identity.key]?.sources == [sources[1]], "An Off keyboard's keys are not applied yet")
    allowChanges = false
    setSegment(modeControl(virtual), 2)
    precondition(checked.last?.conflict == sources[1] && engine.keyboards.known[virtual.identity.key]?.mode == .off
        && modeControl(virtual).selectedSegment == 0, "Turning a keyboard on checks its keys, and cancelling keeps it off")
    setSegment(toggle, 1)
    precondition(checked.last?.keyboards == [builtIn.identity.key] && !engine.keyboards.defaultEnabled && toggle.selectedSegment == 0,
        "Turning Default on checks the keyboards on Default, and cancelling keeps it off")
    allowChanges = true
    virtual.mappings = []
    choose(picker("\(virtual.name) 한영 키"), 0)
    setSegment(toggle, 1)
    precondition(engine.keyboards.defaultEnabled && builtIn.mappings.contains { $0[srcKey]?.uint64Value == sources[3] && $0[dstKey]?.uint64Value == f19 })
    toggleMultiple(detachedPicker, [sourceNames[0]])
    precondition(engine.keyboards.known[disconnected.identity.key]?.sources == [sources[0], sources[2]]
        && detachedPicker.titleOfSelectedItem == "\(sourceNames[0]) +1", "Several keys show the first key and a count")
    precondition([sources[0], sources[2]].allSatisfy { key in disconnected.mappings.contains { $0[srcKey]?.uint64Value == key && $0[dstKey]?.uint64Value == f19 } })
    toggleMultiple(detachedPicker, [sourceNames[3]], press: "취소")
    precondition(engine.keyboards.known[disconnected.identity.key]?.sources == [sources[0], sources[2]], "Cancel keeps the saved keys")
    toggleMultiple(builtInPicker, [], press: "취소")
    precondition(engine.keyboards.known[builtIn.identity.key]?.sources == nil, "Cancel keeps a keyboard on Default")
    toggleMultiple(builtInPicker, [])
    precondition(engine.keyboards.known[builtIn.identity.key]?.sources == nil && builtInPicker.indexOfSelectedItem == 0,
        "Done with the Default keys unchanged keeps a keyboard on Default")
    toggleMultiple(defaultPicker, [sourceNames[1]])
    precondition(engine.defaultSources == [sources[1], sources[3]] && defaultPicker.titleOfSelectedItem == "\(sourceNames[1]) +1"
        && delegate.picker.titleOfSelectedItem == "\(sourceNames[1]) +1" && builtInPicker.titleOfSelectedItem == "기본값 (\(sourceNames[1]) +1)",
        "Global keys set here reach the main window and Default rows")
    settings.changed()
    precondition([sources[1], sources[3]].allSatisfy { key in builtIn.mappings.contains { $0[srcKey]?.uint64Value == key && $0[dstKey]?.uint64Value == f19 } },
        "Default keyboards apply every global key")
    try save(settings.window.contentView!, "keyboards-multi.png")
    toggleMultiple(detachedPicker, [sourceNames[0], sourceNames[2]])
    precondition(engine.keyboards.known[disconnected.identity.key]?.sources == nil, "Checking no keys returns a keyboard to Default")
    toggleMultiple(defaultPicker, [sourceNames[1], sourceNames[3]])
    precondition(engine.defaultSources == [sources[1]] && defaultPicker.titleOfSelectedItem == sourceNames[1], "Checking no keys keeps one global key")
    delegate.resetSelection()
    toggleMultiple(delegate.picker, [sourceNames[2]])
    precondition(engine.defaultSources == [sources[1], sources[2]] && delegate.picker.titleOfSelectedItem == "\(sourceNames[1]) +1")
    settings.refresh()
    choose(detachedPicker, detachedPicker.numberOfItems - 1)
    let sheet = settings.window.attachedSheet!
    try save(sheet.contentView!, "keyboards-sheet.png")
    devices.removeAll { $0 === disconnected }
    settings.changed(); settings.refresh()
    precondition(!descendants(settings.window.contentView!).contains { $0 === detachedPicker }, "Disconnecting rebuilds the rows")
    for title in [sourceNames[0], "완료"] { descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }!.performClick(nil) }
    precondition(engine.keyboards.known[disconnected.identity.key]?.sources == [sources[0], sources[1], sources[2]], "A row rebuilt under the sheet keeps its choice")
    settings.window.orderOut(nil)
    engine.defaultSources = [sources[3]]; settings.refresh()
    precondition(defaultPicker.titleOfSelectedItem == "\(sourceNames[1]) +1", "A hidden window skips refreshes")
    settings.window.orderFront(nil); settings.refresh()
    precondition(defaultPicker.titleOfSelectedItem == sourceNames[3], "A shown window catches up")
    settings.window.orderOut(nil)
    delegate.refreshKeyboardState()
    delegate.window.appearance = NSAppearance(named: .aqua)
    try save(delegate.window.contentView!, "settings-recovered.png")
    print("PASS: default and per-keyboard segments and key dropdowns, warnings on key and mode changes, sheet cancel, rows rebuilt under a sheet, hidden refresh, warning UI recovery")
    print("Rendered UI to \(directory)")
}
