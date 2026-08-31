import Foundation

/// 包的种类
enum PackageKind: String, Codable {
    case formula
    case cask
}

/// 一个已安装的包(包管理页数据)
/// id 用 kind+name 稳定组合键(非 UUID):每次刷新列表时 SwiftUI 能 diff 复用行视图,避免整表重建闪烁
struct InstalledPackage: Identifiable, Hashable {
    let name: String
    let version: String
    let kind: PackageKind
    var isPinned: Bool = false

    var id: String { kind.rawValue + "/" + name }
}

/// 一个 brew services 服务(服务管理页)
struct ServiceInfo: Identifiable, Hashable {
    let name: String
    let status: String
    let user: String
    let file: String

    var id: String { name }

    /// 是否运行中(状态可能是 started / stopped / error / none)
    var isRunning: Bool { status.lowercased().hasPrefix("start") }
}

/// 一条待更新项(对应 brew outdated 的解析结果)
/// id 用 kind+name 稳定组合键:检查更新后清单行可复用,不闪烁
struct OutdatedEntry: Identifiable, Hashable {
    let name: String
    let currentVersion: String
    let newestVersion: String
    let kind: PackageKind
    var isIgnored: Bool
    /// 是否自更新应用(cask 的 auto_updates 字段;formula/未知时 nil)
    var autoUpdates: Bool?

    var id: String { kind.rawValue + "/" + name }

    var displayVersion: String {
        "\(currentVersion) → \(newestVersion)"
    }
}

/// 升级任务的状态机(与 brew-ua 的失败隔离状态一一对应)
enum TaskStatus: Equatable {
    case queued            // 等待下载
    case downloading       // 阶段1:正在下载
    case downloaded        // 阶段1:下载成功(可进入阶段2)
    case installing        // 阶段2:正在安装
    case succeeded         // 安装成功
    case failed(String)    // 失败(携带原因)
    case timeout           // 单包超时(默认 600s)
    case canceled          // 用户取消

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .timeout, .canceled: return true
        default: return false
        }
    }
}

/// 单个包的升级任务可视化状态
/// id 用 kind+name 稳定组合键(同一运行内每包一行;retryFailed 重建后 id 不变,行视图可复用)
struct PackageTask: Identifiable {
    let name: String
    let kind: PackageKind
    var status: TaskStatus
    var bytesDownloaded: Int64 = 0
    var totalBytes: Int64 = 0
    var speedBytesPerSec: Double = 0
    var startedAt: Date?
    var finishedAt: Date?

    var id: String { kind.rawValue + "/" + name }

    var durationText: String {
        guard let s = startedAt else { return "—" }
        let end = finishedAt ?? Date()
        let secs = Int(end.timeIntervalSince(s))
        if secs < 60 { return "\(secs)s" }
        return String(format: "%dm %02ds", secs / 60, secs % 60)
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(bytesDownloaded) / Double(totalBytes), 1.0)
    }

    /// 是否有确定的进度(总字节已知)。brew formula 拿不到总大小,此时用不确定进度条。
    var hasDeterminateProgress: Bool { totalBytes > 0 }

    var speedText: String {
        speedBytesPerSec <= 0 ? "—" : sizeText(speedBytesPerSec) + "/s"
    }

    var downloadedText: String {
        sizeText(Double(bytesDownloaded)) + (totalBytes > 0 ? " / " + sizeText(Double(totalBytes)) : "")
    }

    /// 状态徽章文字(下载/安装阶段分离,失败区分来源)
    var statusDisplayText: String {
        switch status {
        case .queued: return "等待中"
        case .downloading: return "下载中"
        case .downloaded: return "已下载待安装"
        case .installing: return "安装中"
        case .succeeded: return "已完成安装"
        case .failed(let reason): return reason.hasPrefix("安装") ? "安装失败" : "下载失败"
        case .timeout: return "下载超时"
        case .canceled: return "已取消"
        }
    }

    /// 进度详情:下载阶段显示 "23.4MB / 275MB · 45%"
    var progressDetailText: String {
        if totalBytes > 0, bytesDownloaded > 0 {
            return "\(downloadedText) · \(Int(progress * 100))%"
        }
        return downloadedText
    }

    private func sizeText(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var v = bytes
        var idx = 0
        while v >= 1024 && idx < 3 {
            v /= 1024
            idx += 1
        }
        return idx == 0 ? "\(Int(v))\(units[idx])" : String(format: "%.1f%@", v, units[idx])
    }
}

/// 一次升级运行的统计摘要
struct RunSummary {
    var total: Int = 0
    var succeeded: Int = 0
    var failed: Int = 0
    var timeout: Int = 0
    var totalDuration: TimeInterval = 0
    var failedNames: [String] = []

    var successRateText: String {
        guard total > 0 else { return "—" }
        return "\(Int(Double(succeeded) / Double(total) * 100))%"
    }

    var durationText: String {
        let secs = Int(totalDuration)
        if secs < 60 { return "\(secs)s" }
        return String(format: "%dm %02ds", secs / 60, secs % 60)
    }
}

// MARK: - 更新历史(持久化,升级中心"更新记录"面板)

/// 单个包的历史记录条目
struct RecordEntry: Codable, Hashable {
    let name: String
    let kind: PackageKind
    let fromVersion: String
    let toVersion: String
    let success: Bool
    /// 失败/超时/取消等原因;成功为空
    let detail: String
}

/// 一次升级运行的历史记录
struct UpdateRecord: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let entries: [RecordEntry]

    var succeededCount: Int { entries.filter(\.success).count }
    var failedCount: Int { entries.count - succeededCount }

    var summaryText: String {
        if failedCount == 0 { return "成功 \(succeededCount) 个" }
        return "成功 \(succeededCount) · 失败 \(failedCount)"
    }
}