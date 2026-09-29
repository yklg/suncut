# ASR 档位可选 + 云端/本地可切 · 计划 v14（2026-09-29，宽窗那套已删除）

> **v13 → v14：宽窗（扩窗再裁回）整块删除，本计划里所有关于它的叙述转为历史记录（§11.9）。**
> 留下来的只有**简体风格锚 + 锚回吐自检 + 引擎能力表**这三件主路径每天在用的东西。
> 静态读数：`swift test` 301、守卫 37、自证注入树 33 红、Debug 构建 SUCCEEDED；⚠️ 运行期那一格仍待探针重跑。

> **v12 → v13：F（换引擎）从"案头待查"变成"跑过一遍"，结论没变但语气变了（§11.8）。**
> 一句反直觉的：SenseVoice 在本仓这 4 段上**没有把错字修少**（可判定错字 4/62，与今天的带锚 whisper 打平），
> 它赢在**不漂繁体 + 词级时间戳原生 + 体积小一个数量级**。⇒ "换引擎能不能救台词质量"这条**仍未证明**，
> 缺的不是第二颗模型，是这 17.1 秒的**人工转写基准**。
> **同一天他据此拍了板：「先不换了」** ⇒ F 收档、生产路径维持 large-v3 + 风格锚，**错字这条线只剩 LLM 清洗一条出路**（§11.8 末尾）。

> **v11 → v12：v11 里"待另立"的那条质量问题已经另立计划并做完（见 §11）。**
> 结论三句：① **简体风格锚**（与业务内容零交集的固定 prompt）已生效，切窗出繁体这条在主路径上被治好；
> ② v11 推测的"扩窗能修"被**两遍实测否掉**（宽窗在这份素材上 4 段只有 1 段产出）⇒ 宽窗整套实现但**默认关**、带活入口；
> ③ 错字这条线**不在风格锚射程内**，出路只剩换引擎（F）或既有 LLM 清洗 —— 本计划的档位结论不受影响，但"台词质量"别当成已解决。
> 另有一条与代码无关但会反复咬人的取证纪律写进 §11.5（App 从终端起探针必须 `</dev/null`）。

> **v10 → v11：两处新事实，其中一处改了问题的归属层。**
> ① 打包链已在隔离目录**真跑通**（§8.9）：5 颗 universal、兜底件老系统校验全过，且新编的包内 whisper **实测可用**（12 秒音频 7.2s 出字、依赖只有系统框架、输出与 Homebrew 那颗逐字节相同）；但构建期那行 large-v3 下载 URL 仍未下过一遍（本次用本机同字节文件顶替），产物也未装进真树。
> ② "切窗出繁体"由推测升级为**受控对照已证**（§2 追加二）：窗口长度是唯一变量，3.067 秒出繁体+错字、12 秒简体正确。
>    ⇒ 这条质量问题的归属层从"模型/档位"移到**切窗策略**（`SegmentTranscriber` 取窗那一环），修它不在本计划第二批范围内，待另立。
>    **（v12 更正：已另立并落地，结论与实测见 §11；本行保留是为了留住"当初它被误归到模型层"这个事实。）**

> **v9 → v10：设计未改，只是把"执行到哪"如实记账。§8.3 的第二批 7 项已全部落地（§8.4…§8.7），收官状态与仍未验的 6 条列在 §8.8。**
> v10 有两处**实现期长出来的小设计**（不改红线，但改了核心公开类型，故记在这里）：
> ① `ModelReport` 加 `detected: [ModelFile]`（按挑档顺序的全候选表）—— 界面要报「另检测到 base（未使用）」，
>    而"检测到哪些"与"用了哪颗"必须出自同一次扫描，否则 §6 的同源判据（R3）从结构上就没法满足；补 TC-109 钉住"第 0 个即 selected"。
> ② `ModelRoot` / `ASRPreference` / `ASREngine` 的**中文措辞**扩展放在 App 侧 `ASRSettings.swift`，不进 MixCutCore
>    —— 核心层留规则，界面措辞归界面（与 `TextProvenance.displayLabel` 的取舍不同，那处是能力面也要用的字符串）。

> **v9 只做一件事：把 test-coverage-expander 对 §3 的覆盖评估并成 §10 测试层（TC-61…TC-108，八条一般规则 + 差距矩阵 + 用例清单）。§3 的设计未改，八条红线未动。**
> v2 实测收敛 → v3 吃架构评审 → v4/v5 吃两轮方案评审 → v6 收三问定案并加 R8 → v7 把 R8 接进系统已有的陈旧抽象
> → **v8 吃第四轮方案评审（tech-solution-review 对 v7 的结论：有条件落地，2 条 P0 + 4 条 P1 + 2 条 P2，全部并入）。**
> v8 的两条 P0 都是**边界纪律**：① 新宿主模块 `ASRPolicy` 不许碰存储（否则纯函数包被污染，"下沉=可测"这条方法论在本项目失效）；
> ② 陈旧判定必须有**一个聚合入口**，不许靠两个消费点各自记得多调一次（同一规则两处各写一遍，本项目已吃过两次亏）。
> 已定案（你拍的）：默认引擎=强制本地 · 整片与逐段恒 large-v3 · 台词来源加列 · 包内换 large-v3 · 磁盘优先 · R1 走 b2。
> **仍未拍**：§3.7 B 案（文本候选 + 生效指针）—— v8 的工时与测试覆盖都**不含** B 案。

## 0. v7 → v8 变更表（v8→v9 未改设计，只新增 §10 测试层）

| # | 评审结论 | v7 的写法 | v8 改成 |
|---|---|---|---|
| 1（P0） | 新宿主可能把纯函数包弄脏（`Sources/MixCutCore/` 现在**零 `UserDefaults` 引用**，已核） | §3.1 让 `ASRPolicy` 同时持 `defaultPreference` 并被视图取默认值，没说"当前值从哪来" | **拆两样**：`ASRPolicy`（MixCutCore，只有常量与规则）+ `ASRSettings`（App 侧，唯一读写 UserDefaults 的地方）。决策函数**只收入参** `currentPreference`。新增守卫：`grep UserDefaults Sources/MixCutCore/` 必须为空 |
| 2（P0） | 两套陈旧 API 并存 = 第三处必漏 | §3.3③ 在 `MCPSegmentToolHandlers.swift:45-47` 与 `SegmentVariantInspector.swift:80-82` **各自再加一次** `checkSource` | 出**聚合入口** `DubStaleness.checkAll(...)`（一次调用合两维），两处调用点**各改一次**调用而非各加一次；`check` 降为内部实现，既有 5 个测试（`DubStalenessTests.swift`）保持测它、不动 |
| 3（P1） | 确认弹窗没分入口类型 | R8 写"整批重提取前给一次可见确认" | R8 补作用域：**确认只针对用户主动发起的整批重听**；自动链（`ImportViewModel:384/:657`）不弹窗但必须写来源 |
| 4（P1） | `generatedFor*` 还兼时长职责 | 未声明 | §3.3 明写：`MCPSegmentToolHandlers.swift:375` 用 `generatedForEndFrame - generatedForStartFrame` 算时长，本轮**不动那两字段语义**，只加 hash 字段 |
| 5（P1） | 三个 schema 变更可被读成分两次发布 | §3.3/§3.8 分两节，未约束 | §7 加硬约束：**三字段同一轮 bump、同一次"旧版本读新库"验证**（半个来源体系比一次都不做更难解释） |
| 6（P1） | 逐段串行会拖慢导入，无人报警 | 未估 | §6 加判据：同一条素材导入端到端时间**前后对比**写回 §2；进度须显示"逐段重听 k/n"（今天无 Key 时它是秒失败回落，体感差是新出现的） |
| 7（P2） | 日志文案真源会再多一处 | 未预判 | 新提示一律复用 `AIProvider.swift` 那处 `evidenceHint` 型真源；若确需第 5 处，按纪律改 `scripts/test_project_guards.sh:36`（现断言 `MixLog.logFileURL` 恰 4 处）并写原因，**不许为让它绿而放宽** |
| 8（P2） | 旧数据观感 | 只说显示"旧数据·未记录来源" | 补：`unknownLegacy` 用**中性样式**，`get_asr_status` 里它是统计项不是错误项（否则升级当天全库"看起来坏了"） |
| 附 | 好消息，省一件事 | — | `scripts/check_project_integrity.sh` 无硬计数基线（`:26-46` 是源码树↔pbxproj 双向守恒），新增 4 个文件**不需要改任何数字**，加完引用它自然转绿 |
| 工时 | — | 9.25 小时 | **10.25 小时**（+`ASRSettings` 拆分与守卫 0.25h、+`checkAll` 两处调用改造 0.25h、+进度与时长判据 0.25h、+新守卫 0.25h） |

## 0.1 v6 → v7 变更表（上一轮，保留作历史；其中 A′ 已被 §0 第 2 项取代：改为聚合入口而非各加一次）

| # | 评审结论 | v6 的写法 | v7 改成 |
|---|---|---|---|
| A（P0，非遮盖不达标） | R8 把历史放进不可查询的日志，绕过了系统里**已有**的陈旧抽象 | 「覆盖前把旧值写日志，列里只存最新来源」 | 改为**接进 `DubStaleness`**：`SegmentDub` 记"生成时看到的那句原台词"的哈希，原台词被换 ⇒ 已生成配音自动判 `stale` 且原因可区分。UI 与 MCP 的既有消费点（`SegmentVariantInspector.swift:83-86`、`MCPSegmentToolHandlers.swift:48-52`）**无需新增分支就获得报警** |
| A′ | 接进去会不会扯坏现有判定？ | 未评估 | **不动 `DubStaleness.check` 的 4 参数签名**（`DubStaleness.swift:52-55`），而是新增一个独立纯函数维度 ⇒ 它那 **5 个已有测试**（`DubStalenessTests.swift`）一行不改、两处调用方不重写 |
| B（P0/P1，摆成待拍） | "覆盖本身"才是根问题，光防无声覆盖不够 | v6 只有单值 + 来源 | §3.7 摊开 **B 案：文本候选 + 生效指针**，并指出仓库里**已有三个同形状先例**（`Segment.swift:106/:112` 替换画面 + `pictureShowsReplaced`、`SegmentDub.textVariantIndex:12` 改写版池）。等你拍，不默认做 |
| C（P1） | 来源只标 `Segment` 会漏一层 | 未提 `Video` 层 | §3.8：`Video` 的**三个文本载体**（`transcript:42`、`asrSentencesData:44`、`asrWordsData:43`）加一档 `asrSource`；否则段级是新引擎、片级还是 base 年代旧档，你要避免的"混用"继续存在 |
| D（P1） | 两个新默认值没有唯一宿主 | "恒用 large-v3"写在 §3.1、"默认本地"写在 §3.2（视图若自带默认就是第三处） | 新增 `Sources/MixCutCore/ASRPolicy.swift`：**引擎档位、默认偏好、根顺序、下载目标四样同住一处**，视图与 `get_asr_status` 只读它 |
| E（P1） | 来源枚举缺一种 | 无 `uploadedClip` | 补 `uploadedClip`（`ImportViewModel.swift:528` 那句文本来自用户上传的自建分镜文件整听，既非整片切片也非逐段重听）；并补 `boundaryShift` 规则（`:903/:916` 是把字**在相邻两段之间搬**，一段内容可来自两段来源） |
| F（P1） | 唯一写入口把退路当主路 | 首选"编译器强制 `private(set)`"，退化为守卫 | **默认按"方法 + 守卫允许清单"设计**（本仓 `private(set)` 在 `MixCut/Models/` **零先例**；已有先例是 `Segment.setFrameRange:230`、`ProjectVideo.associate:31`）；`private(set)` 只作加分试验，成不成都不影响计划成立 |
| 新增 G | 迁移与"只在真变了时才写"没有形状依据 | 未引 | 仓库已有 **3 个一次性修复守卫先例**（`didFixMissingSemanticTypes_v1`、`didBackfillSegmentFrames_v1`、`didCleanTranscripts_v1`，`MixCutApp.swift:330/:484/:509`），且那支清洗正是**只在 `cleaned != original` 时才写**（`:518`）⇒ 来源列的迁移与 `cleaned` 语义照这个形状做，不许每次启动都把手改的来源刷掉 |
| 删 | `previousText` 与来源列/陈旧机制三处并存 | 门面结果里带 `previousText` | **删除该字段**（旧值只有一条路：哈希进陈旧判定、来源进列） |
| 工时 | — | 8.0 小时 | **9.25 小时**（+A 陈旧联动 0.75h、+C Video 层来源 0.5h）；B 案若采纳另 **+2 小时** |

## 1. 现状事实（新增 19-21，其余同 v6 已复核）

| # | 事实 | 位置 |
|---|---|---|
| 1-8 | 就绪判定不看档位；布尔被 3 个界面同步消费；识别路径藏自动下载；查找按根优先；打包内置 turbo；`Resources/bin` 是 folder reference；构建闸门 `WMIN=1600000000`；`turbo` 名写死 4 处 | 同 v6（`ASRService.swift:371-375/:696-741/:768-772/:935-937`、`build_universal_binaries.sh:112-121`、`project.pbxproj:166`、`SettingsView.swift:775`、`FileHelper.swift:159`、`SidebarView.swift:282`、`WelcomeView.swift:122`） |
| 9-13 | 逐段 3 处实现 / 空识别当成功 / 格式不对称 / 能力不对称 / CPU 兜底超时 | `ImportViewModel.swift:1101/:1225/:1234`、`SegmentLibraryViewModel.swift:531`、`FFmpegRunner.swift:459-468`、`ASRService.swift:172/:386-400/:443-448`、`DubbingViewModel.swift:534` |
| 14 | **`Segment.text` 有 10 个裸写入点**：ASR 覆盖 4、相邻段搬字 2、界面手改 1、Agent 写 1、启动清洗 1、上传段 1 | `ImportViewModel.swift:528/:903/:916/:1116/:1234`、`SegmentLibraryViewModel.swift:408/:555`、`MixCutApp.swift:520`、`SegmentLibraryView.swift:1113`、`MCPSegmentToolHandlers.swift:174` |
| 15-18 | MCP 只绑 127.0.0.1 无鉴权且既有输出含绝对路径；工具名单被逐名硬断 23；偏好 key 用宿主静态常量 + `@AppStorage`；只有 application target、`DebugSelfTest` 7 支 ASR 探针全云端 | `MCPServer.swift:5/:32`、`AgentToolCatalogTests.swift:7`、`SettingsView.swift:25-26`、`Package.swift`、`DebugSelfTest.swift:178+` |
| **19** | **系统里已经有"文本变了要让派生物报警"的一等抽象**：`StalenessReason.textHashChanged` + `DubStaleness.check(snapshot:currentStartFrame:currentEndFrame:currentTextHash:)`；被 UI 与 MCP 两处消费；已有 5 个测试。但它盯的是 `dub.rewrittenText` 的哈希（**改写版**），**不看 `Segment.text`（原台词）** ⇒ 重提取换掉原台词，现有机制一声不响 | `Sources/MixCutCore/DubStaleness.swift:5-12/:52-55`、`SegmentVariantInspector.swift:83-86`、`MCPSegmentToolHandlers.swift:48-52`、`DubbingViewModel.swift:476`、`SegmentDub.swift:21-23` |
| **20** | 台词文本其实有**两层三个载体**：段级 `Segment.text`；片级 `Video.transcript` / `asrSentencesData` / `asrWordsData`。片级被界面 6 处与导入流程消费（含 `ImportViewModel:294`、`ImportView:335/:608/:777`） | `Video.swift:42-44`、`ImportViewModel.swift:294`、`ImportView.swift:289/:335/:459/:608/:777` |
| **21** | 仓库已有 **3 个一次性数据修复守卫**，且清洗那支**只在内容真变时才写** ⇒ 迁移与"来源不被反复刷掉"有现成形状可抄 | `MixCutApp.swift:330/:484/:509`（key 三个）、`:518`（`cleaned != original` 才写） |

## 2. 实测数据（v10 追加一条门面探针读数）

整片（141.8 秒素材）：base 4-5 秒 / large-v3 **39 秒**，只有 large-v3 写对卖点词。
逐段（同一素材 9.6 秒窗口）：**large-v3 单段 4.5 秒**（加载冷 2.5s / 热 0.8s）、base 单段 **0.45 秒**；整批 17-20 段推算 **1.2-1.5 分钟**（不含每段 ffmpeg 切窗与进程启动）。
R8 的证据：同一句话整片跑「给你们**发货**」、切窗跑「给你们**发火**」；base 切窗另有 4 处错字且**整段繁体**（N=1，形状自洽 ⇒ 按风险处理，不当必然）。

**2026-09-29 追加（真 App 门面探针，同一条素材的前 2 段，`segasr-*` 残留 0）**：
逐段本机识别耗时 **4.8s / 3.4s**（与上面 4.5s 的推算同量级 ⇒ 门面没有引入额外开销，`format=wav`、`tier=large-v3`、`root=你下载的模型文件夹` 三项也与设置页同源）。
⚠️ 新证据：**换成 large-v3 之后，切窗仍然出繁体** —— seg_001「秋冬一到嘴就**乾這**骨頭咬一口全是水」、seg_002「有干油皂的季节苹果梨都吃腻了…」（同一段里繁简混排）。
⇒ 此前"整段繁体"不是 base 档专属，而是**切窗这条路径的属性**（短窗少了上下文，模型在繁简之间漂）。这把 R8 的理由从"覆盖会丢字"加重成"**重听可能把对的改成错的**"：整片听写出来的简体台词被逐段重认覆盖后，可能出现繁混。
（N=2，且探针不写库，所以库里那两段仍是原值 —— 形状与 §6 的判据一致，**不当必然**，但它足以让"整批重听"必须带确认这件事成立。）

**2026-09-29 追加二：受控对照，窗口长度是唯一变量（把上面那条推测升级为已证）**

同一条素材、同一颗 `ggml-large-v3.bin`（3095033483 字节，魔数 `lmgg`）、同一颗 whisper-cli、同一组 flags（`-l zh`），只换喂进去的时长：

| 窗口 | 输出 | 判定 |
|---|---|---|
| 0 → 12.0 秒 | 秋冬一到嘴就**干** / **这果子**咬了一口全是水 | 简体、正确 |
| 0 → 3.067 秒（= seg_001 的真实边界，帧 0~92） | 秋冬一到嘴就**乾** / **這骨頭**咬一口全是水 | 繁体 + "果子"听成"骨头" |

⇒ 退化由**短窗缺上下文**引起，与档位、引擎构建、App 代码三者都无关。
⇒ 库里 seg_001 现值「秋冬一刀嘴就干这本贴咬一口全是水」是**旧一轮**（档位/引擎与现在不同）整片识别按帧切出来的残句，**不能**拿来当窗口长度的对照值。
⇒ 修的方向在**切窗策略**（给上下文余量 / 短段门槛 / 合并相邻段一起听再切回），**不在**后处理繁简转换——转换救不回"骨头"这类错字。

## 3. 本轮要做的事

### 3.0 八条红线（同 v6，R8 的落地方式改了）

R1 下载只由按钮触发 · R2 `isModelAvailable()` 锁 L1 · R3 一处真源 · R4 门面唯一出口 · R5 格式由引擎决定 · R6 偏好只管逐段覆盖 · R7 打包链与运行期同表 ·
**R8 重提取不许无条件覆盖**：只在内容真变时写；写之前旧值与旧来源必须先有去处（v8 的去处 = §3.3 的陈旧联动 + 来源列，**不是日志**）；`emptyAudio`/失败/被拒一律不写。
**确认的作用域（v8 补）**：可见确认**只针对用户主动发起的整批重听**；自动链（`ImportViewModel.swift:384/:657`）不弹窗——那时库里还没有"旧台词"可保护——但**必须写来源**。

### 3.1 `ASRPolicy` + `ASRSettings`（P0-1：规则与状态分家）

- `Sources/MixCutCore/ASRPolicy.swift`（**纯常量与规则，不读任何外部状态**）：`engineTier = large-v3`、`defaultPreference = 本地`、`rootOrder = [磁盘, 包内, 旧缓存, 系统目录]`、`downloadTarget`。
- `MixCut/Services/ASR/ASRSettings.swift`（App 侧，**唯一**允许读写 UserDefaults 的地方，key 作宿主静态常量，照 `SettingsView.swift:25-26` 惯例）：提供**当前**偏好，缺省时回落 `ASRPolicy.defaultPreference`。
- **决策函数只收入参** `currentPreference`，由调用方（视图 / 门面 / status）从 `ASRSettings` 取好后传入 ⇒ `Sources/MixCutCore/` 保持零 `UserDefaults`（现状已核为零）。
- 新增守卫一条：`grep -r UserDefaults Sources/MixCutCore/` 必须为空，**改前快照（若有人先在包里读存储）必须让它变红**。
- 设置页、`get_asr_status`、打包脚本注释一律引用这两个宿主，杜绝"第三个默认值"。

### 3.2 档位目录（角色：识别 + 如实报告 + 下载目标）

`WhisperModelCatalog.swift`：档位表（只 large-v3 需要精确期望值 3,095,033,483；其余档**如实显示 stat 到的体积**，取消"联网取近似值"这条前置）、`detect(candidates:)` 带**根类型**并按 `ASRPolicy.rootOrder` 选，四层就绪 L1~L4，L2~L4 **不上主线程**（三处视图只问 L1）。
设置页措辞：「语音模型：large-v3（2.9 GB）· 来自你下载的文件夹 · 另检测到 base（未使用）」。

### 3.3 来源列 + 唯一写入口 + **陈旧联动聚合入口**（v7-v8 主改动）

**① 来源列**：`Segment.textSource`，枚举 `unknownLegacy` / `fullVideoSlice` / `segmentLocal` / `segmentCloud` / `uploadedClip` / `manualEdit` / `agentEdit` / `cleaned` / `boundaryShift`。
默认值 `unknownLegacy`（旧数据·未记录来源，界面就显示这五个字，**不许显示成任何引擎名**）。

**② 唯一写入口**：`Segment.setText(_:_:source:)`（照 `setFrameRange:230` / `associate:31` 的既有形状）改 10 处裸赋值。
每条搬运规则定死：`:903/:916` 相邻搬字 → `boundaryShift`（**不许猜测继承邻段来源**）；`MixCutApp:520` 清洗 → 仅当内容真变时改 `cleaned`（照 `:518` 形状，且带一次性守卫）；界面手改 → `manualEdit`；MCP → `agentEdit`。
`private(set)` 当**加分试验**（`MixCut/Models/` 零先例），主路是方法 + 守卫允许清单。

**③ 陈旧联动（P0-2：一个聚合入口，不是两处各加一次）**：`SegmentDub` 新增 `generatedForSourceTextHash: String = ""`（默认空 = 旧数据，照 `generatedForTextHash:23` 的形状；`DubStaleness.swift:83` 已把"空串=未配置占位"当约定，与之一致），在**唯一那个写点** `DubbingViewModel.swift:474-476` 同时记录。
判定收进**一个公开聚合入口** `DubStaleness.checkAll(snapshot:currentStartFrame:currentEndFrame:currentRewrittenTextHash:currentSourceTextHash:) -> CheckResult`，`StalenessReason` 加一档 `sourceTextChanged(current:recorded:)`；现有 `check` **降为内部实现**，两处消费点（`MCPSegmentToolHandlers.swift:45-47`、`SegmentVariantInspector.swift:80-82`）**各改一次调用**（不是各加一次），这样将来第三个消费点天然拿齐两维。既有 **5 个测试**（`DubStalenessTests.swift`）不动。
`generatedForSourceTextHash == ""` 的旧数据**不许报 stale**（无从判起），只报"未记录"。
**明写不动的东西**：`generatedForStartFrame/EndFrame` 另兼**时长**职责（`MCPSegmentToolHandlers.swift:375` 用它俩算时长），本轮只加 hash 字段，**不许顺手统一或重构那两字段的语义**。

**④ 删** `SegmentTranscriptionResult.previousText`。

### 3.4 门面与决策（同 v6，去掉旧值副本）

`ASREngineDecision` 9 格表（3 purpose × 3 偏好，含 `单段整听 × 云端` 这格的显式定义）；`SegmentTranscriber` actor 门面：问决策 → 按引擎切格式 → 送引擎 → 判空 → 计时 → `outcome` 六档 + `engine/tier/rootKind/format/elapsed`。
串行不并行；逐段超时上限 + 每段间查取消 + 连续 K 段失败即止 + **如实报失败几段**（老机器 CPU 兜底慢也不暗换档，只显式提示）。
调用点：`ImportViewModel:1101/:1225`、`SegmentLibraryViewModel:531` 三处实现收敛；`:384/:657` 消费 `outcome`；两 VM 的云端客户端字段删除；防重入留 VM；Toast 文案按 `engine` 生成；新增 `ASRService.transcribeAudioFile(path:)`。

### 3.5 能力面 `get_asr_status`（同 v6）

报：用哪颗 / 在包内还是磁盘 / 四层卡在哪 / 偏好 / `hasQwenKey`（只布尔，不回显片段）/ 本次走哪条及原因 / **各来源档的段数**（含 `unknownLegacy` 多少段）/ **陈旧联动结果**（原台词变过而配音未重生成的段数）。
约束：同源（只调 `ASRPolicy`/决策/catalog）、23→24 属有意契约变更且**改前快照必须变红**、`mcp_smoke_test.sh:22` 保持红且不算验证。

### 3.6 打包链（R7）：脚本改两行

`WMODEL` → `ggml-large-v3.bin`、`WMIN` → 3.0e9 级，注释指认 `ASRPolicy`/catalog 为真源。**先建表再动脚本**。根顺序验收不需要真打包（往 `Resources/bin` 放一颗 base 冒充内置档，零下载、测完还原）；真跑打包（2.9GB + 源码编译）须单独授权。

### 3.7 **待你拍的一问（B 案）**：要不要"文本候选 + 生效指针"

评审的判断：A 案（v7 已写）根治的是"**无声**覆盖"；B 案根治的是"**覆盖**"本身。
仓库里已经有三个同形状先例，B 不是新发明：`Segment.swift:106/:112`（替换画面 + `pictureShowsReplaced` 生效指针）、`SegmentDub.textVariantIndex:12`（改写版变体池）。

- **B 案长什么样**：一个分镜的台词可有 N 个候选（每个带 文本 + 来源 + 引擎 + 档位 + 时间），字段 `text` 仍是"当前生效那条"（下游零改动），另加候选集合与"当前生效"指针；素材库给一个"上一版/切换"入口。
- 好处：切窗 vs 整片之争变成**可切换的两个候选**，「发火/发货」不再是事故；手改的那条永远在候选里，不怕被重提取盖。
- 代价：比来源列多约 **2 小时**；schema 变更更大（新关系）；双击编辑框语义要改（编辑的是当前候选）；MCP `update_segment_text` 要决定写候选还是写生效指针（这是契约问题，不能默认）。
- **不拍就按 A 案实施**（A 已能防"无声"，只是丢了"可回看/可切换"）。

### 3.8 `Video` 层来源（C 项）

`Video` 加一档 `asrSource`（引擎 + 档位 + 日期），覆盖 `transcript` / `asrSentencesData` 两个文本载体（`asrWordsData` 只在字级用、不写文本，**本轮不标**，并把这个取舍写在代码注释里）。
理由：那 17 段的母体就是 base 年代的片级听写（事实 18/20）；段级换了引擎而片级仍无标记，"混用"会以片-段不一致的形式留着。
迁移照事实 21：一次性守卫 + 只在真写文本时更新。

## 4. 已落改动记账（v1→v2，之后未动代码）

同 v6：查找表/下载表加了 `ggml-large-v3`；模型落位并**从进程参数取证**（仅 dev 构建成立）；`~/Downloads/` 原件已按你指示删除（删前两份 `md5` 相同 = `186b3b498020462afb7f48a8a087110e`）；编译 + 三套守卫 + `swift test` 255 绿。**§3.1~§3.8 全未动。**

## 5. 成本与纪律

DeepSeek 今天累计 **2 次**（13:15 你授权；14:14 我误用 `retry_asr`，20 段变 17 段）。纪律：① 验收不用 `retry_asr`；② `retry_asr` 描述诚实、缺陷在 `AgentToolCatalog.swift:101` 的 `destructiveHint:false`（改 true 待你点头）；③ 模型相关取证必须标 dev / 打包；④ 本轮零 API 成本。

## 6. 验收判据（v8 新增 4 组，其余同 v6/v7）

- **陈旧联动（走用户入口）**：挑一个**已生成过配音**的分镜，重提取台词把原句换掉 ⇒ 该分镜的配音变体必须显示 `stale`，且原因能读出"**原台词变了**"而不是"改写版变了"；反过来只改改写版时，仍走原有那条原因。**反向**：`generatedForSourceTextHash == ""` 的旧数据不得报 stale。**聚合入口自证**：`MCPSegmentToolHandlers.swift:45-47` 与 `SegmentVariantInspector.swift:80-82` 两处必须都改调 `checkAll`（守卫断言：`MixCut/` 内不得再有对 `DubStaleness.check(` 的直接调用）。
- **导入时长回归（P1-6）**：同一条素材（141.8 秒那条）导入端到端时间**前后对比**写回 §2；逐段阶段必须有"逐段重听 k/n"的可见进度；若走 CPU 兜底二进制，日志里要能看出是哪一段慢。
- **纯函数边界（P0-1）**：`grep -r UserDefaults Sources/MixCutCore/` 为空；`ASREngineDecision` 的用例**只用入参构造**，不出现任何存储读取。
- **旧数据观感（P2-8）**：升级后 `unknownLegacy` 在素材库为**中性样式**、在 `get_asr_status` 记为统计项；断言它**不进错误计数**（否则升级当天全库看起来都坏了）。
- **日志真源（P2-7）**：新增用户文案复用 `AIProvider.swift` 的 `evidenceHint` 型真源；`scripts/test_project_guards.sh:36` 现断言 `MixLog.logFileURL` 恰 4 处，若确需第 5 处**按纪律改基线并写原因**，不许放宽判据。
- **来源不被反复刷**：同一库连开两次 App，`manualEdit` 的段不得变成 `cleaned`（照事实 21 的守卫形状）。
- **搬字规则用例**：调边界把字从 A 段并进 B 段 ⇒ B 段来源 = `boundaryShift`，**不是** A 段原来源。
- **`uploadedClip` 用例**：上传一个自建分镜文件 ⇒ 该段来源 = `uploadedClip`，不落在 `fullVideoSlice`。
- **旧库判据**：升级后 `get_asr_status` 与界面必须报「N 段 = 旧数据·未记录来源」，不得显示任何引擎名。
- **R8 判据**：重提取失败 / 空识别时原句必须一字不动；整批重提取前必须有一次可见确认。
- 其余（三形态根顺序、`detect` 与 `findWhisperCppModel` 一致、9 格表、R5/R6、拆分入口、`private(set)` 试验结果、旧版本读新库、守卫改前快照必须变红）同 v6 §6。

## 7. 工时与待拍

| 项 | 内容 | 约 |
|---|---|---|
| §3.1+§3.2 | `ASRPolicy` + `ASRSettings` 分家 + catalog（识别/报告/下载目标）+ 四层就绪 + 根顺序 + 主线程分层 + 界面措辞 + 拆隐式下载 | 2.5 小时 |
| §3.3 | 来源列 + 唯一写入口（10 处改造）+ **`checkAll` 聚合入口与两处调用改造** + 迁移守卫 | 2.0 小时 |
| §3.4 | 9 格决策表 + 门面 + 三处实现收敛 + 批次超时取消 + **"逐段重听 k/n"进度** | 3.25 小时 |
| §3.5 | `get_asr_status` + 同源 + 名单断言 + 只读性自证 | 0.75 小时 |
| §3.6 | 打包脚本两行 + R7 守卫 | 0.5 小时 |
| §3.8 | `Video` 层来源 + 迁移 | 0.5 小时 |
| 守卫 | 8 条新守卫（含 `Sources` 禁 UserDefaults、禁直调 `check`）+ 改前快照自证 | 0.75 小时 |
| §10 测试层 | 48 条用例的展开（单测本体已含在各节）+ **TC-99 需要的"迁移前 store"夹具** | 0.75 小时 |
| | **合计（A 案）** | **11.0 小时**，零 API 成本 |
| §3.7-B | 文本候选 + 生效指针 + 素材库切换入口 + MCP 契约决定 | **+2 小时**（待拍） |

**硬约束（P1-5）**：`Segment.textSource`、`SegmentDub.generatedForSourceTextHash`、`Video.asrSource` 三个字段**同一轮 bump、同一次"旧版本读新库"验证**——分两次发布会出现"半个来源体系"（列有了、配音快照没有），比一次都不做更难解释，也不允许拿它当"渐进交付"的借口。

**待你拍 / 待授权**：① §3.7 B 案要不要做；② 真跑一次打包（2.9GB 下载 + 源码编译）；③ `AgentToolCatalog.swift:101` 的 `destructiveHint` 改 true；④ 删掉成为摆设的 base（141MB）；⑤ 任何再烧 DeepSeek 的取证；⑥ §10.5 的开工顺序：**先出可下沉那批测试文件给你过一遍**，还是先实现纯函数再补测试。

## 8. 执行日志

### 8.1 第一批：规则层落地（2026-09-28 深夜，零 API 成本）

**做了什么**（只动 `Sources/MixCutCore` + `Tests/` + pbxproj 引用，**App 侧一行未改**）：

| 产物 | 内容 |
|---|---|
| `Sources/MixCutCore/ASRPolicy.swift` | 常量宿主：`engineTier = large-v3`、`defaultPreference = 本地`、逐段超时 180s、连续失败上限 3 |
| `Sources/MixCutCore/ASREngineDecision.swift` | 3 purpose × 3 偏好的决策表；`preference` 可收 `nil`（区分"没设过"与"选了自动"）；拒绝分三条理由（能力／凭据／本地未就绪） |
| `Sources/MixCutCore/WhisperModelCatalog.swift` | 档位表 + `ModelRoot` 四根 + `report(files:)`：根优先（磁盘>包内>旧缓存>系统）、L1 决定可用、L2/L3/L4 只出提示 |
| `Sources/MixCutCore/TextProvenance.swift` | 9 档来源枚举 + `resolve()`：空文本不写、内容没变不写、写入记 `previousSource` |
| `Sources/MixCutCore/DubStaleness.swift`（扩） | `DubSnapshot` 加 `recordedSourceTextHash`（**带默认参数** ⇒ 既有两处构造点与 5 条老测试零改动）、`StalenessReason.sourceTextChanged`、聚合入口 `checkAll` |
| `Tests/MixCutCoreTests/` 新增 4 文件 | 30 个 `@Test`（TC-61…77、88…97） |
| `MixCut.xcodeproj/project.pbxproj` | 4 个新文件手工加引用（4 站点 ×4）；**未跑生成器** |
| `scripts/check_asr_guards.sh` | 新守卫 5 组（规则层禁 `UserDefaults.standard`、四个规则文件禁 I/O、三条裁定项、未校验档必须 nil、`checkAll` 必须存在）+ `--selftest` 探针模式 |

**读数**（先红后绿，逐条留档）：

- **红态取证**：4 个测试文件移入 `Tests/` 后先跑 `swift test`，报 `cannot find type 'ModelFile' in scope`、`cannot find 'WhisperModelCatalog' in scope` 等 ⇒ 判据确实在等实现，不是恒绿。
- `swift test`：**285 tests passed**（此前 255；+30 全绿）。
- `check_project_integrity.sh`：**134/134 双向守恒**（此前 130）。
- `xcodebuild -scheme MixCut -configuration Debug build`：**BUILD SUCCEEDED**（app target 直编这 4 个新文件；日志 `.scratch/logs/appbuild-asr-core.log`）。
- `test_project_guards.sh`：全 PASS，TC-05b 基线仍是 4（本轮没加 App 侧文案）。
- `check_ai_completeness_guards.sh` ALL PASS；`bash scripts/check_association_guards.sh`（第 1 期）PASS。
- `check_asr_guards.sh` 全绿；`--selftest` 在合成违规树上 **6 条变红**（探针目录跑完即删）。

### 8.2 这一批里三处"写完才发现我错了"

1. **TC-61 原先写错**：它要求"表里每个档都有精确期望字节"，而 base/small/medium 的精确值**根本没取到**（§3.1 早写明只有四舍五入值）。照原测试实现就会逼我填假数。改法不是放宽：现在断言"校验过的三档等于镜像真值 + 未校验的三档**必须为 nil**"，并让 `report` 对 nil 档跳过 L3 比较 —— 防的正是"拿近似值当预期值"把正常文件判成下断了。
2. **TC-75 的组合数我算错**：写成 27（3×3×3 的臆想），实际 3 purpose × 3 偏好 × 2 有无 Key × 2 本地就绪 = **36**；是夹具自检把它抓出来的，改的是我那句算术，不是判据。
3. **守卫被自己的文档注释绊倒**：`grep UserDefaults Sources/MixCutCore/` 命中 3 处，全是我在 `ASRPolicy.swift` 注释里写的"不得读写 UserDefaults"。改成只匹配 `UserDefaults.standard` 真实用法 —— 数注释的守卫是误报机器。

### 8.3 第二批拆成的 7 项（**全部完成**：1、2 见 §8.4，4、5 见 §8.5，3 见 §8.6，6、7 见 §8.7）

规则层就位后，把它们接进 App：

1. ✅ `ASRSettings`（App 侧唯一读写 UserDefaults）+ 设置页三档偏好与"当前用哪颗 / 来自哪一层"的措辞；
2. ✅ `ASRService` 的模型查找改调 `WhisperModelCatalog`（含**拆掉 `ASRService.swift:371-375` 的隐式下载**）与 `isModelAvailable()` 只问 L1；
3. ✅ `SegmentTranscriber` 门面 + 三处逐段实现收敛（R4/R5/批次取消/`outcome` **七档**，见 §8.6）；
4. ✅ `Segment.setText(_:source:)` 唯一入口 + 10 个裸赋值点改造（**`private(set)` 编译期与运行期都已验**：写入→退出→重启读回）+ 三个新字段同轮 schema bump；
5. ✅ `DubStaleness.checkAll` 接管两处调用点 + 守卫"不得直调 `check(`"；
6. ✅ `get_asr_status` 只读工具（23→24，见 §8.7）；
7. ✅ 打包脚本两行（R7，见 §8.7；**脚本改了但没真跑打包**）。

### 8.4 第二批 · 2a：设置页与模型查找接线（2026-09-29，零 API 成本）

| 产物 | 内容 |
|---|---|
| `MixCut/Services/ASR/ASRSettings.swift`（新） | App 侧**唯一**的 ASR UserDefaults 宿主。`storedPreference` 没设过时返回 **nil**（回落动作留给规则层，存储层不写默认值）；`hasCloudKey` **只回布尔**，Key 片段不出 Keychain。同文件收 `ModelRoot`/`ASRPreference`/`ASREngine` 的中文措辞 |
| `ASRService.swift` 模型查找 | `findWhisperCppModel()` 与 `isModelAvailable()` 改为同问 `Self.modelReport()`（新，扫 4 类根 → stat + 读 4 字节头 → 交 `WhisperModelCatalog.report`）。旧的"先跑完包内整轮再换磁盘"六段循环删掉 |
| **隐式下载已拆**（R1） | 原 `runWhisperCpp` 里"找不到模型就自动下 1.6GB turbo"整段移除，未就绪直接 `throw .modelNotFound` 并在日志写清去哪下载 |
| `downloadModelIfNeeded` | 档位默认值改指 `ASRPolicy.engineFileName`；URL 改从 `WhisperModelCatalog` 取（本地 `modelDownloadURLs` 字典删除）；**"已存在就早退"从"有没有随便一颗"改成"这颗在不在"** —— 旧写法在只有 base 的机器上点"下载"会直接返回 base 路径、什么都不下，然后界面报"已就绪"（就是记忆里那条假就绪） |
| `SettingsView.swift` | 三档偏好 Picker（`@AppStorage(ASRSettings.preferenceKey)`）+「当前生效」一行**由 `ASREngineDecision` 现算**（界面不复写规则）；语音模型行从笼统「已就绪」改成 `large-v3（2.9 GB）· 来自你下载的模型文件夹 · 另检测到 base（未使用）`；L2/L3/L4 提示另起小字，**不改变"已就绪"**（R2）；下载按钮文案跟着档位走；探测与 Keychain 读都挪到后台队列 |
| `WhisperModelCatalog`（核心，+1 字段） | `ModelReport.detected: [ModelFile]`：按挑档顺序的全候选，`detected[0] == selected`；新 TC-109 钉它（含"故意把磁盘那颗放最后"的顺序判据） |
| `MixCut/Utilities/FileHelper.swift` | 注释里点名的 `ggml-large-v3-turbo` 改为"具体档位只由 `ASRPolicy.engineTier` 定"（不留第二处档位事实） |
| `scripts/check_asr_guards.sh` | 新增 4 组 7 条：G6a/G6b App 侧不得有第二份档位文件名/下载 URL；G7a/G7b `downloadModelIfNeeded` 只允许"1 定义 + 设置页 1 调用"；G8a/G8b/G8c 偏好 key 与 UserDefaults 宿主唯一 |
| `scripts/selftest_asr_guards.sh`（新） | 两步自证：① **干净探针树必须全绿**（17 PASS，防空文件清单把"缺文件"伪装成"违规被抓"）；② 注入树 13 条判据全部变红 |

**读数**：

- `swift test` **286 passed**（285 + TC-109）。
- `xcodebuild -scheme MixCut -configuration Debug build` **BUILD SUCCEEDED**（日志 `.scratch/logs/appbuild-batch2a.log`，`error:` 0 处）。
- `check_project_integrity.sh` **135/135 双向守恒**（134 → 135，新文件手工加引用 4 站点，**未跑生成器**）。
- `check_asr_guards.sh` 全绿；`selftest_asr_guards.sh`：干净树 17 PASS / 0 FAIL，注入树 **13 条变红**。
- `test_project_guards.sh` 全 PASS（TC-05b 仍 4 处，本轮新增文案都走 `MixLog`/catalog 真源）；`check_ai_completeness_guards.sh` ALL PASS；`check_association_guards.sh` 全部通过。

**自证过程抓到的一条弱判据（已修）**：G5 原判据是 `grep 'public static func checkAll'`，探针把函数改名成 `checkAllRenamedAway` 后**子串仍然命中**，守卫假绿（13 条只红 12）。改成匹配完整签名 `func checkAll(snapshot:`。⇒ 没有这一步自证，这条防线到今天还是空的。

**故意留的口子**：本机"当前用哪颗 / 另检测到 base"这句**还没有运行期取证** —— 2a 只做到了编译与静态判据，设置页在真机上打开需要人手点（`osascript` 无辅助访问权限），而 MCP 侧目前没有可读的 ASR 状态面。**这一条挪到 §8.3 第 6 项（`get_asr_status`）一起验**：那个工具上线后，同源判据（R3：`detect` 选出的 == 引擎实际用的）在跑着的 App 上一次性取证。



### 8.5 第二批 · 2b：来源列 + 唯一写入口 + 陈旧联动（2026-09-29，零 API 成本）

| 产物 | 内容 |
|---|---|
| `Segment.text` → `private(set)` | **SwiftData 接受 `private(set)`，且运行期已证**：编译通过 + 真 App 里经 `setText` 写入、退出重启后读回原值（见本节末取证表）。⇒ 唯一写入口由**编译器**守，不靠 grep 数裸赋值 |
| `Segment.textSourceRaw` + `textSource` + `setText(_:source:)` | 新列默认 `unknownLegacy`；读侧认不出存量字符串时回落"未记录"而不是某个引擎；写侧把 `TextProvenance.resolve` 的结论落库，**不写时 `text` 与来源逐字节不动** |
| 10 个裸赋值点全部改道 | `SegmentLibraryViewModel:408→fullVideoSlice`、`:555→segmentCloud`、`MixCutApp:520→cleaned`（计数跟 `shouldWrite` 走）、`MCPSegmentToolHandlers:174→agentEdit`、`ImportViewModel:528→uploadedClip`、`:903/:916→boundaryShift`、`:1116/:1234→segmentCloud`、`SegmentLibraryView:1113→manualEdit`；构造点 `:712` 带 `textSource:`（切到字⇒`fullVideoSlice`，退回 AI 建议文本⇒**不猜**、记未记录） |
| `TextUpdate.textToWrite` | 规则层**连要写的值一起返回**（已 trim），不写时为 `nil`。原因：trim 本身是"内容没真变"判据的一部分，两处各 trim 一次会让判据与落库值分家。新 TC-110 钉它 |
| `StalenessReason.userText` | 四条原因的人话版住在**核心层**（两个消费点要用同一套措辞，散在界面里会长出第三种说法）。新 TC-111 钉"原台词变了"与"改写版台词变了"**互不含对方关键词** —— 这是 §6 那条判据的可执行形式 |
| `SegmentDub.generatedForSourceTextHash` | 默认 `""` = 旧数据不报 stale；唯一写点 `DubbingViewModel:476` 旁边同批记原台词哈希 |
| 两处消费点改调 `checkAll` | `MCPSegmentToolHandlers.staleCheck`、`SegmentVariantInspector.isStale`（后者改为返回 `[StalenessReason]`，界面 tooltip 现在说得出是哪一维变的；MCP `stale_dubs` 多带 `reasons` 数组） |
| `Video.asrEngineRaw/asrModelTier/asrRunAt` + `recordASRRun/clearASRRun` | 只在**引擎真的跑完**后记（`:604` 那条加了 `asrRan` 闸门：识别失败时上面落的是空文本，标成"large-v3 跑过"就是又一次假就绪）；`retryASR` 清空文本时同步 `clearASRRun`；`asrWordsData` 不标的取舍写在字段注释里 |
| 台词面板来源标签 | `SegmentLibraryView` 台词头部加 `TextProvenance.displayLabel(...)`，**中性 `.tertiary` 色**（P2-8：它是"没记过"，不是"坏了"） |
| 守卫 +6 条 | G9 禁直调 `DubStaleness.check(`；G10a/b/c 钉 `private(set)`、`setText` 签名、无类外 `.text =`；G11 **三字段同轮在场**（把 P1-5 那句硬约束变成可执行判据）；G12 禁绕过 setText 改来源列 |
| 守卫自证 | 探针树扩到 10 个 App 文件；注入 6 条新违规，`selftest_asr_guards.sh` 现在要求**干净树 23 PASS / 注入树 19 条全红** |

**读数**：`swift test` **288 passed**（+TC-110、TC-111）；`xcodebuild … build` **BUILD SUCCEEDED**；`check_project_integrity.sh` **135/135**（本轮无新文件，未动 pbxproj）；`check_asr_guards.sh` 全绿；`test_project_guards.sh` 8/8 PASS；第 1、2 期守卫全 PASS；自证两步全过。

**两处"写着才发现计划不对"**：

1. **§3.3④ 的目标物不存在**：计划要"删 `SegmentTranscriptionResult.previousText`"，全仓 `grep` 无 `SegmentTranscriptionResult` 这个类型，也没有 `previousText` 字段（逐段重听今天返回的是裸 `String`）。⇒ 该条**作废**，不是"已删"。
2. **我自己的测试写错一次**：TC-111 起初断言 `reasons == [.textHashChanged(current:"a",recorded:"b")]`，而实现里载荷是**真哈希** —— 断言的是我抄进夹具的占位串。改成断言**种类**（`if case .textHashChanged`）而不是载荷。写死哈希等于把实现细节当契约，而且恰好是唯一那条会因"实现真的算了哈希"而红的形状。

**运行期取证（2026-09-29 01:33~01:45，你点头后跑的：只读 + 一次可还原写入）**：

换掉正在跑的旧二进制 → 备份 store 三件套（`.scratch/db-before-batch2/`）→ 启新包 → 走 MCP 取证 → 还原 → 重启再读。

| 判据 | 读数 |
|---|---|
| ① 旧库能被轻量迁移打开 | 新包起来后 `list_projects`/`list_segments` 正常：2 个项目、17 段全部读得出文本，`has_stale_dubs` 也算得出来（⇒ `checkAll` 在**真 store** 上跑过一遍没崩） |
| 三个新字段确实落了库 | `PRAGMA table_info` 见到 `ZTEXTSOURCERAW` / `ZGENERATEDFORSOURCETEXTHASH` / `ZASRENGINERAW`+`ZASRMODELTIER`+`ZASRRUNAT` |
| 旧数据不装懂 | 迁移后 26 段 `ZTEXTSOURCERAW` **全部** `unknownLegacy`；4 条配音的原台词哈希全为空串（⇒ 报"未记录"而不是 stale，实测 `has_stale_dubs=false`）；4 个 `ZVIDEO` 的引擎/档位/日期为空 |
| ② 唯一写入口在跑着的 App 里生效 | `update_segment_text` 返回 `changed:true` + `old_text`，库里该段 `ZTEXT` 变、`ZTEXTSOURCERAW` 变 `agentEdit` |
| R8 的"没变就不写" | 对同一段再写一次**相同文本** ⇒ `changed:false`（且来源没被二次刷） |
| trim 只有一个出处 | 还原时我故意在原文后面多打一个空格 ⇒ 落库的 `new_text` **没有**那个空格（规则层 trim 掉了） |
| 重启后仍在 | 退出（干净 checkpoint）→ 再起 → `seg_001` 文本 == 原文、17 段齐；列状态 `agentEdit×1` + `unknownLegacy×25` |
| 数据已还原 | 该段文本回到取证前的原值；只有来源列留下 `agentEdit`（诚实：Agent 确实写过它） |

**仍未取证**：设置页与台词面板那两处**新文案**（`large-v3（2.9 GB）· 来自你下载的模型文件夹 · 另检测到 base（未使用）`、来源标签）—— 打开设置页/素材库要人手点（`osascript` 无辅助访问权限），而能力面还没有 ASR 状态工具。按 §8.4 的记账，这条并到第 6 项 `get_asr_status` 一起验。


### 8.6 第二批 · 2c：逐段重听门面（2026-09-29，零 API 成本）

| 产物 | 内容 |
|---|---|
| `Sources/MixCutCore/SegmentTranscribeOutcome.swift`（新） | 结果分类档（计划写"六档"，**实现是七档**，理由见下面第 1 条自纠）+ `SegmentTranscribeRule`（格式/来源由引擎定、判空与落笔交给 `TextProvenance`）+ `SegmentBatchPolicy`（连续失败上限、分档计数） |
| `MixCut/Services/ASR/SegmentTranscriber.swift`（新，actor） | 逐段重听的**唯一出口**（R4）：问 `ASREngineDecision` → 按引擎切格式（R5）→ 跑引擎 → 分类 → 计时，返回 `engine/tier/rootKind/format/elapsed/fallbackUsed/reason`。入参与返回**全是纯值**，门面不碰 SwiftData，`Segment` 仍由 VM 写 |
| `ASRService.transcribeAudioFile(path:)`（新） | 本机那条腿的"对已切好的音频直接识别"入口；与整片共用同一个 `findWhisperCppModel()` ⇒ 同一颗模型（R3） |
| `FFmpegRunner.extractSegmentAudio(…wav…)`（新） | 逐段的本机格式。与 `extractSegmentPCM` 只差容器 —— **两枚都在，由门面按引擎选**，调用方没有格式参数可填 |
| 三处实现收敛 | `ImportViewModel.reidentifySegmentTexts`（整批循环）、`ImportViewModel.reASRSegment`（拆分后补认）、`SegmentLibraryViewModel.reextractTranscript`（单段按钮）全部改走门面；两 VM 的 `QwenASRClient()` 字段删除 |
| 批次纪律 | 串行、每段间查取消、连续 `ASRPolicy.consecutiveFailureLimit` 段拿不到字即止、进度 `[UUID:(done,total)]` 上卡片显示「逐段重听 k/n」 |
| 计数诚实 | 汇总 Toast 分档报「拿到字 / 没拿到字 / 没跑识别 / 被取消」 —— 以前 `refused`（没配 Key）会被并进"N 段失败"，把配置问题伪装成识别质量问题 |
| 两处自动链 | `:388/:672` 改调 `autoReidentifySegments`：**不弹窗**（R8 作用域），但结果进日志；以前这两处**忽略返回值**，整批一个没跑成也没人知道 |
| Toast 文案 | 按**实际跑的引擎**生成（`已用本机 whisper重提取（large-v3）`），`unchanged` 单说一句"与原台词一致，未改动" |
| 守卫 +4 条（G13…G16） | G13 云端客户端只许门面构造（允许清单：门面 + `DebugSelfTest`）；G14 逐段切音频只许门面做；G15 本机逐段入口存在且被用；G16 VM 不许就地判 `outcome == .replaced` |
| `DebugSelfTest.runFacade`（新探针） | `MIXCUT_SELFTEST_FACADE=1`：取前 N 段**只问门面、不写库**，报逐段 outcome/引擎/档位/来源根/格式/耗时 + 清点 `segasr-*` 残留。偏好不是本地时**拒绝跑**（不静默改设置来凑绿灯） |

**读数**：`swift test` **294 passed**（+TC-78…81、TC-112、TC-113 共 6 条）；App **BUILD SUCCEEDED**；integrity **137/137**；`check_asr_guards.sh` 全绿；自证 **干净树 27 PASS / 注入树 23 条全红**；其余三套守卫全 PASS。

**运行期取证**（新探针，真 App、真库、零 API、不写库）：

```
存储里的偏好: 未设置→回落 local         ← TC-76 那条回落在真机上第一次被看见
- seg_001: outcome=replaced engine=local tier=large-v3 root=你下载的模型文件夹 format=wav elapsed=4.8s
- seg_002: outcome=replaced engine=local tier=large-v3 root=你下载的模型文件夹 format=wav elapsed=3.4s
R-h 残留 segasr-* 文件数: 0
```
⇒ R5（本机⇒wav）、R3（档位与来源根与设置页同一个答案）、R-h（临时文件清干净）、逐段耗时 3.4-4.8s（与 §2 的 4.5s 推算一致）**都拿到了运行期证据**；跑完 `sqlite3` 复查来源列仍是 `agentEdit×1 + unknownLegacy×25` ⇒ 探针确实没写库。

**三处自纠**：

1. **"六档"不够，拆成七档**：起初把"只有一条腿跑挂"并进 `bothEnginesFailed`，于是用户显式选本地、本机 whisper 挂了，界面会说"两个引擎都失败"—— 另一个根本没试，真实原因（模型没下 / GPU 崩）被这句话盖掉。新增 `engineFailed`。这是 §3.4 的字面清单没覆盖的形状，已在此记账而非改红线。
2. **测试抓出我的实现把来源记错**：回落成功时我用了**决策首选**那台引擎来定来源 ⇒ 库里会写"云端认的"，而字其实是本机认的。`TranscribeAttempt` 因此加 `engine` 字段，来源跟**实际跑的**那台走（TC-80 第三条现在钉这件事）。
3. **写探针时发现守卫会"因为路径没定义而全绿"**：`set -u` 下 `"$APP"` 未定义只让命令替换空掉，grep 拿到空路径 ⇒ G13/G14 在没拷全的探针树上直接假绿。已把 `APP`/`ASR_DIR` 上提，并加一条"守卫根缺失就 exit 1"的前置断言。

**没做的**：`reASRSegment` 的返回值语义变了（以前"引擎跑通就算成功"，现在是"拿到字才算成功"）⇒ 拆分失败提示会更严。这是有意的，但它改变了 `SplitOutcome` 的口径，**运行期未验**（拆分那条链要真跑一次拆分，会删现有分镜并重新识别，本轮没做）。

### 8.7 第二批 · 2d：`get_asr_status` 能力面 + 打包链两行（2026-09-29，零 API 成本）

| 产物 | 内容 |
|---|---|
| `get_asr_status`（第 24 个工具，只读） | 报：`policy`（档位 + 默认偏好）/`settings`（**未设置时回 `null`** + `has_cloud_key` 只布尔）/`binaries`（whisper 与 CPU 兜底在不在）/`model`（用哪颗、来自哪个根、实际字节 vs 期望字节、L2~L4 提示、**检测到自己没用**的档）/`routes`（三种用途各自会走哪条及原因，refused 明写 refused）/`library_scope`（全库台词来源分布 + 陈旧联动计数） |
| 同源纪律 | 四个宿主之外不复写任何规则；陈旧计数直接复用 `staleCheck`（同一个聚合入口），不在能力面重拼一遍 |
| 措辞收口 | `ModelIssue.userText`、`ASRPurpose.displayName` 落 App 侧 `ASRSettings.swift`；`SettingsView.modelHintLines` 改用它 —— 消掉"界面一种说法、Agent 另一种说法" |
| 打包链（R7） | `WMODEL` → `ggml-large-v3.bin`、`WMIN` → `3000000000`、下载 URL 与 echo 同步；注释指认 `ASRPolicy`/catalog 为真源。**只改脚本，未真跑打包**（2.9GB + 源码编译仍待点头） |
| 工具名单 23→24 | **改前先取证为红**：`AgentToolCatalogTests` 的逐名断言实际报错把 24 个名字全列出来了 ⇒ 名单是逐名比对，改名/漏名/多名都会被抓。之后才有意更新清单并写明这是有意的契约变更 |
| 守卫 +5 条 | G17 打包内置文件名 == `ASRPolicy.engineFileName`；G17b 体积闸门落在真实字节数量级；G18 `MixCut/Services/MCP` 内零 `KeychainHelper`；G19 工具"声明了且接上了"（两处各 1 次）；G20 App 侧不许复写陈旧原因 |
| 自证 +5 条注入 | 干净树 **32 PASS**、注入树 **28 条全红**。过程中步骤① 先失败过一次：探针树没拷 `AgentToolCatalog.swift`，`grep -c` 对不存在的文件**输出空串**、判定"看起来通过" ⇒ 加了"守卫要读的文件不存在就直接 exit 1"的逐文件前置 |

**运行期读数**（真 App、MCP `tools/list` + `get_asr_status`，只读零成本）：

- 工具数 **24**，`get_asr_status` 在只读组里（`readOnlyHint`）。
- `model.tier=large-v3`、`file_name=ggml-large-v3.bin`、`root=你下载的模型文件夹`、`byte_count=expected_bytes=3095033483`、`detected_but_unused=[base]`、`layer_2_to_4_hints=[]` ⇒ **与 2a 设置页那句、2c 门面探针三项完全一致**（R3 同源至此有了跨表面证据；§8.4 留的那个口子在这里闭掉）。
- `preference=null` + `preference_label="未设置（按默认 本地（whisper））"` ⇒ "没设过"与"设成 auto"在能力面上可分辨（TC-76 的运行期形式）。
- `segments_by_source = {Agent 写入:1, 旧数据·未记录来源:25}`，且 `unknownLegacy` 只作为统计出现、错误计数里不含它（P2-8 / TC-101）。
- `dubs_checked=0`（库里 4 条配音变体都还没生成音频）⇒ 陈旧联动这一档**没有样本可验**，只验到"不报错、计 0"。
- 泄漏扫描：输出 1185 字节里 ≥20 字符的类 token 串只有三个**字段名**；无 `api_key` 字样、无 `sk-` 前缀（TC-100）。

**一条顺带查出来的事实（值得单独说）**：`has_cloud_key=false` 是**真值**，不是读错 —— 本机 `com.mixcut.app` 的偏好里有 `api_key_deepseek`，**没有 `api_key_qwen`**（只有 `selected_model_qwen` 这个残留选择）。⇒ 现在整台机器上云端那三条能力（逐段听写、配音 TTS、声音克隆）都不可用；也正因如此，本轮把默认定成"强制本地"没有实际损失。`KeychainHelper` 这个名字是**误称** —— 它实际用 `UserDefaults` 存 Key（注释里写了是为避开 Keychain 弹窗），所以"能力面零 KeychainHelper"这条守卫防的是复写读法，不是防泄露本身。

### 8.8 第二批收官状态

§8.3 的 7 项**全部完成**。仍未做/仍未验的：

1. **真跑一次打包** —— **已在隔离目录跑通整条链（见 §8.9）**，但仍差两件：① 构建期那两行 large-v3 **下载 URL** 没下过一遍（本次用本机同字节文件顶替，跳过分支按预期生效）；② 产物没装进真树 `MixCut/Resources/bin`（仍为 0 文件）。
2. **§3.7 B 案**（文本候选 + 生效指针）—— 待拍；不拍就按 A 案定稿。
3. **`AgentToolCatalog.swift:101` 的 `retry_asr` `destructiveHint` 改 true** —— 待点头（本轮没动，因为它会改契约名单之外的注解，且需要一起决定 `retry_analysis` 等是否同类）。
4. **拆分链的新返回口径**（§8.6 末）—— 未运行期验。
5. **`dubs_stale_because_source_text_changed` 没有真样本**（本机 0 条已生成配音）⇒ 那一条判据要在有配音的库上才能验真。
6. **删掉成为摆设的 base（141MB）** —— 待点头。

### 8.9 打包链隔离跑通 + 短窗退化受控对照（2026-09-29，零 API 成本）

**为什么隔离跑**：脚本会把 5 颗二进制 + 3.4GB 模型写进 `MixCut/Resources/bin`，那会改变 App 运行期解析（包内优先于 Homebrew 兜底），也会让每次 Debug 构建多拷 3.4GB。所以把脚本原样复制到 `.scratch/packrun/scripts/`，靠它自算的 `ROOT="$(dirname $0)/.."` 把 `DEST` 重定向到隔离目录 —— **同一条代码路径，只换目的目录**。

GitHub 直连不通（`Empty reply from server`），改用脚本自带的镜像开关：`GIT_MIRROR=https://ghproxy.net/`（第 27 行的 `insteadOf` 改写连子模块一起覆盖；demucs 的 `vendor/eigen` 指向 **gitlab**，不在改写范围内，实测直连也通）。

| 判据 | 读数 |
|---|---|
| 5 颗架构 | `ffmpeg` `ffprobe` `whisper` `whisper-cpu` `demucs` 全部 `x86_64 arm64` |
| 兜底件老系统兼容 | whisper-cpu / demucs 均 `minos=13.0`、`nm -u` 无 `MTLResidencySet`；**whisper-cpu 一处 Metal 都不链**（GPU 版链 2 处）⇒ "老系统换这颗"是结构性的 |
| 拷贝是否被认（反向判据） | 日志里「下载 Whisper 模型」出现 **0 次** ⇒ `WSIZE ≥ WMIN` 跳过分支生效；文件仍 3095033483 字节 / 魔数 `lmgg` |
| demucs 模型 | 83,994,361 字节、魔数 `4cmd`（是真模型，不是镜像错误页） |
| 结尾 | `✅ 完成` |

**一个当场收回的预警**：我曾担心"打包版引擎与本机 1.9.4 版本漂移会污染台词基线"。实测新编那颗自报 `1.9.4-dev`，同代；再往下测，**同一段 12 秒音频 + 同一颗 large-v3，包内静态构建与 Homebrew 动态构建的输出逐字节相同**（`diff` 无差异，各 7.2s / 7.6s）。⇒ 该预警撤销：两种构建在本用例上等价，台词基线可以跨构建比。（保留的最小怀疑：等价只在"这一档 + 这一类输入"上成立，换档位或换语言未测。）

**"静态自包含"这条也被实测坐实**：`otool -L` 只列出 `libSystem` / `libc++` / `Accelerate` / `Foundation` / `Metal`（arm64 切片带 Metal，x86_64 切片不带），**没有任何 Homebrew 路径**；对照 Homebrew 那颗会去加载 `/opt/homebrew/Cellar/ggml/0.25.3/libexec/libggml-blas.so`。⇒ 拷到没装过 Homebrew 的 Mac 上能跑，只要 macOS ≥ 13。

**顺带一条诚实记录**：包内那颗 12 秒输出虽回到简体，后半段仍错 ——「石林**人生**果片**生就是厚熟**」（应为"人参果片"）。⇒ 升档解决繁简与大部分错字，**不解决全部**，台词清洗那一层仍然必要。

**仍未验的两件**：① 构建期 large-v3 的下载 URL 一行没跑过（本次顶替）；② 产物装进真树后 App 的实际行为（含"包内优先"会不会改变现有台词基线）。

**短窗退化的受控对照**（数据与结论在 §2 追加二）：窗口长度是唯一变量，3.067 秒出繁体且错字、12 秒简体正确。这把"逐段重听"的质量问题从**模型/档位问题**重新定位成**切窗策略问题**，修的位置在 `SegmentTranscriber` 的取音频窗口，不在后处理。

**仍未验的两件**：① 构建期 large-v3 的下载 URL 一行没跑过（本次顶替）；② 产物装进真树后 App 的实际行为（含"包内优先"会不会改变现有台词基线）。

## 9. 本计划取代的旧文档

- `docs/superpowers/specs/2026-06-24-segment-asr-reextract-design.md`、`docs/superpowers/plans/2026-06-24-segment-asr-reextract.md`（"逐段固定由阿里"被 §3.4 取代）。
- `docs/superpowers/specs/2026-06-24-fullvideo-aliyun-asr-design.md`（分工被 §3.0 R6 重写）。
- 落地动作：两份 spec 顶部各加一行"已被 2026-09-28 ASR 计划 v9 §3.0 取代"（各一行、非破坏）；正文保留不删。

## 10. 测试层（v9 并入 · test-coverage-expander 对 §3 的覆盖评估）

### 10.1 八条一般规则（从已有种子归纳，是"为什么测"的根据）

| # | 不变量 / 规则 | 来自哪条设计 | 已有的同类种子 |
|---|---|---|---|
| R-a | **就绪单调性**：L2/L3/L4 任一档变红都不得让 L1=true 变成"没模型" | §3.2 / 红线 R2 | `CosyVoiceCatalogTests` 的"未命中回退" |
| R-b | **同源唯一且确定**：`detect` 选出的文件 == 引擎实际使用那颗；同输入两次同结论 | §3.2 / 红线 R3 | 第 2 期 `SegmentationCompletenessTests` 的一致性断言 |
| R-c | **能力优先于偏好**：需要时间戳的路径永不走云端 | §3.4 / 红线 R6 | `ParaformerASRTests` 的"只拼 final" |
| R-d | **不无条件覆盖**：`outcome ≠ replaced` 时 `text` 与 `textSource` 逐字节不变 | §3.3①② / 红线 R8 | 第 1 期幂等入口 `ProjectVideoDedupTests` |
| R-e | **来源不被刷**：内容未真变则来源不变 | §3.3②（照 `MixCutApp.swift:518`） | 仓库三个 `did*` 一次性守卫 |
| R-f | **旧数据不装懂**：空哈希 / `unknownLegacy` 不进 stale 与错误计数 | §3.3③ / §3.5 | `DubStalenessTests` 的 `recordedStartFrame=-1→stale`（本次取反） |
| R-g | **纯函数边界**：决策与 catalog 的用例只能由入参构造 | §3.1 / 红线 R3 | 全部 MixCutCore 测试的共同前提 |
| R-h | **临时资源必清**：每个 outcome 分支（含抛错与取消）都不留 wav/pcm | §3.4 | `ASRService.swift:174` 的 defer 注释 |

### 10.2 外部经验（**降级如实标注**）

两次检索只到链接层：Apple 的 Swift Testing / Core Data 文档页存在，但正文需 JS 渲染，`WebFetch` 一次 404、一次只拿到"requires JavaScript" ⇒ **未取到外部正文**。唯一可用结论（标题层）：官方有"由集合初始化测试用例"的参数化机制 ⇒ §10.5 里 9 格表与层级矩阵**用参数化展开，不手写 9 遍**。其余补充维度取自本 Skill 内置模式库：并发（EX-04）、性能基线（PERF-01）、迁移兼容（MIG-01）、落库正确（DATA-01）、凭据不回显（SEC-01）、可观测真源计数（OBS-01）。

### 10.3 差距矩阵（现状 → 拟新增）

| 维度 | 单元 | 集成/守卫 | E2E（用户入口） |
|---|---|---|---|
| catalog 表形状（唯一性/顺序/字段非空/未命中回退） | 缺失→TC-61 | — | 已有 |
| 四层就绪 16 组合 + 单调性 | 缺失→TC-62…65、TC-72 | — | 侧栏/欢迎页不变脸（已有） |
| 根优先级三形态 | 缺失→TC-66…70 | TC-69 一致性 | 放 base 冒充包内（已有） |
| 9 格决策表 | 缺失→TC-73…77 | — | — |
| 门面六档 outcome / 不覆盖 / 资源 | 部分可下沉→TC-78…82 | 守卫 TC-83…87 | TC-105、TC-108 |
| `setText` 唯一入口与来源迁移 | 缺失→TC-88…92 | 守卫 TC-87 | TC-108 |
| `checkAll` 陈旧联动 | 已有 5 条 + 扩 TC-93…97 | 守卫 TC-85 | 配音卡片原因 |
| 迁移与旧库兼容 | 无法单测 | TC-98、**TC-99（要新夹具）** | 旧版本读新库（§6） |
| 契约 24 / 凭据 / 日志真源 | TC-100 | TC-102、TC-103、TC-104 | — |
| 并发（防重入 vs 门面）、导入时长基线 | — | **完全缺失→TC-106、TC-107** | 同左 |

### 10.4 用例清单（TC-61…TC-108；P0 = 没有它本轮等于没验，P1 = 同族未触达，P2 = 加固）

| # | 层 | 触发规则 | 预期 | 级 |
|---|---|---|---|---|
| TC-61 | 单元 | catalog 表：档名唯一、每条有 URL 与期望值、字段非空 | 无重复；URL 全 https | P1 |
| TC-62 | 单元 | 未识别文件名（`ggml-tiny.bin`/自定义名） | 判"检测到但未使用"，不判"没有模型" | **P0** |
| TC-63 | 单元 | 字节数 < 期望（半截文件） | L3 提示，**L1 仍可用**（R-a） | **P0** |
| TC-64 | 单元 | 文件头 magic 不合法 | L2 报损坏，仍算 L1 存在 | **P0** |
| TC-65 | 单元 | 正向对照：唯一一颗 large-v3、头与字节都对 | 四层全绿、零告警（防恒真） | **P0** |
| TC-66 | 单元 | 同档两颗（磁盘 + 包内同名） | 选磁盘那颗 | **P0** |
| TC-67 | 单元 | 只有包内有 turbo、磁盘空 | 选包内并如实报来源 | P1 |
| TC-68 | 单元 | 候选空序列 | "无任何模型"，不崩 | P1 |
| TC-69 | 单元 | 同输入两次 `detect` | 逐字段相同（R-b） | P1 |
| TC-70 | 单元 | 旧缓存与磁盘各一颗同档 | 按 `ASRPolicy.rootOrder` 择一 | P1 |
| TC-71 | 单元 | 改表里的期望值，判据应跟着动 | 预期值有来源、非硬编码 | P1 |
| TC-72 | property | 随机候选序列（SplitMix64）：`detect` 结果必属输入且 rootKind 一致 | 无凭空路径 | P1 |
| TC-73 | 单元 | 9 格全展开（参数化，一格一例） | 无一格留空 | **P0** |
| TC-74 | 单元 | 整片×云端；强制本地但本地不就绪 | 两格必拒且**理由不同** | **P0** |
| TC-75 | 单元 | 决策只由入参决定 | 用例内不出现存储读取（R-g） | **P0** |
| TC-76 | 单元 | `ASRSettings` 无 key | 回落 `ASRPolicy.defaultPreference` 且日志可见 | P1 |
| TC-77 | 单元 | 偏好=云端但没配 Key | 拒绝/降级理由**必须说"没 Key"**，不静默改路线 | **P0** |
| TC-78 | 单元 | 六档 outcome 的后置条件 | 非 `replaced` 时文本与来源逐字节不变（R-d） | **P0** |
| TC-79 | 单元 | 云端成功但空文本 | `emptyAudio`，不是 `replaced`、不是 `true` | **P0** |
| TC-80 | 单元 | 两引擎都失败 | `bothEnginesFailed`；回落标记为真但**不写文本** | P1 |
| TC-81 | 单元 | 取消发生在第 k 段 | `cancelled`，第 k+1 段不启动 | P1 |
| TC-82 | 单元 | 每个分支（含抛错）后的临时目录 | 无残留 wav/pcm（R-h） | P1 |
| TC-83 | 守卫 | `MixCut/` 内不得出现 `QwenASRClient(` | R4；改前快照必须变红 | **P0** |
| TC-84 | 守卫 | 识别路径内不得出现 `downloadModel` | R1 | **P0** |
| TC-85 | 守卫 | 不得直调 `DubStaleness.check(` | P0-2 聚合入口 | **P0** |
| TC-86 | 守卫 | `grep UserDefaults Sources/MixCutCore/` 为空 | P0-1 边界 | **P0** |
| TC-87 | 守卫 | `.text = ` 裸赋值只在允许清单内 | §3.3② 唯一入口 | **P0** |
| TC-88 | 单元 | `setText` 同值同来源重复调用 | 来源不改写、无重复记账（幂等） | P1 |
| TC-89 | 单元 | 清洗输入与输出同串 | **来源不变**（R-e） | **P0** |
| TC-90 | 单元 | 相邻搬字（`:903/:916`） | 目标段 = `boundaryShift`，不继承邻段 | P1 |
| TC-91 | 单元 | `uploadedClip` vs `fullVideoSlice` | 两个不同值，不合并 | P1 |
| TC-92 | 单元 | 枚举全量：每个来源至少被一条用例经过 | 无死值 | P1 |
| TC-93 | 单元 | 只原台词变 | `stale([sourceTextChanged])`，不含 rewritten 原因 | **P0** |
| TC-94 | 单元 | 只改写版变 | 与既有 5 条测试行为一致（向后兼容） | **P0** |
| TC-95 | 单元 | 两者都变 | `reasons ≥ 2` | P1 |
| TC-96 | 单元 | 旧 dub：来源哈希为空 | **不报 stale**，只报"未记录"（R-f） | **P0** |
| TC-97 | 单元 | 正向对照：两者都没变 | `fresh`（防恒真） | **P0** |
| TC-98 | 集成 | 三字段同轮 schema bump | 旧 store 打开后三处默认值成立，无半个体系 | **P0** |
| TC-99 | 集成 | **旧版本读新库**（需"迁移前 store"夹具） | 不崩、不丢字段 | **P0**，本轮成本最高 |
| TC-100 | 集成 | `get_asr_status` 输出扫描 | 不含 Key 的任何片段/长度/前缀（SEC-01） | P1 |
| TC-101 | 集成 | `unknownLegacy` 计数 | 统计项，**不进错误计数**（R-f 的观测面） | P1 |
| TC-102 | 集成 | 工具名单 23→24 逐名 | 有意契约变更；改前快照变红 | **P0** |
| TC-103 | 集成 | `list_segments`/`export_segments` | 新列之后输出字段不破（行为契约） | P1 |
| TC-104 | 集成 | `MixLog.logFileURL` 真源计数（现 4） | 复用真源，或按纪律改基线并写原因 | P2 |
| TC-105 | E2E | 没 Key 设「本地」→ 素材库重提取 | 文本被本地重写、无"尚未配置千问 API Key"；status 同步印证 | **P0** |
| TC-106 | E2E | 同一段连点两次「重提取」 | 防重入生效，不并发跑两个 whisper 进程（EX-04） | P1 |
| TC-107 | E2E | 同一条素材导入端到端前后对比 + "逐段重听 k/n" | 时长差写回 §2（**目前完全无基线**） | P1 |
| TC-108 | E2E | 手改过的段被整批重听 | 出现**一次**确认；自动链（`:384/:657`）**不得**弹窗 | **P0** |

### 10.5 交付口径与两个前置

1. **这 48 条现在一条都跑不了** —— `WhisperModelCatalog` / `ASREngineDecision` / `checkAll` 尚不存在。交付顺序照第 2 期：**§3.1/§3.2/§3.3 的纯函数与 TC-61…77、TC-88…97 同批落地**（先出测试文件给你过一遍再开工）。
2. TC-83…87、TC-105…108 属守卫与运行期判据，**不进 `swift test`**（工程只有 application target）；48 条里 12 条是这一类。
3. 覆盖数预期：`swift test` 255 → **约 290**。
4. **TC-99 需要新夹具**（一个"迁移前"的 store）：不造它，三个新字段的兼容性就只剩一句"应该没问题"。已在 §7 计 +0.75 小时。
5. 每条"会报警"的判定都必须配一条**正向对照**（TC-65/TC-97 这类），沿用第 2 期定下的防恒真纪律。

### 10.6 测试先行反推出的三条设计约束（v9.1，写 TC 批时才发现，已回写 §3）

预览文件在 `.scratch/tests-preview/`（4 个测试 + 1 个契约桩 + README）；`swiftc -parse` 全绿，**未编译未运行**（被引用的 API 还不存在）。写它们的过程中暴露了三条设计约束，比"补测试"更值钱：

1. **来源规则必须下沉**：`Segment.text` 住在 App target、没有单测面 ⇒ "该不该落笔、来源改成什么"若写在 `Segment` 里就永远测不到。新增 `Sources/MixCutCore/TextProvenance.swift`（纯函数 `resolve(current:currentSource:incoming:writer:) -> TextUpdate`），`Segment.setText(_:source:)` 只是它的调用者。**§3.3② 的实现物因此多一个文件**（工时不变，位置变了）。
2. **`DubSnapshot` 的新字段必须带默认参数** `recordedSourceTextHash: String = ""`：否则 `MCPSegmentToolHandlers.swift:44`、`SegmentVariantInspector.swift:80` 两处构造点加既有 5 条测试全挂 —— 那会把一个加维度的改动扩散成重构（v8 P0-2 的同类风险）。
3. **`decide(preference:)` 必须能收 `nil`**："用户从没设过"与"用户选了自动"是两种状态；不区分就会在视图与决策两侧各写一份默认值（正是 v8 P0-1 那个病）。TC-76 钉这条。

**我在测试里替你定了一格**（必须过你的眼）：`singleClipListening × 云端 = 拒绝`，理由**不是能力**而是**默认不把用户上传的片段送上云端**。要放开就同时改 TC-73 的期望表与本节，别只改实现——计划里"不许实现时随手填"说的就是这种格子。

## 11. 切窗退化这条线的收官（v12 新增 · 另立的计划已全部落地）

落地的独立计划：`~/.qoder-cn/plans/northern-hollow-gannet.md`（现 v7，§6–§10 是实测与自证的原始记账）。本节只写**结论与读数**，细节以那份为准。

### 11.1 四组受控实验（本机 whisper-cli 1.9.4 + large-v3，零 API 成本）

| 实验 | 输入 | 输出与结论 |
|---|---|---|
| 对照 | seg_001（3.07s）无 prompt | 繁体 + 错字 ⇒ 窗口长度是唯一变量（v11 §2 追加二） |
| E1 | seg_002/003/004 短窗无 prompt | **都是简体**，但都有错字 ⇒ 真实退化是**错字为主、繁简漂移为偶发** |
| E2 | s4 音频本身干净，prompt 放邻居式错写法 | 「汁水汪汪…还带点**乃香**」⇒ **邻居台词绝不能当 prompt**（会把对的词写坏） |
| E3 | s3 扩到 12.6 秒 | 错字没修、句子被切碎、边界错位 ⇒ 宽窗收益不明 |
| E4 | 三段短窗 + **固定简体风格锚** | seg_001 简体正确、s4 未被带偏、s3 仍错字（预期）⇒ 锚零传染面、零额外耗时 |

### 11.2 已生效的两条设计

- **风格锚**：`ASRPolicy.retakeStyleAnchor`（34 字、与业务内容零交集）经 `--prompt` 只接**逐段重听链**，
  整片链恒传 `nil`（守卫 G21 守`--prompt` 只在 `ASRService.swift`）；**不用 `--carry-initial-prompt`**
  （always prepend 在 >30s 滑窗里会反复复述）。云端腿不带锚，auto 回落时锚跟着**真正跑的那台**（TC-125）。
  超长 prompt 实测：300 字不报错、不静默截断、不回吐 ⇒ F 换引擎可直接喂长上下文。
- **宽窗 + 裁回**：整套实现但 `retakeWidenEnabled = false`，靠 `MIXCUT_SELFTEST_RETAKE_WIDEN=1` 这个活入口跑（G25 守入口在）。

### 11.3 运行期两态实测（`.scratch/v7_facade_off.txt` / `v7b_facade_on.txt`）

- **关态 = 主路径**：seg_001 从「秋冬一到嘴就**乾** / **這骨頭**」变「秋冬一到嘴就干,这果子咬一口全是水。」；
  seg_004 未被带偏；四段 `anchor=true widened=false`、`outcome=replaced`、`segasr-*` 残留 0。
  中修之后重跑，**与修复前逐字节相同**（diff 只动四行 elapsed）。
- **开态**：4 段里 **1 段产出（seg_001, coverage 0.98）、3 段判不可信、台词保持原样**（R8 未被触碰）
  ⇒ **宽窗在这份素材上净收益为负**，v11 里那句推测现在有实测支撑。
- 修复前那遍开态曾以 `coverage=0.93` 放行、把 seg_004 的「切开来汁水汪汪」写进 seg_003 —— 见 §11.4。

### 11.4 归属契约的二次修改（"中修"）

v5 的裁回按**句子中点**判归属 ⇒ 跨段边界的一句会整句保留，且 `keptCoverage` 量的是时间并集，
**污染越重分数越高**（0.489 被拒、0.93 反被放行）。已改成：

- **完整包含才保留**：越出本段窗口超过 `ASRPolicy.retakeBoundaryTolerance = 0.05`（`-ss` seek + AAC priming 的 20~40ms 抖动额度）的内容**整条丢弃** ——
  宁可少一句，不可写进邻居；
- 没有正时长 / 时间戳非有限的项判为**不可定位** ⇒ 可解释的空结果；
- `carve` 的拼接走 `joinWordTexts`（原来两份实现分家，TC-121 是在守一颗没人调的函数）。
- ⚠️ **与选型时说的一句有出入**：当时描述成"改成按词判断"，**实际没换成词** ——
  `ASRService.swift:34` 记着本仓已证的结论：whisper 词级输出会丢 token，用词重拼会把"抄邻居"换成"丢自己的字"。

顺带查出并修掉一条报表缺陷：`SegmentTranscriber` 的 `failure()` 把 `keptCoverage` 硬写成占位 `0`，
忽略实测值 ⇒ 探针同一行出现 `coverage=0.00` 与 `reason=…只剩 43%…` 两个互相打脸的数。
改成 `failure(_:coverage:)`，两个裁回分支传实测值、其余分支留 `nil`（"没测到"与"测到 0"是两个值）；
复验后四行的 coverage 与 reason 一致，且两遍开态的「认到」文本逐字节相同 ⇒ **只改了报表，行为零变化**。

### 11.5 三条纪律级教训（与功能无关，但下次一定会再踩）

1. **守卫自己也会是假防线**：G25 第一版数的是标识符，注释里提一次就算命中 ⇒ 删掉真正的读取代码它照样绿；
   被自证脚本当场抓住（红数 33≠34），收紧成必须匹配 `environment["…"]`。
2. **门面探针必须 `</dev/null` 启动**：App 从终端直接跑时，它的孙子进程 ffmpeg 继承了这个 TTY 的 stdin，
   一读就吃 SIGTTIN 被停住（`ps -o stat` = `T`、CPU 0.03 秒）⇒ 探针活着、产物永不生成。**前后台都一样**。
   归因顺序：`pgrep` 有没有进程 → `lsof -nP -iTCP:8787 -sTCP:LISTEN`（在听 = 探针确实开跑）→ 子进程 `stat`。
3. **抄错读数要当场更正**：我把 seg_003 的 reason 报成"只剩 4%"，文件里实际是 **43%** —— 记账句必须先 grep 文件再落笔。

### 11.6 静态读数（本轮全部重跑）

- `swift test`：**325 通过 / 0 失败 / 0 已知缺陷登记**（本计划第二批收官时是 295）。
- `scripts/check_asr_guards.sh`：**41 条全绿**（第二批收官时 32；G21…G29 是这一轮长出来的）。
- `scripts/selftest_asr_guards.sh`：干净树 41 全绿；注入树 **37 条全红**。
- **TC-138 变异自证通过**：不改生产码，把 `Package.swift + Sources + Tests` 复制到 `.scratch/tc138-mutation/`
  后只在副本里 `+ offset → - offset` ⇒ 副本 **325 failed**，红的正是钉偏移的 TC-118；真树核对 `+ offset` 仍 3 处、副本已删。
- `xcodebuild -scheme MixCut -configuration Debug build`：**BUILD SUCCEEDED**。

### 11.7 这条线上仍未做的两件

- **TC-147 跨段重复内容判据**（与覆盖率不同源的那道自检）：要新增纯函数 + 门面接法；在"宽窗留不留"定下来之前做它可能是给准备放弃的路加护栏。
- ~~**工作流二 F 引擎调研**：案头部分可查；但计划定义的"本仓同 4 段素材上的中文 CER 对照"**必须先下第三台引擎的模型**（GB 级取网，要单独点头）。~~
  **这条已在 v13 做完案头 + 一半实测，见 §11.8。**

### 11.8 F 引擎实测第一轮（SenseVoice，2026-09-29 18:1x · 详表在另一份计划 §12）

模型那颗 158 MB 的 tar.bz2 已下并跑通本仓同一批 4 段素材（`.scratch/fengine/sv_run.log`）。三句结论：

1. **两条退出判据都没触发**：词级时间戳**实测有**（四段 tokens/timestamps = 16/16、30/30、25/25、16/16）；
   Swift 接口只到**案头级**（本轮跑的是 Python 面，一行 Swift 都没编）。
2. **"换引擎修错字"没有被证明**：按三方共识基准算可判定错字，whisper（今天的带锚默认）与 SenseVoice **打平在 4/62**；
   SenseVoice 只赢在无基准的 seg_003（**石林 / 人参果**  whisper 连续写成 石陵 / 人生果）与繁简稳定。
   ⇒ 下一刀是**给这 17.1 秒写人工转写**，不是再下第二颗模型（多引擎互证出来的是共识，不是对错）。
3. 体积 **233 MB vs 3.0 GB**（约 1/13，档位目录要为它重想一档）；代价三条要记账：SenseVoice **不吐标点**、
   词级粒度是**字/词片**而非 whisper 的 word、**权重自身授权未核验**（pip 包自报 Apache-2.0）。

**⇒ 这一问已由用户裁定：暂不换引擎（2026-09-29 18:3x，原话"先不换了"）。** 生产路径维持 large-v3 + 风格锚，
F 到此收档（详见另立计划 §12e）。⚠️ 三条随之定死的口径：① "换引擎省时间"这条**不再需要测**，那条计时命令作废；
② 人工转写这把尺子的必要性随问题一起撤掉（它服务的就是"要不要换"）；③ **错字这条线的出路收窄成只剩既有的 LLM 台词清洗**
—— 别把"繁简修好了 + 引擎调研过了"当成台词质量解决了。他没给理由也没给期限 ⇒ 将来再议 F 是**重开**，不是"推进上一步"。

### 11.9 宽窗那套已整块删除（v14 · 详单在另立计划 §13）

§11.2 / §11.3 里"宽窗整套实现但默认关、带活入口"这句**从今天起不再描述当前代码**：
用户下令「删掉宽窗逻辑和相关测试守卫」⇒ 取窗计划、按时间戳裁回、覆盖率阈值、接缝容差、
运行期活入口 `MIXCUT_SELFTEST_RETAKE_WIDEN`、探测总时长**全部删掉**，连带 **24 条测试与 4 条守卫**（G24/G25/G28/G29）。

留下的是**主路径每天在用的那半**：`ASRPolicy.retakeStyleAnchor`（风格锚，喂 `--prompt`）、
引擎能力表（只剩 `contextPrompt` 一列）、锚回吐自检 `containsAnchorEcho`。

删除的证据链：`swift test` 325 → **301**（−24）、守卫 41 → **37** 全绿、自证注入树 37 → **33 条全红**、
宽窗符号 `grep` 残留 **0 处**、Debug 构建 **SUCCEEDED（0 error）**、工程文件**未触碰**（mtime 仍是当天 02:07）。
⚠️ **仍差运行期那一格**：门面取窗那一行被改过，"台词逐字节没变"目前只有编译级证据 ——
判据是关态探针重跑后与 `.scratch/v7_facade_off.txt` 逐字 diff 为空（命令在另立计划 §13e，要用户跑）。

**为什么这条要写进主计划**：本计划里那一串"扩窗/裁回/覆盖率"的设计叙述与"默认关的码必须有活入口"这条纪律，
现在的正确读法是**历史记录**，不是待维护的防线。纪律本身没作废 —— 它反过来成立了一次：
正因为默认关还配了活入口，才拿到"4 段只产出 1 段"这个实测，才敢整块删掉而不是留着腐烂。

