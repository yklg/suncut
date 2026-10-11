# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 开发工作方式要求

**必须优先使用已安装的专业 agent 和 skills 来完成 macOS 原生应用的所有开发工作**，包括但不限于：

- **设计/架构**: 使用 `everything-claude-code:planner`、`everything-claude-code:architect` 等做方案设计
- **编码**: 使用 `swiftui-patterns`、`swift-concurrency-6-2`、`swift-actor-persistence` 等 Swift/SwiftUI 专业 skill
- **Code Review**: 使用 `everything-claude-code:code-reviewer` 做代码审查，每次改完代码都要 review
- **安全审查**: 使用 `everything-claude-code:security-reviewer` 检查安全问题
- **Debug**: 使用 `everything-claude-code:build-error-resolver` 修复编译错误
- **测试**: 使用 `everything-claude-code:tdd-guide` 做测试驱动开发
- **发版**: 修复完成后主动用多个 agent 并行审查（代码质量 + 安全 + 架构），确保分发质量

不要手动逐步试错，遇到问题直接调用对应的专业 agent 一步到位解决。

## 项目概述

> **用户约定**：用户说「SC」即指 SunCut 本应用（原名 MixCut，用户嘴里说「MC」时也是它）。凡是"SC 的项目 / 让 SC 导入 / SC 导出"等说法，一律指调用本机 suncut MCP 服务（http://127.0.0.1:8787/mcp，24 个工具）操作 SunCut。

SunCut 是一款 macOS 原生桌面应用（SwiftUI + SwiftData），面向广告投放团队的 AI 视频混剪工具。用户导入广告素材视频，AI 自动按语义切分镜头并标注类型，然后智能排列组合生成多条差异化的混剪广告视频。

> **名字分三层，别混着改**：
> - **给人看的**：产品名/产物名/进程名 = `SunCut`（`SunCut.app`、`pkill -x SunCut`、`Contents/MacOS/SunCut`），由 `Brand.displayName` + pbxproj `PRODUCT_NAME` 两处一致决定，`check_project_integrity.sh` 会对账。
> - **机器身份（小写，不跟拼写漂）**：bundle id `com.suncut.app`、MCP 注册名/日志名 `suncut`。翻这些 = 再迁一次设置域 + TCC 重新授权。
> - **盘上目录**：`~/Library/Application Support/Suncut/`（一次性迁移时的名字）。翻它 = 再搬一次 3GB 模型与库。
> - **仓库与工程名仍是 `MixCut`**：`MixCut.xcodeproj` / scheme `MixCut` / target `MixCut` / `Sources/MixCutCore/` 都不动。

## 构建与运行

- **必须使用 Xcode 编译**（SwiftData 宏依赖 Xcode 编译器）
- 在 Xcode 中通过 `File → Open` 打开 `Package.swift`，或打开 `MixCut.xcodeproj`
- 最低要求：macOS 14.0 (Sonoma)，Swift 5.10+，Xcode 15.0+
- 无第三方 SPM 依赖

### 外部工具依赖（内置于 app bundle，用户无需安装）

- **FFmpeg**: 视频处理（镜头检测、静音检测、缩略图、导出拼接）— 内置于 `Resources/bin/`
- **Whisper (whisper.cpp)**: 本地语音识别（ASR）— 内置于 `Resources/bin/`
- **Whisper 模型**: `ggml-small.bin` (~488MB) — 首次使用时自动下载到 `~/Library/Application Support/Suncut/whisper-models/`

> **核心原则：开箱即用** — 像剪映一样，用户双击即可使用，不需要安装 homebrew、FFmpeg、Whisper 等任何外部依赖。
> 内置二进制均为**静态自包含 universal（arm64 + x86_64）**，无外部 dylib，支持 Intel Mac。
> 由 `./scripts/build_universal_binaries.sh` 生成（下载静态 ffmpeg + 源码编 whisper/demucs + `lipo` 合并）；
> `bundle_deps.py` 现为校验器（检查 4 个二进制是否就位且双架构）。`Resources/bin/` 为 gitignored 本地产物。
> 开发期间如果 bundle 内二进制不可用，会 fallback 到系统安装的版本（仅开发便利，不应依赖）。

## 架构

### 分层结构（MVVM + Service Layer）

```
App/          → 入口 + 主路由（MixCutApp, ContentView）
Models/       → SwiftData 模型（10 个 @Model 类，含 ProjectVideo 中间表；清单真源是 SchemaVersions.swift 的 AppSchemaV1.models）
ViewModels/   → @Observable VM，持有 Service 引用，@MainActor
Services/     → actor 隔离的业务逻辑，无 UI 依赖
Views/        → SwiftUI 视图，按功能分子目录
Utilities/    → KeychainHelper, FileHelper
Resources/    → AI Prompt 模板（.md 文件，通过 Bundle 加载）
```

### 数据模型关系

```
Project *──* Video 1──* Segment        （视频全局共享，通过 ProjectVideo 多对多关联）
Project 1──* MixScheme 1──* SchemeSegment *──1 Segment
Project 1──* ProjectVideo *──1 Video   （中间表）
```

- **全局共享**：同一视频（SHA-256 哈希相同）全局只有一个 Video 实体和一组 Segment，多项目共享
- 导入已分析视频秒级完成（直接创建 ProjectVideo 关联，不重复处理）
- 在任何项目中修改分镜，所有项目即时同步
- 视频文件按 hash 存储在全局目录 `AppSupport/Suncut/Videos/{hash}/`
- `Project`: 7 种状态（created → importing → analyzing → ready → generating → completed → archived）
- `Video`: 6 种状态（imported → detectingScenes → transcribing → analyzing → completed → failed）
- `Segment`: 11 种语义类型（SemanticType，支持多个）+ 3 种位置类型（PositionType，单个）

### AI 服务架构

采用 **AIProvider 协议** 支持多提供商（千问 / MiniMax），均通过 OpenAI 兼容 API 调用：

- `AIProvider` 协议 → `OpenAICompatibleClient`（通用 OpenAI 兼容格式，支持千问和 MiniMax）
- `AIProviderManager` 工厂 → 根据 UserDefaults 中保存的设置创建实例（Service 层每次调用动态获取，Settings 变更立即生效）
- API Key 存储在 UserDefaults（已移除 KeychainAccess 依赖，避免开发期钥匙串弹窗）
- 用户在 Settings 窗口（macOS 原生 `Settings` scene）选择提供商和模型

### 核心数据流水线

视频导入后的处理流程（`ImportViewModel.importSingleVideo`）：

1. 复制文件到应用目录 + AVFoundation 提取元数据
2. FFmpeg 生成缩略图
3. **本地分析**（SceneDetectionService）：场景切换检测 + 静音检测 + I-frame 提取
4. **ASR 语音识别**（ASRService）：Whisper 本地执行，输出字级时间戳
5. **AI 语义分析**（AIAnalysisService）：仅发送结构化文本数据给 AI（不发送视频）
6. **四阶段边界优化**（BoundaryOptimizerService）：句子吸附 → 场景对齐 → 静音吸附 → I-frame 对齐

方案生成采用**两步架构**（`SchemeGenerationService`）：
- Step 1: AI 生成策略（风格、受众、叙事结构）
- Step 2: AI 基于策略选择具体分镜组合

### 关键设计决策

- **不直接传视频给 AI**：所有视觉/音频信号由本地 FFmpeg 精确提取，转为结构化数据后传给 AI 做语义决策
- **每步独立容错**：导入流水线每个步骤失败不阻塞后续步骤（元数据/缩略图/ASR/AI 分析各自 try-catch）
- **视频删除即取消**：`cancelledVideoIDs` 集合跟踪已删除视频，处理中的任务会在 checkpoint 处跳过
- **沙盒已关闭**：`com.apple.security.app-sandbox = false`，直接使用 `Process` 调用 FFmpeg/Whisper
- **导航方式**：不使用 NavigationSplitView，而是自定义 `HStack` 布局（固定宽度侧边栏 + 详情区域），通过 `NavigationItem` 枚举 + `@State selectedNavItem` 切换视图

### Prompt 模板

AI 提示词模板存放在 `MixCut/Resources/Prompts/`，通过 `PromptLoader` 从 Bundle 加载：
- `segment_types_definition.md` — 11 种语义类型定义（被 AIAnalysisService 加载）
- `video_recombination_prompt.md` — 方案生成（被 SchemeGenerationService 加载）
- `ad_styles.md` — 10 种广告风格（被 SchemeGenerationService 加载）
- `recombination_principles.md` — 混剪原则（被 SchemeGenerationService 加载）
- `video_segmentation_prompt.md` — 分镜标注参考（未被代码直接引用，prompt 在 AIAnalysisService 中内联构建）

## 开发工作流

- **编译后自动重启应用**: 每次 xcodebuild 编译成功后，必须执行 `pkill -x SunCut; sleep 1; open <DerivedData路径>/Build/Products/Debug/SunCut.app` 自动重启用户的应用（进程名与产物名都是 SunCut；杀用户实例前先跟用户确认）
- **DerivedData 路径**: `/Users/yilukaige/Library/Developer/Xcode/DerivedData/MixCut-bwzwtxgcuznkvsbxqcduvqzndian/`（目录名仍随工程名走 `MixCut-<hash>`，产物在其 `Build/Products/Debug/SunCut.app`）
- **版本号以「发版」动作为准（2026-07-28 修订）**：只在用户明确要发版时才 bump 版本号（VERSION + pbxproj 两处 MARKETING_VERSION），平时改代码、打测试包**都不动版本号**。测试包内部版本号抬高会导致同事装了之后收不到真正新版的更新提示。
- **测试包按需打，不自动打**：日常改动只做 Debug 编译+重启验证；用户要分发测试时才打 Release 测试包，命名 `SunCut-v<当前版本>-<用途>-test.dmg`（如 `SunCut-v0.9.2-mcp-test.dmg`），一看即知是测试包。正式发版包才叫 `SunCut-v<新版本>.dmg`。
- **⚠️ 产物文件名必须带版本号**：**绝不允许**打成 `SunCut.dmg`。桌面上会同时存在多个包，不带版本号分不清也没法传网盘。卷名（`-volname`）同样带版本号。
  ```bash
  # 0. bump 版本号（VERSION 文件 + pbxproj 的两处 MARKETING_VERSION 必须一致）
  # 1. Debug 编译 + 重启本地应用
  xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build
  pkill -x SunCut; sleep 1; open <DerivedData>/Build/Products/Debug/SunCut.app
  # 2. Release 编译 + 打包 DMG（后台执行，不阻塞用户）
  # ⚠️ 必须带 universal 参数，否则默认只编本机 arm64，Intel Mac 装了报「不支持此应用程序」
  xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Release \
    -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
  V=$(cat VERSION)
  TEMP=$(mktemp -d) && cp -R <DerivedData>/Build/Products/Release/SunCut.app "$TEMP/" && ln -s /Applications "$TEMP/Applications"
  cp -R Licenses "$TEMP/"
  # GPL 对应源码：打包前取回（gitignored，不进仓库），并以 REQUIRE_SOURCE=1 硬校验
  mkdir -p Licenses/source && for v in 8.1 8.1.2; do f="Licenses/source/ffmpeg-$v.tar.xz"; [ -f "$f" ] || curl -fL --retry 3 --max-time 600 -o "$f" "https://ffmpeg.org/releases/ffmpeg-$v.tar.xz"; done
  REQUIRE_SOURCE=1 ./scripts/check_license_notice.sh
  rm -f ~/Desktop/SunCut-v${V}.dmg
  hdiutil create -volname "SunCut ${V}" -srcfolder "$TEMP" -ov -format UDZO ~/Desktop/SunCut-v${V}.dmg
  rm -rf "$TEMP"
  ```

  > **发版前务必校验 DMG 内主程序是 universal**：`lipo -archs <app>/Contents/MacOS/SunCut` 应为 `x86_64 arm64`。
  > 普通 `xcodebuild ... Release build`（不带 `-destination generic + ARCHS`）只出 arm64，会悄悄丢掉 Intel 支持。
  > 同时校验 DMG 内 `CFBundleShortVersionString` == 目标版本号（挂载后用 PlistBuddy 读），别只信构建目录。

## 自己先测试，别让用户当测试员（必须遵守 ⚠️⚠️⚠️）

**改完代码必须先自己跑、自己看、自己点，确认没问题再交给用户**。具体要求：

1. **每次改 UI 后必须**：编译 → `pkill -x SunCut; open <app>` 重启 → 用 `screencapture -l <window-id> /tmp/check.png` 截图查看效果，或自己用 LSP/编译反馈反复验证
2. **不能验证的**（比如需要鼠标交互、播放视频、跨多个视图状态切换等），列出明确的"用户必须测试项"清单，注明每项验证步骤
3. **绝对不允许**："看上去应该没问题"、"理论上能跑"、"等你测一下"这种把验证甩给用户的话
4. **每个 commit 之前**必须确认本次改动**自己肉眼看过/截过图**，不光是编译通过

> **背景**：之前我多次只编译就 commit，结果 UI 完全坏掉用户才发现。这是浪费用户时间的根因，必须杜绝。

5. **判据脚本要在用户那个 locale 下再跑一遍**：`LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xxx.sh`。
   我的执行环境是 `LANG=""` / `LC_CTYPE=C`，而 macOS 自带 bash 3.2 在 UTF-8 下会把紧贴在变量展开后面的
   全角标点首字节吞进变量名，`set -u` 当场死在第一条判定上 —— 2026-09-30 就是这个差异让守卫脚本
   「我这边 24 条全绿、用户一跑两行就死」。写法约定：消息串里变量一律加花括号（`${label}` 后再接全角括号），
   `scripts/check_project_integrity.sh` 已把它变成机械门（全仓 `.sh` 命中数必须为 0，`bash -n` 测不出这类运行期错）。
6. **守卫脚本扫目录必须先定取样面，否则包内二进制会冒充代码。** `MixCut/Resources/bin/` 里躺着 whisper 等成品
   可执行文件，它们自带的帮助文本含有 `--prompt`、`ggml-large-v3.bin` 这类字样，`grep -rn 模式 $ROOT/MixCut`
   会把两颗二进制各算一处 ⇒ 判据恒红，而红被当成"真违规"（2026-09-30 实测：ASR 守卫的 G21、G6a 就是这么红的）。
   两种写法按判据性质选：**找代码构造点的**加 `--include="*.swift"`；**找品牌/署名残留的**加 `-I`
   （排除二进制但保留 `.md`/`.json`/`.plist` 的覆盖 —— 那些位置的真残留必须抓得到，用 `--include` 会把它一起漏掉）。

## 视频显示比例（必须遵守 ⚠️）

**SunCut 的所有视频素材都是信息流广告，目标投放在手机端，统一使用 9:16 竖屏比例**。

任何展示视频画面 / 缩略图 / 视频预览的视图，**必须使用 9:16 竖屏比例**（手机端纵向），不能使用 16:9 横屏或正方形比例。具体约束：

- 缩略图卡片：宽高比 = 9:16（例如 width=140 → height≈250）
- 内嵌播放器（`SegmentInlinePlayer`、`SegmentPreview` 等）：同样使用 9:16
- 不要为了"塞下两行台词"而压扁视频区域；要么调整卡片整体尺寸，要么把台词放到视频下方

如果新增任何展示视频或视频缩略图的视图，**审查时必须验证比例是 9:16**，不是请立刻调整。已经存在的视图也应该按这个规则审计修正。

## 数据模型注意事项

- `Segment.semanticTypesData` 是 `Data?`，通过计算属性 `semanticTypes: [SemanticType]` 读写（JSON 编解码）
- 旧版代码曾用 `semanticType: SemanticType` 单字段存储，已迁移到多类型。旧数据通过 `MixCutApp.fixMissingSemanticTypes()` 在首次启动时修复（填充默认值「过渡」）
- `Segment.keywords` 同理使用 `keywordsData: Data?` + 计算属性
- `Video.asrSentences` 使用 `asrSentencesData: Data?` + 计算属性存储 Whisper 原生句子段

## Git 与发版规则（必须遵守）

- **不要自动提交 git 和发布版本**：修改代码后只做编译+重启+打包 DMG，不要执行 `git add/commit/push` 和 `gh release`。必须等用户验证没问题后，用户明确要求才能提交和发版。
- **不要自作主张 `git tag` 或 `gh release create`**：版本号和发布时机由用户决定。

### 分发方式（v0.7.1 起，现行）：DMG 走百度网盘，release 只放下载页链接

DMG 内置 Whisper 大模型约 **1.6GB**，挂 GitHub Release 附件传得慢，所以不放附件（见下方链路：正文只指向下载页）。
现行分发链路是 **固定下载页 + versions.json + 用户提供的网盘分享链接**：

- **下载页**：http://47.119.175.47/mixcut/ （nginx `location ^~ /mixcut/` → `/www/wwwroot/dlpage/`）
- **版本库**：`/www/wwwroot/dlpage/versions.json`，结构 `{"mac":[{version,date,size,url},…], "win":[…]}`，
  每平台一个数组、**最新在最前**；主按钮取 `[0]`，弹窗列出全部历史版本（老链接一律保留）。
- **发新版 = 往对应数组最前面 prepend 一条**，改完即时生效。

**⚠️ 各自的职责边界（务必分清，我曾搞错）**：

| 谁 | 做什么 |
|---|---|
| 我（Claude） | 只负责：bump 版本 → 打带版本号的 DMG → 提交/推送/打 tag → 发 GitHub release（**正文指向下载页，不传附件**） |
| 用户 | 把桌面上的 DMG 传到**百度网盘**，把分享链接（含提取码）发给我 |
| 我（拿到链接后） | 把链接 prepend 进服务器的 `versions.json` |

> **绝对不要自作主张把 DMG 上传到服务器 `/dl/`**。那是早期方案的遗留兜底路径，现行流程里包由用户放网盘。

**发版标准动作全序列**：
1. bump 版本号（VERSION + pbxproj 两处 MARKETING_VERSION）→ clean Release universal 构建 → 打 `SunCut-v<版本>.dmg`
2. 四项强制校验：主程序 `lipo -archs` == `x86_64 arm64`、5 个内置二进制均双架构、DMG 内 `CFBundleShortVersionString` == 目标版本、DMG 内含 `Licenses/`
3. `git commit` → `git tag vX.Y.Z` → `git push origin main` → `git push origin vX.Y.Z`
4. `gh release create vX.Y.Z --title … --notes-file …`（**不传 DMG**，正文「下载」段指向下载页）
5. **等用户给百度网盘链接** → 更新服务器 `versions.json`

**凭据**：服务器 `CN_SSH_*` 在项目根 `.env`（gitignored，绝不提交/外传）。
服务器登录用**密码**不是 key，且密码含特殊字符：
- 绝不能 `source .env`（`#` 会截断密码）；要 `grep -E '^CN_SSH_PASSWORD=' .env | sed -E 's/^CN_SSH_PASSWORD=//; s/^"(.*)"$/\1/'`
- ssh/scp 必须带 `-o PreferredAuthentications=password -o PubkeyAuthentication=no` + `sshpass`

（改已发版本的正文用 `gh release edit vX.Y.Z --notes-file`，不需要 release id。）

## 关键开发规则（必须遵守）

### 双系统（Universal）支持铁律 ⚠️⚠️⚠️

SunCut 必须**同时原生支持 Apple Silicon 与 Intel Mac**。任何构建、发版、二进制改动都必须保持 universal，绝不能退回 arm64-only（否则 Intel 同事装了直接报「这台 Mac 不支持此应用程序」）。

1. **主程序**：Release/DMG 构建必须带 `-destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`。普通 `xcodebuild ... Release build` 只出本机 arm64，**严禁**用它打分发包。
2. **内置二进制**：ffmpeg / ffprobe / whisper / whisper-cpu / demucs 必须都是 universal（arm64 + x86_64）静态自包含二进制，由 `./scripts/build_universal_binaries.sh` 生成；改动或更新任何内置二进制后，必须重跑该脚本并 `python3 bundle_deps.py` 校验。
3. **发版前强制校验**（缺一不可）：
   - `lipo -archs <app>/Contents/MacOS/SunCut` == `x86_64 arm64`
   - 五个内置二进制逐个 `lipo -archs` 均为双架构（或直接 `python3 bundle_deps.py`）
   - DMG 内 `CFBundleShortVersionString` == 目标版本号
   - DMG 根目录内有 `Licenses/`（通告 + GPL-3 全文 + `source/` 两颗 ffmpeg 源码包），且
     `REQUIRE_SOURCE=1 ./scripts/check_license_notice.sh` 绿 ——
     这条守的是「通告里登记的体积、configure 参数与随包源码，确实对得上包内这颗二进制」；
     不打进去就等于没履行告知义务。开发期不带 `REQUIRE_SOURCE` 跑，缺源码包只 WARN 不判红。
4. **新增任何内置二进制/处理链组件**：默认就要做成 universal，并纳入 `build_universal_binaries.sh` 与 `bundle_deps.py` 的校验清单。

> 背景：v0.6.0 曾因 arm64-only 分发导致 Intel 同事「不支持此应用程序」；v0.6.1 起整条链改为 universal。此后**任何发版都必须守住双系统**。

### 许可与署名（不是残留，别顺手清理）

- 根 `LICENSE` 有**两行**版权：`MengGang`（原始版本作者）与 `一路凯歌HNaa`。MIT 要求保留各方版权声明，
  **删掉任何一行都不算"清理残留"**。TC-06 那条剥离原作者身份的守卫只扫 `MixCut/` 源码树、够不到根目录 ——
  别把它推广到这里。
- `Licenses/NOTICE-内置组件许可.txt` 里第 2–5 项标 ⚠️ 的"许可文本未核验"是**如实声明**，不是待办占位符：
  公开发布前须逐条取回文本并销标，**不许为了好看先把 ⚠️ 删掉**。

### 不要在修改过程中破坏已有功能（最重要 ⚠️⚠️⚠️）

修改任何代码前，**必须先识别该文件/模块已有的功能点**；改完后这些功能必须依然完整可用。**严禁为了修一个问题而误伤相邻功能**。

#### 强制 SOP（每次代码改动都必走）
1. **改动前**：通读要改的文件 + 周边文件（相同 view tree），用一句话列出"这里能做的事"（点击/双击/编辑/选中复制/拖拽/右键菜单/键盘快捷键/项目切换联动 等等）。
2. **改动中**：每次修改只针对当前任务，不要顺手"重构"周边代码。
3. **改动后**：人工跑一遍受影响的视图，**逐项验证**第 1 步列出的能力，确认没破坏。
4. **疑似删改**：不确定某段代码的作用时，先查 `git blame` / `git log`，不要随意删改。

#### 已知容易被误伤的功能清单（动相关文件时必须回归验证）
- **素材导入页**：台词行双击编辑、台词文本选中复制、视频卡片文件名选中复制、卡片右键菜单
- **分镜素材库**：多选模式（checkbox + 全选/反选/清空）、批量导出（编号 + 命名规则）、批量删除、Equatable 性能优化、`isHovering/isSelected` 控制 BoundaryAdjustRow 显示
- **分镜库 / 项目概览 / 素材导入**：切换项目时的**数据联动刷新**（详见下一节"切换项目铁律"）
- **导出**：默认 H.264 硬件加速、分镜导出第一帧不黑屏（trim filter + setpts 重置时间戳）
- **强制浅色外观**：`MixCutApp.init()` 中 `NSApplication.shared.appearance = .aqua`
- **应用启动恢复上次项目**：`ProjectViewModel.setModelContext` 末尾的 lastSelectedProjectID 恢复
- **缩略图全局缓存**：`ThumbnailCache.shared`，不要重新引入 `NSImage(contentsOfFile:)` 直接同步加载
- **Toast / InlineBanner / SkeletonView**：全局共享组件，新视图需要错误提示/loading 时复用

#### 当出现 bug 时不要"修一个改坏三个"
本项目已多次出现"修一个 bug 把别的功能改坏"的情况。**当你的改动跨越多个文件 / 改了核心视图时，必须用第 3 步的人工验证来兜底**，不要假设 SwiftUI 的 diff 会保护你。

### 切换项目时各模块必须联动刷新（多次踩坑，铁律 ⚠️）

所有依赖项目数据的视图，必须使用以下两种之一加载数据：

```swift
// ✅ 写法 A：onAppear + onChange（最稳）
.onAppear { viewModel.loadData(for: project) }
.onChange(of: project.id) { viewModel.loadData(for: project) }

// ✅ 写法 B：.task(id: project.id) — 在 project.id 变化时自动重新执行
.task(id: project.id) {
    viewModel.loadData(for: project)      // ⚠️ 视图里不要再放 isLoading，见下一节
}

// ❌ 错误：仅 onAppear（切换项目时视图复用不会重新触发）
.onAppear { viewModel.loadData(for: project) }
```

#### 骨架屏判据：住在 ViewModel，而且**换项目不许上屏**（2026-09-30 闪屏事故，两轮才修对）

**绝对不要**在模块视图里写 `@State private var isLoading`。`ContentView.detailView(for:)` 是
`@ViewBuilder switch`，分支返回不同**类型**，所以**每次点侧边栏切模块，旧视图实例都被销毁、新实例被重建** ——
视图自己的 `@State` 必然回到初始值，于是本该只为「切项目」服务的骨架屏每次切模块都上一帧。这是第一轮修掉的闪屏。

第二轮才量出来：**骨架屏自己上屏的那几帧，就是残余跳动的本体**。`mainContent → SkeletonView → mainContent`
这次结构翻转要在同一次提交里拆掉整棵旧内容树，主线程被占住、窗口拿不到新帧 —— 逐帧实测侧栏区连续
3–10 帧（**50–133ms**）完全没有内容。消融对照：把内容区整块换空仍剩 33–50ms（换入换出本身的底价），
**不亮骨架则 359 帧一帧不丢**。所以判据只能看「屏上还有没有东西可留」：

```swift
// ✅ 正确：骨架只在「屏上还没有任何项目数据」时亮；换项目不换分支，旧画面留屏但禁点
Group {
    if viewModel.readiness.needsSkeleton {
        SkeletonView(layout: .segmentLibrary)
    } else {
        mainContent
            .allowsHitTesting(viewModel.readiness.holdsData(for: project.id))
    }
}
.task(id: project.id) {
    viewModel.loadSegments(for: project)   // 加载末尾自己 markLoaded
}

// ❌ 错误一：视图自持开关 —— 每次切模块都被重建复位，闪屏复发
@State private var isLoading = true
// ❌ 错误二：needsSkeleton(for: project.id) —— 判据长出项目维度，换项目就又上一次骨架
```

`needsSkeleton` **不带任何参数**。它一旦长出项目（或模块）维度，闪屏当场复发。
换项目期间屏上是**上一个项目的画面**，靠 `holdsData(for:)` 禁点补回来，不靠遮罩 ——
禁点不是可选项：画面上那些按钮的回调捕获的是**新的** `project`（如「上传自建分镜」走
`importSelfSegments(into: project)`），那 150ms 不关窗口就是跨项目误操作。

机械判据：`scripts/check_navigation_readiness_guards.sh`（G01 整棵 `MixCut/Views` 里 `isLoading` 必须为 0，
G04/G05/G13 锁两条判据的接口面与禁点落点，G15 锁冷启动预热及其每进程一次的闸门，G14 保证一次性探针已删净）。
量法：`scripts/measure_nav_blank.sh <录屏.mov>`（逐帧「边缘能量塌缩」）。**改过导航或渲染就必须跑它**，
判据：切项目时侧栏区空白 ≤ 1 帧。

**修完之后仍然剩下的那一次骨架**：冷启动后第一次进某个面 —— 那个 VM 连一个项目都没加载过，屏上确实没东西可留，
`needsSkeleton` 为真是正确判定。但它照样要付那 100ms 空窗，所以 `ContentView.onAppear` 给分镜库表面**预热一次**
（闸门 `readiness.loadedProjectID == nil` ⇒ 每进程至多一次；实测 load 0–11ms）。
这不属于「判据长出项目维度」：判据仍然无参数，只是让它从启动那一刻起就为假。

四条已被实测排除的旧假设，别再走回去（证据与数字见计划 `fluid-spring-char` §批九）：
① `loadXXX` 的调用时机 —— load 实测 0–11ms，空白 50–133ms，不是一回事（批六整批因此撤销）；
② 容器交叉淡入 —— `.animation` 整条关掉照旧跳，且空白帧是静止帧不是渐变；
③ 网格重排 / 340pt 详情栏 —— 空白帧里布局子树整体缺席；
④ 卡片与 `AVPlayer` 的拆除 —— 消融后仍剩 33–50ms，是底价不是主犯。

#### 🚨 致命陷阱：`.task(id:)` 必须放在 body 最外层

**绝对不要**把 `.task(id: project.id)` 附加在条件渲染的子视图上：

```swift
// ❌ 致命错误：骨架分支不渲染时 task 也一起消失 → 切项目不联动！
var body: some View {
    if viewModel.readiness.needsSkeleton {
        SkeletonView()
            .task(id: project.id) { ... }        // ← task 绑在条件分支上
    } else {
        mainContent
    }
}

// ✅ 正确：task 在 Group 外层，无论当前走哪个分支都监听 project.id
var body: some View {
    Group {
        if viewModel.readiness.needsSkeleton { SkeletonView() } else { mainContent }
    }
    .task(id: project.id) {        // ← task 跟随整个 view 生命周期
        viewModel.loadData(for: project)
    }
}
```

**为什么犯过这个错**：2026-05-23 我把性能优化的 task 绑到了 SkeletonView 上，导致从其他项目切回来时（已经不需要骨架）task 不触发，数据停留在上一个项目。这种错误**视觉上一切正常但数据完全是错的**，必须人工切项目验证才能发现。

#### 换项目会「露出上一个项目的残留」的，不能只靠 `.task` 清

`.task(id:)` 跑在**首帧之后**。任何「换项目必须当帧就不该看到」的东西（红色错误 banner、跨项目的选中/预览），
放在视图的 `.task` 里会晚一帧露出来 —— 视图没有骨架屏挡着时尤其明显。这类清理挂在常驻的壳上：
`ContentView` 的 `.onChange(of: projectVM.selectedProject?.id)`。

#### 检查清单（改完依赖项目的视图必须人工跑一遍）
1. 项目 A → 项目 B：视频列表、分镜、统计数据是否变成 B 的？
2. B → A 回切：A 数据完整？
3. 多选状态下切项目：选中状态是否清空？
4. **概览 ↔ 素材导入 ↔ 分镜素材库 来回切 ≥3 次：不得出现灰骨架屏，不得向白底塌陷**（换模块判据）。
4b. **停在分镜素材库页，点侧栏项目名来回切 ≥4 次：不得有任何一帧侧栏整块没内容**（换项目判据）。肉眼容易看漏，跑 `scripts/measure_nav_blank.sh` 出数，要求侧栏区空白 ≤1 帧。
4c. **完全退出 App 再启动（预热闸门是每进程一次，热启动测不出回归），进去后第一次点「分镜素材库」：不得出现空窗**（冷启动判据）。同一条尺子的期望值：**整段录屏空白段 = 0**；出现 1 段 100ms 就是预热被删/失效。
5. 从概览的「快速操作」按钮进去（这些写入没包 `withAnimation`）与从侧栏行进同一页，淡入时长看起来是否一致、有无回弹？
6. 项目 A 的素材导入页报错时直接切到项目 B：banner 必须在切换那一帧就不在（不能"闪一下 A 的报错再消失"）。
7. 日志里 `[Perf] <模块>` 有、`[Readiness]` 没有 → 判为骨架卡死而非加载慢。

#### 各模块现在的加载方式（改视图时按这表核对，别再往回退）
- ProjectOverviewView：`.task(id: project.id)` 调 `projectVM.refreshOverviewSnapshot(for:)`；骨架由 `projectVM.readiness.needsSkeleton`（无参数）决定，换项目留旧画面 + `holdsData(for:)` 禁点
- SegmentLibraryView：`.task(id: project.id)` 调 `viewModel.loadSegments(for:)`；同上，由 `viewModel.readiness` 决定
- ImportView：**无骨架屏**（正文实时读 `project.videos`，SwiftData 的 Observation 就是权威源）；`.task(id: project.id)` 只剩封面预热
- SchemeListView、ExportView（用 `onAppear + onChange`，同样没有骨架屏）
- 跨项目残留清理（`importVM.errorMessage` 等）挂在 `ContentView` 的 `.onChange(of: selectedProject?.id)`，不放视图的 `.task`
- `ContentView.onAppear` 额外给 `segmentLibraryVM.loadSegments(for: 启动选中的项目)` 预热一次，带 `loadedProjectID == nil` 闸门（每进程至多一次）。**这不是把加载搬上导航边界**：视图自己的 `.task(id:)` 一行没动，预热只是把「第一次进这个面」的那次骨架提前消掉；别顺手把它改成每次换项目都跑（实测那条方向批六整块撤销过）
新增视图如果依赖项目数据，必须遵循以上模式；机械判据见 `scripts/check_navigation_readiness_guards.sh`。

### Schema 变更：备份门已装在开库前，改代码阶段仍要手动留一份

**先纠正一条害人的旧命令**：本节原先写的 `cp ~/Library/Application Support/default.store …` 指向的是
2026-04-21 的 73KB 死库。真库在这里，而且跑 WAL 模式，**三件套必须一起**（实测现网 `.store` 348KB
而 `.store-wal` 2.16MB —— 最近的写入几乎都在 WAL 里，只拷主文件等于拷半份库）：

```bash
cd /Users/yilukaige/mixed_cut-main
TS=$(date -u +%Y%m%d-%H%M%S)
mkdir -p .scratch/store-backup-${TS}
cp ~/Library/Application\ Support/Suncut/Suncut.store* .scratch/store-backup-${TS}/
```

改 SwiftData 模型（增删字段、改类型、改关系）时的流程：

1. **动手前先手动留一份三件套**（上面的命令）。运行时那道备份门只在**开库前**触发，
   改代码阶段它救不了你。
2. 模型清单与版本锚点在 `MixCut/Models/SchemaVersions.swift`（`AppSchemaV1` = 当前 10 个 `@Model`）。
   开库走 `MixCut/App/SchemaGuard.swift`：算描述行 → 指纹比对 → 变更分类 → 需要时备份三件套 →
   `PRAGMA integrity_check` 自证 → 才建 `ModelContainer`。
3. **只增行**（加可选字段、加实体）会被判成轻量兼容 ⇒ 备份后照常开库。
   **有行消失**（删字段、改类型、改属性名、改关系）判成不可自动迁移 ⇒ **拒绝开库**并给出备份路径。
   这时不要绕门：补一个 `AppSchemaV2` + `MigrationStage.custom`。
   ⚠️ 别说"装回上一个版本就行"——这句 2026-10-11 被实测证伪：sidecar 里的 `lines` 是**单调棘轮**
   （每次成功开库都覆盖成当时那个二进制的 schema），所以任何**更旧**的二进制在同一棵数据根上都会被这道门
   一起拒掉。真正的退路是把 `.backup` 目录里的四件（`.store`/`-wal`/`-shm`/`.launch-ledger`）原样放回。
   门现在把写下记录的版本号一起记进 `Ledger.appVersion`（**必须是 Optional**，否则老 sidecar 解码失败
   ⇒ 读成"首次带门启动" ⇒ 这道防线被静默废掉），界面据此把"跑的是旧产物"与"代码真删了字段"分开说。
4. 门的两处已知不完备，写在这而不是藏在代码里：
   - 新增**必需且无默认值**的字段会落在"只增"，轻量迁移不一定过得去 —— 那种失败会走内存降级，
     其文案已改成**不指引删库**；
   - `#Index` 变更**不进指纹**（`Entity.indices` 要 macOS 15+，本工程部署目标 14.0），
     所以"指纹没变"只能读成"除索引外没变"。
5. 机械判据：`LC_ALL=en_US.UTF-8 ./scripts/check_schema_ledger_guards.sh`（SL-01~14）——
   `@Model` 与 `AppSchemaV1.models` 逐名对账、清单/动作条数相等、`did…_v1` 键与账本**双向**覆盖、
   `orphanGC` 的 `requires` 必须含三颗、有真信号的步骤必须回报 `Bool`、防线文案不得叫用户删库、
   启动账本 `Ledger` 里老 sidecar 可能没有的键**必须是 Optional**（SL-14：带默认值也不行，
   Swift 合成解码器不查默认值，实测 `keyNotFound`）。启动顺序与前序约束的**唯一来源**是
   `MixCut/App/LaunchSteps.swift` 的清单，别退回平铺调用。

### 不要由工具去打开用户的活库（这条原先只写在脚本注释里，2026-10-11 补上判据与出处）

真库在 `~/Library/Application Support/Suncut/Suncut.store`，跑 **WAL** 模式。
即使以只读方式打开，SQLite 也可能要创建/改写 `-shm` 边车 —— **那是写副作用**。
所以：

- 要读库里的东西，**把 SQL 打印给用户自己跑**（照 `scripts/verify_graph_broadcast.sh` 步骤 ③ 的写法），
  或改走不碰库的路子：启动账本 `Suncut.store.launch-ledger` 是纯 JSON、产物二进制可 `strings`、文件可 `stat`。
- 真要代跑，三个条件缺一不可：`sqlite3 -readonly` + 先 `pgrep -x SunCut` 确认应用已退出 + 用户显式同意。
- 机械判据：`bash scripts/check_live_store_guards.sh` —— 扫全仓 `.sh`，任何对 `*.store` 的
  `sqlite3` 调用少了 `-readonly` 或同文件没有"活实例未运行"前置就红；写语句直接红；
  注释与 heredoc 内的例子不算调用（区分器由台架 M7/M8/M9 三格钉住，防它退化成"见啥都放过"）。

## 撤销浮条与延迟删除

- **撤销条可见性的唯一来源是状态机的 `armed` 相位**（`Sources/MixCutCore/UndoGraceMachine.swift`）。
  `ToastCenter` 只管瞬时提示，**不许**再携带 `actionTitle` / `action` —— 一旦撤销条退回那条单槽，
  任意一条 2.2 秒提示就会把正在倒计时的 5 分钟宽限顶成装饰（这就是 1.3 审查判"表面修补"的那个形状）。
- 两类事务共用一条通道：延迟删除（`schedule`，300 秒，了结时**欠一次真删**）与
  批量覆盖（`scheduleUndoOnly`，5 秒，改动已落库、到点不欠东西）。
- `flushNow()` 在切项目 / 数据重载前必须调（现有 4 处），且它**同帧收回浮条**。
  恢复一律是"放回"而非"重建"，且**永不依赖 SwiftData 内置 UndoManager**（它一挂删除就崩）。
- 批量撤销的闭包会在删除宽限期之内跑，所以对快照里每个对象先验 `modelContext != nil` 再写 ——
  对已 delete 的对象写属性直接崩（见下面「数据库保存」同级的崩溃记录）。
- 机械判据：`LC_ALL=en_US.UTF-8 ./scripts/check_undo_guards.sh`（UG-G01~08），
  自证 `./scripts/selftest_undo_guards.sh`（8 条判言逐条可被对应违规变红）。

## 已知问题与改进方向

- **数据库保存**: `try? ….save()` 吞错仍剩 **48 处**（2026-10-01 实数，`grep -rEc` 口径见 SL 守卫脚本头），
  后续应逐处换 `safeSave`/`saveOrWarn`；启动链上那三处会连累孤儿 GC 的已收口，由 SL-08 钉住不许退回
- **并发安全**: 多视频并行导入时共享 ModelContext 可能有竞态风险（当前实际为顺序处理）
- **Schema 版本**: 已采纳 `VersionedSchema`（V1 = 采纳点，`stages` 为空是当前正确状态）；
  启动链上那 19 颗一次性迁移的账本正在收进 `LaunchStepLedger`，见 `docs/superpowers/plans/2026-09-30-upstream-012-portability.md`
- **样式规范**: 已创建 `DesignTokens.swift`（Corner/Spacing/Padding），部分视图已迁移，其余视图待统一

## 开发阶段

当前处于 **Phase 1 MVP 进行中**。
- 素材导入 + AI 分析流水线已完成（8 步处理链）
- 分镜素材库浏览/筛选/微调已完成
- 混剪方案生成 UI + 两步 AI 流程已搭建
- 视频导出功能骨架存在（ExportView + ExportService）
- 端到端方案生成 → 导出流程待验证
详见 `PRODUCT_SPEC.md`。
