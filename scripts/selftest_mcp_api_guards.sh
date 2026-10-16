#!/usr/bin/env bash
# check_mcp_api_guards.sh 的判据自证（照本仓 selftest_* 惯例：合成一棵必红树，
# 证明每颗判据真的会变红；若变绿，本脚本自己以非 0 退出并报「判据失效」）。
#
# 为什么要有这支：恒绿的守卫比没有守卫更糟。集成层这批判据里有四道是"安全阀"
# （Debug 产物、产物不早于源码、端口独占、活库未变），它们一旦静默失效，
# 代价要么是直接写用户真库，要么是全批绿灯读的是旧构建的行为。
#
# 2026-10-04 的第一版在这里栽过两次，都记着，别再犯：
#   ① 只比退出码不比"红的原因" ⇒ 扰动跑成"App 没起来"也算红，假通过。
#      现在每颗都必须同时命中期望码 **和** 期望日志特征。
#   ② 给扰动换 MCP_PORT ⇒ 当时产品端口硬编码 8787，换端口只会让门禁去探一个永不起的端口。
#      2026-10-09 起产品支持 MIXCUT_MCP_PORT 覆盖（b43962c），这条前提已作废；
#      自证 2 随之换成它真正的不变式（见该条注释）。串行跑的纪律不变。
#
# 用法：bash scripts/selftest_mcp_api_guards.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.scratch/mcp-selftest"
CHECK="$ROOT/scripts/check_mcp_api_guards.sh"
RELEASE_APP="$ROOT/.scratch/dd/Build/Products/Release/SunCut.app"
fail=0

rm -rf "$WORK"; mkdir -p "$WORK"

# ---------------------------------------------------------------- 前置：产物必须是当前的
# 这条不是判据，是**自证成立的前提**：默认产物若比源码旧，下面每条腿红的原因都是
# 「产物陈旧」而不是它自己要验的那件事 —— 那等于一整批变异腿集体假红，比没门禁更糟。
if ! bash "$CHECK" --preflight-only > "$WORK/preflight.log" 2>&1; then
    echo "SELFTEST ABORT：默认产物过不了前置，下面的变异腿全都会红在错误的原因上。"
    sed 's/^/       /' "$WORK/preflight.log"
    echo "   ↑ 以上原样摘自 --preflight-only，那才是真实原因（可能是产物旧，也可能是端口被占或假库开关丢了）。"
    echo "   处理：重建 Debug 产物（xcodebuild -configuration Debug -derivedDataPath .scratch/dd build），"
    echo "        或 SUNCUT_APP=<当前产物> bash scripts/selftest_mcp_api_guards.sh"
    exit 2
fi
echo "PASS 前置：默认产物不早于源码（变异腿的红才归因得清）"

# 造一棵"含 DEBUG 假库开关字面量"的假产物：只够过 U01，用来单独扰动 U05 的时间判据。
make_synth_app() {
    mkdir -p "$1/Contents/MacOS"
    printf 'MIXCUT_DEBUG_APP_SUPPORT_ROOT\n' > "$1/Contents/MacOS/SunCut"
    printf 'MIXCUT_DEBUG_APP_SUPPORT_ROOT\n' > "$1/Contents/MacOS/SunCut.debug.dylib"
}

# 合成违规目录真源
python3 - "$ROOT/Sources/MixCutCore/AgentToolCatalog.swift" "$WORK" <<'PY'
import sys, os
src_path, work = sys.argv[1], sys.argv[2]
text = open(src_path, encoding="utf-8").read()
anchor = text.find("static let all:")
# 违规一：摘掉一个工具（数量与名单同时少一个）
i = text.find('name: "list_segments"', anchor)
start = text.rfind("MCPToolDefinition(", 0, i)
nxt = text.find("MCPToolDefinition(", i)
open(os.path.join(work, "Catalog_missing.swift"), "w", encoding="utf-8").write(text[:start] + text[nxt:])
# 违规二：改个名（数量相同、名单不同）—— 名字含大写，顺带考验解析器没在静默丢条目
k = text.find('name: "get_job"', anchor)
open(os.path.join(work, "Catalog_rename.swift"), "w", encoding="utf-8").write(
    text[:k] + 'name: "get_joX"' + text[k + len('name: "get_job"'):])
# 违规三：根本解析不出来
open(os.path.join(work, "Catalog_empty.swift"), "w", encoding="utf-8").write("no catalog here\n")
PY

# expect_red <标签> <期望退出码> <期望日志特征 grep 模式> <命令...>
# 退出码与"红的原因"必须同时命中，否则算判据没按预期生效。
expect_red() {
    local label="$1" want="$2" pattern="$3"; shift 3
    local got
    pkill -x SunCut 2>/dev/null; sleep 1
    "$@" > "$WORK/last.log" 2>&1; got=$?
    if [ "$got" != "$want" ]; then
        echo "FAIL ${label}：期望退出码 ${want}，实际 ${got}"
        tail -3 "$WORK/last.log" | sed 's/^/       /'
        fail=1; return
    fi
    if ! grep -qE "$pattern" "$WORK/last.log"; then
        echo "FAIL ${label}：退出码对上了但原因不对 —— 日志里找不到「${pattern}」"
        echo "       这是假通过：红是别的事导致的，判据本身没生效"
        grep -E "FAIL|ERROR|WARN" "$WORK/last.log" | head -4 | sed 's/^/       /'
        fail=1; return
    fi
    echo "PASS ${label}（退出码 ${got}，且原因命中「${pattern}」）"
}

echo "== 自证 1：产物不是 Debug ⇒ U01 必须报「判据失效」(2) =="
if [ -d "$RELEASE_APP" ]; then
    expect_red "U01 指向 Release 产物" 2 "判据失效.*Release" \
        env SUNCUT_APP="$RELEASE_APP" bash "$CHECK"
else
    echo "SKIP U01：找不到 Release 产物 $RELEASE_APP 可作扰动源"
fi

echo "== 自证 1b：产物里读不到假库开关字面量 ⇒ U01 必须报「判据失效」(2) =="
# 真 Release 产物不一定在（本机就没有），而 U01 判的是"读不到那颗字面量"这个形状本身
# —— 合成一棵没有它的假产物就够，别让这条判据因为缺产物而长期 SKIP。
NOVALVE_APP="$WORK/novalve.app"
mkdir -p "$NOVALVE_APP/Contents/MacOS"
printf 'nothing to see here\n' > "$NOVALVE_APP/Contents/MacOS/SunCut"
expect_red "U01 产物读不到假库开关" 2 "判据失效.*Release" \
    env SUNCUT_APP="$NOVALVE_APP" bash "$CHECK"

echo "== 自证 2：产品侧丢了 MIXCUT_MCP_PORT 覆盖点 ⇒ 必须报「判据失效」(2) =="
# 这条原先验的是「换端口必须被拒」，但产品自 b43962c 起就支持端口覆盖了 —— 门禁自己也用
# MCP_PORT 往下传，那条判据根本不存在。换成验它真正的不变式：覆盖能力不见了 = 门禁
# 可能与用户实例抢 8787 = 判据失效（check_mcp_api_guards.sh 里那两条 grep）。
mkdir -p "$WORK/no_port/MixCut/Services/MCP"
printf 'enum AgentGateway {}\n' > "$WORK/no_port/MixCut/Services/MCP/AgentGateway.swift"
printf 'enum MCPServer {}\n'    > "$WORK/no_port/MixCut/Services/MCP/MCPServer.swift"
expect_red "产品侧读不到端口覆盖点" 2 "硬编码" \
        env PRODUCT_SRC_DIR="$WORK/no_port" bash "$CHECK"

echo "== 自证 3：8787 被占 ⇒ U03 必须红 =="
python3 -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1', 8787)); s.listen(1); time.sleep(30)
" &
HOLDER=$!
sleep 1
expect_red "U03 端口被占" 1 "已被占用" bash "$CHECK"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

echo "== 自证 4：目录真源少一个工具 ⇒ API-01 必须因名单不符而 FAIL =="
expect_red "API-01 真源缺工具" 1 "只在现前台.*list_segments" \
    env CATALOG_PATH="$WORK/Catalog_missing.swift" ONLY=API-01 bash "$CHECK"

echo "== 自证 5：数量相同但名单不符 ⇒ 必须走「名单不符」分支（不能因解析器漏抓而变绿） =="
expect_red "API-01 改名扰动" 1 "只在现前台.*get_job" \
    env CATALOG_PATH="$WORK/Catalog_rename.swift" ONLY=API-01 bash "$CHECK"

echo "== 自证 6：真源不可解析 ⇒ 必须报「判据失效」(2) =="
expect_red "目录真源不可解析" 2 "判据失效" \
    env CATALOG_PATH="$WORK/Catalog_empty.swift" bash "$CHECK"

echo "== 自证 7：跑中途动了「活库」⇒ U04 必须红 =="
FAKE_LIVE="$WORK/fake_live_store"
mkdir -p "$FAKE_LIVE"; : > "$FAKE_LIVE/Suncut.store"
# 扰动必须**等 App 真答了话再动手**。原先写死 sleep 8，而一轮用例跑不满 8 秒
# ⇒ 变异落在后置比对之后，这条判据从入库起就是绿的（HEAD 原版实测退出码 0）。
( for _ in $(seq 1 120); do
      curl -s -o /dev/null --max-time 1 -X POST http://127.0.0.1:8787/mcp \
           -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' \
        && break
      sleep 0.5
  done
  printf 'MUTATED' >> "$FAKE_LIVE/Suncut.store" ) &
MUTATOR=$!
expect_red "U04 合成活库中途被改" 1 "活库校验和变了" \
    env LIVE_STORE_DIR="$FAKE_LIVE" ONLY=API-02 bash "$CHECK"
wait "$MUTATOR" 2>/dev/null

echo "== 自证 8：产物比源码旧 ⇒ U05 必须报「判据失效」(2) =="
# 2026-10-11 的现场就是这一条：默认产物停在 10-05，10-07~10-09 加的 24 项 schema 已被
# 新构建写进共享假根的 sidecar ⇒ schema 门判「消失 24 项」拒开库，脚本 30 秒后红在
# 「端口没起来」。当时没有任何判据说得出"测的是旧构建"，这条就是那颗判据的牙。
STALE_APP="$WORK/stale.app"
make_synth_app "$STALE_APP"
touch -t 202001010000 "$STALE_APP/Contents/MacOS/SunCut" "$STALE_APP/Contents/MacOS/SunCut.debug.dylib"
expect_red "U05 产物比源码旧" 2 "产物比源码旧" \
    env SUNCUT_APP="$STALE_APP" bash "$CHECK"

echo "== 自证 9：半截构建（stub 新、真身 dylib 旧）⇒ 仍必须红 =="
# Xcode 16 的 Debug 真身在 *.debug.dylib，主二进制只是 58K stub。若 U05 取"最晚"那颗，
# 一次只重链了 stub 的半截构建就会比出"新于源码"而假绿 —— 这条钉住它取的是**最早**那颗。
PARTIAL_APP="$WORK/partial.app"
make_synth_app "$PARTIAL_APP"
touch -t 202001010000 "$PARTIAL_APP/Contents/MacOS/SunCut.debug.dylib"
touch                "$PARTIAL_APP/Contents/MacOS/SunCut"
expect_red "U05 半截构建（只重链了 stub）" 2 "产物比源码旧" \
    env SUNCUT_APP="$PARTIAL_APP" bash "$CHECK"

echo "== 自证 10：反向对照 —— 同一棵合成产物把时间放到将来，不许红在 U05 =="
# 证明 U05 不是"见谁红谁"：越过 U01/U05/U03 之后才死在起 App（合成产物不是可执行体），
# 所以期望是退出码 1 + 原因「60 次探测内」，而不是「产物比源码旧」。
touch -t 209901010000 "$STALE_APP/Contents/MacOS/SunCut" "$STALE_APP/Contents/MacOS/SunCut.debug.dylib"
expect_red "U05 反向对照（够新就不该拦）" 1 "60 次探测内" \
    env SUNCUT_APP="$STALE_APP" ONLY=API-01 bash "$CHECK"

# ---------- U06 单实例锁（放在最后：前面每条腿都要真抢真放这把锁）----------
GATE_LOCK="$ROOT/.scratch/mcp-guards/gate.lock"
mkdir -p "$ROOT/.scratch/mcp-guards"

echo "== 自证 11：另一跑持有活锁 ⇒ U06 必须报「判据失效」(2)，且不许删别人的锁 =="
sleep 20 & HOLDER=$!
printf '%s\n8787\n2000-01-01T00:00:00Z\n' "$HOLDER" > "$GATE_LOCK"
expect_red "U06 另一跑持有锁" 2 "另一跑集成层门禁" \
    env bash "$CHECK" --preflight-only
# 顺手验"只放自己的锁"：本轮 LOCK_HELD=0，cleanup 不许把伪造的这把摘掉
if [ -f "$GATE_LOCK" ] && [ "$(sed -n '1p' "$GATE_LOCK")" = "$HOLDER" ]; then
    echo "PASS U06 没有误删他人锁（伪造锁仍在，持有者 pid 未变）"
else
    echo "FAIL U06 把别人的锁摘了 —— 并发保护当场失效，且下一跑会以为自己是唯一在跑的"
    fail=1
fi
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

echo "== 自证 12：陈旧锁（持有者已死）⇒ 必须接管而不是拒跑 =="
printf '%s\n8787\nx\n' 999999 > "$GATE_LOCK"
out12="$(bash "$CHECK" --preflight-only 2>&1)"; rc12=$?
printf '%s\n' "$out12" | grep -E "陈旧锁|前置全过" | sed 's/^/       /'
if [ "$rc12" = "0" ] && printf '%s' "$out12" | grep -q "陈旧锁"; then
    echo "PASS U06 陈旧锁接管（没被上一跑的尸体锁卡死）"
else
    echo "FAIL U06 陈旧锁：期望接管并跑通（退出码 0），实际 ${rc12}"
    fail=1
fi
rm -f "$GATE_LOCK"

echo "== 自证 13：产品侧丢了闸门占位缝 ⇒ 必须报「判据失效」(2)，而不是让 API-17 红成产品坏了 =="
# API-17 是 2026-10-16 新加的那条**零计费**闸门腿：它靠 AgentGateway 读 MIXCUT_SELFTEST_HOLD_JOB
# 把全局作业闸门钉住几秒，再在免费入口 export_segments 上取"拒 / 不拒"那一对读数。
# 注入点不见了（被人摘掉或改名）时，缺的是**工装的可判性**，不是产品行为 ——
# 所以必须红在退出码 2 并点名占位缝，绝不能落进 API-17 那条"竞没被拒"的功能红里。
#
# 扰动树从**真树整目录拷**再摘那一处，不手写壳、也不只拷两份文件：
# 门禁对产品源码做好几颗 grep（端口覆盖、MCPServer 观察 listener、U07 的两份 handler 名册…），
# 取样面不全的壳会先红在别的颗上 —— 而被摘掉占位缝时退出码常常同样是 2，看着就像绿。
# 这一点不是推测：本腿第一版就只拷了 AgentGateway + MCPServer 两份，
# 装上 U07 之后它红的是「U07 取不出 handler」，expect_red 靠"原因命中"那半条才没被读成 PASS。
mkdir -p "$WORK/no_hold/MixCut/Services"
cp -R "$ROOT/MixCut/Services/MCP" "$WORK/no_hold/MixCut/Services/"
GATEWAY_REAL="$ROOT/MixCut/Services/MCP/AgentGateway.swift"
GATEWAY_FAKE="$WORK/no_hold/MixCut/Services/MCP/AgentGateway.swift"
before_hits="$(grep -c 'MIXCUT_SELFTEST_HOLD_JOB' "$GATEWAY_FAKE" || true)"
before_hits="${before_hits:-0}"
grep -v 'MIXCUT_SELFTEST_HOLD_JOB' "$GATEWAY_FAKE" > "$WORK/no_hold/gw.tmp"
mv "$WORK/no_hold/gw.tmp" "$GATEWAY_FAKE"
# 变异未注入这一态必须被抓住：摘之前 0 处说明真树本身没那颗字面（判据无从生效），
# 摘之后仍有 0 处以上说明没摘干净（这条腿什么都没验）。
if [ "$before_hits" -lt 1 ] || [ "$(grep -c 'MIXCUT_SELFTEST_HOLD_JOB' "$GATEWAY_FAKE" || true)" -ne 0 ]; then
    echo "FAIL 自证 13 的变异没生效：摘前 ${before_hits} 处、摘后仍在 ⇒ 不许把这腿读成「判据有牙」"
    fail=1
else
    expect_red "产品侧读不到闸门占位缝" 2 "占位缝" \
            env PRODUCT_SRC_DIR="$WORK/no_hold" ONLY="API-17" bash "$CHECK"
fi

echo "== 自证 13b：反向对照 —— 真树（占位缝在位）单跑 API-17 必须绿 =="
# 只验"摘掉会红"不够：任何一条 grep 失败都能红，那不等于它判的是这件事。
# 补一格"在位就必须走得下去"的对照，两半都在，才证明这一格判的是「占位缝在不在」。
out13b="$(env ONLY="API-17" bash "$CHECK" 2>&1)"; rc13b=$?
printf '%s\n' "$out13b" | grep -E "API-17|前置 U0|判据失效" | sed 's/^/       /'
if [ "$rc13b" = "0" ] && printf '%s' "$out13b" | grep -qE "API-17 +PASS"; then
    echo "PASS API-17 单跑（占位缝在位 ⇒ 前置不误伤，这条零计费腿自己走到底）"
else
    echo "FAIL API-17 单跑：期望退出码 0 且该腿 PASS，实际退出码 ${rc13b}"
    fail=1
fi

echo "== 自证 14：把闸门挪到 jobs.begin 之后 ⇒ U07 必须红（先花钱再被拒的形状） =="
# 变异一律**从真树拷再动那一处**，不手写壳（自证 13 就是被手写壳骗过一次：
# 壳会先红在别的判据上，退出码一样，看着像绿）。每格都自带「变异未注入」这一态。
mkdir -p "$WORK/late_gate/MixCut/Services"
cp -R "$ROOT/MixCut/Services/MCP" "$WORK/late_gate/MixCut/Services/"
python3 - "$WORK/late_gate/MixCut/Services/MCP/MCPToolHandlers.swift" <<'PY'
import hashlib, sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
a = "        try ensureNoActiveJob()\n"
b = "        let job = jobs.begin(kind: .generateSchemes, projectID: project.id)\n"
pair = a + b
assert src.count(pair) == 1, "锚点没命中（%d 处）—— 变异未注入，这腿什么都没验" % src.count(pair)
out = src.replace(pair, b + a)
assert out != src, "字节没变 —— 变异未注入"
assert hashlib.sha256(out.encode()).hexdigest() != hashlib.sha256(src.encode()).hexdigest()
open(path, "w", encoding="utf-8").write(out)
print("已注入变异：generateSchemes 那颗闸门与 jobs.begin 换位")
PY
expect_red "闸门排在 jobs.begin 之后" 1 "排在 jobs.begin" \
        env PRODUCT_SRC_DIR="$WORK/late_gate" bash "$CHECK" --preflight-only

echo "== 自证 15：摘掉一处闸门（exportSegments 那条入口不受保护）⇒ U07 必须红 =="
mkdir -p "$WORK/no_gate/MixCut/Services"
cp -R "$ROOT/MixCut/Services/MCP" "$WORK/no_gate/MixCut/Services/"
python3 - "$WORK/no_gate/MixCut/Services/MCP/MCPSegmentToolHandlers.swift" <<'PY'
import hashlib, sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
a = "        try ensureNoActiveJob()\n"
b = "        let projectID = jobProjectID(explicit: args.project_id, segments: segments)\n"
assert src.count(a + b) == 1, "锚点没命中（%d 处）—— 变异未注入" % src.count(a + b)
out = src.replace(a + b, b)
assert out != src and hashlib.sha256(out.encode()).hexdigest() != hashlib.sha256(src.encode()).hexdigest()
open(path, "w", encoding="utf-8").write(out)
print("已注入变异：exportSegments 那颗闸门调用被摘掉（begin 留在原地）")
PY
expect_red "入口没有闸门" 1 "没有 ensureNoActiveJob" \
        env PRODUCT_SRC_DIR="$WORK/no_gate" bash "$CHECK" --preflight-only

echo "== 自证 16：两份文件里闸门整体改名（一颗调用都取不到）⇒ 必须报「判据失效」(2) =="
# 这一格守的是「扫不到 ≠ 干净」：取样面里一颗闸门都没有时，判据必须自认失能，
# 不许把零命中读成"所有入口都不需要闸门"（本仓老规矩：遍历空集恒绿）。
mkdir -p "$WORK/renamed/MixCut/Services"
cp -R "$ROOT/MixCut/Services/MCP" "$WORK/renamed/MixCut/Services/"
python3 - "$WORK/renamed/MixCut/Services/MCP" <<'PY'
import hashlib, os, sys
d = sys.argv[1]
changed = 0
for name in ("MCPToolHandlers.swift", "MCPSegmentToolHandlers.swift"):
    path = os.path.join(d, name)
    src = open(path, encoding="utf-8").read()
    out = src.replace("ensureNoActiveJob", "gateCheckRenamedAway")
    assert out != src and hashlib.sha256(out.encode()).hexdigest() != hashlib.sha256(src.encode()).hexdigest()
    open(path, "w", encoding="utf-8").write(out)
    changed += 1
assert changed == 2, "只改了 %d 份文件 —— 变异未注满整个取样面" % changed
print("已注入变异：两份 handler 里的闸门名字整体改掉（调用与定义同时消失）")
PY
expect_red "闸门整体取不到" 2 "一颗闸门都取不到" \
        env PRODUCT_SRC_DIR="$WORK/renamed" bash "$CHECK" --preflight-only

pkill -x SunCut 2>/dev/null
echo ""
if [ "$fail" = "0" ]; then
    echo "自证全绿：这批判据确实会红，且红的原因都对 ✓"
else
    echo "有判据没按预期生效 —— 比没门禁更糟，必须查"
fi
exit "$fail"
