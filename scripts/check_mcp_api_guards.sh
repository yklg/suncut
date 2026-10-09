#!/usr/bin/env bash
# 集成 / API 层功能门禁（计划 2026-10-04 分层重排：把功能测试主力从"鼠标点"换成"HTTP 调"）
#
# 这颗门自己管被测 App 的完整生命周期，因为实测发现外部 nohup / 后台任务拉起的 App
# 会随调用结束被回收，判据跑到一半就没服务了。
#
# 四道前置（任一不过就不跑用例，直接红）：
#   U01 产物必须是 Debug —— 假库开关 MIXCUT_DEBUG_APP_SUPPORT_ROOT 在 #if DEBUG 内
#       （MixCut/Utilities/FileHelper.swift:17-25，注释原文「Release 编译不进这一支」）。
#       拿 Release 跑会**静默**写用户真库。注意 Xcode 16 的 Debug 用 dylib 注入，
#       主二进制只是 58K stub，真身在 Contents/MacOS/*.debug.dylib —— 只扫主二进制
#       会两边都读 0 而恒绿（2026-10-04 踩过）。
#   U03 8787 必须空闲 —— MCP 端口是硬编码常量（AgentGateway.swift:11），双实例必抢；
#       更重要的是：若有用户自己开的实例在持有端口，任何写调用都会打到他的活库。
#   U04 活库未被触碰 —— 跑前存基线校验和，跑后逐颗比对。
#   偏好保护 —— App 在 selectedProject 的 didSet 里会把 lastSelectedProjectID 写回标准域
#       （ProjectViewModel.swift:18），而 Debug/Release 共用 bundle id ⇒ 会污染用户真实偏好。
#       所以跑前快照、退出时还原（实测教训：2026-10-04 曾把用户的值覆盖成假库项目 id）。
#
# 用法：bash scripts/check_mcp_api_guards.sh
#   环境变量：SUNCUT_APP=<.app 路径>  CATALOG_PATH=<目录真源>  KEEP_APP=1 跑完不关 App
# 注意：刻意不开 set -e —— 子命令非 0 退出码就是判据本身，不能被静默吞掉（本仓踩过）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${SUNCUT_APP:-$ROOT/.scratch/dd/Build/Products/Debug/SunCut.app}"
CATALOG="${CATALOG_PATH:-$ROOT/Sources/MixCutCore/AgentToolCatalog.swift}"
PORT="${MCP_PORT:-8787}"
# 产品侧端口能力（2026-10-09 起）：`AgentGateway` 读 `MIXCUT_MCP_PORT` 覆盖硬编码默认值，
# 并且**绑不上就非零退出**（`MCPServer.start()` 现在等 NWListener 真进 ready 才算成功）。
# 早先这里写的是「换端口毫无意义，产品只听 8787」——那是对的，因为当时确实没有覆盖能力；
# 当时的后果是：门禁与用户自己开着的实例抢 8787，谁先绑上谁应答，
# 写调用会打到**用户的活库**（2026-10-09 手搓 curl 绕过本门禁时真的发生过一次）。
# 现在换成反向判据：**覆盖能力不见了就是判据失效**，不许退回静默共用 8787。
if ! grep -q 'MIXCUT_MCP_PORT' "$ROOT/MixCut/Services/MCP/AgentGateway.swift" 2>/dev/null; then
    invalid "产品侧读不到 MIXCUT_MCP_PORT 覆盖点 —— 端口重回硬编码，门禁可能与用户实例抢 8787，判据失效"
fi
if ! grep -q 'stateUpdateHandler' "$ROOT/MixCut/Services/MCP/MCPServer.swift" 2>/dev/null; then
    invalid "MCPServer 不再观察 listener 状态 —— 绑不上端口会静默假成功，判据失效"
fi
WORK="$ROOT/.scratch/mcp-guards"
FAKE_ROOT="$WORK/fake-appsupport"
# LIVE_STORE_DIR 只给 selftest 用：指向一棵合成树，用来证明 U04 这颗判据真的会红，
# 而不去碰用户真库（拿真库做扰动等于故意写坏用户数据）。
LIVE_STORE="${LIVE_STORE_DIR:-$HOME/Library/Application Support/Suncut}"
BASELINE="$WORK/live_baseline.sha"
PREFS_SNAP="$WORK/prefs_snapshot.json"
LOG="$WORK/app.log"
fail=0

mkdir -p "$WORK" "$FAKE_ROOT"

note() { printf '%s\n' "$*"; }
die()  { printf 'FAIL %s\n' "$*" >&2; exit 1; }
invalid() { printf 'FAIL[判据失效] %s\n' "$*" >&2; exit 2; }

# ---------- 前置 U01：产物必须是 Debug ----------
[ -d "$APP_PATH" ] || die "找不到被测产物：${APP_PATH}（先 xcodebuild -configuration Debug 构建）"
BIN_DIR="$APP_PATH/Contents/MacOS"
[ -d "$BIN_DIR" ] || invalid "产物里没有 MacOS 目录：$BIN_DIR"
# 扫全部可执行体（含 *.debug.dylib），不只看主二进制
valve_hits=0
while IFS= read -r bin; do
    n=$(strings "$bin" 2>/dev/null | grep -c 'MIXCUT_DEBUG_APP_SUPPORT_ROOT' || true)
    valve_hits=$((valve_hits + n))
done < <(find "$BIN_DIR" -maxdepth 1 -type f)
if [ "$valve_hits" = "0" ]; then
    invalid "产物里读不到假库开关字面量 ⇒ 这是 Release 或异常产物，跑起来会**静默写用户真库**。
       期望：$APP_PATH 是 Debug 构建（Contents/MacOS/ 下应有 SunCut.debug.dylib）"
fi
note "前置 U01 ✓ 产物含 DEBUG 假库开关（命中 ${valve_hits} 处）"

# ---------- 前置 U03：端口必须空闲 ----------
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "端口 ${PORT} 已被占用。MCP 端口硬编码、双实例必抢，且写调用会打到持有端口的那个实例
     —— 那很可能是你自己开着的 SunCut（活库）。请先退出它，或用 MCP_PORT 换端口。"
fi
note "前置 U03 ✓ 端口 ${PORT} 空闲"

# ---------- 前置 偏好快照 ----------
python3 "$ROOT/scripts/make_ui_fixture.py" --prefs-snapshot "$PREFS_SNAP" \
    || invalid "偏好快照失败 —— 无法保证退出时还原用户偏好，不跑"

restore_prefs() {
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
        pkill -x SunCut 2>/dev/null
    fi
    restore_prefs
}
trap cleanup EXIT

# ---------- 前置 U04：活库基线 ----------
if [ -d "$LIVE_STORE" ]; then
    (cd "$LIVE_STORE" && find . -maxdepth 1 -type f \( -name '*.store' -o -name '*.store-wal' -o -name '*.store-shm' \) \
        -print0 | xargs -0 shasum -a 256) > "$BASELINE" 2>/dev/null \
        || invalid "活库基线取不出来 —— U04 无法成立，不跑"
    note "前置 U04 ✓ 已存活库基线（$(wc -l < "$BASELINE" | tr -d ' ') 颗文件）"
else
    note "前置 U04 ⓘ 活库目录不存在，跳过基线比对"
fi

# ---------- 起 App（假库根）并等端口就绪 ----------
note "== 启动被测 App（假库根 ${FAKE_ROOT}）=="
MIXCUT_DEBUG_APP_SUPPORT_ROOT="$FAKE_ROOT" MIXCUT_MCP_PORT="$PORT" "$APP_PATH/Contents/MacOS/"*SunCut > "$LOG" 2>&1 &
APP_PID=$!
ready=0
for _ in $(seq 1 60); do
    if curl -s -o /dev/null --max-time 1 -X POST "http://127.0.0.1:${PORT}/mcp" \
        -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'; then
        ready=1; break
    fi
    sleep 0.5
done
[ "$ready" = "1" ] || die "60 次探测内 ${PORT} 没起来，看 $LOG 尾部：
$(tail -5 "$LOG" 2>/dev/null)"
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
        note "后置 U04 ✓ 活库三颗文件校验和全部未变"
    fi
fi

# ---------- 后置：假库确实生效 ----------
if [ -f "$FAKE_ROOT/Suncut/Suncut.store" ]; then
    note "后置 ✓ 假库确实落在 $FAKE_ROOT/Suncut/（开关生效）"
else
    note "FAIL[判据失效] 假库里没建出 Suncut.store —— 假库开关没生效，写操作可能去了别处"
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
    note "后置 ⓘ KEEP_APP=1，被测 App 保留（pid ${APP_PID}）"
fi

note ""
note "报告：$WORK/report.json"
[ "$fail" = "0" ] && [ "$rc" = "0" ] && { note "集成层门禁全绿 ✓"; exit 0; }
note "集成层门禁未过 ✗（用例退出码 ${rc}，前后置失败 ${fail}）"
exit 1
