import Foundation
import Darwin

struct IgnoredPackageRule: Hashable {
    let kind: PackageKind
    let name: String

    init(storageValue: String) {
        if storageValue.hasPrefix("formula:") {
            kind = .formula
            name = String(storageValue.dropFirst("formula:".count))
        } else {
            // 兼容 CLI 既有格式：没有类型前缀的旧行始终表示 cask。
            kind = .cask
            name = storageValue
        }
    }

    init(kind: PackageKind, name: String) {
        self.kind = kind
        self.name = name
    }

    var storageValue: String {
        kind == .formula ? "formula:\(name)" : name
    }

    var displayValue: String {
        "\(kind == .formula ? "Formula" : "Cask") · \(name)"
    }

    func matches(kind targetKind: PackageKind, name targetName: String) -> Bool {
        guard kind == targetKind else { return false }
        if name.contains("/") { return name == targetName }
        return name == targetName || targetName.split(separator: "/").last.map(String.init) == name
    }
}

/// 配置服务：与 brew-ua 共用 ~/.config/brew-ua/ignored_casks。
/// cask 沿用裸名称；formula 写作 formula:<name>。写入在同一目录中原子替换。
final class ConfigService {
    static let shared = ConfigService()

    let ignoredFileURL: URL
    private let lock = NSLock()

    init(fileURL: URL? = nil) {
        if let fileURL {
            ignoredFileURL = fileURL
        } else {
            ignoredFileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("brew-ua", isDirectory: true)
                .appendingPathComponent("ignored_casks")
        }
    }

    func loadIgnored() -> Set<String> {
        guard let data = try? Data(contentsOf: ignoredFileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    func isIgnored(name: String, kind: PackageKind) -> Bool {
        Self.isIgnored(name: name, kind: kind, rules: loadIgnored())
    }

    static func isIgnored(name: String, kind: PackageKind, rules: Set<String>) -> Bool {
        rules.contains { IgnoredPackageRule(storageValue: $0).matches(kind: kind, name: name) }
    }

    static func matchingRules(name: String, kind: PackageKind, rules: Set<String>) -> Set<String> {
        Set(rules.filter { IgnoredPackageRule(storageValue: $0).matches(kind: kind, name: name) })
    }

    /// 不带 kind 的旧调用保留 cask 语义，避免破坏既有配置入口。
    func addIgnored(_ name: String, kind: PackageKind = .cask) throws {
        try mutateIgnored { rules in
            rules.insert(IgnoredPackageRule(kind: kind, name: name).storageValue)
        }
    }

    func removeIgnored(_ name: String, kind: PackageKind = .cask) throws {
        let value = IgnoredPackageRule(kind: kind, name: name).storageValue
        try removeIgnoredRaw(value)
    }

    /// 移除设置页中的单条配置（参数是文件中原始的一行）。
    func removeIgnoredRaw(_ rawValue: String) throws {
        try mutateIgnored { $0.remove(rawValue) }
    }

    /// 从包管理页解除屏蔽：若短名规则覆盖了完整 tap 名，也一并移除匹配规则。
    func removeIgnoredMatching(name: String, kind: PackageKind) throws {
        try mutateIgnored { rules in
            rules.subtract(Self.matchingRules(name: name, kind: kind, rules: rules))
        }
    }

    private func mutateIgnored(_ mutation: (inout Set<String>) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var rules = loadIgnored()
        mutation(&rules)
        try saveIgnored(rules)
    }

    private func saveIgnored(_ rules: Set<String>) throws {
        let directory = ignoredFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = rules.sorted().joined(separator: "\n") + (rules.isEmpty ? "" : "\n")
        let temporaryURL = directory.appendingPathComponent(".ignored_casks.\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Data(text.utf8).write(to: temporaryURL, options: .atomic)
        let result = temporaryURL.path.withCString { source in
            ignoredFileURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: ignoredFileURL.path])
        }
    }
}
