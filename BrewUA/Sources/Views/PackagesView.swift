import SwiftUI

/// 包管理页:已安装包列表(formula + cask),支持搜索、分段、pin 徽标与卸载。
struct PackagesView: View {
    private let brew = BrewService.shared
    private let config = ConfigService.shared
    @State private var packages: [InstalledPackage] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var kindFilter: PackageKind? = nil
    @State private var errorMessage: String?
    @State private var ignoredNames: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task { await load() }
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
        } else if filtered.isEmpty {
            ContentUnavailableView(
                "没有匹配的包",
                systemImage: "shippingbox",
                description: Text(searchText.isEmpty ? "未安装任何包" : "没有名称包含「\(searchText)」的包")
            )
        } else {
            List(filtered) { pkg in
                PackageRow(
                    package: pkg,
                    isIgnored: ignoredNames.contains(pkg.name),
                    onIgnore: { toggleIgnore(pkg) },
                    onUninstall: { uninstall(pkg) }
                )
            }
            .listStyle(.inset)
        }
    }

    private var filtered: [InstalledPackage] {
        packages
            .filter { kindFilter == nil || $0.kind == kindFilter }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.kind != $1.kind ? $0.kind == .formula : $0.name < $1.name }
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
            // 空列表 = 确实没装包,不误报失败
            if result.packages.isEmpty {
                errorMessage = "当前没有已安装的软件包。"
            }
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
        // 卸载走 brew uninstall,异步执行;确认弹窗由 SwiftUI confirmationDialog 触发
        let name = pkg.name
        Task {
            let flag = pkg.kind == .formula ? "--formula" : "--cask"
            let proc = StreamedProcess(brewArguments: ["uninstall", flag, name])
            _ = try? await proc.runSync()
            // 刷新列表
            await load()
        }
    }
}

/// 单行包
private struct PackageRow: View {
    let package: InstalledPackage
    let isIgnored: Bool
    let onIgnore: () -> Void
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
                onIgnore()
            } label: {
                Image(systemName: isIgnored ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .help(isIgnored ? "解除升级屏蔽" : "屏蔽该包的升级")

            Button(role: .destructive) {
                confirmUninstall = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
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