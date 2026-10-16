# SL-12 后续：把 done 键的**写入**搬进启动账本（计划 v2.1，待批）

日期 2026-10-01 · 作者 Qoder · 状态：**未获批准，本文件之外零改动**

> **判据编号改名（2026-10-16，台账 §6-13）**：本文件里那些"提案中、尚未落地"的守卫编号
> 原先也叫 `SL-13a/13b/…/21`，而 `SL-` 号位属于**已入库**的 `scripts/check_schema_ledger_guards.sh`
> （现存 SL-01…SL-16，含 03b）—— 其中 13/14/15/16 四颗已经被这两天的真实判据占用且**含义完全不同**
> （13=产品归属回填、14=Ledger 新键必须 Optional、15=容器之前的名册、16=账本两种失败不许同形）。
> 同号不同义正是 T4 要收的那类口子，所以本文件的提案一律换成 **`LLG-`** 前缀，数字不变，
> 交叉引用因此不受影响。那份计划若将来获批落地，再按**当时脚本里未占用**的 `SL-` 号位重编并留映射。
> 注意：文中 `SL-12` 指的是已入库那颗棘轮（标题「SL-12 后续」与 §3.15 的说法），**不改**。

> **v1 → v2（`architecture-first-fix` 审查后并入，四条必改全采纳）**
> P0-1 LLG-13 与已拍板的 A 自相矛盾（写键语句实测不止一处）⇒ 判据重写成"从清单读"的三条；
> P0-2 根因只写到"两个作者"这一层，**更深一层是记账的寿命与被记的数据不同命**⇒ §2 重写、新增岔口 D；
> P1-3 缺"每颗必须可重入"这条不变量 ⇒ 新增 I-6 与 R-7；
> P1-4 `bodies` 表允许 `; return true` 那扇门没关 ⇒ 新增 LLG-19；
> P2-5 Core 注释里引用 App 行号会漂 ⇒ §11.1 改掉。
>
> **v2 补查（写 §2.2 时撞出来的，比审查给的更省事也更难看）：** 让记账"跟库同命"的载体**早就在**
> （sidecar，且已在 `storeFamily()` 备份族里），但它那两枚记账字段**全仓无人赋值、实测恒空**
> ⇒ 新增 §2.3，并把岔口 D 的第 2 档从"批 3 的大改"改写成"零 schema 变更、但要推翻 Q0"。
>
> **v2.1（照 v2 自己的判言复查 v2 时发现的矛盾，改在落笔前而不是落地后）：**
> §4.1 写"`markLedgerWritten` 只 `switch ledgerWrite(for: step.cadence)`"，而 `regenerateSegmentThumbnails`
> 是 `.once`、body 一 `Task {}` 排上队就 `return true`（`LaunchSteps.swift:101-104` 实测）
> ⇒ 只看节律会让 executor 在**排上队那一刻**把它的键写成 `true`，正是 §4.3 说要避免的那件事。
> "谁记账"是**第二条轴**，节律推不出来 ⇒ 新增 `LedgerAuthor`（§4.1b），I-7 那份清单改成从它派生。

## 0. 这份文件管什么

只管一件事：**12 颗 `once` 启动步骤"跑过没有"这件事，判定与记账目前分居两处，把它合成一处。**

- 上位契约是 `docs/superpowers/plans/2026-09-30-upstream-012-portability.md`（批 0 那份）。
  它 §3.2 定了账本、§3.15 把 SL-12 棘轮归零，并在 §3.9 留了这句话：
  「executor 只**读** `didXxx_v1` 不写；12 颗 `once` 的 body 仍在自己写键，搬一颗摘一颗，每搬一颗跑一次启动」。
  **本文件就是那"后续一轮"的施工计划**。两份冲突以上位契约为准；本文件若推翻它的某条裁定，会在 §9 单独摆出来要你点头。
- 不动 schema、不动模型、不动导出、不动界面。
  （唯一的例外面已由岔口 D 定 1 打开：动 `MixCut/App/SchemaGuard.swift` 那三处小改，内容见 §4.4。
  那仍是 sidecar 的 JSON 形状，**不是 SwiftData schema**；删字段后"老 sidecar 解不解得开"的判据也写在 §4.4 第 3 条。）

## 1. 现状与证据链（全部 file:line，本轮读到的）

判定与记账现在是这样分开的：

| 环节 | 住在哪 | 做什么 |
|---|---|---|
| 判定该不该跑 | `Sources/MixCutCore/LaunchStepLedger.swift:100-119` `decideStep` | `once` 查 `state.doneKeys`、`throttled` 查 `lastRunAt` |
| 状态从哪来 | `MixCut/App/LaunchSteps.swift:169-188` `ledgerState()` | 读 `UserDefaults`（真源，Q0 裁定） |
| **实际写键** | **每颗 body 自己**（`MixCut/App/MixCutApp.swift`） | 读 guard + 末尾 `set(true, forKey:)` |

12 颗 `once` 的键与它当前那处内部读写（`MixCut/App/MixCutApp.swift`）：

| # | 步骤 id | 键 | guard/写键行 | 签名 |
|---|---|---|---|---|
| 1 | `fixMissingSemanticTypes` | `didFixMissingSemanticTypes_v1` | `:296-297` guard，`:318` 写 | **`Void`**（`:294`） |
| 2 | `purgeLegacyQwenDubs` | `didPurgeLegacyQwenDubs_v1` | `:350-351`，`:386` | `-> Bool`（`:349`） |
| 3 | `purgeLongRefClones` | `didPurgeLongRefClones_v1` | `:395-396` | `-> Bool`（`:394`） |
| 4 | `resetSchemeDubSelection` | `didResetSchemeDubSelection_v1` | `:424` | `-> Bool`（`:423`） |
| 5 | `cleanExistingTranscripts` | `didCleanTranscripts_v1` | `:532` | `-> Bool`（`:531`） |
| 6 | `backfillSegmentFrames` | `didBackfillSegmentFrames_v1` | `:493` | `-> Bool`（`:492`） |
| 7 | `migrateToProjectVideoRelation` | `didMigrateProjectVideo_v1` | `:614` | `-> Bool`（`:613`） |
| 8 | `recoverFromDisk` | `didRecoverFromDisk_v1` | `:1002` | `-> Bool`（`:1001`） |
| 9 | `dedupProjectVideoAssociations` | `didDedupProjectVideoAssociations_v1` | `:460` | `-> Bool`（`:459`） |
| 10 | `ensureCustomGroupStrategy` | `didEnsureCustomGroupStrategy_v1` | `:765` | `-> Bool`（`:764`） |
| 11 | `regenerateSegmentThumbnails` | `didRegenerateSegmentThumbnailsToFirstFrame_v1` | `:816` | **`async`**（`:815`） |
| 12 | `migrateGlobalSubtitleFontRatio` | `didMigrateSubtitleFontRatioToSegment_v1` | `:1103` | **`Void`**（`:1102`） |

另有 `orphanGC` 是 `throttled(key: "lastOrphanGCAt", hours: 24)`，键写在 `:1272` 那条 `Task` 里（见 §5）。

**三条已经查实的关键事实**（不是假设）：

1. **每颗 body 只有 `LaunchSteps.bodies` 一个调用者。** 全仓扫 13 个函数名，除定义与 `LaunchSteps.swift:89-107` 之外，
   命中的全是注释、`CLAUDE.md:189` 与旧 spec/plan 文档 ⇒ 摘掉内部 guard 不会造出"第二个调用者每次都跑"。
2. **`LaunchSteps.swift:83-84` 那句注释已经过期**：它写"目前只有三颗有真信号，其余 body 一律回 `true`"，
   而 `:85-108` 的 `bodies` 表里 9 颗是直接转发 `-> Bool` 的。这句要一起改，否则下一个人按它推。
3. **两颗 `Void` 的 body 现在在骗账本。** `fixMissingSemanticTypes` 内部有四处静默早退
   （`:299` 拿不到 storeURL、`:302` `sqlite3_open` 失败、`:323` 编码失败、`:327` prepare 失败）都 `return`，
   **不写键**（记账诚实），但 `LaunchSteps.swift:89` 那句 `; return true` 会让 executor 把它记进
   `succeededThisLaunch` ⇒ **账本上的"成功"是假的**。它今天没牙（没人 `requires` 它），
   但这正是这套机制以后会长出来的牙。`migrateGlobalSubtitleFontRatio`（`:105`）同形。

## 2. 根因（分两层，v1 只写到第一层）

不是"代码重复"这种审美问题。

### 2.1 第一层：这句话有两个作者

> **"这颗成功过"这句话有两个作者，而它们可以不一致。**

body 写键的时机、条件、以及"什么算失败"，executor 全都不知道；executor 只拿到一个 `Bool`。
于是同一句话有三种口径：body 写键 = 一种，`succeededThisLaunch` = 另一种，sidecar 里那两枚字段 = 第三种
（**第三种实测恒空**，见 §2.3 —— 它连"口径"都算不上，是一段声称自己是账本的死代码）。
批 0 那三颗真缺陷（`upstream-012` §3.12-3.15）全部长在这个缝上 —— 症状都是"落库失败也记成功"，
而**修的方式是逐颗在 body 里补 `return false`**，补完之后缝还在，只是这一颗不漏了。
只要写入权还在 body 手里，下一颗新迁移作者就会重新决定一次"我什么时候写键"。

搬完之后这一层缝就没了：**body 只回答"这次有没有把改动落库"，写不写键由 executor 按节律统一决定。**

### 2.2 第二层：记账的寿命和被记的数据**不同命**（v1 漏了，评审点出来）

真源是 `UserDefaults` —— 那是**偏好域**；而被记录的事实属于**某个具体的 store 文件的数据形状**。两者寿命完全不绑：

- 全仓 `removeObject(forKey:` 只有三处命中（`MixCut/Utilities/KeychainHelper.swift:24`、
  `MixCut/Views/Shared/ThumbnailCache.swift:110`、`MixCut/Services/ASR/ASRSettings.swift:23`），
  **没有任何东西在新建库 / 放回备份时重置这十二枚 `didXxx_v1` 键**（本轮 grep 过，不是推断）。
- 而"放回备份"是**文档支持的操作**：`CLAUDE.md:416` 让你手动 `cp Suncut.store*` 留三件套，
  `CLAUDE.md:447` 写明"恢复一律是'放回'而非'重建'"。

一个动作就能撞出后果：把几个月前的备份放回 → 库里数据形状退回几周前 → 十二枚键在偏好域里仍然全是 `true`
→ **所有迁移永久跳过**，包括 `recoverFromDisk` 与 `migrateToProjectVideoRelation`。
**批 0 那道指纹门拦不住它** —— 门管的是"开库那一刻 schema 兼不兼容"，而备份的 schema 版本可能与现在**相同**
（`CLAUDE.md:426`：只增行判轻量兼容 ⇒ 备份后照常开库）。同版本、更早的数据，门是放行的。

⇒ 这一层**不是第一层修完就自动没的**。搬完写入权，"键说做过、数据其实没做过"依然成立，只是从此**只有一个作者**在错。
所以本计划把三档处置摆成**岔口 D（§9）**，要单独点头；不选就当显式欠账，不许当成"已解决"。

### 2.3 查第二层时撞出来的：跟库同命的那个载体**已经存在，但里面的账是空的**

写 §2.2 时我以为"要让记账跟库走"得新造机制。读了 `MixCut/App/SchemaGuard.swift` 之后这条判断**是错的**，两笔证据：

1. **载体就在旁边**：sidecar `Suncut.store.launch-ledger` 与库同目录同名加后缀
   （`SchemaGuard.swift:88-91`，那句注释写得很准："跟着数据根一起被搬、一起被备份"），
   而 `storeFamily()`（`:124-130`）**已经把它算进备份族** —— 我在克隆库看到的四份 `.backup` 目录里，每份都带着它。
   手动 `cp Suncut.store*`（`CLAUDE.md:416`）那个通配符也正好盖住它。
2. **可它里面的账恒空**：`Ledger` 有 `doneSteps` 与 `lastRunAt` 两个字段（`:37-38`），
   全仓 grep 下来**没有任何一处给它们赋值** —— 只有声明、初始化默认值（`:41/:44` 的 `[]` 与 `[:]`），
   和 `writeLedger` 里那句 `var ledger = previous ?? Ledger()`（`:103`）把它们**原样搬着走**。
   实测克隆库那份 sidecar（12542 字节、169 条描述行）里就是 `"doneSteps":[]`、`"lastRunAt":{}`，
   而同一时刻日志报"已记账 12"；**四份**样本全一致（当前那份 + 三份 `.backup` 目录里各一份）。

于是两份注释互相打脸：`SchemaGuard.swift:23-24` 说"描述行 + `doneSteps` + `lastRunAt` 写在同一份 JSON，
刻意不再发明第二批 `UserDefaults` 键"；`LaunchSteps.swift:168` 说"sidecar 里那份只是镜像，不参与判定"。
真实情况是第三种：**它既不是账本也不是镜像，是没接线的插座**，而它自己的注释承诺它当账本。

⇒ 岔口 D 因此有了第 2 档的**廉价版**：搬进 sidecar **不需要动 schema**（它就是个 JSON 文件，`storeFamily` 已覆盖），
代价从"批 3 的大改"降成"一次把线接上"，但仍有两处硬骨头：
一次性把偏好域里那 12 枚老键抄进去（否则老用户全量重跑，直接撞 I-4），
以及**推翻 Q0 那条"真源是 `UserDefaults`"的裁定** —— 那是上位契约的裁定，只有你能改。

## 3. 目标不变量（搬完必须逐条成立，且都要有判据）

- **I-1** **本轮接管的 11 颗** `once` body 里不再出现对自家 `didXxx_v1` 的读或写（那两句整体消失）。
  另两颗异步（`regenerateSegmentThumbnails`、`orphanGC`）按岔口 A **保留自记账**，它们是 I-2 的显式例外，
  例外要写在**那颗自己的声明上**（`ledgerAuthor = .stepItself`，见 I-7）而不是写在注释里。
- **I-2** 对**被接管**的步骤：done 键只在 body 返回 `true` 之后由 executor 写。任何 `false` 路径都不写 ⇒ 下次启动重试。
  这条就是 `LaunchStepLedger.swift:14-15` 那条契约从"注释约束"变成"结构性唯一出口"。
- **I-6**（v2 新增）**每颗被接管的 body 必须可重入** —— 同一个 store 上连跑两遍，结果与跑一遍相同，且不造成第二次损害。
  理由：搬完之后"body 成功、键没写上"从异常路径变成**常态路径**（`true` 返回与 executor 写键之间被强杀 / 崩溃 / 重启 ⇒ 下次重跑）。
  现在 `LaunchStepLedger.swift:14-15` 只规定了"成功才写"，没规定"重跑必须安全"，**这两条是一套 `once` 机制的左右腿**。
  落地要求见 §4.2 那张表新增的「重跑损害」列 —— 那一列**本轮还没填**，它是每颗动手前的第一个取证动作。
  已经有一条旁证说明这类重复真实存在过：`dedupProjectVideoAssociations` 恰好排在 `migrateToProjectVideoRelation` 之后。
- **I-7**（v2 新增，v2.1 改落点）**"哪几颗不归账本写"是一份数据，不是注释**。
  数据 = `LaunchStep.ledgerAuthor == .stepItself` 那些颗的 **id**（§4.1b），守卫从声明里筛出来读，
  **不许在脚本里写死文件名或行号**。
  （v2 原写法是"从 `ledgerWrite(for:) == .nothing` 推"，**推不出**：`.everyLaunch` 也返回 `.nothing`，
  而 `regenerateSegmentThumbnails` 是 `.once` —— 见 §4.1b 那条矛盾。）
  这样"新增一颗自己记账的步骤"会被判言抓到，而不是被放过。
- **I-3** 每颗 `once` body 的签名一律 `-> Bool`，且 `true` 的含义全工程统一：
  **"这颗这次没有报告失败"**（不是"做了改动"）。没有要改的行也算 `true`（`fixMissingSemanticTypes:314-320` 已是这个口径）。
- **I-4** 键名**一个都不改、不重置**。`StepCadence.once` 的注释（`LaunchStepLedger.swift:17-19`）写着：
  改名或重置会让老用户把已跑过的迁移再跑一遍。
  ⚠️ 岔口 D 若选"指纹重基"那一档，**动的不是键名而是"这些键还算不算数"的判定**，与 I-4 不冲突；选"写进库内表"那一档才会撞 I-4，故归批 3。
- **I-5** executor 写键失败（`UserDefaults` 理论上不抛，但 `set` 之后要能读回）不得伪装成"这颗白跑"——
  本轮**不**给写键加校验，也不假装它可能失败（见 §8 R-5 的口径说明）。

## 4. 改动清单

### 4.1 executor 侧（`MixCut/App/LaunchSteps.swift`，一处新增）

`run(container:)` 里 `if body(container) { succeeded.insert(step.id) }` 那条分支（`:142-143`）改成：
成功 ⇒ 先 `markLedgerWritten(for: step)` 再 `succeeded.insert`。新函数职责单一：

```
/// body 报告成功后，按节律把"跑过"这件事写进真源（UserDefaults）。
/// **被接管**的步骤只有这一个写键出口；不接管的异步步骤由自己声明 `ledgerAuthor = .stepItself`，
/// 那里是它自己写键的唯一许可面（I-7 的清单就是从它派生的，不靠注释）。
private static func markLedgerWritten(for step: LaunchStep)
```

它自己**不判断节律、也不判断该不该记账**，只做两步：先按 `step.ledgerAuthor` 放行，再 `switch ledgerWrite(for: step.cadence)`（§11.1）：

- 作者是 `.stepItself` ⇒ **立刻返回**，一个键都不碰（那两颗异步仍在自己函数里写）
- `.markDone(key:)` ⇒ `UserDefaults.standard.set(true, forKey: key)` —— 键名由 Core 的结果带出来，
  于是这里**没有 `ledgerKey!` 这种强制解包**（v2 原写法要解包，解包点就是一个可以偷偷换键名的地方）
- `.nothing` ⇒ 什么都不做

⇒ "`.once` 写、`.throttled` 与 `.everyLaunch` 不写"这三条**住在 Core 的纯函数里**，App 侧只是照做；
"哪几颗不归我写"住在**声明**里（§4.1b），App 侧也只是照做。
守卫 LLG-14 判的就是"照做这一层有没有偷偷把判断加回来"。

### 4.1b "谁记账"是第二条轴（v2.1 新增，I-7 的落点）

节律只回答"这颗多久跑一次"，回答不了"跑成功之后那笔账由谁来记"。v2 想从节律推出后者，**推不出来**
（`regenerateSegmentThumbnails` 和另外 11 颗 `once` 在节律上长得一模一样），所以给它一个独立的声明字段：

```swift
/// 这颗成功后那笔"跑过了"的账由**谁**写。与"多久跑一次"（`StepCadence`）是两条正交的轴。
/// 刻意不给默认值 —— 与 `onFailure` 同一个先例（现网 19 颗 `LaunchStep` 全部显式给了 `onFailure`，实测数过）：
/// 新增一颗时必须当场回答"谁记账"，不许靠人记。
public enum LedgerAuthor: Equatable, Sendable {
    case executor       // 19 − 2 = 17 颗：被接管的 11 颗 `once` + 6 颗无键的 `everyLaunch`
    case stepItself     // 由那颗函数自己写（异步 ⇒ 只有 `regenerateSegmentThumbnails`、`orphanGC` 两颗）
}
```

`LaunchStep` 加一个存储属性 `ledgerAuthor`，I-7 那份"不接管清单"**就是从 `steps` 里筛 `ledgerAuthor == .stepItself`**，
清单内容因此**只有一份来源**（声明本身），守卫、`markLedgerWritten`、LLG-15 全读它。
它存在的意义不是"给守卫少算两颗"，而是：**将来谁想让第三颗步骤自己写键，必须先改那颗的声明，改声明就要过评审。**

**代价要说死（我刚数的，不是估的）：** `LaunchStep(` 全仓 33 处 —— `MixCut/App/LaunchSteps.swift` 19 处、
`Tests/MixCutCoreTests/LaunchStepLedgerTests.swift` 14 处，加一个**无默认值**的参数就会 33 处同时变红，
由编译器逐条点出来（漏不掉，但也**没有一条能省**）。
选"给默认值 `.executor`"可以只改 2 处，但代价是：新加一颗异步步骤时忘了改 ⇒ 编译通过 ⇒
executor 在"排上队"那一刻记账 ⇒ 正好是 §4.3 要避免的那个坑，而这只能等守卫或真机去抓。
**我按 `onFailure` 的先例选无默认值。**

### 4.2 body 侧（`MixCut/App/MixCutApp.swift`，11 颗各一刀）

每颗做两件事：删掉开头那句 `if UserDefaults.standard.bool(forKey:) { return true }`，
删掉末尾那句 `UserDefaults.standard.set(true, forKey:)`。工作逻辑、日志、`return false` 的分支**一个字不动**。

**每颗动手前的第一个动作：填 §1 那张表新增的「重跑损害」列**（I-6 要求）。填法不是"看着像幂等"，
而是回答一个具体问题：**同一个 store 上连跑两遍，第二遍会不会改坏第一遍的结果或删掉不该删的东西？**
举两个已经想到的对照：`purgeLegacyQwenDubs`（按注册表删非法音色）第二遍是空操作 ⇒ 无害；
`migrateToProjectVideoRelation` 第二遍会不会造出重复关联行 —— 它后面紧跟着 `dedupProjectVideoAssociations`，
**这个顺序本身就是"重复真实存在过"的证据**，所以那一格大概率不能填"无害"，得读代码确认。
本轮 v2 落笔时**这一列还是空的**，不许拿"应该是幂等的"糊过去。

两颗 `Void` 的要先补真信号（否则 I-3 不成立）：

- **`fixMissingSemanticTypes`**（`:294`）：签名改 `-> Bool`；`:299/:302/:323/:327` 四处早退各自 `return false`
  并补一行"为什么 false"的 `MixLog.error`（现在那四处是**静默**的，只有键没写，日志里查不到）；
  成功路径末尾 `return true`。`:314-320` 那个"没有要修的行"分支已经是写键后 return，改成 `return true`（键由 executor 写）。
- **`migrateGlobalSubtitleFontRatio`**（`:1102`）：同形，先读它内部的早退点再定（本文件落笔时我只读到 `:1103` 那行键声明，
  **它的早退清单要在动它那一刀之前补齐取证**，不预先写死有几处）。

`LaunchSteps.swift:83-84` 那句过期注释按 §1 事实 2 改写。

### 4.3 本轮**不动**的三颗

| 步骤 | 为什么不动 |
|---|---|
| `regenerateSegmentThumbnails`（异步） | body 一 `Task {}` 排上队就返回，executor 此刻拿不到成败。若由 executor 写键 = 把"排上队"记成"已成功"，正是 `LaunchSteps.swift:19-20` 与 Q0 裁定点名的那个坑。 |
| `orphanGC`（throttled + 异步） | 时间戳写在 `:1268-1273` 那条 Task 里 `runOrphanGC` **之后**。两条早退路径（`:1256` 品牌迁移未完成、`:1264` 不足 24h）**刻意不写**时间戳，注释 `:1255` 写明理由：写了等于把这枚雷顺延 24 小时、跳过原因从日志里消失。executor 一接管就会破坏这条。 |
| 6 颗 `everyLaunch`（`:34/:36/:37/:42/:64/:78`） | 无键，不参与"跑过没有"。（19 = 6 + 12 + 1，与 §10.1 那次分类计数对齐；v2 此处原写"7 颗"是拿 `grep -c` 直接数的，第 7 次命中其实是 `:183` 的 `case .everyLaunch:`） |

⇒ 本轮实际搬 **11 颗**（9 颗只摘、2 颗先补信号再摘），留 **2 颗异步**按岔口 A 自记账（声明成 `.stepItself`，§4.1b）。

### 4.4 岔口 D 选 1 的落地内容（v2.1，D 拍板后补）

D-1 的"把话说实"具体是**三处小改**，全在 `MixCut/App/SchemaGuard.swift` + 上位契约，不碰启动链：

1. **删掉 `Ledger` 里恒空的 `doneSteps` / `lastRunAt`**（`:37-38`）与构造默认值（`:41/:44` 那两个参数）。
   删的理由不是"没人用所以清爽"，而是：**留着，下一个人读到 `:23` 那句注释就会以为账在这儿**，
   而 §2.2 那层风险（键与库不同命）会被这条假安慰永久压住。
2. **把 `:23-24` 那句改成实话**：sidecar 只存 schema 描述行；"跑过没有"记在偏好域、**不随库走** ——
   并写明"这是 Q0 裁定，放回备份会失效"，指向 §2.2 那条欠账。
3. **`readLedger` 把两种 nil 分开**（这条是拍 D-1 时顺带查出来的，比前两条要紧）：
   `:93-98` 现在 `try? Data(contentsOf:)` 与 `try? decoder.decode(...)` 两处 `try?` 回的是同一个 `nil`，
   于是"**文件不存在**"（新库，正常）与"**文件在、但解不开**"（坏了 / 格式变了）在调用点上完全同形，
   而 `openStore:194-195` 把两者都当 `recorded: nil` ⇒ `decideSchemaGate` 判 `.noPriorRecord` ⇒ **照常开库、永不备份**。
   换句话说：**sidecar 一坏，批 0 那道门就永久失明，且没有任何一行日志说它失明过。**
   改法：文件存在却解不开 ⇒ `MixLog.error` 一行（含路径与错误描述）；判定**仍是** `.noPriorRecord`
   （本轮不改判定 —— "解不开就拒开库"会让一个坏 JSON 变成打不开的应用，那是另一档风险，要单独拍）。
   ⚠️ 第 1 条自己就是"格式变了"的现场：删字段后老 sidecar 里多出来的那两个键**必须仍解得开**，
   而这件事**没有便宜的活入口** —— `Ledger` 住在 App 侧，`swift test` 碰不到；
   且即使解码天天失败，`lines` 也会被当次取值重新写满，LLG-17 那四个数一个字都不变 ⇒ **拿它当判据就是假绿**。
   所以入口改成第 3 条那行 `MixLog.error`：**克隆库上第一次启动必须看不到它**，看到了就说明删错了格式。
   （§0 原先承诺"用一条 Core 单测钉死"——那承诺**做不到**，`Ledger` 不在 Core 里；已改成这条日志判据。）

4. **上位契约记一笔欠账**（§3.9 那段末尾）：搬载体 = 紧接的下一轮，前置是**改 Q0 裁定**；
   并把 D-3 那条"放回检测"登记为下一轮的**第一条判言**（`updatedAt` 倒退的信号本轮已实测，见 §9 D 第 3 档）。

这四处不属于"搬写入"那条主线，但它们是 D-1 这个决定的全部内容 —— 不选 D-1 就一行都不做。
若要更小的版本（只做 1+2+4、把 3 单独留下一轮），说一声，我把 3 摘出去。

## 5. 判据（动手前写死，不许事后找补）

| 编号 | 判据 | 层 | 怎么算过 |
|---|---|---|---|
| LLG-13a | 被接管的 11 颗 body 里不得再出现对**自家** `didXxx_v1` 的读或写 | 守卫（扩 `check_schema_ledger_guards.sh`） | 剥注释后逐颗按函数体扫，命中数 = 0 |
| LLG-13b | 全工程写 done 键的语句**只允许出现在两类位置**：`markLedgerWritten`，以及声明为 `.stepItself` 的那两颗的函数体内 | 守卫（**从声明筛**，不写死文件/行号） | 命中集合 ⊆ {`markLedgerWritten`} ∪ 那两颗的函数体；筛不出来或筛出第三颗 ⇒ 红 |
| LLG-14 | 被接管步骤的写键必须挂在 `body(...) == true` 那条分支上，不许提到分支外；且 `markLedgerWritten` **自己不再判断节律**（只放行 `ledgerAuthor` 再 switch Core 的结果） | 守卫（结构判言） | 从 `run` 里提取该分支体，判 `markLedgerWritten` 在其中；再判它体内没有第二处 `set(` |
| LLG-15 | `.stepItself` 的**颗数 = 2**，且这 2 颗就是异步那两颗 | 守卫（**读 `steps` 声明筛出**，不写死 id） | 从 `LaunchSteps.swift` 筛 `.stepItself` 的 `LaunchStep` 行，颗数 ≠ 2 ⇒ 红。（"`.everyLaunch` 却声明 `.stepItself`"这类**不可能组合**只在 Core 判一次（LW-05），守卫不重抄一遍 —— 两条作者不同的尺子会各自腐烂）|
| LLG-19 | （v2 新增，**v2.1 收窄过一轮**）`bodies` 表里凡"`once` 且由 executor 记账"的那 11 颗，**不得出现字面量 `return true`** —— 必须直接转发一个 `-> Bool` 函数。（v2 原写法是"除那两颗之外全表不得出现"，**那条和 v1 的 LLG-13 同一种错**：实测表内 `return true` 有 **9 处**，其中 5 处属于 `everyLaunch`（`removeQuarantine`/`migrateWhisperModels`/`restoreSelfBuiltFlags`/`resetStaleAnalyzingStatus`/`purgeStaleTempFiles`）—— 它们本来就没有成败可报、也不记账，落地当天就会恒红）| 守卫（豁免面读声明） | 先从 `steps` 筛出"`.once` 且非 `.stepItself`"的 id 集合（12 颗 `once` 去掉缩略图那颗 = **11**，搬前搬后都是这个数），再逐颗查它在 `bodies` 里那一条：出现 `return true` ⇒ 红。**改前红 2 处**（`fixMissingSemanticTypes`、`migrateGlobalSubtitleFontRatio` 两颗 `Void`），终值 0 |
| LLG-20 | （v2 新增）**每颗的「重跑损害」格非空**才算搬完（I-6） | 计划内自检（脚本判不了语义） | 该颗提交前，§1 表那一格填了具体结论 + 依据行号 |
| LLG-21 | （v2.1 新增，**这条是 `ledgerAuthor` 这个新轴自己带来的新风险**）声明成 `.stepItself` 的步骤，**必须真的在自己函数体里写那枚键** —— 否则它的键永远写不上 ⇒ 每次启动重跑（R-2），而 LLG-19 的豁免反而会替它遮着 | 守卫（反向核） | 对 LLG-15 筛出的每一颗：其 body 是自记账/异步形状，**且**对应函数体内出现对该节律键的 `set(`；缺一 ⇒ 红 |
| LLG-16 | 每颗搬完的 body，失败路径**不写键** ⇒ 下次启动还会跑 | 真机（克隆库） | 摘掉某颗的键 → 启动 → 日志出现该颗 `跑`；再启动 ⇒ 该颗进 `已记账` |
| LLG-17 | 搬完不改变任何一颗的**实际执行次数** | 真机（克隆库） | 连跑两次启动，`[LaunchLedger] 本轮 19 颗：跑 N / 已记账 M / 未到期 K / 被拦 B` 四个数与改前逐颗一致 |
| LLG-18 | 键名零变更 | 守卫 | 12 个键名字面量与 `83ba40b` 那份逐字比对 |

⚠️ **v1 的 LLG-13 是错的，别照它写守卫**。它要求"全工程写 done 键的语句只有一处"，而岔口 A 决定让两颗异步继续自记账 ——
实测 `regenerateSegmentThumbnailsToFirstFrame` **一个函数里就有三处** `set(true, forKey:)`（`:827`、`:861`、`:905`），
`orphanGC` 另有 `:1272` 写时间戳。照 v1 写，这条判言**落地当天就恒红**；
而为了让它变绿去手写一条排除，就是**换一把更易过的尺子** —— 那正是批 0 一路在防的动作。
所以拆成 13a/13b，且 13b 的豁免面**读 `.stepItself` 那份声明**（I-7）：将来谁加第三颗自记账步骤，得先改声明，改声明要过评审。

**测试层**：写键动作本身在 App 侧，`swift test` 碰不到 `MixCut/`（本工程的老墙），所以本轮不往 App 侧塞测试。
Core 侧可测的增量已由岔口 C 定死（"拎出来"）：`ledgerWrite(for:)` 与 `LedgerAuthor` 这**两条轴** ⇒ `LW-01~06`（§11.1），
于是 I-2 的形状在 Core 里有断言，App 侧只剩"照做"。

**零断言面**（验收不得写"已验证"）：LLG-16 / LLG-17 只能真机读数；`UserDefaults` 写入的实际落盘时机（`synchronize` 语义）本轮不测。

## 6. 施工顺序（一颗一启，不许攒批）

上位契约 §3.9 已经定了这条，理由抄一遍：一次搬 11 颗，出问题时**无法归因**是哪颗。

1. 先落 Core 侧：`LedgerWrite` + `ledgerWrite(for:)` + `LedgerAuthor` + `LaunchStep.ledgerAuthor`（无默认值 ⇒
   `LaunchStep(` 全仓 **33 处**同时被编译器点出来：App 19 + 测试 14，逐条补参数）+ `validateLaunchPlan` 那条不可能组合，
   配 `LW-01~06` 六条用例；再落 executor 侧的 `markLedgerWritten`
   （此时还没有任何一颗 body 摘 guard ⇒ **运行行为一字不变**，除了那两颗异步多一层 `ledgerAuthor` 声明），
   最后落守卫 LLG-13a/13b/14/15/18/19/21 并取**改前的红**
   （11 颗还在自己读写键，13a 必然红 —— 这是它该有的样子；改前快照不红就说明判言是空的。
   命中**行数**我没数过，所以棘轮按**颗**计，见下面第 3 条。）
   ⚠️ 顺序不许反：先写守卫再补 Core 的轴，守卫会因为 `.stepItself` 还不存在而**筛不出豁免面**，
   变成"筛不到 ⇒ 0 命中 ⇒ 绿"的假绿（判言读不到数据时必须红，这条要写进脚本）。
2. 然后按"依赖面从小到大"逐颗搬，每颗一个提交、每颗跑一次启动、每颗读一次 LLG-17 那四个数，
   **并且每颗提交前先把 §1 表的「重跑损害」格填上**（LLG-20 / I-6）：
   `cleanExistingTranscripts` → `backfillSegmentFrames` → `resetSchemeDubSelection` → `purgeLongRefClones` →
   `purgeLegacyQwenDubs` → `ensureCustomGroupStrategy` → `migrateToProjectVideoRelation` →
   `dedupProjectVideoAssociations` → `recoverFromDisk` → `fixMissingSemanticTypes`（含补信号）→
   `migrateGlobalSubtitleFontRatio`（含补信号）
   —— 有真信号的 9 颗先走，两颗要改签名的最后走（它们动的是返回值形状，风险最高）。
3. 棘轮（两条的**形状不同**，别写成一个）：
   - LLG-13a 按**未搬颗数**从 11 递减到 0（每搬一颗 −1），与 SL-12 归零那两轮同一个玩法。按颗不按命中行数 ——
     每颗有几句读写我没数过，写成"= 22"那种数就是又一个会腐烂的假精确。
   - LLG-19 **不是逐颗棘轮**：11 颗里今天只有 2 颗违规（两颗 `Void`），它在前 9 刀上恒绿，
     到第 10、11 刀各掉一次 ⇒ 终值 0。所以它的自证方式是"改前必须红 2 处"，
     中途任何时候绿都不是好消息，但**只有最后两刀能让它从 2 变 0**。

**每颗启动都在克隆库上跑**（`MIXCUT_DEBUG_APP_SUPPORT_ROOT=.scratch/fakeroot`），真库全程只读。

## 7. 撤销内容清单（要退的时候退这些，不多不少）

- `MixCut/App/LaunchSteps.swift`（新增 `markLedgerWritten`、改 `:83-84` 注释、改 `:142-143` 分支、
  19 处声明补 `ledgerAuthor:`（其中 `regenerateSegmentThumbnails` 与 `orphanGC` 两颗给 `.stepItself`））
- `MixCut/App/MixCutApp.swift`（11 颗 body 各删两句；两颗改签名）
- `Sources/MixCutCore/LaunchStepLedger.swift`（岔口 C 已定"抽纯函数" ⇒ 会动：新增 `LedgerWrite` + `ledgerWrite(for:)`
  + `LedgerAuthor`，并给 `LaunchStep` 加 `ledgerAuthor` 存储属性 ⇒ 连带 `LaunchSteps.swift` 19 处 + `LaunchStepLedgerTests.swift` 14 处构造点）
- `MixCut/App/SchemaGuard.swift`（岔口 D 已定 1 ⇒ 会动，内容 = §4.4 那三处：删两枚恒空字段、改 `:23-24` 那句假承诺、
  `readLedger` 把"文件不存在"与"解不开"分开）
- 上位契约 `docs/superpowers/plans/2026-09-30-upstream-012-portability.md` §3.9 段末的**欠账登记**（§4.4 第 4 条）
- `scripts/check_schema_ledger_guards.sh`（新增 LLG-13a/13b/14/15/18/19/21）与其自检
- `Tests/MixCutCoreTests/LaunchStepLedgerTests.swift`（14 处构造点补参数 + `LW-01~06`）
- 本文件 + 上位契约 §3.9 那句"刻意只搬判定不搬记账"的收口记录

**不在撤销范围**：任何键的重置、任何 schema 变更、`.scratch/fakeroot` 之外的库文件。

## 8. 风险与回滚

- **R-1 最坏后果：某颗迁移从此不再跑。** 若 executor 在 body 还没真成功时就写了键，那颗迁移对这台机器永久消失，
  而它是数据修复类的（`recoverFromDisk` 是 schema 出事后的唯一兜底，见 `MixCut/Models/SchemaVersions.swift:7`）。
  拦它的不是我的小心，是 I-2 那条"只有 `true` 分支写"+ LLG-13a/LLG-14 那两条结构性判言。回滚：单颗退（每颗一个提交）。
- **R-2 次坏后果：某颗每次启动都跑。** 若 executor 写键没生效（写错键名、写在不执行到的分支上），
  症状是启动变慢 + 日志里那颗反复出现在 `跑 N` 里。LLG-17 那四个数就是量这个的。
- **R-3 改签名那两颗可能漏掉早退点**，把"静默不写键"变成"静默记成功"——**这是本轮最容易自伤的一处**。
  要求：动它们之前先逐行列出该函数所有 `return`/早退点，贴进本文件 §4.2 再改；改完 LLG-16 必须真机跑一次。
- **R-4 键名手滑**（`didMigrateProjectVideo_v1` 少个字母 ⇒ 老用户重跑迁移）。LLG-18 逐字比对钉住。
- **R-5 `UserDefaults` 写失败**：现实中 `set` 不抛，本轮**不给它加校验**，也不写"已处理"。
  这条不是遗漏，是刻意不做 —— 加一层校验会造出第二个"成功"口径，与 §2 的根因正好相反。
- **R-6 与另一波改动混树**：当前工作树里有 SunCut 改名/分发那波未提交的东西（README、CLAUDE.md、若干 docs）。
  本轮每颗提交都只点名自己那几个文件，不 `git add -A`。
- **R-7（v2 新增，对应 I-6）跑成功但没记上键 ⇒ 下次重跑**。搬完之后这条从异常路径变成**常态路径**：
  body 返回 `true` 与 executor 写键之间被强杀 / 崩溃 / 系统重启，键就还是空的。
  v1 只防了反方向（R-1 不该记却记了），**方向反过来的风险当时没人写**。
  它不可完全消除（除非把"做过什么"写进库内、与数据同一次事务提交 ⇒ 那是岔口 D 的第 2 档，属批 3），
  本轮的处置是：把每颗的「重跑损害」填进 §1 表并逐颗确认幂等（LLG-20），让"重跑一次"始终是安全的。
- **R-8（v2.1 新增，`ledgerAuthor` 这条新轴自己带的风险）把该自记账的颗误标成 `.executor`。**
  最坏落点很具体：缩略图那颗 body 一 `Task {}` 排上队就 `return true`，executor 若在那一刻写键，
  症状就是"**整批缩略图一张没重生，键却说跑过**" —— 而这正是提交 `1770360` 刚修掉的那件事（"读表失败也别记成功键"）。
  编译器帮不上：它只保证"每颗都回答了谁记账"，答对答错它不管。
  兜它的是 **LLG-15**：33 处如果机械补成 `.executor`，`.stepItself` 颗数会掉到 0 ⇒ 当场红；
  反方向（误标成 `.stepItself` 却并不自己写）由 **LLG-21** 红。
  残余风险：把**别的**颗标成 `.stepItself`、恰好让颗数仍然是 2 —— 我不给守卫写死 id（写死就变成第二条要人维护的账），
  所以这一种要靠 §6 第 1 步那 33 处**逐条看、而不是 sed 一把改**来防，提交前用 `git diff` 数 `.stepItself` 落在哪两行。

## 9. 岔口

A/B/C 已拍板（记录在 §11），**D 于 v2.1 新增、也已拍定 1**（§11.2）。四个岔口的落点都写在这一节里，别再往下翻。

- **A 那两颗异步怎么办** —— **已定：1（本轮不动，只记账）**，理由与后果见 §10.2。
  2. 把 `regenerateSegmentThumbnails` 拆成「排上队」与「跑完了」两颗（`LaunchSteps.swift:68` 注释本来就指了这条路）
     —— 代价：要新增一枚键，且老用户那枚 `didRegenerateSegmentThumbnailsToFirstFrame_v1` 的语义得重新解释
  3. 连 `orphanGC` 一起接管 —— 我判断**不该做**：会直接违反 `:1255` 那条"跳过不记时间戳"的纪律
- **B 一次搬完 11 颗，还是一颗一提（11 次提交、11 次启动读数）** —— **已定：后者**（上位契约 §3.9 定死）。
  代价照抄一遍免得事后才发现：这一轮要占你 **11 次启动核对**。
- **C 要不要把"节律 ⇒ 写什么值"抽成 Core 纯函数** —— **已定：拎出来**，落地形状见 §11.1。

- **D（v2.1 新增，**已定：1**，见 §11.2）§2.2 那层"记账与库不同命"，本轮办到哪一步**

  背景一句话：十二枚 `didXxx_v1` 键住在**偏好域**，而它们描述的是**某个具体 store 文件的数据形状**；
  `CLAUDE.md:447` 支持"放回备份"，一放回，数据形状退回几周前、键仍然全是 `true` ⇒ **十二颗迁移永久跳过**。
  §2.3 又查实：跟库同命的那个载体（sidecar）**早就存在、早就进备份族**，只是里面那两枚记账字段恒空。

  1. **本轮只"把话说实"** —— 我删掉 sidecar 里恒空的 `doneSteps`/`lastRunAt` 两个字段，
     并把 `SchemaGuard.swift:23-24` 那句"账本写在同一份 JSON"改成与现状一致的描述；
     §2.2 那层风险作为**显式欠账**写进上位契约 §3.9 那段，注明"搬载体 = 紧接的下一轮，且要改 Q0 裁定"。
     - 优：本轮范围一字不涨（还是"只搬写入"），出问题时归因干净；顺手拔掉一段"注释承诺了代码没做的事"的谎。
     - 劣：**备份放回这个动作仍然完全没修**，只是从此没人会误以为 sidecar 里存着账。
     - 你的代价：零额外操作（11 次启动核对不变）。失去什么：什么都不失去，只是把根治推到下一轮。
  2. **本轮顺带把真源搬进 sidecar**（键仍叫这些名字，只是从"读偏好域"改成"读库旁边那份 JSON"）。
     - 优：§2.2 当场根治，R-7（跑成功没记上 ⇒ 重跑）也顺带变小 —— 写 sidecar 与写库同在一个目录、同一族备份；
       且 `storeFamily()` 已经把它算进备份，`cp Suncut.store*` 也盖得住，**零 schema 变更**。
     - 劣：**要推翻 Q0**（上位契约裁定"真源是 `UserDefaults`"），那只有你能改；
       并且必须配一次"把偏好域里 12 枚老键一次性抄进 sidecar"的导入，否则老用户全量重跑，直接撞 I-4；
       而**那次导入自己也需要一枚键来记"导入过没有"** —— 迁移记账的迁移，鸡生蛋得当场设计掉。
     - 你的代价：本轮从"11 刀"变成"11 刀 + 一份载体迁移设计"，LLG-16/LLG-17 的取证入口全部换地方
       （从 `defaults write` 改成手改 JSON）。**一轮两件事正是上位契约 §3.9 反对的攒批**，所以我把它排在下一轮更稳。
  3. **只加一条报数**（检出"放回"这个动作发生了）：偏好域新记一枚 `lastSeenLedgerUpdatedAt`，
     启动时若 sidecar 的 `updatedAt` 比上次看到的**更早**，就在日志写明"N 颗迁移对当前这个库可能从未跑过"。
     - 已验的信号（刚在克隆库量的，不是我推的）：当前 sidecar `updatedAt = 2026-10-01T06:22:03Z`，
       三份 `.backup` 目录里的那份分别带回 `2026-09-30T15:02:50Z` / `15:02:50Z` / `15:09:18Z` ⇒ **放回必然让 `updatedAt` 倒退**，
       因为 `writeLedger` 每次都把 `updatedAt` 刷成当前时间（`SchemaGuard.swift:105`）。
     - 优：便宜（一枚新键 + 一次比较），把静默变成读数，且给第 2 档留一把可复用的尺子。
     - 劣：**它不修任何东西**，只是贴上标签；且它是第 2 档落地后要删的脚手架（真源进了 sidecar 就不需要猜"是不是换过库"了）。
     - 你的代价：多一次启动核对；LLG-18 那张键名比对表要加一行（加新键不是改名，但要过清单）。

  **我的推荐：本轮取 1，并把 3 作为下一轮的第一条判言写进欠账记录。**
  理由：这一轮买的是"只有一个作者"，那已经是 I-2 的根；D-2 买的是"作者跟库同命"，是另一条根，
  而两件事同做会让 LLG-16/LLG-17 的每次读数都带上两个嫌疑，正是 §3.9 点名的无法归因。

## 10. 本文件落笔时的取证边界（不装完整）

- `migrateGlobalSubtitleFontRatio` 我只读到键声明那一行（`:1103`），**它的早退点清单还没取**（R-3 要求动它之前补齐）。
- `LaunchSteps.swift:83-84` 那句过期注释是我读 `bodies` 表比对出来的，没有跑过任何一次启动去验证"9 颗真会返回 false"。

### 10.1 LLG-17 的改前基线：**已取**（2026-10-01 15:4x，写完后补的）

日志里今天有六行 `[LaunchLedger] 本轮 19 颗`，读数**全部相同**：

```
跑 6 / 已记账 12 / 未到期 1 / 被拦 0        （6+12+1+0 = 19）
```

其中 **14:22:03.132 那一行是归因清楚的**：那是 pid 39409、`.scratch/dd` 那份当前构建、跑在克隆库
（`MIXCUT_DEBUG_APP_SUPPORT_ROOT=.scratch/fakeroot`）上的启动。其余五行（08:18 / 12:35 / 12:47 / 12:51 / 13:04）
**归因未定** —— 日志文件不在假根的隔离面内，真 app 与克隆实例写的是同一个 `suncut.log`，
所以那五行可能是真库的读数，只能当"这数稳定"的旁证，不能当基线本体。

⇒ **LLG-17 的对照物 = `跑 6 / 已记账 12 / 未到期 1 / 被拦 0`**，锚在 14:22:03 那一次。
这四个数与清单结构逐颗对得上：清单是 **6 颗 `everyLaunch` + 12 颗 `once` + 1 颗 `throttled` = 19**（`grep -c` 数过），
所以 `跑 6` 恰好是那六颗每启动都跑的步骤，`已记账 12` = 十二颗 `once` 的键全部已置位，
`未到期 1` = `orphanGC` 的 24h 节流，`被拦 0`。
搬完 11 颗之后，这四个数**必须一个字都不变** —— 变了就说明某颗的写入时机被改坏了（R-1/R-2）。

### 10.2 岔口 A 已拍板

**A 选 1：本轮不动那两颗异步，只记账。** 于是 §4.1 的 `markLedgerWritten` 对 `.throttled` 明确不写，
`regenerateSegmentThumbnails` 与 `orphanGC` 两颗的 body 内部读写**原样保留**，
LLG-15 钉"`.stepItself` 恰好这 2 颗"、LLG-21 钉"这 2 颗真的在自己函数体里写键"。

## 11. 四个岔口的拍板记录（A/B/C 于 15:5x，D 于 17:5x）

- **A 已定：本轮不动那两颗异步，只记账**（§10.2）。
- **B 由上位契约 §3.9 定死：搬一颗、跑一次启动**。代价照抄一遍免得事后才发现：
  **11 次启动核对，每次要你点一下那个克隆实例**。
- **C 已定：拎出来** —— "节律 ⇒ 成功后该记什么"这条规则单独放进 `MixCutCore`，让它变成 `swift test` 能考的东西。

### 11.1 C 落地形状（写进 §4.1 的 executor 之前先定死）

`Sources/MixCutCore/LaunchStepLedger.swift` 追加：

```swift
/// 一颗步骤**报告成功之后**该往真源写什么。
/// 刻意只有两档、且不给默认值 —— 新增一种 `StepCadence` 时编译器会强制回答"它该记什么"，
/// 这正是"拎出来"买到的东西：写键规则不再靠人记。
/// 它**只管节律**：「由谁写」是另一条轴（`LedgerAuthor`，§4.1b），两者在这里合不成一个返回值。
public enum LedgerWrite: Equatable, Sendable {
    case markDone(key: String)   // `once`：键名一起带出去，App 侧就不必 `ledgerKey!` 解包
    case nothing                 // `everyLaunch` 与 `throttled`：executor 不写
}

public func ledgerWrite(for cadence: StepCadence) -> LedgerWrite
```

（v2 这里原本写的是无参数的 `case markDone`，App 侧再去 `step.cadence.ledgerKey!` 取键 ——
那既留了一个强制解包，又让"键名"这条信息走两遍路。改成把键装在结果里一次带出。）

`throttled ⇒ .nothing` 不是偷懒，是 A 那条决定的代码化：`orphanGC` 的时间戳只能在 GC 真跑完那条 `Task` 里写，
executor 一写就会破坏它的"跳过不记时间戳"纪律（纪律的原因写在那颗函数自己的注释里）。

⚠️ **写进代码的注释一律引用「步骤 id + 规则名」，不引用 App 行号。** 行号一天就漂，漂了的注释比没注释更坏 ——
本文件里那些 `:1255` 之类的坐标是**落笔当时的快照**，只用于让你查得到，不许抄进源码。

Core 侧新增用例（`Tests/MixCutCoreTests/`，与 `decideStep` 那套同族）：

| 编号 | 用例 | 钉住什么 |
|---|---|---|
| LW-01 | `.once("didX_v1")` ⇒ `.markDone(key: "didX_v1")` | I-2 的正半边，**且键名原样带出**（不是"某个键"） |
| LW-02 | `.everyLaunch` ⇒ `.nothing` | 每启动跑的不记账 |
| LW-03 | `.throttled("lastOrphanGCAt", hours: 24)` ⇒ **`.nothing`** | **A 那条决定**（节流那颗不许由 executor 写） |
| LW-04 | 反向对照：三档各来一次，断言 `.markDone` **只**出现在 `.once` 上 | 防 LW-01 测成恒真 |
| LW-05 | `validateLaunchPlan` 对"`cadence = .everyLaunch` 却声明 `ledgerAuthor = .stepItself`"报装配错误 | 新轴也有不可能组合；放 Core 而不是再写一遍守卫（`:138-163` 那个函数本来就是"返回非空即装配错误"，且 DEBUG 下当场 `fatalError`） |
| LW-06 | 同一颗 `.once` 步骤，`ledgerAuthor` 取 `.executor` / `.stepItself` 两种时 `decideStep` 的 verdict **一字不变** | 新轴**不许渗进判定**：谁记账只影响写不写、不影响该不该跑（否则两颗异步会在前序失败时被误判成 `skipAlreadyDone`，正是 `LaunchStepLedger` 那段"判定顺序是判据的一部分"注释防的错归因） |

App 侧 `markLedgerWritten(for:)` 只做两件事，且**两件都不产生判断**：
先 `guard step.ledgerAuthor == .executor else { return }`（读声明），
再 `switch ledgerWrite(for: step.cadence)`（读 Core 的结果）⇒ 只有 `.markDone(key:)` 才 `set(true, forKey: key)`。
守卫 LLG-14 判的就是"这层有没有偷偷把判断加回来"。

⇒ 四个岔口全部拍完（A=1、B=一颗一提、C=拎出来、**D=只把话说实**），本文件进入**待批**状态。
**批之前仍然零改动**（含不建守卫、不动 `LaunchSteps.swift`、也不动 `SchemaGuard.swift` 那两枚恒空字段）。

### 11.2 D 已定：1（2026-10-01 17:5x）

**只做 §4.4 那四处，不动载体。** 于是本轮范围最终是：

| 主线 | 岔口 D 带来的三处小改 |
|---|---|
| Core 两条轴 + `markLedgerWritten` + 11 颗逐颗搬（每颗一提交一启动读数）+ 守卫 LLG-13a/13b/14/15/18/19/21 + `LW-01~06` | `SchemaGuard.swift` 删两枚恒空字段、`:23-24` 注释改成实话、`readLedger` 两种 nil 分开；上位契约登欠账（含 D-3 那条报数为下一轮第一条判言） |

**没被选中的两档不是"不存在"**：§2.2 那层根因**仍然在**（放回备份 ⇒ 十二颗迁移永久跳过），
本轮买的只是"从此没人会以为 sidecar 里存着账"。这句话要以 §4.4 第 4 条的形式落到上位契约里，
否则下一轮的人（包括我）会把它当成已解决。

