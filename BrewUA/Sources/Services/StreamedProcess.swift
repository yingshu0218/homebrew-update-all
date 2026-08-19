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
        let runner = """
        import os, sys
        os.setsid()
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

            p.terminationHandler = { proc in
                // 确保管道洪泛期间数据被消费完
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ProcessError.terminated(code: proc.terminationStatus))
                }
            }

            var outBuf = ""
            var errBuf = ""
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                handleLines(data, buffer: &outBuf) { continuation.yield(.stdout($0)) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                handleLines(data, buffer: &errBuf) { continuation.yield(.stderr($0)) }
            }

            do {
                try p.run()
            } catch {
                continuation.finish(throwing: ProcessError.spawnFailed("\(executableURL.path) \(arguments.joined(separator: " "))"))
                return
            }

            continuation.onTermination = { @Sendable _ in
                let pid = p.processIdentifier
                if pid > 0 {
                    kill(-pid, SIGTERM)
                    // 给进程 2 秒从容退出,再强杀
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if p.isRunning {
                            kill(-pid, SIGKILL)
                        }
                    }
                }
            }
        }
    }

    /// 同步运行并聚合全部输出(用于 info/version 等轻量命令)。
    /// 用 continuation 避免 DispatchSemaphore 阻塞;超时会取消并返回已收集内容。
    func runSync(timeout: TimeInterval = 30) async throws -> String {
        var collected = ""
        let stream = run()
        do {
            for try await event in stream {
                collected += event.text + "\n"
            }
        } catch {
            // 非 0 退出也返回收集到输出(如 brew doctor),上层按输出判定
        }
        return collected
    }
}

private func handleLines(_ data: Data, buffer: inout String, yield: (String) -> Void) {
    guard let str = String(data: data, encoding: .utf8) else { return }
    buffer += str
    while let newline = buffer.firstIndex(of: "\n") {
        let line = String(buffer[..<newline])
        buffer.removeSubrange(...newline)
        // 去掉可能的 \r(brew 进度行常见),空行跳过
        let cleaned = line.replacingOccurrences(of: "\r", with: "")
        if !cleaned.isEmpty {
            yield(cleaned)
        }
    }
}