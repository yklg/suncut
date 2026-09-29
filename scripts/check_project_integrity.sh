#!/usr/bin/env bash
# 工程引用完整性守卫（计划 2026-09-28-strip-original-author-identity §8 TC-01/TC-02）
# 守的是「源码树 <-> project.pbxproj 双向守恒」：本仓库的 pbxproj 含手工维护的 MixCutCore 编译引用，
# 生成器已与它脱钩，引用一旦缺失不会有提示，只会在编译期炸 —— 所以这里把它变成可复跑的机械判据。
# 用法：./scripts/check_project_integrity.sh    （SKIP_XCODEBUILD=1 可跳过 xcodebuild -list 那一步）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# PBX_PATH 可指向别的 pbxproj（用于在"改动前"的备份上验证本判据确实会红，而非恒绿）
PBX="${PBX_PATH:-$ROOT/MixCut.xcodeproj/project.pbxproj}"

python3 - "$ROOT" "$PBX" <<'PY'
import os, re, sys

root, pbx_path = sys.argv[1], sys.argv[2]
text = open(pbx_path, encoding="utf-8").read()

scan_dirs = [os.path.join(root, "MixCut"), os.path.join(root, "Sources", "MixCutCore")]
on_disk = []
for d in scan_dirs:
    for dirpath, _, files in os.walk(d):
        for f in files:
            if f.endswith(".swift"):
                on_disk.append(os.path.relpath(os.path.join(dirpath, f), root))

names = [os.path.basename(p) for p in on_disk]
dupes = sorted({n for n in names if names.count(n) > 1})

build_files = set(re.findall(r"/\* ([\w.]+\.swift) in Sources \*/ = \{isa = PBXBuildFile", text))
phase_block = re.search(r"isa = PBXSourcesBuildPhase.*?files = \((.*?)\);", text, re.S)
if not phase_block:
    print("FAIL: 找不到 PBXSourcesBuildPhase —— 工程结构不认识，判据无法成立")
    sys.exit(1)
in_phase = set(re.findall(r"/\* ([\w.]+\.swift) in Sources \*/", phase_block.group(1)))
filerefs = set(re.findall(r"/\* ([\w.]+\.swift) \*/ = \{isa = PBXFileReference", text))

missing = []
for n in sorted(set(names)):
    gaps = [k for k, s in (("PBXBuildFile", build_files), ("SourcesPhase", in_phase), ("PBXFileReference", filerefs)) if n not in s]
    if gaps:
        missing.append((n, gaps))

dangling = sorted((build_files | in_phase | filerefs) - set(names))
phase_vs_build = sorted(build_files ^ in_phase)

print(f"源码树 swift 文件: {len(on_disk)} 个（唯一文件名 {len(set(names))}）")
print(f"pbxproj: BuildFile={len(build_files)} SourcesPhase={len(in_phase)} FileRef={len(filerefs)}")

failed = False
if dupes:
    print(f"FAIL[判据失效] 同名文件让 basename 判定不可靠: {dupes}")
    failed = True
if missing:
    print(f"FAIL[缺引用] {len(missing)} 个文件不在工程里（编译会少这些文件）:")
    for n, gaps in missing:
        print(f"   {n}  缺: {', '.join(gaps)}")
    failed = True
if dangling:
    print(f"FAIL[悬空引用] {len(dangling)} 个工程引用指向盘上不存在的文件:")
    for n in dangling:
        print(f"   {n}")
    failed = True
if phase_vs_build:
    print(f"FAIL[阶段不一致] BuildFile 与 Sources phase 互差: {phase_vs_build}")
    failed = True
if not missing and not dangling and not dupes and not phase_vs_build:
    print("PASS 源码树与 pbxproj 引用双向守恒")

sys.exit(1 if failed else 0)
PY

if [ -z "${PBX_PATH:-}" ] && [ "${SKIP_XCODEBUILD:-0}" != "1" ]; then
  xcodebuild -list -project "$ROOT/MixCut.xcodeproj" -quiet >/dev/null
  echo "PASS xcodebuild -list 可读（工程结构未因手工编辑损坏）"
fi
