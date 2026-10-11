#!/usr/bin/env bash
# 刀 2 广播链的三步验证（台账 2026-10-04-toone-crossing-real-delete.md §25/§26 的验收腿）
#
# 为什么要有这支脚本：本仓没有 Xcode test target，SwiftData/SwiftUI 那半只能靠
#   ① DEBUG 自检格（格 ⑮，进程内真跑）
#   ② 真机手删 + 日志判据（T-0，像素级判据只有你能看）
#   ③ 只读 SQL 数归属丢失（V-B1'，读的是你的活库）
# 三步散在三个终端里跑就会各数一遍口径；这里收成一条命令，判据写死在码旁。
#
# 用法：
#   ./scripts/verify_graph_broadcast.sh              # ① → ② → ③（② 需要你动手删、③ 需要你亲口确认）
#   ./scripts/verify_graph_broadcast.sh --grid       # 只跑 ①（不碰活库，CI 可用）
#   ./scripts/verify_graph_broadcast.sh --skip-build # 复用上次构建产物
#   ./scripts/verify_graph_broadcast.sh --no-live    # 跑 ①，跳过 ②（③ 仍会打印命令）
#
# ⚠️ 步骤 ③ 的口径：本仓有一条明令 —— **不要由工具去打开你的活库**。WAL 库即使以只读方式打开，
#    SQLite 也可能需要创建/改写 -shm 边车文件，那是写副作用。所以 ③ 默认**只打印命令**，
#    要真跑得你亲手输入 run；且脚本会先确认 SunCut 已退出。
# ⚠️ 全部消息串里 `$变量` 后一律紧跟 ASCII 或写成 ${var}：macOS 自带 bash 3.2 在 UTF-8 locale 下
#    会把紧贴变量的全角标点吞进变量名（由 check_project_integrity.sh 的第三道门守着）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRID_ONLY=0
SKIP_BUILD=0
NO_LIVE=0
for arg in "$@"; do
  case "$arg" in
    --grid) GRID_ONLY=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --no-live) NO_LIVE=1 ;;
    -h|--help) sed -n '1,26p' "$0"; exit 0 ;;
    *) echo "未知参数：${arg}（可用 --grid / --skip-build / --no-live）"; exit 2 ;;
  esac
done

fail=0
say()  { printf '%s\n' "$*"; }
pass() { printf 'PASS %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fail=$((fail + 1)); }

# ---------------------------------------------------------------- 步骤 ① 格 ⑮（假库根，不碰活库）

say "== ① 格 ⑮：发布口 + 中心广播的功能验证 =="

APP=""
locate_app() {
  local line
  line="$(xcodebuild -project "$ROOT/MixCut.xcodeproj" -scheme MixCut -configuration Debug \
          -showBuildSettings 2>/dev/null \
        | sed -n 's/.*TARGET_BUILD_DIR = //p' | head -1)"
  [ -n "$line" ] || { bad "取不到 TARGET_BUILD_DIR"; return 1; }
  APP="$line/SunCut.app"
  [ -d "$APP" ] || { bad "构建产物不存在：$APP"; return 1; }
  return 0
}

if [ "$SKIP_BUILD" = "0" ]; then
  say "  构建中（xcodebuild Debug）……"
  if ! xcodebuild -project "$ROOT/MixCut.xcodeproj" -scheme MixCut -configuration Debug \
        -destination 'platform=macOS' build 2>&1 | grep -q "BUILD SUCCEEDED"; then
    bad "构建未成功 —— 后面两步没有可跑的二进制"
    exit 1
  fi
  pass "构建成功"
fi
locate_app || exit 1
say "  产物：$APP"

WORKROOT="$(mktemp -d)"
OUT="$WORKROOT/grid15"
MIXCUT_SELFTEST_TOMBSTONE=1 MIXCUT_SELFTEST_TOMBSTONE_GRID=15 \
MIXCUT_DEBUG_APP_SUPPORT_ROOT="$WORKROOT" \
MIXCUT_SELFTEST_OUT="$OUT" \
LLVM_PROFILE_FILE="$WORKROOT/app-%p.profraw" \
  "$APP/Contents/MacOS/SunCut" >/dev/null 2>&1 &
APPPID=$!
# 格 ⑮ 全跑约 1~2 秒；给到 20 秒余量，到点还没写完也照样读盘（自检是逐行 flush 的）
for _ in $(seq 1 20); do
  sleep 1
  [ -f "$OUT.grid15.txt" ] && grep -q "^- 结论：" "$OUT.grid15.txt" && break
done
kill "$APPPID" 2>/dev/null
# 收尸要显式 wait：不 wait 的话 bash 会把 "Terminated: 15" 的作业控制消息喷进 stdout，
# 盖在判据读数上面，让人误以为那一行是判据的一部分。
wait "$APPPID" 2>/dev/null
pkill -f "SunCut.app/Contents/MacOS/SunCut" 2>/dev/null
sleep 1

REPORT="$OUT.grid15.txt"
if [ ! -f "$REPORT" ]; then
  bad "没读到格 ⑮ 报告：${REPORT} —— 判据无法成立，不算通过"
else
  say "  读数（逐腿，原文摘自 ${REPORT}）："
  # 用 awk 不用 sed：报告最后一行没有结尾换行，BSD sed 会原样省掉 ⇒ 下面那行 PASS 会粘在同一行上
  awk 'NR>=2 && NR<=8 { print "    " $0 }' "$REPORT"
  if grep -q "^- 结论：通过" "$REPORT"; then
    pass "格 ⑮ 六腿全过（投递 / 降级 / 嵌套不丢 / 中心代广播 / 空台账不发 / 顶掉顺序）"
  else
    bad "格 ⑮ 不通过 —— 按上面逐腿读数定位"
  fi
  # 反向对照的口径提醒：F 腿的 b==0 意味着"真删义务被一次空调用吃掉"
  if grep -q "B commit 0 次" "$REPORT"; then
    bad "F 腿读到 B commit 0 次 ⇒ 广播又早于新事务登记了（§26 第一个窗口复发）"
  fi
fi
rm -rf "$WORKROOT"

if [ "$GRID_ONLY" = "1" ]; then
  say ""; [ "$fail" = "0" ] && say "全部通过（只跑了 ①）" || say "有 ${fail} 条未通过"
  exit $((fail > 0))
fi

# ---------------------------------------------------------------- 步骤 ② T-0 真机（你的活库）

# 路径真源：Sources/MixCutCore/Brand.swift:24-25（logs 目录 = bundleID/logs，文件 = shortName.log）
LOG="${HOME}/Library/Caches/com.suncut.app/logs/suncut.log"

if [ "$NO_LIVE" = "1" ]; then
  say ""; say "== ② 已按 --no-live 跳过 =="
elif [ ! -t 0 ]; then
  say ""; say "== ② 跳过：这一步要你在真 App 里动手删，必须占一个交互终端 =="
  say "  （非交互环境下不启动应用，也不给判据 —— 空跑出来的 0 行会被误读成「链没交台账」）"
  say "  单独跑这一步：./scripts/verify_graph_broadcast.sh --skip-build"
else
  say ""
  say "== ② T-0 真机验证（这一步的判据一半是像素，只能你看） =="
  if [ ! -f "$LOG" ]; then
    bad "读不到日志 ${LOG} —— 先正常启动过一次再跑这支脚本"
  else
    if pgrep -x SunCut >/dev/null 2>&1; then
      say "  ⚠️ 已有一个 SunCut 在跑 ⇒ 本次会再开一个新实例，验证请只做在这个新窗口里"
    fi
    OFFSET="$(wc -c < "$LOG" | tr -d ' ')"
    open -n "$APP"
    say "  应用已启动。请在窗口里做两件事，做完回来按回车："
    say "    1) 删一个视频（素材导入页，等 5 秒撤销条走完，别点撤销）"
    say "    2) 删一个项目（侧栏，同样等它走完）"
    say "  顺手用眼睛记两条：侧栏/分镜库是否少掉对应的项，以及**有没有整页骨架闪烁**。"
    # 上一版这里写的是 `read -r _ "提示"`：bash 把第二个参数当**变量名**，当场报 not a valid
    # identifier 并且**根本不等待** ⇒ 脚本立刻去读日志，读到的 0 行被误判成"链没交台账"。
    # 提示语必须走 -p。
    read -r -p "  做完按回车继续：" _
    read -r -p "  你实际真删了几次（回车=2）：" N_DEL
    read -r -p "  其中删项目几次（回车=1）：" N_PROJ
    # 非数字一律回落到默认值：否则后面 `-eq` 会让 bash 报语法错并把判据整体跳过
    case "$N_DEL" in ''|*[!0-9]*) N_DEL=2 ;; esac
    case "$N_PROJ" in ''|*[!0-9]*) N_PROJ=1 ;; esac
    DELTA="$(tail -c +"$((OFFSET + 1))" "$LOG")"
    if [ -z "$(printf '%s' "$DELTA" | tr -d '[:space:]')" ]; then
      bad "日志没有任何新增 ⇒ 本步没采到证据（不是你删错了，就是日志判据漂了），不计入代码结论"
    else
      N_PRUNE="$(printf '%s' "$DELTA" | grep -c "\[GraphPrune\] 剪枝" || true)"
      N_SETTLE="$(printf '%s' "$DELTA" | grep -c "\[GraphSettle\]" || true)"
      N_NEST="$(printf '%s' "$DELTA" | grep -c "嵌套广播入队" || true)"
      say "  日志增量读数：剪枝 ${N_PRUNE} 行、结算 ${N_SETTLE} 行、嵌套入队 ${N_NEST} 行（真删 ${N_DEL} 次 / 其中项目 ${N_PROJ} 次）"
      printf '%s\n' "$DELTA" | grep -E "\[GraphPrune\]|\[GraphSettle\]" | sed 's/^/    /'
      # 剪枝行数必须恰好等于真删次数：多=同一次被投两次，少=那条链没交台账
      if [ "$N_PRUNE" -eq "$N_DEL" ]; then
        pass "一次删除只投一次（剪枝 ${N_PRUNE} 行 = 真删 ${N_DEL} 次）"
      elif [ "$N_PRUNE" -gt "$N_DEL" ]; then
        bad "剪枝 ${N_PRUNE} 行 > 真删 ${N_DEL} 次 ⇒ 同一次删除被投了两次"
      else
        bad "剪枝 ${N_PRUNE} 行 < 真删 ${N_DEL} 次 ⇒ 有链没交台账。注意：删策略/删方案是**刻意**交空台账（§26 在册欠账 1），若你删的是那两类，这里应该少 —— 那就把这条读数回给方案侧而不是改码"
      fi
      if [ "$N_SETTLE" -eq "$N_PROJ" ]; then
        pass "删项目链每次都走过咽喉（[GraphSettle] ${N_SETTLE} 行）"
      else
        bad "[GraphSettle] ${N_SETTLE} 行 ≠ 删项目 ${N_PROJ} 次 ⇒ 删项目没走咽喉，或日志判据漂了"
      fi
      if [ "$N_NEST" = "0" ]; then
        pass "没出现嵌套入队"
      else
        say "  ⚠️ 出现嵌套入队 ${N_NEST} 次：事件没丢（现在是排空队列），但这个形状值得回给方案侧"
      fi
    fi
    say "  还需你口头确认的两条（脚本判不了）：侧栏与分镜库少得干净；**没有整页骨架闪烁**"
    say "  （闪烁 = 走了无载荷全量重载 ⇒ 那条链的台账被判成不可剪枝，见 §26 的台账口径）"
  fi
fi

# ---------------------------------------------------------------- 步骤 ③ 只读 SQL（默认只打印）

say ""
say "== ③ 数归属丢失（V-B1'）：每删一次项目被抹掉的导入归属 =="
say "  口径已改：盘上外键在 save 时就被清掉（§23 的 ⑬），所以**没有悬空 FK 可查**，"
say "  要数的是 ZOWNERPROJECT 为空 —— 这条数只决定回填工序的优先级，不是崩溃判据。"
SQL="SELECT COUNT(*) FROM ZVIDEO WHERE ZOWNERPROJECT IS NULL;"
say "  命令（交给你自己在终端跑，这是本仓纪律）："
say "    pkill -x SunCut   # 先退应用，否则 WAL 边车会让只读打开也产生写副作用"
say "    sqlite3 -readonly \"\$HOME/Library/Application Support/Suncut/Suncut.store\" '${SQL}'"
if [ "$NO_LIVE" = "1" ] || [ "$GRID_ONLY" = "1" ] || [ ! -t 0 ]; then
  say "  （本次未询问是否代跑）"
else
  printf '  要我替你跑这条只读查询吗？输入 run 才跑，其它任意输入跳过：'
  read -r ANSWER
  if [ "$ANSWER" = "run" ]; then
    if pgrep -x SunCut >/dev/null 2>&1; then
      bad "SunCut 还在运行 ⇒ 拒绝打开活库（WAL 写副作用风险）。先退出应用再重跑 ③"
    else
      say "  读数：$(sqlite3 -readonly "$HOME/Library/Application Support/Suncut/Suncut.store" "$SQL" 2>&1)"
      say "  判读口径：0 或个位数 ⇒ 当潜在风险留着；几十上百 ⇒ 先补回填工序再谈别的（台账 §23）"
    fi
  else
    say "  已按你的选择跳过（只打印命令）"
  fi
fi

say ""
if [ "$fail" = "0" ]; then
  say "全部通过：① 已实测；②③ 里凡脚本判不了的项已在上面逐条列出，需你口头确认"
else
  say "有 ${fail} 条未通过 —— 别把这支脚本的 PASS 读成「根因已解决」，本案根因仍未定（台账 §26）"
fi
exit $((fail > 0))
