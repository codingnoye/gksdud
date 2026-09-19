import AppKit
import Carbon

// This is separate from the F-key switch path. Ordinary input is only queued during
// an explicitly enabled, bounded Option-character transaction; it is never persisted.
enum SpecialCharacterMode: Int { case none, english, block }

struct InputSourceIdentity: Equatable {
    let id: String
    let language: String
}

struct OptionKeyPolicy {
    static let printable: Set<Int64> = Set(0...50).subtracting([36, 48])
        .union([65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 93, 94, 95])
    static func matches(code: Int64, flags: CGEventFlags) -> Bool {
        printable.contains(code) && flags.contains(.maskAlternate)
            && flags.intersection([.maskCommand, .maskControl, .maskSecondaryFn]).isEmpty
    }
}

final class OptionInputController {
    struct Environment {
        var current: () -> InputSourceIdentity?
        var english: () -> InputSourceIdentity?
        var select: (InputSourceIdentity) -> Bool
        var frontmost: () -> pid_t?
        var post: (CGEvent) -> Void
        var later: (TimeInterval, @escaping () -> Void) -> Void
        var clock: () -> TimeInterval
        // Predict only dead-key state; actual character input is performed by the English IME.
        var deadState: (InputSourceIdentity, CGEvent, UInt32) -> UInt32?
    }
    enum Phase { case idle, selecting, delivering, restoring }
    let environment: Environment
    let marker: Int64
    var report: (String) -> Void = { _ in }
    var willBegin: () -> Void = {}
    var didFinish: () -> Void = {}
    private(set) var phase = Phase.idle
    var busy: Bool { phase != .idle }
    private var original: InputSourceIdentity?
    private var destination: InputSourceIdentity?
    private var owner: pid_t?
    private var held: Set<Int64> = []
    private var queued: [CGEvent] = []
    private var strokes: [CGEvent] = []
    private var generation = 0
    private var deadline: TimeInterval = 0
    private var posted = false
    private var pendingDead: [CGEvent] = []
    private var pendingState: UInt32 = 0
    private var pendingSource: InputSourceIdentity?
    private var pendingOwner: pid_t?
    private var pendingOriginal: InputSourceIdentity?
    private var pendingSince: TimeInterval = 0

    init(environment: Environment, marker: Int64) { self.environment = environment; self.marker = marker }

    // Returns true only when this controller owns the event.
    func handle(_ event: CGEvent, mode: SpecialCharacterMode, active: Bool) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == marker { return false }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            cancel(focusChanged: true); return false
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if event.type == .keyUp, held.remove(code) != nil { return true }
        if busy {
            guard owner == environment.frontmost() else { cancel(focusChanged: true); return false }
            if queued.count >= 256 { cancel(); report("특수문자 입력이 지연되어 중단했습니다."); return false }
            guard let copy = event.copy() else { cancel(); return false }
            queued.append(copy)
            return true
        }
        guard active, mode != .none else { clearDead(); return false }
        guard event.type == .keyDown else { return false }
        let option = OptionKeyPolicy.matches(code: code, flags: event.flags)
        if mode == .block {
            clearDead()
            if option { held.insert(code); return true }
            return false
        }
        guard let current = environment.current(), current.language.hasPrefix("ko") else { clearDead(); return false }
        if !pendingDead.isEmpty, pendingOwner != environment.frontmost() || pendingOriginal != current
            || environment.clock() - pendingSince > 30 { clearDead() }
        let continuation = !pendingDead.isEmpty && OptionKeyPolicy.printable.contains(code)
            && event.flags.intersection([.maskCommand, .maskControl, .maskSecondaryFn]).isEmpty
        if !option && !continuation { clearDead(); return false }
        guard let english = pendingSource ?? environment.english(), let copy = event.copy(),
              let front = environment.frontmost() else {
            report("영어 입력 소스를 추가한 뒤 다시 시도해주세요."); clearDead(); return false
        }
        // A dead key has no character to deliver yet. Retain it until the next
        // printable stroke, then replay both in one English transaction. Switching
        // back immediately after a native dead key would discard its composition.
        let nextState = environment.deadState(english, copy, pendingState) ?? 0
        if nextState != 0, pendingDead.count < 4 {
            pendingDead.append(copy); pendingState = nextState; pendingSource = english
            pendingOwner = front; pendingOriginal = current; pendingSince = environment.clock()
            held.insert(code)
            report("악센트와 조합할 문자를 입력하세요. Esc로 취소할 수 있습니다.")
            return true
        }
        strokes = pendingDead + [copy]; clearDead()
        held.insert(code)
        original = current; destination = english; owner = front
        willBegin()
        posted = false; phase = .selecting; generation += 1
        deadline = environment.clock() + 0.4
        let token = generation
        environment.later(0) { [weak self] in
            guard let self, self.generation == token else { return }
            guard self.owner == self.environment.frontmost() else { self.cancel(focusChanged: true); return }
            guard self.environment.select(english) else { self.cancel(); self.report("영어로 전환하지 못했습니다."); return }
            self.advance(token)
        }
        return true
    }
    private func clearDead() {
        pendingDead.removeAll(); pendingState = 0; pendingSource = nil; pendingOwner = nil; pendingOriginal = nil
    }
    private func advance(_ token: Int) {
        guard generation == token, busy else { return }
        guard owner == environment.frontmost() else { cancel(focusChanged: true); return }
        if phase == .selecting, environment.current() == destination {
            phase = .delivering; posted = true
            for event in strokes { postPair(event) }
            // CGEvent posting has no cross-application text-insertion acknowledgement.
            // This bounded grace period is intentionally experimental, not a guarantee.
            environment.later(0.06) { [weak self] in
                guard let self, self.generation == token else { return }
                self.restore(token)
            }
            return
        }
        if phase == .restoring, environment.current() == original { finish(replayOriginal: false); return }
        guard environment.clock() < deadline else {
            cancel(); report("입력 소스 전환을 확인하지 못했습니다. 특수문자 모드를 끄고 다시 시도해주세요.")
            return
        }
        environment.later(0.005) { [weak self] in self?.advance(token) }
    }
    private func restore(_ token: Int) {
        guard owner == environment.frontmost() else { cancel(focusChanged: true); return }
        guard environment.current() == destination else {
            // A manual source change wins. Do not steal the user's selection.
            finish(replayOriginal: !posted); report("입력 소스가 바뀌어 특수문자 전환을 중단했습니다."); return
        }
        phase = .restoring; deadline = environment.clock() + 0.4
        guard let original, environment.select(original) else {
            finish(replayOriginal: false, discard: true); report("한글로 돌아오지 못해 대기 중인 입력을 취소했습니다. 입력 소스를 확인해주세요."); return
        }
        advance(token)
    }
    private func postPair(_ event: CGEvent) {
        guard let down = event.copy(), let up = event.copy() else { return }
        down.type = .keyDown; up.type = .keyUp
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        up.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        for copy in [down, up] {
            copy.setIntegerValueField(.eventSourceUserData, value: marker)
            copy.timestamp = 0
            environment.post(copy)
        }
    }
    private func finish(replayOriginal: Bool, discard: Bool = false) {
        let buffered = queued, retry = strokes
        let sameOwner = owner == environment.frontmost()
        generation += 1; phase = .idle
        original = nil; destination = nil; owner = nil; strokes.removeAll(); queued.removeAll()
        didFinish()
        if !discard && sameOwner {
            if replayOriginal { retry.forEach(postPair) }
            // Queue events re-enter the normal tap so switch keys and subsequent
            // Option strokes retain their own behavior, in original order.
            for event in buffered { environment.post(event) }
        }
    }
    func cancel(focusChanged: Bool = false) {
        clearDead()
        guard busy else { return }
        if owner == environment.frontmost(), environment.current() == destination, let original { _ = environment.select(original) }
        let restored = environment.current() == original
        // Never flush waiting Hangul while a failed restore has left English selected.
        finish(replayOriginal: !posted && restored, discard: focusChanged || !restored)
        if focusChanged { report("입력 창이 바뀌어 대기 중인 특수문자 입력을 취소했습니다.") }
    }
}

extension AppDelegate {
    var specialMode: SpecialCharacterMode { SpecialCharacterMode(rawValue: engine.defaults.integer(forKey: "specialCharacterMode")) ?? .none }
    @objc func changeSpecialMode(_ sender: NSButton) {
        optionInput.cancel()
        engine.defaults.set(sender.tag, forKey: "specialCharacterMode")
        refreshSpecialMode(); ensureKeyTap()
    }
    func refreshSpecialMode() {
        for button in specialButtons { button.state = button.tag == specialMode.rawValue ? .on : .off }
        specialStatus.stringValue = specialMode == .block ? "한글·영어 모두 Option 문자 입력을 차단합니다." :
            specialMode == .english ? "앱에 따라 동작이 다를 수 있습니다. 위 입력창에서 먼저 테스트해보세요." : "기본 macOS 입력 방식을 사용합니다."
    }
    static func sourceIdentity(_ source: TISInputSource) -> InputSourceIdentity? {
        guard let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
              let languages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        return InputSourceIdentity(id: Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String,
            language: (Unmanaged<CFArray>.fromOpaque(languages).takeUnretainedValue() as? [String])?.first ?? "")
    }
    static func sourceForID(_ id: String) -> TISInputSource? {
        // macOS may return nil (not an empty array) when this source is unavailable.
        let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource]
        return list?.first
    }
    func makeOptionInput() -> OptionInputController {
        let controller = OptionInputController(environment: .init(current: {
            TISCopyCurrentKeyboardInputSource().flatMap { Self.sourceIdentity($0.takeRetainedValue()) }
        }, english: { [weak self] in
            if let current = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
               let identity = Self.sourceIdentity(current), identity.language.hasPrefix("en") { return identity }
            return self?.availableSource("en").flatMap(Self.sourceIdentity)
        }, select: { identity in
            guard let source = Self.sourceForID(identity.id) else { return false }
            return TISSelectInputSource(source) == noErr
        }, frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier }, post: { event in
            event.post(tap: .cghidEventTap)
        }, later: { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }, clock: { ProcessInfo.processInfo.systemUptime }, deadState: { identity, event, state in
            guard let source = Self.sourceForID(identity.id), let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(to: UCKeyboardLayout.self)
            var modifiers: UInt32 = 0
            if event.flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
            if event.flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
            if event.flags.contains(.maskAlphaShift) { modifiers |= UInt32(alphaLock) }
            var next = state, length = 0
            var chars = [UniChar](repeating: 0, count: 16)
            let result = UCKeyTranslate(layout, UInt16(event.getIntegerValueField(.keyboardEventKeycode)), UInt16(kUCKeyActionDown), modifiers >> 8,
                UInt32(event.getIntegerValueField(.keyboardEventKeyboardType)), 0, &next, chars.count, &length, &chars)
            // Some layouts retain a nonzero state even after emitting the composed
            // character. Only a zero-length result means another stroke is pending.
            return result == noErr ? (length == 0 ? next : 0) : nil
        }), marker: nativePulseMarker)
        controller.report = { [weak self] text in self?.specialStatus.stringValue = text }
        controller.willBegin = { [weak self] in self?.cancelLongPress(); self?.cancelCapsRestore(); self?.refreshSpecialMode() }
        controller.didFinish = { [weak self] in
            DispatchQueue.main.async { self?.updateInputIndicator(); self?.scheduleCapsRestore() }
        }
        return controller
    }
}
