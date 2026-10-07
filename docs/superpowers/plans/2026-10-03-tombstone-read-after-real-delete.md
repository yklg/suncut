# 真删之后界面无主地认识死人：tombstone 读取崩溃的收口计划

状态：**v1.10**（§12 守卫已落、§13 第一批生产改动已落、**§3 刀 2 已收进事务中心并接完宽限期链**（§14.6/§14.7）；§14 记**第二起同族崩**的取证与升级）。生产代码状态以 §13/§14.7 为准，第二起的方案在 `2026-10-04-toone-crossing-real-delete.md`。

| 版本 | 变化 |
|---|---|
| v1 | 初版，含 2 项待拍板 |
| v1.1 | 拍板项 1 定为 **1-A**：配音批量作用域的定义域 = 本视频**未筛选**全部分镜（与 `video_no` 编号同源） |
| v1.2 | architecture-visualization 评审后升版：**§1.4 三处证据断言被推翻并改正**（裸读面 24→55 处；「没有失效机制」→「机制已存在、UI 删除链一次没发」；delete 站点 ~15 函数→41 处/11 文件）；刀 2 改为**补全已有通道**；刀 3 加 SDK 实证与第 5 处站点；刀 5 门 4a 的禁词表补第二条来源 |
| v1.3 | 拍板项 2 定为 **2-B**（同一条通道 + 可选「被删 id」载荷）。第二轮评审发现一条**与选项无关的 P0**：本仓已有 `modelContext == nil` 这道「正在被移除的视图自己会重算」的渲染门，但只散在 4 处、分镜库一处没有 ⇒ **新增刀 6**；同时刀 2 补：载荷按实体分组、未登记实体回落旧语义、`post` 收口一处、观察者顶端防重入、MCP 保持无载荷 |
| v1.4 | `test-coverage-expander` 第三轮：产出**覆盖差距矩阵 + 用例清单**（§11）。两处对计划的实质修正：**① 门 4a/4b 的主体落点从 shell 脚本改到 `Tests/MixCutCoreTests` 源码扫描守卫**（本仓已有 5 颗这种守卫、自带「非恒绿」自证范式）；**② 新增一条外部经验维度 CTX-01「关系两端必须同属一个 context」**，本仓零覆盖且启动 fixups 确实开着 3 处独立 `ModelContext` |
| v1.5 | **刀 5 的 Swift 守卫已交付**（§12）：`TombstoneReadGuardTests.swift` 8 条用例（G08/G08b/G08c/G09/G10/G11/G12/G12b）自跑全绿；基线由守卫自己生成（49 处 / 47 键 / 12 个文件），**§1.4① 的 55 与 §11 期间的 40 都被作废**，以 §12 为准 |
| v1.6 | **第一批生产改动已落地**（§13）：刀 1 首批（4 处裸读拔掉）+ 刀 3（快照收进 API，5 处站点）+ 刀 6（`isDroppedFromContext` 一处真源 + 分镜库过门）。守卫基线 **49 → 45**，G08 的崩点断言由「必须在册」改指「不得复发」，新增 G08d 作为基线重生成腿。`xcodebuild` Debug **BUILD SUCCEEDED** |
| v1.7 | **第二起同族崩**（2026-10-04 11:59，`Project.id.getter`，崩 `SegmentPickerDrawer.swift:106`）⇒ §14：**本计划的不变量与守卫被证明射程不足**。刀 2（失效广播）与刀 6 追加腿（文件级门）从「第二批」**升为必要配套**；另补 SDK 一手取证一条：**`PersistentModel.isDeleted` 存在但会翻回 false** ⇒ `isDroppedFromContext` 单判据要升级为两信号析取。方案落 `2026-10-04-toone-crossing-real-delete.md` |
| v1.8 | §14.5 **勘误**：本文件 §3 刀 2 关于 `GraphChange` 类型落点（放 `ContentView.swift`）的规定被推翻 ⇒ 下沉 `Sources/MixCutCore/`（否则 Utilities 依赖 App = 逆流，且广播回滚后成幽灵代码）。原文不删，以勘误条为准。另记两条与 `check_navigation_readiness_guards.sh` / `check_association_guards.sh` 的**锚点互斥面**，刀 1/刀 6 续批同样适用 |
| v1.9 | **§3 刀 2 的机制层已落码**（§14.6，落 `2026-10-04-toone-crossing-real-delete.md` §25）：通道可带 `GraphChange`、唯一发布口 `GraphBroadcast`（降级 + 重入闸）、观察者顶端分叉只剪枝、⌘Z/⇧⌘Z 与 MCP 的裸 post 全部并入 ⇒ 全仓该通道 `post(` 恰好 1 处（G19 钉住）。**逐条 UI 删除链仍一次不发** ⇒ §1.4④ 的诊断只对机制收了口，本文件根因层尚未收口 |
| v1.10 | **刀 2 续批：广播口收进事务中心、宽限期 6 条删除链全部接入**（§14.7，细节在本案 §26）：`schedule(commit:)` 闭包交回 `GraphChange`、中心代广播、空台账不发；新判据 **UG-G09 + 变异腿 M9**、新**格 ⑮** 六腿（含"广播晚于登记"的变异反向对照，读数 `B commit 0→1`）。重入从**丢弃**改**排空队列**（丢弃的理由站不住：嵌套那次带的是 `flushNow` 顺带真删的**新** id）。§1.4④ 的收口状态：宽限期链 ✅、非宽限期 11 行直删 ❌ |

拍板项已全部定完（1-A、2-B）。§10 的三条 P0 是**落地前置条件**，不是待选问题。§11 是覆盖方案，**未经你确认不生成测试代码**。

---

## 0. 要解决的问题

SunCut 0.11.0 Debug 于 2026-10-03 21:10:13 崩溃：`EXC_BREAKPOINT (SIGTRAP)`，主线程，
`Segment.id.getter` → SwiftData 内部 → `_assertionFailure`。

一句话根因：**库里已经真删的 `Segment` 对象，仍然被界面持有并被读取**；而界面重绘时读取的是**模型的 to-many 关系本身**，不是任何一份可被剪枝的投影。

直接触发点 `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift:688`
（`domainIDs: Set(video.segments.map(\.id))`，`e040cd5` 当天引入，落在 LazyVStack 的 measure 热路径上）。

---

## 1. 取证（四条独立来源，都能在你机器上复核）

### 1.1 崩溃栈自身给的判别

同一个 `sectionHeader` 里，`video.thumbnailPath`（639 行）、`video.id`（665 行）都读到了，
**死的是 `video.segments` 里的元素，不是 Video 本身**。这条排除了「整个视频对象已被删」那一支。

### 1.2 日志时间线（`~/Library/Caches/com.suncut.app/logs/suncut.log`，1978 行，末尾停在 21:09:53）

| 时间 | 事件 | 意义 |
|---|---|---|
| 21:05:54 | `[Readiness] 分镜数据已就绪 project=19BF… segs=45` | 分镜库投影最后一次重建 |
| 21:06:05 / :09 | `视频无引用，已删除记录` ×5 | `ProjectViewModel.swift:270-274` 把 5 个视频的分镜**全部真删** |
| 21:06:49 | ❌ `项目「测试」已关联视频「视频库 (2).mp4」，幂等返回既有行` | `ProjectVideo.associate` 的去重守卫被触发（见 §6，与库状态矛盾，未解释完） |
| 之后直到崩溃 | **`[Readiness] 分镜数据已就绪` 再没出现过** | 分镜库投影**从没重建**，一直握着那 45 个已死对象 |
| 21:09:53 → 21:10:13 | `AI 响应成功` 后 20 s | 落在 `autoReidentifySegments` 的 await 间隙，主线程交出 → 界面重绘 → 688 行 fault 死数组 |

### 1.3 库的只读核查（`~/Library/Application Support/Suncut/Suncut.store`，`mode=ro`，未写入）

```
PV 悬空(指向不存在的 Video): 0
Segment 悬空(指向不存在的 Video): 0
PV 悬空(指向不存在的 Project): 0
ZVIDEO=5  ZPROJECTVIDEO=5  ZSEGMENT=27  ZPROJECT=1
```

⇒ **盘上数据是干净的，这次崩溃只发生在内存里**，重启即恢复到库的真值。不往「库坏了」方向修。

### 1.4 代码层事实（v1.2 全部重新数过，v1 的三个数都是错的）

**① 视图层裸读模型关系：49 处 / 47 键 / 12 个文件**（§12 的守卫实测，也是销账基线）。
这个数被订正过三次，留全在这里免得有人再拿旧数对账：v1 写「24 处 / 10 文件」——只数了 5 个 `@Relationship` 名字，
既漏掉计算便捷入口又把 `group.segments`（VM 结构体字段）算了进去；v1.2 写「55 处 / 14 文件」——纯 token 命中，
没有 receiver 分类；§11 期间的「40 处」——Python 原型对**类型未知的 receiver 一律放过**。
 shipped 规则改成「逐文件 receiver 分类 + 未知者保守计命中 + 大写非模型名豁免」⇒ **49 处**（比 40 多出的正是
`strategy.orderedSchemes` 这类无注解局部量，比 55 少的是 `NavigationItem.schemes` 这种枚举 case）。
多抓不是坏事，**漏抓才是**；三条最危险的同款引信在 49 里都在册：
其中三类是**同一颗雷的另一个引信**，v1 没数到：
- `ImportView.swift:205` —— `return project.associatedVideos` 在 body 计算属性里；
- `SchemeListView.swift:322`、`NarrativeStructureEditorView.swift:482` —— `project.videos.flatMap(\.segments)`，
  这是**在视图里第二次实现「项目→全部分镜」这份投影**，和 `SegmentLibraryView.swift:611` 注释记载的历史 SIGTRAP 同源；
- `DubSettingsBar.swift:49` —— `video.segments.reduce{ …segmentDubs.count }`。

`Project.videos` 为什么危险却最容易漏：它是**计算便捷入口**（`Project.swift:55` → `associatedVideos` `:50` →
`projectVideos` `@Relationship`），名字不在任何 `@Relationship` 声明上。

**② 边遍历 live 关系数组边改/删：5 处**（v1 写 4 处，漏了第 5 颗）：

| 站点 | 形状 |
|---|---|
| `ImportViewModel.swift:379` | `for oldSeg in video.segments { context.delete(oldSeg) }` —— 同文件 `:277` 自己规定必须先 `Array()` |
| `ImportViewModel.swift:1246` | `for dub in seg.segmentDubs { context.delete(dub) }` |
| `ImportViewModel.swift:1247` | `for shot in seg.physicalShots { context.delete(shot) }` |
| `ShotEditViewModel.swift:247` | `for v in s.variants { modelContext.delete(v) }` |
| `DubbingViewModel.swift:313+318-322` | `let dubs = segment.segmentDubs` 后在循环里 `segment.segmentDubs.removeAll{…}` **又** `context.delete(d)` —— 同一份关系数组被两处同时改 |

**③ 真删站点名册：41 条 delete / 11 个文件**（v1 写「~15 个函数」并**漏掉 2 个文件**）：
`ImportViewModel` 10、`DebugSelfTest` 9、`SegmentLibraryViewModel` 4、`ShotEditViewModel` 3、`MCPToolHandlers` 3、
`ProjectViewModel` 3、`MixCutApp` 2、`MCPSegmentToolHandlers` 2、`SchemeViewModel` 3、
**`ViewModels/DubbingViewModel.swift:321`**、**`Views/Schemes/SchemeDetailView.swift:81`**（后者是**视图层直接改库**，分层本身就越界）。

**④ v1 那句「真删后没人负责让持有者失效」是停早了一层——机制其实已经存在**：

- 通道：`Notification.Name.mixCutDataDidUndo`（`ContentView.swift:12`）。
- 观察者：`ContentView.swift:117-119` → `reloadAfterUndo()`（`PendingDeletionCenter.flushNow()` → `fetchProjects()`
  → 取消已死项目的选中 → `segmentLibraryVM.loadSegments` + `schemeVM.loadSchemes`）。
- 谁在发：**MCP 侧 16 处** mutation 后都调 `MCPToolHandlers.notifyUIReload()`（`:634` 就是转发到这个名字）；
  App 的撤销/重做也发（`MixCutApp.swift:228/236`）。
- 谁**不发**：**界面自己的每一条删除链** —— `ProjectViewModel.swift:261-277`（deleteProject 的 commit）、
  `ImportViewModel.swift` 的 deleteVideo / retryASR / retryAIAnalysis、`SegmentLibraryViewModel.swift:560/569`（撤销时只 append 回投影，不广播）。

⇒ 所以真根因的准确表述是：**「删除后让持有者失效」这件事只给 Agent 那条链装了，UI 自己的删除链一次都没接**。
这决定刀 2 的改法（见 §3 刀 2）：不是新造一套广播，而是把这条已有通道补全并让它能带「被删 id」。

---

## 2. 要立的不变量

> **任何一次 `context.delete` 落地，删除方必须走同一条「图已变更」通道，并显式交出被移除的 Segment / Video id；
> 视图与 VM 只从投影取模型对象，不再从模型的 to-many 关系上直接取值。**

一个通道（不是两个）+ 一条必需声明键（被删 id）。为什么强调「一个通道」：§1.4④ 已经有一条通道在跑，
再造第二条的结果是 MCP 与 UI 走两套语义，早晚再次漂移。

**这条不变量有两个可成立的实现，差别在交互代价，是 §7 唯一待拍板项。**

---

## 3. 七刀（每刀只改**已有文件**，见 §4 雷 1；刀 6/刀 7 由第二轮评审新增）

### 刀 1｜视图层停止裸读模型关系（止血 + 恢复本文件纪律）

- 先产出一张**分类表**（这是刀 1 的第一个交付物，不是我拍脑袋）：把 §1.4① 的 55 处按
  「渲染热路径（body / computed var / ForEach）」vs「事件回调（按钮 / .task / commit）」分类。
  分类判据由门 4a 的输出提供（见刀 5），**保证实际改动与清单一致**，不靠我记得。
- 渲染热路径那批必改，起点是 `SegmentLibraryView.swift:688/693`、`DubSettingsBar.swift:49`、
  `ImportView.swift:205`、`SchemeListView.swift:322`、`NarrativeStructureEditorView.swift:482`。
- 改法统一为**吃 VM 投影**：`SegmentLibraryViewModel` 新增未筛选全域投影
  `unfilteredSegmentsByGroupID: [UUID: [Segment]]`，在 `recomputeNumberByVideo()`（`:162`）**已有的那次分组循环**里顺手产出
  —— 不新增一次遍历，分组 key 与 `video_no` 编号天然同源。
- 口径**已定（v1.1 拍板 1-A）**：`group.segments` 是**筛选后**的集合，**不当定义域用**。
  这样 688 行的作用域、`video_no` 编号、上屏那句「作用于这个视频」三者同源，行为相对今天零变化。
  这条是硬要求，不许为省一颗属性换成 `group.segments`。
- `SchemeListView.swift:322` / `NarrativeStructureEditorView.swift:482` 那两处不套白名单：它们是第二份投影实现，
  改成走同一份 `MixCutCore` 分组函数（刀 4）。

代价：`DubSettingsBar` 要多收一个域数组参数（签名变更要跟上它的调用点）；渲染路径那批改动逐个都要真机看一眼。

### 刀 2｜把已有的 `.mixCutDataDidUndo` 通道补全（根因层，**已定 2-B**）

- **不新建广播口**（v1 打算在 `PendingDeletionCenter` 里加一颗新的，评审 P0-1 否掉了）。
  改法：让通道能带载荷 —— `object:` 传一个 `GraphChange`（类型放 `ContentView.swift` 的
  `Notification.Name` 那个扩展旁边，仍是已有文件）。
  无载荷 = 现有「全量重载」语义**一字不改**（保护型开关默认=旧语义）。
- **载荷形状要按实体分组，不能只有 segment/video 两组 id**（第二轮评审 §10 生长性-2）：
  30 处非豁免 delete 里删的东西跨 7 类实体 —— `MixStrategy`/`MixScheme`/`SchemeSegment`
  （`SchemeViewModel.swift:384/408/469`）、`SegmentDub`（`DubbingViewModel.swift:321`）、
  `PhysicalShot`/`ShotVariant`（`ShotEditViewModel.swift:213/247/486`）、`ProjectVideo`
  （`ImportViewModel.swift:816`）。
  规定：**`GraphChange` 按「实体类型 → 被删 id 集合」记账；观察者只剪它认得的实体；
  出现未登记实体 ⇒ 整条回落无载荷全量重载**。这条回落就是「新加一颗 VM / 一种实体时不会静默漏剪」的那半。
- **`post` 只留一处真源**：现在有 `MCPToolHandlers.notifyUIReload()`（`:634`）这一个发布口，
  UI 侧不得再各写各的 `NotificationCenter.default.post(...)` —— 否则两条写入路径迟早语义分叉。
  在 `ContentView.swift` 的 `Notification.Name` 扩展旁边建唯一发布函数，MCP 那颗转发到它。
- **观察者在 `reloadAfterUndo()` 顶端第一行就分叉**（`ContentView.swift:157-172`）：
  带 id ⇒ 只剪枝，**不得**调 `fetchProjects()` / `loadSegments()` / `flushNow()`。
  理由（§10 健壮性-1，这是 P0）：`NotificationCenter.post` 是**同步**的，而
  `loadSegments()` 第一行就是 `flushNow()`（`SegmentLibraryViewModel.swift:123`）→ commit 里 delete → 发通知 →
  观察者又被叫回 `reloadAfterUndo()` → 若无载荷分支继续往下走就会再进 `loadSegments` ⇒ **同栈递归**。
- UI 侧每条删除链改为在 commit 的 `safeSave()` **之后**发一次带 id 的通知：
  `ProjectViewModel.swift:261-277`、`ImportViewModel.swift`（`:279/379/816-828/947/957/1246-1247`）、
  `SegmentLibraryViewModel.swift:560/569`、`SchemeViewModel.swift:384/408/469`、`ShotEditViewModel.swift:213/247/486`、
  `DubbingViewModel.swift:321`、`SchemeDetailView.swift:81`（这处顺手挪进 VM）。
  **ids 必须在 delete 之前取**：从关系数组里拿到的对象，delete 之后再读 `.id` 本身就是一次 tombstone 读取。
- **MCP 那 16 处保持无载荷**（不改行为）：`MCPSegmentToolHandlers.swift:410-414` 的删除仍走
  `notifyUIReload()` 全量重载。理由写在门 4b 名册里 —— Agent 一次删的是跨项目跨视频的范围，
  给它上剪枝要重画 8 处投影的口径，收益不抵风险；MCP 链的旧语义是它的回归基线（§5.6）。
- 剪枝顺序是真约束：**先剪 `segments`，再 `applyFilter()`**（`recomputeGroupedSegments()` 里
  `guard let video = seg.video` 会对残留死对象做一次 to-one 读取，`SegmentLibraryViewModel.swift:166`）。

### 刀 3｜把「先快照再删」从人的记忆变成 API

- SDK 实证（`SwiftData.swiftmodule/arm64e-apple-macos.swiftinterface:401-402`）：`ModelContext` 只有
  `delete<T>(_ model: T)`、`delete<T>(model:where:predicate:)`、`delete(DataStoreBatchDeleteRequest)`，
  **没有 Sequence 重载** ⇒ 在 `MixCut/Utilities/ModelContextExtension.swift`（已有文件）加
  `func delete<S: Sequence>(_ objects: S) where S.Element: PersistentModel` 不会与现有重载歧义
  （`[Segment]` 不满足 `T: PersistentModel`）。实现第一件事就是 `Array(objects)`。
- **明确不采用官方的 `delete(model:where:)`**：那是存储层批量删，不会动内存里已 materialize 的对象，
  用在本次这条链上会**制造更多 tombstone**（评审 P1-1 要求写明这条取舍）。
- 5 处站点改成走这颗 API：`ImportViewModel.swift:379/1246/1247`、`ShotEditViewModel.swift:247`、
  `DubbingViewModel.swift:313-322`（这颗还多一层「循环里 removeAll 关系数组」，改法是**先删后一次投影回写**）。

### 刀 4｜纯逻辑下沉，让「一份投影」可测

- 把「项目→按视频分组的全部分镜 / 筛选后可见分镜」的分组规则收进
  `Sources/MixCutCore/DubRewriteScopeResolver.swift`（已有文件；`:688` 那句本来就调它）。
- App 层只负责递两个数组：未筛选全域、筛选后可见域。
  `SchemeListView` / `NarrativeStructureEditorView` 那种 `flatMap(\.segments)` 的第二实现全部删除，改调这颗。

### 刀 5｜守卫（**主体落在 `Tests/MixCutCoreTests` 的源码扫描守卫**，shell 只作发布前收口 —— v1.4 依 §11 修正落点）

> 为什么改落点：本仓**已经有这一层**，而且比 shell 更严 —— `BoundaryAdjustUsageGuardTests.swift` 带 `codeOnly()`
> 逐字符剥注释与字符串再扫（避免注释里的示例造成假红），`SegmentRenderFreshnessTests.swift` 更已经把
> 「真仓敏感性下限 / 改名不绕过 / 两种绕法判红一种合法不误伤」写成用例。
> 把门 4a/4b 做成同样的 Swift 守卫 ⇒ 每次 `swift test` 都跑、非恒绿有自证；shell 那份留作发版前的一次性收口。

- **门 4a｜视图层禁止裸读模型关系**，禁词表必须**两条来源**（评审 P0-2：只从 `@Relationship` 派生会让门对
  `project.videos` 这类计算入口**恒绿**）：
  1. `MixCut/Models/*.swift` 里 `@Relationship … var X:` 声明的关系属性名；
  2. 同目录里**返回类型元素为 `@Model` 类**（实测 **11** 颗 `@Model` 类；先前记的 12 来自 `grep "@Model"`，它把
     `SchemaVersions.swift:62` 注释里那句也算成了一次命中）的属性名 ——
     覆盖 `videos` / `associatedVideos` / `projects` / `orderedSegments` / `orderedSchemes` /
     `effectiveDubVariants` / `combinationDubVariants`。
  扫描面：`MixCut/Views/**/*.swift`；命中即 FAIL 打 file:line；允许清单每条必须带「为什么允许」，缺理由判
  `FAIL[判据失效]`；两条来源各自取到 0 个名字也判 `FAIL[判据失效]`。
- **门 4a 的效力上限要写死在脚本注释里**：它是 token 级判据。to-one 读取（`seg.video`）不拦——
  全仓到处都在读，拦了会把门变成噪音；它只保证「**遍历/取值 on 集合属性**」这件事不再出现在视图层。
- **门 4b｜delete 站点名册**：按 §1.4③ 的 **41 条 / 11 文件**建册，按文件计数对账；
  新增站点必须先显式认领（改名册 = 强制一次 review）。`DebugSelfTest`（9 条，DEBUG 门内、用独立 context、跑在界面之前）
  与 `MixCutApp` 启动 fixups（2 条，`:353/:397/:426` 各自 `ModelContext(container)`）登记为**豁免并注明理由**，
  豁免项也要计数，避免「豁免」慢慢变成没人认领的欠账。
- 落地顺序硬约束：门 4a 与刀 1 同批（现在树上有 55 处，先加门当场红）。

### 刀 6｜渲染入口统一过「已被摘除」这道门（§10 评审新增，**与 2-A/2-B 无关，两条路都需要**）

本仓**已经发现并解决过**这次这个时序，只是没有收成一处真源。`ImportView.swift:413-420` 的注释原话：

> 删除视频时，`@Observable` 的 Video 被 `context.delete` 后仍会向「正在被移除的本卡片」发出变更通知，
> 触发 body 重算；此时读 `video.status` 等持久属性会命中 SwiftData 已删除对象断言（EXC_BREAKPOINT）。
> 故先判断对象是否已从上下文摘除，已删则不渲染。

⇒ 这类崩溃**不是投影剪枝能拦的**：通知先到、剪枝后到，而那个「正在被删的视图自己」必然还会重算一次。
现在这道门散在 4 处、各自 ad hoc：`ImportView.swift:418`、`ShotEditViewModel.swift:427/438`、
`SegmentPropertiesSection.swift:456/498`（后两处是撤销闭包里 `where item.seg.modelContext != nil`）。
**分镜库的卡片与分组标题行一处都没有** —— 而 688 行正是崩在那儿。

- 在**已有文件**里给 `PersistentModel` 加一颗 `var isDroppedFromContext: Bool { modelContext == nil }`
  （放 `MixCut/Utilities/ModelContextExtension.swift`，与刀 3 同文件），4 处既有写法统一改调它。
- `SegmentLibraryView.sectionHeader(_:)`（`:617`）与分镜卡片渲染入口先过这道门，已摘除即渲染空。
- 门 4a 追加一条腿：**视图里凡出现 `group.video` / `segment` / `video` 这类模型对象进入 body，
  该文件必须至少有一处 `isDroppedFromContext`**（这条是文件级判据，配「删掉那道门必须变红」的反向对照）。

### 刀 7｜日志形状判据（本案就是靠日志 absence 定位的）

剪枝分支与 commit 各打一行（`[GraphPrune] removed segs=… videos=… 剩余=…`）。
理由：这次崩溃唯一的现场证据就是「`[Readiness] 分镜数据已就绪` 那行 4 分钟没再出现」。
没有对应形状日志，修完之后同样的问题**依旧只能靠肉眼和运气查**。

---

## 4. 项目硬约束（计划里已经避开的雷）

1. **不新增 .swift**：`MixCut/`、`Sources/MixCutCore/` 都不许新增（pbxproj 手工维护；`generate_xcodeproj.py` 一跑抹掉 38 条编译引用）。
   刀 2/3/4/5 全部落在**已有文件**；只有 `Tests/MixCutCoreTests/` 与 `scripts/` 自由。
2. **不改任何 `@Model`/`@Transient` 属性的类型**（schema 指纹门会拒绝打开用户的库）。本计划只加只读派生属性与方法。
3. `swift test` 目标只有 `MixCutCore`（`Package.swift` 注释写明 App 不进 package）⇒
   **SwiftData 真删链无法在单测里覆盖**，这条只能靠守卫 + 真机复现，我不假装能测到。
4. 刀 2 的剪枝分支不复用 `loadSegments` ⇒ 不把切页骨架闪烁那条已修完的线重新引回来。

---

## 5. 验收（谁做什么）

**我做完代码后交给你跑；我不自跑测试，git 写操作也只由你跑。**

1. `swift test` —— 跑前预登记四个数：`passed / skipped / xfailed / 总数`；我只报「新增 N 条用例」，你对总数变化。
2. `SKIP_XCODEBUILD=1 scripts/check_project_integrity.sh` —— **基线已实测 rc=0、三道门全绿**（源码树 169 个 .swift、
   唯一文件名 169、pbxproj BuildFile/SourcesPhase/FileRef 三者各 169、.sh 18 个）。
   **v1.4 落点修正**：门 4a/4b 的**主体在 `Tests/MixCutCoreTests` 的源码扫描守卫**（随每次 `swift test` 跑、
   非恒绿有自证，见 §11.1），shell 那份只作发版前的一次性收口 ⇒ 两边命中数必须**互相对账**（不一致即判失效）。
3. 守卫自证四条腿，每腿都要有「只能红在该腿」的变异（落成为用例 G08/G09/G10/G11/G12）：
   - 改前快照：门 4a 在现在这棵树上必须**变红**（55 处命中）；
   - 正向对照：往 `MixCut/Views/` 注入一处 `video.schemeSegments.map` ⇒ 只准红在 4a；
   - 第二来源对照：把禁词表第 2 条来源临时关掉 ⇒ `project.videos` 那批命中必须消失 ⇒ 证明这条来源承重；
   - 名册对照：从 4b 删一行 ⇒ 只准红在 4b。
   外加一条本仓既有范式：**扫描器必须先剥注释/字符串**（`codeOnly()`），否则我自己写在注释里的反例会把门变成假红。
4. `xcodebuild` Debug 编过（Debug/Release 要标清，行为数与性能数不许混着报）。
5. **真机复现（这次崩溃唯一的正证）**：
   1) 打开分镜库，确认某项目有分镜；2) 删除该项目（撤销条出现后不点撤销，等它了结）；
   3) 立刻在另一项目导入同名素材并跑分析；4) 回分镜库滚动 20 s。
   预期：修前 SIGTRAP / 修后不崩，且分镜条数与库一致（`sqlite3 file:…?mode=ro` 现场对账）。
   判据认三种读数：**崩了 / 没崩 + 分镜条数 + `[GraphPrune]` 那行在不在**（刀 7）。
6. **重入反证（§10 健壮性-1，P0 必测）**：在 `loadSegments()` 的 `flushNow()` 正在了结一枚删除事务时，
   观察者必须只剪枝、不再进 `reloadAfterUndo` 的无载荷分支。判据按形状定：**一次删除只能出现一行 `[GraphPrune]`、
   且同一操作内不得再出现 `[Readiness] 分镜数据已就绪`**（两行同现即说明走了递归那条路）。
7. 刀 2「MCP 无载荷通知仍走旧全量重载」的行为等价性，单独立一条 MCP 侧验证：发一次 `delete_segments`
   ⇒ 侧栏/概览照旧刷新、**且日志形状与今天一致**（这条是 MCP 链的回归基线，不许因为上了剪枝就顺手改它）。
8. 刀 6 的渲染门要有反向对照：临时删掉 `sectionHeader` 那道的 `isDroppedFromContext` 判定 ⇒ 门 4a 追加的那条腿必须变红。
9. `Tests/MixCutCoreTests/DubRewriteScopeResolverTests.swift`（现有 7 处直接调 `resolve(domainIDs:…)`）
   ⇒ 刀 4 规定**不改 `resolve` 现有签名**，只新增重载/新函数；若不得不改，7 处用例同批重指，不留兼容壳。
10. **用例名册对账**（§11.4 的编号就是名册）：交付时逐条报 `G01…G16 / IT-G01…G04 / E2E-G01…G03` 的状态
    ——`已生成 / 待生成 / 构造不出来`。基线读数要预登记四个数：`passed / skipped / xfailed / 总数`
    （基线 **70 个文件 = 533 条 Swift Testing `@Test` + 10 条 XCTest `func testXxx` = 543 条**，见 §11.1
    ⇒ 新增条数以 runner 报的为准，不按文件名数）。
    IT/E2E 那 10 条**永远不该出现在 `swift test` 的通过数里**，出现即说明有人拿桩冒充了真删链。

---

## 6. 现在还不能确定的（如实留着，不写进上屏话）

- §1.2 那条 ❌ 去重日志与 §1.3 库干净之间的**矛盾我没解释完**：`ProjectVideo.associate` 当时凭什么认为「已关联既有行」，
  而那个视频 40 秒前刚被删。库里没留悬空行 ⇒ 没造成持久损害，但可能是**内存关系数组滞后**（与 §1.4④ 同族）。
  刀 2 落地后重跑这条链看它还出现不出现；若出现，另立计划。
- 崩溃那一瞬到底是哪一次 delete 把死人留在 `video.segments` 里，**没钉死**：候选是 `ImportViewModel.swift:379`
  （未快照遍历）或撤销条 commit 那批。两支都落在刀 2/3 覆盖面里，不影响改法，只影响复现该走哪条 —— 交给 §5.5。
- `DubbingViewModel.swift:313` 的 `dubs` 是否真的与 `segment.segmentDubs` 共享同一底层缓冲（即是否真会互相踩），
  我只读了形状没做变异验证；刀 3 改完必须让它**构造不出来**，而不是证明它现在会不会崩。
- 55 处的「渲染热路径 / 事件回调」分类我**还没做**（刀 1 的第一个交付物就是这张表，由门 4a 的输出产生）。

---

## 7. 拍板状态

**拍板项 1｜配音批量作用域的定义域口径 —— 已定：1-A（2026-10-03，v1.1）**

| 选项 | 定义域是什么 | 得到 | 失去 | 结果 |
|---|---|---|---|---|
| **1-A** | 未筛选的本视频全部分镜（与 `video_no` 编号同源） | 与上屏话「作用于这个视频」一致，行为不变 | 多一颗 VM 派生属性 + 纯逻辑下沉，约 40 分钟 | **✅ 采纳** |
| 1-B | 复用筛选后的 `group.segments` | 最小改动，约 10 分钟 | 筛选开着时批量范围缩窄，文案仍说「本视频 N 个分镜」⇒ 上屏话说假话 | ❌ 否决 |

**拍板项 2｜删除后的失效走哪条实现 —— 已定：2-B（2026-10-03，v1.3）**

| | 做法 | 得到 | 失去 | 工作量（估于 v1.2） | 结果 |
|---|---|---|---|---|---|
| 2-A 保守 | UI 删除链补发**无载荷**通知，复用 `reloadAfterUndo` | 零新语义、改动最小，当场止崩 | 每次删除都 `flushNow`+全量重载 ⇒ 多选态与 pinned Inspector 被清、撤销浮条被自己了结；切页骨架闪烁有回顶风险 | 1.5 h + 回归 2 条链 | ❌ 否决 |
| **2-B** | 同一条通道加**可选载荷**（被删 id）：带 id⇒剪枝保交互；无载荷⇒旧全量重载一字不动 | MCP 16 处行为零变化；UI 删除不丢选中；不变量只有「一条通道 + 一个必需声明键」 | 非豁免 30 处站点要在删前算出 id；观察者顶端要防重入；载荷要按实体分组并留回落 | 3 h + 回归 3 条链 | **✅ 采纳** |

采纳理由按代价说话：2-A 省 1.5 小时，但把「删除后选中态与撤销条」这两条**用户每天走的路径**变成副作用；
2-B 多出的两项成本（id 声明、防重入）分别有门 4b 和一条代码位置约定兜住，2-A 那两项没人兜。

**v1.3 修正 2-B 的成本**：第二轮评审查出 `modelContext == nil` 这道渲染门是**两条路都缺**的独立 P0（§10 健壮性-2），
新增刀 6 + 刀 7 ⇒ 2-B 落地量从 3 h 上浮到**约 4 h**，回归链仍是 3 条（分镜库 / 方案页 / 素材页）+ 新增 1 条 MCP 旧语义基线。
决定不变，只是别拿 3 h 去排期。

---

## 8. 明确不做

- 不碰 SwiftData 内置 `UndoManager`（`MixCutApp.swift:122-125` 已写明一挂删除就崩）。
- 不改 schema、不加模型属性、不动 `videoNoByVideoID` 的规则真源。
- 不在这轮碰「删记录不删文件」那条孤儿文件线（另案，且那是产品口径问题不是崩溃原因）。
- 不为了少改几行而放宽任何现有断言，也不把守卫写成恒绿。
- 不再新建第二条「数据已变更」广播通道（评审 P0-1 的结论：已有 `.mixCutDataDidUndo`，补它）。

---

## 9. 评审结论（architecture-visualization / `risk-quality-reviewer`，2026-10-03）

评审目标：v1.1 计划的证据是否成立、改法是否留下新的静默失效面。
证据来源：源码 grep 复核 + SDK 接口文件 + 活库只读 SQL + 日志 + 守卫脚本实跑（`rc=0`）。

| 编号 | 级别 | 结论 | 证据 | 处置 |
|---|---|---|---|---|
| P0-1 | **推翻计划** | 刀 2 会造出第二条广播机制，而 `.mixCutDataDidUndo` 已存在且被 MCP 用了 16 次；真根因是 UI 删除链一次没发 | `ContentView.swift:12/117-119`、`MCPToolHandlers.swift:634`、`MixCutApp.swift:228/236` | 已改：§1.4④、§3 刀 2 |
| P0-2 | **判据恒绿** | 禁词表只从 `@Relationship` 派生 ⇒ 最常被视图读的 `project.videos` 等计算入口全部门外 | `Project.swift:50/55`、`Video.swift:136`、`MixScheme.swift:69`、`SegmentDub.swift:68/84` | 已改：刀 5 门 4a 双来源 + §5.3 第三腿 |
| P0-3 | **证据数字错** | 裸读面 24→**55 处/14 文件**；delete 站点 ~15→**41 处/11 文件**；未快照遍历 4→**5 处** | §1.4①②③ 的逐条 file:line | 已改正并写进刀 1/3/5 的覆盖面 |
| P1-1 | 计划外收益 | 官方 `delete(model:where:)` 存在但不适用（存储层批量删不动内存对象 ⇒ tombstone 更多） | SDK `arm64e-apple-macos.swiftinterface:401-402` | 已写进刀 3 的取舍 |
| P1-2 | 论证被削半 | 「重建会把宽限期隐藏项捞回屏幕」对已有通道不成立 —— 它先 `flushNow` 再重建；真实差别是交互代价 | `ContentView.reloadAfterUndo()`、`SegmentLibraryViewModel.swift:122-123` | 已重写 §2 与 §7 拍板项 2 |
| P1-3 | 缺一条约定 | `loadSegments` 第一行 `flushNow()` ⇒ 剪枝分支有重入窗口，v1.1 没写 | `SegmentLibraryViewModel.swift:123` | 已加刀 2 防重入条 |
| P1-4 | 替身/豁免会漂移 | 必需声明键扩散到 41 条站点后，DEBUG 与启动 fixups 若靠「记得」豁免就会烂掉 | `DebugSelfTest.swift` 9 条、`MixCutApp.swift:353/397/426/362/473` | 已写进门 4b 的带理由豁免计数 |
| P2 | 分层越界 | `Views/Schemes/SchemeDetailView.swift:81` 在视图里真删库对象 | 该行 | 刀 2 顺手挪进 VM |
| 通过 | — | §1.1/§1.2/§1.3 与 1-A 口径决定，复核为真 | 崩溃栈、日志、库读数 | 保留 |

**评审的总判断**：v1.1 的方向（视图不吃原始关系 + 真删必须有失效责任人）成立，但它把根因停在
「没有机制」这一层，而实际机制存在且只装在了 Agent 那条链上 —— 若照 v1.1 动手，会留下两条语义不同的刷新通道，
比这次崩溃更难排查。v1.2 已按此改正。**纸面再循环的边际收益已经低于一次真实 diff**：
拍板项 2 已定 2-B（§7），第一轮评审的建议据此更新为 ——
**第一批只落刀 1 + 刀 6 + 刀 3**（三者必须同批：刀 1 拔裸读、刀 6 补渲染门、刀 3 断「忘快照」这一类；
约 90 行、可独立验收），拿那一片的 diff 评第二轮，而不是继续在计划上打转。
刀 2（载荷 + 回落 + 防重入，覆盖面最大）作为第二批，独立验收。
下一轮评审的对象应当是那一片 **diff**，不再是这份计划（§10 已是第二轮纸面评审）。

---

## 10. 第二轮评审报告（`tech-solution-review` · A 类方案评审 · 2026-10-03）

> 评审对象：本文件 v1.2 + 新决定 **2-B**（复用 `.mixCutDataDidUndo` + 可选「被删 id」载荷）
> 范围：`MixCut/Views/**`、`MixCut/ViewModels/**`、`MixCut/App/ContentView.swift`、`MixCut/Services/MCP/**`、
> `Sources/MixCutCore/DubRewriteScopeResolver.swift`、`scripts/check_project_integrity.sh`
> 方式：只读探索（grep + SDK 接口 + 活库只读 SQL + 守卫实跑 rc=0），未改任何代码

### 0. 概览

- **评审结论**：**有条件落地**
- **阻断项（P0）数量**：**3**（其中 1 条是本轮新发现、且与 2-A/2-B 的选择无关）
- **一句话总结**：2-B 选的通道是对的（一条通道 + 可选载荷 + 旧语义回落，扩展成本可控），但 v1.2 把「投影剪枝」
  当成了这道崩溃的全部解药 —— 而本仓 4 分钟前的代码里就写着**剪枝拦不住的那一半**（`ImportView.swift:413-420`）。

### 1. 可扩展空间

| # | 可扩展点 | 当前方案是否支持 | 推荐扩展机制 | 演进路径 |
|---|---|---|---|---|
| 1 | 新增一种实体的删除要能通知界面 | **部分**（v1.2 的载荷只有 segment/video 两组 id） | `GraphChange` 按「实体类型→id 集合」记账 + **未登记实体回落无载荷**（已并入刀 2） | 回落规则就是扩展不撕裂的保险 |
| 2 | 新增一颗持有投影的 VM | **部分**（观察者按实体分支会堆在 `ContentView.swift:157-172`） | 由 VM 自注册「我可剪哪些实体」；注册入口收在已有咽喉 `setModelContext`（`ContentView.swift:101-104`、`MCPToolHandlers.swift:29-32`） | 中心不再随 VM 数量改 |
| 3 | 「项目→分镜」这份投影只有一处实现 | **是**（刀 4 拔掉 `SchemeListView.swift:322`、`NarrativeStructureEditorView.swift:482` 两份 `flatMap(\.segments)`） | 下沉 `MixCutCore`，App 只喂值 | `video_no` 编号、配音定义域、方案页选择器共用一份 |
| 4 | 「对象已从上下文摘除」的判据只有一处真源 | **否**（v1.2 完全没提；现已成刀 6） | `PersistentModel.isDroppedFromContext` 放 `ModelContextExtension.swift`，4 处 ad hoc 全改调它 | 第 5、6 处需要这道门的视图零成本复用 |
| 5 | 删除走同一条真删通道 | **否**（41 条 delete 里只有 11 条走 `PendingDeletionCenter`） | 本轮不强制收敛，门 4b 先把名册立住 | 后续把 8 处不走 center 的真删挪进来 ⇒ 「广播漏发」在结构上构造不出来 |

**说明**：2-B 的生长性是正的 —— 一条通道 + 可选载荷 + 旧语义回落，等于给「以后还要通知别的东西」留了插口而不动既有语义。
真正的生长性欠账是 #4/#5：同一个原始知识（对象死了）现在散在 4 处各写各的，再长就长成分叉。

### 2. 健壮性风险清单

| # | 严重度 | 位置 | 风险 | 触发场景 |
|---|---|---|---|---|
| 健壮-1 | **高 P0** | `ContentView.swift:117-119`→`:157-172`、`SegmentLibraryViewModel.swift:123` | `NotificationCenter.post` 同步；`loadSegments()` 首行 `flushNow()` → commit 里 delete → 发通知 → 观察者被叫回同一栈；若无载荷分支继续往下 ⇒ `loadSegments` 递归 | 撤销条到点/被顶掉/退出前 flush，任何一次了结都可能撞上正在重建 |
| 健壮-2 | **高 P0** | 缺在 `SegmentLibraryView.swift:617/688`；先例见 `ImportView.swift:413-420` | **被删对象自己发出的最后一次变更通知会让「正在被移除的那个视图」重算 body** —— 投影剪枝对此无效（通知先于剪枝到达，且那个视图持有的就是死对象） | 与本案完全同一形状；崩在 688 行，而 688 行所在的那个 header 正是被删视频自己的标题行 |
| 健壮-3 | **高 P0** | `SchemeViewModel.swift:384/408/469`、`ShotEditViewModel.swift:213/247/486`、`DubbingViewModel.swift:321` | v1.2 的载荷表达不了 `MixScheme`/`MixStrategy`/`SchemeSegment`/`SegmentDub`/`PhysicalShot`/`ShotVariant` ⇒ 这些页删完**照旧留死人且无人认领**（静默未命中） | 方案页删方案、分镜头编辑删变体、配音池删变体 |
| 健壮-4 | 中 P1 | 刀 2 与刀 3 的耦合点（`ImportViewModel.swift:379` 等） | ids 必须在 delete **之前**取；从关系数组拿到的对象删后再读 `.id` 本身就是一次 tombstone 读取 | 每条链的第一个 id 计算 |
| 健壮-5 | 中 P1 | `SegmentLibraryViewModel.swift:166` | `recomputeGroupedSegments` 里 `guard let video = seg.video` 会对残留死对象做 to-one 读取 ⇒ 剪枝必须**先剪后算** | 剪枝与派生重算的先后被写反 |
| 健壮-6 | 中 P1 | `PendingDeletionCenter.swift:68-79`、`:115-118` | `arm()` 顶掉上一枚时 `settle()` **即刻真删**；若同一对象既在刚了结事务的 commit 里被剪、又被另一枚存活事务的 undo 闭包 append 回来 ⇒ 死对象被放回投影 | 连续两次删除（第二次顶掉第一次），本案日志里 21:06:05/:09 就是这个形状 |
| 健壮-7 | 低 P2 | 剪枝/commit 路径无日志 | 本案唯一现场证据是「`[Readiness]` 那行 4 分钟没出现」；没有形状日志，修完同样只能靠肉眼 | 刀 7 已补 |
| 健壮-8 | 低 P2 | `Views/Schemes/SchemeDetailView.swift:81` | 视图层直接 `modelContext.delete` —— 不受任何投影管理，挪进 VM 前它永远不在广播名单里 | 方案详情页清理无音频变体 |

**说明**：v1.2 的健壮性设计在「数据一致性」一条上是够的（先剪后算 + 防重入已补进刀 2），
缺的是**渲染时序**与**覆盖面**两条：前者是剪枝原理上拦不住的那一半（健壮-2），后者是载荷形状漏掉的 6 类实体（健壮-3）。

### 3. 跨模块回归影响

| # | 受影响模块 | 影响类型 | 概率 | 严重度 | 说明 |
|---|---|---|---|---|---|
| 1 | **MCP 数据面**（`MCPToolHandlers.swift:634` + 16 处 `notifyUIReload`） | 行为契约 | 低 | **高** | 若顺手把 Agent 删除也改成带 id 剪枝 ⇒ Agent 删完侧栏/概览不再全量刷新。已规避：MCP 保持无载荷（刀 2） |
| 2 | **撤销浮条** `PendingDeletionCenter` | 行为契约 + 时序 | 中 | **高** | commit 新增广播，与 `undo` 的 append 竞争（健壮-6）；浮条可见性判据在 `:147-158`，不能碰 |
| 3 | **切页骨架闪烁线**（`ContentView.swift:168-171`） | 行为契约 | 中 | 中 | 误走无载荷分支就会 `loadSegments` ⇒ 清 `readiness`、顶回那条已修完的线。§5.6 用日志形状兜 |
| 4 | **混剪方案页**（`SchemeListView.swift:322`、`NarrativeStructureEditorView.swift:482`、`SchemeDetailView.swift` 11 处裸读） | 行为契约（**顺序口径**） | 中 | **高** | 那两处 `project.videos.flatMap(\.segments)` 的顺序与 VM 分组顺序**不同**（VM：自建组置顶 + `videoOrder`，见 `:356-365`）⇒ 换投影必须逐条比对顺序，只看条数会假绿 |
| 5 | **配音线**（`DubbingViewModel.swift:321`、`DubSettingsBar.swift:49`） | 数据 + 行为 | 中 | 中 | 本机零配音 ⇒ **这两条我验不了，如实标未验**，落地后要你在有配音产物的那台/那一项目上补看 |
| 6 | **素材导入页**（`ImportView.swift:205/53/863` + `:418` 渲染门） | 接口契约（`DubSettingsBar` 新增参数） | 中 | 中 | 卡片自身已有门，改裸读时别把门拆了 |
| 7 | **导出线**（`ExportView.swift` 9 处裸读） | — | 低 | 低 | 本轮不动 ⇒ 进门 4a 允许清单 + 写理由，登记为已知欠账，不写成「已解决」 |
| 8 | **滚动掉帧线**（`SegmentLibraryViewModel.swift:162-183`） | 性能 | 低 | 低 | 剪枝触发一次派生重算；实测 `[Perf] SegmentLibrary: 1ms / segs=45` ⇒ 规模上无害 |
| 9 | **构建与工程**（169 个 .swift / pbxproj 三向守恒，守卫 rc=0） | 配置环境 | **高** | **高** | 门 4a 与刀 1 **必须同批**：现在树上有 55 处裸读，先加门当场红。不新增 .swift 这条已核 |
| 10 | **测试面**（`Tests/MixCutCoreTests/DubRewriteScopeResolverTests.swift` 7 处直调 `resolve(domainIDs:…)`） | 接口契约 | 低 | 中 | 刀 4 规定不改现有签名 ⇒ 零影响；若改，7 处同批重指，不留兼容壳（§5.9） |

**说明**：影响面最大的是 #4 与 #2 —— 都是「绿着但说假话」那一类（顺序口径、竞争 append），
而不是编译期会拦住的类型。这两条必须有运行期对账，不能只靠守卫脚本。

### 4. 优化 / 规避建议

| # | 优先级 | 问题 | 建议（最小改动路径） | 成本 | 需否补测 |
|---|---|---|---|---|---|
| 1 | P0 | 健壮-2 剪枝拦不住被删视图自己的最后一次重算 | **刀 6**：`isDroppedFromContext` 一处真源 + `sectionHeader`/卡片过门；4 处 ad hoc 全改调它 | 低（约 30 行） | 要：§5.8 反向对照 |
| 2 | P0 | 健壮-1 同步 post 的重入 | **刀 2** 观察者顶端第一行分叉；剪枝分支禁调 `loadSegments`/`fetchProjects`/`flushNow` | 低 | 要：§5.6 形状判据（一次删除只一行 `[GraphPrune]`） |
| 3 | P0 | 健壮-3 载荷漏 6 类实体 | 载荷按实体类型分组 + **未登记实体回落无载荷**；门 4b 名册按「实体类型 × 站点」两维登记 | 中 | 要：方案页 / 分镜头 / 配音各一条删除验证 |
| 4 | P1 | #4 顺序口径漂移 | 刀 4 落地时，把 `SchemeListView`/`NarrativeStructureEditorView` 的旧顺序与新投影顺序**逐条比对后**再删旧实现；比对结果贴进验收 | 中 | 要（可写成 MixCutCore 纯函数单测） |
| 5 | P1 | 健壮-6 顶掉上一枚时的 commit/undo 竞争 | 立一条不变量：**已了结事务剪掉的 id，不得被任何存活 undo 闭包 append 回来**；`settle()` 路径纳入 §5.5 复现（连删两次） | 中 | 要 |
| 6 | P1 | 健壮-4/5 ids 删前取 + 先剪后算 | 在刀 2/3 的代码里用注释写死顺序 + 一个「先算后删」的局部惯用法（`let ids = …map(\.id)` 紧跟 `delete(…)`） | 低 | 可省（靠读代码 + 门 4b 理由列） |
| 7 | P2 | 健壮-7 无观测 | **刀 7** 两行日志（`[GraphPrune]` / commit 侧一行） | 低 | 不需要 |
| 8 | P2 | 健壮-8 视图层直接改库 | `SchemeDetailView.swift:81` 那段挪进 `SchemeViewModel` | 低 | 顺带 |

### 5. 总体结论与前置条件

- **是否可落地**：**有条件落地**。方向成立，v1.3 的七刀覆盖了全部 P0。
- **前置条件（缺一不可，缺了就等于这次崩溃换个入口再来一遍）**：
  1. 刀 1 + 刀 6 **同批**（渲染门与裸读面是一对，只做一半会留洞）；
  2. 刀 2 的载荷必须**按实体分组并带回落**，MCP 那 16 处保持无载荷；
  3. 观察者分叉写在 `reloadAfterUndo()` **顶端**，剪枝分支不得调全量重建；
  4. 守卫四条腿 + §5.6/§5.7/§5.8 三条形状/反向判据全过，再谈「修好了」。
- **必须阻断的问题（P0）**：健壮-1（重入递归）、健壮-2（被删视图自身重算无门）、健壮-3（载荷漏 6 类实体）。
- **可后续处理（P1/P2）**：#4 顺序对账、#5 顶掉竞争、健壮-4/5/7/8、#7 导出线 9 处裸读欠账（登记不销账）。
- **补充建议**：`swift test` 只能覆盖刀 4 下沉后的纯函数（分组顺序、定义域口径、回落规则）；
  **SwiftData 真删链在 test target 之外**，所以最终证据只有 §5.5 真机复现 + `[GraphPrune]` 日志形状，
  报告里不给「单测已覆盖」的错觉。

---

## 11. 覆盖差距矩阵与用例清单（`test-coverage-expander` 第三轮 · 2026-10-03）

> 阶段 D 的**方案**部分。**v1.5 已交付 G08–G12 这一批**（8 条，见 §12）；其余用例仍是**待生成**，
> 且生成都沿用 §11.1 探测到的既有约定（编号前缀 + 中文断言句 + 每条主案配 `b` 后缀对照）。
> 全程未改生产源码；只自跑了 `--filter TombstoneReadGuardTests` 这一批做守卫自证，全量套件仍留给你。

### 11.1 种子与本仓测试约定（框架探测）

- 框架：**两种风格并存**。主流是 Swift Testing（`import Testing` + `@Test("ID 中文说明")`，**533 条**）；
  另有 **10 条 XCTest 风格 `func testXxx()`**，集中在 `HoverTipStateTests.swift` 与 `SegmentSelectionStateTests.swift` 两个文件
  ⇒ 基线合计 **543 条 / 70 个文件**（两种计数都是 grep 实测，`@Test` 属性行计数与任意出现计数相同 ⇒ 无注释污染）。新文件一律跟 Swift Testing。
- 命名与形状约定（从种子归纳，不另起）：编号前缀 + 中文断言句（`UG-05`、`LL-02`、`TC-09`、`G2`）；
  **每条主案配一条 `b` 后缀的正向/反向对照**（`UG-04b 反向对照…防 UG-04 测成恒真`、`LL-01b 正向对照…否则 R1 会变成永远拦`）。
- 已存在的**源码扫描守卫层**（本项目专属维度，5 颗 `*Guard*` 测试）：
  `BoundaryAdjustUsageGuardTests.codeOnly()` 逐字符剥注释/字符串再扫（注释里的示例不许造成假红）；
  `SegmentRenderFreshnessTests` 已把三条判据写成用例 —— **真仓敏感性下限**（「在真实代码上确实扫到了」）、
  **改名不绕过**（「字段与盒都换掉名字，检出数不变」）、**正反两半边**（「两种绕法判红、一种合法写法不误伤」）。
- 硬边界（都已取证，不是推测）：`Tests/` 里 `import SwiftData` / `ModelContainer` / `ModelContext` **命中 0 处**；
  `MixCut.xcodeproj` 只有 `com.apple.product-type.application` 一种 target（**无 test target**）
  ⇒ **SwiftData 真删链与 SwiftUI body 渲染在自动化层测不到**，可测面=下沉进 `MixCutCore` 的深度。

### 11.2 模式库映射（契约 → 已覆盖种子 → 缺口）

| 维度 | 守护的契约 | 已覆盖（种子） | 缺口 |
|---|---|---|---|
| IN-01 空/单元素 | 空集合不炸、单元素不误删 | `ProjectVideoDedupTests` TC-01/02/08 | 新 domain API 的「全域空 × 筛选非空」组合 |
| IN-02 三点边界 | 阈值判定不靠运气 | `UndoGraceMachineTests` UG-05、`LaunchStepLedgerTests` LL-05 | 沿用即可，无新边界 |
| INV-01 守恒 | 计数/编号对得上账 | TC-10 编号连续无跳号、`SegmentRenderFreshness` G2 缓存键化 | **剪枝守恒：交出 N 个 id ⇒ 恰好少 N 个** |
| INV-02 幂等 | 重复执行只生效一次 | TC-09 已净数据再跑删 0 条、LL-03 once 幂等 | **同一批 id 连投两次通知** |
| ST-01 状态迁移 | 合法/非法跳转穷尽 | UG-01…UG-12（arm/expire/flush/顶掉/迟到定时器）| 机器层已密；缺 **commit→广播→剪枝→undo 跨对象链** |
| EX-04 竞态/时序 | 同步回调不重入 | UG-03 竞态主案、`ProjectVideo.associate` 必须同步的注释 | **`flushNow` 内发通知导致的同栈重入**（§10 健壮-1） |
| CT-01 契约一致 | 载荷语义不静默降级 | `ThumbnailCacheContractGuardTests` | **未登记实体必须回落，不许静默返回空剪枝** |
| **CTX-01 关系两端同 context** | 跨 context 建关系=崩溃前因 | **零覆盖** | 外部经验所得：见 §11.3 说明；本仓 `MixCutApp.swift:353/397/426` 确有 3 处独立 `ModelContext(container)` |
| GRD-01…04 守卫族 | 守卫非恒绿 | 上述 5 颗 `*Guard*` + LL-02「装配错误四种都抓得住、合法清单必须返回空」 | 门 4a/4b 需**逐条补齐这四半边** |
| OBS-01 可观测 | 关键路径有可核对读数 | 零断言（`MixLog` 只写文件，无一处测试守护日志） | `[GraphPrune]` 行的**存在性 + 数字来源**（§10 健壮-7） |

### 11.3 覆盖差距矩阵（维度 × 层级）

层级说明：**集成 / E2E 两层本仓没有自动化入口**（无 test target），只能落到 `scripts/` 探针 + 你手动跑 ⇒ 标 `🖥 手工`。

| 维度 | 单元（swift test） | 集成（🖥 手工/脚本） | E2E（🖥 手工） | 回溯来源 |
|---|---|---|---|---|
| IN-01 空/单 | ➕ G01 | ❌ | ❌ | 模式库 + 种子 TC-01/02 范式 |
| INV-01 守恒 | ➕ G02/G05 | ➕ IT-G01 | ➕ E2E-G01 | 模式库 + 种子 TC-10 |
| INV-02 幂等 | ➕ G04 | ❌ | ❌ | 模式库 + 种子 TC-09 |
| ST-01 迁移 | ➕ G13/G14 | ➕ IT-G02 | ➕ E2E-G02 | 种子 UG-01…12 |
| EX-04 时序 | ➕ G13 | ➕ IT-G01（**重入只能在此层验**） | ❌ | §10 健壮-1 |
| CT-01 契约 | ➕ G03/G06 | ➕ IT-G02 | ❌ | §10 #4 + 种子 G2 |
| CTX-01 同 context | ➕ G16 | ❌ | ❌ | **外部经验**（SwiftData 崩溃长文：崩因是父对象在私有 context、子在 main context） |
| GRD-01 敏感性下限 | ➕ G08 | — | — | 种子 G1/G2 |
| GRD-02 改名不绕过 | ➕ G09 | — | — | 种子 G2 |
| GRD-03 正反两半边 | ➕ G10 | — | — | 种子 G2 |
| GRD-04 豁免对账 | ➕ G12 | — | — | 种子 LL-02 |
| OBS-01 日志契约 | ➕ G15 | ➕ IT-G01（行数==1） | — | §10 健壮-7 |
| SwiftData 真删 / body 渲染 | **❌ 构造不出来** | 🖥 IT-G01/G03/G04 | 🖥 E2E-G01/03 | §11.1 取证 |

**降级声明**：外部经验检索只成功 1 次（SwiftData 崩溃文章，贡献 CTX-01）；
「架构守卫测试」这一同类经验检索被权限层拦下 ⇒ **GRD-01…04 四条全部只对齐了仓内既有 5 颗守卫，未与外部同类项目比过**，
不要把这四条当成「已按业界最佳实践校准」。

### 11.4 用例清单（每条回溯一条规则）

> **v1.5 状态更新**：G08、G08b、G08c、G09、G10、G11、G12、G12b **已生成并通过**（交付记录见 §12）。
> 其余（G01–G07、G13–G16、IT-*、E2E-*）仍是**待生成** —— 它们要靠刀 2/刀 4 先把逻辑下沉成纯函数才有被测对象。

| 编号 | 层级 | 标题 | 回溯规则 | 输入 | 预期 | 优先级 |
|---|---|---|---|---|---|---|
| G01 | 单元 | 定义域用未筛选全域：筛掉一条仍在域内 | 1-A 决定 + IN-01 | 全域 5 条、可见 2 条 | 域=5，非 2 | **P0** |
| G01b | 单元 | 正向对照：全域==可见域时两者结论一致（防 G01 测成恒真） | 种子 UG-04b 范式 | 无筛选 | 域=可见集 | **P0** |
| G02 | 单元 | 域 key 与 `numberByVideo` key 同源（自建组合并档一致） | INV-01 + `video_no` 契约 | 含 2 条 `isUserUploaded` | 两组 key 集合相等 | **P0** |
| G03 | 单元 | 未登记实体 ⇒ 判「需全量重载」，不许静默返回空剪枝 | CT-01 + 六条必犯错 | `GraphChange` 含 `MixScheme` | 结论=回落 | **P0** |
| G04 | 单元 | 同一批 id 连投两次通知 ⇒ 第二次不改结论 | INV-02 / 种子 TC-09 | 同 payload ×2 | 投影不变量成立 | P1 |
| G05 | 单元 | 剪枝守恒：交出 N 个 id 恰好少 N 个、不误伤他人 | INV-01 | 10 条剪 3 | 剩 7 且 id 集合可复算 | **P0** |
| G06 | 单元 | 分组顺序逐条一致（拔掉第二实现前后） | §10 影响 #4 + 种子 TC-05 乱序 | 自建+3 视频乱序 | 与 `videoOrder` 完全同序 | **P0** |
| G07 | 单元 | 「先算 ids 再删」的纯函数面：空/单/极多/重复元素 | IN-01..03 等价类 | 各档 | 集合无重复、顺序稳定 | P1 |
| G08 | 单元 | 门 4a 真仓敏感性下限：基线扫到 >0，刀 1 后为 0 | GRD-01 + 种子 G1 | 真实 `MixCut/Views/**` | 两个阶段各验一次 | **P0** |
| G09 | 单元 | 门 4a 改名不绕过：换属性名 / 先赋局部变量再遍历 | GRD-02 + 种子 G2 | 合成源码 | 检出数不变 | **P0** |
| G10 | 单元 | 门 4a 正反两半边：`group.segments`/VM 数组不误伤，两种绕法判红 | GRD-03 | 合成源码 | 各半边独立成立 | **P0** |
| G11 | 单元 | 第二来源承重：关掉「返回元素为 @Model 的计算属性」⇒ `project.videos` 命中归 0 | §9 P0-2 | 同一份真仓源码 | 命中数按预期变化 | **P0** |
| G12 | 单元 | 门 4b 名册：删一行必红；豁免缺理由判「判据失效」 | GRD-04 + 种子 LL-02 | 合成名册 | 两种装配错误都抓住 | P1 |
| G13 | 单元 | 观察者分叉纯函数：nil / 空集合 / 含未登记实体 / 混合 | ST-01 + EX-04 | 四档 payload | `.prune` / `.fullReload` 各归位 | **P0** |
| G14 | 单元 | 连删两枚：第一枚被 settle 真删后，其 undo 不得再把 id append 回投影 | §10 健壮-6 | 状态机 + 投影桩 | 投影内不含已了结 id | **P0** |
| G15 | 单元 | `[GraphPrune]` 那行存在，且文案里的数字是**剪完之后**的计数 | OBS-01 + 派生读数命名 | 扫剪枝分支源码 | 命中 + 命名与自增处一致 | P2 |
| G16 | 单元 | 启动 fixups 步骤表声明「可否与主 context 建关系」，装配错误 4 种都抓住 | CTX-01（外部经验） | 合成步骤表 | 违规项全部列出、合法返回空 | P1 |
| IT-G01 | 集成🖥 | 真机复现链（§5.5）：崩/条数/`[GraphPrune]` **恰好 1 行且同操作内无 `[Readiness]`** | EX-04 + OBS-01 | 你手点 4 步 | 三条读数同时成立 | **P0** |
| IT-G02 | 集成🖥 | MCP `delete_segments` 后侧栏/概览刷新、日志形状与今天一致 | 行为契约（§10 #1） | 发一次工具调用 | 与修前同形 | **P0** |
| IT-G03 | 集成🖥 | 配音链删除（`DubbingViewModel.swift:321`）在有配音产物处验 | §10 #5 | 需你侧素材 | 未验则**明写未验** | P1 |
| IT-G04 | 集成🖥 | schema 指纹门未被触发（本轮不改 @Model 类型）+ 真启动一次 | §4 雷 2 | 现有库 | 门绿、能开库 | P1 |
| E2E-G01 | E2E🖥 | 删除后**多选态与 pinned Inspector 仍在**（2-B 的核心卖点） | §7 2-B 前提 | 多选 + 选中后删另一条 | 两者都还在 | **P0** |
| E2E-G02 | E2E🖥 | 「顶掉上一枚」时浮条文案如实交代旧事务 | ST-01 + UG-08 | 连删两条 | 文案含「已确认删除」 | P1 |
| E2E-G03 | E2E🖥 | 滚动 20 s 无 SIGTRAP，且不把滚动掉帧线顶回来 | §10 #8 | 复用 `scripts/measure_nav_blank.sh` 同族探针 | 无崩溃 + 每帧耗时不回退 | **P0** |

### 11.5 生成的前置（这三件事没做，一半用例写不出来）

1. **可测面=下沉深度**：G01–G07、G13、G14、G16 要求 5 件事先在 `MixCutCore` 里成为纯函数/纯数据结构 ——
   全域与可见域的解析、`GraphChange` 的分叉与回落、剪枝守恒、名册对账、启动步骤表的「可建关系」声明。
   ⇒ 这是刀 4 的**扩容项**，不改刀 2/刀 6 的实现位置。
2. `Tests/MixCutCoreTests/` 可自由新增文件，不碰 pbxproj ✓；扫描器**必须复用 `codeOnly()` 那套剥注释/字符串**
   （否则注释里写的「不要再这么写」会把守卫自己变成假红 —— 这条本仓踩过）。
3. 集成/E2E 那 7 条**没有自动化入口**，交付形态是「给你的操作单 + 我先写好的日志对账片段」，
   不写成「已覆盖」。**测试我不自跑，git 也不由我动。**

---

## 12. 刀 5 的 Swift 守卫交付记录（2026-10-03，本轮）

文件：`Tests/MixCutCoreTests/TombstoneReadGuardTests.swift`（新增，Tests/ 目录自由 ⇒ 不碰 pbxproj）。
自跑结果：`swift test --filter TombstoneReadGuardTests` ⇒ **rc=0，8 条全过，其中 1 条是刻意的 known issue**。
`swift build --build-tests` 干净通过。**生产代码零改动**（刀 1/刀 3/刀 6 未动）。

| 用例 | 守的是什么 | 结果 |
|---|---|---|
| G08 | 真仓扫描结论必须与基线名册**逐条相等**（新增一处 ⇒ 红；悄悄拔一处不改表 ⇒ 也红） | ✅ 49 处 / 47 键 / 12 文件 **（v1.6 随刀 1 首批销账改为 45 / 43 / 12，见 §13；本行是那一轮的现场读数，不改写历史）** |
| G08b | 门判定「视图层裸读必须为 0」 | ⚠️ 以 `withKnownIssue` 包住 ⇒ 今天红＝通过；**刀 1 拔完后它会自己变红，逼一次摘标**（strict-xfail 语义） |
| G08c | 往真实取样面**注入**一处新裸读 ⇒ 总数 +1 且该条被单独认出 | ✅ 未碰生产文件的敏感性变异 |
| G09 | 属性改名不绕过（禁词表来自 `Models/` 解析，不硬编码）；先赋局部变量再遍历照样抓 | ✅ |
| G10 | 正反两半边：`group.segments`（结构体）、`viewModel.segments`（VM 数组）、`NavigationItem.schemes`（枚举 case）不误伤；直读 / `$N` 闭包形参 / 未知小写 receiver 三种形状都判红 | ✅ |
| G11 | 第二来源承重：关掉「返回模型数组的计算属性」后 `project.videos` 一族命中必须消失 ⇒ 证明它不是装饰；两条来源各自取不到名字即判「判据失效」 | ✅ |
| G12 | 真删站点名册逐文件计数对账 ⇒ **41 处 / 11 个文件**，与 §1.4③ 一致；`MixCutApp.swift`(2) 与 `DebugSelfTest.swift`(9) 登记为**带理由豁免** | ✅ |
| G12b | 名册少一行 / 计数被改小 / 豁免缺理由，三种都报问题；完整名册必须返回空（防恒红） | ✅ |

**两处实测教训（都写进了代码注释，别靠记得）**

1. **Swift Testing 并行跑用例** ⇒ 我第一版把正则缓存放进一个全局可变 `Dictionary`，直接 `EXC_BAD_ACCESS`
   （崩溃栈：`NSRegexCache.regex(_:) → Dictionary.subscript.setter → objc_msgSend`）。
   本仓此前 5 颗守卫都是纯字符串操作、没有共享可变状态，**这是第一棵带缓存的扫描器** ⇒ 已加 `NSLock`（回调在锁外执行）。
2. **receiver 分类必须逐文件**：`SchemeViewModel.swift:73` 有 `let group: MixStrategy`（模型），
   而 `SegmentLibraryView.swift:617` 的形参是 `_ group: VideoSegmentGroup`（结构体）。
   跨文件汇总同名分类会让结构体那个被误判成模型读取 ⇒ 改成一颗文件一份表，并把未知 receiver 的策略定为
   **大写非模型名豁免、其余保守计命中**（漏抓比多抓危险）。

**基线是守卫自己生成的，不是我手写的**：把 G08b 打印出的 `verdict(hits)` 逐条回填成表 ⇒ 数字与算法同源，
不存在「计划里的数」和「扫描器的数」两套口径。也正因如此，§1.4① 的 55 与 §11 期间的 40 都被订正为 **49**。

**已知保守处（诚实记账，不当已解决）**：`SegmentLibraryView.swift:566`
`LibraryGroupRef(id: $0.id, segmentIDs: $0.segments.map(\.id))` 里的 `$0` 其实是 `VideoSegmentGroup`（结构体字段），
按「未知闭包形参保守计命中」被收进基线。刀 1 本来就要重写这一行（它就是投影构造点），销账时一并核掉。

**没做的事**：`scripts/check_project_integrity.sh` 那侧的收口门（与 Swift 守卫命中数互相对账）**尚未落地** ——
按计划它是刀 5 的第二半，本轮只交付主体。全量 `swift test` 我也没跑，留给你按 §5.10 预登记四个数。

---

## 13. 第一批生产改动交付记录（刀 1 首批 + 刀 3 + 刀 6，2026-10-03 本轮）

**改动清单（全部落在已有文件，未新增 `MixCut/**.swift`）**

| 刀 | 文件 | 做了什么 |
|---|---|---|
| 1a | `MixCut/ViewModels/SegmentLibraryViewModel.swift` | `VideoSegmentGroup.segments` **改名 `visibleSegments`**（与 `Video.segments` 关系名分家，守卫才分得开「读投影」和「fault 关系」）；新增 `unfilteredSegmentsByGroupID: [UUID: [Segment]]` 全域投影；抽出 `groupByDisplayKey(_:)` 让**编号与定义域共用一次遍历**（key 与 `VideoSegmentGroup.id` 同源：`video?.id ?? selfBuiltID`） |
| 1b | `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift` | `:566` 行投影改吃 `$0.visibleSegments`；`:632/:677` 计数同理；**崩点那三行**（`domainIDs: Set(video.segments.map(\.id))` / `return video.segments` / `$0.segments.map`）改吃 `viewModel.unfilteredSegmentsByGroupID[group.id] ?? group.visibleSegments`，口径 = 拍板 1-A 的未筛选全域 |
| 1b | `MixCut/Views/SegmentLibrary/DubSettingsBar.swift` | 新增 `let videoSegments: [Segment]` 入参，`variantCount` 不再 `video.segments.reduce` |
| 6 | `MixCut/Utilities/ModelContextExtension.swift` | `PersistentModel.isDroppedFromContext { modelContext == nil }` 立为**唯一真源** |
| 6 | `ImportView.swift:418` / `ShotEditViewModel.swift:427,438` / `SegmentPropertiesSection.swift:456,498` | 4 处 ad hoc 写法（`modelContext ==/!= nil`）全改调它 |
| 6 | `SegmentLibraryView.swift` | **新增两道渲染门**：`sectionHeader` 拆成「门 + `sectionHeaderContent`」（载体视频已摘除 ⇒ `Color.clear.frame(height: 0)`）；卡片侧抽出 `liveSegment(_:)`，网格与列表两条入口共用 ⇒ 已摘除的分镜不进 `SegmentCard`/`SegmentRow` 的 body |
| 3 | `ModelContextExtension.swift` | `func delete<S: Sequence>(_ objects: S) where S.Element: PersistentModel`，函数体第一句就是 `Array(objects)` ⇒ **「忘了快照」在构造上不可实现**。刻意不用官方 `delete(model:where:)`（存储层批删不动内存里已 materialize 的对象，只会制造更多死对象） |
| 3 | `ImportViewModel.swift:379,1244,1245` / `ShotEditViewModel.swift:247` / `DubbingViewModel.swift:318-325` | 5 处「边遍历关系边删」改成吃这颗 API。`DubbingViewModel` 额外重排：**先**`let doomedIDs = Set(dubs.map(\.id))` → 删音频文件 → `segment.segmentDubs.removeAll { doomedIDs.contains($0.id) }` → **最后**才 `context.delete(dubs)`；反过来（先 delete 再按 id 摘）等于对已删对象读 `.id`，就是这次崩溃那一类 |

**守卫侧的三处必要跟随**（`Tests/MixCutCoreTests/TombstoneReadGuardTests.swift`）

1. **基线 49 → 45**（43 键 / 12 文件）：拔掉 5 命中、新登记 1 命中 ⇒ `49 − 5 + 1 = 45`。
2. **G08 的崩点断言改指「不得复发」**：原来断言 `domainIDs: Set(video.segments.map(\.id))` **必须在册**，
   那一行已被我拔掉 ⇒ 继续断言在册等于把「已修」判成回归。改写成两半且各自承重：
   ① 该文件必须仍有别的命中（证明取样面覆盖到它，下面的零断言不是空的）；② 该文件里 `|segments|` 一族必须归零。
   「扫描器认不认得这个形状」的负担交给 G08c 的注入腿。
3. **新增 G08d = 基线重生成腿**（`.enabled(if: TOMBSTONE_DUMP_BASELINE == "1")`，平时报 skipped）：
   §12 那句「基线由守卫自己生成」以前是靠我读 G08b 打印的 `verdict` 手抄回表 ⇒ 那是**半手写**。
   现在 `TOMBSTONE_DUMP_BASELINE=1 swift test --filter TombstoneReadGuardTests` 直接把表格式写进
   `.scratch/guard_baseline_new.txt`，销账只跑这一条，不再有人抄。

**证据（都是本机实跑，不是纸面）**

- **改前那一次 `--filter` 跑成 rc=1**，且红得恰好：G08 报 `removed` 5 条（正是我拔掉的那 5 处命中）+ `added` 1 条
  + 总数 `49 → 45`。⇒ 「悄悄拔一处不改表也拦得住」这条腿**第一次是被真实删除触发的**，不是我注入的变异。
- 表更新后：`swift test --filter TombstoneReadGuardTests` ⇒ **rc=0，共 9 条 = 7 全绿 + G08b 以「1 已知问题」通过
  （还没拔完，它就该继续红）+ G08d 未启用故 skipped**。
- **回环自证**：重跑 G08d 生成的 43 行与文件里的表 `diff` 为空 ⇒ 表 == 生成器输出。
- `SKIP_XCODEBUILD=1 scripts/check_project_integrity.sh` ⇒ **rc=0**，三道门全绿，源码树 169 / 唯一名 169 / BuildFile=SourcesPhase=FileRef=169（本轮没动 pbxproj）。
- `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build` ⇒ **BUILD SUCCEEDED，rc=0，`error:` 0 条**（`-derivedDataPath .scratch/dd`）。

**残留与没做（不当已解决）**

- 新登记的那 1 处 `variantCount = videoSegments.reduce(0) { $0 + $1.segmentDubs.count }` **仍是裸读**：
  定义域数组的元素照样可能是已删 `Segment`，`$1.segmentDubs` 一样会 fault。要拔掉得让 VM 连
  「每分镜配音变体数」一起投影 —— 属刀 1 剩余 45 处，不在本批。
- 刀 1 还剩 **45 处**（Export / Import / Overview / Schemes 四族为主）⇒ G08b 保持 known issue，**拔完那一轮它自己变红，逼摘标**。
- 刀 2（载荷 + 回落 + 防重入 + 30 处非豁免站点）、刀 4（分组下沉 `MixCutCore`）、刀 7（`[GraphPrune]` 日志形状）、
  刀 5 的 shell 对账半颗 —— 全部未动，按计划是第二批。
- **真机未验**（只能你点）：删视频 / 删分镜 / 撤销宽限期三条路径上不再 SIGTRAP、分镜库滚动不闪、
  「自建分镜」与视频分组的配音批量条文案与旧口径一致（我改的是定义域来源，理论上不变，但这是像素级判据）。
- 全量 `swift test` 我没跑 ⇒ 按 §5.10 预登记 `passed / skipped / xfailed / 总数` 四个数你来对。
  本轮新增用例 1 条（G08d），所以总数相对上次 **+1**。

---

## 14. 第二起同族崩带来的四处升级（2026-10-04，本案只出方案未改生产码）

新案：SunCut 0.11.0 于 2026-10-04 11:59:33 SIGTRAP，`Project.id.getter` → SwiftData 内部 → `_assertionFailure`；
崩点 `MixCut/Views/Schemes/SegmentPickerDrawer.swift:106`
（`CatalogVideo(id: $0.id, ownerProjectID: $0.ownerProject?.id)`，由 `:90` 的 `.task(id:)` 续体驱动）。
完整取证与三刀见 `2026-10-04-toone-crossing-real-delete.md`。此处只记**对本计划的修正**，四件事：

1. **§2 的不变量射程不足**。它管住了「读 to-many 集合」与「删除方交出被删 id」两条轴，
   但崩的是**穿过 to-one 边读持久标量**（`Video.ownerProject`，`MixCut/Models/Video.swift:98`，
   零 `@Relationship` 零删除规则）与**入边无人结算**这两条正交轴。
   实测穷举：模型层共 **13 条这样的裸 to-one 边**（全部 optional）⇒ 本案只是第一张输掉的牌。
2. **刀 5 自认的效力上限被证明是真实 hazard，不是可接受残留**。
   §3 刀 5 写「to-one 读取不拦——全仓到处都在读，拦了会把门变成噪音」，
   `TombstoneReadGuardTests.swift:24` 亦写死「取到数组后的后续使用不在射程内」
   ⇒ **门绿而崩点在册**（基线里 `SegmentPickerDrawer` 只有 `:359` 那一条 `schemeSegments`）。
   解法不是撤让步子，是**两档强度**：硬半边只禁新增（当天即可全绿），存量按实测**宽口径 40 处 / 12 文件**
   建 xfail 名册逐批单调缩短；且新扫描器**必须复用 `classifyReceivers`(:147) 的逐文件三分**
   —— 实测反例 `SidebarView.swift:167/185` 的 `product` 是 `:160` 的局部量，不三分即假红。
3. **刀 2 与刀 6 追加腿从「第二批」升为必要配套**。只落读侧门槛（把死引用折算成 nil 不渲染）
   按本项目自己的标尺判**遮盖**：图上仍长期留着「活对象 → 死对象」这条非法边（`ProjectViewModel.swift:266` 级联不删 `Video`，
   被别的项目复用的 `Video` 就成了携带死指针的活行）。且 §1.3 本轮 SDK 取证：`PersistentModel.isDeleted` 存在
   （`SwiftData.swiftinterface:505`，macOS 14+，项目 target 14.0）但**删除先是标记、物理移除等 save、
   未 save 前记录仍在 fetch 结果里、其它引用能让 `isDeleted` 翻回 false**
   ⇒ 刀 6 那颗 `isDroppedFromContext`（`ModelContextExtension.swift:12`）单判据要升级为
   `isDeleted || modelContext == nil` 的**两信号析取**，且升级前须先跑「判据四态矩阵」实测（新案 §4）。
4. **顺手订正两条口径 + 一处现役缺陷**（都属本计划没覆盖的范围，各自单独立项，别算进「已解决」）：
   - `MixCut/Services/MCP/MCPToolHandlers.swift:592-628` 与 `ProjectViewModel.swift:253-284` 是**同一职责的两份实现**，
     前者 `:611` 注释自证「与 `ProjectViewModel.deleteProject` 的 commit 逻辑一致」= 复制粘贴；
     且它在 `:612 context.delete(project)` **之后**才于 `:615` 读 `video.projectVideos.isEmpty`、`:616 Array(video.segments)`
     ⇒ **现役**的「delete 之后读关系」窗口（MCP 链至今没崩属时序运气）。
   - `MixCut/Models/Segment.swift:446`「`container.mainContext` 是唯一的读写面」与
     `MixCutApp.swift:354/398/427` 三处独立 `ModelContext(container)`（其中 `:363` 真删）直接矛盾
     = 本文件 §11.2 的 **CTX-01**，仍零覆盖 ⇒ 句口径待订正或另案收口。
   - 流程约定：本仓**不启用 `.ai-memory/`**，过程记忆与 Decision Record 一律写进本目录 `plans/*.md`（单一真源）。

### 14.5 勘误（v1.8，本案审查轮抓出，**原 §3 文字不删，以本条为准**）

- **§3 刀 2 第 `:142-143` 行「`GraphChange` 类型放 `ContentView.swift` 的 `Notification.Name` 那个扩展旁边」的落点规定被推翻**。
  理由：本案新增的删除咽喉住在 `MixCut/Utilities/ModelContextExtension.swift`，它要**返回**这份变更集
  ⇒ 类型若留在 App 层 = **Utilities 依赖 App = 依赖逆流**；并且一旦广播按「保护型回滚」退回无载荷，
  这个返回值就成了**无人消费的死代码**。
  ⇒ 改判：**`GraphChange` 下沉 `Sources/MixCutCore/`**（纯值类型、零 SwiftData 依赖、`swift test` 可测），
  App 侧的 `Notification.Name` 扩展与唯一发布口只是它的**消费者**，「一个通道」原则不变（通道仍只有一条，只是消息类型换了住户）。
  本案 §3 刀 9 已按此落。
- 同轮另抓出两条与既有门的**互斥面**，实施本文件的刀 1/刀 6 时同样适用：
  `scripts/check_navigation_readiness_guards.sh:88/:106/:140` 逐字锚 `project.id` 与 `holdsData(for projectID: UUID)` 的**处数**，
  `scripts/check_association_guards.sh:67-68/:76` 把 `Project.swift` 的 `associatedVideos`/`videoNoByVideoID` 钉为唯一出口并禁抽屉旁路
  ⇒ 「把裸读改成过门读」若碰到这些锚点，必须**同步改册**，否则发版门红在一处与本题无关的计数上。

### 14.6 刀 2 交付状态（v1.9，机制层已落、逐链接入未落）

本文件 §3 刀 2 那七条规定，逐条对账（细节与实测账在 `2026-10-04-toone-crossing-real-delete.md` §25）：

| 刀 2 规定 | 状态 |
|---|---|
| 不新建广播口，补全 `.mixCutDataDidUndo` | ✅ `GraphBroadcast` 就建在 `Notification.Name` 扩展旁边 |
| 载荷按实体分组，未登记实体整条回落无载荷 | ✅ `GraphEntity`(10) + `GraphChange` 落 `MixCutCore`；`isPrunable` 假 ⇒ 降级 |
| `post` 只留一处真源，MCP 那颗转发到它 | ✅ 全仓该通道 `post(` **恰好 1 处**，由 **G19** 逐字钉住（含 ⌘Z/⇧⌘Z 两处并入） |
| 观察者顶端第一行分叉，剪枝分支不碰 `fetchProjects/loadSegments/flushNow` | ✅ `reloadAfterUndo(change:)` 首行 `if let change`；两个 `pruneDeleted*` 都不调这三个入口 |
| 重入窗口 | ✅ 发布口内 `isBroadcasting` 闸：嵌套那次**丢弃 + error 日志**（丢弃是有意的：外层已覆盖同一次删除） |
| 剪枝顺序先剪 `segments` 再 `applyFilter()` | ✅ 写在 `pruneDeletedSegments` 里，注释交代了 `recomputeGroupedSegments()` 的 to-one 读 |
| MCP 16 处保持无载荷 | ✅ `notifyUIReload()` → `GraphBroadcast.post()` 空载荷（Agent 链的旧语义＝它的回归基线） |
| **UI 侧每条删除链在 commit 的 `safeSave()` 之后发一次带 id 的通知** | ✅ **宽限期 6 条已接完（§14.7 → 本案 §26）**：删视频 / 单删分镜 / 批删分镜 / 删项目交回 id，删策略与删方案刻意空台账（无第二双手可剪）。⚠️ 仍遗留**非宽限期的直删行**：`ImportViewModel:280/379/945/955/1244/1245`、`SchemeViewModel:469`、`ShotEditViewModel:213/247/486`、`DubbingViewModel:325`、`SchemeDetailView:84` |

最后一行原本是**本文件根因层尚未收口的那半**：§1.4④ 说「机制已存在、UI 删除链一次没发」，
当时机制已经能带 id，但"没发"只对删项目链改判成立。下面那段是当时写下的推荐接法 ——
**已在 §14.7（本案 §26）逐条兑现**，原文保留以对照。
把 `PendingDeletionCenter.schedule(commit:)` 的闭包升为 `() -> GraphChange`，由中心在 commit 落地后
`if !change.isEmpty { GraphBroadcast.post(change) }` —— **空台账不发**（否则每条删除都变全量重载，
会把 §5 那条"切页骨架闪烁"重新引回来），逐链只负责"删之前收 id、return 出来"。

### 14.7 刀 2 续批：广播口收进事务中心（v1.10，细节与实测账在本案 §26）

上面的推荐接法已落地，且比"各链各自发"更强：**发布责任归中心**，
`schedule(commit:)` 的闭包必须交回 `GraphChange`，真删落地后由 `PendingDeletionCenter` 经唯一发布口广播
（新判据 **UG-G09** 钉住：闭包返回类型、两处广播点、中心内仅一处 `post`、空台账不发；变异腿 **M9** 实测可红）。
本批另抓到两条**只有运行时才成立**的判据，都由新格 ⑮ 实测（含变异反向对照）：
① 广播必须发生在**新事务登记之后** —— 否则观察者里一句 `flushNow()` 会把刚 arm 的事务了结成一次空调用，
用户那次删除**既不真删也不可撤销**（读数：变异后 `B commit 0 次`，还原后 `1 次`）；
② 重入时嵌套那次**不许丢弃**，改为排空队列（嵌套那次常带 `flushNow` 顺带真删的新 id，丢掉就是回到本文件的原始病）。

本文件根因层的收口状态因此是：**宽限期链 ✅、非宽限期直删行 ❌（11 行，清单见 §14.6 表末行）**。
§1.4④ 那句诊断只有在这一半也接完、且真机 T-0 看过之后，才可以写成"已收口"。



