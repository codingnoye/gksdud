import AppKit
import ServiceManagement
import IOKit
import Carbon
import QuartzCore

let srcKey = "HIDKeyboardModifierMappingSrc"
let dstKey = "HIDKeyboardModifierMappingDst"
let f19: UInt64 = 0x70000006e
struct TargetKey {
    let name: String
    let usage: UInt64
    let keyCode: Int
}
let targets = zip(13...20, [105, 107, 113, 106, 64, 79, 80, 90]).map {
    TargetKey(name: "F\($0.0)", usage: 0x700000068 + UInt64($0.0 - 13), keyCode: $0.1)
}
let sources: [UInt64] = [0x7000000e7, 0x7000000e6, 0x700000039]
typealias Mapping = [String: NSNumber]

func targetConflict(_ mappings: [Mapping], source: UInt64, target: UInt64, owned: [String: String]?) -> Bool {
    mappings.contains { mapping in
        let ours = owned?["source"] == mapping[srcKey].map { String($0.uint64Value) }
            && owned?["target"] == mapping[dstKey].map { String($0.uint64Value) }
            && owned != nil
        return mapping[srcKey]?.uint64Value != source && mapping[dstKey]?.uint64Value == target && !ours
    }
}

// Only remove our own destination; preserve unrelated mappings and later edits.
func merged(_ current: [Mapping], source: UInt64, previous: UInt64?, original: NSNumber?, target: UInt64 = f19, previousTarget: UInt64 = f19) -> [Mapping] {
    var result = current
    if let previous, previous != source {
        let owned = result.contains { $0[srcKey]?.uint64Value == previous && $0[dstKey]?.uint64Value == previousTarget }
        if owned {
            result.removeAll { $0[srcKey]?.uint64Value == previous }
            if let original { result.append([srcKey: NSNumber(value: previous), dstKey: original]) }
        }
    }
    result.removeAll { $0[srcKey]?.uint64Value == source }
    result.append([srcKey: NSNumber(value: source), dstKey: NSNumber(value: target)])
    return result
}

struct ShortcutPreferences {
    var read: () -> [String: Any]
    var write: ([String: Any]) throws -> Void
    var activate: () throws -> Void

    static let system = ShortcutPreferences(read: {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any] ?? [:]
    }, write: { keys in
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesSetAppValue("AppleSymbolicHotKeys" as CFString, keys as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            throw NSError(domain: "gksdud", code: 1, userInfo: [NSLocalizedDescriptionKey: "입력 소스 단축키를 저장하지 못했습니다."])
        }
    }, activate: {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        // Apply session shortcuts without reapplying physical-device preferences,
        // which can overwrite another app's per-device mouse acceleration settings.
        process.arguments = ["-u", "-virtualSession"]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "gksdud", code: 2, userInfo: [NSLocalizedDescriptionKey: "단축키 활성화에 실패했습니다. 다시 시도해주세요."])
        }
    })
}

final class Engine {
    let defaults: UserDefaults
    let keyboards: KeyboardManager
    let shortcutPreferences: ShortcutPreferences
    private var settingsUpdateDepth = 0
    var isUpdatingSettings: Bool { settingsUpdateDepth > 0 }
    init(defaults: UserDefaults = .standard, discover: @escaping () throws -> [KeyboardDevice] = HIDKeyboardDevice.discover,
         shortcutPreferences: ShortcutPreferences = .system) {
        self.defaults = defaults
        self.shortcutPreferences = shortcutPreferences
        keyboards = KeyboardManager(defaults: defaults, discover: discover)
    }
    var source: UInt64 { UInt64(defaults.string(forKey: "source") ?? "") ?? sources[0] }
    var active: Bool { defaults.object(forKey: "active") == nil || defaults.bool(forKey: "active") }
    var switchOnKeyDown: Bool { defaults.object(forKey: "switchOnKeyDown") == nil || defaults.bool(forKey: "switchOnKeyDown") }
    var longPressCapsLock: Bool { defaults.bool(forKey: "longPressCapsLock") }
    var preserveCapsLock: Bool { defaults.object(forKey: "preserveCapsLock") == nil || defaults.bool(forKey: "preserveCapsLock") }
    var testInputText: String {
        get { defaults.string(forKey: "testInputText") ?? "한dud한dud한dud한dud" }
        set { defaults.set(newValue, forKey: "testInputText") }
    }
    var target: TargetKey { targets.first { $0.name == defaults.string(forKey: "target") } ?? targets[6] }
    var records: [String: [String: String]] {
        get { keyboards.records }
        set { keyboards.records = newValue }
    }
    func services() -> [KeyboardDevice] { (try? keyboards.snapshot()) ?? [] }
    func mappings(_ service: KeyboardDevice) -> [Mapping] { (try? service.readMappings()) ?? [] }
    func id(_ service: KeyboardDevice) -> String { service.registryID }
    func conflicts(_ source: UInt64, target: TargetKey) -> Bool {
        services().filter { keyboards.isSelected($0) }.contains { service in mappings(service).contains {
            let managed = records[id(service)]
            let owned = managed?["source"] == String(source) && managed?["target"] == $0[dstKey].map { String($0.uint64Value) }
            return $0[srcKey]?.uint64Value == source && $0[dstKey]?.uint64Value != target.usage && !owned
        } }
    }
    func targetInUse(_ source: UInt64, target: TargetKey) -> Bool {
        services().filter { keyboards.isSelected($0) }.contains { service in
            targetConflict(mappings(service), source: source, target: target.usage, owned: records[id(service)])
        }
    }
    static func ownsShortcut(_ raw: Any?, keyCode: Int) -> Bool {
        guard let entry = raw as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
              let value = entry["value"] as? [String: Any], value["type"] as? String == "standard",
              let parameters = value["parameters"] as? [NSNumber], parameters.count == 3 else { return false }
        // macOS can add the function-key identity flag when saving an unmodified F key.
        // Do not ignore actual modifiers such as Command, Control, Option, or Shift.
        return parameters[0].intValue == 65535 && parameters[1].intValue == keyCode
            && [0, Int(CGEventFlags.maskSecondaryFn.rawValue)].contains(parameters[2].intValue)
    }
    var managedShortcutKeyCode: Int {
        (defaults.object(forKey: "managedShortcutKeyCode") as? NSNumber)?.intValue ?? target.keyCode
    }
    static func sameShortcut(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if lhs == nil && rhs == nil { return true }
        guard let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any] else { return false }
        if NSDictionary(dictionary: lhs).isEqual(to: rhs) { return true }
        return targets.contains { ownsShortcut(lhs, keyCode: $0.keyCode) && ownsShortcut(rhs, keyCode: $0.keyCode) }
    }
    func shortcut(target: TargetKey) throws {
        settingsUpdateDepth += 1
        defer { settingsUpdateDepth -= 1 }
        var keys = shortcutPreferences.read()
        for (id, raw) in keys where id != "60" {
            guard let entry = raw as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any], let params = value["parameters"] as? [NSNumber], params.count == 3 else { continue }
            if params[1].intValue == target.keyCode && params[2].intValue == 0 {
                throw NSError(domain: "asd", code: 5, userInfo: [NSLocalizedDescriptionKey: "\(target.name)은 다른 시스템 단축키에서 사용 중입니다. 다른 대상 키를 선택하세요."])
            }
        }
        if !defaults.bool(forKey: "shortcutBackedUp") || !Self.ownsShortcut(keys["60"], keyCode: managedShortcutKeyCode) {
            // A user edit/removal becomes the new baseline before we apply again.
            // set(nil) also clears a stale backup when the entry was removed entirely.
            defaults.set(keys["60"], forKey: "originalShortcut")
            defaults.set(true, forKey: "shortcutBackedUp")
        }
        defaults.removeObject(forKey: "shortcutRestorePending")
        keys["60"] = ["enabled": true, "value": ["type": "standard", "parameters": [65535, target.keyCode, 0]]] as [String: Any]
        defaults.set(target.keyCode, forKey: "managedShortcutKeyCode")
        try shortcutPreferences.write(keys)
        try shortcutPreferences.activate()
    }
    func apply(source: UInt64, target: TargetKey) throws -> Int {
        settingsUpdateDepth += 1
        defer { settingsUpdateDepth -= 1 }
        try shortcut(target: target)
        defaults.set(String(source), forKey: "source")
        defaults.set(target.name, forKey: "target")
        defaults.set(true, forKey: "active")
        let count = try reconcile()
        try hideSystemInputMenu()
        return count
    }
    func setSystemInputMenu(_ value: CFPropertyList?) throws {
        settingsUpdateDepth += 1
        defer { settingsUpdateDepth -= 1 }
        let domain = "com.apple.TextInputMenu" as CFString
        CFPreferencesSetAppValue("visible" as CFString, value, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            throw NSError(domain: "gksdud", code: 10, userInfo: [NSLocalizedDescriptionKey: "기본 입력기 메뉴 표시 설정을 저장하지 못했습니다."])
        }
        // This system agent is KeepAlive-managed by launchd; restart only it to reload preferences.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["TextInputMenuAgent"]
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw NSError(domain: "gksdud", code: 11, userInfo: [NSLocalizedDescriptionKey: "기본 입력기 메뉴를 새로 고치지 못했습니다."])
        }
    }
    func hideSystemInputMenu() throws {
        let domain = "com.apple.TextInputMenu" as CFString
        CFPreferencesAppSynchronize(domain)
        let current = CFPreferencesCopyAppValue("visible" as CFString, domain)
        if !defaults.bool(forKey: "inputMenuBackedUp") {
            if let current { defaults.set(current, forKey: "originalInputMenu") }
            defaults.set(true, forKey: "inputMenuBackedUp")
        }
        let showNativeMenu = defaults.bool(forKey: "hidden")
        if (current as? NSNumber)?.boolValue != showNativeMenu {
            try setSystemInputMenu(showNativeMenu ? kCFBooleanTrue : kCFBooleanFalse)
        }
    }
    func restoreSystemInputMenu() throws {
        guard defaults.bool(forKey: "inputMenuBackedUp") else { return }
        try setSystemInputMenu(defaults.object(forKey: "originalInputMenu") as CFPropertyList?)
        defaults.removeObject(forKey: "originalInputMenu")
        defaults.removeObject(forKey: "inputMenuBackedUp")
    }
    func reconcile() throws -> Int {
        keyboards.reconcile(source: source, target: target.usage, active: active).applied
    }
    func restore() throws {
        settingsUpdateDepth += 1
        defer { settingsUpdateDepth -= 1 }
        defaults.set(false, forKey: "active")
        let mappingResult = keyboards.reconcile(source: source, target: target.usage, active: false)
        // A failed quit must not restore the shortcut while some keys still emit our target.
        if mappingResult.pending > 0 { throw KeyboardError.verification }
        try restoreSystemInputMenu()
        try restoreShortcut()
    }
    func restoreShortcut() throws {
        settingsUpdateDepth += 1
        defer { settingsUpdateDepth -= 1 }
        guard defaults.bool(forKey: "shortcutBackedUp") else { return }
        var keys = shortcutPreferences.read()
        let original = defaults.object(forKey: "originalShortcut")
        let resumeActivation = defaults.bool(forKey: "shortcutRestorePending") && Self.sameShortcut(keys["60"], original)
        if Self.ownsShortcut(keys["60"], keyCode: managedShortcutKeyCode) {
            keys["60"] = original
            defaults.set(true, forKey: "shortcutRestorePending")
            try shortcutPreferences.write(keys)
            try shortcutPreferences.activate()
        } else if resumeActivation {
            // A previous write succeeded but activation failed. Retry before retiring the backup.
            try shortcutPreferences.activate()
        }
        defaults.removeObject(forKey: "shortcutBackedUp")
        defaults.removeObject(forKey: "originalShortcut")
        defaults.removeObject(forKey: "managedShortcutKeyCode")
        defaults.removeObject(forKey: "shortcutRestorePending")
    }
    func repair() throws {
        // Process.waitUntilExit pumps the main run loop. A timer/wake callback must not
        // restore a shortcut halfway through activation or enter a second restoration.
        guard !isUpdatingSettings else { return }
        if active { _ = try reconcile() }
        else { try restore() }
    }
    func prepareForExit() throws {
        let resumeOnLaunch = active
        // Cleanup affects macOS, not the user's saved activation choice, even if quit is cancelled.
        defer { defaults.set(resumeOnLaunch, forKey: "active"); defaults.synchronize() }
        try restore()
    }
    func restoreMappings() throws {
        let result = keyboards.reconcile(source: source, target: target.usage, active: false)
        // Normal repair is non-modal. Explicit quit must preserve undo state if cleanup failed.
        if result.pending > 0 { throw KeyboardError.verification }
    }

}

// Tracks only the reserved function key; never reads or stores typed text.
struct PressGate {
    var held: Set<Int64> = []
    mutating func handle(code: Int64, down: Bool, repeatKey: Bool, active: Bool, target: Int64) -> (consume: Bool, switchNow: Bool) {
        if !down { return (held.remove(code) != nil, false) }
        if held.contains(code) { return (true, false) }
        guard active, code == target, !repeatKey else { return (false, false) }
        held.insert(code)
        return (true, !repeatKey)
    }
}

// This is an explicit user-selected threshold, not a claimed macOS default.
struct LongPressState {
    static let delay: TimeInterval = 0.5
    var key: Int64?
    var started: TimeInterval = 0
    var eager = false
    var fired = false
    var cancelled = false
    mutating func begin(key: Int64, now: TimeInterval, eager: Bool) {
        self.key = key; started = now; self.eager = eager; fired = false; cancelled = false
    }
    mutating func claimLong(now: TimeInterval) -> Bool {
        guard key != nil, !cancelled, !fired, now - started >= Self.delay else { return false }
        fired = true
        return true
    }
    mutating func release(key: Int64, now: TimeInterval) -> (owned: Bool, short: Bool, long: Bool) {
        guard self.key == key else { return (false, false, false) }
        let long = claimLong(now: now)
        let short = !cancelled && !fired && !eager
        self.key = nil
        return (true, short, long)
    }
    mutating func cancel() { cancelled = true }
}

// Logical English case survives the input method clearing the hardware Caps Lock bit.
// It is session-local: activation starts from the current keyboard state.
struct EnglishCapsState {
    private(set) var remembered: Bool?
    var switching = false
    mutating func enable(actual: Bool) { if remembered == nil { remembered = actual } }
    mutating func reset() { remembered = nil; switching = false }
    mutating func willSwitch(english: Bool, actual: Bool, longPress: Bool) {
        if remembered == nil || (english && !longPress && !switching) { remembered = actual }
        switching = true
    }
    mutating func capsKeyChanged(english: Bool, actual: Bool) {
        guard english, !switching else { return }
        remembered = actual
    }
    func target(english: Bool) -> Bool? { english ? remembered : nil }
    func beforeLongPress(actual: Bool, preserving: Bool) -> Bool { preserving ? (remembered ?? actual) : actual }
    mutating func committedLongPress(_ desired: Bool) { remembered = desired }
}

func setCapsLock(_ enabled: Bool) throws {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != IO_OBJECT_NULL else {
        throw NSError(domain: "gksdud", code: 20, userInfo: [NSLocalizedDescriptionKey: "Caps Lock 제어 장치를 찾지 못했습니다."])
    }
    defer { IOObjectRelease(service) }
    var connection: io_connect_t = 0
    let opened = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection)
    guard opened == KERN_SUCCESS else {
        throw NSError(domain: "gksdud", code: Int(opened), userInfo: [NSLocalizedDescriptionKey: "Caps Lock 제어 연결에 실패했습니다."])
    }
    defer { IOServiceClose(connection) }
    let result = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), enabled)
    guard result == KERN_SUCCESS else {
        throw NSError(domain: "gksdud", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Caps Lock 상태를 변경하지 못했습니다."])
    }
    var actual = false
    guard IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &actual) == KERN_SUCCESS, actual == enabled else {
        throw NSError(domain: "gksdud", code: 21, userInfo: [NSLocalizedDescriptionKey: "Caps Lock 상태 변경을 확인하지 못했습니다."])
    }
}

// Only the reserved function key is synthesized. Text keys are never buffered.
func nativeSwitchPulse(from event: CGEvent, marker: Int64) -> (CGEvent, CGEvent)? {
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    guard event.type == .keyDown, targets.contains(where: { Int64($0.keyCode) == code }),
          let down = event.copy(), let up = event.copy() else { return nil }
    down.type = .keyDown; up.type = .keyUp
    for pulse in [down, up] {
        // Strip held modifiers, but preserve the function-key identity flags.
        // macOS may normalize F19's shortcut mask to SecondaryFn (0x800000).
        pulse.flags = event.flags.intersection([.maskSecondaryFn, .maskNumericPad])
        pulse.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        pulse.setIntegerValueField(.eventSourceUserData, value: marker)
    }
    return (down, up)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSTextFieldDelegate {
    let engine: Engine
    init(engine: Engine = Engine()) { self.engine = engine; super.init() }
    let installer = UpdateInstaller()
    var preparedToRelaunch = false
    lazy var optionInput = makeOptionInput()
    lazy var updates = UpdateChecker(defaults: engine.defaults)
    var updateTimer: Timer?
    var tabButtons: [NSButton] = []
    var tabPanels: [NSStackView] = []
    var selectedTab = 0
    let updateTabBadge = NSImageView()
    let updateHeading = NSTextField(wrappingLabelWithString: "")
    let updateSummary = NSTextView()
    let updateStatus = NSTextField(wrappingLabelWithString: "")
    let updateButton = NSButton(title: "업데이트 하기", target: nil, action: nil)
    let checkUpdateButton = NSButton(title: "업데이트 확인", target: nil, action: nil)
    var specialButtons: [NSButton] = []
    let specialStatus = NSTextField(wrappingLabelWithString: "")
    var item: NSStatusItem?
    var window: NSWindow!
    var keyboardSettings: KeyboardSettingsController?
    let keyboardWarning = NSTextField(wrappingLabelWithString: "")
    let keyboardWarningRow = NSStackView()
    let warningBadge = WarningBadgeView()
    let picker = NSPopUpButton()
    let targetPicker = NSPopUpButton()
    let testInput = NSTextField()
    let inputBadge = NSImageView()
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === testInput else { return }
        // Save only our test field, without modifying the editor or its marked text.
        engine.testInputText = field.stringValue
    }
    let iconPicker = NSPopUpButton()
    let koreanPreview = NSImageView()
    let englishPreview = NSImageView()
    var iconStyle: Int { let value = engine.defaults.integer(forKey: "iconStyle"); return (0...3).contains(value) ? value : 0 }
    func iconLabel(korean: Bool) -> String { korean ? (iconStyle == 2 ? "KO" : "한") : ["dud", "A", "EN", "캐릭터"][iconStyle] }
    let enabled = NSButton(checkboxWithTitle: "활성화", target: nil, action: nil)
    let login = NSButton(checkboxWithTitle: "로그인 시 시작", target: nil, action: nil)
    let showInMenuBar = NSButton(checkboxWithTitle: "메뉴바에 표시", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "활성화를 켜면 한영 전환이 시작됩니다.")
    var timer: Timer?
    var menuInputTimer: Timer?
    var observers: [NSObjectProtocol] = []
    var keyTap: CFMachPort?
    var keyTapSource: CFRunLoopSource?
    var pressGate = PressGate()
    var longPress = LongPressState()
    var longPressTimer: DispatchWorkItem?
    var longPressEvent: CGEvent?
    var longPressOwner: pid_t?
    var longPressInitialCaps = false
    var longPressGeneration = 0
    var pendingCapsState: Bool?
    var capsConfirmationTimer: DispatchWorkItem?
    var englishCaps = EnglishCapsState()
    var capsRestoreGeneration = 0
    var capsRestoreTasks: [DispatchWorkItem] = []
    let nativePulseMarker = Int64.random(in: 1...Int64.max)
    let pressAccess = NSButton(title: "접근성 권한 허용", target: nil, action: nil)
    let pressSwitch = NSButton(checkboxWithTitle: "누를 때 전환", target: nil, action: nil)
    let longPressSwitch = NSButton(checkboxWithTitle: "길게 눌러 대소문자 전환", target: nil, action: nil)
    let preserveCapsSwitch = NSButton(checkboxWithTitle: "한영 전환시 대소문자 보존", target: nil, action: nil)
    var permissionHighlightGeneration = 0
    var returningFromPermissionSettings = false
    var permissionSettingsWasActive = false
    func finishPermissionVisit() {
        guard returningFromPermissionSettings else { return }
        returningFromPermissionSettings = false
        permissionSettingsWasActive = false
        ensureKeyTap()
        showSettings()
    }
    func windowWillClose(_ notification: Notification) {
        // Respect an explicit close of our settings window.
        returningFromPermissionSettings = false
        permissionSettingsWasActive = false
    }
    func highlightPressAccess() {
        selectTab(0)
        showSettings()
        updatePressAccess()
        guard !AXIsProcessTrusted() else { return }
        permissionHighlightGeneration += 1
        let generation = permissionHighlightGeneration
        pressAccess.wantsLayer = true
        guard let layer = pressAccess.layer else { return }
        layer.cornerRadius = 6
        layer.borderWidth = 2
        layer.borderColor = NSColor.controlAccentColor.cgColor
        let pulse = CABasicAnimation(keyPath: "borderColor")
        pulse.fromValue = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        pulse.toValue = NSColor.controlAccentColor.cgColor
        pulse.duration = 0.35; pulse.autoreverses = true; pulse.repeatCount = 3
        layer.add(pulse, forKey: "permissionHint")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.permissionHighlightGeneration == generation else { return }
            self.pressAccess.layer?.removeAnimation(forKey: "permissionHint")
            self.pressAccess.layer?.borderWidth = 0
        }
    }
    @objc func menuPressSwitch() {
        guard AXIsProcessTrusted() else {
            // Open after menu tracking has finished; don't toggle the saved preference.
            DispatchQueue.main.async { [weak self] in self?.highlightPressAccess() }
            return
        }
        pressSwitch.state = engine.switchOnKeyDown ? .off : .on
        togglePressSwitch()
    }
    func stopKeyTap() {
        optionInput.cancel()
        cancelCapsRestore()
        englishCaps.reset()
        cancelLongPress()
        longPress = LongPressState()
        if let source = keyTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = keyTap { CFMachPortInvalidate(tap) }
        keyTapSource = nil; keyTap = nil; pressGate.held.removeAll()
    }
    func ensureKeyTap() {
        guard AXIsProcessTrusted() else { stopKeyTap(); updatePressAccess(); return }
        if let tap = keyTap, !CFMachPortIsValid(tap) { stopKeyTap() }
        syncCapsPreservation()
        if !engine.active || !engine.longPressCapsLock { cancelLongPress() }
        guard engine.active, engine.switchOnKeyDown || engine.longPressCapsLock || engine.preserveCapsLock || specialMode != .none, keyTap == nil else { updatePressAccess(); return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue) | (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue) | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.cancelLongPress()
                    owner.optionInput.cancel()
                    // Retain owned physical key-ups to avoid an extra native release.
                    if let tap = owner.keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                if owner.optionInput.handle(event, mode: owner.specialMode, active: owner.engine.active) { return nil }
                if type == .flagsChanged {
                    if owner.capsPreservationActive && event.getIntegerValueField(.keyboardEventKeycode) == 57 {
                        owner.englishCaps.capsKeyChanged(english: owner.currentLanguage.hasPrefix("en"),
                            actual: event.flags.contains(.maskAlphaShift))
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
                if event.getIntegerValueField(.eventSourceUserData) == owner.nativePulseMarker {
                    return Unmanaged.passUnretained(event)
                }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let beginsSwitch = type == .keyDown && !repeated
                    || (type == .keyUp && !owner.engine.switchOnKeyDown && !owner.engine.longPressCapsLock)
                if owner.engine.active && beginsSwitch && code == Int64(owner.engine.target.keyCode) {
                    owner.rememberCapsBeforeSwitch()
                }
                if owner.longPress.key == code {
                    if type == .keyUp { owner.finishLongPress(code: code) }
                    return nil
                }
                if owner.engine.active && owner.engine.longPressCapsLock && type == .keyDown && !repeated
                    && code == Int64(owner.engine.target.keyCode) && !owner.pressGate.held.contains(code) {
                    if owner.startLongPress(event: event) { return nil }
                    return Unmanaged.passUnretained(event)
                }
                let active = owner.engine.active && owner.engine.switchOnKeyDown
                // Allocate before claiming the press, so failure falls back to the original shortcut.
                var pulse: (CGEvent, CGEvent)?
                if active && type == .keyDown && !repeated && !owner.pressGate.held.contains(code)
                    && code == Int64(owner.engine.target.keyCode) {
                    pulse = nativeSwitchPulse(from: event, marker: owner.nativePulseMarker)
                    guard pulse != nil else { return Unmanaged.passUnretained(event) }
                }
                let decision = owner.pressGate.handle(code: code, down: type == .keyDown,
                    repeatKey: repeated, active: active, target: Int64(owner.engine.target.keyCode))
                if decision.switchNow, let (down, up) = pulse {
                    // Re-enter before system hotkey handling, not downstream of the session tap.
                    // The marker bypass above lets both pulses through without another switch.
                    // This switch path only posts the reserved F-key.
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
                return decision.consume ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { updatePressAccess(); return }
        keyTap = tap
        keyTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), keyTapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        updatePressAccess()
    }
    func updatePressAccess() {
        let trusted = AXIsProcessTrusted()
        let ready = keyTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        pressAccess.title = trusted ? "권한 허용 완료" : "접근성 권한 허용"
        pressAccess.isEnabled = !trusted
        pressSwitch.state = trusted && engine.switchOnKeyDown ? .on : .off
        pressSwitch.isEnabled = trusted
        longPressSwitch.state = trusted && engine.longPressCapsLock ? .on : .off
        longPressSwitch.isEnabled = trusted
        preserveCapsSwitch.state = trusted && engine.preserveCapsLock ? .on : .off
        preserveCapsSwitch.isEnabled = trusted
        preserveCapsSwitch.toolTip = "영어의 대소문자 상태를 기억해 한글에서 영어로 돌아올 때 복원합니다. 길게 누르기와 별도로 설정할 수 있습니다."
        longPressSwitch.toolTip = trusted ? "선택한 한영 키를 0.5초 누르면 영어로 전환하고 Caps Lock을 켜거나 끕니다." : "오른쪽 접근성 권한 허용 버튼으로 권한을 허용해주세요."
        pressAccess.toolTip = "키를 누르는 순간 전환하려면 접근성 권한이 필요합니다."
        pressSwitch.toolTip = !trusted ? "오른쪽 버튼으로 접근성 권한을 허용해주세요. 허용 전에는 기존 방식으로 동작합니다." :
            !engine.switchOnKeyDown ? "기존 macOS 단축키 방식으로 전환합니다." :
            !engine.active ? "활성화를 켜면 키를 누를 때 전환합니다." :
            ready ? "키를 누르는 순간 전환 · 길게 눌러도 한 번만 전환" : "권한 반영을 기다리는 중입니다. 계속 전환되지 않으면 앱을 다시 실행하세요."
    }
    @objc func togglePressSwitch() {
        cancelLongPress()
        engine.defaults.set(pressSwitch.state == .on, forKey: "switchOnKeyDown")
        ensureKeyTap()
    }
    @objc func toggleLongPress() {
        cancelLongPress()
        engine.defaults.set(longPressSwitch.state == .on, forKey: "longPressCapsLock")
        ensureKeyTap()
    }
    @objc func togglePreserveCaps() {
        cancelLongPress()
        engine.defaults.set(preserveCapsSwitch.state == .on, forKey: "preserveCapsLock")
        ensureKeyTap()
    }
    var currentLanguage: String {
        TISCopyCurrentKeyboardInputSource().map { language($0.takeRetainedValue()) } ?? ""
    }
    var actualCaps: Bool { CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) }
    var capsPreservationActive: Bool { engine.active && engine.preserveCapsLock && AXIsProcessTrusted() }
    func syncCapsPreservation() {
        if capsPreservationActive { englishCaps.enable(actual: actualCaps) }
        else { cancelCapsRestore(); englishCaps.reset() }
    }
    func cancelCapsRestore() {
        capsRestoreGeneration += 1
        capsRestoreTasks.forEach { $0.cancel() }
        capsRestoreTasks.removeAll()
    }
    func rememberCapsBeforeSwitch() {
        guard capsPreservationActive else { return }
        englishCaps.willSwitch(english: currentLanguage.hasPrefix("en"), actual: actualCaps,
            longPress: engine.longPressCapsLock)
        // Also settle if macOS does not change sources (for example, only one is enabled).
        scheduleCapsRestore()
    }
    func restoreEnglishCaps() {
        guard !optionInput.busy, capsPreservationActive, pendingCapsState == nil,
              let desired = englishCaps.target(english: currentLanguage.hasPrefix("en")),
              actualCaps != desired else { return }
        do { try setCapsLock(desired) }
        catch { status.stringValue = error.localizedDescription; preserveCapsSwitch.toolTip = error.localizedDescription }
    }
    func scheduleCapsRestore() {
        cancelCapsRestore()
        guard capsPreservationActive else { return }
        englishCaps.switching = true
        let generation = capsRestoreGeneration
        // Input-source notification and the system's Caps reset can arrive in either order.
        // Bounded checks never replay text and are invalidated on subsequent transitions.
        for delay in [0.0, 0.05, 0.15] {
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.capsRestoreGeneration == generation, self.capsPreservationActive else { return }
                self.restoreEnglishCaps()
                if delay == 0.15 { self.englishCaps.switching = false; self.capsRestoreTasks.removeAll() }
            }
            capsRestoreTasks.append(task)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
        }
    }
    func cancelLongPress() {
        longPressGeneration += 1
        longPressTimer?.cancel(); longPressTimer = nil
        capsConfirmationTimer?.cancel(); capsConfirmationTimer = nil
        pendingCapsState = nil
        longPress.cancel()
        longPressEvent = nil
        longPressOwner = nil
    }
    func startLongPress(event: CGEvent) -> Bool {
        guard let copy = event.copy(), let pulse = nativeSwitchPulse(from: event, marker: nativePulseMarker) else { return false }
        cancelLongPress()
        longPressEvent = copy
        longPressOwner = NSWorkspace.shared.frontmostApplication?.processIdentifier
        longPressInitialCaps = englishCaps.beforeLongPress(actual: actualCaps, preserving: capsPreservationActive)
        longPress.begin(key: event.getIntegerValueField(.keyboardEventKeycode), now: ProcessInfo.processInfo.systemUptime, eager: engine.switchOnKeyDown)
        if engine.switchOnKeyDown { pulse.0.post(tap: .cghidEventTap); pulse.1.post(tap: .cghidEventTap) }
        let generation = longPressGeneration
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.longPressGeneration == generation else { return }
            if self.longPress.claimLong(now: ProcessInfo.processInfo.systemUptime) { self.performLongPress() }
        }
        longPressTimer = task
        DispatchQueue.main.asyncAfter(deadline: .now() + LongPressState.delay, execute: task)
        return true
    }
    func finishLongPress(code: Int64) {
        longPressTimer?.cancel(); longPressTimer = nil
        let result = longPress.release(key: code, now: ProcessInfo.processInfo.systemUptime)
        if result.long { performLongPress() }
        else if result.short, let event = longPressEvent, engine.active, engine.longPressCapsLock,
                longPressOwner == NSWorkspace.shared.frontmostApplication?.processIdentifier,
                let pulse = nativeSwitchPulse(from: event, marker: nativePulseMarker) {
            pulse.0.post(tap: .cghidEventTap); pulse.1.post(tap: .cghidEventTap)
        }
        longPressEvent = nil
        if pendingCapsState == nil { longPressOwner = nil }
    }
    func performLongPress() {
        guard engine.active, engine.longPressCapsLock, AXIsProcessTrusted(),
              longPressOwner == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              availableSource("en") != nil else { cancelLongPress(); return }
        pendingCapsState = !longPressInitialCaps
        if language(current).hasPrefix("en") { completeCapsTransition(); return }
        // Keep composition on the native shortcut path; no text replay or direct TIS selection.
        guard let event = longPressEvent, let pulse = nativeSwitchPulse(from: event, marker: nativePulseMarker) else { cancelLongPress(); return }
        pulse.0.post(tap: .cghidEventTap); pulse.1.post(tap: .cghidEventTap)
        let generation = longPressGeneration
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.longPressGeneration == generation, self.pendingCapsState != nil else { return }
            self.cancelLongPress()
            self.showLongPressError("영어 전환을 확인하지 못해 대문자 전환을 취소했습니다. 영어와 한국어를 최근 입력 소스로 선택해주세요.")
        }
        capsConfirmationTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeout)
    }
    func completeCapsTransition() {
        guard let desired = pendingCapsState else { return }
        guard engine.active, engine.longPressCapsLock,
              longPressOwner == NSWorkspace.shared.frontmostApplication?.processIdentifier else { cancelLongPress(); return }
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), language(current).hasPrefix("en") else { return }
        pendingCapsState = nil
        capsConfirmationTimer?.cancel(); capsConfirmationTimer = nil
        do {
            try setCapsLock(desired)
            if capsPreservationActive { englishCaps.committedLongPress(desired) }
            scheduleCapsRestore()
        } catch { showLongPressError(error.localizedDescription) }
    }
    func showLongPressError(_ message: String) {
        // Do not steal typing focus with a modal alert.
        status.stringValue = message
        longPressSwitch.toolTip = message
    }
    @objc func requestPressAccess() {
        returningFromPermissionSettings = true
        permissionSettingsWasActive = false
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        // Let the system prompt offer Settings; do not open it before the user chooses.
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appEntry = NSMenuItem(); let appMenu = NSMenu(title: "gksdud")
        appMenu.addItem(withTitle: "gksdud 종료", action: #selector(quit), keyEquivalent: "q").target = self
        appEntry.submenu = appMenu; mainMenu.addItem(appEntry)
        let editEntry = NSMenuItem(); let editMenu = NSMenu(title: "편집")
        for (title, action, key) in [("잘라내기", "cut:", "x"), ("복사", "copy:", "c"), ("붙여넣기", "paste:", "v"), ("모두 선택", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editEntry.submenu = editMenu; mainMenu.addItem(editEntry)
        NSApp.mainMenu = mainMenu
        buildWindow()
        updateMenu()
        updates.onChange = { [weak self] in self?.refreshUpdates() }
        installer.onChange = { [weak self] in self?.refreshUpdates() }
        installer.onReady = { [weak self] prepared in self?.installPreparedUpdate(prepared) }
        updates.check()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in self?.updates.check() }
        updateTimer?.tolerance = 60
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(inputSourceChanged), name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notice in
            guard let self, let owner = self.longPressOwner,
                  let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if owner != app.processIdentifier { self.cancelLongPress() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notice in
            guard let self, self.returningFromPermissionSettings,
                  let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier == "com.apple.systempreferences" {
                self.permissionSettingsWasActive = true
            } else if self.permissionSettingsWasActive {
                // Defer until the destination application has finished activating.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.finishPermissionVisit() }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.optionInput.cancel(focusChanged: true)
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.optionInput.cancel() })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.recover() })
        }
        // Low-cost service enumeration also covers Bluetooth/USB reconnects and delayed wake.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.repair() }
        timer?.tolerance = 0.2
        if engine.active { do { try engine.shortcut(target: engine.target); try engine.hideSystemInputMenu() } catch { report(error) } }
        repair()
        if showInMenuBar.state == .off || CommandLine.arguments.contains("--settings") { showSettings() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil else { return }
        ensureKeyTap()
        if returningFromPermissionSettings && permissionSettingsWasActive { finishPermissionVisit() }
    }
    @objc func showKeyboardSettings() {
        repair()
        if keyboardSettings == nil {
            keyboardSettings = KeyboardSettingsController(manager: engine.keyboards) { [weak self] in self?.repair() }
        }
        keyboardSettings?.show(on: window)
    }
    func refreshKeyboardState() {
        let warning = engine.keyboards.warning
        keyboardWarning.stringValue = warning ?? ""
        keyboardWarning.toolTip = engine.keyboards.warningDetails
        keyboardWarningRow.isHidden = warning == nil
        warningBadge.isHidden = warning == nil
        enabled.toolTip = warning
        keyboardSettings?.refresh()
        updateInputIndicator()
    }
    func updateMenu() {
        if showInMenuBar.state == .off { if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil; return }
        guard item == nil else { return }
        item = NSStatusBar.system.statusItem(withLength: 28)
        item?.button?.font = .systemFont(ofSize: 13, weight: .medium)
        if let button = item?.button {
            warningBadge.removeFromSuperview()
            warningBadge.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(warningBadge)
            NSLayoutConstraint.activate([
                warningBadge.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 1),
                warningBadge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -1),
                warningBadge.widthAnchor.constraint(equalToConstant: 9),
                warningBadge.heightAnchor.constraint(equalToConstant: 9)
            ])
            warningBadge.isHidden = engine.keyboards.warning == nil
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let brandEntry = NSMenuItem(title: "gksdud", action: #selector(menuBrand), keyEquivalent: "")
        brandEntry.attributedTitle = NSAttributedString(string: "gksdud", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .heavy), .kern: 0.6])
        brandEntry.image = DudIcon.badge(korean: false)
        brandEntry.target = self
        brandEntry.isEnabled = true
        menu.addItem(brandEntry)
        let updateEntry = NSMenuItem(title: "업데이트 가능", action: #selector(showAbout), keyEquivalent: "")
        updateEntry.target = self
        updateEntry.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: nil)
        updateEntry.isHidden = updates.available == nil
        menu.addItem(updateEntry)
        menu.addItem(NSMenuItem.separator())
        let koreanEntry = menu.addItem(withTitle: "한국어", action: #selector(selectKorean), keyEquivalent: "")
        koreanEntry.target = self; koreanEntry.image = sourceMenuIcon(korean: true)
        let englishEntry = menu.addItem(withTitle: "영어", action: #selector(selectEnglish), keyEquivalent: "")
        englishEntry.target = self; englishEntry.image = sourceMenuIcon(korean: false)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "활성화", action: #selector(menuEnabled), keyEquivalent: "").target = self
        menu.addItem(withTitle: "누를 때 전환", action: #selector(menuPressSwitch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "로그인 시 시작", action: #selector(menuLogin), keyEquivalent: "").target = self
        menu.addItem(withTitle: "메뉴바에 표시", action: #selector(menuHidden), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        let settingsEntry = menu.addItem(withTitle: "설정..", action: #selector(showSettings), keyEquivalent: ",")
        settingsEntry.target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "종료", action: #selector(quit), keyEquivalent: "q").target = self
        item?.menu = menu
        updateInputIndicator()
    }
    @objc func menuBrand() { showAbout() }
    func sourceMenuIcon(korean: Bool) -> NSImage {
        iconStyle == 3 ? DudIcon.badge(korean: korean) : badgeImage(label: iconLabel(korean: korean), filled: korean)
    }
    @objc func changeIconStyle() {
        engine.defaults.set(iconPicker.indexOfSelectedItem, forKey: "iconStyle")
        refreshIconPreviews()
        updateInputIndicator()
        for entry in item?.menu?.items ?? [] {
            if entry.action == #selector(selectKorean) { entry.image = sourceMenuIcon(korean: true) }
            if entry.action == #selector(selectEnglish) { entry.image = sourceMenuIcon(korean: false) }
        }
    }
    func refreshIconPreviews() {
        koreanPreview.image = sourceMenuIcon(korean: true)
        englishPreview.image = sourceMenuIcon(korean: false)
    }
    func badgeImage(label: String, filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 20), flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 1.25), xRadius: 3, yRadius: 3)
            NSColor.black.set()
            if filled { shape.fill() } else { shape.lineWidth = 0.8; shape.stroke() }
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: label.count == 1 ? 11.5 : label.count == 2 ? 9 : 8, weight: .semibold), .foregroundColor: NSColor.black
            ])
            let size = text.size()
            let origin = NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2)
            if filled {
                let mask = NSImage(size: rect.size, flipped: false) { _ in text.draw(at: origin); return true }
                mask.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
            } else { text.draw(at: origin) }
            return true
        }
        image.isTemplate = true
        return image
    }
    func language(_ source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return "" }
        return (Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String])?.first ?? ""
    }
    func availableSource(_ prefix: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceIsEnabled as String: true, kTISPropertyInputSourceIsSelectCapable as String: true, kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        let list = TISCreateInputSourceList(filter, false).takeRetainedValue() as? [TISInputSource] ?? []
        return list.first { language($0).hasPrefix(prefix) }
    }
    @objc func inputSourceChanged() {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            guard !self.optionInput.busy else { return }
            self.completeCapsTransition()
            self.scheduleCapsRestore()
            self.restoreEnglishCaps()
            self.updateInputIndicator()
        }
    }
    func updateInputIndicator() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let lang = language(current)
        updateInputMenuState(language: lang)
        let label = lang.hasPrefix("ko") ? iconLabel(korean: true) : lang.hasPrefix("en") ? iconLabel(korean: false) : (lang.isEmpty ? "?" : String(lang.prefix(3)))
        let korean = lang.hasPrefix("ko")
        // Let the status bar resolve contrast, including its initial appearance and highlighting.
        let badge = (lang.hasPrefix("ko") || lang.hasPrefix("en"))
            ? sourceMenuIcon(korean: korean) : badgeImage(label: label, filled: false)
        inputBadge.image = badge
        tabButtons.first?.image = badge
        inputBadge.setAccessibilityLabel("현재 입력: \(korean ? "한국어" : lang.hasPrefix("en") ? "영어" : label)")
        guard let button = item?.button else { return }
        button.title = ""; button.image = badge
        button.imagePosition = .imageOnly
        let warning = engine.keyboards.warning.map { "\n\($0)" } ?? ""
        button.toolTip = "gksdud · 현재 입력 소스: \(lang)\(warning)"
        button.setAccessibilityLabel("gksdud, 현재 입력 \(korean ? "한국어" : lang.hasPrefix("en") ? "영어" : label)\(warning)")
    }
    func menuWillOpen(_ menu: NSMenu) {
        updateInputIndicator()
        // Menu tracking can delay input-source notifications. Keep the open menu
        // and settings badge current without running hardware repair in this mode.
        menuInputTimer?.invalidate()
        let refresh = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateInputIndicator()
        }
        menuInputTimer = refresh
        RunLoop.main.add(refresh, forMode: .eventTracking)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for entry in menu.items {
            switch entry.action {
            case #selector(menuEnabled): entry.state = engine.active ? .on : .off
            case #selector(menuPressSwitch):
                entry.state = AXIsProcessTrusted() && engine.switchOnKeyDown ? .on : .off
                entry.isEnabled = true
                entry.toolTip = AXIsProcessTrusted() ? "키를 누르는 순간 전환합니다." : "설정을 열어 접근성 권한 허용 버튼을 표시합니다."
            case #selector(menuLogin): entry.state = login.state
            case #selector(menuHidden): entry.state = showInMenuBar.state
            case #selector(selectKorean): entry.isEnabled = availableSource("ko") != nil
            case #selector(selectEnglish): entry.isEnabled = availableSource("en") != nil
            default: break
            }
        }
        menu.autoenablesItems = false
    }
    func menuDidClose(_ menu: NSMenu) {
        menuInputTimer?.invalidate()
        menuInputTimer = nil
    }
    func updateInputMenuState(language: String) {
        for entry in item?.menu?.items ?? [] {
            if entry.action == #selector(selectKorean) { entry.state = language.hasPrefix("ko") ? .on : .off }
            if entry.action == #selector(selectEnglish) { entry.state = language.hasPrefix("en") ? .on : .off }
        }
    }
    func selectLanguage(_ prefix: String) { if let source = availableSource(prefix) { rememberCapsBeforeSwitch(); let result = TISSelectInputSource(source); if result != noErr { status.stringValue = "입력 소스를 변경하지 못했습니다 (\(result))." } }; updateInputIndicator() }
    @objc func selectKorean() { selectLanguage("ko") }
    @objc func selectEnglish() { selectLanguage("en") }
    @objc func menuEnabled() { enabled.state = engine.active ? .off : .on; toggleEnabled() }
    @objc func menuLogin() { login.state = SMAppService.mainApp.status == .enabled ? .off : .on; toggleLogin() }
    @objc func menuHidden() { showInMenuBar.state = showInMenuBar.state == .on ? .off : .on; toggleHidden() }
    @objc func showSettings() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if showInMenuBar.state == .off { showSettings() }; return true }
    @objc func toggleHidden() {
        engine.defaults.set(showInMenuBar.state == .off, forKey: "hidden")
        updateMenu()
        if engine.active { do { try engine.hideSystemInputMenu() } catch { report(error) } }
    }
    @objc func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { status.stringValue = "시스템 설정 → 로그인 항목에서 gksdud를 허용하세요." }
        } catch { login.state = SMAppService.mainApp.status == .enabled ? .on : .off; report(error) }
    }
    func resetSelection() {
        picker.selectItem(at: sources.firstIndex(of: engine.source) ?? 0)
        targetPicker.selectItem(withTitle: engine.target.name)
        enabled.state = engine.active ? .on : .off
    }
    @objc func toggleEnabled() {
        guard !engine.isUpdatingSettings else { resetSelection(); return }
        if enabled.state == .on { applyNow() }
        else { restoreNow() }
    }
    @objc func selectionChanged() {
        guard !engine.isUpdatingSettings else { resetSelection(); return }
        cancelLongPress()
        if enabled.state == .on { applyNow() }
        else {
            engine.defaults.set(String(sources[picker.indexOfSelectedItem]), forKey: "source")
            engine.defaults.set(targets[targetPicker.indexOfSelectedItem].name, forKey: "target")
            status.stringValue = "비활성화됨 · 선택한 설정은 활성화할 때 반영됩니다."
        }
    }
    func applyNow() {
        guard !engine.isUpdatingSettings else { return }
        defer { resetSelection(); refreshKeyboardState() }
        let source = sources[picker.indexOfSelectedItem]
        let target = targets[targetPicker.indexOfSelectedItem]
        if engine.targetInUse(source, target: target) {
            let alert = NSAlert(); alert.messageText = "\(target.name)은 다른 키 매핑에서 사용 중입니다."
            alert.informativeText = "다른 앱과 충돌할 수 있습니다. 대상 키를 바꿔주세요."
            alert.runModal(); resetSelection(); return
        }
        if engine.conflicts(source, target: target) {
            let alert = NSAlert(); alert.messageText = "이 키에 다른 매핑이 있습니다."
            alert.informativeText = "선택한 키를 한영 전환 전용으로 바꿉니다. 다른 앱에서도 이 키의 재매핑을 꺼주세요. 기존 매핑은 해제 시 복원됩니다."
            alert.addButton(withTitle: "변경"); alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { resetSelection(); return }
        }
        do { let count = try engine.apply(source: source, target: target); lastError = ""; ensureKeyTap(); status.stringValue = "활성화됨 · 키보드 \(count)개 · \(target.name) 한영 전환" } catch { report(error); resetSelection() }
    }
    func restoreNow() {
        optionInput.cancel()
        guard !engine.isUpdatingSettings else { return }
        cancelLongPress()
        do { try engine.restore(); lastError = ""; status.stringValue = "비활성화됨 · 이전 키 매핑과 단축키로 복원했습니다." } catch { report(error) }
        resetSelection(); syncCapsPreservation(); updatePressAccess(); refreshKeyboardState()
    }
    func recover() { optionInput.cancel(); cancelCapsRestore(); englishCaps.switching = false; cancelLongPress(); longPress = LongPressState(); pressGate.held.removeAll(); for delay in [0.5, 2.0, 5.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.repair() } } }
    func repair() {
        guard !engine.isUpdatingSettings else { return }
        ensureKeyTap()
        do { try engine.repair() } catch { report(error) }
        let result = engine.keyboards.result
        if result.pending == 0 { lastError = "" }
        status.stringValue = result.pending > 0 ? "키보드 설정을 다시 적용하고 있습니다."
            : !engine.active ? "비활성화됨"
            : result.selected == 0 ? "적용할 키보드 연결 대기 중"
            : "적용됨 · 키보드 \(result.applied)개 · \(engine.target.name) · 자동 복구 켜짐"
        refreshKeyboardState()
    }
    var lastError = ""
    func report(_ error: Error) {
        if error is KeyboardError { refreshKeyboardState(); return }
        status.stringValue = error.localizedDescription
        enabled.toolTip = error.localizedDescription
        guard lastError != error.localizedDescription else { return }
        lastError = error.localizedDescription
        let alert = NSAlert(error: error)
        if window.isVisible { alert.beginSheetModal(for: window) } else { showSettings(); alert.beginSheetModal(for: window) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if preparedToRelaunch { return .terminateNow }
        guard !engine.isUpdatingSettings else { return .terminateCancel }
        do {
            try engine.prepareForExit()
            stopKeyTap()
            timer?.invalidate()
            enabled.state = .off
            return .terminateNow
        } catch {
            report(error)
            return .terminateCancel
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.dropFirst().first == "--install-update" {
    do { try UpdateInstaller.runHelper(CommandLine.arguments) } catch { fputs("Update helper failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--render-keyboard-ui"), CommandLine.arguments.count > index + 1 {
    do { try renderKeyboardUI(to: CommandLine.arguments[index + 1]) } catch { fputs("UI rendering failed: \(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--probe-option-input") {
    do { try probeOptionInput() } catch { fputs("Input probe failed: \(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--self-test") {
    do { try runSettingsReentrancyTests() } catch { fputs("Settings reentrancy tests failed: \(error)\n", stderr); exit(1) }
    do { try runShortcutRestoreTests() } catch { fputs("Shortcut tests failed: \(error)\n", stderr); exit(1) }
    runFeatureTests()
    runKeyboardTests()
    for initial in [false, true] {
        for holdEnabled in [false, true] {
            var caps = EnglishCapsState()
            caps.enable(actual: initial)
            caps.willSwitch(english: true, actual: initial, longPress: holdEnabled)
            caps.capsKeyChanged(english: true, actual: !initial)
            precondition(caps.remembered == initial, "Ignore Caps reset during source transition")
            precondition(caps.target(english: false) == nil, "Never force Caps in Korean or other sources")
            caps.switching = false
            caps.capsKeyChanged(english: false, actual: !initial)
            caps.willSwitch(english: false, actual: false, longPress: holdEnabled)
            precondition(caps.target(english: true) == initial, "English -> Korean -> English restores case")
            precondition(caps.beforeLongPress(actual: false, preserving: true) == initial, "Hold uses remembered case, not IME reset")
            precondition(caps.beforeLongPress(actual: !initial, preserving: false) == !initial,
                "With preservation off, hold reads current Caps even if remembered state exists")
            caps.committedLongPress(!initial)
            precondition(caps.target(english: true) == !initial, "Only completed hold commits the toggle")
            caps.willSwitch(english: true, actual: initial, longPress: holdEnabled)
            precondition(caps.remembered == !initial, "Rapid source changes must not overwrite pending restoration")
            caps.switching = false
            caps.capsKeyChanged(english: true, actual: initial)
            precondition(caps.remembered == initial, "Physical Caps must work with long press both on and off")
            caps.willSwitch(english: true, actual: initial, longPress: holdEnabled)
            precondition(caps.target(english: true) == initial, "Preserve the physical Caps choice on the next round trip")
            precondition(caps.beforeLongPress(actual: !initial, preserving: true) == initial,
                "Next hold must toggle from the physical Caps choice, not an old remembered value")
            caps.reset()
            precondition(caps.target(english: true) == nil && !caps.switching)
            caps.enable(actual: !initial)
            precondition(caps.remembered == !initial, "Reactivation samples fresh keyboard state")
        }
    }
    print("PASS: uppercase/lowercase round trips, physical Caps with hold on/off, next-hold baseline, transition reset suppression, reactivation")
    for eager in [false, true] {
        var hold = LongPressState()
        hold.begin(key: 80, now: 10, eager: eager)
        precondition(!hold.claimLong(now: 10.499))
        let short = hold.release(key: 80, now: 10.499)
        precondition(short.owned && short.short == !eager && !short.long)
        hold.begin(key: 80, now: 20, eager: eager)
        precondition(hold.claimLong(now: 20.5))
        precondition(!hold.claimLong(now: 23), "Only one long action per hold")
        let released = hold.release(key: 80, now: 24)
        precondition(released.owned && !released.short && !released.long)
        hold.begin(key: 80, now: 30, eager: eager)
        precondition(!hold.release(key: 0, now: 30.2).owned, "Other key must not end hold")
        let late = hold.release(key: 80, now: 30.5)
        precondition(late.long && !late.short, "Release handles delayed timer exactly once")
        hold.begin(key: 80, now: 40, eager: eager)
        hold.cancel()
        precondition(!hold.claimLong(now: 41))
        let cancelled = hold.release(key: 80, now: 41)
        precondition(cancelled.owned && !cancelled.long && !cancelled.short)
    }
    print("PASS: 0.5-second hold threshold, eager/release compatibility, one-shot hold, delayed timer, unrelated keys, cancellation")
    for target in targets {
        let original = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(target.keyCode), keyDown: true)!
        original.flags = [.maskShift, .maskCommand, .maskSecondaryFn]
        let (down, up) = nativeSwitchPulse(from: original, marker: 12345)!
        precondition(down.type == .keyDown && up.type == .keyUp)
        precondition(down.flags == .maskSecondaryFn && up.flags == .maskSecondaryFn)
        precondition(original.flags.contains(.maskShift), "Do not mutate the original event")
        for event in [down, up] {
            precondition(event.getIntegerValueField(.keyboardEventKeycode) == Int64(target.keyCode))
            precondition(event.getIntegerValueField(.keyboardEventAutorepeat) == 0)
            precondition(event.getIntegerValueField(.eventSourceUserData) == 12345)
        }
        precondition(nativeSwitchPulse(from: up, marker: 12345) == nil)
    }
    let textKey = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
    precondition(nativeSwitchPulse(from: textKey, marker: 12345) == nil, "Never synthesize ordinary typing")
    print("PASS: F13-F20 native down/up pairs, marker, modifier isolation, original event preservation, text-key rejection")
    var gate = PressGate()
    let press = gate.handle(code: 80, down: true, repeatKey: false, active: true, target: 80)
    precondition(press.consume && press.switchNow)
    precondition(!gate.handle(code: 80, down: true, repeatKey: true, active: true, target: 80).switchNow)
    precondition(!gate.handle(code: 80, down: true, repeatKey: false, active: true, target: 80).switchNow)
    precondition(!gate.handle(code: 0, down: true, repeatKey: false, active: true, target: 80).consume)
    let release = gate.handle(code: 80, down: false, repeatKey: false, active: false, target: 90)
    precondition(release.consume && !release.switchNow) // Balance after disable/target change.
    precondition(!gate.handle(code: 80, down: true, repeatKey: false, active: false, target: 80).consume)
    precondition(gate.handle(code: 90, down: true, repeatKey: false, active: true, target: 90).switchNow)
    precondition(gate.handle(code: 90, down: false, repeatKey: false, active: true, target: 90).consume)
    print("PASS: key-down switch, repeat suppression, release consumption, inactive pass-through, target change")
    let suiteName = "io.gksdud.inputswitch.defaults-test.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    let preferences = Engine(defaults: suite)
    precondition(preferences.testInputText == "한dud한dud한dud한dud")
    preferences.testInputText = "한영 테스트 ABC"
    precondition(Engine(defaults: UserDefaults(suiteName: suiteName)!).testInputText == "한영 테스트 ABC")
    preferences.testInputText = ""
    precondition(Engine(defaults: UserDefaults(suiteName: suiteName)!).testInputText.isEmpty, "Empty input must not reset to default")
    print("PASS: test input default, edited text persistence, empty text persistence")
    precondition(preferences.active, "First launch defaults to active")
    precondition(preferences.switchOnKeyDown, "Key-down switching defaults to checked")
    precondition(!preferences.longPressCapsLock, "Long press is opt-in")
    precondition(preferences.preserveCapsLock, "Case preservation defaults to on")
    for holdEnabled in [false, true] {
        for preserveEnabled in [false, true] {
            suite.set(holdEnabled, forKey: "longPressCapsLock")
            suite.set(preserveEnabled, forKey: "preserveCapsLock")
            let reloaded = Engine(defaults: UserDefaults(suiteName: suiteName)!)
            precondition(reloaded.longPressCapsLock == holdEnabled, "Hold preference survives restart independently")
            precondition(reloaded.preserveCapsLock == preserveEnabled, "Preservation preference survives restart independently")
            var caps = EnglishCapsState()
            caps.enable(actual: true)
            precondition(caps.beforeLongPress(actual: false, preserving: reloaded.preserveCapsLock) == preserveEnabled,
                "Preservation alone decides whether hold uses remembered or current case")
            if !preserveEnabled { caps.reset() }
            precondition(caps.target(english: true) == (preserveEnabled ? true : nil),
                "Hold must not enable restoration when preservation is off")
        }
    }
    print("PASS: four independent hold/preservation combinations, restart persistence, current versus remembered case")
    suite.set(false, forKey: "switchOnKeyDown")
    precondition(!Engine(defaults: suite).switchOnKeyDown, "Explicit unchecked preference survives restart")
    suite.set(true, forKey: "switchOnKeyDown")
    precondition(preferences.switchOnKeyDown)
    suite.set(false, forKey: "active")
    precondition(!preferences.active, "Explicitly disabled preference is preserved")
    suite.set(true, forKey: "active")
    precondition(preferences.active)
    suite.removePersistentDomain(forName: suiteName)
    let option = sources[1], command = sources[0]
    let existing: [Mapping] = [[srcKey: NSNumber(value: option), dstKey: NSNumber(value: UInt64(0x70000006d))]]
    let first = merged(existing, source: command, previous: nil, original: nil)
    let owned = ["source": String(command), "target": String(f19)]
    precondition(!targetConflict(first, source: sources[2], target: f19, owned: owned), "Own old mapping must not block source changes")
    precondition(targetConflict(first, source: sources[2], target: f19, owned: nil), "Unowned target remains a conflict")
    precondition(targetConflict(existing, source: command, target: 0x70000006d, owned: owned), "Unrelated target collision remains blocked")
    precondition(first.count == 2 && first[0] == existing[0])
    precondition(merged(first, source: command, previous: command, original: nil) == first)
    let switched = merged(first, source: sources[2], previous: command, original: nil)
    precondition(!switched.contains { $0[srcKey]?.uint64Value == command })
    precondition(switched.contains { $0[srcKey]?.uint64Value == option && $0[dstKey]?.uint64Value == 0x70000006d })
    let f20 = merged(first, source: command, previous: command, original: nil, target: targets[7].usage)
    precondition(f20.contains { $0[srcKey]?.uint64Value == command && $0[dstKey]?.uint64Value == targets[7].usage })
    let afterWake = merged(existing, source: command, previous: command, original: nil)
    precondition(afterWake == first)
    let restored = merged(first, source: sources[2], previous: command, original: NSNumber(value: UInt64(0x7000000e3)))
    precondition(restored.contains { $0[srcKey]?.uint64Value == command && $0[dstKey]?.uint64Value == 0x7000000e3 })
    print("PASS: unrelated mapping preservation, idempotence, source/target switching, wake recovery, prior mapping restoration")
} else if CommandLine.arguments.contains("--integration-test") {
    let suiteName = "io.gksdud.inputswitch.test.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    let engine = Engine(defaults: suite)
    defer { try? engine.restore(); suite.removePersistentDomain(forName: suiteName) }
    do {
        let count = try engine.apply(source: sources[0], target: targets[6])
        guard count > 0 else { throw NSError(domain: "asd", code: 7, userInfo: [NSLocalizedDescriptionKey: "No real keyboard services visible"]) }
        let menuDomain = "com.apple.TextInputMenu" as CFString
        func nativeMenuVisible() -> Bool? {
            CFPreferencesAppSynchronize(menuDomain)
            return (CFPreferencesCopyAppValue("visible" as CFString, menuDomain) as? NSNumber)?.boolValue
        }
        precondition(nativeMenuVisible() == false)
        suite.set(true, forKey: "hidden")
        try engine.hideSystemInputMenu()
        precondition(nativeMenuVisible() == true, "Hidden gksdud must show native input menu")
        suite.set(false, forKey: "hidden")
        try engine.hideSystemInputMenu()
        precondition(nativeMenuVisible() == false)
        for service in engine.services() {
            var map = engine.mappings(service)
            map.removeAll { $0[srcKey]?.uint64Value == sources[0] }
            try service.writeMappings(map)
        }
        _ = try engine.reconcile()
        for service in engine.services() {
            precondition(engine.mappings(service).contains { $0[srcKey]?.uint64Value == sources[0] && $0[dstKey]?.uint64Value == targets[6].usage })
        }
        _ = try engine.apply(source: sources[0], target: targets[7])
        for service in engine.services() {
            precondition(engine.mappings(service).contains { $0[srcKey]?.uint64Value == sources[0] && $0[dstKey]?.uint64Value == targets[7].usage })
        }
        try engine.prepareForExit()
        precondition(engine.active, "Normal quit must remember activation")
        let restarted = Engine(defaults: suite)
        precondition(restarted.active && restarted.target.name == "F20")
        _ = try restarted.apply(source: restarted.source, target: restarted.target)
        try restarted.restore()
        try restarted.prepareForExit()
        precondition(!restarted.active, "Explicitly disabled must stay disabled")
        print("PASS: \(count) real keyboards; recovery, target switch, quit cleanup, active/inactive launch preference, restoration")
    } catch { fputs("Integration test failed: \(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
