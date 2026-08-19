import Foundation

/// 包的种类
enum PackageKind: String, Codable {
    case formula
    case cask
}

/// 一个已安装的包(包管理页数据)
struct InstalledPackage: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let version: String
    let kind: PackageKind
    var isPinned: Bool = false
}

/// 一个 brew services 服务(服务管理页)
struct ServiceInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let status: String
    let user: String
    let file: String

    /// 是否运行中(状态可能是 started / stopped / error / none)
    var isRunning: Bool { status.lowercased().hasPrefix("start") }
}

/// 一条待更新项(对应 brew outdated 的解析结果)
struct OutdatedEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let currentVersion: String
    let newestVersion: String
    let kind: PackageKind
    var isIgnored: Bool

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
struct PackageTask: Identifiable {
    let id = UUID()
    let name: String
    let kind: PackageKind
    var status: TaskStatus
    var bytesDownloaded: Int64 = 0
    var totalBytes: Int64 = 0
    var speedBytesPerSec: Double = 0
    var startedAt: Date?
    var finishedAt: Date?

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
    var skipped: Int = 0
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