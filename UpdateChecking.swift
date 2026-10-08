import Foundation

struct ReleaseVersion: Comparable {
    let parts: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(fields.count), fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              fields.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = fields.map { Int($0)! } + Array(repeating: 0, count: 4 - fields.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

// The canary build is a separate app, gksdud-dev, that updates only from canary releases (canary-vX.Y.Z prereleases).
enum UpdateChannel: String {
    case stable, canary
    static let current: UpdateChannel = Bundle.main.object(forInfoDictionaryKey: "GKSDUDChannel") as? String == "canary" ? .canary : .stable
    var tagPrefix: String { self == .canary ? "canary-v" : "v" }
    var appName: String { self == .canary ? "gksdud-dev" : "gksdud" }
}

struct AppRelease: Codable {
    let tag_name: String
    let html_url: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    var assets: [ReleaseAsset]? = nil

    var pageURL: URL? {
        guard let url = URL(string: html_url), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil,
              url.path.hasPrefix("/codingnoye/gksdud/releases/tag/") else { return nil }
        return url
    }
    var channel: UpdateChannel? { tag_name.hasPrefix("canary-v") ? .canary : tag_name.hasPrefix("v") ? .stable : nil }
    var versionString: String { String(tag_name.dropFirst(channel?.tagPrefix.count ?? 0)) }
    // The Apple-signed archive. -macos-universal.zip is the self-signed copy for apps up to 1.7.1, which take only that name: from
    // it, the next update is Apple-signed.
    var archiveName: String { "\(channel?.appName ?? "gksdud")-\(versionString).zip" }
    // Canary releases are prereleases, so the stable app and Homebrew never see them.
    var eligible: Bool { !draft && channel != nil && prerelease == (channel == .canary) && pageURL != nil && ReleaseVersion(versionString) != nil }
    func isNewer(than installed: String) -> Bool {
        guard eligible,
              let candidate = ReleaseVersion(versionString), let current = ReleaseVersion(installed) else { return false }
        return candidate > current
    }
    // The text under a heading such as ### 요약 or **경고**; the other sections, such as installation, stay on GitHub.
    func section(_ name: String) -> String {
        var collecting = false, level = 0, fenced = false
        var lines: [String] = []
        let cleaned = (body ?? "").replacingOccurrences(of: "<!--(?s:.*?)-->", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        for line in cleaned.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle() }
            if !fenced {
                let depth = trimmed.prefix(while: { $0 == "#" }).count
                let heading = String(trimmed.dropFirst(depth)).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#*[] "))
                if !collecting, depth > 0 || trimmed.hasPrefix("**") && trimmed.hasSuffix("**"), heading == name {
                    collecting = true; level = depth; continue
                }
                if collecting, depth > 0, level == 0 || depth <= level { break }
            }
            if collecting { lines.append(line) }
        }
        return String(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
    }
    var summary: String {
        let text = section("요약")
        return text.isEmpty ? "이번 버전의 요약은 릴리스 페이지에서 확인할 수 있습니다." : text
    }
    // What to know before installing this version, shown for confirmation before an update installs it.
    var warning: String { section("경고") }
    var summaryItems: [String] { Self.items(summary) }
    var warningItems: [String] { Self.items(warning) }
    // Every line as a "* " item, keeping its indentation.
    static func items(_ text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let marker = ["- ", "* ", "+ "].contains { text.hasPrefix($0) }
            return String(line.prefix(while: { $0 == " " || $0 == "\t" })) + "* " + (marker ? String(text.dropFirst(2)) : text)
        }
    }
}

final class UpdateChecker {
    typealias Fetch = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void
    let defaults: UserDefaults
    let installedVersion: String
    let channel: UpdateChannel
    let fetch: Fetch
    var now: () -> Date
    var onChange: (() -> Void)?
    // This channel's releases newer than the installed version at the last check, newest first.
    private(set) var releases: [AppRelease] = []
    private(set) var checking = false
    private(set) var error: String?
    var pending: [AppRelease] { releases.filter { $0.channel == channel && $0.isNewer(than: installedVersion) } }
    var available: AppRelease? { pending.first }
    var summary: String { Self.merge(pending.map { ($0, $0.summaryItems) }) }
    // The warnings of every version the update installs; empty when none has one.
    var warnings: String { Self.merge(pending.map { ($0, $0.warningItems) }.filter { !$0.1.isEmpty }) }
    static func merge(_ versions: [(AppRelease, [String])]) -> String {
        versions.map { (["v\($0.0.versionString)"] + $0.1).joined(separator: "\n") }.joined(separator: "\n\n")
    }
    var lastChecked: Date? { defaults.object(forKey: "updates.lastSuccess") as? Date }

    init(defaults: UserDefaults, installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0",
         channel: UpdateChannel = .current, now: @escaping () -> Date = Date.init,
         fetch: @escaping Fetch = { request, completion in URLSession.shared.dataTask(with: request, completionHandler: completion).resume() }) {
        self.defaults = defaults; self.installedVersion = installedVersion; self.channel = channel; self.now = now; self.fetch = fetch
        if let data = defaults.data(forKey: "updates.releases") { releases = (try? JSONDecoder().decode([AppRelease].self, from: data)) ?? [] }
    }
    func check(force: Bool = false) {
        guard !checking else { return }
        let date = now()
        if !force, let next = defaults.object(forKey: "updates.nextCheck") as? Date,
           next > date, next.timeIntervalSince(date) <= 86400 { return }
        checking = true; error = nil
        defaults.set(date.addingTimeInterval(3600), forKey: "updates.nextCheck")
        onChange?()
        // Recent releases of every kind: an update can skip versions, and canary releases are never GitHub's latest.
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/codingnoye/gksdud/releases?per_page=30")!)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("gksdud/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        fetch(request) { [weak self] data, response, failure in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                if failure == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let data, data.count <= 1_000_000,
                   let values = try? JSONDecoder().decode([AppRelease].self, from: data) {
                    self.releases = values.filter { $0.channel == self.channel && $0.isNewer(than: self.installedVersion) }
                        .sorted { ReleaseVersion($0.versionString)! > ReleaseVersion($1.versionString)! }
                    self.defaults.set(try? JSONEncoder().encode(self.releases), forKey: "updates.releases")
                    self.defaults.removeObject(forKey: "updates.release")
                    self.defaults.set(self.now(), forKey: "updates.lastSuccess")
                    self.defaults.set(self.now().addingTimeInterval(86400), forKey: "updates.nextCheck")
                } else {
                    self.error = "업데이트를 확인하지 못했습니다. 잠시 후 다시 시도해주세요."
                }
                self.onChange?()
            }
        }
    }
}
