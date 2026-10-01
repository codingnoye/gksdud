import AppKit
import ServiceManagement
import IOKit
import Carbon

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
let sources: [UInt64] = [0x7000000e7, 0x7000000e6, 0x700000039, 0x7000000e4]
let sourceNames = ["우측 Command ⌘", "우측 Option ⌥", "Caps Lock ⇪", "우측 Control ⌃"]
// Space combinations are caught by the event tap, not mapped in HID, so they apply to every keyboard.
// Their IDs only name them in saved settings and are never written to HID.
let spaceCombos: [UInt64] = [0xffff00000001, 0xffff00000002, 0xffff00000003, 0xffff00000004]
let spaceComboNames = ["Ctrl ⌃ + Space ␣", "Cmd ⌘ + Space ␣", "Opt ⌥ + Space ␣", "Shift ⇧ + Space ␣"]
let spaceComboModifiers: [CGEventFlags] = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
// Every key the global choice offers, in menu order.
let hangulKeys = sources + spaceCombos, hangulKeyNames = sourceNames + spaceComboNames
func sourceName(_ key: UInt64) -> String { hangulKeys.firstIndex(of: key).map { hangulKeyNames[$0] } ?? "알 수 없는 키" }
let accessibilityHint = "일반 탭의 접근성 권한 허용 버튼으로 권한을 허용해주세요."
typealias Mapping = [String: NSNumber]

// Several keys are saved comma-separated, so a single key saved by an older version reads unchanged.
func encodeSources(_ keys: [UInt64]) -> String { keys.map(String.init).joined(separator: ",") }
func decodeSources(_ value: String?) -> [UInt64] { (value ?? "").split(separator: ",").compactMap { UInt64($0) } }
// A saved choice keeps only keys the menu offers, in menu order; nothing left means no choice.
func selectable(_ keys: [UInt64], from options: [UInt64] = sources) -> [UInt64]? {
    let valid = options.filter(keys.contains)
    return valid.isEmpty ? nil : valid
}
// Space with exactly one modifier, from either side of the keyboard.
func spaceCombo(flags: CGEventFlags) -> UInt64? {
    spaceComboModifiers.firstIndex(of: flags.intersection(CGEventFlags(spaceComboModifiers))).map { spaceCombos[$0] }
}

// A failed readback may have written the pending target, so it is ours as well.
func owns(_ record: [String: String]?, _ mapping: Mapping) -> Bool {
    guard let record, let source = mapping[srcKey]?.uint64Value, let target = mapping[dstKey]?.uint64Value else { return false }
    return decodeSources(record["source"]).contains(source)
        && [record["target"], record["pendingTarget"], record["extraTarget"], record["pendingExtraTarget"]].contains(String(target))
}

func targetConflict(_ mappings: [Mapping], sources: [UInt64], target: UInt64, owned: [String: String]?) -> Bool {
    mappings.contains { mapping in
        !sources.contains(mapping[srcKey]?.uint64Value ?? 0) && mapping[dstKey]?.uint64Value == target && !owns(owned, mapping)
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

// Whether the Mac input menu shows in the menu bar; nil is macOS's default.
struct InputMenuPreference {
    var read: () -> CFPropertyList?
    var write: (CFPropertyList?) throws -> Void

    static let system = InputMenuPreference(read: {
        let domain = "com.apple.TextInputMenu" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("visible" as CFString, domain)
    }, write: { value in
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
    })
}

final class Engine {
    let defaults: UserDefaults
    let keyboards: KeyboardManager
    let shortcutPreferences: ShortcutPreferences
    let inputMenu: InputMenuPreference
    private var settingsUpdateDepth = 0
    var isUpdatingSettings: Bool { settingsUpdateDepth > 0 }
    init(defaults: UserDefaults = .standard, discover: @escaping () throws -> [KeyboardDevice] = HIDKeyboardDevice.discover,
         shortcutPreferences: ShortcutPreferences = .system, inputMenu: InputMenuPreference = .system) {
        self.defaults = defaults
        self.shortcutPreferences = shortcutPreferences
        self.inputMenu = inputMenu
        keyboards = KeyboardManager(defaults: defaults, discover: discover)
    }
    var defaultSources: [UInt64] {
        get { selectable(decodeSources(defaults.string(forKey: "source")), from: hangulKeys) ?? [sources[0]] }
        set { defaults.set(encodeSources(newValue), forKey: "source") }
    }
    // Keyboards map only the single keys, so a keyboard's Default follows just these.
    var mappedSources: [UInt64] { selectable(defaultSources) ?? [] }
    var chosenCombos: [UInt64] { active ? defaultSources.filter(spaceCombos.contains) : [] }
    var active: Bool { defaults.object(forKey: "active") == nil || defaults.bool(forKey: "active") }
    var longPressCapsLock: Bool { defaults.bool(forKey: "longPressCapsLock") }
    var preserveCapsLock: Bool { defaults.object(forKey: "preserveCapsLock") == nil || defaults.bool(forKey: "preserveCapsLock") }
    // The saved choice waits while Caps Lock is a Korean/English key, however that key was saved.
    var koreanCapsLock: Bool { defaults.bool(forKey: "koreanCapsLock") && !capsLockSwitches() }
    var escapeToEnglish: Bool { defaults.bool(forKey: "escapeToEnglish") }
    // A Caps Lock chosen as a Korean/English key reaches macOS as the reserved F-key, never as Caps Lock; so does the separate key.
    // `fallback` checks default keys before they are saved.
    func capsLockSwitches(_ fallback: [UInt64]? = nil) -> Bool {
        keyboards.maps(sources[2], default: fallback ?? defaultSources) || usesSeparateKey && separateKey == sources[2]
    }
    // Input sources beside Korean and English: the Korean/English key goes round them (cycle), or a key of their own
    // switches to one (separate). Off, nothing changes.
    var addedSourcesEnabled: Bool { defaults.bool(forKey: "addedSources") }
    var addedSourceMode: AddedSourceMode { AddedSourceMode(rawValue: defaults.integer(forKey: "addedSourceMode")) ?? .cycle }
    var usesSeparateKey: Bool { addedSourcesEnabled && addedSourceMode == .separate }
    var addedSourcesCompatible: Bool { defaults.bool(forKey: "addedSourcesCompatibility") }
    // Saved once edited; until then every input source macOS offers.
    var cycleSources: [String]? {
        get { defaults.stringArray(forKey: "cycleSources") }
        set { defaults.set(newValue, forKey: "cycleSources") }
    }
    var separateSource: String? {
        get { defaults.string(forKey: "separateSource") }
        set { defaults.set(newValue, forKey: "separateSource") }
    }
    var separateKey: UInt64? {
        get { (defaults.object(forKey: "separateKey") as? NSNumber).map(\.uint64Value).flatMap { hangulKeys.contains($0) ? $0 : nil } }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: "separateKey") }
    }
    // The separate key's own F-key, so the tap tells it from the Korean/English key. The tap takes every press of it,
    // so it is one no system shortcut uses on its own.
    var separateTarget: TargetKey {
        let order = [18, 17, 16, 20, 19, 15, 14, 13].map { targets[$0 - 13] }.filter { $0.name != target.name }
        return order.first { !systemFKeys.contains($0.keyCode) } ?? order[0]
    }
    // Read when settings change, not on every key.
    private(set) var systemFKeys: Set<Int> = []
    func refreshSystemFKeys() {
        systemFKeys = Set(systemShortcutKeys().filter { [0, Int(CGEventFlags.maskSecondaryFn.rawValue)].contains($0.modifiers) }.map(\.keyCode))
    }
    // Keys of the enabled system shortcuts, except the one this app manages.
    func systemShortcutKeys() -> [(keyCode: Int, modifiers: Int)] {
        shortcutPreferences.read().compactMap { id, raw in
            guard id != "60", let entry = raw as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [NSNumber], parameters.count == 3 else { return nil }
            return (parameters[1].intValue, parameters[2].intValue)
        }
    }
    // Whether a system shortcut is the same Space combination, such as Spotlight's ⌘ + Space.
    func systemShortcutUses(_ key: UInt64) -> Bool {
        spaceCombos.contains(key)
            && systemShortcutKeys().contains { $0.keyCode == kVK_Space && spaceCombo(flags: CGEventFlags(rawValue: UInt64($0.modifiers))) == key }
    }
    var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
    // Mapped like a Korean/English key, but only while the tap can act on it. A Space combination stays in the tap.
    var separateMapping: ExtraKey? {
        guard active, usesSeparateKey, separateSource != nil, let key = separateKey, sources.contains(key), accessibilityTrusted() else { return nil }
        return ExtraKey(source: key, target: separateTarget.usage)
    }
    // Whether another mapping already changes `key` on a keyboard the separate key would apply to.
    func separateKeyConflict(_ key: UInt64) -> Bool {
        services().filter { keyboards.isSelected($0) }.contains { service in
            mappings(service).contains { $0[srcKey]?.uint64Value == key && $0[dstKey]?.uint64Value != separateTarget.usage && !owns(records[id(service)], $0) }
        }
    }
    // A key that is both stays a Korean/English key.
    func separateKeyIsHangulKey(_ fallback: [UInt64]? = nil) -> Bool {
        guard let key = separateKey else { return false }
        return (fallback ?? defaultSources).contains(key) || keyboards.maps(key, default: fallback ?? defaultSources)
    }
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
    // `only` limits the check to the keyboards a settings change affects.
    private func selected(_ fallback: [UInt64], only: Set<String>?) -> [(KeyboardDevice, [UInt64])] {
        services().filter { keyboards.isSelected($0) && only?.contains($0.identity.key) != false }
            .map { ($0, keyboards.sources(for: $0, default: fallback)) }
    }
    // Returns the first key that another mapping already uses.
    func conflict(_ fallback: [UInt64], target: TargetKey, only: Set<String>? = nil) -> UInt64? {
        for (service, keys) in selected(fallback, only: only) {
            let managed = records[id(service)]
            let used = mappings(service).filter { $0[dstKey]?.uint64Value != target.usage && !owns(managed, $0) }.compactMap { $0[srcKey]?.uint64Value }
            if let key = keys.first(where: used.contains) { return key }
        }
        return nil
    }
    func targetInUse(_ fallback: [UInt64], target: TargetKey, only: Set<String>? = nil) -> Bool {
        selected(fallback, only: only).contains { service, keys in
            targetConflict(mappings(service), sources: keys, target: target.usage, owned: records[id(service)])
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
    func apply(sources: [UInt64], target: TargetKey) throws -> Int {
        settingsUpdateDepth += 1
        defer { settingsUpdateDepth -= 1 }
        try shortcut(target: target)
        refreshSystemFKeys()
        defaultSources = sources
        defaults.set(target.name, forKey: "target")
        defaults.set(true, forKey: "active")
        let count = try reconcile()
        try updateSystemInputMenu()
        return count
    }
    func setSystemInputMenu(_ value: CFPropertyList?) throws {
        settingsUpdateDepth += 1
        defer { settingsUpdateDepth -= 1 }
        try inputMenu.write(value)
    }
    // The Mac input menu stays when this app's icon is off, or when the icon does not replace it.
    var replacesInputMenu: Bool { defaults.object(forKey: "replaceInputMenu") == nil || defaults.bool(forKey: "replaceInputMenu") }
    var showsSystemInputMenu: Bool { defaults.bool(forKey: "hidden") || !replacesInputMenu }
    // Hides the Mac input menu only while this app's icon replaces it. Otherwise the menu is the user's own setting:
    // the one from before this app hid it, and later whatever they choose in System Settings.
    func updateSystemInputMenu() throws {
        guard !showsSystemInputMenu else { try restoreSystemInputMenu(); return }
        let current = inputMenu.read()
        if !defaults.bool(forKey: "inputMenuBackedUp") {
            if let current { defaults.set(current, forKey: "originalInputMenu") }
            defaults.set(true, forKey: "inputMenuBackedUp")
        }
        if (current as? NSNumber)?.boolValue != false { try setSystemInputMenu(kCFBooleanFalse) }
    }
    func restoreSystemInputMenu() throws {
        guard defaults.bool(forKey: "inputMenuBackedUp") else { return }
        try setSystemInputMenu(defaults.object(forKey: "originalInputMenu") as CFPropertyList?)
        defaults.removeObject(forKey: "originalInputMenu")
        defaults.removeObject(forKey: "inputMenuBackedUp")
    }
    func reconcile() throws -> Int {
        keyboards.reconcile(sources: defaultSources, target: target.usage, active: active, extra: separateMapping).applied
    }
    // Turning off is saved before anything is undone, so a later failure retries the undo instead of reapplying.
    func restore() throws {
        defaults.set(false, forKey: "active")
        try restoreSystem()
    }
    // Undoes this app's changes to macOS, leaving the saved activation choice alone. Quitting uses it too: logout or
    // restart can end the app with SIGTERM partway through, and the next launch applies again whatever was undone.
    func restoreSystem() throws {
        settingsUpdateDepth += 1
        defer { settingsUpdateDepth -= 1 }
        // The shortcut must not be restored while some keys still emit our target.
        try restoreMappings()
        try restoreSystemInputMenu()
        try restoreShortcut()
    }
    // Applies again what restoreSystem undoes besides the mappings, which repair keeps: at launch,
    // and when a quit or an update stops partway while activation stays on.
    func resume() throws {
        guard !isUpdatingSettings, active, accessibilityTrusted() else { return }
        try shortcut(target: target)
        try updateSystemInputMenu()
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
    func restoreMappings() throws {
        let result = keyboards.reconcile(sources: defaultSources, target: target.usage, active: false)
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

// Claims a Space that starts a chosen combination, with its repeats and release,
// even if the modifier is let go first. Never reads or stores typed text.
struct SpaceComboGate {
    var held = false
    // Shift also types capitals, so a Space after other keys under the same Shift is typed, not a combination.
    var typedWithShift = false
    mutating func note(type: CGEventType, code: Int64, flags: CGEventFlags) {
        if !flags.contains(.maskShift) { typedWithShift = false }
        else if type == .keyDown && code != Int64(kVK_Space) { typedWithShift = true }
    }
    mutating func handle(down: Bool, repeatKey: Bool, flags: CGEventFlags, chosen: [UInt64]) -> (consume: Bool, switchNow: Bool) {
        if repeatKey { return (down && held, false) }
        if !down { defer { held = false }; return (held, false) }
        // A fresh press, even after a release missed while the tap was disabled.
        held = (spaceCombo(flags: flags).map(chosen.contains) ?? false) && !(typedWithShift && flags.contains(.maskShift))
        return (held, held)
    }
}

// This is an explicit user-selected threshold, not a claimed macOS default.
struct LongPressState {
    static let delay: TimeInterval = 0.5
    var key: Int64?
    var started: TimeInterval = 0
    var fired = false
    var cancelled = false
    mutating func begin(key: Int64, now: TimeInterval) {
        self.key = key; started = now; fired = false; cancelled = false
    }
    mutating func claimLong(now: TimeInterval) -> Bool {
        guard key != nil, !cancelled, !fired, now - started >= Self.delay else { return false }
        fired = true
        return true
    }
    mutating func release(key: Int64, now: TimeInterval) -> (owned: Bool, long: Bool) {
        guard self.key == key else { return (false, false) }
        let long = claimLong(now: now)
        self.key = nil
        return (true, long)
    }
    mutating func cancel() { cancelled = true }
}

// Logical English case survives the input method clearing the hardware Caps Lock bit.
// It is session-local: activation starts from the current keyboard state.
struct EnglishCapsState {
    private(set) var remembered: Bool?
    var switching = false { didSet { if !switching { intoEnglish = false } } }
    // A switch that started outside English is on its way there. The input method turns the lock off only on the way
    // into Korean, so a Caps Lock press meanwhile is the user's.
    private var intoEnglish = false
    mutating func enable(actual: Bool) { if remembered == nil { remembered = actual } }
    mutating func reset() { remembered = nil; switching = false }
    mutating func willSwitch(english: Bool, actual: Bool, longPress: Bool) {
        if remembered == nil || (english && !longPress && !switching) { remembered = actual }
        switching = true; intoEnglish = !english
    }
    // A press in Korean sets the English case too when `korean` (Caps Lock in Korean) is on.
    mutating func capsKeyChanged(english: Bool, actual: Bool, korean: Bool = false) {
        guard english || korean, !switching || intoEnglish else { return }
        remembered = actual
    }
    func target(english: Bool) -> Bool? { english ? remembered : nil }
    func beforeLongPress(actual: Bool, preserving: Bool) -> Bool { preserving ? (remembered ?? actual) : actual }
    mutating func committedLongPress(_ desired: Bool) { remembered = desired }
}

// Caps Lock in Korean keeps the lock on only here: 2-Set types Hangul whatever the lock. Other layouts are not checked.
let capsSafeKorean = "com.apple.inputmethod.Korean.2SetKorean"

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
    // No readback: right after a change that took effect it can still report the old state. The restore checks after a
    // switch catch a change that did not.
    let result = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), enabled)
    guard result == KERN_SUCCESS else {
        throw NSError(domain: "gksdud", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Caps Lock 상태를 변경하지 못했습니다."])
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
// A Space combination has no F-key event to copy; a new one carries the flags macOS gives F-keys.
func nativeSwitchPulse(keyCode: Int, marker: Int64) -> (CGEvent, CGEvent)? {
    CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true).flatMap { nativeSwitchPulse(from: $0, marker: marker) }
}

// ESC that may switch: modified ESC stays a shortcut, and a held one acts once.
func plainEscape(type: CGEventType, code: Int64, flags: CGEventFlags, repeated: Bool) -> Bool {
    type == .keyDown && code == Int64(kVK_Escape) && !repeated
        && flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
}

// ESC ends in English lowercase; false when it is already there. The ESC itself still reaches the app.
// In English, `upper` includes the case preservation restores, even before it has, and `switching` tells a switch still on its
// way from that source. Other input sources are left alone: the switch key only returns to the previous source.
func escapeNeedsEnglish(language: String, upper: Bool, switching: Bool) -> Bool {
    language.hasPrefix("ko") || language.hasPrefix("en") && (upper || switching)
}

// The last switch pulse until macOS acts on it; a second pulse meanwhile would switch back.
struct SentSwitch {
    let from: String
    let at: TimeInterval
    func inFlight(now: TimeInterval, language: String) -> Bool { now - at < 0.5 && language == from }
}

// How a transition reaches English. A switch still on its way lands on the other source:
// from Korean it reaches English by itself, from English another one has to come back.
enum EnglishRoute { case now, awaitSwitch, sendSwitch }
func englishRoute(from language: String, switching: Bool) -> EnglishRoute {
    language.hasPrefix("en") ? (switching ? .sendSwitch : .now) : (switching ? .awaitSwitch : .sendSwitch)
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
    let updateHeading = NSTextField(wrappingLabelWithString: "")
    let updateSummary = NSTextView()
    let updateScroll = NSScrollView()
    let updateStatus = NSTextField(wrappingLabelWithString: "")
    let updateButton = NSButton(title: "업데이트 설치", target: nil, action: nil)
    let checkUpdateButton = NSButton(title: "업데이트 확인", target: nil, action: nil)
    var specialButtons: [NSButton] = []
    let specialStatus = NSTextField(wrappingLabelWithString: "")
    var item: NSStatusItem?
    var window: NSWindow!
    var keyboardSettings: KeyboardSettingsController?
    let keyboardWarning = NSTextField(wrappingLabelWithString: "")
    let keyboardWarningRow = NSStackView()
    let warningBadge = WarningBadgeView()
    let picker = SourcePicker()
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
    let replaceInputMenu = NSButton(checkboxWithTitle: "Mac 입력기 아이콘 대체", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    var timer: Timer?
    var menuInputTimer: Timer?
    var observers: [NSObjectProtocol] = []
    var keyTap: CFMachPort?
    var keyTapSource: CFRunLoopSource?
    var pressGate = PressGate()
    var spaceGate = SpaceComboGate()
    // The separate key's F-key.
    var separateGate = PressGate()
    var sourceHistory = SourceHistory()
    var landingGeneration = 0
    // The source a switch is on its way to, and one that waits for it to land.
    var switchLanding: String?
    var queuedSwitch: (target: InputSourceIdentity, pulse: (CGEvent, CGEvent))?
    // Keys typed while such a switch is on its way.
    var holdKeys = false
    var heldKeys: [CGEvent] = []
    var sourceCache: (list: [InputSourceIdentity], layouts: Set<String>)?
    // With added sources, selections that end where they started notify too; they change nothing to restore.
    var sourceNotifications = SourceNotifications()
    // A switch on its way when ESC or a hold wanted English; with added sources it can land elsewhere.
    var englishAfterLanding = false
    lazy var addedSources = AddedSourcesSettings(owner: self)
    var longPress = LongPressState()
    var longPressTimer: DispatchWorkItem?
    var longPressEvent: CGEvent?
    var longPressOwner: pid_t?
    var longPressInitialCaps = false
    var longPressGeneration = 0
    var pendingCapsState: Bool?
    lazy var capsTransitionFeature = longPressSwitch
    var switchErrors: [NSButton: String] = [:]
    var sentSwitch: SentSwitch?
    // Tests answer warnings here without a modal loop.
    var runAlert: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    var capsConfirmationTimer: DispatchWorkItem?
    var englishCaps = EnglishCapsState()
    var capsRestoreGeneration = 0
    var capsRestoreTasks: [DispatchWorkItem] = []
    let nativePulseMarker = Int64.random(in: 1...Int64.max)
    let pressAccess = NSButton(title: "접근성 권한 허용", target: nil, action: nil)
    let pressAccessRequired = NSTextField(labelWithString: "필수")
    let advancedButton = NSButton(title: "고급 설정", target: nil, action: nil)
    // Titles and hints of the settings tabs, with their colors, dimmed along with the controls.
    var settingLabels: [(label: NSTextField, color: NSColor)] = []
    let longPressSwitch = NSButton(checkboxWithTitle: "길게 눌러 대소문자 전환", target: nil, action: nil)
    let preserveCapsSwitch = NSButton(checkboxWithTitle: "한영 전환시 대소문자 보존", target: nil, action: nil)
    let koreanCapsSwitch = NSButton(checkboxWithTitle: "한글 상태에서도 Caps Lock으로 대소문자 전환", target: nil, action: nil)
    let escapeSwitch = NSButton(checkboxWithTitle: "ESC 누를 시 영소문자로 변경", target: nil, action: nil)
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
    func stopKeyTap() {
        optionInput.cancel()
        cancelCapsRestore()
        englishCaps.reset()
        cancelLongPress()
        longPress = LongPressState()
        if let source = keyTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = keyTap { CFMachPortInvalidate(tap) }
        releaseHeldKeys()
        keyTapSource = nil; keyTap = nil; pressGate.held.removeAll(); spaceGate = SpaceComboGate()
        separateGate.held.removeAll()
    }
    func ensureKeyTap() {
        guard AXIsProcessTrusted() else { stopKeyTap(); updatePressAccess(); return }
        if let tap = keyTap, !CFMachPortIsValid(tap) { stopKeyTap() }
        syncCapsPreservation()
        // ESC shares the long-press transition, so it runs while either is on.
        if !engine.active || !engine.longPressCapsLock && !engine.escapeToEnglish { cancelLongPress() }
        guard engine.active, keyTap == nil else { updatePressAccess(); return }
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
                // Keys this app posts again, such as ones held while a switch landed, act only once.
                let ours = event.getIntegerValueField(.eventSourceUserData) == owner.nativePulseMarker
                if !ours && (type == .keyDown || type == .flagsChanged) {
                    owner.spaceGate.note(type: type, code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
                }
                // Before Option input, which would otherwise type Option+Space. While it replays
                // queued strokes, a combination waits in its queue to keep the order.
                if (type == .keyDown || type == .keyUp) && !ours && !owner.optionInput.busy && owner.handleSpaceCombo(event) { return nil }
                if owner.optionInput.handle(event, mode: owner.specialMode, active: owner.engine.active) { return nil }
                // Only the event is checked here. ESC goes on to the app, and the input source is read right after.
                if plainEscape(type: type, code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                               repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
                    && !ours && owner.engine.active && owner.engine.escapeToEnglish {
                    let caps = event.flags.contains(.maskAlphaShift)
                    DispatchQueue.main.async { [weak owner] in owner?.switchToLowercaseEnglish(caps: caps) }
                }
                if type == .flagsChanged {
                    if owner.capsPreservationActive && event.getIntegerValueField(.keyboardEventKeycode) == 57 {
                        let source = owner.currentSource
                        owner.englishCaps.capsKeyChanged(english: source?.language.hasPrefix("en") == true,
                            actual: event.flags.contains(.maskAlphaShift), korean: owner.showsEnglishCase(source))
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
                if ours { return Unmanaged.passUnretained(event) }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                // Keys typed before a switch with selections lands wait for it, so they reach the source it lands on.
                if owner.holdKeys && code != Int64(owner.engine.target.keyCode) && code != Int64(owner.engine.separateTarget.keyCode)
                    && !owner.pressGate.held.contains(code) && !owner.separateGate.held.contains(code) && owner.longPress.key != code {
                    owner.holdKey(event)
                    return nil
                }
                // The separate key's F-key only switches, on press like the Korean/English key.
                if owner.takesSeparateKey(code) {
                    let decision = owner.separateGate.handle(code: code, down: type == .keyDown, repeatKey: repeated, active: true, target: code)
                    if decision.switchNow { _ = owner.switchSeparate() }
                    return decision.consume ? nil : Unmanaged.passUnretained(event)
                }
                if owner.engine.active && type == .keyDown && !repeated && code == Int64(owner.engine.target.keyCode) {
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
                let active = owner.engine.active
                // Allocate before claiming the press, so failure falls back to the original shortcut.
                var pulse: (CGEvent, CGEvent)?
                if active && type == .keyDown && !repeated && !owner.pressGate.held.contains(code)
                    && code == Int64(owner.engine.target.keyCode) {
                    pulse = nativeSwitchPulse(from: event, marker: owner.nativePulseMarker)
                    guard pulse != nil else { return Unmanaged.passUnretained(event) }
                }
                let decision = owner.pressGate.handle(code: code, down: type == .keyDown,
                    repeatKey: repeated, active: active, target: Int64(owner.engine.target.keyCode))
                if decision.switchNow, let pulse {
                    // Re-enter before system hotkey handling, not downstream of the session tap.
                    // The marker bypass above lets both pulses through without another switch.
                    // This switch path only posts the reserved F-key.
                    owner.switchHangul(pulse)
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
        addedSources.refresh()
        let trusted = engine.accessibilityTrusted()
        // Switching needs the tap, so without Accessibility only the permission button and the gksdud tab can be used.
        for control: NSControl in [enabled, login, showInMenuBar, iconPicker, picker, advancedButton] + specialButtons { control.isEnabled = trusted }
        // Only this app's icon can replace the Mac input menu.
        replaceInputMenu.state = engine.replacesInputMenu ? .on : .off
        replaceInputMenu.isEnabled = trusted && showInMenuBar.state == .on
        for preview in [koreanPreview, englishPreview] { preview.contentTintColor = trusted ? .labelColor : .disabledControlTextColor }
        for (label, color) in settingLabels { label.textColor = trusted ? color : .disabledControlTextColor }
        let ready = keyTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        pressAccess.title = trusted ? "권한 허용 완료" : "접근성 권한 허용"
        pressAccess.isEnabled = !trusted
        pressAccessRequired.isHidden = trusted
        longPressSwitch.state = trusted && engine.longPressCapsLock ? .on : .off
        longPressSwitch.isEnabled = trusted
        preserveCapsSwitch.state = trusted && engine.preserveCapsLock ? .on : .off
        preserveCapsSwitch.isEnabled = trusted
        preserveCapsSwitch.toolTip = switchErrors[preserveCapsSwitch] ?? "영어의 대소문자 상태를 기억해 한글에서 영어로 돌아올 때 복원합니다. 길게 누르기와 별도로 설정할 수 있습니다."
        longPressSwitch.toolTip = !trusted ? accessibilityHint : switchErrors[longPressSwitch] ?? "선택한 한영 키를 0.5초 누르면 영어로 전환하고 Caps Lock을 켜거나 끕니다."
        // Caps Lock used as a Korean/English key cannot also turn on uppercase; choosing it turns this off after a warning.
        // It changes the case that preservation keeps, so it works only with preservation.
        let capsTaken = engine.capsLockSwitches()
        koreanCapsSwitch.state = trusted && engine.koreanCapsLock ? .on : .off
        koreanCapsSwitch.isEnabled = trusted && engine.preserveCapsLock && !capsTaken
        koreanCapsSwitch.toolTip = !trusted ? accessibilityHint : capsTaken ? "Caps Lock을 한영 키로 사용하는 동안은 쓸 수 없습니다."
            : !engine.preserveCapsLock ? "대소문자 보존을 켜야 쓸 수 있습니다." : "2벌식에서 한영 전환 없이, 영어로 돌아왔을 때의 대소문자를 바꿉니다."
        escapeSwitch.state = trusted && engine.escapeToEnglish ? .on : .off
        escapeSwitch.isEnabled = trusted
        escapeSwitch.toolTip = trusted ? switchErrors[escapeSwitch] : accessibilityHint
        pressAccess.toolTip = trusted && engine.active && !ready ? "권한 반영을 기다리는 중입니다. 계속 전환되지 않으면 앱을 다시 실행하세요."
            : "키를 누르는 순간 전환하려면 접근성 권한이 필요합니다."
    }
    // Each checkbox saves its own preference; the tap starts or stops with them.
    @objc func toggleFeature(_ sender: NSButton) {
        let keys: [NSButton: String] = [longPressSwitch: "longPressCapsLock",
            preserveCapsSwitch: "preserveCapsLock", koreanCapsSwitch: "koreanCapsLock", escapeSwitch: "escapeToEnglish"]
        guard let key = keys[sender] else { return }
        cancelLongPress()
        switchErrors[sender] = nil
        let koreanCaps = koreanCapsActive
        engine.defaults.set(sender.state == .on, forKey: key)
        if sender === preserveCapsSwitch { turnOffUnusedKoreanCaps() }
        ensureKeyTap()
        if koreanCaps { releaseKoreanCaps() }
    }
    // Caps Lock in Korean works only with preservation, so it goes off with it; left on, it would still warn when Caps Lock
    // becomes a Korean/English or separate key.
    func turnOffUnusedKoreanCaps() {
        if !engine.preserveCapsLock { engine.defaults.set(false, forKey: "koreanCapsLock") }
    }
    var currentLanguage: String {
        TISCopyCurrentKeyboardInputSource().map { language($0.takeRetainedValue()) } ?? ""
    }
    var currentSource: InputSourceIdentity? { TISCopyCurrentKeyboardInputSource().flatMap { Self.sourceIdentity($0.takeRetainedValue()) } }
    var actualCaps: Bool { CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) }
    var capsPreservationActive: Bool { engine.active && engine.preserveCapsLock && AXIsProcessTrusted() }
    var koreanCapsActive: Bool { capsPreservationActive && engine.koreanCapsLock }
    // With Caps Lock in Korean, the lock shows the English case in Korean too.
    func showsEnglishCase(_ source: InputSourceIdentity?) -> Bool { source?.id == capsSafeKorean && engine.koreanCapsLock }
    // Once Caps Lock in Korean stops, the lock it kept on in Korean goes off, as the Korean input method turns it off
    // on the way in. Only a running tap kept it on.
    func releaseKoreanCaps() {
        guard keyTap != nil, !koreanCapsActive, currentSource?.id == capsSafeKorean, actualCaps else { return }
        try? setCapsLock(false)
    }
    // The English case preservation restores, even before it has.
    var rememberedUpper: Bool { capsPreservationActive && englishCaps.target(english: true) == true }
    func syncCapsPreservation() {
        if capsPreservationActive { englishCaps.enable(actual: actualCaps) }
        else { cancelCapsRestore(); englishCaps.reset() }
    }
    func cancelCapsRestore() {
        capsRestoreGeneration += 1
        capsRestoreTasks.forEach { $0.cancel() }
        capsRestoreTasks.removeAll()
    }
    // True when the Space belongs to a chosen combination and must reach neither apps nor system shortcuts.
    func handleSpaceCombo(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Space) else { return false }
        let separate = separateCombo
        let decision = spaceGate.handle(down: event.type == .keyDown,
            repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, flags: event.flags, chosen: engine.chosenCombos + (separate.map { [$0] } ?? []))
        if decision.switchNow, let separate, spaceCombo(flags: event.flags) == separate {
            guard switchSeparate() else { spaceGate.held = false; return false }
        } else if decision.switchNow {
            // Without a pulse, give the Space back instead of swallowing it.
            guard let pulse = nativeSwitchPulse(keyCode: engine.target.keyCode, marker: nativePulseMarker) else { spaceGate.held = false; return false }
            rememberCapsBeforeSwitch()
            switchHangul(pulse)
        }
        return decision.consume
    }
    func rememberCapsBeforeSwitch() {
        guard capsPreservationActive else { return }
        englishCaps.willSwitch(english: currentLanguage.hasPrefix("en"), actual: actualCaps,
            longPress: engine.longPressCapsLock)
        // Also settle if macOS does not change sources (for example, only one is enabled).
        scheduleCapsRestore()
    }
    func restoreEnglishCaps() {
        guard !optionInput.busy, capsPreservationActive, pendingCapsState == nil else { return }
        // With Caps Lock in Korean, Korean shows the English case as well; its input method turns Caps Lock off on the way in.
        let source = currentSource
        guard let desired = englishCaps.target(english: source?.language.hasPrefix("en") == true || showsEnglishCase(source)),
              actualCaps != desired else { return }
        do { try setCapsLock(desired); showSwitchError(nil, on: preserveCapsSwitch) }
        catch { showSwitchError(error.localizedDescription, on: preserveCapsSwitch) }
    }
    func scheduleCapsRestore() {
        cancelCapsRestore()
        guard capsPreservationActive else { return }
        englishCaps.switching = true
        let generation = capsRestoreGeneration
        // Input-source notification and the system's Caps reset can arrive in either order.
        // Bounded checks never replay text and are invalidated on subsequent transitions.
        // The Korean input method has turned Caps Lock off as late as 0.1 seconds after the notification. Only Caps Lock
        // in Korean restores it there, so only it waits that long; Caps Lock presses are ignored until the last check.
        let delays = showsEnglishCase(currentSource) ? [0.0, 0.05, 0.15, 0.3] : [0.0, 0.05, 0.15]
        for delay in delays {
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.capsRestoreGeneration == generation, self.capsPreservationActive else { return }
                self.restoreEnglishCaps()
                if delay == delays.last { self.englishCaps.switching = false; self.capsRestoreTasks.removeAll() }
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
        englishAfterLanding = false
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
        longPress.begin(key: event.getIntegerValueField(.keyboardEventKeycode), now: ProcessInfo.processInfo.systemUptime)
        switchHangul(pulse)
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
        if longPress.release(key: code, now: ProcessInfo.processInfo.systemUptime).long { performLongPress() }
        longPressEvent = nil
        if pendingCapsState == nil { longPressOwner = nil }
    }
    func performLongPress() {
        guard engine.active, engine.longPressCapsLock, AXIsProcessTrusted(),
              longPressOwner == NSWorkspace.shared.frontmostApplication?.processIdentifier else { cancelLongPress(); return }
        beginCapsTransition(!longPressInitialCaps, pulse: longPressEvent.flatMap { nativeSwitchPulse(from: $0, marker: nativePulseMarker) },
            from: longPressSwitch)
    }
    // ESC takes the long-press path with a generated switch key. It has no owner app:
    // ESC often closes the window it was pressed in. `caps` is the lock ESC came with.
    func switchToLowercaseEnglish(caps: Bool) {
        // A transition already on its way ends lowercase; another pulse would switch back.
        // It is ESC's now, so it no longer depends on the app a long press started in.
        if pendingCapsState != nil { pendingCapsState = false; longPressOwner = nil; capsTransitionFeature = escapeSwitch; return }
        let language = currentLanguage
        guard escapeNeedsEnglish(language: language, upper: caps || rememberedUpper, switching: switchInFlight(from: language)) else { return }
        cancelLongPress()
        beginCapsTransition(false, pulse: nativeSwitchPulse(keyCode: engine.target.keyCode, marker: nativePulseMarker), from: escapeSwitch)
    }
    func switchFailure(_ feature: NSButton) -> String {
        feature === escapeSwitch ? "영어 전환을 확인하지 못했습니다. 영어와 한국어를 최근 입력 소스로 선택해주세요."
            : "영어 전환을 확인하지 못해 대문자 전환을 취소했습니다. 영어와 한국어를 최근 입력 소스로 선택해주세요."
    }
    func beginCapsTransition(_ desired: Bool, pulse: (CGEvent, CGEvent)?, from feature: NSButton) {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              availableSource("en") != nil else { cancelLongPress(); return }
        pendingCapsState = desired
        capsTransitionFeature = feature
        let from = language(current), switching = switchInFlight(from: from), route = englishRoute(from: from, switching: switching)
        if addedSourcesActive {
            // A switch on its way can land on any source, so English follows from there. Otherwise it goes straight to English.
            if switching { englishAfterLanding = true }
            else if from.hasPrefix("en") { completeCapsTransition(); return }
            else { guard let pulse, switchToEnglish(pulse) else { cancelLongPress(); return } }
        } else {
            switch route {
            case .now: completeCapsTransition(); return
            case .awaitSwitch: break
            case .sendSwitch:
                // Keep composition on the native shortcut path; no text replay or direct TIS selection.
                guard let pulse else { cancelLongPress(); return }
                postSwitchPulse(pulse)
                // Two are on their way back here, so neither is in flight from this source.
                if switching { sentSwitch = nil }
            }
        }
        // ESC switches only to reach English, so its own switch that went to another source goes back.
        let start = Self.sourceIdentity(current)?.id, revert = feature === escapeSwitch && route == .sendSwitch && !addedSourcesActive
        let generation = longPressGeneration
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.longPressGeneration == generation, self.pendingCapsState != nil else { return }
            let feature = self.capsTransitionFeature
            self.cancelLongPress()
            self.showSwitchError(self.switchFailure(feature), on: feature)
            if revert, let now = self.currentSource, !now.language.hasPrefix("en"), now.id != start,
               let pulse = nativeSwitchPulse(keyCode: self.engine.target.keyCode, marker: self.nativePulseMarker) {
                self.postSwitchPulse(pulse)
            }
        }
        capsConfirmationTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeout)
    }
    func completeCapsTransition() {
        guard let desired = pendingCapsState else { return }
        guard engine.active, longPressOwner == nil || longPressOwner == NSWorkspace.shared.frontmostApplication?.processIdentifier else { cancelLongPress(); return }
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), language(current).hasPrefix("en") else {
            if englishAfterLanding, let current = currentSource, !switchInFlight(from: current.language) {
                englishAfterLanding = false
                if let pulse = nativeSwitchPulse(keyCode: engine.target.keyCode, marker: nativePulseMarker), switchToEnglish(pulse) { return }
            }
            return
        }
        englishAfterLanding = false
        pendingCapsState = nil
        capsConfirmationTimer?.cancel(); capsConfirmationTimer = nil
        do {
            try setCapsLock(desired)
            if capsPreservationActive { englishCaps.committedLongPress(desired) }
            scheduleCapsRestore()
            showSwitchError(nil, on: capsTransitionFeature)
        } catch { showSwitchError(error.localizedDescription, on: capsTransitionFeature) }
    }
    // Shown on the feature's checkbox until it next succeeds. Do not steal typing focus with a modal alert.
    func showSwitchError(_ message: String?, on feature: NSButton) {
        guard switchErrors[feature] != message else { return }
        switchErrors[feature] = message
        updatePressAccess()
    }
    func postSwitchPulse(_ pulse: (CGEvent, CGEvent)) {
        noteSwitchSent()
        pulse.0.post(tap: .cghidEventTap); pulse.1.post(tap: .cghidEventTap)
    }
    // Only ESC asks, so the input source is read only while it is on.
    func noteSwitchSent() {
        guard engine.escapeToEnglish else { return }
        sentSwitch = SentSwitch(from: currentLanguage, at: ProcessInfo.processInfo.systemUptime)
    }
    func switchInFlight(from language: String) -> Bool { sentSwitch?.inFlight(now: ProcessInfo.processInfo.systemUptime, language: language) == true }
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
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(enabledSourcesChanged), name: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil)
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
        do { try engine.resume() } catch { report(error) }
        seedSourceHistory(); engine.refreshSystemFKeys(); turnOffUnusedKoreanCaps()
        repair()
        if showInMenuBar.state == .off || CommandLine.arguments.contains("--settings") { showSettings() }
        UpdateInstaller.acknowledgeLaunch()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil else { return }
        ensureKeyTap()
        if returningFromPermissionSettings && permissionSettingsWasActive { finishPermissionVisit() }
    }
    @objc func showKeyboardSettings() {
        repair()
        if keyboardSettings == nil {
            keyboardSettings = KeyboardSettingsController(engine: engine, targetPicker: targetPicker, sourcesChanged: { [weak self] keys in
                self?.picker.show(keys); self?.selectionChanged()
            }, confirm: { [weak self] keyboards in self?.confirmKeyboardChange(keyboards) ?? true }) { [weak self] in self?.repair() }
        }
        keyboardSettings?.show(on: window)
    }
    // The keyboard sheet saves a change before this check and undoes it on false.
    func confirmKeyboardChange(_ keyboards: Set<String>) -> Bool {
        guard confirmCapsLockKey(engine.capsLockSwitches()), confirmSeparateKey(),
              !engine.active || confirmMapping(engine.defaultSources, target: engine.target, only: keyboards) else { return false }
        releaseKoreanCapsLock(); releaseSeparateKey()
        return true
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
        updateEntry.image = updateGlyph(NSSize(width: 22, height: 20))
        updateEntry.isHidden = updates.available == nil
        menu.addItem(updateEntry)
        menu.addItem(NSMenuItem.separator())
        let koreanEntry = menu.addItem(withTitle: "한국어", action: #selector(selectKorean), keyEquivalent: "")
        koreanEntry.target = self; koreanEntry.image = sourceMenuIcon(korean: true)
        let englishEntry = menu.addItem(withTitle: "영어", action: #selector(selectEnglish), keyEquivalent: "")
        englishEntry.target = self; englishEntry.image = sourceMenuIcon(korean: false)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "활성화", action: #selector(menuEnabled), keyEquivalent: "").target = self
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
        let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        return list.first { language($0).hasPrefix(prefix) }
    }
    @objc func inputSourceChanged() {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            let id = self.currentSource?.id
            if let id { self.sourceHistory.note(id) }
            if id == self.switchLanding {
                self.switchLanding = nil
                // After this notification is handled, like a key pressed now.
                DispatchQueue.main.async { [weak self] in self?.runQueuedSwitch() }
            }
            let added = self.addedSourcesActive
            guard self.sourceNotifications.handles(id, addedSources: added) else { return }
            // The switch on its way has landed, so the next ESC needs its own. With added sources the selections before a
            // switch notify too, while the source is still the one the switch leaves.
            if !added || self.sentSwitch.map({ self.currentLanguage != $0.from }) != false { self.sentSwitch = nil }
            guard !self.optionInput.busy else { return }
            self.completeCapsTransition()
            self.scheduleCapsRestore()
            self.restoreEnglishCaps()
            self.updateInputIndicator()
        }
    }
    @objc func enabledSourcesChanged() {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.sourceCache = nil; self?.addedSources.refresh(force: true) }
    }
    func updateInputIndicator() {
        // The Option-character round trip selects English for a moment; didFinish refreshes afterwards.
        guard !optionInput.busy, switchLanding == nil else { return }
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let lang = language(current)
        updateInputMenuState(language: lang)
        let other = sourceBadgeLabel(lang, position: currentSource.flatMap { sourcePosition($0.id) })
        let label = lang.hasPrefix("ko") ? iconLabel(korean: true) : lang.hasPrefix("en") ? iconLabel(korean: false) : other
        let korean = lang.hasPrefix("ko")
        // This runs every second, and setting an image redraws it; keep the one showing while the source and style stay.
        let key = "\(iconStyle)|\(lang)|\(label)"
        let badge: NSImage
        if let shown = shownBadge, shown.key == key { badge = shown.image } else {
            // Let the status bar resolve contrast, including its initial appearance and highlighting.
            badge = korean || lang.hasPrefix("en") ? sourceMenuIcon(korean: korean) : badgeImage(label: label, filled: false)
            shownBadge = (key, badge)
        }
        if inputBadge.image !== badge {
            inputBadge.image = badge
            inputBadge.setAccessibilityLabel("현재 입력: \(korean ? "한국어" : lang.hasPrefix("en") ? "영어" : label)")
        }
        if tabButtons.first?.image !== badge { tabButtons.first?.image = badge }
        guard let button = item?.button else { return }
        if button.image !== badge { button.title = ""; button.image = badge; button.imagePosition = .imageOnly }
        let warning = engine.keyboards.warning.map { "\n\($0)" } ?? ""
        let tip = "gksdud · 현재 입력 소스: \(lang)\(warning)"
        let spoken = "gksdud, 현재 입력 \(korean ? "한국어" : lang.hasPrefix("en") ? "영어" : label)\(warning)"
        if button.toolTip != tip { button.toolTip = tip }
        if button.accessibilityLabel() != spoken { button.setAccessibilityLabel(spoken) }
    }
    private var shownBadge: (key: String, image: NSImage)?
    func menuWillOpen(_ menu: NSMenu) {
        refreshAddedMenuItems(menu)
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
            case #selector(menuEnabled): entry.state = engine.active ? .on : .off; entry.isEnabled = engine.accessibilityTrusted()
            case #selector(menuLogin): entry.state = login.state; entry.isEnabled = engine.accessibilityTrusted()
            case #selector(menuHidden): entry.state = showInMenuBar.state; entry.isEnabled = engine.accessibilityTrusted()
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
            if entry.action == #selector(selectAddedSource(_:)) { entry.state = entry.representedObject as? String == currentSource?.id ? .on : .off }
        }
    }
    func selectLanguage(_ prefix: String) { if let source = availableSource(prefix) { rememberCapsBeforeSwitch(); _ = TISSelectInputSource(source) }; updateInputIndicator() }
    @objc func selectKorean() { selectLanguage("ko") }
    @objc func selectEnglish() { selectLanguage("en") }
    @objc func menuEnabled() { enabled.state = engine.active ? .off : .on; toggleEnabled() }
    @objc func menuLogin() { login.state = SMAppService.mainApp.status == .enabled ? .off : .on; toggleLogin() }
    @objc func menuHidden() { showInMenuBar.state = showInMenuBar.state == .on ? .off : .on; toggleHidden() }
    @objc func showSettings() { if !window.isVisible { selectTab(0) }; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if showInMenuBar.state == .off { showSettings() }; return true }
    @objc func toggleHidden() {
        engine.defaults.set(showInMenuBar.state == .off, forKey: "hidden")
        updateMenu(); updatePressAccess()
        if engine.active { do { try engine.updateSystemInputMenu() } catch { report(error) } }
    }
    @objc func toggleReplaceInputMenu() {
        engine.defaults.set(replaceInputMenu.state == .on, forKey: "replaceInputMenu")
        if engine.active { do { try engine.updateSystemInputMenu() } catch { report(error) } }
    }
    @objc func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            stickyError = ""; refreshStatus()
        } catch { login.state = SMAppService.mainApp.status == .enabled ? .on : .off; report(error) }
    }
    func resetSelection() {
        picker.show(engine.defaultSources)
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
        guard confirmCapsLockKey(engine.capsLockSwitches(picker.selection)), confirmSeparateKey(picker.selection) else { resetSelection(); return }
        if enabled.state == .on { applyNow() }
        else {
            if let keys = picker.selection { engine.defaultSources = keys }
            engine.defaults.set(targets[targetPicker.indexOfSelectedItem].name, forKey: "target")
        }
        releaseKoreanCapsLock(); releaseSeparateKey()
    }
    // False keeps the old keys.
    func confirmCapsLockKey(_ taken: Bool, as role: String = "한영 키") -> Bool {
        // The saved choice: the keyboard sheet asks after saving the new keys, which already pause it.
        guard taken, engine.defaults.bool(forKey: "koreanCapsLock") else { return true }
        let alert = NSAlert(); alert.messageText = "Caps Lock을 \(role)로 사용합니다."
        alert.informativeText = "'\(koreanCapsSwitch.title)' 기능이 꺼집니다."
        alert.addButton(withTitle: "변경"); alert.addButton(withTitle: "취소")
        return runAlert(alert) == .alertFirstButtonReturn
    }
    // Caps Lock in Korean goes off only once Caps Lock is saved as a Korean/English key, so a later warning that
    // cancels the change keeps it.
    func releaseKoreanCapsLock() {
        if engine.defaults.bool(forKey: "koreanCapsLock") && engine.capsLockSwitches() {
            engine.defaults.set(false, forKey: "koreanCapsLock")
            releaseKoreanCaps()
        }
        updatePressAccess()
    }
    func confirmMapping(_ keys: [UInt64], target: TargetKey, only keyboards: Set<String>? = nil) -> Bool {
        if engine.targetInUse(keys, target: target, only: keyboards) {
            let alert = NSAlert(); alert.messageText = "\(target.name)은 다른 키 매핑에서 사용 중입니다."
            alert.informativeText = "다른 앱과 충돌할 수 있습니다. 대상 키를 바꿔주세요."
            _ = runAlert(alert); return false
        }
        if let key = engine.conflict(keys, target: target, only: keyboards) {
            let alert = NSAlert(); alert.messageText = "\(sourceName(key))에 다른 매핑이 있습니다."
            alert.informativeText = "선택한 키를 한영 전환 전용으로 바꿉니다. 다른 앱에서도 이 키의 재매핑을 꺼주세요. 기존 매핑은 해제 시 복원됩니다."
            alert.addButton(withTitle: "변경"); alert.addButton(withTitle: "취소")
            return runAlert(alert) == .alertFirstButtonReturn
        }
        return true
    }
    func applyNow() {
        guard !engine.isUpdatingSettings else { return }
        defer { resetSelection(); refreshKeyboardState() }
        let keys = picker.selection ?? engine.defaultSources
        let target = targets[targetPicker.indexOfSelectedItem]
        guard confirmMapping(keys, target: target) else { resetSelection(); return }
        do { _ = try engine.apply(sources: keys, target: target); lastError = ""; stickyError = ""; repairFailed = false; ensureKeyTap(); refreshStatus() } catch { report(error); resetSelection() }
    }
    func restoreNow() {
        optionInput.cancel()
        guard !engine.isUpdatingSettings else { return }
        cancelLongPress()
        do { try engine.restore(); lastError = ""; stickyError = ""; repairFailed = false; refreshStatus() } catch { report(error) }
        resetSelection(); syncCapsPreservation(); updatePressAccess(); refreshKeyboardState()
    }
    func recover() { sourceCache = nil; queuedSwitch = nil; releaseHeldKeys(); optionInput.cancel(); cancelCapsRestore(); englishCaps.switching = false; cancelLongPress(); longPress = LongPressState(); pressGate.held.removeAll(); spaceGate = SpaceComboGate(); separateGate.held.removeAll(); for delay in [0.5, 2.0, 5.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.repair() } } }
    func repair() {
        guard !engine.isUpdatingSettings else { return }
        // Without Accessibility there is no tap to switch with, so activation turns off and stays off until turned on again.
        if engine.active && !engine.accessibilityTrusted() { restoreNow(); return }
        ensureKeyTap()
        do { try engine.repair(); if repairFailed { repairFailed = false; stickyError = "" } } catch { report(error); repairFailed = !(error is KeyboardError) }
        if engine.keyboards.result.pending == 0 { lastError = "" }
        refreshStatus(); refreshKeyboardState()
    }
    // Only conditions the user must act on; each stays until it is resolved.
    func refreshStatus() {
        let result = engine.keyboards.result
        status.stringValue = result.pending > 0 ? "키보드 설정을 다시 적용하고 있습니다."
            : !stickyError.isEmpty ? stickyError
            : !engine.chosenCombos.isEmpty && !AXIsProcessTrusted() ? "조합 키를 쓰려면 접근성 권한을 허용하세요."
            : engine.active && result.selected == 0 && !engine.mappedSources.isEmpty ? "적용할 키보드 연결 대기 중"
            : window.isVisible && login.state == .on && SMAppService.mainApp.status == .requiresApproval ? "시스템 설정 → 로그인 항목에서 gksdud를 허용하세요." : ""
    }
    var lastError = ""
    var stickyError = ""
    var repairFailed = false
    func report(_ error: Error) {
        if error is KeyboardError { refreshKeyboardState(); return }
        stickyError = error.localizedDescription; refreshStatus()
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
            try engine.restoreSystem()
            stopKeyTap()
            timer?.invalidate()
            enabled.state = .off
            return .terminateNow
        } catch {
            report(error)
            do { try engine.resume() } catch { report(error) }
            return .terminateCancel
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.dropFirst().first == "--install-update" {
    do { try UpdateInstaller.runHelper(CommandLine.arguments) } catch { fputs("Update helper failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else {
    #if TESTS
    if runTestMode() { exit(0) }
    #endif
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
