import SwiftUI

/// 服务管理页:brew services 的启停、自启查看。只读状态 + 启停操作。
struct ServicesView: View {
    private let brew = BrewService.shared
    @State private var services: [ServiceInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var busyName: String?
    @State private var lastAction: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("brew services 列表")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let lastAction {
                    Text(lastAction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await load() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding(12)

            Divider()

            content
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("正在读取服务状态…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView(
                "加载失败",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if services.isEmpty {
            ContentUnavailableView(
                "没有 brew services",
                systemImage: "server.rack",
                description: Text("当前没有通过 brew services 管理的服务。部分包(如数据库、消息队列)安装后可注册服务。")
            )
        } else {
            List(services) { svc in
                ServiceRow(service: svc, isBusy: busyName == svc.name) { action in
                    await runAction(action, on: svc)
                }
            }
            .listStyle(.inset)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let result = await brew.servicesList()
        if !result.success {
            errorMessage = "未能读取服务列表。请确认 brew services 可用。"
        } else {
            services = result.services
            // 成功但无服务:走"没有 brew services"空状态(不是错误)
        }
    }

    private func runAction(_ action: ServiceAction, on svc: ServiceInfo) async {
        busyName = svc.name
        defer { busyName = nil }
        let args: [String]
        switch action {
        case .start: args = ["services", "start", svc.name]
        case .stop: args = ["services", "stop", svc.name]
        case .restart: args = ["services", "restart", svc.name]
        }
        do {
            _ = try await withBrewGate {
                try await StreamedProcess(brewArguments: args).runSync()
            }
            lastAction = "已\(action.title) \(svc.name)"
        } catch {
            lastAction = "操作失败:\(error.localizedDescription)"
        }
        await load()
    }
}

enum ServiceAction {
    case start, stop, restart
    var title: String {
        switch self {
        case .start: return "启动"
        case .stop: return "停止"
        case .restart: return "重启"
        }
    }
}

private struct ServiceRow: View {
    let service: ServiceInfo
    let isBusy: Bool
    let onAction: (ServiceAction) async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(service.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.body.weight(.medium))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    if service.isRunning {
                        Button("停止") { Task { await onAction(.stop) } }
                        Button("重启") { Task { await onAction(.restart) } }
                    } else {
                        Button("启动") { Task { await onAction(.start) } }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        var parts: [String] = [service.status]
        if !service.user.isEmpty { parts.append("用户: \(service.user)") }
        if !service.file.isEmpty { parts.append(service.file) }
        return parts.joined(separator: " · ")
    }
}