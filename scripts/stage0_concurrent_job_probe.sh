#!/bin/bash
# 档 0 取证③ —— 两人同时派单今天到底怎么打架（计划 v4 档 0 第 3 条 + 那条 P0 根因的读数）
#
# 默认全程零副作用：只发只读调用与协议形状探测，不写库、不调云端、不跑 ffmpeg。
# 想拿"第二个人被拒"的确切读数，必须显式加 --dispatch-import --allow-real-calls，
# 那一档会**真的**导入一条素材、跑完整分析流水线（含 ASR 与 AI 语义分析，可能产生 API 费用）。
#
# 用法：
#   ./scripts/stage0_concurrent_job_probe.sh
#   ./scripts/stage0_concurrent_job_probe.sh --port 8787
#   ./scripts/stage0_concurrent_job_probe.sh --dispatch-import --allow-real-calls --file "/小素材.mp4"
#   ./scripts/stage0_concurrent_job_probe.sh --dispatch-import --allow-real-calls --cleanup
#
# 前提：SunCut 正开着（服务在 127.0.0.1:8787）。脚本自己不负责把它开起来。

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"

PORT=8787
DISPATCH=0
ALLOW_REAL=0
FILE=""
CLEANUP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="${2:-}"; shift 2 ;;
        --dispatch-import) DISPATCH=1; shift ;;
        --allow-real-calls) ALLOW_REAL=1; shift ;;
        --file) FILE="${2:-}"; shift 2 ;;
        --cleanup) CLEANUP=1; shift ;;
        -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
        *) echo "FAIL 未知参数：$1" >&2; exit 2 ;;
    esac
done

MCP() { "$PY" "$ROOT/scripts/stage0_mcp.py" "$PORT" "$@"; }

echo "==================== 档 0 取证③ ===================="
echo "目标         : http://127.0.0.1:${PORT}/mcp"
echo "模式         : 零副作用只读探测（本脚本全程不带任何凭据）"
echo "真派单         : $([ "$DISPATCH" = 1 ] && echo 已要求 || echo 未开启)"
echo "===================================================="

if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "FAIL 本机 ${PORT} 上没在听 —— SunCut 没开就测不到东西（先把它开起来）" >&2
    exit 1
fi

echo ""
echo "---------- 1. 服务身份与规模自报 ----------"
MCP ping
MCP tools-count || true
echo "  注：工具数的权威判据是 Tests/MixCutCoreTests/AgentToolCatalogTests.swift 那条按序锁，"
echo "      这里只报现前台实际吐出的数，用来发现「文档与实际不一致」。"

echo ""
echo "---------- 2. 根因读数 A：现壳能不能给文件 ----------"
CODE="$(MCP get-code /media || true)"
echo "  GET /media  => ${CODE}"
echo "  GET /assets/index.html => $(MCP get-code /assets/index.html || true)"
echo "  判据：应回 404。只要 404，浏览器就拿不到视频与页面，"
echo "        所以「另开一个专职前台」不是风格选择，是这条路能不能走的问题。"
case "$CODE" in
    *404*) echo "  ✓ 与计划里的根因判断一致（非 POST /mcp 一律 404）" ;;
    *"无 HTTP"*) echo "  FAIL 连接层就失败了，这条读数本身不可信，先查服务状态" >&2; exit 1 ;;
    *) echo "  NOTE 竟然不是 404：现壳已能服务 GET，计划里那条根因需要重新核" >&2 ;;
esac

echo ""
echo "---------- 3. 根因读数 B：整请求进内存 + 4MB 上限 ----------"
OVER="$(MCP oversize 6 || true)"
echo "  POST 一个 6MB 的请求体 => ${OVER}"
echo "  判据：要的是「连接被断/无 HTTP 应答」这一类失败种类，不是「回了个别的状态码」。"
echo "        只要它是这种失败，产品侧就绝不可能靠「调大缓冲上限」来支持大文件上传 —— "
echo "        分片上传是必需，不是可选。"

echo ""
echo "---------- 4. 根因读数 C：并发是串行还是并行 ----------"
echo "  故意从 2 路起：N=1 时「之和/墙钟」恒等于 1.00，与「完全串行」的读数无法区分，摆进去就是假证据。"
for N in 2 4 8; do
    echo "  --- ${N} 路并发 list_projects（只读）---"
    MCP concurrent "$N" list_projects || true
done
echo "  读法：比值接近 1 才叫被排成一队走；比值接近路数就是真并行。"
echo "        这条只读探测只管「读」这一侧。「派单」那一侧的闸门是 JOB_ALREADY_RUNNING，"
echo "        必须靠第 6 段真派单才拿得到读数 —— 两侧不能混为一谈（计划 v4 原先把这两件事写成了一件，需按实测更正）。"

echo ""
echo "---------- 5. 无鉴权证据 ----------"
echo "  上面所有调用都没带 cookie、没带 Authorization、没带 Origin："
MCP call list_projects '{}' >/dev/null && echo "  ✓ 零凭据可读到全部项目 —— 放开监听前必须先有鉴权，这条不是建议是前提"

if [ "$DISPATCH" = "1" ]; then
    echo ""
    echo "---------- 6. 真派单档 ----------"
    if [ "$ALLOW_REAL" != "1" ]; then
        echo "拒绝执行：--dispatch-import 会真的导入素材并跑 ASR + AI 语义分析（可能产生 API 费用）。" >&2
        echo "确认要跑就再加 --allow-real-calls。" >&2
        exit 3
    fi
    if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
        echo "FAIL --file 要指一条真实存在的小素材（建议 5–15 秒，缩短流水线时间）" >&2
        exit 1
    fi
    SIZE="$(stat -f %z "$FILE")"
    echo "  素材规模自报：$SIZE 字节 = $(( SIZE / 1024 )) KB"

    echo ""
    echo "  6a. 先问 get_asr_status：这一趟台词会走哪条（本地 whisper 还是云端千问）"
    MCP call get_asr_status '{}' || true

    echo ""
    echo "  6b. 建一个探针专用项目"
    PROJ_OUT="$(MCP call create_project "{\"name\":\"档0并发探针 $(date +%H%M%S)\"}")" || true
    echo "  $PROJ_OUT"
    PID_JSON="$(printf '%s' "$PROJ_OUT" | sed -n 's/.*"id":"\([0-9a-fA-F-]*\)".*/\1/p' | head -n 1)"
    if [ -z "$PID_JSON" ]; then
        echo "FAIL 没解析出 project_id，后面测不了。请把上面载荷摘要贴回来。" >&2
        exit 1
    fi
    echo "  project_id = $PID_JSON"

    echo ""
    echo "  6c. 第一次派单（占住那唯一名额）"
    FIRST="$(MCP call import_videos "{\"project_id\":\"$PID_JSON\",\"paths\":[\"$FILE\"]}")" || true
    echo "  $FIRST"
    JOB1="$(printf '%s' "$FIRST" | sed -n 's/.*job_id=\([0-9a-fA-F-]*\).*/\1/p' | head -n 1)"
    if [ -z "$JOB1" ] || [ "$JOB1" = "-" ]; then
        echo "FAIL 第一次派单没拿到 job_id —— 那就不是「打架」，是导入本身没起来。看上面载荷。" >&2
        exit 1
    fi

    echo ""
    echo "  6d. 立刻第二次派单（这就是「同事同时点导出」的等效形状）"
    SECOND="$(MCP call import_videos "{\"project_id\":\"$PID_JSON\",\"paths\":[\"$FILE\"]}" || true)"
    echo "  $SECOND"
    if printf '%s' "$SECOND" | grep -q 'JOB_ALREADY_RUNNING'; then
        echo "  ✓ 第二人被 JOB_ALREADY_RUNNING 拒 —— 档 3 要改的就是这个：从拒绝改成排队+可见排位"
    elif printf '%s' "$SECOND" | grep -q 'isError=False'; then
        echo "  NOTE 第二次竟然也接了：既有「唯一名额」闸门可能没生效，这条要在档 3 前重新核" >&2
    else
        echo "  NOTE 第二次既不是 JOB_ALREADY_RUNNING 也不是成功，失败种类未知，把上面载荷贴回来" >&2
    fi

    echo ""
    echo "  6e. 轮询第一趟到结束（报总耗时，这是「别人要等多久」的实际读数）"
    WAITED=0
    while [ "$WAITED" -lt 1200 ]; do
        LINE="$(MCP job-state "$JOB1" || true)"
        STATE="${LINE%% *}"
        [ -n "$STATE" ] || STATE="取不到"
        echo "    已等 ${WAITED}s 状态=${STATE}"
        if [ "$STATE" != "running" ] && [ "$STATE" != "取不到" ]; then
            break
        fi
        sleep 5
        WAITED=$(( WAITED + 5 ))
    done
    echo "    流水线结束，累计等待 ${WAITED}s"
    echo "  最后一眼 get_job 载荷："
    MCP call get_job "{\"job_id\":\"$JOB1\"}" || true

    if [ "$CLEANUP" = "1" ]; then
        echo ""
        echo "  6f. 清理探针项目（两步：先拿影响预览，再 confirm=true）"
        MCP call delete_project "{\"project_id\":\"$PID_JSON\"}" || true
        MCP call delete_project "{\"project_id\":\"$PID_JSON\",\"confirm\":true}" || true
    else
        echo ""
        echo "  未清理：探针项目 project_id=$PID_JSON 留在库里。"
        echo "  要删就重跑加 --cleanup（它会先打印影响预览再执行），或在应用里手动删。"
    fi
fi

echo ""
echo "日志：本脚本无产物文件；读数请整屏截回来（尤其第 4 段那两个比值）。"
