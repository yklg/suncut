import Foundation
import SwiftData
import Testing

@testable import SunCut

// ============================================================================
// STW · 分镜「分类标签」的写入通路与下游联动
//
// ## 为什么要有这一组
//
// 在这一组之前，「改一条分镜的语义标签/位置」这件事**全仓零测试**：
// `toggleSemanticType`、`updatePositionType`、`applyFilter`、`SegmentFilter`、`countByType`、
// `applySourceToSelected` 在 `Tests/` 与 `MixCutAppTests/` 里一条命中都没有（计数来自 grep，
// 不是推断）。而屏上「分类标签不显示已命中」这一族症状，根因之一就是**写通路有两套**：
// Inspector 直改模型 + `try? save()`（不刷筛选派生、没有撤销动作名），ViewModel 里那条正解
// 反而零调用点。没有一条测"改完之后库里、计数上、下游池子里各是什么"的判据，这套分叉就一直能活。
//
// ## 这一组测的是"已存在的通路"，不是"计划里的新代码"
//
// 计划笔 1 的 `SemanticType.toggled` / `echoSlice` 还不存在 —— Swift 里引用未定义符号是**编译错误**
// 而不是测试失败，那样会把整个 `MixCutAppTests` 目标挡掉（连带现存 95 条）。所以：
//   · 本文件只打现有 API，今天就能编译；
//   · 断言里凡是"要等实现落地才同源"的字符串，一律写死字面量并在 reason 里标出改常量的时机；
//   · 依赖新符号的等价类穷举（`toggled` 的 4096 子集等）归计划里的第二批，不在这里。
//
// ## 台架
//   · 自建内存容器，绝不碰用户的活库；
//   · `ToastCenter` / `PendingDeletionCenter` 是进程级单例 ⇒ 套件 `.serialized`，
//     断 Toast 前先 `dismiss()`，用了撤销浮条的用例末尾 `flushNow()` 收尾，别把 ticket 漏给隔壁文件；
//   · 断言读**终态**（模型数组、重新 fetch 的结果、`ToastCenter.shared.current`），不读自家日志。
// ============================================================================

private func stwScratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("stw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func stwFile(_ dir: URL, _ name: String) throws -> String {
    let url = dir.appendingPathComponent(name)
    try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
    return url.path
}

private let stwFps = 25.0

/// 一条项目 + 一条源视频 + 若干紧贴分镜。标签/位置/来源/质量分/台词都显式给，
/// 免得用例里靠默认值猜"这段到底算不算可显示"。
@MainActor
private struct STWWorld {
    let project: Project
    let video: Video
    let segs: [Segment]
    let container: ModelContainer
    let ctx: ModelContext
    let vm: SegmentLibraryViewModel
}

@MainActor
private func stwWorld(dir: URL,
                      specs: [(text: String, types: [SemanticType], position: PositionType,
                               source: SegmentSource, quality: Double)]) throws -> STWWorld {
    let container = try ModelContainer(
        for: Schema(versionedSchema: AppSchemaV1.self),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let ctx = container.mainContext
    let project = Project(name: "STW-项目")
    ctx.insert(project)
    let video = Video(name: "STW-源", localPath: try stwFile(dir, "src.mov"))
    video.duration = Double(specs.count) * 2
    video.fps = stwFps
    video.width = 1080
    video.height = 1920
    ctx.insert(video)
    _ = ProjectVideo.associate(project: project, video: video, in: ctx)

    var segs: [Segment] = []
    for (i, spec) in specs.enumerated() {
        let seg = Segment(segmentIndex: String(format: "seg_%03d", i + 1),
                          startTime: Double(i) * 2, endTime: Double(i) * 2 + 2,
                          text: spec.text, semanticTypes: spec.types,
                          positionType: spec.position,
                          qualityScore: spec.quality,
                          textSource: .fullVideoSlice,
                          source: spec.source)
        seg.startFrame = FrameTime.frame(seconds: Double(i) * 2, fps: stwFps)
        seg.endFrame = FrameTime.frame(seconds: Double(i) * 2 + 2, fps: stwFps)
        seg.video = video
        ctx.insert(seg)
        segs.append(seg)
    }
    try ctx.save()

    let vm = SegmentLibraryViewModel()
    vm.setModelContext(ctx)
    vm.segments = segs
    vm.applyFilter()          // 建派生（countByType / filteredSegments / segmentByID）
    return STWWorld(project: project, video: video, segs: segs,
                    container: container, ctx: ctx, vm: vm)
}

/// 默认四段：覆盖「单标签 / 多标签 / 空镜 / 空台词」四种等价类。
private let stwDefaultSpecs: [(text: String, types: [SemanticType], position: PositionType,
                              source: SegmentSource, quality: Double)] = [
    ("橙子汁水多到离谱", [.hook], .opening, .selfShot, 9.0),
    ("秋冬一到嘴就干", [.hook, .painPoint], .middle, .curated, 7.0),
    ("皮很薄 很好剥开", [.painPoint], .ending, .selfShot, 5.0),
    ("", [.emptyShot], .middle, .aiGenerated, 8.0),
]

@Suite("STW · 分镜分类标签的写入通路与下游联动", .serialized)
struct SegmentTagWritePathTests {

    // MARK: FR-01 经写通路落库，再换一个 context 读回来

    @Test("STW-1 经 VM 写通路改标签 ⇒ 落库后重新 fetch 读得回（不是只在内存里改了个对象）")
    @MainActor
    func writePathPersists() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        let seg = w.segs[0]
        #expect(seg.semanticTypes == [.hook], "夹具前提没立住：默认第一段应是单标签 .hook")

        w.vm.toggleSemanticType(for: seg, type: .solution)
        #expect(seg.semanticTypes == [.hook, .solution],
                "VM 写入口没把新标签追加上去（实得 \(seg.semanticTypes.map(\.rawValue))）")

        // 换一颗 context 从同一个容器重读：证的是"落库了"，不是"这个对象被改过"。
        let probe = ModelContext(w.container)
        let back = try probe.fetch(FetchDescriptor<Segment>()).first { $0.id == seg.id }
        #expect(back?.semanticTypes == [.hook, .solution],
                "重新 fetch 读回 \(back?.semanticTypes.map(\.rawValue) ?? []) ⇒ 写通路没真正落库")
    }

    @Test("STW-2 改位置 ⇒ 落库读得回，且按位置筛对得动")
    @MainActor
    func positionWritePersistsAndFilters() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        let seg = w.segs[0]

        w.vm.updatePositionType(for: seg, to: .ending)
        #expect(seg.positionType == .ending)

        let back = try ModelContext(w.container)
            .fetch(FetchDescriptor<Segment>()).first { $0.id == seg.id }
        #expect(back?.positionType == .ending, "位置改动没落库")

        w.vm.filter = SegmentFilter(positionTypes: [.ending])
        w.vm.applyFilter()
        // 原本 .ending 的第三段 + 刚改成 .ending 的第一段 = 2
        #expect(w.vm.filteredSegments.count == 2,
                "按位置筛出 \(w.vm.filteredSegments.count) 条，应为 2 ⇒ 筛与写不是同一份真源")
    }

    // MARK: INV-02 「至少保留 1 个语义类型」

    @Test("STW-3 只剩一颗标签时再点它 ⇒ 数组必须原样（这条今天也成立）")
    @MainActor
    func keepAtLeastOneLeavesArrayUnchanged() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        let seg = w.segs[0]

        w.vm.toggleSemanticType(for: seg, type: .hook)
        #expect(seg.semanticTypes == [.hook],
                "「至少保留一个」被破口：摘掉唯一标签后实得 \(seg.semanticTypes.map(\.rawValue))")
    }

    @Test("STW-4 同上那种拒绝必须出声（屏上「点了没反应」就是这条）")
    @MainActor
    func refusalIsAnnounced() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        let seg = w.segs[0]

        ToastCenter.shared.dismiss()
        w.vm.toggleSemanticType(for: seg, type: .hook)
        // 2026-11-06 摘标：原为 withKnownIssue 红钉（旧 toggleSemanticType 里那句
        // `if types.count > 1` 判掉后什么都不做、不弹提示 ⇒ 用户体感「点了没反应」）。
        // 计划笔 2 落地后它因「不再有问题」自己变红 ⇒ 摘标，断言转为永久闸，
        // 并把原先写死的字面串换成那颗新增的常量（同源，改文案不会再只改到一半）。
        #expect(ToastCenter.shared.current?.text == SemanticType.keepAtLeastOneMessage,
                "被拒不发声 ⇒ 实得 Toast = \(ToastCenter.shared.current?.text ?? "nil")")
        ToastCenter.shared.dismiss()
    }

    // MARK: INV-01 派生刷新（改了标签，顶部筛选条的计数必须同帧跟上）

    @Test("STW-5 经 VM 改标签 ⇒ countByType 与 filteredSegments 同帧一致")
    @MainActor
    func tagWriteRefreshesDerivedState() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        #expect(w.vm.countByType[.solution] == 0, "夹具前提：默认没有「产品方案」")

        w.vm.toggleSemanticType(for: w.segs[0], type: .solution)
        #expect(w.vm.countByType[.solution] == 1,
                "实得 \(w.vm.countByType[.solution] ?? -1) ⇒ 写通路没触发派生重算（顶部 chip 计数会滞后）")

        w.vm.filter = SegmentFilter(semanticTypes: [.solution])
        w.vm.applyFilter()
        #expect(w.vm.filteredSegments.map(\.id) == [w.segs[0].id])
    }

    @Test("STW-6 带筛选态取消当前命中的那颗 ⇒ 卡片移出可见集，但 Inspector 不许跟着关")
    @MainActor
    func editingUnderAnActiveFilterKeepsTheInspector() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        let single = w.segs[0]                 // 只有 [.hook] 一颗
        let multi = w.segs[1]                  // [.hook, .painPoint]
        let hookOnly = Set(w.vm.filteredSegments.map(\.id))

        w.vm.filter = SegmentFilter(semanticTypes: [.hook])
        w.vm.applyFilter()
        #expect(w.vm.filteredSegments.count == 2, "夹具前提：.hook 应命中前两段")

        // ① 单标签那颗**摘不动** —— 最小值不变式在带筛选态时照样拦。
        //    （本条第一版误拿这颗去验"摘掉后移出可见集"，于是红在产品做对的地方。）
        w.vm.pin(single)
        w.vm.toggleSemanticType(for: single, type: .hook)
        #expect(single.semanticTypes == [.hook],
                "单标签被摘掉了：实得 \(single.semanticTypes.map(\.rawValue))")
        #expect(w.vm.filteredSegments.contains { $0.id == single.id },
                "不变式拦下之后这段仍该在可见集里（它还是 .hook）")

        // ② 多标签那颗摘掉筛选命中的那一颗 ⇒ 真的移出可见集。
        w.vm.pin(multi)
        w.vm.toggleSemanticType(for: multi, type: .hook)
        #expect(multi.semanticTypes == [.painPoint],
                "实得 \(multi.semanticTypes.map(\.rawValue))")
        #expect(!w.vm.filteredSegments.contains { $0.id == multi.id },
                "摘掉筛选标签后这段还留在可见集 ⇒ 筛选与写不是同一份真源")

        // 评审 R7 的读数：selectedSegment 走 segmentByID（建自**未筛选**全集，VM:369），
        // 所以面板不会因为"这条被筛掉了"而自己关掉。这条断言钉的是这个行为别被改丢。
        #expect(w.vm.selectedSegment?.id == multi.id,
                "Inspector 跟着筛选一起把当前分镜丢了 ⇒ 用户正在编辑的那条从面板消失")

        w.vm.filter = SegmentFilter()
        w.vm.applyFilter()
        #expect(Set(w.vm.filteredSegments.map(\.id)) == hookOnly,
                "清空筛选后没回到原来的可见集 ⇒ 筛选态是可逆的这件事不成立")
    }

    // MARK: XR-01 标签 ⇄ 逐段重听队列（M1 终态档）

    @Test("STW-7 摘掉「空镜」标签 ⇒ 该段重新进入逐段重听队列；打上 ⇒ 免听")
    func emptyLensTagDrivesTheRetakeQueue() {
        // 终态档的正反两腿：空文本 + 整片切片来源。
        #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "",
                                                   currentSource: .fullVideoSlice,
                                                   isEmptyLensSettled: false) == true,
                "空文本没排进重听队列 ⇒ 空段被当成结论吞了")
        #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "",
                                                   currentSource: .fullVideoSlice,
                                                   isEmptyLensSettled: true) == false,
                "已判空镜的空段还在每次重跑都再听一遍（RP-13c 那颗贵 2.9 倍的雷）")
        // 第三腿：来源在说谎时终态档不许越界免听（有台词的段无论如何都得走原口径）。
        #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "有台词",
                                                   currentSource: .fullVideoSlice,
                                                   isEmptyLensSettled: true) == false,
                "非空台词被终态档免听 ⇒ 这一档越界了")
        #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "",
                                                   currentSource: .manualEdit,
                                                   isEmptyLensSettled: true) == true,
                "手改来源的空文本被终态档免听 ⇒ 来源在说谎时也要真听一遍")
    }

    // MARK: XR-02 手标「空镜」⇄ 导出侧的补差额插片池（评审 R3）

    @Test("STW-8 有台词的段打上「空镜」⇒ 确实会进补差额的插片池（读数留证）")
    @MainActor
    func handTaggedSpeechSegmentEntersBrollPool() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        let speaking = w.segs[0]     // 有台词、原本 .hook
        // 夹具前提只能按 label 集合判：默认四段里 seg_004 本来就是一颗合法空镜（台词为空），
        // 它必须在池子里。拿 `isEmpty` 当前提会红在夹具上，而不是红在这件事上。
        let before = w.project.brollSupplies.map(\.label)
        #expect(before == ["seg_004"], "夹具前提：池子里该只有那段空台词的空镜，实得 \(before)")

        // 模拟把一段**有台词**的分镜标成空镜。
        speaking.semanticTypes = [.emptyShot]
        try w.ctx.save()

        let labels = w.project.brollSupplies.map(\.label)
        #expect(labels.contains(speaking.segmentIndex),
                "实得池子 = \(labels) ⇒ 手标空镜的有台词段没进池，那 R3 这条风险不成立，本条应改写为正向断言")
    }

    @Test("STW-9 目标口径：有台词的段不该被当成补差额的插片素材（模型侧仍未设防）")
    @MainActor
    func speechSegmentsShouldNotFeedBrollPool() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        let speaking = w.segs[0]
        speaking.semanticTypes = [.emptyShot]
        try w.ctx.save()

        // 断言按 label 判，不用 `isEmpty`：默认夹具里 seg_004 那颗合法空镜本来就该在池子里，
        // 用 isEmpty 会让这条红在夹具上、而不是红在"有台词段进池"这件事上。
        let labels = w.project.brollSupplies.map(\.label)
        let reason = "红钉（评审 R3，**本轮未收口**）：`Project.brollSupplies`（Project.swift:86，入池判断在 :87）"
            + "只看标签、不看台词是否为空 —— 而它自己的注释（:81）就写着「带台词的段插进来会让画面与"
            + "别段口播撞叙事」。本轮落的是 **UI 侧**那道闸（`SemanticType.confirmationNeededForEmptyShot`"
            + " ⇒ 有台词段点空镜要先弹代价 + 二次确认，见 STW-9b），所以绕过界面的写入仍然不设防："
            + "MCP 的 set_semantic_types、批量补标、以及将来任何新入口都能把有台词段送进插片池。"
            + "摘标条件：把闸抬进 `Project.brollSupplies` 的入池口径（或写标签的唯一出口）之后本条自然通过。"
        // ⚠️ Swift Testing 的 `Comment` 只吃插值字面量，`+` 拼出来的 `String` 要过一道 `"\(...)"`，
        // 否则是类型错误而不是测试失败 —— 这一形在本文件里错过两次，靠 build-for-testing 才抓到
        // （`swiftc -parse` 只到语法层）。
        withKnownIssue("\(reason)") {
            #expect(!labels.contains(speaking.segmentIndex),
                    "有台词段进了插片池：\(labels)")
        }
    }

    @Test("STW-9b 手改空镜的代价闸：判据只在「有台词 + 尚未标空镜 + 正是要加上」这一档响")
    @MainActor
    func emptyShotConfirmationGateScopesCorrectly() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        let speaking = w.segs[0]      // 有台词、[.hook]
        let silent = w.segs[3]        // 空台词、[.emptyShot]

        // 正腿：有台词段要打上空镜 ⇒ 必须确认。
        #expect(SemanticType.confirmationNeededForEmptyShot(on: speaking, adding: .emptyShot),
                "代价闸没响 ⇒ 用户一次点击就把有口播的画面送进插片池")
        // 反腿一：摘掉已有空镜标签**不该**拦 —— 那是设计内的"人否决机器"入口
        //（见 SegmentTranscribeOutcome.shouldAutoRetake 的说明），拦了就是给正解加门槛。
        #expect(!SemanticType.confirmationNeededForEmptyShot(on: silent, adding: .emptyShot),
                "已经是空镜的段再点不该再要确认")
        // 反腿二：空台词段打空镜不需要确认（它本来就是合法供给）。
        // ⚠️ 这里原本用 `segs[2].setText("   ")` 造空白，实测**造不出来**：
        // `setText` 走 `TextProvenance.resolve` 裁决，空白覆盖真台词是不落库的
        // （那是一条既有防线，不是 bug）。所以空白段必须用 init 直接构造。
        let speechless = Segment(segmentIndex: "gate_blank", startTime: 8, endTime: 10,
                                 text: "   \n ", semanticTypes: [.painPoint],
                                 positionType: .middle)
        #expect(!SemanticType.confirmationNeededForEmptyShot(on: speechless, adding: .emptyShot),
                "纯空白台词被当成有台词 ⇒ 会给正当的补标路径加门槛")
        // 顺带把刚发现的那条防线钉住：手抖想用空白抹掉真台词，抹不掉 ⇒
        // 代价闸也不会因为一次误清空而"看起来该关了"。只读终态（台词本身），
        // 不去断 `shouldWrite` 那种内部标志 —— 内部说该写而实际没写，用户看到的仍是没写。
        _ = speaking.setText("   ", source: .manualEdit)
        #expect(speaking.text == "橙子汁水多到离谱",
                "空白覆盖真台词竟然落库了（实得「\(speaking.text)」）⇒ 台词防抹线破了")
        // 反腿三：加的是别的标签 ⇒ 与这道闸无关。
        #expect(!SemanticType.confirmationNeededForEmptyShot(on: speaking, adding: .hook),
                "闸越界到普通标签上了")
    }

    // MARK: 同族既有空白：批量标记来源（今天也是零测试）

    @Test("STW-10 批量标记来源：只动选中集，撤销逐条还原旧值")
    @MainActor
    func batchSourceIsTargetedAndUndoable() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        defer { PendingDeletionCenter.shared.flushNow() }

        w.vm.selectedSegmentIDs = [w.segs[0].id, w.segs[1].id]
        #expect(w.vm.selectedSegments.count == 2)

        w.vm.applySourceToSelected(.aiGenerated)
        #expect(w.segs[0].source == .aiGenerated && w.segs[1].source == .aiGenerated,
                "批量标记没作用到选中集")
        #expect(w.segs[2].source == .selfShot && w.segs[3].source == .aiGenerated,
                "批量动到了没选中的段")

        PendingDeletionCenter.shared.undoTapped()
        #expect(w.segs[0].source == .selfShot && w.segs[1].source == .curated,
                "撤销没把原来源还回来（实得 \(w.segs[0].source)/\(w.segs[1].source)）")
    }

    @Test("STW-10b 重复批量后再撤销：应回到最初，实得停在原地（既有缺陷，非本轮引入）")
    @MainActor
    func repeatedBatchStealsTheUndoSnapshot() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        defer { PendingDeletionCenter.shared.flushNow() }

        w.vm.selectedSegmentIDs = [w.segs[0].id, w.segs[1].id]
        w.vm.applySourceToSelected(.aiGenerated)
        // 数据层面重复执行是幂等的（什么都没改），但 `applySourceToSelected` 无条件再排一枚
        // ticket，其快照取的是**已经改完**的状态 ⇒ 用户点「撤销」时浮条消失、数据不动。
        w.vm.applySourceToSelected(.aiGenerated)
        #expect(w.segs[0].source == .aiGenerated, "重复执行改动了数据 ⇒ 与实测不符，本条前提要重写")

        let reason = "红钉（既有缺陷，2026-11-06 App 腿实测抓到）：`applySourceToSelected` 不判"
            + "「有没有真的改动」就重新 `scheduleUndoOnly`，第二枚 ticket 的快照已是改后值 ⇒ "
            + "重复批量后点撤销等于空转。本轮新增的 `addSemanticTypeToSelected` / "
            + "`setPositionTypeForSelected` 已经避开了这一形（先算 changed，为 0 就出声并直接返回，"
            + "见 STW-13），所以这颗钉的是**旧的那颗**没同步修。"
            + "摘标条件：给 `applySourceToSelected` 补同一道 `changed` 前置后本条自然通过。"
        withKnownIssue("\(reason)") {
            PendingDeletionCenter.shared.undoTapped()
            #expect(w.segs[0].source == .selfShot && w.segs[1].source == .curated,
                    "撤销空转：实得 \(w.segs[0].source)/\(w.segs[1].source)")
        }
    }

    // MARK: IN-02 筛选五维的交集口径（今天一条都没有）

    @Test("STW-11 筛选组合：语义 × 位置 × 来源 × 质量 × 搜索，逐组对命中数",
          arguments: [
            (Set<SemanticType>([.hook]), Set<PositionType>([]), nil as SegmentSource?, 0.0, "", 2),
            (Set<SemanticType>([.painPoint]), Set<PositionType>([]), nil as SegmentSource?, 0.0, "", 2),
            (Set<SemanticType>([.hook, .painPoint]), Set<PositionType>([]), nil as SegmentSource?, 0.0, "", 3),
            (Set<SemanticType>([]), Set<PositionType>([.middle]), nil as SegmentSource?, 0.0, "", 2),
            (Set<SemanticType>([]), Set<PositionType>([]), .selfShot, 0.0, "", 2),
            (Set<SemanticType>([]), Set<PositionType>([]), nil as SegmentSource?, 8.0, "", 2),
            (Set<SemanticType>([]), Set<PositionType>([]), nil as SegmentSource?, 0.0, "嘴", 1),
            (Set<SemanticType>([.hook]), Set<PositionType>([.opening]), nil as SegmentSource?, 0.0, "", 1),
            (Set<SemanticType>([.emptyShot]), Set<PositionType>([.ending]), nil as SegmentSource?, 0.0, "", 0),
          ])
    @MainActor
    func filterCombinationsIntersectAsExpected(
        types: Set<SemanticType>, positions: Set<PositionType>, source: SegmentSource?,
        minQuality: Double, search: String, expected: Int) throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)

        w.vm.filter = SegmentFilter(semanticTypes: types, positionTypes: positions,
                                    minQualityScore: minQuality, searchText: search,
                                    source: source)
        w.vm.applyFilter()
        let detail = "语义\(types.map(\.rawValue)) 位置\(positions.map(\.rawValue)) "
            + "来源\(String(describing: source)) 质量≥\(minQuality) 搜索「\(search)」"
            + "⇒ 期望 \(expected) 条，实得 \(w.vm.filteredSegments.count) 条"
        #expect(w.vm.filteredSegments.count == expected, "\(detail)")
    }

    @Test("STW-12 反向对照：搜索词命中关键词而不是只命中台词")
    @MainActor
    func searchTextAlsoMatchesKeywords() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        let seg = w.segs[0]
        seg.keywords = ["脐橙"]
        try w.ctx.save()

        w.vm.filter = SegmentFilter(searchText: "脐橙")
        w.vm.applyFilter()
        // applyFilter 的口径是 text ∪ keywords（VM:427-433）；只测台词那一半会漏掉这条腿。
        #expect(w.vm.filteredSegments.map(\.id) == [seg.id],
                "关键词命中没进筛选结果 ⇒ 搜索口径与 VM 里的注释不一致")
    }

    // MARK: 批量（本轮新增的两个 VM 方法）

    @Test("STW-13 批量加语义标签：只改该改的、再跑一次不动、撤销逐条还原")
    @MainActor
    func batchAddIsTargetedIdempotentAndUndoable() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        defer { PendingDeletionCenter.shared.flushNow() }

        let before = w.segs.map(\.semanticTypes)
        w.vm.selectedSegmentIDs = [w.segs[0].id, w.segs[1].id]
        w.vm.addSemanticTypeToSelected(.solution)

        #expect(w.segs[0].semanticTypes == [.hook, .solution],
                "实得 \(w.segs[0].semanticTypes.map(\.rawValue))")
        #expect(w.segs[1].semanticTypes == [.hook, .painPoint, .solution],
                "实得 \(w.segs[1].semanticTypes.map(\.rawValue))")
        #expect(w.segs[2].semanticTypes == before[2] && w.segs[3].semanticTypes == before[3],
                "批量动到了没选中的段")

        // 幂等：选中集都已经有这颗了 ⇒ 一条都不该再动（也不该多出第二份）。
        let afterFirst = w.segs.map(\.semanticTypes)
        w.vm.addSemanticTypeToSelected(.solution)
        #expect(w.segs.map(\.semanticTypes) == afterFirst, "重复执行把标签加了两遍")

        PendingDeletionCenter.shared.undoTapped()
        #expect(w.segs.map(\.semanticTypes) == before,
                "撤销没还原原标签：\(w.segs.map { $0.semanticTypes.map(\.rawValue) })")
    }

    @Test("STW-14 批量加标签不许被「至少保留一个」牵连：单标签成员照样加上")
    @MainActor
    func batchAddDoesNotTripTheMinimumInvariant() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        defer { PendingDeletionCenter.shared.flushNow() }

        // 四段里有两段是单标签 ⇒ 若批量把最小值那条不变式当成"加"的门槛，它们就会被跳过。
        w.vm.selectedSegmentIDs = Set(w.segs.map(\.id))
        w.vm.addSemanticTypeToSelected(.results)

        #expect(w.segs.allSatisfy { $0.semanticTypes.contains(.results) },
                "有成员没被加上 ⇒ 批量误把「至少保留一个」当成加标签的前提")
        // 守恒：每段恰好 +1，没有谁被加了两遍（默认 1/2/1/1 ⇒ 加完 2/3/2/2）。
        #expect(w.segs.map(\.semanticTypes.count) == [2, 3, 2, 2],
                "实得各段标签数 = \(w.segs.map(\.semanticTypes.count))，应为 [2, 3, 2, 2]")
    }

    @Test("STW-15 批量设位置：全量覆盖后撤销逐条还原原位置")
    @MainActor
    func batchSetPositionIsUndoable() throws {
        let dir = try stwScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try stwWorld(dir: dir, specs: stwDefaultSpecs)
        defer { PendingDeletionCenter.shared.flushNow() }

        let before = w.segs.map(\.positionType)
        #expect(before == [.opening, .middle, .ending, .middle], "夹具前提：位置该是 [开头,中间,结尾,中间]")

        w.vm.selectedSegmentIDs = Set(w.segs.map(\.id))
        w.vm.setPositionTypeForSelected(.ending)
        #expect(w.segs.allSatisfy { $0.positionType == .ending },
                "实得 \(w.segs.map(\.positionType))")

        PendingDeletionCenter.shared.undoTapped()
        #expect(w.segs.map(\.positionType) == before,
                "撤销没还原位置：\(w.segs.map(\.positionType))")
    }
}
