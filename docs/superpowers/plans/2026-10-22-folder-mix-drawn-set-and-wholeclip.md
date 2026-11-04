# 文件夹混剪 · 第三轮：抽中集错位（必修 bug）＋「整片段资格」这条硬约束（已拍：甲-隐）

计划落笔日：2026-10-22。三份真源分工：

- 主台账 `docs/superpowers/plans/2026-10-20-folder-mix-by-category.md`（决议台账、修订记录、失败分档都在那本账上）；
- 第二轮专账 `docs/superpowers/plans/2026-10-22-folder-mix-join-key.md`（与库对接的键，决议 J1–J6、判据 JOIN-0…7，落地读数记在它自己的收尾一节）——**那一族已闭**；
- 本文件只记第三轮的缺陷与取证：缺陷一（抽中集错位）、二（整片段资格）、三（库内文件不在盘上，成因另案）、四（混剪不消费可用性）四条，外加四笔执行细则。决议编号从 **K1** 起，避免与主台账的 D/R 和专账的 J 撞号。

本文件自己的台账：修订记录 R1–R10，10 条（第八节），执行进展见第九节。**技术评审（A 类三维）照出的三条新同笔项在第十节，等签字后才并进笔 K2；第十一节是测试覆盖评估（差距矩阵 + 用例清单，尚未生成任何测试代码）。****第五节是本轮的执行细则（R4 重写），等签字；签字前零代码改动。**

一句话根因（两条，互相独立）：**① 入库清单取的是"每类池子的前缀"，不是"这一批真抽中的那几条" ⇒ 小批量 + 大目录时抽中的素材根本没入库；② 混剪把"可用"绑在"库里那行恰好有一条覆盖全片的段"上，而用户主力素材四分之三当年是按分镜导入的 ⇒ 结构性用不了。**

---

## 一、取证状态表

| 类别 | 条目 |
|---|---|
| 已实读核过 | 本文件所有 `文件:行号` 为 2026-10-22 用 `grep` 实读的输出；跑 `python3 scripts/check_plan_doc_citations.py <本文件>` 可复核 |
| 已跑（真机现场，用户贴回） | 人参果拆分2：4 类池子 56/52/43/54、条数 5 ⇒ 计划 5 条一条没出；日志 `对接：交回 32（重复 0）、命中 8、无整片段 24、入库失败 0、没找到 173`。算术核对见第二节 |
| 已跑（机器腿·现状基线） | 第二轮落地后：`swift test` 1324 通过 / 4 known issues、混剪族 141 条、门 17 道 PASS、台架 5 支全咬、App 四腿 PASS。**这一批全绿而真机仍出不来** ⇒ 见第二节"为什么全绿" |
| 未跑 | 本计划落地后的全部腿（落地时逐条回填读数） |
| 已跑（取证·用户贴回） | 缺陷三**已定性**（见第二节末）：库里 163 行的库内拷贝路径在磁盘上不存在，且「0 条路径不在素材目录内」⇒ 排除品牌前缀漂移，是文件真没了；163 这个数从 10-20 到 10-22 一模一样 ⇒ 一次性历史事件。同轮照出**缺陷四**（更要紧）：混剪完全不消费这份已经算好的可用性 ⇒ 会把缺失素材抽进方案 |
| 待人工（成因） | 缺陷三的**成因**仍待查（更早一轮删除/回收，还是人工清理 Videos），归母体链另案；本文件不猜 |
| 已拍 | **K2 = 硬需求**（用户 2026-10-22 原话「是硬需求」）⇒ 丙（只报清楚）出局；方向 **甲-隐**（补建 + 可见性标记）已由用户 2026-10-22 明确「确认选甲-隐」，乙 保留为「不愿动 schema 时的退路」。 |
| 已勘误（R4 实读）| 甲-隐 的代价我原先**报大了**：原写「要走一次 schema 迁移 = 升版本 + 写一条自定义迁移阶段」。实读 `CLAUDE.md:483`（只增行判成轻量兼容、备份后照常开库）⇒ 版本锚点与迁移清单都不动；本仓先例两颗：`MixCut/Models/SchemaVersions.swift:39` 的 `Product`、`MixCut/Models/SchemaVersions.swift:55` 的 `VoiceProfile`，都是加完未冻结新版本。细则见第五节「笔 K2」。另：K4 原先写「要 refresh 并等它落终态」——实读 `MixCut/Infrastructure/MaterialAvailabilityStore.swift:121` 那颗判定本体是 `nonisolated static`、入参是值类型，且已有非界面调用方（同一颗 `missingDivideReading`，`MixCut/App/MixCutApp.swift:1389`）⇒ **直接调那颗，不等异步、不碰共享集**，二阶效应第⑤条随之改口。 |
| 已拍（R5）| 用户「按推荐更新计划」⇒ K2-4 那三处可见面按推荐全部落定：① 概览与导入页**一起藏**；② AI 方案生成候选池**必须过滤**；③ MCP 面**本轮只登记 + 取证**不动。另按推荐新增决议 **K9**（显示与生成面收口到一颗唯一出口，实测 18 处要挂 + 8 组必须豁免，见 K2-6） |
| 已拍（R6）| 用户「按推荐」⇒ 笔 K2 **一轮做完、拆两个提交**（提交 1 = 字段 + 补建 + 唯一出口 + 分镜库那一族含撤销两条腿 + 门；提交 2 = 其余 12 处全量挂出口 + 名册对账）。**交付窗口内不留可见面不一致**，回退单位仍是两个。 | 
| 待拍（评估后新增）| 三维评审（见第十节）照出 **3 条要并进笔 K2 同笔清单**才敢开工：① `TombstoneReadGuardTests` 那张 45 处基线名册会因收口而红，必须同笔重生成并逐条说明去向；② 那颗唯一出口若是计算属性，在 `ForEach` 里逐卡调用会把概览页从「一次读全 + 缓存」退化成「每卡全遍历」，要定体形并用现成的 `[Perf]` 读数点验收；③ 出口体内那一处关系读取本身是墓碑读族的新登记点，得进名册而不是被当成豁免。 |
| 已核（评估补）| `check_undo_guards.sh` 只数 `broadcast`/`post`/`schedule`/`safeSave` 四类站点 ⇒ 本方案不动它们，风险低（实测该脚本 218/236/258 行）；`MediaAvailabilityGuardTests` 内**无** `video.segments` 名册（grep 零命中）⇒ 收口不会打红它 |
| 待取证（用户跑） | 缺陷三的**成因**：本轮实读已把头号嫌疑收窄到「回收那条轴的比对尺子」（见第二节末「成因收窄」），剩下要用日志时间轴与字符形状两条读数坐实 |

---

## 二、现场与根因

### 缺陷一：入库清单 = 池子前缀，不是抽中集

`Sources/MixCutCore/FolderMixOrchestration.swift:179` 这一行：

```swift
for candidate in pool where paths.count < drawn + reserve {
```

它按**池子顺序**取前 `drawn + reserve` 条，与"这一批随机抽中的到底是哪几条"无关（抽中数只当计数用）。余量公式在 `Sources/MixCutCore/FolderMixPicker.swift:344` 的 `substituteReserve`（radix 大时给 3）。

**用户贴回的日志把这件事钉死了**（每个数都对得上算术）：

| 读数 | 对上什么 |
|---|---|
| 交回 32 | 4 类 × (5 抽中 + 3 余量) = 32 ⇒ 清单确实是前缀，与抽中集无关 |
| 没找到 173 | (56+52+43+54) − 32 = 173 ⇒ 池子里除前缀外全部没入库 |
| 命中 8 + 无整片段 24 = 32 | 交回的每条都被判定 ⇒ 第二轮那颗键的错位已闭，join 本身不再漏 |
| 入库失败 0 | 拷贝与关联一步没错 ⇒ 上一版那句「素材入库失败」确属归因错位 |

**为什么 1324 条判据全绿**：`Tests/MixCutCoreTests/FolderMixOrchestrationTests.swift:93` 的 FMX-18 只核三件事——建哪几类、清单去重、条数不超上限，外加一条 provenance（清单里的串必须是真实路径）。**没有一条核"抽中的那几颗必须在清单里"**。而它下面两条（余量封顶、默认公式）同样只看数量。⇒ 「判据因错误原因通过」在这一族的第三次（前两次：FMX-14 的键约定、CR 名册的读数）。

**为什么上一份目录没犯**：蓝莓拆分那次条数 50、池子 9/26/12/12 ⇒ 抽中数 ≥ 池子 ⇒ 前缀恰好等于全池。所以这条 bug 的触发条件是 **条数 ≪ 池子大小**，也就是"小批量 + 大素材目录"这个日常用法。用户把条数拉到 56 后出了 56 条方案（截图里 自定义 #5 = 2.3+6.8+5.2+17.1 = 31.4s 与页头一致）——这既是绕过手段，也是这条根因的反证。

### 缺陷二：「有整片段」被当成资格，而它是历史通路的结果

`MixCut/Services/Import/ClipIngestService.swift:265` 只在 `video.segments.isEmpty` 时补建整片段；否则走 `:274` 的**只关联**支（这是防"重扫同一目录叠出两条整片段"的既有幂等纪律，判据 W 族 + 门 `Tests/MixCutCoreTests/FolderMixIngestGuardTests.swift:789` 的 T-25）。于是：

- 库里那行若是当年从「素材导入」页建的**分镜**（若干条不覆盖全片的段），混剪永远判档 B；
- 决议 D19/④案 + T-25 明令混剪**绝不补建**整片段；
- 现场读数：**无整片段 24 / 交回 32 = 75%** ⇒ 这条不是边角，是用户主力素材的常态。

**架构层的错位在哪**：混剪真正需要的量是「这一条视频 + 它的整片时长」，而实现把它表达成「库里存在一条 `Segment` 行」——因为建方案的入口 `MixCut/ViewModels/SchemeViewModel.swift:954` 的 `createCustomScheme` 吃 `[Segment]`。**数据形状泄漏进了资格判定**：一条素材能不能混剪，取决于它当年从哪条通路进的库。这是本缺陷族的根，不是"哪一行写错了"。

### 缺陷三（已定性，成因另案）：库内拷贝文件不在盘上

截图那条「源文件已不存在：辅17.mp4 可能已被删除或移动」查的是**库内拷贝路径**——`MixCut/Infrastructure/MaterialAvailabilityStore.swift:67` 拿 `video.localPath` 去 stat。混剪在去重命中支**不拷文件**，所以对这条只是依赖、不是制造。三类可能来源（孤儿回收 `MixCut/App/MixCutApp.swift:1353` 的 `scheduleOrphanGCIfDue` / 数据目录搬迁后的路径前缀漂移 / 人工清理过 Videos 目录）已用第六节那三条命令分清，读数与判读见下面两节。

### 缺陷三定性（用户 2026-10-22 贴回的取证读数）

```
[OrphanGC] 库里有 163 条素材记录的 localPath 在磁盘上不存在（只报不删；另有 0 条路径不在素材目录内、0 条读不动）
[可用性对账] 本轮问了 161 条：缺失 161、未参与判定 0、读不动 0、判据降级=false
[可用性对账] 本轮问了 8 条：缺失 8、未参与判定 0、读不动 0、判据降级=false      ← 今天 15:11 与 15:13，混剪那一跑之后
ls -R …/Videos | grep -c "辅17.mp4"  →  0
du -sh …/MixCut_virgin/Videos → 0B   /   …/Suncut/Videos → 2.3G
```

| 读数 | 判掉了什么 |
|---|---|
| 「0 条路径不在素材目录内」 | **排除品牌前缀漂移** —— 漂移的形状是 `excludedRecords > 0`（`MixCut/Infrastructure/MaterialAvailabilityStore.swift:35` 的这颗就是为它留的）。那 163 行的路径**在**现用 Videos 目录里，只是文件没了 |
| 现用根 `Suncut/Videos` 有 2.3G、旧根 `MixCut_virgin/Videos` 是 0B | 不是「行指向空壳旧根」；旧根是个空目录，不参与判定 |
| 163 从 10-20 11:02 到 10-22 08:58 一字不变 | 一次性历史事件，**不是现在还在删**；与那条日志自己写的「只报不删」一致（同一天 11:02:36 那次回收的 72 个是反方向的孤儿：文件在、库里无引用） |
| 今天「问了 8 条：缺失 8」× 3 轮 | 8 = 每类入库数（5 抽中 + 3 余量）⇒ 混剪这一跑关联上的行里，整批都指向缺失文件。这条是**推断**，坐实要看第六节新增那条腿 |

⇒ 缺陷三的**成因**归母体链/回收那一笔另案（见下面「成因收窄」+ 第六节取证组）；但它照出来的**缺陷四**归本轮，因为那是「建出来的方案是不是坏的」这一级。

### 成因收窄（本轮实读代码得到的，不是猜）

两条轴用的是**两把不同的尺子**，这正是本案的形状：

| 轴 | 用什么判 | 后果 |
|---|---|---|
| 可用性（库里有、磁盘无） | `MixCut/Infrastructure/MaterialAvailabilityStore.swift:121` 的 `missingDivideReading`：前缀白名单 + `FileHelper.materialProbe` 逐条 stat | APFS 自己兜住大小写与正规化差异 ⇒ **不会假报缺失**；而「0 条不在素材目录内」也证明这些路径确实带现用根前缀 ⇒ 那 163 条是**真没了**，不是判定误差 |
| 孤儿回收（磁盘有、库里无） | `Sources/MixCutCore/OrphanFileFinder.swift:9` 的 `normalize`：只 `lowercased()` 去尾斜杠，**不做 Unicode 正规化** | 库里记的名字与盘上的名字若 NFC/NFD 不同（含重音拉丁、谚文、部分兼容汉字），归一后**不相等** ⇒ 被引用着的文件被判成孤儿 ⇒ 删掉 ⇒ 剩下的正是「行在、文件没了」 |

**头号嫌疑**：某一次 `collectOrphanFiles` 把被引用的文件当孤儿删了（10-20 11:02:36 那一次就删了 72 个）。**未坐实前不落码** —— 要两条读数：① 日志时间轴上「回收 M 个」之后「库里有 N 条缺失」是否跳增 ≈ M；② 缺失那批的名字里 NFC≠NFD 的占比是否显著高于全库。两条都中 ⇒ 修的是那把尺子（`normalize` 补正规化，或让回收与可用性共用同一颗探针），不是混剪。

### 缺陷四：混剪不消费「已经算好的可用性」

`MixCut/Infrastructure/MaterialAvailabilityStore.swift:28` 的 `missingVideoIDs` 是全仓**唯一**持有者，语义写在它自己头上：「库里有、磁盘无 ⇒ 只能不再显示」。今天它在四个消费点工作（导入页、分镜库、播放组件、App 层），**唯独混剪链零引用**（实测 `MixCut/ViewModels/FolderMixViewModel.swift` 与 `MixCut/Services/Import/` 三颗文件里这颗符号命中 0）。

于是混剪的资格判定是「有行 + 有整片段 ⇒ 可用」，缺的那一格恰恰是**「文件还在不在」**。后果不是报错，是**建出一批导出必坏（或黑屏）的方案** —— 比 K1 的「出不来」更坏：它出得来，坏在后面。

**为什么全绿**：可用性这条轴整套判据都在（`MediaAvailabilityGuardTests` 的 TC-MA 族，含「两轴判定结果互不重叠」那条），但它管的是显示；混剪的资格判定在另一颗文件里，两边都没义务认识对方。⇒ 「已算好却没被消费」那一族的老配方，只是这次缺的消费者是新写的混剪。

---

## 三、本计划引用的既有决议（只登记被本修复触及的）

| # | 议题 | 与本修复的关系 |
|---|---|---|
| D23 | 组合级不重复 | 抽中集必须被完整入库，否则"不重复"是在一堆没入库的候选里挑 ⇒ 与本缺陷一同修 |
| D25 | 懒入库 | 入库清单的语义（"抽中集 ∪ 余量"）就是它定的；实现走样成前缀，本轮把它对齐 |
| D19 | 整片段与状态代次纪律 | K2 三个候选全部触及它：**要么反转"混剪不补建"，要么把整片段从资格判定里摘掉**，属改判不是修 bug |

---

## 四、决议（K2 与 K2-4 三处可见面均已拍；第十节另浮出三条同笔项待定体形）

| # | 议题 | 推荐 | 候选与代价 |
|---|---|---|---|
| K1 | 入库清单怎么算 | **先装抽中的那些**（按 `rows` 的 picks 取路径），再用池子其余补到余量；判据补「每行每格的路径都在该类清单里」的硬断言 | 替代：把替补池限制在已入库前缀内 ⇒ 随机性被破坏（组合总数仍按全池算），且等于承认"只用前 8 条"，否 |
| K2 | 「有整片段才算可用」这条资格怎么处置（**已拍：硬需求 ⇒ 丙出局 ⇒ 甲-隐**） | **甲-隐**：混剪对"有段但无覆盖全片的段"的行补建整片段，并给这条段加一颗可见性标记，分镜素材库默认不列它。**代价已于 R4 改小**：只增一颗带默认值的字段 ⇒ 轻量兼容，不升 schema 版本（详见第五节 K2-1），剩余代价是"隐形段的可见面要逐面表态"（K2-3 那张表）| **甲-显**（补建但不加标记 ⇒ 分镜库混进一条覆盖全片的段，用户看得见、W 族判据要重开）；**乙**（建方案侧改成"整片引用"，不依赖库里那条段 ⇒ 语义最干净，但 `createCustomScheme` 与导出侧 `MixCut/Services/Export/ExportService.swift:165` 的 `ExportInput.from` 都吃 Segment，而它有 MCP 调用方 ⇒ 等于改对外契约，半径最大）；**丙**（不补建，只把这类素材如实计数报出来并给出路 ⇒ 零风险，但按 75% 这个比例，等于该功能对用户主力素材不可用）——已出局 |
| K3 | 补建动作归谁、怎么防重复叠 | 补建只在 `ClipIngestService.importClips` 那一支发生（本轮核实：**那颗服务函数全仓只有混剪一个生产调用方** ⇒ 不需要"哪条链"的入参），守门三条见 K2-2；母体分镜链一行都不动 | 代价：T-25 那道门（"混剪不得成为 `commitWholeVideo(` 的第三个调用方"）要**改口径而不是删掉**，并配正对照。这条必须同笔改判据，否则门会把修好的代码打红 |
| K4 | 库内文件缺失的**成因**（缺陷三）| **本轮不落码**，只跑第六节取证组二；若坐实为"回收误删"，另开一笔挂到母体链 | 混剪侧由**笔 K4**（决议 K6/K7）负责"别让它静默"——两个 K4 是不同东西：决议 K4 = 成因另案，笔 K4 = 可用性进资格。这一轮的坏数据只挡在生成前，不去改任何记录 |
| K6 | 资格判定要不要吃可用性 | **要吃**：`FolderMixRowShape` 加一颗 `filePresent`，缺失的行判成新档「素材文件不在盘上」，**不许进方案** | R4 实读改口：原先这里写的硬约束是「必须对该项目 refresh 并等它落终态，否则串进上一个项目的缺失集」——**已消掉**。那颗判定本体 `MixCut/Infrastructure/MaterialAvailabilityStore.swift:121` 是 `nonisolated static`、收值类型入参、且已有非界面调用方（`MixCut/App/MixCutApp.swift:1389` 打的就是那颗 `missingDivideReading`）⇒ 混剪直接调它，既不碰共享集也不引入时序依赖。仍守的约束只剩一条：**不许造第二个持有者、不许自拼 fileExists** |
| K7 | 「查不了」怎么处置 | 判据不可信时**整批不建并说明查不了**（那颗读数的 `degraded` 就是这一档）| 替代：放行并标注未校验 ⇒ 与本仓「我查不了必须显示成查不了，不许伪装成没丢」那条既有口径相反，否 |
| K8 | 缺陷三的成因怎么查 | **另开一笔**（母体链/回收），本文件只登记嫌疑与取证清单，不与混剪四笔混做 | 若坐实是 `normalize` 那把尺子：修法是「回收与可用性共用同一颗判定」，属破坏性路径的判据变更 ⇒ 必须配「回收前逐名落日志」这条读数点，否则下次还是只能开 sqlite3 手查 |
| K9 | 隐形段的可见性怎么收口（R5 新增）| **一颗唯一出口**：在 `MixCut/Models/Project.swift` 照 `videoNoByVideoID` 的先例（`:66` 那颗「UI 卡片 # 与 MCP video_no 的唯一定义处」）新增「可显示段投影」这一颗，实测 18 处显示/生成面一律调它，**不在各点各写一遍 filter** | 反例（否）：18 处各写 `.filter { !....mixInternalWholeClip }` ⇒ 本仓「对称契约同源 / 半迁移 = 0」那条铁律直接破，且少改一处就是第二个真源。代价：一处新出口 + 一名册闸（凡枚举段的上屏/生成面要么走出口、要么显式登记豁免）|
| K10 | 「库里那行的文件没了」要不要自愈（真机首跑照出来的结构洞） | **先只给出路，不动共用入库动作**：界面那句红字已经点名 materialMissing，下一步加一条可行动的出路文案（放回文件 / 删掉该记录后重新导入）| 自愈方案（去重命中时若库内拷贝缺失就重新拷盘并改写 `localPath`）**半径比想象大**：那颗 `importOrLink` 是三条通路共用的入库动作（生产调用方两处：`MixCut/ViewModels/ImportViewModel.swift:466` 的母体链 与 `MixCut/Services/Import/ClipIngestService.swift:263` 的混剪链）⇒ 改它等于改母体导入语义，且库内路径那一颗字段被多项目共享，一次改写会同时动到别的项目那一行。同形先例有：启动期那颗 `MixCut/App/MixCutApp.swift:1283` 的 `rewriteStoredPathPrefixes` 就是「库内路径与盘上不符时改写库」，并自带 `uncovered` 那格不静默放过。要做就单独一轮、配逐名日志与判据 |
| K5 | 档 B 的措辞 | 改成能行动的句子，并分"补建成功/仍拿不到"两档出声（原文见第五节笔 K3）| 现在的「素材在库里、但没有覆盖整片的段」是事实但不可行动，用户只能猜 |

---

## 五、实现方案（拆笔单位是机理；判据与改动同笔）

**落笔顺序固定为 笔 K1 → 笔 K4 → 笔 K2 → 笔 K3**（编号按缺陷登记先后，不按执行序）：抽中集先对齐、可用性先接进资格，最后才动整片段那条改判 —— 补建绝不允许发生在文件已缺失的行上。

两点消歧：**笔 K4** 落实的是决议 K6/K7（把可用性接进资格判定），与**决议 K4**（缺陷三的成因，本轮不落码）不是同一件事。**每笔都是"改动 + 判据 + 刀"三件同笔交付**，判据名册里任何一条没配刀就不算落完。

### 笔 K1 · 抽中集对齐（独立、必修、零语义风险）

改一处纯函数（`Sources/MixCutCore/FolderMixOrchestration.swift:177-182` 那四行），形状是「先装抽中集，再用池子其余补余量」：

```swift
// ① 先把这一类**真被抽中的那些**装进清单（保参与顺序、按键去重）
let drawnKeys = rows.flatMap { $0.picks }.filter { $0.category == category }.map(\.identityKey)
let byKey = Dictionary(pool.map { ($0.identityKey, $0) }, uniquingKeysWith: { first, _ in first })
var seen = Set<String>()
var paths: [String] = []
for key in drawnKeys where seen.insert(key).inserted {
    if let hit = byKey[key] { paths.append(hit.path) }
}
// ② 再用池子其余补到 drawn + reserve 封顶（余量公式与封顶一个字都不动）
for candidate in pool where paths.count < drawn + reserve {
    guard seen.insert(candidate.identityKey).inserted else { continue }
    paths.append(candidate.path)
}
```

- **上限、去重、provenance 三条既有断言的口径不变**（`Tests/MixCutCoreTests/FolderMixOrchestrationTests.swift:210` 的 FMX-18 仍是 `<= drawn + reserve`），只是清单的**来源**换了。
- **不改余量语义**：`reserve` 仍是 `min(FolderMixLimits.substituteReserve, pool.count - drawn)`（`:176`）。
- **替补腿为什么不用改**：`FolderMixPicker.substitute`（`Sources/MixCutCore/FolderMixOrchestration.swift:222` 的调用点）拿的是全池，但它被 `unusableKeys` 约束，而 `unusable` = 全池键 − 已入库且可用的键 ⇒ 替补天然只会落在**已入库**的那批里。K1 只欠"抽中集本身没入库"这一格，不欠第二格。
- 判据名册：
  | 判据 | 断言 | 为什么今天没有它也不会红 |
  |---|---|---|
  | FMX-18d（新）| 对任意 (rows, pool) 组合：**每行每格的 `identityKey` 所对应的那条 path，必须出现在该类的入库清单里** | FMX-18 只核"建哪几类、去重、条数上限、是真实路径"，全是数量与来源，没有一条把"抽中的那几颗"和"清单"对上 |
  | FMX-18e（新）| 夹具改成 **条数 ≪ 池子**（池 54、抽 5），且把抽中集造在**池子尾部** ⇒ 断言**抽中集的路径集合 ⊆ 清单**（是包含关系，不是「清单条数 == 5 + 3」）| 今天这批夹具的池子是 2–4 条、抽中 2–3 条 ⇒ 前缀恰好等于全池，这个洞在形状上看不见 |
  | FMX-18b/18c（既有）| 余量封顶与默认公式 | 已覆盖，本笔不许动 |
〔R5 勘正：本行原先写的是「断言清单含全部 5 条抽中路 **+ 3 条余量**」——那个「+3」是错的。`drawnPerCategory`（`Sources/MixCutCore/FolderMixOrchestration.swift:162`）数的是**出现次数**，跨行重复抽中同一条时它大于**不同键的个数**，而 `seen` 又按键去重 ⇒ 清单实际条数是浮动值。把条数写死成等号，就是在造一条会因夹具而假红的判据（本仓「判据因错误原因通过」那一族）。条数上界仍由 FMX-18 的 `<= drawn + reserve` 钉。〕
- 台架名册（`.scratch/fm_mutate_stepK.py` 支一）：
  | 刀 | 注入 | 期望只红 |
  |---|---|---|
  | K-a | 删掉 ① 那段（等于退回今天的前缀写法）| FMX-18d、FMX-18e |
  | K-b | ① 只装 `drawnKeys.prefix(1)` | FMX-18d |
  | K-c | 拆掉 `seen` 去重 | FMX-18 那条"路径清单有重复" |
  | K-d | 拆掉 `min(..., pool.count - drawn)` 封顶 | FMX-18b |
  | K-e | 把注入缝默认值写死成 `{ _, _ in 3 }` | FMX-18c |
- 这一笔**不碰**任何持久数据、不碰导出、不碰母体链、不碰 schema。
- **与 K2 的硬前提**：补建整片段绝不允许发生在文件已缺失的行上 ⇒ 落笔顺序固定 **K1 → K4 → K2 → K3**。

### 笔 K4 · 可用性接入资格（决议 K6/K7，必须先于 K2）

**挂点（R4 实读改口）**：不调 `refresh`、不读那颗共享集，直接调那颗判定本体
`MixCut/Infrastructure/MaterialAvailabilityStore.swift:121` 的 `nonisolated static missingDivideReading(records:)` —— 入参是值类型 `[MaterialRecordPath]`（定义在 `Sources/MixCutCore/MissingMaterialFinder.swift:28`），
已经有**非界面调用方先例**（`MixCut/App/MixCutApp.swift:1389` 的启动对账），且 `Tests/MixCutCoreTests/MediaAvailabilityGuardTests.swift:490` 那条 MAV-07 钉的就是"界面与启动日志共用这一颗"。
⇒ 于是 K6 原先那条"要等异步落终态、否则串进上一个项目的缺失集"的顾虑整条消掉：**没有状态可串，也没有终态要等**。判定内部仍走 `FileHelper.materialProbe` 那颗唯一探针，不新增第二把尺子。

- App 层：`MixCut/ViewModels/FolderMixViewModel.swift:588` 的 `rowShapes(for:context:)` 已经在那一趟 fetch 里拿到了这批 `Video`，顺手组出 `[MaterialRecordPath(id:, path: video.localPath)]` 送进那颗判定；**量的是库内拷贝路径**，与用户已经看见的那条横幅同一颗尺子（不是素材目录里的源文件）。
  - 签名改一处：`rowShapes` 多收一个 `missingIDs: Set<UUID>`（由调用方先算，一次算完），返回那颗 `FolderMixRowShape` 多带 `filePresent`。这颗参数**必填、无默认值**（本仓「边界类型必须同形且必填」那条：可选默认会把"忘了传"变成静默全可用）。
  - `reading.degraded == true`（素材根目录不可读那类）⇒ **整批不建**，`errorMessage` 写「素材还在不在盘上这件事本轮查不了：<原因>，未生成方案」并 `return`（K7 那一档，与既有环境级短路同形）。**绝不允许退成"全可用"，也不许退成"全缺失"。**
- Core：`FolderMixRowShape`（`Sources/MixCutCore/FolderMixOrchestration.swift:372`）加 `filePresent: Bool`（init 必填）；档位判定在 `:411` **之前**插一档 —— 有行、文件不在 ⇒ 新码 `materialMissing`，排在档 B（无整片段）**之前**：先因先报，防止把"文件没了"报成"缺个段"（上一轮那条归因错位的教训）。
  - 新码 `case materialMissing`（`:43` 那颗 enum 里）+ `shortfallText`「素材文件已不在盘上」+ `isSystemic` 归**false**（素材级，换一条就行，不许短路整批）。这颗 enum 上的 switch 全仓只有两处（`shortfallText` 那颗与 `isSystemic` 那颗），都不带 default ⇒ 新增一档两处必须同时表态，编译器直接拦（本轮实读数过：两处，零 default）。
  - `FolderMixJoinOutcome` 加 `missingFileCount`，那行 `[FolderMix] 对接：…` 日志（`MixCut/ViewModels/FolderMixViewModel.swift:541`）多出「文件缺失 x」一档 —— 它就是第六节真机腿 3 的判据物。
- **顺手补一处门腐**（本轮实读照出来的，不是新功能）：`Tests/MixCutCoreTests/FolderMixOrchestrationTests.swift:287` 那条 CODES 判据的档位名册是**手抄的七颗**，上一轮加的 `.notIngested` 根本没进册 ⇒ 现在名册说七档、真身八档。改法是给这颗 enum 加 `CaseIterable`、名册改成 `allCases`，"只有环境级三码短路"那条断言原样保留 ⇒ 以后新增档位不表态就编译不过/判据红。这条与 K4 同笔，因为 K4 正是新增档位的第 9 颗。
- 措辞（与既有横幅同一口径，不另造说法）：「素材文件已不在盘上（辅17.mp4 等 k 条）—— 把文件放回原处后点『重新检查』再生成」。
- 判据名册（**编号从 JOIN-20 起跳**，不是接着上一轮的 7 往下：第二轮那本账里 JOIN-8 这条名号已被撤回——它的「时长红利」改列进了那边的「不做」一节；同号指两件事会让台账说谎）：
  | 判据 | 断言 | 归属 |
  |---|---|---|
  | JOIN-20（新）| 交回里有这行、`filePresent == false` ⇒ 报 `materialMissing`，`hitCount` 不含它 | Core 纯函数 |
  | JOIN-21（新）| 缺失与"无整片段"**同时**成立 ⇒ 报的是 `materialMissing`（先因先报）| Core 纯函数 |
  | JOIN-22（新）| `filePresent` 恒真的老夹具 ⇒ 读数与 K4 之前逐字相同（不许把可用的一条误判成缺失）| Core 纯函数（回归腿）|
  | JOIN-23（新，App 腿）| `degraded` ⇒ 零方案 + 文案含「查不了」，**不是**「全部缺失」| `MixCutAppTests/FolderMixIngestJoinTests.swift`（真容器已有）|
  | JOIN-23 的注入缝（R5 补）| `degraded` 怎么在判据里造出来：走那颗**已存在**的 DEBUG 缝 `MIXCUT_DEBUG_APP_SUPPORT_ROOT`（`MixCut/Utilities/FileHelper.swift:21`，Release 编译不进这一支）把数据根指到一个不存在的目录 ⇒ 那颗读数的 `videoRootPresent` 为假 ⇒ `degraded` 真。**不为这一条开新产口、不加新开关** | App 腿 |
  | MAV-补（新）| 混剪链调的是 `missingDivideReading` 那颗，**全仓不出现第二个 `missingVideoIDs` 读侧、不出现自拼的 `fileExists`** | `FolderMixIngestGuardTests` 新门 T-32 的一条腿 |
- 台架名册（`.scratch/fm_mutate_stepK.py` 支二）：① 删掉缺失档 ⇒ 只红 JOIN-20；② 把缺失档挪到档 B 之后 ⇒ 只红 JOIN-21；③ 把 `filePresent` 写死成恒真 ⇒ 红 JOIN-20；④ 把 `degraded` 当「没缺」放行 ⇒ 红 JOIN-23；⑤ 给 `filePresent` 加默认值 ⇒ 红"必填"那条编译期判据（写成台架的"编译失败即咬中"腿，或改钉调用点参数存在性）。
- **不消费那颗集**：`missingVideoIDs` 仍只有原来那四个消费点。混剪走判定本体而不是集，是为了不引入"谁先 refresh"的时序依赖；这一点要在代码注释里写明，否则下一个人会以为这里漏接了。
- **与界面偏好无关**：导入页那颗 `showsMissingVideos` 开关（`MixCut/Views/Import/ImportView.swift:27`）是**显示**偏好，混剪的资格判定**不许**读它 —— 关了开关就允许坏素材进方案，那是把显示偏好当数据契约。

### 笔 K2 · 甲-隐 细则（补建整片段 + 一颗可见性标记）

**这一笔是全轮唯一动持久数据的笔 ⇒ 落到你活库之前我会先停下来给你看备份与验证路径。**

#### K2-1 字段形态与迁移代价（R4 勘误后）

- 新增一颗存储字段到 `MixCut/Models/Segment.swift`（与 `:138` 的 `isVoiceLocked` 同一层次、同一种写法；本文件已有 4 颗带默认值的布尔）。推荐名 **`mixInternalWholeClip: Bool = false`**（读作「这条段是混剪内部用的整片段」），语义单一：**它回答「这条段是谁建的、能不能算进用户手工分镜」，不回答来源**——那颗枚举住在 `Sources/MixCutCore/SegmentSource.swift:14`，回答的是「素材谁拍的」；它的持久字段是 `MixCut/Models/Segment.swift:97` 的 `sourceRaw`，**不许复用那两颗**。
- **不升版本锚点、不写迁移阶段**：只增字段 ⇒ `classifySchemaChange` 走「removed 为空」那一支（增量只算 additionsOnly），`isLightweightCompatible == true`（`Sources/MixCutCore/SchemaFingerprint.swift:109`），门的动作就是「备份后照常开库」（`CLAUDE.md:483`）。本仓先例两颗：`MixCut/Models/SchemaVersions.swift:39` 的 `Product`、`MixCut/Models/SchemaVersions.swift:55` 的 `VoiceProfile`。要动版本锚点的是「必需且无默认值」那种字段（`CLAUDE.md:485` 明写着补 `AppSchemaV2` + `MigrationStage.custom`）——本笔不是。
  〔原文保留：**原计划这里写的是「`AppSchemaV1` 升版 + 一条 `MigrationStage.custom`」—— 已于 R4 实读证伪，见第一节「已勘误」行。**〕
- 但**门会真的动盘**：首次启动新版时 `MixCut/App/SchemaGuard.swift:342` 的 `evaluate` 会算新指纹 → 判「有变更」→ 生成一份改前三件套备份 → 再跑一次 `runIntegrityCheck` 自证（`MixCut/App/SchemaGuard.swift:287`）→ 才建容器。所以改代码阶段仍要**先手动留一份**（命令在 `CLAUDE.md:465-470`，三件套一起）。
- ⚠ 回退路径**不是**「装回旧版 App」：`CLAUDE.md:486` 已把这句实测证伪——sidecar 里的指纹行是单调棘轮，任何更旧的二进制在同一棵数据根上都会被这道门一起拒掉。真正的退路见 `CLAUDE.md:488`：把那棵 `*.backup` 目录里的四件（store / wal / shm / launch-ledger）原样放回。这条要写进交付说明，不然「回退」两个字会把人引到死路。

#### K2-2 补建动作（只发生在混剪入库那一条支）

- 落点：`MixCut/Services/Import/ClipIngestService.swift:271` 的 else 支（今天那里「只关联、不建段」）。守门条件三条，**全在这一支里**：① 该行**没有**任何一条满足整片段形状的段（逐条问 `WholeClipShape`，口径与 `MixCut/ViewModels/FolderMixViewModel.swift:578` 同）；② 文件在盘上（走 `MixCut/Utilities/FileHelper.swift:481` 那颗唯一探针 `materialProbe`，与 K4 同一把尺子，不许自己拼一次文件存在性判断）；③ 建出来的段带 `mixInternalWholeClip = true`。
- 为什么这一支天然只属于混剪：`ClipIngestService.importClips` 全仓**只有一个生产调用方**（`MixCut/ViewModels/FolderMixViewModel.swift:497`）；母体导入页走的是另一颗 `MixCut/ViewModels/ImportViewModel.swift:146` 的 `importVideos`，而那颗薄适配层 `:589` 的 `importClipsWithoutAnalysis` **零生产调用方**（本轮再 grep 复核过）。⇒ **不需要新增"哪条链"的入参**，也不需要 flag —— 加 flag 反而会把"只有混剪补建"这条语义变成调用方各自表态。
- 交回链零改动：补出来的段就在 `video.segments` 里，`rowShapes` 下一趟自然认出 ⇒ join 从档 B 转 hit。`FolderMixIngestedRow` 不加字段、`ImportReport` 只加一颗 `internalWholeClipBuilt` 计数（供日志与 K5 文案说"自动补建了 k 条"）。
- **幂等**：补建前判①，而①判的是形状不是标记 ⇒ 重扫同一目录第二次时，第一次补的那条整片段就在 ⇒ 不再补。这条纪律正是 D19/④案当初的理由，K2 打开它但不放开它。
- 与母体两条既有形状判据的关系（本轮实读，是**好消息**，要钉成判据）：补建恒发生在"该行已有 N≥1 条段"之后 ⇒ 段数恒 ≥2 ⇒ `WholeClipShape.isWholeClip(全部段)` 因 W1（`Sources/MixCutCore/WholeClipShape.swift:87` 的 `count == 1`）恒 false ⇒ ①母体首跑的 `clearsExistingSegments` 判定（`MixCut/ViewModels/ImportViewModel.swift:723`）不会因为补建而清用户旧段；②启动期那颗按"恰好一条整片段"回填自建标记的 `restoreSelfBuiltFlags`（`MixCut/App/MixCutApp.swift:295-304`）也不会误命中。反向：用户**显式重跑分析**（`:412` 传 `true`）会连内部段一起删，下次混剪再补建 —— 这是幂等路径，不是 bug。

#### K2-3 隐形段的可见面（本轮实调研的完整清单，逐面表态）

过滤层次照本仓既有先例：全仓**没有**对 Segment 的 `#Predicate` 字段过滤先例，字段级"显示/不显示"一律落在 **ViewModel 的 Swift 层投影**（`applyFilter`、`loadSegments`）或 View 内联三元 ⇒ 本笔**不新建层**。

| 面 | 位置 | 本笔动作 | 理由 |
|---|---|---|---|
| 分镜素材库全域 | `MixCut/ViewModels/SegmentLibraryViewModel.swift:136` 的 append（`:138` 赋值，下游 `filteredSegments`/分组/计数/`numberByVideo`/配音条 domain 全部由它派生）| **过滤** | 一处即覆盖整个分镜库（含网格、封面墙、计数条、分组表头）——本轮已核实目录内 12 颗文件无独立 fetch、全仓无 `@Query Segment` |
| 分镜库目录内**绕过 VM** 的两处独立读 | `MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift:462` 与 `:497`（"应用到本视频所有分镜"的批量字号/遮罩）、`SegmentVariantInspector.swift:199`（克隆复用判定）| **过滤** | 不过滤就会出现"改了 12 条只看得见 11 条"、以及把隐形段当复用来源 |
| 导出 | `MixCut/Services/Export/ExportService.swift:165` 走 `scheme.orderedSegments` → `:177` 的 `SchemeSegment.segment` 关系反查 | **绝不过滤** | 混剪方案指向的就是这条段；在这里过滤 = 把修好的功能当场打死 |
| 删除咽喉 / 孤儿 GC 引用集 | `MixCut/Utilities/ModelContextExtension.swift:192`、`MixCut/App/MixCutApp.swift:1399` | **绝不过滤** | 要连带删得干净、要把它引用的缩略图保护住 |
| 启动修复六条全表读 | `MixCut/App/MixCutApp.swift:532`、`:573`、`:809`、`:921`、`:1213`、`:1314` | **绝不过滤** | 帧号回填、路径前缀改写漏掉它，就会留一条坏段 |
| 项目概览每视频「N 分镜」 | `MixCut/Views/Overview/ProjectOverviewView.swift:438` | **过滤（R5 已拍）** | 与分镜库同形；否则那条卡显示 12 段、点进分镜库只有 11 段 |
| 概览页那条项目级总结数 | `MixCut/ViewModels/ProjectViewModel.swift:99` 的 `segCount` | **过滤（R5 已拍）** | 同一屏的第二颗分镜数来源；那颗上的注释「分镜计数含自建分镜」会因隐形段变成半谎话，同轮换掉 |
| 导入页分镜标签墙 | `MixCut/Views/Import/ImportView.swift:902`、`:1144` | **过滤（R5 已拍）** | 同上：与分镜库同形 |
| 方案页「N 个分镜可用」 | `MixCut/Views/Schemes/SchemeListView.swift:292`（读 `MixCut/Models/Project.swift:107` 的 `segmentCount`）| **数字过滤（见 K2-4 第 4 条的分叉）** | 这颗字段**一颗两用**：既当数字（:292）又当「有没有料」的禁用闸（`:132`、`:204`、`:276`）⇒ 数字挂新出口、那三处闸一个字不动 |
| 方案页生成弹窗的预估总时长 | `MixCut/Views/Schemes/SchemeListView.swift:328` | **过滤（R5 已拍）** | 时长是对用户承诺的数，含隐形段就与生成结果对不上 |
| AI 方案生成候选池 | `MixCut/ViewModels/SchemeViewModel.swift:351` 与 `:366`（描述符）、`:835` 与 `:848`（叙事结构那条链）| **过滤（R5 已拍：必须）** | 不过滤 ⇒ 隐形段以普通分镜身份进**与混剪无关的** AI 方案，并占一个 `V{n}_{nn}` 别名编号。**为什么不会伤到混剪自己**：混剪建方案走的是 `MixCut/ViewModels/SchemeViewModel.swift:954` 那条**显式入参**的 `createCustomScheme(from:)`（调用方 `MixCut/ViewModels/FolderMixViewModel.swift:936`），根本不读这些枚举面 |
| 语义标签芯片 | `MixCut/ViewModels/SchemeViewModel.swift:766` 的 `availableTags`（被 `MixCut/Views/Schemes/NarrativeStructureEditorView.swift:50` 消费）| **过滤（R5 已拍）** | 隐形段的语义类型会让芯片池出现「有标签、但没有对应卡」的空筛选 |
| 叙事结构编辑器的 view 层候选池 | `MixCut/Views/Schemes/NarrativeStructureEditorView.swift:482` | **过滤（R5 已拍）** | 与 :835/:848 同一条链的第二处枚举，漏改一处就是第二个真源 |
| 方案编辑选段抽屉 | `MixCut/Views/Schemes/SegmentPickerDrawer.swift:127`（自己全库 fetch）| **过滤（R5 已拍）** | 与分镜库不同形 ⇒ 用户在抽屉里挑得到库里没有的那条 |
| MCP 对外工具面 | `MixCut/Services/MCP/MCPToolHandlers.swift:243` 的 `orderedSegments`（工具名 list_segments）、`get_project` 给的 `segment_count`（`MixCut/Services/MCP/MCPToolHandlers.swift:715`）、get_asr_status 的全表读（`MixCut/Services/MCP/MCPToolHandlers.swift:128`）、按编号寻址（`MixCut/Services/MCP/MCPSegmentToolHandlers.swift:722` 的 `orderedSegments`）| **本轮不动，只登记 + 取证** | 这是对外 Agent 契约（本仓既有口径：改它要走契约规矩）。**后果必须写明白**：隐形段会进那份列表，且因 startFrame 排首 ⇒ 该视频其余段的编号**整体后移一位**，与分镜库看到的编号不再同源 |

#### K2-4 这三处已按推荐拍定（R5），另多出一条必须认的分叉

1. **概览与导入页** ⇒ **一起藏**（已拍）。实测到的代价比原先估的大：概览那一屏有**两颗独立的分镜数**（`MixCut/Views/Overview/ProjectOverviewView.swift:438` 每视频一颗、`MixCut/ViewModels/ProjectViewModel.swift:99` 项目级一颗），两处都得挂。
2. **AI 方案生成候选池** ⇒ **必须过滤**（已拍）。R5 把面数清点完了：不止四颗 —— `MixCut/ViewModels/SchemeViewModel.swift:351`、`:366`、`:766`、`:835`、`:848`，加 `MixCut/Views/Schemes/SchemeListView.swift:292`、`:328`、`MixCut/Views/Schemes/SegmentPickerDrawer.swift:127` 与 `MixCut/Views/Schemes/NarrativeStructureEditorView.swift:482` ⇒ 全量收口到一颗唯一出口（K2-6），连同撤销那两条绕过装载的 append 在内，全量 18 处收口，**不在十几处各写一遍 filter**。
3. **MCP 面** ⇒ **本轮只登记 + 真机取证**（已拍）。同时加一条判据腿：`ImportReport` 那颗新计数**不得**进 MCP 的 `get_job` 键字典（与第二轮专账同一口径：那里的键是显式列举的，顺手加进去就是对外契约变更）。
4. **新发现、要认的一条分叉**：`MixCut/Models/Project.swift:107` 的 `segmentCount` **一颗两用** —— `MixCut/Views/Schemes/SchemeListView.swift:276` 拿它当数字显示，`:132`、`:204`、`:276` 拿它当「有没有料」的禁用闸。所以**不许就地过滤那颗**：数字改挂新出口，三处闸原样不动（隐形段恒与真分镜共存 ⇒ 段数恒 ≥2，闸的行为本来就不会变；就地过滤属无收益的越界改动，且会让那颗字段悄悄换语义）。这与本仓「一颗字段两个用途就必须分叉」那条同形。

#### K2-5 判据与门（与改动同笔）

| # | 判据 | 断言 | 归属腿 |
|---|---|---|---|
| JOIN-24 | 去重命中 + 有分镜段 + 无整片段 + 文件在 ⇒ 补建出一条 `0..duration` 的段，且 join 从档 B 转 hit | 真 SwiftData 容器 | App 腿（`MixCutAppTests/FolderMixIngestJoinTests.swift` 夹具已有）|
| JOIN-25 | 同一行**重扫两次** ⇒ 段总数不增（只补一条，不许叠第二片）| 同上 | App 腿 |
| JOIN-26 | 文件缺失 ⇒ **绝不补建**（K4 的档先命中）| 同上 | App 腿 |
| JOIN-27 | 补建后 `video.segments.count >= 2` ⇒ 母体首跑的 `clearsExistingSegments` 恒 false（保住"不毁用户旧段"）| 纯形状 | Core 腿（`WholeClipShapeTests` 族）|
| T-25 **改口径** | 把「混剪链五颗文件里 `commitWholeVideo(` 零调用」（`Tests/MixCutCoreTests/FolderMixIngestGuardTests.swift:800`）改成「调用点名册 = 定义处 + 母体链 + service 内**两处**（新建支、补建支），且补建支必须带那颗标记赋值与两条守门」；正对照 = 往同一份名单（`Tests/MixCutCoreTests/FolderMixIngestGuardTests.swift:805` 那颗文件数组）里塞进混剪 VM 后，混剪链自己调用必须红 | 源码扫描 | 同名册判据 |
| T-33 **新门** | 可见面名册对账：该过滤的 4 处（分镜库全域 + 目录内两处独立读 + 若 K2-4 拍"藏"则再入册）必须都含那颗标记；**不该过滤的面里（导出、删除咽喉、启动修复六条）标记零命中** —— 反向腿是防下一个人在导出侧也 filter 把功能打死 | 源码扫描 | 同 `FolderMixIngestGuardTests`，`selftest_folder_mix_guards.py` 配正反两把刀 |
| CR 名册 | 补建那一步是新的**数据写入点**，要进 `ClipIngestReadoutCharacterizationTests` 的 `ingestSites` 并改口条数（15 → 16）| 源码扫描 | 同名册判据 |
| SchemaGuard | 新字段导致指纹变化 ⇒ 用真库**副本**（不是活库）跑一次旧→新：完整性通过、既有段数不变、无新增段（补建只发生在生成时）、老行读出默认 `false` | 运行 | 取证腿，交你跑或我用 `.scratch` 副本跑 |
| JOIN-28（R5 新）| 唯一出口本身 | 可显示段投影**必须**摘掉隐形段，且**同一颗里另给一个未过滤的原始段数**供那颗禁用闸用 —— 两数并存是刻意的，判据钉住「闸那三处读的是未过滤的那颗」| Core 纯函数 |
| MCP 载荷禁令（R5 新）| 补建计数不外泄 | `ImportReport` 新增的那颗补建计数**不得**出现在 MCP 的 `get_job` 键字典里（那里的键是显式列举的，加进去就是对外契约变更）| `FolderMixIngestGuardTests` 的名册腿 |
| 台架 | `.scratch/fm_mutate_stepK.py` 支三 ≥ 4 把：①去掉标记赋值 ⇒ 红 T-33 与 JOIN-24；②去掉守门①（幂等）⇒ 红 JOIN-25；③去掉守门②（缺失）⇒ 红 JOIN-26；④在导出侧也加过滤 ⇒ 红 T-33 的反向腿 | — | 落地时逐把对"只红自己那条" |

#### K2-6 可见性收口：一颗唯一出口（决议 K9）+ 逐处名册

**为什么不许在十几个站点各写一遍 filter**：本仓「架构一致性铁律」那三条（范式唯一 / 对称契约同源 / 半迁移 = 0）在这里是硬约束，而 `MixCut/Models/Project.swift:65` 已经立过同形先例 —— 那颗 `videoNoByVideoID` 的注释明写着「原来在素材库、导入页、MCP 三处各抄了一遍」之后收敛成唯一定义处。可见性这条口径比编号更敏感（它决定用户看不看得见一条素材），**必须一次收到一处**。

- 落点：`MixCut/Models/Project.swift` 里新增一颗计算属性「可显示段」（名字待定，倾向 `displayableSegments`），体形照 `:66` 那颗：**一次遍历 `associatedVideos`、内部按那颗标记过滤、返回 `[Segment]`**。混剪自己建方案的路径**不经过它**（走 `createCustomScheme(from:)` 的显式数组），所以这条收口不会把功能自己摘掉。
- 名册（R5 逐处实测，编号就是门要扫的条数）：

  要挂出口的 **18 处**：出-1 `MixCut/ViewModels/SegmentLibraryViewModel.swift:136`；出-2 `MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift:462`；出-3 同文件 `:497`；出-4 `MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift:199`；出-5 `MixCut/Views/Overview/ProjectOverviewView.swift:438`；出-6 `MixCut/ViewModels/ProjectViewModel.swift:99`；出-7 `MixCut/Views/Import/ImportView.swift:902`；出-8 同文件 `:1144`；出-9 `MixCut/Views/Schemes/SchemeListView.swift:292`；出-10 同文件 `:328`；出-11 `MixCut/ViewModels/SchemeViewModel.swift:351`；出-12 同文件 `:366`；出-13 同文件 `:766`；出-14 同文件 `:835`；出-15 同文件 `:848`；出-16 `MixCut/Views/Schemes/NarrativeStructureEditorView.swift:482`。

  撤销恢复那两条腿（R5 审查补，漏了就会冒上屏）：出-17 `MixCut/ViewModels/SegmentLibraryViewModel.swift:606` 与 出-18 同文件 `:660` —— 这两处 undo 闭包是**直接往 `segments` 里 append**，绕过 出-1 的那次装载；所以隐形段一旦被删再撤销，就会出现在已经过滤好的投影里。落法：这两处 append 之前过同一颗出口的判据（同一条标记判断，别写第二遍），而撤销时「少塞一条」本身就是正确行为（那条本来就不该上屏）。
  必须**不许**挂的豁免面（门钉反向腿）：豁-1 导出 `MixCut/Services/Export/ExportService.swift:165` 与 `:177`；豁-2 建方案入口 `MixCut/ViewModels/SchemeViewModel.swift:954`（三个调用方：混剪 `MixCut/ViewModels/FolderMixViewModel.swift:949`、分镜库 `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift:382`、MCP `MixCut/Services/MCP/MCPSegmentToolHandlers.swift:548`）；豁-3 删除咽喉 `MixCut/Utilities/ModelContextExtension.swift:192`；豁-4 GC 引用集 `MixCut/App/MixCutApp.swift:1399`；豁-5 启动修复六条 `MixCut/App/MixCutApp.swift:532`、`:573`、`:809`、`:921`、`:1213`、`:1314`；豁-6 「有没有料」那三处禁用闸 `MixCut/Views/Schemes/SchemeListView.swift:132`、`:204`、`:276`；豁-7 生成前置非空判定 `MixCut/Services/MCP/MCPToolHandlers.swift:495`；豁-8 MCP 段面（本轮只登记，见 K2-4 第 3 条）。

- **遍历口径（R5 审查补，防止名册被当成抽样）**：分母取自 `grep -rn "\.segments" MixCut` 的**全部命中** = **29 颗文件 / 120 处**（本回合实跑读数：`wc -l` 得 120、`sort -u` 文件数得 29）。上面 18 处只覆盖其中 **9 颗文件**；其余 20 颗文件按四类逐颗表态，缺一类就是漏点：
  - **入参化（不读关系、随上游投影自动覆盖，4 颗）**：`MixCut/Views/SegmentLibrary/DubSettingsBar.swift`（`:12` 与 `:49` 两条注释写着"刻意不读 `video.segments`"，正是本笔收口的同形先例）、`MixCut/Services/SchemeGeneration/SchemeGenerationService.swift`（只收 `segments:` 入参）、`MixCut/Services/Export/DubExportService.swift`、`MixCut/App/ContentView.swift:248`（读的是 VM 投影 ⇒ 随 出-1）。
  - **必须含隐形段（删除、回收、启动修复、建方案入口，8 颗）**：`MixCut/ViewModels/ImportViewModel.swift:962`（删除前取段快照）、`MixCut/Utilities/ModelContextExtension.swift:192`、`MixCut/App/MixCutApp.swift:1399` 与启动修复六条、`MixCut/Views/SegmentLibrary/SegmentLibraryView.swift:382` 与 `MixCut/Services/MCP/MCPSegmentToolHandlers.swift:548`（两处都是 `createCustomScheme(from:)` 的调用方，传什么就用什么）、`MixCut/Models/Project.swift:92`（那颗字段本身，见 K2-4 第 4 条）。
  - **分析链与配音链（4 颗，逐颗给可成立由）**：`MixCut/ViewModels/ImportViewModel.swift:1380`（逐段转写只处理重建后留下的段，重跑分析在 `:412` 已先把旧段清掉 ⇒ 隐形段进不了这一批）、`MixCut/Services/AI/AIAnalysisService.swift` 与 `MixCut/Services/ASR/ASRService.swift`（同上，属阶段 2 产物）、`MixCut/ViewModels/DubbingViewModel.swift:408` 与 `:437`（`:408` 那颗已经在与 `derivedTotal = duration × fps` 取 `max`，隐形段的 endFrame 恰等于它 ⇒ 数值不变；`:437` 的复用要求 `clonedVoiceId` 非空，隐形段永不被单独点到克隆 ⇒ 恒不命中。这两条是**推断级**理由，落地时逐条写成代码注释并被 T-33 的正腿钉住）。
  - **上报与计数（3 颗）**：`MixCut/ViewModels/ImportViewModel.swift:1202`（真删计数，必须如实含隐形段，否则报少了）、`MixCut/Views/Export/ExportView.swift:786`（读的是已解析的导出输入）、`MixCut/Services/Import/SegmentCommitter.swift`（`commitWholeVideo` 定义处）。
  - **工装（1 颗）**：`MixCut/App/DebugSelfTest.swift`（31 处命中，全在自检与合成夹具里，不改口径）。
  数一下：9（挂）+ 4 + 8 + 4 + 3 + 1 = **29 颗文件，逐颗有表态，零"其余未查"**。混剪自身那颗 `MixCut/ViewModels/FolderMixViewModel.swift` 属"必须含隐形段"那一组的建方案入口，已随 `createCustomScheme` 一起登记。

- 门（T-33 的两条腿）：**正腿** = 上面 18 处每处都必须出现那颗出口调用（或那颗标记），少一处即红；**反腿** = 豁-1…豁-7 里出现那颗标记或出口调用即红（防止下一个人在导出/删除/闸上也过滤，把功能打死或漏删数据）。名册成对，逐条给 `文件:行号`，禁抽样。
- 批量纪律（18 处 ⇒ 命中「批量修改 7 防线」）：预检基线（先跑全量 `swift test` + 四腿取绿基线）→ 试点（先只改 出-1、出-6、出-11 三处代表：VM 投影 / 概览文案 / 生成候选池，确认出口形状够用再推全量）→ 逐文件 `.bak` 由 git 承担（本仓工作树即回退点，落地前 `git status` 先算清他的 WIP）→ 逐处打点日志 → 后检（全量腿复跑并与基线对比）→ 回读（18 处逐条 grep 回读，禁只看 diff 行数）→ 名册对账（T-33 正反两腿）。
- **拆不拆成 K2a / K2b —— 已拍（R6）：一轮做完、拆两个提交**：
  - **一轮做完（推荐）**：隐形段从诞生那一刻起就没有可见面不一致的窗口。代价：这一笔同时动数据模型 + 入库服务 + 18 处显示/生成面 + 2 道门，批量面大，回归要复跑的既有判据族最多（方案生成族、概览族、Sheet 尺寸族、可用性族）。
  - **拆两轮**：K2a 只做到分镜库那一族（出-1…出-4 加撤销两条腿 出-17/出-18）⇒ 功能当天可用、风险面小；K2b 再收 出-5…出-16。代价要写清楚：**中间窗口里隐形段会出现在 AI 方案候选池、预估时长、概览数字与选段抽屉里**，也就是「用户看不见的素材出现在用户看得见的方案里」这件事仍然发生 —— 而这正是推荐②要消灭的那件事。
  - **已拍（R6）的落法：一轮做完、拆两个提交。** 两个提交的边界与各自验收：
    - 提交 1（数据与分镜库族）：字段 + 轻量迁移 + 补建三条守门 + 那颗唯一出口 + 出-1…出-4 与 出-17/出-18（分镜库全域与撤销两条腿）+ T-25 改口径 + T-33 初版名册。验收＝JOIN-12…15 与 JOIN-24…27 全绿、真机腿 4/5 过（补建条数掉下来、重扫不叠段、分镜库条数不变）。
    - 提交 2（其余 12 处口径）：出-5…出-16 全量挂出口 + T-33 名册补全 + 真机腿 5b（三个数逐字相同）+ 概览族/方案页族既有判据复跑。
    - **两笔之间不许插入真机交付**：同一轮里连着落，否则中间窗口就是上面写的那件错事。回退单位是两个提交，而不是两轮交付。

### 笔 K3 · 措辞、台账与全腿

- 档 B 文案改口（决议 K5）：现在那句「素材在库里、但没有覆盖整片的段」是不可行动的。K2 落地后它**只剩"补建失败"这一种成因**，所以改成两档分别出声：
  - 补建成功 ⇒ 不再是 shortfall，只进日志与状态行的「本轮自动补建 k 条整片段（不进分镜库）」；
  - 补建仍拿不到 ⇒ 「这一类里有 k 条素材此前按分镜导入、整片直拼用不了」＋那颗码原样（档 B 保留，不删档）。
- 台账同批改口（**逐颗对账，不批量替换**）：主台账加 **R52** 并在 §九 的档表里新增 `materialMissing` 一行、把档 B 那行的措辞与"绝不补建"那句改口（原句用〔已修订 2026-10-22〕原地标注，不删）；本文件第六/七/八/九节回填读数；两份既有专账（第二轮 join-key）里"混剪不补建整片段"那句同样要扫一遍，否则它会变成谎话。
- 全腿复跑：`swift test` 全量（基线 1324 / 4 known issues）→ 混剪族计数改口 → `check_folder_mix_guards.sh`（17 道，K2/K4 各新增门后重算）→ `selftest_folder_mix_guards.py`（每把新门配自己的刀）→ `.scratch/fm_mutate_stepK.py` 三支全咬 → App 四腿 + `.scratch/dd` 重建 → `check_pbx_registration.py` → 三份 plan 全跑 `check_plan_doc_citations.py`（DOC CLEAN）。

---

## 六、验证（每条都要读数；跑不了的写明待人工）

**机器腿**

- `swift test` 全量（基线 1324 / 4 known issues）；新判据逐条配刀，逐把对"只红自己那条"。
- 台架 `.scratch/fm_mutate_stepK.py` 三支全咬（K1 五把 / K4 五把 / K2 四把，见各笔的刀名册）；`selftest_folder_mix_guards.py` 复跑 —— **T-25 改口径、T-32 与 T-33 两道新门各要配自己的刀**，且 T-33 要同时配正反两把（该过滤处没过滤 ⇒ 红；不该过滤处加了过滤 ⇒ 也红）。
- App 四腿：`MODE=typecheck` / `MODE=silgen` / `xcodebuild build` / `build-for-testing`，`.scratch/dd` 重建。
- App 腿（真 SwiftData 容器）：**只能整目标跑** `-only-testing:MixCutAppTests`（顶层 `@Test` 没有真 suite，类级/函数级过滤会选 0 条仍报 SUCCEEDED），报数只认 `Test case … passed/failed` 行数。**跑前先手动留三件套**（`CLAUDE.md:465-470`）：宿主是 SunCut.app，改过数据模型的那一轮 那道门会当场对你的活库加列并自动备份。2026-10-23 实跑：**29 passed / 0 failed**（含 JOIN-23/24/25/26）。
- 门与名册复跑：`check_folder_mix_guards.sh`、`check_pbx_registration.py`、`check_association_guards.sh`、`check_live_store_guards.sh`（本轮不打开你的活库）。
- schema 那一条**打在副本上，不打在活库上**：把 `Suncut.store*` 三件套复制进 `.scratch/`，用改码后的二进制开这棵副本，读数是四件——① 门的 `PRAGMA integrity_check` 通过并自动产出一份 `*.backup`；② 副本里的既有段数一字不变；③ 存量行读出的新字段是默认 `false`（不许有任何一条变成 `true`）；④ 没有新增段（补建只在生成时发生）。**这一步跑之前我会先把备份路径与命令贴给你。**
- 三份 plan（主台账 + 第二轮专账 + 本文件）都跑 `check_plan_doc_citations.py`（DOC CLEAN）。

**真机腿（用户跑）**

1. 同一份人参果拆分2、**条数 5**：期望日志变成「交回 ≥ 抽中集大小、没找到 0」，且 5 条方案全出（K1 的直接判据）。
2. 把条数从 5 拉到 56 再拉回 5，两次都全出 ⇒ 钉住"清单不再依赖条数与池子的相对大小"。
3. 可用性腿（笔 K4 落地后）：同一份人参果拆分2 再跑一次，期望那行日志多出「文件缺失 m」一档，且 m > 0 时这些条**不进方案** —— 对照今天「问了 8 条：缺失 8」那三轮：修好后这 8 条应被点名挡下，而不是变成方案。
4. 补建腿（笔 K2 落地后）：同一条日志里「无整片段 b」要掉下来（24 ⇒ 接近 0），同时多出「本轮自动补建 k 条」；**分镜素材库每个分镜卡的条数不变**（这是甲-隐成立与否的唯一屏上判据，甲-显 的话就该看到多一条）。
5. 幂等腿：同一份目录**连着生成两次**（不删任何东西）⇒ 分镜库里那条素材的段数第二次不许再 +1。
5b. 口径一致腿（R5 补）：同一条补建过的素材，**项目概览那条卡的「N 分镜」== 点进分镜库的卡数 == 导入页标签数**，三个数逐字相同；方案页那句「N 个分镜可用」也要与之一致。这一条是那颗唯一出口是否真收住了口在屏上唯一的证物。
6. 编号漂移取证（不是验收，是把 K2-4 第 3 处摊成数字给你拍）：拿一条补建过的视频实跑一次 MCP `list_segments`，把每段的 `segment_no` 与分镜素材库里的编号并排贴回 ⇒ 量出"隐形段占了第几号、其余段后移几位"。
7. 反向确认：把 `ingestTask` 临时改回前缀写法重编译，症状必须原样复现（没找到 > 0）；不复现说明还有第二条通路。

**取证腿（用户跑，只读；本组已跑完）**

```
grep -nE "辅17|可用性|孤儿|orphan|GC|不存在" ~/Library/Caches/com.suncut.app/logs/suncut.log | tail -30
ls -R ~/Library/Application\ Support/*/Videos 2>/dev/null | grep -c "辅17.mp4"
du -sh ~/Library/Application\ Support/*/Videos 2>/dev/null
```

三条的判读：第一条看那一行到底指向哪个前缀、日志里有没有回收记录；第二条 = 0 且第三条明显小于素材总量 ⇒ 人工清理或回收删过盘；第二条 > 0 但文件名不同 ⇒ 路径前缀/改名漂移，属搬迁那条链的问题。**本组已跑完，读数与定性在第二节末。**

**取证组二（坐实成因，用户跑；按本仓活库纪律：先退 App，只读方式打开）**

```
grep -nE "\[OrphanGC\]|回收孤儿文件|\[可用性对账\]" ~/Library/Caches/com.suncut.app/logs/suncut.log* | head -60
osascript -e 'quit app "SunCut"'; sleep 2; pgrep -x SunCut || echo 活实例已退
sqlite3 -readonly ~/Library/Application\ Support/Suncut/Suncut.store 'select ZNAME, ZLOCALPATH from ZVIDEO' > /tmp/vnames.txt
python3 -c "import unicodedata as u;n=[l.strip() for l in open('/tmp/vnames.txt') if l.strip()];print('全库条数',len(n));print('NFC不等于NFD 的名字数',sum(1 for x in n if u.normalize(x,'NFC')!=u.normalize(x,'NFD')))"
```

（库文件名与列名已实读对上：`Sources/MixCutCore/Brand.swift:16` 的 storeFileName = `Suncut.store`，ZVIDEO 的名字列是 ZNAME、路径列是 ZLOCALPATH。）

判读：第一条看「回收 M 个」与「缺失 N 条」是否成对跳增（跳增 ⇒ 回收误删坐实）；第二条是前置门 —— 本仓 `check_live_store_guards.sh` 钉的就是「-readonly + 活实例未运行」这两件，缺一不查；第三、四条量的是名字里正规化差异的占比，若显著高于全库平均，头号嫌疑成立。**这四条不通过 ⇒ K8 不落码，混剪侧照旧靠 K4 挡住坏数据。**

---

## 七、风险与不做

- **K1 半径**：只动 `Sources/MixCutCore/FolderMixOrchestration.swift` 一颗纯函数里那四行 + 两条判据 + 五把刀。**零持久化、零契约影响**，可独立先落。
- **K4 半径**：Core 加一档（三处穷尽 switch 编译器会拦）+ App 一颗必填参数 + 一行日志多一个数。**仍然零持久化**（只读判定，不写库、不改任何记录）。
- **K2 半径（本轮真正的风险所在；R5 按实测扩大了一块、也按实测改小了一块）**：动一颗持久字段 + 入库服务的 else 支 + **18 处显示/生成面收口到一颗唯一出口** + T-25 改口径 + T-33 新门 + **反转 D19 的一条子决议** —— 这是改判不是修 bug，且批量面命中「批量修改 7 防线」（K2-6 已把七道逐条排好，含先试点三处的止损点）。**但 schema 那一项比原先报给你的小**：只增带默认值的字段 ⇒ 轻量兼容、不升版本、不写迁移阶段（`CLAUDE.md:483`），剩下真正的不可逆点只有一个：**首次启动新版时门会写你的库**（改前备份 + 加列）。所以交付路径里「落到活库之前停下来」这一格保留。
  甲-显 省掉标记但把混存摊到用户眼前；乙 语义最干净但会改到 MCP 侧在用的 `ExportInput.from` 形状。**三条都不掩盖症状**：共同点是都不允许"混剪悄悄改写用户的分镜库"这件事没有标记、没有判据。
- **二阶效应**（逐条给触发链；R4 按实读改口了②⑤，新增⑥⑦⑧）：
  ① 补建整片段 ⇒ `video.segments` 多一条 ⇒ 段数计数/筛选/删除咽喉的既有判据要复跑（W 族、G12 名册、`check_association_guards.sh`），且**上屏面不止分镜库一处** —— 见 K2-3 那张表，漏一面就是"用户看不见的段在改用户看得见的数"。
  ② 加带默认值的字段 ⇒ 存量行读出默认值、指纹变 ⇒ 首次启动走一次「自动改前备份 + 加列」。**回退 = 把那棵 `*.backup` 里的四件原样放回**（`CLAUDE.md:488`），不是装回旧版二进制（`CLAUDE.md:486` 实测证伪）。
  ③ K1 让清单变大 ⇒ 单次生成的拷贝量与磁盘预估上升（余量公式不变，抽中集不再被前缀"意外省掉"，这是修正不是回归）。
  ④ T-25 改口径 ⇒ 若不同批改判据，门会把修好的代码打红（同笔强制）。
  ⑤ ~~生成期多一次异步等待~~ **消掉**：K4 调的是那颗 `nonisolated static` 判定本体，同步、无状态、不 `refresh`、不读共享集 ⇒ 不存在"串了上一个项目的缺失集"这一格。留下的代价只是每行一次 `stat()`（与启动对账同一把尺子，毫秒级）。
  ⑥ 隐形段与母体两条既有形状判据**天然不冲突**（本轮实读，已列进 K2-2 要钉成 JOIN-27）：补建后段数恒 ≥2 ⇒ W1 那条 `count == 1` 恒 false ⇒ 母体首跑不会清用户旧段、启动期 `restoreSelfBuiltFlags` 不会误命中。**但这条靠的是"补建只发生在已有段的行上"这个前提** —— 谁哪天把补建条件放宽，⑥ 就同时失效，所以它必须落成判据而不是注释。
  ⑦ 用户显式**重跑分析**（`MixCut/ViewModels/ImportViewModel.swift:418` 传 `clearsExistingSegments: true`）会连隐形段一起删 ⇒ 下次混剪再补建一次。这是幂等路径不是 bug，但要在 K3 的文案里说清楚，否则"我重跑完分析怎么又出现一条补建"会成新报障。
  ⑧ MCP 面：隐形段进 `list_segments`、`segment_count` 与按编号寻址 ⇒ **同一颗视频在界面与 Agent 眼里的段编号会不同**（本轮只登记 + 真机量数，见真机腿 6）。
  ⑨ 一句既有注释会变半谎话：`MixCut/ViewModels/ProjectViewModel.swift:99` 那行写着「分镜计数含自建分镜」，加了隐形段之后它含的是**第三种东西** ⇒ 注释与代码不同轮就是假注释（防 AI 通病五戒第 3 条），必须在同一笔里改口。
  ⑩ 收口成一颗出口 ⇒ 概览族、方案页族、分镜库族的既有判据要全量复跑（它们盯的是源码形态，插入一处调用就能让它们红或瞎）；这也是 K2-6 要求「先试点 出-1／出-6／出-11 三处再推全量」的理由 —— 出口的形状不够用要在试点阶段发现，而不是改完 18 处才发现。
- **不做**：不在本轮碰孤儿回收与路径漂移那条链（**成因**未查清，先动等于猜；本轮只保证混剪不再消费到坏数据）；已收窄到的嫌疑（`normalize` 不做 Unicode 正规化）也不动 —— 那是破坏性路径的判据变更，要配「回收前逐名落日志」这条读数点才动得了；**不动 MCP 对外工具面**（要动就单独一轮按契约规矩走）；不替用户删任何指向缺失文件的记录（那颗持有者的注释把这条写成禁令：把「文件没了」自动变成「记录删掉」是最危险的误读）；不把"整片"改成多段拼接（那是分镜语义，会撕裂整片直拼的定义）；不给混剪加"自动清理缺失文件"的动作（删除咽喉只有一条，混剪不该成为第二个入口）；不给 `importClips` 加"哪条链"的 flag（本轮已核实它只有混剪一个生产调用方，加 flag 等于把一条已经唯一的前提变成两处各自表态）；不为 K1 之外的池子顺序、余量大小做顺手调参。
- **不新增决议号到主台账**：K1–K8 只活在本文件，主台账只在修订记录里指一次本文件。

---

## 八、修订记录（本文件自己的账；编号从 R1 起重编，与主台账的 R 号无关）

| # | 日期 | 改了什么 → 落在哪一节 |
|---|---|---|
| R10 | 2026-10-23 | **真机首跑读数回来核对上了两条修复，也照出第三条结构洞**（用户贴屏）。① 缺陷一确认已修：状态行「入库 4/4：卖点（8 条）」= 抽中 5 + 余量 3，四类池子 56/52/43/54 都在正常入库（改前那次是「交回 32、没找到 173」）。② 缺陷四确认已修：红字报的是「素材文件已不在盘上，同类别内已无可换的新素材（档 materialMissing）」，而不是上一版那句误导性的「素材入库失败」——归因这一格终于对了。③ 代价也如实露出来：**这一批 5 条现在一条都出不来**，因为「辅助卖点」这一类被抽中的素材库内拷贝全不在盘上（缺陷三那 163 行的同一族数据）。④ 新照出的结构洞：`findExistingVideo(hash:)` 只看内容哈希、**不看库内那份拷贝还在不在** ⇒ 一行指向已消失文件的记录会永久占住「已导入」，混剪与母体链都不会把它重新拷回来 ⇒ materialMissing 只是把坏挡住了，没有给自愈。据此新增决议 K10（三条出路 + 自愈的半径实测）。⑤ 另需提醒：他此前拉条数到 56 跑出来的那 56 条方案是**在修复之前**建的，里面可能正指向这些缺失文件 ⇒ 导出会坏，别直接拿去出片 |
| R9 | 2026-10-23 | 用户「跑」⇒ 补跑那条被挡的 **App 测试腿**（先取现场证据：SunCut 活实例 0、8787 空闲）。三件事照出来，全部记进本文件与取证腿纪律：① **过滤器假绿**——Swift Testing 的顶层 `@Test` 自由函数没有真 suite，`-only-testing:MixCutAppTests/FolderMixIngestJoinTests` 与逐函数写法都跑出 `totalTestCount: 0` 却报 `TEST EXECUTE SUCCEEDED`（2.9 秒就「跑完」）⇒ 这类文件只能用整目标过滤，报数只认 `Test case … passed/failed` 行数；② **这条腿会动活库**——`TEST_HOST=SunCut.app` 且 `BUNDLE_LOADER` 同值 ⇒ 宿主进程里 `MixCutApp.init` 会执行，`SchemaGuard` 直接在你的 `Suncut.store` 上开库；本轮改过 `@Model`（K2 那颗字段）⇒ 门当场做加列并自动留了一份改前备份目录（名字里的时间戳是 UTC，见 `MixCut/App/SchemaGuard.swift:67`）。副作用是「旧库开得住」被实证了一次，但这不是获授权的用法：以后跑这条腿前先按 `CLAUDE.md:465-470` 手动留三件套；而把 `MIXCUT_DEBUG_APP_SUPPORT_ROOT` 用 shell 前缀喂给 xcodebuild **不生效**（`.scratch/testroot` 全程为空即证据）；③ **App 腿首跑就抓到两条真红**（JOIN-24/25 报 `internalWholeClipBuilt → 0`）——根因在我新写的夹具：去重命中靠 `MixCut/Services/Import/ClipIngestService.swift:158` 那颗 `findExistingVideo(hash:)`，夹具没设 `contentHash` ⇒ 走的是新建支，补建支根本没进；另 JOIN-26 的假路径必须落在可信前缀**之内**（否则算 `excludedRecords` 而不是缺失）。修完夹具后整目标 29 条 passed、失败 0 ⇒ **纯函数那 1334 条全绿看不见这个洞，这正是 App 腿存在的理由** |
| R8 | 2026-10-22 | **四笔全部落地（用户「全部执行，直到结束」）**。笔 K1：`ingestTask` 改成先装抽中集再补余量，判据 FMX-18d/18e，台架支一 K1-a…K1-e；**落地时按台架实测改口两处**——原写「刀 K-d 拆封顶 ⇒ 红 FMX-18b」是错的，实测那层 `min(公式, pool.count − drawn)` 是**数学上的 no-op**（公式本身 ≤ 剩余数，且补余量只遍历有限池），摘掉后一条判据都不红 ⇒ 已删该夹逼并把话写进注释；另新增 FMX-18f 用大池钉住默认公式（小池夹具下「默认 == 注入 99」是恒等，写死常量 3 也抓不到 ⇒ 该类刀登记为**等效变异**）。笔 K4：新码 `materialMissing` 排在档 B 之前、`FolderMixRowShape.filePresent` 必填无默认、`missingFileCount` 进那颗 outcome 与那行对接日志，App 侧 `availabilityReading` 直调那颗 `nonisolated static` 判定本体（不 refresh、不读共享集），degraded ⇒ 整批不建；CODES 名册由手抄七颗改成 `allCases` 并加「一档一句人话、句间不重复」；门 T-32（含腿 D 钉死 `if reading.degraded {` 这一句，因台架实测只查分支体会被 `if false,` 等价摘掉）；判据 JOIN-20/21/22（Core）+ JOIN-23（App 腿，走那颗 DEBUG-only 缝造 degraded）。笔 K2：`Segment.mixInternalWholeClip`（带默认值 ⇒ 轻量兼容，未动版本锚点与 stages）、补建长在 `ClipIngestService` 去重命中支且三道守门齐（形状 / materialProbe / 标记）、唯一出口 `Video.displayableSegments` 与 `Project.displayableSegments`（照那颗「唯一定义处」先例），**19 处挂出口**（比 R5 的 18 处多一处：实施时照出 `ImportView.swift` 那颗重试门禁也读裸关系）、**8 组豁免钉反腿**、T-25 改口径、T-33 正反两腿、CR 名册 15⇒17 处、墓碑基线由 G08d 腿重生成 42/40/10（销账逐条写在该表注释里）；判据 JOIN-24/25/26（App 腿真容器）+ JOIN-27（Core 跨模块不变量）。笔 K3：档 B 文案改口、状态行加「本轮自动补建 k 条（不进分镜素材库）」。台账同轮改口：主台账 R52 与 §九 两格（档 B 改判 + 新增档 B0），第二轮专账 INV-02 加注。**落地读数**：`swift test` 1334 通过 / 4 known issues（改前基线 1324，+10 条判据零回归）；App 四腿 typecheck / silgen / build / build-for-testing 全 PASS，`.scratch/dd` 已重建；三份 plan 逐份 DOC CLEAN（落地过程中因加行腐烂的 40 处行号已按锚点逐处回正，含 4 处源码/脚本注释里的引用） |
| R7 | 2026-10-22 | 走 test-coverage-expander 做覆盖评估 ⇒ 新增第十一节。种子口径实测：混剪族按文件名数 **143 条 `@Test`**（FolderMix 七颗 118 + WholeClipShape 8 + ClipIngestReadout 5 + DiskSpaceBudget 12），广义谓词（并上 Tombstone / MediaAvailability / MissingMaterialFinder / SegmentSource / OrphanFileFinder 等相邻族）数到 **210 条 / 14 颗文件**，两个口径都写进表头以免后人拿错分母。归纳出 **16 条覆盖维度**，逐维对既有种子求差 ⇒ 计划里已登记的 15 条判据（FMX-18d/18e、JOIN-20…28、T-25 改口径、T-32/33）状态是「待落地」，**真缺口只有 9 条**（TC-K1…K9，含两条防判据恒真的自证腿），另两条只能待人工（MCP 编号漂移读数、墓碑基线净变化人审）。外部经验取到三条可用：Swift Testing 的原生参数化让我们**零依赖**用既有 `FolderMixRandom` 注入缝跑准属性测试；`isStoredInMemoryOnly` 容器宜提到 Suite 的 init/deinit 而不是逐用例现建；变异测试工具（Muter 一类）的「存活体要先判等效变异」与本仓「存活先审刀/判据/被测那份」同形 ⇒ **结论是不引入第三方变异与属性测试依赖**（供应链门禁 + `swift test` 只编 Core + 自研台架已在），这条写成结案陈词而非挂着。**未生成任何测试代码、未跑任何测试套件** |
| R6 | 2026-10-22 | 用户「按推荐更新计划」⇒ 笔 K2 定为**一轮做完、拆两个提交**（提交边界与各自验收写进 K2-6 末），并把「两笔之间不许插入真机交付」钉成纪律：中间窗口留下的正是推荐②要消灭的那件事。随后按 tech-solution-review 走 A 类三维评审，照出**三条要并进笔 K2 同笔清单**的新同笔项（① `TombstoneReadGuardTests` 那张 45 处 / 43 键 / 12 颗文件的基线名册必然被收口打红 ⇒ 必须同笔重生成并逐条说明去向；② 唯一出口若是计算属性、又在 `ForEach` 里逐卡调用，会把概览页从「一次读全 + 缓存」退化成每卡全遍历，那颗 `[Perf] ProjectOverview` 日志（`MixCut/ViewModels/ProjectViewModel.swift:106`）就是现成验收点；③ 出口体内那一处关系读取是墓碑读族的**新登记点**，不许当豁免）。同时实测排除两项：`check_undo_guards.sh` 只数 broadcast/post/schedule/safeSave（`:218`、`:236`、`:258`）⇒ 本方案不动它们；`MediaAvailabilityGuardTests` 内零 `video.segments` 名册 ⇒ 不会被红。**仍未动一行生产码** |
| R5 | 2026-10-22 | 用户「按推荐更新计划」⇒ K2-4 三处待拍**按推荐全部落定**（① 概览与导入页一起藏；② AI 方案生成候选池必须过滤；③ MCP 本轮只登记 + 真机取证），并为此新增决议 **K9** 与新小节 **K2-6**：可见性**收口成一颗唯一出口**（照 `MixCut/Models/Project.swift:66` 那颗「唯一定义处」的先例），名册实测到 **18 处要挂 + 8 组必须豁免**（这颗数是审查第二轮补出来的：初版只数到 16，漏了撤销恢复那两条**绕过装载、直接 append 进投影**的腿 `MixCut/ViewModels/SegmentLibraryViewModel.swift:606` 与 `:660`），T-33 因此做成**正反两条腿**的名册对账（正腿 18 处逐条、反腿 8 组逐条）；批量面按「7 防线」逐条排好（预检取基线 → 试点三处 → 后检 → 逐处回读 → 名册对账）。同一轮对本文件自己做了四处纠偏：① FMX-18e 原写「清单 = 5 条抽中 + 3 条余量」是错的（`drawnPerCategory` 数的是出现次数，跨行重复抽中会大于不同键个数，而 `seen` 又按键去重 ⇒ 条数是浮动值），改成集合包含、条数上界仍留给 FMX-18；② `MixCut/Models/Project.swift:107` 的 `segmentCount` 实测**一颗两用**（既当显示数字又当三处禁用闸）⇒ 明令不许就地过滤：数字挂新出口、三处闸原样不动；③ `degraded` 那档的判据找到**零新产口**的注入缝（那颗 DEBUG-only 的 `MixCut/Utilities/FileHelper.swift:21`）；④ 补一条禁令：新增的补建计数不得进 MCP 的 `get_job` 键字典。新增判据 JOIN-28、真机腿 5b、二阶效应 ⑨⑩；K2 半径那句按 18 处收口改口。**仍未动一行生产码** |
| R4 | 2026-10-22 | 用户「确认选甲-隐」后又说「先出计划文件」⇒ **第五节整体重写成四笔细则**：笔 K1 给出改法伪码、「替补腿为什么不用改」的实读结论、FMX-18d/18e 与五把刀的名册；笔 K4 给出新档插入点、多出来的那颗计数、**顺手补一处门腐**（CODES 那条档位名册是手抄的七颗，上一轮加的 notIngested 根本没进册 ⇒ 名册说七档、真身八档）与新门 T-32；笔 K2 拆成 K2-1…K2-5 五个子节（字段形态与迁移、补建三条守门、**隐形段可见面全清单**、待拍三处、判据与刀名册）；笔 K3 给出两档分别出声的文案与台账改口清单。**两处对我自己的勘误**（原文保留加标注）：① 甲-隐 的 schema 代价原先报大了——只增带默认值的字段属轻量兼容（`CLAUDE.md:483`），不升版本、不写迁移阶段，真正不可逆的点只剩「首次启动会写你的库」；② K4 原先的「必须 refresh 并等落终态、否则串项目」整条消掉——那颗判定本体是 `nonisolated static`（`MixCut/Infrastructure/MaterialAvailabilityStore.swift:121`）且已有非界面调用方（`MixCut/App/MixCutApp.swift:1389` 的 `missingDivideReading`）。另按实读新增三条二阶效应（⑥ 补建后段数恒 ≥2 因此不撞母体两条形状判据、⑦ 重跑分析会删掉隐形段、⑧ MCP 段编号会漂），第六节 schema 那条腿改成打在 `.scratch` 副本上而不是活库、真机腿补到 7 条，第七节「不做」补三条。调研用的是只读子代理，未动任何生产码 |
|---|---|---|
| R2 | 2026-10-22 | 用户贴回取证 ⇒ **缺陷三定性**（163 行指向已消失的库内文件；「0 条路径不在素材目录内」把品牌前缀漂移这条判掉了；数从 10-20 起一字不变 ⇒ 一次性历史事件，成因归母体链另案），并照出**缺陷四**：混剪链对全仓唯一的可用性持有者零消费 ⇒ 会把文件已缺失的素材抽进方案，建出「导得出、坏在后面」的方案。据此新增决议 K6/K7、新增笔 K4，并固定落笔顺序 **K1 → K6 → K2**（补建整片段绝不允许发生在缺失行上）；第六节补一条可用性真机腿；第七节补二阶效应第⑤条与「不替用户删记录」那条禁令 |
| R3 | 2026-10-22 | 用户拍定 **K2 = 硬需求** ⇒ 丙出局、方向定为甲-隐（乙保留为不愿动 schema 时的退路）；并按要求开查缺陷三成因 ⇒ 本轮实读把嫌疑**收窄到一把尺子**：可用性那条轴用前缀白名单 + 逐条 stat（APFS 自己兜住大小写与正规化 ⇒ 不会假报缺失，「0 条不在素材目录内」也佐证 163 条是真没了），而回收那条轴的 `normalize` 只做 `lowercased()`、不做 Unicode 正规化 ⇒ 被引用着的文件可能被判成孤儿删掉。新增决议 K8（另案查成因）与取证组二（日志时间轴 + 名字正规化占比两条读数，按本仓活库纪律要求先退 App、只读打开）；**未坐实前不落任何码** |
| R1 | 2026-10-22 | 第三轮落笔：缺陷一（入库清单 = 池子前缀，含用户日志的四个数与算术核对、为什么全绿、为什么上一份目录没犯）、缺陷二（整片段资格 = 数据形状泄漏进资格判定，75% 命中不了 ⇒ 从边角升级成主路径）、缺陷三（库内拷贝缺失，未定性只给取证）；决议 K1–K5（K2 四候选摊开代价）；拆笔 K1/K2/K3；验证含反向确认与三条取证命令；第七节给出二阶效应四条与不做五条 |

---

## 九、执行进展（落地时逐行回填，勘误不删原文、加〔已修订〕）

| 日期 | 产出 | 取证 |
|---|---|---|
| 2026-10-23 | 真机首跑（用户贴屏）⇒ K1 与 K4 两条修复按设计生效得到屏上确认；同时照出「去重命中不看文件在不在」这条结构洞，登记为决议 K10 | 屏上读数：条数 5、四类 56/52/43/54、组合总数 6,761,664、状态行「入库 4/4：卖点（8 条）」、红字「计划 5 条一条都没出：5 条（辅助卖点）：素材文件已不在盘上…（档 materialMissing）」。补建那一档的屏上证物这一跑取不到：缺失行被守门②挡住不补（设计如此），其余类别有没有补成只在日志里 ⇒ 要他 grep 一次 [FolderMix] 才能定 JOIN-24/25/26 的屏上那一格 |
| 2026-10-23 | 补跑 App 测试腿：现场证据（活实例 0、8787 空闲）→ 整目标跑 → 修两条夹具红 → 再跑 | 首跑 `totalTestCount: 0` 却报 SUCCEEDED（过滤器选空）；二跑 29 条里 2 条 failed（JOIN-24/25 报 `internalWholeClipBuilt → 0`）；修夹具后三跑 **29 passed / 0 failed**（含 JOIN-23/24/25/26 四条新腿）；`.scratch/testroot` 全程为空 ⇒ 重定向未生效；活库旁多出一份 Suncut.store.20261023-005738.…-to-….backup 目录（名字里是 UTC 时间 ⇒ 本地 08:57:38，正是首跑那一刻） |
| 2026-10-22 | 四笔落地：`ingestTask` 先装抽中集；可用性进资格（`materialMissing` + degraded 整批停手）；甲-隐补建 + `mixInternalWholeClip` + 一颗唯一出口 19 处收口；T-25 改口径、T-32/T-33 两道新门；墓碑基线重生成；文案与三份台账同轮改口 | `swift test` 1334 通过 / 4 known issues（基线 1324 + 10 条新判据，零回归）；App 四腿 PASS（typecheck / silgen / xcodebuild build / build-for-testing），`.scratch/dd` 重建；台架 `.scratch/fm_mutate_stepK.py` 逐把读数见第九节下一行；三份 plan DOC CLEAN |
| 2026-10-22 | 按 test-coverage-expander 出覆盖评估（第十一节）：16 条维度、差距矩阵、TC-K1…K9 用例清单；两条结案陈词（不引 Muter、不引 SwiftCheck）。**未生成测试代码、未跑套件** | 种子条数实跑：`grep -c '@Test'` 逐颗 ⇒ 狭义 143、广义 210/14 颗；`SchemaFingerprintTests` 的 20 条标题逐条读过（据此改口 D10）；`mcp_api_guards.py` 的 `:127`、`:349` 两处键名册断言实读 ⇒ TC-K8 判为复用既有工装而非新写 |
| 2026-10-22 | 按推荐把 K2-4 三处落定 + 新增决议 K9 与 K2-6（唯一出口 + 18 处名册 + 豁免名册 + 批量 7 防线）；对本文件自纠四处（FMX-18e 的「+3 条余量」、`segmentCount` 一颗两用、degraded 注入缝、MCP 载荷禁令）。**仍未动任何生产码** | 站点全部实读：18 处要挂的逐条 `文件:行号` 见 K2-6；`Project.segmentCount` 一颗两用由 `MixCut/Views/Schemes/SchemeListView.swift:132`、`:204`、`:276`、`:292` 四处 grep 定死；混剪建方案走显式入参由 `MixCut/ViewModels/FolderMixViewModel.swift:949` → `MixCut/ViewModels/SchemeViewModel.swift:954` 实读确认（所以 AI 侧过滤不会自伤）；注入缝为 `#if DEBUG` 包住的 `MixCut/Utilities/FileHelper.swift:21` |\n
| 2026-10-22 | 按 R4 把第五节写成可签字的四笔细则（含甲-隐 的可见面全清单与待拍三处）。**仍未动任何生产码**，等这一节签字 | 三处新实读：① `ClipIngestService.importClips` 全仓只有混剪一个生产调用方（`MixCut/ViewModels/FolderMixViewModel.swift:495`），适配层 `MixCut/ViewModels/ImportViewModel.swift:589` 零调用方 ⇒ K2 不需要链别 flag；② 可用性判定本体是 `nonisolated static`（`MixCut/Infrastructure/MaterialAvailabilityStore.swift:121`）且已有非界面调用方 `MixCut/App/MixCutApp.swift:1389` ⇒ K4 无异步等待；③ 分镜库全域投影只有一处构建口（`MixCut/ViewModels/SegmentLibraryViewModel.swift:136`），目录内 12 颗文件无独立 fetch、全仓无 `@Query Segment`，但**目录内有 3 处绕过 VM 的独立读**（`SegmentPropertiesSection.swift:462`/`:497`、`SegmentVariantInspector.swift:199`）＋库外另有 4 个独立枚举面。可见面清单逐条由只读子代理实读产出，主线程未复算 |
|---|---|---|
| 2026-10-22 | 用户拍 K2 = 硬需求（丙出局、定甲-隐）+ 要求查缺陷三成因 ⇒ 按 R3 加决议 K8 与取证组二，并把嫌疑收窄到回收那条轴的比对尺子。**仍未动任何生产码** | 实读两把尺子各自的位置：`MixCut/Infrastructure/MaterialAvailabilityStore.swift:121` 与 `Sources/MixCutCore/OrphanFileFinder.swift:9`；10-20 11:02:36 那次回收 72 个的读数在用户贴回的日志里 |
| 2026-10-22 | 用户跑取证三条命令 ⇒ 缺陷三定性、照出缺陷四；计划按 R2 扩到 K1–K7 与四笔。**仍未动任何生产码** | 取证读数原文见第二节末（163 / 161 / 8 三档、`grep -c` 得 0、两个根 0B 与 2.3G）。混剪零消费为实跑 grep：那颗符号在混剪两颗文件里命中 0 |
| 2026-10-22 | 计划落笔，未动任何生产码（等拍）。K1 与 K2 是**两笔独立**的事：K1 是必修 bug 可先行，K2 要改判既有决议 | 全部承重事实回实码取：前缀那行在 `Sources/MixCutCore/FolderMixOrchestration.swift:179`；余量公式在 `Sources/MixCutCore/FolderMixPicker.swift:344`；只关联支在 `MixCut/Services/Import/ClipIngestService.swift:274`；可用性 stat 的是库内路径 `MixCut/Infrastructure/MaterialAvailabilityStore.swift:67`；FMX-18 的断言面在 `Tests/MixCutCoreTests/FolderMixOrchestrationTests.swift:93` |
| 2026-11-03 | **缺陷三（库内拷贝不在盘上）的失败面封口 + P-2 封口 + D15 静态核对**：① 日志时间轴实读：10-15/10-19 报 165 条 localPath 不存在 → 10-20/10-22 报 163 → 10-25 只剩 2；GC 事件 10-04 删 151、10-25 删 1258。**无法证明 GC 删过被引用视频**（163 在 10-20 前已存在），但 `TC-OF-15` 的「近零交集整批放行」是可复现失败面 ⇒ 新增内容哈希目录第二坐标：`OrphanFileFinder.contentHashDirectoryName(inVideoPath:)` + `safeOrphanFiles(...protectedDirectoryNames:)`，`MixCutApp.runOrphanGC` 用 `Video.contentHash` 与 localPath 解析同时喂；TC-OF-16/17/17b 三条判据。② P-2：`ClipIngestService` 实读只写 `video.status = .imported`，`needsAnalysis = existingVideo.status != .completed || segments.isEmpty` ⇒ `.imported` + 一条整片段仍判需要分析；新增 T-34 源码门与 App 腿 `mixCarrierStillNeedsParentAnalysis`。③ D15：`FolderMixView` 静态核对无纵向 ScrollView（只有类别行横向 ScrollView）、缩略图走 9:16；**900×600 真机版面仍未跑** | `swift test` **1427 通过 / 5 known issues / rc=0**；GC 保护腿三红一绿的正反对照（不加保护时在用视频确实会进可删清单）；P-2 App 腿只编译未执行（会起宿主实例、按纪律交回用户）；D15 真机腿未跑 |
| 2026-11-03 | **App 测试执行腿补跑（用户授权）**：先备份活库四件 + 偏好 plist；临时关 Agent 服务、跳过 GC；跑完还原 | `xcodebuild test-without-building -only-testing:MixCutAppTests` ⇒ **52 passed / 0 failed**；P-2 的 `mixCarrierStillNeedsParentAnalysis` 与既有 JOIN-23/24/25/26 全绿；活库 `store/shm/wal` 哈希与备份相同。**D15 真机 900×600 与 T-1 真机连删仍未跑** |
| 2026-11-03 | **缺陷三成因取证（只读备份库，不碰活库）**：备份库里 165 条全缺，其中 162 条 createdAt=10-08、每条 1–13 个分镜；10-08 日志确有 `Import videos=162`；10-09 13:00 GC 仅 39、16:00 测试项目删除 0 视频、10-15 GC 2；`Suncut/.DS_Store`=10-09 15:48:31、`Videos/.DS_Store`=10-09 15:49:08；缺失视频的缩略图仅 2/165 还在。**结论：不是 GC/删除咽喉，证据指向 10-09 15:49 前后由 Finder/外部批量删除 162 条视频与缩略图，留下 DB 行**；当前活库只剩 2 条缺失，162 条已随 10-25 删项目级联清理。拦不住什么：只能证明「外部删除」，不能直接证明操作者；若用户记得 10-09 清理过测试素材即闭合 | 只读 `sqlite3` 查 `.scratch/store-backup-20261103-152716` 的 4 份备份；未开活库、未杀进程 |
| 2026-11-04 | **T-1 真机腿已补上（非本文件范围，但上一条 2026-11-03 的「T-1 未跑」已过时）**：活库 APFS clone 到 `.scratch/t1-root`，用户在副本 UI 连删 8 个项目（含当前项目）不崩 | 13:03:28–13:03:52 连续 8 条 `GraphSettle`；`ProjectOverview` 删当前项目后 videos=0；app 存活、无 `Fatal`/`OBJECT_NOT_FOUND`；活库四件校验和未变。详见 `2026-10-23-tombstone-fourth-scene-value-projection.md` 的 2026-11-04 行 |
| 2026-11-04 | **D15 900×600 离屏版面探针（不改生产码，临时测试文件已删）**：在 App 测试宿主内用 `ImageRenderer` 按 900×600 内容区渲染 `FolderMixView`，12/20/24 个类别各跑一次 | 12/20/24 类均无纵向滚动、页头/页脚完整；24 类时类别列底部到页脚约 30pt、底部说明行被压成一行，25 类起会与页脚争空间（产品未设类别上限）。**真实窗口人工点验仍未做**：Trae/Terminal 无屏幕录制 TCC，窗口截图只出壁纸；`ImageRenderer` 的 AppKit 控件是占位块，不代表实际外观。缩略图 9:16 仍由 `DesignTokens.Size.videoHeight(forWidth:)` 保证 |
| 2026-11-04 | **D15 硬上限 24 落地**：`FolderMixLimits.maxCategories = 24` + `categoryLimitMessage(count:)`；`FolderMixViewModel.beginScan` 与 `restoreFromDisk` 双入口拦截；超限时 `scan=nil`、候选走唯一 `rebuildCandidates()` 重建口、`FolderMixView` 左栏红字，25 行不再进视图 | `swift test` **1428 通过 / 5 known issues / rc=0**（新增 FMX-19）；App 腿 `twentyFourCategoriesAreAccepted` / `twentyFiveCategoriesAreRejected` **2 passed / 0 failed**；`xcodebuild build-for-testing` PASS（0 error）；`check_folder_mix_guards.sh` PASS、DOC CLEAN。活库四件校验和跑前备份、跑后逐字节相同；偏好已还原 |
| 2026-11-04 | **D15 真机版面修复（用户实测闭环，走预览闸口 C1/C2/C3）**：真机 900×600 + 侧栏 220 ⇒ 页面内容宽 679，用户截图实证 24 类时页脚整行被顶出窗口、页头「素材来源 / 未选」被压成一字一行竖排 ⇒ **427 行离屏探针「24 类放得下」为假阳性**（探针把页面按整 900 宽渲染且 AppKit 控件非真件）。修复 `FolderMixView.swift`：C1 页头标签「来源」+`fixedSize`、「未选」`fixedSize`，超宽由副标题截断吸收；C2 页脚状态行 `lineLimit(1)`+`.help` 全文；C3 类别行名 13→11pt、行距 4→2、删「不参与」文字、脚注缩一行 | 用户自终端编译后真机复测：页头单行横排、24 类页脚完整可见、无纵向裁切、长类别名单行截断；25 类上限红字不变。高度账 24+12+443+12+41 = **532 ≤ 560**（余 28pt），24 类上限保住。本轮纯视图改动不触及 Core，`swift test` 判据（FMX-19/19a/19b）不受影响；App 编译由用户构建成功背书 |

---

## 十、技术评审（A 类三维）新登记的三条同笔项（等签字）

这三条不是新决议，是**笔 K2 落地时必须同笔处理的既有守卫与体形约束**——漏掉任何一条，K2 就不是"改完就绿"，而是"改完把别的门打红"或"把一处性能退化的债留在仓里"。

| # | 发现 | 证据（本回合实读） | 建议落法 | 级别 |
|---|---|---|---|---|
| E1 | 那张**墓碑读基线名册会被收口打红**。`Tests/MixCutCoreTests/TombstoneReadGuardTests.swift:396` 起注释自写着「45 处 / 43 键 / 12 个文件」「新增一处 ⇒ 红；悄悄拔掉一处 ⇒ 也红（销账必须同时改这张表，逼一次 review）」，而它登记的条目里就包含本笔要改的那些行：`MixCut/Views/Import/ImportView.swift` 那三条 `video.segments` 读、`MixCut/Views/Overview/ProjectOverviewView.swift:438` 那颗每卡分镜计数、`MixCut/Views/Schemes/SchemeListView.swift:328` 与 `MixCut/Views/Schemes/NarrativeStructureEditorView.swift:482` 那两处按视频摊开段的读、`MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift` 的 `let targets = video.segments.filter {...}`（计数 2）、`SegmentVariantInspector.swift` 的 `vid.segments.contains(...)` | 名册由 `TOMBSTONE_DUMP_BASELINE=1` 跑 G08d 那条腿**自己生成**，不手写 | 笔 K2 提交 2 里**同笔重生成基线**，并在台账逐条写明每条去向（拔掉的 8 处 ⇒ 收敛到出口体内 1 处）。这不是阻力，是本仓最需要的一次风险下降：关系读点从 8 处散点变成 1 处受控 | P0 |
| E2 | 那颗唯一出口若是**计算属性**，在 `ForEach` 里逐卡调用会把概览页从"一次读全 + 缓存"退化成"每卡全遍历"。`MixCut/ViewModels/ProjectViewModel.swift:96` 的注释已经把这条写死：「关系字段是计算属性（每次访问都走一遍 dedup），所以一次读全、缓存到本 VM」；而 出-5（`MixCut/Views/Overview/ProjectOverviewView.swift:438`）正是**每卡一次**的形态 | 现成验收点：`MixCut/ViewModels/ProjectViewModel.swift:106` 那条 `[Perf] ProjectOverview: …ms / videos=… segs=…` 日志 | 出口只给 **VM 层一次读全**用；每卡计数走概览快照里**新增一颗 per-video 计数**（同一次遍历顺带算出），View 不直接调出口。性能判据＝落地前后各取一次 `[Perf]` 读数对比，禁无基线声称"没变慢" | P1 |
| E3 | 出口体内那一处 `video.segments` 读取是**墓碑读族的新登记点**，不能按"豁免"处理。豁免名单（K2-6）说的是"不许过滤"，而 E1 的名册说的是"谁在读关系字段"——两者维度不同：出口不过滤掉它自己的那次读，它反而成了全仓读该关系最集中的一处 | 同 E1 那张表；`MixCut/Utilities/ModelContextExtension.swift:192` 的注释也记着「id 一律在 delete 之前取」那条同族纪律 | 出口体内那次读**登记进基线名册**（净效果 8 处 ⇒ 1 处），并保留一条反例判据：出口不许在已删项目/已删视频上被调用（真删后读死对象那一族的形状） | P1 |

**顺带排除的两项**（实测过，不是推测）：`scripts/check_undo_guards.sh` 只数 `broadcast` / `GraphBroadcast.post` / `PendingDeletionCenter.shared.schedule` / `safeSave` 四类站点（该脚本 `:218`、`:236`、`:258` 三处实读）⇒ 本方案一处都不动；`Tests/MixCutCoreTests/MediaAvailabilityGuardTests.swift` 内**零** `video.segments` 名册 ⇒ 收口不会打红它。

**结论（三维各一句）**：生长性——收口成一颗出口是把"再加一类段"的成本从 18 处降到 1 处，方向正确，但体形（计算属性 vs 快照）必须按 E2 定死，否则等于把扩展成本换成性能债。健壮性——失败面（补建幂等、缺失先因、degraded 批级、轻量迁移可回退）都已配判据与注入缝，剩下的洞是 E2/E3。回归影响——真正的硬回归不是新代码而是**既有守卫会被合法地打红**（E1 那张表），这类红必须在同一笔里连同台账一起改口，否则门会把修好的代码打回（同 T-25 那条纪律）。

---

## 十一、测试覆盖评估（特殊 → 一般 → 特殊，方案态；未生成测试代码）

种子口径（两个都列，避免后人拿错分母）：**狭义**按文件名 = FolderMix 七颗 118 条 + `WholeClipShapeTests` 8 + `ClipIngestReadoutCharacterizationTests` 5 + `DiskSpaceBudgetTests` 12 = **143 条 `@Test`**；**广义**（谓词 `FolderMix|WholeClip|ClipIngest|SegmentCommitter`）= 14 颗文件 **210 条**。台账那句「族 141」是第三种口径，本表不与其争数，只声明本表口径。

### 11.1 模式库（一般规则，逐条标已被哪颗种子覆盖）

| # | 维度（不变量 / 等价类 / 边界 / 异常分支 / 状态迁移 / 契约） | 现有种子 | 判定 |
|---|---|---|---|
| D1 | 抽中集 ⊆ 入库清单（不变量） | 无（FMX-18 只核数量与来源） | **缺** ⇒ FMX-18d/18e 已登记 |
| D2 | 清单去重与上界 `drawn + reserve` | FMX-18、18b、18c | 已有，不许动 |
| D3 | 档位优先级：缺失 > 无整片段 > 失败码 > 批级 > 没入库 | JOIN-2…7 覆盖后四档 | 部分 ⇒ JOIN-20/21/22 已登记 |
| D4 | 判据不可信 ⇒ 批级拒绝（降级档，不许伪装成"没缺"） | TC-MA 族只管显示侧 | **缺** ⇒ JOIN-23 已登记 |
| D5 | 新增边界参数必须必填（缺参 = 编译期红） | 无（仓里同类先例靠注释） | **缺** ⇒ TC-K1 |
| D6 | 补建的三条守门（形状、在盘、带标记）与幂等 | W 族只测形状本身 | 部分 ⇒ JOIN-24/25/26 已登记 |
| D7 | 补建后段数恒 ≥2 ⇒ 母体两条形状判据恒不命中（跨模块不变量） | 无 | **缺** ⇒ JOIN-27 已登记 |
| D8 | 可见性名册：该挂的都挂、该豁免的零挂（集合相等，非抽样） | T-30 族有同形写法 | 部分 ⇒ T-33 已登记，**防恒真缺** ⇒ TC-K5 |
| D9 | 撤销/回写这类"绕过装载的第二次写入" | 无 | **缺** ⇒ TC-K2 |
| D10 | 轻量迁移：老库开得住、存量行读出默认值、指纹判 additionsOnly | `SchemaFingerprintTests` 20 条里已有 TC-04「加一个字段必须翻指纹」、TC-05 三档分档、TC-06 0 行优先级、SF-13 同实体换类型必须翻 | 相当程度覆盖，**只剩端到端**：真库副本开得住 + 存量行读出默认值 ⇒ TC-K3 |
| D11 | 回退动作的文档口径（放回四件，不是装旧版） | G-g 文档门（扫 file:line 与表形） | 部分 ⇒ TC-K9 |
| D12 | 对外契约不外泄（MCP 键字典零新增） | `mcp_api_guards.py` 已钉键形状 | 已有工装 ⇒ TC-K8 复用，不新写 |
| D13 | 隐形段进 MCP 列表后的编号漂移可观测 | `mcp_api_guards.py:259` 已在跑 `list_segments` | **待人工**（要真机数据，非判据） |
| D14 | 收口不得把"一次读全"退化成"每卡全遍历" | 无（概览有 `[Perf]` 日志但无判据） | **缺** ⇒ TC-K7 |
| D15 | 一档一句人话，且句间不重复 | JOIN-4 测过单档文案 | 部分 ⇒ TC-K4 |
| D16 | 墓碑基线重生成时"净变化必须解释" | Tombstone 门自身（新增/拔掉都红） | 已有守卫 ⇒ **待人工**（人审那条门测不了） |

〔11.1 勘误（同轮自查，2026-10-22）：D10 那格原文写的是「`SchemaFingerprintTests` 只测指纹翻译」——**回源读它的 20 条 `@Test` 标题后证伪**：TC-04 就是「反向对照：加一个字段必须翻指纹」，TC-05/TC-06 管分档与 0 行优先级，SF-13 管同实体换类型。所以纯函数那一半早就有守卫，真缺口只剩端到端（副本库 + 存量默认值）。原句保留在此以便后人不重犯：**列清单前逐条回源，条数不等于工作量。**

### 11.2 覆盖差距矩阵（层级 × 状态）

| 层级 | 已有 | 缺失（真缺口） | 已登记待落地 |
|---|---|---|---|
| Core 单元（`swift test` 打得到） | D2、D3 的后四档、D6 的形状本身、D15 的单档 | D5、D7 的跨模块腿、D8 的自证、D14 | D1、D3 的新档、D6、D7、D15 |
| App 集成（真 SwiftData 容器，`xcodebuild test`） | Join 键两条（TC-J2/J3） | D9、D10 的端到端那一半 | D4、D6 的三条幂等/在盘腿 |
| 守卫与名册（源码扫描） | T-15…T-31、CR 五颗、MAV 族、Tombstone | D8 的分母自证、D11 | T-25 改口径、T-32、T-33 |
| 台架（变异） | 五支 step 台架 + 17 道门自咬 | D1/D3/D8 各自的"只红自己那条"刀 | stepK 三支 14 把 |
| E2E 真机（只能你跑） | 三条对接分支腿 + 反向确认 | D13、D14 | 真机腿 1–7 与 5b |

### 11.3 用例清单（拟新增，每条可回溯到 11.1 的一行；确认后再生成代码）

| # | 层级 | 用例 | 触发规则 | 预期 | 优先级 |
|---|---|---|---|---|---|
| TC-K1 | 守卫 | 混剪那颗新参数在每个调用点都以**带名实参**出现（扫 `rowShapes(` 调用行，缺参即红） | D5 | 一处不缺 | 高（防"忘了传 ⇒ 静默全可用"） |
| TC-K2 | App | 删掉一条隐形段再触发撤销回调 ⇒ 投影里仍不含它；删掉一条**可见**段再撤销 ⇒ 原样回来 | D9 | 两条腿都过 | 高 |
| TC-K3 | App/取证 | 用 `.scratch` 上代库**副本**过 `SchemaGuard`：完整性通过、段数不变、存量段读出默认值 | D10 | 四个读数 | 高（唯一能证"没写坏存量"的腿） |
| TC-K4 | Core | 遍历 `FolderMixFailureCode.allCases`：每档 `shortfallText` 非空、句间两两不同、`isSystemic` 只三真 | D15、D12 同族 | 全等式成立 | 中（`CaseIterable` 之后才可能自动遍历） |
| TC-K5 | 守卫 | 名册腿的**分母自证**：读不到任何一颗在册文件 ⇒ 记 `Issue.record` 而非静默跳过；并跑一条"把名册故意少填一颗 ⇒ 必须红"的正对照 | D8、防恒真 | 正对照红 | 高（本仓「判据因错误原因通过」已经历三次） |
| TC-K6 | Core | 准属性测试：用既有 `FolderMixRandom` 注入缝跑 20 组固定种子，逐组断 D1＋D2＋D6 三条不变量 | D1、D2、D6 | 20 组全绿且至少一组含"跨行重复抽中" | 中（**零新依赖**，替代 SwiftCheck） |
| TC-K7 | 取证/性能 | 概览 `[Perf] ProjectOverview` 改前改后各取一组读数并列，禁写"没变慢"的结论 | D14 | 两列原始数 | 中（禁无基线声称） |
| TC-K8 | 工装复用 | 在既有 `mcp_api_guards.py` 的键名册上加一条"补建计数不得出现在 `get_job`"断言，而不是新写一颗门 | D12 | 键集合不变 | 中 |
| TC-K9 | 文档门 | G-g 必含串名册加「回退 = 放回 `*.backup` 四件」那句，缺失即红 | D11 | 串在册 | 低 |

**待人工（不列为判据）**：D13 的 MCP 编号漂移要真机跑（且 `check_mcp_api_guards.sh` 在你开着 SunCut 时被 8787 占住）；D16 的"基线净变化解释"只能人审。

### 11.4 两条结案陈词（不挂着）

- **不引入 Muter 一类自动变异工具**：本仓台架是"手写语义刀 + 逐把对『只红自己那条』"，而自动算子变异产出的多是等效变异（改了不影响任何判据的常量替换），要人工再判一遍；加上 `swift test` 只编 `MixCutCore`、App 层根本不在同一可执行面 ⇒ 引它不如把刀写准。外部经验里唯一可用的是「**存活体先问这行会被执行吗**」，本仓已经这么写。
- **不引入 SwiftCheck 一类属性测试依赖**：D1/D6 这类不变量的输入空间已被 `FolderMixRandom` 注入缝参数化，TC-K6 用固定种子集就能覆盖"跨行重复抽中"等人工难写的形状；为此加第三方包要过供应链门禁，收益不抵成本。

### 11.5 与计划的关系

11.1 里标「缺」的 6 维中，4 维已由第五节的判据名册覆盖（FMX-18d/18e、JOIN-20…27、T-32/33），**TC-K1…K9 是本轮新登记**；建议在笔 K2 之前先落 TC-K5（防恒真自证），否则 T-33 那条正腿本身就是本仓最典型的"因错误原因通过"候选。
