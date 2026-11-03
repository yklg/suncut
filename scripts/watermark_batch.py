#!/usr/bin/env python3
"""批量给成品视频叠加两张品牌 PNG：左上 logo + 底部居中大字。

只做两件事，且不改源文件：
  1. 按视频显示尺寸等比缩放两张 PNG（默认：logo 20.4% 宽、大字 64.8% 宽）；
     logo 贴左上，大字水平居中，底边距默认 13% 视频高（抖音底部 UI 近似安全区）。
  2. 逐条编码到独立输出目录，先写 .part.mp4，校验通过后才改名成正式文件。

用法：
    python3 scripts/watermark_batch.py <视频目录> \\
        --logo /path/to/logo.png --title /path/to/title.png --preview

    python3 scripts/watermark_batch.py <视频目录> \\
        --logo /path/to/logo.png --title /path/to/title.png --jobs 4

注意：
  - 预览会在画面底部画 13% 高的红色色带，只进预览，不进正片；真机 UI 仍需截图复核。
  - 左上 logo 也受抖音顶部状态栏/返回按钮影响；预览后如被挡，用 --margin-px 调大。
  - HDR（PQ/HLG）源默认拒绝；10-bit SDR 会转 8-bit 并告警。
  - 元数据默认清空（含 GPS/设备/拍摄时间），字幕/章节不保留。
  - 源文件永不写入；回退只需删除输出目录。
"""
from __future__ import annotations

import argparse
import json
import math
import os
import shlex
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path

HDR_TRANSFERS = {"smpte2084", "arib-std-b67"}
SAFE_AREA_RATIO = 0.13
OPAQUE_PIX_FMTS = {"rgb24", "gray", "gray16be", "gray16le", "rgb48be", "rgb48le"}
PRESETS = ("ultrafast", "superfast", "veryfast", "faster", "fast",
           "medium", "slow", "slower", "veryslow", "placebo")
PRINT_LOCK = threading.Lock()


class UserError(Exception):
    pass


@dataclass
class MediaProbe:
    width: int
    height: int
    duration: float | None
    fps: float
    pix_fmt: str
    color_range: str | None
    color_space: str | None
    color_transfer: str | None
    color_primaries: str | None
    rotation: int
    frames: int | None
    audio_codecs: list[str]
    audio_duration: float | None


@dataclass
class PngProbe:
    width: int
    height: int
    pix_fmt: str


@dataclass
class Layout:
    width: int
    height: int
    logo_w: int
    logo_h: int
    title_w: int
    title_h: int
    margin: int
    bottom: int
    band_y: int
    band_h: int
    title_align: str
    title_margin: int


@dataclass
class Result:
    source: Path
    output: Path | None
    status: str
    reason: str = ""


@dataclass
class Context:
    args: argparse.Namespace
    ffmpeg: str
    ffprobe: str
    logo_path: Path
    title_path: Path
    logo: PngProbe
    title: PngProbe
    items: list[Path]
    root: Path
    out_dir: Path
    jobs: int
    threads: int
    warned: set[str] = field(default_factory=set)


def eprint(*values: object) -> None:
    print(*values, file=sys.stderr, flush=True)


def run_cmd(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )


def parse_float(value: object) -> float | None:
    try:
        return float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None


def parse_int(value: object) -> int | None:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None


def parse_rotation(value: object) -> int | None:
    number = parse_float(value)
    return None if number is None else int(round(number))


def parse_rate(value: object) -> float:
    if not value or value in {"0/0", "N/A"}:
        return 0.0
    text = str(value)
    if "/" in text:
        left, right = text.split("/", 1)
        numerator, denominator = parse_float(left), parse_float(right)
        if not numerator or not denominator:
            return 0.0
        return numerator / denominator
    return parse_float(text) or 0.0


def normalize_color(value: object) -> str | None:
    if not value:
        return None
    text = str(value).strip().lower()
    return None if text in {"unknown", "n/a", "reserved"} else text


def stream_rotation(stream: dict) -> int:
    for side in stream.get("side_data_list") or []:
        if "rotation" in side:
            rotation = parse_rotation(side.get("rotation"))
            if rotation is not None:
                return rotation
    tags = stream.get("tags") or {}
    rotation = parse_rotation(tags.get("rotate"))
    return rotation if rotation is not None else 0


def probe_video(path: Path, ffprobe: str) -> MediaProbe:
    proc = run_cmd([
        ffprobe, "-v", "error", "-show_streams", "-show_format",
        "-count_frames", "-of", "json", str(path),
    ])
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "ffprobe 探测失败")
    try:
        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"ffprobe 输出不是 JSON: {exc}") from exc

    streams = data.get("streams") or []
    videos = [s for s in streams if s.get("codec_type") == "video"]
    if not videos:
        raise RuntimeError("没有视频流")
    video = videos[0]

    width = parse_int(video.get("width"))
    height = parse_int(video.get("height"))
    if not width or not height:
        raise RuntimeError("读不到视频宽高")

    rotation = stream_rotation(video)
    if abs(rotation) % 180 == 90:
        width, height = height, width

    format_duration = parse_float((data.get("format") or {}).get("duration"))
    duration = parse_float(video.get("duration")) or format_duration
    fps = parse_rate(video.get("avg_frame_rate")) or parse_rate(video.get("r_frame_rate"))

    audios = [s for s in streams if s.get("codec_type") == "audio"]
    audio_codecs = [str(s["codec_name"]) for s in audios if s.get("codec_name")]
    audio_durations = [parse_float(s.get("duration")) for s in audios]
    audio_durations = [d for d in audio_durations if d is not None]
    audio_duration = max(audio_durations) if audio_durations else format_duration

    return MediaProbe(
        width=width,
        height=height,
        duration=duration,
        fps=fps,
        pix_fmt=str(video.get("pix_fmt") or ""),
        color_range=normalize_color(video.get("color_range")),
        color_space=normalize_color(video.get("color_space")),
        color_transfer=normalize_color(video.get("color_transfer")),
        color_primaries=normalize_color(video.get("color_primaries")),
        rotation=rotation,
        frames=(parse_int(video.get("nb_read_frames"))
                or parse_int(video.get("nb_frames"))),
        audio_codecs=audio_codecs,
        audio_duration=audio_duration,
    )


def probe_png(path: Path, ffprobe: str) -> PngProbe:
    proc = run_cmd([
        ffprobe, "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,pix_fmt",
        "-of", "json", str(path),
    ])
    if proc.returncode != 0:
        raise UserError(f"读不出图片 {path}: {proc.stderr.strip()}")
    try:
        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise UserError(f"图片探测输出不是 JSON {path}: {exc}") from exc
    streams = data.get("streams") or []
    if not streams:
        raise UserError(f"图片没有图像流: {path}")
    stream = streams[0]
    width = parse_int(stream.get("width"))
    height = parse_int(stream.get("height"))
    if not width or not height:
        raise UserError(f"读不出图片宽高: {path}")
    return PngProbe(width, height, str(stream.get("pix_fmt") or ""))


def even_up(number: int) -> int:
    return int(math.ceil(number / 2.0) * 2)


def display_path(path: Path, root: Path) -> str:
    if root.is_file():
        return path.name
    try:
        return str(path.relative_to(root))
    except ValueError:
        return path.name


def map_relative(source: Path, root: Path) -> Path:
    return Path(source.name) if root.is_file() else source.relative_to(root)


def map_output(source: Path, root: Path, out_dir: Path) -> Path:
    return out_dir / map_relative(source, root).with_suffix(".mp4")


def discover(root: Path, out_dir: Path, extensions: set[str]) -> list[Path]:
    if root.is_file():
        return [root]
    if not root.is_dir():
        raise UserError(f"输入既不是文件也不是目录: {root}")

    out_resolved = out_dir.resolve()
    items: list[Path] = []
    for path in sorted(root.rglob("*"), key=lambda p: str(p)):
        if not path.is_file():
            continue
        if path.name.startswith(".") or path.name.endswith(".part.mp4"):
            continue
        if path.suffix.lower().lstrip(".") not in extensions:
            continue
        try:
            path.resolve().relative_to(out_resolved)
            continue
        except ValueError:
            pass
        items.append(path)
    return items


def build_layout(probe: MediaProbe, args: argparse.Namespace,
                 logo: PngProbe, title: PngProbe) -> Layout:
    width = even_up(probe.width)
    height = even_up(probe.height)

    logo_w = args.logo_width_px if args.logo_width_px is not None else round(width * args.logo_ratio)
    title_w = args.title_width_px if args.title_width_px is not None else round(width * args.title_ratio)
    margin = args.margin_px if args.margin_px is not None else round(width * args.margin_ratio)
    bottom = args.bottom_px if args.bottom_px is not None else round(height * args.bottom_ratio)

    logo_w = max(1, min(int(logo_w), max(1, int(width * 0.9))))
    title_w = max(1, min(int(title_w), max(1, int(width * 0.9))))
    margin = max(0, int(margin))
    bottom = max(0, int(bottom))

    logo_h = max(1, round(logo_w * logo.height / logo.width))
    if logo_h > height * 0.5:
        factor = (height * 0.5) / logo_h
        logo_w = max(1, round(logo_w * factor))
        logo_h = max(1, round(logo_h * factor))

    title_h = max(1, round(title_w * title.height / title.width))
    if title_h > height * 0.5:
        factor = (height * 0.5) / title_h
        title_w = max(1, round(title_w * factor))
        title_h = max(1, round(title_h * factor))

    band_y = int(round(height * (1 - SAFE_AREA_RATIO)))
    band_h = max(1, height - band_y)
    title_margin = (args.title_margin_px
                    if args.title_margin_px is not None else margin)
    title_margin = max(0, int(title_margin))
    return Layout(width, height, logo_w, logo_h, title_w, title_h,
                  margin, bottom, band_y, band_h, args.title_align, title_margin)


def build_filter(layout: Layout, preview: bool = False) -> str:
    title_x = ("main_w-overlay_w-" + str(layout.title_margin)
               if layout.title_align == "right" else "(main_w-overlay_w)/2")
    parts = [
        "[0:v:0]pad=ceil(iw/2)*2:ceil(ih/2)*2[base]",
        f"[1:v:0]format=rgba,scale={layout.logo_w}:-1:flags=lanczos[logo]",
        f"[2:v:0]format=rgba,scale={layout.title_w}:-1:flags=lanczos[title]",
        f"[base][logo]overlay=x={layout.margin}:y={layout.margin}[tmp]",
        f"[tmp][title]overlay=x={title_x}:y=main_h-overlay_h-{layout.bottom}",
    ]
    if preview:
        parts[-1] += "[v0]"
        parts.append(
            f"[v0]drawbox=x=0:y={layout.band_y}:w={layout.width}:h={layout.band_h}"
            ":color=red@0.28:t=fill[v]"
        )
    else:
        parts[-1] += "[v]"
    return ";".join(parts)


def build_encode_cmd(ctx: Context, source: Path, probe: MediaProbe,
                     layout: Layout, dest: Path) -> list[str]:
    args = ctx.args
    cmd = [
        ctx.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(source),
        "-i", str(ctx.logo_path),
        "-i", str(ctx.title_path),
        "-filter_complex", build_filter(layout),
        "-map", "[v]", "-map", "0:a?",
        "-sn", "-dn", "-map_chapters", "-1", "-map_metadata", "-1",
        "-movflags", "+faststart", "-fps_mode", "passthrough",
    ]
    # RGB 源（如 QTRLE/PNG 视频）的 gbr/pc 标签不能写给 yuv420p 输出。
    if probe.pix_fmt.startswith(("yuv", "nv")):
        for option, value in (
            ("-color_range", probe.color_range),
            ("-colorspace", probe.color_space),
            ("-color_trc", probe.color_transfer),
            ("-color_primaries", probe.color_primaries),
        ):
            if value:
                cmd += [option, value]

    if args.encoder == "videotoolbox":
        cmd += ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"]
    else:
        cmd += ["-c:v", "libx264", "-crf", str(args.crf),
                "-preset", args.preset, "-pix_fmt", "yuv420p"]
        if ctx.jobs > 1:
            cmd += ["-threads", str(ctx.threads)]

    if not probe.audio_codecs or all(codec == "aac" for codec in probe.audio_codecs):
        cmd += ["-c:a", "copy"]
    else:
        cmd += ["-c:a", "aac", "-b:a", "192k"]
    cmd.append(str(dest))
    return cmd


def build_preview_cmd(ctx: Context, source: Path, layout: Layout,
                      dest: Path, at: float) -> list[str]:
    return [
        ctx.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-ss", f"{at:.6f}", "-i", str(source),
        "-i", str(ctx.logo_path),
        "-i", str(ctx.title_path),
        "-filter_complex", build_filter(layout, preview=True),
        "-map", "[v]", "-frames:v", "1", "-update", "1",
        "-pix_fmt", "rgb24", str(dest),
    ]


def format_stderr(stderr: str) -> str:
    lines = [line for line in (stderr or "").strip().splitlines() if line.strip()]
    return "\n".join(lines[-12:])


def warn_once(ctx: Context, key: str, message: str) -> None:
    with PRINT_LOCK:
        if key in ctx.warned:
            return
        ctx.warned.add(key)
        eprint(f"[WARN] {message}")


def format_elapsed(seconds: float) -> str:
    seconds = max(0, int(seconds))
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes}:{secs:02d}"


def report_progress(results: list[Result], total: int, started: float) -> None:
    completed = len(results)
    ok = sum(1 for result in results if result.status in {"ok", "preview", "dry"})
    skipped = sum(1 for result in results if result.status == "skipped")
    failed = sum(1 for result in results if result.status == "failed")
    width = 24
    filled = int(width * completed / total) if total else width
    bar = "#" * filled + "-" * (width - filled)
    percent = completed / total * 100 if total else 100
    elapsed = time.monotonic() - started
    rate = completed / elapsed if elapsed > 0 and completed else 0.0
    remaining = (total - completed) / rate if rate > 0 else None
    eta = format_elapsed(remaining) if remaining is not None else "--"
    line = (f"进度 [{bar}] {completed}/{total} {percent:3.0f}% | "
            f"OK {ok} SKIP {skipped} FAIL {failed} | "
            f"已用 {format_elapsed(elapsed)} 剩余 {eta}")
    if sys.stderr.isatty():
        print(f"\r{line}", end="", file=sys.stderr, flush=True)
    else:
        print(line, file=sys.stderr, flush=True)


def finish_progress() -> None:
    if sys.stderr.isatty():
        print(file=sys.stderr, flush=True)


def hdr_reason(probe: MediaProbe) -> str | None:
    if probe.color_transfer in HDR_TRANSFERS:
        return (f"HDR 源（color_transfer={probe.color_transfer}）未做 tonemap，"
                "首版拒绝；请先转 SDR")
    return None


def verify_output(ctx: Context, part: Path, source: MediaProbe, layout: Layout) -> None:
    output = probe_video(part, ctx.ffprobe)
    problems: list[str] = []

    fps = source.fps or 30.0
    tolerance = max(3.0 / fps, 0.15)
    if source.duration is not None and output.duration is not None:
        if abs(output.duration - source.duration) > tolerance:
            problems.append(
                f"时长 {output.duration:.3f}s 与输入 {source.duration:.3f}s "
                f"相差超过 {tolerance:.2f}s"
            )

    if (output.width, output.height) != (layout.width, layout.height):
        problems.append(
            f"尺寸 {output.width}x{output.height} ≠ 期望 {layout.width}x{layout.height}"
        )

    if (source.frames is not None and output.frames is not None
            and abs(output.frames - source.frames) > 1):
        problems.append(f"解码帧数 {output.frames} 与输入 {source.frames} 相差超过 1")

    if source.audio_codecs:
        if not output.audio_codecs:
            problems.append("输入有音轨，输出没有")
        elif not all(codec == "aac" for codec in output.audio_codecs):
            problems.append(f"输出音轨不是 AAC: {output.audio_codecs}")
        if source.audio_duration is not None and output.audio_duration is not None:
            if abs(output.audio_duration - source.audio_duration) > 0.2:
                problems.append(
                    f"音轨时长 {output.audio_duration:.3f}s 与输入 "
                    f"{source.audio_duration:.3f}s 相差超过 0.2s"
                )

    if output.rotation != 0:
        problems.append(f"输出仍带旋转 {output.rotation}°")

    if source.pix_fmt.startswith(("yuv", "nv")):
        for name, before, after in (
            ("color_range", source.color_range, output.color_range),
            ("color_space", source.color_space, output.color_space),
            ("color_transfer", source.color_transfer, output.color_transfer),
            ("color_primaries", source.color_primaries, output.color_primaries),
        ):
            if before and after and before != after:
                problems.append(f"{name} 输入 {before} ≠ 输出 {after}")
            elif before and not after:
                problems.append(f"输出缺少 {name} 标签（输入 {before}）")

    if problems:
        raise RuntimeError("；".join(problems))


def warn_layout(ctx: Context, source: Path, layout: Layout) -> None:
    if layout.margin + layout.logo_w > layout.width:
        warn_once(ctx, f"logo-x:{source}",
                  f"{source.name}: logo 左边距 {layout.margin}px + 宽 {layout.logo_w}px "
                  f"超出画面宽 {layout.width}px")
    if layout.margin + layout.logo_h > layout.height:
        warn_once(ctx, f"logo-y:{source}",
                  f"{source.name}: logo 上边距 {layout.margin}px + 高约 {layout.logo_h}px "
                  f"超出画面高 {layout.height}px")
    if layout.bottom + layout.title_h > layout.height:
        warn_once(ctx, f"title-y:{source}",
                  f"{source.name}: 大字底边距 {layout.bottom}px + 高约 {layout.title_h}px "
                  f"超出画面高 {layout.height}px，可能被裁切")
    if layout.title_align == "right" and layout.title_margin + layout.title_w > layout.width:
        warn_once(ctx, f"title-x:{source}",
                  f"{source.name}: 大字右边距 {layout.title_margin}px + 宽 {layout.title_w}px "
                  f"超出画面宽 {layout.width}px")
    if layout.logo_w > ctx.logo.width * 1.2:
        warn_once(ctx, f"logo-upscale:{layout.logo_w}",
                  f"logo 目标宽 {layout.logo_w}px 超过原图 {ctx.logo.width}px 的 1.2 倍，会放大发虚")
    if layout.title_w > ctx.title.width * 1.2:
        warn_once(ctx, f"title-upscale:{layout.title_w}",
                  f"大字目标宽 {layout.title_w}px 超过原图 {ctx.title.width}px 的 1.2 倍，会放大发虚")


def process_one(ctx: Context, source: Path, index: int, total: int) -> Result:
    try:
        output = map_output(source, ctx.root, ctx.out_dir)
    except Exception as exc:
        with PRINT_LOCK:
            eprint(f"[FAIL] {source}: 输出路径计算失败: {exc}")
        return Result(source, None, "failed", str(exc))

    with PRINT_LOCK:
        print(f"[{index}/{total}] {display_path(source, ctx.root)}", flush=True)

    if output.is_dir():
        with PRINT_LOCK:
            eprint(f"[FAIL] {source}: 输出路径是目录: {output}")
        return Result(source, output, "failed", "输出路径是目录")

    if output.exists() and not ctx.args.overwrite:
        with PRINT_LOCK:
            print(f"  [SKIP] {output}（已存在；改位置/尺寸请加 --overwrite）", flush=True)
        return Result(source, output, "skipped")

    try:
        probe = probe_video(source, ctx.ffprobe)
    except Exception as exc:
        with PRINT_LOCK:
            eprint(f"[FAIL] {source}: 探测失败: {exc}")
        return Result(source, output, "failed", f"探测失败: {exc}")

    reason = hdr_reason(probe)
    if reason:
        with PRINT_LOCK:
            eprint(f"[FAIL] {source}: {reason}")
        return Result(source, output, "failed", reason)

    if "10" in probe.pix_fmt:
        warn_once(ctx, "10bit", f"10-bit SDR 源（{probe.pix_fmt}）会转成 8-bit yuv420p")

    layout = build_layout(probe, ctx.args, ctx.logo, ctx.title)
    warn_layout(ctx, source, layout)

    part = output.with_suffix(".part.mp4")
    renamed = False
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        part.unlink(missing_ok=True)
        proc = run_cmd(build_encode_cmd(ctx, source, probe, layout, part))
        if proc.returncode != 0:
            raise RuntimeError(format_stderr(proc.stderr) or "ffmpeg 编码失败")
        verify_output(ctx, part, probe, layout)
        os.replace(part, output)
        renamed = True
        with PRINT_LOCK:
            print(f"  [OK] {output}  {layout.width}x{layout.height}  "
                  f"logo={layout.logo_w}px  title={layout.title_w}px  "
                  f"bottom={layout.bottom}px", flush=True)
        return Result(source, output, "ok")
    except Exception as exc:
        with PRINT_LOCK:
            eprint(f"[FAIL] {source}: {exc}")
        return Result(source, output, "failed", str(exc))
    finally:
        if not renamed:
            try:
                part.unlink(missing_ok=True)
            except OSError:
                pass


def run_encodes(ctx: Context) -> list[Result]:
    results: list[Result] = []
    total = len(ctx.items)
    started = time.monotonic()
    if ctx.jobs <= 1:
        for index, source in enumerate(ctx.items, 1):
            results.append(process_one(ctx, source, index, total))
            if ctx.args.progress:
                report_progress(results, total, started)
        if ctx.args.progress:
            finish_progress()
        return results

    pool = ThreadPoolExecutor(max_workers=ctx.jobs)
    futures = {
        pool.submit(process_one, ctx, source, index, total): source
        for index, source in enumerate(ctx.items, 1)
    }
    try:
        for future in as_completed(futures):
            try:
                results.append(future.result())
            except Exception as exc:
                source = futures[future]
                with PRINT_LOCK:
                    eprint(f"[FAIL] {source}: {exc}")
                results.append(Result(source, None, "failed", str(exc)))
            if ctx.args.progress:
                report_progress(results, total, started)
    except KeyboardInterrupt:
        for future in futures:
            future.cancel()
        pool.shutdown(wait=False, cancel_futures=True)
        if ctx.args.progress:
            finish_progress()
        raise
    else:
        pool.shutdown(wait=True)
    if ctx.args.progress:
        finish_progress()
    return results


def preview_at(probe: MediaProbe, requested: float) -> float:
    duration = probe.duration or 0.0
    if duration <= 0.2:
        return 0.0
    if requested >= duration:
        return duration / 2
    return requested


def run_previews(ctx: Context) -> list[Result]:
    results: list[Result] = []
    total = len(ctx.items)
    started = time.monotonic()
    for index, source in enumerate(ctx.items, 1):
        with PRINT_LOCK:
            print(f"[{index}/{total}] {display_path(source, ctx.root)}", flush=True)
        try:
            probe = probe_video(source, ctx.ffprobe)
            reason = hdr_reason(probe)
            if reason:
                raise RuntimeError(reason)
            layout = build_layout(probe, ctx.args, ctx.logo, ctx.title)
            warn_layout(ctx, source, layout)
            relative = map_relative(source, ctx.root)
            dest = ctx.out_dir / "_preview" / relative.with_suffix(".png")
            dest.parent.mkdir(parents=True, exist_ok=True)
            at = preview_at(probe, ctx.args.preview_at)
            proc = run_cmd(build_preview_cmd(ctx, source, layout, dest, at))
            if proc.returncode != 0:
                raise RuntimeError(format_stderr(proc.stderr) or "ffmpeg 预览失败")
            rendered = probe_png(dest, ctx.ffprobe)
            if (rendered.width, rendered.height) != (layout.width, layout.height):
                raise RuntimeError(
                    f"预览尺寸 {rendered.width}x{rendered.height} "
                    f"≠ 期望 {layout.width}x{layout.height}"
                )
            with PRINT_LOCK:
                print(f"  [PREVIEW] {dest}  t={at:.3f}s  "
                      f"安全区红带 y={layout.band_y}..{layout.band_y + layout.band_h - 1}  "
                      f"bottom={layout.bottom}px", flush=True)
            results.append(Result(source, dest, "preview"))
        except Exception as exc:
            with PRINT_LOCK:
                eprint(f"[FAIL] {source}: {exc}")
            results.append(Result(source, None, "failed", str(exc)))
        if ctx.args.progress:
            report_progress(results, total, started)
    if ctx.args.progress:
        finish_progress()
    return results


def run_dry(ctx: Context) -> list[Result]:
    results: list[Result] = []
    total = len(ctx.items)
    started = time.monotonic()
    for index, source in enumerate(ctx.items, 1):
        with PRINT_LOCK:
            print(f"[{index}/{total}] {display_path(source, ctx.root)}", flush=True)
        try:
            probe = probe_video(source, ctx.ffprobe)
            reason = hdr_reason(probe)
            if reason:
                raise RuntimeError(reason)
            layout = build_layout(probe, ctx.args, ctx.logo, ctx.title)
            warn_layout(ctx, source, layout)
            output = map_output(source, ctx.root, ctx.out_dir)
            relative = map_relative(source, ctx.root)
            with PRINT_LOCK:
                print(f"  {probe.width}x{probe.height} → {layout.width}x{layout.height}  "
                      f"{probe.duration or 0:.3f}s", flush=True)
                print(f"  logo={layout.logo_w}px  title={layout.title_w}px  "
                      f"margin={layout.margin}px  bottom={layout.bottom}px  "
                      f"band={layout.band_y}..{layout.band_y + layout.band_h - 1}", flush=True)
                print("  filter: " + build_filter(layout, preview=ctx.args.preview), flush=True)
                if ctx.args.preview:
                    dest = ctx.out_dir / "_preview" / relative.with_suffix(".png")
                    at = preview_at(probe, ctx.args.preview_at)
                    print("  preview-cmd: "
                          + shlex.join(build_preview_cmd(ctx, source, layout, dest, at)), flush=True)
                    status = "dry"
                    result_output = dest
                else:
                    if output.exists() and not ctx.args.overwrite:
                        print(f"  [SKIP] {output}（已存在）", flush=True)
                        status = "skipped"
                    else:
                        status = "dry"
                    print("  cmd: "
                          + shlex.join(build_encode_cmd(ctx, source, probe, layout, output)),
                          flush=True)
                    result_output = output
            results.append(Result(source, result_output, status))
        except Exception as exc:
            with PRINT_LOCK:
                eprint(f"[FAIL] {source}: {exc}")
            results.append(Result(source, None, "failed", str(exc)))
        if ctx.args.progress:
            report_progress(results, total, started)
    if ctx.args.progress:
        finish_progress()
    return results


def parse_extensions(value: str) -> set[str]:
    extensions = {part.strip().lower().lstrip(".") for part in value.split(",")}
    extensions.discard("")
    if not extensions:
        raise UserError("--ext 不能为空")
    return extensions


def resolve_binary(explicit: str | None, name: str) -> str:
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_file():
            raise UserError(f"{name} 不存在: {path}")
        if not os.access(path, os.X_OK):
            raise UserError(f"{name} 不可执行: {path}")
        return str(path)
    found = shutil.which(name)
    if not found:
        raise UserError(f"找不到 {name}；请先安装，或用 --{name} 指定路径")
    return found


def build_context(args: argparse.Namespace) -> Context:
    root = Path(args.input).expanduser()
    if not root.exists():
        raise UserError(f"输入不存在: {root}")
    if not root.is_file() and not root.is_dir():
        raise UserError(f"输入既不是文件也不是目录: {root}")

    logo_path = Path(args.logo).expanduser()
    title_path = Path(args.title).expanduser()
    for label, path in (("logo", logo_path), ("title", title_path)):
        if not path.is_file():
            raise UserError(f"{label} PNG 不存在: {path}")

    ffmpeg = resolve_binary(args.ffmpeg, "ffmpeg")
    ffprobe = resolve_binary(args.ffprobe, "ffprobe")
    logo = probe_png(logo_path, ffprobe)
    title = probe_png(title_path, ffprobe)

    out_dir = (Path(args.out_dir).expanduser() if args.out_dir
               else (root if root.is_dir() else root.parent) / "watermarked")
    if out_dir.exists() and not out_dir.is_dir():
        raise UserError(f"输出路径不是目录: {out_dir}")
    extensions = parse_extensions(args.ext)
    items = discover(root, out_dir, extensions)
    if not items:
        raise UserError(f"没有找到可处理的视频: {root}")

    seen: dict[str, Path] = {}
    for source in items:
        output = map_output(source, root, out_dir)
        key = os.path.normcase(str(output.resolve()))
        if key in seen:
            raise UserError(f"输出冲突：{seen[key]} 与 {source} 都映射到 {output}")
        if key == os.path.normcase(str(source.resolve())):
            raise UserError(f"输出与源相同，拒绝执行: {source}")
        seen[key] = source

    cpu = os.cpu_count() or 1
    jobs = max(1, min(args.jobs, cpu))
    if jobs != args.jobs:
        eprint(f"[WARN] --jobs {args.jobs} 超过 CPU 数 {cpu}，按 {jobs} 运行")
    if args.encoder == "videotoolbox" and jobs > 1:
        eprint("[WARN] videotoolbox 不支持并发，--jobs 强制为 1")
        jobs = 1
    threads = max(1, cpu // jobs)

    print(f"ffmpeg: {ffmpeg}", flush=True)
    print(f"ffprobe: {ffprobe}", flush=True)
    print(f"输入: {root}（{len(items)} 条）", flush=True)
    print(f"输出: {out_dir}", flush=True)
    print(f"logo: {logo_path}  {logo.width}x{logo.height}  {logo.pix_fmt}", flush=True)
    print(f"title: {title_path}  {title.width}x{title.height}  {title.pix_fmt}", flush=True)
    if logo.pix_fmt in OPAQUE_PIX_FMTS:
        eprint("[WARN] logo PNG 没有 alpha 通道，叠上去会是实心矩形")
    if title.pix_fmt in OPAQUE_PIX_FMTS:
        eprint("[WARN] title PNG 没有 alpha 通道，叠上去会是实心矩形")

    return Context(
        args=args, ffmpeg=ffmpeg, ffprobe=ffprobe,
        logo_path=logo_path, title_path=title_path,
        logo=logo, title=title, items=items, root=root, out_dir=out_dir,
        jobs=jobs, threads=threads,
    )


def summarize(results: list[Result], mode: str) -> int:
    ok = sum(1 for result in results if result.status in {"ok", "preview", "dry"})
    skipped = sum(1 for result in results if result.status == "skipped")
    failed = [result for result in results if result.status == "failed"]

    if mode == "preview":
        print(f"\n预览：{ok} 张 / 失败 {len(failed)}", flush=True)
    elif mode == "dry":
        print(f"\ndry-run：{ok} 条可处理 / 跳过 {skipped} / 失败 {len(failed)}", flush=True)
    else:
        print(f"\n完成：成功 {ok} / 跳过 {skipped} / 失败 {len(failed)}", flush=True)

    if failed:
        print("失败清单：", flush=True)
        for result in failed:
            print(f"  - {result.source}: {result.reason}", flush=True)
        return 1
    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="批量给成品视频叠加左上 logo 与底部居中大字。",
        epilog=(
            "示例：\n"
            "  python3 scripts/watermark_batch.py ~/Movies/成品 \\\n"
            "      --logo ~/素材/logo.png --title ~/素材/大字.png --preview\n"
            "  python3 scripts/watermark_batch.py ~/Movies/成品 \\\n"
            "      --logo ~/素材/logo.png --title ~/素材/大字.png --jobs 4\n"
            "\n预览底部红带是抖音底部 UI 的近似安全区，仅预览；真机仍需截图复核。"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("input", help="单个视频或目录；目录递归扫描")
    parser.add_argument("--logo", required=True, help="左上角 PNG（建议透明底）")
    parser.add_argument("--title", required=True, help="底部居中大字 PNG（建议透明底）")
    parser.add_argument("--out-dir",
                        help="输出根目录；默认 <输入目录>/watermarked（单文件为 <父目录>/watermarked）")
    parser.add_argument("--logo-ratio", type=float, default=0.204,
                        help="logo 宽 / 视频宽（默认 0.204）")
    parser.add_argument("--title-ratio", type=float, default=0.648,
                        help="大字宽 / 视频宽（默认 0.648）")
    parser.add_argument("--margin-ratio", type=float, default=0.0185,
                        help="左/上边距 / 视频宽（默认 0.0185）")
    parser.add_argument("--bottom-ratio", type=float, default=0.13,
                        help="底边距 / 视频高（默认 0.13，抖音安全区近似）")
    parser.add_argument("--logo-width-px", type=int,
                        help="logo 固定像素宽，覆盖 --logo-ratio")
    parser.add_argument("--title-width-px", type=int,
                        help="大字固定像素宽，覆盖 --title-ratio")
    parser.add_argument("--margin-px", type=int,
                        help="左/上固定边距像素，覆盖 --margin-ratio")
    parser.add_argument("--bottom-px", type=int,
                        help="底部固定边距像素，覆盖 --bottom-ratio；原命令用 40")
    parser.add_argument("--title-align", choices=("center", "right"), default="center",
                        help="大字水平对齐（默认 center；参考图布局用 right）")
    parser.add_argument("--title-margin-px", type=int,
                        help="大字右对齐时的右边距；默认同 --margin-px")
    parser.add_argument("--crf", type=int, default=20,
                        help="libx264 CRF（默认 20；原命令 23）")
    parser.add_argument("--preset", choices=PRESETS, default="fast",
                        help="libx264 preset（默认 fast）")
    parser.add_argument("--encoder", choices=("libx264", "videotoolbox"),
                        default="libx264", help="视频编码器（默认 libx264）")
    parser.add_argument("--jobs", type=int, default=1,
                        help="并发编码数（默认 1；上限 CPU 数）")
    parser.add_argument("--preview", action="store_true",
                        help="只渲染单帧 PNG 调位置，不编码正片")
    parser.add_argument("--preview-at", type=float, default=1.0,
                        help="预览取帧秒数（默认 1.0）")
    parser.add_argument("--dry-run", action="store_true",
                        help="只打印尺寸、滤镜和命令；不建目录、不编码")
    parser.add_argument("--overwrite", action="store_true",
                        help="输出已存在时重编；默认跳过")
    parser.add_argument("--progress", action="store_true",
                        help="每完成一条打印进度条（前台实时刷新；重定向时逐行）")
    parser.add_argument("--ext", default="mp4,mov,m4v",
                        help="扫描扩展名，逗号分隔（默认 mp4,mov,m4v）")
    parser.add_argument("--ffmpeg", help="ffmpeg 路径；默认走 PATH")
    parser.add_argument("--ffprobe", help="ffprobe 路径；默认走 PATH")
    args = parser.parse_args(argv)

    if not (0 < args.logo_ratio <= 1):
        parser.error("--logo-ratio 必须在 (0, 1] 内")
    if not (0 < args.title_ratio <= 1):
        parser.error("--title-ratio 必须在 (0, 1] 内")
    if args.margin_ratio < 0:
        parser.error("--margin-ratio 不能为负")
    if args.bottom_ratio < 0:
        parser.error("--bottom-ratio 不能为负")
    for name in ("logo_width_px", "title_width_px", "margin_px",
                 "bottom_px", "title_margin_px"):
        value = getattr(args, name)
        if value is not None and value < 0:
            parser.error(f"--{name.replace('_', '-')} 不能为负")
    if not (0 <= args.crf <= 51):
        parser.error("--crf 必须在 0..51 内")
    if args.jobs < 1:
        parser.error("--jobs 至少为 1")
    if args.preview_at < 0:
        parser.error("--preview-at 不能为负")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        ctx = build_context(args)
    except (UserError, OSError) as exc:
        eprint(f"错误: {exc}")
        return 2

    try:
        if args.dry_run:
            results = run_dry(ctx)
            mode = "dry"
        elif args.preview:
            results = run_previews(ctx)
            mode = "preview"
        else:
            results = run_encodes(ctx)
            mode = "encode"
    except KeyboardInterrupt:
        eprint("\n已中断；当前 .part.mp4 已清理，源文件未动。")
        return 130

    return summarize(results, mode)


if __name__ == "__main__":
    sys.exit(main())
