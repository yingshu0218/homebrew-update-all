import SwiftUI

/// 升级中心:应用商店式体验——先"检查更新"得到待更新清单(可勾选),再"更新所选/全部更新"执行两阶段升级。
/// 运行中展示任务进度、速度、失败隔离与摘要;「更新记录」面板回看持久化历史。
struct UpgradeCenterView: View {
    @EnvironmentObject private var engine: UpdateEngine

    /// 勾选状态:包名 → 是否选中
    @State private var selectedNames: Set<String> = []
    @State private var greedy = false
    /// 更新记录面板
    @State private var showHistory = false

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
                    "尚无更新任务",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("先点击「检查更新」拉取最新待更新清单,再选择要更新的包。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showHistory) {
            HistorySheet()
        }
        .onChange(of: engine.pendingUpdates.count) { _, _ in
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
                historyButton
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
                historyButton
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
                historyButton
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

    /// 更新记录入口:回看每次升级的持久化历史
    private var historyButton: some View {
        Button {
            showHistory = true
        } label: {
            Label("更新记录", systemImage: "clock.arrow.circlepath")
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

    /// 底部操作条:"更新所选 (N)" + "全部更新"(绿色边框显眼样式)
    private var actionBar: some View {
        HStack(spacing: 12) {
            let selected = engine.pendingUpdates.filter { selectedNames.contains($0.name) }
            Button {
                engine.upgrade(packages: selected, options: UpdateOptions(greedy: greedy))
            } label: {
                Label("更新所选 (\(selected.count))", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(MainActionButtonStyle())
            .disabled(selected.isEmpty)
            .help(selected.isEmpty ? "请先勾选要更新的包" : "两阶段升级所选的包")

            Button {
                engine.start(options: UpdateOptions(greedy: greedy))
            } label: {
                Label("全部更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(MainActionButtonStyle())

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
                .onChange(of: engine.eventLog.count) { _, _ in
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
                    KindBadge(kind: entry.kind)
                    if let auto = entry.autoUpdates {
                        Text(auto ? "自更新" : "手动更新")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(auto ? Color.orange.opacity(0.18) : Color.gray.opacity(0.15))
                            .foregroundStyle(auto ? Color.orange : Color.secondary)
                            .clipShape(Capsule())
                            .help(auto ? "该 cask 自带自动更新,手动升级前可先确认是否必要" : "该 cask 不自带自动更新,需手动升级")
                    }
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

/// 单个升级任务行:状态徽章 + 名称 + 进度条 + 大小/速度/耗时
struct TaskRow: View {
    let task: PackageTask

    var body: some View {
        HStack(spacing: 10) {
            statusBadge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    KindBadge(kind: task.kind)
                }
                progressOrStatus
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(task.durationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if task.status == .downloading {
                    // 下载中:显示大小 + 速度
                    if task.totalBytes > 0 {
                        Text(task.progressDetailText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(task.speedText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text(task.downloadedText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(task.speedText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else if task.status == .downloaded || task.status == .succeeded {
                    if task.totalBytes > 0 {
                        Text("\(task.downloadedText) · \(Int(task.progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .cardBackground(cornerRadius: 8)
    }

    /// 状态徽章:按阶段着色、淡入,比小圆点更直观(下载中/已下载待安装/安装中/完成/失败)
    private var statusBadge: some View {
        Text(task.statusDisplayText)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(Capsule())
            .frame(minWidth: 62)
            .fixedSize()
    }

    private var badgeColor: Color {
        switch task.status {
        case .queued: return .gray
        case .downloading: return .blue
        case .downloaded: return .teal
        case .installing: return .indigo
        case .succeeded: return .green
        case .failed, .timeout: return .red
        case .canceled: return .orange
        }
    }

    @ViewBuilder
    private var progressOrStatus: some View {
        switch task.status {
        case .downloading:
            if task.hasDeterminateProgress {
                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .animation(.linear(duration: 0.3), value: task.progress)
                    .frame(maxWidth: .infinity)
            } else {
                // 无法确定总量(总大小探测失败):不定进度条
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .frame(maxWidth: .infinity)
            }
        case .installing:
            // 安装无法细粒度看进度,用不定进度条表示进行中
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.indigo)
                .frame(maxWidth: .infinity)
        case .queued:
            Text("等待下载…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloaded:
            Text("等待安装(阶段 2 开始后自动执行)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .succeeded:
            Text("安装完成")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.red.opacity(0.9))
                .lineLimit(1)
        case .timeout:
            Text("下载超时,已跳过")
                .font(.caption)
                .foregroundStyle(.red.opacity(0.9))
        case .canceled:
            Text("已取消")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

/// 主操作按钮样式:绿色实线边框 + 绿色文字,悬停浅绿底,视觉上突出"执行更新"。
/// 区别于系统默认边框色,让用户一眼找到关键动作。
private struct MainActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(Color.green.opacity(isEnabled ? 1 : 0.4))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed
                        ? Color.green.opacity(0.22)
                        : Color.green.opacity(isEnabled ? 0.08 : 0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.green.opacity(isEnabled ? (configuration.isPressed ? 0.6 : 0.9) : 0.3), lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
/// 更新记录面板:持久化的升级历史(新→旧),每条可展开查看包明细
struct HistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records: [UpdateRecord] = []
    @State private var confirmClear = false

    private let history = HistoryService.shared
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView(
                        "暂无更新记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("每次升级完成后会自动记录在这里")
                    )
                } else {
                    List {
                        ForEach(records) { record in
                            recordRow(record)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("更新记录")
            .navigationSubtitle("\(records.count) 条记录")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("清空") { confirmClear = true }
                        .disabled(records.isEmpty)
                        .confirmationDialog(
                            "确定清空全部更新记录?",
                            isPresented: $confirmClear,
                            titleVisibility: .visible
                        ) {
                            Button("清空", role: .destructive) {
                                history.clear()
                                records = []
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("历史记录将被永久删除,此操作不可撤销。")
                        }
                }
            }
        }
        .frame(width: 520, height: 520)
        .onAppear { records = history.load() }
    }

    private func recordRow(_ record: UpdateRecord) -> some View {
        DisclosureGroup {
            ForEach(record.entries, id: \.self) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(entry.success ? Color.green : Color.red)
                        .font(.caption)
                    Text(entry.name)
                        .font(.callout)
                        .lineLimit(1)
                    KindBadge(kind: entry.kind)
                    Text("\(entry.fromVersion) → \(entry.toVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 1)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: record.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(record.failedCount == 0 ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dateFormatter.string(from: record.date))
                        .font(.callout.weight(.medium))
                    Text("\(record.summaryText) · 共 \(record.entries.count) 个包")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}
