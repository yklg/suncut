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

## 〔2026-11-04 新增〕同步目录 target 不适用"三段齐全"，反手钉一条反向判据

本判据原先把 `MixCutAppTests/` 也当成"每颗 .swift 都要手工登记"的目录，于是**假红**过一次：
`FolderMixCategoryLimitTests.swift` 报"出现 0 次 ⇒ 漏登记"，我据此手工补了一段登记，
把 pbxproj 改完后**反向确认**（还原＋重跑 App 腿）才发现那颗文件本来就在跑：
54 passed／0 failed，日志里有 `Compiling FolderMixCategoryLimitTests.swift`，
而它登记数为 0。⇒ 补登记不但多余，还多响一条 `Skipping duplicate build file`。

根因在工程自己的结构里：`MixCutAppTests` 这颗 target 声明了
`fileSystemSynchronizedGroups`，对应一颗 `PBXFileSystemSynchronizedRootGroup`
（`path = MixCutAppTests`）—— Xcode 按**目录**收文件，目录里新增一颗就自动进编译单元，
**不需要**也**不该**手工登记。`MixCut`（App target）没有同步组，
所以 Core／App 侧文件仍然必须四段齐全（判据 ②③④ 一条不放宽）。

于是加两条：
- **判据 ⑤′（豁免）**：落在同步目录里的文件不再要求登记段数。
  豁免只按"该目录是否真的是某颗 target 的同步组"判，硬编码目录名一律不算。
- **判据 ⑥（反向）**：同步目录里**已被手工登记**的文件必须逐条在册（`SYNC_REGISTERED`），
  多一颗少一颗都红。2026-11-04 已把历史存量 10 颗从工程里摘掉（连同那个与同步组指向同一目录的
  空经典组），名册于是为空 ⇒ 今天它是一条**禁令**：同步目录里不许有手工登记。
  名册写成"等式"而不是"不许有"，是为了将来真出现同步组时（target 改回经典分组那种）
  不需要重写判据，只需要如实登记在册 —— 两个方向都红，才不会挂成一张只准涨的表。
- **判据 ⑦（防判据失效，三格）**：a) 工程里有同步组条目却解析不出"哪颗 target 声明了它"；
  b) 解析出的同步目录在磁盘上不存在；c) 解析不出同步组而名册说有其文件 ⇒ 一律报"判定链已断"、
  退 1，不判通过。⑦a 是清场之后仍然有效的那一格（它不依赖名册非空）——否则解析一坏，
  ⑤′ 会静默变回"要求登记"（假红回来）、⑥ 会静默遍历空集（恒绿），两种都是最难发现的那种坏。
"""
import io
import os
import re
import sys

# `PBX_PATH` 只给台架用（指一棵合成工程），用来证明 ⑤′⑥⑦ 真会红，而不是恒绿。
PBX = os.environ.get("PBX_PATH") or "/Users/yilukaige/mixed_cut-main/MixCut.xcodeproj/project.pbxproj"
# ⚠️ 仓库根**不能**只从 PBX 路径反推：`PBX_PATH` 指到 /tmp 下的合成工程时，反推出的根里
# 没有 `MixCutAppTests/`，⑤′⑥ 的磁盘取样面会变空 ⇒ ⑦ 会报"同步目录不存在"这种归因错的假红
# （2026-11-04 实测踩到）。所以要单独给一颗 `PROBE_ROOT`：工程正文是合成的，磁盘仍是真仓库。
ROOT = os.environ.get("PROBE_ROOT") or os.path.dirname(os.path.dirname(PBX))

# 同步目录里**已被手工登记**的文件名册。
# 2026-11-04 实测清场：原来在册的 10 颗（每构建一次各响一条 `Skipping duplicate build file`）
# 已从 pbxproj 摘除，连同那个与同步组指向同一目录的空经典组一起删 ⇒ 名册现在是**空的**。
# 空名册的含义是**禁令**：同步目录里的文件一颗都不许手工登记。
# 往这里加名字的唯一正当场景，是工程把某颗 target 从同步组改回了经典分组 —— 那种改动要连着
# 改 `sync_group_dirs` 的口径与本条判据，不是随手登记一颗就完事。
SYNC_REGISTERED: set = set()

# 本轮新增的两个文件（作为回归样本；后续新增文件请追加到EXPECTED ——
# ⚠️ 但**只限必须登记的目录**：同步目录里的文件不许往这里加，判据 ②③④ 会反过来
#    要求那颗文件永远保持冗余登记，与判据 ⑥ 的清理方向打架。）
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
             # 〔2026-11-04 从本名册移出〕这颗在**同步目录**里，登记与否不影响它被编译；
             # 留在这里会让判据 ②③④ 反向要求它"永远保持冗余登记"，与判据 ⑥ 的清理方向打架。
             # 它的守恒改由判据 ⑥ 的名册负责（在册 = 承认它今天确实被登记了）。
             ]


def sync_group_dirs(text: str):
    """解析 pbxproj 里"某颗 target 声明的同步目录"集合（按目录名，与磁盘顶层目录同名）。

    ⚠️ 逐行匹配，不用 `.*?` 跨条目：一颗同步组的正文里有 `explicitFileTypes = {};` 与
    `explicitFolders = ();` 两对花括号，任何"`[^}]*` 到 `path =` 为止"的写法都会在第一个
    `}` 处断掉 —— 我第一版就是这么解析出**空集**的，而空集会让判据 ⑦ 以为"这工程没有同步组"。
    """
    by_id = {}
    for line in text.splitlines():
        m = re.search(r"([0-9A-F]{24}) /\* .*? \*/ = \{isa = PBXFileSystemSynchronizedRootGroup;"
                      r".*?path = ([^;]+);", line)
        if m:
            by_id[m.group(1)] = m.group(2).strip().strip('"')
    dirs = set()
    for m in re.finditer(r"([0-9A-F]{24}) /\* .*? \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};",
                         text, re.S):
        fsg = re.search(r"fileSystemSynchronizedGroups = \((.*?)\);", m.group(2), re.S)
        if not fsg:
            continue
        for oid in re.findall(r"([0-9A-F]{24})", fsg.group(1)):
            if oid in by_id:
                dirs.add(by_id[oid])
    return dirs


def registered_names(text: str):
    """任何 Sources phase 里出现的文件名（用于与同步目录求交 ⇒ 手工登记的存量名册）。"""
    return set(re.findall(r"/\* ([\w.]+\.swift) in Sources \*/ = \{isa = PBXBuildFile", text))



def analyze(text: str, root: str) -> int:
    """全部判据都吃"工程正文 + 仓库根"，这样 `--selftest` 的合成工程与真工程走**同一条**代码。

    ⚠️ 不许给 selftest 另写一份简化判定：那样台架绿证明的是另一份实现，判据本身照样能坏。
    """
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

    # —— 判据 ⑤′／⑥／⑦：登记守恒 + 同步组目录 ——
    # ⑤ 的原意不变：把「记得往 EXPECTED 里追加」变成机械闸，以文件系统为真源逐颗查登记段数，
    # 名册只当"重点样本"留着。但"该不该要求登记"必须按**工程结构**判，不是按目录名硬编码。
    sync = sync_group_dirs(text)
    sync_root_defs = len(re.findall(r"isa = PBXFileSystemSynchronizedRootGroup", text))
    sync_on_disk = {d for d in sync if os.path.isdir(os.path.join(root, d))}
    # ⑦a：工程里明明有同步组条目，却解析不出"哪颗 target 声明了它" ⇒ 声明侧的解析坏了。
    # 这一条**不依赖名册非空**（清掉冗余登记之后名册是空的，那时只有这里还能发现解析链断了）。
    if sync_root_defs and not sync:
        print("FAIL[判据失效] 工程里有 %d 颗 PBXFileSystemSynchronizedRootGroup 条目，"
              "却解析不出任何 target 声明它们 ⇒ 判定链已断，不判通过" % sync_root_defs)
        return 1
    # ⑦b：解析出的同步目录在磁盘上不存在 ⇒ 取样面与工程对不上，读数全部作废
    if sync and len(sync_on_disk) != len(sync):
        print("FAIL[判据失效] 解析出的同步目录有 %d 颗在磁盘上不存在：%s ⇒ 解析错位，⑤′⑥ 的读数全部作废"
              % (len(sync - sync_on_disk), sorted(sync - sync_on_disk)))
        return 1
    # ⑦c：解析不出同步组而名册说"有文件躺在同步目录里" ⇒ 同样只可能是解析坏了
    if not sync and SYNC_REGISTERED:
        print("FAIL[判据失效] 解析不出任何同步组目录，但名册里有 %d 颗同步目录文件 ⇒ 判定链已断，不判通过"
              % len(SYNC_REGISTERED))
        return 1


    # ⑤′：只对"必须登记"的目录要求四段齐全
    must_register = [("Sources/MixCutCore", True)]
    for d in sorted(sync_on_disk):
        must_register.append((d, False))          # 同步目录：按目录收文件，登记反而制造重复
    # 非同步的测试目录若存在，仍要登记（保持旧行为，不因这次改动而放宽）
    if "MixCutAppTests" not in sync_on_disk and os.path.isdir(os.path.join(root, "MixCutAppTests")):
        must_register.append(("MixCutAppTests", True))

    counted, exempted = [], []
    for rel_dir, needs in must_register:
        base = os.path.join(root, rel_dir)
        if not os.path.isdir(base):
            continue
        for n in sorted(x for x in os.listdir(base) if x.endswith(".swift")):
            # 整词计数：`RawAudioCache.swift` 不得被 `RawAudioCacheStore.swift` 的出现次数冒充
            hits = len(re.findall(r"(?<![A-Za-z0-9_])%s" % re.escape(n), text))
            (counted if needs else exempted).append((n, rel_dir, hits))

    thin = [(n, d, c) for n, d, c in counted if c < 4]
    if thin:
        print("FAIL 需登记的目录里有 %d 颗文件不足 4 段（漏登记 = 只有真机 xcodebuild 才红）:" % len(thin))
        for n, d, c in thin:
            print("     %s（%s）出现 %d 次" % (n, d, c))
        fail = 1
    else:
        print("PASS 需登记目录全量：%d 颗 .swift 全部 ≥4 段；同步目录豁免 %d 颗（不要求登记）"
              % (len(counted), len(exempted)))

    # ⑥ 反向判据：同步目录里"已被手工登记"的文件必须**恰好**是名册那一批
    registered = registered_names(text)
    in_sync_registered = sorted({n for n, d, _ in exempted if n in registered})
    missing_from_roster = sorted(set(in_sync_registered) - SYNC_REGISTERED)   # 新涨出来的
    roster_but_unregistered = sorted(SYNC_REGISTERED - set(in_sync_registered))  # 已清掉却没改名册
    if missing_from_roster:
        print("FAIL[⑥] 同步目录里冒出 %d 颗**新的**手工登记（不在名册）：%s"
              % (len(missing_from_roster), missing_from_roster))
        print("     同步组本来就按目录收文件，手工补登记只会让它进两遍 ⇒"
              " 每构建一次多响一条 `Skipping duplicate build file`")
        fail = 1
    if roster_but_unregistered:
        print("FAIL[⑥] 名册里 %d 颗已不再登记：%s ⇒ 清掉冗余项的那一笔必须同轮把 SYNC_REGISTERED 改小"
              % (len(roster_but_unregistered), roster_but_unregistered))
        fail = 1
    if not missing_from_roster and not roster_but_unregistered:
        print("PASS[⑥] 同步目录内的手工登记存量与名册逐颗一致（%d 颗，多一颗少一颗都红）"
              % len(SYNC_REGISTERED))

    return fail


def read_pbx(path: str) -> str:
    with io.open(path, encoding="utf-8") as f:
        return f.read()


def selftest() -> int:
    """四格台架：⑤′ 的放行侧与反向、⑥ 的禁令、⑦a 的失效，四格都要能指出红点归因。

    全部走 `analyze()` 这一条实现，不另写简化判定；红还不够，红必须红在**那一格判据的原文**上
    （否则是隔壁判据坏了冒充这条腿）。合成工程 = 真工程正文改一处，磁盘取样面仍是真仓库。
    """
    text = read_pbx(PBX)
    cases, rig_broken = [], False

    # 造两颗不与现网相撞的 24 位 ID（撞了会让判据 ① 先红，读数就归不到 ⑥ 头上）
    used = set(re.findall(r"[0-9A-F]{24}", text))
    fresh = [i for i in ("F" * 23 + s for s in "0123456789ABCDEF") if i not in used]
    if len(fresh) < 2:
        print("FAIL 台架造不出空闲 ID ⇒ 格2 无对照物")
        return 1
    bid, frid = fresh[0], fresh[1]

    # 格 1：⑤′ 的豁免 —— 往同步目录里放一颗**没登记**的文件，整条判定仍须为绿。
    # 这一格就是 2026-11-04 那起假红的合成复现：改之前它会红在"出现 0 次"。
    probe1 = "ZzzProbeSyncDir.swift"
    with open(os.path.join(ROOT, "MixCutAppTests", probe1), "w") as f:
        f.write("// 台架临时文件，跑完即删\n")
    try:
        cases.append(("格1 同步目录新增一颗未登记的文件 ⇒ 仍须绿（⑤′ 生效）",
                      _run(text), "绿", "无红点"))
    finally:
        os.remove(os.path.join(ROOT, "MixCutAppTests", probe1))

    # 格 2：⑥ 往上 —— 同步目录里多出一颗手工登记（不在名册）⇒ 必须红
    probe2 = "ZzzProbeAlsoRegistered.swift"
    bf = ('\n\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; }'
          % (bid, probe2, frid, probe2))
    mutated = text.replace("\n/* End PBXBuildFile section */",
                           bf + "\n/* End PBXBuildFile section */", 1)
    if mutated == text:
        rig_broken = True
        print("FAIL 台架前置：插不进那颗合成 PBXBuildFile ⇒ 格2 无对照物")
    with open(os.path.join(ROOT, "MixCutAppTests", probe2), "w") as f:
        f.write("// 台架临时文件，跑完即删\n")
    try:
        cases.append(("格2 同步目录新涨一颗手工登记 ⇒ ⑥ 必须红",
                      _run(mutated), "红", "[⑥]"))
    finally:
        os.remove(os.path.join(ROOT, "MixCutAppTests", probe2))

    # 格 3：⑤′ 的反向 —— 必须登记的目录（Core）里摘掉一颗的四段 ⇒ 仍须红。
    # 这一格守的是"豁免别长成'全部免检'"：清掉同步组的假红之后，如果只留下 ⑤′ 的放行侧，
    # 判据就退化成恒绿。挑一颗**不在 EXPECTED 里**的 Core 文件，这样红只能来自 ⑤′ 的全量扫描。
    core_all = {n for n in os.listdir(os.path.join(ROOT, "Sources", "MixCutCore"))
                if n.endswith(".swift")}
    cand = sorted(core_all - set(EXPECTED))
    probe3 = cand[0] if cand else None
    if probe3 is None:
        rig_broken = True
        print("FAIL 台架前置：找不到一颗不在 EXPECTED 里的 Core 文件 ⇒ 格3 无对照物")
    else:
        fid3 = re.findall(r"([0-9A-F]{24}) /\* %s \*/ = \{isa = PBXFileReference" % re.escape(probe3), text)
        bid3 = re.findall(r"([0-9A-F]{24}) /\* %s in Sources \*/ = \{isa = PBXBuildFile" % re.escape(probe3), text)
        if len(fid3) != 1 or len(bid3) != 1:
            rig_broken = True
            print("FAIL 台架前置：%s 的 fileRef/buildFile id 取不到唯一值 ⇒ 格3 无对照物" % probe3)
        else:
            kept3, cut3 = [], 0
            for ln in text.splitlines(keepends=True):
                if bid3[0] in ln or fid3[0] in ln:
                    cut3 += 1
                    continue
                kept3.append(ln)
            if cut3 != 4:
                rig_broken = True
                print("FAIL 台架前置：%s 摘掉的是 %d 行而不是 4 段 ⇒ 格3 无对照物" % (probe3, cut3))
            else:
                cases.append(("格3 必须登记的 Core 目录里摘掉一颗的四段 ⇒ 须红（⑤′ 的放行是条件的）",
                              _run("".join(kept3)), "红", "不足 4 段"))

    # 格 4：⑦a 失效 —— 抹掉 target 的 fileSystemSynchronizedGroups 声明（同步组条目仍在工作区里）
    # ⇒ 工程有同步组却没人声明它，必须报"判据失效"而不是判通过。
    # 这一格是**清场之后仍然有效**的那格：它不依赖名册非空（名册今天已经是空的）。
    no_sync = re.sub(r"\n[ \t]*fileSystemSynchronizedGroups = \([^)]*\);", "", text, count=1)
    if no_sync == text:
        rig_broken = True
        print("FAIL 台架前置：抹不掉 fileSystemSynchronizedGroups ⇒ 格4 无对照物")
    else:
        cases.append(("格4 有同步组条目却解析不出声明它的 target ⇒ 报判据失效、不判通过",
                      _run(no_sync), "红", "判据失效"))

    bad = 0
    for name, (rc, out), expect, reason in cases:
        got = "绿" if rc == 0 else "红"
        ok = (got == expect) and (expect == "绿" or reason in out)
        # 红还不够：必须红在**那一格判据**上，否则是隔壁坏了冒充这条腿（本仓纪律：不许因错误原因通过）
        print("%s %s（期望%s，实得%s，rc=%s，红点归因：%s%s）"
              % ("PASS" if ok else "FAIL", name, expect, got, rc, reason,
                 "" if ok or expect == "绿" else " ← 读数里找不到这条判据的原文"))
        if not ok:
            bad = 1
    if rig_broken:
        print("FAIL 台架前置本身取不到被改对象 ⇒ 这几格无对照物，自测不算通过")
        bad = 1
    print("自测：判据 ⑤′⑥⑦ 共 %d 格" % len(cases))
    return bad


def _run(text: str):
    """跑一遍判定，同时把输出留下 —— 台架要能核对"红在哪条判据上"，只回 rc 不够。"""
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = analyze(text, ROOT)
    return rc, buf.getvalue()


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    return analyze(read_pbx(PBX), ROOT)


if __name__ == "__main__":
    sys.exit(main())
