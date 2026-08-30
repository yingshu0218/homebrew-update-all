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
    private let services: BrewServicing
    private let config = ConfigService.shared
    /// 单包下载超时(秒),与 brew-ua 默认 600 一致
    var fetchTimeout: TimeInterval = 600

    init(services: BrewServicing = BrewService.shared) {
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
        // 软标志 + 下载级联取消:downloadWithTimeout 内会监听 cancelFlag 主动取消下载 Task
        // → StreamedProcess.onTermination kill(-pid) 整组终止当前 brew 进程(下载立即停)。
        // 注意不能直接 runningTask?.cancel():那会连安装中的包(services.install 的 stream)
        // 一起取消,违背"安装让当前包装完再停"的决策。安装阶段只靠循环头 cancelFlag 判断,
        // 不启动新包安装,正在安装的包安全装完。
        appendLog("用户请求取消…")
    }

    /// 追加一条运行日志。类本身是 @MainActor,但 closure 回调路径
    /// (BrewService.fetch/install/update 的 onLine 在后台 stream 恢复点执行)
    /// 可能从后台线程进来,必须切回主线程再改 @Published,否则触发
    /// SwiftUI 后台重建主菜单崩溃(SIGABRT)。
    func appendLog(_ line: String) {
        if Thread.isMainThread {
            eventLog.append(line)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.eventLog.append(line)
            }
        }
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
    /// - Returns: nil = 本轮已终结(update 失败/取消,调用方直接 return,不再 finish)
    func fetchOutdated(options: UpdateOptions) async -> [OutdatedEntry]? {
        // ① brew update:失败不能静默——用旧索引继续升级可能装到旧版本
        phase = .updatingTaps
        appendLog("① 更新 Homebrew 源…")
        do {
            try await services.update(onLine: { [weak self] in self?.appendLog("  " + $0) })
        } catch is CancellationError {
            return nil
        } catch {
            appendLog("✗ 更新 Homebrew 源失败:\(error.localizedDescription)")
            appendLog("  为避免使用过期索引升级,本轮已中止。请检查网络后重试。")
            finish(.failed("更新源失败:\(error.localizedDescription)"), summary: nil)
            return nil
        }

        // ② 列出待更新
        phase = .fetchingOutdated
        appendLog("② 检查待更新包…")
        let outdated = await services.outdatedAll(greedy: options.greedy)
        guard !cancelFlag else { return nil }

        let ignoredNames = config.loadIgnored()
        var entries = filterOutIgnored(outdated, ignored: ignoredNames)
        // ③ 补充 cask 的 auto_updates 标识(一次批量查询,升级中心据此显示"自更新"徽标)
        let caskNames = entries.filter { $0.kind == .cask }.map(\.name)
        if !caskNames.isEmpty {
            let autoFlags = await services.caskAutoUpdates(names: caskNames)
            if !autoFlags.isEmpty {
                entries = entries.map { entry in
                    guard entry.kind == .cask, let flag = autoFlags[entry.name] else { return entry }
                    var e = entry
                    e.autoUpdates = flag
                    return e
                }
            }
        }
        pendingUpdates = entries
        return entries
    }

    /// 仅检测:update + outdated,把结果塞进 pendingUpdates 后结束(不下载不安装)。
    private func runCheckOnly(options: UpdateOptions) async {
        let startTime = Date()
        guard let entries = await fetchOutdated(options: options) else {
            // nil:更新源失败(fetchOutdated 已 finish)或用户取消(此处收尾)
            if cancelFlag { finish(.canceled, summary: nil) }
            return
        }
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
        guard let entries = await fetchOutdated(options: options) else {
            // nil:更新源失败(fetchOutdated 已 finish)或用户取消(此处收尾)
            if cancelFlag { finish(.canceled, summary: nil) }
            return
        }
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
    /// internal 便于测试注入 mock 直接驱动状态机。
    /// 任务列表在本方法初始化(retryFailed 预置重试清单时 tasks 非空,不覆盖)。
    func runPhase1And2(entries: [OutdatedEntry], startTime: Date) async {
        if tasks.isEmpty {
            tasks = entries.map { PackageTask(name: $0.name, kind: $0.kind, status: .queued) }
        }
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
                tasks[taskIdx].speedBytesPerSec = 0 // 停止下载,速度归零,显示"已下载待安装"
                tasks[taskIdx].finishedAt = Date()
                appendLog("✓ \(entry.name) 下载完成")
            case .timeout:
                tasks[taskIdx].status = .timeout
                tasks[taskIdx].finishedAt = Date()
                appendLog("✗ \(entry.name) 下载超时(\(Int(fetchTimeout))s),已隔离")
            case .failed(let reason):
                tasks[taskIdx].status = .failed(reason)
                tasks[taskIdx].finishedAt = Date()
                appendLog("✗ \(entry.name) 下载失败:\(reason),已隔离")
            case .canceled:
                tasks[taskIdx].status = .canceled
                tasks[taskIdx].finishedAt = Date()
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
            // 取消后不再启动新包安装;正在安装的包让其安全装完
            if cancelFlag { break }
            guard let taskIdx = tasks.firstIndex(where: { $0.id == task.id }) else { continue }
            tasks[taskIdx].status = .installing
            tasks[taskIdx].finishedAt = nil
            tasks[taskIdx].speedBytesPerSec = 0
            appendLog("安装 [\(idx + 1)/\(toInstall.count)] \(task.name)…")
            do {
                let entry = OutdatedEntry(name: task.name, currentVersion: "?", newestVersion: "?", kind: task.kind, isIgnored: false)
                try await services.install(package: entry) { [weak self] line in
                    self?.appendLog("  " + line)
                }
                // 安装已完整执行完毕 → 无论是否取消都算成功(用户决策:安装让当前包装完)
                tasks[taskIdx].status = .succeeded
                tasks[taskIdx].finishedAt = Date()
                appendLog("✓ \(task.name) 升级完成")
            } catch {
                tasks[taskIdx].status = .failed("安装失败")
                tasks[taskIdx].finishedAt = Date()
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

    /// 单包下载:三路竞速(下载 / 超时熔断 / 取消监听),先到先得。
    /// - 下载完成 → .success/.failed;超时 → .timeout;用户取消 → .canceled
    /// - 竞速结束后 group.cancelAll():取消下载任务 → StreamedProcess.onTermination
    ///   kill(-pid) 整组终止 brew 进程(旧实现三个游离 Task 手动管理,且超时
    ///   引发的取消会被误标为 canceled/failed,.timeout 实际是死路径)
    /// - 下载任务 @MainActor:onProgress/onLine 都在主线程回调,改 tasks@Published 安全
    private func downloadWithTimeout(package: OutdatedEntry, onLine: @escaping (String) -> Void) async -> DowloadOutcome {
        await withTaskGroup(of: DowloadOutcome.self) { group in
            // ① 下载主体
            group.addTask { @MainActor in
                do {
                    try await self.services.fetch(package: package, onLine: { line in
                        onLine(line)
                    }, onProgress: { bytes, total, speed in
                        guard !Task.isCancelled else { return }
                        if let idx = self.tasks.firstIndex(where: { $0.name == package.name }) {
                            self.tasks[idx].bytesDownloaded = bytes
                            self.tasks[idx].totalBytes = total
                            self.tasks[idx].speedBytesPerSec = speed
                        }
                    })
                    // 正常结束:若期间用户点了取消,也按取消处理(放弃进入阶段2)
                    return self.cancelFlag ? .canceled : .success
                } catch is CancellationError {
                    return .canceled
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            // ② 超时熔断(与 brew-ua 单包超时同语义)
            group.addTask { [fetchTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(fetchTimeout * 1_000_000_000))
                return .timeout
            }
            // ③ 取消监听:用户点击「取消」→ cancelFlag 置位 → 立即返回取消
            group.addTask { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if self?.cancelFlag == true { return .canceled }
                }
                return .canceled
            }
            let first = await group.next() ?? .canceled
            group.cancelAll() // 取消其余竞速者(含下载任务 → 杀 brew 进程)
            return first
        }
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

    func cleanup(onLog: @escaping (String) -> Void = { _ in }) async {
        appendLog("⑤ 清理缓存…")
        let ok = await services.cleanupAll()
        if !ok {
            appendLog("cleanup 失败")
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