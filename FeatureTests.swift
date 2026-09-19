import AppKit
import Carbon

func runFeatureTests() {
    precondition(ReleaseVersion("v1.10.0")! > ReleaseVersion("1.9.9")!)
    precondition(ReleaseVersion("1.2")! == ReleaseVersion("1.2.0")!)
    for invalid in ["pre-v1.3.0", "1.3.0-beta", "1..2", "1.2x", "", "1.2.99999999999999999999999"] { precondition(ReleaseVersion(invalid) == nil) }
    func release(_ body: String?, tag: String = "v1.3.0", url: String = "https://github.com/codingnoye/gksdud/releases/tag/v1.3.0", draft: Bool = false, pre: Bool = false) -> AppRelease {
        AppRelease(tag_name: tag, html_url: url, body: body, draft: draft, prerelease: pre)
    }
    let sample = release("### 요약\r\n\r\n- 탭 추가\r\n- 특수문자 개선\r\n\r\n### 설치\r\n이 내용은 표시하지 않습니다.")
    precondition(sample.summary.contains("탭 추가") && !sample.summary.contains("설치"))
    precondition(release("## 요약\n<!-- 게시 전 요약 작성 -->\n## 설치").summary == release(nil).summary)
    precondition(release("## 요약\n본문\n### 세부\n세부 내용\n## 설치\n비표시").summary == "본문\n### 세부\n세부 내용")
    precondition(release("**요약**\n본문\n## 설치\n비표시").summary == "본문")
    precondition(release("## 설치\n설치 안내").summary == release(nil).summary)
    precondition(release("```\n## 요약\n잘못된 요약\n```\n## 요약\n정상\n## 설치").summary == "정상")
    precondition(sample.isNewer(than: "1.2.0") && !sample.isNewer(than: "1.3.0") && !sample.isNewer(than: "2.0.0"))
    precondition(!release(nil, draft: true).isNewer(than: "1.2.0"))
    precondition(!release(nil, pre: true).isNewer(than: "1.2.0"))
    precondition(!release(nil, url: "https://github.com.evil.test/codingnoye/gksdud/releases/tag/v3.0").isNewer(than: "1.2.0"))
    let suite = "io.gksdud.feature-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var now = Date(timeIntervalSince1970: 100_000), requests = 0
    var completion: ((Data?, URLResponse?, Error?) -> Void)?
    let checker = UpdateChecker(defaults: defaults, installedVersion: "1.2.0", now: { now }, fetch: { request, done in
        requests += 1; completion = done
        precondition(request.url?.host == "api.github.com" && request.timeoutInterval == 20)
    })
    func respond(_ status: Int, _ data: Data?) {
        completion?(data, HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    checker.check(); checker.check(force: true); precondition(requests == 1, "Coalesce concurrent requests")
    respond(200, try! JSONEncoder().encode(sample)); precondition(checker.available != nil && !checker.checking)
    checker.check(); precondition(requests == 1)
    now += 86401; checker.check(); precondition(requests == 2)
    respond(503, nil); precondition(checker.available != nil && checker.error != nil, "Offline checks preserve cached notification")
    let relaunched = UpdateChecker(defaults: defaults, installedVersion: "1.2.0")
    precondition(relaunched.available != nil)
    let upgraded = UpdateChecker(defaults: defaults, installedVersion: "1.3.0")
    precondition(upgraded.available == nil)
    checker.check(force: true); respond(200, Data("{}".utf8)); precondition(checker.error != nil && checker.available != nil)
    checker.check(force: true); respond(200, try! JSONEncoder().encode(release(nil, tag: "v1.2.0")))
    precondition(checker.available == nil && checker.error == nil)
    print("PASS: numeric versions, release summary boundaries, trusted release URLs, daily schedule, retry/cache/offline/upgrade behavior")
    do { try runUpdateInstallTests() } catch { preconditionFailure("Installer tests: \(error)") }
    runOptionInputTests()
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
        return event.getIntegerValueField(.keyboardEventKeycode) == 14 && event.flags.contains(.maskAlternate) ? 1 : 0
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
            count += 1; precondition(count < 1000, "Transactions must terminate")
        }
    }
    let option: CGEventFlags = [.maskAlternate], both: CGEventFlags = [.maskAlternate, .maskShift]
    for flags in [option, both] {
        for key: Int64 in [0, 19, 25, 28, 42, 49, 82] {
            precondition(OptionKeyPolicy.matches(code: key, flags: flags))
        }
    }
    for key: Int64 in [36, 48, 51, 53, 57, 80, 102, 104, 123, 124, 125, 126] { precondition(!OptionKeyPolicy.matches(code: key, flags: both)) }
    for extra: CGEventFlags in [.maskCommand, .maskControl, .maskSecondaryFn] { precondition(!OptionKeyPolicy.matches(code: 25, flags: both.union(extra))) }
    precondition(!controller.handle(event(25, both), mode: .none, active: true))
    precondition(!controller.handle(event(25, both), mode: .english, active: false))
    current = english; precondition(!controller.handle(event(25, both), mode: .english, active: true))
    precondition(controller.handle(event(25, both), mode: .block, active: true))
    precondition(controller.handle(event(25, [], false), mode: .none, active: false), "Owned key-up survives mode change")
    current = korean
    precondition(controller.handle(event(25, both), mode: .english, active: true))
    precondition(controller.handle(event(25, [], false), mode: .english, active: true))
    precondition(controller.handle(event(0), mode: .english, active: true))
    drain()
    precondition(current == korean && !controller.busy && transitions == ["en", "ko"])
    precondition(events.count == 3 && events[0].type == .keyDown && events[1].type == .keyUp)
    precondition(events[0].flags == both && events[2].getIntegerValueField(.keyboardEventKeycode) == 0)
    precondition(events[0].getIntegerValueField(.eventSourceUserData) == marker)
    precondition(!controller.handle(events[0], mode: .english, active: true), "No synthetic recursion")
    events.removeAll(); transitions.removeAll()
    precondition(controller.handle(event(14, option), mode: .english, active: true))
    precondition(!controller.busy && transitions.isEmpty, "Dead keys wait for a composing stroke")
    _ = controller.handle(event(14, [], false), mode: .english, active: true)
    precondition(controller.handle(event(0), mode: .english, active: true))
    drain(); precondition(events.count == 4 && current == korean)
    _ = controller.handle(event(0, [], false), mode: .english, active: true)
    events.removeAll(); transitions.removeAll()
    englishAvailable = false
    precondition(!controller.handle(event(25, both), mode: .english, active: true)); englishAvailable = true
    selectWorks = false
    _ = controller.handle(event(25, both), mode: .english, active: true); drain()
    precondition(!controller.busy && events.count == 2 && current == korean, "Failed switch replays original once")
    _ = controller.handle(event(25, [], false), mode: .english, active: true)
    selectWorks = true; selectedChanges = false; events.removeAll()
    _ = controller.handle(event(25, both), mode: .english, active: true); drain()
    precondition(!controller.busy && events.count == 2, "Missing source confirmation times out")
    _ = controller.handle(event(25, [], false), mode: .english, active: true)
    selectedChanges = true; events.removeAll(); canReturn = false
    _ = controller.handle(event(25, both), mode: .english, active: true)
    _ = controller.handle(event(0), mode: .english, active: true)
    drain()
    precondition(!controller.busy && current == english && events.count == 2, "Failed return must not inject queued Hangul in English")
    _ = controller.handle(event(25, [], false), mode: .english, active: true)
    canReturn = true; current = korean; events.removeAll()
    _ = controller.handle(event(25, both), mode: .english, active: true)
    _ = controller.handle(event(0), mode: .english, active: true)
    front = 99; controller.cancel(focusChanged: true); drain()
    precondition(events.isEmpty && !controller.busy, "Never replay queued text into a different app")
    precondition(!warnings.isEmpty)
    if let abc = AppDelegate.sourceForID("com.apple.keylayout.ABC"), let identity = AppDelegate.sourceIdentity(abc) {
        let owner = AppDelegate(engine: Engine(defaults: UserDefaults(suiteName: "io.gksdud.layout-read-test")!, discover: { [] }))
        let translate = owner.makeOptionInput().environment.deadState
        let pending = translate(identity, event(14, option), 0)!
        precondition(pending != 0)
        precondition(translate(identity, event(0), pending) == 0, "A composed accent must release the following Hangul stroke")
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
    let controller = OptionInputController(environment: environment, marker: delegate.nativePulseMarker)
    controller.report = { print("PROBE notice: \($0)") }
    let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
        guard let cg = event.cgEvent else { return event }
        return controller.handle(cg, mode: .english, active: true) ? nil : event
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
            event.flags = flags; event.postToPid(getpid())
        }
    }
    var passed = 0
    let cases: [(CGKeyCode, CGEventFlags, String)] = [(25, [.maskAlternate, .maskShift], "·"), (28, [.maskAlternate], "•"), (19, [.maskAlternate], "™"), (27, [.maskAlternate], "–"), (27, [.maskAlternate, .maskShift], "—"), (8, [.maskAlternate], "ç")]
    for (code, flags, symbol) in cases {
        text.inputContext?.discardMarkedText(); text.string = ""
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(text); app.activate(ignoringOtherApps: true); pump(0.1)
        let selectionResult = TISSelectInputSource(korean); pump(0.2)
        guard selectionResult == noErr, environment.current()?.language.hasPrefix("ko") == true,
              panel.isKeyWindow, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            throw NSError(domain: "probe", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not prepare an active Korean input context."])
        }
        key(15); pump(0.03); key(40); pump(0.03)
        key(code, flags)
        // Deliberately queue the next Hangul syllable before the 60 ms return.
        pump(0.01); key(1); key(40); pump(0.5)
        let expected = "가\(symbol)나"
        let ok = text.string == expected && environment.current()?.language.hasPrefix("ko") == true
        if ok { passed += 1 }
        print("PROBE \(ok ? "PASS" : "FAIL"): expected=\(expected), actual=\(text.string), returned=\(environment.current()?.language ?? "nil")")
    }
    for (accentKey, baseKey, expected) in [(CGKeyCode(14), CGKeyCode(0), "가á나"), (CGKeyCode(32), CGKeyCode(32), "가ü나")] {
        text.inputContext?.discardMarkedText(); text.string = ""
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(text); app.activate(ignoringOtherApps: true); pump(0.1)
        let selectionResult = TISSelectInputSource(korean); pump(0.2)
        guard selectionResult == noErr, environment.current()?.language.hasPrefix("ko") == true,
              panel.isKeyWindow, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            throw NSError(domain: "probe", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not prepare an active Korean input context."])
        }
        key(15); pump(0.03); key(40); pump(0.03)
        key(accentKey, [.maskAlternate]); pump(0.03); key(baseKey)
        pump(0.01); key(1); key(40); pump(0.5)
        let ok = text.string == expected && environment.current()?.language.hasPrefix("ko") == true
        if ok { passed += 1 }
        print("PROBE \(ok ? "PASS" : "FAIL"): expected=\(expected), actual=\(text.string), returned=\(environment.current()?.language ?? "nil")")
    }
    print("PROBE RESULT: \(passed)/\(cases.count + 2) native AppKit cases")
    guard passed == cases.count + 2 else { throw NSError(domain: "probe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Native input expectations failed."]) }
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
    precondition(version(installed) == "old", "Validate before moving the installed app")
    rejected { try AppReplacement.replace(installed: installed, candidate: candidate, validate: { _, _ in }, launch: { _ in }, move: { from, to in
        if from.lastPathComponent.hasPrefix(".gksdud-update-") { throw UpdateFailure("move failed") }
        try fm.moveItem(at: from, to: to)
    }) }
    precondition(version(installed) == "old", "Failed replacement restores the old path")
    var launches: [String] = []
    rejected { try AppReplacement.replace(installed: installed, candidate: candidate, validate: { _, _ in }, launch: { url in
        launches.append(version(url)); if version(url) == "new" { throw UpdateFailure("launch failed") }
    }) }
    precondition(version(installed) == "old" && launches == ["new", "old"], "Failed launch rolls back and restarts the old bundle")
    try AppReplacement.replace(installed: installed, candidate: candidate, validate: { new, old in precondition(version(new) == "new" && version(old) == "old") }, launch: { precondition(version($0) == "new") })
    precondition(version(installed) == "new" && version(candidate) == "new")
    let remaining = try fm.contentsOfDirectory(atPath: root.path)
    precondition(remaining.allSatisfy { !$0.hasPrefix(".gksdud-") })
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
    precondition(assetURL.host == "github.com")
    rejected { _ = try release.assetURL(named: "test.zip", limit: 99) }
    release.assets = [ReleaseAsset(name: "test.zip", browser_download_url: "https://evil.test/test.zip", size: 100)]
    rejected { _ = try release.assetURL(named: "test.zip", limit: 100) }
    rejected { _ = try UpdateValidation.installedRequirement(candidate) }
    print("PASS: archive checksums/paths/link and size rejection, release asset origin, validation before replacement, move/launch rollback, successful replacement")
}
