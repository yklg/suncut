# 跨关系边界的读取没人结算：tombstone 崩溃第二起（to-one → `Project.id`）收口计划

状态：**v1.14（刀 2 已收进事务中心并接完结算链；17:00:30 抓到第三起同族现场 —— 崩在**已过 `live` 门**的那一行 ⇒ §4 的析取判据被证"不充分"，方案退回根因层重开）**。
本案根因**仍未定**，但追法已经从"造相位"转到"有现场了"：崩点行、二进制 UUID、atos 行号、崩溃前 13 秒的日志全部对得上（§27）。
刀 9 防静默丢归属、刀 2 补"库里删了界面还拿着"这两条一致性缺口仍是有价值的收口，但**都不是那次 SIGTRAP 的因果修复**；十二格有效读数无一复现的差额，现在指向"跨实例遗留的悬空归属边 + 全新 identity map"这一格（未实测）。
已闭合：门 4b 改册 41→47、G18、**G19 唯一发布口**、**GC-01~07 台账判据**、**UG-G09+M9 中心代广播**、**格 ⑮ 六腿（含变异对照）**、宽限期 6 条链接入 + `scripts/verify_graph_broadcast.sh`。
未闭合：**格 ⑯（悬空边复现）**、悬空 owner 的行数（只读 SQL 待用户跑）、第三信号选型（三档候选待评审）、真机 T-0 其余腿、其余 12 条 to-one 边的入边结算、11 行非宽限期直删。

| 版本 | 变化 |
|---|---|
| v1 | 初版。architecture-first-fix 出方案 → dev-expert 审查证伪：**三条承重断言被实测推翻并就地改正**（门槛判据选型 / `liveID` 签名 / 存量规模 15→19与40）；顺带翻出 MCP 删除链一处**现役**墓碑窗口 |
| v1.1 | **本轮审查（architecture-first-fix 审查模式）判「需返工」，五处升级**：① 刀 9 从「只结算 `ownerProject` 一条边」升为**13 条边数据驱动的通用结算**（否则余 12 条边仍属遮盖）；② `GraphChange` **下沉 `MixCutCore`**（原设计 Utilities 返回 App 层类型 = 依赖逆流，且广播回滚后成幽灵代码），顺带推翻前案 §3 刀 2 的落点规定；③ 穷尽性判据从文件级升**计数级** + keypath 走带理由允许清单；④ 抓出方案自己的**第四份 associations 拍平**（该方案目的是消除重复，却准备再拷一份）⇒ 改为复用/上提既有唯一出口；⑤ 实测查穿并改写 §8 那条我未证就断定的禁令（`SchemaGuard.swift:75` → `classifySchemaChange` → `stages=[]` → 拒开库），并补「合法路径 = 加 custom MigrationStage」；另新增两颗门冲突面（`check_navigation_readiness_guards.sh:106/:140/:88`、`check_association_guards.sh:67-68/:76`）与 V-B1>0 的历史数据修复工序 |
| v1.2 | **tech-solution-review A 类评审：判「有条件落地」，2 条 P0 阻断已就地吸收**（详见 §16）：矩阵 4 格 → **5 格**（补「子 context 删 + mainContext 已 fault」，实测本仓确有 `MixCutApp.swift:354/398/427` 三处独立 context 且 `:363` 真删）；刀 8 新增**读取分档**（渲染型可跳过 / **产出型必须 throw**）并定下「先拆 `MCPSegmentToolHandlers.swift:509/:548` 的 `?? UUID()` 随机兜底、再铺门槛」的顺序硬约束；另收 3 条 P1（`safeSave` 失败档、结算表与禁词表逐条对账、readiness 锚点同文件冲突防呆） |
| v1.3 | **测试轮元守卫组已落码并实测**（§18）：门 5 `ToOneReadScan` + 7 条用例并进既有 `TombstoneReadGuardTests.swift`（取样面助手是 file-private ⇒ 另起文件等于重抄扫描器，已改判）。`swift test --filter` **rc=0，17 条 = 13 绿 + 4 红钉 + 2 skip**。守卫实读把 §5 的「40 处」订正为 **43 处 / 41 键 / 12 文件**，并把随机 `UUID()` 兜底从我说的 2 处订正为 **5 处**（4 处归属键 + 1 处语义不同的占位）|
| v1.4 | **刀 8 前置工序落地（§19，生产码首次改动）**：拆掉 4 处归属/分组键的 `?? UUID()` 随机兜底 —— `AgentJob.projectID` 升为 `UUID?`（让"归属不明"可表达）、`get_job` 的 `project_id` 可为 `null`（键仍在，契约不破）、新 `jobProjectID(explicit:segments:)` 优先吃调用方 `project_id`。**顺带修掉一个真缺陷**：变体生成里孤立分镜以前被随机键自成一组再 `guard…continue` 静默丢弃（结果少条目却报成功），现逐条显式记失败。实测：守卫 17 条 / **红钉 4→2**、MCP 31 条、`xcodebuild` BUILD SUCCEEDED、五颗门 rc=0 |
| v1.5 | **刀 8 落地（§20）**：`ModelContextExtension` 新增 `isGoneFromGraph`（两信号析取）与 `live` 过门原语；崩点文件 `SegmentPickerDrawer` 8 处跨边读全部过门 + `.task(id: project.live?.id)` + header 与网格同判据；上游 `SchemeDetailView:39/52` 过门；`liveSegment` 收编到原语。两张名册走重生成回填（门 5 **43→35 处**、抽屉归零；门 4a 总数不变仅一行文本跟随）。**BUILD SUCCEEDED、五颗门 rc=0、17 条守卫通过（红钉 2）**。全量 550 条里 1 条真失败**归属会话前的未提交改动**（`HTTPRequestParserTests.swift:79` 夹具与断言矛盾），非本次引入 |
| v1.6 | **判据矩阵实跑（§21）**：活入口落在 `DebugSelfTest`，走 `MIXCUT_DEBUG_APP_SUPPORT_ROOT` + 内存容器，**没碰用户库**。7 格读数把两件事钉死：① **析取判据是必要的**（①⑥ 只有 `isDeleted` 真、②③ 只有 `modelContext == nil` 真，单信号各漏两格；仓里用久了的 `isDroppedFromContext` 正落在漏 ①⑥ 那一侧）；② **七格无一复现 SIGTRAP** ⇒ §1.1 的"稳定复现"降级为推断，剩 ⑧（通知驱动读）/⑨（有盘 scratch store）两格未做。另有一项超预期的收获：④ 显示 `delete+save` 后框架**自己**把 `Video.ownerProject` 置 nil，配合 once 台账永不二次回填 ⇒ **每删一次项目就永久抹掉一批视频的导入归属** ⇒ 刀 9 的动机从"防崩"改判为"防静默丢数据"，优先级提高，且 §7 的 V-B1 判据要换成数 `ZOWNERPROJECT IS NULL` |
| v1.7 | **矩阵扩到十格并全跑完（§22）**：先认一次假阴性 —— 第⑧格第一版报「通知没触发」是 harness 缺陷（容器随函数返回被释放 + 同步读 `fired`），修好后仍不触发，但那只能说明**纯 SwiftData 层够不到那一拍**，不证明它安全。有盘格（②′④′⑥′）+ 换全新 context 重新 fetch 的 fault 路径（⑩′）全部不 trap ⇒ **十格无一复现**，"读已删对象的持久标量即崩"这个机理模型被证伪，§1.1 的稳定复现说法作废。嫌疑收窄到 ⑦（存储层批删，本轮调用抛错未测成，而前案刀 3 正好说它会"制造更多死对象"）与 save 失败的半完成态。刀 8 保留但改口径：**不是本案根因修复** |
| v1.8 | **追完 ⑦ 与 ⑬，排除法走到头（§23）**：⑦ 的抛因查清 —— `Constraint trigger violation: mandatory OTO nullify inverse on ProjectVideo/video`，即存储层批删在这套 schema 上**根本不可用**（⑫′ 证明批删后 `Project` 数仍为 2，压根没生效）⇒ ⑦ 被排除，并反证真实删除只能走 `delete(object)`；顺带修掉我自己一处 `(try? …) != nil` 的静默吞错（正是它让我第一轮只报得出"成功=false"）。⑬（释放 container 后重开，全新 identity map）：`Project 数=1`、跨边 `ownerProject=nil`、不崩 ⇒ 连"悬空边重新 fault"这条也被排除，副产品是**盘上外键在 save 时就已被清** ⇒ §7 那条查悬空 FK 的 V-B1 属问错问题，改数 `ZOWNERPROJECT IS NULL`。十二格有效读数全不 trap ⇒ **本案根因仍未定**，追法从"造相位"转"抓现场" |
| v1.9 | **刀 9 落地（§24）**：删项目收成唯一咽喉 deleteProjectSettlingOwnerEdges（结算入边 → delete → **中间 save** → 补删孤儿视频），两处复制粘贴实现删除。功能验证格 ⑭ 当场抓到我引进的真 bug：把旧实现两次 save 合成一次后，cascade 尚未落盘、video.projectVideos.isEmpty 恒 false ⇒ 孤儿视频一颗都判不出（修复前 2 颗全留、连带删为空；修复后 [IT-solo] 被删、⑭ 转绿）。门 4b 改册 41→47 并新增 G18 钉住咽喉内 4 处裸 delete()（门 4b 的 regex 看不见它们）；TC-19a 不开豁免，改让自检走 associate 工厂。六颗门 rc=0、守卫 18 条（2 红钉）、MCP/归属 36 条通过 |
| v1.10 | **刀 2 广播机制落地（§25）**：`.mixCutDataDidUndo` 升为可带 `GraphChange` 载荷（类型落 `MixCutCore`，照前案 v1.8 勘误）；唯一发布口 `GraphBroadcast`（不可剪枝⇒自动降为无载荷 + `isBroadcasting` 重入闸）、观察者第一行分叉只剪枝不 `loadXXX`、⌘Z/⇧⌘Z 与 MCP 的裸 post 全部并进 ⇒ 全仓该通道的 `post(` 恰好 1 处。新增 **G19** 钉"发布口唯一/观察者唯一/三条承重写法逐字"，新增 **GC-01~07** 判据组。**自查抓到自己判据里的假档**：`video` 名列 prunable 却没有任何剪枝消费者 ⇒ "只删视频"会被判可剪、什么也没剪还跳过全量重载 ⇒ `isPrunable` 补第三条合取（带 video 必须带 project），GC-07 钉四种形状。另补 §24 欠的一次 G18 改册（`delete(video.segments)`→快照后 `delete(segments)`）。实测：GC 7 绿、守卫 19 条（红钉仍 2）、全量 559 条（唯一真失败仍是遗留的 `HTTPRequestParserTests:79`）、`BUILD SUCCEEDED ×2`、六颗门 rc=0。**逐条 UI 删除链的接入是下一批**（机制已就位，22 行裸 delete 分布在 6 个文件） |
| v1.11 | **刀 2 续批：广播口收进事务中心 + 宽限期链全部接入（§26）**：`PendingDeletionCenter.schedule` 的 commit 闭包改为**交回 `GraphChange`**，真删落地后由中心统一广播（空台账不发 ⇒ 不把每条删除退化成全量重载）；删视频 / 单删分镜 / 批删分镜三条链从此交 id，删项目链的广播也搬进中心，删策略与删方案**刻意交回空台账**（无第二双手可剪，理由在册）。本批我自己引进又被实测抓走的**两个窗口**：① 广播早于"登记新事务"⇒ 观察者里一句 `flushNow()` 会把刚 arm 的事务了结成一次空调用，**用户那次删除既不真删也不可撤销**（新格 ⑮ 的 F 腿，变异读数 `B commit 0 次`、还原后 `1 次`）；② 重入闸原先"丢弃嵌套"的理由站不住（嵌套那次往往带着 flushNow 顺带真删的新 id）⇒ 改**排空队列**，C 腿实测 `投递 2 次`。判据口径改为"**有没有人接得住**"：`ProjectVideo`/`SchemeSegment`/`SegmentDub` 不入台账（无消费者），`.video` 只在删项目链里顺带。新增 **UG-G09 + 变异腿 M9**、G19 承重锚跟改。实测：格 ⑮ 六腿通过（含反向对照）、559 条（真失败仅遗留 1 条）、九条 undo 自证逐条变红、六颗门 rc=0、`BUILD SUCCEEDED ×4` |
| v1.12 | **三步验收腿收成一支脚本 `scripts/verify_graph_broadcast.sh`**（§26 末）：① 格 ⑮ 自动跑（并把 `B commit 0 次` 直接判 FAIL = §26 第一个窗口复发）② T-0 由你动手删、脚本读日志增量判"一次删除只投一次 / 结算行数 / 嵌套入队"，像素级那条明写判不了 ③ `ZOWNERPROJECT IS NULL` **默认只打印**，代跑要你输入 `run` 且先确认应用已退出（本仓纪律：工具不开活库）。实测两条腿 rc=0；`check_project_integrity.sh` 的变量边界门抓到我自己一处 `$REPORT）`，已改 `${REPORT}`；同轮它对 `scripts/mcp_smoke_test.sh:69/:120` 报红 —— 那是你会话期在改的文件（git M），未动 |
| v1.13 | **勘误：验证脚本自己产出过一次假判据**（§26「勘误 v1.13」）。你实跑时步骤 ② 报 `剪枝 0 行 ⇒ 有链没交台账` + `[GraphSettle] 0 行`，两条都是**脚本错**：等待写成 `read -r _ "提示语"` ⇒ bash 把提示串当变量名，报错但**根本不等待**，没等你删就读完了日志。三处改法：提示语走 `read -r -p`；非交互终端直接跳过 ② 且不产判据；「没采到证据」与「代码不符」分口径，剪枝行数改为与你申报的真实删除次数对账（非数字回落默认，避免 `-eq` 语法错静默跳过整棵判据）。教训与本项目纪律同源：**验证器出错比没有验证器更坏**，它会把人引去改本来正确的码。附带：① 在你机上独立复现通过（六腿 + `B commit 1 次`） |
| v1.14 | **🔴 现场抓到了，而且推翻本计划两条既有结论（§27）**：17:00:30 第三起同族 SIGTRAP，`Project.id.getter` ← `closure #3 in SegmentPickerDrawer.rebuild()`，`atos` 定到 **`SegmentPickerDrawer.swift:118`** —— 那一行**正是刀 8 的 `ownerProject.live?.id` 过门写法**；崩的二进制 UUID 与 DerivedData 16:26 构建逐字相同 ⇒ 门确实在里面。⇒ ① **`isGoneFromGraph` 的"充分性"作废**（§4 自写的判定条件"两信号都说活着却 trap"今天被真机兑现，D1 只剩"必要"）；② §23 那句"盘上外键 save 时已被清 ⇒ V-B1 问错问题"要重开 —— 本实例整段日志没有一次删项目（无 `[GraphSettle]`），却仍 fault 出不存在的 `Project` ⇒ 悬空边来自**库里的遗留**（前两实例 16:48/16:49 那 18 次 `删项目《GUARD-*》`，全部"改指 0、置空 0、连带 0"）。同轮正面读数：§26 的广播接线没问题 —— 17:00:15 删视频 ⇒ **一行** `[GraphPrune] 剪枝 segs=7`、剩余 33→26，崩点与它无因果。下一步按 §4 自己写的规矩走：先取悬空行数（只读 SQL，交用户）、补格 ⑯（SQL 造悬空边 + 重开 container，这是 ①-⑭ 唯一没覆盖的相位、也是本机复现 SIGTRAP 的头号候选），第三信号三档候选（`===` 活 fetch 成员判定 / `registeredModel(for:)` / 目录键改 `PersistentIdentifier`）一律**先过评审再动码**；明令禁止 `try?`／吞异常／retry 糊 |

关联案：`2026-10-03-tombstone-read-after-real-delete.md`（同族第一起，崩 `Segment.id.getter`，v1.6）。
本案是它的**第二起**，并且证明那份计划 §3 刀 5 自认的效力上限（「to-one 读取不拦」）**不是可接受残留，是真实 hazard**。
本案 §17.3 的 **E2E 真机列（T-0/T-1/T-2）** 由 `2026-10-04-mac2-ui-smoke-harness.md` 承接首期地基；该案首期只到导航冒烟，T-* 三格仍空，且其 TG-INV-* 认领**等你 §4 五格矩阵定稿**。

---

## 0. 要解决的问题

SunCut 0.11.0 Debug 于 2026-10-04 11:59:33 崩溃：`EXC_BREAKPOINT (SIGTRAP)`，主线程 Thread 0，
栈：SwiftUI 异步续体 → `closure #2 in SegmentPickerDrawer.body.getter`(`SegmentPickerDrawer.swift:90`)
→ `rebuild()`(`:106`) → `Collection.map` → `closure #3 in rebuild()`(`:106`)
→ **`Project.id.getter`**（@Model 宏生成）→ 3 层 SwiftData 内部帧 → `libswiftCore _assertionFailure`。

崩点原文（`MixCut/Views/Schemes/SegmentPickerDrawer.swift:106`）：

```swift
self.catalogVideos = videos.map { CatalogVideo(id: $0.id, ownerProjectID: $0.ownerProject?.id) }
```

一句话根因：**穿过一条没有删除规则的 to-one 边（`Video.ownerProject`），读到一颗已被真删的 `Project` 的持久标量。**

---

## 1. 取证（都能在机器上复核，标注实测/推断）

### 1.1 触发链（实测，逐行）

1. `MixCut/ViewModels/ProjectViewModel.swift:266 context.delete(project)` —— `Project` 的三条
   `@Relationship(deleteRule: .cascade)`（`Project.swift:28/31/34`）带走 `ProjectVideo`/`MixStrategy`/`MixScheme`/`SchemeSegment`，
   **但 `Video` 不在级联范围内**，由 `:270 for video in referencedVideos where video.projectVideos.isEmpty` 手动补删。
2. ⇒ 被**其它项目**复用的 `Video` 活下来，而它的 `ownerProject`（`MixCut/Models/Video.swift:98`）仍指着那颗死 `Project`。
3. `MixCut/Views/Schemes/SegmentPickerDrawer.swift:99` 是**全库** `Video` fetch（不是当前项目的），
   于是在**另一个项目**的方案详情里打开抽屉就扫得到它 ⇒ 不是窄竞态。
4. `MixCut/Views/Shared/PendingDeletionCenter.swift:34 graceSeconds = 5`（工作区未提交，从 300 改回 5）
   ⇒ 点删除 5 秒后 ticker（`:132-150`）落地真删，界面还开着 ⇒ 可稳定复现。
5. `:90` 的 `.task(id: project.id) { rebuild() }` 把这次读取放进**主 actor 的 Task 续体**里，
   与真删定时器排在同一条 queue 上，先后次序不由视图控制。

### 1.2 守卫为什么是绿的（实测）

- `Tests/MixCutCoreTests/TombstoneReadGuardTests.swift:24` 把效力上限写死：「拦的是从模型对象上取**关系集合**这一次读」。
- 禁词两条来源都只收**集合**：`:109`（`@Relationship … var X:`）与 `:124`（返回 `[模型类型]` 的计算属性）。
  `id` 是 `@Attribute(.unique) var id: UUID`（`Project.swift:17`），从来不在表里。
- 基线里 `SegmentPickerDrawer.swift` 只登记了 `:359` 一条（`:46` 的 `schemeSegments`）
  ⇒ `:105/:106/:108/:111-112` 这 4 条 to-one 跨越门**结构上看不见**。**门绿而崩点在册。**

### 1.3 SDK 一手取证（本轮新增，`MacOSX15.5.sdk/…/SwiftData.swiftinterface`）

| 事实 | 位置 | 对方案的影响 |
|---|---|---|
| `PersistentModel` 有一等 API **`isDeleted: Bool`** | `:505`（`@available(macOS 14, iOS 17…)` 那颗 extension 内） | 项目 `MACOSX_DEPLOYMENT_TARGET = 14.0`（实测 pbxproj）⇒ 可用。全仓 `isDeleted`/`persistentModelID`/`registeredModel` **0 处使用**，即本仓的「死对象」判据一直是间接代理 `modelContext == nil` |
| 同一颗 extension 自带 **`var id: PersistentIdentifier`** | `:500` | 而 `Project.swift:16-17`/`Video.swift:30-31` 各自声明 `var id: UUID` + 显式 `: Identifiable` ⇒ `Self.ID` 在两类模型间**类型不一致** ⇒ 任何「泛型门槛直接吐 id」的签名都不可取（见 §3 刀 8） |
| `delete<T>(_ model: T)` 非抛错、且**没有** Sequence 重载 | `:402`（对比 `:401` 的 `delete(model:where:)`） | 印证前案刀 3 那颗 `delete<S: Sequence>` 重载不与 SDK 歧义 |

**`isDeleted` 不能单独当判据**（外部取证，见文末来源）：删除先是**标记**，物理移除要等 save；
**未 save 期间该记录仍会出现在 fetch 结果里**；且**其它引用可能让 `isDeleted` 在持久化后翻回 false**——
因此连官方教程口径都不建议拿它驱动 SwiftUI 交互态（`disabled()`）。
⇒ 门槛取**两个信号的析取**（fail-closed），并强制做 §4 的四态矩阵实测。

### 1.4 写侧的两份实现（实测，比前案判断更硬）

- `ProjectViewModel.swift:253-284` —— 走 5 秒宽限、**不发任何失效通知**。
- `MixCut/Services/MCP/MCPToolHandlers.swift:592-628` —— 即刻真删。`:611` 的注释**自证是复制粘贴**：
  「与 `ProjectViewModel.deleteProject` 的 commit 逻辑一致，但立即执行、无撤销」；`:622` 发 `notifyUIReload()`（无载荷全量重载）。
- ⚠️ **翻出来的现役缺陷**：MCP 那份在 `:612 context.delete(project)` **之后**才读 `:615 video.projectVideos.isEmpty`
  与 `:616 Array(video.segments)` ⇒ 这条链**现在就带一次「delete 之后读关系」**的墓碑窗口，未崩属时序运气。
- 全仓 18 处 `.mixCutDataDidUndo` 发布：**只来自 ⌘Z/⇧⌘Z 与 MCP**；UI 自己的 13 处真删站点一次都不发（前案 §1.4④ 已记，本案再证一次）。

### 1.5 模型层的结构性缺口（实测穷举）

`MixCut/Models/*.swift` 里**恰好 13 条 to-one 边，全部 optional、零 `@Relationship`、零删除规则**：
`Project.swift:26 product`｜`Video.swift:98 ownerProject`｜`ProjectVideo.swift:10 project / :11 video`｜
`Segment.swift:109 video`｜`SchemeSegment.swift:12 scheme / :13 segment`｜`MixScheme.swift:21 strategy / :22 project`｜
`MixStrategy.swift:17 project`｜`SegmentDub.swift:9 segment`｜`PhysicalShot.swift:10 parentSegment`｜`ShotVariant.swift:20 shot`。
⇒ 「它指向的对象还活着吗」不是类型能表达的问题，只能在运行时赌；本案是第一张输掉的牌，另外 12 条同形。

---

## 2. 要立的不变量（补前案 §2 那条）

> **任何一次跨 SwiftData 关系边界的读取，必须先证明目标仍在图上（单一咽喉判据），才准 fault 任何持久属性；
> 任何一次真删，必须同时结算「别人指向我」的边，并走那一条既有通道让持有者失效。**

前案的不变量只管住了「读**集合**」与「删除方交出被删 id」两条；本案补上正交的两条轴：**跨边读**、**入边结算**。

---

## 3. 三刀（编号接前案七刀之后；全部落在**已有文件**）

### 刀 8｜读侧咽喉（`MixCut/Utilities/ModelContextExtension.swift`）

```swift
extension PersistentModel {
    /// 「图已认这颗对象没了」的两个独立信号，任一成立即视为不可读（保守档）。
    var isGoneFromGraph: Bool { isDeleted || modelContext == nil }
    /// 跨关系边界的唯一过门写法：先证明活着，才准 fault 任何持久属性。
    var live: Self? { isGoneFromGraph ? nil : self }
}
extension Optional where Wrapped: PersistentModel { var live: Wrapped? { flatMap(\.live) } }
```

- **刻意不做 `liveID`**：§1.3 第二条给出反例（`Self.ID` 跨模型漂移）。门槛只返回对象，`.id` 门后读。
- 崩点改法：`ownerProjectID: $0.ownerProject.live?.id`；同函数 `:105/:108/:111-112` 与 `:46/:53/:116` 一并过门；
  `:90` 改 `.task(id: project.ifLive?.id)`（仍留在 body 最外层，守 `CLAUDE.md` 那条陷阱，`:89` 注释补一句「门后取值」）。
- `SchemeDetailView.swift:39` 的 `scheme.project` 是崩点的**上游**（未设防跨越并喂进抽屉），同批过门。
- `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift:779-782` 的 `liveSegment`（调用点 `:749/:765`）改建立在门槛原语上，
  不留 `ModelContextExtension.swift:11` 自己警告过的「第五处写法」。
- `SegmentPickerDrawer.swift:126` header 计数与门后列表**同源化**（否则筛掉死引用后数字说假话）。
- 🚫 **门槛的适用边界（必须写进真源注释，防实施时顺手全改）**：门槛只管「**读持久属性**」这条路径。
  `readiness` 禁点与缩略图预热那两处**已经是 UUID 值语义**，不许改写成门后取值 ——
  `scripts/check_navigation_readiness_guards.sh:106`（G13a）逐字锚 `allowsHitTesting(.*readiness\.holdsData(for: project\.id)` **恰好 2 处**、
  `:140`（G10b）锚 `shared\.prewarm(paths: .*, for: project\.id)` **恰好 3 处**，
  且 `holdsData(for projectID: UUID)` 本身由 `:88`（G04b）锚死签名。
  改写的后果有两层：① 发版门当场红（计数归零）；② 把「能不能点 / 预热键」建立在可为 nil 的门后值上 = **交互语义漂移**（预热键漂移会静默丢缓存命中）。
  ⇒ 判据：**输入已经是 id 的地方不设门，输入是对象的地方才设门**。
- ⚠️ **P0 前置：门槛必须按「读取分档」落地，不许一把梭**（tech-solution-review 抓出，判「有条件落地」的两条阻断之一）。
  门槛把「崩」变成 nil，这对**渲染型**读取是对的（画不出就不画），对**产出型**读取是**更坏的失败**（静默少东西 / 错归属）：
  - `渲染型`（可跳过）：`SegmentPickerDrawer`、各 View 的 body/`.task`。
  - `产出型`（**必须显式 throw，不许 `?? 兜底`**）：导出与合成链。实测反例已在仓里：
    `MixCut/Services/MCP/MCPSegmentToolHandlers.swift:509`（`?? UUID()` 当 job 归属键，消费方 `MCPToolHandlers.swift:314` 上报 / `:333` 回查项目）、
    `:548`（`?? UUID()` 当导出分组键 ⇒ 分组被打散）、`MixCut/Views/Export/ExportView.swift:973/1008`（跨 `segment?.video` 选片）。
  ⇒ **顺序硬约束：先把这几处随机兜底拆成 `guard let … else { throw }`，再让产出型链路过门**；
  否则本案会把一次 SIGTRAP 换成「Agent 导出报告里 project_id 是个不存在的 UUID」——崩溃至少会拦住人。
- 收益判据：把死 owner 折算成 nil **不是发明兜底** —— `Sources/MixCutCore/SegmentPickerCatalog.swift:157-168`（R4：
  owner 缺失/悬空 → 回退最早可解析关联 → 默认产品）与 `Tests/MixCutCoreTests/SegmentPickerCatalogTests.swift:87-99`
  （C3 用例正测「ownerProject 指向不存在的项目」）已定义并单测这条语义。

### 刀 9｜写侧入边结算（**通用机制**，不是给一条边写特例）

- **为什么必须通用**：根因是「入边无人结算」，而 to-one 边共 **13 条**（§1.5 实测穷举）。
  只给 `ownerProject` 写特例 ⇒ 剩下 12 条边照样生产「活对象 → 死对象」这个非法状态，只是被刀 8 读成 nil 不崩 ——
  按本项目标尺那**仍是遮盖**。⇒ 结算做成数据驱动的通用件。
- **登记表 + 单一遍历**（禁写成 13 个 `switch` 分支，那会长成 switch-god）：
  在 `Sources/MixCutCore/` 登记一张「被删实体类型 →〔边所属实体、边名、结算策略〕」表，13 条边一次登记，
  **新增一条边只需加一行**；咽喉按表跑一遍泛型遍历。这张表与刀 10 的禁词第三来源**同源生成**（都从 `MixCut/Models/*.swift` 派生），
  不许两处各抄一份。
- 咽喉签名：`ModelContext.deleteAndSettle(_ model: some PersistentModel) -> GraphChange`（11 颗 `@Model` 共用一颗；
  可改站点 = 门 4b 名册那 **41 处 / 11 文件**，本轮先改 `Project` 那条链，其余逐批）。
- 顺序**写死在 API 里**（调用方无从倒置）：`guard !isGoneFromGraph` → **先按表结算入边** → `delete` →
  补删无引用行 → 一次 `safeSave()` → 返回变更集。
  🔴 结算必须早于 delete：`projectVideos` 是 cascade 删的（`Project.swift:28`），删完就再也查不到「还有哪些项目共享这颗视频」。
- `Project` 这条边的结算口径 = **repoint**（D2）：`===` 找入边（**推断**不 fault 持久列，交 §4 实测收口；
  不用 `#Predicate { $0.ownerProject?.id == … }`，它能否被译成 join **未实证**）→ 拍平 associations（排除待死项目）→
  `ProductOwnershipBackfill.ownerProjectIDByVideoID` → 回写。**规则本体不许在 App/Util 层重写**（`Sources/MixCutCore/ProductOwnershipBackfill.swift` 是唯一真源）。
- ⚠️ **不许新增第四份 associations 拍平**（v1 方案的自我矛盾，本轮审查抓出）：同一形状今天已有三处 ——
  `MixCut/Models/Project.swift:65-70`（`videoNoByVideoID` 内，被 `scripts/check_association_guards.sh:67-68` TC-19d 钉为**唯一出口**）、
  `MixCut/App/MixCutApp.swift:756-761`（启动回填）、`MixCut/Views/Schemes/SegmentPickerDrawer.swift:110-113`（抽屉拍平）。
  咽喉必须**复用/上提**那颗既有出口，而不是再拷一份 —— 否则这个「消除重复」的方案自己在制造第四份重复实现。
- **变更集类型下沉 `Sources/MixCutCore/`**（消依赖逆流）：`GraphChange` 做成纯值类型（实体类型 → id 集合，零 SwiftData 依赖），
  咽喉（Utilities）与广播（App）都只是它的使用方 ⇒ 依赖顺流；且按 D3 把广播回滚成无载荷时它仍有消费者
  （`[GraphPrune]` 日志、§4 断言），不留幽灵返回值。
  ⚠️ 这条**推翻前案 §3 刀 2「类型放 `ContentView.swift` 的扩展旁边」的落点规定**（`2026-10-03-…:142-143`），勘误已记进该文件 §14。
- 广播仍走**那一条**既有通道（不新建第二条）：`MixCut/App/ContentView.swift:12` 的 `.mixCutDataDidUndo` 加可选载荷 = 前案**刀 2**，
  本案把它从「第二批」提为**必要配套**（理由见 §5 二阶效应）。
- 两个站点先行改造：`ProjectViewModel.swift:253-284`、`MCPToolHandlers.swift:592-628`
  （后者顺带消掉 §1.4 那处「delete 之后才读关系」的**现役**窗口）。
- **`safeSave()` 失败必须有档**（评审 P1，四选一里选「放行 + 标记 + 上报」，禁"全降级为警告"）：
  咽喉内 `guard safeSave() else { MixLog.error("[GraphSettle] save-failed …"); return GraphChange(saveFailed: true, …) }` ——
  **不重试、不发广播**（发了会让界面剪枝与库不一致），调用方据 `saveFailed` 决定提示口径；
  与既有 `saveOrWarn`（`ModelContextExtension.swift:47-54`）语义对齐，**不再造第二套失败约定**。
- **结算表与守卫禁词表必须同源对账**（评审 P1，防「同一条判据两个住户」）：
  运行时结算表是 Swift 手写常量（正则派生不出运行时数据），故新增一条用例：
  从 `MixCut/Models/*.swift` 派生的 to-one 边集合必须与该表**逐条相等**（多 / 少 / 改名皆红），口径照门 4b 的 G12 名册对账范式。

### 刀 10｜守卫第三来源（`Tests/MixCutCoreTests/TombstoneReadGuardTests.swift`，Tests/ 自由）

- 禁词**第三条来源**：从 `MixCut/Models/*.swift` 派生 `var X: <Model>?$`（即 §1.5 那 13 条，实测与 G09「改名不绕过」同范式）。
- 门 token 白名单 = `live` / `isGoneFromGraph` / `isDroppedFromContext` / `liveSegment`。
- **两档强度（已拍板）**：硬半边只禁「新增未过门的跨越」（本轮即可全绿 ⇒ 可 strict）；
  存量按**宽口径 40 处 / 12 文件**建 xfail 名册（`withKnownIssue` 语义同 `:420-429`），逐批单调缩短。
- **必须复用 `classifyReceivers`(:147) 的逐文件三分**：实测反例 `SidebarView.swift:167/185` 的 `product`
  是 `:160` 的局部量而非关系属性，不三分即假红 —— 这正是前案 §3 刀 5「拦 to-one 会把门变成噪音」警告的解法。
- 前案**刀 6 追加腿**（文件级判据：视图文件里凡有模型对象进 body ⇒ 该文件必须 ≥1 处门）同批落地，
  但**文件级不够当穷尽性判据**（一个文件 10 处跨越只过 1 处也算绿 ⇒ 「所有跨边读取都过了门」这句话没有机械保证）。
  ⇒ 升级为**计数级**：按文件比对「跨边读取表达式数 : 门槛 token 数」，比值不达即红（名册单调缩短的口径同前案 G08）；
  keypath 形态（`ForEach(videos, id: \.video.id)`，token 级扫不到）单独进**带理由的允许清单**，沿用门 4a 既有惯例，不许混进恒绿。
- 🚫 **与另两颗门的互斥项**（新增边/新表中任何一处改动都要同时跑）：`scripts/check_navigation_readiness_guards.sh`
  （G04b/G10b/G13a 逐字锚 `project.id` 与 `holdsData(for projectID: UUID)`）与
  `scripts/check_association_guards.sh`（TC-19d 把 `Project.swift` 的 `var associatedVideos`/`var videoNoByVideoID` 各钉为**恰好 1 处**、
  `:76` 禁抽屉里出现 `projectVideos.compactMap`）⇒ 刀 8/9 的改写面必须绕开这些锚点，或**同步改册**，不得只改一边。
- ⚠️ **约束承载要补齐**：`scripts/check_schema_ledger_guards.sh` 的 SL-13（`:128-150`）取样面**只有
  `backfillProductOwnership` 那颗方法体**（`:133/:135-137`），对新增咽喉无效
  ⇒ 落地时必须把 SL-13 扩到 `deleteAndSettle`，否则「repoint 必须走纯函数」这句承诺没有守卫可红。

---

## 4. 🔴 前置硬门槛：判据矩阵（已实跑 7 格，读数与改判见 §21）

> 本节原样保留（v1 提出、v1.2 扩到五格的判据设计）。实际执行扩到 **7 格**并跑完，结论是两半：
> ① **析取判据得证**（①⑥ 只有 `isDeleted` 真、②③ 只有 `modelContext == nil` 真 ⇒ 单信号各漏两格），D1 维持；
> ② **七格无一复现 SIGTRAP** ⇒ 原判据门「未实测不得进刀 8」只兑现了一半：它选对了判据，
>    却没证明判据**充分**（死边确实存在，但在同步读相位不崩）。
> 缺的两格（⑧ 通知驱动读 / ⑨ 有盘 scratch store）+ ⑦ 重做，与由此引出的刀 9 改判，全记在 §21。

在 `MixCut/App/DebugSelfTest.swift`（已有文件，`:11-30` 的 env 派发约定）新增 `MIXCUT_SELFTEST_TOMBSTONE=1` 分支，
**自建 in-memory `ModelContainer(Schema(versionedSchema: AppSchemaV1.self))`**（不碰用户库），造 A/B 两项目 + 一颗共享 Video，
对五格各测三列：`isDeleted` / `modelContext == nil` / 读 `.id` 是否 trap。

| 格 | 场景 | 为什么必须测 |
|---|---|---|
| ① | `delete` 未 save | §1.3 取证：未 save 前记录仍在 fetch 里，`isDeleted` 相位未知 |
| ② | `delete` + `safeSave` | 本案崩点的相位 |
| ③ | 被 cascade 摘除（`ProjectVideo`/`SchemeSegment`） | **本仓零覆盖**（前案 CTX-01），门槛判据最大软肋 |
| ④ | 从活对象的 to-one 上 fault 出来的死者 | 本案的实际形状 |
| ⑤ | **子 context 删 + save，mainContext 里已 fault 的同一对象** | 本仓**确有**三处独立 context（`MixCutApp.swift:354/398/427`，其中 `:363` 真删 `SegmentDub`），且 `MixCutApp.swift:457-458` 自己记着「子上下文里删行，已 faulting 出来的关系不会同步移除」⇒ 这一格**析取判据可能双 false** |

**判定**：任一格出现「两信号都说活着、读 `.id` 却 trap」⇒ `isGoneFromGraph` 不成立 ⇒ 退回根因重新上溯，
**禁止用 `try?`／吞异常／加 retry 兜过去**（前案 §4 硬约束与本项目明令）。
⑤ 的预案（**不是兜底，是第三信号**）：门槛加第三条 `modelContext !== 期望的读写 context` 也算 gone
（本仓读写面应为 `container.mainContext`，见 `Segment.swift:446` 那句口径 —— 该口径与三处子 context 的矛盾属前案 CTX-01，另案收口，但矩阵必须先把这格测出来）。
顺带断言：① 结算后无对象仍指向死 Project；② `===` 找入边不 trap；③ 咽喉返回的变更集与实删 id 一致；
④ **产出型路径遇死对象必须 throw，不得掉进兜底值**（见刀 8 的分档）。

---

## 5. 存量真值（刀 8/10 的工作量口径，本轮实测自数）

- 严格口径 `.关系?.id` / `.关系?.name` = **19 处 / 6 文件**：
  `SegmentPickerDrawer:46,53,105,106,108,111,112,116`｜`SegmentVariantInspector:300,322,325,391`｜
  `ExportView:735,892,1016`｜`WelcomeView:69,80`｜`ProductPresentation:48`｜`SidebarView:264`
- 宽口径（穿过 to-one 读任意持久标量）= **40 处 / 12 文件**，另含
  `SchemeDetailView:72,252,318,339,533`｜`SegmentLibraryView:622,1068,1069,1170,1785,1849`｜
  `ShotEditSheet:13,115,264,315`｜`SplitSegmentSheet:23,123`｜`SegmentPropertiesSection:166`｜
  `CaptionTimingEditorSheet:23`｜`ExportView:891,973,1008`
- `.关系!.id` 形式 = **0 处**（实测）。
- ⇒ **二阶效应**（新增门槛必查）：门槛把「崩」变成「不显示」，而「未 save 期间记录仍在 fetch 里」
  ⇒ 屏上会出现**已删但可见**的对象（不崩、说假话）。这条落在刀 9 的广播上 ⇒ 广播从「加固」变为**必要配套**。

---

## 6. 决策记录（含撤销条件）

| # | 决策 | 理由 | 撤销条件 |
|---|---|---|---|
| D1 | 门槛判据 = `isDeleted \|\| modelContext == nil`（析取、fail-closed），并升 `isDroppedFromContext` 的注释为「两信号 + 矩阵读数」 | 单代理两侧都不完备（§1.3） | §4 矩阵显示某信号对本仓数据**恒 false** ⇒ 退回单判据并注明，不留死条件 |
| D2 | `ownerProject` 结算口径 = **repoint**（改指最早仍在世的合作项目），不置 nil | `LaunchSteps.swift:70` 的回填是 `.once(key: "didBackfillProductOwnership_v1")` 台账 ⇒ **置 nil 不会自愈**；repoint 与 nil 的目录输出逐条相同（R4 算的就是同一答案），却不破 `Video.swift:93-98`「导入事实」的文档 | 用户改判「nil 也要保留原值可追溯」⇒ 改走 B-null 并同步改写 `Video.swift:96` 那句「nil 仅可能出现在 backfill 之前」 |
| D3 | 范围 = 刀 8 + 刀 9 + 前案刀 2 全套（含 UI 13 处站点接线） | 只落刀 8 按本项目自己的标尺算**遮盖**（图上长期留着活→死边） | 刀 2 接线出现前案 §10 的**同栈递归**（`SegmentLibraryViewModel.swift:125` 首行 `flushNow()`）⇒ 刀 2 单独回滚为「一律无载荷」，刀 8/9 不受影响 |
| D4 | `graceSeconds` 不动（保持 5） | 它不是根因，只是把命中概率放大；被 `check_undo_guards.sh` UG-G04 钉住 | —— |
| D5 | **本仓不启用 `.ai-memory/`**，过程记忆与 Decision Record 一律写进本目录 `plans/*.md`（单一真源） | 避免与前案「活台账」约定形成两套记忆真源；`scripts/init_deploy.py` 会往本仓写 hooks，而本仓 `scripts/` 已有 8 颗自有门 | 出现跨工具/跨机交接需求 ⇒ 单点开启 `.ai-memory/handoff.md`，仍不建第二套决策日志 |

---

## 7. 验证

**本机机械**：`swift test --filter TombstoneReadGuardTests` → 全量 `swift test`（预登记 `passed/skipped/xfailed/总数` 四个数）；
`TOMBSTONE_DUMP_BASELINE=1 swift test --filter TombstoneReadGuardTests` 重生成基线后与表 `diff` 为空（**不手抄**）；
`SKIP_XCODEBUILD=1 scripts/check_project_integrity.sh`（169/169/169/169 守恒，本轮不新增 .swift）；
`xcodebuild -configuration Debug -derivedDataPath .scratch/dd`（SwiftData 宏只在 Xcode 侧编译）；
`scripts/check_undo_guards.sh` + `selftest_undo_guards.sh`（UG-G04 应仍绿）；`scripts/check_schema_ledger_guards.sh`（含 D5/刀 10 的 SL-13 扩面）；
`scripts/check_navigation_readiness_guards.sh` 与 `scripts/check_association_guards.sh`（**本轮新增的两颗冲突面**，见刀 8 的 🚫 边界与刀 10 的互斥项）；
`MIXCUT_SELFTEST_TOMBSTONE=1`（§4）。

**只能真机**（本仓无 test target，`Tests/` 里 `import SwiftData` 0 处）：
T-0 正证 = 开方案详情 → 开抽屉 → 删**另一个**项目（不撤销，等浮条了结）→ 滚动分镜网格 20 s ⇒ 不崩且 header 数字与网格条数一致；
T-1 同族 = 连删两条（第二条顶掉第一条，走 `PendingDeletionCenter.swift:76-77` 即刻真删支路）+ ⌘Z/⇧⌘Z，看 `[GraphPrune]`/`[GraphSettle]` 形状日志。

**需用户跑的一次核查**（决定刀 9 的等级，AI 不擅自打开活库：WAL 未 checkpoint，只读打开有副作用）：

```
sqlite3 "file:$HOME/Library/Application\ Support/Suncut/Suncut.store?mode=ro" \
  "SELECT COUNT(*) FROM ZVIDEO v LEFT JOIN ZPROJECT p ON v.ZOWNERPROJECT=p.Z_PK WHERE v.ZOWNERPROJECT IS NOT NULL AND p.Z_PK IS NULL;"
```

= 0 ⇒ 盘上已干净，刀 9 是加固；> 0 ⇒ **已悬空，重启后仍复发**，刀 9 优先于刀 8。

**若 V-B1 > 0 的后续工序（预先登记，别等崩了再想）**：那是一份**已经落盘的脏数据**，刀 9 的结算只治「以后的删除」，治不了历史行。
需要新增一次修复型 `LaunchStep`（`MixCut/App/LaunchSteps.swift` 台账 + 新的 cadence 版本键，
参照 `LaunchSteps.swift:70` 那颗 `didBackfillProductOwnership_v1` 的写法但**换全新键**，once 台账不可复用），
规则仍调 `ProductOwnershipBackfill`；且它属 schema 之外的数据写 ⇒ 必须在 `SchemaGuard` 备份门**之后**跑。

---

## 8. 明确不做

不新增 `MixCut/**.swift`、`Sources/MixCutCore/*.swift`（pbxproj 手工维护）；不改任何 `@Model` 属性类型、
不给 `ownerProject` 加 `@Relationship(deleteRule:)` / `@Transient` / 换成 `ownerProjectID: UUID?`
（**机理已实测，不是教条**：`MixCut/App/SchemaGuard.swift:75` 把 `|delete=<deleteRule>` 写进描述行，注释 `:55-56` 明列覆盖「删除规则」
⇒ 改一条边 = 一行消失 + 一行新增 ⇒ `classifySchemaChange`（`Sources/MixCutCore/SchemaFingerprint.swift:119-133`）判 `.destructive`
⇒ `isLightweightCompatible=false`，而 `AppMigrationPlan.stages=[]`（`MixCut/Models/SchemaVersions.swift:49`）⇒ 走**拒开库**分支。
**合法路径也存在**：哪天真要框架级 nullify，正解是同时补一个 custom `MigrationStage`（或让分类器识别「deleteRule-only 差异」），
而不是把这条禁令当不可商量的事 —— 那句话写在这里就是为了防止下一个人照抄成教条）；
不新建第二条广播通道；不吞异常、不加 retry、不注释断言；不做 C-全（30 个持有模型的 view struct 全量净化，风险不抵收益，
仅做 C-lite：`SegmentPickerDrawer.swift:18 onPick` 换 id 契约 + `SchemeDetailView.swift:81` 视图层真删挪进 VM ——
实测那两颗 VM 方法全仓只有 `SchemeDetailView.swift:94/103` 两个调用方，改动不外溢）；
`MixCutApp.swift:354/398/427` 三处独立 `ModelContext(container)`（前案 CTX-01）**另案**，不算本案已解决。

---

## 15. 审查轮记录（v1.1，architecture-first-fix 审查模式）与遗留待拍板

三条硬标尺**返工后复检**：

| 标尺 | v1 | v1.1 |
|---|---|---|
| 根因层级 | 过 | 过（且刀 9 泛化后不再只碰 1/13 条边） |
| 非遮盖 | **不过**（余 12 条边仍产非法状态） | **条件过**：以「表覆盖 13 条边 + 站点按名册逐批改完」为前提；站点未改完之前，未改的那些边仍属已知遮盖 ⇒ 必须留在风险条里，不得写进「已解决」 |
| 不引入耦合 + 提升性 | **不过**（`GraphChange` 逆流 + 幽灵返回值；且方案自带第四份重复拍平） | 过（类型下沉 Core、拍平复用唯一出口、表与守卫禁词同源生成） |

**仍需你拍板的两项**（我不擅自扩范围）：

1. **刀 9 的站点范围**：泛化咽喉的收益只有在**全部真删站点**都改走它之后才兑现；但把 41 处 / 11 文件一次改完属跨模块接口变更，
   门 4b 名册、豁免项、`check_project_integrity.sh` 都要同步重算。
   ⇒ 我的建议：本案先只改 `Project` 那条链（2 站点），**其余站点单独立批**，并在本案风险条显式记「N 条边 × M 个站点未收口 = 已知遮盖」。
2. **readiness / prewarm 这两类调用不设门**（刀 8 的 🚫 边界）：判据是「输入已是 UUID 值 ⇒ 不设门；输入是对象 ⇒ 才设门」。
   若你更倾向「一律过门」，则必须同步改 `check_navigation_readiness_guards.sh:88/:106/:140` 三处锚点，并重新定义「项目被删后禁点态」的语义 —— 那是**产品决策**，不是工程顺手活。

**停止条件**：§4 四态矩阵任一格不成立、或 §7 V-B1 > 0（需先走历史数据修复批）⇒ 本案三刀一律不落码。
（v1.2 订正：矩阵已扩为**五格**，新增第 ⑤ 格「子 context 删 + mainContext 已 fault」；停止条件同步以五格为准。）

---

## 16. 评审轮记录（v1.2，tech-solution-review A 类方案评审：判「有条件落地」，2 条 P0 已就地吸收）

| # | 评审发现 | 严重度 | 本文件处置 |
|---|---|---|---|
| 1 | §4 矩阵少「跨 context」那一格，而本仓**确有**三处独立 `ModelContext(container)`（`MixCutApp.swift:354/398/427`，`:363` 真删），且 `MixCutApp.swift:457-458` 记着该形状的后果 ⇒ 析取判据可能双 false | **P0 阻断** | §4 已扩为五格 + 备好第三信号预案（`modelContext !== 期望 context` 也算 gone） |
| 2 | 门槛铺到**产出型路径**会把 SIGTRAP 换成静默错数据：实测 `MCPSegmentToolHandlers.swift:509/:548` 的 `?? UUID()` 兜底与 `ExportView.swift:973/1008` | **P0 阻断** | 刀 8 新增「读取分档」条 + **顺序硬约束（先拆随机兜底，后铺门槛）**；IT-TOMB 增断言④ |
| 3 | 咽喉 `safeSave()` 失败无处置档 ⇒ 半完成态 | P1 | 刀 9 新增失败档（不重试 / 不发广播 / `saveFailed` 标记，复用 `saveOrWarn` 约定） |
| 4 | 运行时结算表与守卫禁词表两个住户 ⇒ 同一条判据两处真源 | P1 | 刀 9 新增逐条对账用例（照 G12 范式）；亦进测试轮 TC-C01 |
| 5 | readiness / prewarm 锚点与刀 8 **同文件冲突**（实测落点 `SegmentLibraryView.swift:39/56`、`ProjectOverviewView.swift:33/38`、`ImportView.swift:35`） | P1 | 刀 8 的 🚫 边界已定；建议加行内哨兵注释 + 计数级守卫排除带哨兵行 |
| 6 | 一次删除改多颗对象 ⇒ Observation 通知量未量化 | P2 | `[GraphSettle]` 计数 + 真机连删 5 项目验；不设阈值不下结论 |
| 7 | 框架行为假设散在注释与台账两处 | P2 | 三条假设集中写进门槛真源注释，台账留指针 |

**总体结论**：有条件落地。前置 = 五格矩阵跑完 + 读取分档（含拆 `?? UUID()`）+ `GraphChange` 下沉与对账腿同批。
生长性评价：表驱动结算 + 禁词同源派生使「新增一条边」成本降为一行登记，是本方案真正的结构性收益；
唯一残留是**站点未收口前，其余边仍属已知遮盖**，须留在风险条而不是「已解决」。

---

## 17. 测试轮方案（test-coverage-expander：特殊 → 一般 → 特殊）

> 种子 = 本仓 70 个测试文件 / 516 条 `@Test` + 10 条 XCTest。本节只出**矩阵与用例清单**，
> **未经确认不生成可执行测试**；生成时不落生产源码，新文件只进 `Tests/MixCutCoreTests/`（该目录自由，不碰 pbxproj）。

### 17.1 阶段 A｜从种子归纳出的不变量（本案新增的用 `TG-` 前缀）

| ID | 不变量（一般规则） | 抽象自哪个种子 |
|---|---|---|
| TG-INV-A | 任何跨 SwiftData 关系边界的读取，必须先过活对象门槛 | `TombstoneReadGuardTests` G08/G09/G10 的「token 级裸读扫描」范式 + 本案 §1.2 盲区 |
| TG-INV-B | 真删落地后，图上不得存在 `live → dead` 的边 | 本案 §1.4 两份删除实现 + `ProjectViewModel.swift:266` |
| TG-INV-C | `isGoneFromGraph` 对五格相位**至少一真**（判据充分性） | 本案 §4；`UndoGraceMachineTests` 的「穷举相位迁移」范式 |
| TG-INV-D | 运行时结算表 ≡ 从 `Models/*.swift` 派生的边集合（逐条相等） | `TombstoneReadGuardTests` G12 名册对账 + G11「来源承重」 |
| TG-INV-E | 结算顺序不变式：结算必先于 delete（倒置即丢信息） | `ModelContextExtension.swift:22-23` 的「用 API 让错误构造不出来」 |
| TG-INV-F | **产出型路径不得用随机值兜底**（`?? UUID()` 之类归零） | 本案 §16-P0-2 + `check_association_guards.sh` 的计数归零型判据 |
| TG-INV-G | 谁删谁广播，且观察者不重入（同步 post + `flushNow()` 递归） | 前案 §10 健壮-1（P0） |
| TG-INV-H | `safeSave()` 失败 ⇒ 不发广播 + 打标记（防剪枝与库不一致） | `ModelContextExtension.swift:30-39` 现有返回 false 语义 |
| INV-01/02 | 状态机守恒与幂等（迟到点击只生效一次） | `UndoGraceMachineTests` UG-03/UG-04/UG-10（**已有，沿用**） |
| IN-01/02 | 空集合 / 单元素 / 极小边界 | `SegmentPickerCatalogTests` C1-C7、`CoalescingLoaderTests`（已有） |

### 17.2 阶段 B｜外部经验净增量（**已联网检索**，标注印证 vs 新增）

| 外部做法 | 对本仓是 | 落点 |
|---|---|---|
| `withKnownIssue` 配 strict 语义：修完会自己变红逼摘标 | **印证**（本仓 G08b 已在用，且注释写明这条纪律） | 无需改 |
| 注入变异自证「非恒绿」（改坏必须红） | **印证**（G08c/G12b/`selftest_undo_guards.sh` 的 mutate 已比外部通用做法更严） | 沿用其"变异未落地即判失败"的防呆 |
| 参数化用例 `@Test(.arguments:)` 摆相位矩阵 | **新增** | 五格矩阵用一条参数化用例跑，一格一行 ⇒ 任格红能指名 |
| `.traits(.timeLimit(...))` 给性能档 | **新增** | §16 P2 建议 6「一次删除改多颗对象的通知量」可机械化成 timeLimit，不再靠真机感觉 |
| 失败时 attachment 挂扫描报告 | **新增** | 元守卫红时把「跨边读取数 : 门槛数」比表作为附件输出，查因不必重跑 |
| 无内置 property-based ⇒ 用 seeded 伪随机循环验 roundtrip 不变量 | **新增（候选）** | `SegmentPickerCatalog` / `ProjectVideoDedup` 的「拍平→投影」幂等 roundtrip，属后续批次 |

### 17.3 阶段 C｜覆盖差距矩阵（本仓真实层级：**单元**=MixCutCore `swift test`；**元守卫**=源码扫描；**集成**=DEBUG 活入口 IT-TOMB（无 test target，SwiftData 只能走这层）；**E2E**=真机）

> 该列的工具链与判据段（`U*`）已在 `2026-10-04-mac2-ui-smoke-harness.md` 立档；本案不另起编号。

| 维度 | 单元 | 元守卫 | 集成 IT-TOMB | E2E 真机 | 回溯 |
|---|---|---|---|---|---|
| 跨边读取穷尽性 | N/A（类型层测不到） | ➕ 新扫描器 | ❌ | ❌ | TG-INV-A |
| 删除后无 live→dead 边 | ❌ | ❌ | ➕ | ➕ T-0 | TG-INV-B |
| 判据五格充分性 | ❌ | ❌ | ➕ 参数化 | ➕ T-0 | TG-INV-C |
| 结算表 ≡ 派生边集 | ❌ | ➕ | ❌ | N/A | TG-INV-D |
| 结算先于 delete | ❌ | ➕ 行序判据 | ➕ 行为级 | N/A | TG-INV-E |
| 产出型无随机兜底 | ❌ | ➕ 计数归零 | ❌ | ➕ T-2 | TG-INV-F |
| 谁删谁广播 + 不重入 | ❌ | ➕ 站点名册 | ➕ | ➕ T-1 | TG-INV-G |
| save 失败不广播 | ❌ | ❌ | ➕ | N/A | TG-INV-H |
| 咽喉幂等（二次调用 no-op） | ❌ | N/A | ➕ | N/A | INV-02 |
| 通知/重算量不失控 | ❌ | N/A | ➕ timeLimit | ➕ 连删 5 项目 | §16-P2-6 |
| 历史脏库修复批（V-B1>0） | ✅ `LaunchStepLedgerTests` 已有台账判据 | ➕ 新 cadence 键唯一 | ❌ | ➕ | §7 工序 |

**已覆盖不需重做**：撤销宽限状态机（UG-01…14）、目录投影规则（C1…C7）、归属回填纯函数（B1…B5）、
指纹与备份门（SF-xx + SL-xx）、就绪禁点（TC-U01…09）、并发合并（`CoalescingLoaderTests`）。

### 17.4 用例清单（全部标 **待生成**；P0 五条 = 落地前置）

| 编号 | 层级 | 标题 | 回溯 | 输入 | 预期 | 优先级 | 状态 |
|---|---|---|---|---|---|---|---|
| TC-T01 | 元守卫 | `ToOneReadScan`：视图层新增未过门的跨边读取必须红 | TG-INV-A | 向真实取样面注入 `x.ownerProject?.id` | 总数 +1 且单独认出该条 | **P0** | 待生成 |
| TC-T02 | 元守卫 | 改名不绕过 + keypath 进允许清单须带理由 | TG-INV-A / G09 | 把边改名 / 写 `\.video.id` | 前者仍红；后者缺理由 ⇒ 判「判据失效」 | P1 | 待生成 |
| TC-T03 | 元守卫 | 穷尽性计数级：每文件「跨边读数 : 门槛 token 数」不足即红 | TG-INV-A（§15 升级） | 同一文件 3 处跨边只 1 处过门 | 红，且报告带比值附件 | **P0** | 待生成 |
| TC-T04 | 元守卫 | 结算表 ≡ `Models/*.swift` 派生边集（多/少/改名皆红） | TG-INV-D | 从表里删一条边 | 红并指名缺哪条 | **P0** | 待生成 |
| TC-T05 | 元守卫 | 产出型文件名单内 `?? UUID()` 兜底数必须为 0 | TG-INV-F | 现状跑（`MCPSegmentToolHandlers.swift:509/:548` 仍存） | **红** ⇒ 以 `withKnownIssue` 显式进套件当红钉，拆掉后自动逼摘标 | **P0** | 待生成 |
| TC-T06 | 元守卫 | 行序判据：咽喉内结算必须早于 `delete(` | TG-INV-E | 手写两版顺序 | 倒置版红 | P1 | 待生成 |
| TC-T07 | IT-TOMB | 五格参数化矩阵（含第 ⑤ 格子 context） | TG-INV-C | 每格：`delete` → 读 `.id` | 每格 `isGoneFromGraph == true` 且不 trap；任格双 false 却 trap ⇒ 该格红并指向第三信号预案 | **P0** | 待生成 |
| TC-T08 | IT-TOMB | 删 A 项目后：B 项目里的共享 Video 无 live→dead 边 | TG-INV-B | A/B 共享一颗 Video，走咽喉删 A | `video.ownerProject === A` 为 false；已 repoint 指向 B；无任何对象指向死 A | **P0** | 待生成 |
| TC-T09 | IT-TOMB | 咽喉幂等：同一对象连调两次 | INV-02 | `deleteAndSettle(x)` ×2 | 第二次 no-op、变更集空、不二次发广播 | P1 | 待生成 |
| TC-T10 | IT-TOMB | save 失败档 | TG-INV-H | 只读/失败态 context 下走咽喉 | 不广播 + `saveFailed` 标记 + `[GraphSettle] save-failed` | P1 | 待生成 |
| TC-T11 | IT-TOMB | `deleteAndSettle` 在 timeLimit 内完成（批量改多颗） | §16-P2-6 | 一次删含 50 颗共享 Video 的项目 | 不超时；命中数进 `[GraphSettle]` | P2 | 待生成 |
| TC-T12 | E2E 真机 | T-0 / T-1 / T-2 三张脚本（删另一项目 + 连删两条 + Agent 导出时删项目） | TG-INV-B/G/F | 见 §7 | 不崩、归属数字不说假话、导出报告无随机 project_id | **P0** | 待人工执行 |

**效力上限（不得当已验证）**：元守卫是 token 级，不做类型推断 ⇒ 保证的是"形状不再出现"，不保证"读法一定安全"；
IT-TOMB 用内存容器 ⇒ **测不到 SwiftUI body 重算与 `.task` 续体时序**，那两样只有真机 T-0/T-1/T-2 能定；
TC-T05 今天是**故意红**的（P0 未修先入册），不是失败。

**确认口径**：确认后我按上表生成 `Tests/MixCutCoreTests/TombstoneLifecycleGuardTests.swift`（元守卫组，沿用 `RelationshipReadScan` 与 `@Test` 命名与 G 系编号风格）
+ `DebugSelfTest.swift` 的 `MIXCUT_SELFTEST_TOMBSTONE=1` 分支（IT 组）；不跑套件、不提交，跑不跑你说。

---

## 18. 测试轮交付记录（v1.3，元守卫组已落码并实测）

**落点改判**（先说，因为它推翻 §17.4 的落点）：元守卫**没有新建** `TombstoneLifecycleGuardTests.swift`，
而是并进既有的 `Tests/MixCutCoreTests/TombstoneReadGuardTests.swift`。理由：取样面助手
（`modelSources()` / `viewSources()` / `allMixCutSources()` / `swiftFiles(under:)`）都是 **file-private**，
换文件就用不到 ⇒ 另起一份等于把扫描器再抄一遍，正撞本案 P1-3 抓出来的「第四份实现」那类错。新住户只有一个：`enum ToOneReadScan`（门 5）。

**实测读数**：`swift test --filter TombstoneReadGuardTests` ⇒ **rc=0；17 条用例 = 13 全绿 + 4 known issue（红钉）+ 2 skipped（重生成腿）**。
本轮新增 7 条（原 10 条）；既有 G08/G08c/G09/G10/G11/G12/G12b 一条没被打破。

**用例映射（§17.4 清单 → 实际落地，含未做项）**：
TC-T01→G14+G15b｜TC-T03→G15（用**名册逐条相等**实现，强于原拟的比值判据）｜TC-T05→G16+G16b｜
TC-T02 的「改名不绕过」半边未做（门 5 的边名派生自 `Models/`，与 G09 同范式，等刀 10 真接入视图改造时补）；
TC-T04 只落了**派生侧**（G13），运行时结算表的对账腿要等刀 9 那颗表存在；TC-T06（行序判据）同样等咽喉存在；
**TC-T07～T11（IT-TOMB 五格矩阵）未生成**；TC-T12 待人工。
另有一条**清单外新增**：G17（readiness / prewarm 锚点防呆），来自评审 P1-5。

| 用例 | 守什么 | 结果 |
|---|---|---|
| G13 | 第三来源承重：to-one 边必须派生出 **13 条声明 / 9 个名字**，名单逐条锚定 | ✅ 绿（§1.5 那句「13 条」从人工 grep 升成机械把守） |
| G14 | 敏感性正反三半边：本案崩形必须抓到；`.live?.id` 改法不许误伤；`video?.isDroppedFromContext` 判据自身不许被拦 | ✅ 绿 |
| G15 | 名册对账：未过门的跨边读取与基线**逐条相等**（新增即红、偷拔不改表也红） | ✅ 绿（41 键） |
| G15b | 门 5 判定：视图层未过门跨边读取必须为 0 | ⚠️ 红钉：今天 **43 处 / 12 文件** ⇒ 刀 8 改完它会自己变红逼摘标 |
| G16 | 产出型路径不许有随机 `UUID()` 兜底 | ⚠️ 红钉：实测 **5 处** |
| G16b | 随机兜底逐条对账 + 缺理由即判「判据失效」 | ✅ 绿 |
| G17 | 锚点防呆：readiness **2** 处 / prewarm **3** 处必须逐字不变 | ✅ 绿（跨行正则与 shell 门同口径实测确认） |
| G17d | 门 5 名册重生成腿（`TOMBSTONE_DUMP_TOONE=1`） | 平时 skipped |

**订正（以守卫生成的读数为准，不手写）**：§3 决策 3 / §5 / §17.3 里那句「宽口径 **40 处 / 12 文件**」是我 grep 人工数的，
守卫实读 **43 处 / 41 键 / 12 文件**（差在同一文件同形多行、同一行多处跨边）。与 v1.5 那次「55 与 40 都订正为 49」同理，**以本节为准**。
分布：`SegmentPickerDrawer` 8（含崩点 `:106`）｜`SegmentVariantInspector` 7｜`SegmentLibraryView` 5｜`SchemeDetailView` 5｜`ExportView` 5｜
`ShotEditSheet` 3｜`SplitSegmentSheet` 2｜`WelcomeView` 2｜`SidebarView` 1｜`ProductPresentation` 1｜`SegmentPropertiesSection` 1｜`CaptionTimingEditorSheet` 1。

**随机兜底 5 处实读**（比我评审时数的 2 处多，且**语义要分档**）：
`MCPSegmentToolHandlers.swift` 的 job 归属键 ×2 + 导出分组键 ×1｜`MCPToolHandlers.swift` 的 `jobs.begin(projectID:)` ×1
—— 这 4 条是**归属/分组键**，属本案 P0；
`ImportViewModel.swift` 的 `contentHash: hash ?? UUID().uuidString` ×1 —— **不同语义**（唯一性占位，不是归属键），
已在名册里单独挂理由待 review，不与前四条混成同一个 P0。

**效力上限（不当已验证）**：门 5 是 token 级 ⇒ 保证"这个形状不再新增"，`\.video` 这类 **keypath 形态仍漏抓**
（注释里写明为已知漏抓，不许声称穷尽）；真删链与 SwiftUI body 重算仍测不到 ⇒ 交 §4 五格矩阵（IT 组）与真机 T-0/T-1/T-2。

**未做（诚实记账）**：
- **TC-T07～T11 全部「待生成」**：IT 组要落 `MixCut/App/DebugSelfTest.swift`（生产 target 内、`#if DEBUG`），
  且跑它要启动 app 打开**用户活库** ⇒ 写之前先报备、跑由你执行或你明确授权。
- 本轮未跑全量 `swift test`（只跑本文件的 filter）⇒ 四个数留给你按老口径对，用例总数相对上次 **+7**。
- 本轮未跑 `check_project_integrity.sh` / `xcodebuild`（只动 Tests/，没动 pbxproj 与生产源码，但没实测就不说）。

---

## 19. 刀 8 前置工序交付（v1.4）：拆掉归属/分组键的随机 UUID 兜底

§16-P0-2 的顺序硬约束是「**先拆随机兜底，后铺门槛**」——门槛把读不到变成 nil，若下游拿 `?? UUID()` 接住，
一次 SIGTRAP 就会被换成一份**静默张冠李戴的产出**。这一步先做，生产码首次落地。

**改了什么（4 处归属/分组键，全部在 MCP 侧）**

| 位置 | 原写法 | 现写法 |
|---|---|---|
| `MixCut/Services/MCP/AgentJobRegistry.swift:24/:44` | `let projectID: UUID`（必填 ⇒ 逼调用方造假值） | `projectID: UUID?` + `begin(kind:projectID: UUID?)`：**「不知道属于哪个项目」成为可表达的状态** |
| `MixCut/Services/MCP/MCPToolHandlers.swift`（getJob） | `job.projectID.uuidString` / `fetchProject(job.projectID.uuidString)` | `"project_id": ... ?? NSNull()`（**键仍在，值可为 null** ⇒ Agent 侧契约不破）；解析不出项目时整段 `videos` 与"项目被删"走同一分支 |
| `MCPToolHandlers.swift`（exportScheme） | `jobs.begin(projectID: projectID ?? UUID())` | 直接传那颗 `projectID?`：跨项目导出本来就**没有**单一归属，报 null 比编一个真 |
| `MCPSegmentToolHandlers.swift`（exportSegments / generateVoiceVariants） | 从 `segments.first?.video?.projectVideos.first?.project?.id ?? UUID()` 猜 | 新增 `jobProjectID(explicit:segments:)`：**先吃调用方自带的 `project_id`**（Agent 寻址口径，确定值），再退回链上首个可解析项目，都没有 ⇒ nil。跨边暴露次数**不多于**改前 |

**顺带修掉一个真实缺陷**（不在原计划里，是拆 `?? UUID()` 时撞出来的）：
`MCPSegmentToolHandlers.swift` 的变体生成用 `Dictionary(grouping: eligible, by: { $0.video?.id ?? UUID() })` 分组，
下面紧跟 `guard let video = group.first?.video else { continue }`
⇒ **没有所属视频的分镜会被自成一组再静默丢弃**，Agent 拿到的是"成功但少条目"的报告。
现改为：孤立分镜逐条 `ok:false + reason:"分镜缺少所属视频"`，其余按 `(Video, Segment)` 配对分组，**不丢条目**。

**测试侧跟随**：`G16` 从「红钉待修」改写成「**旧范式残留 = 0 的回归钉**」（4 条原文钉住，改回去即红）⇒ 今天转绿；
`G16b` 名册缩到 1 条（`ImportViewModel` 的 `contentHash: hash ?? UUID().uuidString`，唯一性占位、**语义不同**，挂 P2 理由待单独 review）。
红钉总数 **4 → 2**（剩 `G08b` 门 4a 未收口、`G15b` 门 5 未收口）。

**实测证据（本机）**
- `swift test --filter TombstoneReadGuardTests` ⇒ **17 条通过 / 2 known issues**（G16 由红转绿即"确实拆净"的机器确认）。
- `swift test --filter "MCPProtocolTests|AgentToolCatalogTests"` ⇒ **31 条通过**。
- `xcodebuild -configuration Debug -derivedDataPath .scratch/dd` ⇒ **BUILD SUCCEEDED**。
- `SKIP_XCODEBUILD=1 scripts/check_project_integrity.sh`、`check_navigation_readiness_guards.sh`、
  `check_association_guards.sh`、`check_schema_ledger_guards.sh`、`check_undo_guards.sh` ⇒ **五颗全 rc=0**
  （本轮点名的两处互斥面：readiness/prewarm 锚点与 TC-19d 唯一出口都没被碰到）。

**这一步带来的行为变化（要说清，属"说真话"的变化）**
`get_job` 的 `project_id` 现在可能是 `null`（跨项目导出、或分段链上解析不出项目时）。以前是个每次都不一样的假 UUID。
⇒ **需要跟进两件小事**：① MCP 工具文档（`docs/superpowers/specs/2026-07-28-mcp-server-phase1-design.md` 一类）里
`project_id` 的语义要补一句"可为 null"；② 真机验一次 Agent `get_job`（含跨项目 export_scheme）确认客户端不因 null 报错。

**未做（诚实记账）**
- 门 5 的取样面目前只有 `MixCut/Views/**` ⇒ 本轮改的 `Services/` 里 `scheme.project?.id`（`MCPToolHandlers.swift` exportScheme 内）
  与 `seg.video?.projectVideos.first?.project?.id`（新 helper 内）这类**跨边读取仍未在册**。
  刀 10 扩面（把 `Services/`、`ViewModels/` 纳入取样）是下一步，**别把门 5 现在绿读成"全仓跨边都设防了"**。
- P0-2 只做了一半：随机兜底拆净了，但**读取分档本身**（渲染型可跳过 / 产出型必须 throw）还没落——它依赖刀 8 的门槛存在。
- IT-TOMB 五格矩阵仍未生成；`check_project_integrity.sh` 报的源码树计数本轮不变（没新增文件）。

---

## 20. 刀 8 交付（v1.5）：跨 to-one 边界的活对象门槛

**落码清单（全部已有文件，未新增 `.swift`）**

| 文件 | 改动 |
|---|---|
| `MixCut/Utilities/ModelContextExtension.swift` | 新增判据真源 `isGoneFromGraph = isDeleted \|\| modelContext == nil`（两信号析取、保守档）与过门原语 `live`（`PersistentModel` 与 `Optional where Wrapped: PersistentModel` 各一颗）。**没做 `liveID`**（§1.3 那条类型漂移）。`isDroppedFromContext` 原样保留给既有 7 处消费者，注释指到新真源 |
| `MixCut/Views/Schemes/SegmentPickerDrawer.swift` | 8 处跨边读取全部过门：`:46 segment.live?.id`、`:53 project.product.live?.id`、崩点 `:106 ownerProject.live?.id`、`:105 product`、`:108 video`、`:111-112 project/video`、`:116 product`；`:90` 改 `.task(id: project.live?.id)`（仍在 body 最外层）；`:71` 网格回查改 `segmentByID[...]?.live`；新增 `listableEntryCount` 让 `:126` header 那句「共 N 个分镜」与网格**同判据** |
| `MixCut/Views/Schemes/SchemeDetailView.swift` | `:39` 上游那道未设防的 `scheme.project` 过门（门后取不到 ⇒ 抽屉整体收起）；`:52` `.task(id: scheme.live?.id)` |
| `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift` | `liveSegment(_:)` 改建立在 `live` 原语上（`ModelContextExtension.swift:11` 警告过的"第五处写法"没再多一处） |
| `Tests/MixCutCoreTests/TombstoneReadGuardTests.swift` | 两张名册各自**重生成回填**（门 5 与门 4a），没手改一行 |

**实测证据**
- `xcodebuild -configuration Debug -derivedDataPath .scratch/dd` ⇒ **BUILD SUCCEEDED**（`isDeleted` 在部署目标 14.0 上可用、可选链扁平化、`Optional.live` 全部成立）。
- 门 5 名册：`TOMBSTONE_DUMP_TOONE=1` 实读 **43 处 → 35 处 / 33 键 / 11 文件**，`SegmentPickerDrawer` 在册条目 **8 → 0**（崩点文件整体从名册消失，这是"销账"而不是"改判据"）。
- 门 4a 基线：总数 **45 处 / 43 键 / 12 文件不变**，但抽屉那条登记行的原文已随改动变化 ⇒ 走 G08d 重生成回填（**没有手抄**）。
- `swift test --filter TombstoneReadGuardTests` ⇒ **17 条通过 / 2 known issue**（红钉剩 `G08b` 与 `G15b`）。
- 全量 `swift test` ⇒ **550 条**，`swift test rc=1`，其中 **1 条真失败与本次改动无关**：
  `Tests/MixCutCoreTests/HTTPRequestParserTests.swift:79`（夹具发的是 `Authorization: Bearer  ` ⇒ 值是 `"Bearer"`，断言却要它 `isEmpty`，**夹具与断言自相矛盾**）。
  归属核实：`Sources/MixCutCore/HTTPRequestParser.swift` 与那对测试文件在本会话开始前就是未提交改动（见会话首帧 git status），本轮三小时没碰过它们。**留给用户决定改夹具还是改断言。**
- 五颗发版门 `check_project_integrity` / `check_navigation_readiness_guards` / `check_association_guards` / `check_schema_ledger_guards` / `check_undo_guards` ⇒ **全 rc=0**。
  特别确认：G17（readiness 2 处 / prewarm 3 处锚点）与 shell 门那几处**逐字未变**——刀 8 的 🚫 边界守住了，没把"值语义"的地方顺手改成门后取值。

**要人知道的两处行为变化（都是"说真话"方向，但是像素级判据）**
1. header 那句「共 N 个分镜」改为**门后可列数**：以前把已真删的分镜也数进去，现在不数 ⇒ 数字可能比以前小。
2. `.task(id:)` 的 id 变 nil 时任务不再重建，抽屉收起改由父视图 `SchemeDetailView.swift:39` 那道门负责 ⇒
   真机要验"删掉项目后抽屉不会留着一个空壳"。

**未闭合（不许当已解决）**
- 🔴 **五格矩阵仍未跑** ⇒ `isGoneFromGraph` 的**充分性**没证明。本轮改动是**单调改善**（判据从单信号扩成两信号析取，只会比原来少漏），
  但"某格两信号都 false 而读 `.id` 仍 trap"这一支没排除；若测出来，第三信号是 `modelContext !== 期望 context`。
  ⇒ 刀 9 与真机 T-0 之前先跑矩阵，仍然是台账里优先级最高的一件事。
- 剩余 **35 处**在册跨边读取属后续批次（`SegmentVariantInspector` / `ExportView` / `SchemeDetailView` 其余处等）。
- 门 5 取样面仍只有 `MixCut/Views/**` ⇒ `Services/`、`ViewModels/` 里的跨边读取（含本轮新写的 `jobProjectID`）**不在册**，
  所以"门 5 绿"不等于"全仓跨边都设防"。
- 读取分档只做了**产出型的前置**（§19 拆随机兜底）；产出型路径本身还没过门。
- 真机 T-0 / T-1 未验（只能你点）。

**回滚**：还原上表 4 个 MixCut 文件 + 跑两条重生成腿回填名册即可；门槛是**纯读侧**判据、不写库，回滚不残留状态。

---

## 21. 判据矩阵实跑（v1.6）：两格推翻机理描述，刀 9 的动机要改写

活入口已落 `MixCut/App/DebugSelfTest.swift`（`MIXCUT_SELFTEST_TOMBSTONE=1`，可加 `_GRID=n` 单跑一格）。
**不碰用户库**：走 `FileHelper.swift:21` 那颗 DEBUG 门 `MIXCUT_DEBUG_APP_SUPPORT_ROOT` 把数据根整体指到临时目录，
容器本身用 `ModelConfiguration(isStoredInMemoryOnly: true)`。每格**先落盘再读 `.id`**（那一读若 trap 会带走进程，
报告停在「即将读」即为证据）。BUILD SUCCEEDED，7 格逐格跑完。

| 格 | 现场 | `isDeleted` | `modelContext == nil` | 跨边仍非 nil | 读 `.id` |
|---|---|---|---|---|---|
| ① | `delete` 未 save，直接拿死对象 | **true** | false | — | 不崩 |
| ② | `delete` + `safeSave` | **false（翻回去了）** | true | — | 不崩 |
| ③ | 被 cascade 摘除的 `ProjectVideo` | false | true | — | 不崩 |
| ④ | 跨 `ownerProject` 边（**save 之后**） | — | — | **false（框架自己置空了）** | 无对象可读 |
| ⑤ | 子 context 删 + save，main 侧已 fault | false | false | — | 不崩 |
| ⑥ | 跨 `ownerProject` 边（**未 save**） | **true** | false | **true** | 不崩 |
| ⑦ | 存储层批删 `delete(model:where:)` | 调用**抛错**（`成功=false`）⇒ 本格读数无效，需重做 | | | |

### 三结论

1. **`isGoneFromGraph` 取两信号析取，被实测证明是必要的，不是偏好**。
   ①⑥ 只有 `isDeleted` 为真；②③ 只有 `modelContext == nil` 为真 ⇒ **任何单信号都会各漏两格**。
   本仓沿用已久的 `isDroppedFromContext` 恰好落在漏 ①⑥ 的那一侧。D1 维持原判，且现在有实测行号可引。
2. **本案的崩点相位没有被这七格复现**（七格里没有一次 trap）。
   ⇒ 方案 §1.1 那句"活 Video 一直指着已删 Project，于是稳定复现"**要降级为推断**：
   ⑥ 证明了"死边确实存在（未 save 相位、跨边拿到的是死对象）"，但也证明了**在那个相位读 `.id` 不崩**。
   剩下没测的、且与崩溃记录最吻合的一支是 `ModelContextExtension.swift:8-9` 自己写着的机制：
   **删除时 SwiftData 给仍存活的内存对象发变更通知，视图在消失前被回调驱动重算一次** ⇒ 崩在**通知驱动**的读上，
   同步排出来的任何一格都测不到。下一批实验（写清判据再动）：
   - **⑧ 通知驱动读**：`withObservationTracking` 订阅 `Video`，在 `onChange` 回调里跨边读 `ownerProject?.id`；
     预期能区分"同步读不崩"与"回调里读崩"。（本仓 `withObservationTracking` 目前 0 处使用，是全新面。）
   - **⑨ 有盘 scratch store**：同一条链跑在 `isStoredInMemoryOnly: false` 的临时目录真 store 上（仍不碰用户库），
     把 WAL / save 中途改写关系这一相位纳入。
   - ⑦ 重做：`delete(model:where:)` 抛错原因先查清（大概率是谓词/时机），它仍是"制造死对象"的头号候选。
3. **刀 9 的动机从"防崩"改成"防静默丢数据"，但更该做了**。
   ④ 是本轮最有价值的读数：`delete + save` 之后 **`Video.ownerProject` 被框架自己置成 nil**。
   配合 `LaunchSteps.swift:70` 那颗 `.once(key: "didBackfillProductOwnership_v1")` 台账（永不二次回填）⇒
   **每一次删项目，都在永久抹掉它名下视频的导入归属**：这些视频的产品归属会从"原项目所属产品"退到
   R4 的回退口径（最早关联 → 默认产品）。这解释了一个以前只能猜的现象，也说明：
   - §7 那条 V-B1 的 SQL 要**换判据**：光查悬空 FK 不够（框架不留悬空，它直接置空），
     真正要数的是 `ZOWNERPROJECT IS NULL` 的 Video 有多少颗、以及它们还能不能从 `ProjectVideo` 反推出归属；
   - 刀 9 的 repoint 结算**不依赖**崩不崩，它救的是数据；§15 待拍板 1 里"只收 `Project` 那条链"的范围不变，
     但优先级从"刀 8 之后"提到"与刀 8 同批或紧随其后"。

### 门槛的代价（实测副产物，必须记）
①②③⑥ 四格判据都 = true 而实测**读 `.id` 不崩** ⇒ 门槛在这些相位上**偏严**：
用户删掉一个项目后，正在显示的抽屉/列表会少列一些其实还能读的对象。方向保守、不丢数据，但**这是产品可见的变化**，
真机 T-0 要看一眼是不是可接受的口径（不可接受的出口：把判据从析取收回成"只认 `modelContext == nil`"，代价是漏 ①⑥）。

### 本轮实测账
`xcodebuild` BUILD SUCCEEDED ×2；判据矩阵 7 格逐格跑完并落盘；全量 `swift test` 550 条（1 条真失败仍属会话前的
`HTTPRequestParserTests.swift:79`，与本轮无关）；五颗门 rc=0（本轮未再复跑门脚本，改动只在 `#if DEBUG` 内）。
**未做**：⑧/⑨ 两格、⑦ 重做、真机 T-0、V-B1 新 SQL。

---

## 22. 第⑧⑨⑩格实跑（v1.7）：十格无一复现 ⇒ "读已删对象即崩"这个机理模型被证伪

### 先认一个假阴性
第⑧格第一版报「onChange 没触发」，**那个读数不可信**，是我的 harness 缺陷而非这一拍的性质：
① `scene`（连带 `ModelContainer`）随函数返回被释放，容器都没了通知自然不会来；
② `fired` 在 `safeSave()` 之后**同步**读，异步派发来不及落。
修好后（容器/上下文/对象由探针强持有 + 收尾跑 1s runloop）**仍然不触发** —— 这次的"不触发"才成立，
且它的含义要写准：**纯 SwiftData 层复现不出"通知驱动重算"那一拍，因为它依赖 SwiftUI 的 body 求值路径**；
本 harness 不是真视图，所以这一格既没证明会崩、**也没证明安全**。

### 读数（活入口 `MIXCUT_SELFTEST_TOMBSTONE=1`，格九含⑩）
| 格 | 现场 | 判据读数 | 读 `.id` |
|---|---|---|---|
| ⑧ | 观察挂在 `Video.ownerProject`，delete+save 叫回回调 | onChange **未触发**（修 harness 后仍false） | 未执行到 |
| ②′ | **有盘** store，delete+save 后直接拿死对象 | `modelContext==nil`=true ⇒ `isGoneFromGraph`=true | **不崩** |
| ④′ | 有盘，delete+save 后跨边 | 跨边结果 **nil**（框架置空） | 无对象 |
| ⑥′ | 有盘，delete 未 save 跨边 | `isDeleted`=true ⇒ `isGoneFromGraph`=true | **不崩** |
| ⑩′ | 有盘，**换一个全新 `ModelContext` 重新 fetch Video** 再跨边（悬空 FK 的 fault 解析路径） | 跨边结果 **nil** | 无对象 |

加上 §21 的 ①-⑦，**十格全部不 trap**。

### 结论：三个层次要分开说
1. **被证伪的是"简单形状"**：在 macOS 15.6 的 Debug 版上，"从活对象跨一条 to-one 边拿到已删对象、再读它的 `@Attribute(.unique) id`"
   这一族**十种相位都构造不出崩溃**；而且框架会在 save 时**主动把悬空边置 nil**（④′/⑩′两条独立证据，内存与有盘一致）。
   ⇒ §1.1 那句"稳定复现"彻底作废，`§2.1 第 4 条`的触发链降级为"未证实的候选"。
2. **嫌疑被收窄到两处，都不是"读"本身**：
   - **⑦ 存储层批删** `delete(model:where:)` —— 本轮**调用抛错**（`成功=false`），所以那格读数无效。
     而前案 §3 刀 3 恰好写着这条 API「不动内存里已 materialize 的对象 ⇒ 会制造更多死对象」，
     **它是最可能造出"backing 已清、内存仍 fault 着"的删法**，必须修好抛错重测。
   - **save 失败 / 半完成态**：`safeSave` 返回 false 的那一支（库里行已清、内存标记没走完）。真机日志里若出现过保存失败，这就是头号候选。
   - 另一处不可排除的差异：我的样本只有 3 对象 / 2 关联，真库是 11 实体级联 + 数千行；**小样本造不出来的路径不能断言不存在**。
3. **刀 8 的门槛该不该留？留，但理由换了**。
   它的**判据选型**是独立成立的（①⑥ 只有 `isDeleted` 真、②③ 只有 `modelContext == nil` 真 ⇒ 单信号各漏两格，实测已证）；
   它拦的是"读一个已删对象"这一**类**动作，价值不依赖本案能否复现。
   但它**不是本案的根因修复** —— 谁要是把"刀 8 已落 + 门 5 绿"当成这个 SIGTRAP 已解决，就是错的。

### 反而被实测**坐实**的一件事（比崩溃更值钱）
`④′/⑩′` 证明框架在 save 时会把 `Video.ownerProject` **主动置 nil**，配合 `LaunchSteps.swift:70` 的
`.once(key: "didBackfillProductOwnership_v1")` 永不二次回填 ⇒ **每删一次项目就永久抹掉名下视频的导入归属**，
这不是推断，是两格独立实测。⇒ 刀 9（repoint 结算）的必要性由"防崩"改判为"防静默丢数据"，**优先级更高**。
V-B1 的判据也跟着定了：查 `ZOWNERPROJECT IS NULL` 的 Video 数（框架不留悬空 FK，所以原 SQL 查不到东西）。

### 下一步（顺序即优先级）
1. 修 ⑦ 的抛错原因（大概率是"新建容器后未 save 就批删"或谓词写法），重测那一格 ⇒ 这是唯一还能直接解释崩溃的候选。
2. ~~测 save 失败分支（把 store 设成只读/满盘等效条件）能否造出 trap。~~ → **已试，造法不成立**，见下一小节。

### 补：第⑪格「save 失败的半完成态」——造法不成立（别拿它的读数当结论）
读数：`safeSave` 返回 **true**、`isDeleted=false / modelContext==nil=true`、跨边 `ownerProject` 已是 nil、读 `.id` 不崩。
**但"save 失败"这个前提压根没造出来**：我是先建好库（SQLite 已经拿到可写 fd）才把目录 chmod 成 0555，
而**只读目录不阻止对已打开 fd 的写入**，所以那次 save 是真成功了 ⇒ 上面那行"不崩"不代表半完成态，别引用。

要不要继续追？我的判断是**不必再追这一格**，因为它想测的那个状态已经被别的格覆盖了：
"库里行已清、内存标记未走完"在可观测层面等价于
**①/⑥′**（内存里 delete 未 save 的相位 —— 判据 `isDeleted` 为真、读 `.id` 不崩）
加上 **⑩′**（换全新 context 重新 fetch，悬空边解成 nil、不崩）。
真要造出一次**真实失败**的 save，得换招（在建库**之前**就把目录设成只读、或建库后往 `.store` 里写垃圾触发 `SQLITE_CORRUPT`），
而那种条件已属"环境故障注入"，为验证一个尚未复现的崩点不值得 —— **留作显式放弃项，不当已测**。
3. 真机 T-0（用户点）：刀 8 已落，若那个操作序列不再崩，是**间接**证据但不等于根因已定。
4. 刀 9 按新动机推进（防丢归属），与 ①② 无依赖，可并行。
本轮实测账：BUILD SUCCEEDED ×3；`swift test --filter TombstoneReadGuardTests` 未受影响（本轮只动 `#if DEBUG` 内）；
临时目录里的 scratch store 全部落 `NSTemporaryDirectory()`，**未接触用户库**。

---

## 23. 追完 ⑦ 与 ⑬（v1.8）：排除法走到头，机制仍未复现，但两条副产品落地

### ⑦ 的抛因（已查清）
```
NSError：Constraint trigger violation: Batch delete failed due to mandatory OTO nullify inverse on ProjectVideo/video
```
`delete(model:where:)` 在这套 schema 上**根本不可用**：`ProjectVideo.project` / `ProjectVideo.video` 是**非可选** to-one，
存储层批删必须 nullify 入边，而 nullify 到非可选列被约束挡下。⑫′（有盘重做）补上最后一块证据：
**批删失败后 `Project` 数仍是 2** ⇒ 它压根没生效。
⇒ ⑦ 被**排除**为崩点来源，同时反证：本仓的真实删除只能走 `delete(object)`（门 4b 名册那 41 处全是它）。

顺带修了我自己一处违规：case 7 原先写的是 `(try? …) != nil`，把错误整个吞掉 —— 正是本仓明令禁止的"静默忽略错误"，
也正是我一开始只报得出"成功=false"、答不出为什么的原因。改成显式 `do/catch` 才拿到抛因。

### ⑬：驱逐 / 重开后重新 fault（⑩′ 绕不开同一 container 的 identity map，所以只有这格算数）
第一程建库 + `delete(A)` + save 后**彻底释放 container**；第二程用同一 store URL 重开：
- `Project 数 = 1` ⇒ A 的行确实被清；
- `Video 数 = 1`、跨边 `ownerProject = nil` ⇒ **盘上的外键也一起被清了**；
- 读 `.id` 无对象可读 ⇒ 不崩。

### 排除表
有效格 **①②③④⑤⑥⑦⑧⑨⑩⑫⑬ 全部不 trap**（⑪ 造法不成立，读数作废，见 §22）。
⇒ 能在本机构造的相位已穷尽。剩下没被排除的只有我 3 对象小样本造不出来的维度：真实数据规模 / 关系图深度，
以及一条**独立机制**：`MixCutApp.swift:122-124` 记着"挂上 SwiftData `undoManager` 后 `context.delete(...)` 会**同步**触发
`_assertionFailure`（删 SchemeSegment 时必崩）"—— 那是"崩在删除动作本身"而非"崩在读"，与本族的两起报告形状不同，但值得单独复验。

### 副产品两条（比"没复现"更值钱）
1. **§7 的 V-B1 可以撤了**：⑬ 直接证明 SwiftData 在 save 时就把 `Video.ownerProject` 的外键清掉 ⇒ 那条"查悬空 FK"的 SQL 必然为 0，
   是**问错了问题**。真正该数的是历史损失面：
   `SELECT COUNT(*) FROM ZVIDEO WHERE ZOWNERPROJECT IS NULL`（再看这些 Video 还能不能从 `ProjectVideo` 反推出归属）。
   这条仍交给你跑，读数决定要不要做一次修复型启动步骤（工序已在 §7 登记）。
2. **刀 9 的必要性从"推断"升为"实测确证"**：归属不是只在内存里看不见，而是**库里被抹**，且 once 台账永不二次回填
   ⇒ 每删一个项目就永久丢一次导入事实。刀 9 与"能不能复现崩溃"完全解耦。

### 结论与下一步
- **本案根因仍未定**。不许把"刀 8 已落 + 门 5 绿 + 十三格不崩"读成"问题已解决"；台账状态继续标"机理未证实"。
- 值得做的三件，按优先级：① 刀 9 落数据侧（防归属丢失，价值确定）；② 复验 `undoManager` 那条"delete 自身 trap"的已记录路径是否与本族相关；
  ③ 崩溃本身改从"造相位"转"抓现场"——下次真机崩时留 `[GraphSettle]` / `[Catalog]` 形状日志与 `MixLog` 尾部，比对当时在哪条链上。
- 本轮实测账：BUILD SUCCEEDED ×3（含一次把我自己改坏的文件结构修回）；活入口现覆盖 ①-⑬；全程临时目录，未接触用户库。

---

## 24. 刀 9 交付（v1.9）：删项目收成一颗咽喉——它当场抓到我引进的真 bug

### 落码清单（全部已有文件，未新增 `.swift`）
| 文件 | 改动 |
|---|---|
| `MixCut/Utilities/ModelContextExtension.swift` | 新增 `ProjectDeletionOutcome` + 咽喉 `deleteProjectSettlingOwnerEdges(_:)`：① 结算入边（`=== project` 指针比较找人，`ProductOwnershipBackfill` 定新归属，不重写规则）→ ② `delete(project)` → ③ **中间那次 save 不能省** → ④ 补删孤儿视频与其分镜 → ⑤ 收尾落盘。幂等：输入 `isGoneFromGraph` 即直接返回全零 |
| `MixCut/ViewModels/ProjectViewModel.swift` | commit 里 3 处 `context.delete` 全删，改调咽喉；`saveFailed` 走 `ToastCenter` 警示（不重试、不静默） |
| `MixCut/Services/MCP/MCPToolHandlers.swift` | 那份「注释自证是复制粘贴」的实现删除，改调同一咽喉；`videos_deleted_globally` 直接吃咽喉读数 |
| `Tests/MixCutCoreTests/TombstoneReadGuardTests.swift` | 门 4b 名册重算 + 新增 **G18** + 修掉 `G12b` 硬编码豁免下标 |
| `MixCut/App/DebugSelfTest.swift` | 新增格 ⑭（咽喉功能验证）；自检现场改走 `ProjectVideo.associate` 工厂 |

### 🔴 第⑭格抓到的真 bug 是**我自己引进的**（这条最该记住）
我「顺手改进」把旧实现的两次 `safeSave` 合并成末尾一次 ⇒ **cascade 是落盘时才摘掉 `ProjectVideo` 的**，
而补删判定读的是 `video.projectVideos.isEmpty` —— 中间不 save，它对所有视频恒 false：
读数 **修复前 2 颗视频全留着、`连带删视频 []`；修复后 `["IT-solo"]`、`Video 1 颗`、⑭ 转绿**。
旧代码那处中间 save 不是冗余，是 cascade 时序的一部分 —— 我合并时把它的**理由**丢了。
⇒ 再次印证本项目纪律：`BUILD SUCCEEDED` + 守卫全绿 **不等于**行为正确；功能验证格不是奢侈品。

### 门 4b 改册，以及一处我自己开的洞
守卫自己报的真实读数：`ProjectViewModel` 3→**0**、`MCPToolHandlers` 3→**0**、`DebugSelfTest` 9→**21**（矩阵自检现场），总数 **41 → 47**。
⚠️ 收咽喉的同时把 **4 处真删挪出了门 4b 的扫描面** —— 咽喉内部写裸 `delete(...)`，而门 4b 的 regex 只认
`context|ctx|modelContext.delete(`。不补就是"少 4 处没人发现"。⇒ 新增 **G18** 逐条钉住这 4 处（各带理由，多一处少一处都红）。
顺带修 `G12b`：原先硬编码 `noReason[9]`，名册删两行就会**越界崩溃** ⇒ 改成按 `exempt` 属性定位。

### TC-19a 撞门：选择不开豁免
`check_association_guards.sh` TC-19a 要求全仓 `ProjectVideo(project:` 裸构造只许 1 处（工厂本体）。自检加了 2 处 ⇒ 门红。
**没有加豁免**（豁免会变成没人认领的欠账），改成让自检也走 `ProjectVideo.associate(...)` 工厂
—— 顺带让自检的挂载语义与生产同源（工厂内含幂等判重）。改完六颗门全 rc=0。

### 实测账
`xcodebuild Debug` **BUILD SUCCEEDED ×4**；六颗门（integrity / navigation-readiness / association / schema-ledger / undo / selftest-undo）**全 rc=0**；
`swift test --filter TombstoneReadGuardTests` **18 条通过 / 2 红钉**；MCP + 归属纯函数 **36 条通过**；
矩阵 ①-⑭ 复跑：⑭ 通过，⑦/⑫′/⑬ 读数与 §23 一致；全量 `swift test` 551 条，唯一真失败仍是会话前遗留的 `HTTPRequestParserTests.swift:79`（与本仓改动无关）。

### 仍未闭合（不许当已解决）
1. **真机 T-0 未验**：删项目的真实链路（宽限期到点 → 咽喉 → 侧栏/抽屉刷新）只能你点。重点看共享视频改指后，
   产品下拉与「共 N 个分镜」的读数是否符合预期（像素级判据）。
2. **其余 12 条 to-one 边的入边未结算**（G13 钉着 13 条，本咽喉只覆盖 `Video.ownerProject`）⇒ 在册欠账。
3. **本案根因仍未定**：刀 9 防的是静默丢归属，与那次 SIGTRAP 无因果关系。
4. ~~前案刀 2 的广播仍未接~~ ⇒ **本轮已接（§25）**：咽喉读数现在进 `outcome.change` 并由唯一发布口交给剪枝分支。
   遗留的是**其余删除链**（本节当时列的那 22 行），不是机制本身。

**回滚**：还原 `ModelContextExtension` / `ProjectViewModel` / `MCPToolHandlers` 三个文件即回到两份实现的原状；
名册与 G18 同批回退（否则 G12/G18 会红 —— 这是有意的，不许只回代码不回册）。

---

## 25. 刀 2 交付（v1.10）：广播通道能带 id 了 —— 顺带在我自己的判据里抓到一个"没人认领的投影"

状态：**机制层已闭合（唯一发布口 + 载荷 + 回落 + 重入闸 + 剪枝分支，全部有门）；逐条 UI 删除链的接入是下一批**。

### 落码清单（全部已有文件，未新增 `.swift`）

| 文件 | 改动 |
|---|---|
| `Sources/MixCutCore/UndoGraceMachine.swift` | `GraphEntity`（10 类）+ `GraphChange`（按实体类型记 id、`isPrunable` 回落判据）。**落点在 MixCutCore 而不是 `ContentView.swift`** —— 前案 v1.8 勘误已推翻原文规定，本轮照勘误执行 |
| `MixCut/App/ContentView.swift` | 唯一发布口 `GraphBroadcast.post(_:)`：① 不可剪枝 ⇒ **自动降为无载荷**；② `isBroadcasting` 重入闸（嵌套那次丢弃 + error 日志）；③ 观察者 `reloadAfterUndo(change:)` **第一行分叉**：带 id ⇒ 只剪枝，绝不碰 `fetchProjects()/loadSegments()/flushNow()` |
| `MixCut/App/MixCutApp.swift` | ⌘Z / ⇧⌘Z 两处裸 `NotificationCenter.post(...)` 并进 `GraphBroadcast.post()`（无载荷 = 旧全量重载语义一字不改） |
| `MixCut/Utilities/ModelContextExtension.swift` | 咽喉把"这次真删了哪些 id"记进 `outcome.change`；**id 一律在 `delete` 之前取**（`let segments = Array(video.segments)` 后再 `noteDeleted`） |
| `MixCut/ViewModels/ProjectViewModel.swift` | commit 成功后 `GraphBroadcast.post(outcome.change)`；**`saveFailed` 时不发**（半完成态不该让界面剪枝成"看起来一致"）；新增 `pruneDeletedProjects(_:)` |
| `MixCut/ViewModels/SegmentLibraryViewModel.swift` | 新增 `pruneDeletedSegments(_:)`：**先剪数组再 `applyFilter()`**（刀 2 真约束：`recomputeGroupedSegments()` 会对残留死对象做一次 to-one 读）；不碰 `loadSegments`/`flushNow` |
| `MixCut/Services/MCP/MCPToolHandlers.swift` | `notifyUIReload()` 转发到唯一发布口，**保持无载荷**（Agent 删的是跨项目跨视频的范围，MCP 旧语义是它的回归基线） |
| `Tests/MixCutCoreTests/TombstoneReadGuardTests.swift` | 新增 **G19**（发布口唯一 = 全仓 `post(name: .mixCutDataDidUndo` 恰好 1 处且必须是 `object: payload`；观察者恰好 1 处；重入闸与降级两行**逐字**钉住）；**G18 名册改册**（见下） |
| `Tests/MixCutCoreTests/UndoGraceMachineTests.swift` | 新增 `GraphChangeTests` **GC-01~07**（并集 / 空集不落键 / 未登记实体读数空 / 直接消费者可剪 / 混入即整条降级 / video 条件可剪 / prunable 名册逐字对账） |

### 交付前自查抓到的洞（这条是本节的主要内容）

我把 `isPrunable` 写成"变更里每类实体都在 `prunable` 名册里 ⇒ 可剪"，并在名册里放了 `project/video/segment` 三类。
**`video` 是假的**：全仓没有任何 VM 持有视频数组投影（实测 `ImportViewModel` 只有 `cancelledVideoIDs: Set<UUID>`，
视图一律从活 `Project.videos` 现读），而剪枝分支只有 `pruneDeletedSegments` / `pruneDeletedProjects` 两双手 ⇒
一条"只删视频"的变更会被判**可剪**、走剪枝、**什么也没剪**、然后 `return` 跳过全量重载。
这正是 C3 那条规则要拦的"半剪半不剪"，而写规则的人是我自己。

⇒ 判据补第三条合取：**`deleted[.video] != nil` 时必须 `deleted[.project] != nil`**（视频投影随所属项目一起摘）。
语义上是"能不能剪 = **有没有人接得住**"，不是"id 好不好拿"。GC-07 钉住四种形状（video 独 / video+project / video+segment / 咽喉真实形状）。
将来任何"单删视频"的链接入时**默认降级为全量重载**，不需要谁记得去看这段注释。

### G18 上一轮就欠了一次改册（门替我记着）

§24 那批我把咽喉里的 `delete(video.segments)` 改成了"先 `Array(video.segments)` 快照 → 记 id → `delete(segments)`"，
但 G18 的名册还写着旧行文本 ⇒ 本轮跑守卫即红。**改册而非改码**（新写法才是对的：`noteDeleted` 要的 id 必须在真删之前取）。
这条的教训不是"门好用"，是**上一批的账我漏了一次**，靠门补上的。

### 实测账（都是跑出来的，不是估的）

- `swift test --filter GraphChangeTests` ⇒ **7 条全绿**。
- `swift test --filter TombstoneReadGuardTests` ⇒ **19 条**，新增 G19 绿、G18 改册后绿，红钉仍 **2 条**（G08b 45 处 / G15b 35 处，单调缩短的存量账）。
- 全量 `swift test` ⇒ **559 条**，真失败 **1 条** = 会话前遗留的 `HTTPRequestParserTests.swift:79`（用户的 WIP，未动）。
- `xcodebuild Debug` **BUILD SUCCEEDED ×2**（判据改动前后各一次）。
- 六颗门 `check_{project_integrity,navigation_readiness_guards,association_guards,schema_ledger_guards,undo_guards}` + `selftest_undo_guards` **全 rc=0**；`check_ai_completeness_guards` 亦 rc=0。
- **未实测**：剪枝分支的真实效果（侧栏/分镜库少一张卡）只能真机看 ⇒ 归 T-0。

### 仍未闭合（不许当已解决）

1. **逐条 UI 删除链还没产出 `GraphChange`** ⇒ **本节写的这条已被 §26 收口**（宽限期 6 条链接完，4 条交台账 / 2 条刻意空台账；
   推荐的"中心代广播"就是 §26 落地的形状）。仍遗留的是**非宽限期的直删行**：`ImportViewModel:280/379/945/955/1244/1245`、
   `SchemeViewModel:469`、`ShotEditViewModel:213/247/486`、`DubbingViewModel:325`、`SchemeDetailView:84` —— 见 §26「在册欠账」2。
   下面这段是当时的原文（保留，因为里面的约束已被 §26 逐条兑现）：机制与咽喉齐了，除删项目链以外其余删除链一次都不发通知 ——
   实测裸 `context.delete(` 行数：`ImportViewModel` **10**、`SegmentLibraryViewModel` **4**、`SchemeViewModel` **3**、
   `ShotEditViewModel` **3**、`DubbingViewModel` **1**、`SchemeDetailView` **1**（`ProjectViewModel` 已归 0，见 §24）。
   ⚠️ 这是**行**数不是**链**数（一条 commit 闭包里常有两三行），逐链接入时要先分清哪些是同一条事务。
   —— 与前案 §1.4④ 诊断的同一条病，只是现在有药了。
   推荐下一批的接法：把 `PendingDeletionCenter.schedule(commit:)` 的闭包签名升为 `() -> GraphChange`，
   由**中心**在 commit 落地后 `if !change.isEmpty { GraphBroadcast.post(change) }` ——
   空台账不发（保持今天行为，不许把每条删除都变成全量重载 ⇒ 那会把"切页骨架闪烁"重新引回来），
   逐链只需"删之前收 id、return 出来"，不必各自记着调发布口。
2. **真机 T-0**：删项目 → 侧栏少一项、分镜库少 N 张卡、日志**只有一行** `[GraphPrune]`（一次删除出现两行 ⇒ 重入没挡住）。
3. 其余 12 条 to-one 边的入边结算（在册欠账，与本节无关）。
4. **本案根因仍未定**：刀 2 补的是"库里删了、界面还拿着"这条**必然存在**的一致性缺口，不是那次 SIGTRAP 的因果修复。

**回滚**：`GraphBroadcast` / `GraphEntity` / `GraphChange` / 两个 `pruneDeleted*` / GC 组 / G19 是一整套，整批还原；
只回 App 层会留 GC 与 G19 红（**有意的**，台账与判据不许只回一边）。G18 那条改册**不能跟着回** —— 它跟的是 §24 的咽喉，不是本节。

---

## 26. 刀 2 续批（v1.11）：广播口搬进事务中心 —— 我自己引进的两个窗口，都被新格 ⑮ 抓到并实测对照

§25 交付的是机制，遗留"逐链接入"。本批把广播口**收进事务中心**（而不是让每条链各自记着发通知），
并接完全部宽限期删除链：**6 条 `schedule` 里 4 条交回台账**（删视频 / 单删分镜 / 批删分镜 / 删项目），
**2 条刻意交回空台账**（删策略 / 删方案，理由见"在册欠账"）。
台账的口径同时被改写了一次 —— 判据从"这类实体在不在名册里"变成"**有没有人接得住**"
（不是"少一处能剪"，是"少一处有人接"）。

### 落码清单（全部已有文件）

| 文件 | 改动 |
|---|---|
| `MixCut/Views/Shared/PendingDeletionCenter.swift` | `commits: [UUID: () -> GraphChange]`、`schedule(commit:)` 闭包**交回台账**；真删落地后由中心经唯一发布口广播（`finish` / `arm` 两处，共用一个 `broadcast(ifNeeded:)`，**空台账不发**） |
| `MixCut/App/ContentView.swift` | `GraphBroadcast` 的防重入从**丢弃**改为**排空队列**（见下"第二个窗口"） |
| `MixCut/ViewModels/ImportViewModel.swift` | `commitDelete` 返回 `(globallyDeleted, change)`：孤儿视频的**分镜 id 在 delete 之前**收进台账；Agent 直删路径（`removeVideoImmediately`）不重复广播，仍由 MCP 的无载荷全量重载覆盖 |
| `MixCut/ViewModels/SegmentLibraryViewModel.swift` | 单删 / 批删两条链各交回 `.segment` 台账（id 取自 schedule 前已快照的数组） |
| `MixCut/ViewModels/ProjectViewModel.swift` | 删项目链不再自己 `GraphBroadcast.post`，改为**交回** `outcome.change`；`saveFailed` 时交回空台账 |
| `MixCut/ViewModels/SchemeViewModel.swift` | 删策略 / 删方案两条链**故意交回空台账**，理由写在码旁（见"在册欠账"） |
| `MixCut/App/DebugSelfTest.swift` | 新增**格 ⑮**：投递 / 降级 / 嵌套不丢 / 中心代广播 / 空台账不发 / 顶掉顺序，六腿真跑 |
| `scripts/check_undo_guards.sh` + `selftest_undo_guards.sh` | 新增 **UG-G09**（commit 返回类型 + 广播点 2 处 + 中心内 post 1 处 + 空台账不发）与变异腿 **M9**（把返回类型退回 `() -> Void` ⇒ 必须变红） |
| `Tests/MixCutCoreTests/TombstoneReadGuardTests.swift` | G19 的承重锚跟着改成新写法（`if isBroadcasting {` + `while !queued.isEmpty` + 降级三元式） |

### 🔴 第一个窗口：广播一旦早于"登记新事务"，就会吃掉那枚新事务的真删义务

把广播从各条链收进中心时，我保留了 `arm()` 原有的顺序（先了结上一枚、再登记新的），
只把 `post` 挪进了 `settle` —— 于是广播发生在 `commits[新id] = commit` **之前**。
后果不是崩，是**丢删除**：观察者里任何一句 `flushNow()`（`ProjectViewModel.selectedProject.didSet` 就挂着一条）
会去了结那枚**刚登记、闭包表里还是空**的新事务 ⇒ `finish` 取到 `nil` 闭包、`dropClosures` 把它抹掉 ⇒
用户刚点的删除**既不真删也不可撤销**，界面已隐藏、库里还留着，重启后它又冒出来。
⇒ 修法：`settle` 只**返回**台账，广播挪到 `arm` 末尾（登记 + publish + startTicker 之后）。
**实测对照**（变异 = 把 `Self.broadcast` 搬回登记之前，重跑格 ⑮）：
`F 顶掉顺序：A commit 1 次、B commit **0** 次、投递 1 次 ⇒ 结论：不通过`；还原后 `A 1、B 1、投递 2 ⇒ 通过`。
这条不是我推测的口径，是跑出来的两行读数。

### 🔴 第二个窗口：重入闸原先"丢弃嵌套"的理由站不住

§25 我写的注释是"外层广播已覆盖同一次删除"。**这句只在嵌套那次来自同一次删除时成立**；
而真实的嵌套形状恰恰是"外层剪 A、内层是 flushNow 顺带真删的 B" —— 丢掉 B 就是回到"库里删了、投影还握着"，
也就是本案的原始病。⇒ 改成**排空队列**：嵌套那次进队列，最外层那次 post 返回前逐条补发
（是循环不是递归 ⇒ 栈不增长；队列里出现无载荷=全量重载时清空其余，因为全量重载覆盖任何剪枝）。
实测：格 ⑮ C 腿嵌套 ⇒ `投递 2 次 ["prune(seg=1)", "prune(seg=1)"]`（旧写法只会投 1 次）。

### 台账记什么：只记"有投影消费者"的那几类

本批把这条定成口径，否则"该不该记"会由每个接入的人临场猜：
- 记 `.segment`（`segmentLibraryVM.segments` 是第二双手）、记 `.project`（`projectVM.projects`）。
- **不记** `ProjectVideo` / `SchemeSegment` / `SegmentDub`：全仓没有持有这三类数组的 VM
  （实测 `ImportViewModel` 只有 `cancelledVideoIDs: Set<UUID>`），记了反而因 C3 整条降级成无载荷 ⇒ 每次删除都全量重载、
  把已修完的"切页骨架闪烁"重新引回来。
- `.video` 只在删项目链里顺带出现（由 `pruneDeletedProjects` 接住），单删视频链**不记** `.video`
  （`project.videos` 从活 `Project` 现读，且 `deleteVideo` 在 schedule 前就已把关系摘掉）。

### 在册欠账（本批刻意没接的，都留了空台账 + 旁注）

1. **删策略 / 删方案**：`schemeVM.strategies` 在 schedule 前已自摘，而 `.strategy` / `.scheme` 没有第二双手可剪 ⇒
   交回空台账 = 保持接入前行为。风险点写清楚：若将来出现"抽屉开着时策略被级联删掉"的形状，
   必须**先加 `pruneDeletedStrategies` 再把这两条链的台账填上**，不许直接填台账（那会整页全量重载）。
2. **非宽限期的直删链**（`ImportViewModel:280/379/945/955/1244/1245`、`SchemeViewModel:469`、
   `ShotEditViewModel:213/247/486`、`DubbingViewModel:325`、`SchemeDetailView:84`）——
   这些不在撤销事务里，接法与广播点都不同（要么链尾自发 `GraphBroadcast.post`，要么先收进中心），**另批**。
   ⚠️ `SchemeDetailView:84` 仍是"视图里真删库对象"（前案评审 P2），本批没动。
3. 真机 T-0、其余 12 条 to-one 边的入边结算、本案根因未定 —— 同 §25，未变。

### 实测账（跑出来的）

- **格 ⑮ 六腿通过**，且 F 腿有**变异反向对照**（见上两行读数）；`MIXCUT_SELFTEST_TOMBSTONE=1 _GRID=15`，走 `MIXCUT_DEBUG_APP_SUPPORT_ROOT` 临时根，不碰用户库。
- `swift test` 全量 **559 条**，真失败 1 条 = 遗留的 `HTTPRequestParserTests:79`（用户 WIP）；红钉仍 2 条。
- 门：**UG-G09 新判据 PASS**，`selftest_undo_guards` **9 条变异腿逐条变红**（含新 M9）；
  `check_{project_integrity, navigation_readiness_guards, association_guards, schema_ledger_guards, ai_completeness_guards}` 全 rc=0。
- `xcodebuild Debug` **BUILD SUCCEEDED ×4**（原状 → 变异 → 还原 → 复跑）。

### 验收腿已收成一支脚本（v1.12）：`scripts/verify_graph_broadcast.sh`

三步散在不同终端里各数一遍口径容易漂移，所以收成一条命令（判据写在码旁，不另立文档）：

| 步 | 内容 | 谁跑 |
|---|---|---|
| ① | 格 ⑮ 六腿（`MIXCUT_SELFTEST_TOMBSTONE_GRID=15` + 临时根，**不碰活库**）；额外把 `B commit 0 次` 直接判成 FAIL（那是 §26 第一个窗口复发） | 脚本自动 |
| ② | T-0：启动真 App，由你删一个视频 + 一个项目，脚本读日志增量并判：`[GraphPrune] 剪枝` 行数 == 删除次数（多=双投 / 少=有链没交台账）、`[GraphSettle]` == 删项目次数、`嵌套广播入队` 出现就报出来 | 脚本判定 + **你动手**；"有没有整页骨架闪烁"这条脚本判不了，明写在输出里 |
| ③ | 数 `ZOWNERPROJECT IS NULL`（V-B1'）| **默认只打印命令**；要代跑必须你亲手输入 `run`，且脚本先确认 SunCut 已退出 —— 本仓纪律：工具不打开活库（WAL 只读也有写副作用） |

实测：`--grid --skip-build` 与 `--no-live --skip-build` 两条腿 rc=0；`check_project_integrity.sh` 的「`$变量` 后不紧跟全角标点」门在本脚本上干净（首轮它抓到我自己一处 `$REPORT）`，已改 `${REPORT}`）。
⚠️ 同一次运行里这颗门还对 `scripts/mcp_smoke_test.sh:69/:120` 报红 —— 那是**会话期你自己在改的文件**（git 状态 M），我没动它，留给你收口。

#### 勘误（v1.13）：首支验证脚本被用户真机跑出一处**假判据**

用户实跑 `./scripts/verify_graph_broadcast.sh` 时，步骤 ② 立刻报
`剪枝 0 行 < 2 ⇒ 有链没交台账` 与 `[GraphSettle] 0 行`。
**这两条 FAIL 是脚本自己的问题，不是生产码的问题**：等待那行我写成 `read -r _ "提示语"`，
bash 把第二个参数当**变量名**（当场 `not a valid identifier`）⇒ 报错但**根本不等待**，
脚本没等他删就去取日志增量了。这类"验证器产出假读数"比缺验证器更坏，因为它会把人引去改本来正确的码。
⇒ 三条改法：① 提示语一律走 `read -r -p`；② 非交互终端（`[ ! -t 0 ]`）**跳过 ② 且不给判据**；
③ 把「没采到证据」与「代码不符」分成两条口径（日志增量为空 ⇒ 报"本步没采到证据，不计入代码结论"），
并把剪枝行数改为与**你申报的实际真删次数**对账（不再硬编码 2 次；非数字输入回落默认值，否则 `-eq` 语法错会让整棵判据静默跳过）。
同轮附带：这次真机跑把 ① 在用户机上独立复现了一遍（六腿通过，`B commit 1 次`）。
脚本侧实测：`bash -n` 通过、变量边界门 0 违规、`</dev/null` 非交互跑 rc=0（② 走新跳过路径）。


**回滚**：本批是一整套（中心的返回类型 + 五条链的交回 + 发布口队列 + 格 ⑮ + UG-G09/M9 + G19 新锚）。
只回中心会让五条链的闭包签名不匹配（编译不过 ⇒ 回不全）；只回 `GraphBroadcast` 的队列会让 G19 红。
两处**不许跟着回**：G18 的改册跟 §24，格 ⑮ 的 F 腿判据跟本批的顺序修法。

---

## 27. 🔴 现场抓到了（v1.14）：一道**已过 `live` 门**的读取在真机 trap ⇒ §4 的析取判据被证不充分

崩溃报告 `~/Library/Logs/DiagnosticReports/SunCut-2026-10-04-170030.ips`（2026-10-04 17:00:30，macOS 15.6.1，`EXC_BREAKPOINT / SIGTRAP`，faultingThread 0）。
这是同族**第三起**，也是第一起**带着现场相位**的一起 —— 前两起都只有崩点，这次日志里有崩溃前 13 秒的全部动作。

### 实测（每一条都能在机器上复核）

| 判据 | 读数 | 怎么取到的 |
|---|---|---|
| 崩栈 | `_assertionFailure` ← SwiftData×3 ← **`Project.id.getter`** ← **`closure #3 in SegmentPickerDrawer.rebuild()`** ← `Collection.map` ← `rebuild()` ← `closure #2 in SegmentPickerDrawer.body.getter` | 报告 `threads[faultingThread].frames` |
| 崩在哪一行 | **`SegmentPickerDrawer.swift:118`** | `atos -o SunCut.debug.dylib -l 0x1042b4000 0x104946108` |
| 崩的二进制含不含门 | **含**：报告里 `SunCut.debug.dylib` 的 UUID = `85B9B22E-31A6-3102-840C-D9CF6E9A487E`，与 DerivedData 里 16:26 那次构建 `dwarfdump --uuid` **逐字相同** | 两侧 UUID 对账 |
| 那一行的源码 | `self.catalogVideos = videos.map { CatalogVideo(id: $0.id, ownerProjectID: $0.ownerProject.live?.id) }` ⇒ **已经是刀 8 的过门写法** | 直接读文件 |
| 崩溃前最后一次真删 | 17:00:15.706 `视频无引用，已删除记录: 视频库 (1).mp4`；17:00:15.707 `[GraphPrune] 剪枝 projects=0 videos=0 segs=7 剩余 segs=26` | 应用日志 |
| 崩前 13 秒内的删除动作 | **除上面那次视频删除之外，没有任何删除**（17:00:15.707 之后日志静默到崩） | 应用日志 |
| 本实例里的删项目 | **一次都没有**（整段日志里没有 `[GraphSettle]`，17:00 那个实例从 16:59:11 起监听 MCP 开始） | 应用日志 |
| 而 §26 那条链本身 | 一次删除**只投一行** `[GraphPrune]`、剪掉 7 条、剩余 33→26 ⇒ **广播接线是对的，崩点与它无因果** | 同上 |

### 由此必须改写的两条既有结论

1. **`isGoneFromGraph`（`isDeleted || modelContext == nil`）不充分。**
   §4 我给自己写的判定是：「任一格出现『两信号都说活着、读 `.id` 却 trap』⇒ 析取判据不成立 ⇒ 退回根因重新上溯，
   禁止用 `try?`／吞异常／加 retry 兜过去」。**这条今天被真机兑现了**：崩的那一行两信号都判"活着"，
   读 `.id` 仍然 trap。⇒ 刀 8 的效力上限比 §20 记的**还要低一档**：它挡住的是"本进程内已知被删"的那批相位，
   挡不住这一批。D1 作为"必要"仍成立（①⑥ 与 ②③ 那两组的互斥证据没被推翻），**"充分"部分作废**。
2. **§23 那条"盘上外键在 save 时就已被清 ⇒ V-B1 属问错问题"要重开。**
   本实例从没删过项目，却仍然 fault 出一颗"已不存在的 `Project`" ⇒ 悬空只可能来自**库里的遗留边**
   （前两个实例 16:48 / 16:49 各有一批 `删项目《GUARD-*》` 经咽喉删除，共 18 次，且全部
   `入边改指 0 颗、置空 0 颗、连带删 0 颗`）。⇒ V-B1 的正确问法不是 `ZOWNERPROJECT IS NULL`，
   而是**"owner 指向一颗不存在的项目行"**。

### 推断（尚未实测，别当结论用）

- 崩的是**跨实例遗留的悬空归属边**，不是本次删除的相位；`isDeleted` 与 `modelContext` 都是这颗对象
  **自己的**局部状态，对"行已不在库里但边还挂着"这种形状天然无感（我的 ①-⑭ 全部在同一颗 container 内造相位，
  从没造过"外部悬空边 + 全新 identity map"这一格 ⇒ 这就是十二格全不崩、真机却崩的差额所在）。
- 那批 `GUARD-*` 测试项目由 UI 冒烟 / MCP 守卫脚本建，归属可能由**非咽喉路径**写下（`make_ui_fixture.py`、
  `mcp_api_guards.py` 都是这半小时里在改的文件），所以咽喉的"置空 0 颗"与盘上仍留有指向它的边并不矛盾。

### 下一步（按 §4 那条自己写的规矩走：退回根因，不兜底）

1. **先取一个数**（只读 SQL，交用户跑）：悬空 owner 的行数。0 ⇒ 上面那条推断作废，回到"同实例内相位"重想；
   >0 ⇒ 判据要加第三条信号，且**存量数据修复**升为 P0。
2. **补格 ⑯**：在临时库里用 SQL 直接造一条 `ZVIDEO.ZOWNERPROJECT` 指向不存在的项目行，重开 container
   （全新 identity map）后跨边读 `.id` —— 这是 ①-⑭ 都没覆盖的相位，也是唯一能**在本机复现 SIGTRAP** 的候选造法。
3. 第三信号的候选（**都要先过评审再动码**，本案纪律）：
   ① 成员判定：`live` 之外另加"这颗对象是否等于本次活 fetch 里的某一行"（用 `===`，不 fault 任何属性）；
   ② `modelContext.registeredModel(for: persistentModelID)` 反查（SDK `:397`）；
   ③ 目录键改用 `PersistentIdentifier` 而不是 `UUID` ⇒ 根本不 fault `Project.id`（改动面最大，但把
   "读持久标量"从路径上拿掉，是唯一可能治本的一档）。
4. ⚠️ **不许**用 `try?` / 吞异常 / retry 把这一崩点糊过去（§4 明令，且第 25/26 节已经证明"崩至少会拦住人"）。


