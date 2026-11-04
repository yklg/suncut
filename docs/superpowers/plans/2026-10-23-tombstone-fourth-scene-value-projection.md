# 2026-10-23 第四处墓碑读现场：崩在 K9 出口体内 —— 概览投影值型化 + 让门重新看见真源

> 本文件是**执行计划**，不是结案报告。生产码一行未改。
> 真源关系：崩溃族的两份活台账仍在 `docs/superpowers/plans/`（`2026-10-03-tombstone-read-after-real-delete.md`、
> `2026-10-04-toone-crossing-real-delete.md`），本文件只登记**第四处现场 + 收口笔次**，不重写它们的前案；
> 文件夹混剪那三份（`2026-10-20-folder-mix-by-category.md`、`2026-10-22-folder-mix-join-key.md`、
> `2026-10-22-folder-mix-drawn-set-and-wholeclip.md`）是**引入这颗崩点的批次**，本文件的 D5 是对它们的返工项。
> 形状约定：本文件按 `scripts/check_plan_doc_citations.py` 的契约写（表格形状、`file:line` 带可核锚点、
> 决议台账 D、修订记录 R、执行进展带日期），验收腿在第七节。修订记录 R1–R1 一条。

## 〇、取证状态表（先说清每句话的来处）

| 断言 | 来处 | 状态 |
|---|---|---|
| 崩点行与调用链 | 用户提供的 `.ips`（SunCut 0.11.0，2026-10-23 10:09:35.800，Thread 0 帧 4–8） | 已取证实读 |
| 崩溃前 45ms 的真删+剪枝 | 活日志 `~/Library/Caches/com.suncut.app/logs/suncut.log` 第 40029–40032 行 | 已取证实读 |
| 改前后那一行的形状差异 | 工作树 `git diff` 两条 `-`/`+` | 已取证实读 |
| 「逐元素 fault 才致命」的因果 | 只由形状与时刻推出，**没复现** | 推断 |
| 「已删对象的持久标量一读就 trap」 | 前案十二格矩阵在本机一次都没复现（见 `2026-10-04` 那份 §22） | 未证，本文件不引用为机理 |
| 崩的那一屏是被删项目还是存活项目 | 日志里 10:09:06 那次同样没触发概览刷新却没崩，两条都还活着 | 未知（第七节 T-1 处置） |
| 门今天的真实读数 | `swift test --filter TombstoneReadGuardTests`：24 条 / 2 条 known issue / rc=0 | 已跑 |
| 七支 shell 门 | `check_folder_mix_guards.sh` 等七支全部 rc=0（本轮建册前实跑） | 已跑，改前基线 |
| 投影持模型引用的存量 | 本文件第三节那三次自写扫描，**口径不同、含噪**，落码时以门生成腿为准 | 粗测 |

## 一、症状与影响（不是「改那一行」）

- 现场：项目概览页的成片卡片网格。崩溃发生在**懒栅格测量 pass**（栈里是 `LazyVGridLayout` → `measureEstimates` → `ForEachState.forEachItem` → `VideoCard.body`），
  距上一次真删落盘 45ms。屏上那次删除是 `删项目《爆点》：连带删无引用视频 9 颗`，随后 `剪枝 projects=1 videos=9 segs=9`。
- 频率：**偶发但可批量诱发** —— 用户在一分钟内连删 13 个项目，崩在最后一次。单次删除没崩过。
- 影响面：崩的是进程，不损库（重启后概览页正常读出 `videos=8 segs=12`，且本族前案已坐实「外键在 save 时就清掉」⇒ 盘上没有悬空行可腐）。
- 表面症状 vs 真实诉求：表面是「`Text("\(video.displayableSegmentCount) 分镜")` 这一行崩了」（`MixCut/Views/Overview/ProjectOverviewView.swift:438`）；
  真实诉求仍是本族从第一天就那句 —— **界面投影不许持有可被存储层销毁的对象**。只把这行换回 `video.segments.count` 是把界线丢掉（见 D2 的反面）。

## 二、根因上溯（五问 + 落层）

1. **为什么崩？** 主线程 layout pass 里逐条 fault 已销毁 `Segment` 的持久列 `mixInternalWholeClip`（`MixCut/Models/Segment.swift:157`），命中 SwiftData 内部断言。
2. **为什么 layout pass 会读到死对象？** 因为 `VideoCard` 的入参是 `let video: Video` —— 抄的是**对象引用**，而「视图正在被移除的那一趟它还会再算一次 body」是本族在册的形状（`MixCut/Utilities/ModelContextExtension.swift:7-9` 那条注释写的就是这件事）。
3. **为什么视图能拿到对象引用？** 因为 `MixCut/ViewModels/ProjectViewModel.swift:83` 那颗 `var videos: [Video] = []` —— 概览页的数据源是**VM 里缓存的模型对象数组**，不是值。
4. **为什么这份缓存没人负责摘干净？** 因为「视频投影」在剪枝分支里**没有消费者**：`MixCut/App/ContentView.swift:241-247` 里 `.segment`、`.project` 各有消费者，`.video` 的那份 id 只进了 `[GraphPrune]` 那行日志；而 `MixCut/ViewModels/ImportViewModel.swift:1163` 那颗 `pruneDeletedVideos` 全仓**零调用方**（实测 grep 只剩定义本身）。
5. **为什么这个形状能一直长在这儿？** 两条，落在不同层：
   - **系统层（缺抽象）**：UI 状态与持久实例是同一批对象。实测三档口径的存量见第三节；本仓没有任何一层「快照=值」的边界，只有 15 处 VM stored property 与一批视图入参在直接持引用。
   - **模块边界（真源与门不同层）**：`RelationshipReadScan` 的两条真仓腿都只喂 `viewSources()`（`Tests/MixCutCoreTests/TombstoneReadGuardTests.swift:389` 与 `:819`），而决议 K9 把真源搬进了 `MixCut/Models/` ⇒ 门看不见。名册注释自己承认：「净变化 −1 处 = 逐卡计数与项目级计数两处改读 `displayableSegmentCount`（那颗不按关系名认出）」（同文件 `:404`）。
6. **为什么昨天之前不崩？** 同一处改前是 `video.segments.count`：取关系数组的**长度**不逐元素加载 backing row；改后 `MixCut/Models/Video.swift:150` 用 `reduce` 对**每一条段**读一次持久列。这不是「新代码有 bug」，是**新代码把一个原本惰性的读换成了实读**，而它落在最要命的那条腿上。

**根因判定（一句话）**：`isPrunable` 那条 `.video` 特例的前提已经腐烂。它写着「界面里没有独立的视频投影生命周期 —— 视频列表一律从活着的 `Project.videos` 现读，删项目时那份投影随 `pruneDeletedProjects` 取消选中一起拆掉」
（`Sources/MixCutCore/UndoGraceMachine.swift:187-190` 区间的文档段）。两半都不成立：概览页那份正是**缓存的、独立的**视频投影；而 `pruneDeletedProjects` 只在被删项目**恰好是当前项目**时才清空那颗 `overviewSnapshot`（`MixCut/ViewModels/ProjectViewModel.swift:332-334`）。
契约靠注释维持、注释的前提没人守 ⇒ 这是设计层缺失，不是某一行的错。

**验证方式**（本仓的规矩：根因要用「改掉它症状是否消失 / 是否在别处复发」来验，验不了就标推断）：
本轮无法用「崩与不崩」当判据（前案十二格 + 本现场都没能造出可复现的 trap）。所以 A 的证明走**形状级**：
把「body 面还能 fault 出可死对象」这个能力从构造上去掉，再用门钉住它不许回来。真机的因果验证交给第七节 T-1。

## 三、族的边界：存量必须先用数字摊开（三次自写扫描，口径互不相同）

| 口径 | 实得 | 备注 |
|---|---|---|
| 五顶层目录下「类型里出现模型类名」的 `var/let` 声明 | 128 处 / 37 颗文件（数组型 51、可选 30、裸单颗 47） | 含函数内局部量，**过计** |
| 同上，但第一版正则漏吃 `= []` 初值 | 101 处 | 少计 27 处 —— 恰好漏掉 `videos: [Video] = []` 这颗本文件的靶子 |
| 只算 `MixCut/ViewModels/**` 里 4 空格缩进的 stored property | 15 处 / 6 颗文件 | 本文件 D6 名册的口径 |

结论与纪律：
- 「128 / 101」两个读数是同一件事的两次错法，**都不进名册**；名册一律由门自己的重生成腿产出（照 `TOMBSTONE_DUMP_BASELINE=1` 那条腿的先例），不手写。
- 正则的 `= []` 那一格要**写进新门的注释**：漏掉带初值的声明会让「谁持着模型引用」的名册天然少计，而少计的那颗正是会崩的那颗。
- 视图入参那一档（`let video: Video` / `let segment: Segment`，实测 47 处 / 23 颗文件）**本轮不动**，登记为在册欠账（第八节 C-3）—— 一次性把它们值型化是跨十个页面重写、且每一页的取数时机都要重评，不属于止血笔次。

## 四、候选方案与三条硬标尺

| 方案 | 改哪个模块 / 职责怎么调 | 上下游影响 | 可扩展性收益 | 三条标尺 |
|---|---|---|---|---|
| A 概览投影值型化（推荐主刀） | `ProjectViewModel` 的 `OverviewSnapshot` 从「装对象」改「装值行」；`VideoCard` 的入参类型换掉 ⇒ 视图层与存储层之间第一次出现一条真边界 | 概览页 5 处读数 + prewarm 入参 + `DebugSelfTest` 那条快照腿（只读 `videoCount`，不受影响） | 每加一类段/一类卡片字段，改的是「行里多一颗值」，不再决定「body 里能不能 fault」 | 根因层✓ 非遮盖✓ 不增耦合✓ |
| A′ 只把 `displayableSegmentCount` 换回 `segments.count` | 一行，报错点回滚 | 无 | 无 | **不合格**：混剪补建的内部段重新被算进用户可见分镜数（界线丢一处），且下次再需要逐元素读时同一个洞原样重开 |
| B 给 `.video` 补消费者 | `ContentView` 剪枝分支接住 payload 里已有的 video ids；`ProjectViewModel` 加一颗纯剪函数 | 只读 `change`，不改发布口、不改 `isPrunable` | 让「有没有人接得住才叫能剪」这条既有纪律第一次在视频档成立 | 根因层✓ 非遮盖✓ 不增耦合✓ |
| B′ 顺带让视频删除咽喉也 note `.video` | 会翻 `UndoGraceMachine.swift:194` 那条特例与 UG-G13（它数的是 `scripts/check_undo_guards.sh:317` 那条 `.video` 分支） | 递归前提（`loadSegments` 首行 `flushNow()`）要一起重评 | —— | **本轮不做**，登记 C-2（跨模块契约变更，须单独评审） |
| C 出口体内过门 | 在 `MixCut/Models/Video.swift:147` 与 `:150` 体内滤死对象 | 19 处调用方全部受影响 | —— | **不合格为主刀**：`.live` 形态已被门钉死不许跨边用（那条腿叫 `noEdgeLiveFaulting`，见 `Tests/MixCutCoreTests/TombstoneReadGuardTests.swift:1374`，它的报错文案写明「必须改为标识符优先」），而标识符优先要在出口体内 fetch ⇒ 把一次 UI 读变成两次存储访问；且那个相位还没测 |
| D 让门重新看见真源 + 补 E3 欠账 | 扫描面扩到 Models 出口；新门 G24/G25；T-33 名册改口 | 会让既有守卫**合法变红**，必须同笔销账 | 收口「真源在哪一层」与「门扫哪一层」不再分叉 | 根因层✓ 非遮盖✓ 不增耦合✓ |

**推荐**：A + B 同笔落地，D 同笔补门并把 T-33/E1 那批合法红项一起销账；C 不作主刀、只作欠账 + 一格矩阵。理由：A 是唯一能**构造性消灭**这条失败面的做法（body 再也拿不到可死对象），B 是 A 的配套（值型行才谈得上按 id 剪；装引用时剪枝自己就要 fault），D 是防止「下一次收口又把热读点搬出门的射程」。

## 五、决议台账

| 号 | 要拍的问题 | 候选与推荐 |
|---|---|---|
| D1 | 概览投影装对象还是装值 | 装值（A）／保持现状只加过门（C）。推荐**装值**：过门只挡已知相位，装值消灭整类相位 |
| D2 | 每卡段数在哪个时点取 | 在 `refreshOverviewSnapshot` 一次读全时取好／仍在 body 里现取。推荐**前者**，且这正是那颗出口注释里 E2 那条教训的正解（`MixCut/Models/Video.swift:143` 区段） |
| D3 | 值型行住哪一层 | `ProjectViewModel` 内嵌 struct（照今天 `OverviewSnapshot` 的住所）／提到 `MixCutCore`。推荐**内嵌**：Core 侧现有代码刻意不 import SwiftData（`Sources/MixCutCore/SchemaFingerprint.swift:16` 的注释写了这条可测性约束），把 UI 行塞进 Core 是让边界反着长 |
| D4 | `pruneDeletedVideos` 这颗零调用方函数 | 接进剪枝分支／登记为死码。推荐**接进来**（它已写好在 ImportViewModel.swift:1163，一行成本，且删别的项目时导入页的选中集同样该剪） |
| D5 | T-33 名册里那条「每卡分镜数」的 needle | 改钉 VM 侧那颗取数点／给视图留一条假写法。推荐**改钉 VM**，并把「19 处都挂上唯一出口」那句计数与说明同轮改口（这是 E1 同形风险：合法打红既有门） |
| D6 | 新门的射程 | 只钉概览这一颗（G24）＋ VM 层 stored property 名册（G25，口径见第三节 15 处）／全仓 128 处一起管。推荐**先窄**，宽口径留给视图入参那档单独一批（C-3） |
| D7 | prewarm 与 readiness 那几处锚 | 保持 `shared.prewarm(paths: …, for: project.id)` 单行形状不动语义。硬约束：`scripts/check_navigation_readiness_guards.sh:140` 与 `Tests/MixCutCoreTests/TombstoneReadGuardTests.swift:970` 两处按形状计数，改形状就双红 |
| D8 | 本轮交付里「已修好崩溃」这句话怎么说 | 只说「失败面从构造上去掉了 + 真机腿待跑」／说「已修」。推荐**前者**：本族至今没有任何一条判据能证「不崩」，声称已修就是给下一轮评审递一把刀 |

## 六、笔次与改动点（最小侵入，逐条可回滚）

### 笔 V1 —— A：概览投影值型化

1. `MixCut/ViewModels/ProjectViewModel.swift`：在 `OverviewSnapshot`（`:82` 那颗 struct）里把 `videos: [Video]` 换成 `var rows: [OverviewVideoRow] = []`，
   并新增同文件内嵌 `struct OverviewVideoRow: Identifiable, Equatable`，字段只有值：`id: UUID`、`name: String`、`duration: Double`、`width: Int`、`height: Int`、`thumbnailPath: String?`、`visibleSegmentCount: Int`。
   字段命名纪律：`visibleSegmentCount` 刻意不叫 `segments` / `displayableSegments` —— 与本族既有那条「同名会让『读这份投影』和『fault 模型关系』在源码里长得一模一样」同源（`MixCut/ViewModels/SegmentLibraryViewModel.swift:16-20`）。
   ⚠ 扫描器口径提醒：`var videos: [Video] = []` 这种**带初值**的声明，本文件第三节第一版正则漏吃过；新门的取样必须显式覆盖带 `=` 的形态并配一条变异腿。
2. `MixCut/ViewModels/ProjectViewModel.swift`：`refreshOverviewSnapshot`（`:95`）内**这一次读全**里逐视频算好 `visibleSegmentCount`（照 `:99` 现在那颗 `reduce` 的写法），行里其余字段取 `video` 的标量；
   函数首行加 `guard !project.isGoneFromGraph else { return }`（`MixCut/Utilities/ModelContextExtension.swift:29`）。
   ⚠ 那条 guard 挡的是「拿一颗死项目去 fault 整张表」，**它不是本崩溃的证明**（`isDeleted`/`modelContext` 在第三起那个相位双 false，前案已记）；写注释时不许把它写成"防崩"。
   `[Perf] ProjectOverview` 那行日志（`:106`）保持原样 —— 它是 E2 的现成验收点，改前读数 37ms / videos=30 / segs=135。
3. `MixCut/ViewModels/ProjectViewModel.swift`：`pruneDeletedProjects`（`:329`）里那次「整颗清空快照」（`:334`）保留，但注释要改口 —— 现在快照装的是值，「成了一串死引用」这句话会变成假话。
4. `MixCut/Views/Overview/ProjectOverviewView.swift`：`:145` 的 `snapshot.videos.isEmpty` → `snapshot.rows.isEmpty`；`:196` 的 `ForEach(snapshot.videos)` → `ForEach(snapshot.rows)`；
   `VideoCard` 的入参 `video: Video` → `row: OverviewVideoRow`，body 内五处读数（`:427` 名字、`:432` 时长、`:435` 分辨率、`:438` 段数、`thumbnailPath` 在 `MixCut/Views/Overview/ProjectOverviewView.swift:472`）全部吃行内值，
   `videoAspectRatio`（`:412`）改吃 `row.width`/`row.height`。
5. `MixCut/Views/Overview/ProjectOverviewView.swift:41` prewarm 改 `snapshot.thumbnailPaths`（VM 侧派生的一颗计算属性，返回 `[String]`），**整行形状保持** `ThumbnailCache.shared.prewarm(paths: …, for: project.id)` 且不换行（D7）。

### 笔 V2 —— B：`.video` 剪枝第一次有消费者

1. `MixCut/ViewModels/ProjectViewModel.swift`：新增 `func pruneDeletedOverviewVideos(_ ids: Set<UUID>)` —— 纯剪 `rows`，并按剩下的行**同步重算** `videoCount` 与 `segmentCount`。
   ⚠ 最容易写错的一格：只剪 `rows` 不重算 `segmentCount`，上方那三张 `StatCard`（视频/分镜/方案，吃的就是 `snapshot.videoCount` 与 `snapshot.segmentCount`）会跟卡片列表各说一套。
   剪与算的**纯判据下沉到 `Sources/MixCutCore`**（一颗值类型函数，输入 rows 值数组 + 待摘 id，输出新计数），这样 `swift test` 就能直接证，不必起容器 —— 与本仓「规则住 Core、VM 只持值」的既有范式一致。
2. `MixCut/App/ContentView.swift`：剪枝分支（`:240-249`）取 `change.idsDeleted(of: .video)`，下发给 `projectVM.pruneDeletedOverviewVideos(...)` 与 `importVM.pruneDeletedVideos(...)`（D4）。
   ⚠ 硬约束：**第一行分叉之后一条都不许碰** `fetchProjects` / `loadSegments` / `loadSchemes` / `flushNow`（那条规则原文从 `MixCut/App/ContentView.swift:235-237` 起）；本笔是**纯剪**，由 V-5 那条腿新钉住。
3. `Sources/MixCutCore/UndoGraceMachine.swift`：`:159` 那句「`.video` 的消费者是间接的」在 V2 之后变假话 ⇒ 同轮改口为「`.video` 有直接消费者（概览投影 + 导入页选中集），但**视频删除咽喉仍不 note `.video`**，所以 `:194` 那条特例保留」。`isPrunable` 与 `prunable`（`:160`）**一个字符都不改**。
4. 不做：`GraphBroadcast`、宽限期、撤销条 —— 本笔不碰发布口与待删台账。

### 笔 V3 —— D：门重新看见真源，并补 E3 那条欠账

1. 把 G08 与门 5 的真仓取样面从「只喂 `viewSources()`」扩成「Views ∪ Models 里返回模型数组的计算出口」⇒ 基线名册必然新增登记（至少 `MixCut/Models/Video.swift:147`、`:150`、`MixCut/Models/Project.swift:67`、`:77` 四处）。
   名册由重生成腿产出、逐条写去向；这条改动的**反例腿**要证明扩面不是白扩：注入一处 `Models` 里的 `var xxx: [Segment] { … }` 形态必须被认出来。
2. 新门 **G24 值型投影契约**：钉 `OverviewSnapshot` 与 `OverviewVideoRow` 的字段类型里**一个模型类名都不许出现**；配变异腿 —— 把 `videos: [Video] = []` 原样写回去必须红（这一腿同时覆盖第 1 条说的「带初值的声明」取样口径）。
3. 新门 **G25 名册**：`MixCut/ViewModels/**` 里 stored property 类型含模型类名的逐条登记（第三节实测口径 15 处 / 6 颗文件，以生成腿为准），新增一处即红、销账必须同批改表。
4. 补 E3 欠的那条反例判据（第三轮评估写了「出口不许在已删项目/已删视频上被调用」，实扫全仓不存在）：App 腿真容器 —— 删一颗视频及其段 ⇒ 对**存活**项目调两颗出口，结果里既不含被删 id、也不得让被删段参与计数。
5. T-33 名册改口（D5）：`Tests/MixCutCoreTests/FolderMixIngestGuardTests.swift:911` 那行的 (file, needle) 从「视图片每卡分镜数」改钉「VM 侧那颗按视频摊开段数的取数点」；
   同轮改口 `:900` 那句「19 处都挂上唯一出口」的计数与说明（V1 之后 ProjectOverviewView 里不再出现 `displayableSegmentCount` 这颗字面）。
6. 现网那条注释也要一起扫：`MixCut/Models/Video.swift:143-161` 那段「逐卡读数请用 `displayableSegmentCount`，绝不要在 ForEach 里逐卡调」——V1 之后「逐卡调」这件事整体被禁了，注释若不改就成了下一轮的错误前提。

### 笔 V4 —— C：不作主刀，登记 + 一格矩阵（见第八节）

## 七、判据与验收腿（每条写清它证明什么、拦不住什么）

| 号 | 腿 | 跑在哪 | 证明什么 / 拦不住什么 |
|---|---|---|---|
| V-1 | 删项目 ⇒ 概览 `rows` 里对应 id 消失，且 `videoCount`/`segmentCount` 与剩下的行自洽 | App 腿（真容器，`MixCutAppTests`） | 证剪枝正确；**拦不住崩**（崩的相位造不出来） |
| V-2 | G24 契约 + 写回 `videos: [Video]` 的变异 | `swift test` | 证「投影里再没有可死引用」这一构造性事实；拦不住别处的引用型投影 |
| V-3 | 补建的内部段不计入概览每卡数（把 `Video.swift:145-183` 的实现退回成 `segments.count` ⇒ 必红） | App 腿 | 界线回归腿；证明 A 没把 K9 的语义换掉 |
| V-4 | 剪与算的纯判据（Core 值函数：给 rows + ids ⇒ 新计数） | `swift test` | 证重算不等于只剪；拦不住 UI 是否真调它（由 V-5 钉） |
| V-5 | 剪枝分支「纯剪」形状：`reloadAfterUndo`（`MixCut/App/ContentView.swift:239-249`）那段里不许出现 `load`/`flushNow`/`fetchProjects`，且两颗 video 消费者各被点名一次 | shell 门（并入 `scripts/check_undo_guards.sh`） | 证 V2 没把递归引回来；拦不住剪枝语义对错 |
| V-6 | 扩面后的 G08/门 5 基线与 T-33 名册逐条相等（改口表同步） | `swift test` | 证「门看得见真源」；这条**本身就是本轮的回归防线** |
| T-1 | 真机复现当时动作序列：概览停在屏上、连删 ≥8 个项目（含一个当前项目）不崩 | 用户手测或 Mac2 UI 环（起进程前必须先断言端口持有者 PID 是自己起的） | 唯一能因果证明「不再崩」的腿。**没跑之前本轮不得声称已修** |

四腿交付验收（改过任何 Swift 都要重跑，含纯注释改动）：
`swift test`；App 侧 typecheck / silgen / `xcodebuild build` / `build-for-testing` 四腿；`.scratch/dd` 重建；
`bash scripts/check_undo_guards.sh`、`bash scripts/check_navigation_readiness_guards.sh`、`bash scripts/check_folder_mix_guards.sh`、
`python3 scripts/check_pbx_registration.py`、`python3 scripts/check_plan_doc_citations.py <本文件>`。
改前基线（2026-10-23，全部实跑）：`swift test --filter TombstoneReadGuardTests` = 24 条 / 2 条 known issue / rc=0；
`check_folder_mix_guards.sh`、`check_navigation_readiness_guards.sh`、`check_undo_guards.sh`、`check_live_store_guards.sh`、
`check_schema_ledger_guards.sh`、`check_association_guards.sh`、`check_project_integrity.sh` 七支 rc=0；
`check_plan_doc_citations.py`（默认那份）DOC CLEAN。

## 八、在册欠账（本轮明确不做，写清为什么）

| 号 | 事项 | 为什么不做 | 何时必须回来 |
|---|---|---|---|
| C-1 | 那个相位的实验：关系数组已 materialize、元素在另一颗 context 里被真删并 save 之后，回主 context 逐元素读持久列到底 trap 不 trap | 前案十二格读的都是**已 materialize 实例的标量**，所以全绿；本格是新相位，得单独造 | C 若要做主刀（出口体内过门）之前，必须先有这格读数 |
| C-2 | 视频删除咽喉 note `.video` ⇒ 与 `UndoGraceMachine.swift:191-195` 那条特例、UG-G13 一起重评 | 跨模块契约变更，且要先解决「`loadSegments` 首行 `flushNow()` 的同栈递归」那个前提 | 与「只删视频」这条链要做剪枝的那一批同笔 |
| C-3 | 视图入参那一档 47 处 / 23 颗文件的 `let video: Video` / `let segment: Segment` | 一次性值型化 = 跨十个页面重写且每页取数时机都要重评；不是止血笔次 | 每页各自改动时顺带收，G25 保证不会**新增** |
| C-4 | 根因仍未定这件事本身 | 本文件给的是「第四处现场 + 失败面被构造性消灭」，不是结案 | 别把 A+B+D 读成「墓碑读族已收口」—— 前案 §22 那句「十二格全不 trap」仍然有效 |
| C-5 | 分镜库 / 导入页同样在 body 里逐元素读出口（`MixCut/Views/Import/ImportView.swift:841`、`:904`、`:1146` 区段） | 它们**已在 G08 名册里在册**，不是本轮新洞；本轮只处理「脱册」那一颗 | 下一轮按页收口 |

## 九、回滚点与实施纪律

- 三笔各自独立可回滚：V1（值型行）、V2（消费者）、V3（门）各一笔提交，**判据与刀同笔**；V3 的门若在 review 中被判过重，可以单独退回而 V1/V2 的止血不受影响。
- 不动的东西要写明，免得顺手：`isPrunable` 与 `GraphEntity.prunable`（`Sources/MixCutCore/UndoGraceMachine.swift:160`）、发布口 `GraphBroadcast`（G19 钉全仓那条通道 `post` 恰好 1 处）、真删站点名册（G12 钉 54 处）、schema 版本锚点与 stages、`Segment.mixInternalWholeClip` 这颗字段本身。
- 不新增文件 ⇒ 不碰 `MixCut.xcodeproj/project.pbxproj`；若实施中确需新建测试文件，`register_pbx_file.py` + `check_pbx_registration.py` 必须同笔跑。
- 本仓的老规矩照守：**不许去开用户的活库**（`check_live_store_guards.sh` + CLAUDE.md 那条）；需要现场相位时用 `MIXCUT_DEBUG_APP_SUPPORT_ROOT` + 临时目录 store。
- 若评审推翻本文件任一条（尤其第二节的根因判定与 D1 的取舍），走「原文不删 + 版本表加行 + 〔勘误 R#〕」回写，不覆写。

## 十、修订记录

| 号 | 内容 |
|---|---|
| R1 | 2026-10-23 建册：第四处现场取证（`.ips` + 活日志时间线 + `git diff` 改前后形状）、五问上溯到 `isPrunable` 前提腐烂、A/A′/B/B′/C/D 六案过三条硬标尺、笔次 V1–V4、判据 V-1…V-6 与真机腿 T-1、欠账 C-1…C-5、回滚点。生产码零改动 |

## 执行进展

| 日期 | 产出 | 取证 |
|---|---|---|
| 2026-10-23 | 建册 + 全部取证只读腿跑完 | `.ips` 现场行号链；活日志第 40029–40032 行；`swift test --filter TombstoneReadGuardTests` 24 条 / 2 known issues；七支 shell 门 rc=0；三档存量扫描 128/101/15 处；本文件 DOC CLEAN 待跑 |
| 2026-11-03 | **笔 V1–V3 落地**（D1–D7 按推荐拍定；V4 仍为「C 不作主刀」的登记，零代码）：① `OverviewSnapshot` 从装 `[Video]` 改为装 `OverviewVideoRow` 值行 + `countRows` 全量值行（自建分镜仍计入分镜总数、不进卡片）；`refreshOverviewSnapshot` 一次读全并加 `isGoneFromGraph` 前置；`VideoCard` 入参改值行，body 内五处读数全部吃行内值；prewarm 走 `snapshot.thumbnailPaths`；② `pruneDeletedOverviewVideos` 接进 `ContentView.reloadAfterUndo`，与 `importVM.pruneDeletedVideos` 同笔，纯剪不 fetch；`UndoGraceMachine` 注释改口（`isPrunable` / `prunable` 一字未改）；③ G08 与门 5 取样面扩到 Views ∪ Models，G24/G24b 值型投影契约、G25/G25d VM 持引用名册（20 处 / 6 文件）、T-33 19→18 改口；④ App 腿 `OverviewProjectionAppTests` 2 条（删视频纯剪 + 删项目清空） | `swift test` **1421 通过 / 5 known issues / rc=0**（基线 1412 + 9：`OverviewProjectionPruneTests` 5 + G24/G24b/G25/G25d 4）；`MODE=typecheck` / `MODE=silgen` PASS（279 编译单元）；`xcodebuild build-for-testing` PASS（沙盒 `-load-plugin-library` 绕法，0 error；同步组导致 8 条 duplicate build-file warning，编译仍成功）；`check_pbx_registration` PASS；G08 42→47（Models +5）、门 5 35→39（Models +4）；12 支 shell 门 + DOC CLEAN 全 PASS；**App 测试执行腿未跑**——`TEST_HOST=SunCut.app` 会在用户活库上开库，按 `CLAUDE.md` 纪律交回用户；真机连删腿 T-1 同样未跑 |
| 2026-11-03 | **App 测试执行腿补跑（用户授权）**：先备份活库四件 + 偏好 plist；临时关 Agent 服务、把 `lastOrphanGCAt` 推到当前时刻以跳过 GC；跑完还原 | `xcodebuild test-without-building -only-testing:MixCutAppTests` ⇒ **52 passed / 0 failed**；`overviewProjectionPrunesWithoutFetching`、`overviewProjectionClearsWhenSelectedProjectIsDeleted`、`mixCarrierStillNeedsParentAnalysis` 全绿；`Suncut.store` / `-shm` / `-wal` 与备份 SHA-256 逐字节相同，`launch-ledger` 与偏好已还原；SunCut 宿主进程退出。**T-1 真机连删腿仍未跑** |
| 2026-11-04 | **T-1 真机手测通过（用户授权，在活库 APFS 克隆上操作）**：活库 13G clone 到 `.scratch/t1-root`，用户在副本 UI 上右键连删 8 个项目（含当前 `zjm`），等 5s 撤销宽限落库 | 13:03:28–13:03:52 连续 **8 条 `GraphSettle`**（辅助卖点/过渡/卖点/爆点/文件夹混剪/zjm/花/测试）；删 `zjm` 后 `ProjectOverview` 4ms / videos=0；**app 全程存活，日志无 `Fatal` / `OBJECT_NOT_FOUND`**；删后 0 项目；活库 `store/shm/wal/launch-ledger` SHA-256 与备份相同，偏好已从快照还原；测试克隆已删除。**文件夹混剪 900×600 真机版面仍未看** |
