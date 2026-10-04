import SwiftUI

/// 视频分组标题行右侧「配音」栏。
///
/// 命名统一为「一键改写台词」体系（方案 A）：自动克隆原声 → 改写台词 → 克隆嗓音合成配音。
/// 作用域（本视频全部 / 当前分镜 / 选中分镜）与呈现文案全部由 SegmentLibraryView
/// 解析后作为入参传入，本组件只做展示，不做集合运算、不出现 scope 逻辑分支。
struct DubSettingsBar: View {
    let video: Video
    /// 本视频的**全部**分镜（由调用方从 VM 的未筛选全域投影传入）。
    ///
    /// ⚠️ 刻意不做成「组件自己去读 `video.segments`」：那是一次 SwiftData 关系 fault，
    /// 已真删的分镜可能仍挂在这个内存对象上，读到就 SIGTRAP（见 SegmentLibraryView 同处注释）。
    let videoSegments: [Segment]
    @Bindable var dubVM: DubbingViewModel
    /// 作用域解析结果（决定按钮文案与禁用态）
    let scope: DubRewriteScopeResolution
    /// 作用域对应的目标分镜（已稳定排序；eligible 过滤在组件与管线中各自按同一口径执行）
    let targets: [Segment]
    /// 作用域呈现文案
    let presentation: DubScopePresentation
    @Environment(\.modelContext) private var modelContext

    /// 每个非锁定分镜要产出的台词变体数量（全局设置，1...5）。
    @AppStorage("dubVariantCount") private var variantCountSetting: Int = DubbingViewModel.defaultVariantCount
    /// 计费确认弹窗
    @State private var showRewriteConfirm = false

    /// 本作用域内真正会被改写的分镜数（非「保留原声」且有原台词），用于确认弹窗与作用域标注。
    private var eligibleSegments: [Segment] {
        targets.filter { !$0.isVoiceLocked && !$0.text.isEmpty }
    }
    private var eligibleCount: Int { eligibleSegments.count }

    /// 按钮是否禁用：多选无勾选（disabled），或作用域内没有可改写分镜。
    private var isCTADisabled: Bool {
        scope.kind == .disabled || eligibleCount == 0
    }
    private var disabledHint: String {
        if scope.kind == .disabled {
            return "多选模式下请先勾选本视频要改写的分镜"
        }
        return presentation.emptyEligibleError
    }

    /// 当前视频已生成的配音变体总数（与作用域无关，统计整个视频）。
    ///
    /// ⚠️ 性能：这原本是计算属性，每次渲染都要遍历全部分镜并触发 `segmentDubs` 关系 faulting；
    /// 而本视图持有 `@Bindable dubVM`，配音进度每跳一次都会重跑一遍。改为缓存，
    /// 仅在进入/切换视频与配音忙碌状态结束时刷新。
    @State private var variantCount: Int = 0

    private func refreshVariantCount() {
        // 吃传入的投影数组，不 fault `video.segments`；元素本身仍是模型对象，
        // 这里的 `$1.segmentDubs` 是对**存活投影元素**的一次计数，规模与危险度都远低于遍历整条视频关系。
        variantCount = videoSegments.reduce(0) { $0 + $1.segmentDubs.count }
    }

    /// 仅反映本视频的忙碌状态（不同视频互不联动）。
    private var busy: Bool { dubVM.isBusy(videoID: video.id) }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            if busy {
                ProgressView().controlSize(.small)
                Text(dubVM.progressText(videoID: video.id))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            } else {
                if variantCount > 0 {
                    Label("\(variantCount) 个变体", systemImage: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(.green)
                        .help("已生成 \(variantCount) 个配音变体，点开分镜在右侧查看")
                }

                Stepper(value: $variantCountSetting, in: DubbingViewModel.variantCountRange) {
                    Text("×\(variantCountSetting)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                .controlSize(.mini)
                .fixedSize()
                .help("每个非「保留原声」分镜要产出的台词变体数量（1–5）")

                scopeLabel

                Button {
                    // 计费确认：未克隆时这一下会触发 demucs 人声分离 + 音色克隆 + N 套 AI 改写
                    // + 分镜 × N 段 TTS 合成，是全 App 最贵的操作之一，手滑点到代价很大。
                    showRewriteConfirm = true
                } label: {
                    Label(ctaTitle, systemImage: "wand.and.stars")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(isCTADisabled)
                .help(isCTADisabled ? disabledHint
                      : "自动克隆原声 → 改写台词 → 用克隆嗓音生成配音。作用域：\(presentation.actionNoun)")
            }
        }
        .confirmationDialog("确定要开始改写台词吗？", isPresented: $showRewriteConfirm) {
            Button("开始（按次计费）") {
                Task {
                    await dubVM.rewrite(video: video,
                                       targets: targets,
                                       presentation: presentation,
                                       context: modelContext)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将为\(presentation.actionNoun) \(eligibleCount) 个分镜各生成 \(variantCountSetting) 套改写台词，并用克隆嗓音合成约 \(eligibleCount * variantCountSetting) 段配音。按次计费，耗时较长。")
        }
        .task(id: video.id) { refreshVariantCount() }
        // 配音跑完（busy 由 true 变 false）时刷新计数
        .onChange(of: busy) { _, isBusy in
            if !isBusy { refreshVariantCount() }
        }
        // 配音错误的 alert 已上移到 SegmentLibraryView 顶层。
        // 挂在这里不可靠：本组件只在「普通视频」分组标题行渲染，且外层是 LazyVStack，
        // 一旦分组标题滚出可视区，宿主被回收，报错就再也弹不出来了。
    }

    // MARK: - 按钮文案（方案 A，不随 clonedVoiceId 变化）

    private var ctaTitle: String {
        switch scope.kind {
        case .all:      return "一键改写台词"
        case .single:   return "改写当前分镜"
        case .selected: return "改写选中分镜"
        case .disabled: return "改写选中分镜"
        }
    }

    // MARK: - 作用域标注（步进器与按钮之间，两行右对齐）

    private var scopeNoun: String {
        switch scope.kind {
        case .all:            return "本视频"
        case .single:         return "当前"
        case .selected, .disabled: return "选中"
        }
    }
    private var scopeCount: Int { scope.kind == .disabled ? 0 : targets.count }

    private var scopeLabel: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("作用域：\(scopeNoun)")
            Text("\(scopeCount) 个分镜")
                .foregroundStyle(scope.kind == .disabled ? Color.secondary : Color.accentColor)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }
}
