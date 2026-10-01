import AppKit
import Carbon

// xterm's hidden textarea is an IME transport, not the terminal input line.
// Its contents may be cleared after each insertion. Keep a logical result only
// for the controller's immediate undo, witnessed by the unchanged proxy/focus.
final class TerminalInputProxyEditor: CorrectionEditor {
    let access: AccessibilityCorrectionEditor
    var providesTextReadback: Bool { false }
    private var result: (witness: CorrectionSnapshot, logical: CorrectionSnapshot)?
    private var failed = false
    init(access: AccessibilityCorrectionEditor) { self.access = access }
    func snapshot() -> CorrectionSnapshot? {
        guard !failed, access.isTerminalInputProxy, let actual = access.snapshot() else { return nil }
        if let result { return actual == result.witness ? result.logical : nil }
        return actual
    }
    func replace(_ expected: CorrectionSnapshot, suffix: String, with replacement: String) -> CorrectionSnapshot? { nil }
    func replace(_ expected: CorrectionSnapshot, suffix: String, with replacement: String,
                 valid: @escaping () -> Bool, completion: @escaping (CorrectionSnapshot?) -> Void) {
        guard valid(), snapshot() == expected, expected.tail.hasSuffix(suffix),
              expected.caret >= suffix.utf16.count, let actual = access.snapshot(),
              CGPreflightPostEventAccess(),
              let deletes = TerminalCorrectionEditor.deletionEvents(suffix, marker: access.marker),
              let inserts = AccessibilityCorrectionEditor.insertionEvents(replacement, marker: access.marker),
              !replacement.contains(where: { $0.isNewline }) else { completion(nil); return }
        let range: CFRange
        if result == nil {
            range = CFRange(location: actual.caret - suffix.utf16.count, length: suffix.utf16.count)
        } else {
            // A cleared proxy has no editable copy of the PTY word. If it kept
            // one, select it so the proxy cannot accumulate stale originals.
            guard actual.tail.isEmpty || actual.tail.hasSuffix(suffix) else { completion(nil); return }
            range = actual.tail.isEmpty ? CFRange(location: 0, length: 0)
                : CFRange(location: actual.caret - suffix.utf16.count, length: suffix.utf16.count)
        }
        // xterm consumes Backspace in keydown, independently of DOM selection.
        // Send this batch exactly once. Only the result observation may retry.
        failed = true
        for event in deletes { event.postToPid(access.pid) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            guard valid(), self.access.snapshot() == actual, self.access.select(range) else { completion(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                guard valid(), self.access.focused(), self.access.sameSelection(range) else { completion(nil); return }
                for event in inserts { event.postToPid(self.access.pid) }
                func observe(_ attempt: Int) {
                    guard valid(), self.access.focused() else { completion(nil); return }
                    if let witness = self.access.snapshot(), witness.tail.isEmpty ||
                        (witness.caret == range.location + replacement.utf16.count && witness.tail.hasSuffix(replacement)) {
                        let logical = CorrectionSnapshot(tail: replacement,
                            caret: expected.caret - suffix.utf16.count + replacement.utf16.count)
                        self.result = (witness, logical); self.failed = false
                        completion(logical); return
                    }
                    guard attempt < 3 else { completion(nil); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { observe(attempt + 1) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { observe(0) }
            }
        }
    }
}

// A terminal selection is a selection of screen output, not an editable range.
// Remember only the starting cursor/prompt when input begins. No key history,
// clipboard access, polling, or automatic conversion is needed.
struct TerminalInputBoundary {
    let caret: Int
    let line: Int
    func permits(_ snapshot: CorrectionSnapshot, suffix: String, line: Int) -> Bool {
        line == self.line && !suffix.isEmpty && snapshot.tail.hasSuffix(suffix)
            && snapshot.caret - suffix.utf16.count >= caret
            && snapshot.caret > caret
    }
}

final class TerminalCorrectionEditor: CorrectionEditor {
    let access: AccessibilityCorrectionEditor
    let boundary: TerminalInputBoundary
    let prefix: String
    let prefixRange: CFRange

    init?(pid: pid_t, marker: Int64) {
        guard let access = AccessibilityCorrectionEditor(pid: pid, marker: marker, terminal: true),
              !access.canReplace, !AccessibilityCorrectionEditor.editable(access.element),
              AccessibilityCorrectionEditor.attribute(access.element, kAXRoleAttribute) as? String == kAXTextAreaRole,
              let line = Self.line(access), let before = access.snapshot() else { return nil }
        self.access = access
        boundary = TerminalInputBoundary(caret: before.caret, line: line)
        prefix = String(before.tail.suffix(16))
        prefixRange = CFRange(location: before.caret - prefix.utf16.count, length: prefix.utf16.count)
    }
    static func line(_ access: AccessibilityCorrectionEditor) -> Int? {
        guard let value = AccessibilityCorrectionEditor.attribute(access.element, kAXInsertionPointLineNumberAttribute) as? NSNumber,
              value.intValue >= 0, value.intValue < Int.max else { return nil }
        return value.intValue
    }
    func snapshot() -> CorrectionSnapshot? {
        guard Self.line(access) == boundary.line,
              access.string(prefixRange) == prefix,
              let snapshot = access.snapshot(), snapshot.caret >= boundary.caret else { return nil }
        return snapshot
    }
    func replace(_ expected: CorrectionSnapshot, suffix: String, with replacement: String) -> CorrectionSnapshot? { nil }
    func replace(_ expected: CorrectionSnapshot, suffix: String, with replacement: String,
                 valid: @escaping () -> Bool, completion: @escaping (CorrectionSnapshot?) -> Void) {
        guard valid(), snapshot() == expected, let line = Self.line(access),
              boundary.permits(expected, suffix: suffix, line: line),
              CGPreflightPostEventAccess(),
              let events = Self.events(suffix: suffix, replacement: replacement, marker: access.marker) else { completion(nil); return }
        // The IME has already been committed by the controller. Erase only the
        // visible suffix entered after our cursor anchor, never a shell prompt
        // or a password entered with terminal echo disabled.
        for event in events { event.postToPid(access.pid) }
        func verify(_ attempt: Int) {
            guard valid(), self.access.focused() else { completion(nil); return }
            if let after = self.snapshot(), CorrectionReadback.inserted(before: expected, after: after,
                original: suffix, requested: replacement) != nil { completion(after); return }
            guard attempt < 4 else { completion(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { verify(attempt + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { verify(0) }
    }
    static func events(suffix: String, replacement: String, marker: Int64) -> [CGEvent]? {
        guard !replacement.isEmpty, replacement.utf16.count <= 72, !replacement.contains(where: { $0.isNewline }),
              var events = deletionEvents(suffix, marker: marker) else { return nil }
        // Some terminal emulators only consume one character per key event.
        for character in replacement {
            guard let pair = AccessibilityCorrectionEditor.insertionEvents(String(character), marker: marker) else { return nil }
            events += pair
        }
        return events
    }
    static func deletionEvents(_ suffix: String, marker: Int64) -> [CGEvent]? {
        guard !suffix.isEmpty, suffix.utf16.count <= 72, !suffix.contains(where: { $0.isNewline }) else { return nil }
        var events: [CGEvent] = []
        for _ in suffix {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: down) else { return nil }
                event.flags = []; event.setIntegerValueField(.eventSourceUserData, value: marker)
                events.append(event)
            }
        }
        return events
    }
}

final class TerminalCorrectionTracker {
    private var pid: pid_t?
    private var current: TerminalCorrectionEditor?
    static let bundleIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "org.wezfurlong.wezterm", "dev.warp.Warp-Stable"]
    // Physical alphabet keys for ABC and macOS two-set Korean.
    static let letters: Set<Int64> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40, 45, 46]
    static let wordStartKeys = letters.union([18, 19, 20, 21, 22, 23, 25, 26, 28, 29, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92])
    func reset() { current = nil }
    func frontmostChanged() {
        reset()
        let app = NSWorkspace.shared.frontmostApplication
        pid = app.flatMap { Self.bundleIDs.contains($0.bundleIdentifier ?? "") ? $0.processIdentifier : nil }
    }
    func editor(for pid: pid_t) -> CorrectionEditor? { self.pid == pid ? current : nil }
    func observe(_ event: CGEvent, enabled: Bool, marker: Int64) {
        guard event.getIntegerValueField(.eventSourceUserData) != marker else { return }
        guard enabled, let pid, !IsSecureEventInputEnabled() else { reset(); return }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { reset(); return }
        guard event.type == .keyDown else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn])
        if modifiers == .maskCommand && code == 9 {
            // Capture the cursor before a user-initiated paste, without reading
            // or replacing the clipboard.
            current = TerminalCorrectionEditor(pid: pid, marker: marker); return
        }
        guard modifiers.isEmpty else { reset(); return }
        if Self.wordStartKeys.contains(code) {
            if current == nil { current = TerminalCorrectionEditor(pid: pid, marker: marker) }
            return
        }
        if [36, 48, 53, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(code) || (64...90).contains(code) {
            reset(); return
        }
    }
}
