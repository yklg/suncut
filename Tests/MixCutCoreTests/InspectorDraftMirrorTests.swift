import Testing
@testable import MixCutCore

@Suite("InspectorDraftMirror 草稿镜像状态机")
struct InspectorDraftMirrorTests {

    @Test("初值：草稿=源且不脏；空初值不崩")
    func initialState() {
        let m = InspectorDraftMirror(source: "原台词")
        #expect(m.draft == "原台词")
        #expect(!m.isDirty)

        let empty = InspectorDraftMirror()
        #expect(empty.draft == "")
        #expect(!empty.isDirty)
    }

    @Test("干净态采纳外部更新，采纳后仍不脏")
    func cleanAdoptsExternal() {
        var m = InspectorDraftMirror(source: "甲")
        let adopted = m.adoptExternal("乙")
        #expect(adopted)
        #expect(m.draft == "乙")
        #expect(!m.isDirty)
    }

    @Test("干净态收到同值外部更新：幂等，不标记脏")
    func sameValueIsIdempotent() {
        var m = InspectorDraftMirror(source: "甲")
        let adopted = m.adoptExternal("甲")
        #expect(adopted)
        #expect(m.draft == "甲")
        #expect(!m.isDirty)
    }

    @Test("脏态拒绝外部覆盖：手改草稿保留、基准不变（核心契约）")
    func dirtyRejectsExternal() {
        var m = InspectorDraftMirror(source: "原台词")
        m.edit("用户手改未保存")
        #expect(m.isDirty)

        // 模拟：失焦后边界微调重切出新文本——旧 focused 判定会在这里吞掉草稿
        let adopted = m.adoptExternal("重切后的新文本")
        #expect(!adopted)
        #expect(m.draft == "用户手改未保存", "脏草稿必须保留，不得被外部值覆盖")
        #expect(m.isDirty, "拒绝后仍是脏态，等待用户保存/还原收口")
    }

    @Test("reset 丢弃脏草稿并以新值重建镜像")
    func resetClearsDraft() {
        var m = InspectorDraftMirror(source: "甲")
        m.edit("脏草稿")
        m.reset(to: "乙")
        #expect(m.draft == "乙")
        #expect(!m.isDirty)
    }

    @Test("didCommit 保存成功：基准与草稿都落为提交值，重新变干净")
    func didCommitRebases() {
        var m = InspectorDraftMirror(source: "甲")
        m.edit(" trimmed ")
        m.didCommit("trimmed")
        #expect(m.draft == "trimmed")
        #expect(!m.isDirty)
    }

    @Test("完整生命周期：编辑→外部更新被拒→还原→重新具备跟随能力（非一次性门锁）")
    func lifecycleRecovers() {
        var m = InspectorDraftMirror(source: "甲")
        m.edit("改")
        let rejected = m.adoptExternal("乙")
        #expect(!rejected)
        m.reset(to: "乙")
        // 还原之后再次外部更新必须恢复跟随（区别于 didLoad 一次性门锁）
        let adopted = m.adoptExternal("丙")
        #expect(adopted)
        #expect(m.draft == "丙")
        #expect(!m.isDirty)
    }

    @Test("值语义：副本修改不影响原值（Sendable 值类型契约）")
    func valueSemantics() {
        let a = InspectorDraftMirror(source: "甲")
        var b = a
        b.edit("乙")
        #expect(a.draft == "甲")
        #expect(!a.isDirty)
        #expect(b.draft == "乙")
        #expect(b.isDirty)
    }

    @Test("连续外部切片：干净态逐次跟随（模拟 reExtractText 连续触发）")
    func consecutiveExternalSlices() {
        var m = InspectorDraftMirror(source: "甲")
        let r1 = m.adoptExternal("甲乙")
        let r2 = m.adoptExternal("甲乙丙")
        #expect(r1 && r2)
        #expect(m.draft == "甲乙丙")
        #expect(!m.isDirty)
    }

    @Test("提交后遇到等值外部更新不标记脏，随后异值仍可跟随")
    func commitThenExternal() {
        var m = InspectorDraftMirror(source: "甲")
        m.edit("甲乙")
        m.didCommit("甲乙")
        let r1 = m.adoptExternal("甲乙")
        #expect(r1)
        #expect(!m.isDirty)
        let r2 = m.adoptExternal("甲乙丙")
        #expect(r2)
        #expect(m.draft == "甲乙丙")
    }
}
