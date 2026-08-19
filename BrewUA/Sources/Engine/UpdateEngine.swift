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
final class UpdateEngine: ObservableObject {
    @Published var phase: EnginePhase = .idle
    @Published var eventLog: [String] = []
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var tasks: [PackageTask] = []
    @Published private(set) var summary: RunSummary?

    private var cancelFlag = false
    private var runningTask: Task<Void, Never>?
    private let services = BrewService.shared
    private let config = ConfigService.shared
    /// 单包下载超时(秒),与 brew-ua 默认 600 一致
    var fetchTimeout: TimeInterval = 600

    init() {}

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

    /// 开始一次升级。幂等:已在运行时忽略。
    func start(options: UpdateOptions = UpdateOptions()) {
        guard !isRunning else { return }
        cancelFlag = false
        isRunning = true
        summary = nil
        tasks = []
        runningTask = Task { [weak self] in
            await self?.run(options: options)
        }
    }

    func cancel() {
        cancelFlag = true
        // 中断当前包任务(由 run 中每个阶段检查)
        appendLog("用户请求取消…")
    }

    /// 追加一条运行日志。任务在后台线程执行,统一切回主线程触发 UI 更新。
    func appendLog(_ line: String) {
        DispatchQueue.main.async {
            self.eventLog.append(line)
        }
    }

    /// 清空日志与摘要
    func reset() {
        tasks = []
        summary = nil
        eventLog = []
        phase = .idle
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

    private func run(options: UpdateOptions) async {
        let startTime = Date()

        // ① brew update
        phase = .updatingTaps
        appendLog("① 更新 Homebrew 源…")
        await servicesUpdate(onLine: { [weak self] in self?.appendLog("  " + $0) })

        // ② 列出待更新
        phase = .fetchingOutdated
        appendLog("② 检查待更新包…")
        let outdated = await services.outdatedAll(greedy: options.greedy)
        guard !cancelFlag else { return finish(.canceled, summary: nil) }

        let ignoredNames = config.loadIgnored()
        let entries = outdated.filter { !ignoredNames.contains($0.name) }
        if entries.isEmpty {
            appendLog("没有需要更新的包 ✓")
            phase = .summary
            finish(.finished, summary: RunSummary(total: 0, succeeded: 0, failed: 0, timeout: 0, skipped: outdated.count, totalDuration: Date().timeIntervalSince(startTime), failedNames: []))
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

        finish(.finished, summary: buildSummary(startTime: startTime))
    }

    private func downloadWithTimeout(package: OutdatedEntry, onLine: @escaping (String) -> Void) async -> DowloadOutcome {
        // 用 Task + duration 超时实现(不忙等);超时后整组 kill
        let task = Task { () -> DowloadOutcome in
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