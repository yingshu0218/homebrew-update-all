import Foundation
import Combine

/// 应用中持久的共享状态(各页面共享 env)。
/// 采用 ObservableObject + @Published(无宏,兼容任意构建环境)。
final class AppModel: ObservableObject {
    /// 已安装包统计(总览页展示),由 BrewService 刷新
    @Published var installedFormulaCount: Int = 0
    @Published var installedCaskCount: Int = 0
    /// 待更新数量,由 BrewService 刷新
    @Published var outdatedCount: Int = 0
    /// 环境信息
    @Published var brewPrefix: String = ""
    @Published var brewVersion: String = ""
    /// 当前选择的分区(供跨页跳转,如总览→升级中心)
    @Published var selectedSection: AppSection? = .overview

    init() {}
}