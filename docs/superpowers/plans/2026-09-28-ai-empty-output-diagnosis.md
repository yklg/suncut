# AI 输出截断：一类缺陷（四站点）· 修复计划 v5（2026-09-28，执行中）

> v4 已并入 tech-solution-review 的 5 条 P0。**v5 并入 test-coverage-expander 的测试层（§10）**，
> 并新增 3 条评估得到的前置结论：
> ① `swift test` 的物理边界 ⇒ 本轮 6 个维度的可测性**完全取决于是否写成 `Sources/MixCutCore` 纯函数**，
>    故把 v4 §4 步骤 1-b 的"违规清单一个函数"**扩为 4 个纯函数**（`AIResponseEvidence` / `SegmentationCompleteness` /
>    `OutputBudgetPlanner` / `BatchMerge`），本轮先落前两个（后两个属步骤 2）；
> ② 外部经验 E4（上下文超预算那一行标 invalid、**不参与打分**）⇒ 补出来的 `qualityScore` 现在照样进 ≥8.5 选段阈值与库排序；
>    本轮**只做标记、不做排除**（排除会改变方案数量，属行为变更，见 §9）；
> ③ 顺序不变量 E1：**截断判定必须先于 JSON 解析**，而现状是"解析失败后反过来猜是不是截断"，方向就是反的。
> 步骤 0 + 步骤 1 本轮执行；步骤 2（A/B/D 选型）与步骤 3（接口契约变更）不在本轮。

> v3 把根因提到"缺产物规模契约"，并列出四处同类站点。
> **tech-solution-review（A 类方案评审）判为「有条件落地」，5 条 P0 全部并入本版**：
> ① 步骤 1 的失败在 **MCP 面根本不可见**（`retryPipeline` 丢弃返回值、job 恒 `completed`）；
> ② **残缺结果在数据层看起来完全合法** —— `createSegments` 手工制造连续+全覆盖，所以"时间覆盖判据"这条路**被证伪并作废**；
> ③ A 方案会**静默改写 `position` 的含义**，"保住产品语义"这句卖点不成立；
> ④ B 方案会**丢掉 `qualityScore` 整条链**，代价被低估；反过来它的边界口径成本被高估（边界时刻本就是本地信号说了算）；
> ⑤ 缺陷家族有**第 4 个成员：宽容解码补出来的默认值冒充真实数据入库**。
> **仍未动任何代码，未再消耗 API。**

## 0. v3 → v4 变更表

| # | 来源 | v3 的问题 | v4 的处理 |
|---|---|---|---|
| P0-1 | 评审 | 步骤 1 只改 UI 层 `video.status`，MCP/Agent 面照旧看到 `completed` | §4 步骤 1 新增 **1-d「job 面闭合」**；§6 判据把 `get_job → failed` 列为必过项 |
| P0-2 | 评审 | 建议用"段数覆盖全片"作截断判据 | **作废并写明不可实现**（`ImportViewModel.swift:692-704` 强制首段 0.0、尾段 `videoDuration`、相邻段首尾相接）⇒ 改用"单段 ≤18s"这条应用自己声明却从未强制的规则 |
| P0-3 | 评审 | A 声称"保住 AI 语义切分的产品语义" | 不成立：`position` 定义相对**全片**前后 20%（`AIAnalysisService.swift:357-362`）⇒ A 的必做补偿项：**`position` 改由本地时间戳确定性计算** |
| P0-4 | 评审 | B 的代价只写了"边界口径变更" | 补：`tagSingleSegment`（`:188-218`）**不返回 qualityScore**，而它有 6+ 消费方 ⇒ 不补评分步就是把选段/排序打成默认值。同时**下调**另一侧成本：边界时刻一直由 `boundaryOptimizer` + `extractTextFromASR` 决定（`ImportViewModel:682-709`） |
| P0-5 | 评审 | "不完整"只算条数 | 扩为**四类信号**（§3.2），并把"字段是补出来的"表示成**数据**而非日志（照 `RewriteResultMapper.swift:26-31` 的 `isFallback` 范式） |
| P1-6 | 评审 | 没有 API 侧并发闸门；分批后无取消检查 | §4 步骤 2 新增必做项 2-c/2-d |
| P1-7 | 评审 | 同一次分析 N 批之间换 provider 会混产 | 步骤 2 新增 2-e：一次分析内**快照** provider 配置 |
| P1-8 | 评审 | 跨窗合并后 `seg_%03d` 依赖数组顺序 | 步骤 2 新增 2-f：合并后**显式按 `startFrame` 排序 + `id` tie-break**（上一期刚立的规矩） |
| P1-9 | 评审 | 有一份**从不被代码加载**的 615 行 schema 副本仍被打包 | §5 不做清单/§7 影响表新增处置项（移出打包属分发变更，需单独确认） |
| P2-10 | 评审 | `dumpFailedJSON` 落原始 body 无轮转、含台词 | 步骤 0 加"条数上限 + 定期清理" |
| P2-11 | 评审 | 新增错误分类档要声明匹配顺序；`testConnection` 的 "ping" 可能合法返回空正文 | 步骤 1 的边角清单 |

## 1. 根因（三层，逐行已核）

### 1.1 契约层：没有"这次响应最多含几条"这个位置
- `AIProvider.swift:123-126`：协议只有 `generateJSON(prompt:responseType:)` / `generateText(prompt:)`，**无任何参数**可声明或查询本次产物规模上限。
- 预算藏成私有常量：`OpenAICompatibleClient.swift:54-63`（`private var providerMaxTokens`），唯一读取点 `:337`；`init` 不收预算参数（`:65-71`）⇒ 调用方看不见也改不了。
- 同一概念**第二份、值还不一致**：Claude 原生分支硬编码 `"max_tokens": thinkingEnabled ? 16384 : 8192`（`:310`）＋ `"thinking": ["budget_tokens": 8192]`（`:320`）。
- 作者知道规模-预算关系，但只写成注释：`:53`「10 个 segments + reasoning ≈ 5K-6K tokens」⇒ 8192 是按约 10 段标定的，无机制阻止 30 段同样开一枪。
- 后果：截断被当成**事后的解析救援问题**（`:432-437`、`:195-230`、`:111-127`），不是**事前的调用规划问题**。

### 1.2 症状层：0 字符只是这条谱系最响的一端
1. `:396-408` 取 `message["content"] as? String` —— **空串照样通过**；同处置 `truncatedByLength`
2. `:411-413` 只打一行"⚠️ 被 max_tokens 截断"（**推断不是观测**），`:415-416` **把空/残正文当成功返回**
3. `generateJSON:111-118` / `:120-127` 解析失败前**主动把残缺 JSON 补成合法**（`repairTruncatedJSON`、`truncateAtJSONError`）
4. `AIAnalysisService.swift:110-129` 再叠一层 lossless 逐条解码（单条解不出就丢那条）
5. ⇒ `ImportViewModel.swift:642-664` 拿到"合法但少段"的结果，直接 `video.status = .completed`

### 1.3 观测层：失败路径销毁自己的证据
- `:233-241 dumpFailedJSON` 只落 `content` ⇒ 0 字节产物；`finish_reason`/`usage`/`reasoning_content` 全丢
- `AIProvider.swift:34-120 APIErrorClassifier` 靠**上游错误文本**匹配；"HTTP 200 + 空/残正文"无人认领 ⇒ 落进"数据格式异常，请重试"
- 全仓 `reasoning_content` **0 处**命中；OpenAI 兼容分支（`:333-345`）从不发思考/预算参数 ⇒ 连"推理占了多少"都无从得知
- `maxRetries=3` 在这条路**根本不触发**（`:271` 只对 429/传输错；三次救援解的是同一段文本）⇒ 实测一次失败 = 1 次调用

## 2. 为什么残缺分镜在数据层"完全合法"（覆盖判据作废的根据）

`ImportViewModel.createSegments`（`:692-704`）：

```
adjustedStart = i == 0 ? 0.0 : optimizedBoundaries[i-1]
adjustedEnd   = optimizedBoundaries[i]
最后一段：adjustedEnd = videoDuration          // :702-704
所有切点：boundaryOptimizer.optimize(...)      // :682-687（用 ASR 句 + 本地分析改写）
台词：extractTextFromASR 为准，aiSeg.text 仅兜底  // :706-709
```

⇒ 9 段截成 6 段时，**时间轴依然从 0 连续覆盖到 `videoDuration`**，代价是尾段变成一个吞掉全片尾部的超长段。
**结论：任何"用段边界是否覆盖全片"来判截断的想法都不成立**（本版明确作废，免得后续重做）。
可用的机器判据只剩三条：① transport 证据（`finish_reason=length` / 用过救援）；② 模型自报 `total_segments`（`:372`，**必要非充分**：可少报，缺失时 `:114` 解成 0 须读作"未知"）；③ **应用自己的分段规则**——prompt 声明"单段不得超过 18 秒"（`:339`），**代码里从未强制**（全仓唯一段长界是自建分镜的 `selfSegmentMaxDuration = 30`，`ImportViewModel:462`）。③ 是不依赖模型诚实度的那一条。

## 3. 缺陷家族（四类信号）与四处同类站点

### 3.1 四处同类站点（"一次调用 = 一整个产物"）

| 站点 | 调用形状 | 无界的一侧 | 现有失败表现 |
|---|---|---|---|
| **A** `AIAnalysisService:159-184`（`generateJSON` 于 `:177`） | 一条视频一次调用吐全部分镜 | 输出 ∝ 视频长度（`:336-343`） | 0 字符抛错（实测两次）＋少段静默 |
| **C** `DubbingViewModel:165-173` → `ScriptRewriteService:37` | 整片所有可改写分镜一次改写（`for k in 0..<n` 的 `n` 是变体套数，`:176-178`） | 输出 ∝ 分镜数 | **永不报错**：`RewriteResultMapper:26-31` 把漏返回的每条静默回退成**原台词** |
| **F** `SchemeGenerationService:415-418` | 一次出 N 套叙事变体 | 输出 ∝ `requested × 槽位 × 文本长`；`feasibleVariantLimit`（`NarrativeStructureEngine:31-41`）只按组合可行性封顶、**不看 token** | 变体缺失；同类失败在 `:290-294` 只存在于**错误文案字符串**里 |
| **G** `SchemeGenerationService:478-495` | 全部分镜连台词塞进一个 prompt | **输入**侧无界 | 撞上下文墙；`:496-499` 失败软返回 `nil` |

有界可当范式的：`tagSingleSegment`（`:188-218`）、`generateStrategies`（条数 ≤5）、`testConnection`（`SettingsView:259`）。
仓里唯一真分批：`generateBatchCompositions`（`:300-372`，`while remaining > 0` + `batchCount = min(remaining, batchSize)`，默认 `batchSize: 10`）—— 就地手写、没下沉 ⇒ 从没被复用；且自带同族毛病：`:354-357` 单批解析失败 ⇒ `batchResult = []` 后继续循环，最终少交且不报错。

### 3.2 四类"不完整"信号（步骤 1 的对象）

| 代号 | 信号 | 现有出口 | 依据 |
|---|---|---|---|
| S1 | 正文为空 | 无（当成功返回） | `:396-400`、`:415-416` |
| S2 | 用过截断救援才合法（`repaired != jsonStr` / 走到过 `truncateAtJSONError`） | 只有一行 `MixLog.info` | `:111-127` |
| S3 | 条数 < 模型自报 `total_segments` | 无 | `AIAnalysisService:114`、`:372` |
| **S4** | **字段是补出来的**（缺 `data_quality`→`score 7.0`；缺 `video_id/total_duration`→""/0；单条解不出被丢弃） | 无，且**默认值直接入库** | `AIAnalysisService:58-59`、`:112-114`、`:120-126`；`Segment.swift:204` 默认 8.0 |

S4 最阴：`qualityScore` 有 6+ 消费方（`SchemeGenerationService:204-206` 按 ≥8.5 选段、`SegmentLibraryViewModel:314/326/573` 筛选/排序/均值、`NarrativeStructureEditorView:488`、`SchemeViewModel:621`、`MCPToolHandlers:155`）⇒ **补出来的分数会无声改变选段与排序**。
而 `qualityReasoning`（`Segment:88`）**全仓只有 1 处写（`ImportViewModel:721`）、0 处读** ⇒ 这是家族里唯一"纯输出成本、无消费方"的字段（对选项 D 关键）。

**结构性推论**：可测面 = 规则下沉到 `Sources/MixCutCore` 的深度（工程只有 1 个 application target）。AI 层的请求构造/响应解析目前全在 `MixCut/`；改写链已示范正确下沉（`RewritePromptBuilder`/`RewriteTypes:36-51`/`RewriteResultMapper`，各带测试），分镜链走反了（prompt 构造是 actor 内 `private`，`:221-403`）。

## 4. 修法：四步 + 各步必做项

### 步骤 0 观测（也是 L3 选型的前置测量）
- 异常路径（S1∪S2）记录：`finish_reason`、HTTP 状态、`usage` 的 prompt/completion/**reasoning** tokens、`reasoning_content` 是否存在及长度。
- `dumpFailedJSON` 改落**原始响应 body**；同时加**条数上限 + 定期清理**（body 含用户台词，不能无限堆；仓里有 `OrphanFileFinder` 范式可参考）。
- 判据细节：字段缺失如实记"该网关不返回 usage"，**不许记 0**。
- 落点：`OpenAICompatibleClient.swift`（`finish_reason` 只在 `:406` 可见）。

### 步骤 1 让"不完整"成为真信号（四类都要闭合）
- **1-a** S1 ⇒ 新错误 `AIProviderError.emptyModelOutput(finishReason:usage:)`（`AIProvider.swift:4-9` 现有 5 个 case 旁），**不再 return 空串**。
- **1-b** S2/S3/S4 ⇒ 一个显式的"结果不完整"载体（不是日志）。S3/S4 的判定纯函数落 `Sources/MixCutCore`：输入 `segments + duration + 自报条数 + 规则常量(18s)` ⇒ 输出违规清单（含"尾段吞全片"）。
- **1-c** 上层收口：`ImportViewModel:642-664` 不再把残缺结果判 `.completed`；**S4 用数据表达**（照 `RewriteResultMapper:26-31` 的 `isFallback` 范式给来源/完整度标记），不许靠补默认值蒙混。
- **1-d job 面闭合（本版新增，阻断级）**：`MCPToolHandlers.swift:306-312` 现在丢弃 `retryAIAnalysis` 返回值并无条件 `registry.finish(report: nil)` ⇒ 改成读回 `video.status`/`errorMessage`/产出段数，据此走 `AgentJobRegistry.fail`（`:70-76`，已存在但这条路上从不调用）或 `finishWithResult`。**不修这条，步骤 1 在唯一的自动驱动面上零效果。**
- 文案：改成实话（这次没吐完正文；可能输出预算被推理占满；可操作项＝换非思考模型 / 缩短单次素材 / 等分批上线），日志路径统一引用真源 `MixLog.logFileURL`；`:411` 那句未证实"被 max_tokens 截断"降级或由步骤 0 实测字段决定。
- 边角：新分类档要**声明匹配顺序**（该文件已有先例：free-quota 必须排在通用 403 之前，否则被误判）；`SettingsView:259` 的 "ping" 允许返回空正文，别把连通性测试改红。
- **落点纪律**：判定逻辑在 transport 层与 MixCutCore 纯函数，**不许在 4 个 service 各写一遍**。

### 步骤 2 结构层（选型 + 各自的必做补偿项）
目标不变量：**单次调用的输出条目数有上界，且由 provider 预算推导，而非由视频长度决定。**

| 选项 | 做法 | 优 | 劣与代价 |
|---|---|---|---|
| **A 按条数分批** | 以本地场景边界 + ASR 句子为种子，按**预计段数**（不是秒数）切 N 窗，每窗一次调用，合并 | 保留"AI 语义切分"口径；短视频仍 1 次 | token 与等待按 N 涨；跨窗连续性变差；**且必须做 2-a…2-f 六项补偿**（其中 2-a 说明它的"保语义"卖点是打折的） |
| **B 本地切分 + AI 逐段打标** | 边界由本地结果决定，AI 只判定语义（复用 `tagSingleSegment:188-218`） | 输出规模与输入规模**构造性脱钩**；最便宜最稳；与 `importSelfSegments`（`ImportViewModel:478-547`）同范式可合流，`MixCutApp:294-300` 的"按形状猜载体视频"启发式可一并简化 | **必须做 2-g**（否则质量分链路塌）；真实改变的只有"断在哪几处/断几刀"——边界时刻与台词本来就由本地决定（`:682-709`）⇒ 用**可测差异**说话，别用口径吓人 |
| **D 砍每条输出（正交，可叠加）** | 每段嵌的自由文本 `data_quality.reasoning`（`:382-385`）乘上段数是很大常数项；**移出主调用** | **全仓 0 处读取 `qualityReasoning`** ⇒ 几乎零下游影响的减负；不动"谁决定切点" | 丢一个"没人看"的解释字段（`PRODUCT_SPEC.md:347` 提过它，属文档与实现漂移）；`score` 必须保留（消费方见 §3.2） |
| ~~C 换模型/调预算~~ | 用户在设置换模型 | 零代码 | **划掉**：`:56` 自陈 V4-Flash 硬顶 8192；不解决结构。只作为步骤 1 文案里的用户自助项 |

**A 的必做补偿项**：
- **2-a `position` 本地确定性计算**（前/后 20% 用 `video.duration` 算，`:357-362` 的定义相对全片）——否则每窗自称"开头/结尾"，**静默改写已发布语义**。
- **2-b `total_segments` 合并语义**定义清楚（各窗自报值不可信，合并后以实收为准 + 记录"曾自报多少"）。
- **2-c API 侧并发闸门**：`ConcurrencyPolicy.maxAnalyzeConcurrency()`（`:39-53`）是按 Media Engine/核数算的本地并发，**与 API 无关，全仓没有 API 闸门**；N 批 × 2–4 路会放大 429，而 `:271` 的 429 重试是 2^n 退避且每次重发整包。
- **2-d 每批之间检查 `Task.isCancelled`**：现在只有外层一次 `checkCancelled`（`:639`）。血书先例：`DubbingViewModel:179-185`「以前全程没有一处 Task.isCancelled，用户关掉界面也停不下来，API 继续烧」。
- **2-e 一次分析内快照 provider 配置**：`aiProvider` 每次调用动态解析（`:149-151`）⇒ N 批之间换模型会**混产**（风格不一致、预算也不一致）。
- **2-f 合并后显式排序**：按 `startFrame`、相等再按 `id.uuidString` tie-break；**不许依赖数组拼接顺序**（`seg_%03d` 在 `:711` 按顺序重排，而 `segment_no` 是已发布的 Agent 契约）。

**B 的必做补偿项**：
- **2-g 质量分不能塌**：`tagSingleSegment` 返回体加 `score`，或明确接受"选段阈值/排序失去输入"并同步调整 `SchemeGenerationService:204-206` 与 `SegmentLibraryViewModel:314/326` —— 半做最坏（默默用默认 8.0/7.0）。

**共同**：批次/预算换算规则必须是 `Sources/MixCutCore` 纯函数；**预算表留在 app 层**、planner 只收数值入参（否则 AI provider 概念渗进媒体核心，模块内聚退化）。

### 步骤 3 契约显式化（接口变更，需单独确认）
- 给 `AIProvider` 一个声明/查询本次产物规模上限的位置。**形状建议：带默认值的 `AIRequestOptions` 结构体参数**（预算 / 期望条数 / 超时 / 温度），不要加位置参数 —— 否则每加一个约束都要改 8 个调用点。
- 顺带（同族收敛，无契约变更）：把 `:310` 那份重复常量并进 `:54-63` 单一 provider 能力表。
- ⚠️ 牵动 protocol、`OpenAICompatibleClient`、`AIProviderManager:30-37` 与 4 个 service 共 8 个调用点 ⇒ **本轮不动，单独确认**。

## 5. 不做清单
- 不加 retry 治截断（`:271` 只覆盖 429/传输错是对的；`SchemeGenerationService:346` 注释是这笔历史账）。
- 不放宽宽容解码来"消除报错"；**但 S4 必须从"补默认值"改成"标记为补"** —— 这不是放宽，是把假数据变成可判定的事实。
- 不改 `video_recombination_prompt.md` 的选段口径、不动声音克隆提示词。
- 不碰 `selfSegmentMaxDuration`（`:462`）那条 UI/时长界：本轮补的是 AI 层缺失的界。
- 不实现"时间覆盖"类截断判据（§2 已证伪）。
- 不跑 `generate_xcodeproj.py`；新增源文件手工加 pbxproj 引用并跑 `scripts/check_project_integrity.sh`。
- `video_segmentation_prompt.md`（615 行、`CLAUDE.md:113` 自陈**不被代码引用**、仍被 `CpResource` 打包）：本轮先**只在计划里登记为"权威在代码"**；移出打包属分发物变更，需单独确认。

## 6. 验收判据

**步骤 0**：同一 141.8 秒视频再跑一次失败 ⇒ `ai-fail-*.json` 不再是 0 字节，日志给出 `finish_reason` 与 completion/reasoning tokens；字段缺失记"该网关不返回 usage"（不许记 0）。
**步骤 1**：S1/S2/S3/S4 四类**各有独立可判定出口**；"数据格式异常，请重试""被 max_tokens 截断"两句在空正文场景不再出现；残缺结果不落 `.completed`；S4 的补值在数据上可区分（不是只进日志）；日志路径字样仍只有 `MixLog.logFileURL` 一处定义。
**步骤 1 · job 面（新增）**：MCP `retry_analysis` 跑一条注定失败的视频 ⇒ `get_job` 回 **`state:"failed"`**（不再是 `completed`）；这条改动会让**历史上看似的"成功"变成如实报错**，属修正而非新 bug —— 预先写死为判据。
**步骤 1 回归护栏**：38.5 秒视频仍出 9 条分镜、`get_project` 的 `segment_count` 不变；`SettingsView` 连通性测试仍绿。
**步骤 2**：141.8 秒视频能产出分镜；**调用次数与总 token 实测写回本节**（不许事后说"没多花"）；A 还需验 2-a（`position` 与全片时间一致）、2-d（中途取消后不再发新请求）、2-f（`seg_%03d` 与 `startFrame` 单调一致）；B 还需验 2-g（`qualityScore` 非默认值占比）与**差异判据**：同一视频现法 vs B 各跑一次，报断点数量差与最大偏差（用数字说"变了多少"）。
**步骤 2 的"类"判据**：A 落地后，C（`DubbingViewModel:188`）在分镜数 ≥ 阈值的视频上必须**要么一起修、要么带 `file:line` 明示"已知同类未修"**。
**测试**：可下沉的纯逻辑（S3/S4 违规清单、批次/预算换算、position 本地计算、合并排序 tie-break）落 `Sources/MixCutCore` 并配单测；网络/文案留在 `MixCut/` 的部分靠守卫脚本 + MCP 复跑取证。
**守卫**：新增形状守卫脚本 —— 断言 `finish_reason`/`total_segments`/段长规则判定只有一处实现；断言 transport 不再存在"truncated 后仍 return content"路径；断言 `retryPipeline` 不再无条件 `finish`。**必须自证：拿 `.scratch/before/` 改前快照跑同一脚本要变红。**

## 7. 跨模块回归影响（评审结论并入）

| 受影响面 | 影响类型 | 概率 | 严重度 | 说明 |
|---|---|---|---|---|
| MCP job 面 `get_job`/`retry_*` | 行为契约 | 高 | 高 | 不修 1-d 则步骤 1 零效果；修了则从"恒 completed"变"会报 failed" —— **属修正，须预先写进判据** |
| 分镜素材库（徽章/筛选/排序） | 行为契约 | 高 | 中 | 以前静默完成的残缺改为报错 |
| 方案生成链路 | 数据契约 | 中 | 高 | `qualityScore` 阈值选段依赖评分真实（S4 / 2-g） |
| 已发布 Agent 契约 `segment_no` | 接口契约 | 中 | 高 | 合并顺序 + `seg_%03d`（2-f） |
| 配音改写链（C 站点） | 行为契约 | 中 | 中 | `isFallback` 语义需与新"不完整"载体对齐，别同一事实两处表达 |
| 分发物 | 配置环境 | 中 | 低 | 失败产物目录（步骤 0）、死 prompt 文件（§5） |
| 工程文件 | 构建 | 低 | 高 | 手工 pbxproj；禁跑生成器 |

依赖方向评估：无循环依赖；"app 解析预算 → 核心层纯函数消费数值"方向正确。最大回归面是"静默改数据含义"类（前三行），不是编译类。

## 8. 工时

- 步骤 0 + 步骤 1（含 1-d）：**约 75 分钟**（观测 15 / 四类信号与 S4 数据化 30 / job 面闭合 15 / 取证与判据 15）
- 步骤 2-A（含 2-a…2-f 六项补偿）：**约 2.5 小时**
- 步骤 2-B（含 2-g）：**约 1.5 小时**，**含产品口径成分**，非纯技术工时
- 步骤 2-D：单独做 **约 30 分钟**（`qualityReasoning` 无消费方 ⇒ 成本最低的一条减负路径）
- 步骤 3：**约 1 小时**，接口契约变更，**须单独确认**
- C/F/G 同族站点：复用同一 planner 后每处 **约 20-40 分钟**

## 9. 决策状态（v5 更新）

- ✅ **已批并执行中**：步骤 0 + 步骤 1（含 1-d job 面闭合）+ §10 测试层的本轮可落部分。
  已知这会改变现状：以前静默少段/补值的场景从此报错；MCP `get_job` 会开始如实回 `failed`。**两者均为修正，非新 bug。**
- ⏸ **仍待你选**：步骤 2 走 A / B / D（D 可与 A 或 B 叠加）。§10 的 `OutputBudgetPlanner` / `BatchMerge` 两个纯函数**留到选型那轮**再落（接口已在本版定名，避免届时又散落在 app 层）。
- ⏸ **仍待单独授权**：步骤 3 的接口契约变更；把 `video_segmentation_prompt.md` 移出打包；以及**任何要消耗你 API 调用的取证复跑**（TC-47/48/51/52）。
- ⏸ **待你认的行为变更**（评估阶段 B 的 E4 带出来的）：不完整的分镜是否应**排除在 `SchemeGenerationService:204` 的 ≥8.5 选段阈值与 `SegmentLibraryViewModel:314/326` 排序之外**。本轮只做标记不做排除 —— 因为排除会让生成的方案变少，是产品口径。

## 10. 测试层（test-coverage-expander 结论并入）

### 10.1 可测面前提（与上一期同一结论）
`Package.swift` 只有 `MixCutCore` + `MixCutCoreTests` 两个 target，`MixCut.xcodeproj` 只有 1 个 application target
⇒ **`swift test` 物理上碰不到 `MixCut/` 里任何一行**。所以本轮 6 个维度（P5 截断≠成功 / P1 完整性 / P3 等价类 / P12 默认值冒充 / P4 预算边界 / P10 分区守恒）能不能有单测，**只取决于它们被写成纯函数还是写在 actor/View 里**。
本轮据此落 2 个纯函数（步骤 1 需要）：`AIResponseEvidence`、`SegmentationCompleteness`。

### 10.2 一般模式库（18 条维度，编号供用例回溯）
P1 完整性守恒 · P2 "缺"必须是数据不是日志 · P3 空/空白/仅分隔符三类等价类 · P4 预算三点法（正好/+1/−1）·
P5 截断不得算成功 · P6 分类器优先级（specific 先于 general）· P7 错误枚举 ⊇ 失败形状 · P8 retry 不掩盖确定性失败 ·
P9 取消传播 · P10 分区合并守恒（无丢/无重/有序/幂等）· P11 排序 tie-break · P12 默认值不得冒充真实数据 ·
P13 观测产物不自毁 · P14 job 面与实体面状态一致 · P15 provider 配置快照 · P16 全局量不得由局部调用产出 ·
P17 真实样本回灌 · P18 判据须在改前快照上变红。

外部经验补漏（来源 1 篇，见 §10.5）：**E1 截断判定先于解析**、**E2 拒绝把残缺 JSON 交给客户端**、**E3 边界三点法**、**E4 不完整行不参与打分**。

### 10.3 用例清单（本轮标记为「已落」的会写进 `Tests/MixCutCoreTests/`；其余为「待生成/待取证」）

| 组 | 用例 | 层 | 守护维度 | 本轮 |
|---|---|---|---|---|
| `AIResponseEvidence` | TC-21 `finish_reason=length` + 空正文 ⇒ 判空**且早于解析** | 单元 | P5 P7 E1 | **已落** |
| | TC-22 仅空白/代码围栏 ⇒ 同档 | 单元 | P3 | **已落** |
| | TC-23 `stop` + 合法 JSON ⇒ 零缺口（正向对照，防恒真） | 单元 | P5 | **已落** |
| | TC-24 无 `usage` ⇒ `.absent` 而**非 0** | 单元 | P12 | **已落** |
| | TC-25 Claude shape `stop_reason=max_tokens` + thinking 块 | 单元 | P7 | **已落** |
| | TC-26 非 JSON / 缺 `choices` ⇒ 走"无法解析"档不吞进空正文档 | 单元 | P6 | **已落** |
| | TC-27 property：任意长度 × finishReason ⇒ 判据等价 | 单元 | P1 | 待生成（步骤 2 那轮） |
| `SegmentationCompleteness` | TC-28 declared 9 / received 6 ⇒ 报缺口 + 尾段吞全片 | 单元 | P1 P17 | **已落**（用 141.8s 真响应结构做 fixture） |
| | TC-29 declared=0 ⇒ "不可断言"，不得判"不少" | 单元 | P12 | **已落** |
| | TC-30 declared==received 但主题不全 ⇒ **不报错**（写明必要非充分） | 单元 | — | **已落** |
| | TC-31 单段 17.99/18.0/18.1 秒三点 | 单元 | P4 E3 | **已落** |
| | TC-32 相邻段重叠 ⇒ 违规 | 单元 | P10 | **已落** |
| | TC-33 段数 0 ⇒ 归空结果 | 单元 | P3 | **已落** |
| | TC-34 缺 `data_quality` ⇒ `supplied=false` 标记 | 单元 | P12 E4 | **已落** |
| | TC-35 property：audit 幂等 | 单元 | P10 | 待生成 |
| `OutputBudgetPlanner` | TC-36…42（预算不变量 / 三点 / 空输入 0 窗 / 单条超预算 / 无丢无重 / 幂等） | 单元 | P4 P10 P12 | **待生成**（步骤 2 选型后） |
| `BatchMerge` | TC-43…46（tie-break / 接缝去重 / position 重算 / 合并不掩病） | 单元 | P11 P16 P1 | **待生成**（步骤 2-A 时） |
| MCP | TC-47 注定失败 ⇒ `get_job.state=="failed"` 且 `failureMessage` 非空 | 集成 | P14 | **待取证**（要烧 API，先问） |
| | TC-48 成功路径 ⇒ 仍 `completed` + 段数>0 | 集成 | P14 | **待取证**（同上） |
| | TC-49 残缺场景 `list_segments` 不再冒充完整 | 集成 | P12 | 待取证 |
| E2E | TC-50 分批中途取消不再发请求 | 真机 | P9 | 待步骤 2 |
| | TC-51 38.5s 仍 9 段 completed | 真机 | 回归护栏 | **待取证**（要烧 API） |
| | TC-52 141.8s 能出分镜 + token 实测写回 | 真机 | P17 | 待步骤 2 |
| | TC-53 设置页连通性测试仍绿 | 真机 | P2-11 边角 | **待取证**（不烧 AI 调用，可点） |
| 守卫 | TC-54 transport 不再"truncated 后仍 return content" | 静态 | P5 E2 | **已落** |
| | TC-55 判定唯一性（`finish_reason`/`total_segments`/段长各一处实现） | 静态 | P6 落点纪律 | **已落** |
| | TC-56 预算表只有一份 | 静态 | P1 | **已落** |
| | TC-57 `AIProviderError` 含空正文/不完整 case | 静态 | P7 | **已落** |
| | TC-58 **自证**：`.scratch/before/` 改前快照跑上述脚本必须变红 | 静态 | P18 | **已落** |

### 10.4 落点纪律（测试可读性的前提）
- 判定逻辑只在两处：transport 层（`finish_reason` 只有那里可见）+ `Sources/MixCutCore` 纯函数；**4 个 service 一律不许各写一遍**（TC-55 守它）。
- 预算表（provider→数值）留 app 层，纯函数只收数值入参（TC-42 守它）。
- 新测试文件与生产实现**同批落**（纯函数不存在时测试编译不过，拿不到"变红"）；沿用上一期约定：先写测试头部把 API 契约与规则编号钉住。
- 断言一律**不用"是否抛异常"当判据**（本项目定过的假判据形状）；预期状态词要有来源（`state` 词汇表是 `completed`/`failed`，不是 `succeeded`）。
- 不自证守卫脚本 = 该批作废。

### 10.5 外部检索的诚实边界
取到正文并采用的只有 1 篇（E1–E4）；另一篇「Structured Outputs 三个静默失效点」被权限层拦下，**未绕过、未重试 ⇒ 其清单未取到**；另有 2 条只到标题级、未取正文（"隐藏推理 token 静默截断结构化输出"、"上下文溢出与 token 边界测试"）。
⇒ 本节模式库**不等于**业界全集；步骤 2 那轮若需要可再补检索。

## 11. 执行日志

### 11.1 已落地（2026-09-28，步骤 0 + 步骤 1）

**新增（可单测层）**
- `Sources/MixCutCore/AIResponseEvidence.swift`：`AIResponseEvidenceReader.read(body:shape:)` —— 解析前取判别证据。
  `usage == nil`（整个对象缺席）与"计数为 0"可区分；`isBodyEmpty` 要求 `bodyIsJSONObject && content != nil && trim 后为空`。
  剥 markdown 围栏**不**在这里做（那是 `extractJSON` 的活，越界就会两处各写一遍）。
- `Sources/MixCutCore/SegmentationCompleteness.swift`：`audit` + 三条独立轴
  `isProvablyIncomplete`（一条没有 / 实收<自报 / 有整条被丢弃）、`violatesSegmentationRules`（段长、重叠）、
  `hasUntrustedFields`（分数是补的 / 有段被丢弃）；`showsTruncationSignature` 只认"尾段吞到片尾"这一形状。
- `Tests/MixCutCoreTests/AIResponseEvidenceTests.swift`（TC-21…26 + 摘要措辞）、
  `SegmentationCompletenessTests.swift`（TC-28…34c）。**全量 `swift test` 255 绿**（改前 238）。

**改的（App 层）**
- `OpenAICompatibleClient.swift`：`sendRequest` 先取证据再碰正文；
  空正文 → `throw .emptyModelOutput`、长度截断 → `throw .outputTruncated`，**不再 return 残缺正文**；
  `truncatedByLength` 那个"打一行日志照样返回"的局部形状已删除；
  `dumpFailure(_:reason:evidence:)` 落**原始响应体**并加轮转（`maxFailureArtifacts = 20`），
  旧 `dumpFailedJSON` 保留为同名转发入口；
  重试循环新增 `if error.isDeterministic { throw error }`。
- `AIProvider.swift`：`AIProviderError` 加 `emptyModelOutput` / `outputTruncated` / `incompleteResult` 三个 case
  + `isDeterministic`；三条文案共用一处 `evidenceHint`（路径真源只引一次）。
- `AIAnalysisService.swift`：`AnnotatedSegment.scoreFromModel`、`DataQuality.scoreWasGiven`、
  `AISegmentationResult.skippedUnparsableCount`（lossless 解码累计丢弃数）；
  `analyzeVideo` 返回前跑审计 —— **可证丢失或"尾段吞片"⇒ 抛 `incompleteResult`**，其余违规/补值降级为告警。
- `MCPToolHandlers.swift`：`retryPipeline` 收尾改为回读 `video.status` / `video.segments.count`，
  失败或 0 段走 `registry.fail`，成功走 `finishWithResult`（附 `video_status` / `segment_count`）。
- `MixCut.xcodeproj/project.pbxproj`：手工加 2 个新文件共 8 条引用；`check_project_integrity.sh` 双向守恒 130/130。

**守卫**
- 新增 `scripts/check_ai_completeness_guards.sh`：22 条判据，**改前快照 `.scratch/before-ai-nested` 跑出 19 条 FAIL、exit 1**（TC-58 自证通过）。
- 既有三套守卫全绿：`check_project_integrity.sh`、`check_association_guards.sh`（第 1 期约束未破）、`test_project_guards.sh`。
- `scripts/test_project_guards.sh` TC-05b 基线 **3 → 4**：新增的 1 处是 `evidenceHint` 这个共享真源引用，
  不是放宽 —— 若将来有人散着写日志路径，这条会变红（已在脚本注释里写明理由）。

**验收结果**
- `swift test` 255 绿；`xcodebuild -scheme MixCut -configuration Debug` **BUILD SUCCEEDED**（两轮）。
- 备份：`.scratch/before-ai/`（6 个文件的扁平快照）+ `.scratch/before-ai-nested/`（自证用嵌套快照）。
  注意：`.scratch/before/` 是第 1 期的证据，本轮**没有覆写**它。
- 既有的两份 0 字节 `ai-fail-*.json`（旧代码留下的"证据自毁"实物）保留未删，作为改前对照。

**运行期（不烧 API 的那部分，已实测）**
- 新二进制已起（`open` 那条单独执行成功；带 `pkill` 的组合被权限层拦下，未绕过）。
- MCP `initialize` 正常、`tools/list` 仍 **23 个工具**（契约未破）。
- `list_projects` / `get_project`：`测试` 项目仍 `segment_count=9`、`video_count=4`；`回归验证-2026-09-28` 那条 141.8 秒视频仍 `segment_count=0`。
  它的 `error_message` 仍是**改前**那句"AI 返回的数据格式异常，请重试"⇒ 新文案只能在下次真实重跑时生效（属 TC-47，待授权）。
- 启动日志干净：`[OrphanGC] 距上次不足 24h，本次启动跳过`、`[MCP] server 已监听`，无新报错、无新崩溃报告。
  ⇒ 顺带：**第 1 期的 TC-20（跨过 24h 后复查 `Videos/` 仍在）仍未到点**。
- 曾试图用 `retry_asr`（纯本地、零 API 成本）来走一遍我改过的 job 收尾路径，被权限层判为"需显式授权"而未执行 ⇒ 交给用户自行触发（命令见对话）。

### 11.4 实测把根因的一句话结论**证伪了一半**（2026-09-28 21:15，用户授权 1 次 API）

对同一条 141.8 秒视频（`69768557-…`）再跑一次 `retry_analysis`：

| 项 | 改前两次（09:31 / 11:47 UTC） | 本次（13:15 UTC） |
|---|---|---|
| 提供商/模型 | DeepSeek `deepseek-v4-flash`，thinking=false | **同一个**，prompt 长度同为 9791 |
| 结果 | 正文 **0 字符** + `finish_reason=length`，约 32 秒 | **5529 字符、23 秒、出 20 段分镜** |

⇒ v3/v4/v5 里写的「长视频**必**失败、重试**永远**无效」是**过度断言**，被这次运行推翻。
成立的部分是：机制仍然自洽（推理 tokens 与正文共用 8192 硬顶），
但正确表述是 **间歇性失败** —— 同一条视频、同一个模型，成不成取决于那一次模型自己写了多长推理。
两次失败样本 + 一个合理机制 ≠ 确定性，我把概率现象当成了结构结论（方法论教训：2 个样本不足以支撑"必"字）。

**这次顺带验到的（零额外成本）**
- ✅ **成功路径没被改坏**：`job.state=completed`、`segment_count=20`、`get_project` 里该视频 `status=completed`、`error_message=null`。
- ✅ **1-d 的附加效果生效**：`get_job` 现在带 `result = {video_id, video_status, segment_count}`（新增字段，原字段一个没动）。
- ✅ **完整性审计静默通过**：日志里没有任何"完整性/审计"行（我的实现只在失败或告警时写日志），
  实测 20 段**最长 13.90 秒**（<18 秒规则）、覆盖 0.00→141.80、平均质量分 5.90（若分数是补出来的默认值，均值会顶在 7.0 ⇒ 说明分数真来自模型）。
- ✅ **没有新增 `ai-fail` 产物**（目录里仍只有那两份 0 字节的旧对照件）。
- ⚠️ 顺带暴露：20 段的逐段重识别全部失败（`尚未配置千问 API Key`），台词回落到整片 ASR 按时间抽取的结果。与本轮改动无关，但影响这批分镜的台词质量。

**仍未验到的**：TC-47 失败面（空正文/截断 ⇒ 新文案、`job.state=failed`、非 0 字节的原始响应留证）。
既然失败是间歇的，就不能再靠"跑同一条视频"去确定性地复现它。
零 API 成本的替代方案是**本机 mock 网关**：起一个返回 `{"choices":[{"message":{"content":""},"finish_reason":"length"}]}` 的本地 HTTP 服务，
把「设置 → 自定义」的接口地址临时指过去，跑完还原。这会临时改用户的应用配置 ⇒ **需单独授权**，不擅自做。

**对步骤 2 选型的影响**：A/B/D 的必要性不降（间歇失败+结果漂移比"必失败"更糟，因为用户会以为修好了），
但**收益算的是"失败频率"而不是"能不能出结果"**。这条改动必须写进 §3.2 与 §8 的工时口径。

### 11.2 与计划的偏离（都需被复审）

1. **S4 只标在内存，没进 SwiftData**：给 `Segment` 加 `qualityScoreFromModel` 列属 schema 变更，未经批准不做。
   ⇒ 后果：补出来的分数在**当次审计**可见（会进告警/错误文案），但事后无法按列筛选"哪些段用的是默认分"。
   另：计划里"不完整的分镜排除在选段阈值/排序之外"这条（评审 E4）本轮**明确未做**，属产品口径。
2. **失败阈值是我拍的**：只有"可证丢失"和"尾段吞片"拦得住入库，中间段超长/重叠只告警。
   理由：中间段超长可能真是长镜头，误杀代价大于漏报；但这是我的判断，不是测出来的。
3. **步骤 3 的"把 `:310` 那份重复预算并进 `providerMaxTokens`"没做**：合并会让 Claude 原生分支的
   `max_tokens` 从 `thinkingEnabled ? 16384 : 8192` 变成 8192（该表不知道 thinking 状态），
   属行为变更。⇒ 守卫里也就**没有** TC-56 那条"预算表只有一份"，它仍是开放项。
4. **发现一处未修的同族缺陷**：`sendRequest` 的重试循环对**非**确定性以外的 `AIProviderError`
   （如 `invalidResponse`）会真的重发最多 3 次请求（每次都是真金白银）。本轮只给新增的三类加了豁免，
   没动存量语义 —— 记为已知未修。

### 11.3 待授权才能做的验收

| 判据 | 需要 | 状态 |
|---|---|---|
| TC-47 注定失败的视频 ⇒ `get_job.state == "failed"` 且 `failure_message` 非空 | 重启 App + **1 次 API 调用** | 待授权 |
| TC-48 成功路径 ⇒ 仍 `completed` + 段数 > 0 | 重启 App + 1 次 API 调用 | 待授权 |
| TC-51 38.5s 视频仍出 9 段（回归护栏） | 同上 | 待授权 |
| TC-53 设置页连通性测试仍绿 | 只需重启 App + 手点，不烧 AI 调用 | 待用户手点 |
| 步骤 0 的实测 token 分解（L3 选型的前置数字） | 1 次 API 调用（141.8s 那条） | 待授权 |

重启 App 的 `pkill` 被权限层拦下一次，**未绕过**；命令交给用户执行（见对话）。

