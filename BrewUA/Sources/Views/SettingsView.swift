import SwiftUI
import UniformTypeIdentifiers

/// 设置迁移页:镜像源(只检测不切换)、屏蔽列表、Brewfile 备份。
struct SettingsView: View {
    private let config = ConfigService.shared
    private let brew = BrewService.shared

    @State private var envInfo: EnvironmentInfo?
    @State private var isDetected = false
    @State private var ignored: [String] = []
    @State private var newIgnoreName = ""
    @State private var isExporting = false
    @State private var brewfileText = ""
    @State private var exportMessage: String?

    @State private var cliStatus: CLIInstallStatus?
    @State private var cliMessage: String?
    @State private var isCLIBusy = false
    @State private var showUninstallConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                mirrorSection
                Divider()
                ignoredSection
                Divider()
                brewfileSection
                Divider()
                cliSection
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .task {
            // 恢复屏蔽列表 + 惰性环境检测
            ignored = config.loadIgnored().sorted()
            if !isDetected {
                envInfo = await EnvDetector.detect()
                isDetected = true
            }
            await refreshCLIStatus()
        }
    }

    // MARK: - 镜像源

    private var mirrorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("镜像源检测", systemImage: "network", tint: .orange)
            Text("本项目只检测当前镜像源,不切换(避免影响 brew-ua CLI 行为)。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let info = envInfo {
                HStack(spacing: 16) {
                    Label(info.mirrorSource.displayName, systemImage: "checkmark.seal")
                        .font(.body.weight(.medium))
                        .foregroundStyle(info.mirrorSource.tint)
                    Text(info.isNetworkOk ? "网络可达(\(info.networkCountry))" : "网络不可达")
                        .font(.caption)
                        .foregroundStyle(info.isNetworkOk ? Color.green : Color.red)
                    Spacer()
                    if !info.tapRemotes.isEmpty {
                        Text("\(info.tapRemotes.count) 个 tap")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .cardBackground(cornerRadius: 12)

                DisclosureGroup("查看 tap 远程地址") {
                    ForEach(Array(info.tapRemotes.keys.sorted()), id: \.self) { tap in
                        HStack(alignment: .top) {
                            Text(tap)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 200, alignment: .leading)
                            Text(info.tapRemotes[tap] ?? "")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.vertical, 3)
                    }
                }
                .font(.caption)
            } else {
                ProgressView("检测中…")
                    .font(.caption)
            }
        }
    }


    // MARK: - 屏蔽列表

    private var ignoredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("升级屏蔽列表", systemImage: "eye.slash", tint: .red)
            Text("屏蔽的包将不会出现在升级中心,也不参与 brew-ua 升级。存储于 ~/.config/brew-ua/ignored_casks(与 brew-ua CLI 共用)。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("输入包名(如 some-app)", text: $newIgnoreName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Button {
                    addIgnored()
                } label: {
                    Label("屏蔽", systemImage: "plus")
                }
                .disabled(newIgnoreName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if ignored.isEmpty {
                Text("暂无屏蔽的包")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                    ForEach(ignored, id: \.self) { name in
                        HStack(spacing: 6) {
                            Text(name)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            Spacer()
                            Button {
                                removeIgnored(name)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("解除屏蔽 \(name)")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .cardBackground(cornerRadius: 8)
                    }
                }
            }
        }
    }

    private func addIgnored() {
        let name = newIgnoreName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        try? config.addIgnored(name)
        newIgnoreName = ""
        ignored = config.loadIgnored().sorted()
    }

    private func removeIgnored(_ name: String) {
        try? config.removeIgnored(name)
        ignored = config.loadIgnored().sorted()
    }

    // MARK: - Brewfile

    private var brewfileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Brewfile 备份", systemImage: "square.and.arrow.up", tint: .blue)
            Text("导出当前全部安装(formula/cask/tap)为 Brewfile,迁移到其他机器用 `brew bundle install` 恢复。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    exportBrewfile()
                } label: {
                    Label("导出 Brewfile…", systemImage: "square.and.arrow.up")
                }
                .fileExporter(
                    isPresented: $isExporting,
                    document: BrewfileDocument(text: brewfileText),
                    contentType: .plainText,
                    defaultFilename: "Brewfile"
                ) { result in
                    switch result {
                    case .success(let url):
                        exportMessage = "已导出到 \(url.lastPathComponent)"
                    case .failure(let error):
                        exportMessage = "导出失败:\(error.localizedDescription)"
                    }
                }

                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func exportBrewfile() {
        // 先异步生成 Brewfile 内容,完成后弹导出面板
        Task {
            exportMessage = "正在生成 Brewfile…"
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("Brewfile.\(UUID().uuidString)")
            do {
                try await brew.exportBrewfile(to: tmp)
                brewfileText = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
                try? fm.removeItem(at: tmp)
                if brewfileText.isEmpty {
                    exportMessage = "导出失败:Brewfile 内容为空"
                } else {
                    isExporting = true
                }
            } catch {
                exportMessage = "生成失败:\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 命令行工具

    private var cliSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("命令行工具", systemImage: "terminal", tint: .green)
            Text("把 brew-ua CLI 安装到 $(brew --prefix)/bin,即可在终端直接运行 `brew ua` 逐个升级包(与 GUI 共用屏蔽列表与升级逻辑)。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let status = cliStatus {
                cliStatusRow(status)
                cliActionRow(status)
                if status.status == .installedForeign {
                    Text("目标位置已有 brew-ua 但解析不到版本(可能来自 Homebrew formula)。重装将覆盖;若来自 formula,其升级时会再次覆盖。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                ProgressView("检测中…")
                    .font(.caption)
            }

            if let message = cliMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("卸载 brew-ua CLI?", isPresented: $showUninstallConfirm, titleVisibility: .visible) {
            Button("卸载", role: .destructive) { uninstallCLI() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从 $(brew --prefix)/bin 中移除 brew-ua,不影响 Homebrew 本身。")
        }
    }

    @ViewBuilder
    private func cliStatusRow(_ status: CLIInstallStatus) -> some View {
        let info: (text: String, tint: Color) = {
            switch status.status {
            case .installed(let version):
                if status.isOutdated, let latest = status.bundledVersion {
                    return ("已安装 v\(version) · 可更新到 v\(latest)", .orange)
                }
                return ("已安装 v\(version)", .green)
            case .installedForeign:
                return ("已安装(来源未知)", .orange)
            case .notInstalled:
                return ("未安装", .secondary)
            case .brewNotFound:
                return ("未找到 Homebrew", .red)
            }
        }()
        HStack(spacing: 16) {
            Label(info.text, systemImage: "terminal")
                .font(.body.weight(.medium))
                .foregroundStyle(info.tint)
            Spacer()
            if let url = status.targetURL {
                Text(url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(url.path)
            }
        }
        .padding(12)
        .cardBackground(cornerRadius: 12)
    }

    @ViewBuilder
    private func cliActionRow(_ status: CLIInstallStatus) -> some View {
        HStack(spacing: 8) {
            switch status.status {
            case .notInstalled:
                Button {
                    installCLI()
                } label: {
                    Label("安装 brew-ua", systemImage: "arrow.down.circle")
                }
                .disabled(isCLIBusy)
            case .installed:
                if status.isOutdated, let latest = status.bundledVersion {
                    Button {
                        installCLI()
                    } label: {
                        Label("更新到 v\(latest)", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isCLIBusy)
                } else {
                    Button {
                        installCLI()
                    } label: {
                        Label("重装", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isCLIBusy)
                }
                Button(role: .destructive) {
                    showUninstallConfirm = true
                } label: {
                    Label("卸载", systemImage: "trash")
                }
                .disabled(isCLIBusy)
            case .installedForeign:
                Button {
                    installCLI()
                } label: {
                    Label("重装(覆盖)", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isCLIBusy)
                Button(role: .destructive) {
                    showUninstallConfirm = true
                } label: {
                    Label("卸载", systemImage: "trash")
                }
                .disabled(isCLIBusy)
            case .brewNotFound:
                EmptyView()
            }
            if isCLIBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func refreshCLIStatus() async {
        cliStatus = await CLIInstallerService.checkStatus()
    }

    private func installCLI() {
        Task {
            isCLIBusy = true
            cliMessage = "正在安装…"
            do {
                let version = try await CLIInstallerService.install()
                cliMessage = "已安装 brew-ua v\(version),在终端运行 `brew ua` 即可使用(新开终端窗口生效)"
            } catch {
                cliMessage = "安装失败:\(error.localizedDescription)"
            }
            isCLIBusy = false
            await refreshCLIStatus()
        }
    }

    private func uninstallCLI() {
        Task {
            isCLIBusy = true
            cliMessage = "正在卸载…"
            do {
                try await CLIInstallerService.uninstall()
                cliMessage = "已卸载 brew-ua"
            } catch {
                cliMessage = "卸载失败:\(error.localizedDescription)"
            }
            isCLIBusy = false
            await refreshCLIStatus()
        }
    }

    // MARK: - helpers

    private func sectionHeader(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(tint)
    }
}

/// 导出的 Brewfile 内容(由 SwiftUI fileExporter 提供数据)
struct BrewfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}