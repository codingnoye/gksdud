import AppKit

#if TESTS
private final class ManualTestEditor: CorrectionEditor {
    var text = "", caret = 0, reads = 0, writes = 0
    var focused = true, writable = true, capitalize = false
    var delay: ((@escaping () -> Void) -> Void)?
    func put(_ text: String) { self.text = text; caret = text.utf16.count }
    func snapshot() -> CorrectionSnapshot? {
        reads += 1
        guard focused else { return nil }
        let start = max(0, caret - 96)
        return .init(tail: (text as NSString).substring(with: NSRange(location: start, length: caret - start)), caret: caret)
    }
    func replace(_ expected: CorrectionSnapshot, suffix: String, with replacement: String) -> CorrectionSnapshot? {
        guard writable, snapshot() == expected, expected.tail.hasSuffix(suffix) else { return nil }
        let actual = capitalize ? replacement.prefix(1).uppercased() + replacement.dropFirst() : replacement
        text = (text as NSString).replacingCharacters(in: NSRange(location: caret - suffix.utf16.count, length: suffix.utf16.count), with: actual)
        caret += actual.utf16.count - suffix.utf16.count; writes += 1
        return snapshot()
    }
    func replace(_ expected: CorrectionSnapshot, suffix: String, with replacement: String,
                 valid: @escaping () -> Bool, completion: @escaping (CorrectionSnapshot?) -> Void) {
        let action = {
            guard valid() else { completion(nil); return }
            completion(self.replace(expected, suffix: suffix, with: replacement))
        }
        if let delay { delay(action) } else { action() }
    }
}

func runManualCorrectionTests() {
    for scalar in 0xAC00...0xD7A3 {
        let syllable = String(UnicodeScalar(scalar)!)
        featureCheck(HangulKeys.decode(HangulKeys.encode(syllable)!) == syllable, "Two-set round trip: \(syllable)")
    }
    for scalar in 0x3131...0x3163 {
        let jamo = String(UnicodeScalar(scalar)!)
        let keys = HangulKeys.encode(jamo)!
        // Standalone double-final jamo are typed as two consonants by a two-set IME.
        if keys.count == 1 || scalar >= 0x314F { featureCheck(HangulKeys.decode(keys) == jamo) }
    }
    for word in ["쫀득쿠키", "값이", "닭이", "읽어요", "앉아", "없어", "괜찮아", "왜요", "뿌엥", "우왕굳", "갔어", "깎아", "까꿍", "ㅋㅋㅋ", "ㅗ디ㅣㅐ"] {
        featureCheck(HangulKeys.decode(HangulKeys.encode(word)!) == word, "Dictionary-free composition: \(word)")
    }
    featureCheck(HangulKeys.decode("Dkssudgktpdy") == "안녕하세요", "Unshifted Korean keys tolerate sentence capitalization")
    featureCheck(HangulKeys.decode("hello") == "ㅗ디ㅣㅐ")
    featureCheck(HangulKeys.decode("rkrk") == "가가")
    featureCheck(HangulKeys.decode("rkqtk") == "갑사")
    featureCheck(HangulKeys.decode("hk") == "ㅘ")
    featureCheck(HangulKeys.decode("123") == nil)
    func plan(_ text: String, caret: Int? = nil) -> ManualCorrectionPlan? {
        .make(.init(tail: text, caret: caret ?? text.utf16.count))
    }
    featureCheck(plan("앞 문장 Whsemrznzl. ")?.replacement == "쫀득쿠키. ")
    featureCheck(plan("🙂 값이")?.replacement == "rkqtdl")
    featureCheck(plan("r")?.replacement == "ㄱ", "Single letters are intentional manual conversions")
    for (keys, hangul) in [("10qnsenldp", "10분뒤에"), ("1qns2ch", "1분2초"), ("qns10", "분10"), ("0rk0sk0", "0가0나0")] {
        featureCheck(plan(keys)?.replacement == hangul, "Preserve leading, internal and trailing digits")
        featureCheck(plan(hangul)?.replacement == keys, "Digit-preserving reverse conversion")
    }
    featureCheck(plan("앞 문장 10qnsenldp. ")?.replacement == "10분뒤에. ")
    for word in ["", "   ", "123", "한abc", "한1abc", "https://hello", "email@hello", "가\n", String(repeating: "a", count: 65), String(repeating: "값", count: 32)] {
        featureCheck(plan(word) == nil, "Leave mixed tokens and overlong text unchanged")
    }
    featureCheck(plan("hello", caret: 100) == nil, "Do not convert a truncated long token")
    featureCheck(plan(" hello", caret: 100)?.replacement == "ㅗ디ㅣㅐ")

    for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea", "AXUnknown"] {
        featureCheck(!CorrectionFieldPolicy.isProtected(role: role, subrole: nil), "General fields are eligible regardless of role")
        featureCheck(CorrectionFieldPolicy.isProtected(role: role, subrole: "AXSecureTextField"), "Secure subrole always wins")
    }
    featureCheck(CorrectionFieldPolicy.isProtected(role: "AXPasswordField", subrole: nil))
    featureCheck(CorrectionFieldPolicy.isTerminalInputProxy(domClasses: ["xterm-helper-textarea"]))
    featureCheck(!CorrectionFieldPolicy.isTerminalInputProxy(domClasses: ["textarea", "xterm-helper-textarea-copy"]), "Ordinary web fields never receive terminal deletion keys")
    let terminalBoundary = TerminalInputBoundary(caret: 12, line: 3)
    featureCheck(TerminalCorrectionTracker.wordStartKeys.contains(18) && TerminalCorrectionTracker.wordStartKeys.contains(83), "Capture terminal boundary before a leading digit on either keyboard row")
    featureCheck(terminalBoundary.permits(.init(tail: "gksdud-test> 10qnsenldp", caret: 22), suffix: "10qnsenldp", line: 3))
    featureCheck(terminalBoundary.permits(.init(tail: "gksdud-test> Whsemrznzl", caret: 22), suffix: "Whsemrznzl", line: 3))
    featureCheck(!terminalBoundary.permits(.init(tail: "Password: ", caret: 12), suffix: "Password: ", line: 3), "No-echo password input never advances the visible cursor")
    featureCheck(!terminalBoundary.permits(.init(tail: "promptword", caret: 15), suffix: "promptword", line: 3), "Never erase text before typing began")
    featureCheck(!terminalBoundary.permits(.init(tail: "Whsemrznzl", caret: 22), suffix: "Whsemrznzl", line: 4), "Changed terminal output line cancels conversion")
    let terminalEvents = TerminalCorrectionEditor.events(suffix: "쫀득쿠키. ", replacement: "Whsemrznzl. ", marker: 909)!
    featureCheck(terminalEvents.count == (6 + 12) * 2, "Terminal erases committed characters, not Hangul keystrokes or UTF-8 bytes")
    featureCheck(terminalEvents.prefix(12).allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 51 && $0.flags.isEmpty })
    featureCheck(terminalEvents.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 909 })
    featureCheck(TerminalCorrectionEditor.events(suffix: "hello\n", replacement: "x", marker: 909) == nil, "Never emit Enter into a terminal")
    for value in ["쫀득쿠키", "hello", String(repeating: "가", count: 64) + ". "] {
        let events = AccessibilityCorrectionEditor.insertionEvents(value, marker: 909)!
        featureCheck(events.count == 2 && events[0].type == .keyDown && events[1].type == .keyUp)
        for event in events {
            var count = 0, characters = [UniChar](repeating: 0, count: 96)
            event.keyboardGetUnicodeString(maxStringLength: 96, actualStringLength: &count, unicodeString: &characters)
            featureCheck(String(utf16CodeUnits: characters, count: count) == value && event.flags.isEmpty)
            featureCheck(event.getIntegerValueField(.eventSourceUserData) == 909)
        }
    }

    let english = "com.apple.keylayout.ABC", korean = "com.apple.inputmethod.Korean.2SetKorean"
    var context: CorrectionContext? = .init(pid: 42, sourceID: english)
    var shortcut = ManualCorrectionShortcut.shiftBackspace
    var secure = false, enabled = true, canSelect = true, hasDestination = true, hasEditor = true
    var jobs: [() -> Void] = [], changes: [String] = [], reports: [String] = []
    let editor = ManualTestEditor()
    let controller = ManualCorrectionController(environment: .init(context: { context }, secure: { secure },
        editor: { _ in hasEditor ? editor : nil }, destination: { hasDestination ? ($0 == .korean ? korean : english) : nil },
        select: { id in
            guard canSelect, let old = context else { return false }
            context = .init(pid: old.pid, sourceID: id); changes.append(id); return true
        }, later: { _, job in jobs.append(job) }))
    controller.report = { reports.append($0) }
    @discardableResult func key(_ code: Int64 = 51, flags: CGEventFlags = .maskShift, down: Bool = true, repeated: Bool = false, marker: Int64 = 0) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return controller.handle(event, enabled: enabled, marker: 909, shortcut: shortcut)
    }
    func press() { featureCheck(key()); featureCheck(key(flags: [], down: false)) }
    func drain() { let pending = jobs; jobs.removeAll(); pending.forEach { $0() } }
    func reset(_ value: String = "Whsemrznzl", source: String? = nil) {
        controller.reset(); jobs.removeAll(); changes.removeAll(); reports.removeAll()
        editor.put(value); editor.focused = true; editor.writable = true; editor.capitalize = false; editor.reads = 0; editor.writes = 0; editor.delay = nil
        context = .init(pid: 42, sourceID: source ?? english)
        shortcut = .shiftBackspace
        secure = false; enabled = true; canSelect = true; hasDestination = true; hasEditor = true
    }
    reset(); press(); drain()
    featureCheck(editor.text == "쫀득쿠키" && context?.sourceID == korean)
    controller.sourceChanged(); press(); drain()
    featureCheck(editor.text == "Whsemrznzl" && context?.sourceID == english, "Second shortcut restores exact spelling and case")
    reset("10qnsenldp"); press(); drain()
    featureCheck(editor.text == "10분뒤에" && context?.sourceID == korean)
    press(); drain()
    featureCheck(editor.text == "10qnsenldp" && context?.sourceID == english, "Undo preserves digits and original input source")

    reset("ㅗ디ㅣㅐ", source: korean); editor.capitalize = true; press(); drain()
    featureCheck(editor.writes == 0 && context?.sourceID == english && jobs.count == 1, "Commit IME before reading the final syllable")
    controller.sourceChanged(); drain()
    featureCheck(editor.text == "Hello" && context?.sourceID == english)
    editor.capitalize = false; press(); drain()
    featureCheck(editor.text == "ㅗ디ㅣㅐ" && context?.sourceID == korean, "Undo follows actual app capitalization")

    reset(); for _ in 0..<1000 { featureCheck(!key(0, flags: [])) }
    featureCheck(editor.reads == 0 && jobs.isEmpty, "No editor reads during ordinary typing")
    editor.put("dkssudgktpdy "); key(49, flags: []); drain()
    featureCheck(editor.reads == 0 && editor.writes == 0 && editor.text == "dkssudgktpdy ", "Space never triggers automatic correction")
    reset(); press(); key(0, flags: []); drain()
    featureCheck(editor.writes == 0 && changes.isEmpty, "Further typing cancels a queued shortcut")
    reset("값이", source: korean); press(); drain(); key(0, flags: []); drain()
    featureCheck(editor.writes == 0 && context?.sourceID == korean, "Cancel IME commit and restore original source")
    reset("값이", source: korean); press(); drain(); context = .init(pid: 43, sourceID: english); drain()
    featureCheck(editor.writes == 0 && context?.pid == 43 && changes == [english], "Never restore input source in a different app")
    reset("값이", source: korean); press(); drain(); editor.focused = false; drain()
    featureCheck(editor.writes == 0 && context?.sourceID == korean, "Changed control cancels writes")
    reset(); press(); editor.focused = false; drain(); featureCheck(editor.writes == 0 && changes.isEmpty)
    reset(); press(); context = .init(pid: 42, sourceID: "unsupported"); drain(); featureCheck(editor.writes == 0)
    reset(); secure = true; featureCheck(!key()); featureCheck(jobs.isEmpty && editor.reads == 0)
    reset(); enabled = false; featureCheck(!key()); featureCheck(jobs.isEmpty)
    reset(); featureCheck(!key(flags: [.maskAlternate, .maskCommand])); featureCheck(jobs.isEmpty)
    reset(); featureCheck(!key(flags: [.maskAlternate, .maskShift])); featureCheck(jobs.isEmpty)
    reset(); context = nil; featureCheck(!key()); featureCheck(jobs.isEmpty, "Missing focus retains the native shortcut")
    reset(); featureCheck(!key(51, flags: [])); featureCheck(jobs.isEmpty, "Plain Backspace remains native")
    reset(); shortcut = .optionSpace; featureCheck(key(49, flags: .maskAlternate)); featureCheck(key(49, flags: [], down: false)); drain()
    featureCheck(editor.text == "쫀득쿠키", "Alternate shortcut remains available")
    reset(); featureCheck(!key(marker: 909)); featureCheck(jobs.isEmpty)
    reset(); featureCheck(key()); featureCheck(key(repeated: true)); featureCheck(jobs.count == 1)
    controller.reset(); featureCheck(key(flags: [], down: false), "Consume owned release after focus reset"); drain(); featureCheck(editor.writes == 0)
    reset(); key(); controller.reset(); press(); drain()
    featureCheck(editor.text == "쫀득쿠키", "Fresh press recovers a key-up lost during sleep")
    reset(); canSelect = false; press(); drain()
    featureCheck(editor.text == "쫀득쿠키" && context?.sourceID == english)
    press(); drain(); featureCheck(editor.text == "Whsemrznzl", "Undo still works when source switching fails")
    reset("값이", source: korean); canSelect = false; press(); drain(); featureCheck(editor.writes == 0 && jobs.isEmpty)
    reset(); hasDestination = false; press(); drain(); featureCheck(editor.writes == 0 && changes.isEmpty)
    reset(); hasEditor = false; press(); drain(); featureCheck(editor.writes == 0 && changes.isEmpty)
    reset(); editor.writable = false; press(); drain(); featureCheck(editor.writes == 0 && changes.isEmpty)
    reset("값이", source: korean); editor.writable = false; press(); drain(); drain()
    featureCheck(editor.writes == 0 && context?.sourceID == korean)
    reset(String(repeating: "🙂 ", count: 100) + "Whsemrznzl! "); press(); drain()
    featureCheck(editor.text.hasSuffix("쫀득쿠키! "))
    press(); drain(); featureCheck(editor.text == String(repeating: "🙂 ", count: 100) + "Whsemrznzl! ")
    reset(); press(); drain(); key(0, flags: []); editor.put("쫀득쿠키가"); press(); drain(); drain()
    featureCheck(editor.text == "Whsemrznzlrk", "Typing clears exact undo; next shortcut converts the current word")
    reset(); editor.delay = { jobs.append($0) }; press(); drain()
    featureCheck(editor.writes == 0 && context?.sourceID == english)
    drain(); featureCheck(editor.text == "쫀득쿠키" && context?.sourceID == korean)
    press(); drain(); drain(); featureCheck(editor.text == "Whsemrznzl" && context?.sourceID == english, "Deferred insertion and undo")
    reset(); editor.delay = { jobs.append($0) }; press(); drain(); key(0, flags: []); drain()
    featureCheck(editor.writes == 0 && changes.isEmpty, "Typing cancels an asynchronous write")
    reset(); editor.delay = { jobs.append($0) }; press(); drain(); secure = true; drain()
    featureCheck(editor.writes == 0 && changes.isEmpty, "Secure input cancels an asynchronous write")
    print("PASS: all 11,172 syllables, dictionary-free two-set composition, manual shortcut/undo, IME commit, focus and typing cancellation, no idle reads")
}

func runCorrectionEditorTests() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 440, height: 240),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "gksdud 입력창 검증"
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    defer { window.orderOut(nil) }
    for field in [NSTextField(), NSSearchField(), NSComboBox(), NSSecureTextField()] {
        field.frame = NSRect(x: 20, y: 130, width: 380, height: 28)
        field.stringValue = "Whsemrznzl"
        window.contentView!.addSubview(field)
        window.makeFirstResponder(field)
        guard let view = field.currentEditor() as? NSTextView else { fatalError("Missing native field editor") }
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        let editor = LocalCorrectionEditor(view)
        if field is NSSecureTextField {
            featureCheck(editor.snapshot() == nil, "Native password field must be rejected before reading")
        } else {
            let before = editor.snapshot()!
            featureCheck(editor.replace(before, suffix: "Whsemrznzl", with: "쫀득쿠키")?.tail == "쫀득쿠키", "Native single-line/search/combo conversion")
            let after = editor.snapshot()!
            featureCheck(editor.replace(after, suffix: "쫀득쿠키", with: "Whsemrznzl")?.tail == "Whsemrznzl", "Native field undo")
            view.setSelectedRange(NSRange(location: 0, length: 1))
            featureCheck(editor.snapshot() == nil, "Selected text remains unchanged")
        }
        window.makeFirstResponder(nil); field.removeFromSuperview()
    }
    let text = NSTextView(frame: NSRect(x: 20, y: 20, width: 380, height: 180))
    text.string = "앞 문장\nWhsemrznzl"
    window.contentView!.addSubview(text); window.makeFirstResponder(text)
    text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
    let editor = LocalCorrectionEditor(text), before = LocalCorrectionEditor(text).snapshot()!
    featureCheck(editor.replace(before, suffix: "Whsemrznzl", with: "쫀득쿠키")?.tail == "앞 문장\n쫀득쿠키")
    text.isEditable = false
    featureCheck(editor.snapshot() == nil, "Read-only controls stay unchanged")
    print("PASS: native text field, search field, combo box, multiline field, password exclusion, selection/read-only protection")
}

#endif
