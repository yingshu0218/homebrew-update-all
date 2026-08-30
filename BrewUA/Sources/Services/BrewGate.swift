import Foundation

/// brew 全局异步互斥闸门。
///
/// Homebrew 有全局锁,GUI 内所有 brew 子进程必须串行,否则互相等待甚至报
/// "Another active Homebrew process"(且报错常被 `try?` 吞掉,表现为数据变 0)。
///
/// 替代旧 NSLock 自旋方案的理由:
/// - NSLock 跨 await 持有:await 恢复点可能换线程,在另一线程 unlock 属未定义行为
/// - 自旋轮询(50ms × 200)忙等浪费 CPU,且 10 秒拿不到锁就抛 busy 造成数据缺失
/// - actor 实现零自旋、无等待上限、跨 await 安全(所有权在等待者之间转移)
actor BrewGate {
    static let shared = BrewGate()

    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume() // 锁所有权直接转移给下一个等待者
        } else {
            locked = false
        }
    }
}

/// 在 brew 全局闸门内执行 body:acquire → body → release(含抛错路径)。
/// 所有 brew 子进程调用(数据查询/升级/安装/卸载/服务/清理/环境检测)统一走这里,
/// 彻底消除并发 brew 冲突。长时间命令(下载/安装)会持闸门直到结束,
/// 此期间的查询命令会排队等待——这是正确行为(等 Homebrew 自身锁释放)。
func withBrewGate<T>(_ body: () async throws -> T) async throws -> T {
    await BrewGate.shared.acquire()
    do {
        let value = try await body()
        await BrewGate.shared.release()
        return value
    } catch {
        await BrewGate.shared.release()
        throw error
    }
}
