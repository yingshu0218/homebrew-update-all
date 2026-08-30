import XCTest

/// 升级状态机流程测试:注入 MockBrewService 驱动引擎,不依赖真 brew。
/// 覆盖:两阶段顺序、失败隔离、更新源失败终止、运行中取消、超时熔断。
@MainActor
final class UpdateEngineFlowTests: XCTestCase {

    // MARK: - Mock

    private final class MockBrew: BrewServicing {
        var updateError: Error?
        var outdatedResult: [OutdatedEntry] = []
        var failingPackages: Set<String> = []
        var fetchDelay: TimeInterval = 0
        var autoFlags: [String: Bool] = [:]
        /// fetch 收到输出行时的回调(模拟运行中用户点取消)
        var onFetchLine: (() -> Void)?
        private(set) var fetchedNames: [String] = []
        private(set) var installedNames: [String] = []
        private(set) var cleanupCalled = false

        func update(onLine: @escaping (String) -> Void) async throws {
            if let updateError { throw updateError }
        }

        func outdatedAll(greedy: Bool) async -> [OutdatedEntry] {
            outdatedResult
        }

        func fetch(package: OutdatedEntry, onLine: @escaping (String) -> Void, onProgress: @escaping (Int64, Int64, Double) -> Void) async throws {
            fetchedNames.append(package.name)
            onLine("mock download \(package.name)")
            onFetchLine?()
            if fetchDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(fetchDelay * 1_000_000_000))
            }
            if Task.isCancelled { throw CancellationError() }
            if failingPackages.contains(package.name) {
                throw NSError(domain: "mock", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟下载失败"])
            }
            onProgress(100, 100, 0)
        }

        func install(package: OutdatedEntry, onLine: @escaping (String) -> Void) async throws {
            installedNames.append(package.name)
        }

        func caskAutoUpdates(names: [String]) async -> [String: Bool] {
            autoFlags
        }

        func cleanupAll() async -> Bool {
            cleanupCalled = true
            return true
        }
    }

    private struct SimError: LocalizedError {
        var errorDescription: String? { "模拟下载失败" }
    }

    private func entry(_ name: String, kind: PackageKind = .formula) -> OutdatedEntry {
        OutdatedEntry(name: name, currentVersion: "1.0", newestVersion: "2.0", kind: kind, isIgnored: false)
    }

    // MARK: - 用例

    /// 两阶段全流程:全部下载成功 → 全部安装成功 → cleanup 收尾
    func testHappyPath() async {
        let mock = MockBrew()
        let engine = UpdateEngine(services: mock)
        await engine.runPhase1And2(entries: [entry("wget"), entry("jq")], startTime: Date())

        XCTAssertEqual(mock.fetchedNames, ["wget", "jq"], "阶段1按序逐包下载")
        XCTAssertEqual(mock.installedNames, ["wget", "jq"], "阶段2安装全部下载成功的包")
        XCTAssertTrue(mock.cleanupCalled)
        XCTAssertEqual(engine.tasks.map(\.status), [.succeeded, .succeeded])
        XCTAssertEqual(engine.phase, .finished)
        XCTAssertTrue(engine.isRunning == false)
    }

    /// 失败隔离:一个包下载失败 → 该包隔离,其余照常下载并安装
    func testFetchFailureIsolation() async {
        let mock = MockBrew()
        mock.failingPackages = ["broken"]
        let engine = UpdateEngine(services: mock)
        await engine.runPhase1And2(entries: [entry("broken"), entry("wget")], startTime: Date())

        XCTAssertEqual(mock.fetchedNames, ["broken", "wget"], "失败不阻断队列")
        XCTAssertEqual(mock.installedNames, ["wget"], "失败的包不进入安装阶段")
        XCTAssertEqual(engine.tasks.first(where: { $0.name == "broken" })?.status.isTerminal, true)
        XCTAssertEqual(engine.tasks.first(where: { $0.name == "wget" })?.status, .succeeded)
    }

    /// 更新源失败:本轮直接终止,phase 报 failed(不用过期索引继续升级)
    func testUpdateFailureAborts() async {
        let mock = MockBrew()
        mock.updateError = SimError()
        let engine = UpdateEngine(services: mock)
        let result = await engine.fetchOutdated(options: UpdateOptions())

        XCTAssertNil(result, "update 失败应返回 nil 终止本轮")
        if case .failed = engine.phase {} else {
            XCTFail("phase 应为 failed,实际 \(engine.phase)")
        }
        XCTAssertFalse(engine.isRunning)
    }

    /// 运行中取消:下载期间点取消 → 当前包标记 canceled,剩余包不再处理
    func testCancelDuringDownload() async {
        let mock = MockBrew()
        let engine = UpdateEngine(services: mock)
        mock.onFetchLine = { engine.cancel() } // 模拟用户在下载第一个包时点「取消」
        mock.fetchDelay = 0.4

        await engine.runPhase1And2(entries: [entry("wget"), entry("jq")], startTime: Date())

        // 当前包被取消;后续包未执行,保持 queued(不进入安装阶段)
        XCTAssertEqual(engine.tasks.first(where: { $0.name == "wget" })?.status, .canceled)
        XCTAssertEqual(engine.tasks.first(where: { $0.name == "jq" })?.status, .queued)
        XCTAssertTrue(mock.installedNames.isEmpty, "取消后不进入安装阶段")
        XCTAssertEqual(engine.phase, .canceled)
        XCTAssertFalse(engine.isRunning)
    }

    /// 超时熔断:单包下载超过 fetchTimeout → 标记 timeout,不进入安装阶段
    func testFetchTimeoutIsolation() async {
        let mock = MockBrew()
        let engine = UpdateEngine(services: mock)
        engine.fetchTimeout = 0.3
        mock.fetchDelay = 2.0 // 每包挂起 2s,引擎 0.3s 即超时打断

        await engine.runPhase1And2(entries: [entry("slow"), entry("jq")], startTime: Date())

        XCTAssertEqual(engine.tasks.map(\.status), [.timeout, .timeout])
        XCTAssertTrue(mock.installedNames.isEmpty, "超时的包不进入安装阶段")
        XCTAssertEqual(engine.phase, .finished)
    }
}
