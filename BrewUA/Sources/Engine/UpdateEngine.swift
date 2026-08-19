import Foundation
import Combine

/// 升级过程所处的阶段(对应 brew-ua 的两阶段流程)
enum EnginePhase: Equatable {
    case idle
    case updatingTaps
    case fetchingOutdated
    case phase1Download
    case phase2Install
    case cleanup
    case summary
    case failed(String)
    case canceled
    case finished
}

/// 升级引擎:复刻 brew-ua 的两阶段升级 + 失败隔离。
///
/// 流程(与 zsh 源一致):
///   ① brew update(更新源)
///   ② brew outdated(列出 formula/cask,过滤屏蔽)
///   ③ 阶段1:逐包 fetch,单包超时 → 整组进程 TERM→2s→KILL;失败/超时不阻断队列
///   ④ 阶段2:仅对下载成功的包执行安装(formula→upgrade,cask→reinstall)
///   ⑤ cleanup + 统计摘要
///
/// ⚠️ 必须是 @MainActor:所有 @Published 变更都要在主线程发生。
/// 否则后台线程改 phase/tasks 会触发 SwiftUI 在后台重建 AppKit 主菜单
/// (`scenesDidChange → makeMainMenu → -[NSMenu itemArray]`),直接 SIGABRT 闪退。
/// brew 子进程全部走 async/await,主线程 await 时不阻塞 UI。
@MainActor
final class UpdateEngine: ObservableObject {
    @Published var phase: EnginePhase = .idle
    @Published var eventLog: [String] = []
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var tasks: [PackageTask] = []
    @Published private(set) var summary: RunSummary?
    /// 上次"仅检测"得到的待更新清单(升级中心据此展示勾选式列表)
    @Published private(set) var pendingUpdates: [OutdatedEntry] = []

    private var cancelFlag = false
    private var runningTask: Task<Void, Never>?
    private let services: BrewService
    private let config = ConfigService.shared
    /// 单包下载超时(秒),与 brew-ua 默认 600 一致
    var fetchTimeout: TimeInterval = 600

    init(services: BrewService = .shared) {
        self.services = services
    }

    /// 供 UI 渲染工具/预览注入假数据视图状态(生产代码不调用)。
    /// 保留公开但语义明确为工具专用。
    func injectPreview(tasks: [PackageTask], summary: RunSummary?, phase: EnginePhase, logs: [String] = [], isRunning: Bool = false) {
        self.tasks = tasks
        self.summary = summary
        self.phase = phase
        self.eventLog = logs
        self.isRunning = isRunning
    }

    var phaseTitle: String {
        switch phase {
        case .idle: return "就绪"
        case .updatingTaps: return "更新源"
        case .fetchingOutdated: return "检查更新"
        case .phase1Download: return "下载阶段"
        case .phase2Install: return "安装阶段"
        case .cleanup: return "清理"
        case .summary: return "完成"
        case .failed(let reason): return "失败: \(reason)"
        case .canceled: return "已取消"
        case .finished: return "完成"
        }
    }

    // MARK: - 公开控制

    /// 开始一次"仅检测"：只做 brew update + 列出待更新清单，不下载不安装。
    /// 结果存到 pendingUpdates,供升级中心展示勾选式清单。幂等:已在运行时忽略。
    func checkOnly(options: UpdateOptions = UpdateOptions()) {
        guard !isRunning else { return }
        cancelFlag = false
        isRunning = true
        summary = nil
        tasks = []
        pendingUpdates = []
        runningTask = Task { [weak self] in
            await self?.runCheckOnly(options: options)
        }
    }

    /// 升级指定的包(两阶段:下载→安装)。
    func upgrade(packages: [OutdatedEntry], options: UpdateOptions = UpdateOptions()) {
        guard !isRunning else { return }
        guard !packages.isEmpty else { return }
        cancelFlag = false
        isRunning = true
        summary = nil
        tasks = packages.map { PackageTask(name: $0.name, kind: $0.kind, status: .queued) }
        let startTime = Date()
        runningTask = Task { [weak self] in
            await self?.runPhase1And2(entries: packages, startTime: startTime)
        }
    }

    /// 兼容包装:升级全部待更新(老入口,不查看是否已检测)。
    func start(options: UpdateOptions = UpdateOptions()) {
        guard !isRunning else { return }
        cancelFlag = false
        isRunning = true
        summary = nil
        tasks = []
        runningTask = Task { [weak self] in
            guard let self else { return }
            // 复用 run 的①~⑤:重新检查并全部升级
            await self.run(options: options)
        }
    }

    func cancel() {
        cancelFlag = true
        // 中断当前包任务(由 run 中每个阶段检查)
        appendLog("用户请求取消…")
    }

    /// 追加一条运行日志。类本身是 @MainActor,所有调用点都在主线程,直接同步追加。
    func appendLog(_ line: String) {
        eventLog.append(line)
    }

    /// 升级后清理:移除已不在待更新清单里且已成功/取消的包。
    /// 保持 pendingUpdates 反映"此刻还剩哪些可更新"。
    private func prunePendingAfterRun() {
        let done = Set(tasks.filter { $0.status == .succeeded || $0.status == .canceled }.map(\.name))
        pendingUpdates = pendingUpdates.filter { !done.contains($0.name) }
    }

    /// 清空日志与摘要
    func reset() {
        tasks = []
        summary = nil
        eventLog = []
        phase = .idle
        pendingUpdates = []
    }

    /// 重试上一轮失败/超时的包(不走 brew update,直接下载→安装)。
    func retryFailed() {
        guard !isRunning else { return }
        let failed = tasks.filter {
            if case .failed = $0.status { return true }
            return $0.status == .timeout || $0.status == .canceled
        }
        guard !failed.isEmpty else { return }
        cancelFlag = false
        isRunning = true
        summary = nil
        // 重置这些任务为 queued,其余移除
        let failedNames = Set(failed.map(\.name))
        tasks = tasks.filter { failedNames.contains($0.name) }.map {
            var t = $0
            t.status = .queued
            t.bytesDownloaded = 0
            t.totalBytes = 0
            t.speedBytesPerSec = 0
            t.startedAt = nil
            t.finishedAt = nil
            return t
        }
        let entries = failed.map { OutdatedEntry(name: $0.name, currentVersion: "?", newestVersion: "?", kind: $0.kind, isIgnored: false) }
        let startTime = Date()
        runningTask = Task { [weak self] in
            guard let self else { return }
            // 复用 run 的③④⑤逻辑:直接下载安装这些包
            await self.runPhase1And2(entries: entries, startTime: startTime)
        }
    }

    // MARK: - 主流程

    /// ① brew update + ② 列出待更新(过滤屏蔽),返回非空时也填充 pendingUpdates。
    /// 被 run()(直接升级)与 runCheckOnly()(仅检测)共用。
    private func fetchOutdated(options: UpdateOptions) async -> [OutdatedEntry] {
        // ① brew update
        phase = .updatingTaps
        appendLog("① 更新 Homebrew 源…")
        await servicesUpdate(onLine: { [weak self] in self?.appendLog("  " + $0) })

        // ② 列出待更新
        phase = .fetchingOutdated
        appendLog("② 检查待更新包…")
        let outdated = await services.outdatedAll(greedy: options.greedy)
        guard !cancelFlag else { return [] }

        let ignoredNames = config.loadIgnored()
        let entries = filterOutIgnored(outdated, ignored: ignoredNames)
        pendingUpdates = entries
        return entries
    }

    /// 仅检测:update + outdated,把结果塞进 pendingUpdates 后结束(不下载不安装)。
    private func runCheckOnly(options: UpdateOptions) async {
        let startTime = Date()
        let entries = await fetchOutdated(options: options)
        if cancelFlag {
            finish(.canceled, summary: nil)
            return
        }
        if entries.isEmpty {
            appendLog("没有需要更新的包 ✓")
            finish(.finished, summary: RunSummary(total: 0, succeeded: 0, failed: 0, timeout: 0, skipped: 0, totalDuration: Date().timeIntervalSince(startTime), failedNames: []))
        } else {
            appendLog("待更新 \(entries.count) 个包(formula \(entries.filter { $0.kind == .formula }.count), cask \(entries.filter { $0.kind == .cask }.count)),点击「更新所选」或「全部更新」开始升级")
            finish(.finished, summary: nil)
        }
    }

    private func run(options: UpdateOptions) async {
        let startTime = Date()
        let entries = await fetchOutdated(options: options)
        if cancelFlag {
            finish(.canceled, summary: nil)
            return
        }
        if entries.isEmpty {
            appendLog("没有需要更新的包 ✓")
            phase = .summary
            finish(.finished, summary: RunSummary(total: 0, succeeded: 0, failed: 0, timeout: 0, skipped: 0, totalDuration: Date().timeIntervalSince(startTime), failedNames: []))
            return
        }
        appendLog("待更新 \(entries.count) 个包(formula \(entries.filter { $0.kind == .formula }.count), cask \(entries.filter { $0.kind == .cask }.count))")

        // 初始化任务列表
        tasks = entries.map { PackageTask(name: $0.name, kind: $0.kind, status: .queued) }

        await runPhase1And2(entries: entries, startTime: startTime)
    }

    /// ③ 阶段1:逐包下载(带超时熔断)→ ④ 阶段2:安装下载成功的 → ⑤ cleanup。
    /// 供 start 与 retryFailed 复用;entries 为待处理包。
    private func runPhase1And2(entries: [OutdatedEntry], startTime: Date) async {
        // ③ 阶段1:逐包下载
        phase = .phase1Download
        appendLog("③ 阶段1:逐个下载…")
        for (idx, entry) in entries.enumerated() {
            if cancelFlag { break }
            guard let taskIdx = tasks.firstIndex(where: { $0.name == entry.name }) else { continue }
            tasks[taskIdx].status = .downloading
            tasks[taskIdx].startedAt = Date()
            appendLog("下载 [\(idx + 1)/\(entries.count)] \(entry.name)…")

            let result = await downloadWithTimeout(package: entry) { line in
                self.appendLog("  " + line)
            }

            switch result {
            case .success:
                tasks[taskIdx].status = .downloaded
                appendLog("✓ \(entry.name) 下载完成")
            case .timeout:
                tasks[taskIdx].status = .timeout
                appendLog("✗ \(entry.name) 下载超时(\(Int(fetchTimeout))s),已隔离")
            case .failed(let reason):
                tasks[taskIdx].status = .failed(reason)
                appendLog("✗ \(entry.name) 下载失败:\(reason),已隔离")
            case .canceled:
                tasks[taskIdx].status = .canceled
                appendLog("已取消 \(entry.name) 下载")
            }
        }

        guard !cancelFlag else { return finish(.canceled, summary: nil) }

        // ④ 阶段2:只安装下载成功的
        phase = .phase2Install
        let toInstall = tasks.filter { $0.status == .downloaded }
        if !toInstall.isEmpty {
            appendLog("④ 阶段2:逐个安装(\(toInstall.count) 个)…")
        }
        for (idx, task) in toInstall.enumerated() {
            guard let taskIdx = tasks.firstIndex(where: { $0.id == task.id }) else { continue }
            tasks[taskIdx].status = .installing
            tasks[taskIdx].startedAt = Date()
            appendLog("安装 [\(idx + 1)/\(toInstall.count)] \(task.name)…")
            do {
                let entry = OutdatedEntry(name: task.name, currentVersion: "?", newestVersion: "?", kind: task.kind, isIgnored: false)
                try await services.install(package: entry) { [weak self] line in
                    self?.appendLog("  " + line)
                }
                if cancelFlag {
                    tasks[taskIdx].status = .canceled
                } else {
                    tasks[taskIdx].status = .succeeded
                    appendLog("✓ \(task.name) 升级完成")
                }
            } catch {
                tasks[taskIdx].status = .failed("安装失败")
                appendLog("✗ \(task.name) 安装失败:\(error.localizedDescription)")
            }
        }

        guard !cancelFlag else { return finish(.canceled, summary: nil) }

        // ⑤ cleanup
        phase = .cleanup
        await cleanup()

        prunePendingAfterRun()
        finish(.finished, summary: buildSummary(startTime: startTime))
    }

    private func downloadWithTimeout(package: OutdatedEntry, onLine: @escaping (String) -> Void) async -> DowloadOutcome {
        // 用 Task + duration 超时实现(不忙等);超时后整组 kill
        // 显式 @MainActor:fetch 的 for-await 恢复沿用本 actor 上下文,onProgress/onLine
        // 都在主线程回调,直接改 tasks@Published 不会触发后台线程 UI 重建。
        let task = Task { @MainActor () -> DowloadOutcome in
            do {
                try await services.fetch(package: package, onLine: { line in
                    onLine(line)
                }, onProgress: { [weak self] bytes, total, speed in
                    guard let self, !Task.isCancelled else { return }
                    if let idx = self.tasks.firstIndex(where: { $0.name == package.name }) {
                        self.tasks[idx].bytesDownloaded = bytes
                        self.tasks[idx].totalBytes = total
                        self.tasks[idx].speedBytesPerSec = speed
                    }
                })
                return .success
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        // 超时熔断(与 brew-ua 单包超时同语义)
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(fetchTimeout * 1_000_000_000))
            if !task.isCancelled {
                task.cancel()
            }
        }
        let result = await task.value
        timeoutTask.cancel()
        if cancelFlag { return .canceled }
        return result
    }

    private func finish(_ phase: EnginePhase, summary: RunSummary?) {
        self.phase = phase
        self.summary = summary
        if summary != nil {
            appendLog("== 升级结束 ==")
        }
        isRunning = false
    }

    private func buildSummary(startTime: Date) -> RunSummary {
        let success = tasks.filter { $0.status == .succeeded }.count
        let failed = tasks.filter { if case .failed = $0.status { return true }; return false }.count
        let timedOut = tasks.filter { $0.status == .timeout }.count
        let total = tasks.count
        return RunSummary(
            total: total,
            succeeded: success,
            failed: failed,
            timeout: timedOut,
            skipped: 0,
            totalDuration: Date().timeIntervalSince(startTime),
            failedNames: tasks.compactMap { task in
                if case .failed = task.status { return task.name }
                return nil
            }
        )
    }

    // MARK: - 服务小封装(供日志共用)

    private func servicesUpdate(onLine: @escaping (String) -> Void) async {
        try? await services.update(onLine: onLine)
    }

    func cleanup(onLog: @escaping (String) -> Void = { _ in }) async {
        appendLog("⑤ 清理缓存…")
        // 简单一次性 cleanup,不逐显示
        let proc = StreamedProcess(brewArguments: ["cleanup", "--prune=all"])
        do {
            _ = try await proc.runSync()
        } catch {
            appendLog("cleanup 失败:\(error.localizedDescription)")
        }
        onLog("cleanup 完成")
        appendLog("cleanup 完成")
    }

    // MARK: - 状态辅助

    var successCount: Int { tasks.filter { $0.status == .succeeded }.count }
    var failedCount: Int { tasks.filter { if case .failed = $0.status { return true }; return false }.count }
    var timeoutCount: Int { tasks.filter { $0.status == .timeout }.count }
    var downloadedCount: Int { tasks.filter { $0.status == .downloaded }.count }
}

/// 每个包下载的结果
enum DowloadOutcome {
    case success
    case timeout
    case failed(String)
    case canceled
}

/// 升级选项
struct UpdateOptions {
    /// 是否用 --greedy 扫描自更新 cask(默认开,对应 brew-ua auto 默认跳过自更新)
    var greedy: Bool = false
}

/// 待更新项过滤规则(屏蔽列表) —— 提取为纯函数以便单测。
func filterOutIgnored(_ entries: [OutdatedEntry], ignored: Set<String>) -> [OutdatedEntry] {
    entries.filter { !ignored.contains($0.name) }
}