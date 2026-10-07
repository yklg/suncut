#!/bin/bash
# 档 0 取证① —— 局域网里用浏览器拖进度条到底稳不稳（计划 v4 档 0 第 1 条）
#
# 测物理事实，不测产品端点：用一次性临时播放服务端放同一条真实素材，两档互为对照 ——
# 只测好看那一档等于没测。
#   200 档：无视 Range，整片返回 = 现有前台唯一能做到的形状
#   206 档：正确实现单段 Range = 计划里"新专职前台"要做的形状
#
# 用法：
#   ./scripts/stage0_lan_playback_probe.sh
#   ./scripts/stage0_lan_playback_probe.sh --file "/path/真实素材.mp4"
#   ./scripts/stage0_lan_playback_probe.sh --only 200
#   ./scripts/stage0_lan_playback_probe.sh --machine-only
#   ./scripts/stage0_lan_playback_probe.sh --wait 300
#   ./scripts/stage0_lan_playback_probe.sh --app-forward --i-understand-no-auth
#
# --app-forward 把内网端口转发到 App 的 127.0.0.1:8787。那段窗口服务零鉴权 ——
# 同网络任何人都能调那 24 个工具，含 delete_project。所以必须显式加
# --i-understand-no-auth，且测完立刻 Ctrl-C 撤掉；不加该 flag 本模式拒绝启动。

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"

FILE=""
ONLY=""
WAIT_SECONDS=180
PORT_200=8790
PORT_206=8791
PORT_FORWARD=8792
APP_PORT=8787
FORWARD=0
ACK_NO_AUTH=0
MACHINE_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --file) FILE="${2:-}"; shift 2 ;;
        --only) ONLY="${2:-}"; shift 2 ;;
        --wait) WAIT_SECONDS="${2:-}"; shift 2 ;;
        --app-port) APP_PORT="${2:-}"; shift 2 ;;
        --app-forward) FORWARD=1; shift ;;
        --i-understand-no-auth) ACK_NO_AUTH=1; shift ;;
        --machine-only) MACHINE_ONLY=1; shift ;;
        -h|--help) sed -n '1,26p' "$0"; exit 0 ;;
        *) echo "FAIL 未知参数：$1" >&2; exit 2 ;;
    esac
done

RUN_DIR="$ROOT/.scratch/stage0-lan-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"

PIDS=""
cleanup() {
    for p in $PIDS; do
        kill "$p" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"

# ---- 选素材：默认取库里最大的真实 mp4，并自报规模（空副本测不出名堂） ----
VIDEOS_DIR="$HOME/Library/Application Support/Suncut/Videos"
[ -d "$VIDEOS_DIR" ] || VIDEOS_DIR="$HOME/Library/Application Support/MixCut/Videos"

pick_default_file() {
    if [ ! -d "$VIDEOS_DIR" ]; then
        echo "FAIL 找不到素材目录 ${VIDEOS_DIR}，请用 --file 指定一条真实视频" >&2
        exit 1
    fi
    local best="" bestsize=0 s
    while IFS= read -r -d '' f; do
        s="$(stat -f %z "$f" 2>/dev/null || echo 0)"
        if [ "${s:-0}" -gt "$bestsize" ]; then
            bestsize="$s"
            best="$f"
        fi
    done < <(find "$VIDEOS_DIR" -type f -name '*.mp4' -print0 2>/dev/null)
    if [ -z "$best" ] || [ "$bestsize" -le 0 ]; then
        echo "FAIL 素材目录里没有非空 mp4，请用 --file 指定" >&2
        exit 1
    fi
    printf '%s' "$best"
}

[ -n "$FILE" ] || FILE="$(pick_default_file)"
if [ ! -f "$FILE" ]; then
    echo "FAIL 文件不存在：$FILE" >&2
    exit 1
fi
SIZE="$(stat -f %z "$FILE")"
if [ "${SIZE:-0}" -le 1048576 ]; then
    echo "FAIL 文件小于 1MB，拖条测不出名堂（规模自报：$SIZE 字节）" >&2
    exit 1
fi
SIZE_MB=$(( SIZE / 1048576 ))

echo "==================== 档 0 取证① ===================="
echo "素材         : $FILE"
echo "规模（自报） : $SIZE 字节 = ${SIZE_MB} MB"
echo "局域网地址   : ${LAN_IP:-未取到，en0 无地址 —— 同事将无法访问，本机自测可继续}"
echo "端口         : 200 档 $PORT_200 ｜ 206 档 $PORT_206 ｜ 转发 $PORT_FORWARD"
echo "人工判定等待 : 每档 ${WAIT_SECONDS} 秒（按回车可提前结束）"
echo "产物目录     : $RUN_DIR"
echo "===================================================="

wait_up() {
    local port="$1" i=0
    while [ "$i" -lt 50 ]; do
        if curl -s -o /dev/null "http://127.0.0.1:${port}/"; then
            return 0
        fi
        i=$(( i + 1 ))
        sleep 0.2
    done
    echo "FAIL 端口 $port 上的临时服务端没起来，见 $RUN_DIR" >&2
    return 1
}

stop_arm() {
    local pid="$1"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    PIDS="$(echo "$PIDS" | sed "s/ ${pid}//")"
}

# ---- 机器判据先行：正半（206/200）+ 负半（越界 416），只跑正半是假绿 ----
machine_checks() {
    local port="$1" label="$2"
    local out
    out="$(curl -s -o /dev/null -w '%{http_code} %{size_download}' \
        -H 'Range: bytes=1048576-1049599' \
        "http://127.0.0.1:${port}/media" || echo '000 0')"
    local code bytes
    code="${out%% *}"
    bytes="${out##* }"

    if [ "$label" = "206" ]; then
        echo "  [机器判据 206 档] Range 请求 HTTP=${code} 收到字节=${bytes}（要 206 且 1024）"
        { [ "$code" = "206" ] && [ "$bytes" = "1024" ]; } || {
            echo "  FAIL 206 档没做到位" >&2
            return 1
        }
        local out416
        out416="$(curl -s -o /dev/null -w '%{http_code} %{size_download}' \
            -H "Range: bytes=$(( SIZE + 10 ))-$(( SIZE + 20 ))" \
            "http://127.0.0.1:${port}/media" || echo '000 0')"
        echo "  [机器判据 206 档 负半] 越界 Range HTTP=${out416%% *}（要 416）"
        [ "${out416%% *}" = "416" ] || {
            echo "  FAIL 越界 Range 没判 416，Range 实现是假通" >&2
            return 1
        }
    else
        echo "  [机器判据 200 档] 带 Range 请求 HTTP=${code} 收到字节=${bytes}（要 200 且 ${SIZE} 字节）"
        { [ "$code" = "200" ] && [ "$bytes" = "$SIZE" ]; } || {
            echo "  FAIL 200 档应无视 Range 回整片，实际不是" >&2
            return 1
        }
    fi
    return 0
}

ask_human() {
    local port="$1" label="$2" log="$3"
    local url="http://${LAN_IP:-127.0.0.1}:${port}/"
    echo "  → 让同事浏览器打开：$url"
    echo "    动作：拖播放条到中段 3 次、快到底部 1 次"
    echo "    要记的现象：能否立刻出画 ／ 有没有黑屏或卡住 ／ 有没有从头重播"
    echo "    读数适用范围：本机 curl 走回环，那行 MB/s 不代表局域网速率。"
    echo "    只有同事从别的机器连进来时，[读数] 行里的 client= 不是 127.0.0.1，速率才算数。"
    if [ "$MACHINE_ONLY" = "1" ]; then
        echo "    （--machine-only：跳过人眼判定）"
        return 0
    fi
    if [ -t 0 ]; then
        printf '    做完按回车结束本档，不按键则 %s 秒后自动结束...' "${WAIT_SECONDS}"
        read -t "${WAIT_SECONDS}" -r _ || true
    else
        echo "    无交互终端，自动等 ${WAIT_SECONDS} 秒"
        sleep "$WAIT_SECONDS"
    fi
    echo "  ---- 本档末 6 行读数 ----"
    tail -n 6 "$log" || true
}

run_arm() {
    local label="$1" range_mode="$2" port="$3"
    local log="$RUN_DIR/arm-${label}.log"
    echo ""
    echo "---------- 档位：${label}（--range ${range_mode}）----------"
    "$PY" "$ROOT/scripts/stage0_media_server.py" \
        --file "$FILE" --port "$port" --range "$range_mode" \
        > "$RUN_DIR/arm-${label}.out" 2> "$log" &
    local pid=$!
    PIDS="$PIDS $pid"
    wait_up "$port"
    echo "  已起 pid=$pid"
    if ! machine_checks "$port" "$label"; then
        stop_arm "$pid"
        echo "  机器判据没过，本档不交给人眼判断（先修脚手架，别拿假通的档去判好坏）" >&2
        return 1
    fi
    ask_human "$port" "$label" "$log"
    stop_arm "$pid"
    grep -h '\[总计\]' "$log" || echo "  WARN 没读到总计行：$log"
}

FAILURES=0
RAN_ANY=0

if [ "$FORWARD" = "1" ]; then
    if [ "$ACK_NO_AUTH" != "1" ]; then
        echo "拒绝启动 --app-forward：那段窗口服务零鉴权，同网络任何人可无密码调 24 个工具（含 delete_project）。" >&2
        echo "确认接受就重跑并加 --i-understand-no-auth，测完立刻 Ctrl-C 撤掉。" >&2
        exit 3
    fi
    RAN_ANY=1
    if ! lsof -nP -iTCP:"$APP_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "FAIL 本机 $APP_PORT 上没在听（SunCut 没开？开起来再跑）" >&2
        exit 1
    fi
    echo ""
    echo "---------- 模式：内网可达性转发（无鉴权窗口，测完就撤）----------"
    echo "  0.0.0.0:$PORT_FORWARD -> 127.0.0.1:$APP_PORT"
    "$PY" "$ROOT/scripts/stage0_tcp_forward.py" \
        --listen-port "$PORT_FORWARD" --target-host 127.0.0.1 --target-port "$APP_PORT" \
        > "$RUN_DIR/forward.log" 2>&1 &
    FPID=$!
    PIDS="$PIDS $FPID"
    sleep 1
    echo "  经转发问 tools/list 的工具数："
    curl -s -m 5 -X POST "http://127.0.0.1:$PORT_FORWARD/mcp" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' > "$RUN_DIR/tools.json" || true
    "$PY" - "$RUN_DIR/tools.json" <<'PYEOF' || true
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
try:
    r = json.loads(raw)
    print("    工具数 =", len(r["result"]["tools"]))
except Exception:
    print("    非预期应答：", raw[:200])
PYEOF
    echo "  经转发的 GET /media（现有前台不会给视频，这条就是那条根因的读数）："
    curl -s -o /dev/null -w '    HTTP=%{http_code}\n' \
        "http://127.0.0.1:$PORT_FORWARD/media" || true
    echo ""
    echo "  → 让同事浏览器打开：http://${LAN_IP:-本机地址}:${PORT_FORWARD}/mcp"
    echo "    能连通就等于「放开监听」本身没有额外工程量，剩下的只是鉴权。"
    if [ "$MACHINE_ONLY" != "1" ] && [ -t 0 ]; then
        printf '  做完按回车撤掉转发...'
        read -t "${WAIT_SECONDS}" -r _ || true
    fi
    stop_arm "$FPID"
    echo "  转发已撤（进程退出即无残留）。日志：$RUN_DIR/forward.log"
    tail -n 5 "$RUN_DIR/forward.log" || true
fi

case "$ONLY" in
    200) RAN_ANY=1; run_arm 200 off "$PORT_200" || FAILURES=$(( FAILURES + 1 )) ;;
    206) RAN_ANY=1; run_arm 206 on "$PORT_206" || FAILURES=$(( FAILURES + 1 )) ;;
    "")
        if [ "$FORWARD" = "0" ]; then
            RAN_ANY=1
            echo ""
            echo "提示：先跑 200 档（现有形状能做到的），再跑 206 档（计划要做的），两档都要人眼判。"
            run_arm 200 off "$PORT_200" || FAILURES=$(( FAILURES + 1 ))
            run_arm 206 on "$PORT_206" || FAILURES=$(( FAILURES + 1 ))
        else
            echo ""
            echo "本轮只跑了可达性转发；播放对照请重跑不带 --app-forward 的那次。"
        fi
        ;;
    *) echo "FAIL --only 只能是 200 或 206" >&2; exit 2 ;;
esac

if [ "$FAILURES" = "0" ] && [ "$MACHINE_ONLY" != "1" ] && [ "$RAN_ANY" = "1" ]; then
    echo ""
    echo "==================== 待你回填（不要凭印象）===================="
    echo "200 档 拖条：稳 / 不稳（现象：____________）"
    echo "206 档 拖条：稳 / 不稳（现象：____________）"
    echo "两档差别：明显 / 不明显"
    echo "判据：若 206 稳而 200 不稳，「新专职前台做 Range」这条必要；"
    echo "      若两档都不稳，问题不在 Range，回来重谈形态（计划停止条件一）。"
fi

echo "日志目录：$RUN_DIR"
if [ "$FAILURES" != "0" ]; then
    echo "有 ${FAILURES} 档机器判据没过，本轮不算取证完成。" >&2
    exit 1
fi
