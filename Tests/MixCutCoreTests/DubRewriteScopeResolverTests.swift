import Foundation
import Testing
@testable import MixCutCore

/// `DubRewriteScopeResolver` / `DubTargetOrdering` / `DubScopePresentationMapper` 契约测试。
///
/// 钉住的规则：
/// - 视频级控件只处理「属于本视频定义域」的目标，跨视频勾选经交集剔除；
/// - 多选优先；空选（非多选无 single）= 本视频全部；
/// - 目标按 (startTime, segmentIndex) 稳定排序；
/// - 作用域呈现由 mapper 单点产出，调用方零 scope 文案分支。
struct DubRewriteScopeResolverTests {

    // 定义域：视频 V 的两个分镜；idC/idD 属于另一个视频
    let idA = UUID()
    let idB = UUID()
    let idC = UUID()
    let idD = UUID()
    var domainIDs: Set<UUID> { [idA, idB] }

    // MARK: - Resolver 四分支真值表

    @Test("非多选 + 空选 → all，targetIDs=nil（本视频全部，空选可点）")
    func emptySelectionResolvesToAll() {
        let r = DubRewriteScopeResolver.resolve(
            domainIDs: domainIDs, isSelectionMode: false,
            selectedSegmentIDs: [], singleSegmentID: nil)
        #expect(r.kind == .all)
        #expect(r.targetIDs == nil)
    }

    @Test("非多选 + single 在定义域内 → single，目标仅该 ID")
    func singleInDomainResolvesToSingle() {
        let r = DubRewriteScopeResolver.resolve(
            domainIDs: domainIDs, isSelectionMode: false,
            selectedSegmentIDs: [], singleSegmentID: idA)
        #expect(r.kind == .single)
        #expect(r.targetIDs == [idA])
    }

    @Test("非多选 + single 属于他视频 → 回落 all，本视频不被他视频选择影响")
    func singleOutOfDomainFallsBackToAll() {
        let r = DubRewriteScopeResolver.resolve(
            domainIDs: domainIDs, isSelectionMode: false,
            selectedSegmentIDs: [], singleSegmentID: idC)
        #expect(r.kind == .all)
        #expect(r.targetIDs == nil)
    }

    @Test("多选 + 勾选含本视频与他视频 → selected，域外 ID 被交集剔除")
    func multiSelectionIntersectsDomain() {
        let r = DubRewriteScopeResolver.resolve(
            domainIDs: domainIDs, isSelectionMode: true,
            selectedSegmentIDs: [idA, idB, idC], singleSegmentID: nil)
        #expect(r.kind == .selected)
        #expect(r.targetIDs == [idA, idB])
    }

    @Test("多选 + 勾选仅部分落在本视频 → selected，只保留域内那一个")
    func multiSelectionPartiallyInDomain() {
        let r = DubRewriteScopeResolver.resolve(
            domainIDs: domainIDs, isSelectionMode: true,
            selectedSegmentIDs: [idA, idC, idD], singleSegmentID: nil)
        #expect(r.kind == .selected)
        #expect(r.targetIDs == [idA])
    }

    @Test("多选 + 勾选全在他视频 → disabled，目标为空")
    func multiSelectionAllOutOfDomainIsDisabled() {
        let r = DubRewriteScopeResolver.resolve(
            domainIDs: domainIDs, isSelectionMode: true,
            selectedSegmentIDs: [idC, idD], singleSegmentID: idA)
        #expect(r.kind == .disabled)
        #expect(r.targetIDs?.isEmpty == true)
    }

    @Test("多选 + 零勾选 → disabled")
    func multiSelectionEmptyIsDisabled() {
        let r = DubRewriteScopeResolver.resolve(
            domainIDs: domainIDs, isSelectionMode: true,
            selectedSegmentIDs: [], singleSegmentID: nil)
        #expect(r.kind == .disabled)
        #expect(r.targetIDs?.isEmpty == true)
    }

    // MARK: - Ordering

    @Test("ordering：乱序按 startTime 升序")
    func orderingByStartTime() {
        let items = [3, 1, 2]
        let result = DubTargetOrdering.ordered(items) {
            (startTime: Double($0), segmentIndex: 0)
        }
        #expect(result == [1, 2, 3])
    }

    @Test("ordering：startTime 相同按 segmentIndex 决胜")
    func orderingBySegmentIndexTiebreak() {
        let items = [3, 1, 2]
        let result = DubTargetOrdering.ordered(items) {
            (startTime: 0, segmentIndex: $0)
        }
        #expect(result == [1, 2, 3])
    }

    @Test("ordering：空数组返回空，非空时保留全部元素")
    func orderingEmptyAndPreservesAll() {
        #expect(DubTargetOrdering.ordered([Int](), key: { (Double($0), $0) }).isEmpty)
        let items = [4, 2, 9, 1, 7]
        let result = DubTargetOrdering.ordered(items) { (Double($0), 0) }
        #expect(result.count == items.count)
        #expect(Set(result) == Set(items))
    }

    // MARK: - Presentation Mapper

    @Test("mapper：四种作用域均产出非空错误引导语")
    func presentationErrorsAreNonEmpty() {
        for kind in [DubRewriteScopeKind.all, .single, .selected, .disabled] {
            let p = DubScopePresentationMapper.presentation(for: kind)
            #expect(!p.emptyEligibleError.isEmpty, "\(kind) 的 emptyEligibleError 为空")
        }
    }

    @Test("mapper：all/selected 需要计数，single/disabled 不需要")
    func presentationWantsCountConvention() {
        #expect(DubScopePresentationMapper.presentation(for: .all).wantsCount == true)
        #expect(DubScopePresentationMapper.presentation(for: .selected).wantsCount == true)
        #expect(DubScopePresentationMapper.presentation(for: .single).wantsCount == false)
        #expect(DubScopePresentationMapper.presentation(for: .disabled).wantsCount == false)
    }

    @Test("mapper：可执行作用域成功 Toast 非空；disabled 为空且不会被成功路径消费")
    func presentationSuccessToastAvailability() {
        #expect(!DubScopePresentationMapper.presentation(for: .all).successToast.isEmpty)
        #expect(!DubScopePresentationMapper.presentation(for: .single).successToast.isEmpty)
        #expect(!DubScopePresentationMapper.presentation(for: .selected).successToast.isEmpty)
        #expect(DubScopePresentationMapper.presentation(for: .disabled).successToast.isEmpty)
    }

    @Test("mapper：actionNoun 按作用域区分")
    func presentationActionNouns() {
        #expect(DubScopePresentationMapper.presentation(for: .all).actionNoun == "本视频")
        #expect(DubScopePresentationMapper.presentation(for: .single).actionNoun == "当前分镜")
        #expect(DubScopePresentationMapper.presentation(for: .selected).actionNoun == "选中分镜")
    }
}
