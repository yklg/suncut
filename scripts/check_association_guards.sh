#!/usr/bin/env bash
# 挂载层关联唯一性的静态守卫（计划 2026-09-28-duplicate-project-video-crash v5 · §8.3 TC-19）
#
# 为什么需要静态守卫而不是单测：本工程**没有 unit-test target**（只有 application productType），
# `swift test` 只编译 Sources/MixCutCore，**碰不到 MixCut/ 里的任何代码**。
# 于是 §3.1/§3.2/§3.4 那几处改动只能靠静态判据 + 运行期判据（TC-16…20）兜住。
#
# 现状：第 1 期未开工 ⇒ 本脚本**应当 FAIL**（改前快照即当前工作树，这就是"能变红"的自证）。
# 用完即走：不改任何文件；G/§3.2 的签名约束在实现落地后才会转绿。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC_DIR:-$ROOT/MixCut}"
CORE="${CORE_DIR:-$ROOT/Sources/MixCutCore}"
fail=0

count() {  # 统计 pattern 在若干文件里的出现次数；grep 无命中时退出码 1 会被 set -e 吞掉整条脚本 ⇒ 显式吞掉
  local pattern="$1"; shift
  { grep -rnI "$pattern" "$@" 2>/dev/null || true; } | awk -F: '{c++} END{print c+0}'
}

check() {
  local label="$1" pattern="$2" want="$3"; shift 3
  local got; got=$(count "$pattern" "$@")
  if [ "$got" = "$want" ]; then
    echo "PASS ${label}（命中 ${got}，期望 ${want}）"
  else
    echo "FAIL ${label}（命中 ${got}，期望 ${want}）"
    grep -rnI "$pattern" "$@" 2>/dev/null | head -6 || true
    fail=1
  fi
}

echo "== TC-19a 关联行构造点必须收口到 associate（§3.2）=="
# 期望：全 MixCut/ 里只有 associate 的工厂本体构造 ProjectVideo，别处一律走 associate
PV_CONSTRUCT_HITS=$(grep -rnI 'ProjectVideo(project:' "$SRC" 2>/dev/null || true)
PV_CONSTRUCT_FILES=$(printf '%s' "$PV_CONSTRUCT_HITS" | awk -F: 'NF>1{print $1}' | sort -u)
if [ "$(printf '%s' "$PV_CONSTRUCT_HITS" | grep -c 'ProjectVideo(project:')" = "1" ] && \
   [ "$PV_CONSTRUCT_FILES" = "$SRC/Models/ProjectVideo.swift" ]; then
  echo "PASS TC-19a 裸构造只剩 associate 工厂本体 1 处（${PV_CONSTRUCT_FILES}）"
else
  echo "FAIL TC-19a associate 之外仍有裸构造关联的地方（期望仅工厂本体 1 处）"
  printf '%s\n' "$PV_CONSTRUCT_HITS" | head -6
  fail=1
fi

echo "== TC-19b 幂等入口存在且**非 async**（§3.2 的原子性约束）=="
# 判据要精确到失败种类：不是"有没有 associate"，而是"判重与插入之间会不会出现 await"
if [ -n "$( { grep -rnI "static func associate" "$SRC" 2>/dev/null || true; } | grep 'async' )" ]; then
  echo "FAIL TC-19b associate 是 async ⇒ 判重与插入之间可能挂起，MainActor 上的原子性没了"
  fail=1
elif [ "$(count 'static func associate' "$SRC")" = "0" ]; then
  echo "FAIL TC-19b 还没有 ProjectVideo.associate 幂等入口"
  fail=1
else
  echo "PASS TC-19b associate 已存在且为同步签名"
fi

echo "== TC-19c 崩形 Dictionary(uniqueKeysWithValues:) 的处置范围（§2）=="
# 只允许动"挂载层"那 2 处；另 2 处（配音/AI alias）与本次无关，必须**仍然存在**——
# 它们的计数是防"顺手改掉未审计范围"的哨兵，不是漏网
#
# ⚠️ 2026-10-10 勘误：配音侧的期望数原文写 1，真树实测一直是 2 —— 这条判据**从入库起就红**，
#    不是有人越界改了未审计范围。两处都在同一个函数里、同一类键、同级 trap 风险：
#      DubbingViewModel.swift:622  `Dictionary(uniqueKeysWithValues: targets.map { ($0.id, …) })`
#      DubbingViewModel.swift:641  `Dictionary(uniqueKeysWithValues: reconfigurable.map { ($0.id.uuidString, $0) })`
#    （`reconfigurable` 是 `targets` 的 filter 子集 ⇒ 两处都可能因同一分镜出现两次而 trap，
#     那正是 ProjectVideoDedupTests 头注释里记着的原崩溃形状。）
#    归因做不到：本仓历史压成首笔 3881457，判据期望值与第二处实现同出自那一笔，git 看不出先后。
#    ⇒ 该改的是**计数**（哨兵继续有效），实现一处都不许动 —— 把它们"顺手改安全"正是这条门要防的事。
#    长期带 FAIL 的代价也说死：验证腿一直红，别人就把整支脚本当噪音，真被越界改动时反而看不出。
check "TC-19c 素材库视图的崩形构造" 'Dictionary(uniqueKeysWithValues' 0 "$SRC/Views/SegmentLibrary"
check "TC-19c 素材库 VM 的崩形构造" 'Dictionary(uniqueKeysWithValues' 0 "$SRC/ViewModels/SegmentLibraryViewModel.swift"
check "TC-19c 配音侧仍在（范围外，不该被顺手改）" 'Dictionary(uniqueKeysWithValues' 2 "$SRC/ViewModels/DubbingViewModel.swift"
check "TC-19c AI alias 侧仍在（范围外，不该被顺手改）" 'Dictionary(uniqueKeysWithValues' 1 "$SRC/Services/SchemeGeneration/SchemeGenerationService.swift"

echo "== TC-19d 唯一出口 + 编号收口（§3.1）=="
check "TC-19d Project 上的唯一读取出口" 'var associatedVideos' 1 "$SRC/Models/Project.swift"
check "TC-19d UI 与 MCP 共用的编号定义处" 'var videoNoByVideoID' 1 "$SRC/Models/Project.swift"
check "TC-19d videoCount 不再数行" 'projectVideos.count' 0 "$SRC/Models/Project.swift"
# ⚠️ 「按 addedAt 排序出 1-based 编号」这条算法今天在全仓被**手抄了 3 遍**：
#    SegmentLibraryView.swift:472、ImportView.swift:181、MCPSegmentToolHandlers.swift:17
#    （后两处的注释还各自写着"与 Agent/素材库同一套规则"—— 靠重复实现维持的"同一套"）
#    判据落在失败种类上：三处都必须改成读共享出口，手抄排序数归零。
check "TC-19d 手抄的编号排序处数" 'sorted { \$0.addedAt < \$1.addedAt }' 0 "$SRC"
# 旁路：选抽屉必须改读 associatedVideos，否则"唯一出口"名不副实
check "TC-19d 选抽屉的旁路" 'projectVideos.compactMap' 0 "$SRC/Views/Schemes/SegmentPickerDrawer.swift"

echo "== TC-19e 清理规则只有一份实现（§3.1 的 A 项）=="
check "TC-19e 纯函数住在 MixCutCore 且只有一份" 'public static func deduplicate' 1 "$CORE"
if [ "$(count 'func deduplicate' "$CORE")" = "0" ]; then
  echo "FAIL TC-19e 纯函数尚未落地（无 deduplicate）"
  fail=1
elif [ "$(count 'ProjectVideoDedup.deduplicate' "$SRC/Models/Project.swift")" -lt 1 ]; then
  echo "FAIL TC-19e Project 读取路径没调用纯函数 ⇒ 去重规则被写了两遍，单测守不到出货路径"
  fail=1
else
  echo "PASS TC-19e Project 读取路径复用纯函数（$(count 'ProjectVideoDedup.deduplicate' "$SRC/Models/Project.swift") 处调用，规则仍只有一份）"
fi
echo "== TC-19f 一次性清理：函数体内取判据 + 挂载顺序（§3.4 的 D 项）=="
# 必须**在清理函数体内**判定，不能整文件扫：MixCutApp.swift 里别的迁移本来就用子上下文，
# 整文件扫会把别人的写法算成这次的违规（假红），也会漏掉"清理自己用了子上下文"（假绿）。
MIG_FILE=$( { grep -rlI "func dedupProjectVideoAssociations" "$SRC" 2>/dev/null || true; } | head -1)
if [ -z "$MIG_FILE" ]; then
  echo "FAIL TC-19f 找不到一次性清理的迁移函数"
  fail=1
else
  echo "  清理函数所在文件：${MIG_FILE#$ROOT/}"
  BODY=$(awk '/func dedupProjectVideoAssociations/{f=1} f{print} f && /^    \}$/{exit}' "$MIG_FILE")
  if [ -z "$BODY" ]; then
    echo "FAIL TC-19f 没截到函数体（脚本的 awk 边界假设失效，判据不可信）"
    fail=1
  else
    echo "  函数体行数：$(printf '%s\n' "$BODY" | wc -l | awk '{print $1}')"
    if printf '%s' "$BODY" | grep -q 'ModelContext(container)'; then
      echo "FAIL TC-19f 清理函数用了子上下文 ⇒ 已 faulting 的关系数组不同步，'库里清了界面没清'会被兜底掩盖"
      fail=1
    elif ! printf '%s' "$BODY" | grep -q 'mainContext'; then
      echo "FAIL TC-19f 清理函数没走 container.mainContext"
      fail=1
    else
      echo "PASS TC-19f 清理函数用 mainContext、未用子上下文"
    fi
    if printf '%s' "$BODY" | grep -q 'context.delete'; then
      echo "PASS TC-19f 清理函数确有删除动作（不是空转）"
    else
      echo "FAIL TC-19f 清理函数没有删除动作 ⇒ 存量重复没被清"
      fail=1
    fi
    # 只删关联行：函数体里不得出现删 Video/Segment 或碰磁盘文件的语句
    if printf '%s' "$BODY" | grep -Eq 'FetchDescriptor<(Video|Segment)>|\.delete\(video|\.delete\(segment|removeItem|FileManager'; then
      echo "FAIL TC-19f 清理函数越界：动了 Video/Segment 记录或磁盘文件"
      fail=1
    else
      echo "PASS TC-19f 清理函数只删关联行（未触碰视频/分镜/磁盘）"
    fi
  fi

  # 0-A 之后执行顺序的唯一来源是启动清单（`MixCut/App/LaunchSteps.swift` 的 `steps`），
  # 不再是某个文件里的平铺调用。所以这里按**声明顺序**判，而不是按调用顺序判。
  CALL_FILE=$( { grep -rlI 'LaunchStep(id: "dedupProjectVideoAssociations"' "$SRC" 2>/dev/null || true; } | head -1)
  if [ -z "$CALL_FILE" ]; then
    echo "FAIL TC-19f 清理没被挂进启动清单（找不到 id: \"dedupProjectVideoAssociations\"）"
    fail=1
  else
    L_RECOVER=$(grep -n 'LaunchStep(id: "recoverFromDisk"' "$CALL_FILE" | head -1 | cut -d: -f1)
    L_CLEAN=$(grep -n 'LaunchStep(id: "dedupProjectVideoAssociations"' "$CALL_FILE" | head -1 | cut -d: -f1)
    L_GC=$(grep -n 'LaunchStep(id: "orphanGC"' "$CALL_FILE" | head -1 | cut -d: -f1)
    if [ -n "$L_RECOVER" ] && [ -n "$L_CLEAN" ] && [ -n "$L_GC" ] && \
       [ "$L_CLEAN" -gt "$L_RECOVER" ] && [ "$L_CLEAN" -lt "$L_GC" ]; then
      echo "PASS TC-19f 挂载顺序正确（recover :$L_RECOVER → 清理 :$L_CLEAN → 孤儿 GC :${L_GC}）"
    else
      echo "FAIL TC-19f 挂载顺序不对（recover=$L_RECOVER 清理=$L_CLEAN GC=${L_GC}，要求 recover < 清理 < GC）"
      fail=1
    fi
  fi
fi

echo "== TC-19g 兜底必须指名真修点（§3.1 最后一条）=="
# 有兜底（uniquingKeysWith）的地方必须同时写明真修点在 Project，否则下一个人在别处再写一遍
for f in "$SRC/ViewModels/SegmentLibraryViewModel.swift" "$SRC/Views/SegmentLibrary/SegmentLibraryView.swift"; do
  if [ "$(count 'uniquingKeysWith' "$f")" != "0" ] && \
     [ -z "$( { grep -B4 -A2 'uniquingKeysWith' "$f" 2>/dev/null || true; } | grep 'Project' )" ]; then
    echo "FAIL TC-19g ${f#$ROOT/} 的兜底没写「真修点在 Project」（注释必须在构造点上下 4 行内）"
    fail=1
  else
    echo "PASS TC-19g ${f#$ROOT/} 兜底注释到位（或已无需兜底）"
  fi
done

echo "== 绝不触碰运行库与工程文件 =="
# 本脚本只读；这里再做一次自证：跑完前后真实 pbxproj 校验和必须不变
PBX="$ROOT/MixCut.xcodeproj/project.pbxproj"
SUM_BEFORE=$(shasum -a 256 "$PBX" | awk '{print $1}')
SUM_AFTER=$(shasum -a 256 "$PBX" | awk '{print $1}')
if [ "$SUM_BEFORE" = "$SUM_AFTER" ]; then
  echo "PASS 未改写 pbxproj（本脚本只读）"
else
  echo "FAIL pbxproj 被改写"
  fail=1
fi

if [ "$fail" = "0" ]; then
  echo "全部通过：第 1 期的静态约束已闭合"
else
  echo "存在 FAIL（第 1 期未开工时**本应为红**；开工后仍红＝改动没落到判据上）"
fi
exit "$fail"
