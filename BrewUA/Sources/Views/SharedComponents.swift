import SwiftUI

// MARK: - 共享 UI 组件
// 此前视图层三组重复实现(kind 胶囊 ×2 样式漂移、镜像色映射 ×2、卡片背景 ×7 圆角不一),统一收敛到这里。

/// formula/cask 类型胶囊徽章
struct KindBadge: View {
    let kind: PackageKind

    var body: some View {
        Text(kind == .formula ? "formula" : "cask")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(kind == .formula ? Color.blue.opacity(0.15) : Color.purple.opacity(0.15))
            .foregroundStyle(kind == .formula ? Color.blue : Color.purple)
            .clipShape(Capsule())
    }
}

extension MirrorSource {
    /// 镜像源 → 主题色
    var tint: Color {
        switch self {
        case .ustc, .tsinghua, .aliyun: return .orange
        case .official: return .teal
        case .unknown: return .gray
        }
    }
}

extension View {
    /// 卡片底色 + 圆角(行卡 8 / 大卡 12)
    func cardBackground(cornerRadius: CGFloat = 12) -> some View {
        background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
