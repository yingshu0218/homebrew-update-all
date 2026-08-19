import SwiftUI

/// 升级中心:展示两阶段升级的实时进度、速度、失败隔离与摘要。
struct UpgradeCenterView: View {
    @EnvironmentObject private var engine: UpdateEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if engine.isRunning || !engine.tasks.isEmpty {
                taskListView
                if let s = engine.summary {
                    summaryView(s)
                }
                logSection
            } else {
                ContentUnavailableView(
                    "尚无升级记录",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("点击「检查更新」开始两阶段升级(下载→安装,失败自动隔离)。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

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
                .disabled(!engine.isRunning)
            } else if engine.tasks.isEmpty {
                Button {
                    engine.start()
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
            } else {
                // 运行结束:重试失败 + 再次检查
                if engine.failedCount > 0 {
                    Button {
                        engine.retryFailed()
                    } label: {
                        Label("重试失败 (\(engine.failedCount))", systemImage: "arrow.counterclockwise")
                    }
                }
                Button {
                    engine.start()
                } label: {
                    Label("再次检查", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) {
                    engine.reset()
                } label: {
                    Label("清空", systemImage: "trash")
                }
            }
        }
    }

    private var taskListView: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(engine.tasks) { task in
                    TaskRow(task: task)
                }
            }
            .padding(2)
        }
        // 任务列表随内容伸缩,但让出 summary/日志的空间
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
                        // 底部锚点:有新日志时自动滚动到这里
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