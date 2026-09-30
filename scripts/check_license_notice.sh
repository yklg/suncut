#!/usr/bin/env bash
# 许可通告与包内二进制的对账（计划 license-packaging-closeout §改动清单 3）
#
# 为什么要有这支脚本：NOTICE 自称"每一项体积与 configure 参数都是从包内这颗二进制自己读出来的"。
# 这句话现在为真，但它没有任何机械防线 —— 下次重编 ffmpeg/换模型，那 7 个数字与 2 条
# configuration 行会悄悄腐烂，而腐烂的是法务文书。本脚本把这句话变成可复跑判据。
#
# 用法：./scripts/check_license_notice.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NOTICE_ROOT="$ROOT"
# 两个入口都可覆盖，只为做"改前快照必须变红"的扰动自证（不必复制 6.7GB 产物目录）
export LICENSE_BIN_DIR="${LICENSE_BIN_DIR:-}"
export LICENSE_NOTICE_PATH="${LICENSE_NOTICE_PATH:-}"
python3 - <<'PY'
import os, re, subprocess, sys

root = os.environ["NOTICE_ROOT"]
bin_dir = os.environ["LICENSE_BIN_DIR"] or os.path.join(root, "MixCut", "Resources", "bin")
note_path = os.environ["LICENSE_NOTICE_PATH"] or os.path.join(root, "Licenses", "NOTICE-内置组件许可.txt")

if not os.path.isdir(bin_dir):
    print(f"FAIL[判据失效] 找不到 {bin_dir} —— 无产物可对账，不算通过")
    sys.exit(1)
if not os.path.isfile(note_path):
    print(f"FAIL[判据失效] 找不到 {note_path}")
    sys.exit(1)

note = open(note_path, encoding="utf-8").read().splitlines()

# 只读「文件与体积（字节）：」标记块，块内形如 "  ffmpeg   132,109,112   （…）"。
# 这样将来另加「源码包与体积」一类登记不会被误当成包内文件。
registered = {}
in_block = False
for line in note:
    if line.startswith("文件与体积（字节）："):
        in_block = True
        continue
    if in_block:
        m = re.match(r"^\s+(\S+)\s+([\d,]{4,})(?=\s|$)", line)
        if m:
            name = m.group(1)
            size = int(m.group(2).replace(",", ""))
            if name in registered:
                print(f"FAIL[判据失效] 通告里 {name} 登记了两次，无法判定以哪条为准")
                sys.exit(1)
            registered[name] = size
        elif line.strip() == "":
            in_block = False

on_disk = {n for n in os.listdir(bin_dir) if not n.startswith(".") and
           os.path.isfile(os.path.join(bin_dir, n))}

failed = False
missing_in_note = sorted(on_disk - set(registered))
extra_in_note = sorted(set(registered) - on_disk)
if missing_in_note:
    print(f"FAIL[登记缺失] 包内有、通告没登记：{missing_in_note}")
    failed = True
if extra_in_note:
    print(f"FAIL[登记多余] 通告登记了、包内没有：{extra_in_note}")
    failed = True

size_ok = 0
for name in sorted(on_disk & set(registered)):
    actual = os.path.getsize(os.path.join(bin_dir, name))
    if actual == registered[name]:
        size_ok += 1
    else:
        print(f"FAIL[体积不符] {name}：通告 {registered[name]:,} ≠ 实测 {actual:,}")
        failed = True

# 架构：通告里凡标了 universal 的（即非 .bin 的可执行体）必须双架构
arch_checked = 0
for name in sorted(on_disk & set(registered)):
    path = os.path.join(bin_dir, name)
    if name.endswith(".bin"):
        continue
    out = subprocess.run(["lipo", "-archs", path], capture_output=True, text=True)
    if out.returncode != 0:
        print(f"FAIL[判据失效] lipo 读不出 {name} 的架构：{out.stderr.strip()}")
        failed = True
        continue
    archs = set(out.stdout.split())
    arch_checked += 1
    if not {"arm64", "x86_64"} <= archs:
        print(f"FAIL[架构不符] {name} 实测 {' '.join(sorted(archs))}，通告按 universal(arm64+x86_64) 登记")
        failed = True

# configuration 行：通告里两条，顺序为 arm64 切片、x86_64 切片
rec_cfg = [l.strip() for l in note if l.strip().startswith("configuration: ")]
if len(rec_cfg) != 2:
    print(f"FAIL[判据失效] 通告里 configuration 行有 {len(rec_cfg)} 条，预期 2 条（arm64 / x86_64）")
    failed = True
else:
    ffmpeg = os.path.join(bin_dir, "ffmpeg")
    tmp = os.path.join(root, ".scratch", "notice_probe_ffmpeg_x86")
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    try:
        actual = []
        r = subprocess.run([ffmpeg, "-version"], capture_output=True, text=True)
        actual.append(next((l.strip() for l in r.stdout.splitlines()
                            if l.strip().startswith("configuration: ")), None))
        thin = subprocess.run(["lipo", "-thin", "x86_64", ffmpeg, "-output", tmp],
                              capture_output=True, text=True)
        if thin.returncode != 0:
            print(f"FAIL[判据失效] 拆不出 x86_64 切片：{thin.stderr.strip()}")
            failed = True
        else:
            os.chmod(tmp, 0o755)
            r2 = subprocess.run([tmp, "-version"], capture_output=True, text=True)
            if r2.returncode != 0:
                print("FAIL[判据失效] x86_64 切片跑不起来（Rosetta 未装？），不能当作已核验")
                failed = True
            else:
                actual.append(next((l.strip() for l in r2.stdout.splitlines()
                                    if l.strip().startswith("configuration: ")), None))
        for tag, want, got in zip(("arm64", "x86_64"), rec_cfg, actual + [None] * (2 - len(actual))):
            if got is None:
                continue
            if want == got:
                print(f"  ✓ configuration[{tag}] 逐字相同（{len(want)} 字符）")
            else:
                print(f"FAIL[configuration 不符] {tag}：通告与实际读数不同")
                failed = True
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)

# 对应源码 tarball：通告里登记在「源码包与体积（字节）：」与「sha256：」两个块里。
# 开发期缺 tarball 只 WARN（该目录 gitignored，打包时才取）；
# 打包链用 REQUIRE_SOURCE=1 跑，缺任何一颗就判红 —— 否则通告里"随包提供"那句就是假话。
src_sizes = {}
src_sha = {}
mode = None
for line in note:
    s = line.strip()
    if s.startswith("源码包与体积（字节）："):
        mode = "size"; continue
    if s.startswith("sha256："):
        mode = "sha"; continue
    if mode == "size":
        m = re.match(r"^(\S+\.tar\.xz)\s+([\d,]{4,})$", s)
        if m:
            src_sizes[m.group(1)] = int(m.group(2).replace(",", ""))
        elif s == "":
            mode = None
    elif mode == "sha":
        m = re.match(r"^([0-9a-f]{64})\s+(\S+\.tar\.xz)$", s)
        if m:
            src_sha[m.group(2)] = m.group(1)
        elif s == "":
            mode = None

if sorted(src_sizes) != sorted(src_sha):
    print(f"FAIL[登记不全] 源码包体积与 sha256 清单一一对不上：{sorted(src_sizes)} vs {sorted(src_sha)}")
    failed = True

src_dir = os.path.join(root, "Licenses", "source")
require_src = os.environ.get("REQUIRE_SOURCE") == "1"
absent = []
for name in sorted(src_sizes):
    p = os.path.join(src_dir, name)
    if not os.path.isfile(p):
        absent.append(name)
        continue
    actual = os.path.getsize(p)
    if actual != src_sizes[name]:
        print(f"FAIL[源码体积不符] {name}：通告 {src_sizes[name]:,} ≠ 实测 {actual:,}")
        failed = True
        continue
    h = subprocess.run(["shasum", "-a", "256", p], capture_output=True, text=True).stdout.split()[0]
    if h == src_sha.get(name):
        print(f"  ✓ 对应源码 {name}：{actual:,} 字节、sha256 相符")
    else:
        print(f"FAIL[源码 sha256 不符] {name}：通告 {src_sha.get(name)} ≠ 实测 {h}")
        failed = True

if absent:
    msg = f"未取回 {absent}（打包前必须取回，见 CLAUDE.md 打包步骤）"
    if require_src:
        print(f"FAIL[对应源码] {msg}")
        failed = True
    else:
        print(f"WARN[对应源码] {msg}；开发期不判红，打包链须以 REQUIRE_SOURCE=1 跑")

if failed:
    print("❌ 许可通告与包内产物对不上账")
    sys.exit(1)
print(f"PASS 许可通告对账：{size_ok} 项体积、{arch_checked} 项 universal、2 条 configuration 行逐字相符")
PY
