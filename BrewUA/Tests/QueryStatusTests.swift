import XCTest

@MainActor
final class QueryStatusTests: XCTestCase {
    private let empty = "{\"formulae\":[],\"casks\":[]}"

    func testValidEmptyOutdatedIsSuccess() async throws {
        let service = BrewService(query: { _ in self.empty })
        let entries = try await service.outdatedAll()
        XCTAssertTrue(entries.isEmpty)
    }

    func testMalformedOutdatedThrows() async {
        let service = BrewService(query: { _ in "not JSON" })
        do {
            _ = try await service.outdatedAll()
            XCTFail("无效输出不能被当成没有更新")
        } catch {}
    }

    func testPartialOutdatedFailureThrows() async {
        let service = BrewService(query: { args in
            if args.contains("--cask") { throw BrewService.QueryError.commandFailed("test failure") }
            return self.empty
        })
        do {
            _ = try await service.outdatedAll()
            XCTFail("任一类别查询失败都应报错")
        } catch {}
    }

    func testPartialInstalledFailureDoesNotReplaceList() async {
        let service = BrewService(query: { args in
            if args.contains("--cask") { throw BrewService.QueryError.commandFailed("test failure") }
            return self.empty
        })
        let result = await service.installedAllWithStatus()
        XCTAssertFalse(result.success)
    }

    func testMalformedInstalledIsFailure() async {
        let service = BrewService(query: { _ in "not JSON" })
        let result = await service.installedAllWithStatus()
        XCTAssertFalse(result.success)
    }

    func testValidEmptyInstalledIsSuccess() async {
        let service = BrewService(query: { _ in self.empty })
        let result = await service.installedAllWithStatus()
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.packages.isEmpty)
    }

    func testOverviewMarksMalformedQueriesUnreliable() async {
        let service = BrewService(query: { _ in "not JSON" })
        let stats = await service.overviewStats()
        XCTAssertFalse(stats.outdatedReliable)
        XCTAssertFalse(stats.installedReliable)
    }
}
