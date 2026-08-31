import XCTest
@testable import BrewUA

/// 更新历史服务测试:临时文件 round-trip、条数裁剪、清空。
final class HistoryServiceTests: XCTestCase {

    private var tempURL: URL!
    private var service: HistoryService!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewua-history-test-\(UUID().uuidString).json")
        service = HistoryService(fileURL: tempURL, maxRecords: 5)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func makeRecord(_ name: String, success: Bool = true) -> UpdateRecord {
        UpdateRecord(
            date: Date(),
            entries: [RecordEntry(
                name: name,
                kind: .formula,
                fromVersion: "1.0",
                toVersion: "2.0",
                success: success,
                detail: success ? "" : "模拟失败"
            )]
        )
    }

    /// append → load round-trip:新记录在最前
    func testAppendAndLoadOrder() {
        service.append(makeRecord("wget"))
        service.append(makeRecord("jq"))
        let records = service.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.entries.first?.name, "jq", "最新记录在前")
        XCTAssertEqual(records.last?.entries.first?.name, "wget")
    }

    /// 超过 maxRecords 裁剪最旧
    func testTrimToMaxRecords() {
        for i in 0..<8 {
            service.append(makeRecord("pkg\(i)"))
        }
        let records = service.load()
        XCTAssertEqual(records.count, 5, "超过上限 5 条后裁剪")
        XCTAssertEqual(records.first?.entries.first?.name, "pkg7", "最新保留")
        XCTAssertEqual(records.last?.entries.first?.name, "pkg3", "最旧被裁掉")
    }

    /// 失败条目携带原因,统计正确
    func testFailedEntryCounts() {
        service.append(makeRecord("bad", success: false))
        let record = service.load().first
        XCTAssertEqual(record?.succeededCount, 0)
        XCTAssertEqual(record?.failedCount, 1)
        XCTAssertEqual(record?.entries.first?.detail, "模拟失败")
    }

    /// clear 后为空
    func testClear() {
        service.append(makeRecord("wget"))
        service.clear()
        XCTAssertTrue(service.load().isEmpty)
    }
}
