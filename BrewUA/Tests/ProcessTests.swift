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
}