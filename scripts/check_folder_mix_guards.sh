#!/usr/bin/env bash
# 文件夹混剪守卫（计划 docs/superpowers/plans/2026-10-20-folder-mix-by-category.md Step 6）
#
# 每条门都写**适用边界 + 豁免边界**二值声明 —— 不写就会把既有正常功能一起挡红。
# 期望值全部来自实测（脚本末尾的 selfreport 会把今天的读数再打一遍），不是随手写的数字。
#
# 用法：./scripts/check_folder_mix_guards.sh
#       ROOT_OVERRIDE=<目录>  把探针根指向改动前的快照，用它证明这些门确实会红
#       SELFTEST=1            只打印读数不判定（自测腿用）
#
# 注意：刻意不开 set -e —— grep 无命中时退出码为 1，会在断言打印之前静默中止脚本（本仓踩过）。
set -uo pipefail

ROOT="${ROOT_OVERRIDE:-$(cd "$(dirname "$0")/.." && pwd)}"
fail=0

# 探针根自证：不存在的目录与"真的干净"读数都是 0，必须先把它们区分开（前案：判据在空集上假绿）
for probe in "$ROOT/MixCut" "$ROOT/Sources/MixCutCore" "$ROOT/Tests" "$ROOT/docs/superpowers/plans"; do
    if [ ! -d "$probe" ]; then
        echo "FAIL[判据失效] 探针根不存在：$probe"
        fail=1
    fi
done
[ "$fail" -ne 0 ] && { echo "—— 探针根都没命中，后面所有读数都不算通过"; exit 1; }

# 下限判定（承重日志这类门要的是"至少这么多"，等号会随每次加日志就红，逼人不写日志）
expect_min_files() {  # label pattern want_min source file...
    local got; got=$(count_files "$2" "${@:5}")
    if [ "$got" -ge "$3" ]; then
        echo "PASS $1（命中 ${got}，下限 $3）"
    else
        echo "FAIL $1（命中 ${got}，下限 $3）"; echo "     期望出处：$4"; fail=1
    fi
}

# 目录作用域：递归 + 只要 *.swift + 去掉整行注释（注释里提到某个 token 不算一处站点）
count_dirs() {
    { grep -rn --include="*.swift" -E "$1" $2 2>/dev/null || true; } \
        | { grep -vE ':[0-9]+:[[:space:]]*(///|//|\*)' || true; } | wc -l | tr -d ' '
}
# 显式文件作用域（-h 去掉文件名，逐文件计数后求和；曾经用 grep -rc 的多文件形态踩过坑：
# 它打印的是 "文件:次数"，再按 awk '{s+=$1}' 求和就恒等于 0）
count_files() {
    local pattern="$1"; shift
    # -h 让输出只剩代码本体 ⇒ 能像 count_dirs 一样剥掉整行注释。
    # 曾用 `grep -h -c` 求和：那样注释行也被算进去，本文件第一跑就被自己写的
    # 一句「不是 SystemRandomNumberGenerator」的说明判成了站点命中（假红）。
    { grep -hn -E "$pattern" "$@" 2>/dev/null || true; } \
        | { grep -vE '^[0-9]+:[[:space:]]*(///|//|\*)' || true; } | wc -l | tr -d ' '
}

expect_dirs() {   # label pattern dirs want source
    local got; got=$(count_dirs "$2" "$3")
    if [ "$got" = "$4" ]; then
        echo "PASS $1（命中 ${got}，期望 $4）"
    else
        echo "FAIL $1（命中 ${got}，期望 $4）"; echo "     期望出处：$5"
        { grep -rn --include="*.swift" -E "$2" $3 2>/dev/null || true; } \
            | { grep -vE ':[0-9]+:[[:space:]]*(///|//|\*)' || true; } | head -6 | sed 's/^/     /'
        fail=1
    fi
}

expect_files() {  # label pattern want source file...
    local got; got=$(count_files "$2" "${@:5}")
    if [ "$got" = "$3" ]; then
        echo "PASS $1（命中 ${got}，期望 $3）"
    else
        echo "FAIL $1（命中 ${got}，期望 $3）"; echo "     期望出处：$4"
        { grep -Hn -E "$2" "${@:5}" 2>/dev/null || true; } | head -6 | sed 's/^/     /'
        fail=1
    fi
}

# 混剪新增的产品码文件（一条通路的全部落点；漏登一个文件 = 那条门看不见它）
# 〔笔 1b 扩面〕`ClipIngestService.swift` 是入库真身搬家后的住所。它不进 LANE 的话，
#   G-d1（零 ASR / 零 AI / 零网络）与 G-a1（不许自长随机源）对**搬家后的真身完全失明** ——
#   而入库这一步恰恰是最容易被塞进网络/分析调用的地方。本仓在 `pendingBatchSource`
#   上栽过同形：符号搬走了、门还在、读数恒绿。
# 〔笔 4 扩面〕再加两颗探针 reader：它们是"扫描期读盘"的唯一出口，
#   而这条通路对外承诺的是**零 AI、零网络**（D8）—— 探针缝恰恰是最容易被顺手接上
#   "顺便调一次云端识别"的地方。不扩这两颗，G-d1 对新增的 IO 面完全失明。
#   注意：Core 那颗 `FolderMixResolve.swift` **不进 LANE** —— LANE 是 App 层扫描面，
#   Core 由本脚本末尾的规模计数按文件名前缀自动接住（写成两遍会漂）。
LANE="$ROOT/MixCut/ViewModels/FolderMixViewModel.swift
$ROOT/MixCut/Views/Import/FolderMixView.swift
$ROOT/MixCut/Services/Import/MaterialFolderScanner.swift
$ROOT/MixCut/Services/Import/ClipIngestService.swift
$ROOT/MixCut/Services/Import/FolderMixDurationReader.swift
$ROOT/MixCut/Services/Import/FolderMixContentKeyReader.swift"
CORE="$ROOT/Sources/MixCutCore"

echo "== G-a 新通路不许长出自己的随机源 =="
# 适用边界：LANE 里每一颗文件（数量会随落点增加，所以这里不写颗数）+ Core 的 FolderMix*/WholeClipShape/SplitMix64 宿主。
#   随机性必须是**注入 seed 的纯函数**（SplitMix64），否则这一条链在测试里不可复现（计划 R1）。
# 豁免边界：`MixCut/ViewModels/DubbingViewModel.swift:655` 的 `Int.random(in:)` 是配音变体
#   风格基线的既有功能，不在本门射程（本期不动它；要收编另案）。测试夹具里的 `.shuffled()`
#   也不在射程（Tests 目录不参与本门）。
for f in $LANE; do
    [ -f "$f" ] || { echo "FAIL[G-a 判据失效] 混剪落点文件不存在：$f"; fail=1; }
done
expect_files "G-a1 LANE 全部落点内 SystemRandomNumberGenerator/.random(in:)/randomElement()/shuffled()" \
    'SystemRandomNumberGenerator|\.random\(in:|randomElement\(\)|shuffled\(\)' 0 \
    "计划 Step 1：随机源只用 Core 的 SplitMix64（值类型、注入 seed）。真随机一旦进来，R1「同 seed 幂等」当场失效，53 条择片判据全部失去意义" \
    $LANE
expect_dirs "G-a2 全仓 SystemRandomNumberGenerator 显式使用" \
    'SystemRandomNumberGenerator' "$ROOT/MixCut $ROOT/Sources" 0 \
    "Swift 的 Int.random/Array.randomElement 内部就是它；本期只锁显式名字，隐式用法由 G-a1 的作用域承担"

echo "== G-b 30 秒闸只归 B 通路 =="
# 适用边界：`ImportViewModel.selfSegmentMaxDuration` 的定义处恰好 1 处，且混剪新代码不许引用它。
#   丁案下 C 根本不经过这条闸（那是自建分镜的规则），引用它 = 把 B 的语义漏进 C。
# 豁免边界：文案里跟着走的那两处（SegmentLibraryView 的提示语、ImportViewModel 内部）算引用，
#   所以这里只数**定义**，不数引用。
expect_dirs "G-b1 30 秒闸的定义处只许 1 处" 'selfSegmentMaxDuration: Double = 30' \
    "$ROOT/MixCut $ROOT/Sources" 1 \
    "计划 Step 6 G-b：改这一个常量即可、文案跟着走（ImportViewModel.swift:488）。第二份副本 = 两处会漂"
expect_files "G-b2 混剪新代码不得引用 30 秒闸" 'selfSegmentMaxDuration' 0 \
    "D5 已拍「不受 30 秒上限约束，所有视频都参选」；C 走丁案根本不经过它" $LANE

echo "== G-c 判定住在 Core，View 只做装配 =="
# 适用边界：MixCut/Views/** 内不得出现择片/上限/形状判定的**函数名**。
# 豁免边界：View 调 ViewModel 的方法（ceiling / drawBatch / rerollCurrentRow）不算判定 ——
#   那是装配；判定本体必须在 Sources/MixCutCore（可被 swift test 覆盖）。
# 〔笔 2 改名〕旧清单里的 `maxWithoutRepeat` 已随 min 口径一起删净。
#   符号不存在了、门还在 ⇒ 这条会**恒绿**（本仓在 `pendingBatchSource` 上栽过同形）。
#   清单换成新机理的入口名，并加 `FolderMixLimits`：钳位/上限也不许在 View 里够 Core 常量。
expect_dirs "G-c1 MixCut/Views 内不得出现组合口径与判定符号" \
    'combinationCount|sampleDistinctOrdinals|FolderMixCombo|drawMany|FolderMixPicker|WholeClipShape|DiskSpaceBudget|FolderMixLimits' "$ROOT/MixCut/Views" 0 \
    "计划 Step 6 G-c + 第二轮 D30：上限与抽取的口径若长在 View 里，swift test 一条都覆盖不到它"

echo "== G-d 新通路零 AI / 零网络 =="
# 适用边界：LANE 全部落点内不得出现 ASR / AI 打标 / 网络客户端 / 方案元信息反推服务。
# 豁免边界：**B（自建分镜上传）与 importVideos 的阶段 2 必须允许调 AI/ASR** —— 那是既有正常功能，
#   不在本门射程；把它们一起挡掉等于把功能删了。另：混剪确实要调 `createCustomScheme`，
#   所以本门数的是 `schemeService`（网络那颗），不是 schemeVM。
expect_files "G-d1 混剪新代码不得调 ASR/AI/网络" \
    'ASRService|AIAnalysisService|Whisper|whisper|URLSession|tagSingleSegment|schemeService|reidentify' 0 \
    "D8 已拍「全跳过：不跑 ASR、不跑 AI 打标」（计划 Step 2 丁案 + 验收 6 断网全流程）" $LANE
expect_files "G-d2 混剪调 createCustomScheme 时必须显式关掉元信息反推" 'inferMetadata: false' 1 \
    "计划 Step 5：现路径在 SchemeViewModel.swift:984 调 inferMetadata（网络）。开关存在但没人传 false = D8 落空" \
    "$ROOT/MixCut/ViewModels/FolderMixViewModel.swift"
expect_files "G-d3 不许出现 inferMetadata: true（默认值形态）" 'inferMetadata: true' 0 \
    "写了 true 就等于允许网络调用；不传则是靠默认值 —— 两者都不许出现在混剪通路" $LANE

echo "== G-e 侧栏 case 数 == 菜单 ⌘ 绑定数 =="
# 适用边界：ContentView 的 `enum NavigationItem` 的 case 数，必须等于 MixCutApp 里
#   `CommandGroup(after: .toolbar)` 内的 `.keyboardShortcut` 绑定数。
# 豁免边界：无。**本期新发现**（计划 R1/风险 5）：全仓原来没有任何脚本数过这个对齐，
#   而 ⌘7（知识库）在侧栏提示里已经写了却根本没有绑定 —— 提示在说做不到的话。
CASES=$(awk '/^enum NavigationItem/,/^}/' "$ROOT/MixCut/App/ContentView.swift" | grep -c '^    case ')
BINDS=$(awk '/CommandGroup\(after: .toolbar\)/,/^            }/' "$ROOT/MixCut/App/MixCutApp.swift" \
        | grep -c 'keyboardShortcut')
if [ "$CASES" = "$BINDS" ]; then
    echo "PASS G-e1 侧栏 case 数 == ⌘ 绑定数（各 ${CASES}）"
else
    echo "FAIL G-e1 侧栏 case 数 $CASES != ⌘ 绑定数 $BINDS"; echo "     期望出处：计划 Step 6 G-e + 风险 5"; fail=1
fi
DUP=$(awk '/CommandGroup\(after: .toolbar\)/,/^            }/' "$ROOT/MixCut/App/MixCutApp.swift" \
      | grep -oE 'keyboardShortcut\("[0-9]"' | sort | uniq -d | wc -l | tr -d ' ')
if [ "$DUP" = "0" ]; then
    echo "PASS G-e2 ⌘ 数字键无重复绑定"
else
    echo "FAIL G-e2 有重复的 ⌘ 数字绑定（$DUP 种）"; echo "     同一个快捷键绑两页 = 后绑的吃掉前一个"; fail=1
fi

echo "== G-g 计划台账的行号与形状（搬进仓的那条腿）=="
# 适用边界：本期新立的那份台账（默认路径）。
# 豁免边界：其余历史 plan 文档按各自形状写成，未按本脚本约定收口 ⇒ 要纳入就显式传路径。
if command -v python3 >/dev/null 2>&1; then
    if python3 "$ROOT/scripts/check_plan_doc_citations.py" >/tmp/fm_doc.out 2>&1; then
        echo "PASS G-g 计划台账形状与 file:line 引用自检通过（$(tail -1 /tmp/fm_doc.out)）"
    else
        echo "FAIL G-g 计划台账自检不干净："; tail -8 /tmp/fm_doc.out | sed 's/^/     /'; fail=1
    fi
else
    echo "SKIP G-g 没有 python3 ⇒ 这一腿没跑，不算通过"
fi

echo "== G-h 新通路关键路径必须打 [FolderMix] 前缀 =="
# 适用边界：扫描 / 建库入库 / 择片 / 建 N 方案 / 丢段 这几处关键路径都要有可 grep 的前缀。
#   数前缀的写法照既有先例：check_navigation_readiness_guards.sh 的 G07 用 expect_count 数 [Readiness]。
# 豁免边界：非关键的调试碎日志不要求前缀；本门数的是"关键路径至少 6 处"——
#   〔笔 5 改档 4 → 6〕这六处分别是：扫描 / 抽片 / 入库与建库失败 / 解析缺段（时长与校验和读不出的
#   逐名）/ 建 N 方案 / 超量与短路。为什么下限要抬：本轮把探针与替补都挪到后台渐进，
#   失败面从"一次弹 toast"变成"一批里静默少几条"，没前缀的碎日志根本对不上是哪条通路少的手。
expect_min_files "G-h1 混剪新代码的 [FolderMix] 前缀" '\[FolderMix\]' 6 \
    "计划 Step 6 G-h：桌面端报障只有一行行文本，没前缀就只能靠猜。这里是下限，实际更多" $LANE

echo "== G-i 视频扩展名白名单只许有一份 =="
# 适用边界：全仓（产品码）里 `"mp4"`/`"mov"`/`"avi"`/`"m4v"`/`"mkv"` 这类带引号的扩展名字面量
#   只许出现在 `Sources/MixCutCore/FolderMixScanner.swift`。
# 豁免边界：① 注释/文档串里提到容器格式不算站点（上面两个 helper 都先剥整行注释）；
#   ② **文案**里的自然语言（如分镜库上传提示那句「mp4/mov」）不带引号形态，不在射程；
#   ③ 生成产物文件名用的 `"\(x).mp4"` 是**输出**扩展名，不是白名单判定，也不在射程。
# ⚠ `grep -rn` 数的是**命中行**，不是命中次数：五颗字面量写在一起就是一行。
expect_dirs "G-i1 全仓带引号的扩展名字面量（期望恰好 1 行，就是 Core 那一行清单）" \
    '"mp4"|"mov"|"avi"|"m4v"|"mkv"' "$ROOT/MixCut $ROOT/Sources" 1 \
    "Step 1 实测：原本有 3 份各写一遍的判据（ImportView.swift:474-477 / MixCutApp.swift:1141-1144 / ImportViewModel 的 UTType 表），已收成 VideoFileFormat 一处"
G_I_OTHER=$( { grep -rn --include="*.swift" -E '"mp4"|"mov"|"avi"|"m4v"|"mkv"' "$ROOT/MixCut" 2>/dev/null || true; } \
    | { grep -vE ':[0-9]+:[[:space:]]*(///|//|\*)' || true; } | wc -l | tr -d ' ')
if [ "$G_I_OTHER" = "0" ]; then
    echo "PASS G-i2 MixCut/（App 层）内扩展名字面量为 0（真源只在 Core）"
else
    echo "FAIL G-i2 App 层还有 $G_I_OTHER 处自己写白的扩展名清单"; echo "     半迁移 = 0：留一份旧判据就是一份会漂的口径"; fail=1
fi

echo "== G-j SplitMix64 只许一份定义 =="
# 适用边界：全仓（含 Tests）`struct SplitMix64` 的定义数 = 1。
# 豁免边界：引用（SplitMix64(seed:)）不算定义。本仓已两次记过裁定「复制随机源 = 第二份真源」
#   （OrphanFileFinderTests.swift:121、WhisperModelCatalogTests.swift:38）。
expect_dirs "G-j1 struct SplitMix64 定义数" 'struct SplitMix64' \
    "$ROOT/MixCut $ROOT/Sources $ROOT/Tests" 1 \
    "Step 1 把 ProjectVideoDedupTests 的 private 副本收编进 FolderMixPicker.swift；同算法由 FolderMixPickerTests.P12 的 golden 值钉住"

echo "== G-k 「自定义组合」容器只许一处构造 =="
# 适用边界：`name: "自定义组合"` 的构造点在 MixCut/ 内 = 1（MixStrategy.attachCustomGroup）。
# 豁免边界：四处旧拷贝（UI 建项 / MCP 建项 / 老项目补建 / createCustomScheme 双保险）已在
#   Step 4 收成一族；注释里提到这个名字不算站点。
expect_dirs "G-k1 name: \"自定义组合\" 构造点" 'name: "自定义组合"' "$ROOT/MixCut" 1 \
    "计划 Step 4 修族不修点：抄一份就多一处「将来加必备字段时只改了被调到的那份」的分歧点"

echo "== G-l 丁案不打自建标记 =="
# 适用边界：LANE 全部落点内不得出现 `isUserUploaded`。
#   C 的素材是整片母体，打上它 = 撒谎，且会被概览的 filter 掉（ProjectViewModel.swift:98）、
#   被分镜库归进 selfBuilt 分组（风险 1/2 的原始形态）。
# 豁免边界：B（自建分镜上传）通路照常打该标记，不在射程。
expect_files "G-l1 混剪新代码不得打 isUserUploaded" 'isUserUploaded' 0 \
    "计划 Step 2 丁案：不打该标记、不写自建注册表 ⇒ 类别项目在概览计数与分镜库分组里都按普通素材走" $LANE

echo "== 规模自报（今天的真实读数，供人核对判据有没有瞎）=="
echo "    [规模] 混剪 Core 文件：$(ls "$CORE" | grep -c '^FolderMix\|^WholeClipShape\|^DiskSpaceBudget') 颗"
echo "    [规模] 全仓 [FolderMix] 日志（含台账引用）：$( { grep -rn --include="*.swift" '\[FolderMix\]' "$ROOT/MixCut" 2>/dev/null || true; } | wc -l | tr -d ' ')"
echo "    [规模] NavigationItem case=$CASES / ⌘ 绑定=$BINDS"
echo "    [规模] 全仓 Int.random/Double.random 站点（本门不管，登记在册）：$( { grep -rn --include="*.swift" -E '\.random\(in:' "$ROOT/MixCut" 2>/dev/null || true; } | { grep -vE ':[0-9]+:[[:space:]]*(///|//|\*)' || true; } | wc -l | tr -d ' ')"

if [ "${SELFTEST:-0}" = "1" ]; then
    echo "SELFTEST 模式：只报读数不判定"
    exit 0
fi
[ "$fail" -eq 0 ] && echo "FOLDER MIX GATES: PASS" || echo "FOLDER MIX GATES: FAIL（$fail 条）"
exit $fail
