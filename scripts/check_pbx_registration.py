#!/usr/bin/env python3
"""pbxproj 登记自检：把「本轮真机 xcodebuild 才暴露的三类登记错误」变成机械判据。

本轮实测事故（M3 登记 RawAudioCacheStore.swift + RawAudioCache.swift 时连踩三次，
沙盒typecheck/silgen 全绿、真机 xcodebuild 三次才红）：

1. **ID 冲突**：新文件抢用了已被别的文件占用的 ID（如 0042 已是 VoicePickerSheet）
   → Xcode 判定两者同一文件 → 新文件被踢出编译单元 + 另一文件报
   「member of multiple groups」+「Skipping duplicate build file」。
   最阴险的地方：新文件本身**不报任何错**，是**别的文件**报 "cannot find type"。

2. **Core 文件漏登记**：本工程 Core 不是纯 SwiftPM 包，MixCut target 直接编译
   Sources/MixCutCore/*.swift ⇒新增 Core 文件同样必须四段登记。

3. **path 基准错**：Core 的 PBXFileReference 必须写
   `name = X.swift; path = Sources/MixCutCore/X.swift`（显式全路径），
   只写 `path = X.swift` 会让Xcode 去仓库根目录找 → "Build input file cannot be found"。

判据：新增文件必须满足 ① ID 唯一 ② 四段齐全 ③ path 与所在组匹配。
"""
import io
import os
import re
import sys

PBX = "/Users/yilukaige/mixed_cut-main/MixCut.xcodeproj/project.pbxproj"
ROOT = os.path.dirname(os.path.dirname(PBX))
# 本轮新增的两个文件（作为回归样本；后续新增文件请追加到EXPECTED）
EXPECTED = ["RawAudioCacheStore.swift", "RawAudioCache.swift", "SegmentCommitter.swift",
             "SegmentationPlanner.swift", "SegmentationPlanSettings.swift",
             "LocalWhisperGate.swift", "AIThinkingPolicy.swift", "AIUsageRecord.swift",
             "AIModelPricing.swift", "NarrativeContinuity.swift", "SegmentSplitRule.swift",
             # 方案 kindled-cloud-robin.md 批 1（2026-10-10 登记）：漏登记的典型症状最阴 ——
             # 沙盒 typecheck 按文件系统扫，看不出漏登记；只有 xcodebuild 会报**别的文件** cannot find type。
             "MissingMaterialFinder.swift", "VideoDeletionScopeResolver.swift",
             # 批 4（2026-10-14）：App 侧那个文件在 MixCut/Infrastructure/ 子目录里 ——
             # register_pbx_file.py 早先只查 MixCut 顶层，子目录里的真文件会被判成"拼写错了"。
             "MissingMaterialCopy.swift", "MaterialAvailabilityStore.swift",
             # 批 5（2026-10-19）：导出画布尺寸的唯一真源。它一旦被踢出编译单元，
             # 报 cannot find type 的会是 ExportService / DubExportService，而不是它自己。
             "DeliverySpec.swift",
             # 文件夹混剪 Step 1（2026-10-20）：三颗 Core 纯逻辑。被踢出编译单元时
             # 报 cannot find type 的是 ImportView / MixCutApp / ImportViewModel（它们已改成调用方），
             # 而不是这三颗自己 —— 正是本脚本要防的那种"报错点离根因隔一层"。
             "FolderMixScanner.swift", "FolderMixPicker.swift", "DiskSpaceBudget.swift",
             # Step 2/3（2026-10-20）：首跑清段判据 + 混剪唯一 IO 面。后者在 MixCut/Services/Import/
             # 子目录里（App 侧按功能分组，登记沿模板走组内裸名），漏登记时 ImportViewModel 报
             # cannot find 'MaterialFolderScanner' —— 报错点隔了一层。
             "WholeClipShape.swift", "MaterialFolderScanner.swift",
             # Step 5（2026-10-20）：混剪的编排层与页面。两颗都是 **App 侧文件**（走组内裸名 path），
             # 且 View 只能落在 `MixCut/Views/Import/` —— register_pbx_file.py 只会"沿模板插入同一个组"，
             # 而 path 是相对组路径解析的：新建 `Views/FolderMix/` 目录会让 Xcode 去旧组路径找文件，
             # 症状是 "Build input file cannot be found"（本仓为登记问题连红过三次，见脚本 docstring）。
             "FolderMixViewModel.swift", "FolderMixView.swift",
             # 计划 2026-10-22 笔 J2：App 腿第一颗混剪判据（真实往返）。它被踢出编译单元时
             # 症状不是"少一条测试"，而是那条接缝重新变成没人跑过 —— 正是这次缺陷的原形。
             "FolderMixIngestJoinTests.swift"]


def main() -> int:
    with io.open(PBX, encoding="utf-8") as f:
        text = f.read()
    fail = 0

    # —— 判据 ①：任何 24 位 ID 不得被两个不同文件名共用 ——
    # 覆盖**所有** 24 位 ID：只认 A[EFCD] 手工段的话，老式无前缀 ID 的冲突没人看得到
    ids = re.findall(r"\b([0-9A-F]{24})\s+/\* ([^*]+?) \*/", text)
    by_id = {}
    for full, name in ids:
        by_id.setdefault(full, set()).add(name.strip())
    dups = {k: sorted(v) for k, v in by_id.items() if len(v) > 1}
    if dups:
        print("FAIL 存在 ID 冲突（一个 ID 被多个文件共用 ⇒ 新文件会被踢出编译单元）:")
        for k, v in dups.items():
            print("     %s → %s" % (k, v))
        fail = 1
    else:
        print("PASS pbxproj ID 唯一（无一个 ID 被多个文件共用）· 共 %d 个" % len(by_id))

    # —— 判据 ②③④：每个新增文件四段齐全 + path 正确 ——
    for name in EXPECTED:
        hits = text.count(name)
        if hits < 4:
            print("FAIL %s 四段登记不完整（出现 %d 次< 4）" % (name, hits))
            fail = 1
            continue
        # Core 文件：path 必须指向 Sources/MixCutCore/
        if "/" not in name:
            pass
        ref = re.search(r"[0-9A-F]{24} /\* %s \*/ = \{isa = PBXFileReference;([^}]*)\}" % re.escape(name), text)
        if not ref:
            print("FAIL %s 缺 PBXFileReference 段" % name)
            fail = 1
            continue
        body = ref.group(1)
        # path 基准取决于**所在组**：App 侧文件在 Services/TTS 组（组自带 path），
        # 裸文件名正确；Core 组没有 path 基准，必须写全路径 Sources/MixCutCore/<名>。
        # 判别方式：看该FileReference 的 path 是裸名还是带目录。
        m = re.search(r"path = ([^;]+);", body)
        path_val = m.group(1).strip() if m else ""
        if not path_val:
            print("FAIL %s 缺 path" % name)
            fail = 1
            continue
        is_core = "MixCutCore" in path_val
        if is_core:
            # Core：必须绝对定位到 Sources/MixCutCore/ 下
            if not path_val.startswith("Sources/MixCutCore/"):
                print("FAIL %s 的 path 未指向 Sources/MixCutCore/：%s" % (name, path_val))
                fail = 1
                continue
            if "name = %s;" % name not in body:
                print("FAIL %s 缺 name 字段（Core 组无 path 基准时 name 必填）" % name)
                fail = 1
                continue
        else:
            # App 侧：裸文件名（靠所在组的 path 解析），若写了目录反而可能错位
            if "/" in path_val:
                print("WARN %s 的 path 带目录（%s）—— 确认是否与所在组 path 重复拼接"
                      % (name, path_val))
        print("PASS %s 四段齐全且 path 正确（%s）" % (name, path_val))

    # —— 判据 ⑤：全量扫描面 —— 把「记得往 EXPECTED 里追加」变成机械闸 ——
    # EXPECTED 是手工名册：新增 Core 文件时忘了追加，判据 ②③④ 就永远看不到那颗漏登记的，
    # 而漏登记的症状是**别的文件**报 cannot find type（沙盒 typecheck 按文件系统扫，看不出来）。
    # 这里直接以文件系统为真源逐颗查登记段数，名册只当"重点样本"留着。
    core_dir = os.path.join(ROOT, "Sources", "MixCutCore")
    core_files = sorted(n for n in os.listdir(core_dir) if n.endswith(".swift"))
    # App 测试目录同一条道理：漏登记不会让 xcodebuild 报"这个文件没进 target"，
    # 只会让那条判据**从未跑过**（读测试报告的人看见的是"全绿"）。
    app_test_dir = os.path.join(ROOT, "MixCutAppTests")
    core_files += sorted(n for n in os.listdir(app_test_dir) if n.endswith(".swift"))
    # 整词计数：`RawAudioCache.swift` 不得被 `RawAudioCacheStore.swift` 的出现次数冒充
    thin = [(n, len(re.findall(r"(?<![A-Za-z0-9_])%s" % re.escape(n), text)))
            for n in core_files]
    thin = [(n, c) for n, c in thin if c < 4]
    if thin:
        print("FAIL Core 目录有 %d 颗文件登记不足 4 段（漏登记 = 只有真机 xcodebuild 才红）:" % len(thin))
        for n, c in thin:
            print("     %s 出现 %d 次" % (n, c))
        fail = 1
    else:
        print("PASS Core + App 测试全量登记：%d 颗 .swift 全部 ≥4 段（不依赖手工名册）" % len(core_files))

    return fail


if __name__ == "__main__":
    sys.exit(main())