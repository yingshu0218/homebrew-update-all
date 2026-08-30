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

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let cmd): return "无法启动进程: \(cmd)"
        case .terminated(let code): return "进程异常退出(\(code))"
        }
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
        guard safeLength > 0,
              let decoded = String(data: pendingData.prefix(safeLength), encoding: .utf8) else { return }
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
            lineBuffer += String(data: pendingData, encoding: .utf8) ?? ""
            pendingData = Data()
        }
        if !lineBuffer.isEmpty {
            emitLocked(lineBuffer)
            lineBuffer = ""
        }
    }

    private func flushLinesLocked() {
        while let newline = lineBuffer.firstIndex(of: "\n") {
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
    /// 退出码(terminationHandler 触发后可读;nil = 尚未退出)
    private(set) var terminationStatus: Int32?

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

    convenience init(brewArguments: [String], environment: [String: String] = StreamedProcess.brewEnv) {
        // 用 python3 setsid 包装成会话领导者,使 brew 及子孙进程同组,可整组 kill
        // (等价 zsh 源的 os.setsid() 包装;GUI 无法保证 Process 有 processGroup 属性)
        //
        // setsid 不是硬依赖:部分环境(以 responsibility 进程 / GUI app 启动的子进程)
        // 会抛 PermissionError: Operation not permitted。此时降级为直接 execv,
        // 命令照常执行,仅"整组终止"能力降级(见 run() 的 kill 兜底)。
        let runner = """
        import os, sys
        try:
            os.setsid()
        except OSError:
            pass
        os.execv(sys.argv[1], sys.argv[1:])
        """
        let brewPath = StreamedProcess.brewExecutablePath()
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        self.init(
            executableURL: python,
            arguments: ["-c", runner, brewPath] + brewArguments,
            environment: environment
        )
    }

    /// 定位 brew 可执行文件:/opt/homebrew/bin/brew 或 /usr/local/bin/brew
    static func brewExecutablePath() -> String {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "/opt/homebrew/bin/brew"
    }

    /// 运行进程,流式产出输出行,直到进程结束。
    /// - 若进程以非 0 退出,流在末尾抛出 `terminated`。
    /// - 用 `Task` 包裹可随时 `cancel()`(会终止进程)。
    func run() -> AsyncThrowingStream<LineEvent, Error> {
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

            p.terminationHandler = { proc in
                self.terminationStatus = proc.terminationStatus
                // 停止异步读取后,同步读完管道残余再收流。
                // (旧实现直接置 nil 收流:内核缓冲里未消费的数据全部丢失,大 JSON 尾部被截断)
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let outRest = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errRest = errPipe.fileHandleForReading.readDataToEndOfFile()
                outAggregator.consume(outRest)
                errAggregator.consume(errRest)
                outAggregator.flush()
                errAggregator.flush()
                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ProcessError.terminated(code: proc.terminationStatus))
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outAggregator.consume(data)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                errAggregator.consume(data)
            }

            do {
                try p.run()
                StreamedProcess.registerActive(pid: p.processIdentifier)
            } catch {
                continuation.finish(throwing: ProcessError.spawnFailed("\(executableURL.path) \(arguments.joined(separator: " "))"))
                return
            }

            continuation.onTermination = { @Sendable _ in
                let pid = p.processIdentifier
                StreamedProcess.unregisterActive(pid: pid)
                if pid > 0 {
                    // setsid 成功时子进程是新会话组长,-pid 可整组终止;
                    // setsid 被拒时子进程在原进程组,组终止会 EPERM,降级杀主进程。
                    let groupKilled = kill(-pid, SIGTERM) == 0
                    if !groupKilled {
                        kill(pid, SIGTERM)
                    }
                    // 给进程 2 秒从容退出,再强杀
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if p.isRunning {
                            if kill(-pid, SIGKILL) != 0 {
                                kill(pid, SIGKILL)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 同步聚合

    /// 聚合运行公共实现:收集输出 + (可选)超时竞速。
    /// - Returns: (全部输出, 退出是否成功;nil 表示超时被终止)
    private func collect(timeout: TimeInterval?) async -> (output: String, success: Bool?) {
        enum RaceOutcome {
            case finished(String, Bool)
            case timedOut
        }
        let stream = run()
        return await withTaskGroup(of: RaceOutcome.self) { group in
            group.addTask {
                var collected = ""
                var ok = true
                do {
                    for try await event in stream {
                        collected += event.text + "\n"
                    }
                } catch {
                    // 非 0 退出也保留收集到的输出(如 brew doctor),上层按输出判定
                    ok = false
                }
                return .finished(collected, ok)
            }
            if let timeout {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return .timedOut
                }
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            switch first {
            case .finished(let output, let ok):
                return (output, ok)
            case .timedOut:
                // 超时:取消收集任务(取消触发 onTermination 杀进程组),等待其返回已收集部分
                let partial = await group.next()
                if case .finished(let output, _)? = partial {
                    return (output, false)
                }
                return ("", false)
            }
        }
    }

    /// 同步运行并聚合全部输出(用于 info/version 等轻量命令)。
    /// 超时会取消进程并返回已收集内容(旧语义保留:非 0 退出也返回输出,上层按输出判定)。
    func runSync(timeout: TimeInterval = 30) async throws -> String {
        let (output, _) = await collect(timeout: timeout)
        return output
    }

    /// 同步运行并返回 (聚合输出, 是否成功退出)。
    /// 需要区分成败的调用方(uninstall 等)用这个;超时/非 0 均判定为失败。
    func runSyncChecked(timeout: TimeInterval = 120) async -> (output: String, success: Bool) {
        let (output, success) = await collect(timeout: timeout)
        return (output, success ?? false)
    }
}
