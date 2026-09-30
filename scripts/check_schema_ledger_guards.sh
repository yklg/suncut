#!/usr/bin/env bash
# 批 0 一致性守卫：schema 锚点 / 启动账本 / 备份门 三处"改了代码忘了改账本"的漂移。
# 计划出处：docs/superpowers/plans/2026-09-30-upstream-012-portability.md §3.4
#
# 纪律照本项目既有守卫：
#   · 取样面只点名几个源文件，**不扫 `MixCut/Resources/bin`**（包内二进制会冒充源码让判据恒红，CLAUDE.md:168-170）
#   · 变量一律 ${var}（bash 3.2 会把紧跟变量的全角括号吞进变量名，`set -u` 当场死）
#   · 判据失效要说"判据失效"，不能默默算通过：任何一步取不出值都按 FAIL 处理
#   · 自证：`SRC_DIR=<违规树> ./scripts/check_schema_ledger_guards.sh` 必须变红
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC_DIR:-$ROOT/MixCut}"

if [ ! -d "$SRC" ]; then
  echo "FAIL 取样面不存在：$SRC —— 判据无法成立，不算通过"
  exit 1
fi

python3 - "$SRC" <<'PY'
import os, re, sys

src = sys.argv[1]
fail = 0

def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError as e:
        print(f"FAIL 读不到 {path}（{e}）—— 判据无法成立，不算通过")
        sys.exit(1)

models_dir  = os.path.join(src, "Models")
schema_ver  = read(os.path.join(src, "Models", "SchemaVersions.swift"))
app_sw      = read(os.path.join(src, "App", "MixCutApp.swift"))
launch_sw   = read(os.path.join(src, "App", "LaunchSteps.swift"))
guard_path  = os.path.join(src, "App", "SchemaGuard.swift")
schema_gd   = read(guard_path)

def ok(label, detail=""):
    print(f"PASS {label}{('（' + str(detail) + '）') if detail else ''}")

def bad(label, detail=""):
    global fail
    fail = 1
    print(f"FAIL {label}{('（' + str(detail) + '）') if detail else ''}")

# ---- SL-01 / SL-02 锚点与 @Model 必须同数同名 ------------------------------
model_files = sorted(f for f in os.listdir(models_dir) if f.endswith(".swift"))
declared = []
for f in model_files:
    body = read(os.path.join(models_dir, f))
    for m in re.finditer(r"^@Model\s+final\s+(?:public\s+|internal\s+)?class\s+(\w+)", body, re.M):
        declared.append(m.group(1))
    for m in re.finditer(r"^@Model\s+class\s+(\w+)", body, re.M):
        declared.append(m.group(1))
anchor_block = re.search(r"var models: \[any PersistentModel\.Type\] \{(.*?)\n    \}", schema_ver, re.S)
anchor = re.findall(r"(\w+)\.self", anchor_block.group(1)) if anchor_block else []

if len(declared) != len(anchor):
    bad("SL-01 @Model 数与版本锚点条数不符", f"@Model {len(declared)} 条 / AppSchemaV1.models {len(anchor)} 条")
elif not declared:
    bad("SL-01 取不到任何 @Model 声明", "取样面或写法变了，判据无法成立")
else:
    ok("SL-01 @Model 数与版本锚点条数一致", f"{len(declared)} 条")

missing = sorted(set(declared) - set(anchor))
extra   = sorted(set(anchor) - set(declared))
if missing or extra:
    bad("SL-02 版本锚点与 @Model 类名不成对", f"漏登记 {missing or '—'} / 锚点多出 {extra or '—'}")
elif not declared:
    bad("SL-02 无类名可比对", "判据无法成立")
else:
    ok("SL-02 版本锚点与 @Model 类名逐一对上", f"{len(set(declared))} 个类名")

# ---- SL-03 清单与动作必须同数 ----------------------------------------------
step_ids  = re.findall(r'LaunchStep\(id:\s*"([^"]+)"', launch_sw)
body_ids  = re.findall(r'^\s{8}"([A-Za-z]+)":\s*\{', launch_sw, re.M)
if len(step_ids) != len(set(step_ids)):
    dupes = sorted({i for i in step_ids if step_ids.count(i) > 1})
    bad("SL-03 清单 id 重复", f"重复 {dupes}")
elif len(step_ids) != len(body_ids):
    bad("SL-03 清单条数与动作条数不符", f"清单 {len(step_ids)} / 动作 {len(body_ids)}；漏的那颗会在运行期被判「清单不可信」而整轮作废")
else:
    ok("SL-03 清单条数与动作条数一致", f"{len(step_ids)} 颗")

if set(step_ids) != set(re.findall(r'^\s{8}"([A-Za-z]+)":\s*\{', launch_sw, re.M)):
    bad("SL-03b 清单 id 与动作 key 不同名")
else:
    ok("SL-03b 清单 id 与动作 key 同名")

# ---- SL-04 / SL-05 一次性键与账本必须互相覆盖 ------------------------------
# App 侧任何形如 "did…_v1" 的字符串字面量都算一颗一次性键 ——
# 不能只认 `let fixKey = "didXxx"` 这一种写法：`set(true, forKey: "didXxx")` 直接内联同样是新造一颗，
# 取样面窄了就会**假绿**（自证时正是这一条没变红，才把口径改宽）。
app_keys = set(re.findall(r'"(did[A-Za-z0-9_]+)"', app_sw))
plan_once_keys = set(re.findall(r'\.once\(key:\s*"([^"]+)"', launch_sw))
only_app  = sorted(app_keys - plan_once_keys)
only_plan = sorted(plan_once_keys - app_keys)
if only_app:
    bad("SL-04 有新的一次性 fixup 没进启动清单", f"只在代码里出现 {only_app} —— 它会绕过顺序与失败传播")
elif not app_keys:
    bad("SL-04 代码里取不到任何 did…_v1 键", "写法变了，判据无法成立")
else:
    ok("SL-04 代码里的每个一次性键都在清单上", f"{len(app_keys)} 颗")

if only_plan:
    bad("SL-05 清单记了代码不写的键", f"{only_plan} —— 账本会永远判 skipAlreadyDone，那颗 fixup 等于被删掉")
else:
    ok("SL-05 清单里的每个 once 键都真被代码写", f"{len(plan_once_keys)} 颗")

# ---- SL-06 删文件那颗必须有前序 -------------------------------------------
gc_stmt = re.search(r'LaunchStep\(id:\s*"orphanGC".*?onFailure:[^\n]*', launch_sw, re.S)
gc_req = re.findall(r'"([A-Za-z]+)"',
                    re.search(r"requires:\s*\[([^\]]*)\]", gc_stmt.group(0)).group(1)) \
        if (gc_stmt and re.search(r"requires:\s*\[([^\]]*)\]", gc_stmt.group(0))) else []
want_req = {"rewriteStoredPathPrefixes", "recoverFromDisk", "dedupProjectVideoAssociations"}
if not gc_stmt:
    bad("SL-06 取不到 orphanGC 的声明", "判据无法成立")
elif not gc_req:
    bad("SL-06 orphanGC 没有 requires", "删文件前必须确认路径改写/恢复/去重都成功过，否则在用素材会被判成孤儿")
elif not want_req.issubset(set(gc_req)):
    bad("SL-06 orphanGC 的 requires 少了关键前序", f"现有 {gc_req} / 要求含 {sorted(want_req)}")
else:
    ok("SL-06 orphanGC 的 requires 覆盖三颗关键前序", "、".join(sorted(gc_req)))

# ---- SL-07 有真信号的步骤必须回报成败 --------------------------------------
sig_missing = []
for name in ("rewriteStoredPathPrefixes", "recoverFromDisk", "dedupProjectVideoAssociations",
             "migrateToProjectVideoRelation"):
    if not re.search(r"static func " + name + r"\(container: ModelContainer\) -> Bool", app_sw):
        sig_missing.append(name)
if sig_missing:
    bad("SL-07 这些步骤不再回报成败", sig_missing)
else:
    ok("SL-07 四颗有真信号的步骤都回报 Bool",
       "rewrite / recover / dedup / migrateToProjectVideoRelation")

# ---- SL-08 那两处不许再退回吞错形状 ----------------------------------------
def body_of(text, name):
    m = re.search(r"static func " + name + r"\(.*?\n(?=    (?:@|static func|private static func|/// )|    \}\n)", text, re.S)
    return m.group(0) if m else ""

offenders = []
for name in ("recoverFromDisk", "dedupProjectVideoAssociations"):
    b = body_of(app_sw, name)
    if b and "try? context.save()" in b:
        offenders.append(name)
    if b and re.search(r"UserDefaults\.standard\.set\(true, forKey: (fixKey|key)\)", b) and "safeSave()" not in b:
        offenders.append(name + "（写成功键但没有 safeSave 门槛）")
if offenders:
    bad("SL-08 恢复/去重退回吞错或无条件记账", offenders)
else:
    ok("SL-08 恢复/去重的成功键只在 safeSave 之后写")

# ---- SL-09 被门拦住时不许教用户删库 ----------------------------------------
noncomment = [l for l in schema_gd.splitlines()
              if "请删除" in l and not l.lstrip().startswith(("//", "///", "*"))]
if noncomment:
    bad("SL-09 拒开库文案里又出现「请删除」", f"{len(noncomment)} 处：" + noncomment[0].strip()[:60])
else:
    ok("SL-09 防线文案不含「请删除」（只在注释里描述旧行为）")

# ---- SL-10 备份保留份数只有一个来源 ----------------------------------------
keep = re.findall(r"func pruneBackups\(storeURL: *URL, *keeping: *Int = (\d+)\)", schema_gd)
if len(keep) != 1:
    bad("SL-10 取不出唯一的备份份数默认值", f"命中 {keep}")
elif keep[0] != "3":
    bad("SL-10 备份保留份数被改了", f"现值 {keep[0]}，计划 §3.3 定的是 3")
else:
    ok("SL-10 备份保留份数默认 3", "口径是「最近一次成功开库后 ≤3」，连续拒开库攒多份是故意的")

# ---- SL-11 节流键必须按 double 读 ------------------------------------------
throttle_write = re.search(r'\.set\(Date\(\)\.timeIntervalSince1970, forKey: key\)', app_sw)
ledger_read = re.search(r'let stamp = defaults\.double\(forKey: key\)', launch_sw)
if not throttle_write:
    bad("SL-11 写节流键的形状变了", "判据无法成立")
elif not ledger_read:
    bad("SL-11 账本没按 double 读 lastOrphanGCAt", "存的是 unix 时间戳的 real；按 Date 读会永远得 nil，GC 于是每次启动都跑")
else:
    ok("SL-11 节流键写读同为 unix 时间戳（double）")

# ---- SL-12 棘轮：还允许多少颗步骤"吞错存盘后照样写成功键" --------------------
# 这不是认可现状，是把 §3.9 挖出的缺陷形状（存盘失败仍记成功 ⇒ 迁移永不重试）
# 钉成**只许减不许增**的基线。2026-10-01 实数 7 颗。修掉一颗就把 EXPECT_SWALLOW 往下调一颗，
# 调低了才算销账；新写一颗（又一个 `try? save()` + `set(true, …)`）当场变红。
lines = app_sw.split("\n")
starts = [(i, m.group(1)) for i, m in
          ((i, re.match(r"    static func (\w+)\(", l)) for i, l in enumerate(lines)) if m]
starts.append((len(lines), "<EOF>"))
swallow_book = []
for (s, name), (e, _) in zip(starts, starts[1:]):
    body = "\n".join(lines[s:e])
    # 形状要写宽：只认 `try? context.save()` 的话，`try? container.mainContext.save()`
    # 与 `try? modelContext?.save()` 会从同一个判据里滑出去（自证时正是这样漏的）。
    if re.search(r"try\?\s+[\w.]+\??\.save\(\)", body) and "set(true, forKey:" in body:
        swallow_book.append(name)

EXPECT_SWALLOW = 7
if len(swallow_book) > EXPECT_SWALLOW:
    bad("SL-12 棘轮涨了：又有步骤吞错存盘后写成功键",
        f"{len(swallow_book)} 颗 > 上限 {EXPECT_SWALLOW}，现单 {swallow_book}")
elif not swallow_book and EXPECT_SWALLOW > 0:
    bad("SL-12 棘轮已清零但上限没下调", "把 EXPECT_SWALLOW 一起改成 0，否则这条从此恒绿")
else:
    ok("SL-12 棘轮未涨", f"{len(swallow_book)}/{EXPECT_SWALLOW}：" + "、".join(swallow_book))

sys.exit(fail)
PY
rc=$?
if [ "$rc" = "0" ]; then
  echo "schema/账本守卫全绿"
elif [ "$rc" = "1" ]; then
  echo "schema/账本守卫有红项"
else
  # 守卫自己崩掉（rc>1）绝不能读成绿：判据没跑完就等于没有判据。
  echo "FAIL 守卫异常退出（rc=${rc}）—— 判据未跑完，按不通过处理"
  rc=1
fi
exit "$rc"
