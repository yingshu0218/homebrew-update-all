import Foundation

enum MirrorSource: String {
    case ustc, tsinghua, aliyun, official, unknown

    var displayName: String {
        switch self {
        case .ustc: return "中科大 USTC"
        case .tsinghua: return "清华 TUNA"
        case .aliyun: return "阿里云"
        case .official: return "官方源"
        case .unknown: return "未知"
        }
    }
}

/// 环境检测:brew 版本/prefix/tap 镜像源/网络所在地区。
/// 对应 brew-ua 的 `ck` 环境诊断命令的可视化。
struct EnvironmentInfo {
    var brewPath: String
    var brewVersion: String
    var prefix: String
    var mirrorSource: MirrorSource
    var tapRemotes: [String: String]     // tap 名 -> 远程 URL
    var networkCountry: String
    var isNetworkOk: Bool
}

enum EnvDetector {
    static func detect() async -> EnvironmentInfo {
        let path = StreamedProcess.brewExecutablePath()
        var version = ""
        var prefix = ""
        var tapRemotes: [String: String] = [:]
        var country = ""
        var netOK = false

        let brewPathResult = try? await StreamedProcess(brewArguments: ["--prefix"]).runSync()
        prefix = brewPathResult?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let v = try? await StreamedProcess(brewArguments: ["--version"]).runSync() {
            // 第一行形如:Homebrew 4.6.2-... 或 Homebrew 4.6.2
            version = v.split(separator: "\n").first.map(String.init) ?? ""
        }

        // tap 远程:从 filesystem 读(brew tap-info --json 无参返回 [])
        tapRemotes = collectTapRemotes(prefix: prefix)

        // 网络所在地区:ipinfo.io/country(镜像检测辅助)
        if let c = try? await fetchCountry() {
            country = c
            netOK = true
        }

        return EnvironmentInfo(
            brewPath: path,
            brewVersion: version,
            prefix: prefix,
            mirrorSource: inferMirror(from: tapRemotes, country: country),
            tapRemotes: tapRemotes,
            networkCountry: country,
            isNetworkOk: netOK
        )
    }

    // MARK: - tap 远程收集

    /// 从 filesystem 收集已安装 tap 的 remote(优于 tap-info --json 无参返回 [])
    static func collectTapRemotes(prefix: String) -> [String: String] {
        let tapsDir = (prefix.isEmpty ? "/opt/homebrew" : prefix) + "/Library/Taps"
        let fm = FileManager.default
        var result: [String: String] = [:]
        // 形如 <prefix>/Library/Taps/<user>/<repo>
        guard let entries = try? fm.contentsOfDirectory(atPath: tapsDir) else { return [:] }
        for user in entries {
            let userPath = tapsDir + "/" + user
            guard let repos = try? fm.contentsOfDirectory(atPath: userPath) else { continue }
            for repo in repos {
                let gitDir = userPath + "/" + repo + "/.git"
                let name = "\(user)/\(repo)"
                let remote = readGitRemote(gitDir: gitDir)
                if !remote.isEmpty {
                    result[name] = remote
                }
            }
        }
        return result
    }

    /// 读一个 tap 的 .git/config remote origin url(兼容 .git 文件类型——worktree 场景)
    static func readGitRemote(gitDir: String) -> String {
        let fm = FileManager.default
        // .git 本身可以是目录或文件(worktree)
        let configURL: URL
        if fm.fileExists(atPath: gitDir + "/config") {
            configURL = URL(fileURLWithPath: gitDir + "/config")
        } else if let data = try? Data(contentsOf: URL(fileURLWithPath: gitDir)),
                  let text = String(data: data, encoding: .utf8),
                  text.contains("gitdir:") {
            // gitdir: <path> 指向实际目录
            let path = text.replacingOccurrences(of: "gitdir:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            configURL = URL(fileURLWithPath: path).appendingPathComponent("config")
        } else {
            return ""
        }
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else { return "" }
        // 找 [remote "origin"] 段下的 url = ...
        let lines = content.components(separatedBy: .newlines)
        var inOrigin = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[remote") {
                inOrigin = trimmed.contains("origin")
            } else if inOrigin, trimmed.hasPrefix("url") {
                let url = trimmed
                    .replacingOccurrences(of: "url", with: "")
                    .replacingOccurrences(of: "=", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return url
            }
        }
        return ""
    }

    /// 通过 remote URL 推断当前镜像源
    static func inferMirror(from taps: [String: String], country: String) -> MirrorSource {
        let joined = taps.values.joined(separator: " ")
        if joined.contains("mirrors.ustc.edu.cn") { return .ustc }
        if joined.contains("mirrors.tuna.tsinghua.edu.cn") || joined.contains("mirrors.tuna") { return .tsinghua }
        if joined.contains("mirrors.aliyun.com") { return .aliyun }
        if joined.contains("github.com/Homebrew") || joined.contains("github.com/homebrew") { return .official }
        return .unknown
    }

    private static func fetchCountry() async throws -> String {
        // 用 brew 环境外的直接 URLSession,短超时
        let url = URL(string: "https://ipinfo.io/country")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: request)
        if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           s.count <= 3, !s.isEmpty {
            return s
        }
        return "unknown"
    }
}