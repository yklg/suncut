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
⇒ 比例规则已立为硬拦（`AspectRule.exactNineSixteen`，零容差）。

**〔同日 19:2x 补〕用户截到了面板原文，区间那一半不用再靠对照猜：**
「竖版视频：宽高比9:16，视频码率≥516kbps，大小≤1000M，**720\*1280≤分辨率≤1440\*2560**，4s≤时长≤300s」
与上面四格读数**逐格自洽**（486 与 480 宽 <720 报宽度；1080×1620 宽在区间内但比例不合报比例；
900×1600 两条都合故放行）⇒ 已立为 `ResolutionRange` 硬拦。

**它同时暴露我规则集缺的另一半：上限 1440×2560。** 素材库里实有 **10 颗 2160×3840**，
而 `.original` 是面板默认档 —— 4K 批次走默认档会超上限被拒，**比 480 那次更隐蔽，因为用户什么都没选错**。
`judge` 的次序也照平台校正了：先区间后比例（依据是 D 格两条都不合却报「宽度」），并有判据钉住。

**原文里仍未立的三条**：码率 ≥516kbps 与大小 ≤1000M 我们产物远超，不值得拦；
**时长 4s…300s 是真隐患** —— `BatchSegmentExportService` 导单分镜，而
`SegmentSplitRule.minimumSliceSeconds` 只有 0.3 秒，短分镜导出来就会被平台按时长拒。
本轮不擅自扩范围，记在 §六。

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

### 〔2026-10-20 这一轮的重取读数〕

| 腿 | 结果 |
|---|---|
| `swift test` 全量 | **Test run with 1183 tests passed，4 known issues（仍是那四条故意红钉），非 known 失败 0**（上一轮 1171 → 新增 LC 6 ＋ DP 3 ＋ ES-08 3） |
| `scripts/check_app_build.sh` | PASS（xcodebuild 全工程，258 编译单元） |
| App 测试腿（全 `MixCutAppTests`，含闸） | **21 条 0 红，连跑两次**；两次都只有 1 个宿主实例（对照：无闸时同样单实例却红 1~2 条）。② 落地后新增 VB 组 3 条 ⇒ **24 条 0 红，再连跑两次**（头一版 VB 没收闸时立刻红 3 条，见"台架账"） |
| 11 支守卫（`check_pbx_registration` ＋ 10 支 `check_*`） | **全 PASS**（② 落地后又复跑一遍，仍全 PASS） |
| `check_mcp_api_guards.sh` | **`--preflight-only` 已跑绿**（U07 六处成对＋一处互斥、U01 产物含 DEBUG 假库开关、U05 产物 10-20 12:10 不早于任何输入、U03 端口 8787 空闲，用户实例已退出）。**完整跑仍待用户对本条命令的明示授权** —— 它会启动一个 Debug SunCut 实例并快照/还原用户偏好；这一腿被权限层拦下，未绕过 |
| `check_mcp_api_guards.sh` | **仍未跑** —— 前提没变（要占 8787、起第二个 SunCut、快照/还原用户偏好），见 §六-5 |
| 分界实测（App 真链路 ＋ 同形 shell） | 见文末「§六-9 的处置结果」两张表 |

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

〔2026-10-20 补，这一环已钉上并换了正确的修法〕上面那句"串行化让它稳定"只撑到本目标
还只有一组渲染腿为止：新增 LC-I（第三组会 spawn 的 suite）之后全目标又红，症状一模一样。
**根因是 `.serialized` 的作用域只到单个 suite，不管 suite 之间** —— 所以组内串行从来只是
必要条件。修法改在台架层：跨 suite 的进程内闸 `withFFmpegBench` ＋ 抛错必记具名原因，
11 条渲染用例全部收进闸内；对照读数与作废的那次假绿（`-parallel-testing-enabled NO`
把用例数收成 0 却报 TEST SUCCEEDED）见文末「台架账」。

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
| 〔2026-10-20〕含**不足 3s 纯数字静音分镜**的方案：以前整条 `rc=234` 失败，现在能导出来 | 那条短静音分镜的音轨改走静音支路（内容等价：全零采样归一后仍是全零）。**作用面已量死**：有电平 1.0s、−81dB 近静音 2.5s 均逐字节不变，各有对照腿 |
| 〔2026-10-20〕导出面板四颗选择改为持久化 | 交付目标／档位／编码器／质量跨会话记住（以前每次进页面回默认）。副作用：上次选到一颗会被平台拦的档位，下次进来仍是那颗 —— 面板回显与导出前闸都还在，拦得住 |

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
   **〔同日 19:2x 结案〕** 用户截到面板原文，区间上下限均已立为硬拦（见 §二 补），
   F 格与 A 格**不再需要传**（本地那 6 条可直接删）。仍建议补一次 A 格实传做阳性确认，
   但那是台架自证，不再是判据缺口。
   **新暴露的缺口转为 §六-8**：面板原文的「时长 4s…300s」尚未立为规则。
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
     〔2026-10-20：持久化这一半已按「单一来源」落地，`@State` 那份持有已删除并有守卫钉住，
     见文末「§六-4 面板持久化的处置结果」。屏上实机看这一半**仍欠**，仍未重启用户实例。〕
5. **`check_mcp_api_guards.sh` 未跑完**：端口 8787 被用户正开着的 SunCut（PID 21334）持有。
   该守卫会启动第二个实例并快照/还原用户偏好，而本轮改动与 MCP 零交集 ⇒ 未擅自执行。
   要跑需用户先退出 SunCut，或明示授权用 `MCP_PORT` 换端口跑。
6. **端到端真机一腿未做**：真导一条 + 真传千川确认放行（属 §六-1 的同一次出行）。
7. **本台账初稿的一处勘误（2026-10-19 自查后改）**：我一度记「`CLAUDE.md:143` 写的 `scripts/` 与实际目录
   Scripts/ 大小写漂移」。那是错的 —— `git ls-files` 显示跟踪路径就是小写 `scripts/`，我先前
   `ls Scripts/` 能通只是因为 macOS 文件系统大小写不敏感。`CLAUDE.md` 一直是对的；本台账里其余
   Scripts/ 已统一改回 `scripts/`（在区分大小写的检出上，写错就是错路径）。

8. **面板原文里的「时长 4s…300s」尚未立为规则**（本轮不擅自扩范围）。
   这是**真实可达**的拒收面：`BatchSegmentExportService` 导的是单个分镜，而
   `SegmentSplitRule.minimumSliceSeconds = 0.3` 秒 —— 一条短分镜导出来就是 3 秒不到的片子，
   平台会按"时长"拒，而报错文案又会指向别处。
   要立的话得先定策略：是**导出前拦下短分镜**（用户得合并），还是**补到 4s**（改变成片内容）。
   这是产品决定，不是工程决定，等拍。
   同批原文里的「码率 ≥516kbps」与「大小 ≤1000M」**不拟立**：产物实测 3.0~6.2 Mbps、
   21~52 MB，离边界两个数量级，立了只会多一条永远不会响的闸。

9. **新发现一颗与本改动无关的既有缺陷：短时长方案在包内 ffmpeg 上直接导不出来。**
   一手证据（2026-10-19，`ExportService.export` 真跑，输入 1 秒）：
   包内 ffmpeg 8.1 以 **`rc=234`** 失败，stderr 是
   `Error submitting audio frame to the encoder` / `Error encoding a frame: Invalid argument`
   （aac 编码器），`Conversion failed!`。
   **分界点未量出**：我试图在 shell 里复现 1.0/2.0/3.0/3.5/4.0 秒的边界，**五个全都失败**
   —— 说明我那条复现命令与产品链路不同形，读数无效；只有"1 秒经产品路径必失败"这一条成立。
   与时长闸无关（闸在它之前就放行了），但**它和时长闸管的是同一类东西：短分镜**。
   要修得先按产品链路重取分界，属独立一轮，本轮不动。
   `MixCutAppTests/ExportDurationGateTests.swift` 第三条因此**故意不断言"1 秒能导成功"**，
   只断"不是被时长闸拦的" —— 否则这条判据会被一个无关故障绑住。
   〔2026-10-20：**分界已沿产品链路量出、缺陷已修**（成因是 `loudnorm` × 纯数字静音 × 不足 3s，
   不是"短时长方案"这么笼统），处置与读数见文末「§六-9 的处置结果」。LC-I 那三条真渲染腿
   已把"1 秒静音必须真导出来"钉成判据。〕

## 六-2 的处置结果（2026-10-19 晚，按推荐的「只拦变体」执行）

分镜批量那条面板一次导「原版＋全部变体」**两种**东西，所以没有一把梭：

- **变体腿已挂闸**：`exportSingleSegment`（实测仅此一个调用方 = `VariantBatchExportService`
  的 `.variant` 分支）现在过尺寸闸（原有）＋时长闸（本轮加）。变体含克隆配音＋BGM＋烧录字幕，
  是确定要投放的成片。
- **原版腿仍不挂**，但**屏上写明了**：`BatchExportSheet` 新增一行
  「变体按交付目标校验画幅与时长，不合规格会被拦下；原版按源片尺寸原样切出、
  **不做交付规格校验**（可能宽/高/时长不合平台要求）」。
  不写的话，"选了 20 个却只导出 18 个"那种无从察觉的坑会换个形式重演一次
  —— 这次是"原版全导出来了但传不上去"。
- 尺寸闸仍不覆盖原版腿（它走 `cutSegment`，无 scale）⇒ **漏口 #7 仍在**，
  只是现在**在屏上可见**了。要收它仍受帧率归一那个代价约束（见上）。

### 一处我写了又删的判据（恒真的假牙）

试过加一条"闸口措辞（『不可投放』『平台原文』）只许住 Core、App 侧必须为 0"的文本扫描。
**它是错的，已删**：`codeOnly` 会剥字符串字面量，而文案永远活在字符串里
⇒ "App 侧为 0" 恒成立，"Core 侧 ≥1" 当场读出 0。
措辞的唯一住所由**类型**保证：App 侧只能 `throw ExportError.deliveryBlocked(blocked)`，
拿到的是 Core 产出的字符串，没有构造权。留下的有效守卫是"三条腿都调
`DeliveryGate.durationRejectionMessage`"（代码位标识符，`codeOnly` 保留）＋ 一条摘腿变异腿。

## §六-9 的处置结果（2026-10-20：分界已量出，缺陷已修）

### 上一轮那条 shell 复现为什么作废，这一轮凭什么算数

上一轮我在 shell 里扫 1.0/2.0/3.0/3.5/4.0s，**五个全红** ⇒ 复现命令与产品链路不同形，读数无效。
这一轮改成**沿真产品链路扫**（`ExportService.export` → `FFmpegRunner.concat`，跑在 App 测试腿上，
宿主就是包内 ffmpeg 8.1），再让 shell 台架**先复现出产品链路量到的那颗分界**，才允许它做消融：

| 台架 | 2.5s | 3.0s | 凭什么可信 |
|---|---|---|---|
| App 测试腿（真链路） | **rc=234** | **rc=0** | 打的就是产品函数本身，一次跑测出整条分界 |
| shell（按 `concat()` 逐参数复刻） | **rc=234** | **rc=0** | 与上一行同形，之后才拿它做消融与取值 |

### 分界与成因：三因合取，缺一不炸

| 条件 | 读数 |
|---|---|
| 纯数字静音 ＋ 2.5s / 2.9s | **rc=234**，stderr 有 `[aac] Input contains (near) NaN/+-Inf` |
| 纯数字静音 ＋ 3.0s / 3.1s / 6.0s | rc=0 |
| 有电平（440Hz）＋ 1.0s / 2.5s | rc=0 |
| 近静音（实测 RMS −81.08 dB）＋ 2.5s | rc=0 |
| **1s 静音分镜 ＋ 4s 有声分镜（总 5s）** | **rc=234** ⇒ 尺寸闸、4s 时长闸都过了仍整条死 |

成因：ffmpeg 8.1 的 `loudnorm` 只剩线性模式（`-h filter=loudnorm` 实测已无 `duration`/
`dynaudnorm`/`override` 等动态档开关），对**不足测量窗的纯数字静音**给出 NaN，
aac 编码器拒收 ⇒ 整条导出失败。**中毒单位是单条分镜，不是成片总时长** —— 所以 §六-8 立的
时长闸救不了它，两条管的是同一类东西却拦不住彼此。屏上此前只有一句
「视频处理失败…（错误码 234）」，原因一个字都没说。

### 修法与它的作用面

规则落 Core：`Sources/MixCutCore/DubSegmentGraph.swift` 新增 `LoudnessChainPolicy`
（`measurementWindowSeconds = 3.0` ＋ `needsSilenceProbe` ＋ `mustBypassLoudnorm`）。
`FFmpegRunner.concat` 的音频支路判据从「有没有音轨」换成「**有没有可听的音频**」，
新增 `probePureDigitalSilence`，取值口径是 `astats` 的 `RMS level dB: -inf`。

判据只认 `-inf`（不是"够安静"）⇒ **作用面严格等于今天必然失败的那些**：
有电平与近静音两条腿各钉了一条"必须仍走 loudnorm"的对照，滤镜串对这些片子逐字节不变。
探测只在不足窗口时发起（长段不付这次解码），探测失败一律按"非静音"处理 ⇒ 不把"没读到"读成"是静音"。

排除掉的路线（都实测过，不是推断）：
- `loudnorm=…:linear=0` —— **不修**（2.5s 纯静音仍 rc=234），且对有电平音频增益无影响
  （mean_volume 两写法都是 −15.3 dB）⇒ 这颗开关在 8.1 上是死的。
- 把时长闸提到 3s 以上 —— 治不了它（M1 那格总时长 5s 已过闸），还会误伤合法短分镜。

### 变异腿：把判据摘掉，红的恰好只有该红的那几条

把 `LoudnessChainPolicy.mustBypassLoudnorm` 的实现临时改成恒 `false`（跑完按预读字节整份还原，
md5 对回原值），两侧读数：

| 腿 | 变异态结果 |
|---|---|
| Core `实测分界` | **红**，且逐参数报 `2.9 / 2.5 / 1.0` 三格 `bypass → false` |
| Core `近静音不等于静音` / `零长负长` | **红**（各 1 issue） |
| Core `有电平一律不绕开` / `达到窗口不绕开` | **绿** —— 它们断言的正是 false，摘掉判据当然不违反 |
| App `LC-I-01 最小复现（1s 静音单段）` | **红** |
| App `LC-I-02 真产品可达形态（1s 静音＋4s 有声）` | **红** |
| App `LC-I-03 探测作用面` | **绿** —— 它测 `probePureDigitalSilence` 本身，与这条判据无关 |
| App ES-I 5 条 / DG 3 条 | **绿** —— 它们的源是 `-an`（无音轨），根本不进这条支路 |

⇒ 这条判据是**承重**的，且判据集对它的作用面判断是准的：只有依赖它的用例红，
不该依赖的一条都没被牵连。

### 族账：`loudnorm` 在仓库里有两处住所，本轮只修了有复现的那一处

- `FFmpegRunner.concat` —— 整方案导出与分镜中间片合成（`ShotCompositionService`）两条腿都走它 ⇒
  **已修**，并已真渲染取证。
- `DubSegmentGraphBuilder.loudnorm` —— 配音中间片那条腿，输入是 TTS 配音 m4a，**未复现**该态 ⇒ 不凭空
  改这里；已在代码就地留指针注释，要判得先给 builder 传"这条配音多长／是否纯静音"。

### 同一条链上的另一处读数：产物音频落盘 96000 Hz，不是链上写的 44100

`concat()` 的音频链写的是 `aresample=44100,loudnorm=…` —— 但 `loudnorm` 内部把采样率抬到 192kHz
再输出，`aresample` 在它**之前**所以白做，aac 编码器上限 96k ⇒ **每一条成功导出的成片落盘都是
96000 Hz**（产品链路 stderr 直读，另用 ffprobe 在 4 颗产物上复核）。把 `aresample=44100` 挪到
`loudnorm` **之后**即可兑现链上写的那句话：

| 量（真素材 `爆点2/…309.mp4`） | 现状（resample 在前） | 挪后 |
|---|---|---|
| mean_volume @6s / @12s | −18.5 / −21.5 dB | −18.5 / −21.5 dB |
| max_volume | −2.9 dB | −3.0 dB |
| 落盘采样率 | **96000** | **44100** |

〔我第一版消融表里"输出采样率"整列读的"无音频流"是**台架故障** —— 我拿 ffmpeg 当 ffprobe 用了，
`-show_entries` 它不认。上表是改对之后重取的。〕

**未落地**，等拍：它改的是每一条交付件的音频采样率（影响面＝全量导出），而 96k 至今没有一条
平台侧受害证据。要动只改一处滤镜顺序，对照数据已备好。

## §六-4 面板持久化的处置结果（2026-10-20）

四颗选择（交付目标／分辨率档／编码器／质量）现在**只住 `@AppStorage`**，
`ExportView.exportConfig` 改成每次现组装的派生计算属性，`@State` 那份持有已删除 ——
不是"再存一份到 UserDefaults 然后同步回 @State"（那正是本轮在修的形状）。

- 键：`exportDeliveryTargetRaw` / `exportResolutionRaw` / `exportCodecRaw` / `exportQualityRaw`
  （存枚举 `rawValue` 串，与本仓 `importDefaultSourceRaw`、`asrPreferenceRaw` 同形）。
- 还原规则一份：`RawRepresentable` 扩展 `init(persisted:fallback:)`（Core，`swift test` 覆盖）。
  读不认识的值 ⇒ 回落调用方给的缺省，**不**回落到 `allCases.first`。
- 缺省值一份：只有 `ExportConfig` 那四行属性初值。面板初值与 `@AppStorage` 初值都从
  `ExportConfig()` 现取，不另写缺省表。
- 守卫 3 条（`ES · 面板导出偏好只住 @AppStorage`）：四颗键在场、`@State private var exportConfig`
  必须为 0 且派生组装处恰好 1 处、以及"复活 @State 抄本必须被抓住"的变异腿。
  这组**扫原文不扫 `codeOnly`** —— 键名活在字符串字面量里，走 `codeOnly` 会当场变成恒真判据
  （同一个坑本轮踩过一次，见下面"我写了又删的判据"）。
- **屏上仍未实机看过**：要看得重启用户正开着的 SunCut，按 `CLAUDE.md` 规矩杀用户实例前须先确认 ⇒
  已交由用户决定，本轮不声称已验证。
- 范围外并案（不是挂着，是判过不做）：BGM 选择与音量不落盘 —— 它是**内容选择**不是设备偏好，
  且面板已有"文件还在不在"的复检；把它持久化会把"选过的 BGM 已被删"变成每次进页面都要处理的状态。

## 台架账：跨 suite 的渲染腿必须共一道闸（2026-10-20，红→定位→绿）

§四 末记的那颗未解释空抛，本轮**定位到了作用域并修在台架层**（生产码未动）：

| 配置 | 结果 |
|---|---|
| ES-I 单独跑（5 条） | 绿 |
| LC-I 单独跑（3 条） | 绿 |
| ES-I ＋ LC-I 并跑 | 一次红 2 条、一次绿 ⇒ **失败集合会移动** |
| 全目标（新增 LC-I 后，无闸） | 一次红 1 条、一次红 2 条，两次红都只在**一个**宿主实例内 |
| 全目标 ＋ `withFFmpegBench` 闸 | **21 条全跑、0 红**，连跑两次 |
| 全目标 ＋ 闸，但**新加的第四组渲染腿（VB 3 条）没收闸** | **又红 3 条**（`ES-I-01` ＋ VB 两条）⇒ 反向确认了因果：漏一组进闸＝等于没闸，症状与之前一模一样 |
| 全目标 ＋ 14 条全收闸 | **24 条 0 红**（读数见 §四 补记） |

根因：`.serialized` 的作用域是**单个 suite**，不管 suite 之间。加了第三组会 spawn 的渲染腿之后，
suite 之间并行 ⇒ 子进程/临时目录压力一起上来，抛点在各文件 `Issue.record` 诊断之外，所以是"瞎红"。
修法：`MixCutAppTests/ExportCanvasReadbackTests.swift` 里加进程内 FIFO 闸 `FfBenchGate` ＋
`withFFmpegBench(_:_:)`，会 spawn 的用例体**全部**收进这道闸（ES-I 5 ＋ DG 3 ＋ LC-I 3 ＋ VB 3 ＝ 14 条），
顺带把"抛出必须记具名原因"补上（本目标四轮瞎红都栽在不打原因上）。
`.serialized` 保留 —— 它管组内顺序，是必要的但不充分；已把这段写进两处注释，别再当成已经修完。

⚠️ 闸门只在**进程内**有效：实测跑子集时 xcodebuild 会起 2~4 个宿主实例（跑全目标起 1 个），
实例之间仍会互相压。别用 `-parallel-testing-enabled NO` 去治 —— 实测它把用例数收成 0 却报
**TEST SUCCEEDED**，是假绿（本轮抓到并作废过一次读数）。

## §六-2 漏口 #7 的处置结果（2026-10-20，拍定「只拦不改」）

### 当初记的两条路都不是该走的路

(a)「给 `cutSegment` 加必填画布」与 (b)「交付腿改走 `exportSingleSegment`」都是**为了修尺寸不合而改掉产物**。
而"原版"这个词的意思就是源片原样 —— 给它加 scale 等于把这个名字变成谎话。加上各自实测到的代价
（(a) 三条中间片白付 +18~23%；(b) 顺带吃进 `fps=30` 归一 ⇒ 25fps 素材出帧复制），两条都否掉了。

### 落的是第三条：切前按交付目标拦，切完回读

`VariantBatchExportService.deliverOriginal`：

- 切之前用**这颗文件自己的**宽高 ＋ 切片时长过一次现成的两条闸（`DeliveryGate.rejectionMessage` ＋
  `durationRejectionMessage`），不合就整条不导、进失败清单，文案仍是 Core 那一处（没有第二条措辞）。
- 切完回读一次落盘宽高并与切前值比对 —— **这条腿此前零回读**。
- 为什么现读而不是取 `video.width/height`：`effectivePicture` 可能是**合成过的中间片**，
  它的尺寸与源视频并不必然相同 ⇒ 拿源片数字当产物数字，等于闸白挂。读不到宽高即整条失败，
  「没读到」不算"合格"。
- 作用面：只在交付目标为千川时生效；选「不限（仅本地留档）」照常出原版 ⇒ 想留档的路径没被堵。

屏上那句「原版按源片尺寸原样切出、**不做交付规格校验**」已改掉（继续写着就是假话），
现在写的是"变体与原版都校验、不合规格的那条不导；区别只在变体缩放、原版不缩放"。

### 三条真跑读数（`MixCutAppTests` 的 VB 组，打的是真 `exportAll`）

| 用例 | 实测 |
|---|---|
| 480×960 源、切 5s（时长刻意合） | `succeeded=0 products=[]`，原因原文：**输出画布 480×960 不可投放（该尺寸已被实传证明拒收；2026-10-19…）…若确需该尺寸，请选「不限（仅本地留档）」交付目标** |
| 1080×1920 源、切 2s（尺寸刻意合） | `succeeded=0 products=[]`，原因原文：**成片时长 2.0s 不可投放（时长须落在 4s ~ 300s 之间…）** |
| 1080×1920 源、切 5s（两条都合，阳性对照） | `succeeded=1 products=["原版.mp4"]`，回读 1080×1920 |

两条拦截用例各自**只让一条规则不满足**，所以"被拦下"能归到该归的那条上；
阳性对照证明前两条的红不是台架坏了。守卫同步改口：ES-07 从"三条腿"改成**四条腿**
（计数 3→4，含摘一条腿的变异腿），Core 里 `durationRejectionMessage` 文档中"三条导出腿"那句同轮一起改。

### 族账（还剩一处未收，等拍）

同一形状的还有 **MCP 的 `export_segments`**（`BatchSegmentExportService`，只有 MCP 在用、UI 不走它）：
它也是按源片尺寸切、也没有任何闸与回读。**本轮没顺手改**，因为那是自动化调用方的契约变化
（它的 `failed` 数组会多出尺寸/时长原因条目），属 §六-3 那条"MCP 档位口径"同一件事，等一起拍。
改动只有一处调用 + 一次 ffprobe，判据可复用 VB 那三条的写法。

## 七、改动文件（12 笔已提交；2026-10-20 这一轮尚未提交）

- 新增：`Sources/MixCutCore/DeliverySpec.swift`、`Tests/MixCutCoreTests/DeliverySpecTests.swift`、
  `Tests/MixCutCoreTests/ExportSizeSingleSourceGuardTests.swift`、`MixCutAppTests/ExportCanvasReadbackTests.swift`、
  本台账
- 修改：`MixCut/Services/Export/ExportService.swift`、`MixCut/Services/Export/DubExportService.swift`、
  `MixCut/Services/VideoProcessing/FFmpegRunner.swift`、`MixCut/Services/ShotEdit/ShotCompositionService.swift`、
  `MixCut/ViewModels/ShotEditViewModel.swift`、`Sources/MixCutCore/SubtitleMaskMode.swift`（注释）、
  `Tests/MixCutCoreTests/MediaAvailabilityGuardTests.swift`（名册计数 6→8 ＋ 84→86）、
  `scripts/check_pbx_registration.py`（EXPECTED 追加）、`scripts/link_test_files.py`（文件名改为可传参）、
  `CLAUDE.md`、`PRODUCT_SPEC.md`、`docs/ROADMAP.md`、`MixCut.xcodeproj/project.pbxproj`（2 个新文件登记）
- 〔上面这份名单停在 15 条那个状态，落后于实际。同日晚上又落了 3 个 App 测试文件与一批闸门，
  已在 §三 与提交历史里记账；2026-10-20 这一轮的清单见下〕
- **2026-10-20 这一轮**（时长闸之后的独立一轮，未提交）：
  新增 `Tests/MixCutCoreTests/LoudnessChainPolicyTests.swift`；
  修改 `Sources/MixCutCore/DubSegmentGraph.swift`（新增 `LoudnessChainPolicy` ＋ 配音腿的族账注释）、
  `Sources/MixCutCore/DeliverySpec.swift`（新增 `init(persisted:fallback:)`）、
  `MixCut/Services/VideoProcessing/FFmpegRunner.swift`（`probePureDigitalSilence` ＋ 音频支路改判据）、
  `MixCut/Services/Export/ExportService.swift`（`ExportConfig` 的四串 rawValue 组装处）、
  `MixCut/Views/Export/ExportView.swift`（四颗 `@AppStorage` ＋ 派生 `exportConfig`）、
  `MixCutAppTests/ExportDurationGateTests.swift`（新增 LC-I 三条真渲染腿、删掉临时诊断腿、
  `source()` 提到文件级并支持静音/有电平/近静音三种源）、
  `MixCutAppTests/ExportCanvasReadbackTests.swift`（`FfBenchGate` ＋ `withFFmpegBench`，5 条收进闸）、
  `Tests/MixCutCoreTests/DeliverySpecTests.swift`（DP 组 3 条）、
  `Tests/MixCutCoreTests/ExportSizeSingleSourceGuardTests.swift`（ES-08 组 3 条）、`CLAUDE.md`、本台账
- **同日第二批（② 只拦不改）**：修改 `MixCut/Services/Export/VariantBatchExportService.swift`
  （新增 `deliverOriginal`：切前两条闸＋切后回读；文件头那条"绕过全部尺寸决策"的注释已改成现状）、
  `MixCut/Views/SegmentLibrary/BatchExportSheet.swift`（屏上那句"原版不做交付规格校验"已成假话，改掉）、
  `MixCutAppTests/ExportDurationGateTests.swift`（新增 VB 组 3 条真跑腿，并收进同一道闸）、
  `Tests/MixCutCoreTests/ExportSizeSingleSourceGuardTests.swift`（ES-07 三条腿→四条腿）、
  `Sources/MixCutCore/DeliverySpec.swift`（文档里"三条导出腿"那句同步改四条）、本台账、`docs/优化日志.md`
