import XCTest

/// 升级状态机流程测试:注入 MockBrewService 驱动引擎,不依赖真 brew。
/// 覆盖:两阶段顺序、失败隔离、更新源失败终止、运行中取消、超时熔断。
@MainActor
final class UpdateEngineFlowTests: XCTestCase {

    // MARK: - Mock

    private final class MockBrew: BrewServicing {
        var updateError: Error?
        var outdatedError: Error?
        var outdatedResult: [OutdatedEntry] = []
        var failingPackages: Set<String> = []
        var failingPackageIDs: Set<PackageIdentity> = []
        var fetchDelay: TimeInterval = 0
        var updateDelay: TimeInterval = 0
        var autoFlags: [String: Bool] = [:]
        /// fetch 收到输出行时的回调(模拟运行中用户点取消)
        var onFetchLine: (() -> Void)?
        var onInstall: (() -> Void)?
        private(set) var fetchedNames: [String] = []
        private(set) var fetchedPackageIDs: [PackageIdentity] = []
        private(set) var installedNames: [String] = []
        private(set) var installedPackageIDs: [PackageIdentity] = []
        private(set) var outdatedCallCount = 0
        private(set) var cleanupCalled = false

        func update(onLine: @escaping (String) -> Void) async throws {
            if let updateError { throw updateError }
            if updateDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(updateDelay * 1_000_000_000))
            }
        }

        func outdatedAll(greedy: Bool) async throws -> [OutdatedEntry] {
            outdatedCallCount += 1
            if let outdatedError { throw outdatedError }
            return outdatedResult
        }

        func fetch(package: OutdatedEntry, onLine: @escaping (String) -> Void, onProgress: @escaping (Int64, Int64, Double) -> Void) async throws {
            fetchedNames.append(package.name)
            fetchedPackageIDs.append(package.identity)
            onLine("mock download \(package.name)")
            onFetchLine?()
            if fetchDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(fetchDelay * 1_000_000_000))
            }
            if Task.isCancelled { throw CancellationError() }
            if failingPackages.contains(package.name) || failingPackageIDs.contains(package.identity) {
                throw NSError(domain: "mock", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟下载失败"])
            }
            onProgress(100, 100, 0)
        }

        func install(package: OutdatedEntry, onLine: @escaping (String) -> Void) async throws {
            installedNames.append(package.name)
            installedPackageIDs.append(package.identity)
            onInstall?()
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

    private func makeEngine(_ mock: MockBrew) -> UpdateEngine {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brewua-flow-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        let config = ConfigService(fileURL: directory.appendingPathComponent("ignored_casks"))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UpdateEngine(services: mock, history: HistoryService(fileURL: url), config: config)
    }

    private func waitForIdle(_ engine: UpdateEngine) async {
        for _ in 0..<300 {
            if !engine.isRunning { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 用例

    /// 两阶段全流程:全部下载成功 → 全部安装成功 → cleanup 收尾
    func testHappyPath() async {
        let mock = MockBrew()
        let engine = makeEngine(mock)
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
        let engine = makeEngine(mock)
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
        let engine = makeEngine(mock)
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
        let engine = makeEngine(mock)
        mock.outdatedResult = [entry("wget"), entry("jq")]
        _ = await engine.fetchOutdated(options: UpdateOptions())
        mock.onFetchLine = { engine.cancel() } // 模拟用户在下载第一个包时点「取消」
        mock.fetchDelay = 0.4

        await engine.runPhase1And2(entries: [entry("wget"), entry("jq")], startTime: Date())

        // 当前包被取消;后续包未执行,保持 queued(不进入安装阶段)
        XCTAssertEqual(engine.tasks.first(where: { $0.name == "wget" })?.status, .canceled)
        XCTAssertEqual(engine.tasks.first(where: { $0.name == "jq" })?.status, .queued)
        XCTAssertTrue(mock.installedNames.isEmpty, "取消后不进入安装阶段")
        XCTAssertEqual(engine.phase, .canceled)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.pendingUpdates.map(\.name), ["wget", "jq"], "取消的包仍应出现在待更新列表")
    }

    /// 超时熔断:单包下载超过 fetchTimeout → 标记 timeout,不进入安装阶段
    func testFetchTimeoutIsolation() async {
        let mock = MockBrew()
        let engine = makeEngine(mock)
        engine.fetchTimeout = 0.3
        mock.fetchDelay = 2.0 // 每包挂起 2s,引擎 0.3s 即超时打断

        await engine.runPhase1And2(entries: [entry("slow"), entry("jq")], startTime: Date())

        XCTAssertEqual(engine.tasks.map(\.status), [.timeout, .timeout])
        XCTAssertTrue(mock.installedNames.isEmpty, "超时的包不进入安装阶段")
        XCTAssertEqual(engine.phase, .finished)
    }
    func testQueryFailurePreservesPendingUpdates() async {
        let mock = MockBrew()
        mock.outdatedResult = [entry("wget")]
        let engine = makeEngine(mock)
        _ = await engine.fetchOutdated(options: UpdateOptions())
        mock.outdatedError = SimError()
        let result = await engine.fetchOutdated(options: UpdateOptions())
        XCTAssertNil(result)
        XCTAssertEqual(engine.pendingUpdates.map(\.name), ["wget"])
        if case .failed = engine.phase {} else { XCTFail("查询失败不能显示为无更新") }
        XCTAssertTrue(mock.fetchedNames.isEmpty)
    }

    func testSuccessfulPackagesRemovedFromPending() async {
        let mock = MockBrew()
        mock.outdatedResult = [entry("wget"), entry("broken")]
        mock.failingPackages = ["broken"]
        let engine = makeEngine(mock)
        _ = await engine.fetchOutdated(options: UpdateOptions())
        await engine.runPhase1And2(entries: mock.outdatedResult, startTime: Date())
        XCTAssertEqual(engine.pendingUpdates.map(\.name), ["broken"])
    }

    func testLogIsBoundedAndKeepsLatestLines() {
        let engine = makeEngine(MockBrew())
        for n in 0..<(UpdateEngine.maxLogLines + 10) { engine.appendLog("line \(n)") }
        XCTAssertEqual(engine.eventLog.count, UpdateEngine.maxLogLines)
        XCTAssertEqual(engine.eventLog.first, "line 10")
        XCTAssertEqual(engine.eventLog.last, "line \(UpdateEngine.maxLogLines + 9)")
        XCTAssertEqual(engine.logRevision, UInt64(UpdateEngine.maxLogLines + 10))
    }

    func testCancelDuringInstallOnlyRemovesCompletedPackage() async {
        let mock = MockBrew()
        mock.outdatedResult = [entry("wget"), entry("jq")]
        let engine = makeEngine(mock)
        _ = await engine.fetchOutdated(options: UpdateOptions())
        mock.onInstall = { engine.cancel() }
        await engine.runPhase1And2(entries: mock.outdatedResult, startTime: Date())
        XCTAssertEqual(mock.installedNames, ["wget"])
        XCTAssertEqual(engine.phase, .canceled)
        XCTAssertEqual(engine.pendingUpdates.map(\.name), ["jq"])
    }

    func testSameNameFormulaAndCaskHaveIndependentTasksAndPendingIdentity() async {
        let mock = MockBrew()
        let formula = entry("shared", kind: .formula)
        let cask = entry("shared", kind: .cask)
        mock.outdatedResult = [formula, cask]
        mock.failingPackageIDs = [PackageIdentity(kind: .cask, name: "shared")]
        let engine = makeEngine(mock)
        _ = await engine.fetchOutdated(options: UpdateOptions())
        await engine.runPhase1And2(entries: mock.outdatedResult, startTime: Date())

        XCTAssertEqual(mock.fetchedPackageIDs, [formula.identity, cask.identity])
        XCTAssertEqual(mock.installedPackageIDs, [formula.identity])
        XCTAssertEqual(engine.tasks.count, 2)
        XCTAssertEqual(engine.tasks.first(where: { $0.identity == formula.identity })?.status, .succeeded)
        XCTAssertEqual(engine.tasks.first(where: { $0.identity == cask.identity })?.status.isTerminal, true)
        XCTAssertEqual(engine.pendingUpdates.map(\.identity), [cask.identity],
                       "formula 成功不能误删同名 cask 的剩余更新")
    }

    func testRetryPreservesOriginalVersionHistory() async throws {
        let mock = MockBrew()
        mock.failingPackages = ["retry-me"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brewua-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryService(fileURL: directory.appendingPathComponent("history.json"))
        let config = ConfigService(fileURL: directory.appendingPathComponent("ignored_casks"))
        let engine = UpdateEngine(services: mock, history: history, config: config)
        let entry = OutdatedEntry(name: "retry-me", currentVersion: "1.0", newestVersion: "2.0",
                                  kind: .formula, isIgnored: false)
        engine.upgrade(packages: [entry])
        await waitForIdle(engine)
        XCTAssertEqual(history.load().first?.entries.first?.fromVersion, "1.0")
        XCTAssertEqual(history.load().first?.entries.first?.toVersion, "2.0")

        mock.failingPackages = []
        engine.retryFailed()
        await waitForIdle(engine)
        XCTAssertEqual(history.load().first?.entries.first?.fromVersion, "1.0")
        XCTAssertEqual(history.load().first?.entries.first?.toVersion, "2.0")
    }

    func testNewIgnoreRuleIsRecheckedBeforeStartingSelectedPackages() async throws {
        let mock = MockBrew()
        let formula = entry("newly-ignored", kind: .formula)
        mock.outdatedResult = [formula]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brewua-ignore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigService(fileURL: directory.appendingPathComponent("ignored_casks"))
        let engine = UpdateEngine(services: mock, config: config)
        _ = await engine.fetchOutdated(options: UpdateOptions())
        try config.addIgnored(formula.name, kind: formula.kind)

        engine.upgrade(packages: [formula])

        XCTAssertTrue(mock.fetchedNames.isEmpty)
        XCTAssertTrue(engine.pendingUpdates.isEmpty)
        XCTAssertFalse(engine.isRunning)
    }

    func testCancelDuringUpdateStopsBeforeOutdatedQuery() async {
        let mock = MockBrew()
        mock.updateDelay = 30
        let engine = makeEngine(mock)
        engine.checkOnly()
        for _ in 0..<100 {
            if engine.phase == .updatingTaps { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        engine.cancel()
        await waitForIdle(engine)

        XCTAssertEqual(engine.phase, .canceled)
        XCTAssertEqual(mock.outdatedCallCount, 0)
        XCTAssertFalse(engine.isRunning)
    }

}
