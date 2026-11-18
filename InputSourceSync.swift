import AppKit
import CryptoKit
import Network

// Input source sync, off by default. Under Universal Control each Mac keeps its own input source, and nothing built in
// carries an app's value both ways: keys go one way, only while the pointer is away. So the Macs that share a code
// find each other on the local network and tell each other the language of the latest switch.
struct SyncState: Codable, Equatable {
    var language: String
    // The sender's clock, in seconds since 1970.
    var at: TimeInterval
}

// Which change is the latest. Only the language is kept, never typed text.
struct SyncClock {
    // Korean and English for now. Another language is neither sent nor taken, so a later version can add it.
    static let languages = ["ko", "en"]
    private(set) var last: SyncState?
    // A change made here, to send. Nil when it is the landing of a change the other Mac asked for.
    mutating func changed(_ language: String, now: TimeInterval) -> SyncState? {
        guard Self.languages.contains(language), language != last?.language else { return nil }
        // After the last change known, even with this Mac's clock behind the other's.
        last = SyncState(language: language, at: max(now, (last?.at ?? 0) + 0.001))
        return last
    }
    // The other Mac's change: the language to switch to, unless a later one is known. The same change sent again is
    // taken again, so a resend makes up for one that was missed.
    mutating func received(_ state: SyncState) -> String? {
        guard Self.languages.contains(state.language), state.at >= (last?.at ?? 0) else { return nil }
        last = state
        return state.language
    }
}

// The connections to the other Macs with the same code. Everything runs on the main queue.
final class SyncLink {
    static let service = "_gksdud-sync._tcp"
    var service = SyncLink.service
    var received: (SyncState) -> Void = { _ in }
    // A Mac has connected, and has yet to hear the latest change.
    var connected: () -> Void = {}
    // Why it cannot look for other Macs, such as the local network permission being refused.
    private(set) var problem: String?
    private var code = ""
    // New each start: nothing about this Mac is advertised, and a Mac back from sleep is called again at once.
    private var name = ""
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [NWConnection] = []
    // The Macs this one called, by their names.
    private var calls: [String: NWConnection] = [:]
    var peers: Int { connections.filter { $0.state == .ready }.count }
    deinit { stop() }

    // The code becomes the key of the connection and never leaves this Mac: another code fails the handshake.
    static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = Data(SHA256.hash(data: Data(code.utf8))).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("gksdud".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        // A Mac that went to sleep says nothing; its connection is found dead in about 20 seconds.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 2
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // WebSocket only to keep each message whole, and to refuse a long one.
        let messages = NWProtocolWebSocket.Options(); messages.maximumMessageSize = 256
        parameters.defaultProtocolStack.applicationProtocols.insert(messages, at: 0)
        return parameters
    }
    func start(code: String) {
        stop()
        self.code = code; name = UUID().uuidString
        guard let listener = try? NWListener(using: Self.parameters(code: code)) else { problem = "동기화 연결을 열지 못했습니다."; return }
        listener.service = NWListener.Service(name: name, type: service)
        listener.newConnectionHandler = { [weak self] in self?.adopt($0) }
        listener.stateUpdateHandler = { [weak self] in self?.note($0) }
        listener.start(queue: .main); self.listener = listener
        let browser = NWBrowser(for: .bonjour(type: service, domain: nil), using: Self.parameters(code: code))
        browser.stateUpdateHandler = { [weak self] in self?.note($0) }
        browser.browseResultsChangedHandler = { [weak self] _, _ in self?.call() }
        browser.start(queue: .main); self.browser = browser
    }
    func stop() {
        listener?.cancel(); browser?.cancel(); listener = nil; browser = nil; problem = nil
        for connection in connections { connection.stateUpdateHandler = nil; connection.cancel() }
        connections = []; calls = [:]
    }
    private func note(_ state: NWListener.State) {
        switch state { case .failed(let error), .waiting(let error): fail(error); case .ready: problem = nil; default: break }
    }
    private func note(_ state: NWBrowser.State) {
        switch state { case .failed(let error), .waiting(let error): fail(error); case .ready: problem = nil; default: break }
    }
    // Mostly the local network permission, which macOS asks for once and reports only as a DNS error.
    private func fail(_ error: NWError) {
        problem = "로컬 네트워크를 쓸 수 없습니다. 시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서 허용해주세요. (\(error))"
    }
    // Of two Macs the one with the lesser name calls, so a pair has one connection.
    private func call() {
        for result in browser?.browseResults ?? [] {
            guard case .service(let other, _, _, _) = result.endpoint, other > name, calls[other] == nil else { continue }
            let connection = NWConnection(to: result.endpoint, using: Self.parameters(code: code))
            calls[other] = connection
            adopt(connection)
        }
    }
    private func adopt(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready: self.connected()
            // Waiting is for a network that may come back; calling again later finds the Mac where it is then.
            case .waiting, .failed: connection.cancel()
            case .cancelled:
                self.connections.removeAll { $0 === connection }
                guard let called = self.calls.first(where: { $0.value === connection })?.key else { return }
                self.calls[called] = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.call() }
            default: break
            }
        }
        receive(connection)
        connection.start(queue: .main)
    }
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, let data, error == nil else { connection?.cancel(); return }
            // Anything else from the other side is not a change, and is dropped.
            if let state = try? JSONDecoder().decode(SyncState.self, from: data) { self.received(state) }
            self.receive(connection)
        }
    }
    func send(_ state: SyncState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let context = NWConnection.ContentContext(identifier: "sync", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        for connection in connections where connection.state == .ready {
            connection.send(content: data, contentContext: context, completion: .idempotent)
        }
    }
}

extension AppDelegate {
    var syncActive: Bool { engine.syncSources && !engine.syncCode.isEmpty }
    // At launch, when the setting or the code changes, and after sleep.
    func updateSync() {
        guard syncActive else { syncLink.stop(); return }
        syncLink.received = { [weak self] in self?.syncReceived($0) }
        syncLink.connected = { [weak self] in self?.resendSync() }
        syncLink.start(code: engine.syncCode)
    }
    // The lock screen selects U.S. for itself, which is not a switch to pass on or to make there.
    func syncLocalChange() {
        guard syncActive, !engine.sessionAway(), let language = (logicalSource ?? currentSource)?.language,
              let state = syncClock.changed(String(language.prefix(2)), now: Date().timeIntervalSince1970) else { return }
        syncLink.send(state)
    }
    func syncReceived(_ state: SyncState) {
        guard syncActive, !engine.sessionAway(), let language = syncClock.received(state) else { return }
        // As `gksdud source ko` switches. Already there, it does nothing.
        _ = runCommand(["source", language])
    }
    // To a Mac that has just connected, and as the pointer leaves for the other Mac, before typing starts there.
    func resendSync() { if syncActive, let last = syncClock.last { syncLink.send(last) } }
    @objc func toggleSync() { setSync(syncSwitch.state == .on) }
    @objc func changeSyncCode() {
        engine.defaults.set(syncCodeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "syncCode")
        if engine.syncCode.isEmpty { engine.defaults.set(false, forKey: "syncSources") }
        updatePressAccess(); updateSync()
    }
    // Sync and an app's own source would each undo the other's switch, so one turns the other off.
    func setSync(_ on: Bool) {
        engine.defaults.set(on && !engine.syncCode.isEmpty, forKey: "syncSources")
        if engine.syncSources { appSourceRules.enabled = false; appSourceFocus.cancel() }
        updatePressAccess(); updateSync()
    }
}

#if TESTS
func runSyncTests() {
    var a = SyncClock(), b = SyncClock()
    precondition(a.changed("ja", now: 10) == nil && a.last == nil, "Only Korean and English are sent")
    let first = a.changed("ko", now: 10)!
    precondition(first == SyncState(language: "ko", at: 10) && a.changed("ko", now: 11) == nil, "A change is sent once")
    precondition(b.received(first) == "ko" && b.changed("ko", now: 10.2) == nil, "The landing of the other Mac's change is not sent back")
    precondition(b.received(first) == "ko", "The same change sent again is taken again")
    // The other Mac's clock is behind: its change still comes after the one it answers.
    let second = b.changed("en", now: 3)!
    precondition(second.at > first.at && a.received(second) == "en", "A later change wins whatever the clocks say")
    precondition(a.received(first) == nil && a.last == second, "An older change does not undo a later one")
    precondition(a.received(SyncState(language: "ja", at: 99)) == nil && a.received(SyncState(language: "ko", at: .nan)) == nil && a.last == second,
                 "A language this version does not know, or a broken time, is ignored")
    // Both changed at once: each keeps the later one.
    var c = SyncClock(), d = SyncClock()
    let early = c.changed("ko", now: 30)!, late = d.changed("en", now: 30.1)!
    precondition(c.received(late) == "en" && d.received(early) == nil && c.last == d.last, "Two changes at once end in the later one on both")

    // Two apps on this Mac with one code find each other and pass a change; one with another code hears nothing.
    let type = "_gksdud-test-\(UUID().uuidString.prefix(8).lowercased())._tcp"
    func link(_ code: String) -> (SyncLink, () -> [SyncState]) {
        let link = SyncLink(); var got: [SyncState] = []
        link.service = type; link.received = { got.append($0) }; link.start(code: code)
        return (link, { got })
    }
    let (one, heardOne) = link("same"), (two, heardTwo) = link("same"), (other, heardOther) = link("different")
    let state = SyncState(language: "ko", at: 1)
    one.connected = { one.send(state) }
    let deadline = Date().addingTimeInterval(10)
    while heardTwo().isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    // Where the local network is refused, as in a sandbox, this part cannot run.
    if let problem = one.problem ?? two.problem {
        print("SKIP: sync over the local network (\(problem))")
    } else {
        precondition(heardTwo() == [state] && heardOne().isEmpty && one.peers == 1 && two.peers == 1, "A change reaches the Mac with the same code")
        precondition(heardOther().isEmpty && other.peers == 0, "Another code connects to nothing")
        two.stop()
        let closed = Date().addingTimeInterval(5)
        while one.peers > 0 && Date() < closed { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        precondition(one.peers == 0, "A Mac that stops is no longer counted")
    }
    one.stop(); two.stop(); other.stop()

    // Turning sync on turns an app's own source off, and the other way; without a code it stays off.
    let suite = "io.gksdud.sync-tests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let engine = Engine(defaults: defaults, discover: { [] })
    engine.accessibilityTrusted = { true }; engine.sessionAway = { false }
    let delegate = AppDelegate(engine: engine)
    delegate.syncLink.service = type
    delegate.setSync(true)
    precondition(!engine.syncSources && !delegate.syncActive, "Without a code there is no Mac to sync with")
    delegate.syncCodeField.stringValue = " code "; delegate.changeSyncCode()
    delegate.appSourceRules.enabled = true
    delegate.setSync(true)
    precondition(engine.syncCode == "code" && delegate.syncActive && !delegate.appSourceRules.enabled, "Sync turns an app's own source off")
    delegate.appSourcesSettings.enable.state = .on; delegate.appSourcesSettings.toggle()
    precondition(delegate.appSourceRules.enabled && !delegate.syncActive, "An app's own source turns sync off")
    delegate.setSync(true)
    delegate.syncCodeField.stringValue = ""; delegate.changeSyncCode()
    precondition(!engine.syncSources, "Clearing the code turns sync off")
    delegate.syncLink.stop()
    print("PASS: sync keeps the latest change, sends no echo, ignores other languages, connects only with the same code, excludes an app's own source")
}
#endif
