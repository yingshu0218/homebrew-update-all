import Foundation

/// brew 数据层协议:供 UpdateEngine 注入测试替身(mock)。
/// 生产实现为 BrewService;测试用 MockBrewService 验证升级状态机全路径。
@MainActor
protocol BrewServicing: AnyObject {
    func update(onLine: @escaping (String) -> Void) async throws
    func outdatedAll(greedy: Bool) async -> [OutdatedEntry]
    func fetch(package: OutdatedEntry, onLine: @escaping (String) -> Void, onProgress: @escaping (Int64, Int64, Double) -> Void) async throws
    func install(package: OutdatedEntry, onLine: @escaping (String) -> Void) async throws
    func caskAutoUpdates(names: [String]) async -> [String: Bool]
    /// 清理缓存(brew cleanup --prune=all);返回是否成功
    func cleanupAll() async -> Bool
}

/// brew 数据层:封装 brew 的 JSON 接口。
/// 参考成熟方案(brew-browser/Cork)的数据策略:全部走 `brew ... --json` 结构化数据,
/// 只有执行型命令才走流式输出。
final class BrewService: BrewServicing {
    static let shared = BrewService()
    private let config = ConfigService.shared

    init() {}

    /// 串行执行一个 brew 同步命令,返回 stdout 字符串。
    /// 走全局 BrewGate 异步排队(替代旧 NSLock 自旋:跨 await 解锁属未定义行为且忙等)。
    private func runSerialized(_ arguments: [String]) async throws -> String {
        try await withBrewGate {
            try await StreamedProcess(brewArguments: arguments).runSync()
        }
    }

    /// 同步执行 brew 命令,返回输出;失败(含排队外的真实失败)返回 nil。
    /// 供 EnvDetector 等绕开 BrewService 内部方法的调用方统一走闸门。
    func brewOutput(_ arguments: [String], timeout: TimeInterval = 30) async -> String? {
        try? await withBrewGate {
            try await StreamedProcess(brewArguments: arguments).runSync(timeout: timeout)
        }
    }

    /// 同步执行 brew 命令,返回 (输出, 是否成功退出)。失败给出明确状态而非静默。
    func brewChecked(_ arguments: [String], timeout: TimeInterval = 120) async -> (output: String, success: Bool) {
        (try? await withBrewGate {
            await StreamedProcess(brewArguments: arguments).runSyncChecked(timeout: timeout)
        }) ?? ("", false)
    }

    // MARK: - brew update

    /// 更新源和包信息。流式输出行到闭包。
    /// @MainActor:onLine 闭包的调用点强制在主线程。
    /// 若不隔离,AsyncThrowingStream 的 for-await 恢复点在后台线程执行,
    /// 回调改 @Published 会触发 SwiftUI 后台重建主菜单崩溃(SIGABRT)。
    @MainActor
    func update(onLine: @escaping (String) -> Void) async throws {
        try await withBrewGate {
            let proc = StreamedProcess(brewArguments: ["update"])
            for try await event in proc.run() {
                onLine(event.text)
            }
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
    nonisolated static func parseOutdatedJSON(_ json: String, kind: PackageKind) -> [OutdatedEntry] {
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

    /// 从 `brew info --json=v2` 输出里提取首个下载 URL(回退解析)。
    /// 单独抽成静态方法便于单测。
    nonisolated static func extractDownloadURL(fromInfoJSON json: String) -> String? {
        struct InfoPayload: Decodable {
            struct Formula: Decodable {
                let urls: [String]?
                let url: String?
            }
            struct Cask: Decodable {
                let url: String?
                let artifacts: [CaskArtifact]?
                struct CaskArtifact: Decodable {
                    let url: String?
                }
            }
            let formulae: [Formula]
            let casks: [Cask]
        }
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(InfoPayload.self, from: data) else { return nil }
        if let f = payload.formulae.first {
            if let urls = f.urls, !urls.isEmpty { return urls.first }
            if let u = f.url { return u }
        }
        if let c = payload.casks.first {
            if let u = c.url { return u }
            if let artifacts = c.artifacts {
                for a in artifacts where a.url != nil { return a.url }
            }
        }
        return nil
    }

    /// HEAD 请求下载地址,拿 `Content-Length`(字节)作为包总大小。失败返回 nil(调用侧降级)。
    /// async 实现:等待网络响应期间让出线程(修复旧 DispatchSemaphore 同步等待
    /// 在 @MainActor 上最长卡主线程 16s 的问题)。
    nonisolated static func probeDownloadSize(urlString: String, timeout: TimeInterval = 15) async -> Int64? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        // 兼容部分 CDN 需要 UA,否则 403/404
        request.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent")
        guard let (_, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let len = http.value(forHTTPHeaderField: "Content-Length"),
              let bytes = Int64(len), bytes > 0 else { return nil }
        return bytes
    }

    /// 解析 `brew info --json=v2 --cask …` 输出的 auto_updates 字段(token → Bool)。
    /// 单独抽成静态方法便于单测。返回空字典表示全部无法解析。
    nonisolated static func parseCaskAutoUpdates(fromInfoJSON json: String) -> [String: Bool] {
        struct InfoPayload: Decodable {
            struct Cask: Decodable {
                let token: String
                let auto_updates: Bool?
            }
            let casks: [Cask]
        }
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(InfoPayload.self, from: data) else { return [:] }
        var result: [String: Bool] = [:]
        for cask in payload.casks {
            if let au = cask.auto_updates {
                result[cask.token] = au
            }
        }
        return result
    }

    /// 批量查询多个 cask 的 auto_updates(一次 brew info 命令,避免逐包慢查询)。
    /// 失败返回空字典(UI 降级不显示徽标)。
    func caskAutoUpdates(names: [String]) async -> [String: Bool] {
        guard !names.isEmpty else { return [:] }
        let args = ["info", "--json=v2", "--cask"] + names
        guard let out = try? await runSerialized(args) else { return [:] }
        return Self.parseCaskAutoUpdates(fromInfoJSON: out)
    }

    /// 清理缓存(⑤ cleanup 阶段)。走闸门串行。
    func cleanupAll() async -> Bool {
        await brewOutput(["cleanup", "--prune=all"], timeout: 300) != nil
    }

    /// 阶段1:下载单个包(流式,带进度事件)。
    /// - `onProgress`: 收到 progress 帧时回调,含已下载/总量/速度
    /// - 下载期间用**定时器独立轮询**缓存文件大小算速度(不依赖 brew 输出事件频率)
    /// - 总量来源:头部仅当日志出现下载完成/失败或超时时中止
    /// - @MainActor:与 update 同理,保证 onLine/onProgress 在主线程执行,
    ///   避免后台 stream 恢复点改 @Published 触发 SIGABRT
    @MainActor
    func fetch(package: OutdatedEntry, onLine: @escaping (String) -> Void, onProgress: @escaping (Int64, Int64, Double) -> Void) async throws {
        let flag = package.kind == .formula ? "--formula" : "--cask"
        // ① 先探测包大小:info 查询过闸门 + HEAD 网络请求(不占闸门)。
        //    必须在下载主体前完成——闸门内不能再调 runSerialized(actor 不可重入,会死锁)
        var total: Int64 = 0
        if let json = try? await runSerialized(["info", "--json=v2", flag, package.name]),
           let url = Self.extractDownloadURL(fromInfoJSON: json) {
            total = await Self.probeDownloadSize(urlString: url) ?? 0
        }
        // ② 下载主体:整个下载期间持有闸门(期间其他 brew 命令排队等待)
        try await withBrewGate {
            let proc = StreamedProcess(brewArguments: ["fetch", flag, package.name])
            // 独立定时器轮询缓存文件大小算速度(不依赖 brew 输出事件频率)
            let poll = PollingMonitor(packageName: package.name, kind: package.kind, interval: 0.6) { bytes, speed in
                onProgress(bytes, total, speed)
            }
            poll.start()
            var lastBytes: Int64 = 0
            var reportedOnce = false
            do {
                for try await event in proc.run() {
                    onLine(event.text)
                    // 保留流内采样,作为定时器之外的一层兜底(缓存已就绪但极早结束的场景)
                    if let size = poll.sample() {
                        lastBytes = size
                        reportedOnce = true
                    }
                }
            } catch {
                poll.stop()
                let finalBytes = reportedOnce ? lastBytes : 0
                onProgress(finalBytes, total, 0)
                throw error
            }
            poll.stop()
            // 结束时:上报当前缓存大小(下载完成后 .incomplete 改名为正式文件,最后一次采样已覆盖)
            if let finalSize = BrewService.currentDownloadFileSize(packageName: package.name) {
                onProgress(finalSize, total, 0)
            } else if reportedOnce {
                onProgress(lastBytes, total, 0)
            } else {
                // 无任何可见进度(极小文件或直接命中缓存):标记完成
                onProgress(total, total, 0)
            }
        }
    }

    /// 阶段2:安装单个包。formula 走 upgrade,cask 走 reinstall(复刻 brew-ua 分支)
    /// @MainActor:同理,onLine 在主线程执行
    @MainActor
    func install(package: OutdatedEntry, onLine: @escaping (String) -> Void) async throws {
        try await withBrewGate {
            let args: [String] = package.kind == .formula
                ? ["upgrade", "--formula", package.name]
                : ["reinstall", "--cask", package.name]
            let proc = StreamedProcess(brewArguments: args)
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
    func overviewStats() async -> (installedFormulae: Int, installedCasks: Int, outdatedFormulae: Int, outdatedCasks: Int, outdatedReliable: Bool) {
        let packages = await installedAll()
        let ignored = config.loadIgnored()
        // outdated 检测失败(如 busy/命令异常)必须让上层知道,否则"检测失败"会被当成"没有更新"
        var outdatedReliable = true
        let outdatedF: [OutdatedEntry]
        if let out = try? await runSerialized(["outdated", "--formula", "--json"]) {
            outdatedF = Self.parseOutdatedJSON(out, kind: .formula)
        } else {
            outdatedF = []
            outdatedReliable = false
        }
        let outdatedC: [OutdatedEntry]
        if let out = try? await runSerialized(["outdated", "--cask", "--json"]) {
            outdatedC = Self.parseOutdatedJSON(out, kind: .cask)
        } else {
            outdatedC = []
            outdatedReliable = false
        }
        let formulae = packages.filter { $0.kind == .formula }.count
        let casks = packages.filter { $0.kind == .cask }.count
        let outdatedFormulae = outdatedF.filter { !ignored.contains($0.name) }.count
        let outdatedCasks = outdatedC.filter { !ignored.contains($0.name) }.count
        return (formulae, casks, outdatedFormulae, outdatedCasks, outdatedReliable)
    }

    /// 解析 `brew list --json` 输出。
    /// - formula: `{"formulae":[{"name","versions":[...],"linked_version",...}],"casks":[]}`
    /// - cask: `{"formulae":[],"casks":[{"token","versions":[...],"pinned_version"}]}`
    /// - 与 parseOutdatedJSON 相同策略:先整段,失败再逐行从末尾找(兼容前导警告行)
    nonisolated static func parseInstalledList(_ json: String, kind: PackageKind) -> [InstalledPackage] {
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
    private nonisolated static func decodeJSONWithFallback<T>(_ text: String, _ decode: (String) -> T?) -> T? {
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
    nonisolated static func parseServicesOutput(_ text: String) -> [ServiceInfo] {
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
    nonisolated static func downloadFileBytes(packageName: String, kind: PackageKind) -> Int64? {
        currentDownloadFileSize(packageName: packageName)
    }

    /// 在 brew 下载目录里找与该包相关的"活跃下载文件"大小。
    /// - 包名匹配:名称前缀包含包名(兼容 `xxx--<name>--...` 的 hash 文件名,也兼容明文 URL 文件名)
    /// - 下载中文件带 `.incomplete` 后缀;完成后改名为正式文件名
    /// - 过滤 `.json`(那是 API 元数据,不是包体)
    nonisolated static func currentDownloadFileSize(packageName: String) -> Int64? {
        guard let downloadsDir = brewDownloadsDirectory() else { return nil }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: downloadsDir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        // 优先 .incomplete(正在下载),无则取最近改动的正式文件
        var candidates: [(URL, Int64)] = []
        for url in urls {
            let name = url.lastPathComponent
            guard name.contains(packageName), !name.hasSuffix(".json") else { continue }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else { continue }
            candidates.append((url, size))
        }
        guard !candidates.isEmpty else { return nil }
        if let incomplete = candidates.first(where: { $0.0.lastPathComponent.hasSuffix(".incomplete") }) {
            return incomplete.1
        }
        // 下载完成后没有 .incomplete,取最新改动的
        let sorted = candidates.sorted { l, r in
            let lDate = (try? FileManager.default.attributesOfItem(atPath: l.0.path)[.modificationDate] as? Date) ?? .distantPast
            let rDate = (try? FileManager.default.attributesOfItem(atPath: r.0.path)[.modificationDate] as? Date) ?? .distantPast
            return lDate > rDate
        }
        return sorted.first?.1
    }

    /// brew 下载缓存目录:$HOME/Library/Caches/Homebrew/downloads
    nonisolated static func brewDownloadsDirectory() -> URL? {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/Homebrew/downloads")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return dir
    }
}

/// 下载进度轮询器:与 brew 输出流解耦,定时采样缓存文件大小,实时计算下载速度。
/// 独立于 brew 输出事件——即使 brew 在非 TTY 下几乎不输出(如静默下载),也能持续上报速度。
final class PollingMonitor {
    private let monitor: () -> Int64?
    private let interval: TimeInterval
    private let onSample: (Int64, Double) -> Void
    private var timer: DispatchSourceTimer?
    private var lastSize: Int64 = 0
    private var lastTime: Date = Date()
    private var hasBaseline = false
    private let queue = DispatchQueue(label: "brewua.download-monitor")

    /// - Parameters:
    ///   - sample: 返回当前已下载字节(需线程安全)
    ///   - interval: 采样间隔秒
    ///   - onSample: 上报 (当前大小, 速度B/s)
    init(sample: @escaping () -> Int64?, interval: TimeInterval = 0.6,
         onSample: @escaping (Int64, Double) -> Void) {
        self.monitor = sample
        self.interval = interval
        self.onSample = onSample
    }

    convenience init(packageName: String, kind: PackageKind, interval: TimeInterval = 0.6,
                     onSample: @escaping (Int64, Double) -> Void) {
        self.init(sample: { BrewService.currentDownloadFileSize(packageName: packageName) },
                  interval: interval,
                  onSample: onSample)
    }

    /// 采样一次(由外部循环或定时器调用,返回当前大小)并报告速度。
    /// 若采样失败返回 nil(文件未出现或已改名)。
    func sample() -> Int64? {
        guard let size = monitor() else { return nil }
        let now = Date()
        if hasBaseline {
            let dt = now.timeIntervalSince(lastTime)
            if dt >= 0.2 {
                let speed = max(0, Double(size - lastSize) / dt)
                report(size, speed)
                lastSize = size
                lastTime = now
            }
        } else {
            hasBaseline = true
            lastSize = size
            lastTime = now
            report(size, 0)
        }
        return size
    }

    /// 上报回调强制主线程:定时器在独立队列,后台线程直接改 @Published 会触发
    /// SwiftUI 后台重建主菜单崩溃(SIGABRT)。主线程调用则直通。
    private func report(_ size: Int64, _ speed: Double) {
        if Thread.isMainThread {
            onSample(size, speed)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onSample(size, speed)
            }
        }
    }

    /// 启动独立定时轮询(下载期间自动持续上报速度,不依赖 brew 输出)。
    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            _ = self?.sample()
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
