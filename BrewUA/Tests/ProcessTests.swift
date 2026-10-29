import XCTest

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
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

}