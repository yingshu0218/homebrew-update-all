import XCTest

/// 升级引擎纯逻辑测试:不依赖真 brew,验证"应用商店式"流程的状态机与过滤规则。
final class UpdateEngineLogicTests: XCTestCase {

    /// 屏蔽列表过滤:屏蔽的包移出待更新清单
    func testFilterOutIgnored() {
        let entries = [
            makeEntry("wget"),
            makeEntry("firefox"),
            makeEntry("mysql")
        ]
        let result = filterOutIgnored(entries, ignored: ["firefox"])
        XCTAssertEqual(result.map(\.name), ["wget", "mysql"])
    }

    /// 空屏蔽列表不影响
    func testFilterOutIgnoredEmptyIgnored() {
        let entries = [makeEntry("wget")]
        XCTAssertEqual(filterOutIgnored(entries, ignored: []).count, 1)
    }

    /// 全屏蔽 → 空清单
    func testFilterOutIgnoredAllIgnored() {
        let entries = [makeEntry("wget")]
        XCTAssertTrue(filterOutIgnored(entries, ignored: ["wget"]).isEmpty)
    }

    /// upgrade(packages:) 空包列表是安全的(直接忽略,不启动)
    @MainActor
    func testUpgradeEmptyPackagesIsNoop() {
        let engine = UpdateEngine()
        engine.upgrade(packages: [])
        XCTAssertFalse(engine.isRunning)
        XCTAssertTrue(engine.tasks.isEmpty)
    }

    /// 关联测试:disabled 逻辑 —— 无待更新时"更新所选"按钮不可用(在视图层,这里验证 guard)
    @MainActor
    func testPendingUpdatesDefaultEmpty() {
        let engine = UpdateEngine()
        XCTAssertTrue(engine.pendingUpdates.isEmpty)
    }

    private func makeEntry(_ name: String) -> OutdatedEntry {
        OutdatedEntry(name: name, currentVersion: "1.0", newestVersion: "2.0", kind: .formula, isIgnored: false)
    }
}