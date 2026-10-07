#!/bin/bash
# 档 0 取证④ —— 内网回调能不能走通公司登录（计划 v4 档 0 第 4 条，阻塞档 1）
#
# 背景事实（2026-10-03 查飞书官方《配置重定向 URL》）：重定向 URL 在开发者后台
# 「安全设置 → 重定向 URL」白名单里配；官方原文只写"只有配置在应用重定向 URL 列表内的
# 网页地址可以通过安全校验"，并补充 ?/# 后缀不生效。**是否要求公网/HTTPS/备案，官方文档未写。**
# 所以"内网地址能不能用"这件事只能实测，不能靠推。
#
# 两段：
#   第一段（自动，零风险）：那台机器能否出公网 —— 换 token 是服务器侧调用，出不了网这套方案当场不成立。
#   第二段（要人配合）：起一个回调接收端，把它给的 URL 填进开发者后台白名单，
#                       再让同事浏览器走一次跳转，看这台机器收不收得到。
#
# 用法：
#   ./scripts/stage0_sso_callback_probe.sh
#   ./scripts/stage0_sso_callback_probe.sh --selftest        # 只证接收端本身在工作
#   ./scripts/stage0_sso_callback_probe.sh --port 8794 --wait 300
#
# 接收端不接任何密钥、不换 token，只把回调参数脱敏打印；它绑 0.0.0.0 是因为回调
# 必须由同事的浏览器发起，网卡不可达就谈不上走通。

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"

PORT=8794
WAIT_SECONDS=300
SELFTEST=0
OUTBOUND_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="${2:-}"; shift 2 ;;
        --wait) WAIT_SECONDS="${2:-}"; shift 2 ;;
        --selftest) SELFTEST=1; shift ;;
        --outbound-only) OUTBOUND_ONLY=1; shift ;;
        -h|--help) sed -n '1,26p' "$0"; exit 0 ;;
        *) echo "FAIL 未知参数：$1" >&2; exit 2 ;;
    esac
done

RUN_DIR="$ROOT/.scratch/stage0-sso-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SINK_PID=""

stop_sink() {
    if [ -n "$SINK_PID" ] && kill -0 "$SINK_PID" 2>/dev/null; then
        kill "$SINK_PID" 2>/dev/null || true
        # 必须 wait：总计行是进程退出前才写的，不等就会 grep 到半份日志（假读数）
        wait "$SINK_PID" 2>/dev/null || true
    fi
    SINK_PID=""
}
trap stop_sink EXIT INT TERM

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
CB_URL="http://${LAN_IP:-127.0.0.1}:${PORT}/callback"

echo "==================== 档 0 取证④ ===================="
echo "本机局域网地址 : ${LAN_IP:-未取到（en0 无地址，回调地址无法填内网，先解决联网）}"
echo "回调接收端     : ${CB_URL}"
echo "产物目录       : $RUN_DIR"
echo "===================================================="

if [ "$SELFTEST" = "1" ]; then
    # 纯本地短路：不碰任何外部域名。它的唯一目的是证明接收端与判据本身是活的。
    echo ""
    echo "---------- --selftest：只证脚手架，不外呼 ----------"
    "$PY" "$ROOT/scripts/stage0_callback_sink.py" \
        --port "$PORT" --path /callback --lan 127.0.0.1 \
        > "$RUN_DIR/sink-url.txt" 2> "$RUN_DIR/sink.log" &
    SINK_PID=$!
    sleep 1.2
    if ! kill -0 "$SINK_PID" 2>/dev/null; then
        echo "FAIL 接收端起不来，见 $RUN_DIR/sink.log" >&2
        cat "$RUN_DIR/sink.log" || true
        exit 1
    fi
    curl -s -m 5 -o /dev/null "http://127.0.0.1:${PORT}/callback?code=SELFTESTCODE123456&state=abc" || true
    curl -s -m 5 -o /dev/null -w '  打错路径应回 404，实际 HTTP=%{http_code}\n' \
        "http://127.0.0.1:${PORT}/callback2?code=nope" || true
    stop_sink
    grep -E '\[回调\]|\[路径不符\]|\[总计\]|只有本机' "$RUN_DIR/sink.log" || true
    echo "  以上只证明：接收端能收参数、code 被脱敏、路径不符有读数、总计能算出"
    echo "  它**不证明**公司登录能用内网回调 —— 取证④要的那一条是来源 IP 不是 127.0.0.1。"
    echo "  日志目录：$RUN_DIR"
    exit 0
fi

echo ""
echo "---------- 第一段：这台机器能不能出公网（换 token 的前提）----------"
echo "  口径：只测域名可达性。**可达不等于接口可用**（路径、方法、参数要按官方文档另核）；"
echo "        不可达要先分清是 DNS、TCP、超时还是证书，四种成因处置完全不同。"
echo "        主机名以各平台官方文档为准，这里列出的是候选，不是承诺。"

probe_host() {
    local host="$1"
    local out rc detail errfile="$RUN_DIR/curl-$(echo "$host" | tr './' '__').err"
    set +e
    out="$(curl -sS -o /dev/null -m 8 -w '%{http_code}' "https://${host}/" \
        2>"$errfile")"
    rc=$?
    set -e
    detail="$(head -n 1 "$errfile" 2>/dev/null || true)"
    case "$rc" in
        0)  printf '  %-30s 可达 HTTP=%s\n' "$host" "$out" ;;
        6)  printf '  %-30s DNS 解析失败（内网 DNS 没放行或需要代理）\n' "$host" ;;
        7)  printf '  %-30s TCP 连接失败（出口被拦）\n' "$host" ;;
        28) printf '  %-30s 8 秒超时（防火墙/代理限速）\n' "$host" ;;
        35) printf '  %-30s TLS 握手失败：%s\n' "$host" "${detail:--}" ;;
        60) printf '  %-30s 证书不受信：%s\n' "$host" "${detail:--}" ;;
        *)  printf '  %-30s 其它失败 curl 码=%s：%s\n' "$host" "$rc" "${detail:--}" ;;
    esac
    return 0
}

for H in open.feishu.cn accounts.feishu.cn open.dingtalk.com \
         login.dingtalk.com api.dingtalk.com oapi.dingtalk.com \
         open.work.weixin.qq.com; do
    probe_host "$H"
done
echo "  结论口径：这一段只回答「出不出得去」，不回答「哪个接口能用」。"

if [ "$OUTBOUND_ONLY" = "1" ]; then
    echo "  --outbound-only：不起回调接收端。第二段要人配合建应用，另跑不带该 flag 的那次。"
    echo "  日志目录：$RUN_DIR"
    exit 0
fi

echo ""
echo "---------- 第二段：起回调接收端 ----------"
"$PY" "$ROOT/scripts/stage0_callback_sink.py" \
    --port "$PORT" --path /callback --lan "${LAN_IP:-127.0.0.1}" \
    > "$RUN_DIR/sink-url.txt" 2> "$RUN_DIR/sink.log" &
SINK_PID=$!
sleep 1
if ! kill -0 "$SINK_PID" 2>/dev/null; then
    echo "FAIL 接收端没起来，见 $RUN_DIR/sink.log" >&2
    cat "$RUN_DIR/sink.log" || true
    exit 1
fi
echo "  接收端已起 pid=${SINK_PID}（只听回调、不接密钥、参数脱敏）"

echo ""
echo "  接下来要人配合做三件事（我做不到，这三步只能你或公司里的人点）："
echo "   1) 请管理员在开放平台建一个「网页应用/网站应用」，拿到 App ID / Client ID；"
echo "      并把重定向 URL 白名单里加这一条：${CB_URL}"
echo "      —— 官方文档说 ? 与 # 后缀不生效，所以就把这一段整串填进去，别带查询参数；"
echo "      —— **能不能保存成功，本身就是这条取证的答案**（若后台直接拒绝内网地址/要求 HTTPS，"
echo "      就截图回来，那意味着档 1 的鉴权要先有公网域名或走公司反向代理）。"
echo "   2) 让同事浏览器先打开 http://${LAN_IP:-本机}:${PORT}/ 确认这个端口对他可达。"
echo "   3) 从平台的授权入口走一次跳转（带 state 更好），看浏览器最后落回哪里、"
echo "      这边 [回调] 行里的来源 IP 是不是同事那台机器。"
echo ""
echo "  判据（三条，缺一条就不算走通）："
echo "   A 后台允许把内网 http 地址存进重定向白名单；"
echo "   B 同事浏览器确实跳回了 ${CB_URL}；"
echo "   C 接收端收到非 127.0.0.1 来源，且参数里出现了 code（或明确的 error）。"
echo ""
echo "  现在可以去做上面三步；这边接收端会一直等。做完回到这里按回车（或等 ${WAIT_SECONDS} 秒）。"
if [ -t 0 ]; then
    read -t "$WAIT_SECONDS" -r _ || true
else
    sleep "$WAIT_SECONDS"
fi
stop_sink

echo ""
echo "---------- 接收端实测读数 ----------"
grep -E '\[自报\]|\[回调\]|\[路径不符\]|\[总计\]|错误回调|本轮|只有本机' \
    "$RUN_DIR/sink.log" || true

TOTAL="$(grep -c '\[回调\]' "$RUN_DIR/sink.log" || true)"
EXT="$(grep '\[回调\]' "$RUN_DIR/sink.log" | grep -vc '（本机）' || true)"
echo ""
echo "---------- 结论口径 ----------"
if [ "${EXT:-0}" -ge 1 ]; then
    echo "  走通：外部机器确实回调进来了（次数 ${EXT}）。内网回调地址这条路成立，"
    echo "  档 1 可以直接按「公司登录 + 内网地址」设计，不需要公网域名。"
elif [ "${TOTAL:-0}" -ge 1 ]; then
    echo "  部分：只有本机来源。说明接收端与判据是活的，但「同事浏览器完成一次跳转」还没证到。"
else
    echo "  未走通：一次回调都没收到。三种成因要分开看 —— 后台没保存成功 / 同事压根没跳过来 /"
    echo "  端口被 macOS 防火墙挡。别把它直接读成「公司登录不能用内网地址」。"
fi
echo "  日志：$RUN_DIR/sink.log"
