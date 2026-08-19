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
            if let envInfo {
                environmentCards(envInfo)
            } else if isLoading {
                ProgressView("正在检测环境…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Button("开始环境检测") {
                    refresh()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            quickActions
            Spacer(minLength: 0)
        }
        .padding(20)
        .task { refresh() }
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
            metricCard("镜像源", info.mirrorSource.displayName, icon: "network", tint: mirrorTint(info.mirrorSource)) {
                Text(info.isNetworkOk ? "网络可达 · \(info.networkCountry)" : "网络不可达")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            metricCard("待更新", "\(appModel.outdatedCount)", icon: "arrow.triangle.2.circlepath", tint: appModel.outdatedCount > 0 ? .orange : .teal) {
                Text("已安装 \(appModel.installedFormulaCount + appModel.installedCaskCount) 个包")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onTap?() }
    }

    private func mirrorTint(_ source: MirrorSource) -> Color {
        switch source {
        case .ustc, .tsinghua, .aliyun: return .orange
        case .official: return .teal
        case .unknown: return .gray
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            actionCard("检查更新", systemImage: "arrow.triangle.2.circlepath", tint: .blue) {
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
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let brew = BrewService.shared
        Task {
            async let info = EnvDetector.detect()
            async let stats = brew.overviewStats()
            let (env, stat) = await (info, stats)
            await MainActor.run {
                self.envInfo = env
                self.appModel.brewPrefix = env.prefix
                self.appModel.brewVersion = env.brewVersion
                self.appModel.installedFormulaCount = stat.installedFormulae
                self.appModel.installedCaskCount = stat.installedCasks
                self.appModel.outdatedCount = stat.outdated
                self.isLoading = false
            }
        }
    }
}