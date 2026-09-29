# 分镜素材库崩溃 + 同素材重复使用 · 修复计划 v5（2026-09-28，待审）

**产品口径已定**：选**第一种** —— 一个项目里同一段素材只挂一份（挂载是集合），
"同一段素材在成片里出现两次"由**方案层重复引用同一段分镜**实现，而不是靠挂两份。
v2 的 5 条 P0、v3 评审的 A/D/E+F/G、v4 测试评估的 **INV-T** 已全部并入本版。
**第 1 期已按本版执行并通过验收（见 §10），只剩 TC-20 的 24h 延迟复查。**

## 0. v4 → v5 改了什么（并入 `test-coverage-expander` 的结论）

| 来源 | 并入位置 | 一句话 |
|---|---|---|
| 🚨 **INV-T：`addedAt` 相等时留哪条没定义** | §3.1 + §3.4 | 补 tie-break 规则，**沿用本仓既有先例** `MixScheme.swift:69-75`（同 `position` 时按 `id.uuidString` 字典序）⇒ 同 `addedAt` 时按 `pv.id.uuidString` 字典序。**这不是测试补漏，是计划缺一条规则**：tie-break 不定 ⇒ `videoNoByVideoID` 跨启动可变 ⇒ MCP 的 `video_no` 契约漂移（Agent 上次 `video_no=2` 打中的视频，这次指向另一个） |
| 可测性边界（工程无 unit-test target，只有 application productType） | §8.1 | `swift test` **碰不到 `MixCut/` 任何代码** ⇒ "规则下沉多深，可测面就有多大"是本期第一条覆盖决定 |
| 不变量模式库（INV-A…INV-T） | §8.2 | **9 条**项目不变量逐条标注现有种子与缺口（另含内置模式库的 IN-01/02 边界维度、CT/DATA/MIG/PERF 四类通用维度） |
| 用例清单 TC-01…TC-20 | §8.3 | 单元 14 条 + 集成 1 + E2E 4 + 静态守卫 1；**未生成代码，全部标"待生成"** |
| 静态守卫层（`associate` 非 async、全仓崩形清零） | §8.3 TC-19 | 单测够不着 App target ⇒ 用既有 `scripts/test_project_guards.sh` 兜 |
| 自证纪律 | §8.4 | 手写属性测试最容易写成恒真；生成后做 AST 审计，且 TC-03/06/08/09/10 必须能在"规则写错"的版本上变红 |

**工时 85 → 105 分钟**（+20：纯函数测试从"3 条手写"扩到 TC-01…15 的表格化参数用例 + 1 条手写属性测试 + 1 条规模用例）。

## 0.1 v3 → v4 改了什么（并入上一轮 `tech-solution-review` 的结论）

| 评审项 | 并入位置 | 一句话 |
|---|---|---|
| A（P0）规则会被实现两遍 | §3.1 | 读取路径**必须调用** §3.4 那个 MixCutCore 纯函数（同模块无需 import，零成本） |
| D（P0）清理用哪个上下文没钉 | §3.4 + §5 | 钉死 `container.mainContext`；"sqlite 行数"与"当次运行 UI 数字"拆成**两条独立判据** |
| E（P0）备份盖不住 24h 后才显形的后果 | §3.5 | 备份目录加 `Videos/`（实测仅 61 MB）+ `Thumbnails/`；§5 加"跨 24h 阈值后复查文件仍在" |
| F（P1）回滚后一次性开关仍为 true | §3.5 | 回滚步骤补 `defaults delete` 那一行 |
| G（P1）`associate` 的原子性靠约定 | §3.2 | 签名定为**非 async**，注释锁死"判重与插入之间不得引入 await" |
| 旁路（P1）唯一出口有 2 处绕行 | §3.1 | `SegmentPickerDrawer.swift:41`、`ImportView.swift:180` 一并改读 |
| 下游消费者（P1） | §5 | 清理会让 `delete_project` 的"会被全局删除"预览**如实报危险**，写进判据防误认新 bug |
| 契约（P2） | §6 | 明确判断：`video_no` 语义不变 ⇒ `AgentToolCatalog` 描述与契约测试**不动** |
| 反向派生（P2） | §6 | `Video.projects:93`/`referenceCount:98` 同款写法，但全仓**无调用者**（已 grep 核实），本期不动 |

**工时 70 → 85 分钟**（多出的 15 分钟 = 读取路径改调纯函数 + 2 处旁路收口 + 备份与判据补全）。

## 0.2 v2 → v3 改了什么（更早一轮的 5 条 P0，仍然有效）

| P0 | 并入位置 | 一句话 |
|---|---|---|
| P0-1 不变量没收敛在真正的边界 | §3.1 | 收敛到 `Project` 的**单一派生访问器**，视图层兜底降级为兜底 |
| P0-2 第 2 期"按出现次寻址"的语义没定 | §4 | 写成**待你定口径**的一节，不替你选 |
| P0-3 备份路径与回滚步骤没写 | §3.5 | 三件套一起备份（实测 WAL 3.3 MB 未合并，只抄主文件等于没备）+ 可粘贴的回滚命令（v4 又把 `Videos/` 加进来了） |
| P0-4 清理缺幂等与"不误删"判据 | §5 | 加"第二次跑删 0 条"和"各表行数/目录条目数不变"的精确判据 |
| P0-5 跨期"唯一键"改了哪些、留了哪些没清单 | §6 | 明确列成表，防止第 2 期以为第 1 期已铺平 |

**v3 期间新查实的 4 条事实（v2 不知道，且会改变报价）**：

1. ⚠️ **`Project.videoCount`（`MixCut/Models/Project.swift:47`）读的是 `projectVideos.count`，而概览（`ProjectOverviewView.swift:38,42`）和 MCP（`MCPToolHandlers.swift:84-85`）读的是 `videos.count`** —— 两个口径今天就已经不一致（前者会把悬空关联也计入，MCP 那行注释就是在规避这点）。清理后 `SchemeListView.swift:286,341` 显示的「N 个视频」会变、概览不变 ⇒ **必须一起收敛，否则同一个数字在两个页面打架**。
2. ⚠️ **`video_no` 是 Agent 的寻址契约**：`MCPSegmentToolHandlers.swift:15-19` 用关联行排序后 `enumerated()` 出编号，`:597-599` 再按 `video_no` 下标反查。重复行 ⇒ 编号整体错位，Agent 传 `video_no: 3` 会拿到**另一个视频**或直接「超出范围（项目共 5 个视频）」—— 而磁盘只有 4 个文件。而 `SegmentLibraryView.swift:467-468` 的注释写着 UI 编号要与 MCP **同一套规则**，今天这句话是靠**两处各写一遍**来维持的（隐式耦合）。⇒ 见 §3.1，编号必须收成一处。
3. 🚨 **v2 §4 说"结构上已经支持重复"只对了一半**：`Sources/MixCutCore/NarrativeStructureEngine.swift:46` 有 `guard Set(segmentIDs).count == segmentIDs.count else { return false }` —— **组合内重复被核心校验器硬禁**，且 `Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift:85` 把这条断言写成**预期行为的测试**（`rejectsWrongCountDupOrOutOfPool`）。⇒ 第 2 期是**三层阻塞**（prompt / 核心校验器+其测试 / UI），不是 v2 说的两层，见 §4。
4. ✅ **存量规模实测（只读快照 `.scratch/db-v3/`，未碰运行库）**：`ZPROJECTVIDEO` 共 **6 行**，重复组恰好 **1 个**（`ZPROJECT=1, ZVIDEO=2` 两行，`ZADDEDAT` 差 **0.178 秒**）；`ZVIDEO=4`、`ZSEGMENT=9`、`ZMIXSCHEME=0`、`ZSCHEMESEGMENT=0`、`Videos/` 目录 **4 项**。⇒ **第 1 期清理只会删 1 行**，判据能精确到"删的是后加入的那条"。

## 1. 崩溃根因（实证）

3 份崩溃报告同栈：`EXC_BREAKPOINT/SIGTRAP` → `_assertionFailure` → `_NativeDictionary.merge`
→ `Dictionary.init(uniqueKeysWithValues:)` → **`SegmentLibraryView.videoNoByID.getter`**（`SegmentLibraryView.swift:470`）。

- 肇因代码：`ImportViewModel.swift:415-417` 的 hash 复用分支——只对"视频记录是否已存在"去重，
  **不对"本项目是否已关联"去重**。同一批导入里两个内容相同、文件名不同的文件 ⇒ 第二条关联行（实测 0.178 秒差）。
- 触发时机：分镜数 > 0 才会走到建字典那支，所以此前一直潜伏；重试出 9 条分镜后当场炸。
- 污染面比崩溃大（同一份脏数据的四种表现，都不需要崩）：
  分镜列表翻倍（`SegmentLibraryViewModel.swift:82-83`）、`segmentCount` 翻倍（`Project.swift:50-52`）、
  UI 与 MCP 的 `video_no` 错位（上面第 2 条）、`SchemeListView` 的「N 个视频」虚高。

## 2. 全局假设清点：「按 id 建键必然唯一」

**5 处** `Dictionary(uniqueKeysWithValues:)`，同一种乐观假设，脏数据一到就整进程 SIGTRAP：

| # | 位置 | 键 | 现状 | 第 1 期处置 |
|---|---|---|---|---|
| 1 | `SegmentLibraryView.swift:470` | `video.id` | **已崩** | 改走 §3.1 共享编号，构造点消失 |
| 2 | `SegmentLibraryViewModel.swift:236` | `segment.id` | 同素材挂两份 ⇒ `allSegments` 同批分镜两次 ⇒ 必崩 | 兜底不 trap + 上游靠 §3.1 |
| 3 | `DubbingViewModel.swift:174` | dub `id.uuidString` | 来源 reconfigurable，与挂载无关 | **不动**，记 §6 |
| 4 | `SchemeGenerationService.swift:421` | AI 返回的 alias | AI 给重复 alias 即崩，与挂载无关 | **不动**，记 §6 |
| 5 | `MCPSegmentToolHandlers` 编号链（`:15-19`/`:597`） | 下标即 `video_no` | 不 trap，但**静默错位**（更坏） | 改走 §3.1 共享编号 |

"关联行 → 视频"这一派生今天有 **6 处各写一遍**（`.videos` / `.videoCount` / `SegmentLibraryView:471` / `SegmentPickerDrawer:41` / `ImportView:180` / `MCPSegmentToolHandlers:16`）—— 这正是漏掉收敛点的原因。

## 3. 第 1 期（本轮做）：修崩 + 挂载层不变量

### 3.1 不变量收敛在**唯一一处**（P0-1，本期的骨架）

在 `MixCut/Models/Project.swift` 落一个**单一派生访问器**，其余全部改为读它：

```swift
/// 项目内「每个视频一条」的关联视图：按 addedAt 升序、同一 video 只留最早一条，
/// addedAt 相等时按 pvID.uuidString 字典序（INV-T，先例 MixScheme.swift:69-75）——
/// **没有 tie-break 就没有稳定编号**，见 §3.4。
/// 关联唯一性的**读取侧唯一出口**。写入侧由 ProjectVideo.associate 保证，
/// 这里去重只是兜底（防历史脏数据 / 未来新增写入口漏判）。
/// ⚠️ 规则本体在 MixCutCore.ProjectVideoDedup（§3.4），这里**只调用、不再写一遍**：
///    `Package.swift:9-11` 已注明 App target 直接编译 Sources/MixCutCore（同模块、无需 import），
///    所以复用零成本。写在两处 = 单测只守迁移、不守出货路径。
var associatedVideos: [Video] { /* 交给纯函数出「应保留的 pvID 集合」，再按该集合取行 */ }
var videos: [Video]      { associatedVideos }   // 既有 15 处调用无需改
var videoCount: Int      { associatedVideos.count }
/// UI 卡片 # 与 MCP video_no 的**唯一定义处**（原注释要求"同一套规则"，今天靠两处重复实现维持）
var videoNoByVideoID: [UUID: Int] { /* 与 associatedVideos 同序，1-based，同样由纯函数出顺序 */ }
```

- `SegmentLibraryView.swift:469-476` 的自建字典删掉，改读 `project.videoNoByVideoID` ⇒ **崩点从物理上消失**，不是"崩得晚一点"。
- `MCPSegmentToolHandlers.swift:15-19` 与 `MCPToolHandlers.swift:105-107` 改读同一批访问器 ⇒ UI 编号与 Agent 编号再也分不开。
- **旁路一并收口**（v3 评审项：否则"唯一出口"名不副实 —— 这两处今天只是"因为数据被修好了才恰好正确"）：
  `SegmentPickerDrawer.swift:41`（方案选抽屉）、`ImportView.swift:180`（导入页）各改 1 行，改读 `associatedVideos`。
- `videoCount` 从「行数」改「去重视频数」：与 MCP 既有口径（`MCPToolHandlers.swift:84` 的注释）对齐，**这本身是一处行为变更**，见 §5 判据。
- 视图层残留的 `Dictionary(_,uniquingKeysWith:)` 只作为兜底，**必须带注释指名"真修点在 Project.associatedVideos"** —— 否则下一个人在别处再写一遍。


### 3.2 写入侧收口为幂等入口

`ProjectVideo.associate(project:video:context:)`：已关联则返回既有行 + `MixLog` 记警告，不再插入。
**签名必须是同步（非 `async`）函数** —— 判重与插入之间不得出现 `await`，否则 MainActor 上的
check-then-insert 原子性就没了（已核实今天的肇因段 `ImportViewModel.swift:412-418` **没有挂起点**，
重复纯粹来自"根本没判"；这条约束是防第 8 个写入口把竞态引进来）。注释里写死这句。
**7 处构造点全改走它**（逐处加判断必漏第 8 处）：`ImportViewModel.swift:417`（肇因）/`:441`/`:509`、
`MixCutApp.swift:609`/`:620`/`:964`（`:964` 是 `recoverFromDisk`，磁盘恢复路径同样能造重复，v2 已列但要点名它跑在清理**之前**）、`DebugSelfTest.swift:527`。

### 3.3 撤销路径（已定并入）

`ImportViewModel.swift:752-766`：删除时按 `video.id` 摘除**全部**关联行，撤销时 `append(contentsOf:)` 原样回填 ⇒ 关系数组里同一对象两次。回填前按 `pv.id` 去重。

### 3.4 一次性清理存量重复（纯函数下沉 MixCutCore）

`Sources/MixCutCore/ProjectVideoDedup.swift`：输入 `[(pvID, videoID, projectID, addedAt)]`，输出应删 pvID 集合 + **保留行的有序序列**（编号也用它，见 §3.1）。

**规则 = 每个 `(project, video)` 只留"最早一条"，并必须有确定的 tie-break（v5 的 INV-T）**：

1. 主序键 `addedAt` 升序；
2. **`addedAt` 相等时按 `pvID.uuidString` 字典序**留首条。规则**照抄本仓既有先例**
   `MixCut/Models/MixScheme.swift:69-75` 的 `orderedSegments` ——
   `$0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position`。
   **为什么必须定死**：tie-break 缺失 ⇒ 排序不稳定 ⇒ `videoNoByVideoID` 两次启动可给出不同编号 ⇒
   **MCP 的 `video_no` 契约漂移**（Agent 上次 `video_no=2` 打中的视频，这次指向另一个）。
   而撞 tie 不是理论风险：实测肇因两行只差 0.178 秒，同批导入完全可能取到同一个 `Date()`。
3. 有序序列 = 各组保留行再按 `addedAt`（tie 同上）全局排序，编号从 1 起。
App 侧在既有启动迁移区调用（`MixCutApp.swift:133-150` 之间，**必须在 `recoverFromDisk`(:135) 之后、`scheduleOrphanGCIfDue`(:150) 之前），且上下文钉死为 `container.mainContext`**
（对齐 `backfillSegmentFrames:451` 的写法；**不要**学 `purgeLegacyQwenDubs:408` 那种新建 `ModelContext(container)` ——
仓库里两种写法并存，用子上下文删行时，已 faulting 出来的 `project.projectVideos` 数组不保证同步移除，
结果会"库里清了、界面没清"，而 §3.1 的兜底恰好会把这种没清干净**伪装成已收敛**）。
一次性开关沿用既有 `UserDefaults` 写法（见 `:406-407`、`:428-429`），开关 key 记进 §3.5 回滚清单。

**两条硬约束（写进纯函数 + 断言，违反就是删用户文件）**：
1. **绝不删某个 video 的最后一条关联** —— 关联一旦归零，磁盘 `.mp4` 会被连带删掉，判定散布四处：
   `MixCutApp.swift:548`（`orphanVideos`）、`:1034+`（孤儿 GC，每 24h 一次）、`ImportViewModel.swift:779`、`ProjectViewModel.swift:100`。
   规则按 `(project, video)` 分组留首条 ⇒ 天然不会归零，但**必须用断言把它锁住**（TC-08），
   防止日后有人"顺手"改成按 video 全局去重。
2. **只删关联行**，绝不删 `Video` / `Segment` / 磁盘文件（引用计数语义见 `ImportViewModel.swift:779`）。

⚠️ 新增 MixCutCore 文件要**手工加 4 处 pbxproj 引用**并跑 `scripts/check_project_integrity.sh`；**绝不跑 `generate_xcodeproj.py`**（会抹掉 36 条手工引用，工程编不过）。

### 3.5 备份与回滚（P0-3 + v4 的 E/F，动手前置）

实测 `~/Library/Application Support/MixCut/`：`MixCut.store` 212 KB + **`MixCut.store-wal` 3.3 MB** + `-shm` 32 KB，
`Videos/` **61 MB（4 个 hash 目录）**，`Thumbnails/` 916 KB。
**只抄主文件 = 备份了空库**（最新写入全在 WAL）；**只备库 = 备不住删文件的后果**（下面第 2 条）。

```
mkdir -p ~/Library/Application\ Support/MixCut/backup-$(date -u +%Y%m%dT%H%M%SZ)
```
把 `MixCut.store`、`MixCut.store-wal`、`MixCut.store-shm`、`Videos/`、`Thumbnails/` **一起**搬进备份目录
（**必须先退出 App**，否则 WAL 不合并、副本不自洽）。`Videos/` 61 MB 的代价约等于 0，而它保护的正是本计划唯一不可逆的失败模式：

> **为什么必须备 `Videos/`**：孤儿 GC 是「每 24 小时最多一次」（`MixCutApp.swift:1034+`，挂载点 `:150`）。
> 若去重逻辑错删了某个 video 的最后一条关联，**文件不会在验收窗口内消失，而是一天后的某次启动才消失** —— 那时才显形就已经太晚。

**回滚步骤（写死在这里，不做临场发挥）**：
1. 退出 App → 把当前 `MixCut.store*` 三件套改名加 `.bad` 后缀（别删，留取证）
2. 从备份目录把三件套原样 `cp` 回；`Videos/`、`Thumbnails/` 若被改动则整目录还原
3. **清掉一次性开关，否则回滚后清理不再跑**（回滚与修复两条路会同时断）：
   `defaults delete com.mixcut.app didDedupProjectVideoAssociations_v1`
   （若 bundle id 不是 `com.mixcut.app`，用 `defaults domains | tr ',' '\n' | grep -i mixcut` 先确认；
   开关 key 名以实际写入代码为准，执行时把真实 key 回填到本行）
4. 启动 App 验证：`ZPROJECTVIDEO` 回到 6 行、页面走 §3.1 兜底**不崩**

`CLAUDE.md:316-320` 的备份铁律原文指向 `default.store`，那是**旧版路径**（`FileHelper.swift:34-35` 现在是 `MixCut/MixCut.store`）；本次不是 schema 变更，但这是**有删行的数据操作**，按铁律精神执行。

### 3.6 明确不做

给 store 加 `(ZPROJECT,ZVIDEO)` 唯一索引。SwiftData 会校验 store 元数据 ⇒ 属 schema 变更，撞 `CLAUDE.md:316` 铁律且需迁移映射。代码层闭合即可，§3.1+§3.2 已是读写两侧收口。

**第 1 期约 105 分钟**（纯函数含"规则本体唯一化 + tie-break"15、其单测 TC-01…15 约 20、收敛点+编号+2 处旁路 20、幂等入口 15、撤销 10、
启动清理挂载与 mainContext 核对 10、pbxproj 与 `check_project_integrity.sh` 10、备份与基线记录 5）。
比 v2 的 60 分钟多 45 分钟，多出来的全在 §3.1 的收敛（6 处调用点收一处 + 让读取路径复用同一个纯函数）与 §8 的测试层。
**代价要认**：做完后"同一段素材在成片里出现两次"仍然没有，第 2 期才给。

## 4. 第 2 期（需你单独确认口径后才设计）

### 4.1 待你定的口径：两次"出现"要不要能各自寻址（P0-2）

放开后，方案里会出现两条指向同一个 `Segment` 的 `SchemeSegment`。由此产生三件**你现在就得选**的事，我不替你定：

| 问题 | 选项 A | 选项 B |
|---|---|---|
| 分镜库里同一段出现两次，点其中一张卡，两张高亮吗（`SegmentLibraryView.swift:568,582` 按 `segment.id` 判等） | 两张都亮（"这是同一段料"） | 要区分就得引入"出现次"标识，UI 要重做 |
| 删除/替换某一次出现，另一条不动 —— 但按 `segment.id` 找"在不在方案里"的判等（`SchemeViewModel.swift:429-432`）语义变了 | 保留判等作为"提示"，不再阻止 | 完全去掉判等 |
| Agent/MCP 侧怎么指名"第 2 次出现"？现有 `segment_ids` / `video_no+segment_no` 两种寻址**都只能指到"那一段"，指不到"那一次"** | 本期不动 MCP，只放开手工 UI ⇒ Agent 仍无法构造重复 | 给 `SchemeSegment` 加"出现序号"对外标识（新的公开契约） |

**共享语义必须认下来**：两次出现指向同一个 `Segment` ⇒ **台词、字幕文本、裁剪区间是共享的**（改一处两处同变）；
只有挂在"出现"上的属性（配音选择 `selectedSegmentDubId`、`position`、理由）各自独立。
要"两份各自裁不同区间、配不同字幕"是**第二种**，本计划不做。

### 4.2 三处硬阻塞（第 1 期一律不动，先列全）

1. **核心校验器**：`Sources/MixCutCore/NarrativeStructureEngine.swift:46` 硬禁组合内重复；
   `Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift:85` 把它**当成预期行为断言**。放开＝改这条断言，属**产品口径变更**，按老规矩不许悄悄放宽。
2. **AI 提示词**：`SchemeGenerationService.swift:335`「同一组合内不重复同一片段」是刻意规则；不放开则只有手工建方案能重复用。
3. **UI 阻止**：`SchemeViewModel.swift:487`（`insertSegment`）与 `:519`（`replaceSegment`）的「该分镜已在方案中」，
   返回值被 `SchemeDetailView.swift:94,103` 当成功/失败信号用，`SegmentPickerDrawer.swift:135` 用它置灰按钮 ⇒ 去掉后要一并决定这三处 UI 怎么变。

第 2 期真做前，先按 §4.1 定口径，再单独出计划。

## 5. 验收判据

> 完整用例清单（TC-01…TC-20，含每条回溯到哪条不变量、层级、优先级）见 **§8.3**；本节只留口径性判据。

**第 1 期 · 纯逻辑**（`swift test`，每条都要能在实现写错时变红）：
无重复→删空集；两条→留最早删后；三条→只留最早；`addedAt` 乱序输入仍按时间判定（防"按数组顺序"的假实现）；
**`addedAt` 完全相等时仍每次留同一条、编号跨调用稳定**（INV-T，v5 新增）；
**同一 video 关联到不同 project → 一条都不能删**（最危险误伤）；
**某 video 只有 1 条关联时不得进删除集**（= §3.4 硬约束 1 的断言，防孤儿 GC 删文件）；
`video` 为 nil 的悬挂关联有明确处置且不影响 `associatedVideos`。

**第 1 期 · 幂等（P0-4）**：清理函数**连跑两次**，第二次删 **0 条**、行数不再变
（注意：这条要测**纯函数**，不是测 `UserDefaults` 开关 —— 开关挡住第二次运行不等于规则本身幂等）。

**第 1 期 · 不误删（P0-4，精确到数）**：以下四项前后必须完全一致
`ZVIDEO=4`、`ZSEGMENT=9`、`Videos/` 目录条目 4、`ZPROJECTVIDEO` **6 → 5（恰好少 1，少的是 `ZADDEDAT` 较晚那条）**。

**第 1 期 · 延迟显形的补测（v4-E）**：清理后**跨过孤儿 GC 的 24h 阈值再启动一次**（或临时把阈值判据读出来核对上次运行时间），
复查 `Videos/` 仍为 **4 项**、4 个 hash 目录都还在。这条不能省 —— 删文件的后果今天看不见。

**第 1 期 · 用户可观察**：
- 点「分镜素材库」不崩（旧包必崩是现成红→绿对照），9 条分镜正常显示
- 概览「已导入视频」 **5 → 4**，且 `SchemeListView` 的「N 个视频」显示同一个数（§0.2 第 1 条口径统一）
- ⚠️ **D 的拆条要求**：「当次运行的 UI 数字」与「重启后 sqlite 行数」是**两条独立判据**，不许互相替代
  （否则"库里清了、界面没清"会被兜底逻辑掩盖成通过）
- sqlite 只读复查 `group by ZPROJECT,ZVIDEO having c>1` 返回 **0 行**
- MCP 复跑判据：`get_project` 的 `videos` 条目数 == 唯一 id 数，且**每个 `video_no` 从 1 连续无跳号**、`video_no` 反查回来的视频与 UI 卡片 # 一致（§0.2 第 2 条）
- **下游消费者变化要预期**：清理后调 `delete_project`（不带 `confirm`）的影响预览里，
  那个原本"看着像被两个项目引用"的视频应出现在 `videos_that_would_be_deleted_globally` 中
  （判据来自 `MCPToolHandlers.swift:438` 的 `projectVideos.count <= 1`）。
  **这是修正、不是新 bug**；不写下来，验收时会把它当成回归。
- 回归肇因路径：把两个**内容相同、文件名不同**的视频先后导入同一项目 → 只产生 1 条关联、日志有幂等警告、页面不崩

**第 2 期（若做）**：同一方案内把同一段加两次 → 不崩、两张卡可区分、两处可选不同配音、导出的 MP4 里该片段真的出现两次（ffprobe 数流与总时长核对）。

## 6. 跨期遗留清单（P0-5：第 1 期到底修了什么、把什么留着）

| 位置 | 依赖的假设 | 第 1 期 | 第 2 期 |
|---|---|---|---|
| `SegmentLibraryView.swift:470` | video.id 唯一 | **消失**（改读共享编号） | — |
| `MCPSegmentToolHandlers.swift:15-19` `:597` | 关联行→video 顺序唯一 | **改指共享访问器** | video_no 仍指不到"第 N 次出现"（§4.1 第 3 问） |
| `SegmentLibraryViewModel.swift:236` | segment.id 唯一 | 兜底不 trap | **必改**（放开后合法重复键） |
| `SchemeViewModel.swift:429-432` | "在不在方案里" | **不动** | **必改**（语义变更） |
| `SegmentLibraryView.swift:568,582` | 一段只出现一次才不重复高亮 | **不动** | 待 §4.1 口径 |
| `NarrativeStructureEngine.swift:46` + 测试 `:85` | 组合内不重复 | **不动** | **必改** |
| `SchemeGenerationService.swift:335` prompt | 同上 | **不动** | 待你定 |
| `DubbingViewModel.swift:174` | dub 自身 id 唯一 | **不动**（与挂载无关） | 需核是否与方案层耦合 |
| `SchemeGenerationService.swift:421` | AI alias 唯一 | **不动**（AI 输入问题，另案） | 另案 |
| `MixScheme.swift:69-75` `orderedSegments` | `position` 相等时按 `id.uuidString` 定序（**已有 tie-break**） | **不动，但作为 INV-T 的规则先例** | 第 2 期若出现"同一段两次插入撞同一 `position`"，这条 tie-break 就是两条出现的区分依据（§4.1 第 1 问相关） |

**残余风险要写明白**：清理靠 `UserDefaults` 一次性开关 ⇒ 只跑一次。若将来新增写入口绕过 `associate`，
脏数据会再出现，届时**只有 §3.1 的兜底在挡**（不崩，但计数仍会偏）。这就是为什么 §3.1 必须做在模型层而不是视图层。

**两条"已核后决定不动"的判断（v4 补，防止后来者误改）**：
1. `video_no` 的对外契约定义在 `Sources/MixCutCore/AgentToolCatalog.swift:40-41,155,160,165,170`、
   设计文档 `docs/superpowers/specs/2026-07-28-mcp-segment-editing-design.md:33-34`，并有契约测试
   `Tests/MixCutCoreTests/MCPProtocolTests.swift:109`、`AgentToolCatalogTests.swift:28,53`。
   去重后「按导入顺序 1 起」**仍然成立** ⇒ 工具描述与这些测试**不动**。
   （反过来说：谁要是为了让描述去迁就**错位**编号而改契约，就是把 bug 固化成规范。）
2. 反方向派生 `Video.projects`（`Video.swift:93-95`）与 `referenceCount`（`:98`）是同款"关联行→对侧"写法，
   但 grep 全仓**没有任何调用者**（只有定义）⇒ 本期不动。真正在用的引用计数是 `projectVideos.isEmpty`
   （`MixCutApp.swift:548`、`ImportViewModel.swift:779`、`ProjectViewModel.swift:100`、`MCPToolHandlers.swift:453`），
   这四家才是 §3.4 硬约束 1 要保护的对象。

## 7. 执行顺序

1. 你退出 App → §3.5 备份（store 三件套 **+ `Videos/` + `Thumbnails/`**）→ 记录 §5 的四项基线数与开关 key
2. 纯函数 + 单测（`swift test`，先红后绿；用例清单见 **§8.3 TC-01…15**，含 tie-break 的 TC-06）
   → 手工加 4 处 pbxproj 引用 → `scripts/check_project_integrity.sh` → 守卫脚本补 TC-19
3. §3.1 收敛点（`Project` 三访问器 + 编号，**内部调用步骤 2 的纯函数**）→ 2 处旁路收口 → §3.2 `associate`（非 async）改 7 处 → §3.3 撤销 → §3.4 启动清理挂载（`mainContext`）
4. 编 Debug 包 → 按 §5 用户可观察项逐条验（含 MCP 复跑、UI 与 sqlite **两条独立判据**、`delete_project` 预览变化）
5. **跨过 24h 阈值后再启动一次**，复查 `Videos/` 仍为 4 项（§5 延迟显形那条）
6. 若 §5 有任一条不过 → 按 §3.5 回滚（含清开关），不进第 2 期

## 8. 测试覆盖层（v5，由 `test-coverage-expander` 从既有种子归纳 + 同类项目经验补漏）

**框架探测**（生成前已核）：swift-testing（`import Testing` / `@Test` / `#expect`），`Tests/MixCutCoreTests/` 共 34 文件 223 个 `@Test`；
`Package.swift` 的 `dependencies: []` ⇒ **不许为测试引入 SwiftCheck**，属性测试用手写确定性种子；
被测对象约定是 `public enum <Subject>` + 值类型入参（见 `Sources/MixCutCore/*`），测试内用本地工厂构造（`NarrativeStructureEngineTests.swift:60-86` 的 `seg()` 形状）。

### 8.1 第一条结论：可测面 = 规则下沉的深度

本工程**只有 application productType、没有 unit-test target** ⇒ `swift test` 物理上碰不到 `MixCut/` 里的任何代码。

| 计划里的动作 | 落在哪 | 能否 `swift test` | 不可单测时的替代覆盖 |
|---|---|---|---|
| 去重规则本体 + 编号 + tie-break | `Sources/MixCutCore` | ✅ 可 | — |
| `Project.associatedVideos` / `videoCount` | `MixCut/Models` | ❌ 不可 | 复用同一纯函数后只剩"接没接对线" ⇒ 静态守卫 + UI 判据 |
| `ProjectVideo.associate` 幂等 | `MixCut/Models` | ❌ 不可 | TC-19 静态断言（签名非 `async`）+ TC-17 导入回归 |
| 撤销路径去重 | `MixCut/ViewModels` | ❌ 不可 | TC-18 E2E（删除→撤销→计数与 sqlite 行数） |
| 视图兜底冲突策略 | `MixCut/Views` | ❌ 不可 | 旧包必崩 = 现成红→绿对照 |

### 8.2 不变量模式库（阶段 A 归纳，标注现有种子）

| ID | 不变量 | 现有种子 | 状态 |
|---|---|---|---|
| INV-A | 保留行数 == 唯一 `(project,video)` 组数 | `OrphanFileFinderTests.swift:10-13` 同型 | ➕ |
| INV-B | **每组至少留 1 条**（挡住孤儿 GC 删文件） | 无同类种子 | ➕ P0 |
| INV-C | 留的是组内 `addedAt` 最小者 | 无 | ➕ P0 |
| INV-D | 幂等：对已净数据再跑 → 删 0 | `UniqueFileNamerTests.swift:6-9` 同型 | ➕ P0 |
| INV-E | 同 video 关联到不同 project 一条都不能删 | 无 | ➕ P0 |
| INV-F | 输入行序打乱 → 结果集合相同 | 无 | ➕ P0 |
| INV-G | 编号 1-based 连续、无跳号、键唯一（⇒ 不可能再 trap） | `AgentToolCatalogTests.swift:28` 只测 schema 字段名 | ➕ P0 |
| INV-H | 悬挂行（`video`/`project` 为 nil）有确定处置且不污染编号 | 无 | ➕ P1 |
| **INV-T** | **`addedAt` 相等时 tie-break 确定 ⇒ 编号跨调用稳定** | 无（先例在 `MixScheme.swift:69-75`） | ➕ **P0（v5 新增规则）** |
| CT-01 | 契约描述与实现一致（`video_no`「按导入顺序 1 起」） | `MCPProtocolTests.swift:109` | ✅ 已有，不动 |
| DATA-01 | 落库正确性 / 去重 / 事务边界 | 无 | ➕ 只能集成层（TC-15/17） |
| MIG-01 | 旧数据向后兼容 | `NarrativeStructureEngineTests.swift:88`（legacy JSON）同型 | ➕ P1 |
| PERF-01 | 启动迁移路径的规模上限 | 无（事故记录在 `MixCutApp.swift:146-148`） | ➕ P1 |

### 8.3 用例清单（**全部"待生成"，未伪造覆盖**）

| 编号 | 层级 | 标题 | 回溯 | 输入 → 预期 | 优先级 |
|---|---|---|---|---|---|
| TC-01 | 单元 | 空输入返回空集 | IN-01/INV-D | `[]` → 删 0、编号 `[:]` | P1 |
| TC-02 | 单元 | 单条关联不动 | INV-A | 1 行 → 删 0，编号 =1 | P1 |
| TC-03 | 单元 | 两条同组留最早 | INV-C | `t1<t2` → 删 `pv2` | **P0** |
| TC-04 | 单元 | 三条同组只留最早 | INV-C | → 删后两条 | P1 |
| TC-05 | 单元 | 乱序输入结果同 | INV-F | 打乱行序 → 删除集合相同 | **P0** |
| TC-06 | 单元 | tie 按 `pvID` 字典序 | **INV-T** | 同 `addedAt` 两行 → 每次留同一条、编号不变 | **P0** |
| TC-07 | 单元 | 同 video 不同 project 全保留 | INV-E | 2 组跨项目 → 删 0 | **P0** |
| TC-08 | 单元 | 每组至少留一条 | **INV-B** | 某 video 只有重复行 → 保留数 ≥1 | **P0** |
| TC-09 | 单元 | 幂等再跑 | INV-D | 删除集合作输入 → 第二次 ∅ | **P0** |
| TC-10 | 单元 | 编号连续且键唯一 | INV-G | N 组 → `(1...N)`，且用它建 `Dictionary(uniqueKeysWithValues:)` 不 trap | **P0** |
| TC-11 | 单元 | 悬挂行处置 | INV-H | `video=nil` → 不进编号、不影响他组 | P1 |
| TC-12 | 单元 | 混合场景（重复+唯一+悬挂） | INV-A/B/C | → 删恰好 1 | P1 |
| TC-13 | 单元 | 规模与顺序复杂度 | PERF-01 | 1000 行 = 250 组各 4 条 → 保留 250 组、编号 1…250，且**耗时不超过 100 行时的 40 倍**（实测 1000 行 0.006 秒；不拿拍的毫秒数当判据） | P1 |
| TC-14 | 单元 | 手写确定性伪随机属性测试 | INV-B/D/F | 固定种子生成 200 组 → 三条性质同时成立（不引外部依赖） | P1 |
| TC-15 | 集成 | 用实测基线做 fixture | MIG-01 | §0.2 第 4 条那 6 行（含 1 组重复）→ 恰好删 1 | **P0** |
| TC-16 | E2E·MCP | 清理后 `video_no` 与 UI 卡片 # 一致 | CT-01 | `get_project` 编号连续、反查回同一视频 | **P0** |
| TC-17 | E2E·手工 | 导入两个内容相同/文件名不同的视频 | DATA-01/OBS-01 | 只 1 条关联 + 日志出现幂等警告行（判据落**用户可观察**结果，不预置状态） | **P0** |
| TC-18 | E2E·手工 | 删除→撤销 | ST-02 | 计数与 sqlite 行数不变、不崩 | P1 |
| TC-19 | 静态守卫 | `associate` 非 `async`、全仓不再有崩形 `Dictionary(uniqueKeysWithValues:` | §3.2 / §2 | 加进 `scripts/test_project_guards.sh`，**改前快照必须变红** | P1 |
| TC-20 | E2E·延迟 | 跨 24h 后 `Videos/` 仍 4 项 | INV-B 下游 | 唯一能证明"没误删文件"的判据 | **P0** |

**外部经验标注**：参数化测试与属性测试的维度取自 Swift Testing 官方/WWDC24 与 QuickCheck/SwiftCheck 的守恒·幂等性质实践；
"Core Data 清理迁移幂等测试"那次检索返回的是无关内容 ⇒ INV-C/INV-D 的回溯只标**内置模式库**，不冒充检索所得。

### 8.4 生成纪律

- 测试代码在你确认 §8.3 后才生成，**沿用既有目录与命名**（`Tests/MixCutCoreTests/ProjectVideoDedupTests.swift`），**不改任何生产码**。
- 不自动跑测试、不提交。
- 手写属性测试（TC-14）最容易写成恒真 ⇒ 生成后做 AST 审计；且 TC-03/06/08/09/10 必须能在"规则故意写错"的版本上变红才算有效覆盖。
- `swift test` 只覆盖 `Sources/MixCutCore`，**不许把"223 个测试全绿"读成"这次修复被验证了"** —— App target 那四条改动靠 TC-17/18/20 的运行期判据兜。

## 9. 待你确认

1. **第 1 期是否现在开工**（开工前你需要**先退出 App**，否则备份不含 WAL 里 3.3 MB 最新写入）。
2. §0.2 第 1 条：`videoCount` 改成与概览/MCP 同口径，会让 `SchemeListView` 上「N 个视频」这个数字**变小** —— 认可这个行为变更吗？
3. **tie-break 按 `pvID.uuidString` 字典序**（§3.4 第 2 条，抄 `MixScheme.swift:69-75` 的先例）—— 认可这条规则吗？
   它不改任何用户可见行为，但**不定死就没有稳定的 `video_no`**；如果你希望别的口径（例如"同毫秒时后加入的算 1 号"），要说，因为那会让 MCP 编号跟着变。
4. §8.3 的用例清单是否照单生成（**生成测试文件、不动生产码、不自动跑**）。
5. 第 2 期是否立项；若立项，先回答 §4.1 的三个口径问题（尤其第三个：Agent 侧要不要能指名"第 N 次出现"）。
6. 主链剩余「导出 MP4」一段与本次无耦合，可在第 1 期后继续收口。

## 10. 执行记录（第 1 期已开工，2026-09-28）

**备份**：`~/Library/Application Support/MixCut/backup-20260928T105625Z`（store 三件套 + `Videos/` + `Thumbnails/`，66 MB；
备份副本自查 `pv=6 / ZVIDEO=4 / ZSEGMENT=9` 自洽）。改动前的 12 个源文件与 pbxproj 另存于 `.scratch/before/`。

**改了哪些文件**：
- 新增 `Sources/MixCutCore/ProjectVideoDedup.swift` —— 规则本体（分组、组内留最早、tie-break、编号、悬挂行 `untouched`）
- `MixCut/Models/Project.swift` —— `associatedVideos` / `videos` / `videoCount` / `videoNoByVideoID`，读取路径复用纯函数
- `MixCut/Models/ProjectVideo.swift` —— 新增**同步**幂等入口 `associate(project:video:in:)`
- `MixCut/App/MixCutApp.swift` —— 一次性清理 `dedupProjectVideoAssociations`（用 `mainContext`，挂在 `recoverFromDisk` 之后、孤儿 GC 之前）+ 3 处构造点改走 `associate`
- `MixCut/ViewModels/ImportViewModel.swift` —— 3 处构造点改走 `associate`；撤销回填按 `pv.id` 去重
- `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift` —— 自建 uniqueKeys 字典删除，改读 `project.videoNoByVideoID`（**原崩点**）
- `MixCut/ViewModels/SegmentLibraryViewModel.swift` —— `uniqueKeysWithValues` 改冲突策略 + 注释指名真修点
- `MixCut/Views/Import/ImportView.swift`、`Views/Schemes/SegmentPickerDrawer.swift`、`Services/MCP/MCPSegmentToolHandlers.swift` —— 旁路收口（手抄编号的三处归一）
- `MixCut/App/DebugSelfTest.swift` —— 构造点改走 `associate`
- `MixCut.xcodeproj/project.pbxproj` —— 手工加 4 处引用（BuildFile / FileReference / Group / Sources phase）
- 新增 `Tests/MixCutCoreTests/ProjectVideoDedupTests.swift`、`scripts/check_association_guards.sh`

**判据结果**：

| 判据 | 结果 |
|---|---|
| `swift test` 全量 | **238 通过**（原 223 + 新 15），无回归 |
| 非空洞性（变异探针） | 在 `.scratch/` 副本上把规则故意写错 3 次（留最新 / 忽略项目分组 / 编号从 0 起）⇒ TC-03/04/05/07/09/12/14/15 全部变红；探针目录已删 |
| TC-13 实测 | 1000 行 **0.006 秒**（判据用相对上界，不拿拍的毫秒数当结论） |
| `check_project_integrity.sh` | PASS 128 ↔ 128/128/128（新文件已进工程，36 条 MixCutCore 手工引用未损） |
| `check_association_guards.sh`（TC-19） | 现树 **20 PASS / 退出码 0**；把 `.scratch/before/` 的**改前快照**喂给同一脚本 ⇒ 退出码 **1**，红在 TC-19a（7 处裸构造）/19b/19c（2 处崩形）/19d（缺出口 + 3 处手抄排序）/19e/19f ⇒ 判据不是恒绿 |
| `xcodebuild` Debug | **BUILD SUCCEEDED** |
| 启动日志 | `关联去重：删除 1 条重复的项目↔视频关联（视频、分镜、磁盘文件均未改动）` |
| 概览同口径（§0.2 第 1 条） | 同一份日志自带红→绿对照：`09:55:54 ProjectOverview … videos=5` → 修复后 `11:13:48 videos=4`、`11:15:14 videos=4`；`segs=9` 不变。与 MCP 的 `videos` 条数、`SchemeListView` 的 `project.videoCount` 现已同源 |
| sqlite 复查 | `pv 6 → 5`、`group by ZPROJECT,ZVIDEO having c>1` 返回 **0 行**、`ZVIDEO=4`、`ZSEGMENT=9`、`Videos/` **4 项 / 61 MB** 前后不变 |
| 幂等（重启一次） | 第二次启动去重日志**仍只有 1 行**，未再动数据 |
| MCP `get_project` | `videos` 4 条、id 唯一、`video_no = [1,2,3,4]` 连续无跳号（修复前是 5 条含重复） |
| TC-17 回归肇因路径 | 新建临时项目，经 MCP 导入**同内容的两个不同文件名** ⇒ 只产生 **1 条关联**、0 个重复组，日志 `项目「TC17-关联幂等回归」已关联视频「视频库 (1).mp4」，幂等返回既有行（不重复挂载）`；临时项目已删除，`videos_deleted_globally: []`（没伤任何素材） |
| §0.1 下游消费者变化 | `delete_project` 的影响预览现在如实上报 `视频库 (2)`、`视频库 (4)` 会被全局删除（清理前那个视频有 2 行 ⇒ `count <= 1` 判定漏报）。**这是修正，不是回归** |

**没做到的部分（要说清，不算已验收）**：
1. ~~「点分镜素材库不崩」~~ → **用户已实测通过（2026-09-28）**：打开「测试」项目点分镜素材库，9 条分镜正常显示、不退出。
2. ~~TC-18 撤销路径~~ → **用户已实测通过（2026-09-28）**：删除视频 → 撤销，列表稳定在 4，未复现重复。
3. **TC-20 跨 24h 的孤儿 GC 复查**仍待办：下次跨过阈值启动后再数一次 `Videos/`（现在 4 项 / 61 MB）。
   这是唯一还开着的判据 —— 它防的是"误删最后一个关联 → 一天后文件被 GC 收走"这种延迟显形的失败。

**第 1 期状态：已落地并通过验收（除 TC-20 延迟复查）**。备份保留在 `backup-20260928T105625Z`，`.scratch/before/` 保留代码级回滚副本，别急着删。

**过程中的误判（留档）**：
- 守卫脚本自己有三处判据写错，全是"整文件扫 + 期望值拍脑袋"这一类：TC-19a 期望裸构造归零（工厂本体那 1 处必须允许）、
  TC-19e 期望恰好调 1 次（读取路径会调两次同一个纯函数，重点是**别出现第二份规则**而不是次数）、
  TC-19f 在整个 `MixCutApp.swift` 里扫 `ModelContext(container)` —— 会把别的迁移的既有写法算成本次违规（假红），
  同时漏掉"清理函数自己用了子上下文"（假绿）⇒ 改成**函数体内取判据 + 挂载顺序比对**，并加"不得越界删 Video/Segment/磁盘"的反向断言。
- `Project.segmentCount` 第一版写成 `reduce(0.0) … .let { Int($0) }`（无意义且依赖不存在的方法），编译前已改回整数累加。
- 计划原写"沿用 md5(name) 的确定性 ID 先例"—— 实测现有 pbxproj 的 ID **并不匹配** `generate_xcodeproj.py` 的 md5 方案
  ⇒ 再次印证工程文件是手工维护的权威件；本次用带前缀的 md5 生成新 ID 前先验证了全文件唯一。
- 变异探针（临时改生产码证明测试会红）被权限层拦下 ⇒ 按规矩不绕过，改用"把改前快照喂给同一判据"的等效自证。

## 11. 顺带收口：主链最后一段「分镜 → 导出成片」（2026-09-28，§9 第 6 条）

全程走 App 自带的本地 MCP（`POST 127.0.0.1:8787/mcp`），即用户入口，不是我旁路调函数。

| 步骤 | 结果 |
|---|---|
| `export_segments`（段 1、2） | `state:completed`、`succeeded:2 / failed:[]` → `1_视频库 (1).mp4`(3.1 MB)、`2_…`(6.0 MB)；ffprobe：h264 540×960@30 + aac，时长 **3.066667 / 5.800000**，与分镜 `duration_sec` 完全一致 |
| `create_custom_scheme`（9 段**乱序**：索引 2,0,4,1,8,3,7,5,6） | 回 `segment_count:9`、`total_duration_sec:38.466664221022015`；`list_schemes` 的 `segment_indexes` 确实是乱序 `[seg_003, seg_001, seg_005, …]` |
| `export_scheme` | 产出 `自定义组合_1_主链验收-乱序9段.mp4`（49 MB），视频轨 **1156 帧 / 38.5333 秒**，h264 540×960@30 + aac |
| **拼接顺序是否真按方案走**（这条最容易被"时长对了"糊过去） | 把候选段各自单独导出来，再用同一时刻的帧做 SSIM：成片 t=1.0s vs 乱序**首位**(段3) **0.9796**、vs 段1 **0.5731**；成片 t=5.6s（首位 4.6s 之后的第 1 秒）vs 段1 **0.9397**、vs 段3 **0.5733** ⇒ 前两个位置都按给定顺序落位 |

**三个实测特征，别误报成"完全相等"**：
1. 成片视频轨 **1156 帧**，而按各段 `end_frame - start_frame` 累加期望 **1154 帧**（+2 帧 = 0.067 秒）—— 逐段编码的边界取整，不影响播放，
   但"帧数必须等于各段之和"这种判据本身是错的。
2. **容器时长以音轨为准**：`format=duration` 给 38.8023 秒，比视频轨的 38.5333 长 ~0.27 秒（AAC priming）
   ⇒ 验收导出要**分别读视频轨与容器**；拿 `format=duration` 去对"各段时长之和"会得出"多剪了 0.3 秒"的错误结论。
3. `output_dir` 必须**事先存在**，否则 MCP 回 `INVALID_ARGUMENT「选择的位置不存在或不是文件夹」`（它不自动建目录）。

**主链状态**：导入 → ffprobe/场景检测 → ASR → AI 分镜 → 组方案 → 导出成片，**六段全部在本机跑通且有产物**。
仍开着的两件：① 本计划 §10 的 **TC-20**（跨 24h 后复查 `Videos/` 仍为 4 项）；
② 「回归验证-2026-09-28」项目 AI 返回 **0 字符**（`ai-fail` 产物 0 字节，日志写成"max_tokens 截断"是误导文案）—— AI 侧独立问题，与本次修复无关。
产物留在 `.scratch/export/`（含 49 MB 成片），要看直接打开；不需要了我再清。
