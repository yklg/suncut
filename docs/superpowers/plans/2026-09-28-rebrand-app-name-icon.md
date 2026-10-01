# 改名与换图标 · 实施计划 v2（2026-09-28）

新品牌名：**Suncut**。
v1 经 `architecture-first-fix` 评审判定**需返工**（硬标尺 1「根因层级」不通过、标尺 2「非遮盖」部分不通过）。v2 按评审结论重写：不再做清单式替换，改为先把品牌收敛成单一来源，再换名。

## 0. 根因（v2 的出发点）

「改个名」之所以难，是因为**这个品牌工程没有身份单一来源**。实测落点：

| 落点 | 位置 |
|---|---|
| bundle id | `generate_xcodeproj.py:500,529` 两处字面量 → 注入 pbxproj（**行号已因 2026-09-28 插入守卫而漂移，原文写 485/514**；且脚本现已拒绝运行，见 §8） |
| 产品名 | `PRODUCT_NAME = "$(TARGET_NAME)"`，即 target 名 |
| 数据目录 | `FileHelper.swift` 4 处裸 `"MixCut"`（18/22/35/323 行） |
| 日志目录 | `OpenAICompatibleClient.swift:7` 把 `"com.mixcut.app/logs"` 写死在 Swift 源码 |
| MCP 身份 | `AgentToolCatalog.swift` 的 `serverInfo.name` 与 instructions 里「用户常说简写：MC」 |
| 更新检查 | `UpdateChecker.swift:33-35` 三个原作者 URL |
| UI 文案 | `OnboardingView` 57/88/254、`SidebarView:40`、`SettingsView:622`、`MixCutApp.swift:174` |
| 发版 | `release_gitee.sh:26,73,79` |
| 文档规范 | `CLAUDE.md:21`「用户说 MC 即 mixcut MCP」、README、PRODUCT_SPEC |

**结论**：逐处替换只消除本次症状，下次新增文案/目录/URL 会再散落一份。v2 的目标是让「改名」这件事本身变成**改一个文件 + 跑一次测试**。

## 1. 采用的模式：沿用仓库已有的 VERSION 单一来源先例

`generate_xcodeproj.py:37` 的 `_detect_marketing_version()` 读 `VERSION` 文件 → 注入两处 build config（484/413 行）。品牌照抄同一形状，不发明新机制：

- 新增 `BRAND` 文件（一行一值，与 `VERSION` 同风格）：`name=Suncut`、`bundle_id=com.local.suncut`、`data_dir=Suncut`、`store=Suncut.store`、`log_dir=suncut`、`mcp_server_name=suncut`、`agent_short_name=SC`
- 生成器从中取 target 名与 bundle id 注入 pbxproj
- 生成器同时产出 **`Sources/<Core>/Brand.swift`（生成物，禁止手改）**，暴露上述常量
- `FileHelper`、`OpenAICompatibleClient`、UI 文案、`AgentToolCatalog`、`UpdateChecker` 全部改读 `Brand`
- **结构性防线**：新增一条纯逻辑单测——全仓不得出现裸 `"MixCut"` / `"com.mixcut.app"` 字面量，白名单只放 `Brand.swift` 与生成物。该测试 `swift test` 即可跑，不需要 Xcode。

依赖方向：`Brand`（最底层纯逻辑）← FileHelper / Services / Views / AgentToolCatalog。无反向依赖、无循环、无常量之外的行为。

## 2. 分阶段实施（每阶段独立可验，不许大爆炸）

| 阶段 | 内容 | 验收 |
|---|---|---|
| **1** | 内部标识重命名：`MixCutApp`→`SuncutApp`、`MixCutCore`→`SuncutCore`（`Package.swift` target/path、`Tests/SuncutCoreTests` 目录、34 个 `@testable import`、生成器路径） | `swift test` 全绿；`xcodebuild ... Debug` 成功 |
| **2** | 建 `BRAND` + 生成器注入 + 产出 `Brand.swift`；把上表 9 类落点的字面量**改为读 Brand，值仍是 MixCut** | 新增守卫测试通过；App 行为与阶段 1 完全一致（名字仍显示 MixCut）——这一步证明抽象没漏 |
| **3** | 只改 `BRAND` 一个文件为 Suncut 值 → 重跑生成器 → 重编 | 显示名/目录/bundle id/MCP 名一次性全变；守卫测试仍绿 |
| **4** | 图标：先备份原 10 张到 gitignored 的 `build/icon-backup/`，再用新 1024 源图 `sips` 切 10 个尺寸**同名覆盖**（`Contents.json` 与 pbxproj 不动） | 重编后 Dock/⌘Tab 图标生效 |
| **5** | `UpdateChecker.swift` 三个 URL 改读 Brand（或整块停用）；`release_gitee.sh` 的 DMG 名与 Release 标题 | 不再指向原作者仓库 |
| **6** | 文档层：`CLAUDE.md:21`（「MC」约定→「SC」）、README、PRODUCT_SPEC；`scripts/mcp_smoke_test.sh:22` 的 `assert len(tools) == 9` → 23 | 后续 AI 会话不会按旧约定行事 |

阶段 3 的验收本身就是这套架构的**存在性证明**：如果换名不是只改一个文件，说明还有字面量漏在外面。

## 3. v1 漏项（已并入）

1. `OpenAICompatibleClient.swift:7` 的 bundle id 字面量。
2. **TCC 与 LaunchServices**：换 bundle id 后系统按新身份重新弹「允许访问文稿/下载文件夹」，⌘Tab 会短暂出现新旧两条目。属预期现象，写进验收说明，避免被当成 bug。
3. **文档规范层**：`CLAUDE.md` 是给 AI 协作者的操作性规范，不改会误导后续会话。
4. **pbxproj 确定性 ID 全量漂移**：`make_id("target_MixCut_app")`、`make_id("project_MixCut")` 以名字为种子，改名后 pbxproj 变成全文件 diff，「比对引用数」这一判据太弱。
   **升级为 `./scripts/check_project_integrity.sh`**（逐名双向校验：源码树里每个 `.swift` 都要有 PBXBuildFile + Sources phase + PBXFileReference 三处，
   反向还要证明没有悬空引用；同名文件会直接判「判据失效」而非蒙混通过；末尾再跑 `xcodebuild -list`）。
   **原文写的「`grep -c '.swift'` 校验引用数（基线 93 App + 35 Core）」不成立**：生成器只扫 `MixCut/`，产不出那 35 条 Core 引用，
   实测重生成后是 92/0（见 §8）。数总数会被「同时增删」掩盖，必须逐名。
5. **迁移不能靠空库躲过去**。本次因为 `list_projects` 返回 `[]`，可直接删旧目录；但计划必须写下将来的正解：若已有数据要换 bundle id/目录，在 `FileHelper` 加一次性搬迁（照 `MixCutApp.swift:800-847` 的 `default.store` 迁移形状），并按 `CLAUDE.md:316` 铁律先备份 `MixCut.store`。

## 4. 待定默认值（不另外提问，用户可随时改）

- bundle id：`com.local.suncut`（占位；对外分发前建议换成真实域名，改一次 `BRAND` 即可）
- 数据目录：`~/Library/Application Support/Suncut/`，store 为 `Suncut.store`
- MCP `serverInfo.name`：`suncut`；Agent 简写约定：`MC` → `SC`
- 保留 `MixCut/` 源目录名（不出现在任何用户可见处，收益最低）

## 5. 明确不改

10 个 `@Model` 类名：`Project` `Video` `Segment` `MixStrategy` `MixScheme` `SchemeSegment` `ProjectVideo` `SegmentDub` `PhysicalShot` `ShotVariant`。SwiftData 把实体名持久化进 store schema，改任一即 schema 变更 → 旧库打不开、退到 `MixCutApp.swift:157-174` 的内存模式兜底（表现＝数据全丢），需显式迁移映射。
澄清：store **文件名**可改（只是路径），不可改的是这些**类名**。

## 6. 总验收（走用户可观察结果，不看进程号）

- ⌘Tab / 菜单栏 / Dock 显示 Suncut、新图标
- `~/Library/Application Support/Suncut/` 被创建，旧目录不再被写
- `defaults domains` 出现 `com.local.suncut`；Settings 填 Key 后重启仍记得住
- MCP：`initialize` 回 `serverInfo.name = "suncut"`；`tools/list` 为 **23**（用修好的 `mcp_smoke_test.sh` 跑，不是手数）
- `swift test` 全绿，含新的品牌守卫测试
- 回归主链：导入一个真实视频 → 出分镜 → 导出一条 MP4（对照 `CLAUDE.md:241` 易误伤清单）

## 7. 前置输入（缺一项就停在对应阶段）

- 图标源图 1024×1024：**待用户提供**，或授权我用 ImageGen 生成
- 真实视频素材一条用于阶段 6 回归：**待用户提供**（仓库里 `康王视频/` 是 gitignored 的测试素材，本机没有）
- ASR 链路要通还需 `brew install whisper-cpp`（否则导入后台词为空，回归只能验到「出分镜」为止）

## 8. 来自另一窗口的实测勘误（2026-09-28，见 `2026-09-28-strip-original-author-identity.md` §1/§2.3/§10）

**A. 一处阻塞性事实，会影响 §1、§2 阶段 3**
`MixCut.xcodeproj/project.pbxproj` **不是该脚本的纯生成物**：它含 **36 条手工追加的 `Sources/MixCutCore/*.swift` 编译引用**
（App target 扁平编译这些文件、无 `import`；手工痕迹是 ID 形状 `0FA1B2C3D4E5F60718293A4B/C` vs 生成器的 `md5(name)[:24].upper()`）。
生成器只扫 `MixCut/`，**跑一次就把这 36 条抹掉 → App target `cannot find type` 编译失败**。
现在脚本开头已加**无条件硬失败守卫**（检测到 `Sources/MixCutCore` 即 `SystemExit`，无 `--force` 旁路），
所以本文所有「重跑生成器」的步骤（§1 的注入 `Brand.swift`、§2 阶段 3）**都会直接非零退出**。
正解二选一：① 给生成器补扫 `Sources/MixCutCore`（并解决手工 ID ↔ md5 ID 映射，使「重生成 == 仓库 pbxproj」成立）；
② 全程手工编辑 pbxproj 的四个 section。两者都要求把 §3.4 的判据换成逐名校验。

**B. 阶段 1 的真实成本被低估**
`MixCutCore`→`SuncutCore` 会牵动那 36 条 fileRef 的 `path = Sources/MixCutCore/...`。
在生成器不可用的前提下，这是 **36 处手工路径改写 + 逐名 diff 自证**，不是一行 target 名的事。

**C. 表 §0 里已有两项被本窗口做掉，请划掉**
- 「更新检查 `UpdateChecker.swift:33-35`」→ **文件已删**，pbxproj 里 7 条引用已手工清除，`MixCut/` 内 0 引用。§2 阶段 5 的前半作废。
- 「日志目录 `OpenAICompatibleClient.swift:7` 写死」→ 已收敛为 `MixLog.logFileURL` 单一真源，三条用户文案改指它。§3.1 已完成。
  ⚠️ 但 `"com.mixcut.app/logs"` 这**一处**是设计上的真源，§1 那条「全仓不得出现裸字面量」的品牌守卫测试
  **白名单必须包含它**，否则阶段 2 一起步就必红。

**D. §7 第 3 条存疑**
「ASR 要通还需 `brew install whisper-cpp`」与仓库的自包含设计冲突：`scripts/build_universal_binaries.sh` 会把
`whisper`（arm64 Metal + x86 CPU）与 `whisper-cpu`（兜底）装进 `MixCut/Resources/bin/`，`ASRService` 有 GPU→CPU 降级链。
brew 那条请先核实来源再保留。

**E. 可直接复用的现成资产**
- `scripts/check_project_integrity.sh` —— 逐名双向引用守卫（同名文件会判「判据失效」而非蒙过；含 `xcodebuild -list`）。
  改名后它仍是主判据，比数总数强。
- `scripts/test_project_guards.sh` —— 「旧品牌字样整棵源码树归零」的形状可直接搬来当 Suncut 的收口判据。
  注意它带 `PBX_PATH` 覆盖口，专门用来在「改动前」的快照上自证会红（防恒绿）。

## 9. 落地记录与勘误（2026-10-01 按实测回写；本文与现状不符处以本节为准）

**已落地，但与本文原写法不同**

- 阶段 2/3 的真源是 `Sources/MixCutCore/Brand.swift`，**手写而非生成物** —— §1 设想的「生成器产出 `Brand.swift`」
  没走通，因为 §8A 那颗守卫把生成器无条件拦死了。值已翻：`shortName=suncut`、`dataDirectoryName=Suncut`、
  `storeFileName=Suncut.store`、`displayName=SunCut`、`abbrev=SC`；旧路径另立 `legacy*` 一组，只给一次性迁移读。
- **bundle id 实录 `com.suncut.app`**，不是 §4 的占位 `com.local.suncut`。pbxproj 两处
  `PRODUCT_BUNDLE_IDENTIFIER` 与 `PRODUCT_NAME = SunCut` 已一致。
- 阶段 4 图标：AppIcon 10 张已换。**本文漏了一处** —— `docs/screenshots/logo.png` 是 README 顶部图，
  换图标时它仍是旧「MC」立体标，2026-10-01 才从新 AppIcon 重生成 256×256。

**阶段 1 未做，且这是有意保留的真名（别当残留清掉）**

`Package.swift` 仍 `name: "MixCut"`、target 仍 `MixCutCore`；工程文件仍叫 `MixCut.xcodeproj`，
target `name = MixCut` / `productName = MixCut`，只有 `productReference` 是 `SunCut.app`（`project.pbxproj:748-763`）。
⇒ 文档里凡出现 `MixCutCore`、`open MixCut.xcodeproj`、`-scheme MixCut` 都是**当前真名**，
改成 Suncut 就是文档说假话（README 已就此写了一句提醒）。这正是 §8B 估的「36 处手工路径改写」那一档成本，没付。

**判据现状（一条已失效，必须点名）**

- §0 落点表「发版 → `release_gitee.sh:26,73,79`」一行已随文件消失：该脚本 2026-10-01 删除（渠道改成只走 GitHub，
  且 `CLAUDE.md` 早已判它「会强制上传 1.6GB DMG 到 Gitee，必然失败」）。阶段 5 的后半随之作废。
- §6「MCP `tools/list` 为 **23**（用修好的 `mcp_smoke_test.sh` 跑）」**未落地**：`scripts/mcp_smoke_test.sh:22`
  至今仍是 `assert len(tools) == 9`，从没修过。这条要么按实测工具数改对、要么删掉 —— 挂着就是一条永不响的假防线。
- §3.4 的逐名判据已由 `scripts/check_project_integrity.sh` 承担；`scripts/test_project_guards.sh` 的 TC-05
  改成从 `Brand.swift` 现场读 `bundleID` 推期望值（不写死字面量），换品牌时判据自动跟着换口径。

