#!/usr/bin/env bash
# 就绪态归属守卫（计划 fluid-spring-char §批一/批四 立，§批九/批十 改判据 · TC-G01…G14）
#
# 守的是两句话：
#   ① **骨架屏的判据住在 ViewModel，视图不许自持 loading 标志**。破这句，「点模块闪一下」就会复发
#      （`ContentView.detailView` 是 switch，视图实例每次导航都被重建，视图里的 @State 必然复位）。
#   ② 批十加：**骨架不许因换项目而上屏，换项目只许改禁点判据**。实测那次上屏要在同一次提交里
#      拆掉整棵旧内容树，窗口连续 3–10 帧（50–133ms）拿不到新帧 —— 就是用户报的闪屏。
#      量法：scripts/measure_nav_blank.sh（逐帧边缘能量），三个对照数在计划 §批九第 0 步④⑤。
#
# ⚠️ 批六曾加过一组「加载必须住在导航边界」的门（当时也叫 G13–G17），已随批六整体撤销 ——
# 那条方向（把 load 从视图 .task 上移到 ContentView.onChange）实测没修好跳动，反而新增概览跳动，
# 详见计划 §批八。本文件现在的 G13/G14 是批十新加的，与那组同号不同物，别混。
#
# 期望值出处见每条后面的注释，全部来自实测或本方案契约，不是随手写的数字。
#
# 关于「什么时候该是红的」：
#   批一交付时生产码尚未迁移，本脚本必然大面积报红 —— 那是设计好的（改前快照必须变红才算判据成立）。
#   批二/批三落完，G01/G02/G03/G05/G06/G07/G09/G12 转绿；批四把剩下的补齐。
#   任何一次「红的条目比预期少」都要当作判据失效来查，不要当成功。
#
# 用法：./scripts/check_navigation_readiness_guards.sh
#   ROOT_OVERRIDE=<目录> 可把探针根指向改动前的快照（用它证明这些门确实会红，而非恒绿）
#
# 注意：刻意不开 set -e —— grep 无命中时退出码为 1，会在断言打印之前静默中止脚本（本仓踩过）。
set -uo pipefail

ROOT="${ROOT_OVERRIDE:-$(cd "$(dirname "$0")/.." && pwd)}"
Views="$ROOT/MixCut/Views"
VMs="$ROOT/MixCut/ViewModels"
App="$ROOT/MixCut/App"
Core="$ROOT/Sources/MixCutCore"
fail=0

# 探针根自证：不存在的目录与「真的干净」读数都是 0，必须先把它们区分开
for probe in "$Views" "$VMs" "$App" "$Core"; do
    if [ ! -d "$probe" ]; then
        echo "FAIL[判据失效] 探针根不存在：$probe"
        fail=1
    fi
done
if [ "$fail" -ne 0 ]; then
    echo "—— 探针根都没命中，后面所有读数都不算通过"
    exit 1
fi

# 实测规模自报：先报今天到底扫到多少，再报判定
# 注：$path 故意不加引号，好让它能传目录列表（本仓路径无空格；有空格会把这里改成数组）
#     只扫 *.swift —— 这些判据说的是代码，把 .xcassets 里的二进制一起扫既慢（整脚本约 60 秒）又是噪声。
selfreport() {
    local label="$1" pattern="$2" path="$3"
    local got
    got=$( { grep -rc --include="*.swift" "$pattern" $path 2>/dev/null || true; } | awk -F: '{s+=$2} END{print s+0}')
    echo "    [规模] $label 实测 $got"
}

expect_count() {
    local label="$1" pattern="$2" path="$3" want="$4" source="$5"
    local got
    got=$( { grep -rc --include="*.swift" "$pattern" $path 2>/dev/null || true; } | awk -F: '{s+=$2} END{print s+0}')
    if [ "$got" = "$want" ]; then
        echo "PASS ${label}（命中 ${got}，期望 ${want}）"
    else
        echo "FAIL ${label}（命中 ${got}，期望 ${want}）"
        echo "     期望出处：$source"
        grep -rn --include="*.swift" "$pattern" $path 2>/dev/null | head -6 | sed 's/^/     /'
        fail=1
    fi
}

echo "== G01 视图不得出现 isLoading 这个 token（整棵树级门，比只查声明更硬）=="
selfreport "G01 现状" "isLoading" "$Views"
expect_count "G01 MixCut/Views 内 isLoading" "isLoading" "$Views" 0 \
    "改前实测 12 处，全在 SegmentLibraryView / ProjectOverviewView / ImportView（各 4）。就绪态一旦回到视图里，闪屏就复发 —— 所以整棵视图树都不许出现这个 token。"

echo "== G02 视图不得自持骨架开关 =="
expect_count "G02 MixCut/Views 内 @State private var isLoading" "@State private var isLoading" "$Views" 0 \
    "改前实测 3 处（三个模块视图各一个）。视图实例每次切模块都被销毁重建，@State 必然复位，这就是闪屏的成因。"

echo "== G03 骨架屏只剩两个宿主 =="
selfreport "G03 现状" "SkeletonView(layout" "$Views"
expect_count "G03 MixCut/Views 内 SkeletonView(layout:" "SkeletonView(layout" "$Views" 2 \
    "改前实测 3 处；素材导入的正文实时读 project.videos，骨架从无数据职责，已撤。宿主变成概览 + 分镜库两个。"

echo "== G04 判据的接口面：骨架无参数、禁点只吃项目 id =="
expect_count "G04a 骨架判据逐字是无参数属性" "public var needsSkeleton: Bool" "$Core" 1 \
    "契约 R1+R2（批十改）：骨架只由「屏上有没有任何项目数据」决定。它一旦长出项目参数，换项目就又上一次骨架，而那次上屏实测就是 50–133ms 的拆树空白。"
expect_count "G04b 禁点判据逐字只吃项目 id" "public func holdsData(for projectID: UUID) -> Bool" "$Core" 1 \
    "契约 R6：换项目只改变这条，不改变骨架。两条读法必须分离，合并成一条就是闪屏本体。"
# 旧契约的带参形态一律不许再出现（定义与调用两侧一起封）
expect_count "G04c 全仓不得出现 needsSkeleton(for: 形态" "needsSkeleton(for:" "$ROOT/MixCut $ROOT/Sources $ROOT/Tests" 0 \
    "批十之前的旧契约写法。留着它说明有人把骨架又挂回项目维度 —— 闪屏会当场复发。"

echo "== G05/G06 判据与落点各两处 =="
# 作用域按「谁该读判据」划分，不是一句「全仓」：
#   宿主视图各读一次 = 2；DEBUG 自检程序（DebugSelfTest）读它是合法取样，不该记进这道门；
#   而 ContentView 作为边界**不许**接管骨架判据（那是第二阶段的事），所以那里必须为 0。
expect_count "G05a MixCut/Views 内 needsSkeleton 读取" "readiness\.needsSkeleton" "$Views" 2 \
    "两个宿主视图各读一次：ProjectOverviewView 读 projectVM、SegmentLibraryView 读 viewModel。"
expect_count "G05b ContentView 不得自持骨架判据" "needsSkeleton" "$App/ContentView.swift" 0 \
    "边界只负责底色与动画驱动，加载与判据仍归各自 VM/视图（第一阶段范围）。"
expect_count "G06 ViewModels 内 markLoaded(for: 落点" "markLoaded(for:" "$VMs" 2 \
    "ProjectViewModel.refreshOverviewSnapshot 与 SegmentLibraryViewModel.loadSegments 末尾各一次。"

echo "== G13 旧画面必须禁点（批十：不换分支的代价要用禁点补回来）=="
expect_count "G13a holdsData 落在 allowsHitTesting 上" "allowsHitTesting(.*readiness\.holdsData(for: project\.id)" "$Views" 2 \
    "换项目那 150ms 屏上是上一个项目的画面，而里面的按钮回调捕获的是**新** project（如「上传自建分镜」走 importSelfSegments(into: project)）。只留视觉提示、漏掉禁点 = 跨项目误操作。"
expect_count "G13b 骨架分支不得再被项目 id 左右" "if .*readiness\.needsSkeleton {" "$Views" 2 \
    "两处 if 的条件里只允许有无参数属性；一旦看到 for: 就是退回旧契约。"

echo "== G15 冷启动预热：每进程至多一次，且只预热会亮骨架的那个面 =="
# 实测期望值来自批十选项 2 落地后的当前树。改前基线（同一棵树、没加预热时实测）：
#   预热调用点 = 1（只有 reloadAfterUndo 那一处，不是预热）、闸门 = 0。
selfreport "G15 现状（ContentView 预热调用点）" "segmentLibraryVM\.loadSegments(for:" "$App/ContentView.swift"
expect_count "G15a ContentView 必须给分镜库表面预热一次" "segmentLibraryVM\.loadSegments(for:" "$App/ContentView.swift" 2 \
    "实测 2 处：onAppear 里的冷启动预热（:98）+ reloadAfterUndo 里撤销/重做的重载（:166，批十之前就存在）。预热没了，冷启动后第一次点「分镜素材库」就仍要走一次骨架上屏 —— 那一次实测 100ms 侧栏空窗（尺子 scripts/measure_nav_blank.sh，18.12.41 录像），且别处不会变红。出现第 3 处则当作「有人在导航边界挂了每次换项目的 load」处理 —— 那条方向（批六 G13–G17）实测没修好跳动、反而新增概览跳动，已整块撤销。"
expect_count "G15b 预热必须带每进程一次的闸门" "readiness\.loadedProjectID == nil" "$App/ContentView.swift" 1 \
    "没有这个闸门，预热就挂在每次 onAppear 上：loadSegments 开头会清掉用户在分镜库里的多选、选中与预览。"

echo "== G07 永久骨架必须可被日志识别（v3 P1：声明了可见失败就得给判据）=="
expect_count "G07 ViewModels 内 [Readiness] 日志" "\[Readiness\]" "$VMs" 2 \
    "与既有 [Perf] 组成对照：有 [Perf] 无 [Readiness] 即判为骨架卡死而非加载慢。"

echo "== G08 不扩散：不闪的模块不许顺手加就绪态 =="
expect_count "G08 SchemeViewModel 内 readiness" "readiness" "$VMs/SchemeViewModel.swift" 0 \
    "方案模块今天不闪（SchemeListView 用 onAppear+onChange，无骨架），加就绪态属越界改动。"
expect_count "G08b ImportViewModel 内 readiness" "readiness" "$VMs/ImportViewModel.swift" 0 \
    "素材导入的正文实时读 project.videos（Observation 权威），骨架从来没有数据职责。"

echo "== G09 换模块动画只有一处驱动 =="
expect_count "G09 ContentView 详情容器的隐式动画" "\.animation(DesignTokens\.Motion\.transition, value: selectedNavItem)" "$App/ContentView.swift" 1 \
    "改前实测 0。「selectedNavItem = 」的写入散在 12 处（6 处包着 withAnimation、6 处裸写，分布在 SidebarView 与 ProjectOverviewView）；只有容器层驱动能覆盖全部写入者，否则侧栏有淡入而概览「快速操作」硬切 —— 同一手势两种手感。"

echo "== G10 prewarm 的调度契约：按项目分组，同项目不互杀 =="
# 模式带 `shared.` 前缀，只数调用点 —— 用 `prewarm(paths:` 会把 ThumbnailCache 里的
# **定义行**一起算进来（实测那样读到 5，本脚本初版就在这里写错了期望值）。
selfreport "G10 现状（调用点）" "shared\.prewarm(paths:" "$Views"
expect_count "G10 MixCut/Views 内 prewarm 调用点" "shared\.prewarm(paths:" "$Views" 3 \
    "改前实测 4 处调用：分镜库在同一个 .task 里连发两次（第二次必然 cancel 掉第一次），另两处是概览与素材导入。批三把分镜库那两处并成一次 → 3。"
expect_count "G10b 每处调用都带项目键" "shared\.prewarm(paths: .*, for: project\.id)" "$Views" 3 \
    "同项目合并进一条队列的前提是调用方交出 projectID。"

echo "== G11 R5：不做无人调用的 API =="
expect_count "G11 MixCutCore 内 invalidate" "invalidate" "$Core/ProjectDataReadiness.swift" 0 \
    "进入模块仍重跑 loadXXX，就绪态只管亮不亮骨架、不管数据新鲜度 → 没有调用者需要 invalidate（反假覆盖）。"

echo "== G12 详情区必须有 opaque 底色（交叉淡入不向窗口白底塌陷）=="
expect_count "G12 DesignTokens 里的底色令牌" "static let detailBackdrop" "$ROOT/MixCut/Utilities/DesignTokens.swift" 1 \
    "改前实测 0。详情区一直没有自己的底色：ContentView 那个 .background 槽位被两个 .opacity(0) 的快捷键按钮占着，所以交叉淡入时新旧两页一起透出窗口白底。"
expect_count "G12b ContentView 用上该底色" "Palette\.detailBackdrop" "$App/ContentView.swift" 1 \
    "令牌定义了但没用上等于没修。"

echo "== G14 一次性消融探针必须已删净（批九第 0 步③ 的销账门）=="
expect_count "G14 生产码里不得残留探针" "PROBE9\|probe9\|NavAblation\|SUNCUT_ABLATE" "$ROOT/MixCut" 0 \
    "SUNCUT_ABLATE 那套子树消融只为准归因临时而写，量完即删。留在树里就是这轮的新债：它会替生产分支决定渲染内容。"

echo
if [ "$fail" -eq 0 ]; then
    echo "PASS 就绪态归属守卫全部成立"
else
    echo "FAIL 有门未成立 —— 见上面每条 FAIL 的『期望出处』"
fi
exit "$fail"
