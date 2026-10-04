#!/bin/bash
# MCP server 冒烟测试：app 必须已运行。用法：./scripts/mcp_smoke_test.sh [端口] [--allow-write]
#
# 2026-10-04 修两处纪律破口（计划 2026-10-04-mac2-ui-smoke-harness 分层重排 §起手第一步）：
#   ① 旧版第 22 行写死「期望 9 个工具」，而真源早已是 24 个 ⇒ 这颗门此刻必红，属假红灯。
#      现改为从 Sources/MixCutCore/AgentToolCatalog.swift 现场读工具名册，
#      数量与名单一起对账；取不出真源就报「判据失效」而非默默通过（照 check_schema_ledger_guards.sh 口径）。
#   ② 旧版第 29 行无条件 create_project 且跑完不清理 ⇒ 名字叫"冒烟"，实际在写用户真库。
#      现默认全程只读；要写必须显式 --allow-write，且那一档会自己把建出来的项目删回去。
#      注意：本脚本无从判断对面那个实例用的是真库还是假库，所以 --allow-write 只应在
#      由 check_mcp_api_guards.sh 自己拉起的假库实例上使用。
#
# 注意：刻意不开 set -e —— grep/curl 无命中时退出码为 1，会在断言打印之前静默中止脚本（本仓踩过）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="8787"
ALLOW_WRITE=0
for arg in "$@"; do
    case "$arg" in
        --allow-write) ALLOW_WRITE=1 ;;
        [0-9]*) PORT="$arg" ;;
        *) echo "FAIL 未知参数：$arg" >&2; exit 2 ;;
    esac
done
URL="http://127.0.0.1:${PORT}/mcp"
CATALOG="${CATALOG_PATH:-$ROOT/Sources/MixCutCore/AgentToolCatalog.swift}"
fail=0

call() {
    curl -sS -X POST "$URL" -H 'Content-Type: application/json' -d "$1"
}

# ---- 真源：从 Swift 目录里现场读出工具名册，不写死任何数字 ----
if [ ! -f "$CATALOG" ]; then
    echo "FAIL[判据失效] 取不到目录真源：$CATALOG —— 无册可对账，不算通过" >&2
    exit 1
fi
expected_names=$(python3 - "$CATALOG" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.find("static let all:")
if start < 0:
    sys.stderr.write("取不到 `static let all:` 锚点\n")
    sys.exit(1)
# 只吃 all 数组这一段，避免把 serverInstructions 文案里的引号算进来
end = text.find("\n    ]", start)
body = text[start:end if end > start else len(text)]
defs = len(re.findall(r'MCPToolDefinition\(', body))
# 名字字符集要放宽：只写 [a-z0-9_] 会把含大写/连字符的名字静默丢掉，
# 于是"改个名"这种扰动会被读成"少一个工具"，判据悄悄变弱而不报错。
names = re.findall(r'name:\s*"([A-Za-z0-9_\-]+)"', body)
if not names:
    sys.stderr.write("锚点内取不到任何 name:\n")
    sys.exit(1)
if len(names) != defs:
    # 定义数与名字数对不上 = 有条目没被解析到，判据本身不可信
    sys.stderr.write(
        "MCPToolDefinition 出现 %d 次但只解析出 %d 个 name，解析器漏抓\n" % (defs, len(names)))
    sys.exit(1)
print(" ".join(names))
PY
)
if [ $? -ne 0 ] || [ -z "${expected_names//[[:space:]]/}" ]; then
    echo "FAIL[判据失效] 从 $CATALOG 解析不出工具名册 —— 判据无法成立，不算通过" >&2
    exit 1
fi
expected_count=$(echo "$expected_names" | wc -w | tr -d ' ')
echo "目录真源读到 ${expected_count} 个工具（$CATALOG）"

echo "== initialize =="
call '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' | python3 -m json.tool

echo "== notifications/initialized（应无输出体） =="
call '{"jsonrpc":"2.0","method":"notifications/initialized"}'

echo "== tools/list：数量 + 名单双向对账 =="
call '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | python3 -c '
import json, sys
expected = sys.argv[1:]
r = json.load(sys.stdin)
tools = r["result"]["tools"]
actual = [t["name"] for t in tools]
if len(actual) != len(expected):
    print(f"FAIL 工具数不符：期望 {len(expected)}，实际 {len(actual)}")
    print(f"  只在真源: {sorted(set(expected) - set(actual))}")
    print(f"  只在现前台: {sorted(set(actual) - set(expected))}")
    sys.exit(1)
if set(actual) != set(expected):
    print("FAIL 数量相同但名单不符（多半是一进一出互相抵消，必须查）")
    print(f"  只在真源: {sorted(set(expected) - set(actual))}")
    print(f"  只在现前台: {sorted(set(actual) - set(expected))}")
    sys.exit(1)
print(f"工具数 {len(actual)} 与名单逐项一致 ✓")
' ${expected_names}
[ $? -eq 0 ] || fail=1

echo "== list_projects（只读） =="
call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}' \
    | python3 -c '
import json, sys
r = json.load(sys.stdin)
if r["result"]["isError"]:
    print("FAIL list_projects 报 isError", r["result"]["content"][0]["text"][:200]); sys.exit(1)
print("list_projects ✓")'
[ $? -eq 0 ] || fail=1

if [ "$ALLOW_WRITE" = "1" ]; then
    echo "== --allow-write：建一个临时项目再删回去（确认对面是假库实例！） =="
    created=$(call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"create_project","arguments":{"name":"MCP冒烟临时项目"}}}')
    pid=$(echo "$created" | python3 -c '
import json, sys
r = json.load(sys.stdin)
body = json.loads(r["result"]["content"][0]["text"])
print(body.get("id") or body.get("project_id") or "")')
    if [ -z "$pid" ]; then
        echo "FAIL 建项目没拿到 id：${created:0:200}"
        fail=1
    else
        echo "  已建 $pid，回查一次字段齐全性"
        call "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"get_project\",\"arguments\":{\"project_id\":\"$pid\"}}}" \
            | python3 -c '
import json, sys
r = json.load(sys.stdin)
if r["result"]["isError"]:
    print("FAIL 刚建的项目查不到", r["result"]["content"][0]["text"][:200]); sys.exit(1)
print("  回读 ✓")'
        [ $? -eq 0 ] || fail=1
        # 两步删除：先不带 confirm 拿预览，再 confirm=true 执行
        call "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_project\",\"arguments\":{\"project_id\":\"$pid\"}}}" >/dev/null
        call "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_project\",\"arguments\":{\"project_id\":\"$pid\",\"confirm\":true}}}" \
            | python3 -c '
import json, sys
r = json.load(sys.stdin)
if r["result"]["isError"]:
    print("FAIL[清理失败] 临时项目没删掉，请手工检查", r["result"]["content"][0]["text"][:200]); sys.exit(1)
print("  清理 ✓")'
        [ $? -eq 0 ] || fail=1
    fi
else
    echo "== create_project：跳过（默认零副作用；要测写路径加 --allow-write，且只在假库实例上用） =="
fi

echo "== 错误路径：不存在的项目 =="
call '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_project","arguments":{"project_id":"00000000-0000-0000-0000-000000000000"}}}' | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r["result"]["isError"] is True
body = json.loads(r["result"]["content"][0]["text"])
assert body["code"] == "PROJECT_NOT_FOUND", body
print("PROJECT_NOT_FOUND ✓")'
[ $? -eq 0 ] || fail=1

echo "== 错误路径：非法方法 =="
call '{"jsonrpc":"2.0","id":9,"method":"resources/list"}' | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r["error"]["code"] == -32601, r
print("-32601 ✓")'
[ $? -eq 0 ] || fail=1

if [ "$fail" = "0" ]; then
    echo "全部冒烟通过 ✓"
else
    echo "有判据未过 ✗"
fi
exit "$fail"
