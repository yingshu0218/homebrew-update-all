import Foundation

/// 全局常量:集中管理散落在各处的魔法数字/路径,便于调整与审阅。
enum Constants {
    /// 单包下载超时(秒),与 brew-ua CLI 默认 600 一致
    static let fetchTimeout: TimeInterval = 600

    /// 下载进度轮询间隔(秒):缓存文件大小差分算速度;过小会抖动,过大刷新迟钝
    static let downloadPollInterval: TimeInterval = 0.6

    /// 取消监听轮询间隔(秒):cancelFlag 置位到终止 brew 进程的最大延迟
    static let cancelPollInterval: TimeInterval = 0.15

    /// 轻量 brew 命令(info/list/outdated/config)同步超时(秒)
    static let brewSyncTimeout: TimeInterval = 30

    /// HEAD 探测包大小的网络超时(秒)
    static let headProbeTimeout: TimeInterval = 15

    /// HEAD 请求 UA:部分 CDN 无 UA 时返回 403/404
    static let headProbeUserAgent = "curl/8.7.1"

    /// brew 可执行文件候选路径(按优先级)
    static let brewPathCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
}
