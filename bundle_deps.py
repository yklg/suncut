#!/usr/bin/env python3
"""校验 MixCut 内置二进制是否就位且为 universal (arm64 + x86_64)。

历史：本脚本曾负责「从 Homebrew 抓 ffmpeg/whisper + 递归收集/修复 dylib」。
现已改为**静态自包含 universal 二进制**方案（支持 Intel Mac），二进制由
`scripts/build_universal_binaries.sh` 生成（下载静态 ffmpeg + 源码编 whisper/demucs
+ lipo 合并）。本脚本退化为校验器：确认文件就位、且都是双架构。
"""
import os
import subprocess
import sys

DEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "MixCut", "Resources", "bin")
BINARIES = ["ffmpeg", "ffprobe", "whisper", "whisper-cpu", "demucs"]   # 需为 universal（whisper-cpu=老系统/GPU失败兜底）
# 架构无关的内置数据文件。2026-11-16 起 Whisper ASR 模型不再内置 —— 改首次启动从
# hf-mirror 下载（安装包体积 1.2GB → ~0.15GB）。包内只留人声分离模型 demucs。
# Whisper 各档（含引擎档 large-v3-q5_0）由 WhisperModelCatalog 表 + 运行期下载链路管，
# 不随包分发 —— 这里若还登记 q5_0，check_license_notice.sh 会因「登记多余」失败。
DATA = ["ggml-htdemucs-4s.bin"]
# 最小体积下限（字节）——防止「下了半个/被截断」的模型蒙混过关（存在性检查拦不住）
MIN_SIZE = {
    "ggml-htdemucs-4s.bin": 80_000_000,           # 人声分离模型 ≈ 84MB
}


def archs(path):
    try:
        return set(subprocess.check_output(["lipo", "-archs", path], text=True).split())
    except Exception:
        return set()


def main():
    print(f"校验 {DEST}")
    ok = True
    for name in BINARIES:
        p = os.path.join(DEST, name)
        if not os.path.isfile(p):
            print(f"  ✗ 缺少 {name}")
            ok = False
            continue
        a = archs(p)
        if {"arm64", "x86_64"} <= a:
            print(f"  ✓ {name}: {' '.join(sorted(a))}")
        else:
            print(f"  ✗ {name} 架构不完整: {' '.join(sorted(a)) or '未知'}（需 arm64 + x86_64）")
            ok = False
    for name in DATA:
        p = os.path.join(DEST, name)
        if not os.path.isfile(p):
            print(f"  ✗ 缺少 {name}")
            ok = False
            continue
        size = os.path.getsize(p)
        floor = MIN_SIZE.get(name, 0)
        if size >= floor:
            print(f"  ✓ {name}: {size / 1e6:.0f} MB")
        else:
            print(f"  ✗ {name} 体积异常: {size / 1e6:.0f} MB（应 ≥ {floor / 1e6:.0f} MB，疑似未下完/被截断）")
            ok = False

    # 全集断言（计划 v4 ⑤）：bin 下所有 .bin 必须恰等于 DATA 白名单。
    # 比黑名单严密 —— 换任何 ASR 档位名（哪怕不在已知名单里）都会被拦，
    # 防止有人把 1.08GB 的 Whisper 模型重新塞回包里而这份清单毫无察觉。
    actual_bins = {n for n in os.listdir(DEST)
                   if n.endswith(".bin") and not n.startswith(".")
                   and os.path.isfile(os.path.join(DEST, n))}
    expected_bins = set(DATA)
    if actual_bins != expected_bins:
        extra = sorted(actual_bins - expected_bins)
        missing = sorted(expected_bins - actual_bins)
        print(f"\n✗ bin/*.bin 全集与 DATA 白名单不符：多出 {extra}，缺少 {missing}")
        if extra:
            print("  （Whisper 模型不再内置；多出的 .bin 请从 MixCut/Resources/bin 移除）")
        ok = False

    if not ok:
        print("\n内置二进制缺失或非 universal，请运行：\n  ./scripts/build_universal_binaries.sh")
        sys.exit(1)
    print("\n✅ 所有内置二进制就位且为 universal (arm64 + x86_64)；bin/*.bin 恰等于白名单。")


if __name__ == "__main__":
    main()
