#!/usr/bin/env bash
# check_mcp_api_guards.sh 的判据自证（照本仓 selftest_* 惯例：合成一棵必红树，
# 证明每颗判据真的会变红；若变绿，本脚本自己以非 0 退出并报「判据失效」）。
#
# 为什么要有这支：恒绿的守卫比没有守卫更糟。集成层这批判据里有三道是"安全阀"
# （Debug 产物、端口独占、活库未变），它们一旦静默失效，代价是直接写用户真库。
#
# 2026-10-04 的第一版在这里栽过两次，都记着，别再犯：
#   ① 只比退出码不比"红的原因" ⇒ 扰动跑成"App 没起来"也算红，假通过。
#      现在每颗都必须同时命中期望码 **和** 期望日志特征。
#   ② 给扰动换 MCP_PORT ⇒ 产品的 MCP 端口硬编码 8787（AgentGateway.swift:11），
#      换端口只会让门禁探测一个永不起的端口。现在一律用默认端口，串行跑。
#
# 用法：bash scripts/selftest_mcp_api_guards.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.scratch/mcp-selftest"
CHECK="$ROOT/scripts/check_mcp_api_guards.sh"
DEBUG_APP="${SUNCUT_APP:-$ROOT/.scratch/dd/Build/Products/Debug/SunCut.app}"
RELEASE_APP="$ROOT/.scratch/dd/Build/Products/Release/SunCut.app"
fail=0

rm -rf "$WORK"; mkdir -p "$WORK"

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

echo "== 自证 2：换端口必须被拒（产品端口硬编码，换端口只会造成假通过） =="
expect_red "MCP_PORT 换端口被拒" 2 "硬编码" \
        env MCP_PORT=8799 bash "$CHECK"

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
# 后台在第 8 秒往合成库里追加一字节，模拟隔离失效写进真库
( sleep 8; printf 'MUTATED' >> "$FAKE_LIVE/Suncut.store" ) &
MUTATOR=$!
expect_red "U04 合成活库中途被改" 1 "活库校验和变了" \
    env LIVE_STORE_DIR="$FAKE_LIVE" ONLY=API-02 bash "$CHECK"
wait "$MUTATOR" 2>/dev/null

pkill -x SunCut 2>/dev/null
echo ""
if [ "$fail" = "0" ]; then
    echo "自证全绿：这批判据确实会红，且红的原因都对 ✓"
else
    echo "有判据没按预期生效 —— 比没门禁更糟，必须查"
fi
exit "$fail"
