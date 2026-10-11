#!/usr/bin/env bash
# 活库访问纪律守卫（计划 2026-10-11-schema-gate-stale-artifact.md §6-8）
#
# 守的是本仓一条明令：**不要由工具去打开用户的活库**
# （`verify_graph_broadcast.sh:16-18` 原文：WAL 库即使以只读方式打开，SQLite 也可能要
#   创建/改写 `-shm` 边车，那是写副作用；所以只读 SQL 交用户亲手跑）。
# 本案取证过程中一个探查子代理为"确认那些列还在"就开了活库，活库 `-shm` 的 mtime 当场被推后 ——
# 而这条纪律当时只写在台账里，**没有任何会红的东西**。这与 SL-14 的立项理由自相矛盾
# （"规矩只写在注释里就会被改掉，必须钉成判据"），同案不该两套标准。
#
# 口径（对**指向活库**的 sqlite3 调用逐条判）：
#   ① 必须带 `-readonly`；
#   ② 同一文件里必须存在"活实例未运行"的前置（`pgrep -x SunCut`）—— 应用还开着时 WAL 边车最危险；
#   ③ 调用行里出现写语句（UPDATE/INSERT/DELETE/DROP/VACUUM/journal_mode）直接红，不看别的。
#
# ⚠️ 触发条件是"**引用活库目录**"，不是"引用了某个 `*.store`"。
#    第一版按 `.store` 触发，实测把合法夹具判红了：往 `mktemp -d` 里的副本库 `UPDATE` 造悬空边
#    （正是 §6-1 验收格要做的事）也被这条判据拒掉 —— 纪律管的是用户的活库，不是所有叫 Suncut.store 的文件。
#    判据只验"该红的会红"是不够的，**"该绿的不会乱红"要一起验**（台架 M10 钉这一格）。
#    已知拦不住的形状：把活库路径拆成几段变量拼出来、或先 `cd` 进活库目录再开相对路径 ——
#    那要真堵得靠运行时（App 侧或 OS 层），不靠文本扫描，别把这条读成全覆盖。
# 今天全仓只有一处真调用（`verify_graph_broadcast.sh:200`），它三条都满足。
# 这条不是为现状开的，是为"下一个想顺手读一眼库"的人开的。
#
# 用法：bash scripts/check_live_store_guards.sh
#   自证：LIVE_STORE_SCAN_DIR=<合成树> bash scripts/check_live_store_guards.sh   （必须变红）
# 注意：刻意不开 set -e —— 子命令非 0 退出码就是判据本身（本仓踩过）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="${LIVE_STORE_SCAN_DIR:-$ROOT}"

python3 - "$SCAN" <<'PY'
import os, re, sys

root = sys.argv[1]
if not os.path.isdir(root):
    print(f"FAIL[判据失效] 取样根不存在：{root}")
    sys.exit(2)

sh_files = []
for dirpath, dirnames, files in os.walk(root):
    dirnames[:] = [d for d in dirnames if not d.startswith(".") and d != "node_modules"]
    sh_files += [os.path.join(dirpath, f) for f in files if f.endswith(".sh")]

# 取数闸：一颗都没扫到 = 探针根没命中，绝不能读成"没有违规"
if not sh_files:
    print(f"FAIL[判据失效] {root} 下扫不到任何 .sh —— 取样面为空，这条不算通过")
    sys.exit(2)

# ⚠️ 判定按**文件级**触发，不按行级：`DB="$LIVE/Suncut.store"` 然后下一行 `sqlite3 "$DB" …`
#    这种变量间接，行级正则会整个漏掉（写第一版时就是这么漏的）。
#    触发面是"引用了活库目录"（不是"引用了某个 .store"）—— 见上面口径里那条实测教训。
live_dir_re = re.compile(r"Library/Application Support/Suncut\b")
call_re = re.compile(r"\bsqlite3\b")
write_re = re.compile(r"\b(UPDATE|INSERT|DELETE|DROP|VACUUM)\b|journal_mode\s*=", re.I)
pgrep_re = re.compile(r"pgrep[^#\n]*SunCut")

hits = []
checked = 0
here_start = re.compile(r"<<-?['\"](\w+)['\"]")
for path in sorted(sh_files):
    rel = os.path.relpath(path, root)
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as exc:
        print(f"FAIL[判据失效] 读不到 {rel}（{exc}）")
        sys.exit(2)
    if not live_dir_re.search(text):
        continue
    # 只认**真正的 shell 命令行**：注释行与 heredoc 内部（python 块）都不算调用。
    # 第一版没做这件事，结果守卫把自家 print("… sqlite3 … .store …") 抓成了违规 ——
    # 与本仓 check_asr_guards.sh G14 那条"grep 分不清注释与调用点"同一族坑。
    # 选"让扫描器学会区分"而不是"给守卫开豁免口"：豁免会被后来者照抄。
    call_lines = []
    heredoc = None
    for i, raw in enumerate(text.splitlines(), 1):
        s = raw.strip()
        if heredoc:
            if s == heredoc:
                heredoc = None
            continue
        if s.startswith("#"):
            continue
        hm = here_start.search(raw)
        if hm:
            heredoc = hm.group(1)
            continue
        if call_re.search(raw):
            call_lines.append((i, raw))
    if not call_lines:
        continue
    checked += len(call_lines)
    has_pgrep = bool(pgrep_re.search(text))
    for i, line in call_lines:
        stripped = line.strip()
        if write_re.search(line):
            hits.append((rel, i, "写语句直接拒", stripped[:90]))
        elif "-readonly" not in line:
            hits.append((rel, i, "缺 -readonly", stripped[:90]))
        elif not has_pgrep:
            hits.append((rel, i, "同文件没有『活实例未运行』前置（pgrep -x SunCut）", stripped[:90]))

print(f"取样 .sh: {len(sh_files)} 个；指向活库的 sqlite3 调用: {checked} 处")

if not checked:
    # 取样面非空却一颗调用都没有 ⇒ 唯一的真调用被删了，这条判据会静默变虚
    print("FAIL[判据失效] 全仓没有任何指向活库的 sqlite3 调用 —— 要么纪律被整体删除，"
          "要么调用点被改写成扫不到的形状（拆变量拼路径、或先 cd 进活库再开相对路径）；"
          "这条判据当场失去意义，请人工确认")
    sys.exit(2)

if hits:
    print(f"FAIL 有 {len(hits)} 处对活库的访问不合纪律（WAL 库只读打开也会写 -shm 边车）：")
    for rel, i, why, snippet in hits:
        print(f"   {rel}:{i}  {why}")
        print(f"      {snippet}")
    print("   改法：把 SQL **打印**给用户自己跑（照 verify_graph_broadcast.sh:188-190），")
    print("        真要代跑必须同时满足：-readonly + 先 pgrep -x SunCut 确认应用已退出 + 用户显式同意。")
    sys.exit(1)

print(f"PASS 全部 {checked} 处活库调用都带 -readonly 且有『活实例未运行』前置")
PY
exit $?
