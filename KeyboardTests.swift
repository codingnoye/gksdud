import AppKit

#if TESTS
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
    let comboOnly = TestKeyboard("11", serial: "combo-only")
    devices = [comboOnly]; _ = repair()
    _ = manager.reconcile(sources: [capsLock, spaceCombos[0]], target: f19, active: true)
    precondition(comboOnly.mappings == [mapping(capsLock, f19)], "Space combinations are never mapped in HID")
    precondition(manager.reconcile(sources: [spaceCombos[1]], target: f19, active: true).applied == 0
        && comboOnly.mappings.isEmpty && manager.records[comboOnly.registryID] == nil, "With only combinations, keyboards get their own keys back")
    manager.setSources([spaceCombos[0], option], for: comboOnly.identity.key)
    precondition(manager.known[comboOnly.identity.key]?.sources == [option], "A keyboard's own keys cannot hold combinations")
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

// Caps Lock chosen as a Korean/English key while Caps Lock in Korean is on, from the menu and from the keyboard sheet.
// Warnings are answered in order without a modal loop; nothing may reach system settings.
func runCapsLockKeyTests() {
    _ = NSApplication.shared
    let suite = "io.gksdud.caps-key-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let keyboard = TestKeyboard("caps-key-1", name: "Keyboard", serial: "caps-key"), key = keyboard.identity.key
    let untouched = ShortcutPreferences(read: { [:] }, write: { _ in preconditionFailure("A warning must stop the change before it is applied") }, activate: {})
    let engine = Engine(defaults: defaults, discover: { [keyboard] }, shortcutPreferences: untouched)
    defaults.set(false, forKey: "active")
    _ = try? engine.keyboards.snapshot()
    let delegate = AppDelegate(engine: engine)
    delegate.buildWindow()
    var answers: [NSApplication.ModalResponse] = [], warnings: [String] = []
    delegate.runAlert = { alert in
        warnings.append(alert.messageText)
        return answers.isEmpty ? .alertSecondButtonReturn : answers.removeFirst()
    }
    let capsWarning = "Caps Lock을 한영 키로 사용합니다.", otherMapping = "\(sourceNames[2])에 다른 매핑이 있습니다."
    let capsMapped: Mapping = [srcKey: NSNumber(value: sources[2]), dstKey: NSNumber(value: UInt64(0x7000000e2))]
    func chooseCapsLock(_ replies: [NSApplication.ModalResponse]) {
        answers = replies; warnings = []
        delegate.picker.selectItem(withTitle: sourceNames[2])
        precondition(delegate.picker.sendAction(delegate.picker.action, to: delegate.picker.target))
    }
    // Saved first and undone on a cancelled warning, like the sheet.
    func setKeyboardKeys(_ keys: [UInt64]?, _ replies: [NSApplication.ModalResponse]) {
        answers = replies; warnings = []
        let saved = engine.keyboards.known[key]?.sources
        engine.keyboards.setSources(keys, for: key)
        if !delegate.confirmKeyboardChange([key]) { engine.keyboards.setSources(saved, for: key) }
    }
    defaults.set(true, forKey: "koreanCapsLock")
    chooseCapsLock([])
    precondition(warnings == [capsWarning] && engine.defaultSources == [sources[0]] && engine.koreanCapsLock, "Cancel keeps both the keys and Caps Lock in Korean")
    chooseCapsLock([.alertFirstButtonReturn])
    precondition(engine.defaultSources == [sources[2]] && !engine.koreanCapsLock, "Confirming turns Caps Lock in Korean off")
    precondition(!delegate.koreanCapsSwitch.isEnabled && delegate.koreanCapsSwitch.state == .off)
    engine.defaultSources = [sources[0]]; delegate.resetSelection()
    // Confirmed, then cancelled at the next warning: Caps Lock already has another mapping, so nothing is applied.
    keyboard.mappings = [capsMapped]
    defaults.set(true, forKey: "koreanCapsLock")
    delegate.enabled.state = .on
    chooseCapsLock([.alertFirstButtonReturn])
    precondition(warnings == [capsWarning, otherMapping], "Both warnings are shown in order")
    precondition(engine.defaultSources == [sources[0]] && engine.koreanCapsLock, "A change cancelled after the Caps Lock warning keeps Caps Lock in Korean")
    keyboard.mappings = []
    setKeyboardKeys([sources[2]], [])
    precondition(warnings == [capsWarning] && engine.keyboards.known[key]?.sources == nil && engine.koreanCapsLock,
        "Cancel in the keyboard sheet keeps the keyboard's keys and Caps Lock in Korean")
    setKeyboardKeys([sources[2]], [.alertFirstButtonReturn])
    precondition(engine.keyboards.known[key]?.sources == [sources[2]] && !engine.koreanCapsLock, "One keyboard's Caps Lock key turns Caps Lock in Korean off")
    engine.keyboards.setSources(nil, for: key)
    keyboard.mappings = [capsMapped]
    defaults.set(true, forKey: "koreanCapsLock"); defaults.set(true, forKey: "active")
    setKeyboardKeys([sources[2]], [.alertFirstButtonReturn])
    precondition(warnings == [capsWarning, otherMapping] && engine.keyboards.known[key]?.sources == nil && engine.koreanCapsLock,
        "A sheet change cancelled after the Caps Lock warning keeps Caps Lock in Korean")
    delegate.specialStatus.isHidden = false; delegate.refreshSpecialMode()
    precondition(delegate.specialStatus.isHidden, "Empty special-character status takes no room")
    print("PASS: Caps Lock as a Korean/English key from the menu and the keyboard sheet: warning, cancel, confirm, cancel at the next warning")
}

// Renders native UI against fake devices; never opens a real HID client or applies system settings.
func renderKeyboardUI(to directory: String) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // Rendering must not depend on this process's Accessibility permission.
    SourcePicker.combosAvailable = { true }
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
    let settings = KeyboardSettingsController(engine: engine, targetPicker: delegate.targetPicker, sourcesChanged: { delegate.picker.show($0); delegate.selectionChanged() }, confirm: {
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
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
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
    // Right Control goes last: the screenshots and later checks start from it.
    for (title, usage): (String, UInt64) in [("Ctrl ⌃ + Space ␣", spaceCombos[0]), ("Cmd ⌘ + Space ␣", spaceCombos[1]), ("Opt ⌥ + Space ␣", spaceCombos[2]),
                                          ("우측 Command ⌘", 0x7000000e7), ("우측 Option ⌥", 0x7000000e6),
                                          ("Caps Lock ⇪", 0x700000039), ("우측 Control ⌃", 0x7000000e4)] {
        delegate.picker.selectItem(withTitle: title)
        precondition(delegate.picker.sendAction(delegate.picker.action, to: delegate.picker.target))
        precondition(engine.defaultSources == [usage], "The selected label must save the matching HID key")
        delegate.picker.selectItem(at: 0)
        delegate.resetSelection()
        precondition(delegate.picker.titleOfSelectedItem == title, "Saved key selection must be restored")
    }
    SourcePicker.combosAvailable = { false }
    if let menu = delegate.picker.menu { delegate.picker.menuNeedsUpdate(menu) }
    precondition(spaceComboNames.allSatisfy { delegate.picker.item(withTitle: $0)?.isEnabled == false }
        && sourceNames.allSatisfy { delegate.picker.item(withTitle: $0)?.isEnabled == true }, "Combinations wait for Accessibility")
    SourcePicker.combosAvailable = { true }
    if let menu = delegate.picker.menu { delegate.picker.menuNeedsUpdate(menu) }
    delegate.selectTab(0)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        delegate.window.appearance = NSAppearance(named: appearance)
        try save(delegate.window.contentView!, "right-control-\(name).png")
    }
    print("PASS: source picker actions and saved selection for right Command, right Option, Caps Lock, right Control and Space combinations")
    // 입력 소스 추가, cycling with a saved source macOS no longer offers, then with a separate key.
    let enabledSources = delegate.enabledSources()
    defaults.set(true, forKey: "addedSources")
    engine.cycleSources = defaultCycle(enabledSources) + ["com.example.inputmethod.Removed"]
    delegate.addedSources.refresh(force: true)
    precondition(delegate.addedSources.list.arrangedSubviews.count == enabledSources.count + 1)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        delegate.window.appearance = NSAppearance(named: appearance); delegate.selectTab(2)
        try save(delegate.window.contentView!, "added-cycle-\(name).png")
    }
    defaults.set(AddedSourceMode.separate.rawValue, forKey: "addedSourceMode")
    engine.separateKey = sources[1]; engine.separateSource = enabledSources.first { !isKorean($0) && !isEnglish($0) }?.id
    delegate.addedSources.refresh(force: true)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        delegate.window.appearance = NSAppearance(named: appearance); delegate.selectTab(2)
        try save(delegate.window.contentView!, "added-separate-\(name).png")
    }
    engine.separateKey = engine.mappedSources.first; delegate.addedSources.refresh(force: true)
    precondition(!delegate.addedSources.warning.isHidden || !AXIsProcessTrusted(), "A separate key that is a Korean/English key is shown")
    try save(delegate.window.contentView!, "added-separate-conflict.png")
    for key in ["addedSources", "addedSourceMode", "cycleSources", "separateKey", "separateSource"] { defaults.removeObject(forKey: key) }
    delegate.addedSources.refresh(force: true)
    // Caps Lock chosen as a Korean/English key while Caps Lock in Korean is on: the warning, then the tab once confirmed.
    // runCapsLockKeyTests checks the answers.
    defaults.set(true, forKey: "koreanCapsLock")
    let savedSources = engine.defaultSources
    delegate.runAlert = { alert in
        alert.layout(); try? save(alert.window.contentView!, "caps-taken-alert.png")
        return .alertFirstButtonReturn
    }
    delegate.picker.selectItem(withTitle: sourceNames[2])
    precondition(delegate.picker.sendAction(delegate.picker.action, to: delegate.picker.target))
    delegate.runAlert = { $0.runModal() }
    delegate.selectTab(1)
    try save(delegate.window.contentView!, "caps-taken.png")
    engine.defaultSources = savedSources; delegate.resetSelection()
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
    precondition(defaultPicker.itemTitles.contains(spaceComboNames[0]) && !builtInPicker.itemTitles.contains(spaceComboNames[0]),
        "Only the global picker offers combinations")
    toggleMultiple(defaultPicker, [spaceComboNames[0]])
    settings.changed()
    precondition(engine.defaultSources == [sources[1], sources[2], spaceCombos[0]] && defaultPicker.titleOfSelectedItem == "\(sourceNames[1]) +2"
        && builtInPicker.titleOfSelectedItem == "기본값 (\(sourceNames[1]) +1)" && !builtIn.mappings.contains { $0[srcKey]?.uint64Value == spaceCombos[0] },
        "Default rows follow only the single global keys")
    choose(defaultPicker, defaultPicker.numberOfItems - 1)
    try save(settings.window.attachedSheet!.contentView!, "keyboards-combos-sheet.png")
    descendants(settings.window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "취소" }!.performClick(nil)
    toggleMultiple(defaultPicker, [sourceNames[1], sourceNames[2]])
    settings.changed()
    precondition(engine.defaultSources == [spaceCombos[0]] && builtInPicker.titleOfSelectedItem == "기본값"
        && !builtIn.mappings.contains { $0[dstKey]?.uint64Value == f19 }, "With only combinations, Default keyboards keep their own keys")
    SourcePicker.combosAvailable = { false }
    choose(defaultPicker, defaultPicker.numberOfItems - 1)
    let unavailable = descendants(settings.window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }
    precondition(unavailable.first { $0.title == spaceComboNames[0] }?.isEnabled == false && unavailable.first { $0.title == sourceNames[0] }?.isEnabled == true,
        "The sheet also waits for Accessibility")
    unavailable.first { $0.title == "취소" }!.performClick(nil)
    SourcePicker.combosAvailable = { true }
    toggleMultiple(defaultPicker, [sourceNames[1], sourceNames[2], spaceComboNames[0]])
    precondition(engine.defaultSources == [sources[1], sources[2]])
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

// The separate key maps beside the Korean/English keys on its own F-key, and gives way to them.
func runSeparateKeyTests() {
    func mapping(_ source: UInt64, _ target: UInt64) -> Mapping { [srcKey: NSNumber(value: source), dstKey: NSNumber(value: target)] }
    func same(_ lhs: [Mapping], _ rhs: [Mapping]) -> Bool { KeyboardManager.canonical(lhs) == KeyboardManager.canonical(rhs) }
    let command = sources[0], option = sources[1], capsLock = sources[2], leftOption: UInt64 = 0x7000000e2, f18 = targets[5].usage
    let suite = "io.gksdud.separate-key-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let keyboard = TestKeyboard("s1", serial: "separate", mappings: [mapping(option, leftOption)])
    var devices: [KeyboardDevice] = [keyboard]
    let manager = KeyboardManager(defaults: defaults, discover: { devices })
    let extra = ExtraKey(source: option, target: f18)
    func repair(_ extra: ExtraKey?, active: Bool = true) -> KeyboardReconcileResult {
        manager.reconcile(sources: [command], target: f19, active: active, extra: extra)
    }
    _ = repair(extra)
    precondition(same(keyboard.mappings, [mapping(command, f19), mapping(option, f18)]), "The separate key goes to its own F-key")
    precondition(owns(manager.records[keyboard.registryID], mapping(option, f18)), "Its mapping is ours")
    var writes = keyboard.writes; _ = repair(extra)
    precondition(keyboard.writes == writes, "Unchanged hardware is not rewritten")
    _ = repair(nil)
    precondition(same(keyboard.mappings, [mapping(command, f19), mapping(option, leftOption)]), "Without it, the key's own mapping comes back")
    _ = repair(ExtraKey(source: command, target: f18))
    precondition(same(keyboard.mappings, [mapping(command, f19), mapping(option, leftOption)]), "A Korean/English key stays one")
    _ = repair(extra); _ = repair(extra, active: false)
    precondition(keyboard.mappings == [mapping(option, leftOption)] && manager.records[keyboard.registryID] == nil, "Turning off restores it too")
    keyboard.afterWrite = { keyboard.failRead = true }
    _ = repair(extra)
    keyboard.afterWrite = nil; keyboard.failRead = false
    _ = repair(nil, active: false)
    precondition(keyboard.mappings == [mapping(option, leftOption)], "A failed readback still undoes the separate key")
    manager.setSources([option], for: keyboard.identity.key)
    _ = repair(extra)
    precondition(same(keyboard.mappings, [mapping(option, f19)]), "A keyboard whose own Korean/English key it is keeps that")
    manager.setSources(nil, for: keyboard.identity.key)
    writes = keyboard.writes; _ = repair(extra)
    precondition(same(keyboard.mappings, [mapping(command, f19), mapping(option, f18)]) && keyboard.writes == writes + 1, "Moving between roles is one write")
    _ = repair(nil, active: false)
    let taken = TestKeyboard("s2", serial: "taken", mappings: [mapping(capsLock, f18)])
    devices = [taken]
    let blocked = repair(extra)
    precondition(blocked.extraBlocked == 1 && blocked.pending == 0 && same(taken.mappings, [mapping(capsLock, f18), mapping(command, f19)]),
        "A taken F-key leaves the Korean/English key working")
    _ = repair(nil, active: false)
    precondition(taken.mappings == [mapping(capsLock, f18)])

    // Settings: the separate key maps only when it is a single key, a source is chosen, and the tap can act on it.
    let engineSuite = "io.gksdud.separate-engine-tests.\(UUID().uuidString)"
    let engineDefaults = UserDefaults(suiteName: engineSuite)!
    defer { engineDefaults.removePersistentDomain(forName: engineSuite) }
    let engine = Engine(defaults: engineDefaults, discover: { [] })
    var trusted = true
    engine.accessibilityTrusted = { trusted }
    engineDefaults.set(true, forKey: "addedSources"); engineDefaults.set(AddedSourceMode.separate.rawValue, forKey: "addedSourceMode")
    engine.separateKey = option
    precondition(engine.separateMapping == nil, "No mapping before an input source is chosen")
    engine.separateSource = "com.apple.inputmethod.SCIM.ITABC"
    precondition(engine.separateMapping == ExtraKey(source: option, target: f18) && engine.separateTarget.name == "F18")
    engineDefaults.set("F18", forKey: "target")
    precondition(engine.separateTarget.name == "F17", "Never the Korean/English key's F-key")
    trusted = false
    precondition(engine.separateMapping == nil, "Without the tap the key keeps its function")
    trusted = true
    engine.separateKey = spaceCombos[2]
    precondition(engine.separateMapping == nil && engine.separateKey == spaceCombos[2], "A Space combination is not mapped")
    engineDefaults.set(99, forKey: "separateKey")
    precondition(engine.separateKey == nil, "An unknown saved key is no key")
    engine.separateKey = capsLock
    precondition(engine.capsLockSwitches(), "A Caps Lock separate key takes Caps Lock like a Korean/English one")
    engineDefaults.set(AddedSourceMode.cycle.rawValue, forKey: "addedSourceMode")
    precondition(!engine.capsLockSwitches() && engine.separateMapping == nil, "Cycling leaves the separate key unused")
    engineDefaults.set(AddedSourceMode.separate.rawValue, forKey: "addedSourceMode")
    engine.separateKey = command
    precondition(engine.separateKeyIsHangulKey() && !engine.separateKeyIsHangulKey([option]), "The Korean/English keys, saved or about to be")
    engineDefaults.set(false, forKey: "active")
    precondition(engine.separateMapping == nil)
    print("PASS: separate key on its own F-key, undo, failed readback, Korean/English keys first, taken F-key, settings")
}

// The tap takes the separate key's F-key only while the separate key is mapped to it.
func runSeparateKeyTapTests() {
    let suite = "io.gksdud.separate-tap-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let keyboard = TestKeyboard("st-1", name: "Keyboard", serial: "separate-tap")
    let untouched = ShortcutPreferences(read: { [:] }, write: { _ in }, activate: {})
    let engine = Engine(defaults: defaults, discover: { [keyboard] }, shortcutPreferences: untouched)
    var trusted = true
    engine.accessibilityTrusted = { trusted }
    defaults.set(true, forKey: "active")
    defaults.set(true, forKey: "addedSources"); defaults.set(AddedSourceMode.separate.rawValue, forKey: "addedSourceMode")
    engine.separateKey = sources[1]; engine.separateSource = "com.apple.inputmethod.SCIM.ITABC"
    let delegate = AppDelegate(engine: engine)
    let target = engine.separateTarget, code = Int64(target.keyCode)
    func reconcile() { engine.keyboards.reconcile(sources: [sources[0]], target: f19, active: true, extra: engine.separateMapping) }
    reconcile()
    precondition(delegate.takesSeparateKey(code) && !delegate.takesSeparateKey(Int64(engine.target.keyCode)), "The mapped separate key's F-key is taken")
    // Caps Lock already sends that F-key for another app.
    keyboard.mappings.append([srcKey: NSNumber(value: sources[2]), dstKey: NSNumber(value: target.usage)])
    reconcile()
    precondition(engine.keyboards.result.extraBlocked == 1 && !delegate.takesSeparateKey(code), "A taken F-key stays the other mapping's")
    keyboard.mappings.removeAll { $0[srcKey]?.uint64Value == sources[2] }
    reconcile()
    precondition(delegate.takesSeparateKey(code), "Freed again, it is taken again")
    trusted = false
    precondition(!delegate.takesSeparateKey(code), "Without Accessibility nothing is taken")
    print("PASS: separate key's F-key taken only while mapped, left to another mapping that sends it")
}

// Warnings when the separate key and a Korean/English key meet, from either side.
func runSeparateKeyWarningTests() {
    _ = NSApplication.shared
    let suite = "io.gksdud.separate-warning-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let keyboard = TestKeyboard("sw-1", name: "Keyboard", serial: "separate-warning")
    // Spotlight on ⌘ + Space, and a shortcut on F18 alone.
    let systemShortcuts: [String: Any] = ["64": ["enabled": true, "value": ["type": "standard", "parameters": [32, 49, 1048576]]],
                                          "900": ["enabled": true, "value": ["type": "standard", "parameters": [65535, 79, 0]]],
                                          "901": ["enabled": false, "value": ["type": "standard", "parameters": [32, 49, 262144]]]]
    let untouched = ShortcutPreferences(read: { systemShortcuts }, write: { _ in }, activate: {})
    let engine = Engine(defaults: defaults, discover: { [keyboard] }, shortcutPreferences: untouched)
    defaults.set(false, forKey: "active")
    defaults.set(true, forKey: "addedSources"); defaults.set(AddedSourceMode.separate.rawValue, forKey: "addedSourceMode")
    _ = try? engine.keyboards.snapshot()
    let delegate = AppDelegate(engine: engine)
    delegate.buildWindow()
    var answers: [NSApplication.ModalResponse] = [], warnings: [String] = []
    delegate.runAlert = { alert in
        warnings.append(alert.messageText)
        return answers.isEmpty ? .alertSecondButtonReturn : answers.removeFirst()
    }
    let keyPicker = delegate.addedSources.keyPicker
    func chooseSeparate(_ title: String, _ replies: [NSApplication.ModalResponse] = []) {
        answers = replies; warnings = []
        delegate.addedSources.refresh(force: true)
        keyPicker.selectItem(withTitle: title)
        precondition(keyPicker.sendAction(keyPicker.action, to: keyPicker.target))
    }
    chooseSeparate(sourceNames[0])
    precondition(warnings == ["\(sourceNames[0])은 한영 키로 사용 중입니다."] && engine.separateKey == nil, "A Korean/English key cannot be the separate key")
    chooseSeparate(sourceNames[1])
    precondition(warnings.isEmpty && engine.separateKey == sources[1] && keyPicker.titleOfSelectedItem == sourceNames[1])
    // From the Korean/English side: cancel keeps both, confirm clears the separate key.
    let separateWarning = "\(sourceNames[1])은 입력 소스 추가의 전환 키입니다."
    answers = []; warnings = []
    delegate.picker.selectItem(withTitle: sourceNames[1])
    precondition(delegate.picker.sendAction(delegate.picker.action, to: delegate.picker.target))
    precondition(warnings == [separateWarning] && engine.defaultSources == [sources[0]] && engine.separateKey == sources[1], "Cancel keeps both keys")
    answers = [.alertFirstButtonReturn]; warnings = []
    delegate.picker.selectItem(withTitle: sourceNames[1])
    precondition(delegate.picker.sendAction(delegate.picker.action, to: delegate.picker.target))
    precondition(engine.defaultSources == [sources[1]] && engine.separateKey == nil, "Confirming makes it a Korean/English key only")
    engine.defaultSources = [sources[0]]; delegate.resetSelection()
    chooseSeparate(sourceNames[1])
    // The keyboard sheet saves first and undoes a cancelled change.
    let key = keyboard.identity.key
    answers = []; warnings = []
    engine.keyboards.setSources([sources[1]], for: key)
    if !delegate.confirmKeyboardChange([key]) { engine.keyboards.setSources(nil, for: key) }
    precondition(warnings == [separateWarning] && engine.keyboards.known[key]?.sources == nil && engine.separateKey == sources[1])
    answers = [.alertFirstButtonReturn]
    engine.keyboards.setSources([sources[1]], for: key)
    precondition(delegate.confirmKeyboardChange([key]) && engine.separateKey == nil, "One keyboard's key is enough to clear it")
    engine.keyboards.setSources(nil, for: key)
    // Caps Lock stops being Caps Lock, so Caps Lock in Korean asks first.
    defaults.set(true, forKey: "koreanCapsLock")
    chooseSeparate(sourceNames[2])
    precondition(warnings == ["Caps Lock을 전환 키로 사용합니다."] && engine.separateKey == nil && engine.koreanCapsLock, "Cancel keeps Caps Lock in Korean")
    chooseSeparate(sourceNames[2], [.alertFirstButtonReturn])
    precondition(engine.separateKey == sources[2] && !engine.koreanCapsLock, "Confirming turns Caps Lock in Korean off")
    // Another app's mapping of the key.
    keyboard.mappings = [[srcKey: NSNumber(value: sources[3]), dstKey: NSNumber(value: UInt64(0x7000000e2))]]
    chooseSeparate(sourceNames[3])
    precondition(warnings == ["\(sourceNames[3])에 다른 매핑이 있습니다."] && engine.separateKey == sources[2], "Cancel keeps the old key")
    chooseSeparate(sourceNames[3], [.alertFirstButtonReturn])
    precondition(engine.separateKey == sources[3])
    chooseSeparate("선택 안 함")
    precondition(engine.separateKey == nil && warnings.isEmpty)
    // A system shortcut on the same Space combination; a disabled one does not count.
    chooseSeparate(spaceComboNames[1])
    precondition(warnings == ["\(spaceComboNames[1])은 시스템 단축키에서 사용 중입니다."] && engine.separateKey == nil, "Cancel keeps Spotlight")
    chooseSeparate(spaceComboNames[1], [.alertFirstButtonReturn])
    precondition(engine.separateKey == spaceCombos[1])
    chooseSeparate(spaceComboNames[0])
    precondition(warnings.isEmpty && engine.separateKey == spaceCombos[0], "Only enabled shortcuts count")
    // Preservation off turns Caps Lock in Korean off with it, so Caps Lock as a separate key no longer warns about it.
    defaults.set(true, forKey: "preserveCapsLock"); defaults.set(true, forKey: "koreanCapsLock")
    delegate.preserveCapsSwitch.state = .off; delegate.toggleFeature(delegate.preserveCapsSwitch)
    precondition(!defaults.bool(forKey: "preserveCapsLock") && !defaults.bool(forKey: "koreanCapsLock"))
    delegate.preserveCapsSwitch.state = .on; delegate.toggleFeature(delegate.preserveCapsSwitch)
    precondition(!defaults.bool(forKey: "koreanCapsLock"), "Turning preservation back on leaves it off")
    defaults.set(false, forKey: "preserveCapsLock"); defaults.set(true, forKey: "koreanCapsLock")
    delegate.turnOffUnusedKoreanCaps()
    precondition(!defaults.bool(forKey: "koreanCapsLock"), "A choice saved before this is cleared at launch")
    chooseSeparate(sourceNames[2])
    precondition(warnings.isEmpty && engine.separateKey == sources[2])
    chooseSeparate(spaceComboNames[0])
    // The F-key the tap takes for the separate key avoids one a system shortcut uses alone; saving a choice reads them.
    precondition(engine.systemFKeys == [79] && engine.separateTarget.name == "F17", "F18 has a system shortcut")
    print("PASS: separate key against Korean/English keys from both sides, the keyboard sheet, Caps Lock in Korean, other mappings, system shortcuts, Caps Lock in Korean off with preservation")
}
// Without Accessibility there is nothing to switch with: activation turns off and only the permission button and the
// gksdud tab stay usable. Granting it again leaves activation off until turned on.
func runPermissionTests() {
    _ = NSApplication.shared
    let suite = "io.gksdud.permission-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let keyboard = TestKeyboard("perm-1", name: "Keyboard", serial: "permission")
    let untouched = ShortcutPreferences(read: { [:] }, write: { _ in preconditionFailure("Nothing to restore") }, activate: {})
    let engine = Engine(defaults: defaults, discover: { [keyboard] }, shortcutPreferences: untouched)
    var trusted = false
    engine.accessibilityTrusted = { trusted }
    defaults.set(true, forKey: "active")
    let delegate = AppDelegate(engine: engine)
    delegate.buildWindow()
    delegate.updatePressAccess()
    let settings: [NSControl] = [delegate.enabled, delegate.login, delegate.showInMenuBar, delegate.iconPicker, delegate.picker,
                                 delegate.advancedButton, delegate.longPressSwitch, delegate.escapeSwitch, delegate.addedSources.enable] + delegate.specialButtons
    precondition(settings.allSatisfy { !$0.isEnabled } && delegate.pressAccess.isEnabled, "Only the permission button is left")
    precondition(delegate.settingLabels.allSatisfy { $0.label.textColor == .disabledControlTextColor }, "Titles and hints dim too")
    delegate.picker.show([sources[0], sources[1]])
    delegate.picker.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: delegate.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    precondition(delegate.window.attachedSheet == nil, "Holding several keys, the picker does not open their sheet either")
    delegate.resetSelection()
    delegate.repair()
    precondition(!engine.active && delegate.enabled.state == .off, "Activation turns off")
    trusted = true
    // The section refreshes while the window shows; this one is not on screen.
    delegate.updatePressAccess(); delegate.addedSources.refresh(force: true)
    precondition(settings.allSatisfy { $0.isEnabled } && !delegate.pressAccess.isEnabled)
    precondition(delegate.settingLabels.allSatisfy { $0.label.textColor == $0.color })
    precondition(!engine.active && delegate.enabled.state == .off, "It stays off until turned on again")
    // Replacing the Mac input menu is on by default and works only while this app's icon shows.
    precondition(delegate.replaceInputMenu.state == .on && delegate.replaceInputMenu.isEnabled && !engine.showsSystemInputMenu)
    delegate.replaceInputMenu.state = .off; delegate.toggleReplaceInputMenu()
    precondition(!engine.replacesInputMenu && engine.showsSystemInputMenu, "Unchecked, both menus show")
    delegate.replaceInputMenu.state = .on; delegate.toggleReplaceInputMenu()
    delegate.showInMenuBar.state = .off; delegate.toggleHidden()
    precondition(!delegate.replaceInputMenu.isEnabled && delegate.replaceInputMenu.state == .on && engine.showsSystemInputMenu,
        "Without this app's icon the Mac input menu shows, and the choice waits")
    delegate.showInMenuBar.state = .on; delegate.toggleHidden()
    precondition(delegate.replaceInputMenu.isEnabled && !engine.showsSystemInputMenu)
    print("PASS: without Accessibility, settings disabled and activation off; granted again, settings back and activation still off; replacing the Mac input menu")
}
#endif
