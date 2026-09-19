import AppKit
import Security
import CryptoKit

struct ReleaseAsset: Codable {
    let name: String
    let browser_download_url: String
    let size: Int64
}

struct UpdateFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct PreparedUpdate {
    let directory: URL
    let candidate: URL
    let version: String
}

extension AppRelease {
    var versionString: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    func assetURL(named name: String, limit: Int64) throws -> URL {
        guard let matches = assets?.filter({ $0.name == name }), matches.count == 1,
              let asset = matches.first, asset.size > 0, asset.size <= limit,
              let url = URL(string: asset.browser_download_url), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/codingnoye/gksdud/releases/download/\(tag_name)/\(name)" else {
            throw UpdateFailure("업데이트 파일을 찾지 못했습니다. 릴리스 페이지를 확인해주세요.")
        }
        return url
    }
}

// The installer has no signing secrets and never modifies signature requirements.
// A new bundle must satisfy the currently installed app's certificate-bound identity.
enum UpdateValidation {
    static let identifier = "io.gksdud.inputswitch"
    static let strict = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    static func signedCode(_ path: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, strict, nil) == errSecSuccess else {
            throw UpdateFailure("앱의 서명을 검증하지 못했습니다. 기존 앱은 그대로 유지됩니다.")
        }
        return code
    }
    static func installedRequirement(_ path: URL) throws -> SecRequirement {
        let code = try signedCode(path)
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any], let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty else {
            throw UpdateFailure("개발용 ad-hoc 빌드는 자동 업데이트를 지원하지 않습니다. 정식 배포본을 설치해주세요.")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let requirement else { throw UpdateFailure("현재 앱의 서명 정보를 읽지 못했습니다.") }
        return requirement
    }
    static func candidate(_ new: URL, installed: URL, version: String) throws {
        let requirement = try installedRequirement(installed)
        let code = try signedCode(new)
        guard SecStaticCodeCheckValidity(code, strict, requirement) == errSecSuccess else {
            throw UpdateFailure("현재 앱과 업데이트의 서명이 다릅니다. 기존 앱은 그대로 유지됩니다.")
        }
        guard let bundle = Bundle(url: new), bundle.bundleIdentifier == identifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              let oldBundle = Bundle(url: installed), oldBundle.bundleIdentifier == identifier,
              let old = oldBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let current = ReleaseVersion(old), let next = ReleaseVersion(version), next > current else {
            throw UpdateFailure("업데이트의 앱 이름 또는 버전이 올바르지 않습니다.")
        }
    }
    static func checksum(_ archive: URL, text: String, name: String) throws {
        let lines = text.split(whereSeparator: \.isNewline)
        let matches = lines.compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == Substring(name) || fields[1] == Substring("*" + name) else { return nil }
            return String(fields[0]).lowercased()
        }
        guard matches.count == 1, matches[0].count == 64, matches[0].allSatisfy(\.isHexDigit) else {
            throw UpdateFailure("업데이트 체크섬 정보가 올바르지 않습니다.")
        }
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == matches[0] else { throw UpdateFailure("다운로드한 파일의 체크섬이 일치하지 않습니다. 다시 시도해주세요.") }
    }
    static func archiveNames(_ names: String, listing: String) throws {
        let entries = names.split(separator: "\n", omittingEmptySubsequences: true)
        guard !entries.isEmpty, entries.count <= 5000,
              entries.allSatisfy({ name in
                  (name == "gksdud.app/" || name.hasPrefix("gksdud.app/")) && !name.contains("\\")
                      && !name.split(separator: "/").contains("..") && !name.contains("\r")
              }) else { throw UpdateFailure("업데이트 압축 파일의 경로가 올바르지 않습니다.") }
        // This app's archives contain only regular files/directories. Reject links
        // before extraction, including a link that could redirect a later member.
        let modes = listing.split(separator: "\n").filter { $0.count >= 10 && $0.dropFirst().prefix(9).allSatisfy { "rwxstST-".contains($0) } }
        guard modes.count == entries.count, modes.allSatisfy({ $0.first == "-" || $0.first == "d" }) else {
            throw UpdateFailure("지원하지 않는 링크가 압축 파일에 포함되어 있습니다.")
        }
        let total = try modes.reduce(Int64(0)) { sum, line -> Int64 in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4, let size = Int64(String(fields[3])), size >= 0, size <= 200_000_000 - sum else {
                throw UpdateFailure("업데이트 압축 파일이 너무 큽니다.")
            }
            return sum + size
        }
        guard total > 0 else { throw UpdateFailure("업데이트 압축 파일이 비어 있습니다.") }
    }
    @discardableResult static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure("업데이트 파일을 준비하지 못했습니다.") }
        return String(decoding: data, as: UTF8.self)
    }
}

// All mutations are confined to a verified app and its sibling staging/rollback paths.
// Injection points let tests exercise failures without replacing any installed app.
enum AppReplacement {
    static func replace(installed: URL, candidate: URL, validate: (URL, URL) throws -> Void,
                        launch: (URL) throws -> Void, move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let fm = FileManager.default, parent = installed.deletingLastPathComponent()
        let token = UUID().uuidString
        let stage = parent.appendingPathComponent(".gksdud-update-\(token).app")
        let backup = parent.appendingPathComponent(".gksdud-rollback-\(token).app")
        let failed = parent.appendingPathComponent(".gksdud-failed-\(token).app")
        guard fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: installed.path) else {
            throw UpdateFailure("앱 설치 폴더에 쓰기 권한이 없습니다. 쓰기 가능한 응용 프로그램 폴더에서 다시 시도해주세요.")
        }
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: candidate, to: stage)
        try validate(stage, installed)
        try move(installed, backup)
        do {
            try move(stage, installed)
            try launch(installed)
        } catch {
            do {
                if fm.fileExists(atPath: installed.path) { try fm.moveItem(at: installed, to: failed) }
                try fm.moveItem(at: backup, to: installed)
                try? launch(installed)
                try? fm.removeItem(at: failed)
            } catch {
                throw UpdateFailure("자동 복원이 완료되지 않았습니다. 기존 앱은 \(backup.path)에 보관되어 있습니다.")
            }
            throw UpdateFailure("업데이트를 완료하지 못해 기존 앱으로 복원했습니다.")
        }
        try? fm.removeItem(at: backup)
    }
}

// Instance state is accessed only on the main queue; detached work posts results there.
final class UpdateInstaller: @unchecked Sendable {
    private(set) var busy = false
    private(set) var status = ""
    var onChange: (() -> Void)?
    var onReady: ((PreparedUpdate) -> Void)?
    func clearStatus() { if !busy { status = "" } }
    func fail(_ error: Error) { busy = false; status = error.localizedDescription; onChange?() }
    func start(_ release: AppRelease) {
        guard !busy else { return }
        let installed = Bundle.main.bundleURL.resolvingSymlinksInPath()
        do {
            _ = try UpdateValidation.installedRequirement(installed)
            guard FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path),
                  FileManager.default.isWritableFile(atPath: installed.path) else {
                throw UpdateFailure("앱 설치 폴더에 쓰기 권한이 없습니다. 쓰기 가능한 응용 프로그램 폴더에서 다시 시도해주세요.")
            }
        }
        catch { fail(error); return }
        busy = true; status = "업데이트 다운로드 중…"; onChange?()
        Task.detached(priority: .utility) { [weak self] in
            var workspace: URL?
            do {
                let name = "gksdud-\(release.versionString)-macos-universal.zip"
                let archiveURL = try release.assetURL(named: name, limit: 100_000_000)
                let checksumURL = try release.assetURL(named: "SHA256SUMS", limit: 100_000)
                let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("gksdud-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                workspace = directory
                let archive = directory.appendingPathComponent(name)
                try await Self.download(archiveURL, to: archive, limit: 100_000_000)
                let sums = directory.appendingPathComponent("SHA256SUMS")
                try await Self.download(checksumURL, to: sums, limit: 100_000)
                DispatchQueue.main.async { self?.status = "다운로드한 앱을 검증하는 중…"; self?.onChange?() }
                try UpdateValidation.checksum(archive, text: String(contentsOf: sums, encoding: .utf8), name: name)
                let names = try UpdateValidation.command("/usr/bin/unzip", ["-Z1", archive.path])
                let listing = try UpdateValidation.command("/usr/bin/unzip", ["-Z", "-l", archive.path])
                try UpdateValidation.archiveNames(names, listing: listing)
                let expanded = directory.appendingPathComponent("expanded", isDirectory: true)
                try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: false)
                try UpdateValidation.command("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
                let candidate = expanded.appendingPathComponent("gksdud.app", isDirectory: true)
                try UpdateValidation.candidate(candidate, installed: installed, version: release.versionString)
                let prepared = PreparedUpdate(directory: directory, candidate: candidate, version: release.versionString)
                DispatchQueue.main.async {
                    self?.status = "업데이트를 설치하고 다시 시작하는 중…"; self?.onChange?(); self?.onReady?(prepared)
                }
            } catch {
                if let workspace { try? FileManager.default.removeItem(at: workspace) }
                DispatchQueue.main.async { self?.fail(error) }
            }
        }
    }
    private static func download(_ url: URL, to destination: URL, limit: Int64) async throws {
        var request = URLRequest(url: url); request.timeoutInterval = 120
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", let host = http.url?.host,
              ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host),
              let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= limit else { throw UpdateFailure("업데이트 다운로드에 실패했습니다.") }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    static func launchHelper(_ update: PreparedUpdate) throws {
        guard let executable = Bundle.main.executableURL else { throw UpdateFailure("업데이트 도우미를 실행하지 못했습니다.") }
        let helper = Process(); helper.executableURL = executable
        helper.arguments = ["--install-update", update.directory.path, update.candidate.path, update.version, String(getpid())]
        helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
        try helper.run()
    }
    static func runHelper(_ arguments: [String]) throws {
        guard arguments.count == 6, let parent = pid_t(arguments[5]), parent > 1 else { throw UpdateFailure("잘못된 업데이트 요청입니다.") }
        let workspace = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let candidate = URL(fileURLWithPath: arguments[3]).standardizedFileURL
        let installed = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard workspace.lastPathComponent.hasPrefix("gksdud-update-"),
              workspace.path == workspace.resolvingSymlinksInPath().path,
              candidate.path == workspace.appendingPathComponent("expanded/gksdud.app").path,
              candidate.path == candidate.resolvingSymlinksInPath().path,
              installed.pathExtension == "app" else { throw UpdateFailure("잘못된 업데이트 경로입니다.") }
        defer { try? FileManager.default.removeItem(at: workspace) }
        do {
            try UpdateValidation.candidate(candidate, installed: installed, version: arguments[4])
            let deadline = Date(timeIntervalSinceNow: 60)
            while kill(parent, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            guard kill(parent, 0) != 0 else { throw UpdateFailure("앱이 종료되지 않아 업데이트를 취소했습니다.") }
            try AppReplacement.replace(installed: installed, candidate: candidate, validate: { new, old in
                try UpdateValidation.candidate(new, installed: old, version: arguments[4])
            }, launch: { try launchAndCheck($0) })
        } catch {
            if kill(parent, 0) != 0,
               !NSRunningApplication.runningApplications(withBundleIdentifier: UpdateValidation.identifier).contains(where: { !$0.isTerminated && $0.processIdentifier != getpid() && $0.bundleURL?.resolvingSymlinksInPath() == installed }),
               FileManager.default.fileExists(atPath: installed.path) { try? launchAndCheck(installed) }
            // Show an actionable error after the main app has exited; never silently
            // leave the user without either the old app or its backup location.
            let alert = NSAlert(); alert.messageText = "gksdud 업데이트"; alert.informativeText = error.localizedDescription
            alert.runModal()
            throw error
        }
    }
    private static func launchAndCheck(_ url: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false; configuration.createsNewApplicationInstance = true
        var completed = false, launched: NSRunningApplication?, failure: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            DispatchQueue.main.async { launched = app; failure = error; completed = true }
        }
        let deadline = Date(timeIntervalSinceNow: 20)
        while !completed, Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        guard completed, failure == nil, let launched else { throw UpdateFailure("새 앱을 실행하지 못했습니다.") }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        guard !launched.isTerminated else { throw UpdateFailure("새 앱이 실행 직후 종료되었습니다.") }
    }
}
