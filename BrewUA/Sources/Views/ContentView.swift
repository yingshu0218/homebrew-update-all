import SwiftUI

/// 应用导航:5 个模块页
enum AppSection: String, CaseIterable, Identifiable {
    case overview = "总览"
    case packages = "包管理"
    case upgrade = "升级中心"
    case services = "服务管理"
    case settings = "设置迁移"

    var id: String { rawValue }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .overview: OverviewView()
        case .packages: PackagesView()
        case .upgrade: UpgradeCenterView()
        case .services: ServicesView()
        case .settings: SettingsView()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $appModel.selectedSection) { section in
                Label(section.rawValue, systemImage: icon(for: section))
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        } detail: {
            if let section = appModel.selectedSection {
                section.destination
                    .navigationTitle(section.rawValue)
            } else {
                Text("选择一个模块")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func icon(for section: AppSection) -> String {
        switch section {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .packages: return "shippingbox"
        case .upgrade: return "arrow.triangle.2.circlepath"
        case .services: return "server.rack"
        case .settings: return "gearshape"
        }
    }
}