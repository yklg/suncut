#!/bin/bash
# 档 0 取证② —— 分片上传与断点续传的物理可行性（计划 v4 档 0 第 2 条的前半）
#
# 要回答的是：中途硬死之后能不能不重传整片，以及这座桥需要多少代码。
# 做法是真的 kill -9 掉接收端（不是假装返回 500），重启后由客户端问 /state 只补缺的那几片，
# 最后把重组文件的 sha256 与源文件**逐字节对账**。
#
# 用法：
#   ./scripts/stage0_chunked_upload_probe.sh
#   ./scripts/stage0_chunked_upload_probe.sh --file "/path/真实素材.mp4"
#   ./scripts/stage0_chunked_upload_probe.sh --chunk 4194304 --kill-after 3
#   ./scripts/stage0_chunked_upload_probe.sh --keep
#
# 默认拿库里最大那条真实素材（几十 MB 级）。要测 2GB 级就自己 --file 指一条真件 ——
# 稀疏文件造出来的 2GB 测不出磁盘与网络，本脚本拒收 0 字节与小文件。

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"

FILE=""
PORT=8793
CHUNK=1048576
KILL_AFTER=3
UPLOAD="stage0probe"
KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --file) FILE="${2:-}"; shift 2 ;;
        --port) PORT="${2:-}"; shift 2 ;;
        --chunk) CHUNK="${2:-}"; shift 2 ;;
        --kill-after) KILL_AFTER="${2:-}"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
        *) echo "FAIL 未知参数：$1" >&2; exit 2 ;;
    esac
done

RUN_DIR="$ROOT/.scratch/stage0-upload-$(date +%Y%m%d-%H%M%S)"
WORK="$RUN_DIR/work"
mkdir -p "$WORK"

SINK_PID=""
stop_sink() {
    if [ -n "$SINK_PID" ]; then
        local pid="$SINK_PID"
        SINK_PID=""
        kill "$pid" 2>/dev/null || true
        # 等它真退出：sink.log 的总计行是退出前才写的，不等就是读半份日志
        wait "$pid" 2>/dev/null || true
    fi
}
trap stop_sink EXIT INT TERM

pick_default_file() {
    local dir="$HOME/Library/Application Support/Suncut/Videos"
    [ -d "$dir" ] || dir="$HOME/Library/Application Support/MixCut/Videos"
    if [ ! -d "$dir" ]; then
        echo "FAIL 找不到素材目录，请用 --file 指定一条真实视频" >&2
        exit 1
    fi
    local best="" bestsize=0 s
    while IFS= read -r -d '' f; do
        s="$(stat -f %z "$f" 2>/dev/null || echo 0)"
        if [ "${s:-0}" -gt "$bestsize" ]; then
            bestsize="$s"
            best="$f"
        fi
    done < <(find "$dir" -type f -name '*.mp4' -print0 2>/dev/null)
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
if [ "${SIZE:-0}" -lt 1048576 ]; then
    echo "FAIL 文件小于 1MB：分片续传测不出名堂（规模自报 ${SIZE} 字节）" >&2
    exit 1
fi
COUNT=$(( (SIZE + CHUNK - 1) / CHUNK ))
if [ "$COUNT" -lt "$(( KILL_AFTER + 2 ))" ]; then
    echo "FAIL 片数 $COUNT 不够在第 ${KILL_AFTER} 片后动手（换更大的 --file 或调小 --chunk）" >&2
    exit 1
fi

state_count() {
    "$PY" "$ROOT/scripts/stage0_upload_sink.py" state \
        --port "$PORT" --upload "$UPLOAD" 2>/dev/null | awk '{print $1}'
}

start_sink() {
    "$PY" "$ROOT/scripts/stage0_upload_sink.py" sink \
        --port "$PORT" --work "$WORK" > "$RUN_DIR/sink-$1.out" 2>> "$RUN_DIR/sink.log" &
    SINK_PID=$!
    local i=0
    while [ "$i" -lt 50 ]; do
        if state_count >/dev/null 2>&1; then
            return 0
        fi
        i=$(( i + 1 ))
        sleep 0.2
    done
    echo "FAIL 接收端没起来，见 $RUN_DIR/sink.log" >&2
    return 1
}

echo "==================== 档 0 取证② ===================="
echo "素材         : $FILE"
echo "规模（自报） : ${SIZE} 字节 = $(( SIZE / 1048576 )) MB"
echo "分片大小     : ${CHUNK} 字节 ｜ 应有片数 $COUNT"
echo "中断点       : 第 ${KILL_AFTER} 片收完后 kill -9 接收端"
echo "产物目录     : $RUN_DIR"
echo "===================================================="

echo ""
echo "---------- 阶段 A：推到第 ${KILL_AFTER} 片后自断，再 kill -9 接收端 ----------"
start_sink 1
set +e
"$PY" "$ROOT/scripts/stage0_upload_sink.py" push \
    --file "$FILE" --port "$PORT" --upload "$UPLOAD" --chunk "$CHUNK" \
    --stop-after "$KILL_AFTER" \
    > "$RUN_DIR/push-A.out" 2> "$RUN_DIR/push-A.log"
A_RC=$?
set -e
kill -9 "$SINK_PID" 2>/dev/null || true
SINK_PID=""
if [ "$A_RC" != "7" ]; then
    echo "FAIL 阶段 A 退出码应为 7（自断），实际 $A_RC —— 中途断根本没造出来" >&2
    tail -n 5 "$RUN_DIR/push-A.log" || true
    exit 1
fi
echo "  客户端已在第 ${KILL_AFTER} 片后自断（退出码 7），随后接收端被 kill -9"
echo "  这一趟的账："
grep -E '\[中途断\]|\[续传账\]' "$RUN_DIR/push-A.log" || true

PARTS_DIR="$WORK/$UPLOAD/parts"
STRAGGLERS="$(find "$PARTS_DIR" -name '*.part' 2>/dev/null | wc -l | tr -d ' ')"
RENAMED="$(find "$PARTS_DIR" -type f ! -name '*.part' 2>/dev/null | wc -l | tr -d ' ')"
echo "  磁盘现状：完整片 ${RENAMED} 个 ｜ 半片(.part) ${STRAGGLERS} 个"
echo "  注意：这一轮是在两片之间断的，服务端从没写坏过 —— 所以「半片不被计入」这条还没被证到，见阶段 A2"

echo ""
echo "---------- 阶段 A2：让服务端写坏一半后当场死（注入真崩溃）----------"
start_sink 2
BROKEN_INDEX=$KILL_AFTER
head -c 65536 "$FILE" | curl -s -m 10 -X POST --data-binary @- \
    "http://127.0.0.1:${PORT}/chunk?upload=${UPLOAD}&index=${BROKEN_INDEX}&break=1" \
    > /dev/null 2>&1 || true
sleep 0.3
if kill -0 "$SINK_PID" 2>/dev/null; then
    echo "FAIL 注入没让服务端死掉，阶段 A2 不成立" >&2
    exit 1
fi
SINK_PID=""
A2_PARTS="$(find "$PARTS_DIR" -name '*.part' 2>/dev/null | wc -l | tr -d ' ')"
A2_FULL="$(find "$PARTS_DIR" -type f ! -name '*.part' 2>/dev/null | wc -l | tr -d ' ')"
echo "  服务端死在半片写入中：半片(.part) ${A2_PARTS} 个（要 1）｜ 完整片 ${A2_FULL} 个（要 ${KILL_AFTER}）"
if [ "$A2_PARTS" != "1" ] || [ "$A2_FULL" != "$KILL_AFTER" ]; then
    echo "FAIL 磁盘状态与预期不符，注入形状不对" >&2
    exit 1
fi

echo ""
echo "---------- 阶段 B：重启接收端，先看它认不认那半片，再补缺 ----------"
start_sink 3
GOT2="$(state_count || echo 0)"
echo "  重启后 /state 报已收 ${GOT2} 片 ｜ 磁盘完整片 ${A2_FULL} 片（半片 ${A2_PARTS} 个不计入）"
if [ "$GOT2" != "$A2_FULL" ]; then
    echo "FAIL /state 读数与磁盘完整片不符：state=${GOT2} 磁盘=${A2_FULL}" >&2
    exit 1
fi
if [ "$GOT2" -gt "$KILL_AFTER" ]; then
    echo "FAIL /state 把写坏的那半片也算成已收到（${GOT2} 大于 ${KILL_AFTER}）—— 原子性是假通" >&2
    exit 1
fi
# 负半：片没齐就想拼，必须被拒，而不是默默拼出一个坏文件
BEFORE_SHA="$(curl -s -m 30 -o "$RUN_DIR/finalize-premature.json" -w '%{http_code}' \
    -X POST "http://127.0.0.1:${PORT}/finalize?upload=${UPLOAD}&count=${COUNT}" || echo 000)"
echo "  负半判据：片没齐就 finalize，HTTP=${BEFORE_SHA}（要 409）"
if [ "$BEFORE_SHA" != "409" ]; then
    echo "FAIL 没凑齐也允许拼，会静默产出坏文件 —— 这条比续传本身更要命" >&2
    exit 1
fi

"$PY" "$ROOT/scripts/stage0_upload_sink.py" push \
    --file "$FILE" --port "$PORT" --upload "$UPLOAD" --chunk "$CHUNK" \
    > "$RUN_DIR/push-B.out" 2> "$RUN_DIR/push-B.log"
echo "  续传这一趟的账："
grep -E '\[续传账\]|\[逐字节对账\]|\[自报\]' "$RUN_DIR/push-B.log" || true
stop_sink

SKIP="$(sed -n 's/.*跳过已收=\([0-9]*\).*/\1/p' "$RUN_DIR/push-B.log" | head -n 1)"
RESUME_SHA="$(tail -n 1 "$RUN_DIR/push-B.out" | tr -d '[:space:]')"
LOCAL_SHA="$(shasum -a 256 "$FILE" | awk '{print $1}')"
ASSEMBLED="$WORK/$UPLOAD/assembled.bin"

echo ""
echo "---------- 对账 ----------"
echo "  跳过片数（续传证据，必须 > 0）      : ${SKIP:-未知}"
echo "  服务端重组 sha256                   : ${RESUME_SHA:-未知}"
echo "  本机独立复算源文件 sha256           : $LOCAL_SHA"
if [ -z "$SKIP" ] || [ "$SKIP" = "0" ]; then
    echo "FAIL 跳过 0 片：根本没续传，可能整片重推了" >&2
    exit 1
fi
if [ "$SKIP" -ge "$COUNT" ]; then
    echo "FAIL 跳过 $SKIP 片 = 总片数 ${COUNT}：中途断没造出来，这一趟是全已知直接拼，不算续传证据" >&2
    exit 1
fi
echo "  中途确实断在半途：跳过 $SKIP 片、补 $(( COUNT - SKIP )) 片，总片数 $COUNT"
if [ "$RESUME_SHA" != "$LOCAL_SHA" ]; then
    echo "FAIL 重组与原文件不是逐字节相同 —— 分片方案有缺陷，别拿去写档 3" >&2
    exit 1
fi
ASIZE="$(stat -f %z "$ASSEMBLED" 2>/dev/null || echo 0)"
if [ "$ASIZE" != "$SIZE" ]; then
    echo "FAIL 重组字节数不符：$ASIZE vs $SIZE" >&2
    exit 1
fi
echo "  重组大小 $ASIZE 字节 = 源文件 $SIZE 字节 ✓"
echo ""
echo "结论：分片 + 原子 rename + /state 补缺 + 不齐不拼，这四条都拿到读数和负半了。"
echo "      移植进产品时照搬的就是这四条：写 .part → rename 才算收到 → /state 只认 rename 后的 →"
echo "      finalize 前查缺口并拒绝。"

if [ "$KEEP" = "1" ]; then
    echo "保留产物：$WORK"
else
    rm -rf "$WORK"
    echo "已清理工作目录（日志仍在 ${RUN_DIR}）"
fi
echo "日志目录：$RUN_DIR"
