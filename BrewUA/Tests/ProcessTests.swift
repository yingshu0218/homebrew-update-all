import XCTest
import Darwin

final class ProcessTests: XCTestCase {
    /// 验证 StreamedProcess 能流式捕获 echo 输出
    func testStreamedProcessCapturesStdout() async throws {
        let proc = StreamedProcess(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello", "brewua"]
        )
        var lines: [String] = []
        for try await event in proc.run() {
            lines.append(event.text)
        }
        XCTAssertEqual(lines.joined(separator: " "), "hello brewua")
    }

    /// 验证显式注入的 PATH 能找到 brew(只跳过,不真跑 brew 避免慢)
    func testBrewEnvPathConfigured() {
        let env = StreamedProcess.brewEnv
        XCTAssertTrue(env["PATH"]?.contains("/opt/homebrew/bin") == true,
                      "必须显式注入 PATH 否则 GUI 找不到 brew")
    }
    func testCarriageReturnProgressEmittedWithoutNewline() {
        var lines: [String] = []
        let aggregator = LineAggregator { lines.append($0) }
        aggregator.consume(Data("10%\r20%\r".utf8))
        XCTAssertEqual(lines, ["10%", "20%"], "不能等待进程退出才显示进度")
        aggregator.consume(Data("30%\r\ndone\n".utf8))
        XCTAssertEqual(lines, ["10%", "20%", "30%", "done"])
    }

    func testInvalidUTF8DoesNotHideFollowingValidLog() {
        var lines: [String] = []
        let aggregator = LineAggregator { lines.append($0) }
        aggregator.consume(Data([0xff] + Array("valid line\n".utf8)))
        XCTAssertEqual(lines, ["�valid line"])
    }

    func testMultibyteCharacterAcrossChunks() {
        var lines: [String] = []
        let aggregator = LineAggregator { lines.append($0) }
        let data = Data("下载中\r".utf8)
        aggregator.consume(data.prefix(2))
        XCTAssertTrue(lines.isEmpty)
        aggregator.consume(data.dropFirst(2))
        XCTAssertEqual(lines, ["下载中"])
    }

    func testCheckedProcessReportsNonzeroExitAndTimeout() async {
        let failed = StreamedProcess(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo failure; exit 7"])
        let result = await failed.runSyncChecked()
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("failure"))
        let slow = StreamedProcess(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])
        let start = Date()
        let timeout = await slow.runSyncChecked(timeout: 0.1)
        XCTAssertFalse(timeout.success)
        XCTAssertTrue(timeout.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testStdoutStderrAndExitStatusStaySeparate() async {
        let proc = StreamedProcess(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", "printf '{\\\"formulae\\\":[],\\\"casks\\\":[]}\\n'; printf 'warning\\n' >&2"])
        let result = await proc.runSyncChecked()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("\"formulae\""))
        XCTAssertTrue(result.stderr.contains("warning"))
        XCTAssertFalse(result.stdout.contains("warning"))
    }

    func testProductionLauncherPreservesFoundationProcessGroup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brewua-launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeBrew = directory.appendingPathComponent("brew")
        let script = "#!/bin/sh\npid=$$\npgid=$(/bin/ps -o pgid= -p \"$pid\" | /usr/bin/tr -d ' ')\nprintf '%s %s\\n' \"$pid\" \"$pgid\"\n"
        try script.write(to: fakeBrew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBrew.path)

        let result = await StreamedProcess(brewArguments: [], brewPath: fakeBrew.path).runSyncChecked()
        XCTAssertTrue(result.success, result.output)
        let fields = result.stdout.split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields.first, fields.last, "exec 后假 brew 应继承 Foundation.Process 创建的独立 PGID")
    }

    func testCanceledProcessGroupIsReapedBeforeBrewGateIsReleased() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brewua-process-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeBrew = directory.appendingPathComponent("brew")
        let childPIDFile = directory.appendingPathComponent("child.pid")
        let script = "#!/bin/sh\n(trap '' TERM; echo $$ > \"$BREWUA_CHILD_PID_FILE\"; echo child-ready; exec >/dev/null 2>&1; while :; do /bin/sleep 1; done) &\necho leader-ready\nwait\n"
        try script.write(to: fakeBrew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBrew.path)
        var environment = StreamedProcess.brewEnv
        environment["BREWUA_CHILD_PID_FILE"] = childPIDFile.path
        let process = StreamedProcess(brewArguments: [], environment: environment, brewPath: fakeBrew.path)
        let gate = BrewGate()
        let leaderReady = expectation(description: "fake brew started")
        let childReady = expectation(description: "TERM-ignoring child started")
        let gateReleasedEarly = expectation(description: "brew gate released before process group exit")
        gateReleasedEarly.isInverted = true
        let gateReleased = expectation(description: "next brew acquired gate")
        let started = Date()

        let operation = Task {
            try await withBrewGate(using: gate) {
                do {
                    for try await event in process.run() {
                        if event.text == "leader-ready" { leaderReady.fulfill() }
                        if event.text == "child-ready" { childReady.fulfill() }
                    }
                    try Task.checkCancellation()
                    await process.waitUntilTerminated()
                } catch {
                    await process.terminateAndWait()
                    throw error
                }
            }
        }
        await fulfillment(of: [leaderReady, childReady], timeout: 5)
        let nextOperation = Task {
            try await withBrewGate(using: gate) {
                gateReleasedEarly.fulfill()
                gateReleased.fulfill()
            }
        }
        operation.cancel()

        await fulfillment(of: [gateReleasedEarly], timeout: 0.5)
        await fulfillment(of: [gateReleased], timeout: 5)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.5,
                             "Gate must remain held through TERM grace and process-group KILL/drain")
        _ = await operation.result
        _ = await nextOperation.result
    }

    func testRunSyncTimeoutWaitsForTermIgnoringGroupChildWithClosedPipes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brewua-closed-pipes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeBrew = directory.appendingPathComponent("brew")
        let childPIDFile = directory.appendingPathComponent("child.pid")
        let script = "#!/bin/sh\n(trap '' TERM; exec >/dev/null 2>&1; while :; do /bin/sleep 1; done) &\necho $! > \"$BREWUA_CHILD_PID_FILE\"\necho leader-ready\nwhile :; do /bin/sleep 1; done\n"
        try script.write(to: fakeBrew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBrew.path)
        var environment = StreamedProcess.brewEnv
        environment["BREWUA_CHILD_PID_FILE"] = childPIDFile.path
        let process = StreamedProcess(brewArguments: [], environment: environment, brewPath: fakeBrew.path)

        let started = Date()
        // Allow the Python exec wrapper to start on slower cold launches before timing out.
        let result = await process.runSyncChecked(timeout: 1.5)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.success)
        XCTAssertGreaterThan(elapsed, 3.3, "Timeout must wait for the two-second TERM grace and group KILL")
        let childPID = try XCTUnwrap(Int32(try String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<50 {
            if Darwin.kill(childPID, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotEqual(Darwin.kill(childPID, 0), 0, "descendant must be dead when timed-out run returns")
    }

    func testPollingMonitorSerializesStreamingAndTimerSamples() async {
        let lock = NSLock()
        var value: Int64 = 0
        var reported = 0
        let monitor = PollingMonitor(sample: {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }, interval: 0.002) { _, _ in
            lock.lock(); defer { lock.unlock() }
            reported += 1
        }
        monitor.start()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<300 { _ = monitor.sample() }
                }
            }
            group.addTask {
                for _ in 0..<40 {
                    monitor.stop()
                    monitor.start()
                    await Task.yield()
                }
            }
        }
        monitor.stop()
        let finalReported = lock.withLock { reported }
        XCTAssertGreaterThan(finalReported, 0)
    }

}
