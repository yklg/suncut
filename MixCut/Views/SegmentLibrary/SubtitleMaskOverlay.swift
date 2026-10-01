// MixCut/Views/SegmentLibrary/SubtitleMaskOverlay.swift
import SwiftUI

/// 9:16 预览上的可拖拽/可调高遮挡框。父容器需给定 9:16 尺寸。
struct SubtitleMaskOverlay: View {
    @Binding var rect: SubtitleMaskRect

    /// 高度下限（归一化）。传 `SubtitleMaskRect.minimumHeight(fontRatio:)` 时，
    /// 遮挡带就拖不到"盖不住本分镜字幕"的高度。
    ///
    /// ⚠️ 必须在拖拽期间也用它：`draft` 是本地草稿、不经过 `Segment.maskRect` 的 setter，
    /// 只在写入侧钳位的话，拖矮的过程中屏幕会先如实画出那条盖不住的矮带、松手才弹回去 ——
    /// 用户看到的是"能拖矮，只是存不住"，而不是"拖不下去"。
    var minBandHeight: Double = SubtitleMaskRect.minSize

    /// 拖拽结束时回调一次（用于松手后保存，避免拖拽期间高频写 SwiftData）
    var onCommit: () -> Void = {}

    /// 拖拽期间的本地草稿，nil 表示当前未处于拖拽状态
    @State private var draft: SubtitleMaskRect?

    private let handleHeight: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // 显示用：拖拽中用草稿，否则用绑定值
            let active = draft ?? rect
            let px = active.pixelRect(width: w, height: h)

            ZStack(alignment: .topLeading) {
                // 遮挡区域手柄：**只描边，不填充**。
                // 以前这里无条件铺一层 accentColor.opacity(0.28)，而效果预览（模糊/纯色）
                // 画在播放器内部的静止帧上、位于本层之下 ⇒ 导出是 0x1A1A1A@1.0 的实色条，
                // 屏幕上却被这层蓝盖成"深蓝灰"，"预览与导出同源"当场就是假的。
                Rectangle()
                    .fill(Color.clear)
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: px.width, height: px.height)
                    // ⚠️ 透明填充不参与命中测试 —— 少了这一行整块区域就拖不动了，
                    // 而"拖不动"看起来像手势 bug，不会有任何编译或运行期提示。
                    .contentShape(Rectangle())
                    .offset(x: px.x, y: px.y)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // translation 是从手势起点到当前的累计位移，
                                // 拖拽期间 rect 不变，始终以 rect 为基准，避免叠加翻倍
                                let dy = Double(value.translation.height) / Double(h)
                                draft = rect.movedBy(dy: dy, minHeight: minBandHeight)
                            }
                            .onEnded { _ in
                                if let d = draft { rect = d }
                                draft = nil
                                onCommit()
                            }
                    )

                // 底部调高手柄
                Capsule()
                    .fill(Color.white)
                    .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 40, height: handleHeight)
                    .position(x: px.x + px.width / 2,
                              y: px.y + px.height)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // 同上：以稳定的 rect 为基准，按累计位移调整高度
                                let dH = Double(value.translation.height) / Double(h)
                                draft = rect.resizedBy(dHeight: dH, minHeight: minBandHeight)
                            }
                            .onEnded { _ in
                                if let d = draft { rect = d }
                                draft = nil
                                onCommit()
                            }
                    )
            }
        }
    }
}
