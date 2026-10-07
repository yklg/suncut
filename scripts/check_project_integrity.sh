#!/usr/bin/env bash
# 工程引用完整性守卫（计划 2026-09-28-strip-original-author-identity §8 TC-01/TC-02）
# 守的是「源码树 <-> project.pbxproj 双向守恒」：本仓库的 pbxproj 含手工维护的 MixCutCore 编译引用，
# 生成器已与它脱钩，引用一旦缺失不会有提示，只会在编译期炸 —— 所以这里把它变成可复跑的机械判据。
# 用法：./scripts/check_project_integrity.sh    （SKIP_XCODEBUILD=1 可跳过 xcodebuild -list 那一步）
#
# 2026-09-30 追加第三道门：全部 .sh 里 `$变量` 后不许紧跟全角标点 —— 否则这套"判据"在用户终端
# （UTF-8 locale）里根本跑不起来，等于伪装防线。详见该段注释。
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

# 第四段对账：每个 swift FileRef 的 object id 必须挂在某个 PBXGroup 的 children 里。
# 漏挂 group 时 <group> sourceTree 会把文件解析到工程根，xcodebuild 报
# "Build input file cannot be found: $SRCROOT/<File>.swift"（2026-10-05 实测）。
fileref_ids = dict(re.findall(
    r"([0-9A-F]{24}) /\* ([\w.]+\.swift) \*/ = \{isa = PBXFileReference", text))
group_refs = set()
for group_block in re.findall(r"isa = PBXGroup;.*?children = \((.*?)\);", text, re.S):
    group_refs.update(re.findall(r"([0-9A-F]{24}) /\*", group_block))
ungrouped = sorted((name, oid) for oid, name in fileref_ids.items() if oid not in group_refs)

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
if ungrouped:
    print(f"FAIL[漏挂分组] {len(ungrouped)} 个文件引用不在任何 PBXGroup 里（会被解析到工程根）:")
    for n, oid in ungrouped:
        print(f"   {n}  ({oid})")
    failed = True
if not missing and not dangling and not dupes and not phase_vs_build and not ungrouped:
    print("PASS 源码树与 pbxproj 引用双向守恒（含 PBXGroup 挂载）")

# 显示身份对账：菜单栏/Dock/Finder 上的名字来自 pbxproj 的 PRODUCT_NAME，它不在 Brand.swift 里，
# 是第二处身份来源。上一轮的教训正是「界面文案翻干净了，另一处还写着旧名」—— 这里把两处钉成一处。
brand_path = os.path.join(root, "Sources", "MixCutCore", "Brand.swift")
bm = re.search(r'static let displayName = "([^"]+)"', open(brand_path, encoding="utf-8").read())
if not bm:
    print(f"FAIL[判据失效] 取不出 Brand.displayName —— 无法对账，不算通过")
    failed = True
else:
    display = bm.group(1)
    prod = set(re.findall(r"PRODUCT_NAME = ([^;]+);", text))
    apps = set(re.findall(r"explicitFileType = wrapper\.application;[^}]*?path = ([^;]+);", text))
    if prod == {display} and apps == {display + ".app"}:
        print(f"PASS 显示身份单一来源：PRODUCT_NAME 与产物名都等于 Brand.displayName（{display}）")
    else:
        print(f"FAIL[显示身份] Brand.displayName={display!r}，但 PRODUCT_NAME={sorted(prod)}、产物={sorted(apps)}")
        print("   —— 只改 Brand 会让界面叫新名、菜单栏/Dock/Finder 仍叫旧名（改名必须两处一起翻）")
        failed = True

sys.exit(1 if failed else 0)
PY

# shell 消息串的变量名边界门。macOS 自带 bash 3.2 在 **UTF-8 locale** 下会把紧贴在 `$var` 后面的
# 全角标点首字节吞进变量名 —— 消息串里若让全角括号紧贴变量，脚本会在 set -u 下当场死在第一条
# 判定上（本仓 2026-09-30 踩过 27 处，分布在 7 个文件）。我在 LC_CTYPE=C 里跑全绿、用户在
# UTF-8 里必红，所以这类写法必须机械禁掉；`bash -n` 碰不到运行期展开，语法检查不算数。
# 写法统一成：变量一律加花括号，全角标点只跟在 `}` 之后。
python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
found = []
for dirpath, dirnames, files in os.walk(root):
    # 点开头的目录整体跳过：.git 之外，本仓的 .scratch/ 里放着 0.11.0 快照等第三方拷贝，
    # 把它们算进来会让这条门在正常树上直接变红（实测踩过）。
    dirnames[:] = [d for d in dirnames if not d.startswith(".")]
    for f in files:
        if f.endswith(".sh"):
            found.append(os.path.relpath(os.path.join(dirpath, f), root))

hits = []
bad = re.compile(rb'\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])')
for rel in sorted(found):
    with open(os.path.join(root, rel), "rb") as fh:
        for i, line in enumerate(fh.read().splitlines(), 1):
            if bad.search(line):
                hits.append(f"{rel}:{i}")

if not found:
    print(f"FAIL[判据失效] {root} 下扫不到任何 .sh —— 探针根没命中，这条不算通过")
    sys.exit(1)
print(f"仓库 .sh 文件: {len(found)} 个")
if hits:
    print(f"FAIL[判据不可跑] {len(hits)} 处 $变量后紧跟全角标点（UTF-8 locale 下 bash 3.2 会把它吞进变量名，脚本死在第一条判定上）:")
    for h in hits[:12]:
        print(f"   {h}")
    print('   改法：把 $name 写成 ${name}（本仓踩实时 27 处，分布在 7 个文件）')
    sys.exit(1)
print("PASS 全部 .sh 的 $变量后不紧跟非 ASCII（判据在用户 locale 下真跑得起来）")
PY

if [ -z "${PBX_PATH:-}" ] && [ "${SKIP_XCODEBUILD:-0}" != "1" ]; then
  xcodebuild -list -project "$ROOT/MixCut.xcodeproj" -quiet >/dev/null
  echo "PASS xcodebuild -list 可读（工程结构未因手工编辑损坏）"
fi
