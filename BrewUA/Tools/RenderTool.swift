import SwiftUI
import AppKit

// 离线渲染器:在无屏幕权限的环境里把关键视图渲染成 PNG,供人工检查布局
// 用法: swift RenderTool.swift /tmp/output_dir

@main
struct RenderTool {
    @MainActor
    static func main() async {
        // 初始化 AppKit + 创建可见窗口(不 orderFront,仅用于离屏渲染管线)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "offline"

        var outDir = "/tmp/brewua-render"
        if CommandLine.arguments.count > 1 { outDir = CommandLine.arguments[1] }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // 组装一个预览用引擎
        let engine = UpdateEngine()
        let task1 = PackageTask(name: "wget", kind: .formula, status: .downloading,
                                bytesDownloaded: 42_000_000, totalBytes: 0, speedBytesPerSec: 2_500_000,
                                startedAt: Date())
        let task2 = PackageTask(name: "bambu-studio", kind: .cask, status: .downloaded,
                                bytesDownloaded: 0, totalBytes: 0, speedBytesPerSec: 0,
                                startedAt: Date().addingTimeInterval(-30), finishedAt: Date())
        let task3 = PackageTask(name: "mysql", kind: .formula, status: .failed("校验失败"),
                                bytesDownloaded: 0, totalBytes: 0, speedBytesPerSec: 0,
                                startedAt: Date().addingTimeInterval(-120), finishedAt: Date())
        let task4 = PackageTask(name: "redis", kind: .formula, status: .queued)
        engine.injectPreview(
            tasks: [task1, task2, task3, task4],
            summary: RunSummary(total: 4, succeeded: 1, failed: 1, timeout: 1, skipped: 0,
                                totalDuration: 125, failedNames: ["mysql", "nginx"]),
            phase: .finished,
            logs: ["① 更新 Homebrew 源…", "  ==> Updating Homebrew", "② 检查待更新包…",
                   "  待更新 4 个包(formula 3, cask 1)", "③ 阶段1:逐个下载…",
                   "  ✓ wget 下载完成", "  ✗ mysql 下载超时(600s),已隔离", "④ 阶段2:逐个安装(1 个)…",
                   "  ✓ bambu-studio 升级完成", "⑤ 清理缓存…", "  cleanup 完成", "== 升级结束 =="],
            isRunning: false
        )

        let appModel = AppModel()
        appModel.installedFormulaCount = 86
        appModel.installedCaskCount = 24
        appModel.outdatedCount = 3

        let views: [(String, AnyView)] = [
            ("overview", AnyView(OverviewView().environmentObject(appModel).environmentObject(engine))),
            ("upgrade_center", AnyView(UpgradeCenterView().environmentObject(engine))),
            ("packages_idle", AnyView(PackagesView().environmentObject(appModel).environmentObject(engine))),
            ("services_idle", AnyView(ServicesView().environmentObject(appModel).environmentObject(engine))),
            ("settings_idle", AnyView(SettingsView().environmentObject(appModel).environmentObject(engine))),
        ]

        for (name, view) in views {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = window.contentView!.bounds
            hosting.autoresizingMask = [.width, .height]
            window.contentView = hosting
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            // 跑 runloop 让 SwiftUI 完成布局与字体加载
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()

            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                print("FAILED rep \(name)")
                continue
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: "\(outDir)/\(name).png")
                try? data.write(to: url)
                print("wrote \(url.path)")
            }
        }
        print("DONE")
        exit(0)
    }
}