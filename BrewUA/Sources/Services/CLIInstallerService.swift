import Foundation

/// brew-ua CLI 脚本安装器。
/// 把仓库根目录的 brew-ua zsh 脚本(构建时打进 app 资源)安装到
/// `$(brew --prefix)/bin/brew-ua`,让终端可直接运行 `brew ua`。
/// Homebrew 前缀目录归当前用户所有,无需管理员权限。
enum CLIToolStatus: Equatable {
    case notInstalled
    /// 已安装,携带从脚本内容解析出的版本
    case installed(version: String)
    /// 目标位置存在文件但解析不到版本标记(来源未知,如 formula 安装的旧版或其他副本)
    case installedForeign
    case brewNotFound
}

struct CLIInstallStatus: Equatable {
    var status: CLIToolStatus
    var installedVersion: String?
    var bundledVersion: String?
    var targetURL: URL?

    /// 已安装版本与资源内脚本版本不一致 → 可更新/重装
    var isOutdated: Bool {
        guard case .installed = status,
              let installed = installedVersion,
              let bundled = bundledVersion else { return false }
        return installed != bundled
    }
}

enum CLIInstallError: LocalizedError {
    case bundledScriptMissing
    case brewNotFound

    var errorDescription: String? {
        switch self {
        case .bundledScriptMissing: return "应用资源中未找到 brew-ua 脚本,请重新安装应用"
        case .brewNotFound: return "未找到 Homebrew,无法确定安装目录"
        }
    }
}

enum CLIInstallerService {
    static let scriptName = "brew-ua"
    static let fileMode: Int = 0o755

    // MARK: - 版本解析

    /// 从脚本文本解析 BREW_UA_VERSION="x.y.z"(与 CLI 的版本自检常量对应)
    static func parseVersion(fromScript text: String) -> String? {
        guard let keyRange = text.range(of: "BREW_UA_VERSION") else { return nil }
        let rest = String(text[keyRange.upperBound...].prefix(64))
        guard let open = rest.firstIndex(of: "\"") else { return nil }
        let afterOpen = rest.index(after: open)
        guard let close = rest[afterOpen...].firstIndex(of: "\"") else { return nil }
        let version = String(rest[afterOpen..<close])
        return version.isEmpty ? nil : version
    }

    /// 取打进 app 资源的脚本(无扩展名文件,extension 传 nil)
    static func bundledScriptURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: scriptName, withExtension: nil)
    }

    // MARK: - 状态检测

    /// 检测安装状态。brewPrefix / bundledScript 均可注入(测试用临时目录);
    /// 默认经 BrewService 闸门跑 `brew --prefix`,规避 Apple Silicon / Intel 前缀差异。
    static func checkStatus(brewPrefix: String? = nil, bundle: Bundle = .main, bundledScript: URL? = nil) async -> CLIInstallStatus {
        let bundledVersion = (bundledScript ?? bundledScriptURL(bundle: bundle))
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap(parseVersion(fromScript:))

        guard let prefix = await resolvePrefix(brewPrefix) else {
            return CLIInstallStatus(status: .brewNotFound, installedVersion: nil,
                                    bundledVersion: bundledVersion, targetURL: nil)
        }
        let target = targetURL(prefix: prefix)
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else {
            return CLIInstallStatus(status: .notInstalled, installedVersion: nil,
                                    bundledVersion: bundledVersion, targetURL: target)
        }
        let installedText = try? String(contentsOf: target, encoding: .utf8)
        if let version = installedText.flatMap(parseVersion(fromScript:)) {
            return CLIInstallStatus(status: .installed(version: version), installedVersion: version,
                                    bundledVersion: bundledVersion, targetURL: target)
        }
        return CLIInstallStatus(status: .installedForeign, installedVersion: nil,
                                bundledVersion: bundledVersion, targetURL: target)
    }

    // MARK: - 安装 / 卸载

    /// 覆盖安装资源内脚本到 <prefix>/bin/brew-ua,返回安装后的版本。
    @discardableResult
    static func install(brewPrefix: String? = nil, bundledURL: URL? = nil) async throws -> String {
        guard let source = bundledURL ?? bundledScriptURL() else {
            throw CLIInstallError.bundledScriptMissing
        }
        guard let prefix = await resolvePrefix(brewPrefix) else {
            throw CLIInstallError.brewNotFound
        }
        let fm = FileManager.default
        let binDir = URL(fileURLWithPath: prefix).appendingPathComponent("bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let target = binDir.appendingPathComponent(scriptName)
        // 覆盖安装:先删旧文件(若旧目标是符号链接,直接删链接本身,避免 copy 写穿链接目标)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.copyItem(at: source, to: target)
        try fm.setAttributes([.posixPermissions: fileMode], ofItemAtPath: target.path)
        let text = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        return parseVersion(fromScript: text) ?? "未知版本"
    }

    /// 卸载。目标不存在时不视为错误;brew 未找到时静默返回(无可卸载)。
    static func uninstall(brewPrefix: String? = nil) async throws {
        guard let prefix = await resolvePrefix(brewPrefix) else { return }
        let target = targetURL(prefix: prefix)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
    }

    // MARK: - helpers

    static func targetURL(prefix: String) -> URL {
        URL(fileURLWithPath: prefix).appendingPathComponent("bin/" + scriptName)
    }

    /// 解析 brew 前缀:显式注入优先;否则走 `brew --prefix`(空输出视为未找到)
    private static func resolvePrefix(_ explicit: String?) async -> String? {
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        guard explicit == nil,
              let out = await BrewService.shared.brewOutput(["--prefix"]) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
