# 追平上游 0.12.x 可移植面 · 实施计划 v3（2026-09-30）

目标：把上游 v0.12.0～v0.12.5 发布说明里**这份 Swift 工程真能落地**的功能，按批做进 SunCut。
已拍板：**① 跟到 B+C 档**（D 档见 §1.2，其中 D2 已拆出来要做）；**② 批 0 先补 SwiftData `VersionedSchema`
与改前备份门 + 启动步骤账本**，再让任何一条 C 档动 schema。

> **v1 经 `architecture-first-fix` 评审判「需返工」**（4 条 P0：根因停早一层 / 缓解冒充根治 / 清单一致性无防线 /
> "不做"档吞掉可修层）→ v2 全接。
> **v2 再经 `tech-solution-review` 评审判「有条件落地，批 0 不可开工」**（3 条 P0）。v3 按此重写批 0 与批 1/3 分档：
> **R1** 拒开库的落点是既有"删库降级分支**（`MixCutApp.swift:176-187`）⇒ 开库结果三态化，拒绝路径禁止出现"删除 store"；
> **R2** 账本只定义了"该不该跑/顺序对不对"，**没定义"某颗失败后要不要继续"**，而链下游是删文件的孤儿 GC ⇒ 加 `onFailure` + `blocked`；
> **R3** 批 1.2「无字幕」被标"零 schema / 1 天"，实测底层两字段编码**只有三态可表达** ⇒ 移出批 1，进批 3 的 schema 轮。
> 另并入 P1 五条：账本合一、备份校验与保留、闪屏回归判据入批 0、MCP 契约清单补全、脱敏定档。

## 0. 证据等级

| 侧 | 证据强度 | 说明 |
|---|---|---|
| **上游 0.12.x 功能细节** | ⚠️ **仅发布说明** | tag `v0.12.5` 指向 commit `7dc9af1a`（= 0.11.0 代码，2026-07-30 05:14:06Z），release **未挂任何源码资产** ⇒ 交互细节、算法参数、边界行为**不可对照** |
| **现工程现状与缺口** | ✅ 实读 `文件:line` | 13 条经二次抽验，含本轮新增的 `MixCutApp.swift:176-187`、`:596`、`DubEnums.swift:66,95-98`、`SegmentLibraryView.swift:986`、`SubtitleMaskMode.swift:15-20` |
| **"要不要新内核"的判断** | 🔶 架构推断 | 按功能描述 + 本机架构（单机 SwiftData + 子进程 ffmpeg + 云端 AI）推 |

**纪律性推论**：每条功能动手前必须先写死**我们自己的验收判据**（§4「判据」列）。

## 1. 分档结论

### 1.1 A 档 · 已经有了，不排期（9 条）

语义单元切分+类型/关键词/质量分（`AIAnalysisService.swift:320,357,413-427` → `Segment.swift:75-83`）·
边界四级择优帧级量化（`BoundaryAlignmentEngine.swift:155-189,119-121`）· ±帧微调即时回放与定格末帧
（`SegmentLibraryViewModel.swift:385-402`、`SegmentLibraryView.swift:1450,1500-1510`）· 字级时间戳与逐字进出
（`ASRService.swift:581-594`、`SegmentLibraryViewModel.swift:375-418`）· 分镜严格等台词（`AIAnalysisService.swift:215`
+ `SegmentationCompleteness.swift:42-54`）· 方案卡悬停播放含改写配音静音播那版（`SegmentLibraryView.swift:1258,1455-1457`）·
方案卡上直接选配音（`SchemeDetailView.swift:474-499`）· AI 换画面与配音克隆（`Wan25VideoEditClient`、`VoiceCloneService`）·
分镜库多选批量与 ⌘Z 成组撤销（`SegmentLibraryViewModel.swift:101,141,196,500`、`SchemeViewModel.swift:257-263`）。

> 0.12.0 那份清单读起来像新功能，其实是**重写公告把 0.7~0.11 的既有能力重新描述了一遍**。真实增量只在 0.12.1~0.12.5。

### 1.2 D 档

| 项 | 判定 |
|---|---|
| **D1 分镜不再跨项目共享** | **不做**。牵动 `video_no`/`segment_no` 契约、`SegmentExportExpander` segmentKey 与导出文件名、`DubStaleness` 快照、缩略图唯一性、3 处测试 + `check_association_guards.sh`，且推翻已拍板的「同素材重复使用走第一种」。**重定契约，不是移植** |
| **D2 拦截提示语与可达路径不符** | **做，进批 2（2.7）**。`ImportViewModel.swift:1215` 让用户"先从方案中移除它"，而挡它的方案可能在别的项目里，用户当前项目找不到也删不掉 |
| 换音色不丢感情的"情绪/语调" | **不做**。`CosyVoiceTTSClient.swift:20` 只暴露 `rate` ⇒ 卡在 DashScope 模型侧。语速那半留批 4 |
| 双端 / 服务端形态 | **不做**。属我们自己未拍板的 A/B 分叉 |

## 2. 排批与顺序理由

| 批 | 内容 | 动 schema | 规模（估算，非承诺） |
|---|---|---|---|
| **0** | 启动步骤账本（含失败传播）+ VersionedSchema + 改前备份门（含**拒开库三态化**）+ 一致性守卫 + 修 CLAUDE.md | 不改结构，只加锚点与账本 | **6~7 天**（v2 的 5~6 天 + R1/R2 补强） |
| **1** | 时间码三段直输 · ⌘Z 宽限 5s→5min · 悬停角标 · 方案变体多选 · 方向键移卡 | 否 | **3~4 天**（1.2 移出） |
| **2** | BGM 多选随机均分 · 配音「停止」· 裂图进诊断 · 报错落盘+**写入时**脱敏 · 自建分镜补质量分 · D2 说清真凶 | 否 | 5~6 天 |
| **3** | 方案批次分组 + 组合级去重 · AI 产物花费标注 · **字幕第四档「无字幕」（R3 移入，含编码重做）** | **是** | **9~11 天** |
| **4** | AI 校对错别字（顺带修 `TextProvenance` 手改被盖）· 英文整条链路 | 否（枚举扩档走字符串列） | 10~14 天 |
| **5** | 存储位置可迁移 · 任务制重启接续 | **是**（新增 `AgentTask`） | 12~15 天 |

顺序被三件事钉住：批 3/5 真动 schema，必须有批 0 的锚点、账本与回退点；**字幕第四档现在也属批 3**（它要重做编码）；
批 4 的英文链路动四个 Core 模块 + 4 套测试，放太前会挤掉快赢。

## 3. 批 0 明细（v3 重写 R1/R2 两处）

### 3.1 根因

`MixCutApp` 启动链挂着 **19 颗一次性 fixup/迁移**，账本是散落的 `UserDefaults` bool
（`didFixMissingSemanticTypes_v1:339`、`didPurgeLegacyQwenDubs_v1:382`、`didPurgeLongRefClones_v1:418`、
`didResetSchemeDubSelection_v1:440`、`didDedupProjectVideoAssociations_v1:469`、`didBackfillSegmentFrames_v1:493`、
`didCleanTranscripts_v1:516`、`didMigrateProjectVideo_v1:584`、`didEnsureCustomGroupStrategy_v1:729`、
`didRegenerateSegmentThumbnailsToFirstFrame_v1:768`、`didRecoverFromDisk_v1:939`，加节流键 `lastOrphanGCAt:1169`），
**执行顺序只写在注释里靠人记**（`:23-24`、`:58-59`、`:68-69`）。

⇒ 根因是：**"数据形状变更"被实现成"启动时再挂一颗一次性函数 + 再发明一个 bool"**。
`CLAUDE.md:416` 自陈无 VersionedSchema、清库后只能靠 `recoverFromDisk()` 从视频反推（台词/方案/配音变体全拿不回）；
`CLAUDE.md:413` 教的备份命令指向 4 月 21 日的 73KB 死库 `default.store`，真库是 `Suncut/Suncut.store`（348KB，WAL 今天 13:49 还在写）——**照文档执行 = 假保险**。

批 0 做四件事：0-A 账本（消根因）· 0-B 版本锚点 + 改前备份门 + 拒开库（消"清库无退路"）·
0-C 清单一致性守卫（消"漏注册静默丢表"）· 0-D 文档纠偏（消假保险）。

### 3.2 0-A 启动步骤账本（v3 加失败传播）

**Core 侧纯函数** `Sources/MixCutCore/LaunchStepLedger.swift`：

```
enum StepCadence: Equatable { case once(key: String), everyLaunch, throttled(key: String, hours: Double) }
enum StepFailure: Equatable { case haltChain, continueWithWarning }     // ← v3 新增（R2）
struct LaunchStep: Equatable { id: String; cadence: StepCadence
                               requires: [String]; onFailure: StepFailure }
enum StepVerdict: Equatable { case run, skipAlreadyDone, skipNotYetDue,
                              blocked(missing: [String]) }              // ← v3 强化
func decideStep(step: LaunchStep, done: Set<String>, succeeded: Set<String>,
                lastRunAt: [String: Date], now: Date) -> StepVerdict
func validateOrder(_ steps: [LaunchStep]) -> [String]
```

三条硬规定（本轮评审的直接产物）：

1. **`requires` 未成功 ⇒ `blocked`，该步不跑。** 不只是"顺序在后"，而是"前序失败就停"。
   判据落点：孤儿 GC（`MixCutApp.swift:596` 的未引用判据是 `$0.projectVideos.isEmpty`）与
   `purgeStaleTempFiles` 两颗必须 `requires` 全部迁移/恢复步骤 —— 否则 `recoverFromDisk` 一失败，
   GC 就把还在磁盘上的真实素材判成孤儿**删掉**。这是数据丢失级，也是 v2 引入的新风险。
   > **落地时更正（§3.12）**：这句"未引用判据是 `$0.projectVideos.isEmpty`"取错了地方 —— 那是
   > `migrateToProjectVideoRelation` 挑孤儿视频的判据；`runOrphanGC` 的受保护集合来自**全部 `Video.localPath`**，
   > 与关联行无关。所以 GC 的 `requires` 只钉三颗有真信号的（路径改写 / 恢复 / 去重），
   > **不**把关联迁移与 `purgeStaleTempFiles` 挂成前序（那是假依赖）。数据丢失级的那条路仍成立，只是入口不同：
   > 见 §3.9 第 1、2 条与 §3.10 的正反对照。
2. **`validateOrder` 必须断言 `requires` 指向的 id 存在于清单。** 拼错的 id 若静默通过，顺序约束就退回"靠人记"，
   等于没做账本。返回非空即装配错误：DEBUG `fatalError`、Release 写日志并**跳过整轮清单**（不是跳过那一颗）。
3. **`onFailure` 逐颗显式声明**，不给默认值。现状是每颗各自吞错（`CLAUDE.md:420` 自陈"大量 `try?` 吞掉错误"），
   形式化顺序而不形式化失败传播 = 把最坏路径写进新机制。

**App 侧** `MixCut/App/LaunchSteps.swift` 按现状登记 19 颗，**`UserDefaults` 键名原样搬**（不重命名、不重置，
否则老用户会把已跑过的迁移再跑一遍）；`MixCutApp.swift:88-178` 改遍历执行。
**一颗一颗搬、每搬一颗跑一次启动 + 跑一次闪屏尺子**（`scripts/measure_nav_blank.sh`，判据沿用"逐帧 0 段"；
`CLAUDE.md:407` 记着这条方向"批六整块撤销过"）。

### 3.3 0-B 版本锚点 + 改前备份门 + 拒开库三态化（v3 重写 R1）

已落（`swift test` 9/9 绿，期望摘要值由 `shasum -a 256` 外部算得）：`SchemaFingerprint.swift`、
`SchemaFingerprintTests.swift`（TC-01~09）、`SchemaVersions.swift`（`AppSchemaV1` = 当前 10 个 `@Model`，
`AppMigrationPlan.stages` 为 `[]` 是正确状态）。备份单位是**目录**（WAL 模式只拷 `.store` 会漏已提交未 checkpoint 的事务）。

**v3 的关键修正**：现有开库失败落点是**降级分支**——`MixCutApp.swift:176-187` 的 catch 会改用
`isStoredInMemoryOnly` 容器再开一次（`:181`），再失败就 `try! ModelContainer(for: schema)`（`:182`，可崩），
并把错误文案写成「**请删除 ~/Library/Application Support/Suncut/Suncut.store 后重启应用**」。
⇒ 若"拒开库"复用这条路径，防线拦住的这一次开库，交给用户的第一条指令就是**删掉它正在保护的库**。

所以开库结果改显式三态，**且三处容器构造点（`:107`、`:181`、`:182`）一起改**：

| 结果 | 触发 | 用户看到什么 |
|---|---|---|
| `.opened` | 正常 | 照常 |
| `.degradedInMemory` | 库真的损坏（非 schema 原因） | 保留既有降级语义与文案，但 `try!` 必须换掉 |
| `.refusedBySchemaGate` | 指纹变了且无可用迁移 | **独立错误面板**：说明这次升级会改数据结构且无迁移可走；**给出备份目录完整路径 + 退回上一版的一句话**；**文案内禁止出现"删除 store"** |

| 指纹判定 | 有 `MigrationStage` 或属轻量兼容（只增可选/带默认值字段） | 动作 |
|---|---|---|
| `changed` | 是 | 备份三件套 → 校验备份 → 开库 → 成功后写回指纹 |
| `changed` | 否 | 备份三件套 → 校验备份 → **`.refusedBySchemaGate`** |
| `untrustworthy`（0 行） | — | 不写记录、不建备份、**不开库**（装配失误不得伪装成"schema 没变"） |

**备份自证**（v3 并入 P1）：备份后至少验证 `.store` 能被打开且 `PRAGMA integrity_check` 通过，
否则"可回退"只是假设；备份目录保留最近 **3** 份，超出按时间戳删最旧，份数进守卫断言。

**账本合一**（v3 并入 P1）：sidecar 一份 JSON 同时收 `fingerprint` + `doneSteps` + `lastRunAt`，
`UserDefaults` 只作兼容读（读到即回填）。否则 v2 会把"状态散落多处"这个 v1 的根因**换个地方长回来**。

### 3.4 0-C 一致性守卫 `scripts/check_schema_ledger_guards.sh`

断言：`grep -c "@Model" MixCut/Models/*.swift` == `AppSchemaV1.models` 条数 == App 侧清单条数；
`LaunchSteps` 条数 == `MixCutApp` 登记的步骤数（防有人新加一颗 `Self.xxx()` 绕过清单）；
备份目录份数 ≤ 3；GC 与 `purgeStaleTempFiles` 两颗的 `requires` 非空。
纪律：取样面**排除 `Resources/bin`**（否则包内二进制冒充源码让判据恒红，`CLAUDE.md:168-170`）、变量一律 `${var}`、
`LC_ALL=en_US.UTF-8` 复跑、**改前快照必须先变红**；入册 `test_project_guards.sh` 时**重算计数期望值**。

**0-C 落笔前三条口径要先改对（本轮实测纠出来的，照 v3 原文写会把守卫写成假绿）**：

- 「备份目录份数 ≤ 3」**不能**无条件断言：`pruneBackups` 只在**开库成功**那条路跑（§3.8），连续拒开库时攒 >3 份是**故意的**。
  口径改成：「最近一次**成功开库**后 ≤ 3」。
- 「GC 与 `purgeStaleTempFiles` 两颗的 `requires` 非空」**要拆**：GC 非空照旧断言；
  `purgeStaleTempFiles` 的取样面是**系统临时目录**（`FileHelper.swift:414` = `FileManager.temporaryDirectory + Suncut`），
  与库内路径和那 5 棵树无关，给它编一条前序就是写假依赖。改成断言它的 cadence 与"只删 >24h"这条判据仍在。
- 任何在产物里搜字符串的判据，取样面写 `SunCut.app/Contents/MacOS/SunCut.debug.dylib`，
  **不写主二进制**（58KB 蹦板，且 `__TEXT` 的 `fileoff=0`，直接 grep 必为 0）。

### 3.5 实现前必查（已答，代码面取证 2026-09-30）

- **结论：自家清理逻辑吃不到备份目录与 sidecar。** 两条都取到具体扫描范围：
  - 孤儿 GC `FileHelper.collectOrphanFiles(referencedPaths:)`（`FileHelper.swift:347-410`）只枚举
    `Videos/{hash}`、`Thumbnails/`、`ReplacedPictures/{hash}`、`ShotThumbnails/{hash}`、`ShotVariants/{hash}/{shotId}`
    五个**子目录内部**，从不列数据根第一层；删空 hash 子目录那步也只对 `globalVideoDirectory` 的子项做。
    ⇒ 数据根下的 `<store>….backup` 目录与 `<store>.launch-ledger` 不在它的取样面里。
  - `purgeStaleTempFiles()`（`MixCutApp.swift:1046-1066`）的根是 `FileHelper.tempDirectory`
    = `FileManager.default.temporaryDirectory + Suncut`（`FileHelper.swift:414-419`），即系统临时目录，
    **不是**数据根。删的是该目录顶层 >24h 的文件。
  - 仍留一条未证：`migrateToBrandDirectoryIfNeeded`（`FileHelper.swift:296`）会搬数据根第一层的条目
    （`:320-340`），但那是"搬进新根"而非删除，且已有 `migratedToKey` 一次性标志。批 3 真动 schema 前不必再查。

### 3.6 待落清单

1. `Sources/MixCutCore/LaunchStepLedger.swift` + 用例（0-A 纯函数面，含 `blocked`/`validateOrder` 断言）
2. `MixCut/App/SchemaGuard.swift`（0-B App 侧：`Schema.entities` → 描述行 → 门 → 账本合一 sidecar）
3. `MixCut/App/LaunchSteps.swift` + `MixCutApp.swift:88-178` 与 `:176-187` 三态化改造（0-A/0-B）
4. `scripts/check_schema_ledger_guards.sh` 并入册（0-C）
5. **pbxproj 手工注册**（漏注册不报错）：`SchemaFingerprint`、`LaunchStepLedger`、`SchemaVersions` 进 Core；
   `SchemaGuard`、`LaunchSteps`、`SchemaVersions` 进 App target。严禁 `generate_xcodeproj.py`
6. **验证六条读数**（v3 从 4 条加到 6 条）：`swift test` 全量 → `xcodebuild Debug` → 克隆库隔离实测
   （`MIXCUT_DEBUG_APP_SUPPORT_ROOT` 指 `.scratch` 假根 + 真库副本，见 `FileHelper.swift:16-24`）：
   ① 数据不丢（项目/方案/分镜计数与真库一致）；② 指纹未变时**不**产生备份；③ 变异：改错 sidecar 指纹一位
   ⇒ 生成三件套齐全且 `integrity_check` 通过的备份目录；④ 变异：无迁移可走的形状 ⇒ **拒绝开库**且面板含备份路径、
   **不含"删除 store"字样**；⑤ **新增**变异：人为让 `recoverFromDisk` 失败 ⇒ GC 与临时件清理**不跑**；
   ⑥ **新增**闪屏尺子读数仍为逐帧 0 段。真库全程只读。　⇒ **六条已全部闭合，⑥ 见 §3.16**

### 3.7 批 0 的诚实边界

- VersionedSchema 不会让已有 `Suncut.store` 长出历史版本；V1 就是"采纳这一刻的形状"。
- 账本不让迁移变少，只让它们可见、有序、可断言。19 颗里真正该继续存在的可能只有几颗，
  **清理它们不属于批 0**（那是另一轮销账，需逐颗确认没有老用户依赖）。
- "拒开库"把失败从"静默丢数据"换成"打不开"。**只有配上自救路径才是改进**，否则是更糟的替换 —— 这条列批 0 用户必测项。

### 3.8 克隆库实测读数（2026-09-30 夜，`MIXCUT_DEBUG_APP_SUPPORT_ROOT=.scratch/fakeroot`）

真库全程未被动过。假根 = 真数据根的完整拷贝（63M，含 `Suncut.store` 348160B / `-wal` 2167152B / `-shm` 32768B）。
产物是 Debug 包，被测二进制 `…/Debug/SunCut.app/Contents/MacOS/SunCut.debug.dylib`（`SunCut` 本体只有 58400B 的蹦板，
**文案在 dylib 里** —— 0-C 守卫若要搜字符串，取样面必须写 dylib 而不是主二进制）。

六次启动，读数按时间序：

| # | 前置 | 预期 | 实读 |
|---|---|---|---|
| L1 首次 | 无 sidecar | 建账本、**不**建备份 | sidecar 12542B / 169 行，无 `*.backup`，MCP 数据完整 |
| L2 重启 | 指纹未变 | 不产生备份 | 无 `*.backup`，sidecar 只刷 `updatedAt` |
| L3 变异 | sidecar 删掉 1 行（真子集 ⇒ 只增） | 备份 + 照常开库 | 日志 `schema 只增行变更（+1 项）…照常开库`；备份目录含 **4 件**（`.store`+`-wal`+`-shm`+sidecar）；备份库 `PRAGMA integrity_check` = `ok`；备份内计数 ZPROJECT 2 / ZSEGMENT 26 / ZMIXSCHEME 53，与真库快照逐字同 |
| L4 变异 | 改 1 行内容（1 消失 + 1 新增 ⇒ 需自定义迁移） | **拒绝开库** | 整条日志只有 `拒绝开库` 这一行 —— BrandMigration / OrphanGC / MCP / Readiness **一颗都没跑**（链在门前就断）；三件套 md5 与开库前逐字相同；sidecar **未被回写**（`updatedAt` 停在 L2，坏行原样留着） |
| L5 清理门 | 手造 3 个更旧 `.backup` ⇒ 共 5 | 只留最近 3 | 剩 3，删的是最旧两颗；同趟顺带证 `pruneBackups` 按名序=时间戳序成立 |
| L6 复原 | 还原正确 sidecar | 恢复正常、不再备份 | 无门日志、备份数仍 3、MCP 数据完整 |

面板取证走的是可达性树（`System Events` 读 `group 1 of window 1` 的 static text），不是源码字符串：
标题「数据库异常」+ 正文含**改前备份的完整路径**与「装回上一个版本即可继续使用」，
全文**不含**「请删除」；源码里 `请删除` 只剩 `SchemaGuard.swift:6` 那条描述旧行为的注释。

**测中当场发现并已修的缺陷**：面板文案里的 `**…**` 会**原样上屏**（`MixCutApp.swift:188` 是 `Text(errorMsg)`，
String 走的是非 LocalizedStringKey 初始化器，SwiftUI 不解析 markdown）。5 处用户可见串已摘星号，
重编后 L4 复跑，渲染文本无星号；`grep -cFa '已**拒绝打开数据库**'` 在 dylib 里为 0、无星号版为 1。

**两处新认知，写进 0-C 的判据前**：
1. `pruneBackups` 只在**开库成功**那条路跑（`SchemaGuard.openNormally`）。连续拒开库会攒下 >3 份备份 —— 这是**故意的**
   （拦下来的那次正是唯一退路），所以守卫**不能**断言"备份目录 ≤ 3"，只能断言"最近一次成功开库后 ≤ 3"。
2. 污染面如预料在 UserDefaults：`didXxx_v1` 那 11 颗键按 bundle id 存，假根隔离不了。
   跑前跑后各存一份 `defaults read com.suncut.app`，**diff 为 0 行**（含退出后 flush 复测）。

**仍未取的两条读数**：⑤（人为让 `recoverFromDisk` 失败 ⇒ GC 与临时件清理不跑）要等 0-A 把 19 颗 fixup 接进账本才有入口，
现下 GC 的 24h 节流仍读 UserDefaults 键，六次启动全被跳过；⑥（闪屏逐帧 0 段）只能真机肉眼/抽帧，留给用户
——**已于 2026-10-01 取到，见 §3.16（并用两段修前录屏做了正对照）**。

### 3.9 0-A 已落（2026-09-30 深夜，Q0 裁定后第一刀）

`MixCut/App/LaunchSteps.swift`（新，已手工进 pbxproj 四处）= 19 颗步骤的**唯一清单** + 驱动：
`steps`（声明顺序即执行顺序，与原 `MixCutApp.init` 的平铺调用逐颗同序）+ `bodies`（返回 `true` = 这次没报告失败）
+ `run(container:)`（`validateLaunchPlan` 先过，DEBUG `fatalError` / Release 记日志后**整轮作废**；
逐颗 `decideStep`；只有三颗有真信号，其余一律回 `true` —— 注释里写明了这不是"都会成功"）。
`AgentGateway.configure` 与 `DebugSelfTest` **不入清单**：它们是运行时接线，清单作废时界面仍要能用 MCP 排查。

**这一刀顺手修掉的三处真缺陷**（都是账本接管判定后才暴露的）：

1. `recoverFromDisk`：以前 `try? context.save()` 之后**无条件**写 `didRecoverFromDisk_v1`。
   存盘失败 ⇒ 键被写死 ⇒ 恢复出来的 `Video` 只活在内存里 ⇒ 重启后那批文件"无记录引用" ⇒ **下一趟 GC 删盘**。
   现在 `safeSave()` 失败就返回 `false` 且**不写键**（下次重跑），GC 由 `requires` 拦住。
2. `rewriteStoredPathPrefixes`：以前三张表都是 `(try? fetch) ?? []`，读失败伪装成"没有要改的行"，
   改写空转一趟还记成功；`uncovered > 0`（有值以旧前缀开头却没命中改写规则）也只记日志。
   现在这三处 + 落库失败全部返回 `false` ⇒ **未改写干净就不许跑 GC**（旧路径没对上 = 在用素材会被判孤儿）。
3. `fixMissingSemanticTypes`：`nullCount == 0` 时直接 `return` **不写键**，于是 `didFixMissingSemanticTypes_v1`
   在现网从来没存在过，这颗每次启动都重跑 SQL 统计 —— 违背它自己开头那句注释。现在"确认没有要修"也记账。
   （副作用如实记：本轮演练在 UserDefaults 里新增了这一颗键。已核对**改前快照** `ZSEGMENT` 里
   `ZSEMANTICTYPESDATA IS NULL` 的行数 = **0**，所以"没有要修"是真话，不是把该修的跳过了。）

**账实分离（Q0 裁定的落地形状）**：executor 只**读** `UserDefaults` 出 verdict，**不写任何键**；
12 颗 `once` 的 body 仍各自写自己的键。理由写在文件头：异步那颗（缩略图重生）若由 executor 先写键，
会把"只是排上了队"记成"已成功"，违反 `LaunchStepLedger` 顶部契约。
把写收进账本 = 搬一颗摘一颗内部 guard，每搬一颗跑一次启动，属后续轮次。
sidecar 里那份 `doneSteps`/`lastRunAt` 此刻**不写入**（镜像要读-改-写同一份 JSON，会撞指纹行；裁定它是镜像后收益不抵风险）。

**节流键的类型雷**：`lastOrphanGCAt` 存的是 **unix 时间戳的 Double**（`plutil -extract` 实测 `<real>1790758324.48122</real>`），
不是 `Date`。`ledgerState()` 头一版用 `object(forKey:) as? Date` 读 ⇒ 永远 nil ⇒ 账本判"从没跑过" ⇒
GC 每次启动都跑，正是当初加节流要治的冷启动拖慢。已改成 `double(forKey:)`。

**克隆库实测读数**（Debug 构建，`.scratch/build-b0-0A5.log` BUILD SUCCEEDED）：

- 启动日志新增两行且形状正确：`[LaunchLedger] orphanGC 未到节流间隔，本次跳过`、
  `[LaunchLedger] 本轮 19 颗：跑 7 / 已记账 11 / 未到期 1 / 被拦 0`；
  第二次启动变 `跑 6 / 已记账 12`（那颗语义类型自愈记账成功，7=6+1 对上）。
- 「被拦 0」= 清单校验通过、无 halt ⇒ `fatalError` 那颗雷没踩。
- 跳过原因**没有**从日志里消失：账本接管判定后 `scheduleOrphanGCIfDue` 自己的那行 `[OrphanGC] 距上次不足 24h…`
  不再打印（body 压根没被调），所以这里补了 `[LaunchLedger] …未到节流间隔`，另加一行本轮汇总。
- 克隆库数据与 MCP 计数照旧（`而非` 0/0、`测试` 4/26/53），`.store` md5 仍 `beb203ed…`；真库无 sidecar、无 `.backup`。
- `scripts/check_association_guards.sh` TC-19f 改成按**清单声明顺序**判（原来 grep `Self.xxx(container` 的平铺调用，
  0-A 之后调用点只剩 1 处，那条断言会失去抓手）。
  红证已取：把 `.scratch/guardmut/` 副本里 GC 的声明挪到 recover 之前 ⇒ `FAIL … recover=61 清理=64 GC=58`；真树 `PASS :58→:61→:75`。

### 3.10 判据⑤ 已证（2026-10-01 〇点，克隆库正反对照）

⑤ 的原文是"人为让 `recoverFromDisk` 失败 ⇒ GC 与临时件清理不跑"。**实际按清单的依赖形状证的是更强的那一版**：
断掉 `rewriteStoredPathPrefixes`（它是 `recoverFromDisk`/`dedup`/`orphanGC` 的公共前序），
三颗下游一起被拦。两次启动唯一的差别就是那一个注入，其余条件相同。

先纠一条前面所有演练读数的**适用范围**：克隆库 `ZVIDEO.ZLOCALPATH` 里存的仍是**真库的绝对路径**
（`…/Library/Application Support/Suncut/Videos/…`），不是假根下的路径。假根只换了根，没换库里的字符串。
⇒ ① 前面"L1–L6 数据不丢"是靠 MCP 计数证的，不受影响；
② 克隆库里的 GC **永远落在"零交集拒绝回收"那一支**，所以这轮能证"跑没跑"，不能证"删得对不对"；
③ 也正因为这样，这轮演练对盘上没有删除风险。

| 档 | 前置 | 读数 |
|---|---|---|
| **正对照** | 库完好，`lastOrphanGCAt` 拨到 30h 前（到期） | `本轮 19 颗：跑 7 / 已记账 12 / 未到期 0 / 被拦 0`（GC 那颗计入"跑"）；3s 后 `[OrphanGC] 跳过回收：磁盘 34 个文件与库内 34 条引用零交集`；`lastOrphanGCAt` 被推进 ⇒ **GC 真的执行过** |
| **变异** | 把 1 行 `ZLOCALPATH` 改成 `…/.scratch/fakeroot/MixCut`（截断到旧前缀本身，无尾斜杠 ⇒ `rewrite()` 拒改但 `hasPrefix` 为真 ⇒ `uncovered=1`）；时间戳再拨回 30h 前 | `有 1 个值以旧前缀开头却没被改写` ⇒ `rewriteStoredPathPrefixes 失败，依赖它的所有步骤本次被拦住` ⇒ `recoverFromDisk 未跑：前序未成功 …`、`orphanGC 未跑：前序未成功 …`；汇总 `跑 6 / 已记账 11 / 未到期 0 / 被拦 2`（6+11+0+2=19 对得上，recover 从"已记账"挪进"被拦"、GC 从"跑"挪进"被拦"）；**日志里没有 `[OrphanGC]` 那行**、`lastOrphanGCAt` **纹丝不动**、假根下 4 个 mp4 全在 ⇒ **GC 一次没执行** |
| **复原** | 按改前快照逐行还原 `ZVIDEO`（与 `store-backup-20260930-140939` 比对为**逐行一致**）、时间戳写回原值 | `跑 6 / 已记账 12 / 未到期 1 / 被拦 0`、GC 被节流跳过（原值距今 7.5h < 24h）、MCP 计数照旧 |

顺带把 `purgeStaleTempFiles` 该不该挂前序查到底，结论是**不挂，但不是因为"没想过"**：
它删的是**系统**临时目录里的过期件（`FileManager.temporaryDirectory + Suncut`），
而库内持久化的每一条路径都在 App Support 下 —— `ShotVariantService.swift:128` 用 `FileHelper.shotVariantURL`、
`ShotCompositionService` 的 `composite-*` 由 `ShotEditViewModel.swift:545` 先 `moveItem` 再落库、
`DubAudioFinalizer.swift:23` 用 `FileHelper.dubAudioURL`。三处都不是临时目录，所以给这颗编一条前序就是写假依赖。

**这轮自己造的次生雷（如实记）**：还原 `lastOrphanGCAt` 时用了 `defaults write … -float`，
float32 在 1.79e9 处的间距是 128 ⇒ 存成 `1790758272`，比原值 `1790758324.48122` **早 52.5 秒**；
`-double` 不是 `defaults` 支持的类型，写不回去。影响面只有 24h 节流窗口提前 52.5 秒，
且下次真 GC 跑完应用会自己把它写成 double。另外还原注入行时 `cut -f2-` 按**制表符**切而我拿 `|` 拼的串当行用，
第一次把 `1|/Users/…` 整个写进了库 —— 当场以改前快照为准逐行比对才发现并修回。

### 3.11 0-C 已落（2026-10-01）：`scripts/check_schema_ledger_guards.sh`

12 条判言（SL-01/02/03/03b/04/05/06/07/08/09/10/11），全部**只扫点名的四个源文件**
（`Models/SchemaVersions.swift`、`App/MixCutApp.swift`、`App/LaunchSteps.swift`、`App/SchemaGuard.swift`），
不递归扫树 ⇒ 天然不会把 `Resources/bin` 里的包内二进制算进取样面。支持 `SRC_DIR=` 覆盖取样面做自证。

v3 原文的四条断言按 §3.4 的纠口径落地：模型数↔锚点（SL-01/02 还比**类名**，不只比数）、
清单↔动作（SL-03 双向 + SL-05 反向防"清单记了个没人写的键"，那颗会永远 `skipAlreadyDone`）、
备份份数（SL-10 断言"默认值=3"这一个真源，**不**断言运行期份数）、
`requires`（SL-06 只钉 `orphanGC`；`purgeStaleTempFiles` 依 §3.10 的取证**不给假依赖**）。
另补三条 v3 没预见的：SL-07 三颗必须回报 `Bool`、SL-08 不许退回 `try? save()`+无条件记账、
SL-11 节流键写读同为 unix `double`（就是 §3.9 那颗 float/Date 雷）。

**自证：11 个变异逐个变红 + 一块取样面缺失也算不通过**（`.scratch` 副本上跑，`SRC_DIR` 指过去）：

| 变异 | 变红的判言 |
|---|---|
| 锚点漏一个模型 | SL-01 + SL-02 |
| 少一颗动作 | SL-03 + SL-03b |
| 新造 `didSneakyFixup_v1` 且没上清单 | SL-04 |
| 清单记了代码不写的键 | SL-04 + SL-05 |
| `orphanGC` 的 `requires` 清空 | SL-06 |
| 去重那颗退回 `Void` | SL-07 |
| 恢复退回 `try? context.save()` | SL-08 |
| 防线文案写「请删除 Suncut.store」 | SL-09 |
| 备份份数默认改成 9 | SL-10 |
| 账本按 `Date` 读节流键 | SL-11 |
| 删掉 `SchemaVersions.swift` | 打印"判据无法成立"，rc=1 ⇒ **不是绿** |

**自证反过来抓到守卫自己的两个假绿**（这两条比"全绿"更值得记）：

1. SL-04 头一版只认 `let fixKey = "didXxx"` 这种**赋值形**，而变异用的是内联 `set(true, forKey: "didXxx")`
   ⇒ 该红的没红。取样面窄一档就是假绿，已改成扫 `MixCutApp.swift` 里任意 `"did…"` 字面量。
   改宽后干净树仍是 12 颗、不误伤。
2. `bad(label, detail)` 把 `list` 往 `str` 上拼 ⇒ SL-08 检出违规后**在打印那一行崩了**，
   Python 非 0 退出、一条 FAIL 行都没出。外层原来只区分 `rc=0 / 其他`，会被读成"有红项"——
   其实是判据没跑完。现在 `rc>1` 单独打印「守卫异常退出 ⇒ 按不通过处理」。

登记面：`check_project_integrity.sh` 已经在管"每个 `.swift` 必须同时出现在 PBXBuildFile / SourcesPhase /
PBXFileReference"（`LaunchSteps.swift` 就是被它兜住的），所以 0-C **不重复**注册检查。
本仓库没有守卫聚合器（`test_project_guards.sh` 只是身份剥离/生成器自检），运行口径写进 `CLAUDE.md` §Schema 第 5 条。

### 3.12 第二批一刀：关联迁移不再吞错记账 + SL-12 棘轮（2026-10-01 凌晨）

**先纠 §3.2 的一处硬错**：原文写"孤儿 GC 的未引用判据是 `$0.projectVideos.isEmpty`（`MixCutApp.swift:596`）"。
实测 `runOrphanGC`（现 `:1172-1198`）的受保护集合是**全部 `Video.localPath`/`thumbnailPath` + `Segment` 一路到 `ShotVariant`**，
跟 `projectVideos` 有没有行**无关**；`$0.projectVideos.isEmpty` 那句真正出现在 `migrateToProjectVideoRelation:553`，
是它自己挑孤儿视频的判据。⇒ **不要**把这颗挂成 `orphanGC` 的前序（那会是第二条假依赖，同 §3.10 的 `purgeStaleTempFiles`）。

但这颗自己的缺陷是真的，且已修：四条失败路（读 `Video` 表失败 / 取不到库路径 / 打不开 SQLite /
`try? context.save()` 吞错）**以前全都写成功键** —— 于是那批视频永远没有 `ProjectVideo` 行，
既在项目列表里看不见，也没有第二次机会补上。现在四条全部 `return false` 且不写键（下次启动重试），
`migratedCount > 0` 时改用 `safeSave()`，签名进 `Bool`（SL-07 的四颗之一）。

顺手归位一段孤儿注释：`/// 从磁盘恢复丢失的项目和视频…` 两行一直贴在 `resetStaleAnalyzingStatus` 头上，
而它说的是 `recoverFromDisk`。

**SL-12 棘轮**（守卫从 12 条加到 13 条）：把"吞错存盘后照样写成功键"的**函数数**钉成只许减不许增，
基线 = 今日实数 **7 颗**（`purgeLegacyQwenDubs`、`purgeLongRefClones`、`resetSchemeDubSelectionToOriginal`、
`backfillSegmentFrames`、`cleanExistingTranscripts`、`ensureCustomGroupStrategy`、`regenerateSegmentThumbnailsToFirstFrame`）。
配套一条防恒绿：若清零而 `EXPECT_SWALLOW` 没跟着下调，SL-12 自己变红。

**自证又抓到我一次同样的窄形状**（与 SL-04 一模一样的错法）：第一版判据只认 `try? context.save()`，
我用 `try? container.mainContext.save()` 造的变异**没让它变红**（SL-04 红了，SL-12 仍 7/7）。
改成 `try\?\s+[\w.]+\??\.save\(\)` 后同一变异报 `8 颗 > 上限 7`。写宽之后基线仍是 7，没有误伤。

**回归读数**：`xcodebuild Debug` BUILD SUCCEEDED；克隆库再启一次
`本轮 19 颗：跑 6 / 已记账 12 / 未到期 1 / 被拦 0`（与改造前同形状，这颗既没重跑也没被误拦）、MCP 计数照旧、演练实例已退；
`swift test` 377 颗全绿 0 失败；守卫族 8 颗脚本 exit 全 0，PASS **130**（`check_schema_ledger_guards.sh` 13）、FAIL 0。

### 3.13 SL-12 销账第一轮：3 颗收口，棘轮 7→4（2026-10-01 凌晨）

提交 `e0401c1` 之后继续。**这轮动的是"吞错记账"的形状，不是执行顺序**，所以不适用"搬一颗跑一次闪屏尺子"
那条纪律（那条是给把步骤换进账本定的）；仍按形状成组：三颗配音/音色类一次性迁移一颗改法。

收口的三颗：`purgeLegacyQwenDubs`、`purgeLongRefClones`、`resetSchemeDubSelectionToOriginal`。
三颗原样都是同一形状 —— `if let rows = try? fetch` 读失败当成"没有要改的"、`try? ctx.save()` 吞掉落库失败、
末尾**无条件** `set(true, forKey:)`。后果不是崩溃而是**永久放弃**：旧 qwen 配音留在库里，
用户每次重跑一键改写都继续撞引擎的 418；长参考音色与"默认预选改写A"同理。
现在三颗都 `-> Bool`（进 SL-07 的名单）、读表或落库失败即 `return false` 且不记账，下次启动重试。

**守卫自己又假红一次，记下来免得重踩**：SL-12 把 `fixMissingSemanticTypes` 报成了违规，
而它体内根本没有被吞的 `save()` —— 命中的是我在 §3.9 写的**文档注释**里那句"以前是 `try? ctx.save()` 吞掉…"。
判据拿注释当代码，就是把"写清楚了"判成"还犯着"。修法：切出函数体后先剥掉 `//`、`/*`、`*` 开头的行再匹配。
反向也证了：剥完仍能把真代码（`try? container.mainContext.save()`）数出来 ⇒ `5 颗 > 上限 4` 变红。

**读数**：`xcodebuild Debug` BUILD SUCCEEDED；克隆库启动形状与改前**逐字相同**
（`本轮 19 颗：跑 6 / 已记账 12 / 未到期 1 / 被拦 0` —— 这三颗的键早已记着，本就该 skip，
所以这一档证的是"没有误重跑"，不是"失败路径会重试"）；守卫族 8 颗 exit 全 0、PASS 130、FAIL 0；
SL-12 现单 4 颗：`backfillSegmentFrames`、`cleanExistingTranscripts`、`ensureCustomGroupStrategy`、
`regenerateSegmentThumbnailsToFirstFrame`。

**未证的部分说清楚**：这三颗的**失败路径没有运行期实测**（`swift test` 物理上碰不到 `MixCut/`；
演练里它们的键早已写死，走的是 skip 那一支）。最便宜的证法是批 3 真动 schema 那一轮，
把克隆库设成只读 + 摘掉对应键跑一次，期望看到 `[LaunchLedger] xxx 失败，本次不记成功键` 且下次启动重跑。

### 3.14 SL-12 销账第二轮：又收 3 颗，棘轮 4→1（2026-10-01 早）

`backfillSegmentFrames`、`cleanExistingTranscripts`、`ensureCustomGroupStrategy` 三颗收口（同一形状：
`try? save()` 吞错 + 无条件记账），SL-07 的名单从 7 颗扩到 **10 颗**，`EXPECT_SWALLOW` 从 4 下调到 **1**。

`backfillSegmentFrames` 多修一层，值得单独记：它以前对"所属视频缺有效 fps 而回填不了"的分镜直接 `continue`，
然后照样写成功键 —— 那些分镜的边界永久停在秒制，逐帧功能对它们是静默失效。
现在这类分镜计入 `blocked`，`blocked > 0` 就返回 `false` 且不记账（下次启动重试并再报一次）。
代价如实写在这：若某条记录真的永远没有有效 fps，这颗每启动跑一次并留一行错误日志 ——
**可见的重试**比**静默的放弃**好，这正是批 0 要换掉的那个默认。

**两处我自己犯的纪律错，当场补做了**：

1. 变异没证落地就下结论。第一次把"签名回退成 Void"的变异和"新造吞错记账"的变异塞在同一段脚本里跑，
   结果只看到 SL-04/SL-12 变红，`SL-07` 没红 —— 因为第二个变异的锚点根本没断言命中。
   重做时先 `assert old in s`（打印"变异已落地"）再跑，`SL-07` 如实变红：
   `FAIL SL-07 这些步骤不再回报成败（['cleanExistingTranscripts']）`。
2. 取证顺序错了。上一轮我在 `kill` 之后才查 MCP，拿到的是 `ECONNREFUSED`，那一档**没有数据读数**。
   重做（启动 → 查 MCP → 再退）后计数照旧对得上。

**读数**：`xcodebuild Debug` BUILD SUCCEEDED；克隆库启动形状仍 `跑 6 / 已记账 12 / 未到期 1 / 被拦 0`
（三颗的键早已记着 ⇒ 这一档证"没有误重跑"，失败路径依旧只有静态判据、无运行期实测，理由同 §3.13）；
`swift test` 377 绿；守卫族 8 颗 exit 全 0、PASS 合计 **130**、FAIL 0；
克隆库 `.store` md5 变为 `bfda4dfe…`（演练自己写过盘，正常），
**真库仍 `beb203ed…`** —— 与批 0 开工前那份快照逐字节相同。

余下一颗 `regenerateSegmentThumbnailsToFirstFrame`：异步，账本此刻看不到它的成败，
要收口得先拆成"排上队"与"跑完了"两颗（`LaunchStepLedger` 现有一刻一判的模型装不下半完成态）。
这是设计动作，不与本轮同形，留到下一次单独做。

### 3.15 SL-12 归零：异步那颗的两处真缺陷（2026-10-01 早）

最后一颗 `regenerateSegmentThumbnailsToFirstFrame` 不是同形替换能了事的，查实际行为后是两处缺陷：

1. **先删后生 = 自己造丢图窗口**。旧图路径与新输出名是**同一个文件**（`seg_<uuid>.jpg`，
   `ImportViewModel.swift:1027` 建的就是这个名），而 `generateThumbnail` 本来带 `-y` 原地覆盖
   （`FFmpegRunner.swift:664`）。所以那次 `removeItem(oldPath)` 没有任何收益：只要一个分镜的 ffmpeg 失败，
   它的缩略图就被**删没了又补不上**，而 `segment.thumbnailPath` 仍指着那个不存在的文件 ⇒ 界面是空白而不是旧图。
   预删除已整段去掉。
2. **读表失败也记账**。`guard let segments = try? fetch, !segments.isEmpty` 把"确实没分镜"和"读不到分镜"
   合进同一分支，于是一次读失败就把整批迁移永久作废。现在拆开：读失败不记账、下次重试；真的没有分镜才记账。

**记账口径没改成"个别失败就重跑"，这是有意的**，理由写在函数头：这颗异步、账本看不到它，
若部分失败就不记账，代价是每次冷启动重打 N 个 ffmpeg 进程，收益只是重试那几个注定失败的作业。
口径能成立的前提正是第 1 条——旧图还在原处，失败只降外观、不丢数据。落库失败仍然不记账。
日志因此带上下计数：`完成重生 x/y —— 失败的那些仍用旧图，本次已记账不再重试`。

**棘轮归零**：`EXPECT_SWALLOW` 从 1 下调到 **0**，SL-12 从此是零容忍。
归零档也补了红证：往 `.scratch` 副本加一处真吞错记账（`try? container.mainContext.save()` + 成功键）
⇒ `FAIL SL-12 … 1 颗 > 上限 0`，变异落地由 `assert` 先证；真树 `0/0` 全绿。

**读数**：`xcodebuild Debug` BUILD SUCCEEDED；`swift test` 377 绿；守卫族 8 颗 exit 全 0、PASS 130、FAIL 0。

**这轮的证据边界，说清楚不藏着**：本机这把 `didRegenerateSegmentThumbnailsToFirstFrame_v1` 键**早已记着**，
⇒ 这次改动对本机未来的行为是零影响（它不会再跑），真正受益的是还没跑过或跑到一半的用户。
要在本机实跑这条新分支就得摘那把键，代价是下次用真 app 重生成一次全部分镜缩略图（几十个并行 ffmpeg，
几秒、只花 CPU），而收益只到"正常完成会重新记账"这一条 happy path —— "失败不丢原图"要靠弄坏 ffmpeg 才造得出。
所以本轮按**代码级证据**记，不摘键；批 3 真动 schema 那轮若要碰缩略图路径，再一起验。

### 3.16 批 0 验收 ⑥ 闪屏尺子读数收口（2026-10-01 15:3x，带正对照）

⑥ 是批 0 六条读数里唯一一直挂着"留给用户真机"的那一条。这次由用户 `screencapture -v -V 20` 录两段窗口录屏
（`录屏2026-10-01 15.35.07.mov` 15.3s / 918 帧、`15.32.23.mov` 8.5s / 510 帧，都是 **1804×1266**，
与脚本标定的参考几何逐字相同 ⇒ **不需要**传 `--sidebar-crop / --detail-crop`），我跑 `scripts/measure_nav_blank.sh`，
**默认阈值、一个参数都没改**：

| 片段 | 侧栏区基线边缘能量 | 详情顶区基线 | 侧栏空白段 | 详情顶空白段 |
|---|---|---|---|---|
| 10-01 15.35.07（本次） | 11.9228 | 17.8781 | **0 段 / 0.0ms** | **0 段 / 0.0ms** |
| 10-01 15.32.23（本次） | 11.9440 | 17.8287 | **0 段 / 0.0ms** | **0 段 / 0.0ms** |
| 09-30 18.46.48（**正对照**·修前） | 13.8383 | 13.4164 | **2 段 / 200.1ms / 最长 100.0ms** | 0 段 |
| 09-30 18.12.41（**正对照**·修前） | 11.9590 | 17.8006 | **1 段 / 100.0ms** | 0 段 |

脚本自己写着"0 检出 ≠ 达标，可能这段根本没切项目"，所以两头都补了：

- **尺子活着**：同一条命令跑在两段 9-30 修前录屏上分别读出 2 段与 1 段（100ms 一档，正是当年那个 50–134ms 的形状）
  ⇒ 它看得见空白，不是瞎的。
- **片段真含切项目**：把 15.35.07 按 1fps 抽成 16 格拼图逐格看过 —— 侧栏选中在两个项目之间来回，
  内容区在「27 / 27 个分镜 + 缩略图」与「0 / 0 个分镜 + 还没有分镜」之间来回，一段里至少 3 次切换。
  载体是 1.4 那个新构建（pid 39409，`.scratch/dd` 产物）跑在克隆库上。

⇒ **批 0 六条读数全部闭合**。边界照旧记着：这只量了 **Debug**，Release 那条线仍未测（与本条无关，一直挂着）。

## 4. 批 1~5 逐条判据



> 格式：**缺的那一口** → **判据**（动手前写死）→ **测试层**（P 维度取自 `2026-09-28-ai-empty-output-diagnosis.md §10.2`）
> → **零断言面**（`swift test` 碰不到，验收不得写"已验证"）→ **MCP 契约影响**（v3 新增列，评审 P1 第 4 条）。

### 批 1（全零 schema）

| # | 功能 | 缺的那一口 | 判据 | 测试层 | 零断言面 | MCP 契约 |
|---|---|---|---|---|---|---|
| 1.1 | 边界直输时间码 | `FrameTime.swift:25-37` 只有格式化**无解析器**；View 是单帧号框 `SegmentLibraryView.swift:1799-1825`；越界**静默 clamp**（`SegmentLibraryViewModel.swift:423,439`） | `分:秒:帧` 三段各自可点直改；帧段按真实 fps 封顶（30fps 只能输 0~29）；回车生效 / Esc 取消；越界**拦下并说明可用范围**，不得静默改值 | Core 新 `TimecodeParser`：P4 三点法、P11 tie-break、P12 越界不得当合法值 | 三段点击手感、Esc、文案 | ⚠️ `adjust_segment_boundary` 现在也是 clamp 语义，界面改拒绝而 MCP 仍 clamp 会分叉 ⇒ 见 Q5 |
| 1.3 | ⌘Z 宽限 5s→5min | `PendingDeletionCenter.swift:21` 一颗常量 ⚠️ **此格漏了同一颗常量还驱动浮条时长、且提示是单槽位 ⇒ 见下方落地记录，判据已升级** | 4 分 59 秒可放回、5 分 01 秒不可放回 | 无（落地后改为 Core 可测，17 条用例） | 浮条停留时长 | 无 |
| 1.4 | 悬停角标 | 配音标识在文字下方（`SchemeDetailView.swift:408,453-500`）⚠️ 这格漏了两口：浅底搬到画面上会糊、`bottomLeading` 隔壁那颗时长角标占的就是 `bottomTrailing` ⇒ 见下方落地记录 | 视频区 `bottomLeading` 显示「改写A 配音」/「原声」 | 无（纯界面，无下沉点） | 位置与可读性；另加「画面上点得开下拉」一条 | 无 |
| 1.5 | 方案变体多选 | `SchemeListView.swift:605` 单选、`:616-618` 只删单条 | 多选后批量删（走 `PendingDeletionCenter` 可撤销） | 复用既有 | 框选手感 | 无 |
| 1.6 | 方向键移卡 | Views 内唯一按键 `SegmentLibraryView.swift:1090` | ←→ 移光标、回车进详情 | 无 | 键盘走一遍 | 无 |

#### 批 1 落地记录

**1.3 已落（2026-10-01，提交 `83ba40b`，10 文件 973+/99−）—— 判据按本表执行会得"装饰性的 5 分钟"，已升级**

上表把这一条写成"`PendingDeletionCenter.swift:21` 一颗常量"，漏了同一颗常量还驱动着浮条时长，
而提示是**单槽位**（任何 `show()` 覆盖上一条）⇒ 光把 5 改成 300，中途任何一条提示都会把「撤销」顶掉，
用户到点前屏上没有可点之物。`architecture-first-fix` 审查后选定 **A 统一撤销事务抽象**：

- 新增纯状态机 `Sources/MixCutCore/UndoGraceMachine.swift`（`idle/armed/undone/expired/flushed`）。
  核心判言是**「浮条可见 ⟺ armed」在类型上同成立** ⇒ 审查记的竞态①（切项目后残留可点撤销）在状态机层面消失，不靠调用点纪律。
- `PendingDeletionCenter` 成为 ticket 唯一持有者与唯一可见性来源；`Toast` 拆成两个槽位：
  上方专用常驻撤销条 `UndoSlotView`（带倒计时与具名按钮），下方 `NoticeSlotView`（非交互提示，`show()` 不再收 `actionTitle`/`action`）。
- 两种 ticket：`.deletion`（300 秒，欠一次 commit）/ `.batchOverwrite`（5 秒，只欠 undo）；
  批量字号、批量遮挡两处从 `ToastCenter.show(actionTitle:)` 搬进 `scheduleUndoOnly`。
- 顶掉旧条时**先了结再登记**（顺序反了会把上一条的 commit 丢掉），文案交代「上一条…已确认删除」。
- ⌘Q 补真删：`MixCutApp.init()` 成功开库路径注册 `willTerminateNotification` → `flushNow()`。
  **强杀与崩溃救不了**，这条边界写在代码注释与 `CLAUDE.md` §撤销浮条与延迟删除，不当秘密。

测试层从上表的「无」改为 **Core 可测**：`Tests/MixCutCoreTests/UndoGraceMachineTests.swift`
**14 个编号 / 17 条可执行用例**（UG-01~14，另 UG-04b、UG-07b、UG-08b 三条反向与正向对照），
含反向对照（armed 内点击必须真撤销，否则 UG-04 恒真）。守卫 `scripts/check_undo_guards.sh` 8 条（UG-G01~08），
自检 `scripts/selftest_undo_guards.sh` 8 颗变异 M1~M8 全部变红、基线全绿。守卫族实测 **138 PASS / 0 FAIL**
（= 批 0 的 130 + 撤销这族 8；读数取自已跑的那次运行，非本次重算）。
**`swift test` 已于 2026-10-01 14:3x 跑过：`Test run with 394 tests passed`、0 失败**，
`UndoGraceMachine · 撤销宽限事务判据` 套件 17 条全绿 —— 394 = 批 0 基线 377 + 这 17 条，正好对平
（先前写「14 条」是数了编号没数用例，已更正）。

验收读数：**已过五条** —— ① 撤销条上屏带「已删除分镜 · 3:52 ｜ 撤销删除」（真像素，整屏两帧差图定位后回裁）；
② **切项目当场消失**（P0，用户屏前读数「立刻没了」）；③ ⌘Q 钩子补真删（`ZSEGMENT 20 → 18`，期间日志无重载、300 秒未到点 ⇒ 唯一 commit 时机是退出）。
④ **倒计时真在走**（2026-10-01 15:15:50 读到 `4:59`、15:16:41 读到 `4:09`：真实间隔 51 秒、数字走 50 秒，
差的 1 秒是显示按 `rounded(.up)` 取整；同一条屏撑过 51 秒，旧的 5 秒设计做不到）；
⑤ **「上一条已确认删除」交代**（15:27 连删两条、第二刀落在第一刀 20 秒后，条上读到
「已删除分镜（上一条「已删除分镜」已确认删除） · 5:00 ｜ 撤销删除」，与 UG-08 断言逐字一致）。
数据侧同时收口：克隆库 `ZSEGMENT` 31 → **28**，减的 3 条 = 前两枚各自到点真删 + 第三枚被顶掉时即刻真删，
第四枚当时仍在宽限期内未落 —— 与"顶掉先了结、到点也了结"的次序自洽。
**仍欠一条**：「撤销批量遮挡」那枚像素（四次抓取未赶上，实现按同组件落地）。`swift test` 那条已销账，见上一段。

**取证过程中钉下来的两条边界**（判据原文没有，写死在这里免得下轮重踩）：

1. **撤销条覆盖六处删除，不覆盖「方案内移除分镜」**：走条子的是 `ImportViewModel:774`、`SchemeViewModel:380`（删策略）
   与 `:404`（删方案）、`ProjectViewModel:119`（删项目）、`SegmentLibraryViewModel:483`（删分镜）与 `:512`（批量删分镜）；
   而 `SchemeViewModel.removeSegment()`（`:460-479`，方案详情里那张卡片的垃圾桶）是 `context.delete` + `safeSave()`
   **当场落死**，只挂 `⌘Z` 的 action 名，压根不登记 ticket ⇒ 那一页删完**屏上不会有条子**，不是回归。
2. **任何 `load*` 都会先 `flushNow()`**：`loadSegments(for:)`、`loadSchemes(for:)`、`fetchProjects()`、
   `ProjectViewModel.selectedProject.didSet` 全都收条子 ⇒ **取证期间一换页/一换项目，宽限期当场结束**，
   两帧对照必须在同一页内取。上一轮 14:54 那两张拍不到条子，就是这个原因（不是没生效）。
零断言面从上表的「浮条停留时长」扩大为「浮条停留时长 + 两槽位同屏的可读性」。

**1.4 已落（2026-10-01，`SchemeDetailView.swift` 单文件 11+/9−）—— 上表「缺的那一口」只写了落点，漏了两口**

预览闸口选了 **档 A**（深底白字）。落码：`dubBadge` 从正文 `VStack` 删掉，改挂
`.overlay(alignment: .bottomLeading)`；选中改写版时文案写「改写X 配音」，未选写「原声」，
锁定态保持「原声（锁定）」；三处胶囊底换成 `Color.black.opacity(0.55)`，字色白／绿／橙分三态。
`minHeight: 380` / `height: 400` 未动。

上表两处漏写，都是当场挖出来补的：

1. **判据只说"搬到 `bottomLeading`"，没说搬过去会看不清** —— 原胶囊是浅底深字（`gray/green/orange.opacity(0.12~0.15)`），
   在白卡片上成立，压到明暗不可控的视频帧上直接糊（预览里拿同一个真视频帧画了档 A/档 B 两屏对照）。
2. **画面右下角不是空的** —— `bottomTrailing` 已被时长角标占着（实测左缘在卡片 2x 坐标 x=202）。
   三态里最挤的是「原声（锁定）」，右缘 x=192，净距只剩 10px（5pt）。

读数：Debug 编译 **BUILD SUCCEEDED**、8 颗 `check_*.sh` 全 rc=0；新 dylib 里 ` 配音` 出现 6 次 vs 旧那份 5 次（字面量确实进了产物）。
真机复拍已过四条 —— 角标在画面左下、正文那行消失（同一 x 窗口切行段：旧卡 6 段 → 新卡 5 段）、
卡片变矮实测 **53px = 26.5pt**（预览预测 51px = 25.5pt，差 2px 属阈值噪声）、白色泡沫托（画面最亮处）上白字仍读得清。
**仍欠两条**：「改写A 配音」文案与 C3「画面上点得开下拉」—— 本机 `ZSEGMENTDUB` 行数在克隆库与真库都是 **0**，
那支 Menu 渲不出来，只能等真有一条配音变体后由用户点一次。测试层仍为「无」（纯界面，无下沉点）。

### 批 2（全零 schema）

| # | 功能 | 缺的那一口 | 判据 | 测试层 | 零断言面 | MCP 契约 |
|---|---|---|---|---|---|---|
| 2.1 | BGM 多选随机均分 | `ExportView.swift:31,436-443` 单选；`DubExportService.swift:43-46,263-265` 一条轨；导出层零 `random/均分` | K 首导 N 条 ⇒ 每首 ⌊N/K⌋ 或 N/K⌉；**不做笛卡尔积**（2 首 20 条仍是 20）；不整除给区间；"保留原声"= 一首都不选 | Core 新 `BGMAllocationPlanner`：P10 分区合并守恒、P4 整除/不整除、P16 全局量不得由局部调用产出 | 抽 3 条听 BGM | 无 |
| 2.2 | 配音「停止」 | `DubSettingsBar.swift:73` `Task {}` 句柄丢弃、busy 分支只有 spinner；教训见 `ExportView.swift:719-721` | 停止后**不再发起后续请求**；已提交 TTS 按次计费须明说"这一条已花钱" | P9 取消传播（可测部分：计划表截断后不产生新条目） | 按钮出现/消失时机 | 无 |
| 2.3 | 裂图进诊断 | `ThumbnailCache.swift:50-60` 解码失败只塞 `failedPaths` **完全静默**；预热 `:89-91` 同 | 四类归因各自成句：不存在 / 0 字节 / 不在放行范围 / 文件正常但解不出来；写日志且进报告 | Core 新 `ImageFailureDiagnoser`：P7 枚举 ⊇ 失败形状、P6 specific 先于 general | 造坏图看报告 | 无 |
| 2.4 | 报错落盘 + 脱敏 | `Toast`/`InlineBanner` 零 `MixLog` ⇒ 报错上屏即丢；全仓零脱敏，日志天然含 `/Users/<name>/`（`FileHelper.swift:26`） | **v3 定档：写入时掩**（`MixLog` 落盘前替换 `<HOME>`），导出时再掩一次作二次防线；界面上每条报错都落盘；`FFmpegRunner.swift:59` 裸退出码过中文化层 | Core：P13 观测产物不自毁、P2 "缺"必须是数据不是日志 | 触发失败后搜登录名 | 无 |
| 2.5 | 自建分镜补质量分 | `AIAnalysisService.swift:229-258` 不返回分，`qualityScore` 停默认 8.0（`Segment.swift:209,220`）⇒ 被 `SchemeGenerationService.swift:204` 的 `>=8.5` 挡在候选外 | 自建分镜打标同时产出真实质量分并进候选池 | P12 默认值不得冒充真实数据 | 方案里能否选到 | 无 |
| 2.7 | D2 拦截说清真凶 | `ImportViewModel.swift:1215` 文案让用户"先从方案中移除"，但挡它的方案可能在**别的项目** | 文案必须列出**哪几个项目的哪些方案**在挡 + 一条可达路径；不得只说"请先从方案中移除" | Core 新 `BlockageExplain`：P1 完整性（引用数 == 列出数）、P11 排序 | 文案与跳转 | 无 |
| 2.6 | 顺手 | `CLAUDE.md:98` 与实现不符；`CLAUDE.md:56` 写"6 个 @Model"实际 **10 个** | 文档与实现一致 | 无 | — | 无 |

### 批 3（第一次真动 schema）

| # | 功能 | 缺的那一口 | 判据 | 测试层 |
|---|---|---|---|---|
| 3.1 | 方案批次分组 + 组合级去重 | `MixScheme` 无批次字段（`:7-26`）；落库零去重（`SchemeViewModel.swift:674-705`）；提示词只带本次内存组合（`SchemeGenerationService.swift:313,327,452-458`），库里已有组合从未回喂；全重复只写日志（`:366`） | 已有策略+组合回喂 AI 避开；落库组合级去重；**全重复明确告知**；中栏按批次分组、最新在上、头写「第 N 批·时间·X 策略/Y 变体」、可折叠、右键整批删、5 分钟可撤销；**只有一批时界面与以前完全一样** | Core 新 `CompositionDedup` + `SchemeBatchFolder`（形态照抄 `ProjectVideoDedup.swift:51-61`）：P10、P11 同时间戳排序、P14 job 面与实体面一致 |
| 3.2 | AI 产物花费标注 | `ShotVariant.swift:17-47`、`SegmentDub.swift:8-37` 无计费字段；`AIResponseEvidence.swift:176-177` 是文本 token 仅诊断；现只有"按次计费"文案 | 生成后标注**这一次**实际花费；金额必须来自服务返回值，取不到显示"未知"而非 0。⚠️ 前置：先验证万相/DashScope 响应能否取到实际用量（§8） | P12 nil ≠ 0；同行"字段+文案"两个数字必须同源 |
| **3.3** | **字幕第四档「无字幕」**（v3 自批 1 移入，R3） | **编码容量不够，不是加一个 case**：`SubtitleTreatment` 为"避免数据库迁移"映射到 `(hasHardSubtitle, maskStyle)` 两字段（`DubEnums.swift:66` 原文），而写入侧把 `hasHardSubtitle` **挪用成 `needsMask`**（`SegmentLibraryView.swift:986`），读取侧 `guard hasHardSubtitle else { return .direct }`（`:96`）⇒ 只有三态可表达；第四态"不遮不烧"与 `.direct` 共用 `false`，**存"无字幕"下次读回"直接烧字幕"**。若改走 `maskStyleRaw="none"`，未知 raw 又 `default: return .blur`（`SubtitleMaskMode.swift:19`）⇒ 读成"模糊遮挡+烧字幕"，正好是需求反面 | 四档各自 `encode→decode` **必须回到原值**（往返断言）；旧库三值读回**不得**变第四档（反向对照）；`from(hasHardSubtitle:maskStyle:)` 的有损归并（`dim`→`blur`，`:98`）要一并处理；「应用到该视频全部分镜」的批量写入点（`SegmentLibraryView.swift:1177-1207`）同步；导出侧与"保留原声"解耦（`DubExportService.swift:293-308`、`DubSegmentGraph.swift:76-83`） | Core：P7 枚举 ⊇ 失败形状、P10 四档互斥且全覆盖、往返守恒 |

### 批 4

| # | 功能 | 缺的那一口 | 判据 | 测试层 |
|---|---|---|---|---|
| 4.1 | AI 校对错别字（只换字不动时间轴） | 现只有正则去乱码（`MixCutApp.swift:513-534`）；⚠️ 顺带暴露真缺陷：`TextProvenance.swift:62-76` 的 resolve 不看 `currentSource`，**手改过的台词照样被盖** | 只换字、时间轴逐字不动；手改永不覆盖；已生成配音变体的分镜提示"是否重生成"而非自动重做 | Core 新 `TranscriptProofreader`：P1 完整性（字数/句数不变）、P17 真实样本回灌 |
| 4.2 | 英文整条链路 | `"zh"` 写死四处（`ImportViewModel.swift:327`、`ImportView.swift:290,331`、`QwenASRClient.swift:113`，whisper 只吃 `-l` 见 `ASRService.swift:472`）；预算按字（`CharBudget.swift:19-38` + `RewritePromptBuilder.swift:9-13` + `script_rewrite_prompt.md:14`）；切分按字母且把空格当杂质滤掉（`SentenceTimingAligner.swift:17-21`、`CaptionBoundaryEditor.swift:22-40`） | 自动检测语言不误判中文；词间空格保留；**中文按字、西文按词**；改写保持原文语言；字幕切分按词不劈单词；英文不跑中文同音校对 | P3 等价类（纯中/纯英/混排/纯符号）、P4 预算三点法（48 字符≈9 词） |

### 批 5

| # | 功能 | 缺的那一口 | 判据 | 风险与兼容 |
|---|---|---|---|---|
| 5.1 | 存储位置可迁移 | 根写死 Application Support（`FileHelper.swift:16-28`）；设置页只读（`SettingsView.swift:438-457`）。引擎已有一半：`BrandDirectoryMigration.swift:46-125` + App 侧 `MixCutApp.swift:1111-1158` | 迁移前自动备份；逐字节校验；失败自动回退；迁移后项目/分镜/缩略图/模型全部指得到 | 三处不能直接复用：① from/to 只建模成同一 base 下的目录名（`FileHelper.swift:299-311`）；② 无逐字节校验；③ 无失败回退。**且完成标志存的是"目录名"（`FileHelper.swift:287-289`），跨卷时该语义失效** ⇒ 要连完成标志一起重建模。派生路径 `FileHelper.swift:62-88,93-100` 全表要跟。⚠️ 与批 0 冲突面最大：`rewriteStoredPathPrefixes` 就是清单里的一颗 |
| 5.2 | 任务制重启接续 | `AgentJobRegistry.swift:3-4` 自陈"内存态，app 重启即失效"；ffmpeg 子进程类任务无落库句柄；周期核对不存在。可抄 `ShotEditViewModel.swift:74-88`、`:566-574` | 崩溃/强退后重启自动接续或明确判为中断；未处理完时界面定期核对，全部完成后自动停止 | 新增 `AgentTask` ⇒ 真 schema 变更。⚠️ **MCP 契约**：`AgentToolCatalog.swift:98 get_job` 从"本进程任务"变"跨重启任务"，接入方行为变 ⇒ 同步 `AgentToolCatalogTests`、instructions 文本，并按 Q6 裁定能力声明 |

## 5. 全批共用的交付纪律

1. **可测面 = 下沉深度**。`Package.swift` 只有 `MixCutCore` + `MixCutCoreTests` ⇒ `swift test` 碰不到 `MixCut/` 任何一行。
   标"零断言面"的条目验收只给读数来源，**不得写"已验证"**。
2. **每条防线必须写"它失败之后落到谁手里"**（v3 新增，本轮评审的直接教训）。v2 三条 P0 全是这一类：
   拒开库落进删库分支、失败传播未定义而下游是删文件的 GC、新档位在旧编码里放不下。
3. **新文件必须手工注册进 pbxproj**，漏注册不报错。严禁 `generate_xcodeproj.py`。
4. **不 bump 版本号**（`CLAUDE.md:125`）。
5. **守卫脚本**：取样面先定（排除 `Resources/bin`）、`${var}` + `LC_ALL=en_US.UTF-8`、改前快照必须先变红、入册重算计数期望值。
6. **判据必须能在改前快照上变红**（P18）。
7. **文档里的数字要么当场复算要么不写**（`CLAUDE.md:56` 的"6 个 @Model"就是这么变成第二个假数字的）。

## 6. 待用户裁定

| # | 事项 | 优劣与代价 |
|---|---|---|
| **Q0** | **0-A 的「这颗跑过没有」持久化真源放哪** | **已裁定（2026-09-30）：保留 UserDefaults 作真源**，sidecar 只镜像顺序与成败。代价是两处存、账本不整洁；换来的是 sidecar 丢失或被清理时不会把一次性 fixup 重跑一遍。回填方向反过来不成立，所以 `LaunchSteps` 的 `doneKeys` 取值必须**以 UserDefaults 为准**，sidecar 只读不判 |
| Q1 | 3.3「无字幕」要不要同时暴露给 Agent | 暴露：一句话可切第四档，但 `set_subtitle_mode` 枚举是契约（`AgentToolCatalogTests.swift:47-49` 锁三档，v2 漏列）⇒ 要重验接入方。不暴露：界面先拿到，Agent 侧留到批 5 与 `get_job` 一起改一次契约 |
| Q2 | 2.5 与 `docs/PRD/05` 冲突 | 改：自建分镜进高质量候选位。不改：维持原裁定 —— 但它现在是被**默认 8.0** 挡在门外，不是被设计挡在门外。要改就连 `-PRD.md:21`、`-TRD.md:62` 一起改 |
| Q3 | 4.1 与 ASR 裁定的边界 | `2026-09-28-asr...md:621-624` 定"先不换引擎"、F 已收档。校对层不涉引擎；若为拿词级时间戳引入第二引擎，那是**重开裁定**，另立一轮 |
| Q4 | 批 3 与批 5 的 schema bump 分开还是一次并批 | 分开（推荐）：每批一次备份门触发、一轮回归，能归因；代价多 1~2 天。并批：省一轮回归，代价是 `AgentTask` 与批次字段互相污染归因，且批 5 本就排在批 3/4 后 |
| **Q5** | **1.1 越界改"拒绝"后，MCP `adjust_segment_boundary` 要不要同步** | 同步：界面与 Agent 同一套语义，但会改变已有接入方拿到的行为（现在越界是 clamp 成功）。不同步：同一件事两条路径两种结果，正是本工程最忌讳的分叉 |
| **Q6** | **5.2 之后 MCP 能力声明要不要抬版本** | 抬：接入方能识别 `get_job` 语义变了。不抬：省一次契约动作，但跨重启任务对 Agent 可见是**行为变更**，不声明等于让接入方自己撞 |

## 7. 总验收（走用户可观察结果）

- **批 0**：老用户升级首启数据零丢失，且**已跑过的一次性迁移不被重跑**（逐颗 bool 键核对）；`changed` 时出现三件套齐全
  且 `integrity_check` 通过的备份目录；改错指纹能翻出这道门；无迁移可走的形状**拒绝开库**且面板给备份路径、
  **不出现"删除 store"**；**人为让前序迁移失败 ⇒ 孤儿 GC 与临时件清理不跑**；清单装配错序 DEBUG 当场炸；
  闪屏尺子仍逐帧 0 段。
- **批 1**：30fps 素材入点能从 `01:03:24` 直改成 `00:12:00`，不用点 1500 多次。
- **批 2**：2 首 BGM 导 20 条 = 每首 10 条且总数仍是 20；配音中途停止后不再产生新请求与扣费；
  诊断报告与盘上日志都搜不到本机登录名；拆分被挡时文案点名哪个项目哪几条方案。
- **批 3**：同项目连点两次「生成方案」，第二批不复刻第一批；只有一批时界面与现在逐像素一致；
  **四档字幕设置重开应用后仍是原档**（往返守恒）。
- **批 4**：英文素材走完整链路，词间有空格、改写保持英文、字幕不劈单词；手改台词不被校对覆盖。
- **批 5**：数据根迁到另一块盘后项目与分镜无缝可用；强杀进程再启动不留下永远转圈的卡片。

## 8. 前置输入

- 批 0 开工前：**真库三件套手工备份**（运行时门只在开库前触发，改代码阶段它救不了你）；
  `measure_nav_blank.sh` 的当前基线读数（搬每一颗都要对照）。
- 批 0 的 §3.5：`purgeStaleTempFiles` 与 GC 的回收范围核对结果。
- 批 0 的 0-A：19 颗步骤各自"是否允许重跑"逐颗确认（§3.1 键清单）。
- 批 3.2：**先验证万相 / DashScope 响应能否取到实际计费用量**（取不到就改自算口径，判据随之改写）。
- 批 3.3：旧库三值样本（验往返与"旧值不得变新档"的反向对照）。
- 批 4.1：一批真实错字样本（历史台词里取，别造）。
- 批 4.2：至少一条英文素材 + 一条中英混排素材。
- 批 5.1：第二块可写磁盘（跨卷才是真正判据，同目录改名已被 `BrandDirectoryMigration` 覆盖）。

## 9. 测试覆盖评估结论并入（`test-coverage-expander`，2026-09-30）

### 9.1 种子与差距

种子 = 现有 **330→363 条 `@Test` / 48 文件**。与批 0 同族的四组模板：`ProjectVideoDedupTests`（幂等 TC-09、
顺序无关 TC-05/14、tie-break TC-06、悬挂输入 TC-11、规模 TC-13、**线上库快照回灌 TC-15**）、
`BrandDirectoryMigrationTests`（重复执行是空的、collision 两边都不许动、清单不依赖磁盘返回顺序）、
`OrphanFileFinderTests`（**GC 何时不该动手**：引用集空/零交集 ⇒ 拒；有交集 ⇒ 照常给，防退化成假守卫）、
`SchemaFingerprintTests`。⇒ 0-A 的 `blocked` 语义**不必发明，照抄 `safeOrphanFiles` 三档形状**。

两个结构性 ❌（不是"补几条测试"能填的）：
- **MIG-01 旧库+新模型仍读出原值**：`swift test` 只有 `MixCutCore` 一个可测 target，碰不到 SwiftData
  ⇒ 单元层**永远填不上**，只能降级为克隆库脚本读数（§3.6 第 6 步的 ①②③④）。
- **指纹判据的效力上限**：本文件只保证"同一行集→同一指纹"与"这几类改动会翻指纹"，
  **不保证"所有真实 schema 变更都会翻指纹"**——后者取决于 App 侧 `Schema.entities`→描述行的翻译是否完整
  （漏译 `#Index`/`#Unique`/关系基数，指纹就不动）。那半边在 0-C 守卫里，不在单测里。

### 9.2 D-1 已落（对象存在，可立即跑）

`SchemaFingerprintTests` 追加 SF-10~15，全量 `swift test` **362 条通过、known issue 归零**。
期望摘要值全部由 `shasum -a 256` 外部算得（`f38a6d2e1eec35e6`、`dc6c2489a90d04ff`、`33cccb9b51dfebc0`、
`050952caf8c37288`、`76d332eda1077afd`、`c4fb71d81abfc0c6`、`5ec202c920bdbd2f`）。

### 9.3 指纹碰撞破口：已修（2026-09-30 当日销账）

SF-10 首跑钉住一个真缺陷：`joined(separator: "\n")` 使 `["a","b\nc"]` 与 `["a\nb","c"]` 得到**同一指纹**
（都是 `ea7fb08b7a2dc461`）。现实中描述行不含换行，但这条判据的全部职责就是"变了必须翻"，**碰撞即漏判**。

修法已落：拼前逐行转义，**反斜杠最先**，再换行、回车。三条配套证据：

- 修后两组各自锚定新值（`c4fb71d81abfc0c6` ≠ `5ec202c920bdbd2f`），SF-10 从 strict-xfail 转普通断言，
  原 SF-10a「记录现状」删除 —— 读数翻转即修好证明。
- **既有锚值一条没动**（TC-02/03/04、SF-11/12/13 仍绿）⇒ 转义不影响不含换行的正常描述行，
  已写盘的指纹不会因此误判成"schema 变了"。
- **转义顺序是真约束，已实测**：把两步替换反过序，`"a\\nb"` 与 `"a\nb"` 会拼成同一个 `a\\nb` 再度相撞；
  正确顺序下不撞。SF-10 里那条反向对照专抓这次改动。

### 9.4 对本计划的更正（含对"更正"本身的更正）

1. ~~`MigrationStage.lightweight` 在 macOS 14 可能不可用~~ —— **我错了，已用 SDK 接口文件推翻自己**。
   `MacOSX15.5.sdk/.../SwiftData.swiftinterface:688-692` 写明 `MigrationStage` 整体是
   `@available(macOS 14, iOS 17, ...)`，`.lightweight(fromVersion:toVersion:)` 是它的 case 之一。
   我上轮把 WWDC25 示例里给**子类支持**打的 `@available(iOS 26,*)` 读成了给 lightweight 打的。
   ⇒ §3.3 表格里"属轻量兼容 ⇒ 照常开库"这一格**恢复原判据**，但仍须由 SG-02 实测确认轻量迁移在
   本数据模型上真的能吃掉"加可选字段"（这是团队实测层面的问题，不是 API 可用性问题）。
2. **"不给迁移就静默重建空库"不是 Apple 的承诺**，来源是本工程 `CLAUDE.md:416` 的团队实测。
   整个 0-B 的动机建在它上面 ⇒ **SG-02 必须先跑**（克隆库上故意改模型不加 stage，看库到底空不空），
   否则我们在给自己讲的传说装防线。
3. **描述行的可用字段以 SDK 为准**（v3 §3.3 里我凭记忆写的 `originalType`/`hasDefaultValue`/`isIndexed`
   在 `SchemaProperty` 上**不存在**）。实测可用：`name`、`originalName`、`valueType`、`isAttribute`、
   `isRelationship`、`isTransient`、`isOptional`、`isUnique`；`Entity` 侧另有 `superentityName`、
   `relationships`（含 `destination`/`deleteRule`/`inverseName`）、`uniquenessConstraints`。
   ⇒ 关系基数与唯一约束**能**进指纹，v3 §9.1 说的"漏译关系基数"这个担忧撤回。
   **唯一真取不到的是 `Entity.indices`（`#Index`），它要 macOS 15+** ⇒ 指纹判据的效力上限收窄成一句话：
   **索引变更不翻指纹**，其余 schema 变更都会翻。
4. 上轮我称"GC 会在前序迁移失败时误删素材"**说过头了**：`OrphanFileFinder.safeOrphanFiles` 已有两道
   保守守卫（`OrphanFileFinderTests.swift:32-46`）。残留风险收窄为：**前序部分失败、引用集非空且与磁盘
   有交集时两道守卫都不拦** —— 仍是真缺口，但严重度从中降到中偏低。

### 9.5 守死码销账（批 3.3 的前置）

`SubtitleMaskModeTests.swift:23`「未知 style 退回 blur」现在把**错误行为钉成契约**。批 3.3 落地时必须
摘掉它并改成**四档往返断言**，否则这条绿测试会守住"把无字幕读成模糊+烧字幕"的缺陷。

### 9.6 D-2 用例归属（与实现同轮写，不提前造空壳）

| 组 | 编号 | 挂到哪一步 |
|---|---|---|
| 账本单元 | LL-01~07（blocked / requires 存在性 / 幂等 / 顺序无关 / throttled 三点法 / 传递闭包 / **11 个老键不重跑**） | §3.6 第 1 步 |
| 门与备份 | SG-01~06（计数不变 / **SG-02 假设证伪实验** / integrity_check 与保留 3 份 / sidecar 缺失或被写坏 / 并发开库 / **前序失败⇒GC 不删文件**） | §3.6 第 2、6 步 |

### 9.7 一条踩过的雷（写下来免得重踩）

`BrandIdentityTests` 会扫 `MixCut/`、`Sources/`、`Tests/` **全部非注释行**，命中 `Brand.displayName` 或
`Brand.shortName` 即判违规 ⇒ **新文件的类型名与测试字面量都不许带品牌字样**。本轮首跑就被它拦下两处：
`SunCutSchemaV1/SunCutMigrationPlan` 改名 `AppSchemaV1/AppMigrationPlan`，测试里的库名改用中性 `data.store`。
（这条守卫是有效的，不是噪音。）
