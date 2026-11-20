import AppKit
import CryptoKit
import Network

// Input source sync, off by default. Under Universal Control each Mac keeps its own input source, and nothing built in
// carries an app's value both ways: keys go one way, only while the pointer is away. So the Macs that share a code
// find each other on the local network, or on Tailscale from farther away, and tell each other the language of the
// latest switch.
struct SyncState: Codable, Equatable {
    var language: String
    // The sender's clock, in seconds since 1970.
    var at: TimeInterval
}
// What a Mac says first on a connection, so that one reached over both networks counts once.
struct SyncHello: Codable { var name: String }

// Which change is the latest. Only the language is kept, never typed text.
struct SyncClock {
    // Korean and English for now. Another language is neither sent nor taken, so a later version can add it.
    static let languages = ["ko", "en"]
    private(set) var last: SyncState?
    // The language this Mac was last seen in, or is on its way to for the other Mac. Not the last one sent: Japanese
    // is not sent, yet coming back from it to Korean is a change, with the other Mac perhaps elsewhere by then.
    private var here: String?
    // A change made here, to send. Nil when it is the landing of a change the other Mac asked for.
    mutating func changed(_ language: String, now: TimeInterval) -> SyncState? {
        guard language != here else { return nil }
        here = language
        guard Self.languages.contains(language) else { return nil }
        // After the last change known, even with this Mac's clock behind the other's.
        last = SyncState(language: language, at: max(now, (last?.at ?? 0) + 0.001))
        return last
    }
    // The other Mac's change: the language to switch to, unless a later one is known. The same change sent again is
    // taken again, so a resend makes up for one that was missed.
    mutating func received(_ state: SyncState) -> String? {
        guard Self.languages.contains(state.language), state.at >= (last?.at ?? 0) else { return nil }
        last = state; here = state.language
        return state.language
    }
}

// The connections to the other Macs with the same code. Everything runs on the main queue.
final class SyncLink {
    static let service = "_gksdud-sync._tcp"
    // Fixed, as a Mac on Tailscale has no Bonjour to learn it from.
    static let port: NWEndpoint.Port = 47583
    var service = SyncLink.service
    var port: NWEndpoint.Port? = SyncLink.port
    // Finds the Macs to call that Bonjour does not reach.
    var tailnet: (@escaping ([NWEndpoint]) -> Void) -> Void = SyncLink.tailnet
    var received: (SyncState) -> Void = { _ in }
    // A Mac has connected, and has yet to hear the latest change.
    var connected: () -> Void = {}
    // Why it cannot look for other Macs, such as the local network permission being refused.
    private(set) var problem: String?
    private var code = ""
    // New each start: nothing about this Mac is advertised, and a Mac back from sleep is called again at once.
    private var name = ""
    private var listener: NWListener?
    private(set) var tailnetListener: NWListener?
    private var browser: NWBrowser?
    private var timer: Timer?
    private var connections: [NWConnection] = []
    // The Macs this one called, by their names, or by their addresses on Tailscale.
    private var calls: [String: NWConnection] = [:]
    // The name each connected Mac gave.
    private var names: [ObjectIdentifier: String] = [:]
    var peers: Int { Set(connections.filter { $0.state == .ready }.compactMap { names[ObjectIdentifier($0)] }).count }
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
        // Tailscale takes a while to learn that a Mac sleeps; a call to one is given up, to be made again once it wakes.
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // WebSocket only to keep each message whole, and to refuse a long one.
        let messages = NWProtocolWebSocket.Options(); messages.maximumMessageSize = 256
        parameters.defaultProtocolStack.applicationProtocols.insert(messages, at: 0)
        return parameters
    }
    // A Mac on Tailscale is called at an address. WebSocket connects to one only as a URL.
    static func endpoint(_ address: String, port: NWEndpoint.Port = SyncLink.port) -> NWEndpoint? {
        URL(string: "wss://\(address.contains(":") ? "[\(address)]" : address):\(port.rawValue)").map { .url($0) }
    }
    // From `tailscale status --json`: the addresses of this account's other Macs that are online, for this Mac to call.
    // As with names, of two Macs the one with the lesser address calls. Only the account's own are called, so that a
    // company's tailnet is not knocked on Mac by Mac.
    static func tailnetCalls(status: Data) -> [String] {
        struct Node: Decodable { var TailscaleIPs: [String]?, UserID: Int?, OS: String?, Online: Bool? }
        struct Status: Decodable {
            var BackendState: String, own: Node, Peer: [String: Node]?
            enum CodingKeys: String, CodingKey { case BackendState, own = "Self", Peer }
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: status), status.BackendState == "Running",
              let own = status.own.TailscaleIPs?.first else { return [] }
        return (status.Peer ?? [:]).values.filter { $0.OS == "macOS" && $0.Online == true && $0.UserID == status.own.UserID }
            .compactMap { $0.TailscaleIPs?.first }.filter { $0 > own }
    }
    // Asks Tailscale's own command, off the main queue. Without Tailscale there is nothing to find.
    static func tailnet(_ found: @escaping ([NWEndpoint]) -> Void) {
        let paths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = ["status", "--json"]
        // Away from a terminal the app's binary takes itself for the app, unless told that it is the command.
        process.environment = ProcessInfo.processInfo.environment.merging(["TAILSCALE_BE_CLI": "1"]) { $1 }
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        DispatchQueue.global(qos: .utility).async {
            guard (try? process.run()) != nil else { return }
            // A command that hangs does not keep this thread.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
            let status = output.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async { found(tailnetCalls(status: status).compactMap { endpoint($0) }) }
        }
    }
    func start(code: String) {
        stop()
        self.code = code; name = UUID().uuidString
        guard let listener = try? NWListener(using: Self.parameters(code: code)) else { problem = "동기화 연결을 열지 못했습니다."; return }
        listener.service = NWListener.Service(name: name, type: service)
        listener.newConnectionHandler = { [weak self] in self?.adopt($0) }
        listener.stateUpdateHandler = { [weak self] in self?.note($0) }
        listener.start(queue: .main); self.listener = listener
        listenAtPort()
        let browser = NWBrowser(for: .bonjour(type: service, domain: nil), using: Self.parameters(code: code))
        browser.stateUpdateHandler = { [weak self] in self?.note($0) }
        browser.browseResultsChangedHandler = { [weak self] _, _ in self?.call() }
        browser.start(queue: .main); self.browser = browser
        // Tailscale tells nothing of a Mac that wakes or joins, so it is asked again and again.
        // shortcut: its command runs every 15 seconds while sync is on, Tailscale's LocalAPI can notify instead if that costs.
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.tailnet { endpoints in
                guard let self, self.timer != nil else { return }
                for endpoint in endpoints { self.call(endpoint, as: "\(endpoint)") }
            }
        }
        self.timer = timer; timer.fire()
    }
    func stop() {
        listener?.cancel(); tailnetListener?.cancel(); browser?.cancel(); timer?.invalidate()
        listener = nil; tailnetListener = nil; browser = nil; timer = nil; problem = nil
        for connection in connections { connection.stateUpdateHandler = nil; connection.cancel() }
        connections = []; calls = [:]; names = [:]
    }
    // Where the Macs on Tailscale call. A listener of its own: the one Bonjour tells of fails with the local network refused.
    private func listenAtPort(again: Bool = true) {
        tailnetListener?.cancel()
        guard let listener = try? NWListener(using: Self.parameters(code: code), on: port ?? .any) else { return }
        listener.newConnectionHandler = { [weak self] in self?.adopt($0) }
        // The listener before a restart holds the port a moment longer, so it is asked for once more.
        // shortcut: a port another program holds is given up in silence, and this Mac is then reached on Tailscale only
        // where it is the one to call; report it if that comes up.
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard again, case .failed(.posix(.EADDRINUSE)) = state else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let self, let listener, self.tailnetListener === listener { self.listenAtPort(again: false) }
            }
        }
        listener.start(queue: .main); tailnetListener = listener
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
            guard case .service(let other, _, _, _) = result.endpoint, other > name else { continue }
            call(result.endpoint, as: other)
        }
    }
    private func call(_ endpoint: NWEndpoint, as other: String) {
        guard calls[other] == nil else { return }
        let connection = NWConnection(to: endpoint, using: Self.parameters(code: code))
        calls[other] = connection
        adopt(connection)
    }
    private func adopt(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready: self.send(SyncHello(name: self.name), to: [connection]); self.connected()
            // Waiting is for a network that may come back; calling again later finds the Mac where it is then.
            case .waiting, .failed: connection.cancel()
            case .cancelled:
                self.connections.removeAll { $0 === connection }
                self.names[ObjectIdentifier(connection)] = nil
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
            // Anything else from the other side is neither a change nor a name, and is dropped.
            if let state = try? JSONDecoder().decode(SyncState.self, from: data) { self.received(state) }
            else if let hello = try? JSONDecoder().decode(SyncHello.self, from: data) { self.names[ObjectIdentifier(connection)] = hello.name }
            self.receive(connection)
        }
    }
    // A Mac connected over both networks hears a change twice, and takes the second as a resend.
    func send(_ state: SyncState) { send(state, to: connections) }
    private func send<Message: Encodable>(_ message: Message, to connections: [NWConnection]) {
        guard let data = try? JSONEncoder().encode(message) else { return }
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
    // A code to read on one Mac and type on the other, so without the letters and digits taken for one another.
    static func newSyncCode() -> String {
        let letters = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return (0..<3).map { _ in String((0..<4).map { _ in letters.randomElement()! }) }.joined(separator: "-")
    }
    // A code being typed in the field gives way to the new one.
    @objc func generateSyncCode() { syncCodeField.abortEditing(); syncCodeField.stringValue = Self.newSyncCode(); changeSyncCode() }
    // Sync and an app's own source would each undo the other's switch, so one turns the other off.
    func setSync(_ on: Bool) {
        // Turned on for the first time, it starts with a code of its own.
        if on && engine.syncCode.isEmpty { engine.defaults.set(Self.newSyncCode(), forKey: "syncCode") }
        engine.defaults.set(on, forKey: "syncSources")
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
    // Both in Korean, then both in Japanese, which is not sent: one coming back to Korean brings the other along.
    var e = SyncClock(), f = SyncClock()
    let before = e.changed("ko", now: 40)!
    precondition(f.received(before) == "ko" && f.changed("ko", now: 40.1) == nil && e.changed("ja", now: 41) == nil && f.changed("ja", now: 41) == nil
        && e.last == before, "A language that is not synced is not sent")
    let back = e.changed("ko", now: 42)
    precondition(back.map { $0.language == "ko" && $0.at > before.at && f.received($0) == "ko" } == true && e.changed("ko", now: 43) == nil,
                 "Coming back from it is sent again")

    // Of the Macs Tailscale lists, this one calls its account's other Macs that are online and have a greater address.
    func node(_ address: String, user: Int = 1, os: String = "macOS", online: Bool = true) -> String {
        "{\"TailscaleIPs\":[\"\(address)\",\"fd7a::1\"],\"UserID\":\(user),\"OS\":\"\(os)\",\"Online\":\(online)}"
    }
    func status(_ backend: String) -> Data {
        Data("""
            {"BackendState":"\(backend)","Self":\(node("100.64.0.5")),"Peer":{"a":\(node("100.64.0.9")),"b":\(node("100.64.0.1")),
             "c":\(node("100.64.0.6", online: false)),"d":\(node("100.64.0.7", user: 2)),"e":\(node("100.64.0.8", os: "iOS"))}}
            """.utf8)
    }
    precondition(SyncLink.tailnetCalls(status: status("Running")) == ["100.64.0.9"] && SyncLink.tailnetCalls(status: status("Stopped")).isEmpty
        && SyncLink.tailnetCalls(status: Data()).isEmpty, "Tailscale's own, online Macs with a greater address are called")
    precondition("\(SyncLink.endpoint("100.64.0.9")!)" == "wss://100.64.0.9:47583" && "\(SyncLink.endpoint("fd7a::1")!)" == "wss://[fd7a::1]:47583",
                 "A Mac on Tailscale is called at the fixed port")

    // Apps on this Mac with one code find each other and pass a change; one with another code hears nothing.
    let type = "_gksdud-test-\(UUID().uuidString.prefix(8).lowercased())._tcp"
    func link(_ code: String, service: String = type, port: NWEndpoint.Port? = nil, calls: [NWEndpoint] = []) -> (SyncLink, () -> [SyncState]) {
        let link = SyncLink(); var got: [SyncState] = []
        link.service = service; link.port = port; link.tailnet = { $0(calls) }; link.received = { got.append($0) }; link.start(code: code)
        return (link, { got })
    }
    func wait(_ seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let (one, heardOne) = link("same"), (two, heardTwo) = link("same")
    wait(5) { one.tailnetListener?.state == .ready }
    // As after sleep, the port is asked for again while the listener before still holds it.
    let port = one.tailnetListener!.port!
    one.port = port; one.start(code: "same")
    wait(5) { one.tailnetListener?.state == .ready }
    precondition(one.tailnetListener?.state == .ready && one.tailnetListener?.port == port, "A restart listens on the same port")
    // Called at its address, as on Tailscale, by a Mac with no Bonjour in common, at two addresses.
    let there = [SyncLink.endpoint("127.0.0.1", port: port)!, SyncLink.endpoint("::1", port: port)!]
    let (far, heardFar) = link("same", service: type.replacingOccurrences(of: "test", with: "away"), calls: there)
    let (other, heardOther) = link("different", calls: there)
    let state = SyncState(language: "ko", at: 1)
    var ways = 0
    one.connected = { one.send(state) }; far.connected = { ways += 1 }
    // Where the local network is refused, as in a sandbox, the part over Bonjour cannot run.
    func local() -> Bool { (one.problem ?? two.problem) == nil }
    wait(10) { ways == 2 && far.peers == 1 && !heardFar().isEmpty && one.peers == (local() ? 2 : 1) && (!local() || !heardTwo().isEmpty && two.peers == 1) }
    precondition(ways == 2 && far.peers == 1 && one.peers == (local() ? 2 : 1), "A Mac reached two ways counts once")
    precondition(!heardFar().isEmpty && heardFar().allSatisfy { $0 == state } && heardOne().isEmpty, "A change reaches the Mac called at its address")
    precondition(heardOther().isEmpty && other.peers == 0, "Another code connects to nothing")
    if local() {
        precondition(!heardTwo().isEmpty && heardTwo().allSatisfy { $0 == state } && two.peers == 1, "A change reaches the Mac with the same code")
    } else {
        print("SKIP: sync over the local network (\(one.problem ?? two.problem ?? ""))")
    }
    two.stop(); far.stop()
    wait(5) { one.peers == 0 }
    precondition(one.peers == 0, "A Mac that stops is no longer counted")
    one.stop(); other.stop()

    // Turning sync on turns an app's own source off, and the other way; without a code it stays off.
    let suite = "io.gksdud.sync-tests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let engine = Engine(defaults: defaults, discover: { [] })
    engine.accessibilityTrusted = { true }; engine.sessionAway = { false }
    let delegate = AppDelegate(engine: engine)
    delegate.syncLink.service = type; delegate.syncLink.port = nil; delegate.syncLink.tailnet = { $0([]) }
    delegate.buildWindow()
    precondition(delegate.syncSwitch.isEnabled && delegate.syncCodeField.superview?.isHidden == true, "The code shows only with sync on")
    delegate.setSync(true)
    let made = engine.syncCode
    precondition(delegate.syncActive && made.count == 14 && made == made.lowercased() && delegate.syncCodeField.stringValue == made
        && delegate.syncCodeField.superview?.isHidden == false, "Sync turned on first makes its own code, and shows it")
    delegate.setSync(false); delegate.setSync(true)
    precondition(engine.syncCode == made && delegate.syncActive, "A code is kept while sync is off")
    delegate.generateSyncCode()
    precondition(engine.syncCode != made && engine.syncCode.count == 14 && delegate.syncActive && delegate.syncCodeField.stringValue == engine.syncCode,
                 "The button makes another code")
    delegate.syncCodeField.stringValue = " code "; delegate.changeSyncCode()
    delegate.appSourceRules.enabled = true
    delegate.setSync(true)
    precondition(engine.syncCode == "code" && delegate.syncActive && !delegate.appSourceRules.enabled, "Sync turns an app's own source off")
    delegate.appSourcesSettings.enable.state = .on; delegate.appSourcesSettings.toggle()
    precondition(delegate.appSourceRules.enabled && !delegate.syncActive, "An app's own source turns sync off")
    delegate.setSync(true)
    delegate.syncCodeField.stringValue = ""; delegate.changeSyncCode()
    precondition(!engine.syncSources && delegate.syncCodeField.superview?.isHidden == true, "Clearing the code turns sync off")
    delegate.syncLink.stop()
    print("PASS: sync keeps the latest change, sends no echo, ignores other languages, connects only with the same code, calls a Mac on Tailscale, makes its own code, excludes an app's own source")
}
#endif
