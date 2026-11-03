# 文件夹混剪 · 修复「与库对接的键错位」（真机第 5 步抓出的阻断缺陷）

计划落笔日：2026-10-22。主台账：`docs/superpowers/plans/2026-10-20-folder-mix-by-category.md`（第二轮改判的决议与风险都从 D23 / R25 起编，记在那本账上；本文件只记这一族缺陷的决议、拆笔与读数，决议编号从 **J1** 起，避免与主台账的 D/R 撞号）。

本文件自己的台账：修订记录 R1–R6，6 条（第八节），执行进展见第九节，测试覆盖拓展见第十节，**落地读数见第十一节**。笔 J1/J2/J3 已完工，剩真机三腿与 `xcodebuild test` 两条要用户跑。

一句话根因：**混剪把「用户素材目录里的路径」当成了与 SwiftData 库对接的外键，而库里那一行的路径是拷贝后的 `<AppSupport>/videos/<contentHash>/<文件名>` —— 两个域共用一颗键，join 永不相交。**

修法一句话（评审 R2 定的）：**不再事后反查库里的任何一颗键 —— 入库那一刻「哪个源文件落进哪一行」已经在服务手里，让它把这张对应关系交回来。**

---

## 一、取证状态表

| 类别 | 条目 |
|---|---|
| 已实读核过 | 本文件所有 `文件:行号` 均为 2026-10-22 用 `grep` 实读的输出；跑 `python3 scripts/check_plan_doc_citations.py <本文件>` 可复核。评审那一轮新增的四条承重事实也逐条回实码取过（见第九节第二行） |
| 已跑（真机现场） | 用户本机跑「预览 50 条组合」⇒ 4 个类别全部入库成功、50 条全部被摘行。日志原文见第二节 |
| 已跑（机器腿·改前基线） | 〔2026-10-22 修复前〕`swift test` 1306 通过 / 4 known issues、17 道门 PASS、既有变异台架全咬中（把数逐支记在主台账的取证表里，本文件不复述） —— **全绿而真机第一步就废**，这正是本计划要补的那格（见第二节的判据缺陷分析） |
| 已跑（机器腿·落地后） | 逐条读数在第十一节：`swift test` **1324 通过 / 4 known issues**（混剪族 123→141）；17 道门 PASS + 门自测 17 把全咬；新台架 `stepJ` **12 把全咬中**且还原 md5 自证；typecheck / silgen / build / build-for-testing 四项 PASS；App 腿新增 2 条真实往返判据并编译进 target |
| 未跑 | 只剩两腿：真机三条分支腿 + 反向确认；`xcodebuild test`（会拉起宿主、与 8787 端口相冲，按本仓规矩由用户跑）。另 `check_mcp_api_guards.sh` 本轮被环境挡住——端口 8787 被用户开着的实例占住，按纪律不杀活实例 |
| 待人工 | 真机三条分支腿（第六节 1–3）+ 精确档叠加那半句；版面 900×600 目测。机器腿那边 TC-J2/J3 已把同样两条分支在内存容器 + 真 ffmpeg 源上压过，但**真库真目录**那一趟只有用户能跑 |
| 已拍 | 用户指令「全部执行」⇒ 按甲案（入库当场交回对应关系）落地，笔 J1/J2/J3 完工，第十节 TC-J1…J8 也已落地（TC-J9 未做，理由见第十一节）。**没有待拍项**；TC-J2/J3 需要的内存容器也不是新立——本仓 `MixCut/App/DebugSelfTest.swift` 早有两处自建形状，照搬即可 |

---

## 二、现场与根因

### 日志（`~/Library/Caches/com.suncut.app/logs/suncut.log`，2026-10-22 08:59–09:00）

```
09:00:23 ℹ️ [FolderMix] 入库完成：项目「爆点」  新建整片段 0、仅关联 9、 失败 0
09:00:23 ℹ️ [FolderMix] 入库完成：项目「爆点2」 新建整片段 0、仅关联 26、失败 0
09:00:23 ℹ️ [FolderMix] 入库完成：项目「卖点」  新建整片段 0、仅关联 12、失败 0
09:00:23 ℹ️ [FolderMix] 入库完成：项目「卖点2」 新建整片段 0、仅关联 12、失败 0
09:00:23 ❌ [FolderMix] 全部行被摘掉 requested=50 shortfalls=50
08:59:52 ℹ️ [FolderMix] 扫描 蓝莓拆分：类别 4、… 库里命中时长 0、待探 59
```

「仅关联」= `importOrLink` 命中 `contentHash` 走了幂等关联分支（这批素材此前已被导入过），**入库这一步一条都没失败**；红字里那句「素材入库或解析失败（档 ingestFailed）」是**归因错位**。

### 键为什么永不相交

| 侧 | 那颗键实际是什么 | 出处 |
|---|---|---|
| 混剪候选 | 用户素材目录里的绝对路径（根目录 + 一级文件夹 + 文件名） | 〔改前读数 2026-10-22：`FolderMixViewModel.swift:227` 的 `beginScan` 在 `:247` 拼出 `MaterialEntry`〕—— 修复后这段仍在，只是行号随本次改动移到 `MixCut/ViewModels/FolderMixViewModel.swift:234` 的 `beginScan` |
| 库里那一行 | 拷贝落地的库内路径 `<videos>/<contentHash>/<原文件名>` | `MixCut/Utilities/FileHelper.swift:264` 按 `contentHash` 建目录、`MixCut/Services/Import/ClipIngestService.swift:171` 的 `Video(name: url.lastPathComponent, localPath: destURL.path)` |

两处拿它当外键用，于是双双落空：

1. 〔改前读数 2026-10-22：`FolderMixViewModel.swift:527` 的 `videoByPath` 表〕—— 先按 `video.localPath` 建索引，再用 `candidate.path` 去查 ⇒ 永远 `nil` ⇒ 全部落进 `.ingestFailed` 兜底分支 ⇒ 每一行都"同类别内无可换"⇒ 50 条全摘。
2. 〔改前读数 2026-10-22：`FolderMixDurationReader.swift:45` 的 `paths.contains`〕同一颗键 ⇒ 第一层命中恒 0（日志「库里命中时长 0、待探 59」，而这 59 条其实全在库里）。**「库里已算好的那份优先」这条承诺在这条通路上从未生效**，界面上「库里已有 X 条（零成本）」那句是空话。

### 这颗跨域键的全族站点（实测 6 处，逐处枚举；不许"修点不修族"）

| # | 站点 | 现状 | 处置 |
|---|---|---|---|
| 1 | 〔改前 527〕`videoByPath` 那张表 | 按库内路径建索引、按素材路径查 ⇒ 恒 miss | 删，换成入库当场交回的对应关系 |
| 2 | 〔改前 547〕`candidate.path` 与库内路径的相等比较 | **第二处同类比对，落在旧计划点名范围之外**；恒 false ⇒ `segmentIDByKey` 从未被填上（即使第 1 处修好，建方案仍会缺段） | 删，由 join 结果直接给段 id |
| 3 | 〔改前 45〕`paths.contains` | 恒 false | 见第五节：改**名字启发式**，且只服务成本预估 |
| 4 | 同文件 `:48` 的 `out[video.localPath]` | 取"第一条有值的那份"的去重键 | 同上，随第 3 处一起换键 |
| 5 | 同文件 `:53` 的 `out[video.localPath] = record` | 写入端与读取端同源（这颗键目前是自洽的，但键本身是错的域） | 同上 |
| 6 | `MixCut/Services/Import/FolderMixContentKeyReader.swift` 的 `plan.identityProbePaths` | 只喂"素材目录里的路径"给自己算校验和，**不与库比对** | 不动（它没跨域） |

判据要钉的是**残留 = 0**：改完后混剪链里 `video.localPath` 参与相等比较或字典下标的写法一处都不许剩（第 3–5 处换的是键，不是删功能）。

### 为什么全绿却废（判据层的根因）

`Tests/MixCutCoreTests/FolderMixResolveTests.swift:42` 的 FMX-14 测的是 `FolderMixResolver.plan` 这颗**纯函数**，夹具直接喂 `library["/r/A/a.mp4"]` —— 键与路径由夹具凭空约定，**从没经过"库里真实 localPath 长什么样"这一层**。join 键本身没有任何判据覆盖 ⇒ 键错位时 1306 条判据一条都不会红。这是「判据因错误原因通过」的又一形：判据证的是"给定命中则不读盘"，被当成"真实会命中"。

---

## 三、本计划引用的既有决议（只登记被本修复触及的，避免撞号）

| # | 议题 | 与本修复的关系 |
|---|---|---|
| D23 | 组合级不重复 | 摘行/替补的语义不变，只是喂给它的 resolution 不再恒空 |
| D25 | 懒入库 | 本缺陷是它的直接副产物：候选来源改成文件系统后，"与库对接"那颗键没跟着换 |
| D31 | 素材身份轴 | `identityKey` 在混剪内部仍用路径（自洽，不动）；**与库对接是另一颗键**，本计划把它分开 |
| D33 | 两层解析 | 第一层现在按 `localPath` 查 ⇒ 恒空。评审后改口：**正确性通路不再用"层"**（直接用入库交回的对应关系，天然精确）；名字启发式只留在**成本预估通路**上，并让文案与实现一致 |

---

## 四、决议（已按甲案拍定并落地；每条都留了推荐与代价）

| # | 议题 | 推荐 | 代价与替代 |
|---|---|---|---|
| J1 | 与库对接的键用什么 | **不反查，改"当场记账"**：入库服务把「哪个源文件落进哪一行」直接交回来（素材目录路径 → 那一行的持久 id）。证据：`MixCut/Services/Import/ClipIngestService.swift:263` 的 `importOrLink` 两支都返回行对象，而 `MixCut/Services/Import/ClipIngestService.swift:268` 的 `importedVideoIDs` 只记新建行的 id、`MixCut/Services/Import/ClipIngestService.swift:275` 的 `linkedExistingNames` 只留名字、把 id 丢掉（同一支下面 `:278` 已补上交回） —— **对应关系此刻是已知量**。于是混剪用的键始终活在候选自己那个域里，跨域比对彻底消失 | 代价三笔（都比"名字键"多）：① `ImportReport` 加 1 个字段；② `ClipIngestService.swift` 加 2 行写入；③ 新增写入点必须成对登记进特征化名册 `Tests/MixCutCoreTests/ClipIngestReadoutCharacterizationTests.swift:100` 的 `ingestSites`，否则 `:58` 那条"实得/应得"计数断言会红。收益：混剪用的键从今往后只活在候选自己那个域里，跨域比对没有存在的余地。〔另外那件"已经算好却没人用"的数据 —— 去重命中行的真实时长 —— 本笔**不**消费，见第七节"不做"最后一条〕 |
| J1-否 | 三个被否掉的键 | — | ①**文件名**（本节初版选的就是它，评审 S1/S2 否掉）：仍是跨域反查，只是换一颗较不撞车的跨域键；且 `MixCut/ViewModels/ImportViewModel.swift:46` 的注释早就把"按文件名字符串回查"判死为"替错素材"的形状，本计划不能与仓内既有判据反着走。②给 `Video` 加 `sourcePath` 列 ⇒ schema 迁移 + 把"挂载点一变就失效"的易碎量固化进库。③生成期先算校验和再按 `contentHash` 对接 ⇒ 默认档多付 8 MB/条，而 `importOrLink` 内部已经算过一次（同一件事算两遍） |
| J2 | join 逻辑住在哪 | **下沉成 Core 纯函数** `FolderMixLibraryJoin`（放 `Sources/MixCutCore/FolderMixOrchestration.swift`）。否则它留在界面模型里，`swift test` 那条腿看不见 ⇒ 这次的"全绿却废"会重演 | 多一个 Core 类型；换来 join 可判据、可注刀 |
| J3 | 扫描期的时长预估怎么兑现 | **保留按文件名的启发式，但降级为"只服务预估"**：命中数与歧义数分开报，文案写清"按文件名认出"是猜的。这里确实在入库之前、手上没有对应关系，只能启发式 | 猜不中就多读一次容器头（退回探针），不影响出片正确性。替代：整颗删掉 ⇒ 已在库素材也要逐条读盘才能报代价，与既有"两层解析"的初衷相反 |
| J4 | 「没认出来」还报不报「入库失败」 | **不报**。解析码分开：有行无整片段 ⇒ `.noWholeClipSegment`（档 B）；`codeByPath` 里有那颗码 ⇒ `.ingestFailed` 一族（档 A）；两者都不是却查不到 ⇒ 新码 `.notIngested`，文案写「入库后没找到这条素材」 | 加一颗码 = 一档一码（既有判据 FMX-09 的口径），不是复用 |
| J5 | 50 条重复红字怎么收 | 按（档, 类别）**聚合**成一句：「计划 50 / 实得 0：入库后没找到 50 条（爆点 9、爆点2 26、卖点 12、卖点2 12）」 | 逐条拼接在 N 大时完全不可读；聚合不丢信息（类别与档都在） |
| J6 | 记账的粒度：记到"行"还是记到"段" | **记到行 id，段 id 由 Core 判形状时现取**。服务只交 `(源路径, 行 id)`，"哪条段覆盖整片"仍由既有形状判据定（`Sources/MixCutCore/WholeClipShape.swift:85` 的 `isWholeClip`） | 多一次投影；换来"入库服务不兼职判段"，职责不混。替代：服务直接返段 id ⇒ 把 D25 那条"绝不替解析不到的素材补建整片段"的判据搬进服务，风险 9 那族门要重开 |

---

## 五、实现方案（拆笔单位是机理；判据与改动同笔）

### 笔 J1 · Core：对应关系的形状 + join 下沉 + 判据 + 刀

`Sources/MixCutCore/FolderMixOrchestration.swift` 新增（键自始至终只有候选自己那个域里的"素材文件绝对路径"）：

```swift
/// 入库当场交回的一条对应关系：这个源文件落进了库里哪一行。
/// 注意记的是**行 id**，不是段 id —— 哪条段覆盖整片由形状判据现取（决议 J6）。
public struct FolderMixIngestedRow: Equatable, Sendable {
    public let sourcePath: String      // 素材目录里的绝对路径 == FolderMixCandidate.path
    public let videoID: UUID           // 那一行的持久 id（不持模型对象）
}

/// Core 只认这两样；从 SwiftData 取数是 App 层的投影活。
public struct FolderMixRowShape: Equatable, Sendable {
    public let videoID: UUID
    public let wholeClipSegmentID: UUID?   // nil = 有行但没有覆盖整片的段（档 B）
}

public enum FolderMixLibraryJoin {
    /// 把「每类别的候选」与「入库交回的对应关系 + 行形状」折成 resolution 与 键→段 id。
    /// 未命中时的档位判定见决议 J4：先认入库失败码，再落新码 notIngested。
    public static func resolve(candidatesByCategory: [String: [FolderMixCandidate]],
                               ingested: [FolderMixIngestedRow],
                               shapes: [UUID: FolderMixRowShape],
                               failureCodeBySourcePath: [String: FolderMixFailureCode]) -> FolderMixJoinOutcome
}
```

`FolderMixJoinOutcome` 必须**自带计数**（`ingestedCount` / `hitCount` / `noWholeClipCount` / `failedIngestCount` / `notIngestedCount`），因为这两个地方都要吃它：界面上的聚合红字（决议 J5）与下面那条结构化日志。判据不读日志、日志不进判据，两头都会退化成"肉眼数方案"。

日志一行（形状照本仓既有 `[FolderMix] …` 口径，落在 `generate()` 里 join 之后）：`[FolderMix] 对接：交回 N、命中 M、无整片段 b、入库失败 a、没找到 k`。**这五个数就是第六节三条真机腿的判据物**，不许靠截屏数。

判据（`FolderMixOrchestrationTests` 内新增一族）：

**夹具形状是硬定义，不是自觉**（这次的根因正是"夹具凭空约定键"，所以形状本身要先被钉住）——
- 库内那一行的路径必须写成 `"/Library/Application Support/<品牌>/videos/<校验和>/<原文件名>"`（校验和段是真的，不是占位符）；
- 素材候选的路径必须写成 `"/Users/x/素材/<类别>/<原文件名>"`；
- **JOIN-0 夹具自检**：断言这两个串**互不为前缀**、且库内串含 `/videos/` 段。这条腿的作用：谁哪天把夹具"顺手"改成同一个域，判据族立刻红，而不是悄悄退化成"自洽的假绿"。

- **JOIN-1 主腿**：候选 `path = "/Users/x/素材/爆点/钩子A.mp4"`、入库交回 `(同一条 path → videoID)`、形状给 `wholeClipSegmentID` ⇒ 解析成功且 `segmentIDByKey` 填上。**这条是本缺陷的复现腿**：任何"按库内路径反查"的写法都必红。
- **JOIN-2 档 B**：入库交回里有这颗 path，但形状 `wholeClipSegmentID == nil` ⇒ `.noWholeClipSegment`，且**不报**「入库失败」。
- **JOIN-3 档 A**：`failureCodeBySourcePath` 给了 `.diskShortfall` ⇒ 报档 A 且带那颗码（不许被兜底改写成"没找到"）。
- **JOIN-4 新码**：入库没交回这颗 path、也没有失败码 ⇒ `.notIngested`，文案含「入库后没找到」。
- **JOIN-5 重复交回**：同一个 `sourcePath` 被交回两次（重试/双批）⇒ 取第一条有形状的那份并计数，不静默覆盖成"最后写的那条"。
- **JOIN-6 类别隔离**：两条同类别与跨类别的 path 各自命中各自的行，**不许把一张全库大表当 join 源**（这条钉的是"只认入库交回的那批"，与 `ensureProject` 会复用同名既有项目这件事直接相关：`MixCut/ViewModels/ProjectViewModel.swift:279` 的 `ensureProject` 有则复用 ⇒ 项目里可能躺着上一轮的旧行）。
- **JOIN-7 分界判据（同内容、不同文件名）**：`爆点/钩子A.mp4` 与 `卖点/同款素材.mp4` 内容相同 ⇒ 第二颗走的是去重命中分支、库里那行的 `name` 是第一次引入它的那个文件名（`MixCut/Services/Import/ClipIngestService.swift:158` 的 `findExistingVideo` 全库按校验和取第一条、命中就原样返回不改名）。**这条腿在"当场记账"下绿、在任何"按名字反查"下必红** —— 它是甲案与乙案的判据，不是可选项。
判据族到 JOIN-7 为止（含 JOIN-0 夹具自检，共 8 条）。库里那行现成的时长**本笔不消费** —— 理由见第七节"不做"最后一条：那是另一笔的功能，混进修复笔里会让回归半径说不清。

台架：`.scratch/fm_mutate_stepJ.py`，逐把登记"只红自己那条"的读数 —— 至少六把：把键改回按库内路径反查、把档 B 与档 A 的码合并成一颗、把重复交回改成"后写覆盖"、把未命中兜底成 `.ingestFailed`、把 join 源改成全库大表（不看入库交回的那批）、**把夹具里两颗路径改成同一个域（必须只红 JOIN-0，不许让主腿跟着变绿）**。

### 笔 J2 · App：让入库服务交回对应关系 + 删掉两处反查 + 文案与错误聚合

**① 服务侧（本笔唯一碰"母体链共用件"的地方，改动面 1 字段 + 2 行）**

- `MixCut/ViewModels/ImportViewModel.swift:22` 的 `ImportReport` 加一个字段：`ingested: [FolderMixIngestedRow]` —— **直接复用 Core 那两颗字段，不再发明一个匿名元组**（同文件 `:39` 的 `FailedItem.code` 已经证明"Core 类型放进 `ImportReport`"是本仓既有形状：Core 源文件是逐颗编进 App target 的，所以这里不需要 `import`）。**纯追加**：现有消费者只读 `failed` 与 `abortMessage`（`MixCut/ViewModels/FolderMixViewModel.swift:498-514`），母体导入页读 `importedVideoIDs` / `linkedExistingNames` —— 加字段不改变任何既有读数。
- `MixCut/Services/Import/ClipIngestService.swift:269` 与 `MixCut/Services/Import/ClipIngestService.swift:270` —— 两支各补一句 `ingested.append`，把此刻已在手的 `url.path` 与 `video.id` 记下。**仅关联支正是这次 59 条走的那条，也是唯一原本把 id 丢掉的那条。**
- 新增的写入点**成对登记**进 `Tests/MixCutCoreTests/ClipIngestReadoutCharacterizationTests.swift:100` 的 `ingestSites` 名册并跑该族 5 条（`:58` 的"实得/应得"计数断言会自己核对，漏登记当场红）。

**② 混剪侧（删反查、接 join）**

- `MixCut/ViewModels/FolderMixViewModel.swift` 的 `generate()`：把每个批次 `importClips` 交回的对应关系累积成一张 `ingested`，随后按行 id 投影出 `FolderMixRowShape`（整片段用 `Sources/MixCutCore/WholeClipShape.swift:85` 的 `isWholeClip` 判），喂 `FolderMixLibraryJoin.resolve`。
- 站点 1 与站点 2 一起删（〔改前 527〕那张按库内路径建的表、〔改前 547〕那句 `candidate.path` 相等比较 —— 后者恒 false，所以只修前者的话键→段 id 那张表照样是空的）。**落地读数**：这张表现在只剩 `MixCut/ViewModels/FolderMixViewModel.swift:536` 的 `segmentIDByKey`（整表赋值，值来自 join）一处、`MixCut/ViewModels/FolderMixViewModel.swift:466` 的 `segmentIDByKey`（每次生成开头的清空）一处、**下标写入 0 处**；声明在 `:115`、读取在 `:916`。
- 站点 3–5（〔改前 45/48/53〕那三处按库内路径的读写）改成按名字建索引 + 同名唯一才采信、返回 `(records, ambiguousCount)`；`beginScan` 与代价文案（`MixCut/ViewModels/FolderMixViewModel.swift:303` 的 `probeCostNote`）改准为「按文件名**猜**出 X 条已在库（零成本）、同名歧义 Y 条退回探针、需新算 Z 条」，并在注释里写明这层**只服务磁盘与耗时预估，不参与出片正确性**（正确性走 ①②，那里没有猜）。

**③ 错误呈现**：摘行报告按决议 J5 聚合（`Sources/MixCutCore/FolderMixOrchestration.swift:214` 那句 reason 保留档名，聚合发生在 VM 的 `errorMessage` 组装处）。

**④ 守卫**：`check_folder_mix_guards.sh` 的 LANE 不变（已含两颗 reader）。新增门 **T-30** 钉的是**用法与写入点计数**，不是变量名（初版写成"某些标识符不得出现"，换个名字就绕过，还会误伤合法用法）：

- 腿 A（残留 = 0）：混剪链的文件里，库内路径参与相等比较或字典下标的写法 0 处 —— 按 API 用法扫，数法照 `Tests/MixCutCoreTests/FolderMixIngestGuardTests.swift:491` 的 `computeFileHash`（"定义处恰好 1 处"那种数法），不扫标识符。
- 腿 B（**三类分开数**，落地后的真实形状）：B1「形如 `segmentIDByKey[` 的下标写入」= 0 处（改完不留下标写入）；B2「整表赋值」恰好 1 处且右侧必须是 join 的产物；B3「整表清空」恰好 1 处（每次生成开头那次，既有纪律）。初版写的"赋值点恰好 1 处"会把清空也数进去 ⇒ 落地即红，而红了的门最容易被"顺手放宽计数"救活 —— 那正是假绿的起点（名册对账口径同 `Tests/MixCutCoreTests/FolderMixIngestGuardTests.swift:348` 的 T-20）。
- 腿 C（不许绕过服务）：混剪链不得自己 `FetchDescriptor<Video>` 再去猜对应关系 —— 对应关系只能来自 `importClips` 的返回值。
- 每条腿配"钩子扫得到"的正对照（注入一处违规必须红），否则判据与"恒真"看不出区别。

### 笔 J3 · 收口与台账

全腿复跑（见第六节读数），主台账补：它自己的 §九 两档措辞改口（档 A 不再兜"没找到"）、执行进展一行、修订记录 **R51**（真机第 5 步抓出的 join 错位 + 「FMX-14 的夹具把键约定凭空写死 ⇒ 判据因错误原因通过」+「初版选的名字键仍属跨域反查，被分界判据 JOIN-7 否掉」）。本文件的第八节、第九节同步回填读数。

---

## 六、验证（每条都要有读数；跑不了的写明待人工）

**机器腿**

- **纯逻辑腿**：`swift test` 全量（基线 1306 / 4 known issues），JOIN-0…7 逐条配刀并跑全量取红 set，逐把对"只红自己那条"。**JOIN-7 是分界判据**：它必须在"按名字反查"的写法下红 —— 只验它在记账键下绿，等于没验。**JOIN-0 是夹具闸**：它要能在"有人把两颗路径改成同一个域"时独自红。
- **特征化腿**：改了 `importClips` 的写入点后，`ClipIngestReadoutCharacterizationTests` 全族 5 条要过（含"13 处一处不多一处不少"那条计数与顺序断言），且新写入点已在名册登记。
- **台架**：`.scratch/fm_mutate_stepJ.py` 六把全咬中；`selftest_folder_mix_guards.py` 复跑（T-30 的 A / B1 / B2 / C 四条各配自己的刀，含"注入一处违规必须红"的正对照）。
- **App 腿**：`MODE=typecheck` / `MODE=silgen` / `xcodebuild build` / `build-for-testing` 四项 PASS，`.scratch/dd` 重建。
- **文档门**：`python3 scripts/check_plan_doc_citations.py` 对本文件与主台账都跑一遍（DOC CLEAN）。

**真机腿（待用户跑；这三条各压一条分支，缺一条就是"只验了 happy-path"）**

1. **仅关联支**（这次的现场）：同一份「蓝莓拆分」目录 → 选目录 → 条数 50 → 点「预览 50 条组合」→ 再点一次生成。期望日志「入库完成：… 仅关联 N、失败 0」后**不再**出现「全部行被摘掉」，侧栏汇总项目「文件夹混剪」出现 50 条方案。
2. **新建整片段支**（这批素材全在库里 ⇒ 本条从未被压过，而它才是日常主用法）：拿一个**从没导入过**的文件放进某个类别目录再跑一次；或直接换一份干净的新素材目录。期望日志出现「新建整片段 ≥ 1」，且这一条照样出方案。**这条不过 = 修复只覆盖了半条通路。**
3. **同内容、不同文件名支**（决议 J1 甲案的机器侧证据）：把某类别里一个文件复制到另一个类别目录下并**改名**，再跑预览+生成。期望：那条素材正常被选中（走的是去重命中、库里那行的名字是原文件名）。按名字反查的写法在这里必然摘行 —— 所以这条腿就是甲案与乙案的分界。
4. **精确档叠加半句**（打开「精确识别（慢）」再跑一遍第 1 条）：期望扫描期那句提示走校验和口径、不再出现"猜"字（身份轴与对接轴各管各的，这条钉它别互相踩）。
5. 扫描期成本提示的预期值（**期望，不是承诺**）：这批素材的 59 条大多已在库里，"按文件名猜出已在库"的命中数应显著大于 0；若歧义数 Y > 0，判读口径是"同名不同内容的素材按预期退回探针"，属正确行为不是缺陷。版面 900×600 不纵向滚动一并目测。

**以上四条腿的判据物统一是那行对接日志的五个数**（交回 / 命中 / 无整片段 / 入库失败 / 没找到）：第 1、2 条要读到「命中 = 计划条数 × 类别数、没找到 = 0」，第 3 条要读到「命中 ≥ 那条改名素材所在行」，第 4 条要读到提示串里没有"猜"。数方案条数只能当旁证，不能当判据。

**因果腿**

- **反向确认**（最便宜的因果证明）：修好后把 join 的取键临时改回"按库内路径反查"重编译，第 1 条真机腿的症状必须原样复现；不复现就说明还有第二条通路在错。

---

## 七、风险与不做

- **新不变式的生效条件（照本仓对注入点的规矩写进代码注释与这里，三件都要）**：**生效条件** = 每条候选在解析之前必然已经过入库那一趟（实测 `MixCut/ViewModels/FolderMixViewModel.swift:481` 起的那个 `batches` 循环就是干这件事）；**拦不住什么** = 将来若有"不入库、直接引用外部文件"的第三条通路，这张表是空的；**最坏代价** = 整批被判成「入库后没找到」，错误落在最表层、离真因最远 —— 所以要靠 JOIN-4 那颗新码与那条日志把"没交回"和"没入库"分开。**证伪条件**：一旦日志里「交回 N」与「候选总数」对不上而入库又报成功，就是这条不变式被破，本族判据应立刻红而不是静默降级。
- **字段生命周期**：`ImportReport` 不是 `Codable`，`MixCut/Services/MCP/AgentJobRegistry.swift:39` 的 `report` 只活在内存作业表里（注册表自己的注释就写着"app 重启后任务会丢失"）⇒ 这张对应关系是**会话内临时量**，不落盘、不进任何持久化结构；后来人若要留，得先回答"跨重启的路径还有效吗"（挂载点一变就失效，正是当初否掉 `sourcePath` 列的理由）。
- **外部契约面（评审取证补登，初版漏了这一层）**：`ImportReport` 不只被界面消费 —— MCP 工具 `get_job` 会把它序列化进 Agent 侧返回（`MixCut/Services/MCP/MCPToolHandlers.swift:327` 的 `linked_existing` 那批键）。那里的键是**显式列举**的 ⇒ 新字段不会自己漏出去，但落地时**不得顺手把它加进那个字典**（改了就是外部契约变更，要按本仓 MCP 契约的规矩走）。同时实测 `ClipIngestService.importClips` 今天只有一个生产调用方（混剪 `MixCut/ViewModels/FolderMixViewModel.swift:497` 的 `importClips`）：母体导入页走的是另一条 `MixCut/ViewModels/ImportViewModel.swift:146` 的 `importVideos`，而适配层 `MixCut/ViewModels/ImportViewModel.swift:595` 的 `importClipsWithoutAnalysis` 当前无生产调用方 ⇒ 服务侧那 2 行的真实影响面只有混剪这一条。
- **回归半径（比初版计划宽，必须如实登记）**：`Sources/MixCutCore/FolderMixOrchestration.swift`、`MixCut/ViewModels/FolderMixViewModel.swift`、`MixCut/Services/Import/FolderMixDurationReader.swift`、`MixCut/Services/Import/ClipIngestService.swift`（+2 行）、`MixCut/ViewModels/ImportViewModel.swift`（`ImportReport` +1 字段）、`Tests/MixCutCoreTests/ClipIngestReadoutCharacterizationTests.swift`（名册 +1 条）。**不动**数据模型（无 schema 迁移）、不动导出侧、不动 `importOrLink` 那六步的顺序与判定。
- **碰了母体链共用件的代价（这是甲案唯一比乙案贵的地方）**：`ClipIngestService` 与 `ImportReport` 同时服务导入页的阶段 1（调用点实测 2 处：`MixCut/ViewModels/FolderMixViewModel.swift:464` 与 `MixCut/ViewModels/ImportViewModel.swift:631`）。字段是**纯追加**、两支各写一句、不改任何既有读数 ⇒ 导入页行为面为 0，但特征化名册必须同步登记，否则那条"一处不多一处不少"的计数断言会红（这正是它该有的作用）。
- **二阶效应**（枚举后逐条判定，无则声明）：① 改对应关系来源 ⇒ 账本签名（按素材身份键记"已发出"）不受影响，那颗键本来就活在候选域内；② `ImportReport` 追加字段 ⇒ 结构体是 `Sendable` 的值类型，两处调用点各读自己的子集，无默认值语义变化；③ 时长启发式退出正确性通路 ⇒ 磁盘预估的"读不到时长就记 `—`、不计入预算"这条既有口径不变（它本来就不信任猜的值）；④ `segmentIDByKey` 写入点收成 1 处 ⇒ 「不持模型对象」那条既有纪律（防"真删后读死对象"那一族崩溃）由更多处变一处，只增强不削弱。
- **歧义/猜不中是真实边界，但只落在预估层**：默认档按文件名猜库里哪行是同一份内容，同名不同内容 ⇒ 判为歧义、退回探针，代价是多读一次容器头，**不会**读错时长、**不会**替错素材（正确性通路压根不用它）。要精确归并就打开「精确识别（慢）」（那颗键是内容校验和）。
- **不做**：不给 `Video` 加 `sourcePath` 列（把易碎量固化进库）；不在默认档为对接再算一次哈希（入库内部已经算过，且这次的修法正是去**消费**那次计算的结果）；不把 join 留在界面模型里（那正是"全绿却废"的成因）；不改 `importOrLink` 的哈希去重口径（它是对的，错的是我们没用它已经在手里的那份对应关系）；不把 `ImportReport` 的新字段暴露给导入页界面（母体链不需要它）；**不拿库里那行现成的时长去回填扫描期猜不中的「—」、也不改磁盘预估口径**（同一份内容 ⇒ 那行的时长就是真实时长，数据此刻确实可得，但那是独立一笔的功能；混进修复笔会让回归半径说不清 —— 留作这张对应关系的下一个接入口）。
- **本计划不新增决议号到主台账**：J1–J6 只活在本文件，主台账只在执行进展里指一次本文件 —— 避免同一事实两处登记会漂。

---

## 八、修订记录（本文件自己的账；编号从 R1 起重编，与主台账的 R 号无关）

| # | 日期 | 改了什么 → 落在哪一节 |
|---|---|---|
| R1 | 2026-10-22 | 真机第 5 步抓出 join 键错位，落本修复计划：根因（二）、引用既有决议（三）、J1–J5 决议（四）、笔 J1/J2/J3 拆法（五）、验证腿（六）、不做清单（七） |
| R2 | 2026-10-22 | 方案评审后改判（严重问题 3 条全收）：**对接键从"按文件名反查"改判为"入库当场交回对应关系"**（新增决议 J1-否 记录被否的三种键与理由、新增决议 J6 定记账粒度）；判据补 JOIN-7（同内容不同名 = 甲乙案分界腿）与 JOIN-8（时长红利）〔R3 已撤 JOIN-8，改列进第七节"不做"〕，JOIN-5/6 语义随键改写；门 T-30 从"标识符黑名单"改判为"API 用法 + 写入点计数 + 正对照"三条腿〔R4 把腿 B 再拆成 B1/B2，现为 A/B1/B2/C 四条〕；跨域键站点从 2 处补成全族 6 处（第二节新增逐处枚举表，含初版漏点的〔改前 547〕）；验证新增"新建整片段支"与"同内容不同名支"两条真机腿（初版只压到一条分支）；第七节回归半径如实放宽（初版"不动 `ClipIngestService`、`ImportViewModel`"那句已不成立）并补二阶效应四条 |
| R3 | 2026-10-22 | 三维架构评审（生长性 / 健壮性 / 跨模块回归）取证补两层 + 修两处行号腐烂：① 第七节新增"外部契约面"那条 —— 入库报告会被 MCP 的取任务工具序列化给 Agent 侧，新字段禁止进那个字典；并实测出"服务只有一个生产调用方"这条把回归半径从"母体链共用件"缩到"仅混剪"；② 仅关联支的行号由 273 修正为 272、对接证据的行号补齐完整路径（原文按评审要求保留勘误痕迹，不删条目） |
| R4 | 2026-10-22 | 三维评审的 P1 四条 + P2 三条全部并入（P0 为零，故不阻断）：**P1-1** 门 T-30 的腿 B 拆成 B1 下标写入 / B2 整表清空两类分开数（现网实测三处赋值 + 一处读，混着数会落地即红）；**P1-2** 夹具形状改成硬定义并新增 JOIN-0 夹具自检（两颗路径互不为前缀、库内串含 `/videos/` 段），台架随之加第六把刀；**P1-3** `FolderMixJoinOutcome` 自带五个计数 + 新增那行对接日志，并把第六节三条真机腿的判据物统一改成这五个数（数方案条数降为旁证）；**P1-4** 第七节新增"新不变式的生效条件 / 拦不住什么 / 最坏代价 / 证伪条件"四件套。**P2-5** `ImportReport.ingested` 改用 Core 的 `FolderMixIngestedRow`，不再发明匿名元组（同文件既有 `FailedItem.code` 先例）；**P2-6** 新增字段生命周期那条（会话内临时量，不落盘）；**P2-7** 第六节新增"精确档叠加"半句。判据族计数由 7 条改为 8 条（JOIN-0…7） |
| R6 | 2026-10-22 | **笔 J1/J2/J3 落地**（用户指令「全部执行」）：Core 加 `FolderMixIngestedRow`/`FolderMixRowShape`/`FolderMixJoinOutcome`/`FolderMixLibraryJoin` + 新码 `notIngested` + `shortfallText`；服务两支各交回一次并成对登记进 CR 名册（13→15 处）；解析步两处跨域猜键删除（改后键表只剩一处整表赋值、下标写入 0）；扫描期时长层降级为名字启发式（新纯函数 `FolderMixNameHeuristic`，规则 H1–H3）；摘行红字按（档, 类别）聚合；新增那行对接日志成为真机腿的判据物；门 T-30（腿 A/B1/B2/C）与 T-31 落地并各配正对照；App 腿第一颗混剪判据 `MixCutAppTests/FolderMixIngestJoinTests.swift`（TC-J2/J3）写好并登记进 target。读数逐条见第十一节。同轮勘误两处：① 本文件初版「全仓无内存容器先例」是只扫测试目录得到的错结论（实为 DebugSelfTest 早有两处）；② 第十节 10.4 与第一节随之改口；主台账侧 R51 登记本缺陷族与「算得对≠归因对」那条经验的再命中 |
| R5 | 2026-10-22 | 新增第十节「测试覆盖拓展」（特殊→一般→特殊 闭环，只出方案不生成代码）：种子按实数盘点（Core 混剪族 123 条 / App 腿 4 个文件 / 6 个套件 / 24 条 @Test，**混剪在 App 腿里是 0 条** —— 这是"全绿却废"的第二块证据）；模式库 12 维（含本缺陷族专属的 KEY-01 身份必须显式携带、KEY-03 键的可变性、META-01 夹具形状真实性）；差距矩阵三层逐项标 ✅/❌/➕；新识别用例 TC-J1…J9，其中 **TC-J1 两支计数门 = P0**（它钉的正是现网"只在新建支记、仅关联支丢 id"这个形状），TC-J2/J3 需先拍 App 腿要不要新立内存数据容器；**三条写结案不新增**（已被既有判据挡住 / 属不可达分支，为其造用例只能造恒真断言）；外部经验取到一手 Identity Field 定义（Fowler 原文），"脏夹具 + 夹具指纹"条目命中多为二手摘要、按降级标注且结论不依赖它 |

---

## 九、执行进展（落地时逐行回填，勘误不删原文、加〔已修订〕）

| 日期 | 产出 | 取证 |
|---|---|---|
| 2026-10-22 | 计划落笔，未动任何生产码（等拍） | `python3 scripts/check_plan_doc_citations.py docs/superpowers/plans/2026-10-22-folder-mix-join-key.md` 读数见交付说明 |
| 2026-10-22 | 方案评审（dev-expert 的 code-review 链）⇒ 计划按 R2 改判，仍未动任何生产码 | 评审证据全部回实码取：对应关系此刻在手里 `MixCut/Services/Import/ClipIngestService.swift:262`；仅关联支把 id 丢掉 `:272`；去重返回旧行不改名 `:158`；仓内已判死名字反查 `MixCut/ViewModels/ImportViewModel.swift:35`；同族站点实测 6 处（第二节表） |
| 2026-10-22 | 三维架构评审（生长性 / 健壮性 / 跨模块回归）⇒ 按 R3 补两层取证与两处行号，仍未动任何生产码 | `ImportReport` 的下游消费者实测 3 处：MCP 取任务工具 `MixCut/Services/MCP/MCPToolHandlers.swift:327`、导入页适配层（当前无生产调用方）、混剪。`importClips` 的生产调用方实测恰好 1 处 ⇒ 回归半径收窄为"仅混剪"。文档门复跑 DOC CLEAN |
| 2026-10-22 | 评审的 P1 四条 + P2 三条并入计划（R4），判据族扩到 JOIN-0…7，仍未动任何生产码 | 腿 B 的口径缺口来自实测计数：`MixCut/ViewModels/FolderMixViewModel.swift` 里那颗表的三处赋值与一处读取；MCP 载荷的键是显式列举（`MixCut/Services/MCP/MCPToolHandlers.swift:327` 那批）⇒ 新字段不会自动外泄；`ImportReport` 非 `Codable`（`MixCut/Services/MCP/AgentJobRegistry.swift:39` 只在内存持有）⇒ 生命周期结论成立 |
| 2026-10-22 | 测试覆盖拓展方案（第十节，TC-J1…J9 + 结案件 3 条），仍未动任何生产码，也未生成任何测试代码 | 种子计数为实跑读数：`grep -c '@Test'` 逐族求和 = 123（Picker 27 / Scanner 21 / IngestGuard 19 / Orchestration 14 / SessionState 10 / DiskSpaceBudget 12 / WholeClipShape 8 / Resolve 7 / ClipIngestReadout 5）；App 腿目录实测只有导出与音色：4 个文件 / 6 个套件 / 24 条 @Test（`@Test` 与 `@Suite` 分开数，早前写的 30 是把两类混着数了）；全仓探测不到内存数据容器工厂 |
| 2026-10-22 | **笔 J1/J2/J3 落地完毕**：Core 4 个新类型 + 新码 `notIngested`；服务两支各交回一次（CR 名册 13→15）；解析步两处跨域猜键删除；扫描期降级为名字启发式；聚合红字；对接日志；门 T-30（A/B1/B2/C）+ T-31；App 腿首颗混剪判据 TC-J2/J3；注册工具与登记闸扩到 App 测试目录 | 读数全在第十一节：`swift test` 1324 / 4 known issues（族 141）、台架 stepJ 12/12、门自测 17/17、typecheck+silgen+build+build-for-testing 四项 PASS、pbx 128 颗、两份文档 DOC CLEAN。**未跑**：真机三腿 + 反向确认 + `xcodebuild test`（均待用户）；`check_mcp_api_guards.sh` 被活实例占端口而阻塞 |

---

## 十、测试覆盖拓展（第三轮该补的格子；方案，未生成代码）

种子盘点（实数，非回忆）：Core 混剪族 **123 条** = Picker 27 / Scanner 21 / IngestGuard 19 / Orchestration 14 / SessionState 10 / DiskSpaceBudget 12 / WholeClipShape 8 / Resolve 7 / ClipIngestReadout 5；App 腿 **4 个文件 / 6 个套件 / 24 条 @Test**，全部是导出与音色 —— **混剪在 App 腿里是 0 条**（实测 `MixCutAppTests/` 目录只有 Export*、VoiceClone*）；变异台架 6 支、守卫脚本 11 份。

**这一格就是"1306 条全绿而真机第一步就废"的第二块证据**：判据密度全在纯函数层，跨接缝的那条通路（文件系统 → 服务 → SwiftData → join）一层判据都没有，源码形状门只看得见"写了什么串"，看不见"跑起来对不对"。

### 10.1 模式库（本缺陷族用到的维度；「种子」列空 = 缺口）

| 维度 | 说明 | 种子 |
|---|---|---|
| KEY-01 身份必须显式携带 | 内存对象与库行之间的身份要由数据带着走，不能用派生属性反查（外部经验：Identity Field） | 本轮新增 JOIN-1…7 |
| KEY-02 键的唯一性与基数 | 同名多行 / 重复交回 / 歧义判定 | JOIN-5、JOIN-6 |
| KEY-03 键的可变性 | 显示名可被改、挂载点会变 ⇒ 不许当外键 | JOIN-7、第七节"不做" |
| IN-05 编码与字符 | macOS 文件名走 NFD 正规化；空格 / 引号 / 逗号 / CJK / 大小写 | **缺** |
| ST-01 状态迁移 | 预览 → 入库 → 解析 → 生成 → 记账，任一环中断的态 | FMX-19、覆盖面 |
| ST-02 终态与回滚 | 停止≠删除、建方案中途失败走删除咽喉回滚 | 档 A/B/C、G12 名册 |
| EX-03 下游依赖失败 | 磁盘预检整批中止、单文件读不出 | SHORT-1、SHORT-2 |
| INV-02 幂等 | 同一素材二次入库不叠第二段 | W 族 + T-25 + FMX-18 〔2026-10-22 第三轮：T-25 改口径，补建获准长在 ClipIngestService 的补建支，幂等改由形状守门 + App 腿 JOIN-25 钉；见第三轮专账〕 |
| DATA-01 数据完整性 | 两支（新建 / 仅关联）都要把对应关系记全 | **缺**（本轮 59 条只压到一支） |
| CT-04 对外契约不外泄 | MCP 载荷的键是显式列举，内部字段不得自动外流 | **缺** |
| OBS-01 可观测性 | 五个计数的日志行是真机腿的判据物 | R4 新加，**尚无判据** |
| META-01 夹具形状真实性 | 判据的输入必须复刻生产形状；改断言不改夹具 = 假绿（外部经验：夹具指纹/脏夹具；亦即本仓 R2 那条「FMX-14 凭空约定键」） | JOIN-0 |

### 10.2 覆盖差距矩阵（✅ 已有 / ❌ 缺失 / ➕ 拟新增）

| 维度 | 单元（`swift test` 纯函数） | 集成（App 腿 / 源码形状门） | E2E（真机） | 来源 |
|---|---|---|---|---|
| KEY-01 身份显式携带 | ➕ JOIN-1、JOIN-7（第五节已排期） | ❌ 服务两支→SwiftData→join 的真实往返 0 条 | ✅ 真机腿 1–3（R4 已列） | 内置 + 外部(Identity Field) |
| DATA-01 两支记全 | ❌ | ➕ T-31 两支计数门 | ✅ 真机腿 2（新建支） | 内置模式库 |
| IN-05 编码与字符 | ➕ | ❌ | ❌ | 内置 + 外部(脏夹具) |
| CT-04 对外契约 | — | ➕ | ✅ 手动跑一次 MCP 取任务对照键 | 内置 |
| OBS-01 日志读数 | ➕（计数由 Core 返回，可直接断言） | ❌ 日志行本身无判据 | ✅ 三腿以五个数为准 | 内置 |
| ST-02 / EX-03 / INV-02 | ✅ 既有 14 + 19 + 8 条 | ✅ T 族 19 条 | ⚠ 待人工 | 内置 |
| META-01 夹具形状 | ➕ JOIN-0 | ❌ | — | 外部(检索) + 本仓 R2 根因 |

### 10.3 用例清单（本轮新识别；每条都能回溯到 10.1 的一行，无来源不新增）

| 编号 | 层级 | 标题 | 回溯 | 输入 | 预期 | 优先级 | 落点 |
|---|---|---|---|---|---|---|---|
| TC-J1 | 集成（形状门） | 两支各记一次对应关系 | DATA-01 | 扫服务体内 `ingested` 写入点 | 恰好 2 处、新建支与仅关联支各 1；只在新建支写 ⇒ 红（这就是现网的形状） | **P0** | `FolderMixIngestGuardTests` 新门 T-31 + 台架一把刀 |
| TC-J2 | 集成（App 腿） | 真实 SwiftData 往返：仅关联支 | KEY-01 | 内存容器里先塞一行同校验和的视频，再入库一个**改名后**的文件 | `ingested` 里这条 path 有行 id、join 命中、段 id 非空 | P1 | 新文件 `MixCutAppTests/…`（**需先拍：App 腿目前无内存 SwiftData 容器先例**） |
| TC-J3 | 集成（App 腿） | 真实往返：新建支 | DATA-01 | 空容器 + 一个从未导入的文件 | 新建行 + 整片段 + join 命中三件事同时成立 | P1 | 同 TC-J2 |
| TC-J4 | 单元 | 文件名正规化差异不替错素材 | IN-05 | 候选名 NFD、库内行名同字符 NFC | 预估层判为"没认出"退探针；正确性层（记账键）不受影响、命中不变 | P1 | `FolderMixResolveTests` 补一条 |
| TC-J5 | 单元 | 大小写不同的两颗不许并成同名 | KEY-02, IN-05 | 同类别两颗 `钩子.mp4` / `钩子.MP4` | 名字启发式不许 case-insensitive 合并；歧义计数 = 2 | P2 | 同上 |
| TC-J6 | 单元 | 脏文件名照常记账 | IN-05, META-01 | 名字含空格、「、」，引号、逗号、emoji | 对应关系命中；日志五个数与预期逐一对上 | P2 | JOIN 族夹具直接扩一行 |
| TC-J7 | 单元 | 整批没入库时不许谎报"入库后没找到" | EX-03, ST-01 | `ingested` 空 + 批级中止原因在 | 报中止档、不逐条落新码 `notIngested` | P1 | `FolderMixOrchestrationTests` 一条 |
| TC-J8 | 单元 | 摘掉的行不进取号账本 | ST-01, INV-02 | 生成失败回滚后重抽同一序号 | 签名账本零污染（既有 FMX-06/07 已证"预览不消耗组合"，这条只补"失败也不消耗"） | P2 | `FolderMixPickerTests` 一条 |
| TC-J9 | 集成 | 内部字段不外流进对外载荷 | CT-04 | 对照 MCP 取任务返回的键集合 | 键集合与既有台账一致、无新增；新字段缺席 | P2 | `check_mcp_api_guards.sh` 的既有名册口径 |

**已排期不重复列**：JOIN-0…7（第五节笔 J1，8 条）。
**写成结案件（查过既有判据，确认不该再加）**：① "未交回的键当不可用" —— 已由 Orchestration 的「覆盖面：resolution 里没出现过的键当不可用」钉住；② "重复交回不叠第二段" —— 已由 W 族 + T-25 + FMX-18 三处钉；③ "同一条 path 出现在两个批次" —— 实码上批次按类别切、类别内 path 互斥，属**不可达分支**，按规矩不为其造用例（要造也只能造恒真断言）。

### 10.4 框架探测清单（已探得，生成时沿用）

Swift Testing（`@Test` / `#expect`，非 XCTest）；Core 判据落 `Tests/MixCutCoreTests/`、App 腿落 `MixCutAppTests/`（module 名 `SunCut`，`@testable import SunCut`）；源码形状门的既有写法是"扫文件文本 + 计数 + 名册对账"（`FolderMixIngestGuardTests` 的 T-20 / T-27 两种口径）；夹具惯例是**在测试内现造纯值**，〔勘误 2026-10-22：这里初版写「全仓无内存容器先例」，那句是**只扫了测试目录**得到的错结论——实读 `MixCut/App/DebugSelfTest.swift` 里已有两处自建内存容器（`isStoredInMemoryOnly`），TC-J2/J3 正是照那个形状写的，前置成本比初版估的低一档〕；运行命令 `swift test`（Core，机器腿）与 `xcodebuild test`（App 腿，**会拉起宿主、与 8787 端口相冲，按本仓规矩由你跑**）。

### 10.5 外部经验来源与可信度

- **Identity Field**（Fowler，POEAA 目录页原文）：「Saves a database ID field in an object to maintain identity between an in-memory object and a database row.」—— 本轮甲案的经典同名模式：身份靠携带，不靠派生属性反查。可信度：权威一手（已 WebFetch 取到原文定义）。
- **脏夹具 + 夹具指纹同变更**：检索命中的是二手中文摘要（CSDN 农场系），要点可用但**未取到权威原文**，按降级标注 —— 它的价值已由本仓 R2 那条「FMX-14 的夹具把键约定凭空写死」独立成立，故不依赖该来源。可信度：低，只作旁证。

---

## 十一、落地读数（2026-10-22，笔 J1–J3 完工当轮实跑）

| 腿 | 读数 | 口径 |
|---|---|---|
| 纯逻辑 | `swift test` → **1324 通过 / 0 真失败 / 4 known issues**；混剪族 **141 条**（Picker 27 / Scanner 21 / Orchestration 24 / IngestGuard 23 / Resolve 11 / Budget 12 / WholeClip 8 / SessionState 10 / CR 5） | 改前基线 1306 / 123 ⇒ 本轮 +18 条（JOIN 族 10 + 名字启发式 4 + 新门 4） |
| 特征化 | CR 全族 5 条 PASS；名册从 13 处变 **15 处**（两支各一句 `ingested` 已登记，`ingestSites` 现 4 条） | 漏登记会被"实得/应得"计数断言当场抓红，不是靠人记 |
| 台架 | 新支 `.scratch/fm_mutate_stepJ.py` **12/12 全咬中**，还原 md5 自证（5 颗文件）；`selftest_folder_mix_guards.py` **17/17** | K1/K9/K10 三把专证「改回反查就会红」；K8 只咬 JOIN-0；App 侧那四把是源码扫描腿的读数，不代替编译/运行 |
| 门 | 17 道 PASS；GuardTests 19→**23**：T-30A 跨域猜键 = 0、T-30B1 下标写入 = 0、B2 整表赋值 = 1 且必须来自 join、B3 清空 = 1、T-30C 对应关系唯一来源 + 取数按 id + 读全表文件名册、T-31 两支各记一次且顺序锁定 | 每条都带"注入违规必须红"的正对照，防恒真 |
| App 四腿 | `MODE=typecheck` PASS / `MODE=silgen` PASS（17 批）/ `xcodebuild build` **BUILD SUCCEEDED** / `build-for-testing` **TEST BUILD SUCCEEDED**；`.scratch/dd` 已重建 | TC-J2/J3 只证到"编译进 target"，**跑**归用户 |
| 登记 | `check_pbx_registration.py` PASS：128 颗（Core + App 测试目录全量）≥4 段，新那颗四段齐全 path 正确 | 本笔顺带把注册工具与登记闸扩到 `MixCutAppTests/`（此前只认 `MixCut/`，测试文件会被判成"拼写错了"） |
| 文档 | 本文件与主台账都 **DOC CLEAN**；主台账 15 张表 / 223 数据行 / 修订记录 R1–R51 五十一条自洽（2026-10-22 当天读数，现状声明在它自己的〇节） | 两份同源互指：修复机理在主台账 §九 与 R51，判据与拆笔在本文件 |

**未做与原因**（不含"以后再说"式含糊）：
- 真机三条分支腿 + 反向确认腿：只有用户的真库真目录能跑（第六节 1–3）。
- `xcodebuild test`：会拉起宿主实例并抢 8787 端口 ⇒ 按本仓纪律交用户。
- `check_mcp_api_guards.sh`：本轮实跑被环境挡住（端口已被用户开着的实例占用，脚本自己报"请先退出它"）。按纪律不杀用户实例，故这条腿读数缺失，**不是**通过。
- TC-J9（MCP 键集合对照）随之一起没跑 —— 但它防的是"新字段被顺手加进对外载荷"，代码层面那批键是显式列举的（`MixCut/Services/MCP/MCPToolHandlers.swift:327`），本次没有改动那张字典；等端口空了与上面那条腿一起补跑。
- 一处**既有**编译告警非本轮引入：`MixCut/ViewModels/FolderMixViewModel.swift:495` 的 `var hooks` 未被修改（笔 5 留下的形状），本轮不顺手改，登记在此。
