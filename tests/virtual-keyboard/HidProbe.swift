import AppKit
import Carbon
import IOKit

// Presses keys on a Karabiner virtual keyboard through vhid-keys, so macOS, the input method and the running gksdud
// see them like a physical keyboard. Checks the input source, the Caps Lock lock and the typed text in its own window.
// Arguments: <vhid-keys socket> [--reset]. --reset only leaves English lowercase remembered and exits.

let socketPath = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") } ?? ""
func log(_ line: String) { print(line); fflush(stdout) }
func fail(_ message: String) -> Never { log("ABORT: \(message)"); exit(2) }

// MARK: - vhid-keys
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: Array(socketPath.utf8.prefix(raw.count - 1)) + [0]) }
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0, let stream = fdopen(fd, "r+") else { fail("cannot connect to vhid-keys at \(socketPath)") }
func send(_ command: String) -> String {
    fputs(command + "\n", stream); fflush(stream)
    var buffer = [CChar](repeating: 0, count: 256)
    return fgets(&buffer, 256, stream).map { String(cString: $0).trimmingCharacters(in: .newlines) } ?? "closed"
}
guard send("ping") == "ok" else { fail("the virtual keyboard is not ready") }

// MARK: - State
func withHIDSystem<T>(_ body: (io_connect_t) -> T?) -> T? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    defer { IOObjectRelease(service) }
    var connection: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else { return nil }
    defer { IOServiceClose(connection) }
    return body(connection)
}
func lock() -> Bool {
    withHIDSystem { connection in
        var state = false
        return IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS ? state : nil
    } ?? false
}
func language(_ source: TISInputSource) -> String {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return "" }
    return (Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String])?.first ?? ""
}
func currentLanguage() -> String { language(TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()) }
func available(_ prefix: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceIsEnabled as String: true, kTISPropertyInputSourceIsSelectCapable as String: true,
                  kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
    let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    return list.first { language($0).hasPrefix(prefix) }
}
guard let english = available("en"), let korean = available("ko") else { fail("English and Korean input sources are required") }

// The running app's settings, read only. The first single key chosen as a Korean/English key switches.
let settings = UserDefaults(suiteName: "io.gksdud.inputswitch")!
let singleKeys: [(UInt64, String)] = [(0x7000000e7, "rcmd"), (0x7000000e6, "ropt"), (0x700000039, "caps"), (0x7000000e4, "rctrl")]
let chosen = (settings.string(forKey: "source") ?? "\(singleKeys[0].0)").split(separator: ",").compactMap { UInt64($0) }
guard let switchKey = singleKeys.first(where: { chosen.contains($0.0) && $0.1 != "caps" })?.1 else {
    fail("choose right Command, right Option or right Control as a Korean/English key; Caps Lock is needed as Caps Lock")
}
let preserve = settings.object(forKey: "preserveCapsLock") as? Bool ?? true
let koreanCaps = preserve && settings.bool(forKey: "koreanCapsLock")

// MARK: - Window
// ESC in a text view would open completions, so everything but typing goes to a plain view.
final class KeySink: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}
}
let app = NSApplication.shared
app.setActivationPolicy(.regular); app.finishLaunching()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "gksdud 가상 키보드 테스트 (키보드를 만지지 마세요)"
let text = NSTextView(frame: NSRect(x: 10, y: 10, width: 440, height: 120)), sink = KeySink(frame: .zero)
text.font = .systemFont(ofSize: 24); window.contentView!.addSubview(text); window.contentView!.addSubview(sink)
window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(sink); app.activate(ignoringOtherApps: true)
func pump(_ duration: TimeInterval) {
    let end = Date(timeIntervalSinceNow: duration)
    while Date() < end {
        if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default, dequeue: true) { app.sendEvent(event) }
    }
}
func focused() -> Bool { app.isActive && window.isKeyWindow }
pump(0.8)
// With Caps Lock in Korean, the lock in Korean shows the remembered English case too.
let savedSource = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue(), savedLock = lock()

// MARK: - Keys
func press(_ key: String, hold: TimeInterval = 0.03) {
    guard focused() else { restore(); fail("the test window lost focus before \(key)") }
    guard send("down \(key)") == "ok" else { restore(); fail("vhid-keys refused \(key)") }
    // Apple keyboards ignore a Caps Lock tap shorter than their Caps Lock delay.
    pump(key == "caps" ? max(hold, 0.25) : hold)
    _ = send("up \(key)")
    pump(0.03)
}
// gksdud ignores software lock changes, so the English case it remembers is set back with a real Caps Lock press.
func restore(englishCaps: Bool = savedLock) {
    _ = send("release")
    window.makeFirstResponder(sink)
    _ = TISSelectInputSource(english); pump(0.6)
    if lock() != englishCaps && focused() { _ = send("down caps"); pump(0.25); _ = send("up caps"); pump(0.4) }
    _ = TISSelectInputSource(savedSource); pump(0.6)
}
func state() -> String { "\(currentLanguage()) Caps Lock \(lock() ? "on" : "off")" }
func typed(_ key: String) -> String {
    window.makeFirstResponder(text); text.inputContext?.discardMarkedText(); text.string = ""; pump(0.05)
    press(key); pump(0.2)
    defer { text.inputContext?.discardMarkedText(); text.string = ""; window.makeFirstResponder(sink) }
    return text.string
}
var passed = 0, total = 0
func check(_ name: String, _ language: String, caps: Bool, letter: String? = nil) {
    let result = letter.map { _ in typed("r") }
    let ok = currentLanguage().hasPrefix(language) && lock() == caps && result == letter
    total += 1; if ok { passed += 1 }
    log("\(ok ? "PASS" : "FAIL"): \(name) — \(state())\(result.map { ", r types \($0)" } ?? "")")
}
func switchSource(_ settle: TimeInterval = 0.8) { press(switchKey); pump(settle) }
func start(_ source: TISInputSource, caps: Bool) {
    window.makeFirstResponder(sink)
    _ = TISSelectInputSource(source); pump(0.6)
    if lock() != caps { press("caps"); pump(0.4) }
    guard currentLanguage() == language(source), lock() == caps else { restore(); fail("could not start from \(language(source)) with Caps Lock \(caps)") }
}

guard focused() else { restore(); fail("the test window did not become active") }
if CommandLine.arguments.contains("--reset") { restore(englishCaps: false); log("reset: \(state())"); exit(0) }
log("gksdud: switch key \(switchKey), preserve \(preserve), Caps Lock in Korean \(koreanCaps), ESC \(settings.bool(forKey: "escapeToEnglish"))")
// gksdud maps the switch key on a new keyboard within a second.
start(english, caps: false)
var mapped = false
for _ in 0..<5 where !mapped { switchSource(); mapped = currentLanguage().hasPrefix("ko"); if !mapped { pump(0.6) } }
guard mapped else { restore(); fail("the switch key did not switch; is gksdud running and active?") }

// A Caps Lock press in English survives a round trip through Korean.
start(english, caps: false)
press("caps"); pump(0.3)
check("Caps Lock key in English", "en", caps: true, letter: "R")
switchSource()
check("to Korean", "ko", caps: koreanCaps, letter: "ㄱ")
switchSource()
check("back to English", "en", caps: preserve, letter: preserve ? "R" : "r")
// Caps Lock in Korean sets the English case.
if koreanCaps {
    switchSource()
    press("caps"); pump(0.3)
    check("Caps Lock key in Korean", "ko", caps: false, letter: "ㄱ")
    switchSource()
    check("English follows the Caps Lock pressed in Korean", "en", caps: false, letter: "r")
}
// ESC ends in English lowercase.
if settings.bool(forKey: "escapeToEnglish") {
    start(english, caps: false); switchSource()
    press("esc"); pump(0.8)
    check("ESC in Korean", "en", caps: false, letter: "r")
    start(english, caps: true)
    press("esc"); pump(0.8)
    check("ESC in English uppercase", "en", caps: false, letter: "r")
    // ESC goes down while the switch key is still held, before the switch lands.
    start(english, caps: false); switchSource()
    _ = send("down \(switchKey)"); _ = send("down esc"); pump(0.03); _ = send("up \(switchKey)"); _ = send("up esc"); pump(0.8)
    check("ESC rolled over the switch key", "en", caps: false, letter: "r")
    // The same from English: the switch on its way leaves English, so ESC comes back.
    start(english, caps: false)
    _ = send("down \(switchKey)"); _ = send("down esc"); pump(0.03); _ = send("up \(switchKey)"); _ = send("up esc"); pump(0.8)
    check("ESC rolled over the switch key in English", "en", caps: false, letter: "r")
}
// A Caps Lock press right after a switch into English is the user's, not the input method's.
start(english, caps: false); switchSource()
switchSource(0.05); press("caps"); pump(0.8)
check("Caps Lock 0.05 s after switching to English", "en", caps: true)

restore()
log("RESULT: \(passed)/\(total)")
exit(passed == total ? 0 : 1)
