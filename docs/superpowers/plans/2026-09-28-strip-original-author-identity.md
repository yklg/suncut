# 清除原作者身份残留 · 实施计划 v4（2026-09-28，测试覆盖修订版 · 待复审）

目标：把 App **运行态可见**的原作者身份全部清掉，彻底移除会把用户导向原版的更新检查，
并且**不留任何悬空指引**（v2 被 `architecture-first-fix` 判为「需返工」：根因层级不过、扩展性不过）。

> **v3 相对 v2 的三处变化**：新增 §2.2（错误文案悬空指引处置，P0-A）、新增 §2.3（把"不跑生成器"从纪律变机制，P0-B）、
> §3/§4 补结构完整性与文案判据。§1 的 pbxproj 定性结论原样保留。
>
> **v4 相对 v3 的变化**：新增 **§8 测试与守卫层**（按 `test-coverage-expander` 做覆盖差距分析后的产物）——
> §3 第 9 步从裸 `xcodebuild -list` 换成可复用的守卫脚本，§4 的判据改为"有机械判据的走脚本、没有的明确标人工"。
> **v4 只加文档，测试代码尚未生成**（§8.5 待你确认后生成）。

## 0. 已定事项

- 清理范围 = **A 三处全删**（不换成你的信息，不留原版更新提示）
- 工程文件处理 = **备选 2**：删 `UpdateChecker.swift` 源文件 **+ 手工删 pbxproj 那 7 条引用**
- **禁令：全程不跑 `generate_xcodeproj.py`**，且 v3 把这条禁令落成代码守卫（§2.3）
- 被否方案留档：**B** 换成你的联系方式（要三个字符串，改 6 个位置，填错就是把别人的号留给用户）；
  **C** 只断原版链接、保留原作者微信（用户会加错人）

## 1. 背景与禁令依据（v1 §3 第 4 步作废的完整证据）

v1 原写「删文件后重跑 `python3 generate_xcodeproj.py` 生成 pbxproj，手撕会被下次生成覆盖」。**方向说反了**：

- 重跑一次，pbxproj 的 swift 唯一引用 **129 → 92**、`in Sources` **256 → 184**，少 **36 个文件**：
  `MCPProtocol` `AgentToolCatalog` `SentenceTimingAligner` `CaptionRenderer` `ParaformerASR` `DubStaleness` `HTTPRequestParser` 等。
- 这 36 个**都在盘上**（`Sources/MixCutCore/`），且原本**直接编进 App target**。三条证据：
  1. fileRef 写 `path = Sources/MixCutCore/xxx.swift`（`grep -c 'path = Sources/MixCutCore'` = 35），且在 App 的 Sources build phase 里
  2. App 源码 `import MixCutCore` 出现 **0 次**（同 target 扁平编译，本就不需要 import）
  3. `Package.swift` 注释自陈「App target 通过 xcodeproj 直接编译 `Sources/MixCutCore/*.swift`（同模块，无需 import）」，Package 只服务 `swift test`
- 生成器 `SRC = os.path.join(ROOT, "MixCut")`（`generate_xcodeproj.py:14`）不扫 `Sources/`
  → 重生成 = 这 36 个文件被移出编译而 App 无 import → **`cannot find type` 编译期直接失败**。
- **根因**：这份 pbxproj = 生成器输出 **+ 手工追加 36 条**（ID 形状 `0FA1B2C3D4E5F60718293A4B/C`、`2DEF5175904C2A272B9CDE44`
  是人工递增 hex，而生成器 `make_id()` 是 `md5(name)[:24].upper()`）。
  ⇒ **pbxproj 现在是手工维护的权威件，生成器已与它脱钩。**

## 2. 改动清单

### 2.1 Swift 源码删除（3 个文件）

| 文件 | 删什么 | 注意 |
|---|---|---|
| `MixCut/App/ContentView.swift` | `:42` `@State updateChecker`、`:53-54` 注释 + `UpdateBanner(viewModel:)`、`:86` `updateChecker.checkSilently()` | `:120` 收尾注释 `// close VStack (UpdateBanner + HStack)` → `// close VStack` |
| `MixCut/Views/Sidebar/SidebarView.swift` | `:16-18` 三个微信 `@State`、`:20-21` 注释 + `weChatID`、`:83-117` 侧边栏微信区块、`:337-363` `weChatCard`、`:365-372` `copyWeChatID()` | **保留** `:81` 的 `Divider()`（分隔导航区与底部「设置」）；删 `weChatCard` 时锚点不能吞掉后面的 `private var newProjectButton` 声明头 |
| `MixCut/Views/Settings/SettingsView.swift` | `:466-478` 三个 `LabeledContent`（原作者姓名 / 手机号 / GitHub 账号） | 删后 `Section("关于")` 仍剩使用引导 + 键盘快捷键，结构完整 |

### 2.2 【P0-A】错误文案的悬空指引处置（v2 漏掉，评审新增）

**这是 P0，不是可选**：v2 删掉微信入口后，App 里**唯一的"出问题该找谁"去处**消失，而两条**用户出错时才会看到**的文案仍在承诺它。

- `MixCut/Services/VideoProcessing/FFmpegRunner.swift:59`：「视频处理失败。请重试；若反复失败，**请到设置中导出诊断日志反馈**（错误码 X）。」
- `MixCut/Utilities/ModelContextExtension.swift:28`：toast「\(whatFailed)保存失败，改动可能在重启后丢失。请重试或**导出诊断日志反馈**。」

**取证（v3 新查，比评审时更严重）**：`导出诊断日志` 这个动作**在 App 里从来不存在** ——
全仓 grep 无任何实现；`SettingsView.swift:348-361` 那个按钮是「在 Finder 中打开」，指向 `FileHelper.appSupportDirectory`（Application Support），
而日志实际写在 `~/Library/Caches/com.mixcut.app/logs/mixcut.log`（`OpenAICompatibleClient.swift:5-14`）。
**即文案在 v2 之前就已经是悬空指令**（既无导出功能，目录也不对），原作者的微信号是它唯一的人工兜底。删入口 = 抽掉兜底。

处置（最小且不引新耦合）：

1. 在 `MixLog` 上开一个 `static let logFileURL`（`logPath` 现在是 `private static`，`OpenAICompatibleClient.swift:5`），
   把已有形状收敛成单一来源 —— **不要再硬编码一份路径字符串**（那正是本次要治的"字面量散落"同一根因）。
2. 两条文案改为指向真实可执行动作，与 `ASRService.swift:948` 已有的正确形状看齐（那条就写了真实日志路径）：
   - `FFmpegRunner.swift:59` → 「视频处理失败。请重试；若反复失败，日志见 `\(MixLog.logFileURL.path)`（错误码 X）。」
   - `ModelContextExtension.swift:28` → 「…请重试；日志见 `\(MixLog.logFileURL.path)`」
   - 顺带把 `ASRService.swift:948` 里那份硬编码的 `~/Library/Caches/com.mixcut.app/logs/mixcut.log` 换成同一 accessor（3 处收敛为 1 处）
3. `ASRService.swift:948` 的替换属于同一接缝、零行为变化，一并做；**不做**"新增导出日志按钮"（→ §5 P1）。

**注意**：日志路径含 `com.mixcut.app`，与改名计划的 bundle id 议题耦合。此处按**现状字符串**输出真实路径即可，
改名时再统一换 —— 别在 v3 里顺手改目录，那是 §5 的另案范围。

### 2.3 【P0-B】把"不跑生成器"从纪律变机制（v2 只有纪律，评审判为半遮盖）

v2 写"我不跑"是把系统性缺陷降格成个人纪律 —— 而仓库里有一份**活着的计划**正在指导下一个人跑它：
`docs/superpowers/plans/2026-09-28-rebrand-app-name-icon.md:19`（「pbxproj 是它生成的，手改会被下次生成覆盖」，与实测方向相反）、
`:40`（第 2 步「重新生成 `project.pbxproj` → 校验 93+35 个源文件引用数不变」，按 §1 实测这条永远过不了）。

处置：

1. `generate_xcodeproj.py` 在收集源文件之前（约 `:38`，`swift_files = []` 那行上方）加**硬失败守卫**：
   若 `Sources/MixCutCore/` 存在且含 `.swift`，直接 `raise SystemExit(带原因与正确做法的提示)`。
   语义：把「跑一次 → 编译期 36 个 cannot find type」提前到**0 秒显式失败**，并让正确做法随错误信息一起出现。
   守卫必须是**无条件失败**，不留 `--force` 之类的旁路开关（留了就等于没修）。
2. 同步纠正 `rebrand-app-name-icon.md`：`:19` 的结论反转为「pbxproj 是手工权威件，生成器只覆盖 `MixCut/`」；
   `:40` 第 2 步改为「手工编辑 pbxproj 中的名字引用 + 逐名 diff 校验」，并把「校验 93+35」这条判据标为失效。
   （这是对**另一份计划文档**的修改，属文档不影响代码，v3 一并列出待你审。）

### 2.4 工程文件：手工删 7 条（跨 4 个 section）

`grep -n UpdateChecker MixCut.xcodeproj/project.pbxproj` 当前 7 条：

| 行 | section | 处理 |
|---|---|---|
| `:37` | PBXBuildFile | 删整行（`4073A3718CC9FAB5EE400BB7 … in Sources`） |
| `:180` | PBXFileReference | 删整行（`398D9F67B6B07F677992CA9D`） |
| `:542` | 父分组 `Services` 的 children | 删 `B3D90C14AE78316E2E14FF41 /* UpdateChecker */,` |
| `:566-571` | `UpdateChecker` 分组本体（PBXGroup） | 删整个 6 行块（含 `path = UpdateChecker;`） |
| `:832` | App target 的 PBXSourcesBuildPhase | 删 `4073A3718CC9FAB5EE400BB7 … in Sources,` |

**按 ID 删，不按行号删** —— 删 `:566-571` 后 `:542`/`:832` 的行号会前移。
删完自查：`UpdateChecker`、`4073A3718CC9FAB5EE400BB7`、`398D9F67B6B07F677992CA9D`、`B3D90C14AE78316E2E14FF41` 四个计数全为 **0**。

### 2.5 明确不碰

- `MixCut.entitlements`：无网络权限项（沙箱本就是 `false`），AI API 与模型下载兜底仍需联网，删它零收益有风险。
- `UpdateChecker.swift` 的 `UserDefaults` 键 `dismissedUpdateVersion`：删文件后成孤儿，**不清理**（清了要碰迁移逻辑，属范围外）。
- `README.md:11-17,57-58,123,163,195-197`、`CLAUDE.md:203`、`release_gitee.sh`、`docs/PRD/04-*.md:26`：
  纯文本、不影响运行时，与改名计划重叠（→ §5 P1 一并治根因）。
  **（2026-10-01 已单独收口，本格作废）** 实际做完的是：README 门面重写 + 顶部 `logo.png` 从新 AppIcon 重生成 +
  `demo-video.jpg` 删除、`CLAUDE.md` 发版段改 GitHub-only 并删历史 Gitee release id 表、`release_gitee.sh` 与
  `bundle_deps.sh` 两颗脚本删除、`docs/PRD/04:26` 图片改仓内相对路径、13 份历史计划里 34 处原作者机器路径换成
  `<仓库根>` / `<DerivedData>` 占位。全仓严格残留停在 **9 处**，逐处都是有意保留：`LICENSE:3`、`README.md:187`、
  `CLAUDE.md:254`（MIT 两行版权的规范说明）、`scripts/test_project_guards.sh:26`（判据自身含 pattern）、
  以及本文 `:45/:142/:143/:235/:283` 五处 token reprint（账本，删了就说不清谁被清过）。

## 3. 施工顺序（含回退链）

**本仓库不是 git 仓库**，没有 `git checkout` 兜底，备份必须显式做。

1. `mkdir -p .scratch/before` 并 `cp` 这 7 个文件进去：`ContentView.swift` `SidebarView.swift` `SettingsView.swift`
   `FFmpegRunner.swift` `ModelContextExtension.swift` `ASRService.swift` `MixCut.xcodeproj/project.pbxproj`，
   外加 `UpdateChecker.swift`、`OpenAICompatibleClient.swift`（§2.2 第 1 步要给它加 accessor）、`generate_xcodeproj.py`。
   （`.scratch/pbxproj.before` 已在，可与 pbxproj 互相 `cmp` 校验。）
2. §2.2 第 1 步：`MixLog` 暴露 `static let logFileURL`
3. §2.2 第 2、3 步：改三条文案（`FFmpegRunner:59`、`ModelContextExtension:28`、`ASRService:948`）
4. §2.3 第 1 步：`generate_xcodeproj.py` 加硬失败守卫 → **立即原地空跑一次确认它真的拒绝运行**（守卫自身也要验，不然等于没加）
5. §2.1 三个文件的调用点与 UI 区块删除
6. §2.4 手工删 pbxproj 7 条 → 跑 §2.4 的四项 ID 计数自查（必须全 0）
7. 删 `UpdateChecker.swift` 与空目录
8. **逐名 diff 证明 36 条 MixCutCore 引用一条没少**：
   `comm -13 <(改动前 pbxproj swift 名排序) <(改动后 …)` 只允许 `UpdateChecker.swift` 消失，反向 diff 必须为空。
   **不接受只比总数**（总数对得上也可能被同时增删掩盖）。
9. 跑 §8.4 的三个守卫脚本（内含 `xcodebuild -list` 结构校验）——
   手工删 6 行块若括号错位会**静默丢整个分组**，肉眼看代码发现不了，必须有机械判据
10. `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build`
    （本机 DerivedData：`~/Library/Developer/Xcode/DerivedData/MixCut-bwzwtxgcuznkvsbxqcduvqzndian/`；
    `CLAUDE.md:118` 那条是原作者机器的路径，别照抄。
    `CLAUDE.md:117` 要求编译后 `pkill -x MixCut` 自动重启 —— **这一步我会先问你**，不擅自杀你开着的实例。）
11. 起 App 做 §4 肉眼验收

**回退**：任一步失败，`cp .scratch/before/<文件名>` 原位还原并 `cmp` 确认。上一轮已验证这条链可用
（pbxproj `cmp identical`；三个 Swift 文件 42/54/86/120 与 21/338/466 行号全部对上）。

## 4. 验收判据（只看用户可观察结果 + 可机械执行）

**残留清除**
- 起 App：窗口顶部**无**紫蓝渐变横幅；侧边栏「设置」上方**无**「微信」行；设置页「关于」只剩使用引导 + 键盘快捷键
- 对四个上游标识（姓名 / 手机号 / GitHub 账号 / Gitee 账号）做 grep = **0 命中**（整棵 App 源码树，不止三个文件）
  〔2026-11-10 更正：具体判据值不再以明文写在本文件里，见 `scripts/test_project_guards.sh` 的 TC-06〕
- 启动期抓网络：对 `api.github.com` / `gitee.com` 的请求消失

**工程契约**
- 编译通过；§2.4 四个 ID 计数全 0；§3 第 8 步逐名 diff 干净
- 以上三条**由 §8 的 `scripts/check_project_integrity.sh` 机械判定**（TC-01/02），不再靠我口头比对；
  `xcodebuild -list` 退出 0 且列出 `MixCut` target；Xcode 打开工程无红字缺文件引用

**守卫与文案（v3 新增，防的是"同类问题再来一遍"）**
- `python3 generate_xcodeproj.py` **必须非零退出并打印原因**（这是把纪律换成机制的落地证据；它若静默成功则 P0-B 没做到）
- `grep -rn "导出诊断日志" MixCut/` = **0 命中**；三条错误文案里的日志路径**来自 `MixLog.logFileURL`**，
  且 `grep -rn "Caches/com.mixcut.app/logs" MixCut/` 只剩 `OpenAICompatibleClient.swift` 那一处真源

**主链与交互回归**
- 导入一个真实视频 → 分镜出来 → 导出一条 MP4（`ContentView` 是根视图，动它必须验主链）
- ⌘B 侧边栏显隐、⌘/ 快捷键面板仍可用；触发一次可故意复现的失败（如断网后跑 AI 分析）确认新文案里的日志路径**肉眼可打开且文件存在**

**反假绿要求**
- 横幅判据必须是「装好新包、启动、肉眼看不到横幅」，不接受「把 `hasUpdate` 设成 false 来验」，
  也不接受「没人调用所以一定不显示」的推理 —— 要看到 `UpdateBanner` 真从 `ContentView` 消失。
- 文案判据必须是**真实触发一次失败、读到那句话**，不接受"改了字符串就行"。

## 5. 另案（超出本次授权，需单独确认，v3 不做）

- **P1 品牌/渠道单一来源**：新建 `MixCut/Support/Brand.swift`（署名、联系渠道、仓库地址、更新源 URL），
  View 只读它；更新检查若恢复，用 `ReleaseSource` 协议注入而非把 URL 焊进 actor。
  这一条才是 §1/§2.2 那个「字面量散落 + 悬空承诺」根因的终点（一并治 README/CLAUDE/release_gitee/PRD 那批硬编码）。
  **与改名计划重叠，建议合入改名一起做**，现在插一脚两件事会互相踩。
- **P1 「导出诊断日志」补齐真实能力**：在设置页加一个真的导出/打开日志目录的动作
  （现有按钮 `SettingsView.swift:355-361` 开的是 Application Support，不是日志目录）。v3 只是把文案改成说真话，**功能缺口仍在**。
- **P2 pbxproj 恢复可再生**：给生成器补扫 `Sources/MixCutCore` 并处理手工递增 ID ↔ `md5` ID 的映射，
  使「重生成 == 仓库 pbxproj」成立，再加 CI 判据。这是同类问题的结构性终点防线，成本 1–2 小时 + 全量编译验证。

## 6. 三条硬标尺对照（v2 → v4，**结论仍需你复审，我不自判通过**）

| 标尺 | v2 | v4 |
|---|---|---|
| 根因层级 | 不过：只删三个实例 | 部分改善：§2.2 收敛日志路径字面量到单一真源、§2.3 纠正那份错误的活计划；**彻底解（P1 品牌层）明确推到另案** |
| 非遮盖 | 基本通过 | 通过：错误文案改为说真话而非删掉承诺；守卫是无条件失败且带自检判据（TC-03 把"守卫静默成功"本身测成红），无 `--force` 旁路且 TC-07 验证这点 |
| 不引入耦合 + 提升性 | 不过：手工删引用加深隐性契约、无防线 | 明显改善：**§8 TC-01/02 把"源码树 ↔ pbxproj 引用守恒"变成可复跑的机械判据** —— 这是 §1 那个根因第一次有防线；代价是 pbxproj 仍手工维护（→ P2 才根治） |

## 7. 谁做 · 多久

我改。§3 十一步约 **35 分钟**（v2 的 25 分钟 + 文案处置与守卫各 5 分钟）；若 §8 的守卫脚本一并落地，**再加 10 分钟**。
主链回归需要你给一个可用素材路径，或授权我用 App 里现有项目验；这步不做，改动不算完成。

## 8. 测试与守卫层（v4 新增，按 `test-coverage-expander` 四阶段产出）

### 8.1 种子层现状（全部实测，非推测）

- 已有测试：**34 个文件**，全在 `Tests/MixCutCoreTests/`，框架是 **swift-testing**（`import Testing` / `@Test` / `#expect`），
  `@testable import MixCutCore`；仓库内 **0 个 XCTest 文件**。断言风格是"对产出字符串做 `contains`/等值比对"（如 `ParaformerASRTests.swift:9-15`）。
- **硬结构约束（决定本次能测什么）**：`MixCut.xcodeproj` 只有 **1 个 target**，
  `productType = "com.apple.product-type.application"`（`project.pbxproj:711`）—— **没有 unit-test target**，
  `xcodebuild test` 无 target 可跑；`Package.swift` 的 target/testTarget path 又各自锁死在 `Sources/MixCutCore`、`Tests/MixCutCoreTests`。
  ⇒ **`MixCut/` 里的任何东西（`MixLog`、两条文案、`ContentView`/`SidebarView`/`SettingsView`）物理上进不了 `swift test`。**
- 已有的非单元测试守卫先例（本次沿用它的形状，不发明新框架）：`scripts/mcp_smoke_test.sh` —— 黑盒 curl + 内嵌 python `assert`。
- **两个反面种子，禁止模仿**：
  1. `Tests/MixCutCoreTests/SmokeTest.swift` 全文就是 `#expect(Bool(true))` —— 恒真断言，零信息量。
  2. `scripts/mcp_smoke_test.sh:22` 的 `assert len(tools) == 9` 与真实 23 个工具不符（改名计划 `:61` 已把它记为**必挂的假红灯**）。
     新守卫的判据必须**从被测对象自身推导**（扫文件树、扫 pbxproj），不得抄一个写死的数字。

### 8.2 本次五项改动的可测性判定

| # | 改动 | 进 `swift test`？ | 判定依据 | 落地层级 |
|---|---|---|---|---|
| a | 删更新检查调用点（`ContentView`） | ❌ | App target 无测试入口（§8.1） | 静态接缝 + 人工/E2E |
| b | 删微信入口 / 关于三行 | ❌ | 同上 | 静态接缝 + 人工/E2E |
| c | 文案改指真实日志路径 + `MixLog.logFileURL` | ⚠️ **有条件可测** | 路径计算现在是 App target 内的 `private static`（`OpenAICompatibleClient.swift:5-14`），**够不着**；若把这段纯函数下沉到 `Sources/MixCutCore`，就进得了现有 34 个测试的框架 | 下沉 → 单元；不下沉 → 只能静态 grep |
| d | `generate_xcodeproj.py` 硬失败守卫 | ✅（脚本级） | 与 Xcode 无关，python + 文件系统即可判定 | 守卫脚本 TC-03/07 |
| e | pbxproj 引用完整性（36 条不许少、7 条删干净） | ✅（脚本级） | 纯文本 + 目录树双向比对 | 守卫脚本 TC-01/02，**本层价值最高** |

### 8.3 覆盖差距矩阵（维度取自 skill 内置模式库；**未检索到有效外部经验**，两次检索命中内容农场且原文 404，已降级）

| 维度 | 单元 | 集成/脚本 | E2E | 来源 / 回溯 |
|---|---|---|---|---|
| INV-01 不变量守恒（源码树 ↔ pbxproj 引用双向守恒） | ❌ | ➕ TC-01/02 | ❌ | 内置模式库；由 §1 根因直接导出 |
| CT-01 契约一致（文案路径 == `MixLog` 真源） | ❌ | ➕ TC-05/06 | ❌ | 内置模式库；由 §2.2 导出 |
| CFG-01 缺省安全降级（`cachesDirectory` 不可用→`temporaryDirectory` 且目录被建） | ❌ | ➕ TC-04 | ❌ | 内置模式库；等价类 IN-06 |
| IN-01 空输入（`Sources/MixCutCore` 缺失/为空时守卫语义） | ➕ TC-03 反例 | | | 内置模式库 |
| OBS-01 可观测性（失败文案给出**可打开且存在**的日志路径） | ❌ | ❌ | ➕ TC-08（人工） | 内置模式库；§2.2 取证 |
| EX-03 下游失败（日志目录不可写时 `MixLog` 不崩） | ❌ | ❌ | ❌ | 标注**不做**：需 App target 测试入口，超出本次范围 |
| MIG-01 兼容（`dismissedUpdateVersion` 孤儿键） | ❌ | ❌ | ❌ | 标注**不做**，见 §2.5 |

### 8.4 用例清单（拟新增，均为**新增文件、零生产源码改动**）

| 编号 | 层级 | 标题 | 回溯规则 | 输入 | 预期（失败种类要能区分） | 优先级 |
|---|---|---|---|---|---|---|
| TC-01 | 脚本 | pbxproj 覆盖全部源文件 | INV-01 | 扫 `MixCut/**/*.swift` + `Sources/MixCutCore/*.swift`，逐个查 pbxproj 是否有 BuildFile 且在 Sources phase | 缺失 → 退出非 0 并**列出文件名与缺失的 section**；0 缺失才绿 | **P0** |
| TC-02 | 脚本 | pbxproj 无悬空引用（反向） | INV-01 | 取 pbxproj 里所有 `.swift` 路径引用，逐个查盘上是否存在 | 悬空 → 非 0 并列出；顺带证明 §2.4 那 7 条删干净了 | **P0** |
| TC-03 | 脚本 | 生成器守卫必须拒绝运行 | IN-01/CT-01 | `python3 generate_xcodeproj.py`（在含 `Sources/MixCutCore` 的本仓库根） | 退出码 **非 0**，stderr 含"手工维护/MixCutCore"原因与正确做法；**若静默成功即判红**（证明 P0-B 没落地） | **P0** |
| TC-04 | 单元 | 日志路径降级等价类 | CFG-01 | `cachesDir` 正常 / 为 `nil` 两类入参 | 正常→`Caches/com.mixcut.app/logs/mixcut.log`；`nil`→`temporaryDirectory` 分支且目录被创建 | P1（**需 §8.5 下沉才成立**） |
| TC-05 | 脚本 | 三条文案的路径来自真源 | CT-01 | `grep "导出诊断日志"` 必须 0 命中；`grep "com.mixcut.app/logs"` 在 `MixCut/` 只剩 1 处真源；`grep "MixLog\.logFileURL"` = **3**（每条用户文案各引用一次） | 命中数不符即红 | P1 |
| TC-06 | 脚本 | 原作者身份字符串归零 | INV-01 | 对四个标识（姓名 / 手机号 / GitHub / Gitee）grep `MixCut/` | 必须 0 命中（整棵 App 源码树，不止 §2.1 那三个文件） | **P0** |
| TC-07 | 脚本 | 守卫无旁路开关 | IN-04 | `python3 generate_xcodeproj.py --force` 等常见绕过参数 | 仍然非 0 退出（证明不是"看参数的软提醒"） | P1 |
| TC-08 | E2E | 真实失败时读到新文案且路径可打开 | OBS-01 | 断网触发一次 AI 分析失败 → 读 toast → 用该路径确认文件存在 | 人工判据，**须走用户入口**（不许直接调 service 预置状态） | P1 |

### 8.5 阶段 D：待你确认才生成的东西

- **默认落地（零生产码改动）**：TC-01/02/03/06/07 → 两个脚本 `scripts/check_project_integrity.sh`、`scripts/test_project_guards.sh`，
  沿用 `mcp_smoke_test.sh` 的 shell + 内嵌 python 断言形状。
- **需单独授权**：TC-04/05 —— 它要求把 `MixLog` 的路径计算**下沉成一个 `Sources/MixCutCore` 纯函数**（新增 1 文件 + 改 `OpenAICompatibleClient.swift:5-14` + 3 处文案调用点）。
  这**动了生产源码**，超出本 skill「只增测试文件」的边界，且新文件必须同步进 pbxproj（回到 §1 那个手工权威件的坑）。
  收益是本次唯一能被真实单测覆盖的接缝从 0 变 4 个等价类。**我的建议是先不做**，用 TC-05 的静态判据替代，等 P2「pbxproj 恢复可再生」落地后再补。
- **不自动跑**：脚本写完不代跑、不提交，运行由你点头（沿用既有约定）。
- **自检要求**：我生成的每条断言都要能在"改动未做"的代码上变红；写完做一次 AST 复查剔除任何 `or True`/自环式恒真断言（§8.1 的 `SmokeTest.swift` 就是那种废判据）。
  若要跑变异验证（临时改生产码证明测试会红），我会先问你再动。

## 9. 落地记录与偏差（2026-09-28 执行 §3 + §8.5 默认项）

**已做（生产码 6 个文件 + 工程 1 个 + 删 1 个 + 新增 2 个脚本）**
`OpenAICompatibleClient.swift`（`MixLog.logFileURL` 真源）、`FFmpegRunner.swift:59`、`ModelContextExtension.swift:28`、
`ASRService.swift:948`（三条文案改指真源）、`ContentView.swift`、`SidebarView.swift`、`SettingsView.swift`、
`MixCut.xcodeproj/project.pbxproj`（手工删 7 条）、删 `UpdateChecker.swift` 与空目录、
新增 `scripts/check_project_integrity.sh`、`scripts/test_project_guards.sh`（未提交，git 无关）。

**验证结果（全部实测输出）**
- 逐名 diff：`消失=UpdateChecker.swift`，`新增=无`；128 → 127。36 条 MixCutCore 引用一条未少。
- 工程守卫：**绿**（源码树 127 ↔ BuildFile/SourcesPhase/FileRef 各 127，`xcodebuild -list` 可读）。
- 残留/生成器守卫：**8 条全 PASS**，含「`python3 generate_xcodeproj.py` 退出码 1 且打印原因」「`--force` 同样被拦」
  「探测全程真实 pbxproj 校验和未变」。
- 非空跑证据：把 `PBX_PATH` 指向改动前的备份工程，同一守卫立刻变红
  （`FAIL[悬空引用] UpdateChecker.swift`）—— 证明它不是恒绿判据。**这条替代了变异验证**，未临时改生产码。
- `xcodebuild ... Debug build` → **BUILD SUCCEEDED**（普通 Debug，仅本机 arm64；分发需按 `CLAUDE.md:139` 加 generic destination）。

**与计划的偏差（5 条，均如实记录）**
1. §2.4 写 UpdateChecker 分组块是「6 行（`:566-571`）」，实际是 **8 行 `:563-570`**（含 `};` 收尾）。按 ID 定位删的，结果一致。
2. §8.4 TC-05b 原判据写成「`logFileURL` 总行数 = 4」，**数错了**（漏算 `logPath = logFileURL.path` 那行）→ 首次跑该判据变红。
   已把判据改成有语义的「`MixLog.logFileURL` 限定引用 = 3（每条用户文案一处）」，并回写 §8.4。
   记这笔账的意义：**判据写错会被自己的脚本抓到，这比脚本恒绿有价值。**
3. 新脚本自带两个 bug，都在首次运行暴露并已修：
   ① `grep` 无命中时退出码 1 被 `set -e` 掐死 → 脚本**静默中止且无输出**（最坏的一种失败，看起来像"跑了但没事"），
      改成 `{ grep … || true; } | awk` 由计数做判定；
   ② `xcodebuild -list -project` 传的是 pbxproj **文件**而非 `.xcodeproj` **目录** → 报 `not a project file`。
4. §8.5 写「脚本写完不代跑」，你回「执行」后我把两个守卫都跑了（纯只读 + `.scratch` 隔离探测），
   并给 `check_project_integrity.sh` 加了 `PBX_PATH` 覆盖口，专门用来在"改动前"的工程上自证会红。TC-04/05 的下沉方案**未做**。
5. `Resources/bin/` 仍是空的（本次未跑 `build_universal_binaries.sh`，那是 GB 级下载，需你单独授权）。

**验收完成情况（2026-09-28 14:13 更新）**
- **肉眼验收：2/3 已用截图证实**（`.scratch/verify-main.png`，新构建 pid 60736，走的是真实用户入口——启动后的主窗口）：
  ① 窗口顶部**无**紫蓝渐变横幅；② 侧边栏底部**只剩「设置」一行，「微信」行已消失**。
  ③ 设置页「关于」区无 `MengGang`/微信号/GitHub —— **未截图证实**：本机 osascript 无辅助访问权限，
  我没法自动点开设置。该条目前只有静态判据 TC-06（整棵 `MixCut/` 源码树 0 命中）背书，需你点一下设置页肉眼确认。
- **启动期网络请求**：**未抓包验证**。替代判据是 TC-06b（`UpdateChecker`/`UpdateBanner` 在 `MixCut/` 内 0 引用，
  即无调用点）。这是**替代而非等价**，若要实证需你点头我再跑一次带网络观测的启动。
- **主链回归（导入→分镜→导出）：未做，且当前不可能做**——`MixCut/Resources/bin/` 是空目录（只有 `.gitkeep`），
  内置 ffmpeg/ffprobe/whisper/demucs 全部缺失，侧边栏「设置」旁的橙色感叹号就是这个缺依赖提示。
  补齐要跑 `scripts/build_universal_binaries.sh`，其中含 **1.62GB Whisper 模型 + 80MB demucs 模型**下载，
  属 GB 级拉取，按约定需你单独授权。库里有现成项目「测试」（已导入 5 个视频，缩略图正常），
  所以一旦 bin/ 补齐，导入→分镜→导出可立刻用真素材验，不必另找路径。

## 10. 补 `Resources/bin/` 的现场记录（2026-09-28 16:20）

- 第一次跑 `build_universal_binaries.sh` 在 `[2/3]` 克隆 whisper.cpp 时 `Empty reply from server` 失败，`bin/` 保持空
  （脚本最后一步才 `install`，中途失败不留半成品，这点设计正确）。
- **我一度把它报成成功**：后台命令写成 `脚本 > log 2>&1; echo; tail`，退出码被 `tail` 覆盖成 0，包装器照此报「exit code 0」。
  教训：结论必须配**产物证据**（`ls` 出文件、`lipo -archs` 出架构），不能只看退出码。
- 网络探测：`git ls-remote` 直连 GitHub **rc=0 正常列分支** → 上次是瞬时故障；`gitclone.com` 镜像 500/超时，
  `ghproxy.net`、`gh-proxy.com` 均 HTTP 200 可用。
- 据此给 `build_universal_binaries.sh` 加了**镜像开关**（默认仍直连上游、不改语义）：
  `GIT_MIRROR=https://ghproxy.net/ ./scripts/build_universal_binaries.sh`，
  用 `url.<mirror>https://github.com/.insteadOf=` 改写，**连 demucs.cpp 的子模块一起走镜像**。`bash -n` 通过。
- 吞吐实测（各 40s 上限）：evermeet 与 osxexperts **40 秒都没拉满 2MB（≤51 KB/s，这是下界不是速率）**，
  hf-mirror ≈350 KB/s。估算剩余 1.5–2.5 小时。已选「等它跑完」，任务在后台继续。
- **分镜不依赖 API Key**（`ImportViewModel.swift:331/584` 调 `sceneDetection.analyzeLocally`，本地 ffmpeg 场景检测）；
  需要 Key 的是 AI 语义分析（日志 `API Key 为空！provider=DeepSeek` → `分析完成 status=failed` 即那一步）。
  ⇒ bin/ 补齐后「导入→分镜→导出」可全程真跑，无需配 Key。
- **撞车已收口（P0-B 第二半完成）**：`2026-09-28-rebrand-app-name-icon.md` 曾在 14:07 被另一窗口重写成 v2，
  其中「重跑生成器」的路线与 §54 的「`grep -c '.swift'` 校验引用数（基线 93 App + 35 Core）」判据均与本计划 §1 实测冲突；
  我插入的守卫还把它引用的 `generate_xcodeproj.py:485,514` 行号推移到 **500,529**。
  用户裁定「那边已停，以当前窗口为准」后，我已就地修正该文档：行号勘误、§54 判据换成
  `scripts/check_project_integrity.sh`（逐名）、并新增其 §8 勘误章节（生成器守卫导致的阻塞、阶段 1 的 36 处手工路径成本、
  本窗口已代做的两项、品牌守卫测试必须把 `"com.mixcut.app/logs"` 列入白名单、`brew install whisper-cpp` 那条存疑）。

### 10.1 主链回归的实测进展（2026-09-28 17:0x，走 App 自带 MCP 接口，23 个工具）

- **导入这一环已真跑通**：`create_project` → `import_videos`（34MB 真实视频）→ job `report.imported=["视频库 (3).mp4"]`、`failed=[]`，
  且 `get_project` 回 `duration_sec=141.80` —— **说明 ffprobe 正常**，我改的根视图没弄坏导入链。
- **纠正我自己的两个误判**：
  ① `FFmpegRunner.resolveBinary`（`:116-134`）与 ffprobe 对称，优先级是「显式 > bundle 内（存在才用）> 系统安装
  `/opt/homebrew/bin/{ffmpeg,ffprobe}`」⇒ **本机 ffmpeg 根本不需要等那 6 小时慢包**；
  ② 但 `ASRService.findWhisperBinaryStatic` 的候选里 whisper 也走同一形状，而本机**未装** whisper-cpp ⇒
  **分镜卡的是 ASR 组件缺失，不是 ffmpeg**。我先前「只要 ffmpeg 到位分镜就能跑」的说法不成立。
  （顺带：rebrand §7 那条我标为「存疑」的 `brew install whisper-cpp` 建议，其实**方向是对的**，只是它该走 bundle 内置而非 brew。）
- 现状：`segment_count=0`，`video.status=failed`，错误三条 = whisper 未找到 / 未配 API Key / AI 未产出。
- **已停掉后台构建**（用户指令）。核查过：无残留进程、`Resources/bin/` 仍只有 `.gitkeep`（无半成品污染）、
  临时工作目录已被脚本 trap 清理。App（pid 32766）仍在运行、MCP 在监听。
- **未闭合项**：分镜与导出两段。最短路径 = 装 whisper 运行时（`brew install whisper-cpp`，命中代码里的开发期 fallback）
  + 让 App 自动下 1.62GB 模型（约 80 分钟），再 `retry_analysis` → `list_segments` 由 0 变正 → `export_segments` 出真 MP4。
  装包动作**尚未获授权，未执行**。

### 10.2 主链回归的实际结论（2026-09-28 17:27）

用户放行后装了 `whisper.cpp 1.9.4`（`/opt/homebrew/bin/whisper-cli`）并放了 **148MB 的 `ggml-base` 模型**
（`findWhisperCppModel:697` 认 base，省掉 1.62GB large-v3-turbo 的 80 分钟；只为验链路，不代表正式 ASR 质量）。
日志实证**系统回退真的生效、ASR 跑通了**：
`ASR(whisper 切分用) 完成：words 509 / 句子 76`、`场景检测完成: 30 个切换点`、`I-frame 提取完成: 31`、`静音检测完成: 15`。

**但分镜与导出仍未跑通，卡点是 AI Key，不是我改的代码**：`error_message = "AI 分析失败: DeepSeek API Key 未配置，请在设置中添加"`，
`segment_count = 0`、`status = imported`。⇒ **Segment 记录是由 AI 分析产出并落库的**，
这是我本轮**第三个误判**（先说「分镜只要 ffmpeg」，改口「分镜只要 ASR」，实际两者都只是前置，落库要 AI 那一步成功）。

已通 / 未通：
- 通：`create_project` → `import_videos`（34MB 真素材，`imported`、`failed=[]`）→ ffprobe 读时长 141.80s → 场景检测/静音/I-frame → ASR
- 未通：分镜落库、`export_segments` 出 MP4。**需要用户在「设置」里自行填 API Key**（密钥不应经我手或进对话），
  填完再跑 `retry_analysis` 即可续上。

**本次为验证引入的外部资产（可随时撤）**：brew 包 `whisper.cpp 1.9.4`；`~/Library/Application Support/MixCut/whisper-models/ggml-base.bin`；
MCP 建的测试项目「回归验证-2026-09-28」（`6C1B0212…`，可用 `delete_project` 清）；工作区 `.scratch/`（备份、日志、截图、mcptest）。





