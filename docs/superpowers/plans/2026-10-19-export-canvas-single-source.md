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

### 三个假设目前互相混淆，一个都没被证伪

过的样本**既**宽度 ≥720 **又**是精确 9:16 **又**恰是标准档；拒的样本三条全不满足。
⇒「宽度下限」/「必须精确 9:16」/「标准分辨率白名单」**分不开**。平台文案写「宽度」只是文案，不是判据证明。
**因此本轮没有把任何门槛数字写进代码**（见 §四 的降级设计）。

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

**App 侧**：6 处尺寸决策改调 Core；导出前闸（`ExportError.deliveryBlocked`）＋
导出后 ffprobe 回读并与计划值比对（`FFmpegRunner.probeCanvasSize`、
`ExportError.canvasMismatch`/`canvasUnverifiable`，不符则删**本次自己创建**的成品）。

**测试 33 条**（全仓 1122 → **1149**）
- `Tests/MixCutCoreTests/DeliverySpecTests.swift` 16 条：档位矩阵（参数化，先例 `OrphanFileFinderTests.swift:148`）、
  偶数不变量、缺测兜底、非 9:16 源不带偏画布、横屏不翻转固定档、证据表可回溯性、派生量基准
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
| `swift test` 全量 | **1149 tests passed，4 known issues（均为既有故意红钉），非 known 失败 0** |
| `scripts/check_app_build.sh` | PASS（xcodebuild 全工程，258 编译单元） |
| `scripts/check_pbx_registration.py` | PASS（含新登记的 `DeliverySpec.swift`） |
| `scripts/check_project_integrity.sh` | PASS（含"测试文件未泄进 App target"一项） |
| App 测试腿 `xcodebuild -only-testing:MixCutAppTests test` | **TEST SUCCEEDED，11 passed / 0 failed**（增量、冷构建、加前置探针后共 3 次均绿） |
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

### 一处未解释的现象（诚实记录）

App 测试腿**首跑**有 3 条（全部走 `concat` 的那 3 条）在 **0.000 秒即失败**（抛错，非断言不过），
同批不用 `concat` 的 2 条 2 秒后正常通过。增量重跑与冷构建重跑**都没能复现**，
所以「冷构建取不到包内 ffmpeg」这个第一假设**已被证伪**，真因未知。
已加 `esIRequireBinaries()` 前置探针，把未来的同类空抛换成具名原因；**不声称已修复**。

## 五、行为变更清单（需知悉）

| 变更 | 影响面 |
|---|---|
| 删除 480p 档 | 面板少一个选项。要小样请另立档位，勿复用 480×854 |
| 固定档不再随横屏源翻转 | 现网素材全竖屏 ⇒ 该分支不可达，实测无影响。旧两份抄本在此点本就不一致 |
| 导出后宽高不符即失败并删成品 | 新增失败模式。只删本次创建的文件，目标路径原有文件保留 |
| 导出前硬拦"已证拒收"画布 | 目前只可能命中 `.original` 透出 480×960 / 704×1248 这类源 |
| `concat(resolution:)` 由可选改必填 | 内部 API，2 个调用方已同批改 |
| `ShotCompositionService.compose` 默认参数移除 | 1 个调用方（`ShotEditViewModel.swift:535`）已同批改 |

## 六、还欠什么

1. **千川判据未分离**（阻塞 `DeliverySpec` 的约束字段形状与任何硬拦常量）。
   破混淆设计是五格对照小样，全部**同源同内容同时长、统一 `-b:v 6000k`**（该值远高于已证的 1.4 Mbps 放行值，
   使任何一格的红都归不到码率上）：`1080×1920`（阳性对照）/`486×864`（精确 9:16 但窄）/
   `1080×1620`（宽但画幅错）/`480×854`（已知红对照，意外过即台架坏了）/**`900×1600`**
   （精确 9:16、宽度达标、但非标准档 —— 专杀"白名单"假设）。需用户在其账号上逐条真传，测完即删。
2. **`VariantBatchExportService.swift:136` 的 `.original` 腿**仍不带 scale 出交付目录（漏口 #7）。
   〔**本条初稿的两处错记，2026-10-19 实测后改**〕
   - 我写过「改重编码会让分镜批量导出**明显变慢**，因为从流复制变重编码」—— **前提就是错的**：
     `cutSegment` 本来就用 `-c:v h264_videotoolbox` 重编码（该方法体里 `-c copy` 出现 **0 次**），
     要加的只是 scale/pad 滤镜。实测增量（同一条 20s 源、各跑两遍、产物均 ffprobe 反查为 1080×1920/600 帧）：
     `trim+videotoolbox` 3.84s、4.57s → 加 scale 后 4.76s、5.29s ⇒ **约 +18~23%**，不是数量级变化。
     （口径注：该源本就是 1080×1920，scale 近似空转，量到的是滤镜图开销；720→1080 上采会略高。）
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
3. **MCP `export_scheme`** 仍靠默认 `.original`（`MCPToolHandlers.swift:574` 不传 config）；
   改它要连 `AgentToolCatalog` 的 inputSchema 与 `scripts/mcp_api_guards.py` 一起动。
4. **面板「交付目标」选择器与实时回显**（计划 W3）未做；`ExportConfig` 仍不持久化。
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
