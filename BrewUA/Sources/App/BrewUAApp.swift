import SwiftUI

@main
struct BrewUAApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var engine = UpdateEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .environmentObject(engine)
                .frame(minWidth: 960, minHeight: 640)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    // 升级中退出会中断 brew 进程组;确保子进程被终止
                    if engine.isRunning {
                        engine.cancel()
                    }
                    // 断开所有子进程(如果仍在跑 brew)
                    terminateRunningBrew()
                }
        }
        .windowResizability(.contentMinSize)
        // 注意:不要在这里加 .commands 的 CommandGroup —— 之前把 engine.isRunning 等状态
        // 绑定进主菜单导致 SwiftUI 更新 AppKit 主菜单时触发 NSMenu 断言崩溃(SIGABRT)。
        // 保留系统默认菜单(App 菜单/About/退出)最稳定。
    }

    private func terminateRunningBrew() {
        // 尽力而为:若仍有 brew 进程,发 SIGTERM(StreamedProcess 超时熔断已覆盖常规场景)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-TERM", "-f", "brew (fetch|install|upgrade|reinstall)"]
        try? proc.run()
    }
}