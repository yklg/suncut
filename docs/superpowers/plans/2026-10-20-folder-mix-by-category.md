# 2026-10-20 · 素材文件夹驱动的类别混剪（需求澄清 + 实现计划）

需求：指着一个素材根目录，App 认出它的一级子文件夹名当类别；用户勾选并排列类别；按排列顺序从每个文件夹各随机抽一条视频，整片顺序拼成成片。

一句话结论：**这不是新模块，是补前半段。** 拼接、排序、建方案、导出这四段仓库里已跑通并实读核实；要新写的是「扫一级子目录 + 文件夹名→类别 + 每类随机择一且会话内不回放」这一层，其中**随机性是本仓库从零引入的概念**，必须做成注入 seed 的纯函数才可测。

## 〇、取证状态表（先声明哪些数是真读过的）

| 类别 | 条目 |
|---|---|
| 已实读核过 | 下文所有 `文件:行号`，除标注〔勘误〕者外均为本轮 `sed`/`grep` 实读输出 |
| 已勘误 | R1–R52 五十二条，见「修订记录」：R1–R5 行号/引用错（含一条我凭空写出的守卫），R6–R10 方案级返工（R10 连上一轮审查自己的推荐一起推翻），R11–R13 丁案自身的三处缺陷，R14–R17 评审实做闭合出的四处，R18–R19 **第二次评审把自己推荐的 D19 也打回**（半径 7→2，G-f 整块取消），R20–R22 Step 1 落地那一轮实读再收三处（扩展名实为三处、`:838` 属既有行为⇒半径 7→1、四个锁定签名改形才有牙齿），R23–R24 Step 5–7 落地时收的两处（`ExportInput` 不在 Codable 落盘纪律的适用面上；⌘7 是既有缺口不是本期新增）。原文一律保留并标〔已作废〕〔已消解〕〔已证伪〕〔已闭合〕，不删 |
| 已跑 | 〔2026-10-22 现状，join 修复笔 J1–J3 落地后〕`swift test`（全量）→ **1324 通过 / 0 真失败 / 4 known issues**；混剪族 **141 条**：Picker 27 / Scanner 21 / Orchestration 24 / IngestGuard 23 / Resolve 11 / Budget 12 / WholeClip 8 / SessionState 10 / CR 5。门仍 17 道 PASS，`selftest_folder_mix_guards.py` 17 把逐把咬住自己那道门；Core 侧台架多出第五支 `.scratch/fm_mutate_stepJ.py` **12 把全咬中**（K1/K9/K10 三把专门证明「改回反查就会红」）；`check_pbx_registration.py` 128 颗全登记（含 App 测试目录那颗）；**App 腿新增第一颗混剪判据** `MixCutAppTests/FolderMixIngestJoinTests.swift`（2 条：TC-J2 去重命中支 / TC-J3 新建整片段支）—— `xcodebuild test` 那条腿由用户跑；typecheck / silgen / `xcodebuild build` / `build-for-testing` 四项本轮复跑 PASS |
| 已跑 | 〔2026-10-21 读数，第二轮笔 1a–笔 7 全部落地后〕`swift test`（全量）→ 1306 个测试通过、0 真失败、4 known issues。族数与条数：Picker 27 / Scanner 21 / IngestGuard 19 / Orchestration 14 / SessionState 10 / Resolve 7 / Budget 12 / WholeClip 8 / CR 5 = 123 条混剪族判据。守卫 17 道（G-a1…G-l1，**无 G-f**，G-f 那四处目标值随 R18/R19 一起取消）；台架刀：shell 侧 17 把（`scripts/selftest_folder_mix_guards.py`）+ Core 侧 17+10+11+10 把（`.scratch/fm_mutate_step1/2/4/5.py`、`fm_mutate_1a.py`）+ 预览件四腿台架 180 条断言 11 把刀。〔2026-10-20 的历史读数：全量 1257 通过 / 4 known issues，Step 1–7 落地时〕 |
| 未跑 | **App 四腿本轮全部跑过**：`MODE=typecheck` / `MODE=silgen` / `xcodebuild -derivedDataPath .scratch/dd build` / `build-for-testing` 四项 PASS，每轮改过 Swift 都重建了 `.scratch/dd`。silgen 腿本轮再次抓到 typecheck 漏掉的 `missing return`（两颗探针 reader 在 `AsyncStream` 前插日志那一笔）—— 这条腿的存在理由被现场复现。`xcodebuild test -only-testing:MixCutAppTests` 仍**交给你跑**（会拉起宿主实例并占 8787 端口） |
| 真机验收 | 未做。第六节的端到端清单是**待执行**，不是已验证 |
| 一手外部源 | MoneyPrinterTurbo `app/models/schema.py`（curl 取回，`video_count ge=1 / le=5`、`video_clip_duration` 默认 5）；Shotstack/Creatomate 官方文档抓取失败 ⇒ 相关表述标注为"基于已知推断，未联网核验" |

## 一、既有能力盘点

| 环节 | 现状 | 取法 |
|---|---|---|
| 按序拼接 | ✅ `FFmpegRunner.concat(segments:[(path,start,end)],…)` `MixCut/Services/VideoProcessing/FFmpegRunner.swift:600` 起，含 scale/pad 统一画幅、30fps、有无音轨自动补静音、loudnorm、VideoToolbox | 实读 |
| 保留各素材原声 | ✅ `MixScheme.audioTrackPolicyRaw` 默认 `keepOriginal` `MixCut/Models/MixScheme.swift:37` | 实读，零改动 |
| 跨项目分镜建方案 | ✅ `ExportInput.from(scheme:)` 只走 `schemeSeg.segment → video → effectivePicture`，**不读 `scheme.project`** `MixCut/Services/Export/ExportService.swift:165-190` | 实读 |
| 勾选+排序+建方案 | ✅ `Views/SegmentLibrary/ArrangeOrderSheet.swift`（左右箭头，非拖拽）+ `SchemeViewModel.createCustomScheme(from:in:)` `ViewModels/SchemeViewModel.swift:954` | 实读 |
| 批量串行导出 | ✅ `VariantBatchExportService.export(jobs:…)` `Services/Export/VariantBatchExportService.swift:118-168`，for 循环、每条开始前查取消、失败删半成品、同名加 `(1)(2)` | 实读 |
| **识别文件夹名** | ❌ 拖入文件夹被 `isVideoFile` 过滤丢弃 `Views/Import/ImportView.swift:132`（fileImporter）与 `:243`（dropDestination）；`docs/ROADMAP.md:135` 把「拖拽文件夹一键导入」仍列在长期 idea 池 | 实读 |
| **每类随机择一** | ❌ 全库无 `randomElement` / `shuffled` 使用 | 全库 grep |

## 二、决议台账（用户逐条拍板）

| # | 议题 | 决议 |
|---|---|---|
| D1 | 目录→资产映射 | 根目录 = 一个 Product（名=目录名）；每个一级子文件夹 = 一个 Project（名=文件夹名）。零新数据模型　〔已修订 2026-10-21：根目录/子目录的建库时机与「扫描即建库」都被 D25/D26 改判：扫描零建库，生成时才建〕 |
| D2 | 子目录层级 | 只扫一级，不递归 |
| D3 | 择片规则 | 每类随机抽 1 条；**多次生成之间不回放**（会话内已用集合，该类抽空才重置）。⚠ 作用域是**会话内**：`used` 只活在 `FolderMixViewModel` 内存、不落 UserDefaults ⇒ App 重启即失效。**界面文案必须写「本次会话内不回放」**，不得写无条件承诺（预览件原写「已生成的不再回放」，属过度承诺，见 R7）　〔已修订 2026-10-21：素材级「会话内不回放」作废，改判成 D23 的组合级不重复（同一素材允许在不同条里复现）〕 |
| D4 | 拼接单位 | 整片直接拼，不截时长 |
| D5 | 时长上限 | 不受 30 秒上限约束，所有视频都参选 |
| D6 | 音频 | 保留各素材原声（沿用 `keepOriginal`） |
| D7 | 出片数量 | 原文：「单条，不需要批量裂变」。**〔已修订 2026-10-20〕用户反问「一次可以出几条」⇒ 改判，见 D16** |
| D8 | AI/API | 全跳过：不跑 ASR、不跑 AI 打标（现通路第 6、7 步 `ImportViewModel.swift:518-529`〔2026-10-21 行号勘误：自建分镜入库的 ASR 与 AI 打标两步，下沉后行号上移〕） |
| D9 | 生成时机 | 先预览再确认　〔已修订 2026-10-21：预览/确认两段式仍在，但主按钮已收成一颗（D27），且预览不再消耗组合〕 |
| D10 | 方案归属 | 自动建汇总 Project「文件夹混剪」，因 `MixScheme.project` 是单值 `MixScheme.swift:22` |
| D11 | 汇总项目复用 | 一个产品共用一个 |
| D12 | 重名 | 同名 Product/Project 合并复用，不加后缀　〔已修订 2026-10-21：同名合并仍在，但建库时机改到生成期（D26），扫描期一颗项目都不建〕 |
| D13 | 空类别 | 标灰 + 写明原因，不阻断确认　〔已修订 2026-10-21：空类仍标灰不阻断；新增：空类默认不勾，勾了也不进乘积（D29/R4）〕 |
| D14 | 挂载点 | **A：侧栏新增独立页**（看完渲染预览拍定） |
| D15 | 版面约束 | 整页必须在真实最小窗口 **900×600**（`App/ContentView.swift:217` 的 `minWidth/minHeight`）内**不滚动**走完流程 |
| D16 | 一次几条 | **N 条，N 钳到「不重复上限」** = 参与类别可用素材数的最小值。软件层无硬钳制，真限制只有两条：素材供给木桶效应 + 时间/磁盘线性（每条完整重编码；1080p 中档约 5–8 Mbps，见 `ExportService.swift:93-102`）　〔已修订 2026-10-21：「一次出几条」的上限口径由「最少那一类」改判为「组合总数」（D23），并加软上限（D24）〕 |
| D17 | 是否直出 mp4 | 只到方案。导出仍去「导出」页勾选，不新增导出通道 |
| D18 | 侧栏位置 | 放「工作区」列表**末尾**，快捷键 **⌘8**；既有 ⌘1–⌘7 不动 |
| D19 | `Video.status` 第三态 | 〔已作废，见 R18〕原拍"加 `.wholeClipReady` 枚举"。**现改判为 ④：不加枚举**，C 的载体停在 `.imported`，改为修误读 `.imported` 的消费者。**〔半径再缩 2→1，见 R21〕**：`:838` 那条实测早就带 `video.segments.isEmpty`，只剩 `:639` 首跑清旧段判定一处要改 |
| D20 | 素材来源标签谁给 | **必填入参**：C 的入库入口必须显式收 `source: SegmentSource` 并把 `importOrLinkVideo` 的 `:437` 从"读实例状态 `pendingBatchSource`"改成"读参数"。**属修族**：这条隐式通道对任何第三个调用方都是静默错值源（默认值是 `.curated` 搬运） |
| D21 | A 视图的来源控件 | 页头一行加与 B/C 同款的三段来源 Picker（自拍/搬运/AI生产），**默认不预选**、未选时「生成方案」禁用。理由：D20 要求 source 必填，界面就必须有它的入口 |
| D22 | 翻页态下的单类换一换 | `used` 按条分账（per-draw 快照），改第 k 条只回收第 k 条的那一次消耗，不污染其他条的不回放语义　〔已修订 2026-10-21：「换一换」仍在，但作用域从「重掷素材」改成「重掷组合序号」〕 |
| D23 | 不重复口径（第二轮改判） | **组合级不重复**：同一素材允许在不同条里复现，但整行「类别→素材」搭配必须互不相同。唯一记录是会话签名集 `FolderMixComboLedger.issuedSignatures`（Core 值类型），预览/失败/停止都不写它　〔落点：笔 2/5、FMX-06/07/08、T-18 措辞改口〕 |
| D24 | 条数上限（第二轮改判） | **软上限 50 + 超量确认**：默认 50，越线时页脚出 danger 预估、必须勾「我已确认」才放行；上限值本身可在页面改并被记住；理论天花板 = 组合总数（不是「最少那一类」）　〔落点：页脚 + `FolderMixLimits.defaultSoftLimit`、档 F〕 |
| D25 | 入库时机 | **懒入库**：扫描只读盘（不拷盘、不建库、不跑缩略图），点生成时才把**抽中的**素材入库。硬约束：方案必须指向库里的 Segment，所以「完全不入库」这一档不可选，只能推迟　〔落点：笔 4/5、`beginScan` 不再要求先入库〕 |
| D26 | 建库时机 | 类别项目与产品**只在生成时**为「真被抽中了素材的类别」创建；扫描期零建库 ⇒ 不再留下 0 视频的空壳项目与侧栏假入口　〔落点：FMX-18、`FolderMixIngestTask.categoriesNotBuilt`〕 |
| D27 | 一键式 | 一颗主按钮跑完「抽 → 入库 → 解析 → 替补 → 建 N 个方案」；保留「生成前先预览」开关（默认开），开着时第一次点只出预览不碰盘　〔落点：`generate()`、`previewFirst`〕 |
| D28 | 会话状态归属 | 页面状态**不留在页面 `@State`**：`FolderMixViewModel` 由 `ContentView` 持有，并把 `FolderMixSessionState`（Core `Codable`）的 JSON 塞进 `UserDefaults`；预览行只持久化**组合序号**，且仅当 `spaceRevision` 相符才复用　〔落点：笔 7、FMX-12a-e/13〕 |
| D29 | 左栏可勾选 | 左栏每行一颗勾选（未勾显示「不参与」）+「全选/全不选」；排列与勾选两轴独立，两者都改变组合空间　〔落点：`setEnabled`/`setAllEnabled`〕 |
| D30 | 择片机理换代 | **Floyd 无放回抽样 + 混合基数解码 + 签名账本**；放弃上一版的 Feistel 双射 + cycle-walking + 游标 + 跳过规则 + 两级账本。理由三条（游标+跳过本身有反例、两级账本只为游标而长、cycle-walking 撞的是序号空间省不掉签名层过滤），写在代码注释里防后人「简化」回去　〔落点：`FolderMixPicker` 文件头〕 |
| D31 | 素材身份轴 | 候选带 `identityKey`：默认档 = 路径（零等待，代价是跨目录同内容算两条），「精确识别（慢）」开关打开 = 内容校验和（库里那份优先，未入库才现算）。radix/签名/指纹全部只认这一颗键 ⇒ 去重不需要第二套逻辑　〔落点：`FolderMixLibrary.identityKey`、FMX-14b〕 |
| D32 | 入库能力归属 | 「入库一批素材」下沉成**无 UI 状态**的 `ClipIngestService`（不持有也不写 `phase/progress/progressDescription/errorMessage`、不调 `ToastCenter`、零 `context.delete(`）；`ImportViewModel.importClipsWithoutAnalysis` 降为薄适配层。混剪链不再持有 `importVM`　〔落点：T-24/T-26/CR-1..5、G23b 未被带走〕 |
| D33 | 已算好的存量 | **时长与素材身份都两层解析**：先问库里那份（`Video.duration` 全仓唯一写点、`Video.contentHash` 已用于全局去重），问不到才读盘。`duration > 0` 才算命中——非可选 Double 永远给不出 nil，0 必须折成 nil　〔落点：`FolderMixResolve.swift`、FMX-14/15、B6〕 |
| D34 | 哈希原语归层 | `computeFileHash` 从 ViewModel 移进入库 service 并成为全仓唯一定义（`nonisolated`：否则上千次 8 MB 读盘排在主线程）；Service 层不许反向依赖 ViewModel　〔落点：T-27、正/负对照〕 |
| D35 | 产出顺序 | Floyd 产出的序号是**升序**的（外部经验），而截断发生在补抽那一步 ⇒ 必须先按注入种子做 Fisher-Yates 打散再过滤取满，否则系统性偏向每个文件夹开头的素材　〔落点：`sampleDistinctOrdinals`、FMX-03/04〕 |
| D36 | 终止性判据形态 | 用「随机数消耗**恰为 m 次**」这种可机检的构造性保证（珠玑 12.9），不用墙上时钟；`.timeLimit` 在仓内 0 处使用 ⇒ 不写进台账当指令　〔落点：FMX-02/02b〕 |
| D37 | 不引 property-based 依赖 | 小空间**穷举** + **桶覆盖** + 同 seed 复现三件已达同效；引第三方测试依赖要过引入前审查且改 `swift test` 链，收益不抵成本 —— 这是**结案件**，不是待评估　〔落点：见第十一节〕 |
| D38 | 变异刀的住所 | `.scratch/` 的 Core 刀**不迁进 `scripts/`**（一迁就把每次跑门的成本抬到「全量 swift test × 刀数」）。代价如实登记：`.gitignore` 排除 `.scratch` ⇒ 换机即丢，读数只能靠本台账逐轮回填　〔落点：八、执行进展各轮读数〕 |

## 三、Step 0 · 预览先行（已交付，四腿取证）

预览件：`.scratch/previews/folder-mix-mount-options.html`（三态可切换单文件，`.gitignore:45` 已忽略，`git check-ignore` 实测通过）。A 视图按 D14/D15/D16 重排为：页头一行 → 左栏类别顺序(232pt) + 右栏抽片卡片流（栏头放 `条数 − N ＋` 与 `第 k / N 条` 翻页）→ 底部常驻两行。改动区 11 个（A1–A11）。

| 腿 | 脚本 | 证明什么 | 本轮读数 |
|---|---|---|---|
| 静态 | `audit_preview.js` | 图例↔徽标↔高亮框三者 1:1、`[hidden]` 覆盖生效、标注 `outline-offset:0` 无绝对定位、真实文案只认**界面节点**、9:16 铁律、侧栏逐项点名 | 29 项 PASS |
| 几何 | `measure_preview.py` | 1440×950 真渲染：图例与改动区矩形零相交、A 页钉死 900×600 且 `vOver/hOver == 0`、逐元素扫"非滚动容器里有被裁内容"、按钮相对基准不挤压 | `GEOMETRY CLEAN` |
| 遮挡对齐 | `probe_overlap.py` | 卡片盒两两不相交、说明文字不越盒、四卡等高且按钮 y 对齐 | `OVERLAP CLEAN`（4×297.5px，btnY 全 557） |
| 变异 | `mutate_audit.js` | 8 把刀 + 双基线前置 + 还原 md5 自证 | `8 把刀全部被咬住`，md5 `72ad0807…` |

### 台架自己栽过的四次（写下来，Step 1–6 别重犯）

1. 忠实性判据原本只查"字符串在文件里出现过"，M4 变异证明它会因**说明句里引用原文**而假绿 ⇒ 改成剥掉 `<script>` 与 `<p class="ss">` 后只认界面节点。
2. 几何判据最初拿 30px 硬阈值判"换行"，而单行按钮实测就是 31px ⇒ 整页误判。改成**同类元素相对基准**（与同面板最矮者比 1.6×）并打印读数。
3. 把 17px 的纯文字 `.lbl` 混进按钮基准里，31px 按钮全体假红 ⇒ 基准按类分算。
4. **只测容器 scrollHeight 会被 `overflow:hidden` 骗过**：M8 灌高后主区读数仍是 600，内容其实是被裁掉——比滚动更糟 ⇒ 加逐元素裁切扫描。它当场又抓出一个真缺陷：拖拽区 42px 箭头字形被自己 `line-height:1` 裁掉 8px。

### 渲染才暴露的两条结论

1. **B 方案的按钮放不进顶栏**：混剪方案页左栏只有 320pt，顶栏已有「混剪方案 + 胶囊 + 生成」，第三颗会把「生成」压成竖排 ⇒ 只能独占一行。（B 未被选中，但这条对 A 也适用：右栏实测仅约 376pt 宽，塞「条数+上限说明+翻页」三件套会挤爆标签，已把说明下移到栏注。）
2. **徽标本身会占一个行盒**：四张卡底边差 18.8px 的真因不是文字遮挡，是标注 `<span>` 落在块级首子节点位置。挪进卡名那一行即齐。

## 四、实现计划（拆笔单位是机理，每笔单独验成立，判据与改动同笔）

### Step 1 — Core 纯逻辑（与 UI 无关，先落）

新增，需 `scripts/register_pbx_file.py` 登记；`scripts/check_pbx_registration.py:13,19,62-66` 判据要求**新增 Core 文件四段登记齐全且 path 正确**：

- `Sources/MixCutCore/FolderMixScanner.swift`：输入「一级子目录名 → 该目录文件名数组」，输出类别→候选。**收编现在口径不一致的扩展名判据**（〔勘误 R20〕初稿记的 `ImportView.swift:264-267` 与 `ImportViewModel.swift:998` 两处行号已腐烂，落码前 grep 重取，实为**三处**〔旧读数：`ImportView.swift:474-477` 的 `["mp4","mov","avi","m4v","mkv"]`、`MixCutApp.swift:1141-1144` 同集合的另一种顺序、`ImportViewModel.swift:1294-1296` 的 UTType 表 `[.movie,.mpeg4Movie,.quickTimeMovie,.avi]` —— 前两颗恰好等价、第三颗真的少收了 m4v/mkv；2026-10-21 现状：三处已收成调用 `VideoFileFormat`，字面量只剩 Core 那一份，见守卫 G-i〕：Core 成为唯一真源后，三处**同笔改为调用它**，不留"三处旧判据 + 一处新源"的过渡态（半迁移 = 0），并配守卫扫"扩展名字面量只许出现在 Core 一处"（新守卫 **G-i**）。
- `Sources/MixCutCore/FolderMixPicker.swift`：
  ```
  struct FolderMixCandidate { id, category, name, duration }
  draw(candidatesByCategory:, orderedCategories:, used:, seed:)
      -> (picked, usedAfter, emptyCategories, resetCategories)
  drawMany(candidatesByCategory:, orderedCategories:, count:, seed:)
      -> (rows: [[picked]], usedPerDraw: [UsedSet], emptyCategories, resetCategories)
      // D22：逐条留 used 快照，第 k 条局部重掷只回滚第 k 条那一次消耗
  maxWithoutRepeat(candidatesByCategory:, orderedCategories:, used:) -> Int
      // 非空类「可用数 − 已用数」的最小值；随 used 实时下降，不是扫描时快照
  reroll(current:, atRow k:, candidatesByCategory:, used: usedPerDraw[k-1], seed:) -> 同上单元
  ```
  随机源用自写 SplitMix64 值类型，**禁用 `SystemRandomNumberGenerator`**。规则 R1 同 seed 幂等 / R2 排除 used / R3 用尽即重置并回报 / R4 空类别不崩不猜 / R5 输出顺序恒等于 `orderedCategories` / R6 同一条方案内不出现同一分镜 / **R7 `drawMany` 第 k 条必须逐次等于 `draw` 第 k 条**（两条路径不同解 ⇒ 钳制数与实际产出打架）/ **R8 `count > maxWithoutRepeat` 返回硬错误而非静默截断**（钳制在 UI 层拦，纯函数层不许悄悄少给）/ **R9 第 k 条 reroll 后，第 1…k−1 与 k+1…N 条的选中集必须逐字不变**（D22 的判据形态，防"改一条动了全局"）。
- **上限读数口径（P1-4 定档）**：界面「上限 N」取**实时** `maxWithoutRepeat(..., used:)`——用户每点一次换一换 N 就会掉；扫描完成时的值只是首次渲染，不做快照锁死。理由：快照态会与「生成 N 个方案」按钮的可用态互相打架。
- 文件头照 `Sources/MixCutCore/SegmentPickerCatalog.swift:1-47` 的既有范式写「接口锁定 + R1..Rn + 非空洞性论证」。

**〔Step 1 已落地 2026-10-20，取证见「〇」与「八」〕** 三颗文件：`Sources/MixCutCore/FolderMixScanner.swift`（`VideoFileFormat` 扩展名真源 + 一级目录归一投影，规则 S1–S6）、`FolderMixPicker.swift`（`SplitMix64` + `draw/drawMany/maxWithoutRepeat/reroll`，规则 R1–R9）、`DiskSpaceBudget.swift`（素材×2 ＋ 逐条成片项，规则 B1–B5）。判据 53 条：`FolderMixScannerTests`(14) / `FolderMixPickerTests`(24) / `DiskSpaceBudgetTests`(9) + `FolderMixScannerTests` 里两条 UTType 口径对账腿。pbxproj 四段登记已进 `check_pbx_registration.py` 名册，并新增**全量扫描面**判据⑤。

落地时对锁定的接口做了四处改形（见 R22），都是"实现必须能表达判据"逼出来的，不是风格偏好：
1. `seed:` → `rng: inout SplitMix64`：R7 要求"drawMany 第 k 行 = 逐次 draw 第 k 行"，一次性 seed 值表达不了"随调用推进的状态"。
2. `draw` 多一个必填 `banned:`：换一换必须硬排除当前这条，而 R3 的"用尽即重置"会回收 used —— 让 banned 走 used 的话，重置会把刚排除的那条放回来，等于没换（刀 K12 验的就是这条）。
3. 不保留 `reroll(current:atRow k:...)` 的 `k`：函数体用不到它（banned 由 `current` 给出、used 由调用方传），而"第几条"这个承重信息在调用方已经有一份 —— 两处各写一遍才有静默改错行的风险。行号由 VM 的 splice 目标唯一决定。
4. `FolderMixRow` 多两个回报清单：`duplicateBlockedCategories`（R6 行内去重挡掉，成片会少一段 ⇒ 必须出声）与 `unchangedCategories`（该类只有 1 条素材，换一换打不动 ⇒ 不许假装成功）。

### Step 2 — C 走「母体通路的阶段 1」，不碰自建分镜用例（推翻前两版方案）

**〔已证伪的两条前提〕** 初稿（三开关）与上一轮架构审查的推荐（抽 `WholeClipIngest` 内核）**共享同一个错前提：以为 C 必须落在 `importSelfSegments` 这条路上**。一旦回到数据与契约层查，这个前提不成立——`importSelfSegments` 的名字承诺的是"用户上传的自建分镜"（`ImportViewModel.swift:489-491`），而 C 的素材是**整片母体**。在它下面做任何变体（加开关 / 抽公共内核）都是在给一个说谎的名字找补丁。

**本轮实测到的既有事实（四条，全部实读）**

1. `importVideos` 本身就是**两段式**：阶段 1 逐文件 `importOrLinkVideo`（`:157-185`），阶段 2 才并发跑切分+ASR+AI（`:187-242`，由 `videosToAnalyze` 集合门控）。⇒ "只入库不分析"在结构上是**已存在的切面**，不需要新造。
2. `importOrLinkVideo`（`:401-460`）已包含 C 需要的全部六件事：算 hash（`:409`）→ 全局 hash 去重（`:412`）→ **命中即幂等挂到本项目**（`:413-414`，注释原文「已有此视频：幂等挂到本项目（同一素材第二次进来不产生第二行关联）」）→ 落盘 `copyVideoToGlobal`（`:425`）→ 建 `Video` + `contentHash` + `ownerProject` + `defaultSourceRaw` + `associate`（`:431-441`）→ 元数据与缩略图（`:444-458`）。
3. `SegmentCommitter.commitWholeVideo` 的注释**已经为这种用法预留**（`Services/Import/SegmentCommitter.swift:161-166`）：「覆盖整片的单段（自建分镜上传路径；**后续「整片保留」规则也接这里**）」。
4. 阶段 1 的循环里**本来就有取消检查点**（`:161`）与 `finishAsCancelled` 收尾（`:244`）⇒ C 的中断语义是复用得来的，不是新写的。

**采纳方案（丁）**：在 `ImportViewModel` 内新增一个与 `importSelfSegments` **平级**的入口 `importClipsWithoutAnalysis(urls:to:source:)`，内部只做两件事——调既有的 `importOrLinkVideo`（需从 `private` 提为 `internal`，同文件内改动）+ 对返回的 Video 调 `SegmentCommitter.commitWholeVideo`。**不打 `isUserUploaded`、不写自建注册表、不进阶段 2、不受 30 秒闸管辖**（那是 B 的规则，C 根本不经过它）。

| 候选 | 内容 | 判定 |
|---|---|---|
| 甲 | 给 `importSelfSegments` 加 `durationCap`/`runTranscription`/`runTagging` 三开关 | 反选：三个开关之后它已不是它，且 `isUserUploaded` 这个名字会对一整类新数据说谎 |
| 乙 | 抽 `WholeClipIngest` 公共内核，B/C 都为调用方（上一轮审查的推荐） | **〔已作废〕** 比甲好但仍接受"C 属于自建分镜家族"这个错前提；抽出来的内核要同时服务两种语义，等于把错位固化成一层抽象 |
| 丙 | C 走完整 `importVideos` | 反选：必跑镜头检测+ASR+AI 且会切分，与 D2/D8 正面冲突 |
| **丁** | 复用阶段 1 + `commitWholeVideo`，不碰 B | **采纳**。零新抽象、零新语义标记、B 的行为逐字不变 |

**丁必须同时做的两件事（否则界面与数据都会说谎）**

1. **状态（改判为 ④，见 R18）**：C 的载体**保持 `.imported` 不动**，不引入新枚举。要修的是两处**误读 `.imported` 的消费者**：
   - `:639` 首跑的 `clearsExistingSegments` 由常量改成"是否已存在覆盖整片的单段"——判据形态直接复用仓内既有先例 `MixCutApp.swift:295-304` 的 `byShape`（`segments.count == 1 && startTime < 0.01 && abs(endTime - duration) < 0.2`），并把这条前置写进注释。
   - ~~`:838` 的 `canShowRetry = (status == .imported || status == .failed)` 加一个条件：**已有 Segment 就不显示重试**，否则 C 的素材会在导入页挂出假的「重试 / AI 分析」入口~~ **〔已消解 2026-10-20，见 R21〕** 落码前实读 `MixCut/Views/Import/ImportView.swift:838-841`，那里**早就**有 `&& video.segments.isEmpty` 这一项（原文注释：「白名单：只在『孤立 imported（未排队也未在跑）』或『明确 failed』时显示重试按钮」）。C 的载体必然带一条整片段 ⇒ 假重试按钮这条路今天就已经堵着，**不需要改**。④ 的半径从 2 处缩到 **1 处**（只剩 `:639`），代价表里第③格（"界面少一格整片就绪信息"）仍然成立。
   **为什么 ④ 能区分 C 与母体链（本轮实测）**：`Video.asrSentences` 的 setter 是 `asrSentencesData = try? JSONCoding.encoder.encode(newValue)`（`Models/Video.swift:220`）——**空数组编码出的是非 nil 的 Data**，而 `clearASRRun()` 只清 `asrEngineRaw/asrModelTier/asrRunAt` 三样、**不清 `asrSentencesData`**（`:67-71`）。⇒ 母体链无论 ASR 成功还是失败都会写 `asrSentencesData` ⇒ 永远非 nil ⇒ `byShape` 的 `asrSentencesData == nil` 这一项足以把 C 与母体链分开。
   **④ 的代价（必须摊开，不是免费的）**：① 它把一条**形状启发式从兜底升级成承重判据**；② 它**分不开 C 与 B**（自建分镜也不写 `asrSentences`，`importSelfSegments` 只调 `seg.setText`）——但两者在该判据下同侧时的行为是"清掉旧整片段、按母体链重切"，对 B 卡死在 `.analyzing` 这种残留态来说**是正确行为**，不是误判；③ C 素材在界面上显示"已导入"而不是"整片就绪"——不算谎报（它确实只是导入了），但少了一格信息。
   **已排除的反面做法**：把 status 收成 `.completed` 会让同一文件日后走母体导入时被 `:418` 静默判为"已分析"（第十节二阶效应 1）——D19 最初就是为了修这个副作用而生的，④ 从源头绕开了它。
2. **来源标签**：`:437` 写的是 `video.defaultSourceRaw = pendingBatchSource.rawValue`，而 `pendingBatchSource` 是 **`private var`、默认 `.curated`（搬运）**、只在 `importVideos` 里赋一次值（`:51`、`:103`）。C 若直接调 `importOrLinkVideo` 而不设它 ⇒ **每条素材被静默标成"搬运（他人视频）"**，编译器不提醒、测试不覆盖就无声通过。按 **D20** 落：`source` 改成 `importOrLinkVideo` 的**必填入参**、`:437` 改读参数，B 侧由 `importVideos` 传下去——这是**修族**，那条隐式通道对任何将来的第三个调用方都是静默错值源。界面上按 **D21** 给 A 视图补来源 Picker（未选则「生成方案」禁用）。

**〔P0-1 已闭合 2026-10-20，只读实做〕** 上面撤销条件指向的那个未知（"已有整片 Segment 的视频再走母体导入会不会混存"）**已用实读判定：会混存**。链路：`analyzeVideo` 首跑在 `:634-639` 调 `rebuildSegments(clearsExistingSegments: false)`，而 `:697/:734` 两处都靠这个开关决定是否删旧段——传 `false` 时**旧整片段不删、新切分段追加** ⇒ 一条素材同时挂着"1 个覆盖整片的段 + N 个切分段"。
根因不是漏了个 if，而是**这个布尔入参背后有一条未声明的前置条件**：`false` 之所以安全，前提是"首跑此刻没有旧分镜可退"（该注释自己也这么写）。D19 的 `wholeClipReady` 是历史上第一次让首跑路径遇到"已有旧分镜"的视频 ⇒ 前置失效。
**修法（最小且与既有契约同形）**：`:639` 由常量改为 `clearsExistingSegments: video.status == .wholeClipReady`，并把上面那条前置**写进注释**（否则同一个坑会留给下一个新状态）。反选记录：把 `:418` 判成"wholeClipReady 已处理"= 退回污染；弹二次确认框 = 多一条用户可见规则且没修根因。
**验收**：造一条 `status = .wholeClipReady` + 1 条整片 Segment 的夹具，跑 `analyzeVideo`，断言 Segment 总数 == 切分段数且**不含**那条整片段；并配反向对照（`status = .imported` 时旧段不该被删）。

**撤销条件（保留）**：若实做发现 `commitWholeVideo` 对"无台词 + >30s + 非自建"三者并存有隐含假设，丁退回乙——但退回时**必须同时改掉 `isUserUploaded` 的语义归属**，不接受"先复用标记、以后再分"的过渡态（半迁移 = 0）。

### Step 3 — C 通路的入库序列与失败处理

序列：`DiskSpaceBudget` 预检（N 类 × 整片 ×2）→ 逐文件 `importOrLinkVideo(url, project, source)`（**source 显式传入**，D20）→ 每个成功入库的 Video 调 `commitWholeVideo` 建覆盖整片的一段 → `status = .wholeClipReady`（D19）→ 每 5 个文件回写一次进度。

- 不变式：Segment 只许 `SegmentCommitter` 构造，守卫在 `scripts/check_ai_completeness_guards.sh:137-144`（〔勘误 R2〕初稿写 114-122，那里是 `SegmentationCompleteness.audit` 与 18 秒规则）。
- `commitWholeVideo` 不设 `textSource`（用 `Segment.init` 的 `.unknownLegacy`，`SegmentCommitter.swift:163-166`）⇒ C 的分镜**天然无台词**，与 D8 一致；**不得**沿用 B 的 else 分支写默认「过渡」标签，那是给数据贴假标签。
- 失败分档、报告通道与验收要求见**第九节**（逐条已定档，无"静默 continue"）。
- 取消：复用阶段 1 的 `Task.isCancelled`（`:161`）与 `finishAsCancelled`（`:82-92`）语义——**停止 ≠ 删除**，已入库素材与已建项目保留。

### Step 4 — 扫描与建库（D1/D2/D12/D13）

- `MixCut/Services/Import/MaterialFolderScanner.swift`：唯一 IO 面，`contentsOfDirectory(...options: .skipsHiddenFiles)` 只取一层；`startAccessingSecurityScopedResource()` 包裹（先例 `ImportView.swift:128/238`）。
- 建库收口：`ProjectViewModel.createProject()` `:214-259` 现在读 UI state，抽出程序化入口，与 `Services/MCP/MCPToolHandlers.swift` 的建项路径、`MixCutApp.swift:847` 的「Project + 自定义组合容器」拷贝**收成一族**（修族不修点）。
- **D12「同名合并」没有可复用的实现，是本期要新写的逻辑**（本轮实测）：`createProduct` 那条链有 `product(named:)` 可查（`ProjectViewModel.swift:222` 在用；2026-11-03 概览投影值型化把它往后顶了 3 行），**Project 侧没有任何按名查项目的入口**（`grep "func project(named" / "name == "` 在 `ProjectViewModel.swift` 零命中）。⇒ Step 4 必须自带一个 `ensureProject(named:in:)`，并明确它的匹配口径：
  - `createProject()` 在 `:216` 对名字做了 `trimmingCharacters(in: .whitespacesAndNewlines)` ⇒ 文件夹 `A` 与 `A␣`（尾随空格，Finder 里看不见）会归一到同一个项目名 ⇒ **两个不同文件夹静默合成一个类别**，这是 trim 的既有行为，本期沿用但要在扫描结果里出声（"两个文件夹归为同一类别"）。
  - 本卷实测**大小写不敏感**（`.scratch` 下建 `CaseTest` 后 `casetest` 可见）⇒ 同一台机器上不会出现 `Hook`/`hook` 两个文件夹；但素材来自外接盘或解包时可能出现，而 SwiftData 的字符串比较是**大小写敏感**的 ⇒ 会建出两个近名项目。定档：**按 trim 后的精确名匹配**（与 `createProject` 同口径，不引入第三种规范化），近名情况在扫描结果里提示，不自动合并。
- **候选真源 = 文件系统投影**（〔2026-10-21 笔 5 改判：上一版这条写的是「入库后的 Segment」，因为当时要求先点入库；懒入库之后候选直接来自盘上那两层枚举，键 = `identityKey`（本轮改判的「素材身份」轴，决议号待笔 8 登记）：默认档就是那条路径本身，见 `MixCut/ViewModels/FolderMixViewModel.swift:197` 的 `FolderMixLibrary.identityKey(` 与 `rebuildCandidates()`——后者是唯一一处算键的地方〕）。　旧写法留下的那条**理由仍然成立、只是换了处理位置**：按 FS 直取会碰上被哈希去重跳过的文件（`ImportViewModel.swift:477`，`skippedDup` 那颗 continue；〔2026-10-21 行号勘误：笔 1b/笔 5 两次改动把行号顶过 17 行〕），而导出侧对解析不到的槽位是静默丢段 —— `ExportService.swift:165-190` 两处 `continue`：① `schemeSeg.segment`/`segment.video` 为 nil；② `effectivePicture.videoPath` 为空或文件不在盘上。〔已修订 2026-10-22：原文这条描述的机理是**按路径反查**，实跑证明它一行都命中不了（素材目录路径与拷贝落地的库内路径永不相交），详见 `docs/superpowers/plans/2026-10-22-folder-mix-join-key.md` 第二节〕现在这条路这么闭：抽中的路径在入库那一刻由服务**当场交回**「哪个源文件落进哪一行」（`MixCut/Services/Import/ClipIngestService.swift:269` 与 `:278` 两支各记一次），解析步只按这张表取行、再按整片段形状取段（`FolderMixLibraryJoin`）⇒ 不再猜路径；行有而段无 ⇒ 档 B；带失败码 ⇒ 档 A；表里没有 ⇒ 新码 `notIngested`。替不动才摘行。（〔勘误 R3〕初稿记成"`:156` 一处 continue"，实为 `:164-168` 两处、两种成因。）
- 同素材出现在两个文件夹：C 走丁案 ⇒ 第二次命中时 `importOrLinkVideo` **幂等挂到第二个类别项目**（`:413-414`），库里仍只一行 Video、`ownerProject` 保持首次导入项目不覆写（`Models/Video.swift:119-122`），但两个类别项目各可见一次 ⇒ 类别候选不会被吃掉。择片器只需守住**同一条方案内不出现同一分镜**（`SchemeViewModel.swift:686-692` 已在管，〔勘误 R4〕初稿写 678/710）。

### 前置决策 P-1｜"同一素材属于多个类别"怎么落 —— **〔已消解 2026-10-20，无需拍板〕**

**消解依据**：Step 2 改走丁案后，C 复用的是 `importOrLinkVideo`，而它**本来就是"命中即幂等挂到本项目"**（`ClipIngestService.swift:154-155`〔2026-10-21 勘误：笔 1b 把六步真身搬进了服务，注释原文随之内迁〕，注释原文「已有此视频：幂等挂到本项目（同一素材第二次进来不产生第二行关联）」）。也就是说乙案所求的"多归属"在母体通路里**已经是既有行为**，而 B（自建分镜）的"命中即跳过"根本不会被 C 触发 ⇒ 既不需要跨用例契约变更，也不需要你单独点头。下面两案的原文保留，作为"当初为什么会以为要拍"的记录。

**唯一仍然活着的连带项**：`ProjectVideo.associate` 把正常幂等记成 `MixLog.error`（`Models/ProjectVideo.swift:31-39`）。C 的"同素材跨类别"正是这条路径的常规触发场景 ⇒ 落地时同笔降为 info + 配判据（见风险 9）。

本轮实测到一个此前没摊开的事实：**两条既有入库通路对"素材已存在"的处理口径不一致**，而 C 通路会同时踩到两种口径。

| | `importVideos`（母体整片） | `importSelfSegments`（自建分镜） |
|---|---|---|
| 去重函数 | `isDuplicate(url:in: project)` `:1154-1166` | `findExistingVideo(hash:)` `:1143-1151` |
| 作用域 | **项目内**，先按文件名再按 hash | **全库**，只按 hash |
| 命中后行为 | **不跳过，改为关联**（`:175-177` `linkedExistingNames`，日志原文「视频已存在且已分析，直接关联」） | **整条跳过**（`:498` `continue`），不建关联 |

- **甲（计划初稿案）**：C 沿用"命中即跳过"，靠择片器 R6 跨类别去重绕过。代价：这不是"避免重复"而是**类别候选被静默吃掉**——用户看到"信任背书 0 条可用"，而真实原因是该素材已被别的类别项目导入。R6 治不了这个，它治的是"同一条方案内出现两次同一分镜"。
- **乙（推荐）**：C 命中 hash 时不 continue，改为把既有 Video `associate` 到当前类别项目（照 `importVideos` 已有的 `linkedExistingNames` 语义）。`ProjectVideo` 本就是多对多（`Models/ProjectVideo.swift:31-39` 幂等），类别于是成为"关联集合"而非"唯一归属"，多归属天然成立；R6 退回它该有的表述：**同一条方案内不许出现同一分镜**（这本就是 `SchemeViewModel.swift:686-692` 在管的事，〔勘误 R4〕初稿写 678/710）。
- **乙案的代价与前置**：① 会改变 B（自建分镜上传）对用户可见的行为——原来第二个同名素材显示"已存在，已跳过"，改后显示"已关联"，属**跨用例契约变更，须你单独点头**；② 会让 `ProjectVideo.associate` 的幂等分支大量触发，而它把正常路径记成 `MixLog.error`（Step 3 已记），必须同笔降级；③ 需补一条判据：同素材两类别 ⇒ 两个类别项目各可见一次，且择片器不会因此在一轮里给出两条同一分镜。
- **若你反选乙、坚持甲**：则第五节风险 6 必须把"同素材跨类别会静默吃掉一个类别的候选"从技术处理升格为**产品可见限制并写进界面文案**，否则它是被遮盖的症状、不是被接受的边界。
- 磁盘预检公式（**修正：原式系统性低估**）：现状 `requiredSpace = totalFileSize * 2`（`ImportViewModel.swift:183-184`〔2026-10-21 行号勘误：原 :133-137 → :149-156 → 笔 5 的 `FailedItem` 加两颗字段后又顶到 :163-167〕）只算"复制进来 + 留一份余量"，**没算 N 条成片的输出**。改为 `素材总字节 × 2 + 每条成片估重 × N`，每条估重直接复用导出页那套码率文案的数（`ExportService.swift:93-102`：1080p 中档约 5–8 Mbps ⇒ 60 秒约 38–60 MB）。N=8 时漏算约 300–480 MB，正好是"预检通过、导出到第 6 条磁盘满"的那种事故形态。

### Step 5 — 择片编排 + 预览 + 建 N 个方案（D3/D9/D10/D11/D16/D18）

- `MixCut/ViewModels/FolderMixViewModel.swift`：持 seed、used 集（**仅内存，不落 UserDefaults**）、N 与翻页态；编排「扫描→建库→抽片→确认→建方案」。
- 末端接 `createCustomScheme(from:in:)`，并加 `inferMetadata: Bool = true` 开关 —— 现路径在 `SchemeViewModel.swift:1012` 调 `schemeService.inferMetadata(for:)`，定义在 `SchemeGenerationService.swift:493`，是网络调用，D8 要求关掉。顺手补 `estimatedDuration`（现 custom 路径没写）。
- **N 条落成 N 个独立方案，禁止共用 `templateGroupId`**：该字段是"同一原分镜序列展开的多条配音变体"共享组 id（`MixScheme.swift:23-27`），这里 N 条序列各不相同，套上去会让方案页误并成一个模板的变体。编号用 `自定义组合` 分组内 `variationIndex` 递增。
- View 层按 D15 版面：整页 900×600 内不出现纵向滚动，长高即算缺陷；N 条靠翻页而非铺卡片；缩略图高用 `Size.videoHeight(forWidth:)`（9:16 铁律，`Utilities/DesignTokens.swift` 的 `Size` 注释明令不许手写数字）。
- 侧栏新增第 8 项：`App/ContentView.swift:65-87` 枚举 + `MixCutApp.swift:195-220` 菜单命令与 ⌘8。**注意：全仓没有任何脚本数 `NavigationItem` 的条数**（`grep -rn NavigationItem scripts/*.sh` 空 ⇒ 见第五节风险 5），这条改动没有既有守卫兜底。

### Step 6 — 守卫脚本与文档

新增 `scripts/check_folder_mix_guards.sh`（配 `selftest_` 自证腿）。**每条守卫必须写「适用边界 + 豁免边界」二值声明**，否则会把既有正常功能一起挡红：

| 守卫 | 断言 | 适用边界 | 豁免边界 |
|---|---|---|---|
| G-a | 全仓随机源命中数 = 0（SplitMix64 除外） | `Sources/MixCutCore/**` + `MixCut/**` | 无（测试夹具用定值 seed，不算随机源） |
| G-b | 30 秒闸字面量只许 1 处 | `ImportViewModel.selfSegmentMaxDuration` 定义处 | B 通路专用；C 通路不得出现第二份副本（丁案下 C 根本不经过它） |
| G-c | 择片/上限逻辑不得出现在 `MixCut/Views/` | Views 目录 | ViewModel 只做装配与传参，判定全在 Core |
| G-d | 新通路不得调 AI/网络 | `FolderMix*` 与 `importClipsWithoutAnalysis` 调用链 | **B（自建分镜上传）与 `importVideos` 阶段 2 必须允许调 AI/ASR**——既有正常功能，不在本守卫射程 |
| G-e | 侧栏 `NavigationItem` 的 case 数与菜单 ⌘1–⌘8 绑定数必须对齐 | `ContentView.swift:65-87` + `MixCutApp.swift:195-220` | 无（补风险 5 那个缺口） |
| ~~**G-f**~~ | 〔已作废，见 R19〕原要求"对 `VideoStatus` 的 switch 不得带 `default:`" | — | 它只为 D19 的新枚举服务。④ 不加枚举 ⇒ **整块取消**：不必改 4 处 UI 映射、不必加这条守卫。实测留档（6 处 switch 仅 2 处穷尽、4 处带 default：`ImportView.swift:529/:1084/:1381`、`MixCutApp.swift:827`）**仍然有效**——它是"将来真要加状态时"的已知地形，别重测一遍 |
| **G-g** | 计划文档里的 `文件:行号` 引用必须仍落在文件长度内 | `docs/superpowers/plans/*.md` | 直接把本轮 `check_doc.py` 的那条腿搬进仓；本仓**无 remote、钩子是空壳**，没有 CI 会替我们兜行号腐烂 |
| **G-h** | 新通路关键路径必须打 `[FolderMix]` 日志前缀（扫描 / 择片 / 建 N 方案 / 丢段四处） | `FolderMix*`、`importClipsWithoutAnalysis` | 数前缀的写法照既有先例：`check_navigation_readiness_guards.sh` 的 G07 用 `expect_count` 数 `[Readiness]`。不加前缀 ⇒ 桌面端报障只能靠猜 |
| **G-i** | 视频扩展名字面量（`"mp4"`/`"mov"`/`"avi"`/`"m4v"`/`"mkv"` 的数组形态）全仓只许出现在 `Sources/MixCutCore/FolderMixScanner.swift` 一处 | 全部 `MixCut/**` + `Sources/**` | Step 1 已经把三份旧判据收成一处（`ImportView.swift:476` / `MixCutApp.swift:1144` / `ImportViewModel.swift:1431` 现全走 `VideoFileFormat`）。这条守的是"下一个消费者又自己抄一份"—— 半迁移 = 0。**豁免**：文案里以自然语言提到容器格式（如分镜库上传提示 `SegmentLibraryView.swift:511` 那句「mp4/mov」）不算判据副本，它不是白名单而是提示语 |
| **G-j** | `struct SplitMix64` 全仓只许有一份定义 | 全部 `MixCut/**` + `Sources/**` + `Tests/**` | Step 1 把 `ProjectVideoDedupTests` 的 private 副本收编进 Core（`FolderMixPicker.swift`），并把三处引用它的注释同轮改口（`OrphanFileFinderTests.swift:121`、`WhisperModelCatalogTests.swift:38`、`SegmentTranscribeRuleTests.swift:224`）。同算法由 `FolderMixPickerTests.P12` 的四条 golden 读数钉住 ⇒ 迁移零行为变化。这条守的是仓内已两次记过的裁定「复制随机源 = 第二份真源」 |

- `docs/ROADMAP.md:135` 的「批量导入」条目结案 —— 〔已落地 2026-10-20，见第八节 Step 6〕。
  **迁移口径的最终版（随 R18/R19 改判，原文保留在下段作记录）**：本期**既不加新字段也不加枚举 case**
  （④ 方案下 C 的载体停在 `.imported`）⇒ 存量行零迁移、`SchemaVersions`/`SchemaGuard` **无需表态**，
  当初为"加 case"立的那条前置随 D19 一起作废。
  原文：「本期仍**不加新字段**，但 D19 要**加一个枚举 case** ⇒ 存量行零迁移（不动既有 rawValue），
  而它是**行为契约变更**（多一种终态），须按 `SchemaVersions.swift:71-80` 的纪律核一遍并在 `SchemaGuard`
  表态；初稿那句"零新数据字段 ⇒ 无迁移动作"在 D19 之后不再完整成立，已就地更正」——
  这段话在 R18 之后只剩最后一句仍成立：**"零新数据字段"重新完整成立，因为枚举也不加了**。

### Step 7 — 两处静默口收口（架构审查问题 3，独立一笔）

**不新造机制，只让新代码参加既有契约。** 仓库已有一条"方案内分镜被剪除"的通知链，实测在位：

```
GraphChange 广播（唯一发布口，G19 守卫钉住 post 恰好 1 处）
  → App/ContentView.swift:232  schemeVM.notePrunedSegments(goneSegments)
  → ViewModels/SchemeViewModel.swift:34-35  prunedSegmentIDs / notePrunedSegments
  → Views/Schemes/SegmentPickerDrawer.swift:113  目前唯一的消费点
```

机制层的收口状态以 `2026-10-03-tombstone-read-after-real-delete.md` v1.10 为真源（§14.7 广播口收进事务中心、宽限期 6 条删除链接入；**非宽限期 11 行直删仍 ❌**）。据此两条动作：

1. **汇总项目的方案要显式显示"该方案有 N 段素材已不存在"**，消费同一份 `prunedSegmentIDs`，而不是等用户去抽屉里发现卡片少了。落点：方案详情头部（`SchemeDetailView`）加一条计数提示，复用抽屉已有的置灰语义。
2. **导出侧丢段必须出声，但不许改返回类型**：`ExportService.swift:163-174` 现在两处 `continue`（① `schemeSeg.segment`/`segment.video` 为 nil；② `effectivePicture.videoPath` 空或文件不在盘上），只有全空才 `return nil` ⇒ 后果是**产出一部短了一截、没有任何地方说少了几段的 mp4**。
   **实测到的对外契约面**：`ExportInput.from(scheme:)` 有 **2 个生产调用方**——`Views/Export/ExportView.swift:792` 与 **`Services/MCP/MCPToolHandlers.swift:562`**。后者是 Agent 可见的 MCP 工具契约，改返回结构 = 破坏对外接口。
   **采纳形态**：保持 `-> ExportInput?` 不变，在 `ExportInput` 内加**可选**字段（`plannedSegmentCount: Int?` / `droppedDescriptions: [String]?`），两个调用方按需消费：导出页显示"计划 N 段 / 实得 M 段"，MCP 侧只多两个可选返回字段、不改既有字段语义。档位按第九节：**部分丢 = 放行 + 标记，全丢 = 拒绝**。
   ⚠ 守本仓既有教训：**给已落盘的 Codable 结构加字段必须用 Optional**（非 Optional 即使带默认值也会 keyNotFound）。

⚠ 本步不改 `FFmpegRunner`；会改 `ExportService.swift`——该文件用户已提交（HEAD `4ac5704`），当前无在途冲突，但它是导出链热区，**动前重跑一次 `git status` 复核**（风险 7 的纪律）。

## 五、已知边界与风险

1. ~~模块 Project 在概览里显示 0 视频~~ **〔已消解〕** 该后果只在 C 打 `isUserUploaded` 时成立（`ProjectViewModel.swift:137` 的 filter；2026-11-03 概览投影值型化后行号）。丁案不打该标记 ⇒ 模块项目正常计数。原文保留：「整片走自建通路后不计入"视频"，类别追溯靠 Project 名」。
2. ~~分镜库里类别语义会糊~~ **〔已消解〕** 同理，`SegmentLibraryViewModel.swift:185/194` 只把 `isUserUploaded` 的载体归进合成分组 `VideoSegmentGroup.selfBuiltID`；丁案的素材按普通 Video 分组 ⇒ 类别在分镜库里天然可见。
3. **汇总项目的单项目假设**：`SchemeViewModel.swift:322/793` 一类"按本项目分镜"的辅助视图对汇总项目恒空；建方案本身已核实可跨项目。生成后须切 `selectedProject`（`:989`）。
4. **删模块 Project 会级联删 Segment** → 汇总方案静默掉槽：`Utilities/ModelContextExtension.swift:189-198`（`video.projectVideos.isEmpty` 时连带 `delete(segments)`）。〔已修订 2026-10-20 架构审查〕初稿把它列为"本期只如实记录"的既有边界——**这是接受症状**：仓里已有 `notePrunedSegments`/`prunedSegmentIDs` 契约可暴露它（Step 7），所以本期改为**必须接**，不再记为边界。
5. **侧栏新增项没有既有守卫**（本轮新发现）：`scripts/` 下无任何脚本按条数校验 `NavigationItem`，所以 Step 5 那处改错（比如枚举加了、菜单没加）不会当场红。Step 6 的 G-e 就是来补这个口子的。
6. 空类别按 D13 不阻断 ⇒ 成片可能少一段，界面必须把原因写在该卡上而不是一句「已跳过」。
7. **协作栅栏**：〔已结案 2026-10-20〕本轮期间工作树曾有用户在途改动（`FFmpegRunner.swift`+63、`DubSegmentGraph.swift`+38、`ExportDurationGateTests.swift`+151、未跟踪 `LoudnessChainPolicyTests.swift`），**用户已于本轮期间自行提交**（HEAD `4ac5704`），现 `git status` 只剩本文件一个未跟踪项。**保留的纪律**：开工前重跑 `git status` 复核；`git add` 只按文件名点，禁目录形式；Step 7 要动的 `ExportService.swift` 当前无冲突，但它是热区文件，改前须再核一次。
8. ~~C 通路没有可复用的中断语义~~ **〔已消解〕** 该结论来自"走 `importSelfSegments`"这个错前提（那条路确实零取消点）。丁案复用阶段 1，其循环自带 `Task.isCancelled`（`:161`）与 `finishAsCancelled`（`:82-92`、`:244`）⇒ 中断语义是**既有**的。残留：阶段 1 的取消粒度是"每个文件之间"，单个大文件的 `copyItem` 不可中断——可接受，不另立动作。
9. **`ProjectVideo.associate` 把正常幂等记成 `MixLog.error`**（`Models/ProjectVideo.swift:31-39`）：P-1 乙案会让它大量触发，日志会刷一片红并误导后续取证（`2026-10-03-tombstone…md:48` 已被它误导过一次）。同笔降级 + 配判据。

## 六、验证（**已跑腿**与**待跑腿**分列，别把跑不了的当成已验证）

Step 1–7 落地后的收口状态。左列是第 1–11 条编号；"机器取证"指本次真跑过并有读数的腿，
"待真机"指必须在用户本机、用真实素材目录才能验的腿 —— 它们**没有**被验证过，只是有明确的验收形状。

| 条目 | 状态 | 取证 / 缺什么 |
|---|---|---|
| 1 纯逻辑腿（第二轮收口后的族数：Picker 27 / Scanner 21 / Budget 12 / WholeClipShape 8 / IngestGuard 19 / SessionState 10 / Resolve 7 / Orchestration 14 / CR 特征化 5 = **123 条混剪族判据**） | ✅ 机器取证 | `swift test` → **1306 通过 / 0 真失败 / 4 known issues**；每条新判据都配变异刀，红点逐把对到「只红自己那条」（`.scratch/fm_mutate_1a.py` 3 把、`step1` 17 把、`step2` 10 把、`step4` 11 把、`step5` 10 把） |
| 2 App 层腿（`swift test` 不编 App） | ✅ 编译四腿齐 | `MODE=typecheck` / `MODE=silgen` / `xcodebuild build` / `build-for-testing` 四项 PASS（270 编译单元，每轮改过 Swift 都重建 `.scratch/dd`）。silgen 腿本轮再次抓到 typecheck 漏掉的 `missing return` ⇒ 这条腿不是冗余。**执行腿 `xcodebuild test` 仍交给你跑**（会拉起宿主实例并占 8787 端口） |
| 3 守卫 | ✅ 机器取证 | `check_folder_mix_guards.sh` G-a1…G-l1 共 **17 道** PASS（**无 G-f**：那四处目标值随 R18/R19 取消）；`selftest_folder_mix_guards.py` 17 把刀逐把咬住自己那道门、互不串味、还原回基线；LANE 由 3 颗扩到 6 颗 App 文件（含两颗探针 reader 与下沉后的 service），并各配一颗「塞一条 `URLSession` 必须红」的生效正对照 |
| 端到端手工（第一轮 1–11 条 + 第二轮 1–13 条） | ❌ 待真机 | 两条必须在用户本机、用真实素材目录跑：「选完目录不点任何按钮就看到类别」与「切到素材导入页看它的进度条是不是干净的」是第二轮改判的现场证明，机器测不到。第一轮那份清单原文保留在下面，但第 3/4/5 条的口径已被第二轮改判（见 R 行），以第二轮的 13 步为准 |

### 第二轮改判后的真机验收清单（13 步，**未跑**；跑完把读数回填第八节）

1. 备根目录：4 个一级子文件夹（候选数 20/20/10/5）、一个空文件夹、一个非视频文件、一个**跨文件夹内容重复**的文件、一个 >30s 的整片。
2. 选目录 → **不点任何按钮**，左栏立刻列出 4 个类别 + 空类标灰；卡片时长在 1–2 秒内渐进补齐（**留一次实测读数**，回填「探针 ≈? ms/条」这条估算）。
3. 取消勾选一个类别 → 组合总数读数从 20000 掉到对应值；勾回来恢复。
4. 条数输 60 → 红字预估出现、「生成」禁用；勾「我已确认」后可点。软上限本身可改并被记住。
5. 点主按钮 → 侧栏冒出**被抽中类别**的项目（未抽中的一颗不建）、汇总项目「文件夹混剪」里有 60 个方案；`SchemeSegment.position` 顺序 == 排的类别顺序；`templateGroupId` 各不相同。**同时切到「素材导入」页看它的进度条：必须是干净的、不显示混剪的活**（第 5 条根因的现场证明）。
6. 逐条比对 60 个方案的「类别→素材」搭配，**无两条完全相同**（允许同一素材出现在多条里）。
7. 「精确识别（慢）」关闭时跨目录那份重复可在同一行同时入选（连着两段同样画面）；打开后类别行出现「发现 1 组跨文件夹同内容」、**组合总数不变**（radix 是类内去重，见 R33），且那一行改走替补/摘行。
8. 断网跑全流程：零 ASR / 零 AI / 零网络请求；当日日志里 whisper/API 的命中数不新增。
9. 中途点「停止」：已入库素材与已建项目**保留**（停止 ≠ 删除），未建的方案不出现；再跑一次导入页的正常导入，四条读数正常。
10. 把某个抽中文件在生成前从磁盘移走 → 该类替补一条进来；该类已被用尽 → 该条不出并报「计划 60 / 实得 59（第 k 条：…）」。
11. 切到「素材导入」页再切回、以及退出 App 重开 → 类别列表、勾选、排列、条数、两颗开关都在；预览行只在目录内容未变时保留（指纹一变就明说作废）。
12. 同目录重扫 → 不新建副本产品/项目、候选数不膨胀；「精确识别（慢）」的代价读数应变成「库里已有 N 条（零成本）｜需新算 0 条」，且已在库素材的时长不再触发读盘（对应机检腿 FMX-14/15）。
13. 版面 900×600 无纵向滚动 —— **SwiftUI 侧目前不可机器取证**（Mac2 黑盒 UI 环两条 P0 未修），只能人工目测；HTML 预览的断言不担保 SwiftUI 等价。

下面 1–11 条原文保留（第一轮，其中 3/4/5 条口径已被上面那 13 步取代），是**待执行**的验收形状：

- 纯逻辑腿：`swift test` 新增 `FolderMixPickerTests`（P1–P10：幂等/不回放/用尽重置/空类别/乱序输入/跨类不重复/单候选/换一换不复用/**drawMany 与逐次 draw 同解**/**超上限硬错`）、`FolderMixScannerTests`（S1–S6）、`MaxWithoutRepeatTests`。风格照 `Tests/MixCutCoreTests/SegmentPickerCatalogTests.swift` 定宽夹具。每条 R 规则配变异，验"只红自己那条"。
- App 层腿：`swift test` 只编 Core，App 层必须走 xcodebuild 这条腿。本期已跑两条编译腿（都 SUCCEEDED）：
  ```
  xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug -derivedDataPath .scratch/dd build
  xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug -derivedDataPath .scratch/dd build-for-testing
  ```
  **待用户跑的是执行腿**（它会拉起 2~4 个宿主 App 实例、App 启动要占 MCP 端口 8787，可能撞用户正在跑的实例，
  所以我没有替你跑）：
  ```
  xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug -derivedDataPath .scratch/dd test -only-testing:MixCutAppTests
  ```
  ⚠ `-only-testing` 要写到**目标级**：本仓实测方法级选择会选中 0 条用例却报绿（项目记忆「四条取证腿」那格记着）。
  改过任何 Swift（含纯注释）⇒ 重建 `.scratch/dd`，否则门禁测旧产物。
- 守卫：`scripts/check_folder_mix_guards.sh` + 全量守卫；全量 `swift test` 连跑数遍含顺序扰动，并报压力条件。
- 端到端手工（真机，只读用户自己的素材目录）：
  1. 备根目录：4 个一级子文件夹，含一条 >30s、一个非视频文件、一个空文件夹、一个与别处内容重复的文件。
  2. 扫描 → 侧栏出现该产品与 4 个项目；超 30s 那条**在候选里**；重复文件被哈希去重且不出现在候选数里；空文件夹标灰写明原因。
  3. 条数步进器：上限读数应等于非空类可用数的最小值；试图超过时硬报错不静默截断。
  4. 翻页 `第 k / N 条`：逐条核对每类素材互不重复；点「整批重掷」后不出现本次会话已用过的素材。
  5. 确认 → 汇总项目里出现 N 个方案，`SchemeSegment.position` 顺序 == 排的类别顺序；`templateGroupId` 各不相同（不并组）。
  6. 导出页勾选后出 mp4：`ffprobe` 数流时长 ≈ 各整片之和；逐段听到原声；**断网状态下全流程零 AI/ASR 请求**。
  7. 同目录重扫 → 不新建副本产品/项目（D12），方案进同一汇总项目（D11），候选数不因重扫膨胀。
  8. 来源标签（D20/D21）：A 视图未选来源时「生成方案」必须禁用；选定后入库的每条 `Video.defaultSourceRaw` 等于所选值，**不得出现 `.curated`（搬运）的默认残留**。〔形态已随 Step 2 变更，2026-10-20〕原来设计的"先不设 source 调一次 `importOrLinkVideo`，断言读回的是搬运"这条真跑腿**在编译期就不可能写了** —— `source:` 是必填入参、`pendingBatchSource` 属性已删除 ⇒ 缺 source 直接编译失败，比运行时红得早。剩下的运行时部分（界面选的那颗 == 库里读回的那颗）改由 A 视图那条腿验（未选 ⇒ 按钮禁用 + 选定 ⇒ 入库后逐条读回）。守卫侧由 `FolderMixIngestGuardTests` T-16 钉住"不许再有经实例状态的隐式通道"。
  9. 翻页与局部重掷（D22）：N=4 时翻到第 3 条点「换一换」，第 1/2/4 条的选中集必须逐字不变（R9 判据；已由 `FolderMixPickerTests` P9b/P9c 在纯函数层取证）。
  10. 入库终态（D19 改判为 ④，见 R18/R21）：C 入库的 Video 状态**停在 `.imported`**（不加枚举），断言三条：① 同一文件**再走母体导入**时阶段 2 必须照常触发（证明 `:418` 没被污染）；② `ImportView.swift:838` 不给它挂假重试按钮 —— 〔实测该条件早就在，R21〕那一行本来就带 `&& video.segments.isEmpty`，C 的载体必带一条整片段 ⇒ 这条不需要新增代码，只需要被验到；③ 已有整片段时首跑**不混存**：段数 == 切分段数、且那条整片段不在结果里（判据真源 `WholeClipShape`，已由 `WholeClipShapeTests` W1–W6 + 8 把变异刀取证；端到端那一腿需要 `xcodebuild test`，见第八节"未跑"）。
  11. 版面：窗口拉到 900×600 最小尺寸，整页无纵向滚动。**⚠ 本条在 SwiftUI 侧目前不可取证**——项目自带的 Mac2 黑盒 UI 环有两条 P0 未修（假库开关 DEBUG-only、MCP 端口硬绑，见项目记忆），故本条现阶段只能是**人工目测**；若要机器化，先修环，别把跑不了的验收当成已验证。（mockup 侧的同名断言已实测通过，但那是 HTML，不担保 SwiftUI 布局等价。）

## 七、修订记录

| 编号 | 初稿断言 | 勘误后 | 落点 |
|---|---|---|---|
| R1 | 「`check_navigation_readiness_guards.sh:121` 是导航计数判据，须同步」 | **该判据不存在**；`:115-125` 实为 G15a/G15b 预热与 G07/G08 就绪态判据。全仓无 `NavigationItem` 条数守卫 | 风险 5 + Step 6 的 G-e |
| R2 | 「Segment 唯一生产者守卫在 `check_ai_completeness_guards.sh:114-122`」 | 守卫存在但在 **`:137-144`**；114-122 处是 `SegmentationCompleteness.audit` 与 18 秒规则 | Step 3 |
| R3 | 「`ExportService.swift:156` 一处静默 continue」 | 实为 **`:164-168` 两处**：关系为 nil、或 `effectivePicture.videoPath` 空/文件不在盘 | Step 4 |
| R4 | 「重复分镜拦截在 `SchemeViewModel.swift:678/710`」 | 实为 **`:686-692` 与 `:715`**（toast 原文「该分镜已在方案中」） | Step 4 |
| R5 | 「`createCustomScheme` 的 AI 反推在 `:976` → `SchemeGenerationService.swift:465`」 | 实为调用点 **`:984`**、定义 **`SchemeGenerationService.swift:493`** | Step 5 |
| R6 | 「Step 2/3＝给 `importSelfSegments` 加 `durationCap`/`runTranscription`/`runTagging` 三开关」 | **方案级返工**（架构审查问题 1）：三开关是把语义不同的用例硬掰。**〔已作废 2026-10-20 同日再审〕** 本条给出的替代案（抽 `WholeClipIngest` 内核）也被 R10 推翻，见该条 | Step 2、Step 3 |
| R7 | 预览件 A5 文案「随机 · 已生成的不再回放」 | **过度承诺**：D3 的作用域是会话内，重启即失效。改为「本次会话内不回放」 | 预览件 + D3 |
| R8 | 风险 4「删模块项目级联掉槽 ⇒ 本期只如实记录」 | **接受症状**：仓里已有 `notePrunedSegments` 契约可暴露它，改为必须接（Step 7）。原文保留并标〔已修订〕 | Step 7、风险 4 |
| R9 | 「同素材跨类别 ⇒ 择片器 R6 挡掉」 | 治错了对象：真实故障是**第二个类别的候选被导入环节静默吃掉**（`:498` `continue`，连关联都不建）。升格为前置决策 P-1 摊开两案。**〔已消解〕** 丁案下 C 走 `importOrLinkVideo`，命中即幂等关联，两案皆不必 | P-1 |
| R10 | 上一轮架构审查推荐的「抽 `WholeClipIngest` 公共内核」 | **审查自身被推翻**：甲（三开关）与乙（抽内核）共享同一个错前提——"C 必须落在 `importSelfSegments` 上"。回到契约层查，`commitWholeVideo` 注释早已为"整片保留"预留接入口（`SegmentCommitter.swift:161-166`），而 `importVideos` 本就是两段式、阶段 1 自带去重+幂等关联+取消点 ⇒ 正解是**第三条路丁**：复用阶段 1，不碰 B。乙案若成立等于把语义错位固化成一层抽象 | Step 2 全节重写、P-1 消解、风险 1/2/8 消解 |
| R11 | 丁案「C 在 `commitWholeVideo` 成功后把 status 收在 `.completed`」 | **自己写的方案里藏着数据污染**：那会让同一文件日后走母体导入时被 `:418` 静默判为已分析。改判为 D19（加 `.wholeClipReady` 终态）。同时**修正乙案的核心论据**：「Swift 穷尽 switch 会帮你找齐消费点」实测只对 2/6 成立——`ImportView.swift:529/:1084/:1381` 与 `MixCutApp.swift:838-847` 都带 `default:`，会静默吞新态 ⇒ 新增 G-f 守卫补这 4 处 | D19、Step 2、Step 6 G-f |
| R12 | 丁案「直接调 `importOrLinkVideo` 即可复用阶段 1」 | **漏了一条隐式通道**：`:437` 读的是 `private var pendingBatchSource`（默认 `.curated` 搬运，只在 `:103` 被赋值），不传 source 就把整批素材静默标成"他人视频"，编译器与现有测试都不拦 ⇒ 升为 D20（source 改必填入参，属修族）+ D21（A 视图补来源控件，否则必填无处可填） | D20、D21、Step 2、Step 3、验收 8 |
| R13 | 「上限 8 ＝ 各类可用数的最小值」 | 口径未定是快照还是实时 ⇒ 定为**实时** `maxWithoutRepeat(..., used:)`，随换一换消耗而下降；否则与「生成 N 个方案」按钮态打架 | Step 1 |
| R14 | 未知清单第 1 项「已有整片段 + 母体导入会不会混存」标着**未验证** | **已用实读闭合，答案是会混存**：首跑 `:634-639` 传 `clearsExistingSegments: false`，`:697/:734` 靠它决定是否删旧段 ⇒ 整片段不删、切分段追加。根因是这个布尔入参背后有一条**未声明的前置**（"首跑必然无旧分镜"），D19 第一次让它不成立。修法：`:639` 改按状态判定 + 把前置写进注释 | Step 2〔P0-1 已闭合〕、验收、测试清单 T-15（结构钉，**已生成**）+ 行为夹具判据待 Step 2 同笔 |
| R15 | Step 7「导出侧丢段要出声」未定形态 | 实读发现 `ExportInput.from` 有 **2 个生产调用方**，其中 `MCPToolHandlers.swift:562` 是**对外 Agent 契约** ⇒ 改返回类型即破坏工具接口。定形：返回类型不动，`ExportInput` 加两个**可选**字段（且遵守"给已落盘 Codable 加字段必须 Optional"） | Step 7 第 2 条、测试清单 T-16 |
| R16 | 磁盘预检 `totalFileSize * 2` | 系统性低估：漏算 N 条成片输出。改式 `素材×2 + 每条估重×N`，估重复用 `ExportService.swift:93-102` 的码率文案数 | Step 4 |
| R17 | `computeFileHash` 返回 nil 时退 UUID 目录名继续入库 | 该分支**同时跳过 `:412` 的去重** ⇒ 去重整体失效、同文件重复入库，把 D3「不回放」击穿。改判为**拒绝该文件 + 逐名上报**，并加"`Videos/<uuid>/` 行数恒 0"判据 | 第九节、测试清单 T-18（结构钉，**已生成**；含 T-18b 族覆盖腿：两处兜底必须全抓） |
| R18 | D19「加 `VideoStatus.wholeClipReady` 终态」+「Step 2 把 status 收成 `.completed`」 | **上一轮评审自己的推荐被打回**（候选 ④ 胜出）。实测两条：① `Video.asrSentences` setter 是 `try? encode(newValue)`（`Models/Video.swift:220`），**空数组也编码成非 nil Data**；② `clearASRRun()` 只清引擎三字段、不清 `asrSentencesData`（`:67-71`）。⇒ `byShape` 的 `asrSentencesData == nil` 足以把 C 与母体链分开 ⇒ **不必加枚举**：让 status 停在 `.imported`，只修两处误读它的消费者（`:639`、`:838`）。半径 7→2。残余代价：形状启发式变承重、分不开 C 与 B（但同侧时行为正确）、UI 少一格"整片就绪"信息 | D19 改判、Step 2 第 1 条重写、G-f 作废 |
| R19 | Step 6 守卫表里的 G-f「`VideoStatus` 的 switch 不得带 default」 | **整块取消**：它只为 D19 的新枚举服务。④ 不加枚举 ⇒ 不必改 4 处 UI 映射。实测地形（6 处 switch 仅 2 处穷尽、4 处带 default）**留档为将来加状态时的已知地图**，本期不作判据 | Step 6 G-f 行 |
| R20 | 「扩展名判据有两处：`ImportView.swift:264-267` 与 `ImportViewModel.swift:1009`」 | **行号腐烂 + 少了一处**：落码前 grep 重取，扩展名字面量实际在 `ImportView.swift:474-477` 与 `MixCutApp.swift:1141-1144`（旧库恢复扫描，同集合另一种顺序——这一处初稿根本没看见），UTType 表在 `ImportViewModel.swift:1305-1307`。前两处今天恰好等价，第三处**真的**少收 m4v/mkv ⇒ 收编的是三处不是两处 | Step 1、新守卫 G-i |
| R21 | 「④ 要修两处误读 `.imported` 的消费者：`:639` 与 `:838` 假重试按钮」 | **其中一处是既有行为**：实读 `ImportView.swift:838-841`，`canShowRetry` 早就含 `&& video.segments.isEmpty`（注释原文「白名单：只在『孤立 imported』或『明确 failed』时显示」）。C 的载体必带一条整片段 ⇒ 假按钮不会出现 ⇒ 半径 2→1。教训与 R1 同类：**"读一遍现状"必须在动手那一轮再读一遍，隔了一天的行号与条件都会变** | D19、Step 2 第 1 条 |
| R22 | Step 1 锁定的四个签名（`draw(...seed:)`、`drawMany(...seed:)`、`reroll(current:atRow k:...)`、两元组返回值） | **改形四处后才有牙齿**（详见 Step 1 落地块）：① `seed:`→`rng: inout SplitMix64`，一次性 seed 表达不了"逐次推进"⇒ R7 无法成立；② `draw` 增必填 `banned:`，否则 R3 的重置会把换一换刚排除的那条放回来（刀 K12 实测）；③ 删 `atRow k:`，函数体用不到而"第几条"在调用方已有一份 ⇒ 两处各写一遍才是风险；④ `FolderMixRow` 增 `duplicateBlockedCategories`/`unchangedCategories` 两份清单，分别接 R6 行内去重挡掉与"只有 1 条素材换不动"，两者都不许静默 | Step 1、Step 5（VM 按 `usedPerDraw[k-1]` 组账） |
| R23 | Step 7「在 `ExportInput` 内加**可选**字段（`plannedSegmentCount: Int?` / `droppedDescriptions: [String]?`）」，依据是「守本仓既有教训：给已落盘的 Codable 结构加字段必须用 Optional」 | **纪律引用对了对象错**：实测 `ExportInput` 只在内存里跨 actor 传（`Sendable` 值类型），全仓**不 Codable、不落盘**——构造点只有 `ExportService.from(scheme:)` 一处，消费点两处（`ExportView.swift:792` / `MCPToolHandlers.swift:562`）。那条 Optional 纪律防的是"旧数据缺键 ⇒ keyNotFound"，而这里没有"旧数据"。照抄只会给两个调用方各加一次**永不成立**的 nil 分支 ⇒ 改判为非 Optional；MCP 侧的"不许破坏对外契约"仍然成立，做法是不动既有键、只**新增**可选返回键（那是 JSON 层的可选，不是 Swift 类型的可选） | Step 7 第 2 条 |
| R24 | 「G-e 只要新增 ⌘8 就对齐」 | **对齐时撞出一条既有缺口**：`SidebarView.shortcutHint` 把「知识库」标成 ⌘7 已有相当时日，而 `MixCutApp` 的菜单里从来没有那颗按钮（实测 `keyboardShortcut("7")` / `("8")` 全仓 0 命中）⇒ 侧栏悬停提示在说做不到的话。本期补上 ⌘7 与 ⌘8，门才从 7 case/6 绑定变成 8/8 | Step 6 G-e、Step 5 |
| R25 | 计划里写「用既有导入判据做对照」来证下沉没改行为 | **无中生有**：实测全仓对 `phase/progress/progressDescription/isProcessing/errorMessage` 的断言数 = 0（`Tests/**` 的命中全是同名异物）。改法=在**现码**上先写一组特征化判据、取改前绿灯读数当基线（CR-1..CR-5），并配变异刀证它非恒真 | 笔 1a |
| R26 | 下沉被估成「纯搬家 + 两条回归腿」 | 实测面是**一次跨 6 个脚本 / 3 个测试文件的名册重写**（约 4 倍）。定档：同笔全登七颗名册、成对改数、继续排最前 | 笔 1b 名册表 ①–⑦ |
| R27 | 计划把 `@MainActor` 写成 service 的禁忌 | 先例 `SegmentCommitter.swift:25-26` 本身就是 `@MainActor` 且不碰任何 UI 读数；要禁的是「为写 UI 而 `@MainActor`」，不是它本身（SwiftData 的 `ModelContext` 本来就在主 actor 上） | T-24 措辞、D-0 段 |
| R28 | LANE 扩面清单里写了 Core 那颗 `FolderMixCombination.swift` | LANE 是 **App 层**扫描面，Core 文件按名前缀被规模计数自动接住 ⇒ 层级写错。笔 4 实际扩的是三颗 App 文件 | `check_folder_mix_guards.sh` 的 LANE 注释 |
| R29 | 计划写「补抽 count + reserve 个然后**取前 count 个**」 | 外部经验揭示 Floyd 产出的 m 个序号是**升序**的，取前缀 = 系统性偏向每个文件夹开头的素材（成员分布本身均匀，被带偏的是截断顺序）。改成先按注入种子打散再过滤取满（D35、FMX-03/04） | `sampleDistinctOrdinals` |
| R30 | 计划把终止性判据写成 `.timeLimit` 那种墙上时钟形态 | 实测全仓 `Tests/MixCutCoreTests/` 里 `.timeLimit` 出现 **0 次**、可行性未验证 ⇒ 写进台账就是一条没人跑过的指令。换成「随机数消耗恰为 m 次」（D36） | FMX-02 |
| R31 | 覆盖率轮把 23 条新用例当成 23 份工作量 | 逐条回源后：真缺口对应 10 族**已覆盖的结案件**（RNG 无偏、`SplitMix64` 序列、扩展名白名单、整片段容差、预算取整、日志级别、associate 幂等、台架自证…）。不生成的写成结案件，不挂着当缺口 | 六、验证的结案件清单 |
| R32 | 刀面处置把 K11（不做行内去重）列入摘标 | 默认档下一颗文件只有一个父目录、行内同素材不可达；但精确档会把跨目录同内容归并成同一键 ⇒ K11 **改判目标**为「解析后同一个 Segment 不许在一行出现两次」，不摘 | 笔 2 摘标名册 |
| R33 | 预览件轮把「精确识别会压低组合总数」写进文案 | **错**：radix 是「该类别内不同素材数」，一个文件只有一个父目录 ⇒ 跨目录重复不减格。真效果在「同一行不许重复用同一素材」（失败档 C）。文案与判据都按这个改 | 页脚旁注、验证腿 6/7 |
| R34 | 计划把两颗开关放在页头 | 台架 spill 腿实测：900 窗口下页头已占 608/640，再塞两颗开关会把「换目录」顶出窗口（2px，长副标题 35px）⇒ 改落页脚按钮行右侧；副标题允许 ellipsis 收缩、完整文案进 `help` | 笔 6 UI |
| R35 | 台账里 `函数名:行号` 的引用长期只验「路径存在 + 行号不越界」 | 这类腐败会静默通过（本轮实测 69 处越锚）。G-g 加越锚腿：锚点拆标识符颗粒 + 按词边界 + 时态豁免 + 5 条非恒真自测；同轮修行号腐烂 46 处（台账 25、源码与脚本注释 21） | `check_plan_doc_citations.py` 第 2b 节 |
| R36 | 给历史死数「直接改成现值」的冲动 | 台账的规矩是**勘误不删原文**：死数用 `〔旧读数：…〕` 停放、带日期的执行进展行算当天事实 ⇒ 门按此豁免（否则要么洗掉日志、要么红得没有信息量）。本轮实测第一版就是拿现状去判历史读数，误报 140 处 | 同上的豁免边界 |
| R37 | 变异台架 `swift test` 一把梭 | 连续两次写同一颗文件时 SPM 增量编译会跑**上一份二进制** ⇒ 出现「同一把刀两次读数不同」（本轮 R3/R10 各读到一次不全的红集合）。改成先 `swift build --build-tests` 再 `swift test --skip-build`，并把 mtime 推到未来 | `.scratch/fm_mutate_step4.py`、step5 |
| R38 | 台架分类器把输出里出现 `error:` 当编译失败 | `Fatal error:` 也含这个子串 ⇒ 把咬中的刀误判成 COMPILE；而别的套件回显源码里的 `Fatal error:` 字样又把它误判成崩溃。现规则：编译错误必须成 `文件:行:列: error:` 形状，**有干净的红就不算 CRASH** | 两个台架的 run_tests |
| R39 | G-h 那把刀第一次跑出 VACUOUS 就怀疑门恒真 | 实际是**刀太窄**：只摘了 VM 与扫描器两颗文件，service 与两颗探针里还剩 8 行前缀 ⇒ 门照样绿。「门恒真」与「刀太窄」修法完全不同，先审刀再审判据 | `selftest_folder_mix_guards.py` 的 G-h 刀 |
| R40 | 三颗新文件登记后 pbx 自检全绿就当登记没问题 | `check_pbx_registration.py` 只验「四段齐全 + path 字面」，验不出**挂错组** ⇒ 只有真机 `xcodebuild` 报「Build input files cannot be found」（一趟 4 分钟）。手工归位后给 `register_pbx_file.py` 加「模板必须与新文件同目录」的闸，并跑正/负对照（默认模板被拒 / 同目录模板放行） | 笔 4 落地段 |
| R41 | 上一版打算新造一颗「唯一读时长的地方」并把读盘当默认路径 | 库里 `Video.duration` 与 `Video.contentHash` 都已算好、且**今天的混剪候选键本来就是 contentHash** ⇒ 那是重复计算。改判成两层解析（D33），把已算好的存量接上 | 笔 3/4 |
| R42 | 给已落盘的 `FolderMixSessionState` 加字段时按 Swift 直觉写非 Optional | 本仓实测：非 Optional 字段即使有默认值，缺键仍 `keyNotFound` ⇒ 逐颗 `decodeIfPresent`，新字段一律 Optional（FMX-12b 逐颗删键、FMX-12e 老 JSON 缺 `rowOrdinals` 各钉一遍） | `FolderMixSessionState.swift` |
| R43 | Floyd 实现里用 `Array(Set(picked))` 输出 | 破坏 R1「同 seed 逐字可复现」—— Swift 的 `Set` 迭代序不保证稳定 ⇒ 改成插入序数组。**这是新判据抓出的真缺陷**，不是理论担心 | FMX-01/P12 那轮 |
| R44 | `drawMany` 用「预留量抽一批、过滤后取满」的写法在 3/4 就报「组合空间已耗尽」 | 按预留大小抽样会漏掉最后几个未发出的序号 ⇒ 改为按剩余量决定抽样规模。**新判据抓出的第二处真缺陷** | FMX-01/06 |
| R45 | `seenHere` 那支「行内已见过就跳过」的分支 | 判据跑下来证明不可达（`substitute` 的过滤已经保证）⇒ **删掉**，不写注释糊它。留一支不可达分支 = 下一个人以为它在防什么 | `FolderMixPicker` |
| R46 | P9 替补判据只测 0 号格 | 跨类别动手的那把刀是 no-op（换 1 号格照样绿）⇒ 判据改成逐格验「除那一格外其余 picks 逐字不动」。第三处真缺陷，同样是判据先于评审抓到 | P9/P9b |
| R47 | 会话还原时自己写一句 `FileManager.default.fileExists` 问目录在不在 | 被 `MediaAvailabilityGuardTests` G-M01 的逐文件名册当场抓红（多一颗裸问站点）。改由唯一 IO 面 `MaterialFolderScanner` 报 `rootError` ⇒ 名册不用改，且「在不在」与「读不读得动」不再分两处判 | 笔 7 |
| R48 | T-26 打算长期以 `withKnownIssue` 留在套件里 | 红钉的寿命只到缺陷修完那一刻：混剪链的 `importVM` 归零后**摘标升成硬闸**，否则「谁又把它接回去」这件事不红。known issues 5 → 4 | `FolderMixIngestGuardTests` |
| R49 | UI 落地时把钳位写在 View 的 Stepper 里（`FolderMixLimits.countInputClamp`） | G-c 立刻打红：判定长在界面层 ⇒ `swift test` 一条都覆盖不到。收回 VM 的 `stepRowCount/stepSoftLimit`，口径只有一份 | 笔 6 |
| R50 | 台账表格与批量脚本里第三次踩同一族坑：一行写成 5 格、Python 串里用 ASCII 双引号 | 表格列数自检抓到（`数据行 174 行` 那次 FAIL x1）；中文里写 ASCII 双引号会**静默吞掉字符串**（本轮两次 SyntaxError）。规矩：表格改完跑形状判据、中文引号一律用「」 | 本台账 + `.scratch` 脚本 |
| R52 | 第三轮落地（真机第二次失败照出四条缺陷）：入库清单按「池子前缀」取、可用性从不进资格、档 B 一刀不补建、墓碑基线不动 | 清单改成「先装抽中集再补余量」；新码 `materialMissing` 排到档 B 之前，判据不可信时整批停手；档 B 改判成甲-隐「补建 + 内部段标记 + 一颗唯一出口」（19 处收口、8 组豁免、门 T-33 正反两腿）；T-25 从「绝对不许补建」改成「只许长在入库真身那两处」；墓碑基线随之重生成 45/43/12 ⇒ 42/40/10 | 细则与实测读数在 `docs/superpowers/plans/2026-10-22-folder-mix-drawn-set-and-wholeclip.md`（决议 K1–K9、笔 K1/K4/K2/K3、判据 FMX-18d/18e/18f 与 JOIN-20…27、App 腿 JOIN-23…26、门 T-25 改口径 / T-32 / T-33）；两条根因经验：可见性收口必须连「撤销那两条绕过装载的写入面」一起枚举，`segmentCount` 一颗两用（数字 + 三处禁用闸）必须分叉而不是就地过滤 |
| R51 | 初版修复计划（2026-10-22 那份）把与库对接的键选成「类别项目 + 文件名」，并声明本修复**不动** `ClipIngestService` 与 `ImportViewModel` | **两条都被评审推翻**：文件名仍是一颗跨域反查键，且「同内容、不同文件名」的素材会继续被静默摘行 —— 分界判据 JOIN-7 就是专门打它的；而真正零代价的解是**当场记账**（入库那一刻对应关系就在服务手里），于是服务 +1 字段、两支各补一句写入，回归半径如实放宽 | 修复与判据同源登记在 `docs/superpowers/plans/2026-10-22-folder-mix-join-key.md`（决议 J1–J6、JOIN-0…7、门 T-30/T-31、App 腿首颗混剪判据 TC-J2/J3）；判据层的根因是 FMX-14 那族夹具**自己约定键**（键与路径同域 ⇒ 键错位时判据看不见），现用 JOIN-0 夹具自检 + JOIN-7 分界腿钉死；错误码归因同步改口：`notIngested` 成档 B2 专属码，档 A 不再兜「没找到」 —— 本仓「算得对≠归因对」那条经验又中一次 |

## 八、执行进展

| 时间 | 产出 | 取证 |
|---|---|---|
| 2026-10-19 | 需求澄清完成，六维度压缩为三轮（技术选型/安全/成本被仓库与单机场景钉死，未提问） | 三轮 AskUserQuestion 全答 |
| 2026-10-19 | 既有能力盘点 + 缺口定位 | 实读 `ImportView.swift:61-88/176-195`、`ImportViewModel.swift:463-560`、`FFmpegRunner.swift:600`、`MixScheme.swift`、`SegmentPickerCatalog.swift`、`ROADMAP.md:135` |
| 2026-10-20 | Step 0 预览件（三态单文件）+ 四腿工装 | 静态 29 PASS / `GEOMETRY CLEAN` / `OVERLAP CLEAN` / 8 刀全咬 |
| 2026-10-20 | 你反馈「上下太长」⇒ 量出 900×600 预算重排；反问「一次几条」⇒ D7 改判 D16/D17/D18 | 版面读数 `bodyH 600 / vOver 0 / hOver 0 / clipped []`；条数上限来源实读 `VariantBatchExportService.swift:118-168` |
| 2026-10-20 | 计划落仓库文档，并回源核错 5 处行号（含一条我凭空写出的守卫） | 本文档第七节 R1–R5 |
| 2026-10-20 | 架构审查（architecture-first-fix）判 **需返工**：非遮盖、不引入耦合两条不过 ⇒ 落 R6–R9 四条修订，Step 2/3 重写为抽内核，新增 Step 7 与 P-1 | 三条硬标尺逐条对源；新实测两条事实：`ProjectVideo.swift:31-39` 幂等记 error、`importSelfSegments` 零取消检查点 |
| 2026-10-20 | **再审推翻上一轮审查自己的推荐**（R10）：甲/乙共享错前提，真答案是第三条路丁——复用 `importVideos` 阶段 1 + `commitWholeVideo`。Step 2/3 重写，P-1 消解，风险 1/2/8 消解 | 实读 `ImportViewModel.swift:157-185`（两段式）、`:401-460`（阶段 1 已含去重+幂等关联+元数据+缩略图）、`:418`（status 当分析代理）、`SegmentCommitter.swift:161`（「整片保留也接这里」预留）、`ImportView.swift:838`（`.imported` 会挂假重试按钮） |
| 2026-10-20 | 丁案的二阶效应自查抓出一条跨通路污染：C 置 `.completed` ⇒ 同文件日后母体导入被静默判为已分析 ⇒ 升为待拍 P-2 | 触发链单点 `:418`，已按「反向确认」核过：status 与 segments 两条件在 C 产物上同时为假 |
| 2026-10-20 | 用户在途改动已自行提交（HEAD `4ac5704`）⇒ 风险 7 与 Step 7 的开工前置阻塞结案 | `git status --porcelain` 只剩本文件一个未跟踪项；三个热区文件路径逐个查为空 |
| 2026-10-20 | 按推荐全量落进计划：新增 **D19–D22**、Step 6 守卫表扩到 G-a…G-g（含每条的适用/豁免二值声明）、Step 1 API 加 per-draw used 快照与实时上限、验收加 3 条、修订记录补 R11–R13 | 文档判据：11 张表 88 数据行、67 处 `file:line` 逐个核过、22 条决议、R1–R13 十三条自洽、DOC CLEAN(exit 0)；预览件加 A12 来源条后仍 `12=12=12`、`GEOMETRY CLEAN`、`OVERLAP CLEAN`、8 刀全咬、md5 `3bfb622f…` |
| 2026-10-20 | 落 D21 时实测到两处：加来源条会让「素材来源」标签被挤到溢出（长提示文案所致，缩短后复绿）；`VideoStatus` 的 6 处 switch 仅 2 处穷尽 ⇒ **乙案"编译器兜底"的论据被削弱**，据此新增 G-f | 前者由几何腿抓到（`badLbl`），后者逐个 `sed` 出 default 分支实读 |
| 2026-10-20 | 架构评审（tech-solution-review）后按推荐全量落 7 条：P0-1 **只读实做闭合**（结论：会混存，根因是布尔入参背后一条未声明前置）、P0-2 改形（返回类型不动 + 可选字段，因 `MCPToolHandlers.swift:575` 是对外契约）、hash 失败改拒绝档、G-f 四处目标值定死、磁盘公式补成片项、G-h 日志前缀、新增第十一节「明确不做」7 项 | 实读 `ImportViewModel.swift:362-367/634-639/697/734`（两个 `rebuildSegments` 调用点的 `clearsExistingSegments` 分别是 true/false）、`ExportInput.from` 调用方 2 处、`#Predicate<Video>` 仅 1 处且按 hash 不按 status |
| 2026-10-20 | 你确认 A 版面（含 A12 来源条）⇒ 预览闸口放行 | 你的原话"选a" |
| 2026-10-20 | `FolderMixIngestGuardTests.swift` **真跑取证**：`swift test --filter` → 8 个测试全过、3 条 known issue（xfail 红钉各抓到 1 处真站点，T-18 抓到 2 处）；全量 `swift test` → **1191 个测试通过、0 真失败、7 known issues**（3 条 `skipped` 是 env 门控的重生成腿） | `/tmp/fm4.log`、`/tmp/fm_full.log` |
| 2026-10-20 | 台架连修四处：① `String`/`Substring` 混用与 `withKnownIssue` 首参是 `Comment` 不是 `String`（拼接不自动转）⇒ 编译错；② `line.prefix(index)` 不存在（那是 `prefix(maxLength:)`）⇒ 改切片；③ **正则用 `[^;]*?` 收尾假设了分号分隔语句，Swift 不用分号 ⇒ 越过 `)` 吃到下一条语句，把修好后的代码报成命中（假阳性）**，改括号平衡窗口；④ `#"…"#` 里插值写 `\#(` 会吃掉字面量 `\(` ⇒ 放弃插值直接写进模式 | ③ 是「对照·阴性」抓出来的：它今天真的失败了，不是走过场。若没有那对阴性对照，这枚红钉修完也摘不掉 |
| 2026-10-20 | 对判据做**反例攻击**（dev-expert/code-review），新增第十二节：4 例反例读数 + G-1…G-6 待办；同时修掉 Step 4 里把 D12 当成既有能力的一句话 | 反例用 Python 复跑同一条 ICU 正则（8/8 符合预期）；`copyVideoToGlobal` 调用面实测 3 处全在 `ImportViewModel.swift`；Project 侧「按名查项目」入口实测**零命中**；本卷大小写不敏感实测（`CaseTest`→`casetest` 可见） |
| 2026-10-20 | 第二次评审把**我自己推荐的 D19 也打回**：改判 ④（不加枚举，只修两处误读 `.imported` 的消费者），半径 7→2，G-f 整块取消（R18/R19）。第九节补 3 档失败形态（symlink / 扫描后文件消失 / 归一同名） | 两条实测支撑改判：`Video.swift:194` 的 setter 是 `try? encode(newValue)` ⇒ **空数组编码成非 nil Data**；`clearASRRun()`（`:67-71`）不清 `asrSentencesData` ⇒ `byShape` 的 nil 判据足以分开 C 与母体链 |
| 2026-10-20 | 落 G-1…G-5，新增 T-19（④ 承重前提）与 T-20（名册对账）+「尾部未被吞」 | `swift test --filter` → **11 条全绿、3 known issue**，行号读数 `:428/:501/:437/:634` 正确；全量 `swift test` → **1194 通过、0 真失败、7 known issues**（`/tmp/fm6.log`、`/tmp/fm_full2.log`）。踩到两个自己的坑：`NSTextCheckingResult` 没有 `.location`（要 `.range.location`）、名册漏登定义处 `FileHelper.swift` 会让 T-20 假红 |
| 2026-10-20 | **Step 1 落地**：`FolderMixScanner.swift`（`VideoFileFormat` 真源 + 一级目录归一投影）/ `FolderMixPicker.swift`（`SplitMix64` + `draw/drawMany/maxWithoutRepeat/reroll`）/ `DiskSpaceBudget.swift`（素材×2＋逐条成片项）三颗 Core 文件 + 53 条判据；**同笔**把三处旧扩展名判据改成调用真源、`supportedTypes` 改由真源派生、`ProjectVideoDedupTests` 的 private `SplitMix64` 副本收编进 Core 并同轮换名（`next()`→`nextUInt64()`）、三处引用它的注释同轮改口 | `swift test --filter` 53 条全绿；全量 **1247 通过 / 0 真失败 / 7 known issues**；`MODE=typecheck` 与 `MODE=silgen` 两腿 PASS（261 编译单元）；`check_pbx_registration.py` PASS 且新增**判据⑤全量扫描面**（119 颗 Core 文件逐颗查登记，不再只依赖手工名册）；变异腿 **24 把刀全被对应判据咬住**，还原 md5 `511bf073/1147bc34/2675f17e` |
| 2026-10-20 | 变异台架第一版把四种成因混在一起报（编译不过 / 刀没注进 / 判据恒真 / 期望写错），12 把刀"未达预期"里只有 **2 条是真缺口**：P10 把空类放在字典里却没放进 `orderedCategories`（等于没测"空类不取 min"）、K7 的锚点在文件头说明里也出现过 ⇒ "替换第一个匹配"洗掉的是注释，刀根本没注入。台架改成 COMPILE/CRASH/SKIP/VACUOUS/EXPECT 五态分类 + **锚点必须整文件唯一**才准注刀 | 第二轮 24/24 全咬。这两条真缺口都是"判据看起来绿、其实没牙"的形态，不跑变异永远发现不了 |
| 2026-10-20 | **Step 2/3 落地（丁案入库通路）**：`importOrLinkVideo` 由 `private` 提为 `internal` 并加**必填** `source:`（D20/R12 的隐式通道连根拔掉：`pendingBatchSource` 属性**已删除**）；新增 `importClipsWithoutAnalysis(urls:to:source:onUpdate:)` —— 只走阶段 1 + `commitWholeVideo`，不进阶段 2、不打 `isUserUploaded`、不受 30 秒闸管辖；`:639` 的 `clearsExistingSegments` 由字面量 `false` 改成形状判定（判据真源新增 `Sources/MixCutCore/WholeClipShape.swift`，容差与 `MixCutApp.swift:284-293` 的 byShape 同源、**多一个 `start ≥ 0` 下界**）；hash 算不出 ⇒ 两处（母体入库 + 自建分镜入库）统一改**拒绝该文件 + 逐名上报**（新 `ImportIngestError.uncomputableHash`）；`ProjectVideo.associate` 幂等命中由 error 降 info（风险 9）；新增唯一 IO 面 `MixCut/Services/Import/MaterialFolderScanner.swift`（只扫一级、`.skipsHiddenFiles`、**symlink 目录整类拒绝且判序早于 isDirectory**、`localizedStandardCompare` 稳定排序、自带 security-scoped start/stop 配对） | 全量 `swift test` **1256 通过 / 0 真失败 / 4 known issues**（红钉 T-15/T-16/T-18 三条**已摘标转正**，7→4）；`FolderMixIngestGuardTests` 新增 T-21（associate 级别，带"只换级别必须被抓到"的自检腿）与 T-18b 转型（真实代码归零 + 合成两处族计数）；扫描面锚点同轮换掉 `pendingBatchSource`（符号已不存在，留着就是假绿）；`check_pbx_registration.py` PASS（120 颗 Core 全量登记） |
| 2026-10-20 | **Step 4 落地（扫描与建库）**：`MaterialFolderScanner`（唯一 IO 面：只扫一级、`.skipsHiddenFiles`、**替身目录判序早于 isDirectory 并整类拒绝**、`localizedStandardCompare` 稳定排序、自带 security-scoped start/stop 配对）；`ProjectViewModel` 新增本期缺的那半 —— `project(named:in:)` / `ensureProject` / `ensureProduct`（D12 同名合并在 Project 侧原本**没有任何可复用入口**）；**建库一族收口**：「Project + 自定义组合容器」的逐字拷贝实测有 4 份（UI 建项 / MCP 建项 / 老项目补建 / `createCustomScheme` 双保险），现收成 `MixStrategy.attachCustomGroup` + `customGroup(for:)` + `Project.makeWithName` 三颗；候选真源按 Step 4 定档 = 入库后的 Segment、键 `contentHash ?? id`，且只收"有一条覆盖整片的段"的视频（用 `WholeClipShape` 判，不替它造段） | `FolderMixRawDirectory` 新增 `videoFolders`/`videoPaths`（provenance 列）—— 归一合并后"文件出自哪个文件夹"是重建 URL 的唯一办法，让调用方回目录自己找 = 把 S3/S4 的合并规则抄第二份。判据 S4f + 变异刀 K6 |
| 2026-10-20 | **Step 5 落地（编排 + 页面 + 侧栏）**：`FolderMixViewModel`（会话 seed 取挂钟不是 `SystemRandomNumberGenerator`、`used` 只在内存、D22 的组账方式照 P9c 那条腿、生成前按持久 id **重新解析**每条素材——预览与确认之间被删掉的素材在这里被查到，缺一条就整批不建，中途失败回滚已建的）；`FolderMixView` 按已确认的 A 版面；侧栏第 8 项 + 菜单 ⌘8。**顺带补真的既有缺口**：`SidebarView.shortcutHint` 早就把「知识库」标成 ⌘7，而 `MixCutApp` 的菜单里从来没有那颗按钮 ⇒ 提示在说做不到的话，G-e 对齐时一并补上 | **UI 未在真机验证**（诚实声明）：版面按 A 方案实现，但 D15「900×600 不滚动」这条在 SwiftUI 侧目前不可机器取证 —— 项目自带的 Mac2 黑盒 UI 环有两条 P0 未修（假库开关 DEBUG-only、MCP 端口硬绑）。HTML 预览件的同名断言已实测，**不担保 SwiftUI 布局等价**。`swift test` 不编 App 层 ⇒ 只能靠 typecheck+silgen 两腿证明可编译 |
| 2026-10-20 | **Step 6 落地**：`scripts/check_folder_mix_guards.sh`（G-a…G-l 共 14 条，每条都写适用边界 + 豁免边界）+ `scripts/selftest_folder_mix_guards.py`（**14 把刀逐条把门打红**，先跑未改动副本作基线）；把上一轮的 `check_doc.py` 搬进仓成 `scripts/check_plan_doc_citations.py`（G-g 的真身，参数化路径，默认只钉本期这份台账）；`docs/ROADMAP.md:135`「批量导入」条目结案 | 守卫全绿 17 条 PASS；自测腿：基线绿 → 14/14 刀各自咬红且不串味 → 还原后回到基线。三条台架教训写进脚本注释：① `finditer(out, re.M)` 的第二个位置参数是 **pos**，re.M(=1024) 被当成"跳过前 1024 字符"⇒ 14 把刀齐刷刷假报"恒真"；② bash 里 `$got` 紧跟全角逗号会被并进变量名 ⇒ `set -u` 当场 unbound；③ `grep -rc` 多文件打印的是 `文件:次数`，再 `awk '{s+=$1}'` 求和恒等于 0 |
| 2026-10-20 | **Step 7 落地（两处静默口）**：① `SchemeViewModel` 新增 `segmentIDsByScheme`（在 `loadSchemes` 时建索引 —— 真删之后 `schemeSeg.segment` 已是 nil，那一刻问不出"少的是哪条方案的第几段"）+ `prunedCountByScheme`（**归属一份**），`SchemeDetailView` 头部读本字典显示"该方案有 N 段素材已不存在"（视图层不裸读关系，G08b 那道门不许添新站点）；② `ExportInput` 加 `plannedSegmentCount` / `droppedDescriptions`，两个调用方各就各位：导出页 toast「计划 N 段、实得 M 段（逐条原因）」、MCP 侧只**新增**可选键不动既有语义 | 〔改判一处，见 R23〕计划原文要求这两个字段用 Optional，依据是「给已落盘的 Codable 加字段必须 Optional」——实测 `ExportInput` **只在内存跨 actor 传、全仓不 Codable 不落盘**（构造点 1 处、消费点 2 处），套过来只会给两个调用方各加一次永不成立的 nil 分支 ⇒ 用非 Optional 并留证据 |
| 2026-10-20 | **Step 7 的回滚写法被既有名册抓红**：我最初把「要么 N 个要么 0 个」的回滚写成 `context.delete(scheme)` —— 全量 `swift test` 当场两条红：`G12 名册对账` 报真删站点 54→55 且「未登记的新站点：FolderMixViewModel.swift」，`G12b 反向对照` 跟着红。那不是名册太严，它拦的就是**绕过咽喉的第 12 处直删**，而这一族缺陷的原始症状正是「真删之后读死对象」的 SIGTRAP。改走 `schemeVM.deleteScheme(_:)`（界面隐藏 + 宽限期 + 撤销浮条 + 脚本配音回收都已经在它里面）后全绿 | 读数 `/tmp/step7_test.log`（1257 里 3 条真失败）→ 修复后 `/tmp/final_test.log`（1257 通过、4 known issues）。**教训**：给一个已有「每处真删都要登记」名册的仓加删除动作，先查名册而不是先加判据 |
| 2026-10-20 | **改判被既有名册抓到**：删掉 `contentHash: hash ?? UUID().uuidString` 之后，`TombstoneReadGuardTests` 的 **G16b 随机兜底名册对账**当场红 —— 那一处正是名册里唯一在册的兜底（理由原文挂着"是否改成跳过并上报**另案 review**"）。名册改为空表并留拆解记录，同时给它补了一条**扫描面非空**自证：空表 + 扫描面空转（前缀写错）也会全绿，那是第三种假绿 | 这条红是好消息：它证明名册是承重的。另案已定（R17）并落地，理由里漏看的一格写进注释 —— "它不是归属键"不等于"它无害"，那条分支同时跳过了按 hash 的去重 |
| 2026-10-20 | **更正我上一轮的口头说法**：说过"这三条现在就能生成并立刻变红"，两处不准。① T-16/T-18 的行为判据依赖尚不存在的入口，今天只能做成**源码结构判据**；② 三条按仓内 `G08b` 先例走 `withKnownIssue` 严格 xfail ⇒ **今天是绿的**，是"修好后自己变红逼摘标"，不是"现在就红" | 先例出处 `TombstoneReadGuardTests.swift:498-507` |
| 2026-10-20 | **Step 1–7 全部落地完毕**（用户那一轮原话：「全链路执行，直到完全结束」）。产出：Core 纯逻辑 4 颗（Scanner / Picker / DiskSpaceBudget / WholeClipShape）+ 判据 63 条 + App 层新文件 3 颗（MaterialFolderScanner / FolderMixViewModel / FolderMixView）+ 改到的既有文件 12 处 + 守卫脚本 2 份 + 台账腿 1 份 + ROADMAP 结案 | 见「〇 取证状态表」的已跑 / 未跑两行 |
| 2026-10-20 | 补跑真机编译腿：`xcodebuild build` 与 `build-for-testing` 双 SUCCEEDED，`.scratch/dd` 产物随之刷新（不再是 10-11 的旧产物）| `/tmp/final_xcodebuild.log`、`/tmp/final_bft.log`，各 0 条 `error:` |
| — | ⏳ **还剩两件事，都不在我能做的范围内**：① 真机端到端验收（第六节 4–11 条，要用户本机 + 真实素材目录；版面那条还得先修 Mac2 UI 环的两条 P0，否则只能人工目测）；② 提交 —— 按约定只在用户明示时提交，本期所有改动**全部未提交**，也没有推过任何远端（本仓无 remote） | `git status --porcelain` 可查；HEAD 仍是 `4ac5704`，与开工前一致 |
| 2026-10-21 | **第二轮改判 · 笔 0 预览件**：`.scratch/preview/foldermix-round2.html` 自包含整页，逐态覆盖「勾选/取消（含不参与置灰）」、「超软上限红字 + 我已确认」、「生成前先预览」两态、「精确识别（慢）」两态（含「发现 X 组跨文件夹同内容」与「库里已有 X 条、需新算 Y 条」两颗读数）、替补/摘行脚注、目录失效、已发出/剩余 | 四腿台架 `.scratch/preview/bench_foldermix.py`：静态审计 / 几何 / 遮挡 / 变异，**180 条断言全 PASS、11 把刀逐把只咬自己那条**。spill 腿实测：两颗开关放页头会把「换目录」顶出窗口 2px（长副标题文案时 35px）⇒ 开关改落页脚按钮行右侧。你原话「没问题，执行直到全部结束」放行 |
| 2026-10-21 | **笔 1a 特征化判据先行**：`ClipIngestReadoutCharacterizationTests.swift` 5 条 —— CR-0 扫描面非空、CR-1 适配层四颗读数的取值序列、CR-2 `混剪入库第 i/N 个…` 这条文案与其时序、CR-3 `defer { isProcessing = false }` 落点与 `abortMessage` 早退时的读数、CR-5 service 全文禁 UI 读数且零 `context.delete(`。**改前基线在现码上取**，动手搬之前 | 上一版计划写的「用既有导入判据做对照」被实测证伪：全仓对那四颗读数的断言数 = **0**（`Tests/**` 里的命中全是同名异物）⇒ 登记 R25。配刀 `.scratch/fm_mutate_1a.py` K1/K2/K3 → **3/3 各咬自己那条** |
| 2026-10-21 | **笔 1b 入库能力下沉**：新增 `MixCut/Services/Import/ClipIngestService.swift`（`@MainActor`、零 UI 读数、零 `context.delete(`、事件经 `ClipIngestHooks` 回调给调用方），`importOrLinkVideo` / `importClipsWithoutAnalysis` 降为薄适配层；`computeFileHash`（口径 = SHA256 over 文件大小字符串 + 头 4 MB + 尾 4 MB，**不是整片**）从 ViewModel 归层进 service，成为全仓唯一定义 | 七颗名册逐颗改口并留读数：T 族扫描面由一颗文件改成名册（ImportViewModel + ClipIngestService）、T-20 调用名册 +`ClipIngestService.swift`（只登文件不登行号）、`TombstoneReadGuardTests` 每文件删除数成对（全仓 54 不变）、`MediaAvailabilityGuardTests` 每文件计数、`check_asr_guards.sh` 的 G23b（`shouldAutoRetake`）未被带走、LANE 扩到 4 颗 App 文件、readiness/undo/ai-completeness 三处确认未动。新门 T-24（service 禁 UI 状态）/ T-26（`importVM` 清零，按本仓规矩以 `withKnownIssue` 先进套件）/ T-27（`func computeFileHash` 全仓恰好 1 处）。FMX-21 生效正对照跑过：往 service 塞一条 `URLSession` ⇒ G-d1 必须红 |
| 2026-10-21 | **笔 2 择片语义换代**：`FolderMixPicker.swift` 整颗重写成组合语义 —— `FolderMixComboSpace`（混合基数双向映射 + 饱和乘积）、`FolderMixComboLedger`（签名集是唯一一份「已发出」记录）、Floyd 无放回抽样 + **注入种子的 Fisher-Yates 打散**（Floyd 产出升序，不打散就截断 = 系统性偏向每个文件夹开头的素材）、有界补抽、`substitute` 同类替补；旧的 `maxWithoutRepeat` / `FolderMixUsedSet` / `resetCategories` / 游标 / 两级账本 / Feistel 轮函数**一次删净** | `FolderMixPickerTests` 重写 26 条（含 FMX-01/02/02b/03/04/05/06/07/08/11）；`.scratch/fm_mutate_step2.py` N1–N11 → **10/10 咬中**，N7 如实写明「没有可注的刀，是结构性保证」。**新判据抓出三处真缺陷**：① `Array(Set<Int>)` 让「同 seed 同解」（R1）不成立；② `drawMany` 在 3/4 就误报「组合空间已耗尽」；③ `seenHere` 分支不可达（删掉，不写文档糊它）。P7「前缀一致」作废，换成交付的两条契约 FMX-07 + FMX-19；摘标 K8/K9/K12/K13/K15/K16/K17 共 7 把，保留 K10/K14，K11 改判目标（解析后同一个 `Segment` 不许在一行出现两次） |
| 2026-10-21 | **笔 3 会话状态与上限口径 + G-g 加腿**：`FolderMixSessionState.swift`（Core `Codable`：编解码放 Core，App 层只把 JSON 塞 `UserDefaults`；逐键 `decodeIfPresent` —— 非 Optional 即使有默认值也 `keyNotFound`，这是本仓实测坑）、`FolderMixSpaceFingerprint.revision`（FNV-1a 64，把「精确识别」开关算进指纹）、`FolderMixLimits` 每颗常量都带「生效条件 / 拦不住什么 / 最坏代价」 | `FolderMixSessionStateTests` 9 条（FMX-12a-d、FMX-13a-e；三颗 FNV-1a 黄金值手算锁定）。**G-g 加越锚腿**：锚点拆成标识符颗粒 + 按词边界命中（`avi` 不许命中 available）+ 时态豁免（带日期的执行进展行、`〔〕` 里停放的旧读数不核 —— 「勘误不删原文」的必然推论）+ **5 条非恒真自测**（腐烂必红 / 对准必核 / 散文锚点必跳 / 死括注必跳 / 词边界）。同轮修**行号腐烂 46 处**（本台账 25 颗、源码与脚本注释 21 颗），逐颗回源取实读位置。读数：越锚 69 → **0**（带锚点引用核对 84 处）、`DOC CLEAN`；`swift test` → **1272 通过 / 5 known issues**（基线 1257/4）；`check_folder_mix_guards.sh` 17 条 PASS；`selftest_folder_mix_guards.py` 18 把刀逐把咬中且还原回基线；typecheck / silgen / `xcodebuild build` / `build-for-testing` 四腿全 PASS（`.scratch/dd` 已随本轮注释改动重建） |
| 2026-10-21 | **笔 4 候选来源改文件系统 + 两层解析**：`MaterialFolderScanner` 的 `contentsOfDirectory` 加 `.fileSizeKey`，候选形状由「三列平行数组」改成一条值 `FolderMixVideoFile{folder, name, byteSize}`（`videoFileNames`/`videoFolders`/`videoByteSizes` 降为视图 ⇒ 「两列不齐」这种错法在类型上不可表示，`precondition` 从读取处挪到构造处）；新增 Core `FolderMixResolve.swift`（`FolderMixLibraryRecord` / `FolderMixLibrary.duration` / `identityKey` / `FolderMixResolver.plan` / `applyDurations` / `mergedDurations`）；新增 App 两颗探针 `FolderMixDurationReader`（`AVURLAsset.load(.duration)`，走既有 `BoundedTaskGate` + 新加的 `ConcurrencyPolicy.maxProbeConcurrency()` 三件套）与 `FolderMixContentKeyReader`（只吃 `plan.identityProbePaths`）；`computeFileHash` 改 `nonisolated`（否则上千次 8 MB 读盘排在主线程 = 界面卡死）；`DiskSpaceBudget.estimate` 新增「未知时长不计入但逐名报出」 | 判据 16 条：`FolderMixResolveTests` 7（FMX-14/14b/14c/15/16/16b + L4）、`FolderMixScannerTests` S8/S8b/S8c、`DiskSpaceBudgetTests` B6a/B6b/B6c、`FolderMixIngestGuardTests` T-23/T-28/T-29（各带合成正负对照）；FMX-17 **结案**为既有 `BoundedTaskGateTests` BC-3…BC-6，不重写一遍。台架 `.scratch/fm_mutate_step4.py` **11/11 咬中**（R6 第一版写成语法破坏 ⇒ 只报 COMPILE、证明不了判据有牙，改成语义改动后才红在该咬的那条；R3/R10 第一版读到不全的红集合，根因是台架跑旧二进制 —— 改成「先 `swift build --build-tests` 再 `swift test --skip-build`」后才可信）。读数：`swift test` **1288 通过 / 5 known issues**；`check_folder_mix_guards.sh` LANE 扩到 6 颗 App 文件后 17 条 PASS；`selftest_folder_mix_guards.py` 17 把刀逐把咬中且还原回基线（笔 3 那行写的「18 把刀」实为 15 把刀 + 1 条还原自证 = 18 行 OK，本轮起以 KNIVES 清单条数为准）；`check_plan_doc_citations.py` DOC CLEAN；typecheck / silgen PASS；**`xcodebuild build` 首跑 FAIL** —— `register_pbx_file.py` 把三颗新文件挂进了默认模板所在的 `MixCut/Services/TTS` 组（ID 唯一、四段齐全、path 字面全对，`check_pbx_registration.py` 也全绿 ⇒ 只有真机编译暴露），手工归位到 MixCutCore / Services/Import 两组后 build 与 build-for-testing 双 SUCCEEDED；同笔给该工具加「模板必须与新文件同目录」的闸，并跑了一对正负对照（默认模板被拒 / 同目录模板放行），测试条目已撤销且 pbxproj md5 回到改动前 |
| 2026-10-21 | **笔 5 生成期编排（懒入库）+ 状态机下沉 Core**：新增 `Sources/MixCutCore/FolderMixOrchestration.swift`（`FolderMixFailureCode` 七档专属码 + `isSystemic`、`FolderMixResolution`、`FolderMixIngestTask`、`FolderMixGeneratePlanner`）；`ClipIngestService.importClips` 的失败项加 `path` 与 `code` 两颗字段（**短路只按码判，不匹配中文措辞**）；`FolderMixViewModel` 删掉 `runIngest`、生成流水改走 `generate()`（一次算完「抽中集 ∪ 每类余量」→ 只为真被抽中的类别建库 → 按整片段解析 → 同类替补 → 摘行 → 建方案 → 成功才记签名），停止 = 取消探针 + 保留已入库 | 判据 14 条（FMX-18/18b/18c、FMX-19、档 A/B/C、NAMING、覆盖面、替补不回已发、SHORT-1/2、CODES、余量公式）+ `FolderMixIngestGuardTests` 新增 T-22/T-25、**T-26 摘标升成硬闸**（混剪链的 `importVM` 实测归零）；`FolderMixPicker` 公开序号→行的入口让 rehydrate 与 `drawMany` 共用同一份解码（P17 钉住）。台架 `.scratch/fm_mutate_step5.py` **10/10 咬中**：K2 第一版（去掉按 identityKey 去重）**注不出红**——同键的第二条路径在替补过滤下永不可达，改打成「把身份键当路径去拷」才红，为此给 FMX-18 补了 provenance 断言；K6 要**同时**摘掉替补内的账本筛与产出后的复检两层才有读数（只拆一层会被另一层兜住，这是好事）；另修两处台架自身缺陷：分类器把别的套件回显的 `Fatal error:` 字样当崩溃、一把刀不支持多处替换。FMX-20 **结案**给既有三件更硬的（G12 名册 + CR-5 + 真机第 9 步），不造第四份「没有删除动作」的抄本 |
| 2026-10-21 | **笔 6 UI 勾选轴 + 一键式**：左栏每行加勾选（空类可勾但不进乘积）与「全选/全不选」；条数改 `TextField(value:format:.number)` + Stepper（钳位口径收回 VM）；软上限同排可改并被记住；栏注改成「组合总数 ｜ 已发出 ｜ 还能出」并在饱和时**两颗都不报精确数**；超软上限出 danger 预估 + 「我已确认」；页脚四颗收成 主按钮 + 换一换 + 停止，「入库所选类别」这颗**消失**；两颗开关按预览件落在页脚按钮行右侧 | 实测把 G-c 打红过一次：Stepper 里写了 `FolderMixLimits.countInputClamp` ⇒ 判定长在界面层、`swift test` 覆盖不到，随即收回 VM。`check_folder_mix_guards.sh` 17 条 PASS；LANE 由 4 颗扩到 6 颗后 G-h 下限 4 → 6（新增的两处是「解析缺段逐名」与「超量/短路」）。台架 `selftest_folder_mix_guards.py` 第一版报 **VACUOUS**：G-h 那把刀只摘 VM 与扫描器两颗文件，service 与探针里还剩 8 行前缀 ⇒ 门照样绿（**门不是恒真，是刀太窄**，两种读数的修法完全不同），改成逐颗注满五颗文件后咬中 |
| 2026-10-21 | **笔 7 会话状态持久化 + 页面状态提升**：`FolderMixViewModel` 提到 `ContentView`（页面不再用 `@State` 自己持有 —— 那正是「切页再切回就回到 0 类那屏」的成因）；`FolderMixSessionState` 加 `rowOrdinals: [Int]?`（**只存组合序号，不存路径也不存素材对象**），`rehydratableOrdinals(nowRevision:)` 是指纹相符才复用旧行的唯一入口；VM 加快照/落盘/还原，`onAppear` 自动重扫（懒入库下只是两层 `contentsOfDirectory`），目录失效时**保留**用户的排列与勾选并出红字让他重选 | 判据：FMX-12e（上一轮的老 JSON 缺 `rowOrdinals` 这颗键 ⇒ 必须解成 nil，不崩也不折成空数组）、FMX-12a/b 的键数与逐颗删键两轮跑到 9 颗键。还原路径**不自己裸问 `FileManager.fileExists`**：目录能不能读由 IO 面 `MaterialFolderScanner` 报 `rootError`，第一版在那儿多出一颗裸问站点、被 `MediaAvailabilityGuardTests` G-M01 的名册判据当场抓红（改的是代码，名册未动）。`swift test` → **1306 通过 / 4 known issues**（红钉摘掉一颗）；typecheck PASS、silgen PASS、`xcodebuild build` 与 `build-for-testing` 双 SUCCEEDED；`DOC CLEAN`、pbx 123 颗全登记 |
| 2026-10-21 | **笔 8 守卫与台账收口**：决议台账补 **D23–D38**（16 条）并把 D1/D3/D9/D12/D13/D16/D22 标〔已修订 2026-10-21〕留原文；修订记录补 **R25–R50**（26 条，含评审链四条、覆盖率轮四条、预览件轮两条与本轮实现期十六条）；第六节换成**第二轮 13 步真机清单**（第一轮的 1–11 条原文保留并标出 3/4/5 条口径已被取代）；第九节失败分档扩到 15 行（超量未确认 / 环境级短路 / 档 A/B/C / 时长读不出 / 校验和读不出 / 目录失效 / 停止）；第十一节补 9 条不做项与 3 条结案件；第十二节补记门数 12→19 与四处名册同笔改口的教训；〇 取证状态表计数改口（R1–R50 五十条、判据 123 条、门 17 道、刀数逐支登记） | 台架收口时发现**刀自己先腐烂了三处**（这正是 SKIP 状态存在的意义）：1a 的 K1/K3 锚点没跟上笔 1b 之后适配层的 `self.` 与 `count` 形状 ⇒ 命中 0 次；step1 的 K3/K4 锚点随 S8 改写失效 ⇒ 重钉，K10/K11/K14 三把按摘标名册删出清单并在文件头写明接手的是 step2-N5 / step5-K4 / step5-K7（留着只会每轮报 SKIP，噪声会把真没咬中的刀混过去）；step5 的 K3 拆的是「哪些素材不可用」这一**整族**判定，哪条先红取决于套件跑到哪儿 ⇒ 期望值从钉死一条改成给一族。复跑读数：`fm_mutate_1a.py` 3/3、`step1` **17/17**、`step2` 10/10、`step4` 11/11、`step5` 10/10、`selftest_folder_mix_guards.py` 17 把逐把咬住自己那道门且还原回基线；`check_folder_mix_guards.sh` 17 道 PASS；`check_plan_doc_citations.py` DOC CLEAN（表格 15 张 / 数据行 218、越锚 0）；`check_pbx_registration.py` 123 颗全登记；`swift test` **1306 通过 / 4 known issues**；typecheck / silgen / `xcodebuild build` / `build-for-testing` 四项 PASS。**本轮未做**：真机端到端 13 步、`xcodebuild test`（会拉起宿主实例并占 8787）、以及任何提交（本仓全部改动仍未提交，HEAD 仍是 `4ac5704`） |
| 2026-10-22 | **join 键修复笔 J1–J3 落地**（计划 2026-10-22 那份，方案经两轮评审改判：初版选的「按文件名反查」被分界判据 JOIN-7 否掉，改成「入库当场交回对应关系」）：Core 加 `FolderMixIngestedRow`/`FolderMixRowShape`/`FolderMixJoinOutcome`/`FolderMixLibraryJoin` + 新码 `notIngested` + `shortfallText`；解析期那两处跨域猜键删除；扫描期时长层降级为「只服务预估」的名字启发式（`FolderMixNameHeuristic`，H1–H3）；摘行红字按（档, 类别）聚合成一句；服务两支各交回一次对应关系并成对登记进 CR 名册（13→15 处） | 读数：`swift test` **1324 通过 / 4 known issues**（混剪族 123→141）；`check_folder_mix_guards.sh` 17 道 PASS、`selftest_folder_mix_guards.py` 17 把全咬；新台架 `.scratch/fm_mutate_stepJ.py` **12 把全咬中**且还原 md5 自证；门 T-30（A/B1/B2/C 四条腿）+ T-31 落地并各配正对照；App 腿 `MixCutAppTests/FolderMixIngestJoinTests.swift` 2 条编译进 target（`build-for-testing` PASS），**跑由用户执行**；typecheck / silgen / build / build-for-testing 四项 PASS，`.scratch/dd` 已重建；两份计划文档 DOC CLEAN；`check_pbx_registration.py` 128 颗全登记。**本轮未做**：真机三条分支腿（同一份「蓝莓拆分」目录仅关联支 / 新建整片段支 / 同内容不同名支）+ 反向确认；`xcodebuild test`；`check_mcp_api_guards.sh` 被环境挡住（端口 8787 被用户开着的 SunCut 占住，pid 实测在跑 —— 按纪律不杀用户实例）；以及任何提交（HEAD 仍是 `4ac5704`） |

## 九、失败模式分档（每条定档 + 指定报告通道）

触发面：新增校验/清洗/批量处理/外部依赖调用。禁"整批因单条失败静默中止"，禁"全部降级为警告而无拒绝档"。

| 失败模式 | 档位 | 报告通道 | 验收要求 |
|---|---|---|---|
| 某类别 0 可用素材（全非视频 / 全重复 / 读不出时长） | **放行 + 标记**（D13） | 预览卡 ∅ 占位 + 面包屑「不重复上限」读数 + `MixLog.info` | 判据须覆盖"标记被下游消费"（上限计算要排除它） |
| 用户设定的 N > 不重复上限 | **拒绝**（阻断 + 错误文案） | 步进器就地红字，不落库、不建方案 | E2E 必验拒绝态；纯函数层 R8 返回硬错误而非截断 |
| 超软上限（默认 50）而用户没勾「我已确认」 | **拒绝**（档 F：主按钮禁用 + danger 预估） | 页脚红字「将新建约 X 的素材文件、产出 N 个方案、导出后另占约 Y」+ 那颗勾选 | 数字全走 `DiskSpaceBudget`；不写耗时（仓内无实测带宽真源）。判据：`canCreate` 与界面禁用同一条口径（G-c） |
| 抽中的素材入库失败（拷盘/建库那步报错） | **同类替补**（档 A）；替不动才摘行 | 逐名进 `ingestFailures`（页脚列前 3 个）+ `droppedRows` 的原因句带档名（〔2026-10-22 改口〕这句不再兜底——过去「没找到」也被它顶掉，归因就指错了磁盘） | FMX-18/档 A 判据；错误码由 service 结构化给出，**不许字符串匹配** |
| 入库报成功、但交回的对应关系里没有这一条 | **同类替补**（档 B2，专属码 `notIngested`） | 一句聚合红字「N 条（类别）：入库后没找到这条素材」+ 日志 `[FolderMix] 对接：…没找到 k` | JOIN-4 判据 + 台架 K4；一档一码（FMX-09），不许复用 `ingestFailed` —— 真机 50 条全摘那次就是被顶掉的归因骗的 |
| 素材在库里但没有任何一条覆盖整片的段 | **先补建，补不动才同类替补**（档 B，专属码 `noWholeClipSegment`） | 补建成功 ⇒ 只进日志与状态行「本轮自动补建 k 条整片段（不进分镜素材库）」；补不上 ⇒ 一句「这条素材此前按分镜导入、整片直拼要的那条覆盖全片的段没补上」 | 〔已改判 2026-10-22 第三轮，决议 K2 甲-隐 / K3〕原文这一格写的是「T-25 钉绝不替它补建整片段——那是母体导入的语义，不是混剪的」；现场读数「无整片段 24 / 交回 32 = 75%」证明这条界线让用户主力素材整片用不了 ⇒ T-25 从「绝对不许」改成「只许长在入库真身那两处，且第二处必须带标记与两道守门」。细则与判据在 `docs/superpowers/plans/2026-10-22-folder-mix-drawn-set-and-wholeclip.md` 第五节笔 K2 |
| 库内那一行的拷贝文件已不在盘上 | **不许进方案**（档 B0，专属码 `materialMissing`）；判据本身不可信时整批停手 | 一句「素材文件已不在盘上」＋ 日志 `[FolderMix] 对接：… 文件缺失 m`；查不了时另有一句「本轮查不了，未生成方案」 | 决议 K6/K7。混剪直调那颗唯一判定本体（界面与启动对账同一颗），不读共享集、不新建第二个持有者；真机现场那 163 行此前混剪完全看不见 ⇒ 会建出「导得出、坏在后面」的方案 |
| 一行里两段解析到同一素材（只在精确档可达） | **替补一次，仍撞则摘行**（档 C） | `droppedRows` 点名类别 + 界面脚注 | 档 C 判据（`FolderMixOrchestrationTests`）+ K4 那把刀 |
| 连续 3 条**同因**环境级失败（磁盘满 / 无权限 / 读不出） | **整批停手**（不再替补、不再拷盘，已入库的保留） | 一条 error 红字说明"这是环境级故障"，日志 `[FolderMix] 环境级短路 code=…` | SHORT-1/SHORT-2 判据：换因即重置、`.other` 永不参与短路 |
| 时长探针读不出（损坏 / 格式不支持 / 扫描后被移走） | **留未知**：卡片显示「—」，不计入磁盘预估但逐名计数 | 界面脚注「有 k 段时长没读到」+ 日志逐名 `时长读不出：<path>` | 决定 6：0 秒与"不知道"是两件事。判据 FMX-15/B6a/b/c |
| 校验和读不出（精确档） | **给它独占一键**（`unreadable:<path>`），不退回路径、不并入任何素材 | 日志逐名 + 类别行仍在 | 退回路径会让它与另一颗同内容素材并键 ⇒ 用户以为开关生效，实际那一格是猜的 |
| 还原会话时目录读不到（外接盘被拔 / 改名 / 权限） | **保留用户选择 + 红字让他重选**（不清排列与勾选） | `errorMessage` 两行：读不到的原因 + 「你的类别顺序与勾选都还在」 | 目录可读性只由 IO 面报（`rootError`），VM 不自己裸问 `fileExists`（G-M01 名册） |
| 用户在入库/探针途中点「停止」 | **停止 ≠ 删除**（档 G）：已入库与已建项目保留，未建方案不出现 | statusText 明说 + 日志 `[FolderMix] 用户停止` | FMX-20 结案给既有三件：G12 真删名册 + CR-5（service 零 delete）+ 真机第 9 步 |
| 单文件读不出时长（损坏/格式不支持） | **放行 + 标记**，逐文件名上报 | 沿用 `importSelfSegments` 既有硬规则：`failedUnreadable` 非空必须 toast 且列前 3 个文件名（`ImportViewModel.swift:582-583`） | 判据：不得回到"静默 continue 让文件凭空消失" |
| 落盘失败（磁盘满 / 无权限 / 外接盘拔出） | **放行 + 标记**，该类候选减少 | 同上 `failedCopy` 通道（`:562`）；开工前 `DiskSpaceBudget` 预检报总量 | 预检读数与实际拷贝失败数须可对账 |
| **`computeFileHash` 返回 nil**（IO 抖动 / 内存压力） | **拒绝该文件**（不再退 UUID 目录名） | 走 `failedUnreadable` 同型通道，逐文件名 + 原因上报 | ⚠ 现状是 `:426-429` 用 UUID 当目录名继续入库，**并且跳过 `:412` 的去重分支** ⇒ 去重整体失效，同一文件会重复入库成多行 Video、各带一条整片段，把 D3 的"不回放"直接击穿。C 一次几十条 ⇒ 命中概率被放大。判据：`Videos/<uuid>/` 形态的行数必须恒为 0 |
| 抽片中该类别 used 已耗尽 | **放行 + 标记**（R3 自动重置并回报 `resetCategories`） | 预览卡标「该类已循环，第 k 条起会与前几条重复」 | 必验"重置后确实允许重复"且界面不假装还是新的 |
| 建方案时 `createCustomScheme` 返回 nil | **拒绝**（整批中止 + 原因） | `errorMessage` 已有先例（`SchemeViewModel.swift:961` 「数据存储未就绪，请重启应用后重试」/ `:965` 「没有选中任何分镜，无法组合为方案」） | 不得留半批方案：要么 N 个要么 0 个 |
| 导出时素材文件已不在盘上 | **拒绝**（Step 7 改造后） | 从"静默 continue"改为"计划 N 段/实得 M 段"显式失败 | 必验拒绝态与"少段"文案；旧行为作为反面对照 |
| 扫描中途用户取消 / 外接盘拔出 | **拒绝 + 保留已完成部分** | 新写检查点，收尾走 `finishAsCancelled` 先例（`:82-92`） | 必验"停止 ≠ 删除"，已建项目与已入库素材保留 |
| **子目录是符号链接 / 替身**（`contentsOfDirectory` 会把 symlink 目录当子项返回） | **拒绝该类别** + 逐名上报 | 扫描结果区标灰写明"是替身，未跟随" | 一个指向外部大库的替身就能让"只扫一级"变成无底洞；成环时更不能静默递归。判据须覆盖"symlink 目录不产生候选" |
| **扫描后、入库前文件被移走/删除**（与 `copyItem` 抛错是两条链路） | **放行 + 标记**，该类候选减少 | 归到 `failedCopy` 同型通道，但原因文案要区分"文件不见了"与"拷贝失败" | 必验：候选数与最终入库数差额有逐名解释，不静默 |
| **两个文件夹 trim 后同名**（Finder 里看不见的尾随空格） | **放行 + 合并**，但必须出声 | 扫描结果显示"2 个文件夹归为 1 个类别：A、A␣" | 静默合并会让用户以为少了一个类别；`createProject:216` 的 trim 是既有行为，本期不改口径，只加提示 |

## 十、二阶效应 · 歧义 · 未知

**二阶效应（触发链 + 观察指标 + 兜底）**

1. **（丁案自带，最重的一条）C 把载体 `status` 收成 `.completed` ⇒ 同一文件日后走母体导入会被静默判为"已分析"**。触发链：`importOrLinkVideo:418` 的 `needsAnalysis = status != .completed || segments.isEmpty` ⇒ C 留下的状态是 `.completed` + 恰好 1 条整片 Segment ⇒ 两个条件都判"不需要分析" ⇒ 阶段 2 整段跳过 ⇒ 用户后来在「素材导入」里正常导入这个文件时，拿到的是**一条覆盖整片的粗分镜**，而不是镜头检测+ASR+AI 的结果，且界面不会给任何提示。观察指标：同一 hash 的文件先走混剪、再走母体导入，看分镜数是否为 1。兜底见下方 **P-2（待拍）**。
2. C 的"同素材跨类别"是常规路径 ⇒ `ProjectVideo.associate` 的幂等分支大量触发，而它把正常路径记成 `MixLog.error`（`Models/ProjectVideo.swift:31-39`）⇒ 日志一片红且误导后续取证（已有先例 `2026-10-03…:48`）。观察：单次扫描后该条日志计数。兜底：同笔降为 info + 判据。
3. 「不回放」的 `used` 只活内存 ⇒ 用户重启 App 后看到"重复的素材"却界面写着"不再回放" ⇒ 信任损失。兜底：R7 文案收敛为"本次会话内"。
4. 汇总项目跨项目引用分镜 ⇒ 删任一模块项目都波及它（风险 4）⇒ 若不做 Step 7，掉槽只在导出结果里显形。已列为必须做。

**歧义清单（已声明假定 / 待澄清）**

- 「可用素材数」的口径 = *入库成功且能整片拼接的 Segment 数*，不是文件系统的文件数（假定已声明；证伪条件：若用户期望"扫到几个文件就算几个"，P-1 甲乙之争会改变结论）。
- 「不重复上限」是否把空类别算进 min：本档定为**排除空类别后取 min**（与 D13 不阻断一致）。若你要的是"有空类别就直接不能出片"，那是 D13 改判，需回炉。
- **P-2 → 〔已拍：乙，2026-10-20〕** `Video.status` 现在同时充当**分析进度**与**分析完成**两种语义（`:418` 拿它当"已分析"的代理判据），C 需要"整片已就绪、但从未被分析"的第三态。定乙：给 `VideoStatus`（`Models/Video.swift:5-13`，`String, Codable, CaseIterable`，现 7 个 case）加一个终态 `.wholeClipReady = "whole_clip_ready"`。
  - **乙的前置守卫（必做，否则乙的核心论据不成立）**：实测 `VideoStatus` 的 6 处 switch 里**只有 2 处是穷尽的**——`ImportView.swift:1393`（标签，`switch status` 起 7 case 无 default）与 `:1403`（颜色，无 default）会被编译器抓到；而 `:529`（`default: return false`）、`:1084`（`default: return ""`）、`:1381`（`default: return "gearshape.2.fill"`）、`MixCutApp.swift:838-847`（带 default）**会静默吞掉新态**。⇒ "Swift 穷尽 switch 帮你找齐消费点"这句话只对 2/6 成立，必须配 Step 6 的 G-f 守卫补其余 4 处。
  - 另注：`ProjectOverviewView.swift:274/286` 与 `ShotEditSheet.swift:396` 是 `Project.status` / `ShotVariant.status`，与本案无关，别误算进影响面。
  - 反选记录：甲（留 `.imported` + 改 `canShowRetry`）会把问题推给一条未验证的重复建段路径（见未知清单）；丙（接受污染并写成产品语义）需新增用户可见规则。
  - **松绑声明**：乙与 D1「零新模型」的精神差一格，已按你的"按推荐"授权记为 **D19**；它是**状态语义**扩展而非分类模型，且加 case 不动既有 rawValue 顺序 ⇒ 存量数据零迁移。

**未知清单（还缺什么信息 + 闭合方式 + 对决策的影响）**

| 缺什么 | 指向 | 闭合方式 | 未闭合的影响 |
|---|---|---|---|
| ~~`commitWholeVideo` 对 >30s、以及"无台词"Segment 是否有隐含假设~~ **〔已闭合 2026-10-20 Step 2〕** | `SegmentCommitter.swift:161-165` 的注释只说了 `textSource` 不设 | 读全函数（`:166-181`）闭合：对 >30s **无**假设（它只按 `video.duration × fps` 算帧），对无台词**无**假设（`text: ""` 是默认形态）。**但它对"被重复调用"没有防护** —— 函数体里没有任何"已有整片段"的检查，每次调用都 `context.insert` 一条新段 | ⇒ 丁案成立，撤销条件不触发；代价是**守门移到调用方**：`importClipsWithoutAnalysis` 里 `if video.segments.isEmpty` 才建段（否则重扫同一目录会给同一素材叠两条整片段，混剪就会出现"同一素材的两个副本"）。这条已写进函数自己的 doc 注释 |
| ~~`analyzeVideo` 对"已有一条整片 Segment"的视频会不会重复建段 / 覆盖~~ **〔已闭合 2026-10-20：会混存〕** | 〔旧读数 2026-10-20：`ImportViewModel.swift:634-639` 传 `clearsExistingSegments: false`〕〔2026-10-21 现状：该处已改为传形状判据〕`ImportViewModel.swift:723-728` 的 `WholeClipShape.isWholeClip(...)`，`:782/:819` 据此决定删不删旧段 | 实读闭合（见 R14 与 Step 2 的 P0-1 块）；仍需一条夹具判据钉成回归防线（结构钉 T-15 已生成；行为夹具待 Step 2 同笔） | 不再是未知；D19 的修法已定 |
| 非宽限期 11 行直删是否覆盖"删模块项目"这条链 | `2026-10-03…md` v1.10 明写该 11 行 ❌ | grep 删除链 + 真机删一个模块项目看广播是否到 `notePrunedSegments` | Step 7 第 1 条能否成立；不成立则要先补广播，Step 7 升为两笔 |
| `VariantBatchExportService` 是否接受"整片 concat"型 job | 其 `VariantExportJob` 只有 `.original(cutSegment)` 与 `.variant(dub)` 两形 | 读 enum 定义 | D17 只到方案 ⇒ 本步不改导出，影响仅为"将来若要直出"的成本估计 |
| 用户素材目录的真实规模（文件数/总字节） | 用户机器上的目录 | 请用户给一条 `du -sh` + `find -maxdepth 2 -type d` 读数 | 决定 `DiskSpaceBudget` 的预检阈值与是否需要分批；当前按"几十条、GB 级"假定 |

## 十一、明确不做（含"什么条件下要重开"）

写这一节是因为：不写，将来它们会被当成缺陷提回来；写了，就是边界而不是遗漏。

| 不做项 | 为什么不做 | 重开条件 |
|---|---|---|
| 跨会话的"不回放"持久化 | `used` 只在 `FolderMixViewModel` 内存（D3 作用域），持久化要一张已用台账表 = 新模型，与 D1「零新模型」冲突 | 用户明确说"我隔天再抽还是那几条，烦" —— 即把 D3 的作用域本身改判 |
| 把文件夹混剪暴露成 MCP 工具 | 现 24 工具面（`AgentToolCatalog.swift:57-183`）不含它；要暴露就得把 D20 的 source、D22 的 per-draw used 变成工具入参，且 Step 7 已证明 MCP 是**对外契约面**，动它成本高于收益 | 有真实的 Agent 驱动需求（例如要批量出片自动化）；届时先定工具入参形状再动 |
| 一键直出 mp4 | D17 已拍"只到方案"；导出仍走「导出」页勾选 | 用户明确说"我不想再点一次导出" |
| 给 C 的素材补语义标签/台词 | D8 已拍全跳过；补标要跑 ASR+AI，正撞"零网络零算力"这条 | 用户想用配音或按语义筛选这批素材 —— 那时应引导走「素材导入」的正常分析链（配合 R14 的修法，两条链已能共存） |
| 给「在库但没有整片段」的素材补建一条整片段 | 那是母体导入的分镜语义，混剪替它补 = 造出没被任何复核过的段，导出照拼不误 | 母体链的整片段语义变更，且带一条"补出来的段形状对得上 `WholeClipShape`"的行为判据 |
| 在默认路径上做全量或头尾校验和 | 默认档要求"选完目录立刻看到组合总数"，而校验和是 ≈8 MB/条的读盘 ⇒ 大目录开局就卡住 | 用户显式打开「精确识别（慢）」（本期已做），且成本写进旁注 |
| 为了凑满条数而放宽组合级不重复 | 放宽后用户拿到的是"看着不同、搭配重复"的方案，比少几条更糟 | 不重开。宁可摘行并报「计划 N / 实得 M」 |
| 治 `ImportViewModel` 的多实例本身 | 实测 4 颗（`ContentView.swift:97` / `AgentGateway.swift:15` / `SegmentLibraryView.swift:23` / `DebugSelfTest.swift:493`）；本轮只把**混剪这条通路**从 UI 状态宿主上解绑，多实例是既有结构 | 另案：统一 VM 生命周期时一起处理（别当本轮缺陷提回来） |
| 持久化签名账本（跨批不重复） | 「已发出」按 D3 的作用域只在本次会话；持久化它是 ~10⁶ 条元组的量（软上限可调到 999_999），`FolderMixLimits.maxPersistedSignatures = 20_000` 是为此立的规则 | 用户明确要"重启后也别重复审过的搭配" ⇒ 只存 `spaceRevision` + 签名上限内截断，并在页面明说"重启后跨批不重复失效" |
| 「完全不入库」的虚拟 Segment 通路 | 硬约束判死：方案必须指向库里的 `Segment` 行（`SchemeViewModel.createCustomScheme(from: [Segment], …)` → `ExportInput.from(scheme:)` 顺 `segment.video…videoPath` 找文件），没有虚拟段这条路 | 导出侧出现可寻址非库对象的通路时才谈 |
| 引入 property-based 测试框架 | 小空间穷举 + 桶覆盖 + 同 seed 复现三件已达同效（FMX-01/03/05）；引第三方依赖要过引入前审查并改 `swift test` 链 | **结案件**，不是待评估 |
| 把 `.scratch/` 的 Core 变异刀迁进 `scripts/` | 一迁就把每次跑门的成本抬成「全量 `swift test` × 刀数」 | **结案件**：代价改由本台账逐轮登记读数（换机即丢这件事如实认了） |
| 自己重写一套探针并发闸 / 取消语义 | `BoundedTaskGate` 已有 FIFO 许可、`cancelAll`、`inFlightCount` 与整套判据（BC-3…BC-6）；再造一份 = 把证过的换成没证的 ⇒ FMX-17 结案为引用既有判据 | 若探针需要与配音不同的调度语义（如按字节预算），在闸外套策略层，不改闸 |
| 类别作为第四条标签轴 | D1 选了"文件夹=Project"，加轴要新模型 + 迁移 + 每处筛选逻辑认它 | 出现"同一素材要同时属于两个并列分类体系"的真实需求（当前由 `ProjectVideo` 多对多承担） |
| 一屏并排看完 N 条 | D15 钉死 900×600 零溢出，靠 A11 翻页压高度 | 要么放弃 D15 的高度约束，要么加分页/列表视图 —— 二者只能选一个 |
| 修 Mac2 黑盒 UI 自动化环 | 它不是本功能的前置，只是让验收第 11 条能机器化 | 需要把"版面不滚动"从人工目测升级为判据时（两条 P0：假库开关 DEBUG-only、MCP 端口硬绑） |

## 十二、结构判据自身的审查（`FolderMixIngestGuardTests`）

判据的价值在于不可绕过，所以对它做的不是代码风格审查，而是**构造反例攻击**。8 例反例全部按预期出结果（Python 复跑同一条 ICU 正则），下面每条漏口都是实测。

| # | 反例形态 | 结果 | 定级 |
|---|---|---|---|
| 1 | `importOrLinkVideo(url, to: project, source: pendingBatchSource)`（把隐式状态**当参数转发**） | **漏检** ⇒ 而 Step 2 正是要新增第二个调用方 | **严重** |
| 2 | `let shouldClear = false` + `clearsExistingSegments: shouldClear` | 漏检（文本扫描固有上限） | 警告 |
| 3 | `let fb = UUID().uuidString` + `contentHash: hash ?? fb` | 漏检（同上） | 警告 |
| 4 | 收紧成 `[:=]\s*pendingBatchSource\b` 后，真文件命中数 | **仍恰好 1 处（`:437`）**，`:51` 声明与 `:103` 反向赋值都不误报 ⇒ xfail 仍只记 1 条 known issue | 已验证可安全收紧 |

### 待办状态（本轮已落 5 条，全部真跑取证）

| 编号 | 动作 | 状态 | 取证 |
|---|---|---|---|
| G-1 | T-16 正则收紧为 `[:=]\s*pendingBatchSource\b` | ✅ 已落 | xfail 仍只记 1 条 known issue，命中 `:437` 一处 ⇒ 零新增假阳性 |
| G-2 | 文件头补「已知绕法」声明（4 类：命名常量 / 局部变量 / 换函数名 / 跨文件） | ✅ 已落 | 头部新增段落，并写明"真正兜底是行为判据" |
| G-3 | 扫描面改**名册对账** | ✅ 已落成 T-20 | 实测 `copyVideoToGlobal(` 落在 2 个文件：定义处 `FileHelper.swift` + 3 处调用的 `ImportViewModel.swift`。⚠ 名册**必须含定义处**，否则 T-20 假红（本轮就这么错过一次） |
| G-4 | 防剥离器失步的守卫 | ✅ 已落成「尾部未被吞」 | 取文件末 40 行里最长的标识符做探针，断言它仍在剥离结果里 ⇒ 比"长度比例"更直接，且不受注释密度影响 |
| G-5 | 命中项带行号 | ✅ 已落 | 扫描时同步维护"字符 → 源行号"映射；实测读数 `:428` / `:501` / `:437` / `:634` |
| G-6 | `codeOnly` 抽成仓内共用工具 | ⏸ 挂起（YAGNI） | 现在只有本文件用；第四条判据族出现时再抽 |

**〔第二轮补记 2026-10-21〕这一族从 12 条涨到 19 条**：新增 T-22（候选账本只由一处重建，且任何路径都不许把它清空 —— 用户报的那条「入库中止把左栏全变无候选」在派生视图这个形状里写不出来）、T-23（校验和读取器只许吃 `plan.identityProbePaths`）、T-25（混剪链不许成为 `commitWholeVideo(` 的第三个调用方）、T-26（混剪链的 `importVM` 归零，红钉已摘成硬闸）、T-27（`func computeFileHash` 全仓恰好 1 处）、T-28（探针不许新造第二套并发闸）、T-29（IO 面必须请求 `.fileSizeKey` —— 字节数是懒入库预算的唯一来源）。T-24 的真身仍在 `ClipIngestReadoutCharacterizationTests.CR-5`（同一判据只留唯一承载文件，这里只留指针）。
名册类改动同笔落地的有四处：T 族扫描面由一颗文件改名册（ImportViewModel + ClipIngestService）、T-20 调用名册 +1 颗、`TombstoneReadGuardTests` 每文件删除数成对改（全仓 54 不变）、`MediaAvailabilityGuardTests` 每文件计数与 `LANE` 扩面。**踩到的一次红点归因教训**：还原会话时我多写了一颗裸 `fileExists`，被 G-M01 当场判红 —— 名册的价值就在这类"合法但没人登记"的生长上，改代码而不是改名册是那次正确的选择。

**新增判据 T-19（钉住 ④ 的承重前提）**：`asrSentencesData` 全仓写入点必须恰好 1 处、且从不被写成 `nil`。④ 能区分 C 与母体链，全部依据就是"母体链无论 ASR 成败都会写非 nil"——一旦将来有人"顺手清理"加一处 `asrSentencesData = nil`，形状判据会**静默误判**且没有任何其它地方会报。这条今天绿，且要一直绿。

**这条判据族最有价值的部分**：「对照·阴性」真的失败过一次，抓出我用了 `[^;]*?` 收尾——那是"语句以分号分隔"的假设，**Swift 不用分号**，于是正则越过 `)` 吃到下一条语句，把修好后的代码也报成命中。没有那对阴性对照，这枚红钉修完也摘不掉。

