import AppKit
import Carbon

// Input sources beside Korean and English. The Korean/English key goes round some of them (the cycle), and a source can
// have a key of its own that goes there. Either way only the system shortcut switches.

func isKorean(_ source: InputSourceIdentity) -> Bool { source.language.hasPrefix("ko") }
func isEnglish(_ source: InputSourceIdentity) -> Bool { source.language.hasPrefix("en") }

// Recently observed sources. Notifications can omit intermediate selections, so this list alone does not establish
// where the native previous-source shortcut goes.
struct SourceHistory {
    private(set) var ids: [String] = []
    private var previousIsKnown = true
    init(_ ids: [String] = []) { self.ids = ids }
    // External selections can change the native previous source without reporting each intermediate selection.
    // Keep recency for cycle/source-key choices, but do not trust it as the shortcut's destination until set up again.
    mutating func invalidatePrevious() { previousIsKnown = false }
    mutating func preparedPrevious() { previousIsKnown = true }
    func previous(of current: String) -> String? { previousIsKnown && ids.first == current && ids.count > 1 ? ids[1] : nil }
    func validatedPrevious(of current: String, system: [String]) -> String? {
        previousIsKnown && system.first == current && system.count > 1 ? system[1] : nil
    }
    mutating func note(_ id: String) {
        ids.removeAll { $0 == id }; ids.insert(id, at: 0)
        if ids.count > 16 { ids.removeLast() }
    }
    // Falls back to the first candidate, in the order macOS lists them.
    func mostRecent(_ candidates: [InputSourceIdentity]) -> InputSourceIdentity? {
        ids.lazy.compactMap { id in candidates.first { $0.id == id } }.first ?? candidates.first
    }
}

// Complete an arrival only after the observed source stays put, checking it again before releasing queued work.
struct SourceArrival {
    enum Outcome { case waiting, arrived, interrupted }
    let target: String
    let origin: String
    private(set) var observed: String?
    private(set) var since: TimeInterval = 0
    private(set) var sawTarget = false
    static let settling: TimeInterval = 0.03
    mutating func observe(_ id: String?, at now: TimeInterval) {
        if observed != id { observed = id; since = now }
        if id == target { sawTarget = true }
    }
    func settled(_ current: String?, at now: TimeInterval) -> Bool {
        current != nil && current == observed && now - since >= Self.settling
    }
    func outcome(_ current: String?, at now: TimeInterval) -> Outcome {
        guard settled(current, at: now) else { return .waiting }
        if current == target { return .arrived }
        return sawTarget || current != origin ? .interrupted : .waiting
    }
}

// A press discarded after a click/focus change must not release into the newly selected input field. A fresh press
// recovers even when a release was lost while the tap was unavailable.
struct SourceDiscardedKeys {
    private var codes: Set<Int64> = []
    mutating func discard(_ events: [CGEvent]) {
        for event in events {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if event.type == .keyDown { codes.insert(code) }
            else if event.type == .keyUp { codes.remove(code) }
        }
    }
    mutating func consumes(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard codes.contains(code) else { return false }
        if event.type == .keyUp { codes.remove(code); return true }
        guard event.type == .keyDown else { return false }
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { codes.remove(code); return false }
        return true
    }
}

// A busy front app can make a working shortcut look broken, so one failure backs off only briefly. Failures in a row,
// with no arrival in between, back off longer: a shortcut that never switches would lose a press at every retry.
struct NextSourceFailure {
    private(set) var key: String?
    private var retryAt: TimeInterval = 0
    private var count = 0
    private var attempt: Int?
    // `attempt` names the pulse: one that changed nothing in time and then went elsewhere fails once.
    mutating func failed(_ key: String, at now: TimeInterval, attempt: Int? = nil) {
        if let attempt, attempt == self.attempt, key == self.key { return }
        count = key == self.key ? count + 1 : 1
        self.key = key; self.attempt = attempt
        retryAt = now + min(600, 5 * pow(4, Double(count - 1)))
    }
    mutating func clear() { key = nil; retryAt = 0; count = 0; attempt = nil }
    func allows(_ key: String, at now: TimeInterval) -> Bool { self.key != key || now >= retryAt }
}

// With added sources, this app's own selections notify too, so a notification for the source already handled is skipped.
// Sources are noted while they are off as well: the first notification after they turn on is not taken for a repeat.
struct SourceNotifications {
    private(set) var last: String?
    mutating func handles(_ id: String?, addedSources: Bool) -> Bool {
        defer { last = id }
        return !addedSources || id != last
    }
}

// macOS keeps its recent sources in its preferences, naming an input mode, an input method or a keyboard layout.
// An entry that matches no enabled source ends the list, since the entries after it would be out of place.
struct SourceInfo { let id: String; let mode: String?; let bundle: String?; let layout: Bool }
func systemHistory(_ entries: [[String: Any]], sources: [SourceInfo]) -> [String] {
    func letters(_ text: Substring) -> String { text.filter { $0.isLetter || $0.isNumber } }
    var ids: [String] = []
    for entry in entries {
        let bundle = entry["Bundle ID"] as? String
        let match: SourceInfo?
        if let mode = entry["Input Mode"] as? String { match = sources.first { $0.mode == mode && $0.bundle == bundle } }
        else if let name = entry["KeyboardLayout Name"] as? String {
            match = sources.first { $0.layout && $0.id.split(separator: ".").last.map(letters) == letters(Substring(name)) }
        } else { match = sources.first { !$0.layout && $0.mode == nil && $0.bundle == bundle } }
        guard let match else { break }
        ids.append(match.id)
    }
    return ids
}

// What is selected from the background before the system shortcut switches, and whether that can cost the syllable in
// progress. A keyboard layout selected from the background reaches the frontmost app as soon as it looks, dropping an
// input method's composition, while an input method does not reach it at all. So the shortcut alone goes from an input
// method to a layout, which needs that layout as its previous source; it is set up on the way into the input method.
// `next` is where the Korean/English key goes from the target.
struct SwitchPlan: Equatable { var selections: [String]; var risky: Bool }
func switchPlan(current: InputSourceIdentity, target: InputSourceIdentity, next: String?, previous: String?,
                isLayout: (String) -> Bool) -> SwitchPlan {
    // Selected last, it becomes the shortcut's previous source once the switch lands.
    let wanted = next.flatMap { !isLayout(target.id) && isLayout($0) && $0 != current.id ? $0 : nil } ?? current.id
    func plan(_ last: String) -> [String] { previous == target.id && last == current.id ? [] : [target.id, last] }
    func risky(_ ids: [String]) -> Bool { !isLayout(current.id) && ids.contains { $0 != current.id && isLayout($0) } }
    var selections = plan(wanted)
    // Korean keeps its syllable; the layout after the target waits.
    if risky(selections) && isKorean(current) { selections = plan(current.id) }
    return SwitchPlan(selections: selections, risky: risky(selections))
}
// Back to back in one process, the first of two selections can be lost while a third-party input method such as WeChat's
// is current or selected, and the shortcut then goes to an older source. Around one, each selection has its own process.
func involvesThirdParty(_ bundles: [String?]) -> Bool {
    bundles.contains { $0.map { !$0.hasPrefix("com.apple.") } ?? false }
}

// The same process can retain stale TIS state after another app selects a source, so each selection has a process of its
// own, which waits for a byte before touching TIS. All start at once, as starting takes longer than selecting, and are
// told in turn. waitpid avoids Process.waitUntilExit's nested main run loop, and a child has a bounded lifetime.
// The event tap waits meanwhile, so the selections of one switch share `deadline`.
func selectSourcesInHelpers(_ ids: [String], executable: URL? = nil, gap: useconds_t = 0,
                            until deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 0.75, canContinue: () -> Bool) -> Bool {
    let path = (executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gksdud")).path
    var waiting: [(pid: pid_t, gate: Int32)] = []
    func stop(_ pid: pid_t) { var status: Int32 = 0; kill(pid, SIGKILL); while waitpid(pid, &status, 0) == -1 && errno == EINTR {} }
    // However this ends, no helper is left to select later.
    defer { for helper in waiting { stop(helper.pid); close(helper.gate) } }
    for id in ids {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { return false }
        // Above the standard descriptors: an app started without a stdin would get 0, and a descriptor placed onto
        // itself stays closed in the helper.
        let reader = fcntl(ends[0], F_DUPFD_CLOEXEC, 3)
        close(ends[0])
        guard reader >= 0 else { close(ends[1]); return false }
        _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
        // A helper that died early must not take the app with it.
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, reader, STDIN_FILENO)
        let values = [path, "--select-input-source", id]
        var arguments: [UnsafeMutablePointer<CChar>?] = values.map { value in value.withCString { strdup($0) } } + [nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, nil, &arguments, environ) == 0
        posix_spawn_file_actions_destroy(&actions)
        for argument in arguments { free(argument) }
        close(reader)
        guard spawned else { close(ends[1]); return false }
        waiting.append((pid, ends[1]))
    }
    while let helper = waiting.first {
        if gap > 0 && waiting.count < ids.count { usleep(gap) }
        guard canContinue() else { return false }
        waiting.removeFirst()
        var go: UInt8 = 1
        _ = write(helper.gate, &go, 1)
        close(helper.gate)
        var status: Int32 = 0
        while true {
            let result = waitpid(helper.pid, &status, WNOHANG)
            if result == helper.pid { break }
            if result == -1 && errno != EINTR { return false }
            guard ProcessInfo.processInfo.systemUptime < deadline, canContinue() else { stop(helper.pid); return false }
            usleep(1_000)
        }
        guard status == 0 else { return false }
    }
    return canContinue()
}

// The badge of an input source other than Korean or English: its language code of up to three letters, or without one
// its place among the sources, up to 10. Past that the badge stays empty.
func sourceBadgeLabel(_ language: String, position: Int?) -> String {
    let code = language.prefix { $0 != "-" && $0 != "_" }
    if (2...3).contains(code.count) && code.allSatisfy({ $0.isASCII && $0.isLetter }) { return code.uppercased() }
    return position.flatMap { (1...10).contains($0) ? String($0) : nil } ?? ""
}

// Modes with the same name are told apart by their input method's name.
func sourceDisplayTitle(_ name: String, provider: String?) -> String {
    guard let provider, !provider.isEmpty, !name.localizedCaseInsensitiveContains(provider) else { return name }
    return "\(name) · \(provider)"
}

// Korean first, then English, then the rest in the order macOS lists them.
func defaultCycle(_ enabled: [InputSourceIdentity]) -> [String] {
    (enabled.filter(isKorean) + enabled.filter(isEnglish) + enabled.filter { !isKorean($0) && !isEnglish($0) }).map(\.id)
}

// The input menu, and the next-source shortcut that goes round it, lists the sources by the name of their language in the
// system's language, keeping macOS's order within one. Measured on macOS 26 and 27.
func menuOrder(_ sources: [InputSourceIdentity], locale: Locale) -> [String] {
    let names = sources.map { locale.localizedString(forIdentifier: $0.language) ?? $0.language }
    return sources.indices.sorted { a, b in
        let order = names[a].compare(names[b], locale: locale)
        return order == .orderedSame ? a < b : order == .orderedAscending
    }.map { sources[$0].id }
}
func nextInMenu(_ ids: [String], after id: String) -> String? {
    guard ids.count > 1, let index = ids.firstIndex(of: id) else { return nil }
    return ids[(index + 1) % ids.count]
}

// Where the Korean/English key goes round the cycle; nil leaves it to the system shortcut alone. `enabled` are the sources
// in use now, so saved ones that are gone or turned off are skipped.
func cycleTarget(current: InputSourceIdentity, cycle: [String], enabled: [InputSourceIdentity], history: SourceHistory) -> InputSourceIdentity? {
    let members = cycle.compactMap { id in enabled.first { $0.id == id } }
    guard members.count > 1 else { return nil }
    // Another layout of a listed language takes that one's place; from elsewhere the cycle resumes where it was left.
    // Sources that name no language share none.
    let exact = members.firstIndex { $0.id == current.id }
    guard let index = exact ?? members.firstIndex(where: { !current.language.isEmpty && $0.language == current.language })
    else { return history.mostRecent(members) }
    return members[(index + 1) % members.count]
}
// A source's own key goes there, and pressed there again back to the most recent other source when `returns`.
func keySourceTarget(_ id: String, current: InputSourceIdentity, returns: Bool, enabled: [InputSourceIdentity],
                     history: SourceHistory) -> InputSourceIdentity? {
    guard let source = enabled.first(where: { $0.id == id }) else { return nil }
    guard current.id == id else { return source }
    return returns ? history.mostRecent(enabled.filter { $0.id != id }) : nil
}
// Without added sources a command still goes between the most recent Korean and English, as the system shortcut does.
func languageToggleTarget(current: InputSourceIdentity, enabled: [InputSourceIdentity], history: SourceHistory) -> InputSourceIdentity? {
    if isKorean(current) { return history.mostRecent(enabled.filter(isEnglish)) }
    if isEnglish(current) { return history.mostRecent(enabled.filter(isKorean)) }
    return history.mostRecent(enabled.filter { isKorean($0) || isEnglish($0) })
}

extension AppDelegate {
    var addedSourcesActive: Bool { engine.active && !engine.paused && engine.addedSourcesEnabled && engine.accessibilityTrusted() }
    // The source a source's key's F-key goes to.
    func sourceKeyTarget(_ code: Int64) -> String? {
        guard targets.contains(where: { Int64($0.keyCode) == code }), addedSourcesActive,
              let key = engine.sourceKeyTargets.first(where: { Int64($0.value.keyCode) == code })?.key else { return nil }
        return engine.usedSourceKeys.first { $0.value == key }?.key
    }
    // The tap takes a source's key's F-key only while the key is mapped to it. When another mapping already sends that
    // F-key, the key is not applied and its presses stay that mapping's.
    func takesSourceKey(_ code: Int64) -> Bool {
        if sourceKeyGate.held.contains(code) { return true }
        guard targets.contains(where: { Int64($0.keyCode) == code }), addedSourcesActive,
              let target = engine.sourceKeyTargets.values.first(where: { Int64($0.keyCode) == code }) else { return false }
        return !engine.keyboards.result.blockedTargets.contains(target.usage)
    }
    // Sources' keys that are Space combinations. A Korean/English combination wins over them.
    var sourceCombos: [UInt64: String] {
        guard addedSourcesActive else { return [:] }
        let chosen = engine.chosenCombos
        var combos: [UInt64: String] = [:]
        for (id, key) in engine.usedSourceKeys where spaceCombos.contains(key) && !chosen.contains(key) { combos[key] = id }
        return combos
    }
    // Keyboard input sources macOS offers now, in its order. Read again when macOS reports a change, not on every key.
    func enabledSources() -> [InputSourceIdentity] { loadSources().list }
    private func loadSources() -> (list: [InputSourceIdentity], layouts: Set<String>) {
        if let sourceCache { return sourceCache }
        let filter = [kTISPropertyInputSourceIsEnabled as String: true, kTISPropertyInputSourceIsSelectCapable as String: true,
                      kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        var list: [InputSourceIdentity] = [], layouts: Set<String> = []
        for source in TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? [] {
            guard let identity = Self.sourceIdentity(source) else { continue }
            list.append(identity)
            if let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType),
               Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String == kTISTypeKeyboardLayout as String { layouts.insert(identity.id) }
        }
        sourceCache = (list, layouts)
        return (list, layouts)
    }
    func isLayout(_ id: String) -> Bool {
        let sources = loadSources()
        return sources.list.contains { $0.id == id } ? sources.layouts.contains(id) : Self.isLayout(id)
    }
    // Where switching is headed: a switch waiting for the one on its way, or that one until it lands.
    var logicalSource: InputSourceIdentity? {
        if let owner = sourceSwitchOwner, owner != frontmostPID() { return currentSource }
        if let target = queuedSwitch?.target { return target }
        if let id = switchLanding, let source = enabledSources().first(where: { $0.id == id }) { return source }
        return currentSource
    }
    // The saved cycle with the sources turned off still in their places; sources added since then are outside it.
    var cycleOrder: [String] { engine.cycleSources ?? defaultCycle(enabledSources()) }
    // The sources macOS offers, without the ones turned off here.
    func activeSources() -> [InputSourceIdentity] {
        let disabled = engine.disabledSources
        return enabledSources().filter { !disabled.contains($0.id) }
    }
    func hangulTarget(from current: InputSourceIdentity) -> InputSourceIdentity? {
        cycleTarget(current: current, cycle: cycleOrder, enabled: activeSources(), history: sourceHistory)
    }
    // The Korean/English key. Without added input sources, or a cycle of fewer than two, it sends the system shortcut alone.
    @discardableResult
    func switchHangul(_ pulse: (CGEvent, CGEvent)) -> Bool {
        guard addedSourcesActive, let current = logicalSource, let target = hangulTarget(from: current) else {
            postSwitchPulse(pulse); return true
        }
        return switchSource(to: target, from: current, pulse: pulse)
    }
    // A source's own key. False when there is nothing to switch with, so a Space goes back to the app; pressed in its source
    // with nowhere to go back to, it does nothing.
    func switchToKeySource(_ id: String, key: CGEvent) -> Bool {
        guard addedSourcesActive, let current = logicalSource,
              let pulse = nativeSwitchPulse(keyCode: engine.target.keyCode, marker: nativePulseMarker) else { return false }
        let enabled = activeSources()
        guard enabled.contains(where: { $0.id == id }) else { return false }
        guard let target = keySourceTarget(id, current: current, returns: engine.sourceKeyReturns, enabled: enabled, history: sourceHistory) else { return true }
        rememberCapsBeforeSwitch(key)
        _ = switchSource(to: target, from: current, pulse: pulse)
        return true
    }
    // The English a long press or ESC goes to: the most recent one in use, or any.
    func switchToEnglish(_ pulse: (CGEvent, CGEvent)) -> Bool {
        let inUse = activeSources().filter(isEnglish)
        guard let current = logicalSource,
              let english = sourceHistory.mostRecent(inUse.isEmpty ? enabledSources().filter(isEnglish) : inUse) else { return false }
        return switchSource(to: english, from: current, pulse: pulse)
    }
    static func isLayout(_ id: String) -> Bool {
        guard let source = sourceForID(id), let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        return Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String == kTISTypeKeyboardLayout as String
    }
    static func bundleID(_ id: String) -> String? {
        sourceForID(id).flatMap { TISGetInputSourceProperty($0, kTISPropertyBundleID) }.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }
    func plannedSwitch(to target: InputSourceIdentity, from current: InputSourceIdentity) -> (plan: SwitchPlan, fresh: Bool) {
        var landed = sourceHistory; landed.note(current.id); landed.note(target.id)
        // A command can switch without added sources, when the Korean/English key goes between Korean and English.
        let next = addedSourcesActive ? cycleTarget(current: target, cycle: cycleOrder, enabled: activeSources(), history: landed)
            : languageToggleTarget(current: target, enabled: enabledSources(), history: landed)
        let previous = sourceHistory.validatedPrevious(of: current.id, system: readSystemSourceHistory())
        return (switchPlan(current: current, target: target, next: next?.id, previous: previous, isLayout: isLayout),
                previous == nil || previous != sourceHistory.previous(of: current.id))
    }
    // Only the system shortcut switches, as without added sources. Sources selected from here first only set where it goes.
    // Keep the last requested target separate from observed history. Wait before sending another pulse or changing the
    // native history under one already sent.
    // False when it could not: the target is gone or a selection failed. The shortcut is then not sent, as it would go
    // wherever the sources selected so far point.
    @discardableResult
    func switchSource(to target: InputSourceIdentity, from current: InputSourceIdentity, pulse: (CGEvent, CGEvent), owner expectedOwner: pid_t? = nil) -> Bool {
        let frontmost = frontmostPID()
        guard expectedOwner == nil || expectedOwner == frontmost else { return false }
        if let owner = sourceSwitchOwner, owner != frontmost { cancelSourceSwitch() }
        sourceSwitchOwner = frontmost
        if switchLanding == target.id { queuedSwitch = nil; return true }
        if switchLanding == nil && target.id == current.id { return true }
        if switchLanding != nil { queuedSwitch = (target, pulse); holdKeys = true; return true }
        let generation = landingGeneration, started = ProcessInfo.processInfo.systemUptime
        func canContinue() -> Bool {
            guard generation == landingGeneration else { return false }
            // TIS and its inter-selection wait can delay the event tap's mouse callback. Check clicks that happened
            // during setup too, before making another selection or posting a pulse into a window the user left.
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let clicked = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].contains {
                CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) <= elapsed
            }
            guard frontmost == frontmostPID(), !clicked else { cancelSourceSwitch(discardKeys: clicked); return false }
            return true
        }
        // The input menu's next source is one shortcut away, as the previous one is: nothing is selected first. Not while
        // another switch is on its way: its notices would look like this one going elsewhere.
        if queuedSwitch == nil, let next = engine.liveNextTarget, engine.nextFailure.allows(next.name, at: ProcessInfo.processInfo.systemUptime),
           menuNext(after: current.id) == target.id, Self.sourceForID(target.id) != nil,
           let nextPulse = nativeSwitchPulse(keyCode: next.keyCode, marker: nativePulseMarker) {
            guard canContinue() else { return false }
            addedSources.showError(nil)
            postSwitchPulse(nextPulse)
            nextSent = (current.id, target.id, next.name)
            expectLanding(target, origin: current.id)
            return true
        }
        let setup = plannedSwitch(to: target, from: current), plan = setup.plan
        let bundles = ([current.id] + plan.selections + Array(sourceHistory.ids.prefix(2))).map(Self.bundleID)
        // A recently left third-party IME can retain stale state even when the history itself is known.
        let fresh = setup.fresh || involvesThirdParty(bundles)
        // Compatibility mode waits between any two selections.
        let gap: useconds_t = engine.addedSourcesCompatible ? 50_000 : 0
        var failed = Self.sourceForID(target.id) == nil
        if !plan.selections.isEmpty { sourceHistory.invalidatePrevious() }
        if fresh {
            guard canContinue() else { return false }
            failed = failed || !selectSourcesInHelpers(plan.selections, gap: gap, until: started + 0.8, canContinue: canContinue)
        } else {
            for (index, id) in plan.selections.enumerated() where !failed {
                if index > 0 && gap > 0 { usleep(gap) }
                guard canContinue() else { return false }
                guard let source = Self.sourceForID(id), TISSelectInputSource(source) == noErr else { failed = true; break }
            }
        }
        guard generation == landingGeneration else { return false }
        guard !failed else {
            // macOS's list may have changed without a notice yet.
            sourceCache = nil
            addedSources.showError("입력 소스를 전환하지 못했습니다.")
            updateInputIndicator()
            return false
        }
        guard canContinue() else { return false }
        addedSources.showError(nil)
        // The frontmost app can see the selections before the shortcut's switch reaches it.
        if !plan.selections.isEmpty { sourceHistory.preparedPrevious(); holdKeys = true }
        postSwitchPulse(pulse)
        expectLanding(target, origin: plan.selections.last ?? current.id)
        return true
    }
    // A change notification does not identify who selected a source, so an unexpected arrival cannot teach this order.
    func menuNext(after id: String) -> String? {
        nextInMenu(menuOrder(enabledSources(), locale: Locale(identifier: Locale.preferredLanguages.first ?? "en")), after: id)
    }
    // A delayed retry or queued switch belongs to the app where it started, including switches requested by the CLI.
    func cancelSourceSwitch(discardKeys: Bool = false) {
        let discard = discardKeys || (sourceSwitchOwner != nil && sourceSwitchOwner != frontmostPID())
        if switchLanding != nil { sourceHistory.invalidatePrevious() }
        landingGeneration += 1
        queuedSwitch = nil; switchLanding = nil; sourceArrival = nil; nextSent = nil; sourceSwitchOwner = nil
        sentSwitch = nil
        // Keys captured in the old input window must not be replayed into the newly focused app.
        if discard { discardHeldKeys() }
        else { releaseHeldKeys() }
    }
    func sourceMouseDown() {
        guard switchLanding != nil || holdKeys else { return }
        cancelSourceSwitch(discardKeys: true)
    }
    func observeSourceArrival(_ id: String?) {
        guard switchLanding != nil else { return }
        sourceArrival?.observe(id, at: ProcessInfo.processInfo.systemUptime)
        let generation = landingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + SourceArrival.settling) { [weak self] in
            guard let self, self.landingGeneration == generation else { return }
            self.settleSourceArrival(self.currentSource?.id, at: ProcessInfo.processInfo.systemUptime)
        }
    }
    func settleSourceArrival(_ id: String?, at now: TimeInterval) {
        guard switchLanding != nil, let arrival = sourceArrival else { return }
        guard sourceSwitchOwner == frontmostPID() else { cancelSourceSwitch(); return }
        switch arrival.outcome(id, at: now) {
        case .waiting: return
        case .arrived:
            if nextSent != nil { engine.nextFailure.clear() }
            nextSent = nil; switchLanding = nil; sourceArrival = nil
            updateInputIndicator()
            runQueuedSwitch()
        case .interrupted:
            // An external selection and a misdirected pulse look identical. Never force the old target back or run its
            // queued request: the next explicit key starts from the actual source and rebuilds uncertain history.
            // Having reached its target, the next-source shortcut worked: what came after was chosen elsewhere.
            if let sent = nextSent {
                if arrival.sawTarget { engine.nextFailure.clear() }
                else { engine.nextFailure.failed(sent.key, at: now, attempt: landingGeneration) }
            }
            cancelSourceSwitch()
            updateInputIndicator()
        }
    }
    // Until the switch lands the icon keeps showing where it started, not the sources selected on the way. Timeouts
    // cancel only: another app may have selected even the original source without an identifiable notification.
    func expectLanding(_ target: InputSourceIdentity, origin: String) {
        switchLanding = target.id
        sourceArrival = SourceArrival(target: target.id, origin: origin)
        landingGeneration += 1
        let generation = landingGeneration
        let owner = sourceSwitchOwner
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.landingGeneration == generation else { return }
            guard owner == frontmostPID() else { self.cancelSourceSwitch(); return }
            guard self.switchLanding != nil else { return }
            self.sourceHistory.invalidatePrevious()
            if let sent = self.nextSent { self.engine.nextFailure.failed(sent.key, at: ProcessInfo.processInfo.systemUptime, attempt: generation) }
            // The front app may just be busy. Do not reorder its sources and send a second pulse while the first is queued.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.expireSourceSwitch(generation: generation, owner: owner)
            }
        }
    }
    func expireSourceSwitch(generation: Int, owner: pid_t?) {
        guard landingGeneration == generation, switchLanding != nil else { return }
        guard owner == frontmostPID() else { cancelSourceSwitch(discardKeys: true); return }
        // With the input window unchanged, a timeout releases its text in the current source instead of losing it.
        cancelSourceSwitch()
        updateInputIndicator()
    }
    // The switch that waited for the last one to land; once none is on its way, the keys held meanwhile go on. macOS
    // reports the switch a moment before the frontmost app's input method is ready, so they wait a little longer.
    func runQueuedSwitch() {
        guard sourceSwitchOwner == frontmostPID() else { cancelSourceSwitch(); return }
        if let queued = queuedSwitch {
            queuedSwitch = nil
            if let current = currentSource { switchSource(to: queued.target, from: current, pulse: queued.pulse) }
        }
        guard switchLanding == nil, holdKeys else { return }
        releaseHeldKeys()
    }
    // Bounded: past it the keys go on in whatever source is current.
    @discardableResult
    func holdKey(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // A key already delivered before buffering started still needs its release, even if the buffer is cancelled.
        if event.type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 && !bufferedSourceKeys.contains(code) { return false }
        if event.type == .keyUp && !bufferedSourceKeys.contains(code) { return false }
        guard let copy = event.copy() else { return false }
        if event.type == .keyDown { bufferedSourceKeys.insert(code) }
        else if event.type == .keyUp { bufferedSourceKeys.remove(code) }
        heldKeys.append(copy)
        if heldKeys.count >= 128 { releaseHeldKeys() }
        return true
    }
    func discardHeldKeys() {
        sourceDiscardedKeys.discard(heldKeys)
        heldKeys.removeAll(); bufferedSourceKeys.removeAll(); holdKeys = false
    }
    // In order, marked so the tap lets them through.
    func releaseHeldKeys() {
        if let owner = sourceSwitchOwner, owner != frontmostPID() { discardHeldKeys(); return }
        holdKeys = false
        let keys = heldKeys
        heldKeys = []; bufferedSourceKeys.removeAll()
        let caps = currentCaps
        for key in keys {
            // With the lock as it is now, as a key pressed now would have it.
            key.flags = capsFlags(key.flags, caps: caps)
            swapBackquote(key)
            key.setIntegerValueField(.eventSourceUserData, value: nativePulseMarker); postHeldKey(key)
        }
    }
    // Read independently of change notifications: several changes may precede even the first callback.
    func readSystemSourceHistory() -> [String] {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        let entries = CFPreferencesCopyAppValue("AppleInputSourceHistory" as CFString, domain) as? [[String: Any]] ?? []
        let filter = [kTISPropertyInputSourceIsEnabled as String: true, kTISPropertyInputSourceIsSelectCapable as String: true,
                      kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        let infos = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []).compactMap { source -> SourceInfo? in
            func text(_ key: CFString) -> String? { TISGetInputSourceProperty(source, key).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } }
            guard let id = text(kTISPropertyInputSourceID) else { return nil }
            return SourceInfo(id: id, mode: text(kTISPropertyInputModeID), bundle: text(kTISPropertyBundleID),
                              layout: text(kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String)
        }
        return systemHistory(entries, sources: infos)
    }
    // The recent sources macOS keeps, as far as they are known; otherwise only the current one.
    func seedSourceHistory() {
        let ids = readSystemSourceHistory(), current = currentSource?.id
        sourceHistory = SourceHistory(ids.first == current ? ids : current.map { [$0] } ?? [])
    }
    // Korean and English show this app's icons, other sources their own, or a badge without one.
    func sourceIcon(_ source: InputSourceIdentity) -> NSImage {
        isKorean(source) || isEnglish(source) ? sourceMenuIcon(korean: isKorean(source), upper: englishCase())
            : cachedNativeIcon(source.id) ?? badgeImage(label: sourceBadgeLabel(source.language, position: sourcePosition(source.id)), filled: false)
    }
    func cachedNativeIcon(_ id: String) -> NSImage? {
        if let cached = nativeIconCache[id] { return cached }
        let image = nativeSourceIcon(id)
        nativeIconCache[id] = .some(image)
        return image
    }
    // Each source's own icon, as macOS gives it; Korean's and English's often have no file.
    func nativeSourceIcon(_ id: String) -> NSImage? {
        let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource]
        guard let source = list?.first, let pointer = TISGetInputSourceProperty(source, kTISPropertyIconImageURL) else { return nil }
        let url = Unmanaged<CFURL>.fromOpaque(pointer).takeUnretainedValue() as URL
        var image = NSImage(contentsOf: url)
        // An asset catalog may hold the image even when its file URL does not exist.
        if image == nil, let bundleID = Self.bundleID(id),
           let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).flatMap(Bundle.init(url:)) {
            image = bundle.image(forResource: url.deletingPathExtension().lastPathComponent) ?? bundle.image(forResource: url.lastPathComponent)
        }
        // A copy, as the bundle's image is shared; resized keeping its shape.
        guard let image = image?.copy() as? NSImage, image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(22 / image.size.width, 20 / image.size.height)
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        // Black glyphs like Apple's are drawn in the text color, as the input menu does, so they show in dark mode too.
        if !image.isTemplate { image.isTemplate = Self.colorless(image) }
        return image
    }
    static func colorless(_ image: NSImage) -> Bool {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 22, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 22, height: 20))
        NSGraphicsContext.restoreGraphicsState()
        for x in 0..<22 { for y in 0..<20 {
            guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.1 else { continue }
            let channels = [color.redComponent, color.greenComponent, color.blueComponent]
            if channels.max()! - channels.min()! > 0.08 || channels.max()! > 0.35 { return false }
        } }
        return true
    }
    // Counted in the cycle's order, which starts as Korean, English, then the rest; a source outside it follows that
    // default order.
    func sourcePosition(_ id: String) -> Int? {
        if let index = cycleOrder.firstIndex(of: id) { return index + 1 }
        return defaultCycle(enabledSources()).firstIndex(of: id).map { $0 + 1 }
    }
    // An input method's modes are named after it, as other input methods can name theirs the same.
    static func sourceTitle(_ id: String) -> String {
        let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource]
        guard let source = list?.first else { return id }
        func text(_ key: CFString) -> String? {
            TISGetInputSourceProperty(source, key).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        }
        let name = text(kTISPropertyLocalizedName) ?? id
        guard let bundleID = text(kTISPropertyBundleID), !bundleID.hasPrefix("com.apple.") else { return name }
        let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).flatMap(Bundle.init(url:))
        let provider = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return sourceDisplayTitle(name, provider: provider)
    }
    // The settings' order: the cycle, then the other sources in use, then the ones turned off, each as macOS lists them
    // but the cycle. Saved sources macOS no longer offers are left out until they come back.
    func sourceGroups() -> (cycle: [InputSourceIdentity], other: [InputSourceIdentity], off: [InputSourceIdentity]) {
        let enabled = enabledSources(), active = activeSources(), order = cycleOrder
        let cycle = order.compactMap { id in active.first { $0.id == id } }
        let other = active.filter { source in !cycle.contains(source) }
        let off = enabled.filter { source in !active.contains(source) }
        return (cycle, other, off)
    }
    // The 한국어 and 영어 menu items: with added sources, the first source of that language in use.
    func menuLanguageSource(_ prefix: String) -> InputSourceIdentity? {
        let candidates = engine.addedSourcesEnabled ? activeSources() : []
        return candidates.first { $0.language.hasPrefix(prefix) } ?? enabledSources().first { $0.language.hasPrefix(prefix) }
    }
    // The menu lists the other sources in use after Korean and English, in the settings' order.
    var menuSources: [InputSourceIdentity] {
        guard engine.addedSourcesEnabled else { return [] }
        let groups = sourceGroups(), shown = [menuLanguageSource("ko")?.id, menuLanguageSource("en")?.id]
        return (groups.cycle + groups.other).filter { !shown.contains($0.id) }
    }
    func refreshAddedMenuItems(_ menu: NSMenu) {
        for entry in menu.items where entry.action == #selector(selectAddedSource(_:)) { menu.removeItem(entry) }
        guard let english = menu.items.firstIndex(where: { $0.action == #selector(selectEnglish) }) else { return }
        for (offset, source) in menuSources.enumerated() {
            let entry = NSMenuItem(title: Self.sourceTitle(source.id), action: #selector(selectAddedSource(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = source.id; entry.image = sourceIcon(source)
            menu.insertItem(entry, at: english + 1 + offset)
        }
    }
    @objc func selectAddedSource(_ sender: NSMenuItem) {
        appSourceFocus.cancel(); cancelSourceSwitch(discardKeys: true)
        if let id = sender.representedObject as? String, let source = Self.sourceForID(id) { rememberCapsBeforeSwitch(); _ = TISSelectInputSource(source) }
        updateInputIndicator()
    }
    func addedSourcesChanged() {
        cancelLongPress(); sourceCache = nil; engine.nextFailure.clear(); seedSourceHistory(); engine.refreshSystemFKeys()
        ensureKeyTap(); repair()
        do { try engine.updateNextShortcut() } catch { addedSources.showError(error.localizedDescription) }
        releaseKoreanCapsLock()
        addedSources.refresh(force: true)
        updateInputIndicator()
    }
    // A Korean/English key can also be a source's key; it stays a Korean/English key once confirmed. False keeps the old keys.
    func confirmSourceKeys(_ keys: [UInt64]? = nil) -> Bool {
        guard let (id, key) = engine.sourceKeysAmongHangulKeys(keys).min(by: { $0.value < $1.value }) else { return true }
        let alert = NSAlert(); alert.messageText = "\(sourceName(key))은 \(Self.sourceTitle(id))의 전용 전환 키입니다."
        alert.informativeText = "한영 키로 바꾸면 전용 전환 키가 해제됩니다."
        alert.addButton(withTitle: "변경"); alert.addButton(withTitle: "취소")
        return runAlert(alert) == .alertFirstButtonReturn
    }
    // Only once the key is saved as a Korean/English key, so a later warning that cancels the change keeps it. Saved keys of
    // sources that are gone go too, so they do not come back as Korean/English keys.
    func releaseSourceKeys() {
        let taken = engine.sourceKeys.filter { engine.defaultSources.contains($0.value) || engine.keyboards.maps($0.value, default: engine.defaultSources) }
        guard !taken.isEmpty else { return }
        for id in taken.keys { engine.setSourceKey(nil, for: id) }
        addedSources.refresh(force: true)
    }
}

// Moves `id` to `index` among the cycle's visible members, keeping the others (turned off, or gone) in their places.
func movedCycle(_ order: [String], visible: [String], moving id: String, to index: Int) -> [String] {
    guard let from = visible.firstIndex(of: id) else { return order }
    var moved = visible
    moved.remove(at: from)
    moved.insert(id, at: min(max(0, from < index ? index - 1 : index), moved.count))
    var slots = moved.makeIterator()
    return order.map { visible.contains($0) ? slots.next() ?? $0 : $0 }
}

private final class SourceCheckbox: NSButton { var sourceID = "" }
private final class SourceKeyPicker: NSPopUpButton { var sourceID = "" }
private final class InternalKeyPicker: NSPopUpButton { var sourceID = "" }
// Only the cycle's rows start a drag; the table would otherwise hide a row it has nothing to drag for.
final class SourceTable: NSTableView {
    var draggable: (Int) -> Bool = { _ in false }
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        rowIndexes.allSatisfy(draggable) && super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }
}

// The 입력 소스 추가 section of the extras tab, and its sheet: each source in use or not, in the cycle or not, and its key.
final class AddedSourcesSettings: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowType = NSPasteboard.PasteboardType("io.gksdud.cycle-source")
    unowned let owner: AppDelegate
    private var engine: Engine { owner.engine }
    let enable = NSButton(checkboxWithTitle: "활성화", target: nil, action: nil)
    let edit = NSButton(title: "입력 소스 설정", target: nil, action: nil)
    let warning = NSTextField(wrappingLabelWithString: "")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 490), styleMask: [.titled], backing: .buffered, defer: false)
    let table = SourceTable()
    let returns = NSButton(checkboxWithTitle: "전용 전환 키를 한 번 더 누를 시 직전 입력 소스로 전환", target: nil, action: nil)
    let compatible = NSButton(checkboxWithTitle: "호환성 모드", target: nil, action: nil)
    let sheetWarning = NSTextField(wrappingLabelWithString: "")
    enum Group { case cycle, other, off }
    // A source, or the gap between two groups.
    enum Row: Equatable { case source(String, Group), gap }
    private(set) var rows: [Row] = []
    private var identities: [String: InputSourceIdentity] = [:], titles: [String: String] = [:]
    // English rows without an icon of their own show the English icon, which follows its case.
    private var englishIcons: [NSImageView] = []
    private var signature = ""
    private var error: String?
    private var usable = false

    init(owner: AppDelegate) { self.owner = owner; super.init() }

    func install(in panel: NSStackView) {
        enable.target = self; enable.action = #selector(toggle)
        edit.target = self; edit.action = #selector(showSheet); edit.bezelStyle = .rounded
        warning.font = .systemFont(ofSize: 11); warning.textColor = .systemOrange
        let section = NSStackView(views: [enable, edit, warning]); section.orientation = .vertical; section.alignment = .leading; section.spacing = 8
        section.setCustomSpacing(10, after: enable)
        warning.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        panel.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        buildSheet()
        refresh(force: true)
    }
    private func buildSheet() {
        window.title = "입력 소스 설정"
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let title = NSTextField(labelWithString: "입력 소스 설정")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        func hint(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            return label
        }
        let dragHint = hint("드래그로 순환 순서를 변경할 수 있어요.")
        for (id, name, width) in [("name", "입력 소스", 0.0), ("enabled", "활성화", 60.0), ("cycle", "한영 키로 순환", 100.0), ("key", "전용 전환 키", 170.0), ("internal", "내부 키", 110.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = name
            if width > 0 {
                column.width = width; column.minWidth = width; column.maxWidth = width
                column.headerCell.alignment = .center
            } else { column.resizingMask = .autoresizingMask }
            table.addTableColumn(column)
        }
        table.style = .fullWidth
        table.rowHeight = 34
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.dataSource = self; table.delegate = self
        table.draggable = { [unowned self] row in
            guard self.usable, self.rows.indices.contains(row), case .source(_, .cycle) = self.rows[row] else { return false }
            return true
        }
        table.registerForDraggedTypes([Self.rowType])
        table.draggingDestinationFeedbackStyle = .gap
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("입력 소스")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = table
        let list = NSBox()
        list.boxType = .custom; list.titlePosition = .noTitle
        list.cornerRadius = 7; list.borderWidth = 1
        list.borderColor = .separatorColor; list.fillColor = .controlBackgroundColor
        list.contentViewMargins = .zero
        scroll.translatesAutoresizingMaskIntoConstraints = false
        list.contentView!.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: list.contentView!.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: list.contentView!.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: list.contentView!.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: list.contentView!.bottomAnchor, constant: -1)
        ])
        returns.target = self; returns.action = #selector(toggleReturns)
        compatible.target = self; compatible.action = #selector(toggleCompatible)
        let compatibleHint = hint("WeChat 입력기 등 서드파티 입력기 사용 중 전환이 다른 입력 소스로 가면 켜주세요.")
        sheetWarning.font = .systemFont(ofSize: 11); sheetWarning.textColor = .systemOrange
        let compatibleRow = NSStackView(views: [compatible, compatibleHint])
        compatibleRow.orientation = .vertical; compatibleRow.alignment = .leading; compatibleRow.spacing = 2
        let options = NSStackView(views: [returns, compatibleRow, sheetWarning])
        options.orientation = .vertical; options.alignment = .leading; options.spacing = 8
        let done = NSButton(title: "완료", target: self, action: #selector(closeSheet))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        for view in [title, dragHint, list, options, done] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            dragHint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            dragHint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            compatibleHint.leadingAnchor.constraint(equalTo: compatible.leadingAnchor, constant: 20),
            list.topAnchor.constraint(equalTo: dragHint.bottomAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            options.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 14),
            options.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 2),
            options.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            sheetWarning.widthAnchor.constraint(equalTo: options.widthAnchor),
            done.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 16),
            done.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
    }
    @objc func showSheet() {
        refresh(force: true)
        guard let parent = owner.window, window.sheetParent == nil else { return }
        parent.beginSheet(window)
    }
    @objc private func closeSheet() { window.sheetParent?.endSheet(window); window.orderOut(nil) }
    // Shown until the next switch succeeds; typing focus stays where it is.
    func showError(_ message: String?) {
        guard error != message else { return }
        error = message; refresh(force: true)
    }
    // Repair calls this every second, so the rows are rebuilt only when something they show changed.
    func refresh(force: Bool = false) {
        guard force || owner.window?.isVisible == true else { return }
        let trusted = engine.accessibilityTrusted(), on = engine.addedSourcesEnabled, groups = owner.sourceGroups()
        // Built in steps: as one literal it exceeds the type-checker time limit on older Swift (macos-15 CI).
        var parts: [String] = [String(trusted), String(on), owner.cycleOrder.joined(separator: ","), engine.disabledSources.sorted().joined(separator: ",")]
        parts += [engine.sourceKeys.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","), String(engine.sourceKeyReturns)]
        parts += [owner.enabledSources().map(\.id).joined(separator: ","), engine.defaultSources.map(String.init).joined(separator: ",")]
        parts += [engine.keyboards.result.blockedTargets.sorted().map(String.init).joined(separator: ","), String(owner.iconStyle), error ?? ""]
        parts += [String(engine.addedSourcesCompatible), String(engine.target.keyCode)]
        parts += [engine.internalKeys().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.target.name)\($0.value.automatic)" }.joined(separator: ",")]
        let state = parts.joined(separator: "|")
        guard force || state != signature else { return }
        signature = state
        enable.state = on ? .on : .off
        enable.isEnabled = trusted
        enable.toolTip = trusted ? nil : accessibilityHint
        usable = trusted && on
        edit.isEnabled = usable
        returns.state = engine.sourceKeyReturns ? .on : .off
        compatible.state = engine.addedSourcesCompatible ? .on : .off
        for control in [returns, compatible] { control.isEnabled = usable }
        identities = Dictionary(owner.enabledSources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [Row] = []
        for (group, ids) in [(Group.cycle, groups.cycle.map(\.id)), (.other, groups.other.map(\.id)), (.off, groups.off.map(\.id))] where !ids.isEmpty {
            if !next.isEmpty { next.append(.gap) }
            next += ids.map { .source($0, group) }
        }
        rows = next
        titles = Dictionary(next.compactMap { row -> (String, String)? in
            if case .source(let id, _) = row { return (id, AppDelegate.sourceTitle(id)) }; return nil
        }, uniquingKeysWith: { first, _ in first })
        englishIcons = []
        table.reloadData()
        // An app's source is chosen among the ones in use here.
        owner.appSourcesSettings.refresh(force: force)
        // Only states the user has to act on.
        let text = !usable ? "" : error ?? currentWarning()
        for label in [warning, sheetWarning] { label.stringValue = text; label.isHidden = text.isEmpty }
    }
    private func currentWarning() -> String {
        if !engine.sourceKeysAmongHangulKeys().isEmpty { return "전용 전환 키가 한영 키와 겹칩니다. 다른 키를 선택해주세요." }
        if let blocked = engine.sourceKeyTargets.values.sorted(by: { $0.keyCode < $1.keyCode })
            .first(where: { engine.keyboards.result.blockedTargets.contains($0.usage) }) {
            return "\(blocked.name)이 다른 키 매핑에서 사용 중이라 전용 전환 키를 적용하지 못했습니다."
        }
        return ""
    }
    func showEnglishIcon(_ image: NSImage) {
        for icon in englishIcons where icon.image !== image { icon.image = image }
    }
    var cycleCount: Int { rows.filter { if case .source(_, .cycle) = $0 { return true }; return false }.count }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row] == .gap ? 9 : tableView.rowHeight }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard case .source(let id, let group) = rows[row], let column = tableColumn?.identifier.rawValue else {
            guard tableColumn === tableView.tableColumns.first else { return nil }
            let line = NSBox(); line.boxType = .separator
            let cell = NSView(); line.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(line)
            NSLayoutConstraint.activate([line.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                                         line.widthAnchor.constraint(equalToConstant: tableView.bounds.width - 24)])
            return cell
        }
        let source = identities[id], name = titles[id] ?? id
        let live = usable && group != .off
        let cell = NSView()
        func center(_ view: NSView) -> NSView {
            view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view)
            NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: cell.centerXAnchor), view.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        // Turned off, only its checkbox shows, so the row reads as one to turn back on; its other settings wait.
        if group == .off && column != "enabled" && column != "name" { return cell }
        switch column {
        case "enabled":
            let box = SourceCheckbox(checkboxWithTitle: "", target: self, action: #selector(toggleSource(_:)))
            box.sourceID = id; box.state = group == .off ? .off : .on
            box.isEnabled = usable; box.setAccessibilityLabel("\(name) 활성화")
            return center(box)
        case "cycle":
            let box = SourceCheckbox(checkboxWithTitle: "", target: self, action: #selector(toggleCycle(_:)))
            box.sourceID = id; box.state = owner.cycleOrder.contains(id) ? .on : .off
            box.isEnabled = live; box.setAccessibilityLabel("\(name) 한영 키로 순환")
            return center(box)
        case "internal":
            // The F-key a single key goes to; a Space combination is caught as it is.
            let picker = InternalKeyPicker(frame: .zero, pullsDown: false)
            picker.sourceID = id; picker.controlSize = .small; picker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            picker.autoenablesItems = false
            if let assigned = engine.internalKey(for: id), let key = engine.usedSourceKeys[id] {
                let automatic = engine.internalKeys(ignoring: id)[key]?.target ?? assigned.target
                picker.addItem(withTitle: "\(automatic.name) (자동)")
                picker.menu?.addItem(.separator())
                for target in targets {
                    picker.addItem(withTitle: target.name); picker.lastItem?.representedObject = target.name
                    // The Korean/English key's own.
                    picker.lastItem?.isEnabled = target.name != engine.target.name
                }
                if assigned.automatic { picker.selectItem(at: 0) } else { picker.selectItem(withTitle: assigned.target.name) }
                picker.isEnabled = live
            } else {
                picker.addItem(withTitle: "—"); picker.isEnabled = false
            }
            picker.target = self; picker.action = #selector(changeInternalKey(_:))
            picker.setAccessibilityLabel("\(name) 내부 키")
            picker.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(picker)
            NSLayoutConstraint.activate([picker.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         picker.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                                         picker.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12)])
            return cell
        case "key":
            let picker = SourceKeyPicker(frame: .zero, pullsDown: false)
            picker.sourceID = id; picker.controlSize = .small; picker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            picker.addItem(withTitle: "없음")
            for key in hangulKeys {
                if key == spaceCombos.first { picker.menu?.addItem(.separator()) }
                picker.addItem(withTitle: sourceName(key)); picker.lastItem?.representedObject = NSNumber(value: key)
            }
            if let key = engine.sourceKeys[id] { picker.selectItem(withTitle: sourceName(key)) } else { picker.selectItem(at: 0) }
            picker.target = self; picker.action = #selector(changeKey(_:))
            picker.isEnabled = live
            picker.setAccessibilityLabel("\(name) 전용 전환 키")
            picker.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(picker)
            NSLayoutConstraint.activate([picker.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         picker.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                                         picker.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12)])
            return cell
        default:
            let native = owner.cachedNativeIcon(id)
            let icon = NSImageView(image: native ?? source.map(owner.sourceIcon) ?? owner.badgeImage(label: "", filled: false))
            if native == nil, source.map(isEnglish) == true { englishIcons.append(icon) }
            if icon.image?.isTemplate == true { icon.contentTintColor = live ? .labelColor : .disabledControlTextColor }
            icon.alphaValue = live || icon.image?.isTemplate == true ? 1 : 0.4
            let label = NSTextField(labelWithString: name)
            label.lineBreakMode = .byTruncatingTail; label.textColor = live ? .labelColor : .disabledControlTextColor
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.toolTip = name
            var views: [NSView] = [icon, label]
            // Only the cycle's order is dragged.
            if group == .cycle {
                let handle = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "순서 변경")!)
                handle.contentTintColor = live ? .tertiaryLabelColor : .quaternaryLabelColor
                views.insert(handle, at: 0)
            } else { views.insert(NSView(frame: NSRect(x: 0, y: 0, width: 16, height: 1)), at: 0) }
            let stack = NSStackView(views: views); stack.spacing = 8; stack.alignment = .centerY
            views[0].widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true; icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
            stack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                                         stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)])
            return cell
        }
    }
    // Drags the cycle's rows within the cycle.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard usable, case .source(let id, .cycle) = rows[row] else { return nil }
        let item = NSPasteboardItem(); item.setString(id, forType: Self.rowType)
        return item
    }
    // Below the cycle, a row goes to its end.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType: Self.rowType) != nil else { return [] }
        if row > cycleCount || dropOperation != .above { tableView.setDropRow(min(row, cycleCount), dropOperation: .above) }
        return .move
    }
    // A drag dropped nowhere shows its rows again.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == [] { tableView.reloadData() }
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: Self.rowType) else { return false }
        moveCycle(id, to: row)
        return true
    }
    func moveCycle(_ id: String, to index: Int) {
        let visible = rows.compactMap { row -> String? in if case .source(let id, .cycle) = row { return id }; return nil }
        setCycle(movedCycle(owner.cycleOrder, visible: visible, moving: id, to: index))
    }

    private func save(_ change: () -> Void) { change(); owner.addedSourcesChanged() }
    @objc func toggleCompatible() { save { engine.defaults.set(compatible.state == .on, forKey: "addedSourcesCompatibility") } }
    @objc func toggleReturns() { save { engine.defaults.set(returns.state == .on, forKey: "sourceKeyReturns") } }
    @objc func toggle() {
        if enable.state == .on {
            // The keys take keys away from the keyboard, so the same warnings as choosing them apply.
            let disabled = engine.disabledSources, available = engine.availableSources()
            for key in engine.sourceKeys.filter({ !disabled.contains($0.key) && available?.contains($0.key) != false }).values.sorted()
            where !confirmKey(key) { refresh(force: true); return }
        }
        save { engine.defaults.set(enable.state == .on, forKey: "addedSources") }
    }
    // The whole cycle at once, from the command line or a drag.
    func setCycle(_ order: [String]) { save { engine.cycleSources = order } }
    @objc private func toggleCycle(_ sender: SourceCheckbox) { setCycle(id: sender.sourceID, sender.state == .on) }
    func setCycle(id: String, _ on: Bool) {
        var order = owner.cycleOrder
        order.removeAll { $0 == id }
        if on { order.append(id) }
        setCycle(order)
    }
    @objc private func toggleSource(_ sender: SourceCheckbox) {
        guard setSource(sender.sourceID, on: sender.state == .on) else { refresh(force: true); return }
    }
    // A source turned back on takes its key back, with the same warnings. False keeps it off.
    @discardableResult func setSource(_ id: String, on: Bool) -> Bool {
        if on, let key = engine.sourceKeys[id], !engine.usedSourceKeys.values.contains(key), !confirmKey(key) { return false }
        save { if on { engine.disabledSources.remove(id) } else { engine.disabledSources.insert(id) } }
        return true
    }
    @objc private func changeInternalKey(_ sender: InternalKeyPicker) {
        setInternalKey(sender.selectedItem?.representedObject as? String, for: sender.sourceID)
    }
    // nil goes back to automatic.
    func setInternalKey(_ name: String?, for id: String) { save { engine.setInternalKey(name, for: id) } }
    @objc private func changeKey(_ sender: SourceKeyPicker) {
        let key = (sender.selectedItem?.representedObject as? NSNumber)?.uint64Value
        if !setKey(key, for: sender.sourceID) { refresh(force: true) }
    }
    // False when the key stays as it was.
    @discardableResult func setKey(_ key: UInt64?, for id: String) -> Bool {
        guard let key else { save { engine.setSourceKey(nil, for: id) }; return true }
        guard engine.sourceKeys[id] != key else { return true }
        guard !(engine.defaultSources.contains(key) || engine.keyboards.maps(key, default: engine.defaultSources)) else {
            let alert = NSAlert(); alert.messageText = "\(sourceName(key))은 한영 키로 사용 중입니다."
            alert.informativeText = "다른 키를 선택해주세요."
            _ = owner.runAlert(alert); return false
        }
        // Moved from another source, it was confirmed there.
        guard engine.usedSourceKeys.values.contains(key) || confirmKey(key) else { return false }
        save { engine.setSourceKey(key, for: id) }
        return true
    }
    // Caps Lock stops being Caps Lock, a system shortcut on the same Space combination stops working, and another app's
    // mapping of the key is replaced. False keeps the old key.
    private func confirmKey(_ key: UInt64) -> Bool {
        guard owner.confirmCapsLockKey(key == sources[2], as: "전용 전환 키") else { return false }
        if engine.systemShortcutUses(key) {
            let alert = NSAlert(); alert.messageText = "\(sourceName(key))은 시스템 단축키에서 사용 중입니다."
            alert.informativeText = "전용 전환 키로 쓰면 그 단축키는 동작하지 않습니다."
            alert.addButton(withTitle: "변경"); alert.addButton(withTitle: "취소")
            guard owner.runAlert(alert) == .alertFirstButtonReturn else { return false }
        }
        guard sources.contains(key), engine.sourceKeyConflict(key) else { return true }
        let alert = NSAlert(); alert.messageText = "\(sourceName(key))에 다른 매핑이 있습니다."
        alert.informativeText = "선택한 키를 입력 소스 전환 전용으로 바꿉니다. 다른 앱에서도 이 키의 재매핑을 꺼주세요. 기존 매핑은 해제 시 복원됩니다."
        alert.addButton(withTitle: "변경"); alert.addButton(withTitle: "취소")
        return owner.runAlert(alert) == .alertFirstButtonReturn
    }
}
