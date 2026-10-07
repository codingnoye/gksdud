import AppKit

#if TESTS
// The tool and the app read arguments alike, and the app changes settings through the settings window's own paths.
// Fake keyboards, shortcuts and input menu; nothing reaches system settings.
func runCommandTests() {
    func parse(_ words: [String]) -> CLI.Invocation? { try? CLI.parse(words) }
    func change(_ name: String, _ keyboard: String? = nil, _ operation: CLI.Operation = .set, value: CLI.Value) -> CLI.Change {
        CLI.Change(address: CLI.Address(name: name, keyboard: keyboard), operation: operation, value: value)
    }
    precondition(CLI.keyNames.count == hangulKeys.count && CLI.singleKeyNames.count == sources.count && CLI.targetNames == targets.map(\.name),
        "Every key and F-key has a name")
    precondition(parse([])?.command == .help(nil) && parse(["set", "--help"])?.command == .help(nil) && parse(["help", "settings"])?.command == .help("settings"))
    precondition(parse(["--enable"])?.command == .set([change("active", value: .bool(true)), change("paused", value: .bool(false))])
        && parse(["disable"])?.command == .set([change("active", value: .bool(false))])
        && parse(["--im", "com.apple.keylayout.ABC"])?.command == .source("com.apple.keylayout.ABC"), "The flags issue #47 asked for")
    let set = parse(["set", "long-press=on", "keys+=Caps-Lock,shift-space", "target=19", "-j", "--force"])
    precondition(set?.options == CLI.Options(json: true, force: true, wait: false) && set?.command == .set([change("long-press", value: .bool(true)),
        change("keys", nil, .add, value: .list(["caps-lock", "shift-space"])), change("target", value: .text("F19"))]))
    precondition(parse(["set", "keyboard.Magic Keyboard 2.0.keys-=caps-lock", "keyboard.*.mode=OFF", "keyboard.ab12.keys=default"])?.command == .set([
        change("keys", "Magic Keyboard 2.0", .remove, value: .list(["caps-lock"])), change("mode", "*", value: .text("off")), change("keys", "ab12", value: .none)]),
        "A keyboard's name can hold dots")
    precondition(parse(["pause", "--no-alert"])?.options.alert == false && parse(["pause"])?.options.alert == true)
    precondition(parse(["pause"])?.command == .set([change("paused", value: .bool(true))]) && parse(["toggle", "escape"])?.command == .toggle([CLI.Address(name: "escape", keyboard: nil)]))
    for wrong in [["set"], ["set", "nope=on"], ["set", "active"], ["set", "active=maybe"], ["set", "active+=on"], ["toggle", "keys"], ["set", "keys="],
                  ["set", "keyboard.x.keys=ctrl-space"], ["set", "keyboard..mode=on"], ["get", "keyboard."], ["status", "x"], ["frobnicate"], ["--nope"]] {
        precondition(parse(wrong) == nil, "A usage error: \(wrong)")
    }
    print("PASS: commands, options, issue #47's flags, list operations, keyboard names with dots, usage errors")

    _ = NSApplication.shared
    let suite = "io.gksdud.command-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let one = TestKeyboard("command-1", name: "Keyboard One", serial: "command-1"), two = TestKeyboard("command-2", name: "Keyboard Two", serial: "command-2")
    var shortcuts: [String: Any] = [:], menu: CFPropertyList?
    let engine = Engine(defaults: defaults, discover: { [one, two] }, shortcutPreferences: ShortcutPreferences(read: { shortcuts }, write: { shortcuts = $0 }, activate: {}),
                        inputMenu: InputMenuPreference(read: { menu }, write: { menu = $0 }))
    var trusted = true
    engine.accessibilityTrusted = { trusted }
    // Inactive, so no change starts this process's own tap.
    defaults.set(false, forKey: "active")
    let delegate = AppDelegate(engine: engine)
    delegate.buildWindow()
    func run(_ words: String...) -> CommandReply { delegate.runCommand(words) }
    var shown: [[String]] = []
    delegate.presentCommandErrors = { shown.append($0) }
    func results(_ reply: CommandReply) -> [[String: Any]] { reply.json["results"] as? [[String: Any]] ?? [] }

    precondition(run("get", "long-press").text == "off" && run("get", "keys").text == "right-command", "One value alone")
    precondition((run("get").json["settings"] as? [String: Any])?.count == CLI.settings.count && run("get", "--json").exit == CLI.Exit.ok)
    var reply = run("set", "long-press=on", "escape=on")
    precondition(reply.exit == CLI.Exit.ok && reply.json["succeeded"] as? Int == 2 && engine.longPressCapsLock && engine.escapeToEnglish)
    precondition(results(reply).first?["before"] as? Bool == false && results(reply).first?["after"] as? Bool == true)
    precondition(run("toggle", "long-press").exit == CLI.Exit.ok && !engine.longPressCapsLock)
    reply = run("set", "escape=on")
    precondition(reply.exit == CLI.Exit.ok && results(reply).first?["changed"] as? Bool == false, "Already so is a success")
    print("PASS: get one value or all, set several, toggle, unchanged values")

    // Caps Lock in Korean needs case preservation, which comes later in the same command.
    precondition(run("set", "preserve-case=off").exit == CLI.Exit.ok && !engine.preserveCapsLock)
    reply = run("set", "korean-caps-lock=on", "preserve-case=on")
    precondition(reply.exit == CLI.Exit.ok && engine.preserveCapsLock && engine.koreanCapsLock, "A change waiting for another goes after it")
    precondition(run("set", "korean-caps-lock=on", "preserve-case=off").exit == CLI.Exit.failed && !engine.koreanCapsLock,
        "Turning preservation off turns Caps Lock in Korean off, as in the window")
    precondition(run("set", "preserve-case=on", "korean-caps-lock=on").exit == CLI.Exit.ok)
    // Caps Lock as a Korean/English key turns Caps Lock in Korean off: the window asks, and so --force is needed.
    reply = run("set", "keys=caps-lock")
    precondition(reply.exit == CLI.Exit.failed && (results(reply).first?["error"] as? String)?.contains("--force") == true
        && engine.defaultSources == [sources[0]] && engine.koreanCapsLock, "A declined warning changes nothing")
    reply = run("set", "keys=caps-lock", "--force")
    precondition(reply.exit == CLI.Exit.ok && engine.defaultSources == [sources[2]] && !engine.koreanCapsLock)
    let also = results(reply).first?["also"] as? [[String: Any]]
    precondition(also?.first?["setting"] as? String == "korean-caps-lock" && also?.first?["after"] as? Bool == false
        && (results(reply).first?["warnings"] as? [String])?.count == 1, "What else changed, and the warning that went ahead")
    precondition(run("set", "keys=right-command", "korean-caps-lock=on").exit == CLI.Exit.ok)
    reply = run("set", "keys=caps-lock", "korean-caps-lock=off")
    precondition(reply.exit == CLI.Exit.ok && engine.defaultSources == [sources[2]] && !engine.koreanCapsLock, "Turned off in the same command, nothing to warn about")
    precondition(run("set", "keys+=right-option,ctrl-space").exit == CLI.Exit.ok && engine.defaultSources == [sources[1], sources[2], spaceCombos[0]])
    precondition(run("set", "keys-=right-option").exit == CLI.Exit.ok && engine.defaultSources == [sources[2], spaceCombos[0]])
    precondition(run("set", "keys-=caps-lock,ctrl-space").exit == CLI.Exit.failed && engine.defaultSources == [sources[2], spaceCombos[0]], "One key at least")
    precondition(run("set", "keys=right-command").exit == CLI.Exit.ok)
    print("PASS: order-independent dependencies, warnings need --force, what else changed, list operations")

    reply = run("set", "long-press=on", "keyboard.nothing.mode=off")
    precondition(reply.exit == CLI.Exit.usage && !engine.longPressCapsLock, "A keyboard not found stops the whole command")
    precondition(run("set", "separate-source=nothing-like-this").exit == CLI.Exit.usage)
    reply = run("set", "keyboard.keyboard one.mode=off")
    precondition(reply.exit == CLI.Exit.ok && engine.keyboards.known[one.identity.key]?.mode == .off && engine.keyboards.known[two.identity.key]?.mode == .default)
    precondition(run("set", "keyboard.\(two.identity.key.prefix(6)).keys=right-option").exit == CLI.Exit.ok
        && engine.keyboards.known[two.identity.key]?.sources == [sources[1]], "By ID prefix")
    precondition(run("get", "keyboard.*.mode").text.components(separatedBy: "\n").count == 2 && run("get", "keyboard.Two.keys").text == "right-option")
    precondition(run("set", "keyboard.Keyboard.mode=on").exit == CLI.Exit.usage, "A part of two names is ambiguous")
    precondition(run("set", "keyboard.*.keys=default", "keyboard.*.mode=default").exit == CLI.Exit.ok
        && engine.keyboards.known.values.allSatisfy { $0.mode == .default && $0.sources == nil })
    precondition((run("keyboards").json["keyboards"] as? [[String: Any]])?.count == 2)
    print("PASS: keyboards by name, ID prefix or *, unknown or ambiguous ones stop the command")

    trusted = false
    reply = run("set", "escape=off")
    precondition(reply.exit == CLI.Exit.failed && engine.escapeToEnglish && (results(reply).first?["error"] as? String) == accessibilityHint,
        "Without Accessibility the window's controls are off, and so are the command's")
    precondition(run("enable").exit == CLI.Exit.failed && !engine.active)
    trusted = true
    delegate.commandSession = CommandSession(force: false)
    precondition(run("status").json["ok"] as? Bool == false, "One command at a time")
    delegate.commandSession = nil
    let status = run("status", "--json").json
    precondition(status["active"] as? Bool == false && status["paused"] as? Bool == false && status["keyboards"] is [String: Any])
    precondition(run("sources").json["sources"] is [[String: Any]])
    print("PASS: Accessibility, one command at a time, status and sources")

    // What the window shows in a window, such as a separate key that is a Korean/English key, shows there too unless --no-alert.
    // A declined warning was the command's answer, so it shows nothing.
    precondition(shown.isEmpty && run("set", "added-sources=on", "added-mode=separate").exit == CLI.Exit.ok)
    precondition(run("set", "separate-key=right-command", "--no-alert").exit == CLI.Exit.failed && shown.isEmpty && engine.separateKey == nil)
    precondition(run("set", "separate-key=right-command").exit == CLI.Exit.failed && shown.count == 1 && shown[0].count == 1
        && shown[0][0].contains("한영 키로 사용 중"), "Once, however often it was tried")
    precondition(run("set", "added-mode=cycle", "added-sources=off").exit == CLI.Exit.ok)
    print("PASS: errors and notices in a window by default, only in the result with --no-alert")

    // Paused, keyboards get their own keys back and Space combinations pass, without undoing the shortcut.
    defaults.set(true, forKey: "active")
    engine.defaultSources = [sources[2], spaceCombos[0]]; delegate.resetSelection()
    try! engine.shortcut(target: engine.target)
    _ = try! engine.reconcile()
    let mapped: [Mapping] = [[srcKey: NSNumber(value: sources[2]), dstKey: NSNumber(value: engine.target.usage)]]
    precondition(one.mappings == mapped && two.mappings == mapped && engine.chosenCombos == [spaceCombos[0]])
    reply = run("pause")
    precondition(reply.exit == CLI.Exit.ok && engine.paused && engine.active && one.mappings.isEmpty && two.mappings.isEmpty
        && engine.chosenCombos.isEmpty && Engine.ownsShortcut(shortcuts["60"], keyCode: engine.target.keyCode) && delegate.keyTap == nil)
    engine.paused = false
    try! engine.repair()
    precondition(one.mappings == mapped && engine.chosenCombos == [spaceCombos[0]], "Resuming maps them again")
    // Resuming through the command or the menu starts the tap, which this process must not; enable resumes, as parsed above.
    try! engine.restore()
    print("PASS: pause keeps activation and the shortcut, gives keyboards their keys back, resume maps them again")
}
#endif
