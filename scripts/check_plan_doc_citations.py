"""计划台账的形状与引用自检（守卫 G-g 的真身）。

为什么要有这道门（本仓实测，不是理论担心）：
  · 台账里的 `函数名:行号` **会腐败**（本期 R1/R2/R3/R5/R20 全是这一类：行号对不上、
    守卫根本不存在、把既有行为当成本期要改）；
  · Markdown 表格改一行就会整块崩（本期至少两次把数据行数改错单元格）；
  · 本仓 **无 remote、git 钩子是空壳** ⇒ 没有任何 CI 会替我们兜行号腐败。

用法：
    python3 scripts/check_plan_doc_citations.py                # 默认：文件夹混剪那份
    python3 scripts/check_plan_doc_citations.py <其他 plan 的路径>

适用边界：只钉**按本文件约定的形状写的**台账（表格、决议台账 D、修订记录 R、
〔勘误 Rx〕标记、「◇ 取证状态表」里的现状声明）。
豁免边界：其他历史 plan 文档按各自的形状写成，未按这套约定收口 ⇒ 不在默认范围内，
要纳入就显式把路径当参数传进来（否则第一次跑就会被陌生文档的形状打红，和本仪器无关）。
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    ROOT, "docs", "superpowers", "plans", "2026-10-20-folder-mix-by-category.md")
if not os.path.isfile(DOC):
    print("FAIL 台账文件不存在：%s" % DOC)
    sys.exit(2)
src = open(DOC, encoding="utf-8").read()
lines = src.split("\n")
fails = []

# ── 1. 表格形状：表头 / 分隔行 / 每个数据行的竖线数必须一致 ──
i, tables, checked = 0, 0, 0
while i < len(lines):
    if lines[i].lstrip().startswith("|"):
        blk = []
        while i < len(lines) and lines[i].lstrip().startswith("|"):
            blk.append((i + 1, lines[i]))
            i += 1
        tables += 1
        if len(blk) < 2:
            fails.append(f"表格 @{blk[0][0]} 只有 1 行，缺分隔行")
            continue
        head_n = blk[0][1].count("|")
        if not re.fullmatch(r"\|[\s:|-]+\|", blk[1][1].strip()):
            fails.append(f"表格 @{blk[0][0]} 第 2 行不是分隔行: {blk[1][1][:40]}")
        for ln, row in blk[2:]:
            checked += 1
            if row.count("|") != head_n:
                fails.append(f"表格 @{blk[0][0]} 第 {ln} 行列数 {row.count('|')} ≠ 表头 {head_n}")
    else:
        i += 1
print(f"表格 {tables} 张 / 数据行 {checked} 行")

# ── 2. file:line 引用：路径必须存在，行号必须落在文件长度内 ──
pat = re.compile(r"([A-Za-z0-9_./\u4e00-\u9fff+.-]+\.(?:swift|sh|py|md|js))[:：](\d+)(?:-(\d+))?")
seen, hits = set(), 0
for m in pat.finditer(src):
    path, a, b = m.group(1), int(m.group(2)), m.group(3)
    key = (path, a, b)
    if key in seen:
        continue
    seen.add(key)
    cand = [p for p in (path, os.path.join(ROOT, path), os.path.join(ROOT, "scripts", os.path.basename(path)))
            if os.path.isfile(p)]
    if not cand:
        # 允许只写文件名的情形：全仓搜一次
        base = os.path.basename(path)
        cand = [os.path.join(dp, f) for dp, _, fs in os.walk(ROOT)
                if ".git" not in dp and ".build" not in dp and ".scratch" not in dp
                for f in fs if f == base]
        cand = [c for c in cand if os.path.isfile(c)]
        if not cand:
            fails.append(f"引用路径找不到: {path}:{a}")
            continue
    n = sum(1 for _ in open(cand[0], encoding="utf-8", errors="replace"))
    hi = int(b) if b else a
    hits += 1
    if hi > n:
        fails.append(f"行号越界: {path}:{a}-{b or ''} 但该文件只有 {n} 行")
print(f"file:line 引用 {hits} 处已核（去重后）")

# ── 2b. 引用行必须**真含被引的那个锚点串** ──
# 上面第 2 节只验"路径存在 + 行号不越界"，抓不到 `:136 → :152` 这类腐烂：行号还在文件长度内，
# 指的却已经是别的代码（本期实测返工过三次）。这条腿把"引用句里反引号括起来的代码串"
# 拿去和被引那一行（或那一段）对，对不上就红。
# 适用边界：本台账 + 源码/脚本注释里的 file:line 引用（注释里那批腐烂最快，改动天天漂）。
# 豁免边界：① 引用句里**没有**可核对的代码串 ⇒ 跳过（不猜锚点，猜就会误红）；
#          ② 其他历史 plan 文档不在默认射程（见文件头的「豁免边界」），要核就把路径当参数传进来。
# 拦不住什么（要写清，否则下一个人以为行号腐败已被这道门全兜住）：
#   · 锚点是**标识符颗粒**级比对，不是整行语义 —— 行号指到同名函数的另一处调用点会漏；
#   · 散文形态的锚点（`Project.id.getter` 这类）拆完颗粒若恰好在被引行附近出现，就判过了；
#   · 指向**区间**的引用（`:164-168`）只要求区间内任一颗粒命中，不检查区间边界是否仍准确。
ANCHOR_PAT = re.compile(r"`([^`\n]{4,60})`")
ANCHOR_NOISE = re.compile(r"[:：]\d|\.(swift|sh|py|md|js)$")

def anchor_tokens(text):
    """把锚点串拆成**标识符颗粒**，用来做「这处引用有没有腐烂」的判据。

    为什么不能整串比对（本轮实测，69 处越锚里约四成是这条造成的假红）：
    台账和注释里的锚点有一大半是**散文形态** —— `MixScheme.project`（带类型前缀）、
    `SchemeViewModel.createCustomScheme(from:in:)`（带省略的参数表）、
    `minWidth/minHeight`（两颗并写）、`["mp4","mov",…]`（字面量数组，源码里带空格）、
    `Project.id.getter`、`Array(…)` —— 这些**永远不会**作为子串出现在被引那一行，
    整串比对就会把它们报成腐烂，于是这道门红得没有信息量，下次真腐烂混在里面就看不见。
    颗粒化后：`MixScheme.project` → `project`，`.createCustomScheme(from:in:)` → `createCustomScheme`。
    """
    stripped = re.sub(r"\([^()]*\)", " ", text)          # 参数表整个丢掉
    toks = [t for t in re.split(r"[^A-Za-z0-9_]+", stripped)
            if len(t) >= 3 and t.isascii()]
    return toks

_resolve_cache = {}

def token_hit(tok, text):
    """标识符颗粒要**按词边界**命中，不能裸子串。

    为什么（本轮实测）：子串匹配会让 `avi` 命中 "available"、`mov` 命中 "removeAnimation"，
    于是"这颗锚点在这个文件里活着"这个前提被假命中满足，接着在被引行上判越锚 ——
    报出来的是一条根本不存在的腐烂。词边界后 `avi` 只认真正的 `avi`。
    """
    return re.search(r"(?<![A-Za-z0-9_])" + re.escape(tok) + r"(?![A-Za-z0-9_])", text) is not None

def resolve_cited(path):
    if path in _resolve_cache:
        return _resolve_cache[path]
    hit = None
    for c in (path, os.path.join(ROOT, path),
              os.path.join(ROOT, "scripts", os.path.basename(path))):
        if os.path.isfile(c):
            hit = c
            break
    if hit is None:
        base = os.path.basename(path)
        for dp, dirs, fs in os.walk(ROOT):
            dirs[:] = [d for d in dirs if d not in (".git", ".build", "node_modules")]
            if any(s in dp for s in (os.sep + ".scratch", os.sep + ".build")):
                continue
            if base in fs:
                hit = os.path.join(dp, base)
                break
    _resolve_cache[path] = hit
    return hit

def in_dead_bracket(text, pos):
    """该处引用是否落在一个 `〔…〕` 括注里 —— 台账用这种括注**停放已腐烂的旧读数**。

    为什么要有这条：本台账的规矩是「勘误不删原文」（修订记录与执行进展里保留当时的读数＋日期），
    所以同一句里会同时出现"旧行号（故意留着的死数）"和"新行号（现状承诺）"。
    本文件的第 5 节已经按同一前提区分过现状/历史（历史读数必须带日期）。
    拦不住什么：把现状承诺写进 `〔〕` 里就躲过核对 —— 靠评审时人眼，不靠这道门。
    """
    open_at = text.rfind("〔", 0, pos)
    if open_at < 0:
        return False
    close_at = text.find("〕", pos)
    return (close_at < 0 or "\n" not in text[open_at:close_at]) and "\n" not in text[open_at:pos]

def is_dated_log_row(line_text):
    """执行进展表的一行（`| 2026-10-20 | …`）= **当天的历史读数**，不是现状承诺。

    同上的道理：这类行里的行号是"那天 grep 到的位置"，改写它等于篡改日志。
    拦不住什么：日志行里顺手写的现状承诺同样不被核 —— 现状承诺不该写在带日期的日志列里。
    """
    return re.match(r"\|\s*20\d\d-\d\d-\d\d\s*\|", line_text.strip()) is not None

def anchor_misses(text, origin):
    """锚点 = 引用**所在那一行**里、离这处引用足够近的反引号代码串。

    为什么按行 + 按距离：台账里两种写法都有 —— 「锚点在前、引用在后」
    （`` `MixScheme.audioTrackPolicyRaw` 默认 `keepOriginal` `X.swift:36` ``）和
    「引用在前、说明在后」（`` `X.swift:77`（fileImporter）与 ``），按行取两种都覆盖；
    但一行里连着写好几处引用时（台账第 86 行一次列五颗），整行取锚点会把同一颗锚点
    摊给所有引用 ⇒ 必假红（第一版就在这儿报了 140 处）。
    另外只认**纯 ASCII** 的反引号串：中文括注不是代码锚点。
    """
    bad = []
    checked = 0
    cites = list(pat.finditer(text))
    for idx, m in enumerate(cites):
        real = resolve_cited(m.group(1))
        if not real:
            continue
        body = open(real, encoding="utf-8", errors="replace").read().split("\n")
        lo = int(m.group(2))
        hi = int(m.group(3)) if m.group(3) else lo
        if lo > len(body):
            continue                                   # 越界由第 2 节报，这里不重复
        line_start = text.rfind("\n", 0, m.start()) + 1
        line_end = text.find("\n", m.start())
        line_text = text[line_start:(len(text) if line_end < 0 else line_end)]
        # 时态豁免（与第 5 节同一条道理）：日期日志行与 `〔…〕` 里停放的是**当天的旧读数**，
        # 台账的规矩是"勘误不删原文"⇒ 那些数本来就是死的，核它等于逼作者篡改日志。
        if is_dated_log_row(line_text) or in_dead_bracket(text, m.start()):
            continue
        # 只认**离这处引用足够近**的锚点（±40 字符）。一行里写了好几处引用时
        # （台账第 86 行一次列五颗），整行取锚点会把同一颗锚点摊给所有引用 ⇒ 必假红。
        radius = 40
        cands = []
        for tm in ANCHOR_PAT.finditer(line_text):
            t = tm.group(1).strip()
            if not re.search(r"[A-Za-z]{3}", t) or not t.isascii() or ANCHOR_NOISE.search(t):
                continue
            if abs(tm.start() - (m.start() - line_start)) <= radius + len(t) \
               or abs(tm.end() - (m.end() - line_start)) <= radius:
                cands.extend(anchor_tokens(t))
        # 只留下**在这颗文件里活着的**颗粒：整颗文件都搜不到的串不是代码锚点，而是散文描述
        # —— 台架读数（`bodyH 600 / vOver 0 / clipped []`）、跨文件用例名（`FolderMixPickerTests.P12`）、
        # 通配路径（`Sources/**`）。把它们当锚点就是拿描述句去要求源码行含它 ⇒ 必假红。
        whole = "\n".join(body)
        toks = [t for t in dict.fromkeys(cands) if token_hit(t, whole)]
        if not toks:
            continue
        checked += 1
        block = "\n".join(body[lo - 1:min(len(body), hi)])
        if not any(token_hit(t, block) for t in toks):
            line_no = text[:m.start()].count("\n") + 1
            # 读数带「锚点实际在哪一行」：没有这颗数，修行号只能把文件翻一遍。
            where = {t: next((str(i) for i, l in enumerate(body, 1) if token_hit(t, l)), "?")
                     for t in toks}
            bad.append("%s:%d → %s:%d 锚=%s 实际=%s"
                       % (origin, line_no, m.group(1), lo, toks[:3], where))
    return bad, checked

anchor_bad, anchor_checked = [], 0
c, n = anchor_misses(src, os.path.relpath(DOC, ROOT)); anchor_checked += n; anchor_bad += c
for top in ("Sources", "Tests", "MixCut", "scripts"):
    base = os.path.join(ROOT, top)
    for dp, dirs, fs in os.walk(base):
        dirs[:] = [d for d in dirs if d not in (".build", ".scratch", "node_modules")]
        for f in sorted(fs):
            if not f.endswith((".swift", ".sh", ".py")):
                continue
            p = os.path.join(dp, f)
            body = open(p, encoding="utf-8", errors="replace").read()
            if not pat.search(body):
                continue
            c, n = anchor_misses(body, os.path.relpath(p, ROOT))
            anchor_checked += n
            anchor_bad += c
# 逐条列出的上限：默认 12 条（够定位），`GG_DUMP_ALL=1` 全量倒出来 ——
# 加这条腿的第一轮要用它把历史越锚一次性看清，再决定豁免（分两笔就收不了尾）。
CAP = 999 if os.environ.get("GG_DUMP_ALL") == "1" else 12
for row in anchor_bad[:CAP]:
    fails.append("引用行不含被引锚点（行号已腐烂）：" + row)
if len(anchor_bad) > CAP:
    fails.append("另有 %d 处同类越锚未逐条列出" % (len(anchor_bad) - CAP))
print(f"越锚核对 {anchor_checked} 处带锚点的引用，越锚 {len(anchor_bad)} 处")

# 这条腿自己的非恒真自测（本仓规矩：新判据不配对侧刀，就等于没写）：
#   正腿 —— 行号指错必须红；
#   长腿 —— 行号指对必须不红且被计入核对（否则"跳过"和"通过"看不出区别）；
#   豁免腿 —— 散文锚点 / `〔〕` 里的死读数必须**不计入**，不是"计入且通过"。
_SELF_FILE = "MixCut/Models/MixScheme.swift"          # 37 行是 audioTrackPolicyRaw 默认值，21 行不是
_SELF_CASES = [
    ("腐烂：指到 21 行必须红",
     "`MixScheme.audioTrackPolicyRaw` 默认 `keepOriginal` `%s:21`" % _SELF_FILE, (1, 1)),
    ("对准：指到 37 行必须过且被核对",
     "`MixScheme.audioTrackPolicyRaw` 默认 `keepOriginal` `%s:37`" % _SELF_FILE, (0, 1)),
    ("散文锚点：文件里搜不到的描述句必须跳过",
     "`bodyH 600 / vOver 0 / clipped` 读数见 `%s:21`" % _SELF_FILE, (0, 0)),
    ("死括注：`〔〕` 里的旧读数必须跳过（勘误不删原文）",
     "〔旧读数：`MixScheme.audioTrackPolicyRaw` `%s:21`〕" % _SELF_FILE, (0, 0)),
    ("词边界：`avi` 不得命中 available",
     "`[\"avi\"]` 那份 `%s:3`" % _SELF_FILE, (0, 0)),
]
for label, sample, want in _SELF_CASES:
    got = anchor_misses(sample, "selftest")
    if (len(got[0]), got[1]) != want:
        fails.append("越锚腿自测不过：%s —— 得 (红%d, 核%d)，应 (红%d, 核%d)"
                     % (label, len(got[0]), got[1], want[0], want[1]))
    else:
        print("越锚腿自测 ✓ %s" % label)

# ── 3. 节引用不能落空 ──
heads = set(re.findall(r"^##+ (.+)$", src, re.M))
for ref in set(re.findall(r"第([一二三四五六七八九十]+)节", src)):
    if not any(h.startswith(ref + "、") for h in heads):
        fails.append(f"引用「第{ref}节」但无该标题")
for tag in re.findall(r"「([^」]*?)」见?[「]?([A-Z]-[a-z]|\d)", src):
    pass
# 决议编号引用必须都在台账里
declared = set(re.findall(r"^\| (D\d+) \|", src, re.M))
used = set(re.findall(r"\bD(\d{1,2})\b", src))
missing = sorted(d for d in used if "D" + d not in declared)
if missing:
    fails.append("引用了未登记的决议号: " + ", ".join("D" + x for x in missing))
print(f"决议台账 {len(declared)} 条")

# ── 4. 勘误标记必须成对：有〔勘误〕就要有对应 R 行 ──
marks = set(re.findall(r"〔勘误 (R\d+)〕", src))
rows = set(re.findall(r"^\| (R\d+) \|", src, re.M))
if marks - rows:
    fails.append("正文引用了修订记录里没有的编号: " + ", ".join(sorted(marks - rows)))
print(f"勘误标记 {len(marks)} 处 / 修订记录 {len(rows)} 行")

# ── 5. 「R1–Rn 若干条」这类范围计数必须与修订记录行数一致（本轮就写错过一次：正文 5 条、开头写 4 条） ──
def range_ok(upto, claimed, actual):
    return upto == actual and claimed == actual

# 判据自测：旧写法（正文 5 条却写「R1–R4 四条」）必须被判为不洽，否则这条判据是恒真的摆设
if range_ok(4, 4, 5):
    fails.append("范围计数判据自测失败：旧写法被判为自洽，说明它没牙")
else:
    print("判据自测：旧写法 R1–R4 四条 / 实际 5 条 → 判为不洽 ✓")

CN = {"一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
def to_int(tok):
    if tok.isdigit():
        return int(tok)
    # 中文数字：十 / 十N / N十 / N十M（上一版只查单字表，「十三条」被判为无法解析）
    if "十" in tok:
        left, _, right = tok.partition("十")
        tens = CN.get(left, 1) if left else 1
        ones = CN.get(right, 0) if right else 0
        if (left and left not in CN) or (right and right not in CN):
            return -1
        return tens * 10 + ones
    return CN.get(tok, -1)

for tok, want in [("10", 10), ("十", 10), ("十三", 13), ("四", 4), ("二十二", 22), ("零", -1)]:
    got = to_int(tok)
    if got != want:
        fails.append(f"中文数字解析错：{tok} → {got}，应为 {want}")
    else:
        print(f"解析自测：{tok} → {got} ✓")

# 正则必须同时吃阿拉伯数字与中文数字：上一版只写 (\d+)，遇到「R1–R10 十条」静默零匹配
# ⇒ 判据自失明却报绿（本轮实测踩到）。故再加"命中数必须 > 0"的守卫。
# 只核「〇 取证状态表」里那一条现状声明。
# 执行进展表里的「R1–R13 十三条自洽」是**当时的历史读数**，拿现状行数判它 = 判据找错对象
# （本轮实测就是这样误报的）。历史读数要保留并带日期，不许被现状覆盖。
head = src.split("## 一、")[0]
claims = list(re.finditer(r"R1[–-]R(\d+)[，,]?\s*([\d一二三四五六七八九十]+)\s*条", head))
if not claims:
    fails.append("范围计数判据零命中：取证状态表里没找到「R1–Rn 若干条」的写法，判据形同虚设")
for m in claims:
    upto, claimed = int(m.group(1)), to_int(m.group(2))
    if claimed < 0:
        fails.append("范围计数的条数无法解析: " + m.group(0))
        continue
    if not range_ok(upto, claimed, len(rows)):
        fails.append(f"范围计数对不上：取证状态表写「{m.group(0)}」，修订记录实为 {len(rows)} 条")
    else:
        print(f"范围计数自洽（仅核现状声明）：{m.group(0)} == 修订记录 {len(rows)} 条")
# 历史读数与现状不一致时，必须带日期，否则视为未标注的旧数字
for m in re.finditer(r"R1[–-]R(\d+)[，,]?\s*([\d一二三四五六七八九十]+)\s*条", src):
    if head.endswith(m.group(0)) or m.group(0) in head:
        continue
    line = src[:m.start()].split("\n")[-1] + src[m.start():src.find("\n", m.start())]
    if "2026-" not in line:
        fails.append("历史读数未带日期：「" + m.group(0) + "」既非现状又没标日期，会被误读成当前值")
    else:
        print("历史读数已带日期 ✓：" + m.group(0))

print("\nDOC " + ("CLEAN" if not fails else "FAIL x%d" % len(fails)))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
