# 2026-10-19 · 导出画幅/尺寸唯一真源（千川整批拒收事故）

## 一、事故与结论

2026-10-19 12:42–12:52 批量导出的 **41 条成片**上传巨量千川，被红字拒收
**「素材尺寸（宽度）不符合规范，请检查后重新上传」**（不是"格式错误"，容器与编码都合法）。

| 取证项 | 实测结果 | 取法 |
|---|---|---|
| 被拒产物 | **41 条全部 480×854**，DAR `240:427`，h264 High/yuv420p/level 31/30fps/SAR 1:1，逐字段一致 | `ffprobe` 逐个跑 |
| 截图里 方案1/3/6 为何没报错 | **只是没传完**（按钮「取消上传」＋99%/77%）。全批都会判死 | 读按钮态 |
| 854 从哪来 | 旧 `DubExportService.swift:593` `case .p480: return (480, 854)` ⇒ 面板选了 **480p** | 实读码 |
| 480 是否素材继承 | **否**。素材库分布 1080×1920(27)/2160×3840(10)/720×1280(6)/720×960/704×1248/480×960，最大宽 2160，**无一条 854 高** | ffprobe 全量 |
| 平台自有素材库 | `video/get` 回包 **120 个 width 全 1080、120 个 height 全 1920**（`千川/api_out/qc_video_get_20261012-114910.json`） | grep＋uniq -c |
| 用户实传源素材的对照 | **被拒**：480×960（`爆点/下载 (20).mp4`）、704×1248（`爆点2/…309.mp4`）。**过**：其余（口述，未逐条对读数） | 用户实传 |

### 〔已修订 2026-10-19 晚〕三个假设曾互相混淆 —— 五格对照已分离出两个

原文（写于取证之前，保留不删）：过的样本**既**宽度 ≥720 **又**是精确 9:16 **又**恰是标准档；
拒的样本三条全不满足。⇒「宽度下限」/「必须精确 9:16」/「标准分辨率白名单」分不开。

**五格对照的读数把它劈开了**（用户 2026-10-19 实传，红字原文逐格记录）：

| 格 | 尺寸 | 结果 | 红字原文 |
|---|---|---|---|
| B | 486×864（精确 9:16） | **拒** | 素材尺寸（**宽度**）不符合规范 |
| C | 1080×1620（2:3） | **拒** | 素材尺寸**比例**不符合规范 |
| D | 480×854 | **拒** | 素材尺寸（**宽度**）不符合规范 ⇒ 与已知一致，**台架可信** |
| E | 900×1600（精确 9:16、非标准档） | **过 ✅** | 无 |
| A | 1080×1920 | 待确认（截图未含） | — |

⇒ **平台是两条互相独立的校验**，证据是**措辞不同**（B 报宽度、C 报比例，同一次上传只命中一条）。
⇒ **「标准分辨率白名单」假设死**（E 不是任何标准档却过了）。
⇒ 比例规则已立为硬拦（`AspectRule.exactNineSixteen`，零容差）；
**宽度下限仍未证**，只夹到 **(486, 900]**，决定性的一格是 `720×1280`（F 格，已生成待传）——
因为 720p 是面板上现成的档位，它若过不了就得下架。
**代码里至今没有任何 `minWidth`**，这条纪律守住了。

## 二、根因（架构层）

**导出侧不存在"画幅/尺寸不变量"这一层。** `CLAUDE.md` 的 9:16 铁律只管展示视图，导出侧零约束；
尺寸规则因此被抄成 7 份，且无一处回读：

| # | 漏口 | 处置 |
|---|---|---|
| 1 | `DubExportService.swift:585-595` | 已删，改调 Core |
| 2 | `ExportService.swift:219-228`（第二份抄本，且**与第 1 份行为不一致**：那份认横屏） | 已删，改调 Core |
| 3 | `ExportService.swift:9-25` 枚举自带尺寸＋一个**全仓零引用**的 `scaleFilter` | 枚举下沉 Core，`scaleFilter` 删除 |
| 4 | `FFmpegRunner.swift:645` 兜底 `?? "1080:1920"` | 改非可选入参，兜底删除 |
| 5 | `ShotCompositionService.swift:39` 默认参数 `"720:1280"` | 改收 `DeliveryCanvas`，调用方 `ShotEditViewModel.swift:535` 同批改 |
| 6 | `DubExportService.swift:405-412` 把单段自身宽高当 maxWidth | 改调 Core（单段作业时"自身即本批最大"，语义等价，已注明） |
| 7 | `VariantBatchExportService.swift:136` 走**完全不带 scale** 的 `cutSegment` ⇒ 源尺寸原样出 | **未动**，属 §7.5 契约变更，等单独回报（代价已量，见 §六-2） |
| — | 导出前不校验、导出后只回读 `start_time`/`duration` | 已补前置闸＋后置回读（见 §三） |

**五问法**：被拒 → 画布不合平台判据（判据待分离）→ 为什么产出 480×854 → 面板有 `.p480` 档，
而 **480 宽的精确 9:16 高是 853.33，整数上永远凑不出合规画布**（结构性永远不达标，与"手滑"无关）→
为什么有这档没人管 → **没有承载"交付画幅"的类型，尺寸知识散在 7 份常量里且无一处回读**。

## 三、本轮落了什么

**Core 新增** `Sources/MixCutCore/DeliverySpec.swift`（已四段登记 pbxproj，已入 `check_pbx_registration.py` 名册）
- `DeliveryTier`（**恰三档**，480p 整档删除）＋ `DeliveryCanvas.size(...)` = 全应用唯一一处"档位→画布"
- `DeliveryCanvas.filterString`（`"W:H"` 冒号形状，原先只活在注释里）
- `DeliverySpec`：`provenAccepted`/`provenRejected` **证据表**（每行带日期＋一手来源），只登记两条硬事实；
  `judge` 只对已证形状表态，未覆盖的一律 `.unproven`
- `DeliveryGate.rejectionMessage`：只硬拦**已证拒收**的形状
- `DeliveryTargetID`（可持久化的目标标识，`spec` 现给证据表 —— 存"选了哪个目标"，不存证据表副本）
  ＋ `DeliveryCanvas.readout`（面板回显与 `size()` 同处产出；`.original` 拿不到素材尺寸时
  **如实说"导出时现算"，不假报一个数**）

**App 侧**：6 处尺寸决策改调 Core；导出前闸（`ExportError.deliveryBlocked`）＋
导出后 ffprobe 回读并与计划值比对（`FFmpegRunner.probeCanvasSize`、
`ExportError.canvasMismatch`/`canvasUnverifiable`，不符则删**本次自己创建**的成品）。
导出面板加「交付目标」Picker ＋ 一行实时回显（`ExportView.canvasReadout`，
此前该面板只有一个裸「分辨率」Picker，选中 480p 时屏上一个字都没变）。

**测试新增 39 条 `@Test` 声明**（Core 执行数 **1155**、App 测试目标 **11**）
- `Tests/MixCutCoreTests/DeliverySpecTests.swift` 22 条：档位矩阵（参数化，先例 `OrphanFileFinderTests.swift:148`）、
  偶数不变量、缺测兜底、非 9:16 源不带偏画布、横屏不翻转固定档、证据表可回溯性、
  **面板回显与换算同源（DS-05）**、派生量基准（DS-06）
- `Tests/MixCutCoreTests/ExportSizeSingleSourceGuardTests.swift` 12 条：App 侧画布字面量必须为 0、
  Core 侧必须仍有、扫描根健全、**四处近邻字面量必绿**（`ArrangeOrderSheet` 的 `minWidth: 720`、
  `ASRService` 的 `7200`、`ThumbnailCache` 注释、`Wan25VideoEditClient` 的 `"720P"`）、三条变异腿
- `MixCutAppTests/ExportCanvasReadbackTests.swift` 5 条：**真跑 ffmpeg ＋ 独立 ffprobe 回读**
  （全仓此前 `Tests/` 里 `ffprobe` 命中数为 **0**）；含 SAR 断言的阳性对照、空读数必须算失败

**文档同轮**：`PRODUCT_SPEC.md:264` 删 480p 并记原因；`CLAUDE.md` 新增「导出产物的画幅与尺寸」一节；
`docs/ROADMAP.md` 导出预设条目标注部分落地与缺口；`SubtitleMaskMode.swift` 那句
"480×854 的成片"改为"480 宽的成片（`.original` 仍会透出）"。

## 四、验证（真实读数）

| 腿 | 结果 |
|---|---|
| `swift test` 全量 | **1155 tests passed，4 known issues（均为既有故意红钉），非 known 失败 0** |
| `scripts/check_app_build.sh` | PASS（xcodebuild 全工程，258 编译单元） |
| `scripts/check_pbx_registration.py` | PASS（含新登记的 `DeliverySpec.swift`） |
| `scripts/check_project_integrity.sh` | PASS（含"测试文件未泄进 App target"一项） |
| App 测试腿 `xcodebuild -only-testing:MixCutAppTests test` | **TEST SUCCEEDED，15 passed / 0 failed**（ES-I 组 `.serialized` 后连绿 3 次 11/0，加 MCP 解析 4 条后 15/0；加 `.serialized` 前 7 次跑红 3 次，见 §四 末） |
| 其余 9 支 `check_*_guards.sh` | 全 PASS |
| `check_mcp_api_guards.sh` | **未跑完** —— 见 §六 |

### 过程中被守卫逮到的两件事（都是我的问题，不是误伤）

1. **`MediaAvailabilityGuardTests` G-M01 红**：我在 `DubExportService` 新增 2 处 `fileExists`
   （`existedBefore`，只清理本次自己创建的成品，与 `ExportService.swift:190` 同族）⇒ 名册 6 实得 8。
   按该守卫自己写的程序重生成（`MEDIA_DUMP_EXISTS_ROSTER=1`）后**只改真正变动的那一行**——
   生成物是脚手架：第二张表写着 `reason: "FILL_ME"`，且 `FileHelper` 那行 `exempt: true` 配空理由
   会反过来触发「豁免条目缺理由」，整段粘回会把门弄坏。
2. **`check_mcp_api_guards.sh` 拦我测旧产物**：我改过 Swift（含纯注释）却没重建 `.scratch/dd`，
   它拒绝用 10-16 的 dylib 给当前代码背书。重建后 U05 转绿。这条纪律是对的，我违反了它。

### 一处 flaky：初判"无法复现、真因未知"，后来复现并修掉了

〔初记，2026-10-19 白天〕App 测试腿**首跑**有 3 条（全部走 `concat` 的那 3 条）在 **0.000 秒即失败**
（抛错，非断言不过），同批不用 `concat` 的 2 条 2 秒后正常通过。增量重跑与冷构建重跑**都没能复现**，
所以当时记为「真因未知、不声称已修复」。

〔已推翻上面那句，同日 18:2x〕它**能复现**，而且不是偶发到看不见的程度：改完面板那一轮起
**连红 3 次**，且**失败集合会移动**（一会儿红这 3 条、一会儿红那 2 条），耗时读数 0.000 秒与
3~4 秒混杂。我先后提了四个假设，全部被自己的实验证伪：

| 假设 | 反证 |
|---|---|
| 冷构建取不到包内 ffmpeg | 用 `-derivedDataPath` 强制冷构建跑，**是绿的** |
| 宿主 App 正在被重签名/注册 | 4 次运行都有 `codesign`＋`RegisterWithLaunchServices`，其中 3 次绿 |
| `Skipping duplicate build file` 警告 | 绿与红的运行里都出现 2 次，不区分 |
| 共享一颗 `FFmpegRunner`（`runningProcess` 只有一个槽位，`FFmpegRunner.swift:125/276/448`） | 拆成"一条用例一颗"之后**仍然连红 3 次** |
| 磁盘/inode 耗尽导致 `mkstemp` 失败 | `df` 显示可用 370Gi、ifree 3.9G |

**真因与处置**：本组每条用例都要 spawn 多个 ffmpeg/ffprobe 子进程，而 Swift Testing **默认并行跑用例**；
压力上来时抛点在 `esIScratch()` 建目录那一步 —— 它在 `esIRequireBinaries()` 与 `esIRender()` 两处诊断
**之外**，所以 `Issue.record` 一次都没触发、Xcode 只留下 `mkstemp: fileSystemFailure`。
给套件加 `.serialized` 后**连绿 3 次**（11 passed / 0 failed × 3）。
这是结构性改动，不是"重跑到绿"。约束与已排除方向都写进了 `ExportCanvasReadbackTests.swift` 的套件注释。

**仍未钉死的一环**：我证明的是"串行化让它稳定"，不是具体哪一个系统调用在什么阈值上失败 ——
没有拿到 `esIScratch()` 抛出的错误原文（它在诊断范围外）。若哪天有人把这组改回并行，
预期症状就是本段描述的样子。

## 五、行为变更清单（需知悉）

| 变更 | 影响面 |
|---|---|
| 删除 480p 档 | 面板少一个选项。要小样请另立档位，勿复用 480×854 |
| 固定档不再随横屏源翻转 | 现网素材全竖屏 ⇒ 该分支不可达，实测无影响。旧两份抄本在此点本就不一致 |
| 导出后宽高不符即失败并删成品 | 新增失败模式。只删本次创建的文件，目标路径原有文件保留 |
| 导出前硬拦"已证拒收"画布 | 目前只可能命中 `.original` 透出 480×960 / 704×1248 这类源 |
| `concat(resolution:)` 由可选改必填 | 内部 API，2 个调用方已同批改 |
| `ShotCompositionService.compose` 默认参数移除 | 1 个调用方（`ShotEditViewModel.swift:535`）已同批改 |
| MCP `export_scheme` 结果 JSON 的 `exported` 由 `[路径]` 变成 `[{path,canvas,delivery_target}]` | 形状变更。实测无消费方（`mcp_api_guards.py` 不读它、`AgentToolCatalogTests` 只断 required 两键），但**外部 agent 若已按旧形状解析会断** |
| MCP `export_scheme` 新增可选入参 `delivery_target` | 不传即千川。未知值硬报错（不静默回退）⇒ 传过拼错值的调用方会从"静默按默认跑"变成"报错" |

## 六、还欠什么

1. **千川判据未分离**（阻塞 `DeliverySpec` 的约束字段形状与任何硬拦常量）。
   破混淆设计是五格对照小样，全部**同源同内容同时长、统一 `-b:v 6000k`**（该值远高于已证的 1.4 Mbps 放行值，
   使任何一格的红都归不到码率上）：`1080×1920`（阳性对照）/`486×864`（精确 9:16 但窄）/
   `1080×1620`（宽但画幅错）/`480×854`（已知红对照，意外过即台架坏了）/**`900×1600`**
   （精确 9:16、宽度达标、但非标准档 —— 专杀"白名单"假设）。需用户在其账号上逐条真传，测完即删。
   **2026-10-19 18:4x 更新：五格小样已生成并逐格 ffprobe 反查通过**（SAR 全 `1:1`、时长 15.000s、
   30fps、yuv420p、**均含音频轨**、码率 6.19~6.22 Mbps），落在
   `~/千川判据取证-2026-10-19/`，同目录 `README.md` 带读数表与判读规则。
   B/E 两格的精确 9:16 已手算复核：486×16=7776=864×9；900×16=14400=1600×9。
   **2026-10-19 19:0x 已传，读数见 §二** —— 三假设劈成两条独立校验，白名单假设死。
   已据此落地：`AspectRule.exactNineSixteen`（零容差，硬拦）＋ 名册新增
   `486×864 拒（宽度）`、`900×1600 过`，`judge` 区分"这个尺寸亲手传过被拒"与
   "没传过但违反已证规则"两种理由；判据 7 条（`AspectRuleTests`）。
   **仍欠两格读数**：① **F 格 `720×1280`**（已生成待传）—— 下限只夹到 (486, 900]，
   而 720p 是面板现成档位，它过不了就得下架；② **A 格 `1080×1920`** 的截图未截到，
   虽然它本就是阳性对照、且 D 格按预测红说明台架可信，仍应补一次确认。
   **代码里至今没有任何 `minWidth`** —— 这条纪律守住了。
2. **`VariantBatchExportService.swift:136` 的 `.original` 腿**仍不带 scale 出交付目录（漏口 #7）。
   〔**本条初稿的两处错记，2026-10-19 实测后改**〕
   - 我写过「改重编码会让分镜批量导出**明显变慢**，因为从流复制变重编码」—— **前提就是错的**：
     `cutSegment` 本来就用 `-c:v h264_videotoolbox` 重编码（该方法体里 `-c copy` 出现 **0 次**），
     要加的只是 scale/pad 滤镜。实测增量（同一条 20s 源、各跑两遍、产物均 ffprobe 反查为 1080×1920/600 帧）：
     `trim+videotoolbox` 3.84s、4.57s → 加 scale 后 4.76s、5.29s ⇒ **约 +18~23%**，不是数量级变化。
     （口径注：该源本就是 1080×1920，scale 近似空转，量到的是滤镜图开销；720→1080 上采会略高。）
   - **新发现（2026-10-19 18:4x），它改变了推荐结论**：路线 (b)「改走 `exportSingleSegment`」
     会顺带吃进 `renderSegment` 滤镜链尾的 `fps=\(fpsInt)` 归一化，而 `cutSegment` **不设帧率**。
     对 25fps 素材（素材库里 `爆点2/…309.mp4` 就是 25/1）这意味着**帧复制** ——
     比 +18~23% 的码率代价实质得多，且我原先没记。⇒ **(b) 不再按"推荐"交付**，
     要么先给 `renderSegment` 加"帧率原样透传"的形态，要么改走 (a)（必填 canvas，
     代价是 3 条中间片各吃一次空转 scale）。**已停下来等拍，未擅自选。**
   - 我写过这条腿"调用方 1 处"—— 也错。`cutSegment` 实测有 **4 个调用方**：
     `ShotVariantService.swift:69`、`ShotCompositionService.swift:60`、`VariantBatchExportService.swift:136`、
     `BatchSegmentExportService.swift:82`。其中 3 个切的是**中间片**（分镜变体、合成输入），不是交付件。
   - **因此留下的分叉（需拍）**：
     (a) 给 `cutSegment` 加**必填** `canvas:` 参数，4 个调用方一律表态 —— 3 个中间片传
         `.original` 语义（行为不变但各吃一次空转 scale 的 +18~23%），换来"没有调用能静默用源尺寸"；
     (b) 只改交付腿，让它改走既有的 `exportSingleSegment`（`DubExportService.swift:453`
         `keepOriginalAudio = isVoiceLocked || dubAudioPath == nil` 证明该路径本就支持无配音保原声，
         且已带闸与回读）—— 旁路被**删除**而非加补丁；但要它不加遮挡带得传 `isVoiceLocked: true`，
         而该标志语义是"人声已锁定"，**借来当"别遮挡"用是语义误用，将来会咬人**，
         做 (b) 就得先把"不遮挡"表达成显式参数而不是搭这个便车。
     推荐 (b) ＋ 顺带把遮挡开关显式化；(a) 是更便宜但把成本摊到三条中间片上的做法。
3. **MCP `export_scheme` 已落（2026-10-19 18:5x）**：新增可选入参 `delivery_target`
   （`enum: qianchuanVertical | unrestricted`，省略＝千川），handler 显式解析并带进 `ExportConfig`，
   结果 JSON 的 `exported` 每条回报 `canvas` 与 `delivery_target`。
   **未知值一律抛 `INVALID_ARGUMENT` 并列出可选项，不静默退回缺省** —— 静默回退就是无声分叉。
   判据 4 条见 `MixCutAppTests/ExportDeliveryTargetParsingTests.swift`，其中一条把
   "schema 里的 enum 必须逐字等于 `allCases`"钉住，防 schema 与解析两头漂。
   〔我原先写「改它要连 `scripts/mcp_api_guards.py` 一起动」—— **实测不需要**：
   `_dummy()` 只喂 required 字段（`delivery_target` 是可选），API-09 也只核 `completed ⇒ result 非空`，
   没有任何腿读 `exported` 的形状。守卫一行未改，11 支全 PASS。〕
   **仍欠**：MCP 这条路的 `resolution` 档位仍是默认 `.original`（要等 §六-2 的帧率问题与
   「`.original` 在投放目标下不可选」一起定）；且 `check_mcp_api_guards.sh` 本轮**未跑**
   （8787 被用户的 SunCut 持有，它会启动第二个实例并快照/还原用户偏好）。
4. **面板：选择器与回显已落，持久化未做，屏上未实机看过。**
   「交付目标」Picker ＋ `ExportView.canvasReadout` 实时回显已加（编译与判据都过）。
   两件事仍欠：
   - `ExportConfig` 仍不持久化。要做对得先把这份 config 的归属从 `@State` 改成 `@AppStorage`
     **单一来源**；若只是"再存一份到 UserDefaults 然后同步回 @State"，就造出两个地方各存一份
     —— 那正是本次在修的东西，不做半吊子版本。
   - **屏上没看过**。要看得重启用户正开着的 SunCut（PID 21334），按 `CLAUDE.md` 的规矩
     杀用户实例前须先确认 ⇒ 已交由用户决定，不声称已验证。
5. **`check_mcp_api_guards.sh` 未跑完**：端口 8787 被用户正开着的 SunCut（PID 21334）持有。
   该守卫会启动第二个实例并快照/还原用户偏好，而本轮改动与 MCP 零交集 ⇒ 未擅自执行。
   要跑需用户先退出 SunCut，或明示授权用 `MCP_PORT` 换端口跑。
6. **端到端真机一腿未做**：真导一条 + 真传千川确认放行（属 §六-1 的同一次出行）。
7. **本台账初稿的一处勘误（2026-10-19 自查后改）**：我一度记「`CLAUDE.md:143` 写的 `scripts/` 与实际目录
   Scripts/ 大小写漂移」。那是错的 —— `git ls-files` 显示跟踪路径就是小写 `scripts/`，我先前
   `ls Scripts/` 能通只是因为 macOS 文件系统大小写不敏感。`CLAUDE.md` 一直是对的；本台账里其余
   Scripts/ 已统一改回 `scripts/`（在区分大小写的检出上，写错就是错路径）。

## 七、改动文件（全部未提交）

- 新增：`Sources/MixCutCore/DeliverySpec.swift`、`Tests/MixCutCoreTests/DeliverySpecTests.swift`、
  `Tests/MixCutCoreTests/ExportSizeSingleSourceGuardTests.swift`、`MixCutAppTests/ExportCanvasReadbackTests.swift`、
  本台账
- 修改：`MixCut/Services/Export/ExportService.swift`、`MixCut/Services/Export/DubExportService.swift`、
  `MixCut/Services/VideoProcessing/FFmpegRunner.swift`、`MixCut/Services/ShotEdit/ShotCompositionService.swift`、
  `MixCut/ViewModels/ShotEditViewModel.swift`、`Sources/MixCutCore/SubtitleMaskMode.swift`（注释）、
  `Tests/MixCutCoreTests/MediaAvailabilityGuardTests.swift`（名册计数 6→8 ＋ 84→86）、
  `scripts/check_pbx_registration.py`（EXPECTED 追加）、`scripts/link_test_files.py`（文件名改为可传参）、
  `CLAUDE.md`、`PRODUCT_SPEC.md`、`docs/ROADMAP.md`、`MixCut.xcodeproj/project.pbxproj`（2 个新文件登记）
