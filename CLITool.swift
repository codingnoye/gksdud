import Foundation

// The gksdud command. The running app applies what it asks for, as its settings window would, and replies with text and
// JSON to print. Help, the version and launching the app need no app.
@main
enum Tool {
    static let arguments = Array(CommandLine.arguments.dropFirst())
    static var json = false

    static func main() {
        let invocation: CLI.Invocation
        json = arguments.contains("-j") || arguments.contains("--json")
        do { invocation = try CLI.parse(arguments) } catch { finish(error.localizedDescription, CLI.Exit.usage) }
        switch invocation.command {
        case .help(let topic):
            if topic == "settings" { json ? write(CLI.settingsJSON) : print(CLI.settingsHelp) }
            else if topic == nil { json ? write(["ok": true, "usage": CLI.usage]) : print(CLI.usage) }
            else { finish("help에는 settings만 붙일 수 있습니다.", CLI.Exit.usage) }
            exit(CLI.Exit.ok)
        case .version:
            let version = app.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "unknown"
            json ? write(["ok": true, "version": version]) : print("gksdud \(version)")
            exit(CLI.Exit.ok)
        case .start: start()
        default: break
        }
        guard var reply = send(arguments) else { finish("gksdud가 실행 중이 아닙니다. gksdud start로 실행하세요.", CLI.Exit.notRunning) }
        if case .source(.some) = invocation.command, invocation.options.wait, reply.exit == CLI.Exit.ok,
           reply.json["switched"] as? Bool == true, let target = (reply.json["to"] as? [String: Any])?["id"] as? String {
            let landed = waitForSource(target)
            reply.json["landed"] = landed
            if !landed { reply.exit = CLI.Exit.failed; reply.json["ok"] = false; reply.text += "\n전환을 확인하지 못했습니다." }
        }
        if json { write(reply.json) }
        else if !reply.text.isEmpty {
            // Results go to standard output even when some failed; wrong arguments go to standard error.
            if reply.exit >= CLI.Exit.usage { fputs(reply.text + "\n", stderr) } else { print(reply.text) }
        }
        exit(reply.exit)
    }

    // The app this command belongs to, through the link it was run by.
    static var app: URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let bundle = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "app" ? bundle : nil
    }

    struct Reply { var exit: Int32; var text: String; var json: [String: Any] }
    // While the app applies a change, it asks again for a few seconds.
    static func send(_ arguments: [String]) -> Reply? {
        let deadline = Date().addingTimeInterval(3)
        while true {
            let reply = request(arguments)
            guard reply?.json["busy"] as? Bool == true, Date() < deadline else { return reply }
            usleep(50_000)
        }
    }
    static func request(_ arguments: [String]) -> Reply? {
        guard let port = CFMessagePortCreateRemote(nil, CLI.port as CFString),
              let request = try? JSONSerialization.data(withJSONObject: ["args": arguments]) else { return nil }
        var data: Unmanaged<CFData>?
        // Applying can wait on macOS's own settings for a moment.
        guard CFMessagePortSendRequest(port, 1, request as CFData, 2, 20, CFRunLoopMode.defaultMode.rawValue, &data) == kCFMessagePortSuccess,
              let body = data?.takeRetainedValue() as Data?,
              let reply = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Reply(exit: CLI.Exit.notRunning, text: "gksdud가 응답하지 않습니다.", json: ["ok": false, "error": "gksdud가 응답하지 않습니다."])
        }
        return Reply(exit: (reply["exit"] as? NSNumber)?.int32Value ?? CLI.Exit.failed, text: reply["text"] as? String ?? "",
                     json: reply["json"] as? [String: Any] ?? [:])
    }

    // The app reports a switch as soon as it sends it; this asks until the input source is there.
    static func waitForSource(_ id: String) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if send(["source"])?.json["id"] as? String == id { return true }
            usleep(5_000)
        } while Date() < deadline
        return false
    }

    static func start() -> Never {
        if CFMessagePortCreateRemote(nil, CLI.port as CFString) != nil { finish("gksdud가 이미 실행 중입니다.", CLI.Exit.ok) }
        guard let app else { finish("gksdud 앱을 찾지 못했습니다.", CLI.Exit.failed) }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [app.path]
        do { try open.run(); open.waitUntilExit() } catch { finish(error.localizedDescription, CLI.Exit.failed) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if CFMessagePortCreateRemote(nil, CLI.port as CFString) != nil { finish("gksdud를 실행했습니다.", CLI.Exit.ok) }
            usleep(50_000)
        }
        finish("gksdud가 응답하지 않습니다.", CLI.Exit.notRunning)
    }

    static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
    static func finish(_ message: String, _ code: Int32) -> Never {
        if json { write(["ok": code == CLI.Exit.ok, code == CLI.Exit.ok ? "message" : "error": message]) }
        else if code == CLI.Exit.ok { print(message) }
        else { fputs(message + "\n", stderr) }
        exit(code)
    }
}
