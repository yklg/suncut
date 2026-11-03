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
    /// 当前项目（提供项目级音色覆盖）。
    let project: Project
    @Bindable var dubVM: DubbingViewModel
    /// 作用域解析结果（决定按钮文案与禁用态）
    let scope: DubRewriteScopeResolution
    /// 作用域对应的目标分镜（已稳定排序；eligible 过滤在组件与管线中各自按同一口径执行）
    let targets: [Segment]
    /// 作用域呈现文案
    let presentation: DubScopePresentation
    /// 停止请求上抛到页面顶层（停止确认弹窗统一在 SegmentLibraryView）
    let onStopRequest: (UUID) -> Void
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

    /// 按钮是否禁用：多选无勾选（disabled）、无可用分镜，或未配置任何音色。
    private var isCTADisabled: Bool {
        scope.kind == .disabled || eligibleCount == 0 || !isVoiceConfigured
    }
    private var isVoiceConfigured: Bool {
        if case .resolved = voiceResolution { return true }
        return false
    }
    /// **本视频**内「可改写」的分镜（全视频口径）。
    ///
    /// ⚠️ 刻意用入参 `videoSegments`，**不用** `video.segments`：后者是 SwiftData 关系
    /// fault，已真删的分镜可能仍挂在内存对象上，读到就 SIGTRAP（见本文件 `:12-13`）。
    /// ⚠️ 也必须排除 `isVoiceLocked` 与空台词：否则被保留原声的镜头与空台词分镜
    /// 会让「全部已克隆」**永远为假** ⇒ 三态永远退化成第二态。
    private var cloneableSegments: [Segment] {
        videoSegments.filter { !$0.isVoiceLocked && !$0.text.isEmpty }
    }
    /// 是否**有任一分镜**已按段级克隆。
    private var hasAnyClone: Bool {
        cloneableSegments.contains { ($0.clonedVoiceId ?? "").isEmpty == false }
    }
    /// 是否**全部分镜**都已按段级克隆（存量视频级克隆不算——它没有段级窗口信息）。
    private var hasAllClone: Bool {
        let cs = cloneableSegments
        guard !cs.isEmpty else { return false }
        return cs.allSatisfy { ($0.clonedVoiceId ?? "").isEmpty == false }
    }
    /// M1b：该视频存在克隆声时，音色状态行才是可切换开关（否则没有「原声克隆」可切）。
    ///
    /// ⚠️ **M2：改按分镜聚合**。旧实现读 `video.clonedVoiceId`，而该字段在 M2 后
    /// 生产代码已无写点（恒 nil）⇒ `hasCloneVoice` 恒 false ⇒ 音色切换菜单整个不渲染
    /// ⇒ 用户在素材库里**看不到也选不了「原声克隆」**（用户报告的现象）。
    private var hasCloneVoice: Bool { hasAnyClone }
    /// 状态文本颜色（克隆=次要灰，全局/项目预置=品牌蓝，未配置=灰）。
    private var isVoiceConfigEnabledColor: Color {
        isVoiceConfigured && usesGlobalVoiceWithoutClone ? Color.accentColor : .secondary
    }
    private var disabledHint: String {
        if scope.kind == .disabled {
            return "多选模式下请先勾选本视频要改写的分镜"
        }
        if eligibleCount == 0 { return presentation.emptyEligibleError }
        if !isVoiceConfigured { return "尚未配置配音音色，请到「设置 → 配音」选择全局音色" }
        return presentation.emptyEligibleError
    }

    /// 当前视频已生成的配音变体总数（与作用域无关，统计整个视频）。
    ///
    /// ⚠️ 性能：这原本是计算属性，每次渲染都要遍历全部分镜并触发 `segmentDubs` 关系 faulting；
    /// 而本视图持有 `@Bindable dubVM`，配音进度每跳一次都会重跑一遍。改为缓存，
    /// 仅在进入/切换视频与配音忙碌状态结束时刷新。
    @State private var variantCount: Int = 0

    /// 当前生效音色解析（视图只展示，真规则在 Core VoiceResolver）。
    /// M1b：透传视频级「跟随全局/项目」开关（voiceFollowsGlobal），压制历史克隆声。
    ///
    /// ⚠️ **M2：必须传段级信息**，否则解析链里只有视频级 `videoCloneVoiceID`，
    /// 而它在 M2 后恒 nil ⇒ 永远解析成预置/全局音色
    /// ⇒ 状态文案恒显示「全局默认」、`:84` 的「原声克隆」分支成为死代码。
    ///
    /// 本组件是**视频级作用域**（`let video` + `videoSegments`），拿不到单一 segment
    /// ⇒ 传「第一个已克隆的分镜」作为代表（各分镜音色可能不同，状态行只能给总览）。
    private var voiceResolution: VoiceResolution {
        VoicePreferences.resolveForLegacy(video: video,
                                          projectOverrideRaw: project.preferredVoiceChoiceRaw,
                                          suppressVideoClone: video.voiceFollowsGlobal,
                                          segment: videoSegments.first(where: { ($0.clonedVoiceId ?? "").isEmpty == false }),
                                          hasAnySegmentClone: hasAnyClone)
    }
    /// 音色状态文案（**三态**，M2）。
    ///
    /// ⚠️ 为什么必须三态而不是二值：段级克隆必然产生**混合状态**
    /// （视频内部分分镜已克隆、部分还没）。若用二值「有/无」，混合状态会显示成
    /// 「各分镜用各自原声」—— **这是谎话**：未克隆的那几段实际会走全局默认。
    ///
    /// 三态：
    /// - 全部分镜已克隆 ⇒ 「各分镜用各自原声」
    /// - **部分已克隆**   ⇒ 「部分分镜用原声（其余用全局默认）」
    /// - 都没有          ⇒ 「当前音色：XXX（全局默认 / 项目覆盖 / 我的复刻）」
    private var voiceStatusText: String {
        // 三态判据优先于 voiceResolution：后者只代表「第一个已克隆分镜」这一个样本，
        // 覆盖不了混合状态。
        if hasAnyClone, !video.voiceFollowsGlobal {
            return hasAllClone ? "各分镜用各自原声" : "部分分镜用原声（其余用全局默认）"
        }
        switch voiceResolution {
        case .resolved(let choice):
            switch choice {
            case .videoClone:
                // 存量视频级克隆（无段级窗口信息）走这里；段级克隆已被上面的三态接住。
                return "原声克隆（旧·整片）"
            case .preset(let id):
                let name = VoiceCatalog.displayName(id: id)
                return project.preferredVoiceChoiceRaw != nil
                    ? "当前音色：\(name)（项目覆盖）"
                    : "当前音色：\(name)（全局默认）"
            case .globalClone(_, _, _): return "当前音色：我的复刻"
            }
        case .unconfigured:
            return "未配置音色 · 改写前请先在设置选择"
        }
    }
    /// 是否走零克隆路径（预置/全局复刻）；决定计费文案。
    private var usesGlobalVoiceWithoutClone: Bool {
        if case .resolved(let c) = voiceResolution, c.engine == .cosyVoice { return true }
        return false
    }
    private var currentVoiceDisplayName: String {
        guard case .resolved(let c) = voiceResolution else { return "" }
        switch c {
        case .preset(let id): return VoiceCatalog.displayName(id: id)
        case .videoClone: return "原声克隆"
        case .globalClone: return "我的复刻"
        }
    }

    private func refreshVariantCount() {
        // 关系读取收口在 VM：只计有音频的真实变体，无音频空壳不计，避免数字虚高。
        variantCount = dubVM.readyDubCount(in: videoSegments)
    }

    /// 仅反映本视频的忙碌状态（不同视频互不联动）。
    private var busy: Bool { dubVM.isBusy(videoID: video.id) }

    /// 语速读写绑定：写入侧一律过 `DubRateLimits.clamp`。
    ///
    /// 为什么必须 clamp 在**写入处**而不是读取处：`Video.dubSpeechRate` 的注释写着
    /// 「范围 0.7~1.3」却全仓没有任何写入面，那句话就这么烂了好几个版本。
    /// 范围只在 `DubRateLimits` 一处定义，界面与引擎合法区间同源，不再抄第二份。
    private var speechRateBinding: Binding<Double> {
        Binding(
            get: { DubRateLimits.clamp(video.dubSpeechRate) },
            set: { newValue in
                let clamped = DubRateLimits.clamp(newValue)
                guard clamped != video.dubSpeechRate else { return }
                video.dubSpeechRate = clamped
                do { try modelContext.save() }
                catch { MixLog.error("语速保存失败：\(error.localizedDescription)") }
            }
        )
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            if busy {
                DubbingCompactProgress(videoID: video.id, vm: dubVM) { onStopRequest(video.id) }
            } else {
                if variantCount > 0 {
                    Label("\(variantCount) 个变体", systemImage: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(.green)
                        .help("已生成 \(variantCount) 个配音变体，点开分镜在右侧查看")
                }

                // 当前音色状态（全局/项目预置 vs 原声克隆 vs 未配置）。
                // M1b：该视频有历史克隆声时，状态行即二选一开关（原声克隆 ↔ 跟随全局/项目）；
                // 无克隆声的视频没有可切对象，保持纯文本。切换只影响此后新生成（VM 收口）。
                if hasCloneVoice {
                    Menu {
                        Button {
                            dubVM.setVideoFollowsGlobal(false, video: video, context: modelContext)
                        } label: {
                            if video.voiceFollowsGlobal {
                                Text("各分镜用各自原声")
                            } else {
                                Label("各分镜用各自原声", systemImage: "checkmark")
                            }
                        }
                        Button {
                            dubVM.setVideoFollowsGlobal(true, video: video, context: modelContext)
                        } label: {
                            if video.voiceFollowsGlobal {
                                Label("跟随全局或项目音色", systemImage: "checkmark")
                            } else {
                                Text("跟随全局或项目音色")
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(voiceStatusText).font(.system(size: 10)).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                        }
                        .foregroundStyle(isVoiceConfigured
                                         ? (usesGlobalVoiceWithoutClone ? Color.accentColor : .secondary)
                                         : .secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                    .help("切换该视频的配音音色来源（仅影响此后新生成，不改动已有配音）")
                } else {
                    Text(voiceStatusText)
                        .font(.system(size: 10))
                        .foregroundStyle(isVoiceConfigEnabledColor)
                        .lineLimit(1)
                        .help(isVoiceConfigured ? voiceStatusText : disabledHint)
                }

                Stepper(value: $variantCountSetting, in: DubbingViewModel.variantCountRange) {
                    Text("×\(variantCountSetting)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                .controlSize(.mini)
                .fixedSize()
                .help("每个非「保留原声」分镜要产出的台词变体数量（1–5）")

                // 语速：A 块「全程语速一致」的唯一可调旋钮。
                // 写在这里而不是另造一颗 @AppStorage —— `Video.dubSpeechRate` 这颗字段早就存在，
                // 但全仓**只有定义与一次读取、没有任何写入面**（注释里那句「范围 0.7~1.3」
                // 因此从来没被 clamp 过）。这一颗控件是它的第一任写入者，值域与 clamp
                // 统一走 DubRateLimits，界面范围和引擎合法区间同源。
                Stepper(value: speechRateBinding, in: DubRateLimits.rateMin...DubRateLimits.rateMax,
                        step: 0.05) {
                    Text(String(format: "语速 %.2f×", video.dubSpeechRate))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                .controlSize(.mini)
                .fixedSize()
                .disabled(busy)
                .help("该视频此后新生成配音的语速（一条视频内恒定，不再逐段变速去凑画面时长）。"
                     + "只影响此后新生成，不改动已有配音。")

                scopeLabel

                Button {
                    showRewriteConfirm = true
                } label: {
                    Label(ctaTitle, systemImage: "wand.and.stars")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(isCTADisabled)
                .help(isCTADisabled ? disabledHint
                      : "改写台词并用\(usesGlobalVoiceWithoutClone ? "全局音色" : "克隆嗓音")合成配音。作用域：\(presentation.actionNoun)")
            }
        }
        .confirmationDialog("确定要开始改写台词吗？", isPresented: $showRewriteConfirm) {
            Button("开始（按次计费）") {
                // 句柄归视频级注册表：切换分镜/素材不再连带取消。
                dubVM.startRewriteTask(video: video,
                                       targets: targets,
                                       presentation: presentation,
                                       context: modelContext,
                                       projectOverrideRaw: project.preferredVoiceChoiceRaw)
            }
            Button("取消", role: .cancel) {}
        } message: {
            if usesGlobalVoiceWithoutClone {
                Text("将为\(presentation.actionNoun) \(eligibleCount) 个分镜各生成 \(variantCountSetting) 套改写台词，并用音色「\(currentVoiceDisplayName)」合成约 \(eligibleCount * variantCountSetting) 段配音。仅 AI 改写 + TTS 合成费用，无需人声分离与声音注册。")
            } else {
                Text("将为\(presentation.actionNoun) \(eligibleCount) 个分镜各生成 \(variantCountSetting) 套改写台词，并用克隆嗓音合成约 \(eligibleCount * variantCountSetting) 段配音。首次克隆含人声分离与声音注册费用，按次计费，耗时较长。")
            }
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
