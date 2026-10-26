import AppKit

#if TESTS
// The tool and the app read arguments alike, and the app changes settings through the settings window's own paths.
// Fake keyboards, shortcuts and input menu; nothing reaches system settings.
func runCommandTests() {
    func parse(_ words: [String]) -> CLI.Invocation? { try? CLI.parse(words) }
    func change(_ name: String, _ keyboard: String? = nil, _ operation: CLI.Operation = .set, value: CLI.Value) -> CLI.Change {
        CLI.Change(address: CLI.Address(name: name, keyboard: keyboard), operation: operation, value: value)
    }
    precondition(CLI.keyNames.count == hangulKeys.count && CLI.singleKeyNames.count == sources.count && CLI.targetNames == targets.map(\.name)
        && CLI.switchTargetNames == switchTargets.map(\.name),
        "Every key and F-key has a name")
    precondition(parse([])?.command == .help(nil) && parse(["set", "--help"])?.command == .help(nil) && parse(["help", "settings"])?.command == .help("settings"))
    precondition(parse(["--enable"])?.command == .set([change("active", value: .bool(true)), change("paused", value: .bool(false))])
        && parse(["disable"])?.command == .set([change("active", value: .bool(false))])
        && parse(["--im", "com.apple.keylayout.ABC"])?.command == .source("com.apple.keylayout.ABC"), "The flags issue #47 asked for")
    precondition(parse(["set", "added-sources=on", "added-mode=cycle", "target=F20"])?.command
        == .set([change("added-sources", value: .bool(true)), change("target", value: .text("F19"))])
        && parse(["set", "separate-key=none", "separate-source=none"])?.command == .set([])
        && parse(["set", "added-mode=separate"]) == nil && parse(["set", "separate-key=right-option"]) == nil
        && parse(["get", "added-mode"]) == nil, "2.0.1's settings: the cycle and no separate key are dropped, F20 reads as F19, separate keys name the new form")
    let set = parse(["set", "long-press=on", "keys+=Caps-Lock,shift-space", "target=19", "-j", "--force"])
    precondition(set?.options == CLI.Options(json: true, force: true, wait: false) && set?.command == .set([change("long-press", value: .bool(true)),
        change("keys", nil, .add, value: .list(["caps-lock", "shift-space"])), change("target", value: .text("F19"))]))
    precondition(parse(["set", "keyboard.Magic Keyboard 2.0.keys-=caps-lock", "keyboard.*.mode=OFF", "keyboard.ab12.keys=default"])?.command == .set([
        change("keys", "Magic Keyboard 2.0", .remove, value: .list(["caps-lock"])), change("mode", "*", value: .text("off")), change("keys", "ab12", value: .none)]),
        "A keyboard's name can hold dots")
    precondition(parse(["set", "source.com.apple.keylayout.ABC.key=Opt-Space", "source.Japanese.enabled=off", "source.ko.key=none"])?.command == .set([
        CLI.Change(address: CLI.Address(name: "key", keyboard: nil, source: "com.apple.keylayout.ABC"), operation: .set, value: .text("opt-space")),
        CLI.Change(address: CLI.Address(name: "enabled", keyboard: nil, source: "Japanese"), operation: .set, value: .bool(false)),
        CLI.Change(address: CLI.Address(name: "key", keyboard: nil, source: "ko"), operation: .set, value: .none)]), "A source's ID can hold dots")
    precondition(parse(["pause", "--no-alert"])?.options.alert == false && parse(["pause"])?.options.alert == true)
    precondition(parse(["pause"])?.command == .set([change("paused", value: .bool(true))]) && parse(["toggle", "escape"])?.command == .toggle([CLI.Address(name: "escape", keyboard: nil)]))
    for wrong in [["set"], ["set", "nope=on"], ["set", "active"], ["set", "active=maybe"], ["set", "active+=on"], ["toggle", "keys"], ["set", "keys="],
                  ["set", "keyboard.x.keys=ctrl-space"], ["set", "keyboard..mode=on"], ["get", "keyboard."], ["status", "x"], ["frobnicate"], ["--nope"],
                  ["set", "source.x.key=caps"], ["set", "source..enabled=on"], ["set", "source.x.key+=caps-lock"]] {
        precondition(parse(wrong) == nil, "A usage error: \(wrong)")
    }
    print("PASS: commands, options, issue #47's flags, list operations, keyboard and source names with dots, usage errors")

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
    precondition(run("get", "backquote").text == "off" && run("set", "backquote=on").exit == CLI.Exit.ok && engine.swapBackquote
        && delegate.backquoteSwitch.state == .on && run("toggle", "backquote").exit == CLI.Exit.ok && !engine.swapBackquote)
    precondition(run("get", "universal-control").text == "off" && run("set", "universal-control=on").exit == CLI.Exit.ok && engine.universalControlCompat
        && delegate.universalControlSwitch.state == .on && run("toggle", "universal-control").exit == CLI.Exit.ok && !engine.universalControlCompat)
    precondition(run("get", "icon-case").text == "off" && run("set", "icon-case=on").exit == CLI.Exit.ok && delegate.showsIconCase
        && delegate.iconCaseSwitch.state == .on && run("toggle", "icon-case").exit == CLI.Exit.ok && !delegate.showsIconCase)
    precondition(run("set", "menubar=off").exit == CLI.Exit.ok && run("set", "icon-case=on").exit == CLI.Exit.failed
        && run("get", "icon-case").text == "off", "Without the menu bar icon it waits, as in the window")
    // Back without putting an icon in the real menu bar.
    defaults.set(false, forKey: "hidden"); delegate.showInMenuBar.state = .on; delegate.updatePressAccess()
    precondition(run("get", "update-badge").text == "on" && run("toggle", "update-badge").exit == CLI.Exit.ok && !delegate.showsUpdateBadge
        && delegate.updateBadgeSwitch.state == .off && run("set", "update-badge=on").exit == CLI.Exit.ok && delegate.showsUpdateBadge)
    var fetched = 0
    delegate.updates = UpdateChecker(defaults: defaults, installedVersion: "9.0.0", channel: .stable, fetch: { _, _ in fetched += 1 })
    precondition(run("set", "update-channel=prerelease").exit == CLI.Exit.ok && delegate.updates.channel == .prerelease && fetched == 1
        && defaults.string(forKey: "updates.channel") == "prerelease" && run("get", "update-channel").text == "prerelease"
        && delegate.channelPicker.titleOfSelectedItem == "프리릴리즈", "Choosing a channel checks it at once")
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
    precondition(run("set", "source.nothing-like-this.key=right-option").exit == CLI.Exit.usage)
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

    // Sources by exact ID: Korean and English ones can have keys too, and saving reads macOS's list again, so it is set each time.
    let korean = "com.apple.inputmethod.Korean.2SetKorean", abc = "com.apple.keylayout.ABC", japanese = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
    func withSources(_ arguments: String...) -> CommandReply {
        delegate.sourceCache = (list: [InputSourceIdentity(id: korean, language: "ko"), InputSourceIdentity(id: abc, language: "en"),
                                       InputSourceIdentity(id: japanese, language: "ja")], layouts: [abc])
        return delegate.runCommand(arguments)
    }
    // What the window shows in a window, such as a source's key that is a Korean/English key, shows there too unless --no-alert.
    // A declined warning was the command's answer, so it shows nothing.
    precondition(shown.isEmpty && withSources("set", "added-sources=on").exit == CLI.Exit.ok)
    precondition(withSources("set", "source.\(abc).key=right-command", "--no-alert").exit == CLI.Exit.failed && shown.isEmpty && engine.sourceKeys.isEmpty)
    precondition(withSources("set", "source.\(abc).key=right-command").exit == CLI.Exit.failed && shown.count == 1 && shown[0].count == 1
        && shown[0][0].contains("한영 키로 사용 중"), "Once, however often it was tried")
    precondition(withSources("set", "source.\(korean).key=opt-space", "source.\(abc).enabled=off", "cycle=\(japanese)").exit == CLI.Exit.ok
        && engine.sourceKeys == [korean: spaceCombos[2]] && engine.disabledSources == [abc] && engine.cycleSources == [japanese],
        "A Korean source's key, a source turned off, and a cycle of one")
    precondition(withSources("get", "source.\(abc).enabled").text == "off" && withSources("get", "source.\(korean).key").text == "opt-space")
    let listed = withSources("sources").json["sources"] as? [[String: Any]]
    precondition(listed?.first { $0["id"] as? String == korean }?["key"] as? String == "opt-space"
        && listed?.first { $0["id"] as? String == abc }?["enabled"] as? Bool == false, "The source list shows them")
    precondition(withSources("set", "source.\(japanese).key=opt-space").exit == CLI.Exit.ok && engine.sourceKeys == [japanese: spaceCombos[2]],
        "A key moves from one source to another")
    precondition(withSources("toggle", "source.\(abc).enabled").exit == CLI.Exit.ok && engine.disabledSources.isEmpty)
    precondition(withSources("set", "source.\(japanese).internal-key=F16").exit == CLI.Exit.failed, "A Space combination has no F-key")
    precondition(withSources("set", "source.\(japanese).key=right-option", "source.\(japanese).internal-key=16").exit == CLI.Exit.ok
        && engine.manualInternalKeys == [japanese: "F16"] && withSources("get", "source.\(japanese).internal-key").text == "F16")
    precondition(withSources("set", "source.\(japanese).internal-key=\(engine.target.name)").exit == CLI.Exit.failed, "Not the Korean/English key's own")
    precondition(withSources("set", "source.\(japanese).internal-key=auto").exit == CLI.Exit.ok && engine.manualInternalKeys.isEmpty)
    precondition(withSources("set", "source.\(japanese).key=none", "added-sources=off").exit == CLI.Exit.ok && engine.sourceKeys.isEmpty)
    engine.cycleSources = nil; delegate.sourceCache = nil
    print("PASS: errors and notices in a window by default, only in the result with --no-alert; sources' keys, turning them off, the cycle")

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
