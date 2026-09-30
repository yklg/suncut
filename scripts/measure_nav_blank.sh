#!/usr/bin/env bash
# measure_nav_blank.sh —— 量「切项目那一帧窗口有没有画完」的尺子（批九第 0 步①）
#
# 用法:
#   bash scripts/measure_nav_blank.sh <录屏.mov> [--halfratio 0.5] [--deep 0.1] [--dump]
#
# 症状（2026-09-30 逐帧取证已确认，见计划批九）：切项目后有 50-134ms 上屏的是
# 「只剩背景层」的半组成帧 —— 侧栏只剩白底、标题退回 SunCut、详情区只剩卡片灰壳。
# 也就是说：文字/图标/缩略图这些**内容层**整块缺席，背景与圆角壳还在。
#
# 所以判据用「边缘能量塌缩」，不用平均亮度：
#   sobel 后的 YAVG = 这块区域的边缘密度。有文字图标的正常帧实测 12.41，
#   半组成帧实测 2.077 —— 差 6 倍，而帧间噪声只有千分位。
#   平均亮度做不得主判据：侧栏本来就大片白底，内容消失时 YAVG 只动 4.4；
#   详情区里有正在播放的视频，亮度天然乱跳（实测 607/1201 帧偏离基线，全是误报）。
# 亮度与亮度跨度仍照量，作为第二路交叉读数一起打印，但不参与判定。
#
# 时间一律取帧的 pts_time：屏幕录制是可变帧率，用帧号乘 1/60 推时间会越推越偏。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

VIDEO="${1:-}"
if [ -z "$VIDEO" ]; then
    echo "用法: bash scripts/measure_nav_blank.sh <录屏.mov> [--halfratio 0.5] [--deep 0.1] [--dump]"
    exit 2
fi
shift

RATIO="0.5"
DEEPR="0.1"
DEV="3.0"
DUMP=0
SBOVR=""   # 参照物构建（原版）窗口尺寸不同，允许手工给死裁区，格式 W:H:X:Y
DTOVR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --halfratio) RATIO="${2:-0.5}"; shift 2 ;;
        --deep)      DEEPR="${2:-0.1}"; shift 2 ;;
        --dev)       DEV="${2:-3.0}"; shift 2 ;;
        --dump)      DUMP=1; shift ;;
        --sidebar-crop) SBOVR="${2:-}"; shift 2 ;;
        --detail-crop)  DTOVR="${2:-}"; shift 2 ;;
        *)           echo "未知参数: $1（忽略）"; shift ;;
    esac
done

[ -f "$VIDEO" ] || { echo "❌ 录屏文件不存在: $VIDEO"; exit 2; }
FF="$(command -v ffmpeg || true)"
FP="$(command -v ffprobe || true)"
if [ -z "$FF" ] || [ -z "$FP" ]; then
    echo "❌ PATH 里找不到 ffmpeg/ffprobe。本脚本不猜安装位置，请先让两者可用。"
    exit 2
fi
[ -d "$ROOT/.scratch" ] || mkdir -p "$ROOT/.scratch"
TMP="$(mktemp -d "$ROOT/.scratch/navblank.XXXXXX")" || { echo "❌ 无法建临时目录"; exit 2; }
trap 'rm -rf "$TMP"' EXIT

WH="$("$FP" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$VIDEO")"
VW="${WH%%,*}"; VH="${WH##*,}"
case "$VW$VH" in
    ''|*[!0-9]*) echo "❌ 读不到视频尺寸(得到 ${VW}x${VH})，无法换算裁切区"; exit 2 ;;
esac
if [ "$VW" -lt 100 ] || [ "$VH" -lt 100 ]; then
    echo "❌ 视频尺寸异常(${VW}x${VH})，拒绝按默认比例裁切"; exit 2
fi

# 区域按实际尺寸等比换算（写死像素会在换分辨率的录屏上静默量到别的东西）
# 基准 = 1804x1266 那次实测: 侧栏 440x1206@(0,60)，详情顶部 1270x230@(480,70)
S_W=$(( VW * 440  / 1804 )); S_H=$(( VH * 1206 / 1266 )); S_X=0;   S_Y=$(( VH * 60 / 1266 ))
D_X=$(( VW * 480  / 1804 )); D_Y=$(( VH * 70   / 1266 ))
D_W=$(( VW * 1270 / 1804 )); D_H=$(( VH * 230  / 1266 ))

DUR="$("$FP" -v error -show_entries format=duration -of csv=p=0 "$VIDEO")"

echo "录屏  : $VIDEO"
echo "尺寸  : ${VW}x${VH}   时长: ${DUR}s"
echo "侧栏区: crop=${S_W}:${S_H}:${S_X}:${S_Y}"
echo "详情顶: crop=${D_W}:${D_H}:${D_X}:${D_Y}"
echo "判据  : 本帧边缘能量 < 基线 × 比例（基线取全片中位值；亮度只作交叉读数）"
echo "        侧栏区比例 ${RATIO}（侧栏内容恒定，塌一半必是没画完）；"
echo "        详情顶区比例 ${DEEPR}（该区会随模块合法地变素净，只认塌到壳的程度）"
echo

# 把 metadata=print 的原始输出压成逐帧表: pts_time  YAVG  YMAX-YMIN
parse_meta() {  # $1=raw 文件
    awk '
        /^frame:/ {
            if (t != "" && y != "" && mx != "" && mn != "") printf "%s\t%s\t%s\n", t, y, mx - mn
            t = ""; y = ""; mx = ""; mn = ""
            if (match($0, /pts_time:[0-9.eE+-]+/)) t = substr($0, RSTART + 9, RLENGTH - 9)
            next
        }
        /lavfi\.signalstats\.YAVG=/ { y  = $0; sub(/.*=/, "", y);  next }
        /lavfi\.signalstats\.YMAX=/ { mx = $0; sub(/.*=/, "", mx); next }
        /lavfi\.signalstats\.YMIN=/ { mn = $0; sub(/.*=/, "", mn); next }
        END { if (t != "" && y != "" && mx != "" && mn != "") printf "%s\t%s\t%s\n", t, y, mx - mn }
    ' "$1"
}

median_of() {  # $1=列号 $2=文件
    cut -f"$1" "$2" | sort -n | awk '
        { a[NR] = $1 + 0 }
        END {
            if (NR == 0) { print "nan"; exit }
            if (NR % 2) { print a[(NR + 1) / 2] } else { printf "%.4f\n", (a[NR / 2] + a[NR / 2 + 1]) / 2 }
        }'
}

measure() {  # $1=标签 $2=crop $3=是否门槛判据区(1/0) $4=该区判定比例
    local tag="$1" crop="$2" gated="$3" myratio="$4"
    local rawE="$TMP/edge.$tag" rawB="$TMP/bri.$tag" tE="$TMP/e.$tag" tB="$TMP/b.$tag"
    local all="$TMP/all.$tag" out="$TMP/runs.$tag"

    "$FF" -hide_banner -v error -i "$VIDEO" \
        -vf "crop=$crop,sobel,signalstats,metadata=print:file=$rawE" -f null - >/dev/null 2>&1
    "$FF" -hide_banner -v error -i "$VIDEO" \
        -vf "crop=$crop,signalstats,metadata=print:file=$rawB" -f null - >/dev/null 2>&1
    if [ ! -s "$rawE" ] || [ ! -s "$rawB" ]; then
        echo "❌ 「${tag}」解码/取元数据失败（边缘路 $([ -s "$rawE" ] && echo 有 || echo 空)，亮度路 $([ -s "$rawB" ] && echo 有 || echo 空)）—— 这是「没量到」，不是「没空白」。"
        return 1
    fi

    parse_meta "$rawE" > "$tE"
    parse_meta "$rawB" > "$tB"
    local ne nb2
    ne="$(wc -l < "$tE" | tr -d ' ')"
    nb2="$(wc -l < "$tB" | tr -d ' ')"
    if [ "$ne" -lt 3 ] || [ "$nb2" -lt 3 ]; then
        echo "❌ 「${tag}」只解出 边缘 $ne 帧 / 亮度 $nb2 帧（<3），本区读数不构成判据。"
        return 1
    fi
    if [ "$ne" != "$nb2" ]; then
        echo "⚠️ 「${tag}」两路帧数不一致($ne vs $nb2)，按较小者对齐，逐帧对应关系可能错位。"
    fi

    # 合并: pts_time  edge  yavg  range
    awk -F'\t' 'NR == FNR { e[FNR] = $2; n = FNR; next } FNR <= n { printf "%s\t%s\t%s\t%s\n", $1, e[FNR], $2, $3 }' \
        "$tE" "$tB" > "$all"

    local base_edge base_y iv
    base_edge="$(median_of 2 "$all")"
    base_y="$(median_of 3 "$all")"
    awk -F'\t' 'NR > 1 { printf "%.6f\n", $1 - prev } { prev = $1 }' "$all" > "$TMP/dt.$tag"
    iv="$(median_of 1 "$TMP/dt.$tag")"

    echo "── $tag ──  (判定比例 $myratio)"
    echo "帧数: $ne    基线边缘能量: $base_edge    基线YAVG: $base_y    帧间隔中位: ${iv}s"
    if [ "$base_edge" = "nan" ] || [ "$(awk -v b="$base_edge" 'BEGIN { print (b > 0) ? 1 : 0 }')" = "0" ]; then
        echo "⚠️ 基线边缘能量为 0：这块区域本来就没有内容层，本判据在这块区域无效。"
        return 1
    fi

    awk -F'\t' -v be="$base_edge" -v by="$base_y" -v iv="$iv" -v ratio="$myratio" -v dev="$DEV" '
        function flushrun() {
            runs++
            dur = (e - s) * 1000 + iv * 1000
            fmt = "段 %2d: %8.3fs → %8.3fs  %d 帧  %7.1f ms   段内最低边缘=%.2f(基线的 %.0f%%)  YAVG=%.1f 跨度=%.0f\n"
            printf fmt, runs, s, e, cnt, dur, mine, mine / be * 100, atminy, atrange
            total += dur
            if (dur > longest) longest = dur
        }
        {
            t = $1 + 0; ed = $2 + 0; y = $3 + 0; r = $4 + 0
            blank = (ed < be * ratio) ? 1 : 0
            d = y - by; if (d < 0) d = -d
            bright_bad = (d > dev) ? 1 : 0
            nbe += blank
            nbp += bright_bad
            if (blank && bright_bad) nbx++
            if (blank) {
                if (!inrun) { inrun = 1; s = t; e = t; cnt = 1; mine = ed; atminy = y; atrange = r }
                else {
                    e = t; cnt++
                    if (ed < mine) mine = ed
                    if (y < atminy) atminy = y
                    if (r < atrange) atrange = r
                }
            } else if (inrun) { flushrun(); inrun = 0 }
        }
        END {
            if (inrun) flushrun()
            printf "XCHECK\t%d\t%d\t%d\n", nbe, nbp, nbx
            printf "SUM\t%d\t%.1f\t%.1f\n", runs + 0, total + 0, longest + 0
            if (runs + 0 == 0) print "NORUN"
        }
    ' "$all" > "$out"

    grep -v "^XCHECK" "$out" | grep -v "^SUM" | grep -v "^NORUN"
    awk -F'\t' '$1 == "XCHECK" { printf "交叉核对: 边缘塌缩 %d 帧 / 亮度偏离 %d 帧 / 两者同时 %d 帧\n", $2, $3, $4 }' "$out"
    awk -F'\t' '$1 == "SUM" { printf "空白段: %d 段   合计 %.1f ms   最长一段 %.1f ms\n", $2, $3, $4 }' "$out"

    if grep -q "^NORUN" "$out"; then
        echo "⚠️ 本区未检出空白帧。这不等于达标：可能这段录屏里没切项目，也可能比例 ${myratio} 太松。"
        echo "   自证办法：把同一条命令跑在一段**已知有空白**的录屏上做正向对照。只把 --halfratio 提到 0.9 不算自证 —— 实测 19.21.20 那段（侧栏全程没被拆）824 帧在 0.9 下仍读 0 帧。"
    elif [ "$gated" = "1" ]; then
        awk -v l="$(awk -F'\t' '$1 == "SUM" { print $4 }' "$out")" \
            -v g="$(awk -v iv="$iv" 'BEGIN { printf "%.1f", iv * 1000 }')" '
            BEGIN {
                if (l <= g) { printf "✅ 侧栏区达标: 最长空白 %.1f ms ≤ 1 帧 (%.1f ms)\n", l, g }
                else        { printf "❌ 侧栏区未达标: 最长空白 %.1f ms > 1 帧 (%.1f ms)\n", l, g }
            }'
    else
        echo "（本区只出数据，通过门槛只看侧栏区）"
    fi
    echo
}

SB_CROP="${SBOVR:-${S_W}:${S_H}:${S_X}:${S_Y}}"
DT_CROP="${DTOVR:-${D_W}:${D_H}:${D_X}:${D_Y}}"
if [ -n "$SBOVR" ] || [ -n "$DTOVR" ]; then
    echo "（有手工覆盖：侧栏=$SB_CROP 详情=$DT_CROP —— 默认是按视频尺寸等比换算，只有参照物构建窗口不同才需要覆盖）"
    echo
fi
measure "sidebar" "$SB_CROP" 1 "$RATIO"
measure "detail"  "$DT_CROP" 0 "$DEEPR"

if [ "$DUMP" = "1" ]; then
    KEEP="$ROOT/.scratch/navblank"
    mkdir -p "$KEEP"
    for f in "$TMP"/all.*; do
        [ -f "$f" ] && cp "$f" "$KEEP/$(basename "$f").tsv"
    done
    echo "逐帧表已存: $KEEP/*.tsv  (列: pts_time  边缘能量  YAVG  亮度跨度)"
fi
