# UI 层没有任何自动化入口：黑盒 E2E 环的首期地基（导航冒烟）

状态：**v1（方案已扛过两轮独立评审，2 条 P0 已收口；尚未落码，本文档即步骤 0 的交付物）**。
本案不是缺陷修复，是**建一层此前不存在的测试面**。交付物「导航冒烟全绿」不等于 UI 层已被覆盖，
只代表这层第一次可跑、可判红、可存证。凡本文档里的读数都标了实测/推断，落码后被实测推翻时**改描述不改读数**。

| 版本 | 变化 |
|---|---|
| v1 | 初版。需求经六维度澄清（目标/范围/技术栈/数据隔离/体验/成本）；实测跑通一次最小探针（Appium 3.8.0 + mac2 driver 4.3.6 + Xcode 16.4 + macOS 15.6.1，读到 261 节点、整屏截图、定位策略矩阵）；architecture-first-fix 审查判「需返工」，就地吸收 R1—R6（接进既有不变量、锚点双向守恒、假库守卫可证伪、重试按阶段、共享会话不变量、观测分两级）；tech-solution-review 三维评审补 R7—R9 与 2 条 P0（MCP 端口争用、Release 产物静默失效）；决策收口：首期禁用 MCP 播种、脏文件全部避开、App 自报判据让位在制品之后 |
| v1.1 | **落档后自数订正（三处，全部以实测覆盖转抄值）**：① `.accessibilityLabel(` 实为 **47 处**（不是 49；另有 6 处是 `accessibilityLabel:` 自定义函数形参，含字样共 53 —— 前案转抄的 49 混了两种口径）；② 行首 `@Test` 实数 **551 条**，与仓内文档口径「550」差 1，本文一律以 551 为准并标注口径；③ 导航枚举 `NavigationItem` 在 `ContentView.swift:14-21`，**6 个 case**（`overview/importMedia/segmentLibrary/schemes/bgmLibrary/export`）+ 设置 = 7 个目的地，§0/§5/刀 12 的行号引用随之改正 |
| v1.2 | **步骤 1 实测（§9）**：假库开关端到端**已验证生效**、活库**零污染**（三颗文件 `shasum -c` 全 OK）；但**真实点击静默无效**（不抛错、`selected` 不变、节点集不变）⇒ 评审里标 P2 的「点了没反应」失效模式在授权之前就被抓到，升级为前置判据 **U09**；另翻出两个新坑：Xcode 16 Debug 用 dylib 注入（U01 的 `strings` 校验必须扫 `*.debug.dylib`，只扫主二进制会两边读 0 而**恒绿**），以及「只读探针」这个说法被证伪 —— 昨天那次 Release 探针确实写了活库的 `launch-ledger` 与 `-shm` |
| v1.3 | **§10 事件通道根因查清，并推翻 §9.4 我自己的推断**：用户已授 Xcode Helper 辅助功能权限后，鼠标点击**仍然零变化**；换无可辩驳目标（点「新建项目」看是否弹表单）与键盘通道（⌘N）双路复测，**全部静默无效且不抛错**。`automationmodetool` 只读实测给出确证读数：`Automation Mode is ENABLED. This device requires user authentication to enable Automation Mode.` ⇒ 根因不是辅助功能授权，而是 **macOS Automation Mode 鉴权门槛**（对应驱动自家 CI 的 `sudo automationmodetool enable-automationmode-without-authentication`，以及 doctor 一开始那条「✖ Automation Mode requires user authentication」警告）。读通道完全正常、事件通道全灭 ⇒ 新增前置判据 **U10** |
| v1.4 | **撤回 v1.3 的根因结论——它不被自己的读数支持（方法论错误，§11）**：解除 Automation Mode 鉴权 + 重启 server 后复测仍"零变化"，于是去抓 WDA 原生输出，发现 `Synthesize event` **确实执行了且无报错**；换真正有效的目标重测，「设置」与「创建新项目」均 **0.5s 内弹出完整面板**。⇒ 事件通道本来就是通的，v1.3 那三次"不通"用的目标**全部无效**：「素材导入」实测 `enabled=false`（空库无项目时本来禁点），「新建项目、⌘N」实测 `enabled=true hittable=true` 但**点击就是不触发动作**。所以既不能归功于 Automation Mode 解除，也不能归功于辅助功能授权——**先前那批读数证明不了任何事**。两条设置变更已生效且可撤销，但因果未证 |

关联案：`2026-10-03-tombstone-read-after-real-delete.md`（同族第一起，崩 `Segment.id.getter`）、
`2026-10-04-toone-crossing-real-delete.md`（第二起；其 §17.3 覆盖矩阵的 **E2E 真机列 T-0/T-1/T-2 已标 ➕ 且至今为空**，
本案要填的就是那一格）。
相关既有门：`scripts/check_navigation_readiness_guards.sh`（G01–G14 守导航/骨架的**代码形状**，本案守它测不到的**运行时事实**）。

---

## 0. 要解决的问题

本仓 551 条 `@Test`（行首实测计数；仓内文档口径写 550，差 1 见 §版本 v1.1）全在 `Tests/MixCutCoreTests/`，
且全部 `@testable import MixCutCore`、`import SwiftData` 0 处；
**App 层与 UI 层零自动化入口**。根因是工程结构死结：

- `MixCut.xcodeproj` 只有 1 个 application target（`project.pbxproj:812-826`），无 test / UI-test target；
- `generate_xcodeproj.py:39-51` 已硬锁拒绝再生成工程；
- 前案 `2026-10-04-toone-crossing-real-delete.md:268` 明文记着「本仓无 test target」。

⇒ Apple 原生 XCUITest 必须往工程里加 UI-test target，与上面两条正面冲突；
appium-mac2-driver 走「外部进程驱动已安装的 App」，是**唯一不需要动工程结构**的 E2E 通路。
本案要把它从一次性探针升级为可重复、可判红、可进门禁的一层。

## 1. 取证（都能在机器上复核，标注实测/推断）

**F1 观测粒度（实测）** 全树 261 节点里 170 个是系统菜单栏，**window 子树仅 69 个**
（22 按钮全部带 label、31 StaticText、6 Image、2 Group、2 ScrollView）。
⇒ 「每卡片级」断言在概览页没有对应节点；UI 环首期只能断言到这 69 个节点这一层。

**F2 dump 自带几何（实测）** source.xml 属性集 =
`elementType / identifier / label / title / enabled / selected / x / y / width / height`，
实测样例 `<XCUIElementTypeButton elementType="9" identifier="" label="SunCut" title="" enabled="true" selected="false" x="342" y="173" width="188" height="17"/>`
⇒ 布局断言**一次 dump 即可**，无需逐元素往返。

**F3 dump 缺 `hittable`/`visible`/`focused`（实测）** 三者只能逐元素 `getAttribute`。
⇒ 「看得见」在 dump 级退化为 `enabled==true` + rect 非零 + 存在性。**效力上限到此为止，不许声称穷尽**
（口径同 `2026-10-04-toone-crossing-real-delete.md:461`）。

**F4 谓词属性名（实测）** `elementType` 在谓词与 XML 里都是整数码（Button=9）；比字符串必须用 4.2.0+ 的 `amType`，
`identifier` 要用 `amIdentifier`；`label`/`title`/`value` 可直接用。
驱动官方 docs 的 `locator-strategies.md` 示例写的 `type`/`name` 已过期，实跑报 unknown attribute。

**F5 driver 4.3.6 的 `amText` 崩溃（实测）** 作谓词条件触发 WDA
`*** -[__NSPlaceholderArray initWithObjects:count:]: attempt to insert nil object from objects[0]`；单读属性正常。
⇒ 契约表 lint 见 U05。

**F6 class chain 语法（实测）** 谓词定界符是 `$...$` 不是反引号；根节点不能写
`XCUIElementTypeApplication/...`（恒 0 命中），要从 `XCUIElementTypeWindow` 起或直接 `**/`。

**F7 崩溃发生在 Debug（实测）** `2026-10-03-tombstone-read-after-real-delete.md:23`
「SunCut 0.11.0 **Debug** 于 2026-10-03 21:10:13 崩溃 `EXC_BREAKPOINT (SIGTRAP)`」
⇒ Debug-only 假库开关与「崩溃族复现」**不冲突**。但同前案 `:269` 立规
「Debug/Release 要标清，行为数与性能数不许混着报」⇒ U08。

**F8 MCP 端口硬编码（实测）** `MixCut/Services/MCP/AgentGateway.swift:11`
`static let defaultPort: UInt16 = 8787`，无 env / 参数覆盖；`MCPServer.swift:23`
用 `requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port:)` 独占绑定。
⇒ 双实例必抢端口，且请求会打到**当前持有 8787 的那个实例**。

**F9 假库开关是 DEBUG-only（实测）** `MixCut/Utilities/FileHelper.swift:17-25`，
`:20` 注释原文「Release 编译不进这一支」。
⇒ 拿 Release 产物跑门禁会**静默**写活库，没有任何报错。探针昨天跑的正是 Release 产物。

**F10 既有静态门已覆盖导航/骨架（实测）** `scripts/check_navigation_readiness_guards.sh` 头注写明守
「骨架屏的判据住在 ViewModel，视图不许自持 loading 标志」「换项目不许上骨架」，
并点名 `ContentView.detailView` 是 switch、视图实例每次导航都被重建。

**F11 现成运行时尺子（实测）** `scripts/measure_nav_blank.sh <录屏.mov>` 已实现逐帧边缘能量判据
（正常帧 YAVG 12.41，空白帧窗口 50–134ms）。本案复用，不另造尺子。

**F12 判据编号已有三套且踩过撞号（实测）** `G01…G23`、`T-0…T-2`、`TC-*` 并存；
`check_navigation_readiness_guards.sh:14` 明文「批六曾加过一组 G13–G17 已随批六撤销……
本文件现在的 G13/G14 是批十新加的，与那组同号不同物，别混」。⇒ 本案判据另开 `U` 段。

**F13 门禁族真实规模与纪律（实测）** 8 颗 `check_*` + 2 颗 `selftest_*` + `test_project_guards.sh` = **11 颗**。
共同纪律「判据失效要说判据失效，不算通过」见 `check_license_notice.sh`、
`check_schema_ledger_guards.sh:11-14`、`check_navigation_readiness_guards.sh` 三处一致；
且 `check_schema_ledger_guards.sh:11` 明令**取样面只点名源文件、不扫整树**。

**F14 `UITests/` 不破坏工程守恒（实测）** `check_project_integrity.sh` 的 `.swift` 扫描面
（其 `scan_dirs`）只含 `MixCut/` 与 `Sources/MixCutCore/` ⇒ 新增 `UITests/` 不会被它算进守恒对账；
但其全角标点门 `os.walk(root)` 只跳**点开头**目录 ⇒ `UITests/node_modules/` 会进 `.sh` 扫描面
（实测当前 0 命中，仅 2 个 `.sh`）。⇒ 依赖目录改放 `UITests/.node_modules`。

**F15 计划要碰的文件里 3 个是在制品（实测）** `MixCut/App/MixCutApp.swift`、
`MixCut/Views/Import/ImportView.swift`、`MixCut/Views/SegmentLibrary/SegmentLibraryView.swift` 状态 `M`；
`MixCut/App/DebugSelfTest.swift` 带 **+394 行未提交在制品**（即前案 §4 判据五格矩阵，
选择器 `MIXCUT_SELFTEST_TOMBSTONE` / `MIXCUT_SELFTEST_TOMBSTONE_GRID`，复用 `:764` 的
`write(_ path:_ lines:)` 报告通道）；全仓 39 个脏文件。

**F16 会话成本与失效（实测）** 新会话 ≈35s（WDA 已编译缓存下）；会话内单次 `findElements` 8–300ms。
被测 App 中途重启 ⇒ WDA 内部会话变 `Session does not exist`，并遗留
`xcodebuild` + `WebDriverAgentRunner-Runner` 孤儿进程；驱动 `wda-mac.ts:150-176` 在端口被占时
会主动 `DELETE http://host:port/` 强杀「疑似过期 WDA」⇒ 并行必互杀。

**F17 自定义 identifier 真数为 0（实测）** window 子树非空 identifier 仅 7 个：
4 个 `_XCUI:`/`SwiftUI.` 生成名、3 个 SF Symbol 名 `film`。产品码里 `accessibilityIdentifier` 0 处使用。

## 2. 要立的不变量

- **UI-INV-A** UI 环只断言**静态门测不到的运行时事实**；任何与 `G*` 同命题的条目视为设计缺陷（F10/F11）。
- **UI-INV-B** 锚点单一真源：Swift 里的 `accessibilityIdentifier("suncut.` 与 `UITests/anchor-roster.json`
  **双向守恒**，任一侧未认领即红（改名册 = 强制一次 review，照前案 G12 先例）。
- **UI-INV-C** 任何写操作都不得落到 `~/Library/Application Support/Suncut`；
  隔离由「产物配置 + 假库路径 + 活库未变」三查**独立成立**，不依赖人记。
- **UI-INV-D** 重试只属于 `session-establishment` 阶段；`in-app behavior` 断言**永不重试**
  （崩溃族根因是时序竞态，重试即把竞态窗口洗成绿）。
- **UI-INV-E** 共享会话内的用例零状态写入（只导航/只读/只断言）；
  任何会改 App 状态的用例强制独立会话 + 每轮从快照重置。
- **UI-INV-F** 每个断言显式声明观测级 `dump` 或 `per-element`（F2/F3），防止为一个 `hittable` 把 69 个元素全往返。
- **UI-INV-G** 判据编号只占 `U` 段，与 `G*` / `T-*` / `TC-*` 互斥（F12）。

## 3. 三刀（编号接前案刀 10 之后；全部落在**已有文件**或全新非工程文件）

### 刀 11｜门禁骨架与前置三查（`UITests/` + `scripts/`，不碰产品码）

```
UITests/
  package.json                 # 只装 webdriverio；APPIUM_HOME 隔离到 UITests/.appium-home
  .gitignore                   # .node_modules/ .appium-home/ artifacts/ .fixture/
  anchor-roster.json           # 锚点名册真源（UI-INV-B）
  lib/session.mjs              # 分层会话 sharedSession()/isolatedSession() + 孤儿 WDA 回收
  lib/guards.mjs               # 前置三查：产物必须 Debug / 假库根可写 / 8787 持有者必须是本轮实例
  lib/evidence.mjs             # 截图 + source.xml + 前后 diff + 驱动日志尾部 → artifacts/<ts>/<case>/
  lib/report.mjs               # 单一事件流 → 终端表 + HTML 两个 renderer
  lib/anchors.mjs              # 契约表：只引用 key，不复制中文标题串
  fixtures/store.snapshot/     # 预置最小库快照（含 schema 版本戳）
  test/navigation-smoke.test.mjs
```

`scripts/check_ui_smoke.sh`（入口）+ `scripts/selftest_ui_smoke.sh`（判据自证）。
新 `.sh` 一律 `${var}` 写法（F13 纪律），取样面只点名文件。

### 刀 12｜锚点与守恒门（只碰当前干净的文件）

`MixCut/App/ContentView.swift:14-21` 的 `NavigationItem` 枚举处给侧栏 6 项加
`.accessibilityIdentifier("suncut.nav.<key>")`；
`ProjectOverviewView.swift` / `SchemeListView.swift` / `BGMLibraryView.swift` / `ExportView.swift` /
`SettingsView.swift` 各加 1 个容器锚点。命名 `suncut.<area>.<element>`（机器身份小写，
与 bundle id `com.suncut.app` 一致，不跟 `SunCut` 显示名漂）。

**明确不碰**（F15）：`MixCutApp.swift`、`ImportView.swift`、`SegmentLibraryView.swift`、
`DebugSelfTest.swift`、`AgentGateway.swift`。

新增 `scripts/check_ui_anchors.sh`：Swift ↔ roster 双向对账（UI-INV-B）。
只加修饰符、不新增 Swift 文件 ⇒ 不动 pbxproj；仍跑 `scripts/check_project_integrity.sh` 做守恒确认。

### 刀 13｜导航冒烟用例与三态报告

`test/navigation-smoke.test.mjs` 走 7 个目的地，每页：点击 → 前后 source.xml diff →
`navigationTitle` 变更断言 → 存在性/坐标/重叠断言。产物：终端表 + `artifacts/<ts>/` 存证 + HTML。
「导航后是否空白帧」不另造尺子，直接调 `scripts/measure_nav_blank.sh` +
驱动原生 `macos: startNativeScreenRecording`（F11），结论回灌给 G 系台账。

### 刀 14（**挂起；前置 = 你的 IT-TOMB 在制品落地或提交**）｜App 自报数据根

在 `DebugSelfTest.swift` 加一个上报分支，把生效中的 `FileHelper.appSupportDirectory`
写进 `MIXCUT_SELFTEST_OUT` 报告，使假库判据从单向变**双向可证伪**——
这样即使将来有人改动 `FileHelper.swift:17-25` 的 `#if DEBUG` 分支或改名，UI 环会判红而非静默跑在活库上。
该文件当前带 +394 行未提交在制品（F15），此刻插笔代价最高 ⇒ 让位。
在此之前，P0-2 由刀 11 的外部三查独立顶住，不构成裸奔。

## 4. 🔴 前置硬门槛：判据矩阵

| # | 判据 | 怎么证明它会红（扰动自证） |
|---|---|---|
| U01 | 产物必须是 Debug | 把 `appium:appPath` 指到 Release 产物 → 必须报 `FAIL[判据失效]`，不得绿（F9）。**校验点见 §9 新坑：要扫 `Contents/MacOS/*.debug.dylib`，扫主二进制两边都是 0** |
| U02 | 假库根生效且可写 | 把假库路径指向不可存在的位置 → 红 |
| U03 | 8787 未被外部实例持有 | 手动占住 8787 → 必须在任何写操作**之前**红（F8） |
| U04 | 活库未被触碰 | 跑完比对 `~/Library/Application Support/Suncut` 校验和 → 变了即红。**基线必须含 `Suncut.store.launch-ledger` 与 `-shm`**——§9 实测证明 App 一启动就写这两颗，"只读探针"不成立 |
| U05 | 契约表不含 `amText` 谓词 | 塞一条 `amText` 用例 → 必须拒跑而非崩掉整条会话（F5） |
| U06 | 行为断言未被重试洗绿 | 合成一条必然失败的行为断言 → 必须保持红（UI-INV-D） |
| U07 | 锚点双向守恒 | Swift 加一个未登记锚点 → 红；roster 留一条 Swift 已无 → 亦红（UI-INV-B） |
| U08 | 报告标注构建配置 | 报告首行缺 `Debug` 标记 → 红（F7 引出的仓内纪律） |
| U09 | **点击有效性自证（v1.2 新增，前置）** | 跑任何用例之前，点一个可回退目标并断言其状态变化（如侧栏 `selected` false→true）；无变化即红并打印「系统设置→隐私与安全性→辅助功能 加入 Xcode Helper」指引。**不许退化成某条用例失败**——§9 实测：缺授权时 `macos: click` 静默返回不抛错 |
| U10 | **事件通道自证（v1.3 新增，覆盖鼠标 + 键盘）** | 两条通道各测一次可回退动作（点「新建项目」应弹表单 / 按 ⌘N 应弹表单），任一不通即红；并打印 `automationmodetool` 的实测读数与解除命令。**U09 单独不够**——§10 实测：辅助功能已授的情况下鼠标与键盘仍全灭 |
| U11 | **探针目标有效性前置（v1.4 新增，U09/U10 的地基）** | 任何"点了没变 ⇒ 通道不通"的推论之前，必须先实测该目标 `enabled==true` **且**其触发效果已被单独证实过。**实测反例**：`素材导入` 在空库下 `enabled=false`、`新建项目、⌘N` 虽 `enabled=true hittable=true` 但点击永不触发动作——拿它们做自证会得到**无法支持的根因结论**（v1.3→v1.4 就是栽在这上面）。当前唯一已证实可靠的自证探针是 **`设置`**（0.5s 内必现 `API/通用/Agent/DeepSeek 配置/保存/测试连接` 面板） |

**与既号码段的互斥声明**（UI-INV-G）：`U*` 只用于本案运行时判据；
`G*` 属 `check_navigation_readiness_guards.sh`，`T-*` 属前案 §17.3 E2E 列，`TC-*` 属 `test_project_guards.sh`。

**效力上限（不许当已验证）**：dump 级断言看不到 `hittable`/`visible`/`focused`（F3）；
UI 环首期不覆盖任何写路径、不覆盖播放、不覆盖导出；自动遍历未开工；
前案 TG-INV-* 的认领**等其 §4 五格矩阵定稿**，在此之前凡依赖其形态的行标「待定稿后认领」，不许占号。

## 5. 存量真值（工作量口径，本轮实测自数）

| 项 | 读数 |
|---|---|
| 可观测节点 | 69（window 子树）/ 261（全树，含 170 系统菜单栏） |
| 产品码自定义 `accessibilityIdentifier` | 0 |
| 导航目的地 | 7（`NavigationItem` 枚举 `ContentView.swift:14-21` 的 6 个 case + 设置） |
| `@Test` 条数 | 551（行首实测；仓内文档口径 550） |
| 既有门禁 | 11 颗（8 check + 2 selftest + test_project_guards） |
| 计划要碰的 9 个文件中的脏文件 | 3 个（另 `DebugSelfTest.swift` 带 +394 行在制品） |
| 依赖体积 | 240M（`node_modules` 119M + `appium-home` 121M） |
| 新会话成本 | ≈35s；会话内单次 `findElements` 8–300ms |
| 首期锚点预算 | 12–15 个 |
| 现有中文 `.accessibilityLabel(` | 47 处（另 6 处为 `accessibilityLabel:` 自定义函数形参，含字样共 53），大量含插值如 `"\(spoken)提前"`、「逐段重听进度 \(progress)」⇒ 不可作稳定定位依据 |

## 6. 决策记录（含撤销条件）

| 决策 | 撤销条件 |
|---|---|
| 首期禁用 MCP 播种，fixture 只走快照文件复制 | 若给 `AgentGateway` 加了 DEBUG 端口覆盖可解禁；那是跨模块产品码变更，须单独确认 |
| 假库首期靠外部三查，App 自报推迟到刀 14 | `DebugSelfTest.swift` 的 +394 行在制品落地/提交后即执行刀 14 |
| 认领前案 TG-INV-* 延后 | 前案 §4 五格矩阵定稿后逐条认领 |
| 判据另开 `U` 段 | 永久，除非全仓统一编号方案出现 |
| 点击需 Xcode Helper 辅助功能授权（人工一次性） | 若实测证明只读即可满足导航断言可省；退路是 `macos: deepLink` 切页 |
| 快照内嵌 schema 版本戳并与 `SchemaVersions` 比对 | schema 若改为其它真源，判据跟着换口径而不是悄悄恒真 |
| 用例严格串行、禁并行 | 永久（F16：驱动端口占用互杀） |

## 7. 验证

1. `bash scripts/check_ui_smoke.sh` rc=0，终端表 7 行全 PASS，HTML 与 source.xml 落盘，首行标 `Debug`。
2. `bash scripts/selftest_ui_smoke.sh` 让合成违规树变红；若变绿则脚本自身以非 0 退出并报「判据失效」。
3. `bash scripts/check_ui_anchors.sh` 双向各扰动一次均红（U07）。
4. U01–U08 逐格实跑并登记读数；读数推翻描述时改描述、不改读数。
5. 每页点击前后 source.xml diff 显示 `navigationTitle` 由上一页变为本页 ⇒ 证明是真实事件链，不是状态旁路。
6. 整轮墙钟 ≤5 分钟，记录在报告首行。
7. 跑完 `pgrep -fl "WebDriverAgentRunner-Runner|xcodebuild.*WebDriverAgentMac"` 为空、`pgrep -x SunCut` 为空。
8. 回归无害：`bash scripts/check_project_integrity.sh` 与既有 551 条 `@Test` 全绿；
   改动集内不含 F15 那四个文件。
9. 假库独立性：跑完活库校验和未变（U04），且 artifacts 里记录的假库路径落在 `UITests/.fixture/`。

## 8. 明确不做

不搭 CI、不上云 runner、不管多机型多系统矩阵；不做像素级视觉 diff；
首期不做自动遍历（遍历产物将来是「待测控件清单报告」，不是门禁判据）；
不改 `FileHelper.swift` / `AgentGateway.swift` 的端口与开关语义；
不在 UI 环里断言数据层不变量（那是单元/集成层的活）；
不碰当前的 39 个在制品文件；不静默 `npm install`（缺依赖只报错并给出确切命令）。

## 9. 步骤 1 交付记录（v1.2）：假库已通，点击静默无效

探针落在 `.scratch/mac2-poc/test/{fake_root_probe,click_probe,tcc_probe}.mjs`，
被测产物 `.scratch/dd/Build/Products/Debug/SunCut.app`（今天 15:08 构建，含你 +394 行 IT-TOMB 在制品码）。

### 9.1 假库开关端到端生效（实测 ✅）

链路：`appium:environment` → 驱动 `FBSessionCommands.m:141` `app.launchEnvironment = [launchEnv copy]`
→ `FileHelper.swift:21` 读 `MIXCUT_DEBUG_APP_SUPPORT_ROOT`。
假根下确实建出了完整数据目录：

```
fake-appsupport/Suncut/
  Suncut.store              233472B
  Suncut.store-shm           32768B
  Suncut.store-wal               0B
  Suncut.store.launch-ledger 13151B
  whisper-models/
```

⇒ 刀 11 的 `guards.mjs` 判据形状可以定死为「假根下出现 `Suncut/Suncut.store`」。

### 9.2 活库零污染（实测 ✅，U04 成立）

跑完对基线做 `shasum -a 256 -c`：`Suncut.store` / `-wal` / `-shm` 三颗**全部 OK**，mtime 未变。

### 9.3 反向证据：「只读探针」这个说法被证伪（实测）

昨天那次**Release** 探针跑完后，活库的 `Suncut.store.launch-ledger` 与 `-shm` mtime 变成 `14:19:52`
—— 正是探针时刻。⇒ **App 一启动就自己写这两颗，UI 层一行不点也写**。
所以 U04 的基线必须把 `launch-ledger` 与 `-shm` 算进去，不能只比主 store 文件。

### 9.4 真实点击静默无效（实测 ⚠️，原因推断）

| 观测 | 读数 |
|---|---|
| `macos: click` 是否抛错 | **否**，正常返回 |
| 侧栏「素材导入」`selected` | `false` → `false` |
| window 子树节点集（type+label+title+坐标+selected 全字段） | 改前后**完全相同**（节点数 29→30 是同一 key 的重复行，无新元素） |
| 驱动/WDA 日志里的权限报错 | 无（`showServerLogs=true` 也没抓到任何 TCC 线索） |

**实测**：点击不生效且无任何报错。
**推断（未证）**：原因是缺 Xcode Helper 辅助功能授权（驱动官方 `docs/getting-started/index.md` 要求，本机从未授过）。
这一步只能由用户在「系统设置 → 隐私与安全性 → 辅助功能」里手动完成，agent 代不了。

> **v1.3 订正：上面这条推断被实测推翻。** 用户完成辅助功能授权后复测，鼠标点击仍零变化，键盘通道同样不通；
> 真实根因见 §10。保留原文不删，按仓内惯例以订正条覆盖。

⇒ 评审里列为 P2 的「静默降级为点了没反应」在授权之前就被抓到，已升级为前置判据 **U09**：
门禁必须在任何用例之前做一次点击有效性自证，失败即红并打印授权指引。

### 9.5 两个新坑（实测）

1. **Xcode 16 Debug 用 dylib 注入**：`Contents/MacOS/SunCut` 只有 **58K**（stub），真身是
   `SunCut.debug.dylib`（**24M**）+ `__preview.dylib`。⇒ **U01 若只 `strings` 主二进制，
   Debug 与 Release 都读 0，判据恒绿**。必须扫 `Contents/MacOS/*.debug.dylib`。
   实测对照：Debug 的 dylib 命中 `MIXCUT_DEBUG_APP_SUPPORT_ROOT` 与 18 个 `MIXCUT_SELFTEST*`；
   Release 主二进制命中 **0** ⇒ F9/P0-2 在本机被直接坐实。
2. **空库首启态不能当导航判据**：假库无项目时窗口标题回退成 `"SunCut"`（不是页面名，
   与 `SchemeListView.swift:82-84` 那条「唯独这里没有 navigationTitle，窗口标题会退回」同型），
   且详情区是「创建新项目」空态。⇒ 导航断言不能靠窗口标题或 label 集合（侧栏 label 恒定不变会淹没差异），
   必须用页面专属锚点或 `selected` 位。

### 9.6 下一步（顺序即优先级）

1. 你手动给 Xcode Helper 授辅助功能权限 → 我立刻重跑 §9.4 那一格，把「推断」变「实测」。
2. U09 自证进刀 11 的 `guards.mjs`（不通过就不跑任何用例）。
3. 造 `fixtures/store.snapshot/`（含 ≥1 项目 + 少量素材），否则分镜库/方案页在空库下不渲染，
   导航冒烟只能验到侧栏。

## 10. 事件通道根因（v1.3，实测闭环）

### 10.1 排除链（逐格实测，探针在 `.scratch/mac2-poc/test/`）

| # | 测法 | 读数 | 结论 |
|---|---|---|---|
| 1 | 辅助功能授权后复测侧栏点击（`tcc_probe.mjs`，读 `selected`） | `false → false` | 授权没解决 |
| 2 | 换无可辩驳目标——点「新建项目」应弹表单（`click_decisive.mjs`），排除"我选了个不会变的属性"这个混淆项 | sheet `0→0`、window `1→1`、输入框 `0→0`、label 数 `14→14`、新增/消失集合均空 | 不是判据选错，界面真没变 |
| 3 | 键盘通道鉴别：⌘N（`Command = 1<<4 = 16`，注意不是 NSEvent 那套 1048576） | 同样零变化 | **不是鼠标专属，整个事件合成通道被挡** |
| 4 | appium server 在授权后重启后重跑第 2 步（排除 TCC 归属缓存在旧进程） | 仍零变化 | 不是进程缓存问题 |
| 5 | `automationmodetool` 只读读数 | `Automation Mode is ENABLED.` `This device requires user authentication to enable Automation Mode.` | 根因锁定 |

### 10.2 根因

macOS 12+ 的 **Automation Mode**：XCTest 向**其它 App** 合成输入事件需要系统鉴权；
非交互进程发起时没有可批准的窗口 ⇒ 事件被**静默丢弃且不抛错**。
读通道（元素树 / 属性 / 截图）不走这条路 ⇒ 全功能正常。这就是"能读不能点"的完整解释。

两处官方证据互相印证：驱动自家 CI `.github/workflows/functional-test.yml` 有独立一步
`sudo automationmodetool enable-automationmode-without-authentication`；本机
`appium driver doctor mac2` 第 3 条实跑读数即 `✖ Automation Mode requires user authentication`（列为可选修复项）。

### 10.3 解除路径（**待你拍板，一条都未执行**）

| 选项 | 动作 | 代价 |
|---|---|---|
| A | `sudo automationmodetool enable-automationmode-without-authentication` | 机器级安全设置变更：解除后本机任意进程都可能借 XCTest 合成输入事件。驱动 CI 用的正是这颗，但那是 SIP 关闭的一次性 runner，你这台是长期开发机 |
| B | 保持鉴权，跑测试时人在场批准系统弹窗 | 无法无人值守 ⇒ 与已锁定决策「agent 改完码自动跑」直接冲突 |
| C | 首期只做**只读环**：不点击，改用 `macos: deepLink` 或 MCP 工具切页，再断言界面结果 | 零安全变更、立刻能动；但测不到真实事件链，导航冒烟降级为「切页可达性 + 布局」。且两条切页路径**均未验证**本 App 是否支持内部路由 |

推荐顺序：先按 C 把只读环、三查、锚点守恒门落地（不碰任何安全设置、不阻塞），
A 作为独立决定另做——它一旦通过，U10 自证就会自动转绿，届时把 §10.1 那五格重跑一遍即可。

### 10.4 已验证仍然成立的部分

§9.1 假库开关端到端生效、§9.2 活库零污染、§9.5 Debug/Release 机械区分法
—— 都与事件通道无关，照旧可用。

## 11. v1.4 撤回 §10 的根因结论：探针目标无效导致的假阴性

### 11.1 我错在哪

§10 那五格排除链有一个共同缺陷：**三次"点击无反应"的读数，全部用没有验证过有效性的目标做**。
抓到 WDA 原生输出之后才发现真相——日志里 `Synthesize event` 逐条执行、无任何权限报错，
说明事件早就在合成。换目标立刻见分晓：

| 目标 | 实测 `enabled` | 实测结果 | 判定 |
|---|---|---|---|
| 侧栏 `素材导入` | **`false`** | 点击零变化 | **无效探针**：空库无项目时它本来就禁点 |
| 侧栏 `新建项目、⌘N` | `true`（`hittable=true`，frame 有值） | 点击零变化（通道正常时也不变） | **无效探针**：该控件不由点击触发动作 |
| 侧栏 `设置` | `true` | **0.5s 内弹出** `API/通用/Agent/DeepSeek 配置/显示密钥/保存/测试连接` | ✅ 有效探针 |
| 空态 CTA `创建新项目` | `true` | **0.5s 内弹出** `新产品/取消/创建/继续/更新` | ✅ 有效探针 |

⇒ §10.2 那句"根因是 Automation Mode 鉴权"**撤回**：它建立在一批证明不了任何事的读数上。
同样也**不能**归功于辅助功能授权或 Automation Mode 解除——这两项变更确实已生效
（`Automation Mode is disabled. This device DOES NOT REQUIRE user authentication`），
但"变更前是否本来就能点"从未被有效测过，因果未证。

### 11.2 这条错误的代价与防线

代价不是白跑几轮，而是**差点把一层测试体系的地基建在一个虚构的根因上**：
如果照 §10 的结论往下走，会去做"解除安全设置"这类真实变更，而真正的问题只是探针选错。

防线落成 **U11**（见 §4）：任何"点了没变 ⇒ 通道不通"的推论之前，必须先实测目标 `enabled==true`
**且**其触发效果已被单独证实。事件通道自证固定用 `设置`（已实测 0.5s 必现新面板），不用侧栏导航项。

### 11.3 顺带查出来的两条真事实

1. **`macos: click` 对 `enabled=false` 的控件静默无操作**，不抛错、不报 `invalid element state`。
   ⇒ 所有点击类用例必须**先断言 `enabled`**，否则"功能没生效"和"控件本来禁点"永远分不清。
2. **`设置` 打开的是同窗口内的面板**（window 计数不变、无 Sheet 节点），
   而 `创建新项目` 打开的表单同样不产生 `XCUIElementTypeSheet` 节点
   ⇒ 用 `sheet/window` 计数做"弹出了什么"的判据在这套 SwiftUI 里**不成立**，
   必须用**新增 label 集合**做判据（实测有效）。
3. 侧栏导航项（`素材导入` 等）在**空库无项目**时整排 `enabled=false`
   ⇒ 这直接证明 §9.6 第 3 条「造 `fixtures/store.snapshot/`」不是优化项而是**硬前置**：
   没有预置项目，导航冒烟一条都跑不了。

### 11.4 当前机器状态（可撤销项，记录备查）

- Xcode Helper 已加入「系统设置 → 隐私与安全性 → 辅助功能」（用户手动）。
- Automation Mode 已解除鉴权：`Automation Mode is disabled.`（用户 `sudo automationmodetool enable-automationmode-without-authentication`）。
  撤销命令 `sudo automationmodetool disable-automationmode-without-authentication`
  （该子命令名**已试探存在**：直接执行会进入密码提示，未授权即失败、不改状态；
  试探本身是一次变更调用，失败后系统读数仍为 `Automation Mode is ENABLED. / DOES NOT REQUIRE user authentication`，未被改动）。
- 以上两项与"点击能用"之间的因果关系**未证**（§11.1）。
