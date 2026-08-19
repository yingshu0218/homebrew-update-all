import Foundation

/// 配置服务:读写屏蔽列表。
/// 兼容 brew-ua 的存储格式:纯文本 `~/.config/brew-ua/ignored_casks`,一行一个包名。
final class ConfigService {
    static let shared = ConfigService()

    /// 屏蔽列表文件目录(与 brew-ua CLI 共用同一配置)
    private var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/brew-ua", isDirectory: true)
    }

    var ignoredFileURL: URL {
        configDir.appendingPathComponent("ignored_casks")
    }

    /// 读取屏蔽列表
    func loadIgnored() -> Set<String> {
        guard let data = try? Data(contentsOf: ignoredFileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    /// 屏蔽一个 cask
    func addIgnored(_ name: String) throws {
        var ignored = loadIgnored()
        ignored.insert(name)
        try saveIgnored(ignored)
    }

    /// 解除屏蔽
    func removeIgnored(_ name: String) throws {
        var ignored = loadIgnored()
        ignored.remove(name)
        try saveIgnored(ignored)
    }

    private func saveIgnored(_ names: Set<String>) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let text = names.sorted().joined(separator: "\n") + (names.isEmpty ? "" : "\n")
        try text.data(using: .utf8)?.write(to: ignoredFileURL)
    }
}