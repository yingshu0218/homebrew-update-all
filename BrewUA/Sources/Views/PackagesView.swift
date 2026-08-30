import SwiftUI

/// 包管理页:已安装包列表(formula + cask),支持搜索、分段、pin 徽标与卸载。
struct PackagesView: View {
    private let brew = BrewService.shared
    private let config = ConfigService.shared
    @EnvironmentObject private var engine: UpdateEngine
    @EnvironmentObject private var appModel: AppModel
    @State private var packages: [InstalledPackage] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var kindFilter: PackageKind? = nil
    @State private var errorMessage: String?
    @State private var ignoredNames: Set<String> = []
    /// 「仅看屏蔽」:开启后列表只显示被屏蔽升级的包
    @State private var showIgnoredOnly = false
    /// 卸载失败提示(弹窗)
    @State private var uninstallError: String?
    /// 正在卸载中的包名(防重复点击)
    @State private var uninstallingName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task { await load() }
        .alert("卸载失败", isPresented: Binding(
            get: { uninstallError != nil },
            set: { if !$0 { uninstallError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(uninstallError ?? "")
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("类型", selection: $kindFilter) {
                Text("全部 (\(packages.count))").tag(PackageKind?.none)
                Text("Formulae (\(packages.filter { $0.kind == .formula }.count))").tag(PackageKind?.some(.formula))
                Text("Casks (\(packages.filter { $0.kind == .cask }.count))").tag(PackageKind?.some(.cask))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            Spacer()

            Button {
                showIgnoredOnly.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showIgnoredOnly ? "lock.fill" : "lock.open")
                    Text(showIgnoredOnly ? "仅看屏蔽 (\(ignoredNames.count))" : "仅看屏蔽")
                }
                .font(.callout)
                .foregroundStyle(showIgnoredOnly ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(showIgnoredOnly ? "当前只显示被屏蔽升级的包(点击显示全部)" : "只显示被屏蔽升级的包(共 \(ignoredNames.count) 个)")

            searchField
            Button {
                Task { await load() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索包名", text: $searchText)
                .textFieldStyle(.plain)
                .frame(width: 180)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("正在读取已安装包…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView(
                "加载失败",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if packages.isEmpty {
            // 确实没装包:中性空状态(此前误走"加载失败"红色分支)
            ContentUnavailableView(
                "没有已安装的包",
                systemImage: "shippingbox",
                description: Text("当前没有已安装的软件包")
            )
        } else if filtered.isEmpty {
            ContentUnavailableView(
                "没有匹配的包",
                systemImage: "shippingbox",
                description: Text(emptyDescription)
            )
        } else {
            List(filtered) { pkg in
                PackageRow(
                    package: pkg,
                    isIgnored: ignoredNames.contains(pkg.name),
                    isUninstalling: uninstallingName == pkg.name,
                    onIgnore: { toggleIgnore(pkg) },
                    onUpgrade: { upgrade(pkg) },
                    onUninstall: { uninstall(pkg) }
                )
            }
            .listStyle(.inset)
        }
    }

    private var filtered: [InstalledPackage] {
        packages
            .filter { kindFilter == nil || $0.kind == kindFilter }
            .filter { !showIgnoredOnly || ignoredNames.contains($0.name) }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.kind != $1.kind ? $0.kind == .formula : $0.name < $1.name }
    }

    private var emptyDescription: String {
        if showIgnoredOnly {
            return searchText.isEmpty ? "没有已屏蔽升级的包" : "没有名称包含「\(searchText)」的已屏蔽包"
        }
        return searchText.isEmpty ? "未安装任何包" : "没有名称包含「\(searchText)」的包"
    }

    // MARK: - 动作

    private func load() async {
        isLoading = true
        errorMessage = nil
        ignoredNames = config.loadIgnored()
        defer { isLoading = false }
        let result = await brew.installedAllWithStatus()
        if result.success {
            packages = result.packages
            // 空列表 = 确实没装包,走独立空状态分支,不误报失败
        } else {
            errorMessage = "未能读取已安装包列表。请确认 Homebrew 可用。"
        }
    }

    /// 在升级屏蔽列表中添加/移除该包
    private func toggleIgnore(_ pkg: InstalledPackage) {
        if ignoredNames.contains(pkg.name) {
            try? config.removeIgnored(pkg.name)
            ignoredNames.remove(pkg.name)
        } else {
            try? config.addIgnored(pkg.name)
            ignoredNames.insert(pkg.name)
        }
    }

    private func uninstall(_ pkg: InstalledPackage) {
        guard uninstallingName == nil else { return } // 防重复点击
        uninstallingName = pkg.name
        let name = pkg.name
        Task {
            let flag = pkg.kind == .formula ? "--formula" : "--cask"
            let result = await brew.brewChecked(["uninstall", flag, name])
            uninstallingName = nil
            if result.success {
                await load()
            } else {
                // 卸载失败必须让用户知道(此前 try? 静默吞掉,包删不掉无解释)
                let reason = result.output
                    .split(separator: "\n")
                    .last { $0.contains("Error") || $0.contains("错误") }
                    .map(String.init) ?? "brew uninstall 退出异常"
                uninstallError = "\(name):\(reason)"
            }
        }
    }

    /// 单包升级:仅升级这一个包(两阶段),并跳转会升级中心看进度
    private func upgrade(_ pkg: InstalledPackage) {
        let entry = OutdatedEntry(
            name: pkg.name,
            currentVersion: pkg.version,
            newestVersion: "?",
            kind: pkg.kind,
            isIgnored: false
        )
        engine.upgrade(packages: [entry])
        appModel.selectedSection = .upgrade
    }
}

/// 单行包
private struct PackageRow: View {
    let package: InstalledPackage
    let isIgnored: Bool
    let isUninstalling: Bool
    let onIgnore: () -> Void
    let onUpgrade: () -> Void
    let onUninstall: () -> Void
    @State private var confirmUninstall = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: package.kind == .formula ? "shippingbox" : "app.badge")
                .foregroundStyle(package.kind == .formula ? .blue : .purple)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if package.isPinned {
                        Text("PIN")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.25))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                    if isIgnored {
                        Text("屏蔽升级")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red.opacity(0.2))
                            .foregroundStyle(.red)
                            .clipShape(Capsule())
                    }
                }
                Text(package.version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onUpgrade()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("升级 \(package.name)")

            Button {
                onIgnore()
            } label: {
                Image(systemName: isIgnored ? "lock.fill" : "lock.open")
                    .foregroundStyle(isIgnored ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isIgnored ? "已屏蔽升级(点击解除)" : "屏蔽该包的升级")

            Button(role: .destructive) {
                confirmUninstall = true
            } label: {
                if isUninstalling {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)
            .disabled(isUninstalling)
            .help("卸载 \(package.name)")
            .confirmationDialog(
                "确定卸载 \(package.name)?",
                isPresented: $confirmUninstall,
                titleVisibility: .visible
            ) {
                Button("卸载", role: .destructive) { onUninstall() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将执行 brew uninstall \(package.name)。此操作不可撤销。")
            }
        }
        .padding(.vertical, 2)
    }
}