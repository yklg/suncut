import SwiftUI

/// 产品视觉呈现的**唯一**收口（色点/面包屑等所有 UI 都从这里取）。
/// 颜色「序号」规则在 MixCutCore.ProductColor（可测、与产品增删无关地稳定），
/// 这里只负责序号 → 实际 Color，以及具体视图。
enum ProductPalette {
    /// 与 ProductColor.paletteCount 等长（6 色）。改数量必须同步核心常量。
    static let colors: [Color] = [
        Color(red: 0.09, green: 0.47, blue: 1.00),  // 蓝
        Color(red: 0.06, green: 0.72, blue: 0.48),  // 绿
        Color(red: 0.49, green: 0.25, blue: 0.87),  // 紫
        Color(red: 1.00, green: 0.49, blue: 0.00),  // 橙
        Color(red: 0.00, green: 0.68, blue: 0.72),  // 青
        Color(red: 0.85, green: 0.27, blue: 0.60),  // 品红
    ]
    static let defaultColor: Color = Color(red: 0.66, green: 0.68, blue: 0.72)  // 默认产品灰

    static func color(for product: Product?) -> Color {
        guard let product,
              let index = ProductColor.colorIndex(forProductID: product.id,
                                                  isDefault: product.isBuiltInDefault) else {
            return defaultColor
        }
        return colors[min(max(index, 0), colors.count - 1)]
    }
}

/// 8pt 产品色点（侧栏组头/欢迎页胶囊/面包屑/右键菜单共用）
struct ProductDot: View {
    let product: Product?
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(ProductPalette.color(for: product))
            .frame(width: size, height: size)
    }
}

/// 内容区顶部归属面包屑：色点 产品名 / 项目名 ……… 模块名
struct ProjectProductCrumb: View {
    let project: Project
    let moduleName: String?

    var body: some View {
        HStack(spacing: 8) {
            ProductDot(product: project.product, size: 7)
            Text(project.product?.name ?? ProductCatalogDefaults.defaultProductName)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text("/")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(project.name)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            if let moduleName {
                Text(moduleName)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.quaternary.opacity(0.6))
                .frame(height: 0.5)
        }
    }
}
