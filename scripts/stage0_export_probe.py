#!/usr/bin/env python3
"""档 0 取证⑤：导出渲染的墙钟耗时（一次性脚手架，只碰现有前台，不碰产品码）。

为什么要有这颗：全仓从来没有一个端到端的导出墙钟数（docs/Tests/scripts 都翻过，
导出路径零计时埋点）。而"多人同时点导出怎么办"这条拍板，缺的正是这个数。

它做的事：对指定方案逐个调 export_scheme（一次一趟，天然串行），用 get_job 轮询到
终态，报墙钟；再从输出目录里按 mtime 找出这次真正落盘的成片，用 ffprobe 读回它的
**成片时长**，算出"渲染 1 秒成片要几秒"。

不自证的东西：
- 轮询有粒度，墙钟是**上界**，脚本会把粒度一起打出来。
- 只在本机、当前这一份 Debug 构建上测；换了机器/构建，数要重取。
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

URL_TMPL = "http://127.0.0.1:%d/mcp"
_id = [0]


def rpc(name, arguments, port, timeout=60):
    _id[0] += 1
    body = {
        "jsonrpc": "2.0",
        "id": _id[0],
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }
    req = urllib.request.Request(
        URL_TMPL % port, data=json.dumps(body, ensure_ascii=False).encode("utf-8"), method="POST"
    )
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    result = payload.get("result") or {}
    content = result.get("content") or []
    text = content[0].get("text", "") if content else ""
    try:
        inner = json.loads(text)
    except (ValueError, TypeError):
        inner = {}
    return bool(result.get("isError")), inner, text


def ffprobe(path):
    """读回成片的时长/大小/分辨率；读不到就照实说读不到，不猜。"""
    try:
        out = subprocess.check_output(
            [
                "ffprobe", "-v", "error",
                "-show_entries", "format=duration,size",
                "-show_entries", "stream=codec_type,width,height,codec_name",
                "-of", "json", path,
            ],
            text=True,
        )
        data = json.loads(out)
        fmt = data.get("format", {})
        streams = [s for s in data.get("streams", []) if s.get("codec_type") == "video"]
        v = streams[0] if streams else {}
        return {
            "duration": float(fmt.get("duration", 0) or 0),
            "size": int(fmt.get("size", 0) or 0),
            "codec": v.get("codec_name", "?"),
            "res": "%sx%s" % (v.get("width", "?"), v.get("height", "?")),
        }
    except Exception as exc:  # noqa: BLE001 - 取证脚本要把失败种类原样报出来
        return {"error": repr(exc)}


def snap(outdir):
    """输出目录里现有 mp4 的 {路径: mtime} 快照，用于事后认定这次落了哪些文件。"""
    found = {}
    for root, _dirs, files in os.walk(outdir):
        for f in files:
            if f.lower().endswith(".mp4"):
                p = os.path.join(root, f)
                found[p] = os.path.getmtime(p)
    return found


def least_squares(points):
    """对 (成片秒, 墙钟秒) 做最小二乘，返回 (斜率, 截距, r^2)。样本少时只当形状看。"""
    n = len(points)
    if n < 2:
        return None
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    if sxx == 0:
        return None
    slope = sxy / sxx
    intercept = my - slope * mx
    syy = sum((y - my) ** 2 for y in ys)
    ssres = sum((y - (slope * x + intercept)) ** 2 for x, y in zip(xs, ys))
    r2 = 1.0 - ssres / syy if syy else 1.0
    return slope, intercept, r2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--scheme", action="append", required=True, help="方案 UUID，可给多次（按顺序一趟一趟导）")
    ap.add_argument("--out", required=True, help="输出目录绝对路径，必须已存在")
    ap.add_argument("--poll", type=float, default=2.0, help="轮询间隔秒；墙钟读数最多虚高这么多")
    ap.add_argument("--max-wait", type=float, default=1800.0, help="单趟最长等多久，超了就判不出终态")
    ap.add_argument("--i-accept-written-files", action="store_true",
                    help="显式确认：这次会在 --out 里真写出成片文件")
    args = ap.parse_args()

    if not args.i_accept_written_files:
        print("拒绝执行：这条探针会往 %s 真写文件。" % args.out)
        print("确认无误后加 --i-accept-written-files 重跑。")
        return 2
    outdir = os.path.abspath(args.out)
    if not os.path.isdir(outdir):
        print("拒绝执行：目录不存在 %s" % outdir)
        return 2

    print("取证⑤ · 导出渲染墙钟")
    print("  前台=http://127.0.0.1:%d/mcp  输出目录=%s  轮询粒度=%.1fs" % (args.port, outdir, args.poll))
    print("  待导方案 %d 条：%s" % (len(args.scheme), ",".join(args.scheme)))
    print()

    rows = []
    for n, sid in enumerate(args.scheme, 1):
        # 每趟导进自己的子目录：上一趟刚写完的文件 mtime 会落进这一趟的时间窗，
        # 共用一个目录会把「墙钟」配到「别人写的成片」上，表就成了假的配对。
        run_dir = os.path.join(outdir, "run%02d_%s" % (n, sid[:8]))
        os.makedirs(run_dir, exist_ok=True)
        before = snap(run_dir)
        t0 = time.time()
        is_err, inner, text = rpc("export_scheme", {"scheme_ids": [sid], "output_dir": run_dir}, args.port)
        if is_err:
            print("  [%d/%d] %s 派单即失败 code=%s" % (n, len(args.scheme), sid[:8], inner.get("code")))
            print("      原文=%s" % text[:200])
            rows.append({"scheme": sid, "error": inner.get("code", "DISPATCH_FAILED")})
            continue
        job_id = inner.get("job_id") or ""
        state, waited = "", 0.0
        while True:
            waited = time.time() - t0
            e2, j2, _ = rpc("get_job", {"job_id": job_id}, args.port)
            state = j2.get("state", "")
            if state in ("completed", "failed", "cancelled"):
                break
            if waited > args.max_wait:
                state = "TIMEOUT(%s)" % state
                break
            sys.stdout.write("    已等 %.0fs 状态=%s\r" % (waited, state or "?"))
            sys.stdout.flush()
            time.sleep(args.poll)
        wall = time.time() - t0
        after = snap(run_dir)
        # 认"这次落的文件"只看 mtime：重导同名方案是**原地覆盖**，路径不新增，
        # 早先用「路径是否新增」当判据会把真跑成功的三趟误报成「没认到成片」。
        fresh = sorted([(p, m) for p, m in after.items() if m >= t0 - 1])
        print("    %s job=%s 终态=%s 墙钟=%.1fs（含 %.1fs 轮询粒度，真实值在 [%.1f, %.1f]）"
              % (sid[:8], job_id[:8], state, wall, args.poll, max(0.0, wall - args.poll), wall))
        if state != "completed":
            print("      报告=%s" % json.dumps(j2, ensure_ascii=False)[:300])
        for p, _m in sorted(fresh):
            info = ffprobe(p)
            dur = info.get("duration", 0)
            ratio = (wall / dur) if dur else 0
            print("      成片 %s  %.1f秒  %s  %sx%s  渲染倍率=%.2f 秒墙钟/秒成片"
                  % (os.path.basename(p), dur,
                     ("%.1fMB" % (info.get("size", 0) / 1048576.0)) if "size" in info else "?",
                     info.get("res", "?"), info.get("codec", "?"), ratio))
            rows.append({"scheme": sid, "wall": wall, "file": p, "clip_dur": dur,
                         "size": info.get("size", 0), "state": state})
        if not fresh:
            print("      ⚠ 这次没在输出目录里认出新的 mp4 —— 别把上面的墙钟当渲染耗时，先看报告字段")
            rows.append({"scheme": sid, "wall": wall, "file": None, "state": state})

    print()
    print("  读数汇总（只统计认成片的趟）")
    good = [r for r in rows if r.get("file")]
    if good:
        print("  %-10s %10s %10s %8s" % ("墙钟(秒)", "成片(秒)", "倍率", "大小"))
        for r in good:
            print("  %-10.1f %10.1f %10.2f %8.1fMB"
                  % (r["wall"], r["clip_dur"], r["wall"] / r["clip_dur"], r["size"] / 1048576.0))
        walls = [r["wall"] for r in good]
        durs = [r["clip_dur"] for r in good]
        print("  跨度：成片 %.1f→%.1f 秒，墙钟 %.1f→%.1f 秒" % (min(durs), max(durs), min(walls), max(walls)))
        fit = least_squares([(r["clip_dur"], r["wall"]) for r in good])
        if fit:
            slope, intercept, r2 = fit
            print("  %d 点最小二乘（样本仍少，只当形状）：每多 1 秒成片多 %.3f 秒墙钟，固定截距 %.2f 秒，r²=%.3f"
                  % (len(good), slope, intercept, r2))
            for probe in (120.0, 300.0, 600.0):
                print("    外推 %.0f 秒成片 → %.1f 秒墙钟" % (probe, slope * probe + intercept))
    else:
        print("  没有一趟认到成片 —— 上面若有 completed，说明产物不在我盯着的那个目录里，先别记数")
    return 0


if __name__ == "__main__":
    sys.exit(main())
