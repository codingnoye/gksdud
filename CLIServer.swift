import AppKit
import Carbon
import ServiceManagement

// What one change of a command ran into. A warning the settings window would ask about goes ahead only with --force.
final class CommandSession {
    let force: Bool
    var errors: [String] = [], declined: [String] = [], accepted: [String] = [], notices: [String] = []
    init(force: Bool) { self.force = force }
    func clear() { errors = []; declined = []; accepted = []; notices = [] }
}

struct CommandReply {
    var exit = CLI.Exit.ok
    var text = ""
    var json: [String: Any] = ["ok": true]
    static func failure(_ message: String, _ exit: Int32 = CLI.Exit.failed) -> CommandReply {
        CommandReply(exit: exit, text: message, json: ["ok": false, "error": message])
    }
    var data: Data { (try? JSONSerialization.data(withJSONObject: ["exit": exit, "text": text, "json": json])) ?? Data() }
}

// One setting a command changes: a global one, or one keyboard's.
struct CommandItem {
    let setting: CLI.Setting
    let keyboard: SavedKeyboard?
    let operation: CLI.Operation
    let value: CLI.Value
    var label: String { keyboard.map { commandLabel($0, setting.name) } ?? setting.name }
}
func commandLabel(_ keyboard: SavedKeyboard, _ name: String) -> String { "keyboard.\(keyboard.key.prefix(8)).\(name)" }
// In their first order.
func unique(_ items: [String]) -> [String] { var seen: Set<String> = []; return items.filter { seen.insert($0).inserted } }

struct CommandResult {
    let item: CommandItem
    var wanted: CLI.Value?
    var ok: Bool
    var before: CLI.Value
    var after: CLI.Value
    var error: String?
    var also: [(label: String, kind: CLI.Kind, before: CLI.Value, after: CLI.Value)] = []
    var warnings: [String] = []
    // What the settings window would have shown in a window.
    var alerts: [String] = []
}

extension AppDelegate {
    // The command-line tool finds the app by this port; a second instance leaves it to the first.
    func startCommandServer() {
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let port = CFMessagePortCreateLocal(nil, CLI.port as CFString, { _, _, data, info in
            guard let info else { return nil }
            let owner = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            let request = (data as Data?).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return Unmanaged.passRetained(owner.runCommand(request?["args"] as? [String] ?? []).data as CFData)
        }, &context, nil) else { return }
        commandPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, port, 0), .commonModes)
    }

    func runCommand(_ arguments: [String]) -> CommandReply {
        let invocation: CLI.Invocation
        do { invocation = try CLI.parse(arguments) } catch { return .failure(error.localizedDescription, CLI.Exit.usage) }
        // A change waiting on macOS runs the run loop, and this port with it. The tool asks again a moment later.
        guard !engine.isUpdatingSettings, commandSession == nil else {
            var reply = CommandReply.failure("설정을 적용하고 있습니다. 잠시 후 다시 시도해주세요."); reply.json["busy"] = true; return reply
        }
        guard NSApplication.shared.modalWindow == nil else { return .failure("gksdud 창의 확인 대화상자를 먼저 닫아주세요.") }
        do {
            switch invocation.command {
            case .status: return commandStatus()
            case .get(let addresses): return try commandGet(addresses)
            case .set(let changes): return try commandSet(changes, options: invocation.options)
            case .toggle(let addresses):
                return try commandSet(addresses.map { CLI.Change(address: $0, operation: .set, value: .bool(commandValue($0.name) != .bool(true))) },
                                      options: invocation.options)
            case .source(let spec): return try commandSource(spec)
            case .sources: return commandSources()
            case .keyboards: return commandKeyboards()
            case .quit:
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return CommandReply(text: "gksdud를 종료합니다.")
            case .help(let topic): return CommandReply(text: topic == "settings" ? CLI.settingsHelp : CLI.usage)
            case .version: return CommandReply(text: "gksdud \(appVersion)", json: ["ok": true, "version": appVersion])
            case .start: return CommandReply(text: "gksdud가 이미 실행 중입니다.")
            }
        } catch { return .failure(error.localizedDescription, CLI.Exit.usage) }
    }
    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    // MARK: Settings

    func keyNames(_ keys: [UInt64]) -> [String] { keys.compactMap { hangulKeys.firstIndex(of: $0).map { CLI.keyNames[$0] } } }
    func keyIDs(_ names: [String]) -> [UInt64] { names.compactMap { CLI.keyNames.firstIndex(of: $0).map { hangulKeys[$0] } } }

    func commandValue(_ name: String, keyboard: SavedKeyboard? = nil) -> CLI.Value {
        if let keyboard {
            let saved = engine.keyboards.known[keyboard.key]
            if name == "mode" { return .text((saved?.mode ?? .default).rawValue) }
            return saved?.sources.map { .list(keyNames($0)) } ?? .none
        }
        switch name {
        case "active": return .bool(engine.active)
        case "paused": return .bool(engine.paused)
        case "login": return .bool(SMAppService.mainApp.status == .enabled)
        case "menubar": return .bool(!engine.defaults.bool(forKey: "hidden"))
        case "replace-input-menu": return .bool(engine.replacesInputMenu)
        case "icon": return .text(CLI.iconNames[iconStyle])
        case "icon-case": return .bool(engine.defaults.bool(forKey: "iconCase"))
        case "keys": return .list(keyNames(engine.defaultSources))
        case "target": return .text(engine.target.name)
        case "keyboard-default": return .bool(engine.keyboards.defaultEnabled)
        case "long-press": return .bool(engine.longPressCapsLock)
        case "preserve-case": return .bool(engine.preserveCapsLock)
        case "korean-caps-lock": return .bool(engine.koreanCapsLock)
        case "special-chars": return .text(CLI.specialNames[specialMode.rawValue])
        case "escape": return .bool(engine.escapeToEnglish)
        case "added-sources": return .bool(engine.addedSourcesEnabled)
        case "added-mode": return .text(engine.addedSourceMode == .cycle ? "cycle" : "separate")
        case "cycle": return .list(cycleOrder)
        case "separate-key": return engine.separateKey.map { .text(keyNames([$0])[0]) } ?? .none
        case "separate-source": return engine.separateSource.map { .text($0) } ?? .none
        case "compatibility": return .bool(engine.addedSourcesCompatible)
        default: return .none
        }
    }
    // What a change can also change, by label. Login is left out: nothing else changes it, and reading it asks the system.
    func commandSnapshot() -> [(label: String, kind: CLI.Kind, value: CLI.Value)] {
        CLI.settings.filter { $0.name != "login" }.map { ($0.name, $0.kind, commandValue($0.name)) }
            + engine.keyboards.keyboards.flatMap { keyboard in
                CLI.keyboardSettings.map { (commandLabel(keyboard, $0.name), $0.kind, commandValue($0.name, keyboard: keyboard)) }
            }
    }

    func matchKeyboards(_ selector: String) throws -> [SavedKeyboard] {
        // Keyboards connected since the last check are known after this.
        _ = engine.services()
        let all = engine.keyboards.keyboards, lower = selector.lowercased()
        guard !all.isEmpty else { throw CLI.UsageError("키보드가 없습니다.") }
        if selector == "*" { return all }
        if lower.count >= 4, lower.allSatisfy(\.isHexDigit) {
            let matches = all.filter { $0.key.hasPrefix(lower) }
            if matches.count == 1 { return matches }
            if matches.count > 1 { throw CLI.UsageError("'\(selector)'로 시작하는 키보드 ID가 여럿입니다. 더 길게 적어주세요.") }
        }
        // Keyboards of one name share it, like identical keyboards; a part of a name has to point at one name.
        for matches in [all.filter { $0.name.lowercased() == lower }, all.filter { $0.name.lowercased().contains(lower) }] where !matches.isEmpty {
            guard Set(matches.map(\.name)).count == 1 else {
                throw CLI.UsageError("'\(selector)'에 맞는 키보드가 여럿입니다: \(matches.map(\.name).joined(separator: ", ")). gksdud keyboards의 ID 앞부분으로 골라주세요.")
            }
            return matches
        }
        throw CLI.UsageError("'\(selector)' 키보드를 찾지 못했습니다. gksdud keyboards로 확인하세요.")
    }
    // ko and en are the Korean or English source used last.
    func matchSource(_ spec: String) throws -> InputSourceIdentity {
        let enabled = enabledSources(), lower = spec.lowercased()
        if let exact = enabled.first(where: { $0.id == spec }) { return exact }
        if ["ko", "korean", "en", "english"].contains(lower) {
            let korean = lower.hasPrefix("k")
            guard let found = sourceHistory.mostRecent(enabled.filter(korean ? isKorean : isEnglish)) else {
                throw CLI.UsageError("\(korean ? "한국어" : "영어") 입력 소스가 없습니다. 시스템 설정에서 추가해주세요.")
            }
            return found
        }
        let rules: [(InputSourceIdentity) -> Bool] = [
            { Self.sourceTitle($0.id).lowercased() == lower },
            { $0.id.split(separator: ".").last?.lowercased() == lower },
            { $0.id.lowercased().contains(lower) || Self.sourceTitle($0.id).lowercased().contains(lower) },
        ]
        for rule in rules {
            let matches = enabled.filter(rule)
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw CLI.UsageError("'\(spec)'에 맞는 입력 소스가 여럿입니다: \(matches.map(\.id).joined(separator: ", "))") }
        }
        throw CLI.UsageError("'\(spec)' 입력 소스를 찾지 못했습니다. gksdud sources로 켜져 있는 입력 소스를 확인하세요.")
    }

    // A change names input sources as the user likes and keyboards by selector; they are saved by ID.
    func commandItems(_ change: CLI.Change) throws -> [CommandItem] {
        let setting = try CLI.setting(change.address.label).1
        var value = change.value
        switch (setting.kind, value) {
        case (.sources, .list(let specs)): value = .list(try specs.map { try matchSource($0).id })
        case (.source, .text(let spec)):
            let source = try matchSource(spec)
            guard !isKorean(source) && !isEnglish(source) else { throw CLI.UsageError("분리로 전환할 입력 소스는 한국어·영어가 아니어야 합니다.") }
            value = .text(source.id)
        default: break
        }
        guard let selector = change.address.keyboard else { return [CommandItem(setting: setting, keyboard: nil, operation: change.operation, value: value)] }
        return try matchKeyboards(selector).map { CommandItem(setting: setting, keyboard: $0, operation: change.operation, value: value) }
    }
    // The value a change asks for, from the current one for += and -=.
    func commandTarget(_ item: CommandItem, current: CLI.Value) throws -> CLI.Value {
        guard case .list(let given) = item.value else { return item.value }
        var base: [String] = []
        if case .list(let list) = current { base = list } else if item.keyboard != nil { base = keyNames(engine.mappedSources) }
        var list = item.operation == .add ? base + given : item.operation == .remove ? base.filter { !given.contains($0) } : given
        if case .keys(let single) = item.setting.kind {
            list = (single ? CLI.singleKeyNames : CLI.keyNames).filter(list.contains)
            // A keyboard with no key of its own follows the default keys, as in the keyboard sheet.
            if list.isEmpty { if item.keyboard != nil { return .none }; throw CLI.UsageError("한영 키를 하나 이상 골라주세요.") }
        } else {
            list = unique(list)
            guard list.count > 1 else { throw CLI.UsageError("순회할 입력 소스를 2개 이상 선택해주세요.") }
        }
        return .list(list)
    }

    // Changes a setting through the control the settings window has for it, so it is checked, warned about and applied the
    // same way. Returns why the control cannot change it now, which another change in the same command may still fix.
    func applyCommand(_ item: CommandItem, _ value: CLI.Value) -> String? {
        var on = false, text: String?, list: [String]?
        switch value { case .bool(let flag): on = flag; case .text(let value): text = value; case .list(let value): list = value; case .none: break }
        // Pausing has no control, and is meant to be quick.
        if item.setting.name == "paused" { setPaused(on); return nil }
        // The controls as the window would show them now.
        updatePressAccess(); addedSources.refresh(force: true)
        let trusted = engine.accessibilityTrusted()
        if let keyboard = item.keyboard {
            guard advancedButton.isEnabled else { return accessibilityHint }
            let key = keyboard.key, saved = engine.keyboards.known[key]
            if item.setting.name == "mode", let mode = text.flatMap(KeyboardMode.init(rawValue:)) {
                changeKeyboards([key], change: { engine.keyboards.setMode(mode, for: key) }, undo: { engine.keyboards.setMode(saved?.mode ?? .default, for: key) })
            } else {
                changeKeyboards([key], change: { engine.keyboards.setSources(list.map(keyIDs), for: key) }, undo: { engine.keyboards.setSources(saved?.sources, for: key) })
            }
            return nil
        }
        func flip(_ button: NSButton, unless reason: String? = nil, _ action: () -> Void) -> String? {
            guard button.isEnabled else { return trusted ? reason ?? button.toolTip ?? "지금은 바꿀 수 없습니다." : accessibilityHint }
            button.state = on ? .on : .off; action(); return nil
        }
        let section = addedSources
        switch item.setting.name {
        case "active": return flip(enabled) { toggleEnabled() }
        case "login":
            let blocked = flip(login) { toggleLogin() }
            if blocked == nil, on, SMAppService.mainApp.status == .requiresApproval { commandSession?.errors.append("시스템 설정 → 로그인 항목에서 gksdud를 허용하세요.") }
            return blocked
        case "menubar": return flip(showInMenuBar) { toggleHidden() }
        case "replace-input-menu": return flip(replaceInputMenu, unless: "메뉴바에 표시를 켜야 쓸 수 있습니다.") { toggleReplaceInputMenu() }
        case "icon-case": return flip(iconCaseSwitch, unless: "메뉴바에 표시를 켜야 쓸 수 있습니다.") { toggleIconCase() }
        case "long-press": return flip(longPressSwitch) { toggleFeature(longPressSwitch) }
        case "preserve-case": return flip(preserveCapsSwitch) { toggleFeature(preserveCapsSwitch) }
        case "korean-caps-lock": return flip(koreanCapsSwitch) { toggleFeature(koreanCapsSwitch) }
        case "escape": return flip(escapeSwitch) { toggleFeature(escapeSwitch) }
        case "icon":
            guard iconPicker.isEnabled, let index = text.flatMap({ CLI.iconNames.firstIndex(of: $0) }) else { return accessibilityHint }
            iconPicker.selectItem(at: index); changeIconStyle()
        case "keys":
            guard picker.isEnabled else { return accessibilityHint }
            picker.show(keyIDs(list ?? [])); selectionChanged()
        case "target":
            guard advancedButton.isEnabled, let text else { return accessibilityHint }
            targetPicker.selectItem(withTitle: text); selectionChanged()
        case "keyboard-default":
            guard advancedButton.isEnabled else { return accessibilityHint }
            let saved = engine.keyboards.defaultEnabled
            // Turning Default on applies to every keyboard left on Default.
            changeKeyboards(Set(engine.keyboards.known.values.filter { $0.mode == .default }.map(\.key)),
                            change: { engine.keyboards.defaultEnabled = on }, undo: { engine.keyboards.defaultEnabled = saved })
        case "special-chars":
            let mode = text.flatMap { CLI.specialNames.firstIndex(of: $0) } ?? 0
            guard let button = specialButtons.first(where: { $0.tag == (mode == 0 ? specialMode.rawValue : mode) }), button.isEnabled else { return accessibilityHint }
            button.state = mode == 0 ? .off : .on; changeSpecialMode(button)
        case "added-sources": return flip(section.enable) { section.toggle() }
        default:
            guard section.modePicker.isEnabled else { return trusted ? "입력 소스 추가를 켜야 쓸 수 있습니다." : accessibilityHint }
            switch item.setting.name {
            case "added-mode": section.modePicker.selectItem(at: text == "separate" ? 1 : 0); section.changeMode()
            case "cycle": section.setCycle(list ?? [])
            case "separate-key":
                let key = text.map { keyIDs([$0]) }?.first
                section.keyPicker.selectItem(at: section.keyPicker.itemArray.firstIndex { ($0.representedObject as? NSNumber)?.uint64Value == key } ?? 0)
                section.changeKey()
            case "separate-source":
                section.sourcePicker.selectItem(at: section.sourcePicker.itemArray.firstIndex { $0.representedObject as? String == text } ?? 0)
                section.changeSource()
            default: return flip(section.compatible) { section.toggleCompatible() }
            }
        }
        return nil
    }
    // As the keyboard sheet changes them: saved first, so the warnings check the new settings, and undone if one is declined.
    func changeKeyboards(_ affected: Set<String>, change: () -> Void, undo: () -> Void) {
        change()
        if confirmKeyboardChange(affected) { repair() } else { undo() }
        keyboardSettings?.refresh()
    }
    func setPaused(_ paused: Bool) {
        engine.paused = paused
        // The tap stops or starts with it, and the keyboards follow at once.
        repair()
    }

    // Changes are tried in the order given. One that waits for another, such as Caps Lock in Korean for case preservation,
    // is tried again after the rest, while that changes something.
    func commandSet(_ changes: [CLI.Change], options: CLI.Options) throws -> CommandReply {
        let items = try changes.flatMap(commandItems)
        let session = CommandSession(force: options.force), ask = runAlert
        commandSession = session
        runAlert = { alert in
            let text = [alert.messageText, alert.informativeText].filter { !$0.isEmpty }.joined(separator: " ")
            // A notice has nothing to choose; a warning goes ahead only with --force.
            if alert.buttons.count < 2 { session.notices.append(text); return .alertFirstButtonReturn }
            if session.force { session.accepted.append(text); return .alertFirstButtonReturn }
            session.declined.append(text); return .alertSecondButtonReturn
        }
        defer { runAlert = ask; commandSession = nil }
        var results: [Int: CommandResult] = [:], waiting = Array(items.indices)
        while !waiting.isEmpty {
            var retry: [Int] = []
            for index in waiting {
                let (result, again) = attemptCommand(items[index], session)
                results[index] = result
                if again { retry.append(index) }
            }
            if retry.count == waiting.count { break }
            waiting = retry
        }
        // A later change can undo an earlier one, as turning case preservation off turns Caps Lock in Korean off.
        let final = items.indices.map { index in
            var result = results[index]!
            let now = commandValue(result.item.setting.name, keyboard: result.item.keyboard)
            if result.ok, let wanted = result.wanted, now != wanted {
                result.ok = false; result.after = now
                result.error = "같은 명령의 다른 변경 때문에 유지되지 않았습니다 (현재 \(CLI.text(now, result.item.setting.kind)))."
            }
            return result
        }
        if options.alert { showCommandErrors(final.filter { !$0.ok }.flatMap(\.alerts)) }
        return commandReply(final)
    }
    // Together in one window, as the settings window shows an error, once the reply has gone so the command does not wait.
    func showCommandErrors(_ messages: [String]) {
        let messages = unique(messages)
        guard let last = messages.last else { return }
        // Shown now, so the next repair does not show the same error again.
        lastError = last
        if let presentCommandErrors { presentCommandErrors(messages); return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = NSAlert(); alert.messageText = messages[0]
            alert.informativeText = messages.dropFirst().joined(separator: "\n")
            if !self.window.isVisible { self.showSettings() }
            alert.beginSheetModal(for: self.window)
        }
    }
    func attemptCommand(_ item: CommandItem, _ session: CommandSession) -> (CommandResult, retry: Bool) {
        session.clear()
        let current = commandValue(item.setting.name, keyboard: item.keyboard)
        var result = CommandResult(item: item, ok: true, before: current, after: current)
        let wanted: CLI.Value
        do { wanted = try commandTarget(item, current: current) } catch {
            result.ok = false; result.error = error.localizedDescription; return (result, false)
        }
        result.wanted = wanted
        guard wanted != current else { return (result, false) }
        let before = commandSnapshot()
        let blocked = applyCommand(item, wanted)
        let after = commandSnapshot()
        result.after = commandValue(item.setting.name, keyboard: item.keyboard)
        result.ok = result.after == wanted && session.errors.isEmpty
        result.warnings = session.accepted
        let earlier = Dictionary(before.map { ($0.label, $0.value) }, uniquingKeysWith: { $1 })
        result.also = after.compactMap { now in
            earlier[now.label].flatMap { $0 != now.value && now.label != item.label ? (now.label, now.kind, $0, now.value) : nil }
        }
        guard !result.ok else { return (result, false) }
        // Errors, and notices that have nothing to choose; a declined warning was the command's own answer.
        result.alerts = session.errors + session.notices
        let reasons = session.errors + session.declined.map { "\($0) (--force로 진행)" } + session.notices + [blocked].compactMap { $0 }
        result.error = reasons.isEmpty ? "적용되지 않았습니다." : reasons.joined(separator: " ")
        // A condition, not an error: another change in the command may meet it.
        return (result, session.errors.isEmpty && (blocked != nil || !session.declined.isEmpty || !session.notices.isEmpty))
    }

    func commandReply(_ results: [CommandResult]) -> CommandReply {
        func show(_ kind: CLI.Kind, _ value: CLI.Value) -> String { CLI.text(value, kind) }
        var lines: [String] = []
        for result in results {
            let kind = result.item.setting.kind, label = result.item.label
            let name = result.item.keyboard.map { " (\($0.name))" } ?? ""
            if !result.ok { lines.append("✗ \(label)\(name): \(result.error ?? "")") }
            else if result.before == result.after { lines.append("✓ \(label)\(name): \(show(kind, result.after)) (변경 없음)") }
            else { lines.append("✓ \(label)\(name): \(show(kind, result.before)) → \(show(kind, result.after))") }
            lines += result.also.map { "    함께 바뀜 \($0.label): \(show($0.kind, $0.before)) → \(show($0.kind, $0.after))" }
            lines += result.warnings.map { "    경고 진행: \($0)" }
        }
        let keyboards = keyboardSummary(), failed = results.filter { !$0.ok }.count
        if engine.active && !engine.paused { lines.append("키보드 \(keyboards.text)") }
        lines += keyboards.details
        if results.count > 1 { lines.append("성공 \(results.count - failed), 실패 \(failed)") }
        let json: [String: Any] = ["ok": failed == 0, "succeeded": results.count - failed, "failed": failed, "keyboards": keyboards.json,
            "results": results.map { result -> [String: Any] in
                var entry: [String: Any] = ["setting": result.item.label, "ok": result.ok, "changed": result.before != result.after,
                                            "before": CLI.json(result.before), "after": CLI.json(result.after)]
                if let keyboard = result.item.keyboard { entry["keyboard"] = ["id": keyboard.key, "name": keyboard.name] }
                if let error = result.error { entry["error"] = error }
                if !result.also.isEmpty { entry["also"] = result.also.map { ["setting": $0.label, "before": CLI.json($0.before), "after": CLI.json($0.after)] } }
                if !result.warnings.isEmpty { entry["warnings"] = result.warnings }
                return entry
            }]
        return CommandReply(exit: failed == 0 ? CLI.Exit.ok : CLI.Exit.failed, text: lines.joined(separator: "\n"), json: json)
    }
    func keyboardSummary() -> (text: String, details: [String], json: [String: Any]) {
        let result = engine.keyboards.result
        let failures = result.pending > 0 ? engine.keyboards.failures.values.sorted { $0.name < $1.name } : []
        let text = !engine.active ? "꺼짐" : engine.paused ? "일시정지"
            : result.selected == 0 && !engine.mappedSources.isEmpty ? "적용할 키보드 연결 대기 중"
            : "\(result.applied)대 적용" + (result.pending > 0 ? ", \(result.pending)대 실패" : "")
        return (text, failures.map { "  \($0.name): \($0.reason)" }, ["selected": result.selected, "applied": result.applied, "failed": result.pending,
                "failures": failures.map { ["name": $0.name, "reason": $0.reason] }])
    }

    // MARK: Reading

    func aligned(_ rows: [(String, String)]) -> String {
        let width = rows.map { CLI.width($0.0) }.max() ?? 0
        return rows.map { CLI.pad($0.0, width) + "  " + $0.1 }.joined(separator: "\n")
    }
    func commandGet(_ addresses: [CLI.Address]) throws -> CommandReply {
        let rows: [(label: String, kind: CLI.Kind, value: CLI.Value)] = addresses.isEmpty
            ? CLI.settings.map { ($0.name, $0.kind, commandValue($0.name)) }
            : try addresses.flatMap { address -> [(label: String, kind: CLI.Kind, value: CLI.Value)] in
                let setting = try CLI.setting(address.label).1
                guard let selector = address.keyboard else { return [(address.name, setting.kind, commandValue(address.name))] }
                return try matchKeyboards(selector).map { (commandLabel($0, address.name), setting.kind, commandValue(address.name, keyboard: $0)) }
            }
        // One value alone, for scripts.
        let text = addresses.count == 1 && rows.count == 1 ? CLI.text(rows[0].value, rows[0].kind) : aligned(rows.map { ($0.label, CLI.text($0.value, $0.kind)) })
        return CommandReply(text: text, json: ["ok": true, "settings": Dictionary(rows.map { ($0.label, CLI.json($0.value)) }, uniquingKeysWith: { $1 })])
    }
    func describe(_ source: InputSourceIdentity) -> [String: Any] {
        ["id": source.id, "name": Self.sourceTitle(source.id), "language": source.language, "layout": isLayout(source.id)]
    }
    func commandStatus() -> CommandReply {
        refreshStatus()
        let keyboards = keyboardSummary(), trusted = engine.accessibilityTrusted(), source = currentSource
        let issues = [status.stringValue, engine.keyboards.warning ?? ""].filter { !$0.isEmpty }
        let rows = [("version", appVersion), ("active", engine.active ? "on" : "off"), ("paused", engine.paused ? "on" : "off"),
                    ("accessibility", trusted ? "on" : "off"), ("source", source.map { "\($0.id) (\(Self.sourceTitle($0.id)))" } ?? ""),
                    ("keyboards", keyboards.text)]
        var json: [String: Any] = ["ok": true, "version": appVersion, "active": engine.active, "paused": engine.paused,
                                   "accessibility": trusted, "keyboards": keyboards.json, "issues": issues]
        json["source"] = source.map(describe)
        return CommandReply(text: ([aligned(rows)] + keyboards.details + issues).joined(separator: "\n"), json: json)
    }
    func commandSources() -> CommandReply {
        let current = currentSource?.id, list = enabledSources()
        let width = list.map { CLI.width($0.id) }.max() ?? 0
        let lines = list.map { "\($0.id == current ? "*" : " ") \(CLI.pad($0.id, width))  \(Self.sourceTitle($0.id)) (\($0.language))" }
        return CommandReply(text: lines.joined(separator: "\n"), json: ["ok": true, "sources": list.map { source -> [String: Any] in
            var entry = describe(source); entry["current"] = source.id == current; return entry
        }])
    }
    func commandKeyboards() -> CommandReply {
        _ = engine.services()
        let manager = engine.keyboards, list = manager.keyboards
        func keys(_ keyboard: SavedKeyboard) -> String { keyboard.sources.map { keyNames($0).joined(separator: ",") } ?? "default" }
        let rows = list.map { keyboard in
            ("\(keyboard.key.prefix(8))  \(keyboard.name)", "\(manager.connected.contains(keyboard.key) ? "연결됨" : "연결 안 됨")  mode=\(keyboard.mode.rawValue) keys=\(keys(keyboard))")
        }
        let header = "기본값: \(manager.defaultEnabled ? "on" : "off"), 기본 한영 키: \(keyNames(engine.mappedSources).joined(separator: ","))"
        return CommandReply(text: ([header] + (rows.isEmpty ? [] : [aligned(rows)])).joined(separator: "\n"), json: [
            "ok": true, "default": manager.defaultEnabled, "default_keys": keyNames(engine.mappedSources),
            "keyboards": list.map { keyboard -> [String: Any] in
                ["id": keyboard.key, "name": keyboard.name, "detail": keyboard.detail, "connected": manager.connected.contains(keyboard.key),
                 "mode": keyboard.mode.rawValue, "keys": keyboard.sources.map { keyNames($0) as Any } ?? NSNull()]
            }])
    }

    // MARK: Input sources

    // With gksdud on, a switch goes through its shortcut like the Korean/English key, so it reaches the app in front even for
    // an input method. Off, the source is selected directly, which an input method may not reach the app in front with.
    func commandSource(_ spec: String?) throws -> CommandReply {
        guard let current = currentSource else { return .failure("현재 입력 소스를 읽지 못했습니다.") }
        guard let spec else { return CommandReply(text: current.id, json: describe(current).merging(["ok": true]) { $1 }) }
        let enabled = enabledSources(), from = logicalSource ?? current
        func switched(to target: InputSourceIdentity?, method: String) -> CommandReply {
            var json: [String: Any] = ["ok": true, "switched": true, "method": method, "from": describe(from)]
            json["to"] = target.map(describe)
            return CommandReply(text: "\(from.id) → \(target?.id ?? "?")", json: json)
        }
        let pulse = engine.active ? nativeSwitchPulse(keyCode: engine.target.keyCode, marker: nativePulseMarker) : nil
        if spec.lowercased() == "toggle" {
            guard let pulse else { return .failure("gksdud가 꺼져 있어 한영 전환을 할 수 없습니다.") }
            let target = addedSourcesActive ? addedTarget(separateKey: false, from: from)
                : sourceHistory.previous(of: from.id).flatMap { id in enabled.first { $0.id == id } }
            rememberCapsBeforeSwitch(); switchHangul(pulse)
            return switched(to: target, method: "shortcut")
        }
        let target = try matchSource(spec)
        guard target.id != from.id else {
            return CommandReply(text: "\(target.id) (이미 선택됨)", json: ["ok": true, "switched": false, "from": describe(from), "to": describe(target)])
        }
        if let pulse {
            rememberCapsBeforeSwitch()
            switchSource(to: target, from: from, pulse: pulse)
            return switched(to: target, method: "shortcut")
        }
        guard let source = Self.sourceForID(target.id), TISSelectInputSource(source) == noErr else { return .failure("입력 소스를 전환하지 못했습니다.") }
        return switched(to: target, method: "select")
    }

    // MARK: Installing

    // In /usr/local/bin, which every shell has on its PATH, as a link into this app: updates keep it current.
    static let cliLink = "/usr/local/bin/gksdud"
    var cliTool: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gksdud").path }
    var cliLinked: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: Self.cliLink)) == cliTool }
    func refreshCLIButton() {
        installCLI.title = cliLinked ? "CLI 제거" : "CLI 설치"
        installCLI.toolTip = Self.cliLink
    }
    @objc func toggleCLI() {
        let files = FileManager.default, linked = cliLinked
        let destination = try? files.destinationOfSymbolicLink(atPath: Self.cliLink)
        // gksdud's own link is replaced, such as one to a moved app; another program's file of the same name stays.
        let ours = destination?.hasSuffix(".app/Contents/Helpers/gksdud") == true
        guard ours || destination == nil && !files.fileExists(atPath: Self.cliLink) else { showCLIError("\(Self.cliLink) 파일이 이미 있습니다."); return }
        guard linked || files.isExecutableFile(atPath: cliTool) else { showCLIError("CLI 파일을 찾지 못했습니다. gksdud를 다시 설치해주세요."); return }
        do {
            if ours { try files.removeItem(atPath: Self.cliLink) }
            if !linked { try files.createSymbolicLink(atPath: Self.cliLink, withDestinationPath: cliTool) }
            refreshCLIButton()
        } catch {
            func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            runAsAdministrator(linked ? "rm -f \(quoted(Self.cliLink))"
                : "mkdir -p /usr/local/bin && ln -sfn \(quoted(cliTool)) \(quoted(Self.cliLink))",
                prompt: linked ? "gksdud 명령을 제거합니다." : "gksdud 명령을 설치합니다.")
        }
    }
    // /usr/local/bin belongs to root, so macOS asks for an administrator, as other apps' command installers do. In its own
    // process: the tap keeps running on the main thread while the password is asked.
    func runAsAdministrator(_ command: String, prompt: String) {
        func literal(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(literal(command)) with prompt \(literal(prompt)) with administrator privileges"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        process.terminationHandler = { [weak self] process in
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.installCLI.isEnabled = true; self.refreshCLIButton()
                // The password prompt is osascript's, so macOS hands the focus to another app once it closes. The window
                // comes back in front even if activation is refused.
                if self.window.isVisible { self.window.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true) }
                // Cancelled at the password prompt (-128): nothing changed.
                if process.terminationStatus != 0 && !message.contains("-128") { self.showCLIError("CLI를 설치하지 못했습니다. \(message)") }
            }
        }
        installCLI.isEnabled = false
        do { try process.run() } catch { installCLI.isEnabled = true; showCLIError(error.localizedDescription) }
    }
    // Once, on the window; unlike a settings error it is not left in the status line.
    func showCLIError(_ message: String) {
        let alert = NSAlert(); alert.messageText = message
        alert.beginSheetModal(for: window)
    }
    @objc func openCLIHelp() { NSWorkspace.shared.open(URL(string: "https://github.com/codingnoye/gksdud/blob/main/docs/cli.md")!) }
}
