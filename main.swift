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
// macOS's input source shortcuts never fire on F20, so the Korean/English key's F-key is one of the others.
let switchTargets = targets.filter { $0.name != "F20" }
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
        && ([record["target"], record["pendingTarget"]].contains(String(target))
            || (extraTargets(record["extraTarget"]) + extraTargets(record["pendingExtraTarget"])).contains(target))
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
    var chosenCombos: [UInt64] { active && !paused ? defaultSources.filter(spaceCombos.contains) : [] }
    var active: Bool { defaults.object(forKey: "active") == nil || defaults.bool(forKey: "active") }
    // Off for a while from the command line, such as while another app is in front: keyboards keep their own keys and the
    // tap stops, but the shortcut and the input menu stay, so it turns back on at once. Not saved; turning activation on ends it.
    var paused = false
    var longPressCapsLock: Bool { defaults.bool(forKey: "longPressCapsLock") }
    var preserveCapsLock: Bool { defaults.object(forKey: "preserveCapsLock") == nil || defaults.bool(forKey: "preserveCapsLock") }
    // The saved choice waits while Caps Lock is a Korean/English key, however that key was saved.
    var koreanCapsLock: Bool { defaults.bool(forKey: "koreanCapsLock") && !capsLockSwitches() }
    var escapeToEnglish: Bool { defaults.bool(forKey: "escapeToEnglish") }
    var swapBackquote: Bool { defaults.bool(forKey: "swapBackquote") }
    var universalControlCompat: Bool { defaults.bool(forKey: "universalControlCompat") }
    // A Caps Lock chosen as a Korean/English key reaches macOS as the reserved F-key, never as Caps Lock; so does a source's key.
    // `fallback` checks default keys before they are saved.
    func capsLockSwitches(_ fallback: [UInt64]? = nil) -> Bool {
        keyboards.maps(sources[2], default: fallback ?? defaultSources) || usedSourceKeys.values.contains(sources[2])
    }
    // Input sources beside Korean and English: the Korean/English key goes round some of them, and a source can have a key
    // of its own. Off, nothing changes.
    var addedSourcesEnabled: Bool { defaults.bool(forKey: "addedSources") }
    var addedSourcesCompatible: Bool { defaults.bool(forKey: "addedSourcesCompatibility") }
    // Saved once edited; until then every input source macOS offers. Sources turned off keep their place.
    var cycleSources: [String]? {
        get { defaults.stringArray(forKey: "cycleSources") }
        set { defaults.set(newValue, forKey: "cycleSources") }
    }
    // Sources this app leaves alone: out of the cycle, without their keys, and never a way back.
    var disabledSources: Set<String> {
        get { Set(defaults.stringArray(forKey: "disabledSources") ?? []) }
        set { defaults.set(newValue.isEmpty ? nil : newValue.sorted(), forKey: "disabledSources") }
    }
    // A key of a source's own, at most one source per key.
    var sourceKeys: [String: UInt64] {
        get {
            (defaults.dictionary(forKey: "sourceKeys") as? [String: NSNumber] ?? [:])
                .compactMapValues { hangulKeys.contains($0.uint64Value) ? $0.uint64Value : nil }
        }
        set { defaults.set(newValue.isEmpty ? nil : newValue.mapValues { NSNumber(value: $0) }, forKey: "sourceKeys") }
    }
    func setSourceKey(_ key: UInt64?, for id: String) {
        let old = sourceKeys
        var keys = old.filter { $0.key != id && $0.value != key }
        if let key { keys[id] = key }
        sourceKeys = keys
        // A source that loses its key starts over on an automatic F-key when it gets one again.
        let dropped = Set(old.keys).subtracting(keys.keys)
        if !dropped.isEmpty { manualInternalKeys = manualInternalKeys.filter { !dropped.contains($0.key) } }
    }
    // F-keys chosen by hand for sources' keys, by name; the others are assigned automatically.
    var manualInternalKeys: [String: String] {
        get { defaults.dictionary(forKey: "sourceInternalKeys") as? [String: String] ?? [:] }
        set { defaults.set(newValue.isEmpty ? nil : newValue, forKey: "sourceInternalKeys") }
    }
    // nil goes back to automatic. A key chosen for another source moves here, and that one goes back to automatic.
    func setInternalKey(_ name: String?, for id: String) {
        var manual = manualInternalKeys.filter { $0.key != id && $0.value != name }
        if let name { manual[id] = name }
        manualInternalKeys = manual
    }
    // Pressed again in its source, a source's key goes back to the source before it. Off until chosen.
    var sourceKeyReturns: Bool { defaults.bool(forKey: "sourceKeyReturns") }
    // The input sources macOS offers, set by the app; nil counts every saved one. A source removed in System Settings keeps
    // its settings for when it comes back, but its key goes back to the keyboard meanwhile.
    var availableSources: () -> Set<String>? = { nil }
    // The keys of the sources turned on that macOS offers.
    var usedSourceKeys: [String: UInt64] {
        guard addedSourcesEnabled else { return [:] }
        let disabled = disabledSources, available = availableSources()
        return sourceKeys.filter { !disabled.contains($0.key) && available?.contains($0.key) != false }
    }
    // Each single key's own F-key, so the tap tells them from the Korean/English key and each other. The tap takes every
    // press of them, so they are ones no system shortcut uses on their own while there are enough.
    // One chosen by hand comes first, unless it is the Korean/English key's own.
    var sourceKeyTargets: [UInt64: TargetKey] { internalKeys().mapValues(\.target) }
    // `ignoring` shows where a source's key would go back to automatically.
    func internalKeys(ignoring: String? = nil) -> [UInt64: (target: TargetKey, automatic: Bool)] {
        let used = usedSourceKeys, manual = manualInternalKeys.filter { $0.key != ignoring }
        var result: [UInt64: (target: TargetKey, automatic: Bool)] = [:]
        for key in sources where used.values.contains(key) {
            guard let id = used.first(where: { $0.value == key })?.key, let name = manual[id],
                  let chosen = targets.first(where: { $0.name == name }), chosen.name != target.name else { continue }
            result[key] = (chosen, false)
        }
        let taken = Set(result.values.map(\.target.name) + [nextTarget?.name].compactMap { $0 }), foreign = keyboards.result.foreignTargets
        let order = [18, 17, 16, 20, 19, 15, 14, 13].map { targets[$0 - 13] }.filter { $0.name != target.name && !taken.contains($0.name) }
        // F-keys a system shortcut or another mapping uses come last.
        let free = order.filter { !systemFKeys.contains($0.keyCode) && !foreign.contains($0.usage) }
            + order.filter { systemFKeys.contains($0.keyCode) || foreign.contains($0.usage) }
        for (key, target) in zip(sources.filter { used.values.contains($0) && result[$0] == nil }, free) { result[key] = (target, true) }
        return result
    }
    // The F-key a source's key goes to, nil without a single key in use.
    func internalKey(for id: String) -> (target: TargetKey, automatic: Bool)? { usedSourceKeys[id].flatMap { internalKeys()[$0] } }
    // Read when settings change, not on every key.
    private(set) var systemFKeys: Set<Int> = []
    func refreshSystemFKeys() {
        systemFKeys = Set(systemShortcutKeys().filter { [0, Int(CGEventFlags.maskSecondaryFn.rawValue)].contains($0.modifiers) }.map(\.keyCode))
    }
    // Keys of the enabled system shortcuts, except the one this app manages.
    func systemShortcutKeys() -> [(keyCode: Int, modifiers: Int)] {
        shortcutPreferences.read().compactMap { id, raw in
            guard id != "60", id != "61" || !defaults.bool(forKey: "nextShortcutBackedUp"), let entry = raw as? [String: Any],
                  (entry["enabled"] as? NSNumber)?.boolValue == true,
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
    // While the screen is locked or another user's session is in front, keyboards keep their own keys: no key press
    // reaches the tap there, so a mapped Caps Lock could not even turn uppercase off. The app sets this at launch.
    var sessionAway: () -> Bool = { false }
    // Mapped like a Korean/English key, but only while the tap can act on them. Space combinations stay in the tap.
    var sourceKeyMappings: [ExtraKey] {
        guard active, accessibilityTrusted() else { return [] }
        return sourceKeyTargets.map { ExtraKey(source: $0.key, target: $0.value.usage) }.sorted { $0.target < $1.target }
    }
    // Whether another mapping already changes `key` on a keyboard the sources' keys would apply to.
    func sourceKeyConflict(_ key: UInt64) -> Bool {
        let ours = Set(sourceKeyTargets.values.map(\.usage))
        return services().filter { keyboards.isSelected($0) }.contains { service in
            mappings(service).contains { $0[srcKey]?.uint64Value == key && !ours.contains($0[dstKey]?.uint64Value ?? 0) && !owns(records[id(service)], $0) }
        }
    }
    // Sources' keys that are Korean/English keys too, saved or about to be; such a key stays a Korean/English key.
    func sourceKeysAmongHangulKeys(_ fallback: [UInt64]? = nil) -> [String: UInt64] {
        usedSourceKeys.filter { (fallback ?? defaultSources).contains($0.value) || keyboards.maps($0.value, default: fallback ?? defaultSources) }
    }
    // Saved settings of the earlier cycle-or-separate choice become the same behavior here: separate kept Korean and English
    // on the Korean/English key and gave one more source a key that goes there and back.
    func migrateAddedSources(enabled: [InputSourceIdentity]) {
        guard let mode = defaults.object(forKey: "addedSourceMode") as? NSNumber else { return }
        if mode.intValue == 1 {
            // Separate went between one Korean and one English source; another layout of either language still counts as it.
            cycleSources = [enabled.first(where: isKorean), enabled.first(where: isEnglish)].compactMap { $0?.id }
            if let id = defaults.string(forKey: "separateSource"), let key = (defaults.object(forKey: "separateKey") as? NSNumber)?.uint64Value,
               hangulKeys.contains(key) { setSourceKey(key, for: id) }
            // The separate key went there and back.
            defaults.set(true, forKey: "sourceKeyReturns")
        }
        for key in ["addedSourceMode", "separateSource", "separateKey"] { defaults.removeObject(forKey: key) }
    }
    var testInputText: String {
        get { defaults.string(forKey: "testInputText") ?? "한dud한dud한dud한dud" }
        set { defaults.set(newValue, forKey: "testInputText") }
    }
    var target: TargetKey { switchTargets.first { $0.name == defaults.string(forKey: "target") } ?? targets[6] }
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
        for (id, raw) in keys where id != "60" && (id != "61" || !defaults.bool(forKey: "nextShortcutBackedUp")) {
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
        try updateNextShortcut()
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
        let away = sessionAway() || paused, extras = sourceKeyMappings
        var result = keyboards.reconcile(sources: defaultSources, target: target.usage, active: active, away: away, extras: extras)
        // An automatic F-key that turns out to be another mapping's moves to a free one at once.
        if !result.blockedTargets.isEmpty, sourceKeyMappings != extras {
            result = keyboards.reconcile(sources: defaultSources, target: target.usage, active: active, away: away, extras: sourceKeyMappings)
        }
        return result.applied
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
        try restoreNextShortcut()
        try restoreShortcut()
    }
    // Applies again what restoreSystem undoes besides the mappings, which repair keeps: at launch,
    // and when a quit or an update stops partway while activation stays on.
    func resume() throws {
        guard !isUpdatingSettings, active, accessibilityTrusted() else { return }
        try shortcut(target: target)
        try updateSystemInputMenu()
        refreshSystemFKeys()
        try updateNextShortcut()
    }
    // The input menu's next-source shortcut (61), on an F-key of its own while added sources are on: a step of the cycle to
    // the menu's next source then needs no selections before it, as a step back to the previous one does not.
    var nextTarget: TargetKey? {
        guard active, addedSourcesEnabled else { return nil }
        let manual = Set(manualInternalKeys.values), foreign = keyboards.result.foreignTargets
        // macOS takes a system shortcut on these alone; F14, F15 and F20 did not switch.
        let free = [16, 13, 17, 18].map { targets[$0 - 13] }.filter {
            $0.name != target.name && !manual.contains($0.name) && !systemFKeys.contains($0.keyCode) && !foreign.contains($0.usage)
        }
        // The one set stays while it is free, so the shortcut is not written again.
        let managed = defaults.bool(forKey: "nextShortcutBackedUp") ? (defaults.object(forKey: "managedNextShortcutKeyCode") as? NSNumber)?.intValue : nil
        return free.first { $0.keyCode == managed } ?? free.first
    }
    // Set once the shortcut is written and active, so a pulse on that F-key switches.
    private(set) var liveNextTarget: TargetKey?
    // The F-key whose pulse changed nothing; a new write or restore of the shortcut tries it again.
    var nextFailedKey: String?
    func updateNextShortcut() throws {
        guard let next = nextTarget else { try restoreNextShortcut(); return }
        var keys = shortcutPreferences.read()
        let backedUp = defaults.bool(forKey: "nextShortcutBackedUp")
        if backedUp && Self.ownsShortcut(keys["61"], keyCode: next.keyCode) {
            // Written before but not activated.
            if defaults.bool(forKey: "nextActivatePending") {
                settingsUpdateDepth += 1
                defer { settingsUpdateDepth -= 1 }
                try shortcutPreferences.activate()
                defaults.removeObject(forKey: "nextActivatePending")
            }
            defaults.set(next.keyCode, forKey: "managedNextShortcutKeyCode")
            if liveNextTarget?.name != next.name { liveNextTarget = next }
            followedNext = nil
            return
        }
        settingsUpdateDepth += 1
        defer { settingsUpdateDepth -= 1 }
        let managed = (defaults.object(forKey: "managedNextShortcutKeyCode") as? NSNumber)?.intValue
        if !backedUp || !Self.ownsShortcut(keys["61"], keyCode: managed ?? -1) {
            defaults.set(keys["61"], forKey: "originalNextShortcut")
            defaults.set(true, forKey: "nextShortcutBackedUp")
        }
        liveNextTarget = nil; nextFailedKey = nil
        defaults.removeObject(forKey: "nextRestorePending")
        keys["61"] = ["enabled": true, "value": ["type": "standard", "parameters": [65535, next.keyCode, 0]]] as [String: Any]
        defaults.set(next.keyCode, forKey: "managedNextShortcutKeyCode")
        defaults.set(true, forKey: "nextActivatePending")
        try shortcutPreferences.write(keys)
        try shortcutPreferences.activate()
        defaults.removeObject(forKey: "nextActivatePending")
        liveNextTarget = next
        followedNext = nil
    }
    // Gives the user's own next-source shortcut back, unless it was changed since.
    func restoreNextShortcut() throws {
        liveNextTarget = nil; nextFailedKey = nil
        guard defaults.bool(forKey: "nextShortcutBackedUp") else { return }
        settingsUpdateDepth += 1
        defer { settingsUpdateDepth -= 1 }
        var keys = shortcutPreferences.read()
        let managed = (defaults.object(forKey: "managedNextShortcutKeyCode") as? NSNumber)?.intValue ?? -1
        let original = defaults.object(forKey: "originalNextShortcut")
        // Written but not activated last time.
        let resumeActivation = defaults.bool(forKey: "nextRestorePending") && Self.sameShortcut(keys["61"], original)
        if Self.ownsShortcut(keys["61"], keyCode: managed) {
            keys["61"] = original
            defaults.set(true, forKey: "nextRestorePending")
            try shortcutPreferences.write(keys)
            try shortcutPreferences.activate()
        } else if resumeActivation { try shortcutPreferences.activate() }
        for key in ["nextShortcutBackedUp", "originalNextShortcut", "managedNextShortcutKeyCode", "nextRestorePending", "nextActivatePending"] {
            defaults.removeObject(forKey: key)
        }
        followedNext = nil
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
        if active { _ = try reconcile(); if try followNextTarget() { _ = try reconcile() } }
        else { try restore() }
    }
    // The free F-key can change as mappings are read, the first time on launch; the shortcut follows it, and the sources'
    // automatic F-keys with it. Tried once per change, so a failing write or activation does not repeat every second; any
    // explicit update or a wake tries again.
    @discardableResult func followNextTarget() throws -> Bool {
        let wanted = nextTarget?.keyCode
        let managed = defaults.bool(forKey: "nextShortcutBackedUp") ? (defaults.object(forKey: "managedNextShortcutKeyCode") as? NSNumber)?.intValue : nil
        let pending = defaults.bool(forKey: "nextRestorePending") || defaults.bool(forKey: "nextActivatePending")
        guard wanted != managed || pending, followedNext != .some(wanted) else { return false }
        followedNext = wanted
        try updateNextShortcut()
        return true
    }
    var followedNext: Int??
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
    // A change only a key's flags showed, as after a Caps Lock press that sent no event of its own. English only and not
    // mid-switch, where the Korean input method turns the lock off by itself.
    mutating func lockSeen(english: Bool, actual: Bool) { if english && !switching { remembered = actual } }
    // A key from another Mac carries that Mac's keyboard lock, the case it types here whatever happened to the lock here.
    mutating func followSender(_ caps: Bool) { remembered = caps }
    // Other sources type their own letters with the lock off, as the Korean input method turns it off on the way in;
    // English gets its case back on the way out.
    func target(english: Bool) -> Bool? { english ? remembered : remembered.map { _ in false } }
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

// Read from the session: secure input turns on and off on the lock screen, and the lock notice can come 0.5 seconds late.
func screenLockedOrAway() -> Bool {
    guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return info["CGSSessionScreenIsLocked"] as? Bool == true || info[kCGSessionOnConsoleKey as String] as? Bool == false
}

// Only the reserved function key is synthesized. Text keys are never buffered.
func nativeSwitchPulse(from event: CGEvent, marker: Int64) -> (CGEvent, CGEvent)? {
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    guard event.type == .keyDown, targets.contains(where: { Int64($0.keyCode) == code }),
          let down = event.copy(), let up = event.copy() else { return nil }
    down.type = .keyDown; up.type = .keyUp
    for pulse in [down, up] {
        // Strip held modifiers, but preserve the function-key identity flags. Caps Lock is added as it goes.
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
// The flags of a key this app posts, with Caps Lock as it is then.
func capsFlags(_ flags: CGEventFlags, caps: Bool) -> CGEventFlags { caps ? flags.union(.maskAlphaShift) : flags.subtracting(.maskAlphaShift) }

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

// The text of a menu bar icon style; the character style draws a face instead. `upper` is the English case to show, or
// nil for English as it always looked. Only English shows the case.
func iconLabel(style: Int, korean: Bool, upper: Bool? = nil) -> String {
    if korean { return style == 2 ? "KO" : "한" }
    switch style {
    case 0: return upper == true ? "DuD" : "dud"
    case 1: return upper == false ? "a" : "A"
    default: return upper == false ? "en" : "EN"
    }
}

// The case English icons show: the lock while English is current, and elsewhere the case preservation restores on the
// way back, or the lock without it.
func englishIconCase(inEnglish: Bool, lock: Bool, restores: @autoclosure () -> Bool?) -> Bool { inEnglish ? lock : restores() ?? lock }

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
    // The case option waits while the menu bar icon is hidden, as replacing the Mac input menu does.
    var showsIconCase: Bool { engine.defaults.bool(forKey: "iconCase") && !engine.defaults.bool(forKey: "hidden") }
    let enabled = NSButton(checkboxWithTitle: "활성화", target: nil, action: nil)
    let login = NSButton(checkboxWithTitle: "로그인 시 시작", target: nil, action: nil)
    let showInMenuBar = NSButton(checkboxWithTitle: "메뉴바에 표시", target: nil, action: nil)
    let replaceInputMenu = NSButton(checkboxWithTitle: "Mac 입력기 아이콘 대체", target: nil, action: nil)
    let iconCaseSwitch = NSButton(checkboxWithTitle: "대소문자를 영문 아이콘에 반영", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    var timer: Timer?
    var menuInputTimer: Timer?
    var observers: [NSObjectProtocol] = []
    var keyTap: CFMachPort?
    var keyTapSource: CFRunLoopSource?
    var pressGate = PressGate()
    var spaceGate = SpaceComboGate()
    // The F-keys of the sources' keys.
    var sourceKeyGate = PressGate()
    var nativeRemote = NativeRemoteGate()
    var sourceHistory = SourceHistory()
    var landingGeneration = 0
    // The source a switch is on its way to, and one that waits for it to land.
    var switchLanding: String?
    var queuedSwitch: (target: InputSourceIdentity, pulse: (CGEvent, CGEvent))?
    // The next-source shortcut on its way, and where it went instead of the expected source, until the sources change.
    var nextSent: (from: String, target: String, key: String)?
    var missedNext: [String: String] = [:]
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
    var remoteKeyboards = RemoteKeyboards()
    // When the tap last saw the Korean/English key go down; a long press it never saw went to another Mac.
    var tapTargetDown: TimeInterval?
    lazy var remoteHold = RemoteHoldMonitor(target: { [unowned self] in self.engine.target.usage }, tapDown: { [unowned self] in self.tapTargetDown })
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
    let backquoteSwitch = NSButton(checkboxWithTitle: "한글 상태에서 ₩와 ` 반전", target: nil, action: nil)
    let universalControlSwitch = NSButton(checkboxWithTitle: "유니버설 컨트롤 호환 모드", target: nil, action: nil)
    var backquote = BackquoteSwap()
    let installCLI = NSButton(title: "CLI 설치", target: nil, action: nil)
    var commandPort: CFMessagePort?
    var commandSession: CommandSession?
    // Tests take a command's errors here instead of a window.
    var presentCommandErrors: (([String]) -> Void)?
    var returningFromPermissionSettings = false
    // The permission of the self-signed build was removed: ask for it again, on every launch until it is given, and then turn
    // back on the activation that turning off without it undid. Kept until then, as the app can quit first.
    var askForPermission = false
    var reactivateWhenTrusted: Bool {
        get { engine.defaults.bool(forKey: "permissions.reactivate") }
        set { engine.defaults.set(newValue, forKey: "permissions.reactivate") }
    }
    // A launch asking again finds the activation undone already, and keeps what the first one saved.
    func keepActivationUntilTrusted() { if engine.active { reactivateWhenTrusted = true } }
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
        keyTapSource = nil; keyTap = nil; pressGate.held.removeAll(); nativeRemote = NativeRemoteGate(); spaceGate = SpaceComboGate()
        sourceKeyGate.held.removeAll(); observedCaps = nil; backquote.reset()
    }
    func ensureKeyTap() {
        defer { updateRemoteHold() }
        guard AXIsProcessTrusted() else { stopKeyTap(); updatePressAccess(); return }
        // Paused, nothing is caught; resuming starts again from the keyboard as it is then.
        if let tap = keyTap, !CFMachPortIsValid(tap) || engine.paused { stopKeyTap() }
        syncCapsPreservation()
        // ESC shares the long-press transition, so it runs while either is on.
        if !engine.active || !engine.longPressCapsLock && !engine.escapeToEnglish { cancelLongPress() }
        guard engine.active, !engine.paused, keyTap == nil else { updatePressAccess(); return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue) | (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue) | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.cancelLongPress()
                    owner.optionInput.cancel()
                    // A lock change may have gone by meanwhile.
                    owner.observedCaps = nil
                    // Retain owned physical key-ups to avoid an extra native release.
                    if let tap = owner.keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                // Keys this app posts again, such as ones held while a switch landed, act only once.
                let ours = event.getIntegerValueField(.eventSourceUserData) == owner.nativePulseMarker
                if !ours && (type == .keyDown || type == .flagsChanged) {
                    owner.spaceGate.note(type: type, code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
                    // Modifier events carry the lock, also a change no key made. A Caps Lock press right after a lock set by
                    // software sends none, so keys catch it too, the switch key before its pulse. Only the HID system's own
                    // events (no posting process): keystrokes other apps post leave the lock out.
                    if event.getIntegerValueField(.eventSourceUnixProcessID) == 0 {
                        owner.observeCaps(event.flags.contains(.maskAlphaShift),
                            capsKey: type == .flagsChanged && event.getIntegerValueField(.keyboardEventKeycode) == 57)
                    }
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
                    // Caps Lock on the lock screen is for the password there. Back in English, followCapsLock takes the lock as left.
                    if owner.capsPreservationActive && event.getIntegerValueField(.keyboardEventKeycode) == 57 && !owner.engine.sessionAway() {
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
                if owner.holdKeys && code != Int64(owner.engine.target.keyCode) && owner.sourceKeyTarget(code) == nil
                    && !owner.pressGate.held.contains(code) && !owner.sourceKeyGate.held.contains(code) && owner.longPress.key != code {
                    owner.holdKey(event)
                    return nil
                }
                owner.swapBackquote(event)
                // A source's key's F-key only switches, on press like the Korean/English key.
                if owner.takesSourceKey(code) {
                    let decision = owner.sourceKeyGate.handle(code: code, down: type == .keyDown, repeatKey: repeated, active: true, target: code)
                    if decision.switchNow, let id = owner.sourceKeyTarget(code) { _ = owner.switchToKeySource(id, key: event) }
                    return decision.consume ? nil : Unmanaged.passUnretained(event)
                }
                if owner.passesNatively(event, code: code, down: type == .keyDown, repeated: repeated) { return Unmanaged.passUnretained(event) }
                if owner.engine.active && type == .keyDown && !repeated && code == Int64(owner.engine.target.keyCode) {
                    owner.tapTargetDown = ProcessInfo.processInfo.systemUptime
                    owner.rememberCapsBeforeSwitch(event)
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
    // With Universal Control in front, the keys go to another Mac. Only with a keyboard mapped here: others have nothing to
    // carry the lock there, and Input Monitoring would be asked for nothing.
    func updateRemoteHold() {
        remoteHold.update(enabled: engine.active && !engine.paused && engine.longPressCapsLock && engine.accessibilityTrusted()
            && engine.keyboards.result.applied > 0)
    }
    func updatePressAccess() {
        addedSources.refresh()
        let trusted = engine.accessibilityTrusted()
        // Switching needs the tap, so without Accessibility only the permission button and the gksdud tab can be used.
        for control: NSControl in [enabled, login, showInMenuBar, iconPicker, picker, advancedButton] + specialButtons { control.isEnabled = trusted }
        // Only this app's icon can replace the Mac input menu.
        replaceInputMenu.state = engine.replacesInputMenu ? .on : .off
        replaceInputMenu.isEnabled = trusted && showInMenuBar.state == .on
        iconCaseSwitch.state = engine.defaults.bool(forKey: "iconCase") ? .on : .off
        iconCaseSwitch.isEnabled = trusted && showInMenuBar.state == .on
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
        backquoteSwitch.state = trusted && engine.swapBackquote ? .on : .off
        backquoteSwitch.isEnabled = trusted
        backquoteSwitch.toolTip = trusted ? switchErrors[backquoteSwitch] : accessibilityHint
        universalControlSwitch.state = trusted && engine.universalControlCompat ? .on : .off
        universalControlSwitch.isEnabled = trusted
        universalControlSwitch.toolTip = trusted ? nil : accessibilityHint
        pressAccess.toolTip = trusted && engine.active && !ready ? "권한 반영을 기다리는 중입니다. 계속 전환되지 않으면 앱을 다시 실행하세요."
            : "키를 누르는 순간 전환하려면 접근성 권한이 필요합니다."
    }
    // Each checkbox saves its own preference; the tap starts or stops with them.
    @objc func toggleFeature(_ sender: NSButton) {
        let keys: [NSButton: String] = [longPressSwitch: "longPressCapsLock",
            preserveCapsSwitch: "preserveCapsLock", koreanCapsSwitch: "koreanCapsLock", escapeSwitch: "escapeToEnglish",
            backquoteSwitch: "swapBackquote", universalControlSwitch: "universalControlCompat"]
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
    // becomes a Korean/English key or a source's key.
    func turnOffUnusedKoreanCaps() {
        if !engine.preserveCapsLock { engine.defaults.set(false, forKey: "koreanCapsLock") }
    }
    var currentLanguage: String {
        TISCopyCurrentKeyboardInputSource().map { language($0.takeRetainedValue()) } ?? ""
    }
    var currentSource: InputSourceIdentity? { TISCopyCurrentKeyboardInputSource().flatMap { Self.sourceIdentity($0.takeRetainedValue()) } }
    // The session's lock. It follows posted events and lags a change until its event passes, and a Caps Lock press right
    // after a lock set by software sends none.
    var actualCaps: Bool { CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) }
    // The lock as the tap last saw it on a key, nil while no tap watches it.
    var observedCaps: Bool?
    var currentCaps: Bool { observedCaps ?? actualCaps }
    var capsPreservationActive: Bool { engine.active && !engine.paused && engine.preserveCapsLock && AXIsProcessTrusted() }
    var koreanCapsActive: Bool { capsPreservationActive && engine.koreanCapsLock }
    // With Caps Lock in Korean, the lock shows the English case in Korean too.
    func showsEnglishCase(_ source: InputSourceIdentity?) -> Bool { source?.id == capsSafeKorean && engine.koreanCapsLock }
    // Once Caps Lock in Korean stops, the lock it kept on in Korean goes off, as the Korean input method turns it off
    // on the way in. Only a running tap kept it on.
    func releaseKoreanCaps() {
        guard keyTap != nil, !koreanCapsActive, currentSource?.id == capsSafeKorean, currentCaps else { return }
        try? setCapsLock(false)
    }
    // The English case preservation restores, even before it has.
    var rememberedUpper: Bool { capsPreservationActive && englishCaps.target(english: true) == true }
    func syncCapsPreservation() {
        if capsPreservationActive { englishCaps.enable(actual: currentCaps) }
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
        let own = sourceCombos
        let decision = spaceGate.handle(down: event.type == .keyDown,
            repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, flags: event.flags, chosen: engine.chosenCombos + own.keys)
        if decision.switchNow, let id = spaceCombo(flags: event.flags).flatMap({ own[$0] }) {
            guard switchToKeySource(id, key: event) else { spaceGate.held = false; return false }
        } else if decision.switchNow {
            // Without a pulse, give the Space back instead of swallowing it.
            guard let pulse = nativeSwitchPulse(keyCode: engine.target.keyCode, marker: nativePulseMarker) else { spaceGate.held = false; return false }
            rememberCapsBeforeSwitch(event)
            switchHangul(pulse)
        }
        return decision.consume
    }
    // `key` is the key that switches, when there is one.
    func rememberCapsBeforeSwitch(_ key: CGEvent? = nil) {
        guard capsPreservationActive else { return }
        if let key, remoteKeyboards.sentFromOtherMac(key) { englishCaps.followSender(key.flags.contains(.maskAlphaShift)) }
        englishCaps.willSwitch(english: currentLanguage.hasPrefix("en"), actual: currentCaps,
            longPress: engine.longPressCapsLock)
        // Also settle if macOS does not change sources (for example, only one is enabled).
        scheduleCapsRestore()
    }
    func restoreEnglishCaps() {
        // The lock screen selects U.S. for itself; restoring there would start the password in the remembered case.
        guard !optionInput.busy, capsPreservationActive, pendingCapsState == nil, !engine.sessionAway() else { return }
        // With Caps Lock in Korean, Korean shows the English case as well; its input method turns Caps Lock off on the way in,
        // and other sources have it turned off here.
        let source = currentSource
        guard let desired = englishCaps.target(english: source?.language.hasPrefix("en") == true || showsEnglishCase(source)),
              currentCaps != desired else { return }
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
        longPressInitialCaps = englishCaps.beforeLongPress(actual: currentCaps, preserving: capsPreservationActive)
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
        // Notices from here on are this switch's, not those of a next-source shortcut sent before.
        nextSent = nil
        // With the lock as it is now, not as when its key went down: the session takes the lock from posted events, and a
        // pulse read as off made restoring the case set the lock again mid-switch, which switched back.
        let caps = currentCaps
        for event in [pulse.0, pulse.1] { event.flags = capsFlags(event.flags, caps: caps) }
        pulse.0.post(tap: .cghidEventTap); pulse.1.post(tap: .cghidEventTap)
    }
    // Only ESC asks, so the input source is read only while it is on.
    func noteSwitchSent() {
        guard engine.escapeToEnglish else { return }
        sentSwitch = SentSwitch(from: currentLanguage, at: ProcessInfo.processInfo.systemUptime)
    }
    func switchInFlight(from language: String) -> Bool { sentSwitch?.inFlight(now: ProcessInfo.processInfo.systemUptime, language: language) == true }
    func permissionAgainAlert() -> NSAlert {
        let name = UpdateChannel.current.appName, alert = NSAlert()
        alert.messageText = "손쉬운 사용 권한을 다시 허용해주세요"
        alert.informativeText = "\(name)가 Apple 서명 버전으로 바뀌어, 이전에 허용한 권한을 macOS가 더 이상 인정하지 않습니다. 다음 창에서 시스템 설정을 열고 \(name)를 켜주세요. 켜면 한영 전환도 다시 켜집니다."
        alert.addButton(withTitle: "계속")
        return alert
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
        let appEntry = NSMenuItem(); let appMenu = NSMenu(title: UpdateChannel.current.appName)
        appMenu.addItem(withTitle: "\(UpdateChannel.current.appName) 종료", action: #selector(quit), keyEquivalent: "q").target = self
        appEntry.submenu = appMenu; mainMenu.addItem(appEntry)
        let editEntry = NSMenuItem(); let editMenu = NSMenu(title: "편집")
        for (title, action, key) in [("잘라내기", "cut:", "x"), ("복사", "copy:", "c"), ("붙여넣기", "paste:", "v"), ("모두 선택", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editEntry.submenu = editMenu; mainMenu.addItem(editEntry)
        NSApp.mainMenu = mainMenu
        if askForPermission { keepActivationUntilTrusted() }
        engine.migrateAddedSources(enabled: enabledSources())
        engine.availableSources = { [weak self] in self.map { Set($0.enabledSources().map(\.id)) } }
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
        engine.sessionAway = screenLockedOrAway
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLockChanged), name: Notification.Name(name), object: nil)
        }
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
            self?.updateRemoteHold()
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
        // Once launching has applied the settings, so a command right after `gksdud start` finds it ready.
        startCommandServer()
        // Restarted by an update, the window comes back on the tab it was installed from. Asking for the permission again opens it
        // on the way back from System Settings instead, as a window shown first would cover the system's request.
        if !askForPermission {
            if ProcessInfo.processInfo.environment["GKSDUD_UPDATE_READY"] != nil { showAbout() }
            else if showInMenuBar.state == .off || CommandLine.arguments.contains("--settings") { showSettings() }
        }
        // Why it asks again, then the system's request, which offers its settings; coming back from there opens this app's.
        if askForPermission {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true); _ = self.runAlert(self.permissionAgainAlert())
                self.requestPressAccess()
            }
        }
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
        guard confirmCapsLockKey(engine.capsLockSwitches()), confirmSourceKeys(),
              !engine.active || confirmMapping(engine.defaultSources, target: engine.target, only: keyboards) else { return false }
        releaseKoreanCapsLock(); releaseSourceKeys()
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
        let brandEntry = NSMenuItem(title: UpdateChannel.current.appName, action: #selector(menuBrand), keyEquivalent: "")
        brandEntry.attributedTitle = NSAttributedString(string: UpdateChannel.current.appName, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .heavy), .kern: 0.6])
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
    // The Korean or English icon of the chosen style. `upper` is the English case, nil without the case option.
    func sourceMenuIcon(korean: Bool, upper: Bool? = nil) -> NSImage {
        let style = iconStyle, upper = korean ? nil : upper
        guard style == 3 else { return badgeImage(label: iconLabel(style: style, korean: korean, upper: upper), filled: korean) }
        let key = "face|\(korean)|\(upper == true)"
        if let image = iconCache[key] { return image }
        let image = DudIcon.badge(korean: korean, upper: upper == true)
        iconCache[key] = image
        return image
    }
    @objc func changeIconStyle() {
        engine.defaults.set(iconPicker.indexOfSelectedItem, forKey: "iconStyle")
        updateInputIndicator()
    }
    @objc func toggleIconCase() {
        engine.defaults.set(iconCaseSwitch.state == .on, forKey: "iconCase")
        updateInputIndicator()
    }
    // Icons are kept, so the refresh every second finds the one showing and sets nothing.
    private var iconCache: [String: NSImage] = [:]
    // Input sources' own icons by ID, nil for one without; read again when macOS's sources change.
    var nativeIconCache: [String: NSImage?] = [:]
    func badgeImage(label: String, filled: Bool) -> NSImage {
        let key = "\(filled)|\(label)"
        if let image = iconCache[key] { return image }
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
        iconCache[key] = image
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
            self.nextLanded(id)
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
    // A source's key maps or goes back to the keyboard as its source comes and goes.
    @objc func enabledSourcesChanged() {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            self?.sourceCache = nil; self?.nativeIconCache = [:]; self?.missedNext = [:]; self?.engine.nextFailedKey = nil; self?.repair(); self?.addedSources.refresh(force: true)
        }
    }
    func updateInputIndicator() {
        // The Option-character round trip selects English for a moment; didFinish refreshes afterwards. Meanwhile the source
        // last read shows, in the style chosen now.
        guard !optionInput.busy, switchLanding == nil, let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            showIndicator(); return
        }
        let source = Self.sourceIdentity(current) ?? InputSourceIdentity(id: "", language: language(current))
        let badge = isKorean(source) || isEnglish(source) ? "" : sourceBadgeLabel(source.language, position: sourcePosition(source.id))
        indicator = (source, badge)
        showIndicator()
    }
    // The current source as last read, and its badge text when it is neither Korean nor English.
    var indicator: (source: InputSourceIdentity, badge: String)?
    // Shows `indicator` without asking macOS again, as a Caps Lock change does.
    func showIndicator() {
        let upper = englishCase()
        refreshSourceIcons(current: indicator?.source, englishUpper: upper)
        guard let (source, other) = indicator else { return }
        let korean = isKorean(source), english = isEnglish(source)
        // Let the status bar resolve contrast, including its initial appearance and highlighting.
        let badge = korean || english ? sourceMenuIcon(korean: korean, upper: upper) : cachedNativeIcon(source.id) ?? badgeImage(label: other, filled: false)
        let name = korean ? "한국어" : english ? "영어" : other
        if inputBadge.image !== badge { inputBadge.image = badge; inputBadge.setAccessibilityLabel("현재 입력: \(name)") }
        if tabButtons.first?.image !== badge { tabButtons.first?.image = badge }
        guard let button = item?.button else { return }
        if button.image !== badge { button.title = ""; button.image = badge; button.imagePosition = .imageOnly }
        let warning = engine.keyboards.warning.map { "\n\($0)" } ?? ""
        let tip = "\(UpdateChannel.current.appName) · 현재 입력 소스: \(source.language)\(warning)"
        let spoken = "\(UpdateChannel.current.appName), 현재 입력 \(name)\(warning)"
        if button.toolTip != tip { button.toolTip = tip }
        if button.accessibilityLabel() != spoken { button.setAccessibilityLabel(spoken) }
    }
    // The Korean and English icons elsewhere: the menu, which also checks the current source, the previews and the added
    // sources.
    func refreshSourceIcons(current: InputSourceIdentity?, englishUpper: Bool?) {
        let korean = sourceMenuIcon(korean: true), english = sourceMenuIcon(korean: false, upper: englishUpper)
        if koreanPreview.image !== korean { koreanPreview.image = korean }
        if englishPreview.image !== english { englishPreview.image = english }
        for entry in item?.menu?.items ?? [] {
            switch entry.action {
            case #selector(selectKorean):
                if entry.image !== korean { entry.image = korean }
                if let current { entry.state = isKorean(current) ? .on : .off }
            case #selector(selectEnglish):
                if entry.image !== english { entry.image = english }
                if let current { entry.state = isEnglish(current) ? .on : .off }
            case #selector(selectAddedSource(_:)):
                if let current { entry.state = entry.representedObject as? String == current.id ? .on : .off }
            default: break
            }
        }
        addedSources.showEnglishIcon(english)
    }
    // The case English icons show, nil with the option off.
    func englishCase() -> Bool? {
        guard showsIconCase else { return nil }
        let inEnglish = indicator.map { isEnglish($0.source) } ?? true
        return englishIconCase(inEnglish: inEnglish, lock: currentCaps,
            restores: self.capsPreservationActive ? self.englishCaps.target(english: true) : nil)
    }
    func observeCaps(_ caps: Bool, capsKey: Bool = false) {
        guard caps != observedCaps else { return }
        let seen = observedCaps != nil
        observedCaps = caps
        // The Caps Lock key's own event has its path in the tap. After a reset a change is not known to be new.
        if seen && !capsKey && capsPreservationActive && !engine.sessionAway() {
            englishCaps.lockSeen(english: currentLanguage.hasPrefix("en"), actual: caps)
        }
        // After the event goes on; the option is read only on a change.
        if showsIconCase { DispatchQueue.main.async { [weak self] in self?.showIndicator() } }
    }
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
            case #selector(menuEnabled): entry.state = engine.active && !engine.paused ? .on : .off; entry.isEnabled = engine.accessibilityTrusted()
            case #selector(menuLogin): entry.state = login.state; entry.isEnabled = engine.accessibilityTrusted()
            case #selector(menuHidden): entry.state = showInMenuBar.state; entry.isEnabled = engine.accessibilityTrusted()
            case #selector(selectKorean): entry.isEnabled = menuLanguageSource("ko") != nil
            case #selector(selectEnglish): entry.isEnabled = menuLanguageSource("en") != nil
            default: break
            }
        }
        menu.autoenablesItems = false
    }
    func menuDidClose(_ menu: NSMenu) {
        menuInputTimer?.invalidate()
        menuInputTimer = nil
    }
    func selectLanguage(_ prefix: String) {
        if let source = menuLanguageSource(prefix).flatMap({ Self.sourceForID($0.id) }) { rememberCapsBeforeSwitch(); _ = TISSelectInputSource(source) }
        updateInputIndicator()
    }
    @objc func selectKorean() { selectLanguage("ko") }
    @objc func selectEnglish() { selectLanguage("en") }
    @objc func menuEnabled() {
        // A pause from the command line shows here as off, and turns back on from here.
        if engine.active && engine.paused { setPaused(false); return }
        enabled.state = engine.active ? .off : .on; toggleEnabled()
    }
    @objc func menuLogin() { login.state = SMAppService.mainApp.status == .enabled ? .off : .on; toggleLogin() }
    @objc func menuHidden() { showInMenuBar.state = showInMenuBar.state == .on ? .off : .on; toggleHidden() }
    @objc func showSettings() { if !window.isVisible { selectTab(0) }; refreshCLIButton(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if showInMenuBar.state == .off { showSettings() }; return true }
    @objc func toggleHidden() {
        engine.defaults.set(showInMenuBar.state == .off, forKey: "hidden")
        updateMenu(); updatePressAccess(); updateInputIndicator()
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
        if enabled.state == .on { engine.paused = false; applyNow() }
        else { restoreNow() }
    }
    @objc func selectionChanged() {
        guard !engine.isUpdatingSettings else { resetSelection(); return }
        cancelLongPress()
        guard confirmCapsLockKey(engine.capsLockSwitches(picker.selection)), confirmSourceKeys(picker.selection) else { resetSelection(); return }
        if enabled.state == .on { applyNow() }
        else {
            if let keys = picker.selection { engine.defaultSources = keys }
            engine.defaults.set(switchTargets[targetPicker.indexOfSelectedItem].name, forKey: "target")
        }
        releaseKoreanCapsLock(); releaseSourceKeys()
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
        let target = switchTargets[targetPicker.indexOfSelectedItem]
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
    func recover() { sourceCache = nil; engine.nextFailedKey = nil; engine.followedNext = nil; observedCaps = nil; queuedSwitch = nil; releaseHeldKeys(); optionInput.cancel(); if capsRestoreTasks.isEmpty { englishCaps.switching = false }; cancelLongPress(); longPress = LongPressState(); pressGate.held.removeAll(); nativeRemote = NativeRemoteGate(); spaceGate = SpaceComboGate(); sourceKeyGate.held.removeAll(); for delay in [0.5, 2.0, 5.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.repair() } } }
    // The tap does not see Caps Lock on another user's login window, and leaves it alone on the lock screen. Coming back
    // with English (or Korean showing the English case) selected, the lock as left there is the English case. A restore on
    // its way finishes first: unlocking can land in Korean while its input method turns the lock off.
    func followCapsLock() {
        guard capsPreservationActive, !englishCaps.switching, !engine.sessionAway() else { return }
        let source = currentSource
        englishCaps.capsKeyChanged(english: source?.language.hasPrefix("en") == true, actual: currentCaps, korean: showsEnglishCase(source))
    }
    // The 1-second repair follows the lock too; this only makes it sooner.
    @objc func screenLockChanged(_ notification: Notification) {
        // Key releases on the lock screen never reached the tap, so keys held before it count as released.
        if notification.name.rawValue == "com.apple.screenIsUnlocked" { recover() }
        repair()
    }
    func repair() {
        guard !engine.isUpdatingSettings else { return }
        // Without Accessibility there is no tap to switch with, so activation turns off and stays off until turned on again.
        if engine.active && !engine.accessibilityTrusted() { restoreNow(); return }
        if reactivateWhenTrusted && engine.accessibilityTrusted() { reactivateWhenTrusted = false; enabled.state = .on; toggleEnabled() }
        ensureKeyTap()
        do { try engine.repair(); if repairFailed { repairFailed = false; stickyError = "" } } catch { report(error); repairFailed = !(error is KeyboardError) }
        // This follows the session itself, as the unlock notice can come late. Not at once: right after unlocking, the lock
        // screen's U.S. can still be selected.
        let away = engine.sessionAway()
        if sessionWasAway && !away { observedCaps = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.followCapsLock() } }
        sessionWasAway = away
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
            : window.isVisible && login.state == .on && SMAppService.mainApp.status == .requiresApproval ? "시스템 설정 → 로그인 항목에서 \(UpdateChannel.current.appName)를 허용하세요." : ""
    }
    var lastError = ""
    var stickyError = ""
    var repairFailed = false
    var sessionWasAway = false
    func report(_ error: Error) {
        if error is KeyboardError { refreshKeyboardState(); return }
        stickyError = error.localizedDescription; refreshStatus()
        enabled.toolTip = error.localizedDescription
        // A command gets the error back, and shows it once it is done unless asked not to.
        if let commandSession { commandSession.errors.append(error.localizedDescription); return }
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
    // Before anything asks about Accessibility: a process keeps the answer it got first.
    let askForPermission = UpdateValidation.forgetSelfSignedPermissions(defaults: .standard)
    let app = NSApplication.shared
    let delegate = AppDelegate()
    delegate.askForPermission = askForPermission
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
