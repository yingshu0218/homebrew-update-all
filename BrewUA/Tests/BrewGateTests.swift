import XCTest

final class BrewGateTests: XCTestCase {
    func testCanceledWaiterIsRemovedAndNeverEntersBody() async throws {
        let gate = BrewGate()
        try await gate.acquire()
        let bodyStarted = expectation(description: "canceled waiter body")
        bodyStarted.isInverted = true
        let waiter = Task {
            try await withBrewGate(using: gate) {
                bodyStarted.fulfill()
            }
        }

        for _ in 0..<100 {
            if await gate.pendingWaiterCount() == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let waiting = await gate.pendingWaiterCount()
        XCTAssertEqual(waiting, 1)
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("被取消的排队任务不应进入临界区")
        } catch is CancellationError {
        }
        let remainingWaiters = await gate.pendingWaiterCount()
        XCTAssertEqual(remainingWaiters, 0)
        await gate.release()

        try await withBrewGate(using: gate) {}
        await fulfillment(of: [bodyStarted], timeout: 0.1)
    }
}
