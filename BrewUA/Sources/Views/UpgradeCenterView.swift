import SwiftUI

/// 升级中心:应用商店式体验——先"检查更新"得到待更新清单(可勾选),再"更新所选/全部更新"执行两阶段升级。
/// 运行中展示任务进度、速度、失败隔离与摘要。
struct UpgradeCenterView: View {
    @EnvironmentObject private var engine: UpdateEngine

    /// 勾选状态:包名 → 是否选中
    @State private var selectedNames: Set<String> = []
    @State private var greedy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if engine.isRunning || engine.tasks.isEmpty == false {
                taskListView
                if let s = engine.summary {
                    summaryView(s)
                }
                logSection
            } else if !engine.pendingUpdates.isEmpty {
                // 应用商店式阶段:待更新清单(可勾选)
                pendingListView
                actionBar
            } else {
                ContentUnavailableView(
                    "尚无更新记录",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("先点击「检查更新」拉取最新待更新清单,再选择要更新的包。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: engine.pendingUpdates.count) { _ in
            // 清单刷新时重置勾选(避免残留旧勾选)
            selectedNames = Set(engine.pendingUpdates.map(\.name))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("升级中心")
                    .font(.title2.bold())
                Text("阶段: \(engine.phaseTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if engine.isRunning {
                ProgressView()
                    .controlSize(.small)
                Button("取消") {
                    engine.cancel()
                }
            } else if engine.pendingUpdates.isEmpty && engine.tasks.isEmpty {
                // 尚未检测 / 已清空
                Toggle("包含自更新应用", isOn: $greedy)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button {
                    engine.checkOnly(options: UpdateOptions(greedy: greedy))
                } label: {
                    Label("检查更新", systemImage: "magnifyingglass")
                }
            } else if !engine.pendingUpdates.isEmpty {
                // 有清单但未运行 → 可再次检查、清空
                Toggle("包含自更新应用", isOn: $greedy)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button {
                    engine.checkOnly(options: UpdateOptions(greedy: greedy))
                } label: {
                    Label("检查更新", systemImage: "magnifyingglass")
                }
                Button(role: .destructive) {
                    engine.reset()
                } label: {
                    Label("清空", systemImage: "trash")
                }
            } else {
                // 运行结束:重试失败 + 再次检查 + 清空
                if engine.failedCount > 0 {
                    Button {
                        engine.retryFailed()
                    } label: {
                        Label("重试失败 (\(engine.failedCount))", systemImage: "arrow.counterclockwise")
                    }
                }
                Button {
                    engine.checkOnly(options: UpdateOptions(greedy: greedy))
                } label: {
                    Label("再次检查", systemImage: "magnifyingglass")
                }
                Button(role: .destructive) {
                    engine.reset()
                } label: {
                    Label("清空", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - 待更新清单(应用商店式)

    private var pendingListView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: allSelectedBinding)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("全选/取消全选")
                Text("待更新包 (\(engine.pendingUpdates.count))")
                    .font(.headline)
                Spacer()
                Text("已选择 \(selectedNames.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(engine.pendingUpdates) { entry in
                        PendingRow(
                            entry: entry,
                            isSelected: selectedNames.contains(entry.name),
                            onToggle: { toggleSelection(entry.name) }
                        )
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: .infinity)
            .background(.quaternary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxHeight: .infinity)
    }

    private var allSelectedBinding: Binding<Bool> {
        Binding(
            get: {
                !engine.pendingUpdates.isEmpty && selectedNames.count == engine.pendingUpdates.count
            },
            set: { on in
                if on {
                    selectedNames = Set(engine.pendingUpdates.map(\.name))
                } else {
                    selectedNames = []
                }
            }
        )
    }

    private func toggleSelection(_ name: String) {
        if selectedNames.contains(name) {
            selectedNames.remove(name)
        } else {
            selectedNames.insert(name)
        }
    }

    /// 底部操作条:"更新所选 (N)" + "全部更新"
    private var actionBar: some View {
        HStack(spacing: 12) {
            let selected = engine.pendingUpdates.filter { selectedNames.contains($0.name) }
            Button {
                engine.upgrade(packages: selected, options: UpdateOptions(greedy: greedy))
            } label: {
                Label("更新所选 (\(selected.count))", systemImage: "arrow.down.circle")
            }
            .disabled(selected.isEmpty)
            .help(selected.isEmpty ? "请先勾选要更新的包" : "两阶段升级所选的包")

            Button {
                engine.start(options: UpdateOptions(greedy: greedy))
            } label: {
                Label("全部更新", systemImage: "arrow.triangle.2.circlepath")
            }

            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - 任务列表/摘要/日志(运行中+结束后,复用原逻辑)

    private var taskListView: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(engine.tasks) { task in
                    TaskRow(task: task)
                }
            }
            .padding(2)
        }
        .frame(maxHeight: .infinity)
        .frame(minHeight: 0)
    }

    private func summaryView(_ s: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                summaryMetric("成功", "\(s.succeeded)", color: .teal)
                summaryMetric("失败", "\(s.failed)", color: .red)
                summaryMetric("超时", "\(s.timeout)", color: .orange)
                summaryMetric("共", "\(s.total)", color: .primary)
                Text("成功率 \(s.successRateText) · 用时 \(s.durationText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if !s.failedNames.isEmpty {
                Text("失败: \(s.failedNames.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 8)
    }

    /// 事件日志面板(追加式,自动滚底)
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("运行日志")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(engine.eventLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("log-bottom")
                    }
                    .padding(8)
                }
                .frame(maxHeight: 140)
                .background(.quaternary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: engine.eventLog.count) { _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func summaryMetric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.medium))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 待更新清单中的一行包
private struct PendingRow: View {
    let entry: OutdatedEntry
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            Image(systemName: entry.kind == .formula ? "shippingbox" : "app.badge")
                .foregroundStyle(entry.kind == .formula ? .blue : .purple)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.kind == .formula ? "formula" : "cask")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(entry.kind == .formula ? Color.blue.opacity(0.15) : Color.purple.opacity(0.15))
                        .foregroundStyle(entry.kind == .formula ? Color.blue : Color.purple)
                        .clipShape(Capsule())
                }
                HStack(spacing: 6) {
                    Text(entry.displayVersion)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 单个升级任务行:状态圆点 + 名称 + 进度条 + 速度/耗时
struct TaskRow: View {
    let task: PackageTask

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.name)
                        .fontWeight(.medium)
                    Text(task.kind == .formula ? "formula" : "cask")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
                if task.status == .downloading || task.status == .installing {
                    if task.status == .installing || !task.hasDeterminateProgress {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(.teal)
                            .frame(maxWidth: .infinity)
                    } else {
                        ProgressView(value: task.progress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                            .animation(.linear(duration: 0.6), value: task.progress)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(task.durationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if task.status == .downloading {
                    Text(task.speedText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 9, height: 9)
    }

    private var statusColor: Color {
        switch task.status {
        case .queued: return .gray
        case .downloading, .installing: return .blue
        case .downloaded: return .teal
        case .succeeded: return .green
        case .failed, .timeout: return .red
        case .canceled: return .orange
        }
    }

    private var statusText: String {
        switch task.status {
        case .queued: return "等待中"
        case .downloading: return "下载中 \(task.downloadedText)"
        case .downloaded: return "下载完成"
        case .installing: return "安装中"
        case .succeeded: return "成功"
        case .failed(let reason): return "失败: \(reason)"
        case .timeout: return "超时"
        case .canceled: return "已取消"
        }
    }
}