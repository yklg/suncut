import Foundation

/// 字幕遮挡渲染模式（纯 Core 表示，与 App 的 MaskStyle/hasHardSubtitle 解耦）。
public enum SubtitleMaskMode: String, Equatable, Sendable, CaseIterable {
    case none    // 原片无硬字幕：不遮挡，仅叠新字幕
    case blur    // 模糊遮挡旧字幕
    case solid   // 纯色字幕条遮挡旧字幕
    case dim     // 半透明压暗（遮挡力度弱，一般不用）

    /// 从 App 层「是否有硬字幕 + maskStyle 原始值」映射到渲染模式。
    /// hasHardSubtitle == false → .none（无视 style）；否则按 style 取，未知退回 .blur。
    public static func from(hasHardSubtitle: Bool, maskStyleRaw: String) -> SubtitleMaskMode {
        guard hasHardSubtitle else { return .none }
        switch maskStyleRaw {
        case "blur":  return .blur
        case "solid": return .solid
        case "dim":   return .dim
        default:      return .blur
        }
    }
}

/// 一种遮挡模式**长什么样**的唯一来源。
///
/// 立表前：`boxblur=20:1` 与 `color=0x1A1A1A@1.0` 是硬编码在 ffmpeg 滤镜串里的，
/// 预览层（SwiftUI 画的那个半透明蓝框）完全不知道有这回事 ⇒ 同一个语义两份互不相干的实现，
/// 于是"模糊虚化"和"纯色遮挡"在卡片上长得一模一样，用户选完看不到任何差别。
/// 立表后：导出串与预览都只从这张表取值 ⇒ 改样式只改这一处，且 `swift test` 钉得住。
///
/// 做成 enum 而不是 struct：糊与填是两种不同操作，糊没有颜色、填没有半径 ——
/// 用类型把它们分开，非法组合就写不出来。
public enum SubtitleMaskRenderSpec: Equatable, Sendable {
    /// 不遮挡，透传
    case passthrough
    /// 裁出遮挡区糊掉再贴回。
    /// ⚠️ ffmpeg `boxblur` 的位置式语法是 `luma_radius:luma_power`；**只给这两个值时色度半径
    /// 继承同一个数**（不是"不设=不糊色度"）。⇒ 约束来自色度平面：yuv420 下色度是半尺寸，
    /// 实测（本机包内 ffmpeg）`r ≤ min(裁面宽, 高)/4`，超了直接 init 失败、导出 rc=234。
    /// 用之前必须过 `clampedRadius(cropWidth:cropHeight:)`。
    case blur(radiusPixels: Int, power: Int)
    /// 纯色/半透明条盖住遮挡区
    case fill(hex: String, alpha: Double)
}

public extension SubtitleMaskRenderSpec {
    /// 该档的标称糊半径（非 blur 档为 0）
    var nominalBlurRadius: Int {
        if case .blur(let radius, _) = self { return radius }
        return 0
    }

    /// 钳到给定裁面（导出像素）上 ffmpeg 真正接受的最大半径。
    ///
    /// 阈值是**实测**钉的，不是从文档抄的（2026-10-01，包内 ffmpeg）：
    /// 裁面高 38 ⇒ 最大 9（10 直接 init 失败）；40 ⇒ 10；78 ⇒ 19；80 ⇒ 20。
    /// 也就是 `floor(min(宽,高)/4)` —— 约束来自 yuv420 的**色度平面**（半尺寸），不是 luma。
    ///
    /// ⚠️ 有了 `SubtitleMaskRect.minimumHeight`（带高不能矮于本分镜字幕块）之后这条**仍然必需**，
    /// 因为两者量的不是同一个东西：下限钉在 1080×1920 基准上，最低档字号算出 0.043（该基准下 82px，
    /// 刚好过半径 20 要的 80px 线）；而钳位吃的是**本次导出的实际像素** —— 导出档按源片宽度走（`.original`），
    /// 480 宽的成片上同一个 0.043 只有 36px，能接受的半径就掉到 9。库里也还留着下限之前拖矮的旧值。
    ///
    /// 注：旧 480p 档写死的 480×854 已随 2026-10-19 那次整批拒收被删除，但**这条钳位依然会踩到** ——
    /// `.original` 仍会把源片宽度原样透出，素材库里现存 480×960 这一颗（2026-10-19 ffprobe 实测）。
    func clampedRadius(cropWidth: Int, cropHeight: Int) -> Int {
        min(nominalBlurRadius, max(0, min(cropWidth, cropHeight) / 4))
    }
}

public extension SubtitleMaskMode {
    var renderSpec: SubtitleMaskRenderSpec {
        switch self {
        case .none:   return .passthrough
        case .blur:   return .blur(radiusPixels: 20, power: 1)
        case .solid:  return .fill(hex: "1A1A1A", alpha: 1.0)
        case .dim:    return .fill(hex: "000000", alpha: 0.5)
        }
    }

    /// 该模式下烧录的新字幕要不要自带底衬。`solid` 已经铺了一条深色带，再叠一层底衬就是糊上加糊。
    /// ⚠️ 这是 mode 的**第三个**消费者（另两个是滤镜串与预览）；以前它写成裸的 `mode != .solid`
    /// 散在导出服务里，不进这张表，"效果只有一份定义"就缺一格。
    var burnsCaptionBackdrop: Bool { self != .solid }

    /// 预览用的糊半径（**点**）。表里存的是导出画布上的绝对像素，卡片只有 ~200pt 宽，
    /// 直接搬 20 会把整块糊成一团 ⇒ 按 `canonicalWidth` 折算回显示尺寸。
    ///
    /// 钳位同一条规则：`r ≤ 短边/4` 是比例式约束，在显示点空间上算与在导出像素上算等价
    /// （两侧同为 9:16 画布）。这里**不**复用 `clampedRadius(cropWidth:cropHeight:)` ——
    /// 那个方法的入参是导出像素，混单位传点会静默算错。
    ///
    /// ⚠️ 这只是**同一语义的近似呈现，不是同源像素**：ffmpeg 是"裁出带内 boxblur 再贴回"，
    /// 预览同序（见 `maskTreatmentPreview`），但核不同 —— `boxblur` 是盒式多重迭代、SwiftUI
    /// `.blur` 是 Gaussian，且带边界取像素的方式也不同（预览吃真实邻域像素，ffmpeg 吃裁出平面的
    /// 边缘处理）。所以预览是"糊成一片"这件事的**量级**对齐，不是逐像素对齐。
    /// `fill` 两档才是精确同源（同 hex 同 alpha）。
    func previewBlurRadius(displayWidth: CGFloat, displayCropHeight: CGFloat,
                           canonicalWidth: Int = 1080) -> CGFloat {
        let spec = renderSpec
        guard case .blur = spec, canonicalWidth > 0 else { return 0 }
        let displayNominal = CGFloat(spec.nominalBlurRadius) * displayWidth / CGFloat(canonicalWidth)
        return min(displayNominal, max(0, min(displayWidth, displayCropHeight) / 4))
    }
}
