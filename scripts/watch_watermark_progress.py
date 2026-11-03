#!/usr/bin/env python3
"""看 watermark_batch.py 后台批处理的实时进度条。

只读日志和输出目录里的 .part 文件，不影响正在跑的批处理。
日志来源：Monitor/Bash 重定向的 stdout+stderr 文件。

用法：
    python3 scripts/watch_watermark_progress.py \\
        --log /tmp/watermark_full_K.log \\
        --out-dir '/path/to/输出目录'

    # 只看一眼
    python3 scripts/watch_watermark_progress.py ... --once
"""
from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path


def fmt_minutes(seconds: float | None) -> str:
    if seconds is None:
        return "--"
    seconds = max(0, int(seconds))
    minutes, secs = divmod(seconds, 60)
    return f"{minutes}m" if minutes >= 1 else f"{secs}s"


def snapshot(log_path: Path, out_dir: Path | None) -> dict[str, object]:
    text = log_path.read_text(encoding="utf-8", errors="replace")
    ok = text.count("[OK]")
    skipped = text.count("[SKIP]")
    failed = text.count("[FAIL]")

    starts = re.findall(r"^\[(\d+)/(\d+)\]\s+(.+)$", text, re.M)
    if starts:
        index, total_text, name = starts[-1]
        current = f"{index}/{total_text}"
        total = int(total_text)
    else:
        match = re.search(r"（(\d+) 条）", text)
        total = int(match.group(1)) if match else 0
        current = "--"
        name = "--"

    completed = ok + skipped + failed
    parts = len(list(out_dir.glob("*.part.mp4"))) if out_dir else 0
    try:
        stat = log_path.stat()
        born = getattr(stat, "st_birthtime", stat.st_ctime)
        elapsed = max(0.0, time.time() - born)
    except OSError:
        elapsed = 0.0
    rate = completed / elapsed if elapsed > 0 and completed else 0.0
    remaining = ((total - completed) / rate
                 if rate > 0 and total > completed else 0.0)
    done = "完成：" in text and total > 0 and completed >= total
    return {
        "total": total, "completed": completed, "ok": ok,
        "skipped": skipped, "failed": failed, "parts": parts,
        "current": current, "name": name, "elapsed": elapsed,
        "remaining": remaining, "done": done,
    }


def render(data: dict[str, object]) -> str:
    total = int(data["total"])
    completed = int(data["completed"])
    width = 24
    filled = int(width * completed / total) if total else 0
    bar = "#" * filled + "-" * (width - filled)
    percent = completed / total * 100 if total else 0
    name = str(data["name"])
    if len(name) > 18:
        name = name[:17] + "…"
    return (f"进度 [{bar}] {completed}/{total} {percent:3.0f}% | "
            f"OK{data['ok']} SKIP{data['skipped']} FAIL{data['failed']} | "
            f".part{data['parts']} | 当前 {data['current']} {name} | "
            f"{fmt_minutes(data['elapsed'])}/余{fmt_minutes(data['remaining'])}")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="看后台贴片批处理的进度条。")
    parser.add_argument("--log", required=True, help="批处理日志路径")
    parser.add_argument("--out-dir", help="输出目录；用于数 .part 文件")
    parser.add_argument("--interval", type=float, default=1.0,
                        help="刷新间隔秒数（默认 1.0）")
    parser.add_argument("--once", action="store_true", help="只打印一次快照")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    log_path = Path(args.log).expanduser()
    out_dir = Path(args.out_dir).expanduser() if args.out_dir else None
    if not log_path.is_file():
        print(f"错误: 日志不存在: {log_path}", file=sys.stderr)
        return 2
    try:
        while True:
            data = snapshot(log_path, out_dir)
            line = render(data)
            if args.once:
                print(line)
                return 0
            print(f"\r{line}", end="", flush=True)
            if data["done"]:
                print()
                return 0
            time.sleep(max(0.2, args.interval))
    except KeyboardInterrupt:
        print()
        return 130


if __name__ == "__main__":
    sys.exit(main())
