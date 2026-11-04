import SwiftUI
import SwiftData

/// 文件夹混剪页（第二轮改判后的版面：懒入库 + 组合级不重复 + 一键式 + 左栏勾选）。
///
/// 版面铁律 D15：**整页必须在真实最小窗口 900×600 内不出现纵向滚动**
/// （`ContentView.swift:217` 的 `minWidth/minHeight`）。所以：
///   - 不套 `ScrollView`；类别多到一行放不下时只允许**横向**翻动（纵向才是 D15 的红线）；
///   - 两颗开关落在**页脚按钮行右侧**，不进页头 —— 预览件台架的 spill 腿实测：900 窗口下
///     页头「标题 + 副标题 + 素材来源 + 换目录」已占 608/640，再塞两颗开关会把「换目录」
///     顶出窗口（2px，长副标题时 35px）；
///   - 缩略图高一律走 `Size.videoHeight(forWidth:)`，不许手写数字（9:16 铁律）。
///
/// 页面状态不在这里：`vm` 由 `ContentView` 持有并传进来（切侧栏页/重启不再整页销毁）。
/// 本文件里也不许出现任何择片/上限/形状判定（守卫 G-c）—— 那都在 Core，`swift test` 才编得到。
struct FolderMixView: View {
    let projectVM: ProjectViewModel
    let schemeVM: SchemeViewModel
    /// 会话状态由上层持有（笔 7 把它提到 `ContentView`）。这里只是接收方。
    @Bindable var vm: FolderMixViewModel

    @Environment(\.modelContext) private var modelContext
    @State private var isPickingRoot = false

    private static let sourceChoices: [SegmentSource] = [.selfShot, .curated, .aiGenerated]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
            header
            HStack(alignment: .top, spacing: DesignTokens.Spacing.comfortable) {
                categoryColumn
                Divider()
                drawColumn
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(DesignTokens.Padding.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // 还原会话（D28）：上一轮的类别顺序/勾选/条数/两颗开关都在，
            // 目录还在就自动重扫一遍 —— 这就是"选完目录不用再点入库"的那一半。
            // 不做这件事的话，页面回到"0 类 + 先选一个素材根目录"，正是用户报的那屏。
            vm.restoreFromDisk(context: modelContext)
        }
        .fileImporter(isPresented: $isPickingRoot,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { vm.beginScan(root: url, context: modelContext) }
            case .failure(let error):
                vm.errorMessage = FriendlyError.reason(for: error)
            }
        }
    }

    // MARK: 页头（标题 / 素材来源 / 选目录）—— 两颗开关不在这里，见文件头那条实测

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.normal) {
            Text("文件夹混剪")
                .font(DesignTokens.Typography.pageTitle)
            Text("一级子文件夹 = 一个类别；排好的顺序就是拼接顺序")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)          // 900 下允许省略号收缩；完整文案进 help
                .help("一级子文件夹 = 一个类别；整片按你排的顺序拼接。选完目录只做识别，不拷盘。")
            Spacer(minLength: DesignTokens.Spacing.tight)
            sourcePicker
            Button(vm.rootURL == nil ? "选择素材目录" : "换目录") { isPickingRoot = true }
        }
    }

    /// D21：来源必须显式选，未选时主按钮禁用 —— 因为 D20 把 `source` 改成了必填入参。
    /// 默认值曾把整批素材静默标成「搬运」（计划 R12），所以这里**没有默认值可退**。
    private var sourcePicker: some View {
        HStack(spacing: DesignTokens.Spacing.tight) {
            Text("素材来源").font(DesignTokens.Typography.label)
            Picker("素材来源", selection: $vm.source) {
                ForEach(Self.sourceChoices) { choice in
                    Text(choice.displayName).tag(SegmentSource?.some(choice))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if vm.source == nil {
                Text("未选").font(DesignTokens.Typography.micro).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 左栏：类别顺序 + 勾选轴（D29）

    private var categoryColumn: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            HStack {
                Text("类别顺序").font(DesignTokens.Typography.labelEmphasis)
                Spacer()
                if vm.scan != nil {
                    Button("全选") { vm.setAllEnabled(true) }
                        .buttonStyle(.bordered).controlSize(.mini)
                    Button("全不选") { vm.setAllEnabled(false) }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
                Text("\(vm.orderedCategories.count) 类").font(DesignTokens.Typography.micro)
                    .foregroundStyle(.secondary)
            }
            if let limit = vm.categoryLimitError {
                Text(limit)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.Status.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if vm.scan == nil {
                emptyHint("先选一个素材根目录。它下面的每个一级子文件夹会成为一个类别。")
            } else {
                ForEach(Array(vm.orderedCategories.enumerated()), id: \.element) { offset, name in
                    categoryRow(name: name, offset: offset)
                }
                Text("勾选决定参不参与；空类别不占额度（组合总数按参与类别相乘）")
                    .font(DesignTokens.Typography.micro).foregroundStyle(.secondary)
                if !vm.mergedCategories.isEmpty {
                    // 第九节「两个文件夹 trim 后同名」= 放行 + 合并，但必须出声
                    Text(vm.mergedNote)
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.Palette.Status.warning)
                        .lineLimit(2)
                }
                if !vm.rejections.isEmpty {
                    Text(vm.rejectionNote)
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.Palette.Status.warning)
                        .lineLimit(2)
                }
            }
        }
        .frame(width: 252, alignment: .topLeading)
    }

    /// 一行三件事：勾选（D29）/ 计数 / 排序。空类别可以勾，但勾了也不进乘积（R4/D13）。
    private func categoryRow(name: String, offset: Int) -> some View {
        let count = vm.candidatesByCategory[name]?.count ?? 0
        let on = vm.enabledCategories.contains(name)
        return HStack(spacing: DesignTokens.Spacing.tight) {
            Button {
                vm.setEnabled(name, on: !on)
            } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(count == 0 ? "这一类没有可拼接的视频，勾了也不参与" : "参不参与这一类")
            Text(name)
                .font(DesignTokens.Typography.cardTitle)
                .lineLimit(1)
                .foregroundStyle(on && count > 0 ? Color.primary : Color.secondary)
            Spacer()
            Text(count == 0 ? "空" : "\(count) 条")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(.secondary)
            if !on { Text("不参与").font(DesignTokens.Typography.micro).foregroundStyle(.secondary) }
            Button { vm.moveCategory(offset, up: true) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.bordered).controlSize(.mini)
                .disabled(offset == 0)
            Button { vm.moveCategory(offset, up: false) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.bordered).controlSize(.mini)
                .disabled(offset == vm.orderedCategories.count - 1)
        }
    }

    // MARK: 右栏：条数 / 翻页 / 抽片卡片

    private var drawColumn: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            HStack(spacing: DesignTokens.Spacing.compact) {
                Text("条数").font(DesignTokens.Typography.label)
                // TextField + Stepper（不是两颗 +/- 按钮）：用户要能直接敲 200，
                // 钳位口径在 VM（`FolderMixLimits.countInputClamp`），界面不自己算上限（G-c）
                TextField("", value: $vm.rowCount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                Stepper { EmptyView() } onIncrement: { vm.stepRowCount(1) }
                    onDecrement: { vm.stepRowCount(-1) }
                .labelsHidden()
                Text("软上限").font(DesignTokens.Typography.micro).foregroundStyle(.secondary)
                Text("\(vm.softLimit)").font(DesignTokens.Typography.label).frame(minWidth: 26)
                Stepper { EmptyView() } onIncrement: { vm.stepSoftLimit(10) }
                    onDecrement: { vm.stepSoftLimit(-10) }
                    .labelsHidden()
                    .help("超过这个条数要先出磁盘预估、勾「我已确认」才能生成（10 条为一档）")
                Spacer()
                Button { vm.step(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(!vm.canStepBack)
                Text("第 \(vm.rowIndex) / \(vm.rows.count) 条")
                    .font(DesignTokens.Typography.label).frame(minWidth: 84)
                Button { vm.step(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(!vm.canStepForward)
            }
            Text(vm.isSpaceSaturated
                 ? "组合空间充足（多到报不出准数）｜ 已发出 \(vm.ledgerIssuedCount) 条 ｜ 剩余 充足"
                 : "组合总数 \(vm.combinationTotal) ｜ 已发出 \(vm.ledgerIssuedCount) ｜ 还能出 \(vm.remainingCombos) 条互不相同的组合")
                .font(DesignTokens.Typography.micro).foregroundStyle(.secondary)

            if vm.rows.isEmpty {
                emptyHint(vm.scan == nil
                          ? "选好目录就能看到类别与候选 —— 本期不再需要先点入库。"
                          : "点下方「生成」抽出预览。（默认开着「生成前先预览」：第一次只出预览，不拷盘）")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.compact) {
                        ForEach(vm.currentRow?.picks ?? []) { pick in
                            card(for: pick)
                        }
                    }
                    .padding(.vertical, DesignTokens.Spacing.tight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Text(rowFootnote)
                    .font(DesignTokens.Typography.micro).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func card(for pick: FolderMixCandidate) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.small, style: .continuous)
                    .fill(DesignTokens.Palette.cardFill)
                Image(systemName: "film")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: DesignTokens.Size.videoHeight(forWidth: 96))
            Text(pick.category).font(DesignTokens.Typography.microEmphasis)
                .foregroundStyle(.secondary)
            Text(pick.name).font(DesignTokens.Typography.cardTitle).lineLimit(2)
            // 决定 6：时长读不到就显示「—」，**不许显示 0 秒**（0 会被磁盘预算当免费额度）
            Text(pick.duration.map { String(format: "%.0f 秒", $0) } ?? "—")
                .font(DesignTokens.Typography.timecode).foregroundStyle(.secondary)
        }
        .padding(DesignTokens.Padding.card)
        .frame(width: 112, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Corner.medium, style: .continuous)
            .strokeBorder(DesignTokens.Palette.border))
    }

    private var rowFootnote: String {
        guard let row = vm.currentRow else { return "" }
        var parts = ["本条 \(String(format: "%.0f 秒", vm.rowDuration(row)))"]
        let collided = vm.droppedRows.flatMap(\.categories)
        if !collided.isEmpty {
            parts.append("这些类别替不动：\(Array(Set(collided)).sorted().joined(separator: "、"))")
        }
        if vm.unknownDurationCount > 0 {
            parts.append("有 \(vm.unknownDurationCount) 段时长没读到（显示「—」，不计入磁盘预估）")
        }
        if !vm.pendingIdentityPaths.isEmpty {
            parts.append("内容归并中，还剩 \(vm.pendingIdentityPaths.count) 条")
        }
        return parts.joined(separator: "；")
    }

    // MARK: 页脚（超量红字 + 确认勾选 + 主按钮 + 两颗开关）

    private var footer: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            if let error = vm.errorMessage {
                Text(error).font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.Status.danger)
                    .lineLimit(3)
            }
            if !vm.ingestFailures.isEmpty {
                // 逐名上报（第九节：不许回到"静默 continue 让文件凭空消失"）
                Text("\(vm.ingestFailures.count) 个文件未入库："
                     + vm.ingestFailures.prefix(3).map { "\($0.name)（\($0.reason)）" }
                        .joined(separator: "、"))
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.Palette.Status.warning)
                    .lineLimit(2)
            }
            if vm.isOverSoftLimit {
                // 档 F：超软上限 = 红字 + 必须勾「我已确认」。数字全走 DiskSpaceBudget，
                // 不写耗时（仓内没有实测带宽真源，不拍脑袋）。
                Text("已超软上限 \(vm.softLimit) 条：将新建约 \(vm.ingestBytesNote()) 的素材文件（拷贝 ×2 预检）、"
                     + "产出 \(vm.rowCount) 个方案，导出后另占约 "
                     + "\(ByteCountFormatter.string(fromByteCount: vm.estimatedOutputBytes, countStyle: .file))")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.Status.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(vm.statusText.isEmpty ? "选目录 → 勾类别 → 排顺序 → 一键生成。整片按你排的类别顺序直拼。" : vm.statusText)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: DesignTokens.Spacing.compact) {
                if vm.isOverSoftLimit {
                    Toggle(isOn: $vm.overLimitConfirmed) {
                        Text("我已确认").font(DesignTokens.Typography.micro)
                    }
                    .toggleStyle(.checkbox)
                }
                Button(vm.previewFirst && vm.rows.isEmpty ? "预览 \(vm.rowCount) 条组合" : "生成 \(vm.rowCount) 个方案") {
                    Task { await vm.generate(projectVM: projectVM, schemeVM: schemeVM,
                                            context: modelContext) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canStartMainAction || vm.isBusy)
                Button("换一换本条") { vm.rerollCurrentRow() }
                    .disabled(vm.rows.isEmpty)
                Button("停止") { vm.stop() }
                    .disabled(!vm.isBusy && vm.pendingIdentityPaths.isEmpty)
                Spacer()
                Toggle("生成前先预览", isOn: $vm.previewFirst)
                    .toggleStyle(.checkbox).font(DesignTokens.Typography.micro)
                Toggle("精确识别（慢）", isOn: Binding(
                    get: { vm.preciseIdentity },
                    set: { vm.setPreciseIdentity($0, context: modelContext) }))
                    .toggleStyle(.checkbox).font(DesignTokens.Typography.micro)
                    .help("按大小 + 头尾各 4 MB 校验和归并内容相同的素材；已在库的零成本，未入库的每条约读 8 MB")
                if vm.lastSummaryProjectID != nil {
                    Button("去看那 \(vm.createdSchemeNames.count) 条方案") {
                        vm.openSummaryProject(projectVM: projectVM, schemeVM: schemeVM)
                    }
                }
                if vm.remainingCombos == 0 && !vm.rows.isEmpty {
                    Button("重新开始一轮") { vm.resetSession() }
                }
            }
        }
    }

    /// 主按钮的放行口径完全交给 VM（`canStartMainAction` 里那条"预览档看 canDraw、
    /// 生成档看 canCreate"的分支），界面不自己判上限 —— 守卫 G-c 拦的正是这个形状。

    private func emptyHint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
