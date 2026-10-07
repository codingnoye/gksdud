import Foundation

// The gksdud command's settings, arguments and help, shared by the command-line tool and the app that runs its commands.
// Foundation only, so the tool starts quickly.
enum CLI {
    static let port = "io.gksdud.inputswitch.cli"
    // 0 everything done, 1 something failed, 2 the arguments were wrong, 3 the app did not answer.
    enum Exit { static let ok: Int32 = 0, failed: Int32 = 1, usage: Int32 = 2, notRunning: Int32 = 3 }

    enum Kind: Equatable {
        case bool
        case choice([String])
        // Korean/English keys, comma-separated; `single` leaves out the Space combinations, as a keyboard maps only those.
        case keys(single: Bool)
        case key
        case sources
        case source
        var isList: Bool { if case .keys = self { return true }; return self == .sources }
    }
    struct Setting { let name: String; let kind: Kind; let title: String }
    enum Value: Equatable { case bool(Bool), text(String), list([String]), none }

    // In the order the app offers them.
    static let keyNames = ["right-command", "right-option", "caps-lock", "right-control", "ctrl-space", "cmd-space", "opt-space", "shift-space"]
    static let singleKeyNames = Array(keyNames.prefix(4))
    static let iconNames = ["dud", "a", "ko-en", "character"]
    static let targetNames = (13...20).map { "F\($0)" }
    static let specialNames = ["off", "english", "block"]
    static let settings: [Setting] = [
        Setting(name: "active", kind: .bool, title: "활성화"),
        Setting(name: "paused", kind: .bool, title: "일시정지 (앱을 다시 실행하면 풀림)"),
        Setting(name: "login", kind: .bool, title: "로그인 시 시작"),
        Setting(name: "menubar", kind: .bool, title: "메뉴바에 표시"),
        Setting(name: "replace-input-menu", kind: .bool, title: "Mac 입력기 아이콘 대체"),
        Setting(name: "icon", kind: .choice(iconNames), title: "메뉴바 아이콘 (한/dud, 한/A, KO/EN, ㅎuㅎ/dud)"),
        Setting(name: "keys", kind: .keys(single: false), title: "한영 키"),
        Setting(name: "target", kind: .choice(targetNames), title: "내부 전환 키 (고급 설정)"),
        Setting(name: "keyboard-default", kind: .bool, title: "키보드 기본값 (고급 설정)"),
        Setting(name: "long-press", kind: .bool, title: "길게 눌러 대소문자 전환"),
        Setting(name: "preserve-case", kind: .bool, title: "한영 전환시 대소문자 보존"),
        Setting(name: "korean-caps-lock", kind: .bool, title: "한글 상태에서도 Caps Lock으로 대소문자 전환"),
        Setting(name: "special-chars", kind: .choice(specialNames), title: "특수문자 (끔, 영어처럼 입력, Option 문자 입력 차단)"),
        Setting(name: "added-sources", kind: .bool, title: "입력 소스 추가"),
        Setting(name: "added-mode", kind: .choice(["cycle", "separate"]), title: "입력 소스 추가 전환 방식 (순회, 분리)"),
        Setting(name: "cycle", kind: .sources, title: "순회 순서"),
        Setting(name: "separate-key", kind: .key, title: "분리 전환 키"),
        Setting(name: "separate-source", kind: .source, title: "분리로 전환할 입력 소스"),
        Setting(name: "compatibility", kind: .bool, title: "입력 소스 추가 호환성 모드"),
        Setting(name: "escape", kind: .bool, title: "ESC 누를 시 영소문자로 변경"),
    ]
    // keyboard.<keyboard>.mode and keyboard.<keyboard>.keys.
    static let keyboardSettings: [Setting] = [
        Setting(name: "mode", kind: .choice(["on", "default", "off"]), title: "키보드별 적용"),
        Setting(name: "keys", kind: .keys(single: true), title: "키보드별 한영 키 (default면 기본 한영 키를 따름)"),
    ]

    // A setting the arguments name: a global one, or one of the keyboards a selector picks.
    struct Address: Equatable {
        let name: String
        let keyboard: String?
        var label: String { keyboard.map { "keyboard.\($0).\(name)" } ?? name }
    }
    enum Operation: String { case set = "=", add = "+=", remove = "-=" }
    struct Change: Equatable { let address: Address; let operation: Operation; let value: Value }
    enum Command: Equatable {
        case help(String?), version, start, quit, status, sources, keyboards
        case get([Address]), set([Change]), toggle([Address]), source(String?)
    }
    // `alert`: errors the settings window shows in a window show there too.
    struct Options: Equatable { var json = false, force = false, wait = false, alert = true }
    struct Invocation: Equatable { var command: Command; var options = Options() }
    struct UsageError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func parse(_ arguments: [String]) throws -> Invocation {
        var options = Options(), words: [String] = [], help = false
        for argument in arguments {
            switch argument {
            case "-j", "--json": options.json = true
            case "-f", "--force": options.force = true
            case "-w", "--wait": options.wait = true
            case "--no-alert": options.alert = false
            case "-h", "--help": help = true
            case "-v", "--version": words.insert("version", at: 0)
            // As issue #47 asked for them.
            case "--enable": words.append("enable")
            case "--disable": words.append("disable")
            case "--im": words.append("source")
            default:
                guard !argument.hasPrefix("-") || argument == "-" else { throw UsageError("알 수 없는 옵션: \(argument)") }
                words.append(argument)
            }
        }
        if help { return Invocation(command: .help(words.first == "help" ? words.dropFirst().first : nil), options: options) }
        guard let name = words.first else { return Invocation(command: .help(nil), options: options) }
        let rest = Array(words.dropFirst())
        func bare(_ command: Command) throws -> Command {
            guard rest.isEmpty else { throw UsageError("\(name)에는 인자가 없습니다.") }
            return command
        }
        func needed() throws { if rest.isEmpty { throw UsageError("\(name)에 바꿀 설정을 적어주세요. 예: gksdud \(name) long-press\(name == "set" ? "=on" : "")") } }
        let command: Command
        switch name {
        case "help":
            guard rest.count <= 1 else { throw UsageError("help에는 settings만 붙일 수 있습니다.") }
            command = .help(rest.first)
        case "version": command = try bare(.version)
        case "start": command = try bare(.start)
        case "quit": command = try bare(.quit)
        case "status": command = try bare(.status)
        case "sources": command = try bare(.sources)
        case "keyboards": command = try bare(.keyboards)
        case "get": command = .get(try rest.map { try setting($0).0 })
        case "set": try needed(); command = .set(try rest.map(change))
        case "toggle":
            try needed()
            command = .toggle(try rest.map { word in
                let (address, setting) = try self.setting(word)
                guard setting.kind == .bool else { throw UsageError("\(word)은 on/off 설정이 아니라 toggle할 수 없습니다.") }
                return address
            })
        case "enable", "disable":
            // Turning on also ends a pause, which activation already on would otherwise keep.
            let active = Change(address: Address(name: "active", keyboard: nil), operation: .set, value: .bool(name == "enable"))
            let resume = Change(address: Address(name: "paused", keyboard: nil), operation: .set, value: .bool(false))
            command = try bare(.set(name == "enable" ? [active, resume] : [active]))
        case "pause", "resume":
            command = try bare(.set([Change(address: Address(name: "paused", keyboard: nil), operation: .set, value: .bool(name == "pause"))]))
        case "source":
            guard rest.count <= 1 else { throw UsageError("입력 소스는 하나만 적어주세요. 이름에 공백이 있으면 따옴표로 감싸주세요.") }
            command = .source(rest.first)
        default: throw UsageError("알 수 없는 명령: \(name). gksdud help로 명령을 확인하세요.")
        }
        return Invocation(command: command, options: options)
    }

    static func setting(_ text: String) throws -> (Address, Setting) {
        if let setting = settings.first(where: { $0.name == text }) { return (Address(name: text, keyboard: nil), setting) }
        // The keyboard's name can hold dots, so the field is what follows the last one.
        let rest = text.dropFirst("keyboard.".count)
        if text.hasPrefix("keyboard."), let dot = rest.lastIndex(of: "."), dot > rest.startIndex,
           let setting = keyboardSettings.first(where: { $0.name == rest[rest.index(after: dot)...] }) {
            return (Address(name: setting.name, keyboard: String(rest[..<dot])), setting)
        }
        throw UsageError("알 수 없는 설정: \(text). gksdud help settings로 설정을 확인하세요.")
    }

    static func change(_ word: String) throws -> Change {
        guard let equals = word.firstIndex(of: "=") else { throw UsageError("\(word): <설정>=<값> 형식으로 적어주세요.") }
        var key = String(word[..<equals]), operation = Operation.set
        if key.hasSuffix("+") { key.removeLast(); operation = .add } else if key.hasSuffix("-") { key.removeLast(); operation = .remove }
        let (address, setting) = try self.setting(key)
        guard operation == .set || setting.kind.isList else { throw UsageError("\(key)에는 \(operation.rawValue)를 쓸 수 없습니다. 목록 설정에만 씁니다.") }
        return Change(address: address, operation: operation, value: try value(String(word[word.index(after: equals)...]), for: setting, label: key, operation: operation))
    }

    static func value(_ raw: String, for setting: Setting, label: String, operation: Operation) throws -> Value {
        let text = raw.trimmingCharacters(in: .whitespaces), lower = text.lowercased()
        let invalid = UsageError("\(label)=\(raw): \(values(setting.kind)) 중에서 적어주세요.")
        let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch setting.kind {
        case .bool:
            if ["on", "true", "yes", "1"].contains(lower) { return .bool(true) }
            if ["off", "false", "no", "0"].contains(lower) { return .bool(false) }
            throw invalid
        case .choice(let options):
            // F19 is also 19.
            guard let match = options.first(where: { $0.lowercased() == lower || $0 == "F\(text)" }) else { throw invalid }
            return .text(match)
        case .keys(let single):
            if single && lower == "default" && operation == .set { return .none }
            let names = list.map { $0.lowercased() }
            guard !names.isEmpty, names.allSatisfy((single ? singleKeyNames : keyNames).contains) else { throw invalid }
            return .list(names)
        case .key:
            if lower == "none" { return .none }
            guard keyNames.contains(lower) else { throw invalid }
            return .text(lower)
        case .sources:
            guard !list.isEmpty else { throw invalid }
            return .list(list)
        case .source:
            if lower == "none" { return .none }
            guard !text.isEmpty else { throw invalid }
            return .text(text)
        }
    }

    static func values(_ kind: Kind) -> String {
        switch kind {
        case .bool: return "on|off"
        case .choice(let options): return options.joined(separator: "|")
        case .keys(let single): return single ? "<키>,...|default" : "<키>,..."
        case .key: return "<키>|none"
        case .sources: return "<입력 소스>,..."
        case .source: return "<입력 소스>|none"
        }
    }
    static func text(_ value: Value, _ kind: Kind) -> String {
        switch value {
        case .bool(let flag): return flag ? "on" : "off"
        case .text(let text): return text
        case .list(let list): return list.joined(separator: ",")
        case .none: if case .keys = kind { return "default" }; return "none"
        }
    }
    static func json(_ value: Value) -> Any {
        switch value {
        case .bool(let flag): return flag
        case .text(let text): return text
        case .list(let list): return list
        case .none: return NSNull()
        }
    }

    static let usage = """
    gksdud: 실행 중인 gksdud의 설정을 바꾸고 입력 소스를 전환합니다.

    사용법: gksdud <명령> [인자...] [옵션]

    명령
      status                현재 상태 (활성화, 접근성 권한, 입력 소스, 키보드)
      get [<설정>...]       설정 조회. 하나만 조회하면 값만 출력
      set <설정>=<값>...    설정 변경 후 바로 적용. 목록은 +=로 추가, -=로 제거
      toggle <설정>...      on/off 설정 뒤집기
      enable, disable       활성화 켜기/끄기 (enable은 일시정지도 해제)
      pause, resume         일시정지/재개. 키 매핑만 잠깐 풀어서 빠름
      source [<입력 소스>]  입력 소스 전환 (ko, en, toggle, ID, 이름). 생략하면 현재 입력 소스
      sources               켜져 있는 입력 소스 목록
      keyboards             키보드 목록과 키보드별 설정
      start, quit           앱 실행/종료
      help [settings]       도움말, 설정 목록
      version               버전

    옵션
      -j, --json            JSON으로 출력
      -f, --force           설정 창에서 확인을 묻는 변경도 진행
      -w, --wait            source 전환이 끝날 때까지 대기 (최대 1초)
      --no-alert            오류를 창으로 띄우지 않고 결과로만 출력

    종료 코드: 0 성공, 1 일부 실패, 2 잘못된 인자, 3 앱이 꺼져 있거나 응답 없음

    예
      gksdud set long-press=on escape=on
      gksdud set keys+=caps-lock --force
      gksdud pause
      gksdud source com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese
      gksdud set keyboard.Magic.mode=off

    자세한 설명: https://github.com/codingnoye/gksdud/blob/main/docs/cli.md
    """

    static var settingsHelp: String {
        let rows = settings.map { ($0.name, values($0.kind), $0.title) }
            + keyboardSettings.map { ("keyboard.<키보드>.\($0.name)", values($0.kind), $0.title) }
        let nameWidth = rows.map { width($0.0) }.max()!, valueWidth = rows.map { width($0.1) }.max()!
        return (rows.map { "\(pad($0.0, nameWidth))  \(pad($0.1, valueWidth))  \($0.2)" } + ["",
            "<키>: \(keyNames.joined(separator: ", "))",
            "      키보드별 한영 키는 앞의 네 개(단일키)만 가능",
            "<키보드>: gksdud keyboards의 ID 앞부분, 이름, 이름 일부. 모든 키보드는 * (셸에서는 'keyboard.*.mode=on'처럼 따옴표로)",
            "<입력 소스>: gksdud sources의 ID, 이름, ID 끝부분이나 일부. ko·en은 최근에 쓴 한국어·영어",
            "목록 설정(keys, cycle, keyboard.<키보드>.keys)은 +=로 추가, -=로 제거"]).joined(separator: "\n")
    }
    // Terminal columns: Hangul and other wide characters take two.
    static let wideRanges: [ClosedRange<UInt32>] = [0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
                                                    0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD]
    static func width(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in total + (wideRanges.contains { $0.contains(scalar.value) } ? 2 : 1) }
    }
    static func pad(_ text: String, _ columns: Int) -> String { text + String(repeating: " ", count: max(0, columns - width(text))) }
    static var settingsJSON: [String: Any] {
        func describe(_ setting: Setting, _ name: String) -> [String: Any] {
            ["name": name, "values": values(setting.kind), "list": setting.kind.isList, "description": setting.title]
        }
        return ["settings": settings.map { describe($0, $0.name) } + keyboardSettings.map { describe($0, "keyboard.<키보드>.\($0.name)") },
                "keys": keyNames, "keyboard_keys": singleKeyNames]
    }
}
