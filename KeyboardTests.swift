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
    do { _ = try engine.apply(source: sources[0], target: targets[6]); preconditionFailure("Expected activation failure") } catch {}
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
        manager.reconcile(source: source, target: target, active: active)
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
    let disappeared = disappearanceManager.reconcile(source: command, target: f19, active: true)
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
    _ = engine.keyboards.reconcile(source: sources[0], target: f19, active: true)
    engine.keyboards.setMode(.on, for: virtual.identity.key)
    engine.keyboards.setMode(.off, for: disconnected.identity.key)
    devices = [builtIn, virtual]
    virtual.mappings = []; virtual.failWrite = true
    for _ in 0..<3 { _ = engine.keyboards.reconcile(source: sources[0], target: f19, active: true) }
    let delegate = AppDelegate(engine: engine)
    delegate.buildWindow()
    delegate.window.makeFirstResponder(nil)
    delegate.updateMenu()
    defer { if let item = delegate.item { NSStatusBar.system.removeStatusItem(item) } }
    let settings = KeyboardSettingsController(manager: engine.keyboards) {
        _ = engine.keyboards.reconcile(source: sources[0], target: f19, active: true)
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
        view.window?.orderOut(nil)
    }
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        delegate.window.appearance = NSAppearance(named: appearance)
        settings.window.appearance = NSAppearance(named: appearance)
        try save(delegate.window.contentView!, "settings-\(name).png")
        try save(settings.window.contentView!, "keyboards-\(name).png")
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let ui = descendants(settings.window.contentView!)
    let toggle = ui.compactMap { $0 as? NSSwitch }.first!
    toggle.state = .off; _ = toggle.sendAction(toggle.action, to: toggle.target)
    precondition(!engine.keyboards.defaultEnabled)
    let segments = ui.compactMap { $0 as? NSSegmentedControl }
    let virtualControl = segments[1]
    virtualControl.selectedSegment = 0
    _ = virtualControl.sendAction(virtualControl.action, to: virtualControl.target)
    precondition(engine.keyboards.known[virtual.identity.key]?.mode == .off)
    precondition(engine.keyboards.warning == nil && delegate.keyboardWarningRow.isHidden && delegate.warningBadge.isHidden)
    precondition(virtualControl.superview != nil, "Mode changes must preserve the focused native control")
    let detachedControl = segments[2]
    detachedControl.selectedSegment = 2
    _ = detachedControl.sendAction(detachedControl.action, to: detachedControl.target)
    precondition(engine.keyboards.known[disconnected.identity.key]?.mode == .on, "Disconnected rows remain editable")
    devices.append(disconnected)
    _ = engine.keyboards.reconcile(source: sources[0], target: f19, active: true)
    settings.refresh()
    precondition(disconnected.mappings.contains { $0[srcKey]?.uint64Value == sources[0] && $0[dstKey]?.uint64Value == f19 })
    delegate.refreshKeyboardState()
    delegate.window.appearance = NSAppearance(named: .aqua)
    try save(delegate.window.contentView!, "settings-recovered.png")
    print("PASS: native default switch, per-keyboard segment actions, disconnected editing/reconnection, warning UI recovery")
    print("Rendered UI to \(directory)")
}
