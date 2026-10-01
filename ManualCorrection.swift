import AppKit

enum ManualCorrectionShortcut: String, CaseIterable {
    case shiftBackspace, optionSpace
    var title: String { self == .shiftBackspace ? "⇧ Backspace" : "⌥ Space" }
    var keyCode: Int64 { self == .shiftBackspace ? 51 : 49 }
    var modifiers: CGEventFlags { self == .shiftBackspace ? .maskShift : .maskAlternate }
}

extension HangulKeys {
    // Two-set composition, including compound vowels and splitting a final
    // consonant before the next vowel. No dictionary or language detector.
    static func decode(_ keys: String) -> String? {
        guard !keys.isEmpty, keys.utf16.count <= 64 else { return nil }
        var result = "", initial: Int?, vowel: Int?, final = 0
        func flush() {
            if let l = initial, let v = vowel {
                result.unicodeScalars.append(UnicodeScalar(0xAC00 + l * 588 + v * 28 + final)!)
            } else if let l = initial {
                result.unicodeScalars.append(UnicodeScalar(0x3131 + consonants.firstIndex(of: initials[l])!)!)
            } else if let v = vowel {
                result.unicodeScalars.append(UnicodeScalar(0x314F + v)!)
            }
            initial = nil; vowel = nil; final = 0
        }
        for scalar in keys.unicodeScalars {
            guard (65...90).contains(scalar.value) || (97...122).contains(scalar.value) else { return nil }
            let raw = String(scalar)
            let key = ["R", "E", "Q", "T", "W", "O", "P"].contains(raw) ? raw : raw.lowercased()
            if let v = vowels.firstIndex(of: key) {
                if vowel == nil { vowel = v; continue }
                if final != 0 {
                    let oldFinal = finals[final]
                    let next = String(oldFinal.suffix(1))
                    final = oldFinal.count == 2 ? finals.firstIndex(of: String(oldFinal.prefix(1)))! : 0
                    flush(); initial = initials.firstIndex(of: next); vowel = v
                } else if let merged = vowels.firstIndex(of: vowels[vowel!] + key) {
                    vowel = merged
                } else { flush(); vowel = v }
            } else if let l = initials.firstIndex(of: key) {
                if initial != nil && vowel != nil, let t = finals.firstIndex(of: finals[final] + key) {
                    final = t
                } else { flush(); initial = l }
            }
        }
        flush()
        return result
    }
}

struct ManualCorrectionPlan {
    let original: String
    let replacement: String
    let language: CorrectionLanguage

    static func make(_ snapshot: CorrectionSnapshot) -> Self? {
        // Keep a few spaces and sentence punctuation after the word, but never
        // cross a newline or convert a truncated suffix of a long token.
        let trailing = snapshot.tail.reversed().prefix { " \t.,!?;:)]}\"'…".contains($0) }
        guard trailing.count <= 8 else { return nil }
        let ending = String(trailing.reversed())
        let body = snapshot.tail.dropLast(trailing.count)
        let word = String(body.reversed().prefix { !$0.isWhitespace }.reversed())
        guard !word.isEmpty, word.utf16.count <= 64,
              word.count < body.count || snapshot.caret == snapshot.tail.utf16.count else { return nil }
        let scalars = word.unicodeScalars.filter { !(48...57).contains($0.value) }
        guard !scalars.isEmpty else { return nil }
        let latin = scalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
        let converted = preservingDigits(word, transform: latin ? HangulKeys.decode : HangulKeys.encode)
        guard let converted, converted.utf16.count <= 64 else { return nil }
        return Self(original: word + ending, replacement: converted + ending, language: latin ? .korean : .english)
    }
    private static func preservingDigits(_ word: String, transform: (String) -> String?) -> String? {
        var result = "", run = ""
        for character in word {
            if let ascii = character.asciiValue, (48...57).contains(ascii) {
                if !run.isEmpty {
                    guard let converted = transform(run) else { return nil }
                    result += converted; run = ""
                }
                result.append(character)
            } else { run.append(character) }
        }
        if !run.isEmpty {
            guard let converted = transform(run) else { return nil }
            result += converted
        }
        return result
    }
}

final class ManualCorrectionController {
    struct Environment {
        var context: () -> CorrectionContext?
        var secure: () -> Bool
        var editor: (pid_t) -> CorrectionEditor?
        var destination: (CorrectionLanguage) -> String?
        var select: (String) -> Bool
        var later: (TimeInterval, @escaping () -> Void) -> Void
    }
    private struct Undo {
        let editor: CorrectionEditor
        let snapshot: CorrectionSnapshot
        let original: String
        let replacement: String
        let originalContext: CorrectionContext
        let currentContext: CorrectionContext
    }
    let environment: Environment
    var report: (String) -> Void = { _ in }
    private var generation = 0
    private var heldKey: Int64?
    private var shortcutTitle = ManualCorrectionShortcut.shiftBackspace.title
    private var undo: Undo?
    private var pendingRestore: (original: CorrectionContext, temporary: CorrectionContext)?

    init(environment: Environment) { self.environment = environment }
    func reset() {
        generation += 1; undo = nil
        restoreSource()
        // Keep ownership until the physical key-up, even if focus changes.
    }
    private func restoreSource() {
        guard let pending = pendingRestore else { return }
        pendingRestore = nil
        if !environment.secure(), environment.context() == pending.temporary {
            _ = environment.select(pending.original.sourceID)
        }
    }
    func sourceChanged() {
        guard pendingRestore == nil else { return }
        if let undo, environment.context() != undo.currentContext { self.undo = nil }
    }
    // Only the explicit shortcut reads the focused editor. Ordinary typing does
    // not retain text or perform accessibility queries.
    func handle(_ event: CGEvent, enabled: Bool, marker: Int64, shortcut: ManualCorrectionShortcut = .shiftBackspace) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == marker { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if event.type == .keyUp, code == heldKey { heldKey = nil; return true }
        if event.type == .keyDown, code == heldKey {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
            heldKey = nil
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { reset(); return false }
        guard event.type == .keyDown else { return false }
        let modifiers = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift, .maskSecondaryFn])
        guard enabled, code == shortcut.keyCode, modifiers == shortcut.modifiers, !environment.secure(),
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { reset(); return false }
        guard let context = environment.context(), context.language != nil else { reset(); return false }
        heldKey = code; shortcutTitle = shortcut.title
        restoreSource()
        generation += 1
        let token = generation
        environment.later(0) { [weak self] in self?.begin(token, requestedContext: context) }
        return true
    }
    private func valid(_ token: Int, _ context: CorrectionContext) -> Bool {
        token == generation && !environment.secure() && environment.context() == context
    }
    private func begin(_ token: Int, requestedContext: CorrectionContext?) {
        guard token == generation else { return }
        guard !environment.secure(), let context = requestedContext, context.language != nil,
              environment.context() == context else {
            report("현재 앱 또는 입력 언어에서는 바로잡기를 사용할 수 없습니다."); return
        }
        if let previous = undo, previous.currentContext == context, previous.editor.snapshot() == previous.snapshot {
            undo = nil
            previous.editor.replace(previous.snapshot, suffix: previous.replacement, with: previous.original,
                valid: { [weak self] in self?.valid(token, context) == true }) { [weak self] after in
                guard let self, self.valid(token, context) else { return }
                guard let after, CorrectionReadback.inserted(before: previous.snapshot, after: after,
                    original: previous.replacement, requested: previous.original) != nil else {
                    self.report("원문을 복원하거나 확인하지 못했습니다."); return
                }
                let selected = self.environment.select(previous.originalContext.sourceID)
                let action = previous.editor.providesTextReadback ? "원문을 복원했습니다." : "터미널에 원문 복원 키를 전달했습니다."
                self.report(selected ? "\(action) 입력 언어도 복원했습니다." : "\(action) 입력 언어는 직접 전환해주세요.")
            }
            return
        }
        undo = nil
        guard let editor = environment.editor(context.pid), editor.snapshot() != nil else {
            report("편집 가능한 입력창에서 사용해주세요. 선택 영역은 해제해주세요."); return
        }
        // Changing away from the Korean IME commits the final composing syllable.
        // Delay the read, not a guessed backspace or a clipboard replacement.
        if context.language == .korean {
            guard let english = environment.destination(.english) else { report("영문 입력 소스를 켜주세요."); return }
            let temporary = CorrectionContext(pid: context.pid, sourceID: english)
            pendingRestore = (context, temporary)
            guard environment.select(english) else { pendingRestore = nil; report("한글 입력을 확정하지 못했습니다."); return }
            environment.later(0.04) { [weak self] in self?.convert(editor, original: context, current: temporary, token: token) }
        } else { convert(editor, original: context, current: context, token: token) }
    }
    private func convert(_ editor: CorrectionEditor, original: CorrectionContext, current: CorrectionContext, token: Int) {
        guard token == generation else { return }
        guard valid(token, current) else { restoreSource(); return }
        guard let snapshot = editor.snapshot(), let plan = ManualCorrectionPlan.make(snapshot) else {
            restoreSource(); report("커서 앞의 한글 또는 영문 단어를 확인하지 못했습니다. 단어 끝에서 눌러주세요."); return
        }
        guard let destination = environment.destination(plan.language) else {
            restoreSource(); report("변환할 입력 언어를 macOS 입력 소스에서 켜주세요."); return
        }
        guard valid(token, current) else { restoreSource(); return }
        editor.replace(snapshot, suffix: plan.original, with: plan.replacement,
            valid: { [weak self] in self?.valid(token, current) == true }) { [weak self] after in
            guard let self, self.valid(token, current) else { return }
            guard let after, let inserted = CorrectionReadback.inserted(before: snapshot, after: after,
                original: plan.original, requested: plan.replacement) else {
                self.restoreSource(); self.report("입력창에서 바로잡기를 적용하거나 확인하지 못했습니다."); return
            }
            self.pendingRestore = nil
            let selected = self.environment.select(destination)
            self.undo = Undo(editor: editor, snapshot: after, original: plan.original, replacement: inserted,
                        originalContext: original, currentContext: .init(pid: current.pid, sourceID: selected ? destination : current.sourceID))
            let action = editor.providesTextReadback ? "바로잡았습니다." : "터미널에 바로잡기 키를 전달했습니다."
            self.report(selected ? "\(action) 다른 입력 없이 \(self.shortcutTitle)을 다시 누르면 원문으로 돌아갑니다." : "\(action) 입력 언어는 직접 전환해주세요.")
        }
    }
}

enum CorrectionReadback {
    static func accepts(_ actual: String, requested: String) -> Bool {
        // NSTextView may capitalize the first ASCII letter while inserting.
        actual == requested || (requested.first.map { ("a"..."z").contains(String($0)) } == true
            && actual == requested.prefix(1).uppercased() + requested.dropFirst())
    }
    static func inserted(before: CorrectionSnapshot, after: CorrectionSnapshot, original: String, requested: String) -> String? {
        guard after.caret == before.caret - original.utf16.count + requested.utf16.count,
              after.tail.utf16.count >= requested.utf16.count else { return nil }
        let text = after.tail as NSString
        let actual = text.substring(from: text.length - requested.utf16.count)
        return accepts(actual, requested: requested) ? actual : nil
    }
}
