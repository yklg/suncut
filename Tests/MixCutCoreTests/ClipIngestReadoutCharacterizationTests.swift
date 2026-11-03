import Foundation
import Testing

// ============================================================================
// CR · 「入库一批素材」的四颗 UI 读数 —— 特征化判据（笔 1a 立、笔 1b 成对改登）
//
// ## 为什么这组测试存在（计划 Context 第 5 条根因 + 评审 P0-1）
//
// `ClipIngestService` 那一步要把「把一批 URL 落进某个 Project」从 `ImportViewModel`
// 搬出去，而 `ImportViewModel` 同时是**导入页的 UI 状态宿主**：`ContentView.swift:97`
// 把它提到根，`:132` 给混剪页、`:269` 给导入页 —— 同一个实例。于是混剪一跑，
// 导入页的进度条就在显示「混剪入库第 3/60 个…」。
//
// 搬家唯一的判据是"行为不变"。但实测全仓 `Tests/**` 对 `phase` / `progress` /
// `progressDescription` / `isProcessing` / `errorMessage` 的断言数 = **0**
// （命中全是同名异物：`UndoGraceMachineTests` 的 `phase`、`HoverTipStateTests` 的
// `phase`、`DubbingPipelineProgressTests` 的 `DubbingJobProgress.phase`）。
// ⇒ 上一版计划里"用既有导入判据做对照"那句是**无中生有**（台账 R41 记了这条）。
// 所以搬家前先把"到底写了什么、按什么顺序写"钉成可机检的判据，并取了一次改前绿灯读数。
//
// ## 改前基线读数（2026-10-21，笔 1a 落地时实跑）
//
// `swift test --filter ClipIngestReadoutCharacterization` → **4 条全绿**，
// 13 处读数写入逐条命中、8 颗锚点顺序命中、`phase` 在混剪入库函数体内 0 次。
// 变异台架 `.scratch/fm_mutate_1a.py`：K1 改坏文案 / K2 去掉 defer / K3 交换收尾顺序
// → 三把全部咬中（K3 只红 CR-3，分工干净）。
//
// ## 笔 1b 搬家后这份判据怎么改登（就是现在这个样子，逐条交代）
//
// 读数写入按性质拆成两份名册，**成对登记**：
//   • `adapterSites` —— 界面读数，仍必须在 `ImportViewModel.importClipsWithoutAnalysis` 体内；
//   • `ingestSites`  —— 数据与结果写入，随真身搬进 `ClipIngestService.importClips`。
// 两份合起来仍是搬家前那 13 处，一处不多一处不少。
// 〔2026-10-22 追加〕笔 J2 在服务里加了 2 处**结果写入**（两支各一句 `report.ingested.append`），
// 于是服务侧从 3 处变 5 处、合计 15 处。加进名册而不是另起一条判据：CR-1 的计数断言正是
// 为"新增写入点必须被看见"而存在的 —— 漏登记它当场红。搬家那 13 处的口径没被放宽。
// 〔2026-10-22 第三轮追加〕笔 K2（甲-隐）在补建支又加了 2 处写入（第二处 `commitWholeVideo(`
// 与那句标记赋值），服务侧 5 → 7、合计 **17 处**。同样只在名册里加，不另起判据。
//
// 三处**源码文本变了但运行时字符串逐字相同**的改写，在这里显式记账（不记账就是"悄悄放宽判据"）：
//   ① `\(urls.count)` → 参数名 `\(count)`：hook 拿不到 `urls`，值同一个；
//   ② `urls.isEmpty ?` → `count == 0 ?`：同上；
//   ③ `report.abortMessage = errorMessage` → `= message`：中止原因是**结果**不是读数，
//      它跟着真身进了服务；适配层里 `errorMessage` 由 `diskShortfall` 回调写，串完全一样。
//
// ## 一处**有意**的行为变化（不是回归，别当 bug 提回来）
//
// 搬家前：混剪链 `importClipsWithoutAnalysis` → `importOrLinkVideo` → 里面写 `phase = .copying`，
// 所以混剪跑起来会把导入页的阶段态也一起改掉。搬家后：适配层**不接** `hooks.copying`，
// 于是混剪链不再写 `phase`（母体导入链 `importVideos` 照旧写，那是它自己的界面）。
// 这正是本轮要的效果 ⇒ CR-2 从"混剪函数体内没写 phase"升级成"**混剪整条链都不写 phase**"。
//
// ## 本判据不证明什么
//
// ❌ 不证明运行时取到的值序列（那需要真 SwiftData 容器 + 真视频 + 真 ffmpeg 缩略图链，
//    `MixCutAppTests` 里没有任何内存容器先例）。这一格**明文交给真机腿**：
//    计划「验证 · 真机端到端」第 9 步 —— 搬家前后各跑一次导入页正常导入，目测四条读数。
//    写成"已机检"就是撒谎，所以写在这段注释里。
//
// ## 判别式设计（防假绿）
//
// - CR-0 是**非空洞性腿**：两份函数体都要够长、每条 pinned 都必须至少命中 1 次。
// - 函数体按"与函数同缩进的收尾 `}` 行"定区间 —— 不能按花括号配平：签名里有
//   `onUpdate: @escaping @MainActor () -> Void = {}`，参数默认值那对花括号才是第一个
//   （第一版就栽在这里，13 条计数全 0，靠 CR-0 当场报出来）。
// - 复用 `FolderMixIngestScan`（同一套注释剥离 + 空白折叠 + 字符→源行号映射），
//   不另发明第二份扫描器。
// ============================================================================

private let crRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private let crAdapterFile = "MixCut/ViewModels/ImportViewModel.swift"
private let crAdapterFn = "func importClipsWithoutAnalysis("
private let crServiceFile = "MixCut/Services/Import/ClipIngestService.swift"
private let crServiceFn = "static func importClips("

/// 界面读数 —— 必须留在 ViewModel 的适配层里（门 T-24 反过来钉服务侧为 0）。
private let adapterSites: [(snippet: String, count: Int, note: String)] = [
    ("isProcessing = true", 1, "开跑置忙碌（改前 :624）"),
    ("errorMessage = nil", 1, "开跑清错误（:625）"),
    ("defer { isProcessing = false }", 1, "退出一定清忙碌 —— 少了它导入页会永远转圈（:626）"),
    ("errorMessage = \"磁盘空间不足：需要约 \\(needed)，当前可用 \\(available)\"", 1,
     "磁盘预检不过时的文案（原 :643，现由 diskShortfall 回调写，串逐字不变）"),
    ("progressDescription = \"混剪入库第 \\(index + 1)/\\(count) 个…\"", 1,
     "逐文件进度文案 —— 混剪与导入页串味就串在这一句（原 :662；\\(urls.count)→\\(count) 同值）"),
    ("progress = count == 0 ? 1.0 : Double(index) / Double(count)", 1,
     "进度值口径：空数组直接算走完（原 :663；urls.isEmpty→count==0 同值）"),
    ("let prevError = self.errorMessage.map { $0 + \"\\n\" } ?? \"\"", 1,
     "失败要**累积**不许互相覆盖（原 :681；搬进 hook 后必须带 self.）"),
    ("errorMessage = prevError + \"入库 \\(file) 失败: \\(reason)\"", 1,
     "逐名出声的失败明细（原 :682；表达式来源换到 hook 参数，运行时串逐字相同）"),
    ("progress = 1.0", 1, "收尾把进度推满（原 :698）"),
    ("progressDescription = \"\"", 1, "收尾清空进度文案 —— 顺序必须在 progress = 1.0 之后（原 :699）"),
]

/// 数据与结果写入 —— 跟着真身进了服务。
private let ingestSites: [(snippet: String, count: Int, note: String)] = [
    ("project.status = .importing", 1, "整批开始前把项目打成导入中（原 :649）"),
    ("report.abortMessage = message", 1, "预检失败要把同一句话回报给调用方（原 :645 的 abortMessage = errorMessage）"),
    ("project.status = .ready", 1, "整批收尾打回就绪（原 :695）"),
    // 甲-隐 的补建支（计划 2026-10-22 第三轮 笔 K2）：一条新的**数据写入点**，
    // 名字/形状/count 三件都要在册，否则"补建被打掉"或"多出一处补建"都无人报警。
    ("committer.commitWholeVideo(for: video, source: source,", 2,
     "service 内两处建段：新建支 + 去重命中的补建支（与门 T-25 的计数同源）"),
    ("built.mixInternalWholeClip = true", 1, "补建那条立刻打上内部段标记（甲-隐 的界线本体）"),
    ("report.ingested.append(FolderMixIngestedRow(sourcePath: url.path,", 2,
     "笔 J2 两支各记一次对应关系（新建整片段支 + 仅关联支）—— 只有一支有名册就红了"),
]

/// 相对顺序锚点（适配层内）：搬家后这条链不许重排。
private let orderAnchors: [String] = [
    "isProcessing = true",
    "errorMessage = nil",
    "defer { isProcessing = false }",
    "errorMessage = \"磁盘空间不足：需要约",
    "progressDescription = \"混剪入库第",
    "progress = count == 0 ? 1.0",
    "progress = 1.0",
    "progressDescription = \"\"",
]

private func crLoad(_ relative: String) -> String {
    let url = crRepoRoot.appendingPathComponent(relative)
    guard let s = try? String(contentsOf: url, encoding: .utf8) else {
        Issue.record("读不出 \(relative) ⇒ 本文件全部判据不可信")
        return ""
    }
    return s
}

/// 截出函数体的**原始行区间**，再交给 `FolderMixIngestScan` 去注释。
///
/// ⚠ 不能"从 marker 之后第一个 `{` 开始配平"：签名里有 `onUpdate: @escaping @MainActor () -> Void = {}`
/// —— 参数默认值的那对花括号才是 marker 之后的第一个，配平会立刻闭合、截出空串。
/// （第一版就栽在这里，13 条计数全 0 —— 非空洞性腿 CR-0 把它当场报了出来，这正是它存在的理由。）
/// 也不能从 marker 之后按括号配平找"参数表结束"：字符串插值 `\(...)` 里的圆括号会污染计数。
/// 所以走最笨也最稳的一条：**按与函数同缩进的收尾 `}` 行**定区间（本仓缩进 4 空格，实码一致）。
private func crFunctionSource(_ raw: String, marker: String) -> String? {
    let lines = raw.components(separatedBy: "\n")
    guard let head = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
    var i = head + 1
    while i < lines.count, lines[i] != "    }" { i += 1 }
    guard i < lines.count else { return nil }
    return lines[head...i].joined(separator: "\n")
}

/// 取到"已去注释、已折叠空白"的函数体文本；取不到就记红并返回 nil。
private func crBody(_ file: String, _ marker: String) -> String? {
    let raw = crLoad(file)
    guard let slice = crFunctionSource(raw, marker: marker) else {
        Issue.record("在 \(file) 里定位不到 \(marker) ⇒ 函数被改名/挪走/收尾括号缩进变了，本文件全部判据失效")
        return nil
    }
    return FolderMixIngestScan.scan(slice).text
}

@Test("CR-0 两份名册各自定位得到、且判据面非空洞（扫描器失步要在这里红，不是让后面十几条一起假绿）")
func crBaselineIsNotEmpty() {
    guard let adapter = crBody(crAdapterFile, crAdapterFn) else { return }
    guard let service = crBody(crServiceFile, crServiceFn) else { return }
    #expect(adapter.count > 500, "适配层只有 \(adapter.count) 字符 ⇒ 截取大概率失步")
    #expect(service.count > 800, "服务体只有 \(service.count) 字符 ⇒ 截取大概率失步")
    let missedAdapter = adapterSites.filter { !adapter.contains($0.snippet) }.map { $0.snippet }
    let missedService = ingestSites.filter { !service.contains($0.snippet) }.map { $0.snippet }
    #expect(missedAdapter.isEmpty, "适配层缺 \(missedAdapter.count)/\(adapterSites.count) 条：\(missedAdapter.prefix(3))")
    #expect(missedService.isEmpty, "服务缺 \(missedService.count)/\(ingestSites.count) 条：\(missedService.prefix(3))")
}

@Test("CR-1 名册 17 处写入逐处计数相符，且各归各位（读数在 VM、结果在服务）")
func crReadoutCountsAreLocked() {
    guard let adapter = crBody(crAdapterFile, crAdapterFn) else { return }
    guard let service = crBody(crServiceFile, crServiceFn) else { return }
    for site in adapterSites {
        let hits = adapter.components(separatedBy: site.snippet).count - 1
        #expect(hits == site.count, "适配层 · \(site.note) —— 实得 \(hits) 处，应 \(site.count) 处：\(site.snippet)")
    }
    for site in ingestSites {
        let hits = service.components(separatedBy: site.snippet).count - 1
        #expect(hits == site.count, "服务 · \(site.note) —— 实得 \(hits) 处，应 \(site.count) 处：\(site.snippet)")
    }
    // 串了位也算错：界面读数写进服务、结果写进适配层，都要红。
    let leaked = adapterSites.filter { service.contains($0.snippet) }.map { $0.snippet }
    #expect(leaked.isEmpty, "界面读数写漏进了服务：\(leaked.prefix(2))")
}

@Test("CR-2 混剪整条链都不写 phase（导入页的阶段态不归它管；母体导入链照旧）")
func crPhaseIsUntouchedOnMixLane() {
    guard let adapter = crBody(crAdapterFile, crAdapterFn) else { return }
    let mentions = adapter.components(separatedBy: "phase").count - 1
    #expect(mentions == 0, "适配层里出现了 \(mentions) 处 `phase` 字样 ⇒ 混剪又开始驱动导入页阶段态")

    guard let service = crBody(crServiceFile, crServiceFn) else { return }
    let serviceMentions = service.components(separatedBy: "phase").count - 1
    #expect(serviceMentions == 0, "服务里出现了 \(serviceMentions) 处 `phase` ⇒ T-24 的前提被从内部击穿")

    // 混剪链拿到的 hooks 不许接 copying —— 接了就等于把 phase 又拽回来。
    #expect(!adapter.contains("hooks.copying"),
            "适配层接了 hooks.copying ⇒ 混剪又开始写 phase = .copying（本轮要消灭的就是它）")
}

@Test("CR-3 八颗锚点的相对顺序锁定（收尾两句换序就是进度条闪回空值）")
func crWriteOrderIsLocked() {
    guard let adapter = crBody(crAdapterFile, crAdapterFn) else { return }
    var positions: [(String, Int)] = []
    for anchor in orderAnchors {
        guard let r = adapter.range(of: anchor) else {
            Issue.record("锚点丢失：\(anchor)")
            continue
        }
        positions.append((anchor, adapter.distance(from: adapter.startIndex, to: r.lowerBound)))
    }
    let outOfOrder = zip(positions, positions.dropFirst()).filter { $0.1.1 <= $0.0.1 }.map { "\($0.0.0) → \($0.1.0)" }
    #expect(outOfOrder.isEmpty, "写入顺序被重排：\(outOfOrder)")
}

@Test("CR-5 服务全文零 UI 读数与零删除（T-24 的第二视角：连提都不该提）")
func crServiceCarriesNoUIState() {
    let raw = crLoad(crServiceFile)
    guard !raw.isEmpty else { return }
    let scanned = FolderMixIngestScan.scan(raw).text
    for forbidden in ["phase", "progress", "progressDescription", "errorMessage", "ToastCenter"] {
        // 只禁**裸名**（VM 那五颗读数）。`video.errorMessage` 是 SwiftData 模型字段，同名异物
        // ——实码 :183 就在写它，把它一起禁掉就是判据自己骗自己（本轮实测踩过一次）。
        let bare = scanned.replacingOccurrences(of: "." + forbidden, with: "")
        let hits = bare.components(separatedBy: forbidden).count - 1
        #expect(hits == 0, "服务里出现 \(hits) 处裸「\(forbidden)」⇒ UI 语义又长回入库真身了")
    }
    let deletes = scanned.components(separatedBy: "context.delete(").count - 1
    #expect(deletes == 0, "服务里有 \(deletes) 处 context.delete( ⇒ 会把 G12 真删名册顶出一颗，且违反\"停止 ≠ 删除\"")
}
