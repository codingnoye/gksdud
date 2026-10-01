import AppKit
import Carbon

final class LocalCorrectionEditor: CorrectionEditor {
    weak var view: NSTextView?
    init(_ view: NSTextView) { self.view = view }
    var protected: Bool {
        guard let view else { return true }
        return view.delegate is NSSecureTextField || view.delegate is NSSecureTextFieldCell
            || CorrectionFieldPolicy.isProtected(role: view.accessibilityRole()?.rawValue,
                                                  subrole: view.accessibilitySubrole()?.rawValue)
    }
    func snapshot() -> CorrectionSnapshot? {
        guard let view, view.window?.firstResponder === view, view.isEditable,
              !protected, !IsSecureEventInputEnabled() else { return nil }
        let range = view.selectedRange(), text = view.string as NSString
        guard range.length == 0, range.location <= text.length else { return nil }
        let start = max(0, range.location - 96)
        return CorrectionSnapshot(tail: text.substring(with: NSRange(location: start, length: range.location - start)), caret: range.location)
    }
    func replace(_ expected: CorrectionSnapshot, suffix: String, with replacement: String) -> CorrectionSnapshot? {
        guard let view, !view.hasMarkedText(), snapshot() == expected, expected.tail.hasSuffix(suffix), expected.caret >= suffix.utf16.count else { return nil }
        let range = NSRange(location: expected.caret - suffix.utf16.count, length: suffix.utf16.count)
        view.insertText(replacement, replacementRange: range)
        return snapshot()
    }
}

enum CorrectionFieldPolicy {
    static func isProtected(role: String?, subrole: String?) -> Bool {
        [role, subrole].compactMap { $0?.lowercased() }.contains { $0.contains("secure") || $0.contains("password") }
    }
    static func isTerminalInputProxy(domClasses: [String]) -> Bool {
        domClasses.contains("xterm-helper-textarea")
    }
}

// No app-name or text-role allowlist. Capability checks keep labels/read-only
// controls unchanged. Never overwrite an entire AXValue or touch the clipboard.
final class AccessibilityCorrectionEditor: CorrectionEditor {
    let pid: pid_t
    let app: AXUIElement
    let element: AXUIElement
    let marker: Int64
    let canReplace: Bool
    let isTerminalInputProxy: Bool
    init?(pid: pid_t, marker: Int64 = 0, terminal: Bool = false) {
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.025)
        guard let focused = Self.attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.025)
        guard !Self.protected(element) else { return nil }
        let canReplace = Self.settable(element, kAXSelectedTextAttribute)
        guard Self.settable(element, kAXSelectedTextRangeAttribute),
              canReplace || Self.editable(element) || (terminal && Self.attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole) else { return nil }
        self.pid = pid; self.app = app; self.element = element; self.marker = marker; self.canReplace = canReplace
        isTerminalInputProxy = CorrectionFieldPolicy.isTerminalInputProxy(
            domClasses: Self.attribute(element, "AXDOMClassList") as? [String] ?? [])
    }
    static func protected(_ element: AXUIElement) -> Bool {
        CorrectionFieldPolicy.isProtected(role: attribute(element, kAXRoleAttribute) as? String,
                                          subrole: attribute(element, kAXSubroleAttribute) as? String)
    }
    static func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var result: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }
    static func editable(_ element: AXUIElement) -> Bool {
        if let editable = attribute(element, kAXIsEditableAttribute) as? Bool { return editable }
        let role = attribute(element, kAXRoleAttribute) as? String
        return [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role ?? "") && settable(element, kAXValueAttribute)
    }
    static func focusedInputIsSecure() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.025)
        guard let raw = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.025)
        return protected(element)
    }
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    func focused() -> Bool {
        guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focus = Self.attribute(app, kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focus, element) && !Self.protected(element)
    }
    func selection() -> CFRange? {
        guard let raw = Self.attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }
    func string(_ range: CFRange) -> String? {
        guard focused(), range.location >= 0, (0...96).contains(range.length) else { return nil }
        var parameterRange = range, value: CFTypeRef?
        if let parameter = AXValueCreate(.cfRange, &parameterRange),
           AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
           let text = value as? String, text.utf16.count == range.length { return text }
        // Some single-line/web controls expose selected text but not StringForRange.
        // Temporarily select only the bounded range, then restore the exact selection.
        guard let original = selection(), focused() else { return nil }
        let alreadySelected = original.location == range.location && original.length == range.length
        guard alreadySelected || select(range) else { return nil }
        guard focused(), sameSelection(range) else { return nil }
        let text = Self.attribute(element, kAXSelectedTextAttribute) as? String
        if !alreadySelected {
            guard focused(), sameSelection(range), select(original), sameSelection(original) else { return nil }
        }
        guard focused(), let text, text.utf16.count == range.length else { return nil }
        return text
    }
    func sameSelection(_ range: CFRange) -> Bool {
        guard let selected = selection() else { return false }
        return selected.location == range.location && selected.length == range.length
    }
    @discardableResult func select(_ range: CFRange) -> Bool {
        guard focused() else { return false }
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
    func snapshot() -> CorrectionSnapshot? {
        guard focused(), let range = selection(), range.length == 0 else { return nil }
        let start = max(0, range.location - 96)
        guard let tail = string(CFRange(location: start, length: range.location - start)) else { return nil }
        return CorrectionSnapshot(tail: tail, caret: range.location)
    }
    func replace(_ expected: CorrectionSnapshot, suffix: String, with replacement: String) -> CorrectionSnapshot? {
        // An xterm textarea mirrors IME input, not the PTY's editable text.
        // Changing it alone inserts new text but never erases the PTY input.
        guard !isTerminalInputProxy else { return nil }
        return replaceSelection(expected, suffix: suffix, with: replacement)
    }
    private func replaceSelection(_ expected: CorrectionSnapshot, suffix: String, with replacement: String) -> CorrectionSnapshot? {
        guard canReplace, snapshot() == expected, expected.tail.hasSuffix(suffix), expected.caret >= suffix.utf16.count else { return nil }
        let range = CFRange(location: expected.caret - suffix.utf16.count, length: suffix.utf16.count)
        guard select(range) else { return nil }
        func selectionStillOurs() -> Bool {
            guard focused(), let selected = selection() else { return false }
            return selected.location == range.location && selected.length == range.length && string(range) == suffix
        }
        guard selectionStillOurs() else { return nil }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success else {
            if selectionStillOurs() { select(CFRange(location: expected.caret, length: 0)) }
            return nil
        }
        let inserted = CFRange(location: range.location, length: replacement.utf16.count)
        guard focused(), let actual = string(inserted), CorrectionReadback.accepts(actual, requested: replacement), let selected = selection() else { return nil }
        let end = inserted.location + inserted.length
        if selected.location == inserted.location && selected.length == inserted.length {
            guard select(CFRange(location: end, length: 0)) else { return nil }
        } else if selected.location != end || selected.length != 0 { return nil }
        return snapshot()
    }
    func replace(_ expected: CorrectionSnapshot, suffix: String, with replacement: String,
                 valid: @escaping () -> Bool, completion: @escaping (CorrectionSnapshot?) -> Void) {
        guard !isTerminalInputProxy else { completion(nil); return }
        replaceAccessibleSelection(expected, suffix: suffix, with: replacement, valid: valid, completion: completion)
    }
    private func replaceAccessibleSelection(_ expected: CorrectionSnapshot, suffix: String, with replacement: String,
                                           valid: @escaping () -> Bool, completion: @escaping (CorrectionSnapshot?) -> Void) {
        guard valid() else { completion(nil); return }
        if canReplace {
            if let after = replaceSelection(expected, suffix: suffix, with: replacement) { completion(after); return }
            // Chromium can advertise AXSelectedText as writable, then reject or
            // ignore the write. Retry via keyboard only if the original text is
            // still intact; an unverified successful write must never repeat.
            let range = CFRange(location: expected.caret - suffix.utf16.count, length: suffix.utf16.count)
            if valid(), focused(), sameSelection(range), string(range) == suffix {
                select(CFRange(location: expected.caret, length: 0))
            }
        }
        // Web/Electron controls may allow selection but expose selected text as
        // read-only. Insert Unicode into that verified selection, without a
        // clipboard round trip or guessed deletion count.
        guard Self.editable(element), snapshot() == expected, expected.tail.hasSuffix(suffix),
              expected.caret >= suffix.utf16.count,
              let events = Self.insertionEvents(replacement, marker: marker) else { completion(nil); return }
        let range = CFRange(location: expected.caret - suffix.utf16.count, length: suffix.utf16.count)
        func verify(_ attempt: Int) {
            guard valid(), self.focused() else { completion(nil); return }
            if let after = self.snapshot(), CorrectionReadback.inserted(before: expected, after: after,
                original: suffix, requested: replacement) != nil { completion(after); return }
            guard attempt < 2 else { completion(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { verify(attempt + 1) }
        }
        guard valid(), select(range) else { completion(nil); return }
        // Web renderers may acknowledge AX selection before the DOM selection
        // has caught up. Let the renderer apply it before sending text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            guard valid(), self.focused(), self.sameSelection(range), self.string(range) == suffix,
                  Self.editable(self.element) else {
                if self.focused(), self.sameSelection(range) { self.select(CFRange(location: expected.caret, length: 0)) }
                completion(nil); return
            }
            for event in events { event.postToPid(self.pid) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { verify(0) }
        }
    }
    static func insertionEvents(_ text: String, marker: Int64) -> [CGEvent]? {
        guard !text.isEmpty, text.utf16.count <= 72 else { return nil }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return nil }
        let unicode = Array(text.utf16)
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
        }
        return [down, up]
    }
}

extension AppDelegate {
    func correctionContext() -> CorrectionContext? {
        guard engine.active, engine.manualCorrection, !optionInput.busy,
              let app = NSWorkspace.shared.frontmostApplication,
              let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), let identity = Self.sourceIdentity(source) else { return nil }
        return CorrectionContext(pid: app.processIdentifier, sourceID: identity.id)
    }
    func makeManualCorrection() -> ManualCorrectionController {
        let controller = ManualCorrectionController(environment: correctionEnvironment())
        controller.report = { [weak self] message in self?.correctionStatus.stringValue = message }
        return controller
    }
    func correctionEnvironment() -> ManualCorrectionController.Environment {
        .init(context: { [weak self] in self?.correctionContext() },
            secure: { AccessibilityCorrectionEditor.focusedInputIsSecure() }, editor: { [weak self] pid in
                if pid == getpid() {
                    guard let view = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
                    return LocalCorrectionEditor(view)
                }
                if let terminal = self?.terminalCorrection.editor(for: pid) { return terminal }
                guard let access = AccessibilityCorrectionEditor(pid: pid, marker: self?.nativePulseMarker ?? 0) else { return nil }
                if access.isTerminalInputProxy { return TerminalInputProxyEditor(access: access) }
                return access
            }, destination: { language in
                let ids = language == .korean ? ["com.apple.inputmethod.Korean.2SetKorean"] : ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
                return ids.first { id in
                    guard let source = Self.sourceForID(id), let enabled = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else { return false }
                    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enabled).takeUnretainedValue())
                }
            }, select: { [weak self] id in
                guard let source = Self.sourceForID(id) else { return false }
                self?.cancelCapsRestore(); self?.rememberCapsBeforeSwitch()
                return TISSelectInputSource(source) == noErr
            }, later: { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) })
    }
    @objc func toggleManualCorrection() {
        terminalCorrection.reset()
        manualCorrection.reset()
        engine.defaults.set(manualCorrectionSwitch.state == .on, forKey: "manualCorrection")
        correctionStatus.stringValue = ""
        ensureKeyTap()
    }
    @objc func changeManualCorrectionShortcut() {
        guard ManualCorrectionShortcut.allCases.indices.contains(manualShortcutPicker.indexOfSelectedItem) else { return }
        terminalCorrection.reset()
        manualCorrection.reset()
        engine.defaults.set(ManualCorrectionShortcut.allCases[manualShortcutPicker.indexOfSelectedItem].rawValue, forKey: "manualCorrectionShortcut")
        correctionStatus.stringValue = ""
        updatePressAccess()
    }
}
