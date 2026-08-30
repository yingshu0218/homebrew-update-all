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
                    // 只终止本 App 自己启动的 brew 进程(登记表),不用 pkill 全局匹配——
                    // 旧实现 pkill -f 会误杀用户终端里自跑的 brew 命令
                    StreamedProcess.terminateAllActive()
                }
        }
        .windowResizability(.contentMinSize)
        // 注意:不要在这里加 .commands 的 CommandGroup —— 之前把 engine.isRunning 等状态
        // 绑定进主菜单导致 SwiftUI 更新 AppKit 主菜单时触发 NSMenu 断言崩溃(SIGABRT)。
        // 保留系统默认菜单(App 菜单/About/退出)最稳定。
    }
}