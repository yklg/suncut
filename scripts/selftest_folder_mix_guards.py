#!/usr/bin/env python3
"""Step 6 守卫脚本的自证腿：每条门都要被打红一次，证明它不是恒真的摆设。

为什么单独立这个文件（项目记忆「红钉可以先进套件」「判据不能因错误原因通过」）：
`check_folder_mix_guards.sh` 今天全绿，可全绿有两种成因 —— 「代码确实干净」和「探针根本没接上」。
本轮就现场踩过后者两次：
  · `count_files` 用 `grep -h -c` 求和，注释行没剥掉 ⇒ 被自己写的一句说明判成站点命中（假红）；
  · 剥注释的正则把 `[[:space:]]*` 写在行号前面 ⇒ 顺序反了，一条都没剥掉（还是假红）。
两种都靠"基线跑"抓出来，不靠肉眼。所以本脚本先跑**未改动的副本**（必须全绿），
再逐条注刀（必须只有该红的那条红）。

用法：python3 scripts/selftest_folder_mix_guards.py [G-a G-e ...]
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 副本要覆盖守卫会读到的**全部**作用域。少拷一个目录就会出现"副本里根本没有那棵树"
# 的假读数：本轮第一版只拷了 docs/superpowers/plans，于是 G-g 找不到 docs/ROADMAP.md，
# 基线当场红 —— 那不是判据的错，是副本不忠实（所以基线必须自己声明这件事）。
COPIED = ["MixCut", "Sources", "Tests", "docs", "scripts"]

VM = "MixCut/ViewModels/FolderMixViewModel.swift"
VIEW = "MixCut/Views/Import/FolderMixView.swift"
SCAN = "MixCut/Services/Import/MaterialFolderScanner.swift"
SVC = "MixCut/Services/Import/ClipIngestService.swift"
PROBE_DUR = "MixCut/Services/Import/FolderMixDurationReader.swift"
PROBE_KEY = "MixCut/Services/Import/FolderMixContentKeyReader.swift"
APP = "MixCut/App/ContentView.swift"
MENU = "MixCut/App/MixCutApp.swift"
CORE_SCAN = "Sources/MixCutCore/FolderMixScanner.swift"
TESTS_DUMMY = "Tests/MixCutCoreTests/CharBudgetTests.swift"
# 特殊锚点：表示"在文件末尾追加"，用于本来就没有可替换行的刀（免得为了注刀去改夹具）
APPEND = "\u003c<append>>"
APPEND_MARKER = "// selftest 追加段"

# (编号, [(相对文件, 锚点, 替换)], 期望变红的门编号前缀集合)
KNIVES = [
    ("G-a1 混剪里长出真随机源", [(VM, "    func reseed() {",
                                  "    func probe() { let x = Int.random(in: 0..<3); _ = x }\n    func reseed() {"),
                                 ], {"G-a1"}),
    ("G-a2 显式用 SystemRandomNumberGenerator", [(SCAN, "enum MaterialFolderScanner {",
                                                  "enum MaterialFolderScanner {\n    static var g = SystemRandomNumberGenerator()"),
                                                 # 这个注入点同时落在 G-a1 的作用域（混剪落点文件）里
                                                 # ⇒ 两条门一起红才是对的；只红一条说明另一条看不见这个文件
                                                 ], {"G-a1", "G-a2"}),
    ("G-b1 30 秒闸的第二份副本", [(VM, "    static let summaryProjectName",
                                   "    static let selfSegmentMaxDuration: Double = 30\n    static let summaryProjectName"),
                                  # 定义写在混剪落点文件里 ⇒ G-b2（新代码不许引用这道闸）同红，
                                  # 两条门各管一侧：G-b1 数全仓定义份数，G-b2 数这条通路的引用
                                  ], {"G-b1", "G-b2"}),
        ("G-b2 混剪引用 30 秒闸", [(VM, "    var combinationTotal: Int { space.total }",
                                   "    /// 刀：把 30 秒闸又拽回混剪（D5 已拍不受它管辖）\n\n"
                                   "    var probeGate: Double { ImportViewModel.selfSegmentMaxDuration }\n"
                                   "    var combinationTotal: Int { space.total }"),
                                  # 〔笔 2 跟上锚点〕原来钉的是 `var ceiling: Int {`，
                                  # 那颗属性随 min 口径一起删净了 ⇒ 锚点未命中。
                                  # 锚点腐烂时台架报 SKIP 而不是假 OK，这条纪律保住了读数。
                                  ], {"G-b2"}),
    ("G-c1 判定长在 View 里", [(VIEW, "    var body: some View {",
                                  "    var probeC: Int { FolderMixPicker.maxWithoutRepeat(\n        candidatesByCategory: [:], orderedCategories: [], used: FolderMixUsedSet()) }\n    var body: some View {"),
                               ], {"G-c1"}),
    ("G-d1 混剪去调 ASR", [(VM, "    func reseed() {",
                            "    func probeD() { _ = ASRService() }\n    func reseed() {"),
                           ], {"G-d1"}),
    # FMX-21：LANE 扩面的**生效正对照**。入库真身搬进 ClipIngestService 之后，
    # 如果 LANE 没把它登进去，这把刀会**存活**（门看不见新真身）——
    # 那正是本仓在 pendingBatchSource 上栽过的假绿形状。它必须红，且只红 G-d1。
    ("G-d1 入库真身去碰网络（搬家后的可见性正对照）",
     [(SVC, "enum ClipIngestService {",
       "enum ClipIngestService {\n    static let probeNet = URLSession.shared")],
     {"G-d1"}),
    # 〔笔 4 扩面的生效正对照〕两颗探针 reader 是新加的 App 落点。逐颗各打一枪：
    # 合并成一枪就看不出"其中一颗其实没进 LANE"。探针缝（"顺便问一次云端"最容易长在这儿）
    # 若门看不见它，D8 的"零 AI / 零网络"承诺就只剩一句文案。
    ("G-d1 时长探针去碰网络（笔 4 新落点的可见性正对照）",
     [(PROBE_DUR, "enum FolderMixDurationReader {",
       "enum FolderMixDurationReader {\n    static let probeNet = URLSession.shared")],
     {"G-d1"}),
    ("G-d1 校验和探针去碰网络（笔 4 新落点的可见性正对照）",
     [(PROBE_KEY, "enum FolderMixContentKeyReader {",
       "enum FolderMixContentKeyReader {\n    static let probeNet = URLSession.shared")],
     {"G-d1"}),
    ("G-d2/d3 元信息反推被打开", [(VM, "inferMetadata: false", "inferMetadata: true"),
                                  ], {"G-d2", "G-d3"}),
    ("G-e1 菜单绑定少一条", [(MENU, '.keyboardShortcut("8", modifiers: .command)',
                              '// G-e 自证：这一条被摘掉'),
                             ], {"G-e1"}),
    ("G-e2 两个页面抢同一个 ⌘", [(MENU, '.keyboardShortcut("8", modifiers: .command)',
                                  '.keyboardShortcut("7", modifiers: .command)'),
                                 ], {"G-e2"}),
    # G-h 的刀必须**注满整条通路**：这条门数的是 LANE 里 `[FolderMix]` 的**总行数下限**（笔 5 抬到 6），
    # 只摘 VM 与扫描器两颗文件时，service + 两颗探针里还剩 8 行 ⇒ 门照样绿 ⇒ 这把刀等于没打。
    # （本轮实测就是这样报的 VACUOUS —— 门不是恒真，是刀太窄；两种读数的修法完全不同，
    #   所以这里把 LANE 里所有带前缀的文件逐个点名，一颗都不省。）
    ("G-h1 关键路径不打前缀", [(VM, "[FolderMix]", "[FM]"),
                                (SCAN, "[FolderMix]", "[FM]"),
                                (SVC, "[FolderMix]", "[FM]"),
                                (PROBE_DUR, "[FolderMix]", "[FM]"),
                                (PROBE_KEY, "[FolderMix]", "[FM]"),
                                ], {"G-h1"}),
    ("G-i 扩展名清单被抄回 App 层", [(VIEW, "struct FolderMixView: View {",
                                      "private let probeExts = [\"mp4\", \"mov\"]\nstruct FolderMixView: View {"),
                                     ], {"G-i1", "G-i2"}),
    ("G-j 第二份 SplitMix64", [(TESTS_DUMMY, APPEND, APPEND_MARKER + "\nprivate struct SplitMix64 {\n    mutating func next() -> UInt64 { 0 }\n}"),
                               ], {"G-j1"}),
    ("G-k 「自定义组合」被再抄一份", [(VIEW, "struct FolderMixView: View {",
                                       "private func probeGroup(_ p: Project, _ c: ModelContext) {\n    _ = MixStrategy(name: \"自定义组合\", style: \"\", description: \"\")\n}\nstruct FolderMixView: View {"),
                                      ], {"G-k1"}),
    ("G-l 混剪打了自建标记", [(VM, "    func reseed() {",
                                "    func probeL(_ v: Video) { v.isUserUploaded = true }\n    func reseed() {"),
                               ], {"G-l1"}),
]

# 注意：flags 必须在编译期给。曾经写成 `RED_RE.finditer(out, re.M)` ——
# finditer 的第二个位置参数是 pos，re.M(=1024) 被当成了"跳过前 1024 个字符"，
# 于是排在最前面的几条 FAIL 全部看不见，14 把刀齐刷刷报"恒真"（本轮实测）。
RED_RE = re.compile(r"^FAIL (G-[a-l]\d[a-z]?)", re.M)


def read(tmp, rel):
    with open(os.path.join(tmp, rel), encoding="utf-8") as f:
        return f.read()


def write(tmp, rel, text):
    with open(os.path.join(tmp, rel), "w", encoding="utf-8") as f:
        f.write(text)


def build_copy():
    tmp = tempfile.mkdtemp(prefix="fm_guards_selftest-")
    for item in COPIED:
        src = os.path.join(ROOT, item)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(tmp, item), symlinks=True)
        else:
            os.makedirs(os.path.dirname(os.path.join(tmp, item)), exist_ok=True)
            shutil.copy2(src, os.path.join(tmp, item))
    return tmp


def run_guard(tmp):
    env = dict(os.environ, ROOT_OVERRIDE=tmp)
    # errors="replace"：副本里连 Resources 一起拷了，grep 撞到二进制会吐出非 UTF-8 字节
    # （本轮实测就是它把整个自测腿炸掉的）—— 判据读的应当是文本，噪声按替换处理而不是让台架崩。
    p = subprocess.run([os.path.join(ROOT, "scripts", "check_folder_mix_guards.sh")],
                       capture_output=True, text=True, errors="replace", env=env, cwd=ROOT)
    out = p.stdout + p.stderr
    red = {m.group(1) for m in RED_RE.finditer(out)}
    green = len(re.findall(r"^PASS ", out, re.M))
    return red, green, p.returncode, out


def gate_ids_in_script():
    """列出守卫脚本里真正**会打印判定**的门号，防"刀注了但门早被删了"这种空转。
    只认出现在 PASS/FAIL 行或 expect_* 标签里的编号 —— 注释里提到的门号不算（那正是会被删掉的）。"""
    ids = set()
    with open(os.path.join(ROOT, "scripts", "check_folder_mix_guards.sh"), encoding="utf-8") as f:
        for line in f:
            if re.search(r'(echo "(PASS|FAIL)|expect_\w+\s+")', line):
                ids.update(re.findall(r"\bG-[a-l]\d[a-z]?\b", line))
    return ids


def main():
    only = [a for a in sys.argv[1:] if a.startswith("G-")]
    live = gate_ids_in_script()
    print("守卫脚本在册的门：%s" % " ".join(sorted(live)))

    tmp = build_copy()
    try:
        print("== 基线（未改动的副本）：必须全绿，否则副本不忠实、后面的读数全部作废 ==")
        red, green, rc, out = run_guard(tmp)
        # 三种台架故障分开判：非 0 退出、一条 PASS 都没拿到、有 FAIL —— 任一都要停机
        if red or rc != 0 or green == 0:
            print("BENCH FAIL rc=%s green=%s red=%s（副本不忠实或门自己坏了，后面读数一律作废）"
                  % (rc, green, sorted(red)))
            print(out[-2500:])
            return 2
        print("基线绿：%d 条 PASS、0 条 FAIL" % green)

        problems = []
        for num, edits, expect in KNIVES:
            if only and not any(num.startswith(k) for k in only):
                continue
            unknown = expect - live
            if unknown:
                print("SKIP  %-28s 门号不在册：%s（守卫脚本被删过，先补门再谈刀）" % (num, sorted(unknown)))
                problems.append((num, "门不在册"))
                continue
            originals = {}
            injected = 0
            for rel, old, new in edits:
                text = read(tmp, rel)
                originals.setdefault(rel, text)
                if old == APPEND:
                    write(tmp, rel, text + "\n" + new)
                    injected += 1
                    continue
                hits = text.count(old)
                if hits != 1:
                    # 多条同锚点是允许的（比如前缀那条要一次换掉 6 处），0 条才是没注进去
                    if hits == 0:
                        print("SKIP  %-28s 锚点 0 命中：%s" % (num, rel))
                        problems.append((num, "锚点未命中"))
                        injected = -1
                        break
                write(tmp, rel, text.replace(old, new))
                injected += 1
            if injected < 0:
                for rel, text in originals.items():
                    write(tmp, rel, text)
                continue
            red, green, rc, out = run_guard(tmp)
            for rel, text in originals.items():
                write(tmp, rel, text)
                assert read(tmp, rel) == text, "还原失败：" + rel
            unexpected = red - expect
            missed = expect - red
            if not red:
                print("VACUOUS %-28s 刀注满了却零红 ⇒ 这条门是恒真的摆设" % num)
                problems.append((num, "恒真"))
            elif missed:
                print("PARTIAL %-28s 期望红 %s，只红了 %s" % (num, sorted(expect), sorted(red)))
                problems.append((num, "该红的没红"))
            elif unexpected:
                print("SPREAD  %-28s 多红了 %s（刀串味了，作用域要收）" % (num, sorted(unexpected)))
                problems.append((num, "越界红"))
            else:
                print("OK      %-28s 只咬住该咬的：%s" % (num, sorted(red)))

        # 全还原后必须回到基线
        red, green, rc, out = run_guard(tmp)
        if red:
            print("FAIL 还原后仍红：%s ⇒ 还原不干净" % sorted(red))
            problems.append(("还原", sorted(red)))
        else:
            print("OK      还原后回到基线（%d 条 PASS）" % green)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if problems:
        print("有 %d 条未达预期：%s" % (len(problems), problems))
        return 1
    print("每条门都被自己的刀咬红过，且互不串味；还原无损")
    return 0


if __name__ == "__main__":
    sys.exit(main())
