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

        // 镜像源检测:多来源汇总(见 inferMirror)。GUI 由 LaunchServices 启动不继承 shell
        // export,所以除进程环境变量外,还需读用户 shell 配置里的 HOMEBREW_*。
        let envText = ProcessInfo.processInfo.environment
            .filter { $0.key.hasPrefix("HOMEBREW_") }
            .values
            .joined(separator: " ")
        let shellText = readShellBrewEnv()
        let brewConfigText = (try? await StreamedProcess(brewArguments: ["config"]).runSync()) ?? ""
        let mergedMirrorText = envText + " " + shellText + " " + brewConfigText + " " + tapRemotes.values.joined(separator: " ")

        return EnvironmentInfo(
            brewPath: path,
            brewVersion: version,
            prefix: prefix,
            mirrorSource: inferMirror(fromText: mergedMirrorText),
            tapRemotes: tapRemotes,
            networkCountry: country,
            isNetworkOk: netOK
        )
    }

    // MARK: - 镜像源检测

    /// 从用户 shell 配置(~/.zprofile / ~/.zshrc / ~/.bash_profile / ~/.bashrc)
    /// 中收集 `HOMEBREW_*` 镜像源环境变量配置。GUI 进程不继承 shell export,
    /// 直接读文件是最可靠的跨环境方式。
    static func readShellBrewEnv() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let files = [".zprofile", ".zshrc", ".bash_profile", ".bashrc"]
            .map { home + "/" + $0 }
        var hits: [String] = []
        for file in files where FileManager.default.isReadableFile(atPath: file) {
            guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: .newlines) where line.contains("HOMEBREW_") {
                // 提取形如 export HOMEBREW_X="url" / export HOMEBREW_X=url 的值
                let cleaned = line
                    .replacingOccurrences(of: "export", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let eq = cleaned.firstIndex(of: "=") {
                    let key = cleaned[..<eq].trimmingCharacters(in: .whitespaces)
                    let value = cleaned[cleaned.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if key.hasPrefix("HOMEBREW_"), !value.isEmpty {
                        hits.append(value)
                    }
                }
            }
        }
        return hits.joined(separator: " ")
    }

    /// 通过汇总文本推断当前镜像源。汇总内容包含:
    /// 进程 HOMEBREW_* 环境变量 / shell 配置 / brew config 输出 / tap remote。
    static func inferMirror(fromText text: String) -> MirrorSource {
        if text.contains("mirrors.ustc.edu.cn") { return .ustc }
        if text.contains("mirrors.tuna.tsinghua.edu.cn") || text.contains("mirrors.tuna") { return .tsinghua }
        if text.contains("mirrors.aliyun.com") { return .aliyun }
        if text.contains("github.com/Homebrew") || text.contains("github.com/homebrew") { return .official }
        // 兜底:多个第三方 tap 都指 github 但无 Homebrew 官方 tap 时,不能断定用了官方源
        return .unknown
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