import AppKit
import Carbon

#if TESTS
// Test modes are compiled only into test builds (-D TESTS); the release app has none. True when a mode ran.
func runTestMode() -> Bool {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--render-keyboard-ui"), arguments.count > index + 1 {
        do { try renderKeyboardUI(to: arguments[index + 1]) } catch { fputs("UI rendering failed: \(error)\n", stderr); exit(1) }
    } else if arguments.contains("--probe-option-input") {
        do { try probeOptionInput() } catch { fputs("Input probe failed: \(error)\n", stderr); exit(1) }
    } else if arguments.contains("--probe-escape") {
        do { try probeEscape() } catch { fputs("ESC probe failed: \(error.localizedDescription)\n", stderr); exit(1) }
    } else if arguments.contains("--probe-input-sources") {
        do { try probeInputSources() } catch { fputs("Input source probe failed: \(error.localizedDescription)\n", stderr); exit(1) }
    } else if arguments.contains("--self-test") {
        runSelfTest()
    } else if arguments.contains("--integration-test") {
        runIntegrationTest()
    } else {
        return false
    }
    return true
}

func runSelfTest() {
    setbuf(stdout, nil)
    do { try runSettingsReentrancyTests() } catch { fputs("Settings reentrancy tests failed: \(error)\n", stderr); exit(1) }
    do { try runShortcutRestoreTests() } catch { fputs("Shortcut tests failed: \(error)\n", stderr); exit(1) }
    do { try runExitTests() } catch { fputs("Exit tests failed: \(error)\n", stderr); exit(1) }
    runFeatureTests()
    runKeyboardTests()
    runRightControlTests()
    runSessionAwayTests()
    runCapsLockKeyTests()
    runAddedSourceTests()
    runSeparateKeyTests()
    runSeparateKeyTapTests()
    runSeparateKeyWarningTests()
    runPermissionTests()
    runCommandTests()
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
    var hold = LongPressState()
    hold.begin(key: 80, now: 10)
    precondition(!hold.claimLong(now: 10.499))
    let short = hold.release(key: 80, now: 10.499)
    precondition(short.owned && !short.long)
    hold.begin(key: 80, now: 20)
    precondition(hold.claimLong(now: 20.5))
    precondition(!hold.claimLong(now: 23), "Only one long action per hold")
    let released = hold.release(key: 80, now: 24)
    precondition(released.owned && !released.long)
    hold.begin(key: 80, now: 30)
    precondition(!hold.release(key: 0, now: 30.2).owned, "Other key must not end hold")
    let late = hold.release(key: 80, now: 30.5)
    precondition(late.long, "Release handles delayed timer exactly once")
    hold.begin(key: 80, now: 40)
    hold.cancel()
    precondition(!hold.claimLong(now: 41))
    let cancelled = hold.release(key: 80, now: 41)
    precondition(cancelled.owned && !cancelled.long)
    print("PASS: 0.5-second hold threshold, one-shot hold, delayed timer, unrelated keys, cancellation")
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
    let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICERALTKEYMASK))
    let shiftFlags: [CGEventFlags] = [.maskShift, [.maskShift, .maskAlphaShift],
        CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | UInt64(NX_DEVICELSHIFTKEYMASK)),
        CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | UInt64(NX_DEVICERSHIFTKEYMASK))]
    precondition(spaceCombo(flags: .maskControl) == spaceCombos[0] && spaceCombo(flags: [.maskCommand, .maskAlphaShift]) == spaceCombos[1]
        && spaceCombo(flags: rightOption) == spaceCombos[2] && shiftFlags.allSatisfy { spaceCombo(flags: $0) == spaceCombos[3] },
        "Each combination is Space with one modifier on either side, whatever Caps Lock is")
    precondition([[], [.maskControl, .maskAlternate], [.maskCommand, .maskAlternate], [.maskCommand, .maskShift], [.maskControl, .maskShift], [.maskAlternate, .maskShift]]
        .allSatisfy { spaceCombo(flags: $0) == nil }, "Other modifier sets keep their meaning")
    var space = SpaceComboGate()
    func spaceKey(_ down: Bool, _ flags: CGEventFlags, repeatKey: Bool = false, chosen: [UInt64] = [spaceCombos[0], spaceCombos[2]]) -> (consume: Bool, switchNow: Bool) {
        space.handle(down: down, repeatKey: repeatKey, flags: flags, chosen: chosen)
    }
    let comboPress = spaceKey(true, .maskControl), comboRepeat = spaceKey(true, .maskControl, repeatKey: true)
    precondition(comboPress.consume && comboPress.switchNow && comboRepeat.consume && !comboRepeat.switchNow, "One switch per press")
    precondition(spaceKey(false, []).consume, "The release stays claimed after the modifier is let go")
    precondition(!spaceKey(true, []).consume && !spaceKey(true, [], repeatKey: true).consume && !spaceKey(false, []).consume, "Plain Space passes")
    precondition(!spaceKey(true, .maskCommand).consume && !spaceKey(false, .maskCommand).consume, "An unchosen combination keeps its system shortcut")
    precondition(!spaceKey(true, .maskControl, chosen: []).consume && !spaceKey(false, .maskControl, chosen: []).consume, "Inactive passes")
    precondition(spaceKey(true, .maskAlternate).switchNow && !spaceKey(true, [], chosen: []).consume && !spaceKey(false, []).consume,
        "A press after a release missed by a disabled tap starts fresh")
    for flags in shiftFlags {
        precondition(!spaceKey(true, flags).consume && !spaceKey(false, flags).consume, "Unchosen Shift+Space passes")
        let press = spaceKey(true, flags, chosen: [spaceCombos[3]])
        let repeated = spaceKey(true, [], repeatKey: true, chosen: [spaceCombos[3]])
        precondition(press.consume && press.switchNow && repeated.consume && !repeated.switchNow, "Shift+Space switches once even if Shift is released during repeat")
        let release = spaceKey(false, [], chosen: [])
        precondition(release.consume && !release.switchNow, "The Shift+Space release stays claimed after disabling")
        precondition(!spaceKey(true, flags, chosen: []).consume && !spaceKey(false, flags, chosen: []).consume, "Inactive Shift+Space passes")
    }
    let shiftOnly = [spaceCombos[3]]
    func shiftSpace() -> Bool {
        let press = spaceKey(true, .maskShift, chosen: shiftOnly), release = spaceKey(false, .maskShift, chosen: shiftOnly)
        precondition(press.consume == press.switchNow && release.consume == press.consume, "A Space is claimed with its release or not at all")
        return press.switchNow
    }
    space.note(type: .flagsChanged, code: Int64(kVK_Shift), flags: .maskShift)
    precondition(shiftSpace() && shiftSpace(), "Space first under Shift switches, again for each Space")
    space.note(type: .keyDown, code: Int64(kVK_ANSI_A), flags: .maskShift)
    precondition(!shiftSpace() && !shiftSpace(), "A Space after capitals typed under the same Shift is typed")
    space.note(type: .flagsChanged, code: Int64(kVK_Shift), flags: [])
    space.note(type: .flagsChanged, code: Int64(kVK_Shift), flags: .maskShift)
    precondition(shiftSpace(), "A new Shift switches again")
    space.note(type: .keyDown, code: Int64(kVK_ANSI_A), flags: .maskShift)
    precondition(spaceKey(true, .maskControl).switchNow && spaceKey(false, .maskControl).consume, "Other combinations ignore what Shift typed")
    let comboSuiteName = "io.gksdud.space-combo-test.\(UUID().uuidString)"
    let comboSuite = UserDefaults(suiteName: comboSuiteName)!
    let comboEngine = Engine(defaults: comboSuite)
    comboEngine.defaultSources = [spaceCombos[1], 1, sources[2]]
    precondition(comboEngine.defaultSources == [sources[2], spaceCombos[1]] && comboEngine.mappedSources == [sources[2]]
        && comboEngine.chosenCombos == [spaceCombos[1]], "Global keys hold both kinds; only single keys are mapped")
    comboEngine.defaultSources = [spaceCombos[3], sources[2], spaceCombos[1]]
    let comboReloaded = Engine(defaults: UserDefaults(suiteName: comboSuiteName)!)
    precondition(comboReloaded.defaultSources == [sources[2], spaceCombos[1], spaceCombos[3]] && comboReloaded.mappedSources == [sources[2]]
        && comboReloaded.chosenCombos == [spaceCombos[1], spaceCombos[3]], "Shift+Space survives restart with existing keys and never reaches HID")
    comboSuite.set(false, forKey: "active")
    precondition(comboEngine.chosenCombos.isEmpty, "Combinations stop with activation")
    comboSuite.removePersistentDomain(forName: comboSuiteName)
    print("PASS: Space combinations with one exact modifier, claimed repeats and release, unchosen and inactive pass-through, missed release, Space after capitals under Shift")
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
    suite.set(false, forKey: "active")
    precondition(!preferences.active, "Explicitly disabled preference is preserved")
    suite.set(true, forKey: "active")
    precondition(preferences.active)
    suite.removePersistentDomain(forName: suiteName)
    let option = sources[1], command = sources[0]
    let existing: [Mapping] = [[srcKey: NSNumber(value: option), dstKey: NSNumber(value: UInt64(0x70000006d))]]
    let first = merged(existing, source: command, previous: nil, original: nil)
    let owned = ["source": String(command), "target": String(f19)]
    precondition(!targetConflict(first, sources: [sources[2]], target: f19, owned: owned), "Own old mapping must not block source changes")
    precondition(targetConflict(first, sources: [sources[2]], target: f19, owned: nil), "Unowned target remains a conflict")
    precondition(targetConflict(existing, sources: [command], target: 0x70000006d, owned: owned), "Unrelated target collision remains blocked")
    precondition(!targetConflict(first, sources: [sources[2]], target: f19, owned: ["source": encodeSources([sources[2], command]), "target": String(f19)]),
        "Every key in a multi-key record is ours")
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
}

func runIntegrationTest() {
    let suiteName = "io.gksdud.inputswitch.test.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    let engine = Engine(defaults: suite)
    defer { try? engine.restore(); suite.removePersistentDomain(forName: suiteName) }
    do {
        let menuDomain = "com.apple.TextInputMenu" as CFString
        func nativeMenuVisible() -> Bool? {
            CFPreferencesAppSynchronize(menuDomain)
            return (CFPreferencesCopyAppValue("visible" as CFString, menuDomain) as? NSNumber)?.boolValue
        }
        let userMenu = nativeMenuVisible()
        let count = try engine.apply(sources: [sources[0]], target: targets[6])
        guard count > 0 else { throw NSError(domain: "asd", code: 7, userInfo: [NSLocalizedDescriptionKey: "No real keyboard services visible"]) }
        precondition(nativeMenuVisible() == false)
        suite.set(true, forKey: "hidden")
        try engine.updateSystemInputMenu()
        precondition(nativeMenuVisible() == userMenu, "Hidden gksdud must leave the native input menu as the user had it")
        suite.set(false, forKey: "hidden")
        try engine.updateSystemInputMenu()
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
        _ = try engine.apply(sources: [sources[0]], target: targets[7])
        for service in engine.services() {
            precondition(engine.mappings(service).contains { $0[srcKey]?.uint64Value == sources[0] && $0[dstKey]?.uint64Value == targets[7].usage })
        }
        try engine.restoreSystem()
        precondition(engine.active, "Normal quit must remember activation")
        let restarted = Engine(defaults: suite)
        precondition(restarted.active && restarted.target.name == "F20")
        _ = try restarted.apply(sources: restarted.defaultSources, target: restarted.target)
        try restarted.restore()
        try restarted.restoreSystem()
        precondition(!restarted.active, "Explicitly disabled must stay disabled")
        print("PASS: \(count) real keyboards; recovery, target switch, quit cleanup, active/inactive launch preference, restoration")
    } catch { fputs("Integration test failed: \(error)\n", stderr); exit(1) }
}
#endif
