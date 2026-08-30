import SwiftUI

/// 总览页:环境健康卡片(brew 版本/prefix/镜像源/网络)+ 待更新入口。
struct OverviewView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var engine: UpdateEngine
    @State private var envInfo: EnvironmentInfo?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            // 三态状态区统一固定高度槽位:加载前/加载中/加载后 quickActions 位置不变
            Group {
                if let envInfo {
                    environmentCards(envInfo)
                } else if isLoading {
                    ProgressView("正在检测环境…")
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Button("开始环境检测") {
                        refresh()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(minHeight: 216, maxHeight: .infinity, alignment: .top)
            quickActions
        }
        .padding(20)
.task { await refreshAsync() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("总览")
                    .font(.title2.bold())
                Text("基于 brew-ua 的两阶段升级策略 · 可视化 Homebrew 环境")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
    }

    private func environmentCards(_ info: EnvironmentInfo) -> some View {
        // 固定 2 列网格保证 4 张卡片始终两两对齐(自适应列数会导致窗口宽度变化时卡片数量/高度参差)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            metricCard("Homebrew", info.brewVersion.isEmpty ? "未检测到" : info.brewVersion, icon: "terminal", tint: .blue) {
                Text(info.brewPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            metricCard("Prefix", info.prefix.isEmpty ? "—" : info.prefix, icon: "folder", tint: .purple) {
                Text(info.prefix.isEmpty ? "未检测到 Homebrew Prefix" : "Homebrew 安装目录")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            metricCard("镜像源", info.mirrorSource.displayName, icon: "network", tint: info.mirrorSource.tint) {
                Text(info.isNetworkOk ? "网络可达 · \(info.networkCountry)" : "网络不可达")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            metricCard("待更新", appModel.outdatedReliable ? "\(appModel.outdatedCount)" : "—", icon: "arrow.triangle.2.circlepath", tint: appModel.outdatedCount > 0 ? .orange : .teal) {
                Text(appModel.outdatedReliable
                    ? "formulae \(appModel.outdatedFormulaCount) · casks \(appModel.outdatedCaskCount) · 已安装 \(appModel.installedFormulaCount + appModel.installedCaskCount) 个包"
                    : "检测失败(可能是升级任务占用中),点击重试")
                    .font(.caption2)
                    .foregroundStyle(appModel.outdatedReliable ? Color.secondary : Color.orange)
            } onTap: {
                appModel.selectedSection = .upgrade
            }
        }
    }

    private func metricCard<Content: View>(_ title: LocalizedStringKey, _ value: String, icon: String, tint: Color, @ViewBuilder subtitle: () -> Content, onTap: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // 固定高度副标题槽位:保证四张卡片视觉等高
            subtitle()
                .frame(height: 16, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 92, alignment: .topLeading)
        .padding(14)
        .cardBackground(cornerRadius: 12)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onTap?() }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            actionCard("检查更新", systemImage: "magnifyingglass", tint: .blue) {
                // 仅检测:拉取待更新清单并跳到升级中心,由用户决定更哪些
                appModel.selectedSection = .upgrade
                engine.checkOnly()
            }
            actionCard("全部升级", systemImage: "arrow.triangle.2.circlepath", tint: .teal) {
                // 一键升级全部待更新(等价 CLI 的 auto 模式)
                appModel.selectedSection = .upgrade
                engine.start()
            }
            actionCard("清理缓存", systemImage: "trash", tint: .red) {
                Task { await engine.cleanup() }
            }
        }
    }

    private func actionCard(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .cardBackground(cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }

    private func refresh() {
        Task { await refreshAsync() }
    }

    /// 结构化并发刷新:.task 调用时随视图生命周期自动取消,不再出现
    /// "视图已销毁任务还在跑并写状态" 的非结构化 Task 泄漏
    private func refreshAsync() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let brew = BrewService.shared
        async let info = EnvDetector.detect()
        async let stats = brew.overviewStats()
        let (env, stat) = await (info, stats)
        guard !Task.isCancelled else { return }
        envInfo = env
        appModel.installedFormulaCount = stat.installedFormulae
        appModel.installedCaskCount = stat.installedCasks
        appModel.outdatedCount = stat.outdatedFormulae + stat.outdatedCasks
        appModel.outdatedFormulaCount = stat.outdatedFormulae
        appModel.outdatedCaskCount = stat.outdatedCasks
        appModel.outdatedReliable = stat.outdatedReliable
    }
}