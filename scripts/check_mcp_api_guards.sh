#!/usr/bin/env bash
# 集成 / API 层功能门禁（计划 2026-10-04 分层重排：把功能测试主力从"鼠标点"换成"HTTP 调"）
#
# 这颗门自己管被测 App 的完整生命周期，因为实测发现外部 nohup / 后台任务拉起的 App
# 会随调用结束被回收，判据跑到一半就没服务了。
#
# 六道前置（任一不过就不跑用例，直接红）：
#   U01 产物必须是 Debug —— 假库开关 MIXCUT_DEBUG_APP_SUPPORT_ROOT 在 #if DEBUG 内
#       （MixCut/Utilities/FileHelper.swift:17-25，注释原文「Release 编译不进这一支」）。
#       拿 Release 跑会**静默**写用户真库。注意 Xcode 16 的 Debug 用 dylib 注入，
#       主二进制只是 58K stub，真身在 Contents/MacOS/*.debug.dylib —— 只扫主二进制
#       会两边都读 0 而恒绿（2026-10-04 踩过）。
#   U05 产物必须不早于它的源码 —— U01 只证明「是 Debug」，不证明「是当前的」，
#       而这条门是功能测试的主力腿：拿旧产物跑出来的绿灯，读的是旧构建的行为。
#       2026-10-11 的现场：默认产物停在 10-05，而 10-07~10-09 新加的 24 项 schema
#       已被新构建写进了假根 sidecar ⇒ schema 门判「消失 24 项」拒开库，
#       30 秒后本脚本以「端口没起来」红，把工装问题误归因到 MCP 层。
#   U03 8787 必须空闲 —— MCP 端口是硬编码常量（AgentGateway.swift:11），双实例必抢；
#       更重要的是：若有用户自己开的实例在持有端口，任何写调用都会打到他的活库。
#   U04 活库未被触碰 —— 跑前存基线校验和，跑后逐颗比对。
#       比对集含 launch-ledger：App 一启动就自己写它（台账 2026-10-04-mac2-ui-smoke-harness.md
#       §9.3 的实测结论，那次 Release 探针就是靠它才被抓到）。
#   U06 同一时刻只许一跑 —— 撞的不是端口而是 $WORK 下固定路径的共享文件（活库基线、偏好快照、
#       app.log）。产品自 b43962c 支持换端口后，U03 已拦不住两跑并发；最坏后果是把用户真实偏好
#       还原成假库项目 id（2026-10-04 真出过）。见下面 U06 那段完整理由。
#   偏好保护 —— App 在 selectedProject 的 didSet 里会把 lastSelectedProjectID 写回标准域
#       （ProjectViewModel.swift:18），而 Debug/Release 共用 bundle id ⇒ 会污染用户真实偏好。
#       所以跑前快照、退出时还原（实测教训：2026-10-04 曾把用户的值覆盖成假库项目 id）。
#
# 用法：bash scripts/check_mcp_api_guards.sh
#   环境变量：SUNCUT_APP=<.app 路径>  CATALOG_PATH=<目录真源>  KEEP_APP=1 跑完不关 App
#             PRODUCT_SRC_DIR=<产品源码根> 只给 selftest 合成扰动树用（同 CATALOG_PATH 一路惯例）
#   参数：--preflight-only 只跑前置（U01/U05/U03）就退出，不起 App、不动用户偏好 ——
#         selftest 用它先证明"产物是当前的"，否则下面每条腿红的原因都不是它自己。
# 注意：刻意不开 set -e —— 子命令非 0 退出码就是判据本身，不能被静默吞掉（本仓踩过）。
set -uo pipefail

PREFLIGHT_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --preflight-only) PREFLIGHT_ONLY=1 ;;
        *) printf '未知参数：%s（可用 --preflight-only）\n' "$arg" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 消息与退出码约定必须在**任何一次调用之前**定义：这三个函数原先住在文件中段，
# 而下面这两条 `invalid` 判据住在它们之前 —— 触发时 bash 报的是 command not found，
# 判据当场静默失效（脚本继续往下跑，两条安全阀形同不存在）。
note() { printf '%s\n' "$*"; }
die()  { printf 'FAIL %s\n' "$*" >&2; exit 1; }
invalid() { printf 'FAIL[判据失效] %s\n' "$*" >&2; exit 2; }

APP_PATH="${SUNCUT_APP:-$ROOT/.scratch/dd/Build/Products/Debug/SunCut.app}"
CATALOG="${CATALOG_PATH:-$ROOT/Sources/MixCutCore/AgentToolCatalog.swift}"
PORT="${MCP_PORT:-8787}"
# 故意**不**叫 SRC_DIR：`check_schema_ledger_guards.sh` 的 SRC_DIR 指的是 `MixCut/` 子树，
# 这里指的是**仓根**（要顺着 MixCut/ 与 Sources/ 两侧取文件）。两者不同域，
# 共用一个变量名会让"给一颗脚本导过 SRC_DIR"静默改坏另一颗的取样面。
PRODUCT_SRC="${PRODUCT_SRC_DIR:-$ROOT}"
# 产品侧端口能力（2026-10-09 起）：`AgentGateway` 读 `MIXCUT_MCP_PORT` 覆盖硬编码默认值，
# 并且**绑不上就非零退出**（`MCPServer.start()` 现在等 NWListener 真进 ready 才算成功）。
# 早先这里写的是「换端口毫无意义，产品只听 8787」——那是对的，因为当时确实没有覆盖能力；
# 当时的后果是：门禁与用户自己开着的实例抢 8787，谁先绑上谁应答，
# 写调用会打到**用户的活库**（2026-10-09 手搓 curl 绕过本门禁时真的发生过一次）。
# 现在换成反向判据：**覆盖能力不见了就是判据失效**，不许退回静默共用 8787。
if ! grep -q 'MIXCUT_MCP_PORT' "$PRODUCT_SRC/MixCut/Services/MCP/AgentGateway.swift" 2>/dev/null; then
    invalid "产品侧读不到 MIXCUT_MCP_PORT 覆盖点 —— 端口重回硬编码，门禁可能与用户实例抢 8787，判据失效"
fi
if ! grep -q 'stateUpdateHandler' "$PRODUCT_SRC/MixCut/Services/MCP/MCPServer.swift" 2>/dev/null; then
    invalid "MCPServer 不再观察 listener 状态 —— 绑不上端口会静默假成功，判据失效"
fi

WORK="$ROOT/.scratch/mcp-guards"
# 假根**每轮全新**：跨运行共享一棵数据根，等于让上一轮的 schema 记录来审判这一轮的二进制。
# schema 门的前提是「这份 sidecar 描述的就是这个库、由同一个 App 写的」（MixCut/App/SchemaGuard.swift），
# 共享根同时破坏前提与现场 —— 2026-10-11 那 4 份反向备份目录就是这么攒出来的。
# 用例侧不依赖跨轮数据（scripts/mcp_api_guards.py 建的项目带 GUARD 前缀、收尾逐个删回去）。
FAKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/suncut-mcp-guards.XXXXXX")" || die "建不出临时假根"
# LIVE_STORE_DIR 只给 selftest 用：指向一棵合成树，用来证明 U04 这颗判据真的会红，
# 而不去碰用户真库（拿真库做扰动等于故意写坏用户数据）。
LIVE_STORE="${LIVE_STORE_DIR:-$HOME/Library/Application Support/Suncut}"
BASELINE="$WORK/live_baseline.sha"
PREFS_SNAP="$WORK/prefs_snapshot.json"
LOG="$WORK/app.log"
fail=0

mkdir -p "$WORK"

PREFS_SNAPPED=0
APP_LAUNCHED=0
LOCK="$WORK/gate.lock"
LOCK_HELD=0

restore_prefs() {
    # 只在**本轮真存过快照**时还原：拿上一轮遗留的快照文件去 write，等于把旧值盖回用户偏好。
    [ "$PREFS_SNAPPED" = "1" ] || return 0
    python3 "$ROOT/scripts/make_ui_fixture.py" --prefs-restore "$PREFS_SNAP" >/dev/null 2>&1 \
        || note "WARN 偏好还原失败，请手工核对 defaults read com.suncut.app lastSelectedProjectID"
}

stop_app() {
    # 残留核对必须在杀进程**之后**做，否则永远误报（第一版就栽在把检查放在 trap 之前）
    [ -n "${APP_PID:-}" ] || return 0
    kill "$APP_PID" 2>/dev/null
    for _ in $(seq 1 12); do
        kill -0 "$APP_PID" 2>/dev/null || break
        sleep 0.5
    done
    wait "$APP_PID" 2>/dev/null   # 收尸，避免 bash 在退出时打一行 Terminated 噪声
    APP_PID=""
}

cleanup() {
    if [ "${KEEP_APP:-0}" != "1" ]; then
        stop_app
        # 兜底清扫只在本轮真起过 App 之后做：trap 现在装得早（为了收走临时假根），
        # 前置红掉时若照旧 pkill，会把用户自己开着的 SunCut 一起杀掉。
        [ "$APP_LAUNCHED" = "1" ] && pkill -x SunCut 2>/dev/null
        rm -rf "$FAKE_ROOT"
    fi
    restore_prefs
    # 锁要**在偏好还原之后**才放：否则下一跑会在我们还留着污染值的时候去做快照，等于把
    # 危险窗口从"并发"搬到了"交接"。且只放自己的锁（pid 对得上），不许误删别人正在持有的。
    if [ "$LOCK_HELD" = "1" ] && [ "$(sed -n '1p' "$LOCK" 2>/dev/null)" = "$$" ]; then
        rm -f "$LOCK"
    fi
}
# 装得早一点：U01/U05 这类前置红掉时也要把临时假根收走，不在 /tmp 下留垃圾。
trap cleanup EXIT

# ---------- 前置 U06：同一时刻只许有一跑门禁 ----------
# 撞的不是端口，是 $WORK 下那几颗**固定路径**的共享文件：活库基线 live_baseline.sha、
# 偏好快照 prefs_snapshot.json、app.log。U03 只按端口串行，而产品自 b43962c 起支持
# MIXCUT_MCP_PORT 覆盖 ⇒ 两跑换端口就能并发，U03 拦不住。
# 最坏的一条后果不是测试数据脏，而是**改错用户偏好**：后一跑在前一跑的实例已经把
# lastSelectedProjectID 写成假库项目 id 之后才做快照 ⇒ 它把污染值当"原值"存下，
# 退出时还原回去 ⇒ 用户的真实值永久错掉。这正是本文件头部记着的 2026-10-04 事故。
if [ -f "$LOCK" ]; then
    holder="$(sed -n '1p' "$LOCK" 2>/dev/null)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        invalid "另一跑集成层门禁正在持有 ${LOCK}（pid ${holder}，端口 $(sed -n '2p' "$LOCK" 2>/dev/null)）⇒ 本轮拒跑。
       两跑并发会互相覆盖 $WORK 下的活库基线与偏好快照，最坏会把用户真实偏好还原成假库项目 id。
       换 MCP_PORT 绕不开这条 —— 撞的从来不是端口。要并发请给每跑另设一个独立的 WORK。"
    fi
    note "WARN 发现陈旧锁（pid ${holder:-空} 已不在）⇒ 本轮接管"
fi
printf '%s\n%s\n%s\n' "$$" "${PORT}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK"
LOCK_HELD=1

# ---------- 前置 U01：产物必须是 Debug ----------
[ -d "$APP_PATH" ] || die "找不到被测产物：${APP_PATH}（先 xcodebuild -configuration Debug 构建）"
BIN_DIR="$APP_PATH/Contents/MacOS"
[ -d "$BIN_DIR" ] || invalid "产物里没有 MacOS 目录：$BIN_DIR"
# 扫全部可执行体（含 *.debug.dylib），不只看主二进制
valve_hits=0
oldest_bin=""          # 产物里最早的那颗 —— 即"这个包最后产出于何时"的下界
oldest_bin_mtime=""
while IFS= read -r bin; do
    n=$(strings "$bin" 2>/dev/null | grep -c 'MIXCUT_DEBUG_APP_SUPPORT_ROOT' || true)
    valve_hits=$((valve_hits + n))
    m=$(stat -f %m "$bin" 2>/dev/null) || continue
    if [ -z "$oldest_bin_mtime" ] || [ "$m" -lt "$oldest_bin_mtime" ]; then
        oldest_bin_mtime=$m; oldest_bin=$bin
    fi
done < <(find "$BIN_DIR" -maxdepth 1 -type f)
if [ "$valve_hits" = "0" ]; then
    invalid "产物里读不到假库开关字面量 ⇒ 这是 Release 或异常产物，跑起来会**静默写用户真库**。
       期望：$APP_PATH 是 Debug 构建（Contents/MacOS/ 下应有 SunCut.debug.dylib）"
fi
note "前置 U01 ✓ 产物含 DEBUG 假库开关（命中 ${valve_hits} 处）"
[ -n "$oldest_bin_mtime" ] || invalid "前置 U05 取不出产物时间戳 —— 判据无法成立，不算通过"

# ---------- 前置 U05：产物必须不早于它的源码 ----------
# 比的是**最早**那颗产物文件，不是最晚：只重链了 58K stub、真身 *.debug.dylib 还是旧的
# 那种半截构建，拿最晚会比出"新于源码"而假绿（自证 9 钉这一格）。
# 输入面**不按后缀筛**：包内二进制与资源换了同样算"测的不是当前代码"。
# 全集实测 294 个文件 / 单次 find 0.002s（Resources 3.2G 但只有 19 个文件），所以扫得起。
#
# ⚠️ 这条是**时间启发式，不是证明**。它只看 mtime，所以任何把 mtime 推到当下的操作都能骗过它：
#    `cp -R` 不带 `-p`、解压、rsync、Finder 拷贝（实测：把旧产物 touch 到 2099 年 ⇒ 判绿）。
#    它的错误方向是"假阳偏多"（新建 worktree、checkout 都会要求重建），这是故意选的保守侧；
#    但**不要把它读成"产物一定出自这份源码"**。要真证明那一点，唯一可靠的绑定是门禁自己构建
#    （抄 verify_graph_broadcast.sh 的 xcodebuild + -showBuildSettings）—— 那在 Agent 沙盒里跑不动，
#    是当初权衡后**已知未解**的口子，不是已经解决的判据。
{ [ -d "$ROOT/MixCut" ] && [ -d "$ROOT/Sources" ] && [ -f "$ROOT/Package.swift" ]; } \
    || invalid "前置 U05 取不到编译输入面（MixCut/ Sources/ Package.swift 缺一）—— 判据无法成立，不算通过"
NEWER_SRC="$(find "$ROOT/MixCut" "$ROOT/Sources" "$ROOT/MixCut.xcodeproj" "$ROOT/Package.swift" \
                 -type f -newer "$oldest_bin" -print0 2>/dev/null \
             | xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn | head -1)"
if [ -n "$NEWER_SRC" ]; then
    invalid "前置 U05 产物比源码旧 ⇒ 这一轮测的是旧构建的行为，不是当前代码。
       源码里最新的一颗：$(date -r "${NEWER_SRC%% *}" '+%Y-%m-%d %H:%M:%S')  ${NEWER_SRC#* }
       产物里最早的一颗：$(date -r "$oldest_bin_mtime" '+%Y-%m-%d %H:%M:%S')  ${oldest_bin##*/}
       被测产物：$APP_PATH
       二选一后再跑：
         xcodebuild -project \"$ROOT/MixCut.xcodeproj\" -scheme MixCut -configuration Debug -derivedDataPath .scratch/dd build
         SUNCUT_APP=<一个已含本次改动的 Debug SunCut.app> bash scripts/check_mcp_api_guards.sh
       （若这是一棵新建的 git worktree：checkout 会把全部源码 mtime 刷成当下，
        此时判旧是正确行为、重建产物即可，不是源码坏了。）"
fi
note "前置 U05 ✓ 产物不早于任何编译输入（产物最早一颗 $(date -r "$oldest_bin_mtime" '+%m-%d %H:%M')）"

# ---------- 前置 U03：端口必须空闲 ----------
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "端口 ${PORT} 已被占用。MCP 端口硬编码、双实例必抢，且写调用会打到持有端口的那个实例
     —— 那很可能是你自己开着的 SunCut（活库）。请先退出它，或用 MCP_PORT 换端口。"
fi
note "前置 U03 ✓ 端口 ${PORT} 空闲"

if [ "$PREFLIGHT_ONLY" = "1" ]; then
    note "前置全过（--preflight-only：不起 App、不跑用例、不动用户偏好）"
    exit 0
fi

# ---------- 前置 偏好快照 ----------
python3 "$ROOT/scripts/make_ui_fixture.py" --prefs-snapshot "$PREFS_SNAP" \
    || invalid "偏好快照失败 —— 无法保证退出时还原用户偏好，不跑"
PREFS_SNAPPED=1

# ---------- 前置 U04：活库基线 ----------
if [ -d "$LIVE_STORE" ]; then
    # 比对集含 launch-ledger：App 一启动就写它（台账 §9.3 实测），漏了它 = 隔离失效也照样绿。
    (cd "$LIVE_STORE" && find . -maxdepth 1 -type f \
        \( -name '*.store' -o -name '*.store-wal' -o -name '*.store-shm' -o -name '*.store.launch-ledger' \) \
        -print0 | xargs -0 shasum -a 256) > "$BASELINE" 2>/dev/null \
        || invalid "活库基线取不出来 —— U04 无法成立，不跑"
    note "前置 U04 ✓ 已存活库基线（$(wc -l < "$BASELINE" | tr -d ' ') 颗文件）"
    [ -s "$BASELINE" ] || invalid "前置 U04 活库目录在、但比对集取空 —— U04 无法成立，不跑"
else
    note "前置 U04 ⓘ 活库目录不存在，跳过基线比对"
fi

# ---------- 起 App（假库根）并等端口就绪 ----------
note "== 启动被测 App（假库根 ${FAKE_ROOT}）=="
# 假根只重定向 Application Support，**日志仍是共享域**（路径真源 Sources/MixCutCore/Brand.swift）。
# 先记字节偏移，起不来时只看这一轮新增的那一段 —— 不切片会把上一轮的红线读成本轮的原因。
SUNCUT_LOG="${HOME}/Library/Caches/com.suncut.app/logs/suncut.log"
LOG_OFFSET="$(wc -c < "$SUNCUT_LOG" 2>/dev/null | tr -d ' ')"
[ -n "$LOG_OFFSET" ] || LOG_OFFSET=0
MIXCUT_DEBUG_APP_SUPPORT_ROOT="$FAKE_ROOT" MIXCUT_MCP_PORT="$PORT" "$APP_PATH/Contents/MacOS/"*SunCut > "$LOG" 2>&1 &
APP_PID=$!
APP_LAUNCHED=1
ready=0
for _ in $(seq 1 60); do
    if curl -s -o /dev/null --max-time 1 -X POST "http://127.0.0.1:${PORT}/mcp" \
        -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'; then
        ready=1; break
    fi
    sleep 0.5
done
if [ "$ready" != "1" ]; then
    # 起不来的原因必须自己报出来：2026-10-11 那次真因是 schema 门拒开库（被拦住时 MCP 根本不接线），
    # 而这里只说"端口没起来"，把工装问题一路读成了 MCP 层缺陷。
    if kill -0 "$APP_PID" 2>/dev/null; then PROC="仍在运行"; else PROC="已退出"; fi
    GATE_HIT="$(tail -c +"$((LOG_OFFSET + 1))" "$SUNCUT_LOG" 2>/dev/null | grep '拒绝开库' | head -1)"
    if [ -n "$GATE_HIT" ]; then
        die "60 次探测内 ${PORT} 没起来（进程${PROC}，本轮被测 pid=${APP_PID}）。本轮日志增量里疑似的原因：
       ${GATE_HIT}
       ⇒ 这不是 MCP 层的问题：schema 门拒开库时 MCP 压根不接线。
         若报的是「消失的定义」，先核对被测产物是否早于源码（前置 U05）。
         注意：日志是**共享域**（假根只重定向 Application Support），这条归因按时间切片取，
         同窗口若还有别的 SunCut 实例在跑，它可能不是本轮这颗 —— 拿上面的 pid 对一下。"
    fi
    die "60 次探测内 ${PORT} 没起来（进程${PROC}），看 ${LOG} 尾部：
$(tail -5 "$LOG" 2>/dev/null)"
fi
note "App 就绪（pid ${APP_PID}）"

# ---------- 跑用例 ----------
note ""
note "== 集成 / API 层用例 =="
START_MS=$(python3 -c 'import time;print(int(time.time()*1000))')
GUARD_ARGS=(--port "$PORT" --catalog "$CATALOG" --out "$WORK/report.json")
[ "${ALLOW_DISPATCH:-0}" = "1" ] && GUARD_ARGS+=(--allow-dispatch --i-understand-real-calls)
[ -n "${ONLY:-}" ] && GUARD_ARGS+=(--only "$ONLY")
python3 "$ROOT/scripts/mcp_api_guards.py" "${GUARD_ARGS[@]}"
rc=$?
WALL_MS=$(( $(python3 -c 'import time;print(int(time.time()*1000))') - START_MS ))
note ""
note "本轮用例墙钟 $(printf '%.2f' "$(python3 -c "print($WALL_MS/1000)")")s（预算 ≤60s，不含起 App）$([ "$WALL_MS" -le 60000 ] && echo ✓ || echo '⚠ 超预算')"

# ---------- 后置 U04：活库必须一字节没变 ----------
if [ -s "$BASELINE" ]; then
    if ! (cd "$LIVE_STORE" && shasum -a 256 -c "$BASELINE" >/dev/null 2>&1); then
        note "FAIL 活库校验和变了 —— 隔离失效，这是最高优先级缺陷"
        (cd "$LIVE_STORE" && shasum -a 256 -c "$BASELINE" 2>&1 | grep -v ': OK$' | head -5)
        fail=1
    else
        note "后置 U04 ✓ 活库 $(wc -l < "$BASELINE" | tr -d ' ') 颗文件校验和全部未变"
    fi
fi

# ---------- 后置：假库确实生效 ----------
if [ -f "$FAKE_ROOT/Suncut/Suncut.store" ]; then
    note "后置 ✓ 假库确实落在 $FAKE_ROOT/Suncut/（开关生效，且这棵根是本轮新建的）"
else
    note "FAIL[判据失效] 假库里没建出 Suncut.store —— 假库开关没生效，写操作可能去了别处"
    fail=1
fi
# 全新假根的首启必然走 noPriorRecord ⇒ 一道备份都不该产生。
# ⚠️ 说清这条的类别：FAKE_ROOT 由本脚本自己 mktemp，所以运行时它**不可能红**；
#    红的唯一途径是有人把 FAKE_ROOT 改回持久共享路径 —— 那正是 2026-10-11 那 4 份反向备份的形状。
#    所以它是"脚本被改回旧形状"的**陷阱**（与 SL 守卫同族），不是运行时防线，别当后者读。
BACKUP_HITS="$(find "$FAKE_ROOT/Suncut" -maxdepth 1 -name '*.backup' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$BACKUP_HITS" != "0" ]; then
    note "FAIL[判据失效] 全新假根里出现 ${BACKUP_HITS} 份 .backup —— 首启不该产生备份"
    fail=1
fi

# ---------- 后置：无残留（先停再验，否则必然误报） ----------
if [ "${KEEP_APP:-0}" != "1" ]; then
    stop_app
    if pgrep -x SunCut >/dev/null 2>&1; then
        note "WARN 仍有 SunCut 进程未退：$(pgrep -x SunCut | tr '\n' ' ')，请手工确认"
    else
        note "后置 ✓ 被测 App 已退，无残留"
    fi
else
    note "后置 ⓘ KEEP_APP=1，被测 App 与假根都保留（pid ${APP_PID}，根 ${FAKE_ROOT}）"
fi

note ""
note "报告：$WORK/report.json"
[ "$fail" = "0" ] && [ "$rc" = "0" ] && { note "集成层门禁全绿 ✓"; exit 0; }
# 用例层回 2 是"判据自己没跑成"（连不上服务、目录真源解析不出），不是"功能红"。
# 原先这里一律压成 1，等于把判据失效降级成一次普通失败 —— 自证 6 从入库起就红在这。
if [ "$rc" = "2" ]; then
    invalid "用例层判据未成立（退出码 2：连不上服务或目录真源不可解析）—— 不能读成功能红或绿"
fi
note "集成层门禁未过 ✗（用例退出码 ${rc}，前后置失败 ${fail}）"
exit 1
