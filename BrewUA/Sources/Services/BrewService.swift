import Foundation

/// brew 数据层:封装 brew 的 JSON 接口。
/// 参考成熟方案(brew-browser/Cork)的数据策略:全部走 `brew ... --json` 结构化数据,
/// 只有执行型命令才走流式输出。
final class BrewService {
    static let shared = BrewService()
    private let config = ConfigService.shared
    /// 互斥锁:同一时刻只允许一个 brew 子进程运行。
    /// Homebrew 有全局锁,并发调用会互相等待甚至报 "Another active Homebrew process"，所以 GUI 内部必须串行化。
    private let brewLock = NSLock()
    /// 等待中的调用者数(用于每次调用排队而不是直接丢弃)
    private var waitingCount = 0

    init() {}

    /// 串行执行一个 brew 同步命令,返回 stdout 字符串。
    /// 用轮询式自旋等待锁,避免 async/await 与 DispatchQueue 组合的复杂性。
    private func runSerialized(_ arguments: [String]) async throws -> String {
        // 尝试获取锁;拿不到则短暂让步后重试(最多等 10 秒)
        for _ in 0..<200 {
            if brewLock.try() {
                defer { brewLock.unlock() }
                return try await StreamedProcess(brewArguments: arguments).runSync()
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        throw BrewError.busy
    }

    // MARK: - brew update

    /// 更新源和包信息。流式输出行到闭包。
    func update(onLine: @escaping (String) -> Void) async throws {
        let proc = StreamedProcess(brewArguments: ["update"])
        for try await event in proc.run() {
            onLine(event.text)
        }
    }

    // MARK: - outdated

    /// 获取待更新的 formula 列表(outdated --formula --json)
    func outdatedFormulae() async -> [OutdatedEntry] {
        let args = ["outdated", "--formula", "--json"]
        guard let out = try? await runSerialized(args) else { return [] }
        return Self.parseOutdatedJSON(out, kind: .formula)
    }

    /// 获取待更新的 cask 列表(含 --greedy 扫描自更新应用)
    func outdatedCasks(greedy: Bool = true) async -> [OutdatedEntry] {
        var args = ["outdated", "--cask"]
        if greedy { args.append("--greedy") }
        args.append("--json")
        guard let out = try? await runSerialized(args) else { return [] }
        return Self.parseOutdatedJSON(out, kind: .cask)
    }

    /// 合并后的待更新列表(已过滤屏蔽列表)
    func outdatedAll(greedy: Bool = true) async -> [OutdatedEntry] {
        // 注意:必须串行执行两个 brew 命令(并发会互相等锁)
        let formulae = await outdatedFormulae()
        let casks = await outdatedCasks(greedy: greedy)
        let ignored = config.loadIgnored()
        return (formulae + casks)
            .map { entry in
                var e = entry
                e.isIgnored = ignored.contains(entry.name)
                return e
            }
            .sorted { $0.kind.rawValue != $1.kind.rawValue ? $0.kind == .formula : $0.name < $1.name }
    }

    /// 解析 outdated --json 输出(`{"formulae":[...],"casks":[...]}` snake_case 字段)
    static func parseOutdatedJSON(_ json: String, kind: PackageKind) -> [OutdatedEntry] {
        struct OutdatedPayload: Decodable {
            struct Item: Decodable {
                let name: String
                let installed_versions: [String]
                let current_version: String
            }
            let formulae: [Item]
            let casks: [Item]

            func rawItems(kind: PackageKind) -> [OutdatedEntry] {
                let items: [Item] = kind == .formula ? formulae : casks
                return items.map { item in
                    let current = item.installed_versions.first ?? "?"
                    let newest = item.current_version.isEmpty ? "?" : item.current_version
                    return OutdatedEntry(
                        name: item.name,
                        currentVersion: current,
                        newestVersion: newest,
                        kind: kind,
                        isIgnored: false
                    )
                }
            }
        }
        return Self.decodeJSONWithFallback(json) { text in
            guard let data = text.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(OutdatedPayload.self, from: data) else { return nil }
            return payload.rawItems(kind: kind)
        } ?? []
    }

    // MARK: - fetch / install

    /// 阶段1:下载单个包(流式,带进度事件)。
    /// - `onProgress`: 收到 progress 帧(每秒若干次)时回调,含已下载/总量/速度
    func fetch(package: OutdatedEntry, onLine: @escaping (String) -> Void, onProgress: @escaping (Int64, Int64, Double) -> Void) async throws {
        let flag = package.kind == .formula ? "--formula" : "--cask"
        let proc = StreamedProcess(brewArguments: ["fetch", flag, package.name])
        var lastSample = Date()
        var lastBytes: Int64 = 0
        var reportedOnce = false
        for try await event in proc.run() {
            onLine(event.text)
            // 主通道:采样缓存文件大小增长;0.8s 最小间隔避免速度抖跳
            if let size = Self.downloadFileBytes(packageName: package.name, kind: package.kind) {
                let now = Date()
                let dt = now.timeIntervalSince(lastSample)
                if dt >= 0.8 || size == lastBytes {
                    let speed = dt > 0 ? Double(size - lastBytes) / dt : 0
                    lastSample = now
                    lastBytes = size
                    onProgress(size, 0, speed)
                    reportedOnce = true
                }
            }
        }
        // 若从未报告过大小(可能已完全缓存),至少标记完成
        if !reportedOnce {
            onProgress(0, 0, 0)
        } else {
            // 下载结束,最终回调一次让 UI 收尾(如显示完成状态)
            onProgress(lastBytes, 0, 0)
        }
    }

    /// 阶段2:安装单个包。formula 走 upgrade,cask 走 reinstall(复刻 brew-ua 分支)
    func install(package: OutdatedEntry, onLine: @escaping (String) -> Void) async throws {
        if package.kind == .formula {
            let proc = StreamedProcess(brewArguments: ["upgrade", "--formula", package.name])
            for try await event in proc.run() {
                onLine(event.text)
            }
        } else {
            let proc = StreamedProcess(brewArguments: ["reinstall", "--cask", package.name])
            for try await event in proc.run() {
                onLine(event.text)
            }
        }
    }

    // MARK: - info / list

    /// 已安装的所有包(formula + cask),用于包管理页。
    /// 基于 `brew list --json`(实测 Homebrew 6.0.x:需带 --versions;cask 用 token 字段)
    /// - Returns: (packages, 是否读取成功)。仅当 brew 命令真正失败时才置 false。
    func installedAllWithStatus() async -> (packages: [InstalledPackage], success: Bool) {
        let formulaArgs = ["list", "--formula", "--versions", "--json"]
        let caskArgs = ["list", "--cask", "--versions", "--json"]
        let formulaOut = try? await runSerialized(formulaArgs)
        let caskOut = try? await runSerialized(caskArgs)
        // 命令失败返回 nil;若两个都失败,判定读取失败
        if formulaOut == nil && caskOut == nil {
            return ([], false)
        }
        let f = Self.parseInstalledList(formulaOut ?? "", kind: .formula)
        let c = Self.parseInstalledList(caskOut ?? "", kind: .cask)
        return (f + c, true)
    }

    func installedAll() async -> [InstalledPackage] {
        await installedAllWithStatus().packages
    }

    /// 总览页聚合统计:已安装 formula/cask 数 + 待更新 formula/cask 数(串行避免 brew 互锁)。
    func overviewStats() async -> (installedFormulae: Int, installedCasks: Int, outdatedFormulae: Int, outdatedCasks: Int) {
        let packages = await installedAll()
        let ignored = config.loadIgnored()
        let outdatedF = await outdatedFormulae()
        let outdatedC = await outdatedCasks(greedy: false)
        let formulae = packages.filter { $0.kind == .formula }.count
        let casks = packages.filter { $0.kind == .cask }.count
        let outdatedFormulae = outdatedF.filter { !ignored.contains($0.name) }.count
        let outdatedCasks = outdatedC.filter { !ignored.contains($0.name) }.count
        return (formulae, casks, outdatedFormulae, outdatedCasks)
    }

    /// 解析 `brew list --json` 输出。
    /// - formula: `{"formulae":[{"name","versions":[...],"linked_version",...}],"casks":[]}`
    /// - cask: `{"formulae":[],"casks":[{"token","versions":[...],"pinned_version"}]}`
    /// - 与 parseOutdatedJSON 相同策略:先整段,失败再逐行从末尾找(兼容前导警告行)
    static func parseInstalledList(_ json: String, kind: PackageKind) -> [InstalledPackage] {
        struct Payload: Decodable {
            struct FormulaItem: Decodable { let name: String; let versions: [String]; let pinned_version: String? }
            struct CaskItem: Decodable { let token: String; let versions: [String]; let pinned_version: String? }
            let formulae: [FormulaItem]
            let casks: [CaskItem]
        }
        return Self.decodeJSONWithFallback(json) { text in
            guard let data = text.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
            switch kind {
            case .formula:
                return payload.formulae.map {
                    InstalledPackage(name: $0.name, version: $0.versions.first ?? "", kind: .formula, isPinned: $0.pinned_version != nil)
                }
            case .cask:
                return payload.casks.map {
                    InstalledPackage(name: $0.token, version: $0.versions.first ?? "", kind: .cask, isPinned: $0.pinned_version != nil)
                }
            }
        } ?? []
    }

    /// 通用 JSON 解析 + 兜底:先整段;失败则从末尾向上逐行累积(处理前导警告/banner 后跟
    /// 单行紧凑 JSON 或多行格式化 JSON 的场景)。返回 nil 表示完全无法解析。
    private static func decodeJSONWithFallback<T>(_ text: String, _ decode: (String) -> T?) -> T? {
        let all = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !all.isEmpty, let result = decode(all) { return result }
        // 从末尾向上累积:先试最后 1 行,再试最后 2 行…直到完整 JSON
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for start in stride(from: lines.count - 1, through: 0, by: -1) {
            let slice = lines[start...].joined(separator: "\n")
            let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let result = decode(trimmed) { return result }
        }
        return nil
    }

    /// brew info --json=v2 单包详情(用于包管理页)
    func infoJSON(package: OutdatedEntry) async -> String? {
        let flag = package.kind == .formula ? "--formula" : "--cask"
        let args = ["info", "--json=v2", flag, package.name]
        return try? await runSerialized(args)
    }

    /// brew services list(服务管理页)
    /// - Returns: (services, 是否读取成功)。命令失败置 false;成功但无服务时 services 为空、success 仍为 true。
    func servicesList() async -> (services: [ServiceInfo], success: Bool) {
        guard let out = try? await runSerialized(["services", "list"]) else {
            return ([], false)
        }
        return (Self.parseServicesOutput(out), true)
    }

    /// 解析 brew services list 的非 JSON 表格输出(兼容性最强)
    /// 表头:`Name  Status  User  File`
    static func parseServicesOutput(_ text: String) -> [ServiceInfo] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }
        // 跳过表头(含 Name/Status),解析后续行
        let rows = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return rows.compactMap { line in
            // 用空白切分,同时兼容 `-` 占位
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 2 else { return nil }
            return ServiceInfo(
                name: cols[0],
                status: cols[1],
                user: cols.count > 2 ? cols[2] : "",
                file: cols.count > 3 ? cols[3] : ""
            )
        }
    }

    /// 导出 Brewfile 到指定路径(设置迁移页)
    func exportBrewfile(to url: URL) async throws {
        _ = try await runSerialized(["bundle", "dump", "--file=\(url.path)", "--force"])
    }

    // MARK: - cache location

    /// 定位单个包的下载缓存文件大小(字节)。
    /// - 优先 `.incomplete`(下载中);下载完成后文件被改名为正式文件名,兜底匹配。
    /// - 失败返回 nil(上层降级为只解析日志)
    static func downloadFileBytes(packageName: String, kind: PackageKind) -> Int64? {
        guard let cacheDir = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        // brew 缓存目录通常为 <cache>/Homebrew/downloads
        let downloadsDir = cacheDir.appendingPathComponent("Homebrew/downloads")
        let enumerator = FileManager.default.enumerator(
            at: downloadsDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        guard let files = enumerator?.allObjects as? [URL] else { return nil }
        // 首选手工用包名匹配的文件
        let candidates = files.filter { url in
            let name = url.lastPathComponent
            return name.contains(packageName) && (name.hasSuffix(".incomplete") || !name.hasSuffix(".json"))
        }
        guard let target = candidates.first,
              let attrs = try? FileManager.default.attributesOfItem(atPath: target.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}
/// brew 数据层错误
enum BrewError: LocalizedError {
    case busy

    var errorDescription: String? {
        switch self {
        case .busy: return "另有 Homebrew 命令正在运行,请稍后重试"
        }
    }
}
