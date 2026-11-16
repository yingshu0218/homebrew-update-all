import XCTest

@MainActor
final class QueryStatusTests: XCTestCase {
    private let empty = "{\"formulae\":[],\"casks\":[]}"

    private func makeConfig() -> ConfigService {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("brewua-query-\(UUID().uuidString)/ignored_casks")
        addTeardownBlock { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        return ConfigService(fileURL: file)
    }

    func testValidEmptyOutdatedIsSuccess() async throws {
        let service = BrewService(query: { _ in self.empty }, config: makeConfig())
        let entries = try await service.outdatedAll()
        XCTAssertTrue(entries.isEmpty)
    }

    func testMalformedOutdatedThrows() async {
        let service = BrewService(query: { _ in "not JSON" }, config: makeConfig())
        do {
            _ = try await service.outdatedAll()
            XCTFail("无效输出不能被当成没有更新")
        } catch {}
    }

    func testPartialOutdatedFailureThrows() async {
        let service = BrewService(query: { args in
            if args.contains("--cask") { throw BrewService.QueryError.commandFailed("test failure") }
            return self.empty
        }, config: makeConfig())
        do {
            _ = try await service.outdatedAll()
            XCTFail("任一类别查询失败都应报错")
        } catch {}
    }

    func testPartialInstalledFailureDoesNotReplaceList() async {
        let service = BrewService(query: { args in
            if args.contains("--cask") { throw BrewService.QueryError.commandFailed("test failure") }
            return self.empty
        }, config: makeConfig())
        let result = await service.installedAllWithStatus()
        XCTAssertFalse(result.success)
    }

    func testMalformedInstalledIsFailure() async {
        let service = BrewService(query: { _ in "not JSON" }, config: makeConfig())
        let result = await service.installedAllWithStatus()
        XCTAssertFalse(result.success)
    }

    func testValidEmptyInstalledIsSuccess() async {
        let service = BrewService(query: { _ in self.empty }, config: makeConfig())
        let result = await service.installedAllWithStatus()
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.packages.isEmpty)
    }

    func testOverviewMarksMalformedQueriesUnreliable() async {
        let service = BrewService(query: { _ in "not JSON" }, config: makeConfig())
        let stats = await service.overviewStats()
        XCTAssertFalse(stats.outdatedReliable)
        XCTAssertFalse(stats.installedReliable)
    }
}
