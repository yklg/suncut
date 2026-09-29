import SwiftUI

/// 品牌标记：一律用美术 logo（与 Dock/Finder 那颗同源）。
///
/// 曾经按尺寸分档退回 SF Symbol，结果侧栏那颗通用胶片被认成「图标没换」——
/// 符号不是品牌标记，分档省下的清晰度不值这个歧义。
struct BrandLogo: View {
    /// 名义边长（pt），与同行文字字号同量级。
    let size: CGFloat

    /// 美术稿四周按 macOS 图标网格自带一圈留白，按名义尺寸画会比旁边的符号显小；
    /// 留白是这张稿的属性、与用在哪个界面无关，所以补偿只给一个全局常数。
    static let opticalScale: CGFloat = 1.15

    var body: some View {
        Image("Logo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size * Self.opticalScale, height: size * Self.opticalScale)
    }
}
