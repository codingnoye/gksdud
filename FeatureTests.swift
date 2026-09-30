import AppKit
import Carbon

#if TESTS
// Preserve an actionable failure location in optimized CI builds, where Swift's
// precondition trap otherwise loses its message and buffered stdout.
func featureCheck(_ condition: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard condition() else {
        fputs("FAIL: \(file):\(line) \(message)\n", stderr)
        exit(1)
    }
}

func runFeatureTests() {
    featureCheck(ReleaseVersion("v1.10.0")! > ReleaseVersion("1.9.9")!)
    featureCheck(ReleaseVersion("1.2")! == ReleaseVersion("1.2.0")!)
    for invalid in ["pre-v1.3.0", "1.3.0-beta", "1..2", "1.2x", "", "1.2.99999999999999999999999"] { featureCheck(ReleaseVersion(invalid) == nil) }
    func release(_ body: String?, tag: String = "v1.3.0", url: String = "https://github.com/codingnoye/gksdud/releases/tag/v1.3.0", draft: Bool = false, pre: Bool = false) -> AppRelease {
        AppRelease(tag_name: tag, html_url: url, body: body, draft: draft, prerelease: pre)
    }
    let sample = release("### 요약\r\n\r\n- 탭 추가\r\n- 특수문자 개선\r\n\r\n### 설치\r\n이 내용은 표시하지 않습니다.")
    featureCheck(sample.summary.contains("탭 추가") && !sample.summary.contains("설치"))
    featureCheck(release("## 요약\n<!-- 게시 전 요약 작성 -->\n## 설치").summary == release(nil).summary)
    featureCheck(release("## 요약\n본문\n### 세부\n세부 내용\n## 설치\n비표시").summary == "본문\n### 세부\n세부 내용")
    featureCheck(release("**요약**\n본문\n## 설치\n비표시").summary == "본문")
    featureCheck(release("## 설치\n설치 안내").summary == release(nil).summary)
    featureCheck(release("```\n## 요약\n잘못된 요약\n```\n## 요약\n정상\n## 설치").summary == "정상")
    featureCheck(sample.isNewer(than: "1.2.0") && !sample.isNewer(than: "1.3.0") && !sample.isNewer(than: "2.0.0"))
    featureCheck(!release(nil, draft: true).isNewer(than: "1.2.0"))
    featureCheck(!release(nil, pre: true).isNewer(than: "1.2.0"))
    featureCheck(!release(nil, url: "https://github.com.evil.test/codingnoye/gksdud/releases/tag/v3.0").isNewer(than: "1.2.0"))
    let suite = "io.gksdud.feature-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var now = Date(timeIntervalSince1970: 100_000), requests = 0
    var completion: ((Data?, URLResponse?, Error?) -> Void)?
    let checker = UpdateChecker(defaults: defaults, installedVersion: "1.2.0", now: { now }, fetch: { request, done in
        requests += 1; completion = done
        featureCheck(request.url?.host == "api.github.com" && request.timeoutInterval == 20)
    })
    func respond(_ status: Int, _ data: Data?) {
        completion?(data, HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    checker.check(); checker.check(force: true); featureCheck(requests == 1, "Coalesce concurrent requests")
    respond(200, try! JSONEncoder().encode(sample)); featureCheck(checker.available != nil && !checker.checking)
    checker.check(); featureCheck(requests == 1)
    now += 86401; checker.check(); featureCheck(requests == 2)
    respond(503, nil); featureCheck(checker.available != nil && checker.error != nil, "Offline checks preserve cached notification")
    let relaunched = UpdateChecker(defaults: defaults, installedVersion: "1.2.0")
    featureCheck(relaunched.available != nil)
    let upgraded = UpdateChecker(defaults: defaults, installedVersion: "1.3.0")
    featureCheck(upgraded.available == nil)
    checker.check(force: true); respond(200, Data("{}".utf8)); featureCheck(checker.error != nil && checker.available != nil)
    checker.check(force: true); respond(200, try! JSONEncoder().encode(release(nil, tag: "v1.2.0")))
    featureCheck(checker.available == nil && checker.error == nil)
    print("PASS: numeric versions, release summary boundaries, trusted release URLs, daily schedule, retry/cache/offline/upgrade behavior")
    do { try runUpdateInstallTests() } catch { preconditionFailure("Installer tests: \(error)") }
    runPrereleaseTests()
    runOptionInputTests()
    runOptionRepeatTests()
    runNativeOptionSymbolTests()
    runEnglishSwitchTests()
}

func runEnglishSwitchTests() {
    func escape(_ type: CGEventType, _ language: String, _ flags: CGEventFlags = [], repeated: Bool = false, code: Int = kVK_Escape,
                upper: Bool = false, switchingFrom: String? = nil) -> Bool {
        plainEscape(type: type, code: Int64(code), flags: flags, repeated: repeated)
            && escapeNeedsEnglish(language: language, upper: flags.contains(.maskAlphaShift) || upper, switching: language == switchingFrom)
    }
    featureCheck(escape(.keyDown, "ko"), "ESC in Korean ends in English lowercase")
    featureCheck(escape(.keyDown, "en", .maskAlphaShift), "ESC in English uppercase turns Caps Lock off")
    featureCheck(!escape(.keyDown, "en"), "ESC in English lowercase changes nothing")
    featureCheck(escape(.keyDown, "en", upper: true), "ESC before the remembered uppercase is restored still ends lowercase")
    featureCheck(escape(.keyDown, "en", switchingFrom: "en") && !escape(.keyDown, "en", switchingFrom: "ko"),
        "ESC right after a switch away from English comes back")
    featureCheck(!escape(.keyDown, "ja") && !escape(.keyDown, "ja", .maskAlphaShift) && !escape(.keyDown, "")
        && !escape(.keyDown, "ja", upper: true, switchingFrom: "ja"), "Other input sources stay; the switch key would only return to the previous one")
    featureCheck(!escape(.keyDown, "ko", repeated: true), "Held ESC switches once")
    let sent = SentSwitch(from: "ko", at: 10)
    featureCheck(sent.inFlight(now: 10.1, language: "ko"), "A Korean/English key just before ESC is still on its way")
    featureCheck(!sent.inFlight(now: 10.1, language: "en"), "Once the source changed, ESC needs no pulse of its own")
    featureCheck(!sent.inFlight(now: 10.5, language: "ko"), "A pulse macOS ignored does not block later switches")
    featureCheck(englishRoute(from: "en", switching: false) == .now && englishRoute(from: "ko", switching: false) == .sendSwitch,
        "English completes at once; Korean sends a switch")
    featureCheck(englishRoute(from: "ko", switching: true) == .awaitSwitch, "A switch on its way from Korean reaches English by itself")
    featureCheck(englishRoute(from: "en", switching: true) == .sendSwitch, "A switch on its way from English needs another to come back")
    featureCheck(!escape(.keyUp, "ko"))
    featureCheck(!escape(.flagsChanged, "ko", .maskAlphaShift, code: kVK_CapsLock) && !escape(.keyDown, "ko", code: kVK_ANSI_A))
    for modifier: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
        featureCheck(!escape(.keyDown, "ko", modifier), "Modified ESC stays a shortcut")
    }
    for initial in [false, true] {
        for korean in [false, true] {
            var caps = EnglishCapsState()
            caps.enable(actual: initial)
            caps.willSwitch(english: true, actual: initial, longPress: false); caps.switching = false
            caps.capsKeyChanged(english: false, actual: !initial, korean: korean)
            caps.willSwitch(english: false, actual: !initial, longPress: false)
            featureCheck(caps.target(english: true) == (korean ? !initial : initial),
                "Caps Lock pressed in Korean sets the English case only with Caps Lock in Korean on")
        }
    }
    var caps = EnglishCapsState()
    caps.enable(actual: false)
    caps.willSwitch(english: true, actual: false, longPress: false)
    caps.capsKeyChanged(english: false, actual: true, korean: true)
    featureCheck(caps.target(english: true) == false, "A Caps Lock change during a switch is still ignored")
    var into = EnglishCapsState()
    into.enable(actual: false)
    into.willSwitch(english: false, actual: false, longPress: false)
    into.capsKeyChanged(english: true, actual: true)
    featureCheck(into.target(english: true) == true, "A Caps Lock press on the way into English is the user's; only Korean turns the lock off")
    into.switching = false
    into.willSwitch(english: true, actual: true, longPress: false)
    into.capsKeyChanged(english: true, actual: false)
    featureCheck(into.target(english: true) == true, "A reset on the way into Korean is still ignored")
    into.switching = false; into.switching = true
    into.capsKeyChanged(english: true, actual: false)
    featureCheck(into.target(english: true) == true, "A switch it did not see start is not taken for one into English")

    let suite = "io.gksdud.english-switch-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let keyboard = TestKeyboard("english-switch-1", name: "Keyboard", serial: "english-switch")
    let engine = Engine(defaults: defaults, discover: { [keyboard] })
    _ = engine.keyboards.reconcile(sources: engine.defaultSources, target: f19, active: true)
    featureCheck(!engine.koreanCapsLock && !engine.escapeToEnglish, "Both keys are opt-in")
    featureCheck(!engine.capsLockSwitches())
    engine.defaultSources = [sources[0], sources[2]]
    featureCheck(engine.capsLockSwitches(), "Caps Lock among default Korean/English keys")
    featureCheck(!engine.capsLockSwitches([sources[0]]) && engine.capsLockSwitches([sources[3], sources[2]]), "Checks keys before saving them")
    engine.keyboards.setSources([sources[2]], for: keyboard.identity.key)
    engine.defaultSources = [sources[0]]
    featureCheck(engine.capsLockSwitches(), "Caps Lock as one keyboard's own key")
    engine.keyboards.setMode(.off, for: keyboard.identity.key)
    featureCheck(!engine.capsLockSwitches(), "Keyboards left off do not count")
    engine.defaultSources = [sources[2]]
    featureCheck(engine.capsLockSwitches(), "New keyboards follow the default")
    engine.keyboards.defaultEnabled = false
    featureCheck(!engine.capsLockSwitches())
    engine.keyboards.setMode(.on, for: keyboard.identity.key); engine.keyboards.setSources(nil, for: keyboard.identity.key)
    featureCheck(engine.capsLockSwitches(), "An enabled keyboard following the default")
    defaults.set(true, forKey: "koreanCapsLock")
    featureCheck(!engine.koreanCapsLock, "Caps Lock in Korean waits while Caps Lock is a Korean/English key, however it was saved")
    engine.keyboards.setMode(.off, for: keyboard.identity.key)
    featureCheck(engine.koreanCapsLock, "and comes back once it is not")
    print("PASS: ESC to English lowercase from Korean only, modifier and repeat exclusions, a remembered uppercase, a switch already on its way from either source, Caps Lock in Korean setting the English case, Caps Lock key conflicts")
}

func runOptionInputTests() {
    let korean = InputSourceIdentity(id: "ko", language: "ko"), english = InputSourceIdentity(id: "en", language: "en")
    var current = korean, front: pid_t? = 42, clock = 0.0
    var events: [CGEvent] = [], transitions: [String] = [], jobs: [(Double, () -> Void)] = []
    var selectWorks = true, selectedChanges = true, englishAvailable = true, canReturn = true
    var warnings: [String] = []
    let marker: Int64 = 191919
    let controller = OptionInputController(environment: .init(current: { current }, english: { englishAvailable ? english : nil }, select: {
        transitions.append($0.id)
        if $0 == korean && !canReturn { return false }
        if selectWorks && selectedChanges { current = $0 }
        return selectWorks
    }, frontmost: { front }, post: { events.append($0) }, later: { delay, action in jobs.append((clock + delay, action)) }, clock: { clock }, deadState: { _, event, state in
        if state != 0 { return 0 }
        return [14, 32, 34, 45, 50].contains(event.getIntegerValueField(.keyboardEventKeycode))
            && event.flags.contains(.maskAlternate) && !event.flags.contains(.maskShift) ? 1 : 0
    }), marker: marker)
    controller.report = { warnings.append($0) }
    func event(_ key: Int64, _ flags: CGEventFlags = [], _ down: Bool = true) -> CGEvent {
        let value = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)!
        value.flags = flags; return value
    }
    func drain() {
        var count = 0
        while !jobs.isEmpty {
            jobs.sort { $0.0 < $1.0 }; let job = jobs.removeFirst(); clock = job.0; job.1()
            count += 1; featureCheck(count < 1000, "Transactions must terminate")
        }
    }
    let option: CGEventFlags = [.maskAlternate], both: CGEventFlags = [.maskAlternate, .maskShift]
    for flags in [option, both] {
        for key: Int64 in [0, 19, 25, 28, 42, 49] {
            featureCheck(OptionKeyPolicy.matches(code: key, flags: flags))
        }
    }
    for key: Int64 in [36, 48, 51, 53, 57, 80, 102, 104, 123, 124, 125, 126] { featureCheck(!OptionKeyPolicy.matches(code: key, flags: both)) }
    for extra: CGEventFlags in [.maskCommand, .maskControl, .maskSecondaryFn] { featureCheck(!OptionKeyPolicy.matches(code: 25, flags: both.union(extra))) }
    featureCheck(!controller.handle(event(25, both), mode: .none, active: true))
    featureCheck(!controller.handle(event(25, both), mode: .english, active: false))
    current = english; featureCheck(!controller.handle(event(25, both), mode: .english, active: true))
    let letterKeys: [Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40, 45, 46]
    for source in [korean, english] {
        current = source
        for flags in [option, both, both.union(.maskAlphaShift)] {
            for down in [true, false] {
                for key in OptionKeyPolicy.printable {
                    let stroke = event(key, flags, down)
                    let expected = letterKeys.contains(key) ? flags.subtracting(.maskAlternate) : flags
                    featureCheck(!controller.handle(stroke, mode: .block, active: true) && stroke.flags == expected,
                        "Block only letter keys, preserving numbers, punctuation, space and keypad: \(key)")
                }
            }
        }
    }
    for extra: CGEventFlags in [.maskCommand, .maskControl, .maskSecondaryFn] {
        let shortcut = event(0, both.union(extra))
        featureCheck(!controller.handle(shortcut, mode: .block, active: true) && shortcut.flags == both.union(extra), "Block mode keeps shortcuts")
    }
    current = korean
    let keypadKeys: [Int64] = [65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 95]
    for key in keypadKeys {
        for flags in [option, both, option.union(.maskNumericPad), both.union([.maskNumericPad, .maskAlphaShift])] {
            featureCheck(!OptionKeyPolicy.matches(code: key, flags: flags), "Keypad must not start an English round trip")
            for repeated in [false, true] {
                let stroke = event(key, flags)
                stroke.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
                featureCheck(!controller.handle(stroke, mode: .english, active: true) && stroke.flags == flags,
                    "Keypad down/repeat must pass unchanged: \(key)")
            }
            let release = event(key, flags.subtracting(.maskAlternate), false)
            featureCheck(!controller.handle(release, mode: .english, active: true)
                && release.flags == flags.subtracting(.maskAlternate), "Keypad must retain its physical key-up")
        }
    }
    featureCheck(jobs.isEmpty && events.isEmpty && transitions.isEmpty && warnings.isEmpty,
        "Idle keypad input must not schedule, replay, switch or warn")
    for flags in [option, both] {
        for repeatKey in [false, true] {
            let grave = event(50, flags)
            grave.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
            featureCheck(!controller.handle(grave, mode: .english, active: true) && grave.flags == flags,
                "Korean Option-won must reach the native IME immediately, including repeats")
        }
        featureCheck(!controller.handle(event(50, [], false), mode: .english, active: true), "Native symbol keeps its physical key-up")
    }
    englishAvailable = false
    featureCheck(!controller.handle(event(50, option), mode: .english, active: true), "Native backtick needs no English source")
    featureCheck(!controller.handle(event(83, option), mode: .english, active: true), "Native keypad needs no English source")
    englishAvailable = true
    featureCheck(!controller.handle(event(0), mode: .english, active: true), "Native backtick must not leave an English dead key pending")
    featureCheck(!controller.busy && jobs.isEmpty && events.isEmpty && transitions.isEmpty && warnings.isEmpty,
        "Native symbols must not switch sources, queue input or warn")
    featureCheck(controller.handle(event(25, both), mode: .english, active: true))
    featureCheck(controller.handle(event(25, [], false), mode: .english, active: true))
    featureCheck(controller.handle(event(0), mode: .english, active: true))
    drain()
    featureCheck(current == korean && !controller.busy && transitions == ["en", "ko"])
    featureCheck(events.count == 3 && events[0].type == .keyDown && events[1].type == .keyUp)
    featureCheck(events[0].flags == both && events[2].getIntegerValueField(.keyboardEventKeycode) == 0)
    featureCheck(events[0].getIntegerValueField(.eventSourceUserData) == marker)
    featureCheck(!controller.handle(events[0], mode: .english, active: true), "No synthetic recursion")
    events.removeAll(); transitions.removeAll()
    for key: Int64 in [28, 19, 25] {
        featureCheck(controller.handle(event(key, option), mode: .english, active: true))
        featureCheck(controller.handle(event(key, option, false), mode: .english, active: true))
    }
    featureCheck(controller.handle(event(0), mode: .english, active: true))
    featureCheck(controller.handle(event(27, option), mode: .english, active: true))
    drain()
    featureCheck(transitions == ["en", "ko"], "Rapid Option strokes share one round trip")
    // An Option stroke behind waiting text is released with it, in order, for its own transaction.
    featureCheck(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [28, 28, 19, 19, 25, 25, 0, 27])
    events.removeAll(); transitions.removeAll()
    for (accent, base): (Int64, Int64) in [(14, 0), (32, 32), (34, 0), (45, 45), (14, 83)] {
        let baseFlags: [CGEventFlags] = base == 83 ? [[], .maskShift, option, both] : [[], .maskShift]
        for flags in baseFlags {
            featureCheck(controller.handle(event(accent, option), mode: .english, active: true))
            featureCheck(!controller.busy && transitions.isEmpty, "Dead keys wait for a composing stroke")
            featureCheck(controller.handle(event(accent, [], false), mode: .english, active: true))
            featureCheck(controller.handle(event(base, flags), mode: .english, active: true))
            featureCheck(controller.handle(event(base, flags, false), mode: .english, active: true))
            featureCheck(controller.handle(event(1), mode: .english, active: true))
            featureCheck(controller.handle(event(1, [], false), mode: .english, active: true))
            drain()
            featureCheck(current == korean && !controller.busy && transitions == ["en", "ko"])
            featureCheck(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [accent, accent, base, base, 1, 1],
                "Accent composition must precede the next Hangul stroke, including keypad continuation")
            featureCheck(events[2].flags == flags && events[3].flags == flags, "Composing letter preserves Shift")
            featureCheck(!controller.handle(event(base), mode: .english, active: true)
                && !controller.handle(event(base, [], false), mode: .english, active: true), "Accent must release the next plain key")
            events.removeAll(); transitions.removeAll()
        }
    }
    englishAvailable = false
    featureCheck(!controller.handle(event(25, both), mode: .english, active: true)); englishAvailable = true
    selectWorks = false
    _ = controller.handle(event(25, both), mode: .english, active: true); drain()
    featureCheck(!controller.busy && events.count == 2 && current == korean, "Failed switch replays original once")
    _ = controller.handle(event(25, [], false), mode: .english, active: true)
    selectWorks = true; selectedChanges = false; events.removeAll()
    _ = controller.handle(event(25, both), mode: .english, active: true); drain()
    featureCheck(!controller.busy && events.count == 2, "Missing source confirmation times out")
    _ = controller.handle(event(25, [], false), mode: .english, active: true)
    selectedChanges = true; events.removeAll(); canReturn = false
    _ = controller.handle(event(25, both), mode: .english, active: true)
    _ = controller.handle(event(0), mode: .english, active: true)
    drain()
    featureCheck(!controller.busy && current == english && events.count == 2, "Failed return must not inject queued Hangul in English")
    _ = controller.handle(event(25, [], false), mode: .english, active: true)
    canReturn = true; current = korean; events.removeAll()
    _ = controller.handle(event(25, both), mode: .english, active: true)
    _ = controller.handle(event(0), mode: .english, active: true)
    front = 99; controller.cancel(focusChanged: true); drain()
    featureCheck(events.isEmpty && !controller.busy, "Never replay queued text into a different app")
    featureCheck(!warnings.isEmpty)
    featureCheck(AppDelegate.sourceForID("io.gksdud.nonexistent-input-source") == nil, "Unavailable input sources must not crash")
    if let abc = AppDelegate.sourceForID("com.apple.keylayout.ABC"), let identity = AppDelegate.sourceIdentity(abc) {
        let owner = AppDelegate(engine: Engine(defaults: UserDefaults(suiteName: "io.gksdud.layout-read-test")!, discover: { [] }))
        let translate = owner.makeOptionInput().environment.deadState
        for (accent, base): (Int64, Int64) in [(14, 0), (32, 32), (34, 0), (45, 45), (14, 83)] {
            let pending = translate(identity, event(accent, option), 0) ?? 0
            featureCheck(pending != 0, "ABC accent must enter composition: \(accent)")
            for flags: CGEventFlags in [[], .maskShift] {
                featureCheck(translate(identity, event(base, flags), pending) == 0,
                    "A composed accent must release the following Hangul stroke")
            }
            featureCheck(translate(identity, event(accent, both), 0) == 0, "Option-Shift accent is a standalone mark")
        }
        featureCheck((translate(identity, event(50, option), 0) ?? 0) != 0, "ABC Option-grave is a dead key, unlike Korean Option-won")
    } else {
        print("SKIP: native ABC accent check (ABC input source is unavailable); simulated dead-key checks passed")
    }
    print("PASS: Option/Option-Shift printable keys, shortcut exclusions, block mode, ordered round trip, dead keys, source failures, focus cancellation, synthetic bypass")
}

// Opt-in native input probe: directs generated test keys only to its own window.
// It does not install a global event tap, touch HID mappings, or replace an app.
func probeOptionInput() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular); app.finishLaunching()
    guard AXIsProcessTrusted() else { throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native input probe requires accessibility permission."]) }
    let previousApp = NSWorkspace.shared.frontmostApplication
    let savedSource = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()
    let suite = "io.gksdud.input-probe.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let delegate = AppDelegate(engine: Engine(defaults: defaults, discover: { [] }))
    let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    panel.title = "gksdud 특수문자 입력 실험"
    let text = NSTextView(frame: NSRect(x: 20, y: 20, width: 480, height: 110))
    text.font = .systemFont(ofSize: 24); panel.contentView!.addSubview(text)
    panel.center(); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(text); app.activate(ignoringOtherApps: true)
    func pump(_ duration: TimeInterval) {
        let end = Date(timeIntervalSinceNow: duration)
        while Date() < end {
            if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default, dequeue: true) { app.sendEvent(event) }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    }
    pump(0.5)
    guard panel.isKeyWindow, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
        panel.orderOut(nil); defaults.removePersistentDomain(forName: suite)
        throw NSError(domain: "probe", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unlock the Mac and activate the test window before running the native input probe."])
    }
    var environment = delegate.makeOptionInput().environment
    environment.post = { $0.postToPid(getpid()) }
    var selections = 0
    let select = environment.select
    environment.select = { source in selections += 1; return select(source) }
    let controller = OptionInputController(environment: environment, marker: delegate.nativePulseMarker)
    controller.report = { print("PROBE notice: \($0)") }
    var mode = SpecialCharacterMode.english
    let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
        guard let cg = event.cgEvent else { return event }
        return controller.handle(cg, mode: mode, active: true) ? nil : NSEvent(cgEvent: cg)
    }
    defer {
        controller.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        _ = TISSelectInputSource(savedSource)
        panel.orderOut(nil); previousApp?.activate(options: [])
        defaults.removePersistentDomain(forName: suite)
    }
    guard let korean = delegate.availableSource("ko") else { throw NSError(domain: "probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Korean input source is unavailable."]) }
    func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = flags
            if OptionKeyPolicy.keypad.contains(Int64(code)) { event.flags.insert(.maskNumericPad) }
            event.postToPid(getpid())
        }
    }
    var passed = 0
    let keypadCases: [(CGKeyCode, String)] = [(65, "."), (67, "*"), (69, "+"), (75, "/"), (78, "-"), (81, "="),
        (82, "0"), (83, "1"), (84, "2"), (85, "3"), (86, "4"), (87, "5"), (88, "6"), (89, "7"), (91, "8"), (92, "9")]
    var cases: [(CGKeyCode, CGEventFlags, String)] = [(25, [.maskAlternate, .maskShift], "·"), (28, [.maskAlternate], "•"), (19, [.maskAlternate], "™"), (27, [.maskAlternate], "–"), (27, [.maskAlternate, .maskShift], "—"), (8, [.maskAlternate], "ç"), (50, [.maskAlternate], "`"), (50, [.maskAlternate, .maskShift], "~")]
    for (code, symbol) in keypadCases {
        cases.append((code, [.maskAlternate], symbol))
        cases.append((code, [.maskAlternate, .maskShift], symbol))
    }
    for (code, flags, symbol) in cases {
        text.inputContext?.discardMarkedText(); text.string = ""
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(text); app.activate(ignoringOtherApps: true); pump(0.1)
        let selectionResult = TISSelectInputSource(korean); pump(0.2)
        guard selectionResult == noErr, environment.current()?.language.hasPrefix("ko") == true,
              panel.isKeyWindow, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            throw NSError(domain: "probe", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not prepare an active Korean input context."])
        }
        key(15); pump(0.03); key(40); pump(0.03)
        let before = selections
        key(code, flags)
        // Deliberately queue the next Hangul syllable before the 60 ms return.
        pump(0.01); key(1); key(40); pump(0.5)
        let expected = "가\(symbol)나"
        let ok = text.string == expected && environment.current()?.language.hasPrefix("ko") == true
            && (!keypadCases.contains(where: { $0.0 == code }) || selections == before)
        if ok { passed += 1 }
        print("PROBE \(ok ? "PASS" : "FAIL"): expected=\(expected), actual=\(text.string), returned=\(environment.current()?.language ?? "nil")")
    }
    let accentCases: [(CGKeyCode, CGKeyCode, CGEventFlags, String)] = [
        (14, 0, [], "가á나"), (32, 32, [], "가ü나"), (34, 0, [], "가â나"), (45, 45, [], "가ñ나"),
        (14, 0, .maskShift, "가Á나"), (32, 32, .maskShift, "가Ü나"), (34, 0, .maskShift, "가Â나"), (45, 45, .maskShift, "가Ñ나"),
        (14, 83, [], "가´1나"), (14, 83, .maskAlternate, "가´1나")]
    for (accentKey, baseKey, flags, expected) in accentCases {
        text.inputContext?.discardMarkedText(); text.string = ""
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(text); app.activate(ignoringOtherApps: true); pump(0.1)
        let selectionResult = TISSelectInputSource(korean); pump(0.2)
        guard selectionResult == noErr, environment.current()?.language.hasPrefix("ko") == true,
              panel.isKeyWindow, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            throw NSError(domain: "probe", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not prepare an active Korean input context."])
        }
        key(15); pump(0.03); key(40); pump(0.03)
        key(accentKey, [.maskAlternate]); pump(0.03); key(baseKey, flags)
        pump(0.01); key(1); key(40); pump(0.5)
        let ok = text.string == expected && environment.current()?.language.hasPrefix("ko") == true
        if ok { passed += 1 }
        print("PROBE \(ok ? "PASS" : "FAIL"): expected=\(expected), actual=\(text.string), returned=\(environment.current()?.language ?? "nil")")
    }
    for rapidMode in [SpecialCharacterMode.english, .block] {
        controller.cancel(); mode = rapidMode
        text.inputContext?.discardMarkedText(); text.string = ""
        let selected = TISSelectInputSource(korean); pump(0.2)
        guard selected == noErr, environment.current()?.language.hasPrefix("ko") == true,
              panel.isKeyWindow, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            throw NSError(domain: "probe", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not prepare the rapid-symbol input context."])
        }
        key(15); key(40); pump(0.03)
        for _ in 0..<10 { key(50, [.maskAlternate]) }
        key(1); key(40); pump(0.3)
        let expected = "가" + String(repeating: "`", count: 10) + "나"
        let ok = text.string == expected && !controller.busy && environment.current()?.language.hasPrefix("ko") == true
        if ok { passed += 1 }
        print("PROBE \(ok ? "PASS" : "FAIL"): rapid backticks mode=\(mode), expected=\(expected), actual=\(text.string)")
    }
    guard let english = delegate.availableSource("en") else { throw NSError(domain: "probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "English input source is unavailable."]) }
    let blockCases: [(CGKeyCode, CGEventFlags, Bool)] = [(0, [.maskAlternate], true), (0, [.maskAlternate, .maskShift], true),
        (14, [.maskAlternate], true), (19, [.maskAlternate], false), (50, [.maskAlternate], false), (42, [.maskAlternate], false)]
    for source in [korean, english] {
        for (code, flags, letter) in blockCases {
            var expected = ""
            for reference in [true, false] {
                controller.cancel(); mode = reference ? .none : .block
                text.inputContext?.discardMarkedText(); text.string = ""
                let selected = TISSelectInputSource(source); pump(0.2)
                guard selected == noErr, environment.current() == AppDelegate.sourceIdentity(source),
                      panel.isKeyWindow, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
                    throw NSError(domain: "probe", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not prepare the block-mode input context."])
                }
                key(code, reference && letter ? flags.subtracting(.maskAlternate) : flags)
                pump(0.03); key(49); pump(0.1)
                if reference { expected = text.string; continue }
                let ok = !expected.isEmpty && text.string == expected && environment.current() == AppDelegate.sourceIdentity(source)
                if ok { passed += 1 }
                print("PROBE \(ok ? "PASS" : "FAIL"): block key=\(code), source=\(environment.current()?.language ?? "nil"), expected=\(expected), actual=\(text.string)")
            }
        }
    }
    let total = cases.count + accentCases.count + 2 + blockCases.count * 2
    print("PROBE RESULT: \(passed)/\(total) native AppKit cases")
    guard passed == total else { throw NSError(domain: "probe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Native input expectations failed."]) }
}

// Drives the running gksdud with HID-level keys from a second instance, then reads the input source and the Caps Lock lock.
// Launch the test app from build.sh, signed like the installed one, so it has gksdud's Accessibility permission:
// open -n -W --stdout <file> <test app> --args --probe-escape
// It needs ESC to English on in the running app. Keys go only while this probe's window is frontmost.
// A physical Caps Lock press cannot be generated: posted Caps Lock events do not toggle the lock.
func probeEscape() throws {
    func failure(_ code: Int, _ message: String) -> NSError { NSError(domain: "probe", code: code, userInfo: [NSLocalizedDescriptionKey: message]) }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular); app.finishLaunching()
    guard AXIsProcessTrusted() else { throw failure(1, "Launch the gksdud bundle with open -n so the probe has its accessibility permission.") }
    // The running app's settings, read only.
    let saved = UserDefaults.standard
    let target = targets.first { $0.name == saved.string(forKey: "target") } ?? targets[6]
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "io.gksdud.inputswitch").contains(where: { $0.processIdentifier != getpid() }),
          saved.object(forKey: "active") == nil || saved.bool(forKey: "active"), saved.bool(forKey: "escapeToEnglish") else {
        throw failure(2, "Run gksdud with ESC to English turned on first.")
    }
    let suite = "io.gksdud.escape-probe.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let delegate = AppDelegate(engine: Engine(defaults: defaults, discover: { [] }))
    guard let korean = delegate.availableSource("ko"), let english = delegate.availableSource("en") else {
        defaults.removePersistentDomain(forName: suite); throw failure(3, "Korean and English input sources are required.")
    }
    func lock() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0, state = false
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else { return false }
        defer { IOServiceClose(connection) }
        IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &state)
        return state
    }
    // ESC in a text view would open completions, so ESC cases send it to a plain view.
    final class KeySink: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {}
    }
    let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    panel.title = "gksdud ESC 실험"
    let text = NSTextView(frame: NSRect(x: 10, y: 10, width: 400, height: 100)), sink = KeySink(frame: .zero)
    text.font = .systemFont(ofSize: 24); panel.contentView!.addSubview(text); panel.contentView!.addSubview(sink)
    let previousApp = NSWorkspace.shared.frontmostApplication
    let savedSource = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()
    // The English case the running app remembers shows in English once it has restored it.
    _ = TISSelectInputSource(english); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
    let englishCase = lock()
    defer {
        // The running app ignores software lock changes, and a posted Caps Lock event does not toggle the lock. So the lock
        // is set directly, and a Caps Lock event only its tap reads sets the case it remembers.
        _ = TISSelectInputSource(english); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        try? setCapsLock(englishCase)
        if let caps = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_CapsLock), keyDown: true) {
            caps.type = .flagsChanged; caps.flags = englishCase ? .maskAlphaShift : []; caps.post(tap: .cghidEventTap)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        _ = TISSelectInputSource(savedSource); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        panel.orderOut(nil); previousApp?.activate(options: [])
        defaults.removePersistentDomain(forName: suite)
    }
    func pump(_ duration: TimeInterval) {
        let end = Date(timeIntervalSinceNow: duration)
        while Date() < end {
            if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default, dequeue: true) { app.sendEvent(event) }
        }
    }
    func frontmost() -> Bool { panel.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() }
    // Through the HID stream, so the running gksdud's tap and the system shortcut see it. Posted flags also become the
    // session's flags, so they carry the Caps Lock lock.
    func post(_ code: Int, hold: TimeInterval = 0) throws {
        guard frontmost() else { throw failure(4, "The probe window lost focus; no more keys were sent.") }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
            if lock() { event.flags.insert(.maskAlphaShift) }
            event.post(tap: .cghidEventTap)
            if down && hold > 0 { pump(hold) }
        }
    }
    // Waits out the running app's Caps Lock checks after the source change before setting the lock.
    func prepare(_ source: TISInputSource, caps: Bool, responder: NSResponder) throws {
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(responder); app.activate(ignoringOtherApps: true)
        _ = TISSelectInputSource(source); pump(0.6)
        // setCapsLock's immediate readback can lag here; the lock is checked below after a pause.
        try? setCapsLock(caps); pump(0.2)
        guard frontmost(), delegate.currentLanguage == delegate.language(source), lock() == caps else {
            throw failure(5, "Could not prepare \(delegate.language(source)) with Caps Lock \(caps ? "on" : "off").")
        }
    }
    var passed = 0, total = 0
    func expect(_ name: String, _ language: String, caps: Bool) {
        let actual = delegate.currentLanguage, actualCaps = lock()
        let ok = actual.hasPrefix(language) && actualCaps == caps
        total += 1; if ok { passed += 1 }
        print("PROBE \(ok ? "PASS" : "FAIL"): \(name), expected=\(language) Caps Lock \(caps), actual=\(actual) Caps Lock \(actualCaps)")
    }
    try prepare(korean, caps: false, responder: sink)
    try post(kVK_Escape); pump(0.8)
    expect("ESC in Korean", "en", caps: false)
    try prepare(english, caps: true, responder: sink)
    try post(kVK_Escape); pump(0.8)
    expect("ESC in English uppercase", "en", caps: false)
    // The switch key's pulse is still on its way when ESC arrives; a second pulse would return to Korean.
    try prepare(korean, caps: false, responder: sink)
    try post(target.keyCode); try post(kVK_Escape); pump(0.8)
    expect("Korean/English key right before ESC", "en", caps: false)
    // 2-Set Korean types Hangul whatever the lock, so showing the English case in Korean is safe.
    try prepare(korean, caps: true, responder: text)
    text.string = ""
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_R), keyDown: down)!
        event.flags = .maskAlphaShift; event.postToPid(getpid())
    }
    pump(0.3); text.unmarkText()
    total += 1; if text.string == "ㄱ" { passed += 1 }
    print("PROBE \(text.string == "ㄱ" ? "PASS" : "FAIL"): Caps Lock in Korean, expected=ㄱ, actual=\(text.string)")
    // Preservation remembers English uppercase; ESC still ends lowercase, even when the frontmost app changes meanwhile.
    // Last, since the probe gives up focus.
    for activation in [false, true] {
        // With long press on, a switch keeps the remembered case, so a hold sets it instead.
        if saved.bool(forKey: "longPressCapsLock") {
            try prepare(english, caps: false, responder: sink)
            // A hold toggles the remembered case, which may already be uppercase.
            for _ in 0..<2 where !lock() { try post(target.keyCode, hold: 0.7); pump(0.5) }
        } else {
            try prepare(english, caps: true, responder: sink)
        }
        guard delegate.currentLanguage.hasPrefix("en"), lock() else { throw failure(6, "Could not reach English uppercase.") }
        try post(target.keyCode); pump(0.8)
        guard delegate.currentLanguage.hasPrefix("ko") else { throw failure(6, "The switch key did not reach Korean.") }
        try post(kVK_Escape)
        if activation { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: []) }
        pump(0.8)
        expect(activation ? "ESC while another app activates" : "ESC over remembered uppercase", "en", caps: false)
    }
    print("PROBE RESULT: \(passed)/\(total) ESC and Caps Lock cases")
    guard passed == total else { throw failure(7, "ESC expectations failed.") }
}

func runUpdateInstallTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("gksdud-installer-test-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let installed = root.appendingPathComponent("Installed.app"), candidate = root.appendingPathComponent("Candidate.app")
    func writeBundle(_ url: URL, _ value: String) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try value.write(to: url.appendingPathComponent("version"), atomically: true, encoding: .utf8)
    }
    func version(_ url: URL) -> String { try! String(contentsOf: url.appendingPathComponent("version"), encoding: .utf8) }
    func rejected(_ action: () throws -> Void) { do { try action(); preconditionFailure("Expected rejection") } catch {} }
    try writeBundle(installed, "old"); try writeBundle(candidate, "new")
    rejected { try AppReplacement.replace(installed: installed, candidate: candidate, validate: { _, _ in throw UpdateFailure("invalid signature") }, launch: { _ in preconditionFailure() }) }
    featureCheck(version(installed) == "old", "Validate before moving the installed app")
    rejected { try AppReplacement.replace(installed: installed, candidate: candidate, validate: { _, _ in }, launch: { _ in }, move: { from, to in
        if from.lastPathComponent.hasPrefix(".gksdud-update-") { throw UpdateFailure("move failed") }
        try fm.moveItem(at: from, to: to)
    }) }
    featureCheck(version(installed) == "old", "Failed replacement restores the old path")
    var launches: [String] = []
    rejected { try AppReplacement.replace(installed: installed, candidate: candidate, validate: { _, _ in }, launch: { url in
        launches.append(version(url)); if version(url) == "new" { throw UpdateFailure("launch failed") }
    }) }
    featureCheck(version(installed) == "old" && launches == ["new", "old"], "Failed launch rolls back and restarts the old bundle")
    try AppReplacement.replace(installed: installed, candidate: candidate, validate: { new, old in featureCheck(version(new) == "new" && version(old) == "old") }, launch: { featureCheck(version($0) == "new") })
    featureCheck(version(installed) == "new" && version(candidate) == "new")
    let remaining = try fm.contentsOfDirectory(atPath: root.path)
    featureCheck(remaining.allSatisfy { !$0.hasPrefix(".gksdud-") })
    let archive = root.appendingPathComponent("test.zip")
    try Data("abc".utf8).write(to: archive)
    let valid = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  test.zip\n"
    try UpdateValidation.checksum(archive, text: valid, name: "test.zip")
    rejected { try UpdateValidation.checksum(archive, text: valid + valid, name: "test.zip") }
    rejected { try UpdateValidation.checksum(archive, text: valid, name: "other.zip") }
    try Data("tampered".utf8).write(to: archive)
    rejected { try UpdateValidation.checksum(archive, text: valid, name: "test.zip") }
    let names = "gksdud.app/\ngksdud.app/Contents/MacOS/gksdud\n"
    let listing = "drwxr-xr-x  2.1 unx 0 bx stor 00-Sep-00 00:00 gksdud.app/\n-rwxr-xr-x  2.1 unx 42 bx defN 00-Sep-00 00:00 gksdud.app/Contents/MacOS/gksdud\n"
    try UpdateValidation.archiveNames(names, listing: listing)
    rejected { try UpdateValidation.archiveNames("gksdud.app/../../escape", listing: listing) }
    rejected { try UpdateValidation.archiveNames("/gksdud.app/file", listing: listing) }
    rejected { try UpdateValidation.archiveNames(names, listing: listing.replacingOccurrences(of: "-rwx", with: "lrwx")) }
    rejected { try UpdateValidation.archiveNames(names, listing: listing.replacingOccurrences(of: "42 bx", with: "999999999 bx")) }
    var release = AppRelease(tag_name: "v1.3.0", html_url: "https://github.com/codingnoye/gksdud/releases/tag/v1.3.0", body: nil, draft: false, prerelease: false)
    release.assets = [ReleaseAsset(name: "test.zip", browser_download_url: "https://github.com/codingnoye/gksdud/releases/download/v1.3.0/test.zip", size: 100)]
    let assetURL = try release.assetURL(named: "test.zip", limit: 100)
    featureCheck(assetURL.host == "github.com")
    rejected { _ = try release.assetURL(named: "test.zip", limit: 99) }
    release.assets = [ReleaseAsset(name: "test.zip", browser_download_url: "https://evil.test/test.zip", size: 100)]
    rejected { _ = try release.assetURL(named: "test.zip", limit: 100) }
    rejected { _ = try UpdateValidation.installedRequirement(candidate) }
    // Real children: timeout must reap the process before replacement can roll back.
    for arguments in [["5"], ["-c", "trap '' TERM; exec /bin/sleep 5"]] {
        var pid: pid_t = 0
        rejected {
            try UpdateProcessLauncher.launch(executable: URL(fileURLWithPath: arguments.count == 1 ? "/bin/sleep" : "/bin/sh"), arguments: arguments, timeout: 0.1, settle: 0) {
                pid = $0.processIdentifier; return false
            }
        }
        featureCheck(pid > 1 && kill(pid, 0) == -1 && errno == ESRCH, "Timeout must leave no live child, including one ignoring SIGTERM")
    }
    rejected { try UpdateProcessLauncher.launch(executable: URL(fileURLWithPath: "/usr/bin/false"), timeout: 0.1, settle: 0.05, ready: { _ in true }) }
    let child = try UpdateProcessLauncher.launch(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.2, settle: 0.05, ready: { _ in true })
    featureCheck(child.isRunning)
    try UpdateProcessLauncher.stop(child)
    var rollbackSawDeadChild = false, failedPID: pid_t = 0
    rejected {
        try AppReplacement.replace(installed: installed, candidate: candidate, validate: { _, _ in }, launch: { _ in
            if failedPID == 0 {
                try UpdateProcessLauncher.launch(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.05, settle: 0) { failedPID = $0.processIdentifier; return false }
            } else { rollbackSawDeadChild = kill(failedPID, 0) == -1 && errno == ESRCH }
        })
    }
    featureCheck(rollbackSawDeadChild, "Old app relaunch waits for timed-out child termination")
    print("PASS: launch readiness, early exit, timeout termination, SIGKILL fallback, child exit before rollback")
    print("PASS: archive checksums/paths/link and size rejection, release asset origin, validation before replacement, move/launch rollback, successful replacement")
}

func runPrereleaseTests() {
    let suite = "io.gksdud.channel-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let tag = "pre-v1.3.0"
    let preview = AppRelease(tag_name: tag, html_url: "https://github.com/codingnoye/gksdud/releases/tag/\(tag)", body: nil, draft: false, prerelease: true)
    featureCheck(!preview.isNewer(than: "1.2.0"))
    var completion: ((Data?, URLResponse?, Error?) -> Void)?
    let checker = UpdateChecker(defaults: defaults, installedVersion: "1.2.0", fetch: { request, done in
        featureCheck(request.url?.path == "/repos/codingnoye/gksdud/releases/latest" && request.url?.query == nil)
        completion = done
    })
    checker.check()
    completion?(try! JSONEncoder().encode(preview), HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    featureCheck(checker.available == nil && checker.error != nil, "Prerelease responses are rejected")
    print("PASS: stable-only endpoint and prerelease rejection")
}

func runOptionRepeatTests() {
    let ko = InputSourceIdentity(id: "ko", language: "ko"), en = InputSourceIdentity(id: "en", language: "en")
    var current = ko, clock = 0.0, posts: [CGEvent] = [], jobs: [(Double, () -> Void)] = []
    let controller = OptionInputController(environment: .init(current: { current }, english: { en }, select: { current = $0; return true },
        frontmost: { 42 }, post: { posts.append($0) }, later: { jobs.append((clock + $0, $1)) }, clock: { clock }, deadState: { _, _, _ in 0 }), marker: 998877)
    func event(_ code: CGKeyCode = 25, down: Bool = true, repeatKey: Bool = false, option: Bool = true) -> CGEvent {
        let value = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        value.flags = option ? [.maskAlternate] : []
        value.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return value
    }
    func handle(_ event: CGEvent) -> Bool { controller.handle(event, mode: .english, active: true) }
    func drain() {
        var turns = 0
        while !jobs.isEmpty || !posts.isEmpty {
            while !posts.isEmpty { _ = handle(posts.removeFirst()) }
            if !jobs.isEmpty { jobs.sort { $0.0 < $1.0 }; let job = jobs.removeFirst(); clock = job.0; job.1() }
            turns += 1; featureCheck(turns < 1000)
        }
    }
    _ = handle(event()); drain()
    _ = handle(event(repeatKey: true))
    _ = handle(event(0, option: false)) // ordinary text prevents merging subsequent repeats
    _ = handle(event(0, down: false, option: false))
    _ = handle(event(repeatKey: true))
    _ = handle(event(down: false))
    drain()
    featureCheck(!handle(event(option: false)))
    featureCheck(!handle(event(down: false, option: false)), "Replayed repeat must not reclaim the already-consumed physical key-up")
    // A fresh queued stroke must still consume its own release during replay.
    _ = handle(event())
    _ = handle(event(down: false))
    _ = handle(event(0, option: false))
    _ = handle(event()); _ = handle(event(down: false)); drain()
    featureCheck(!handle(event(option: false)) && !handle(event(down: false, option: false)))
    print("PASS: repeat replay after physical release, subsequent plain key-up, queued fresh stroke balance")
}

func runNativeOptionSymbolTests() {
    let ko = InputSourceIdentity(id: "ko", language: "ko"), en = InputSourceIdentity(id: "en", language: "en")
    let nativeKeys: [CGKeyCode] = [50, 65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 95]
    for (nativeKey, delivering) in nativeKeys.flatMap({ code in [false, true].map { (code, $0) } }) {
        var current = ko, clock = 0.0, jobs: [(Double, () -> Void)] = []
        var posted: [CGEvent] = [], delivered: [(Int64, CGEventType, String)] = [], transitions: [String] = []
        let controller = OptionInputController(environment: .init(current: { current }, english: { en }, select: {
            transitions.append($0.id); current = $0; return true
        }, frontmost: { 42 }, post: { posted.append($0) }, later: { jobs.append((clock + $0, $1)) }, clock: { clock },
        deadState: { _, event, _ in event.getIntegerValueField(.keyboardEventKeycode) == 50 ? 1 : 0 }), marker: 991199)
        func send(_ event: CGEvent) {
            if !controller.handle(event, mode: .english, active: true) {
                delivered.append((event.getIntegerValueField(.keyboardEventKeycode), event.type, current.id))
            }
        }
        func key(_ code: CGKeyCode, _ down: Bool = true, _ option: Bool = true, repeated: Bool = false) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = option ? [.maskAlternate] : []
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
            send(event)
        }
        func advance() {
            jobs.sort { $0.0 < $1.0 }; let job = jobs.removeFirst(); clock = job.0; job.1()
            while !posted.isEmpty { send(posted.removeFirst()) }
        }
        key(25); key(25, false)
        if delivering { advance() }
        key(nativeKey); key(nativeKey, repeated: true); key(nativeKey, false, false)
        key(0, true, false); key(0, false, false)
        var turns = 0
        while !jobs.isEmpty { advance(); turns += 1; featureCheck(turns < 1000) }
        featureCheck(transitions == ["en", "ko"] && !controller.busy)
        featureCheck(delivered.map { $0.0 } == [25, 25, Int64(nativeKey), Int64(nativeKey), Int64(nativeKey), 0, 0], "Queued native symbols preserve input order")
        featureCheck(delivered.map { $0.1 } == [.keyDown, .keyUp, .keyDown, .keyDown, .keyUp, .keyDown, .keyUp])
        featureCheck(delivered.map { $0.2 } == ["en", "en", "ko", "ko", "ko", "ko", "ko"], "Native symbols and keypad are never merged into English strokes")
        key(nativeKey, true, false); key(nativeKey, false, false)
        featureCheck(delivered.count == 9, "Queued repeats must not steal a subsequent plain symbol key-up")
    }
    print("PASS: native Option-won/keypad during selection/delivery, repeated symbols, ordered Hangul replay and balanced key-up")
}

func runAddedSourceTests() {
    let ko = InputSourceIdentity(id: "ko2", language: "ko"), ko3 = InputSourceIdentity(id: "ko3", language: "ko")
    let abc = InputSourceIdentity(id: "abc", language: "en"), us = InputSourceIdentity(id: "us", language: "en")
    let ja = InputSourceIdentity(id: "ja", language: "ja"), zh = InputSourceIdentity(id: "zh", language: "zh-Hans")
    let enabled = [abc, ko, ja, zh]
    func cycle(_ current: InputSourceIdentity, _ order: [String] = ["ko2", "abc", "ja"], enabled: [InputSourceIdentity] = enabled,
               history: SourceHistory = SourceHistory()) -> String? {
        addedSourceTarget(separateKey: false, current: current, mode: .cycle, cycle: order, separate: nil, enabled: enabled, history: history)?.id
    }
    featureCheck(cycle(ko) == "abc" && cycle(abc) == "ja" && cycle(ja) == "ko2", "The Korean/English key goes round the list and back")
    featureCheck(cycle(ko3, enabled: enabled + [ko3]) == "abc", "Another Korean layout takes Korean's place")
    var history = SourceHistory()
    for id in ["abc", "ja", "zh"] { history.note(id) }
    featureCheck(cycle(zh, history: history) == "ja", "From outside the list it resumes at the most recent entry")
    featureCheck(cycle(zh) == "ko2", "or at the first one without history")
    featureCheck(cycle(ko, ["ko2", "gone", "abc"]) == "abc", "Sources macOS no longer offers are skipped")
    featureCheck(cycle(ko, ["ko2", "gone"]) == nil, "Fewer than two leaves the system shortcut alone")
    featureCheck(addedSourceTarget(separateKey: true, current: ko, mode: .cycle, cycle: ["ko2", "abc"], separate: "zh", enabled: enabled, history: history) == nil)
    func separate(_ current: InputSourceIdentity, key: Bool, source: String? = "zh", enabled: [InputSourceIdentity] = enabled + [us],
                  history: SourceHistory = SourceHistory()) -> String? {
        addedSourceTarget(separateKey: key, current: current, mode: .separate, cycle: [], separate: source, enabled: enabled, history: history)?.id
    }
    var recent = SourceHistory()
    for id in ["abc", "ko2", "us", "zh"] { recent.note(id) }
    featureCheck(separate(ko, key: false, history: recent) == "us" && separate(abc, key: false, history: recent) == "ko2",
        "The Korean/English key goes between the most recent Korean and English")
    featureCheck(separate(zh, key: false, history: recent) == "us", "and from the added source back to the most recent of them")
    featureCheck(separate(ko, key: true) == "zh" && separate(abc, key: true) == "zh" && separate(ja, key: true) == "zh", "The separate key goes to its source")
    featureCheck(separate(zh, key: true, history: recent) == "us", "and back to the most recent Korean or English")
    featureCheck(separate(ko, key: true, source: "gone") == nil && separate(ko, key: true, source: nil) == nil, "A source that is gone does nothing")
    var capped = SourceHistory()
    for index in 0..<20 { capped.note("s\(index)") }
    capped.note("s19"); capped.note("s18")
    featureCheck(capped.ids.count == 16 && capped.ids.prefix(2) == ["s18", "s19"], "History keeps the latest, once each")
    featureCheck(defaultCycle(enabled + [us]) == ["ko2", "abc", "us", "ja", "zh"], "Korean, English, then the rest as macOS lists them")
    featureCheck(sourceBadgeLabel("zh-Hans", position: 5) == "ZH" && sourceBadgeLabel("ja", position: nil) == "JA"
        && sourceBadgeLabel("fr", position: 3) == "FR" && sourceBadgeLabel("en_GB", position: 3) == "EN")
    featureCheck(sourceBadgeLabel("ain", position: 3) == "AIN" && sourceBadgeLabel("yue-Hant", position: 4) == "YUE", "Three-letter codes too")
    featureCheck(sourceBadgeLabel("", position: 3) == "3" && sourceBadgeLabel("tlh-Latn", position: 10) == "TLH" && sourceBadgeLabel("x1", position: 10) == "10",
        "Without a code of up to three letters, its place")
    featureCheck(sourceBadgeLabel("", position: 11) == "" && sourceBadgeLabel("", position: nil) == "", "Past 10, or out of the list, no number")
    featureCheck(recent.previous(of: "zh") == "us" && recent.previous(of: "ko2") == nil, "The previous source is known only from the current one")
    // Plans: a layout selected from the background while an input method is current may drop its syllable in progress.
    let layouts: Set<String> = ["abc", "us"]
    func plan(_ current: InputSourceIdentity, _ target: InputSourceIdentity, next: String?, previous: String?) -> SwitchPlan {
        switchPlan(current: current, target: target, next: next, previous: previous, isLayout: layouts.contains)
    }
    featureCheck(plan(ko, abc, next: "ja", previous: "abc") == SwitchPlan(selections: [], risky: false),
        "Korean to English whose shortcut already goes there sends the shortcut alone")
    featureCheck(plan(abc, ja, next: "ko2", previous: "ko2") == SwitchPlan(selections: ["ja", "abc"], risky: false),
        "From a layout anything can be selected first")
    featureCheck(plan(ko, ja, next: "abc", previous: "abc") == SwitchPlan(selections: ["ja", "ko2"], risky: false),
        "From Korean no layout is selected, even to set up the next one")
    featureCheck(plan(ja, ko, next: "abc", previous: "abc") == SwitchPlan(selections: ["ko2", "abc"], risky: true),
        "Into Korean the next layout is set up, at the cost of another input method's syllable")
    featureCheck(plan(ja, abc, next: "ko2", previous: "abc") == SwitchPlan(selections: [], risky: false))
    featureCheck(plan(abc, ko, next: "abc", previous: "ko2") == SwitchPlan(selections: [], risky: false), "Back to Korean from its layout is the shortcut alone")
    featureCheck(plan(ko, zh, next: "ko2", previous: "abc") == SwitchPlan(selections: ["zh", "ko2"], risky: false))
    featureCheck(plan(ko, abc, next: "ja", previous: "ja") == SwitchPlan(selections: ["abc", "ko2"], risky: true)
        && plan(ko, abc, next: nil, previous: nil).risky, "Only a lost setup leaves Korean's syllable at risk")
    featureCheck(reselectsTarget(landed: false, current: "ja", origin: "ja", targetIsLayout: true), "A switch that did not land ends on its layout")
    featureCheck(!reselectsTarget(landed: true, current: "ja", origin: "ja", targetIsLayout: true), "Back where it started after it landed stays there")
    featureCheck(!reselectsTarget(landed: false, current: "abc", origin: "ja", targetIsLayout: true)
        && !reselectsTarget(landed: false, current: "ja", origin: "ja", targetIsLayout: false), "Elsewhere, or toward an input method, nothing is selected")
    // Notifications for a source already handled.
    var notifications = SourceNotifications()
    featureCheck(notifications.handles("abc", addedSources: true) && !notifications.handles("abc", addedSources: true), "With added sources a repeat is skipped")
    featureCheck(notifications.handles("ko2", addedSources: false) && notifications.handles("ko2", addedSources: false), "Without them none is")
    featureCheck(notifications.handles("abc", addedSources: true), "Sources noted while they were off count, so turning them on skips nothing new")
    // The recent sources macOS keeps.
    let infos = [SourceInfo(id: "com.apple.keylayout.US", mode: nil, bundle: "com.apple.keyboardlayout.all", layout: true),
                 SourceInfo(id: "com.apple.inputmethod.Korean.2SetKorean", mode: "com.apple.inputmethod.Korean.2SetKorean", bundle: "com.apple.inputmethod.Korean", layout: false),
                 SourceInfo(id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", mode: "com.apple.inputmethod.Japanese", bundle: "com.apple.inputmethod.Kotoeri.RomajiTyping", layout: false),
                 SourceInfo(id: "com.apple.keylayout.ABC-AZERTY", mode: nil, bundle: "com.apple.keyboardlayout.all", layout: true)]
    let entries: [[String: Any]] = [["Bundle ID": "com.apple.inputmethod.Korean", "Input Mode": "com.apple.inputmethod.Korean.2SetKorean"],
                                    ["KeyboardLayout ID": 0, "KeyboardLayout Name": "U.S."],
                                    ["Bundle ID": "com.apple.inputmethod.Kotoeri.RomajiTyping", "Input Mode": "com.apple.inputmethod.Japanese"],
                                    ["KeyboardLayout Name": "ABC – AZERTY"], ["KeyboardLayout Name": "Removed"], ["KeyboardLayout Name": "U.S."]]
    featureCheck(systemHistory(entries, sources: infos) == ["com.apple.inputmethod.Korean.2SetKorean", "com.apple.keylayout.US",
        "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", "com.apple.keylayout.ABC-AZERTY"], "Entries map to sources until one does not")
    print("PASS: added input sources: cycle order, other layouts, outside the list, missing sources, separate key and back, history, badges, switch plans, landing, notifications, system history")
}
// Drives the running gksdud with its switch keys, then reads the input source and what this probe's text view receives.
// Launch the test app from build.sh, signed like the installed one, so it has gksdud's Accessibility permission:
// open -n -W --stdout <file> <test app> --args --probe-input-sources
// Needs Korean, English and one more input source. It turns added sources on in the running app's settings, which this
// probe shares, and puts them back afterwards. Letters go only to this probe; switch keys go only while it is frontmost.
func probeInputSources() throws {
    func failure(_ code: Int, _ message: String) -> NSError { NSError(domain: "probe", code: code, userInfo: [NSLocalizedDescriptionKey: message]) }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular); app.finishLaunching()
    guard AXIsProcessTrusted() else { throw failure(1, "Launch the gksdud bundle with open -n so the probe has its accessibility permission.") }
    let saved = UserDefaults.standard
    let target = targets.first { $0.name == saved.string(forKey: "target") } ?? targets[6]
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "io.gksdud.inputswitch").contains(where: { $0.processIdentifier != getpid() }),
          saved.object(forKey: "active") == nil || saved.bool(forKey: "active") else { throw failure(2, "Run gksdud with activation on first.") }
    let suite = "io.gksdud.sources-probe.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let delegate = AppDelegate(engine: Engine(defaults: defaults, discover: { [] }))
    let enabled = delegate.enabledSources()
    guard let ko = enabled.first(where: isKorean), let en = enabled.first(where: isEnglish),
          let foreign = enabled.first(where: { !isKorean($0) && !isEnglish($0) }),
          let korean = AppDelegate.sourceForID(ko.id), let english = AppDelegate.sourceForID(en.id) else {
        defaults.removePersistentDomain(forName: suite); throw failure(3, "Korean, English and one more input source are required.")
    }
    let keys = ["addedSources", "addedSourceMode", "cycleSources", "separateSource", "separateKey"]
    let backup = keys.map { saved.object(forKey: $0) }
    let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
    panel.title = "gksdud 입력 소스 추가 실험"
    let text = NSTextView(frame: NSRect(x: 10, y: 10, width: 500, height: 120)); text.font = .systemFont(ofSize: 24)
    panel.contentView!.addSubview(text); panel.center()
    let previousApp = NSWorkspace.shared.frontmostApplication
    let savedSource = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()
    func pump(_ duration: TimeInterval) {
        let end = Date(timeIntervalSinceNow: duration)
        while Date() < end {
            if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default, dequeue: true) { app.sendEvent(event) }
        }
    }
    defer {
        for (key, value) in zip(keys, backup) { saved.set(value, forKey: key) }
        text.inputContext?.discardMarkedText(); _ = TISSelectInputSource(savedSource); pump(0.3)
        panel.orderOut(nil); previousApp?.activate(options: [])
        defaults.removePersistentDomain(forName: suite)
    }
    panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(text); app.activate(ignoringOtherApps: true); pump(0.5)
    func frontmost() -> Bool { panel.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() }
    func focus() throws {
        guard !frontmost() else { return }
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(text); app.activate(ignoringOtherApps: true); pump(0.3)
        guard frontmost() else {
            throw failure(4, "The probe window lost focus to \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"); no more keys were sent.")
        }
    }
    // Through the HID stream, so the running gksdud's tap and the system shortcut see it.
    func press(_ code: Int, _ flags: CGEventFlags = []) throws {
        try focus()
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
            // Added, not replaced: an F-key keeps the function flag its shortcut is saved with.
            event.flags.insert(flags); event.post(tap: .cghidEventTap)
        }
        pump(0.6)
    }
    func type(_ codes: [Int]) throws {
        try focus()
        for code in codes { for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!.postToPid(getpid()) }; pump(0.06) }
        pump(0.2)
    }
    // This app's own selection reaches its input, unlike one from the background.
    func start(_ source: TISInputSource) throws {
        try focus(); text.inputContext?.discardMarkedText(); text.string = ""
        _ = TISSelectInputSource(source == english ? korean : english); pump(0.3)
        _ = TISSelectInputSource(source); pump(0.5)
    }
    var passed = 0, total = 0
    func expect(_ name: String, _ source: InputSourceIdentity, _ typed: (String) -> Bool) {
        let current = delegate.currentSource?.id ?? "", ok = current == source.id && typed(text.string)
        total += 1; if ok { passed += 1 }
        print("PROBE \(ok ? "PASS" : "FAIL"): \(name), expected=\(source.id), actual=\(current) text=\(text.string.debugDescription)")
    }
    // Typing in the added source gives neither plain letters nor Hangul.
    func foreignText(_ text: String) -> Bool { !text.hasSuffix("ka") && !text.unicodeScalars.contains { (0x3131...0xD7A3).contains($0.value) } }
    let (g, k, a) = (kVK_ANSI_G, kVK_ANSI_K, kVK_ANSI_A), space = kVK_Space
    saved.set(true, forKey: "addedSources"); saved.set(AddedSourceMode.cycle.rawValue, forKey: "addedSourceMode")
    saved.set([ko.id, en.id, foreign.id], forKey: "cycleSources"); pump(1.2)
    try start(korean); try type([g])
    try press(target.keyCode); try type([k, a])
    expect("cycle: Korean composing -> English", en) { $0 == "ㅎka" }
    text.string = ""; try press(target.keyCode); try type([k, a])
    expect("cycle: English -> \(foreign.id)", foreign, foreignText)
    text.inputContext?.discardMarkedText(); text.string = ""
    try press(target.keyCode); try type([g, k])
    expect("cycle: \(foreign.id) -> Korean", ko) { $0 == "하" }
    try type([g]); try press(target.keyCode); try type([k, a])
    // The next syllable takes ㅎ as its final consonant, and it still goes along.
    expect("cycle: second round, Korean composing -> English", en) { $0 == "핳ka" }
    saved.set(AddedSourceMode.separate.rawValue, forKey: "addedSourceMode"); saved.set(foreign.id, forKey: "separateSource")
    saved.set(NSNumber(value: spaceCombos[2]), forKey: "separateKey"); pump(1.2)
    try start(korean)
    try press(space, .maskAlternate); try type([k, a])
    expect("separate: Korean -> \(foreign.id)", foreign, foreignText)
    text.inputContext?.discardMarkedText(); text.string = ""
    try press(space, .maskAlternate); try type([g, k])
    expect("separate: back to Korean", ko) { $0 == "하" }
    // The way back set English up as the shortcut's previous source, so Korean's syllable in progress goes along.
    text.string = ""; try type([g]); try press(target.keyCode); try type([k, a])
    expect("separate: Korean composing -> English after it", en) { $0 == "ㅎka" }
    text.string = ""; try press(space, .maskAlternate); try press(space, .maskAlternate); try type([k, a])
    expect("separate: there and back to English", en) { $0 == "ka" }
    // Pressed again before each switch lands: twice comes back, three times goes.
    func quick(_ times: Int) throws {
        try focus()
        for _ in 0..<times {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(space), keyDown: down)!
                event.flags.insert(.maskAlternate); event.post(tap: .cghidEventTap)
            }
            pump(0.04)
        }
        pump(0.8)
    }
    try start(korean); try quick(2); try type([g, k])
    expect("separate: twice quickly comes back", ko) { $0 == "하" }
    text.string = ""; try quick(3); try type([k, a])
    expect("separate: three times quickly goes", foreign, foreignText)
    print("PROBE RESULT: \(passed)/\(total) added input source cases")
    guard passed == total else { throw failure(7, "Added input source expectations failed.") }
}
#endif
