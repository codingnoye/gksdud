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
    var versionString: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var archiveName: String { "gksdud-\(versionString)-macos-universal.zip" }
    var eligible: Bool { !draft && !prerelease && pageURL != nil && ReleaseVersion(versionString) != nil }
    func isNewer(than installed: String) -> Bool {
        guard eligible,
              let candidate = ReleaseVersion(versionString), let current = ReleaseVersion(installed) else { return false }
        return candidate > current
    }
    var summary: String {
        // Only the explicitly named section is shown; installation instructions stay on GitHub.
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
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#* "))
                if !collecting, (depth > 0 || trimmed == "**요약**"), heading == "요약" {
                    collecting = true; level = depth; continue
                }
                if collecting, depth > 0, level == 0 || depth <= level { break }
            }
            if collecting { lines.append(line) }
        }
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "이번 버전의 요약은 릴리스 페이지에서 확인할 수 있습니다." : String(result.prefix(4000))
    }
}

final class UpdateChecker {
    typealias Fetch = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void
    let defaults: UserDefaults
    let installedVersion: String
    let fetch: Fetch
    var now: () -> Date
    var onChange: (() -> Void)?
    private(set) var release: AppRelease?
    private(set) var checking = false
    private(set) var error: String?
    var available: AppRelease? { release.flatMap { $0.isNewer(than: installedVersion) ? $0 : nil } }
    var lastChecked: Date? { defaults.object(forKey: "updates.lastSuccess") as? Date }

    init(defaults: UserDefaults, installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0",
         now: @escaping () -> Date = Date.init,
         fetch: @escaping Fetch = { request, completion in URLSession.shared.dataTask(with: request, completionHandler: completion).resume() }) {
        self.defaults = defaults; self.installedVersion = installedVersion; self.now = now; self.fetch = fetch
        if let data = defaults.data(forKey: "updates.release") { release = try? JSONDecoder().decode(AppRelease.self, from: data) }
    }
    func check(force: Bool = false) {
        guard !checking else { return }
        let date = now()
        if !force, let next = defaults.object(forKey: "updates.nextCheck") as? Date,
           next > date, next.timeIntervalSince(date) <= 86400 { return }
        checking = true; error = nil
        defaults.set(date.addingTimeInterval(3600), forKey: "updates.nextCheck")
        onChange?()
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/codingnoye/gksdud/releases/latest")!)
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
                   let value = try? JSONDecoder().decode(AppRelease.self, from: data), value.eligible {
                    self.release = value
                    self.defaults.set(try? JSONEncoder().encode(value), forKey: "updates.release")
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
