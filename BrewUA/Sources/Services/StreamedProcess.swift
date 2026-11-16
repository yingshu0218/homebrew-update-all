import Foundation

/// 一条流程事件:标准输出行 / 标准错误行。
enum LineEvent {
    case stdout(String)
    case stderr(String)

    var text: String {
        switch self {
        case .stdout(let s), .stderr(let s): return s
        }
    }
}

enum ProcessError: Error, LocalizedError {
    case spawnFailed(String)
    case terminated(code: Int32)
    case timedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let cmd): return "无法启动进程: \(cmd)"
        case .terminated(let code): return "进程异常退出(\(code))"
        case .timedOut(let seconds): return "进程运行超时(\(Int(seconds)) 秒)"
        }
    }
}

struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32?
    let timedOut: Bool
    let cancelled: Bool
    let streamSucceeded: Bool

    var success: Bool { streamSucceeded && !timedOut && !cancelled && exitCode == 0 }
    /// 用于错误提示的兼容汇总；结构化数据调用方应只读取 stdout。
    var output: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: stdout.isEmpty || stderr.isEmpty ? "" : "\n")
    }
}

/// 行聚合器:跨 chunk 的 UTF-8 边界安全解码 + \r 作为行分隔。
///
/// 修复记录:
/// - 旧实现 `String(data:encoding:.utf8)` 在多字节字符(中文/✔︎)被 chunk 边界截断时
///   解码失败直接丢弃整块数据 → 改为只解码完整序列,尾部不完整字节留待下个 chunk。
/// - 旧实现把 \r 全量替换为空,brew/curl 的 \r 刷新进度行会粘连成超长行 → 改为 \r 分行。
final class LineAggregator {
    private let lock = NSLock()
    private var pendingData = Data()   // 尾部尚未解码的 UTF-8 不完整序列
    private var lineBuffer = ""        // 已解码但未见行分隔符的文本
    private let yield: (String) -> Void

    init(yield: @escaping (String) -> Void) {
        self.yield = yield
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        pendingData.append(data)
        // 只解码完整 UTF-8 序列,尾部不完整字节留待下一个 chunk
        let (safeLength, _) = Self.utf8SafeSplit(pendingData)
        guard safeLength > 0 else { return }
        // 替换已确定非法的 UTF-8 字节，不能让单个坏字节卡住后续日志。
        let decoded = String(decoding: pendingData.prefix(safeLength), as: UTF8.self)
        lineBuffer += decoded
        pendingData = pendingData.count > safeLength ? Data(pendingData.suffix(pendingData.count - safeLength)) : Data()
        flushLinesLocked()
    }

    /// 进程结束后调用:输出残余 buffer(无行分隔符结尾的最后一行)
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if !pendingData.isEmpty {
            // 最后残余即使不完整也尽力解码(容错)
            lineBuffer += String(decoding: pendingData, as: UTF8.self)
            pendingData = Data()
        }
        if !lineBuffer.isEmpty {
            emitLocked(lineBuffer)
            lineBuffer = ""
        }
    }

    private func flushLinesLocked() {
        while let newline = lineBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            emitLocked(String(lineBuffer[..<newline]))
            lineBuffer.removeSubrange(...newline)
        }
    }

    /// \r 也作为行分隔(brew/curl 进度刷新);纯空白行跳过
    private func emitLocked(_ raw: String) {
        for part in raw.split(separator: "\r", omittingEmptySubsequences: false) {
            if !part.trimmingCharacters(in: .whitespaces).isEmpty {
                yield(String(part))
            }
        }
    }

    /// 计算完整 UTF-8 前缀长度:尾部若是不完整的多字节序列则截出。
    /// - Returns: (可安全解码的字节数, 尾部不完整字节数)
    static func utf8SafeSplit(_ data: Data) -> (Int, Int) {
        guard !data.isEmpty else { return (0, 0) }
        let tail = [UInt8](data.suffix(4))
        // 从尾往前找 UTF-8 序列起始字节(非 10xxxxxx continuation)
        var startIdx: Int?
        for (k, byte) in tail.enumerated().reversed() {
            if byte & 0b1100_0000 != 0b1000_0000 {
                startIdx = k
                break
            }
        }
        guard let k = startIdx else {
            // 尾部 4 字节全是 continuation(异常),交由解码器容错
            return (data.count, 0)
        }
        let byte = tail[k]
        let expected: Int
        if byte & 0b1000_0000 == 0 { return (data.count, 0) }            // ASCII 结尾,完整
        else if byte & 0b1110_0000 == 0b1100_0000 { expected = 2 }
        else if byte & 0b1111_0000 == 0b1110_0000 { expected = 3 }
        else if byte & 0b1111_1000 == 0b1111_0000 { expected = 4 }
        else { return (data.count, 0) }                                  // 非法起始字节,容错
        let available = tail.count - k
        if available >= expected { return (data.count, 0) }
        return (data.count - available, available)
    }
}

/// GUI 中统一运行 brew 子进程的封装。
///
/// - 显式注入 PATH(macOS GUI 应用不继承 shell 环境,不注入找不到 brew)
/// - 通过 `FileHandle.readabilityHandler` 流式读取 stdout/stderr,
///   转成 `AsyncThrowingStream<LineEvent>`,事件驱动、不忙轮询
/// - 用 `python3 -c 'os.setsid()'` 包装成会话领导者,
///   使 brew 及子孙进程同组(等价 zsh 源的 `os.setsid()` 包装),
///   便于超时时 `kill(-pid, SIGTERM)` 整组终止
final class StreamedProcess {
    let executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    private(set) var process: Process?
    private let statusLock = NSLock()
    private var storedTerminationStatus: Int32?
    private(set) var terminationStatus: Int32? {
        get {
            statusLock.lock()
            defer { statusLock.unlock() }
            return storedTerminationStatus
        }
        set {
            statusLock.lock()
            storedTerminationStatus = newValue
            statusLock.unlock()
        }
    }
    private let terminationLock = NSLock()
    private var terminationRequested = false
    private var pipeDrainCompleted = false
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - 活跃进程登记(供 App 退出时精准终止,替代误伤面过大的 pkill -f)

    private static let registryLock = NSLock()
    private static var activePIDs: Set<Int32> = []

    static func registerActive(pid: Int32) {
        guard pid > 0 else { return }
        registryLock.lock()
        activePIDs.insert(pid)
        registryLock.unlock()
    }

    static func unregisterActive(pid: Int32) {
        registryLock.lock()
        activePIDs.remove(pid)
        registryLock.unlock()
    }

    /// 终止本 App 启动的全部活跃 brew 进程(SIGTERM)。
    /// 只碰登记表里的 PID,不匹配系统命令行——不会误杀用户终端里自跑的 brew。
    static func terminateAllActive() {
        registryLock.lock()
        let pids = activePIDs
        registryLock.unlock()
        for pid in pids {
            let groupKilled = kill(-pid, SIGTERM) == 0
            if !groupKilled {
                kill(pid, SIGTERM)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
            }
        }
    }

    static let brewEnv: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_VERBOSE"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return env
    }()

    init(executableURL: URL, arguments: [String] = [], environment: [String: String] = StreamedProcess.brewEnv) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }

    convenience init(brewArguments: [String], environment: [String: String] = StreamedProcess.brewEnv,
                     brewPath: String? = nil) {
        // Foundation.Process 通常已把子进程设为进程组长；只有不是组长时才调用 setsid。
        // exec 保留 PID/PGID，使整个 brew 子进程树可按本次进程组精确回收。
        let runner = """
        import os, sys
        if os.getpgrp() != os.getpid():
            try:
                os.setsid()
            except OSError as error:
                os.write(2, ("cannot create isolated brew process group: " + str(error) + "\\n").encode())
                sys.exit(126)
        os.execv(sys.argv[1], sys.argv[1:])
        """
        let selectedBrewPath = brewPath ?? StreamedProcess.brewExecutablePath()
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        self.init(
            executableURL: python,
            arguments: ["-c", runner, selectedBrewPath] + brewArguments,
            environment: environment
        )
    }

    /// 定位 brew 可执行文件:/opt/homebrew/bin/brew 或 /usr/local/bin/brew
    static func brewExecutablePath() -> String {
        let candidates = Constants.brewPathCandidates
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "/opt/homebrew/bin/brew"
    }

    /// 运行进程,流式产出输出行,直到进程结束。
    /// - 若进程以非 0 退出,流在末尾抛出 `terminated`。
    /// - 用 `Task` 包裹可随时 `cancel()`(会终止进程)。
    func run(timeout: TimeInterval? = nil) -> AsyncThrowingStream<LineEvent, Error> {
        let source = runUnbounded()
        return AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    let completed = try await withThrowingTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            for try await event in source {
                                continuation.yield(event)
                            }
                            return !Task.isCancelled
                        }
                        if let timeout {
                            group.addTask {
                                do {
                                    try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                                    return false
                                } catch {
                                    return true
                                }
                            }
                        }
                        let completed = try await group.next() ?? false
                        group.cancelAll()
                        if !completed { await self.terminateAndWait() }
                        try? await group.waitForAll()
                        return completed
                    }
                    if completed {
                        continuation.finish()
                    } else if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                    } else if let timeout {
                        continuation.finish(throwing: ProcessError.timedOut(seconds: timeout))
                    } else {
                        continuation.finish(throwing: CancellationError())
                    }
                } catch {
                    await self.terminateAndWait()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { worker.cancel() }
            }
        }
    }

    /// 终止本次进程组并等待组内进程全部退出、stdout/stderr 管道完全排空。
    /// 调用方必须在释放 BrewGate 前等待此方法完成。
    func terminateAndWait() async {
        guard let process, process.processIdentifier > 0 else { return }
        let pid = process.processIdentifier
        requestTermination(pid: pid, process: process)
        let graceDeadline = Date().addingTimeInterval(2)
        while isProcessGroupAlive(pid) || process.isRunning {
            if Date() >= graceDeadline {
                if kill(-pid, SIGKILL) != 0 && process.isRunning {
                    kill(pid, SIGKILL)
                }
                break
            }
            await sleepUncancelably(nanoseconds: 40_000_000)
        }
        // The session leader can exit while a descendant keeps running after closing both pipes.
        // Wait for the whole group to disappear after SIGKILL before releasing the brew gate.
        while isProcessGroupAlive(pid) || process.isRunning {
            await sleepUncancelably(nanoseconds: 40_000_000)
        }
        await waitForPipeDrain()
    }

    func waitUntilTerminated() async {
        await waitForPipeDrain()
    }

    private func requestTermination(pid: Int32, process: Process) {
        terminationLock.lock()
        let shouldSendSignal = !terminationRequested
        if shouldSendSignal { terminationRequested = true }
        terminationLock.unlock()
        guard shouldSendSignal else { return }

        if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
        // 后台兜底也按组存活状态 KILL；不依赖已退出的 session leader 的 isRunning。
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if Self.isProcessGroupAlive(pid) {
                kill(-pid, SIGKILL)
            } else if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    private static func isProcessGroupAlive(_ pid: Int32) -> Bool {
        if kill(-pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func isProcessGroupAlive(_ pid: Int32) -> Bool {
        Self.isProcessGroupAlive(pid)
    }

    private func sleepUncancelably(nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(nanoseconds) / 1_000_000_000) {
                continuation.resume()
            }
        }
    }

    private func waitForPipeDrain() async {
        await withCheckedContinuation { continuation in
            terminationLock.lock()
            if pipeDrainCompleted {
                terminationLock.unlock()
                continuation.resume()
            } else {
                terminationWaiters.append(continuation)
                terminationLock.unlock()
            }
        }
    }

    private func markPipeDrainCompleted() {
        terminationLock.lock()
        pipeDrainCompleted = true
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        terminationLock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func runUnbounded() -> AsyncThrowingStream<LineEvent, Error> {
        AsyncThrowingStream { continuation in
            let p = Process()
            self.process = p
            p.executableURL = executableURL
            p.arguments = arguments
            p.environment = environment

            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe

            let outAggregator = LineAggregator { continuation.yield(.stdout($0)) }
            let errAggregator = LineAggregator { continuation.yield(.stderr($0)) }
            let outReadLock = NSLock()
            let errReadLock = NSLock()

            p.terminationHandler = { proc in
                self.terminationStatus = proc.terminationStatus
                // 先停止新回调，再分别等待正在进行的读取完成并 drain 尾部。
                // 锁使 readabilityHandler 与 terminationHandler 不会并发消耗/重排同一管道。
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outReadLock.lock()
                let outRest = outPipe.fileHandleForReading.readDataToEndOfFile()
                outAggregator.consume(outRest)
                outAggregator.flush()
                outReadLock.unlock()
                errReadLock.lock()
                let errRest = errPipe.fileHandleForReading.readDataToEndOfFile()
                errAggregator.consume(errRest)
                errAggregator.flush()
                errReadLock.unlock()
                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ProcessError.terminated(code: proc.terminationStatus))
                }
                self.markPipeDrainCompleted()
                StreamedProcess.unregisterActive(pid: proc.processIdentifier)
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                outReadLock.lock()
                defer { outReadLock.unlock() }
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outAggregator.consume(data)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                errReadLock.lock()
                defer { errReadLock.unlock() }
                let data = handle.availableData
                guard !data.isEmpty else { return }
                errAggregator.consume(data)
            }

            do {
                try p.run()
                StreamedProcess.registerActive(pid: p.processIdentifier)
                self.terminationLock.lock()
                let alreadyDrained = self.pipeDrainCompleted
                self.terminationLock.unlock()
                if alreadyDrained { StreamedProcess.unregisterActive(pid: p.processIdentifier) }
            } catch {
                continuation.finish(throwing: ProcessError.spawnFailed("\(executableURL.path) \(arguments.joined(separator: " "))"))
                return
            }

            continuation.onTermination = { @Sendable termination in
                guard case .cancelled = termination else { return }
                let pid = p.processIdentifier
                if pid > 0 {
                    self.requestTermination(pid: pid, process: p)
                    Task { await self.terminateAndWait() }
                }
            }
        }
    }

    // MARK: - 同步聚合

    /// 聚合运行公共实现:收集输出 + (可选)超时竞速。
    /// - Returns: (全部输出, 退出是否成功;nil 表示超时被终止)
    private func collect(timeout: TimeInterval?) async -> ProcessResult {
        enum RaceOutcome {
            case finished(String, String, Bool, Int32?, Bool)
            case timedOut
            case canceled
        }
        let stream = run()
        return await withTaskGroup(of: RaceOutcome.self) { group in
            group.addTask {
                var stdout = ""
                var stderr = ""
                var ok = true
                do {
                    for try await event in stream {
                        switch event {
                        case .stdout(let line): stdout += line + "\n"
                        case .stderr(let line): stderr += line + "\n"
                        }
                    }
                } catch {
                    // 非 0 退出也保留两条管道的内容供上层显示。
                    ok = false
                }
                let cancelled = Task.isCancelled
                return .finished(stdout, stderr, ok && !cancelled, self.terminationStatus, cancelled)
            }
            if let timeout {
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                        return .timedOut
                    } catch {
                        return .canceled
                    }
                }
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            if Task.isCancelled { await self.terminateAndWait() }
            switch first {
            case .finished(let stdout, let stderr, let ok, let exitCode, let cancelled):
                return ProcessResult(stdout: stdout, stderr: stderr, exitCode: exitCode,
                                     timedOut: false, cancelled: cancelled, streamSucceeded: ok)
            case .timedOut:
                // 超时/调用方取消：取消收集任务会终止进程组；等待它回收并取回部分输出。
                await self.terminateAndWait()
                let partial = await group.next()
                if case .finished(let stdout, let stderr, let ok, let exitCode, let cancelled)? = partial {
                    return ProcessResult(stdout: stdout, stderr: stderr, exitCode: exitCode,
                                         timedOut: true, cancelled: cancelled, streamSucceeded: ok)
                }
                return ProcessResult(stdout: "", stderr: "", exitCode: nil,
                                     timedOut: true, cancelled: false, streamSucceeded: false)
            case .canceled:
                await self.terminateAndWait()
                let partial = await group.next()
                if case .finished(let stdout, let stderr, let ok, let exitCode, let cancelled)? = partial {
                    return ProcessResult(stdout: stdout, stderr: stderr, exitCode: exitCode,
                                         timedOut: false, cancelled: cancelled, streamSucceeded: ok)
                }
                return ProcessResult(stdout: "", stderr: "", exitCode: nil,
                                     timedOut: false, cancelled: true, streamSucceeded: false)
            }
        }
    }

    /// 同步运行并聚合全部输出(用于 info/version 等轻量命令)。
    /// 超时、取消和非零退出均抛错；输出仍可由 runSyncChecked 取回用于诊断。
    func runSync(timeout: TimeInterval = 30) async throws -> String {
        let result = await collect(timeout: timeout)
        if result.timedOut { throw ProcessError.timedOut(seconds: timeout) }
        if result.cancelled { throw CancellationError() }
        guard result.success else { throw ProcessError.terminated(code: result.exitCode ?? -1) }
        return result.output
    }

    /// 同步运行并返回 (聚合输出, 是否成功退出)。
    /// 需要区分成败的调用方(uninstall 等)用这个;超时/非 0 均判定为失败。
    func runSyncChecked(timeout: TimeInterval = 120) async -> ProcessResult {
        await collect(timeout: timeout)
    }
}
