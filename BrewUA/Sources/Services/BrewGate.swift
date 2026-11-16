import Foundation

/// brew 全局异步互斥闸门。等待者取消时会从队列移除，不会留下永久挂起的 continuation。
actor BrewGate {
    static let shared = BrewGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var locked = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !locked {
            locked = true
            return
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if !locked {
                    locked = true
                    continuation.resume(returning: true)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }

        guard acquired else { throw CancellationError() }
        if Task.isCancelled {
            // 锁可能已在取消回调运行前转交给本 waiter，必须继续转交以免永久占锁。
            release()
            throw CancellationError()
        }
    }

    func release() {
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            // 若取消 actor hop 尚未执行，acquire 恢复后会检查 Task.isCancelled 并立即转交。
            next.continuation.resume(returning: true)
            return
        }
        locked = false
    }

    func pendingWaiterCount() -> Int { waiters.count }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

func withBrewGate<T>(_ body: () async throws -> T) async throws -> T {
    try await withBrewGate(using: .shared, body)
}

func withBrewGate<T>(using gate: BrewGate, _ body: () async throws -> T) async throws -> T {
    try await gate.acquire()
    do {
        // Task 可能在 acquire 排队期间取消，而锁恰好已被转交给它。
        try Task.checkCancellation()
        let value = try await body()
        await gate.release()
        return value
    } catch {
        await gate.release()
        throw error
    }
}
