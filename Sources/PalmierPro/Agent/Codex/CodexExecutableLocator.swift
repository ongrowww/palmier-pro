import Foundation

struct CodexExecutableStatus: Equatable, Sendable {
    let url: URL?
    let source: Source

    enum Source: Equatable, Sendable {
        case override
        case path
        case fallback
        case missing
    }
}

enum CodexExecutablePreference {
    static let defaultsKey = "codexExecutableOverride"

    static var overrideURL: URL? {
        get {
            UserDefaults.standard.string(forKey: defaultsKey).map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.standardizedFileURL.path, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }
}

enum CodexExecutableLocator {
    static func locate(
        overrideURL: URL? = CodexExecutablePreference.overrideURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexExecutableStatus {
        if let overrideURL, isExecutable(overrideURL) {
            return CodexExecutableStatus(url: overrideURL, source: .override)
        }
        for component in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component), isDirectory: true)
                .appendingPathComponent("codex")
            if isExecutable(candidate) {
                return CodexExecutableStatus(url: candidate.standardizedFileURL, source: .path)
            }
        }
        let fallbacks = [
            homeDirectory.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
        if let candidate = fallbacks.first(where: isExecutable) {
            return CodexExecutableStatus(url: candidate.standardizedFileURL, source: .fallback)
        }
        return CodexExecutableStatus(url: nil, source: .missing)
    }

    static func allowedEnvironment(from source: [String: String]) -> [String: String] {
        let allowlist = ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "CODEX_HOME"]
        return Dictionary(uniqueKeysWithValues: allowlist.compactMap { key in
            source[key].map { (key, $0) }
        })
    }

    private static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
}
