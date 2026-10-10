#!/usr/bin/env bash
# 批 1 · 1.3-A 撤销事务守卫：防"撤销条又退回普通提示的单槽"。
# 计划出处：.scratch/preview-1.3-scope.md §A
#
# 为什么要有这条：A 方案的全部收益挂在一个不变量上 ——
#   **撤销浮条的可见性只来自 PendingDeletionCenter（状态机 armed），不经过 ToastCenter。**
# 一旦有人图省事把 `actionTitle` 加回 `ToastCenter.show`，撤销条就又会被任意一条 2.2 秒提示顶掉，
# 而宽限期在界面上仍然是"看起来在倒计时"的装饰 —— 正是本轮审查判为表面修补的那个形状。
# （时长本身是产品档位，现 5 秒；这颗门钉的是**可见性来源**，与档位无关，换档不影响它承重。）
#
# 纪律照本项目既有守卫：
#   · 取样面只点名源文件，**不扫 `MixCut/Resources/bin`**（包内二进制会冒充源码让判据恒红）
#   · 变量一律 ${var}（bash 3.2 会把紧跟变量的全角括号吞进变量名，`set -u` 当场死）
#   · 扫源码先剥注释（否则我自己写的说明文字会假红）
#   · 判据取不出值就报"判据失效"，不默默算通过
#   · 自证：`./scripts/check_undo_guards.sh --selftest` 必须在合成违规树上逐条变红
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "--selftest" ]; then
  exec bash "$ROOT/scripts/selftest_undo_guards.sh"
fi

SRC="${SRC_DIR:-$ROOT/MixCut}"
CORE="${CORE_DIR:-$ROOT/Sources/MixCutCore}"

for d in "$SRC" "$CORE"; do
  if [ ! -d "$d" ]; then
    echo "FAIL 取样面不存在：$d —— 判据无法成立，不算通过"
    exit 1
  fi
done

python3 - "$SRC" "$CORE" <<'PY'
import os, re, sys

src, core = sys.argv[1], sys.argv[2]
fail = 0

def read(path):
    if not os.path.isfile(path):
        print(f"FAIL 读不到 {path} —— 判据无法成立，不算通过")
        sys.exit(1)
    with open(path, encoding="utf-8") as fh:
        return fh.read()

def strip_comments(text):
    """剥掉 // 行注释与 /* */ 块注释 —— 守卫扫的是代码，不是我自己写的说明。"""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("//"))

def ok(label, detail=""):
    print(f"PASS {label}{('（' + str(detail) + '）') if detail else ''}")

def bad(label, detail=""):
    global fail
    fail = 1
    print(f"FAIL {label}{('：' + str(detail)) if detail else ''}")

def call_spans(code, head):
    """返回每个 `head(` 调用的完整括号平衡文本。窗口式匹配会漏长调用 ⇒ 恒绿，所以做平衡配对。"""
    out = []
    for m in re.finditer(re.escape(head), code):
        i = code.index("(", m.start() + len(head) - 1) if code[m.end() - 1] == "(" else None
        if i is None:
            continue
        depth, j = 0, i
        while j < len(code):
            if code[j] == "(":
                depth += 1
            elif code[j] == ")":
                depth -= 1
                if depth == 0:
                    out.append(code[i:j + 1])
                    break
            j += 1
        else:
            bad("调用括号未闭合", head)
    return out

def func_body(code, head):
    """取 `head` 这个函数的整个函数体（大括号平衡配对）。
    窗口式截取会漏长函数 ⇒ 恒绿；取不到必须返回 None，由调用方报"判据失效"。"""
    i = code.find(head)
    if i < 0:
        return None
    j = code.find("{", i)
    if j < 0:
        return None
    depth, k = 0, j
    while k < len(code):
        if code[k] == "{":
            depth += 1
        elif code[k] == "}":
            depth -= 1
            if depth == 0:
                return code[j:k + 1]
        k += 1
    bad("函数体括号未闭合", head)
    return None

toast = strip_comments(read(os.path.join(src, "Views", "Shared", "Toast.swift")))
center = strip_comments(read(os.path.join(src, "Views", "Shared", "PendingDeletionCenter.swift")))
import_vm = strip_comments(read(os.path.join(src, "ViewModels", "ImportViewModel.swift")))
machine = os.path.join(core, "UndoGraceMachine.swift")

# UG-G01：ToastCenter.show 的参数表里不许再有 actionTitle（撤销条不许走普通提示通道）
# 参数表按括号平衡取，不用"到第一个 )" —— 默认值里出现括号就会提前截断，判据变恒绿。
sig_head = toast.find("func show(")
sig = None
if sig_head >= 0:
    i = toast.index("(", sig_head)
    depth, j = 0, i
    while j < len(toast):
        if toast[j] == "(":
            depth += 1
        elif toast[j] == ")":
            depth -= 1
            if depth == 0:
                sig = toast[i:j + 1]
                break
        j += 1
if not sig:
    bad("UG-G01 取不出 ToastCenter.show 的参数表", "判据失效")
elif "actionTitle" in sig or "action:" in sig:
    bad("UG-G01 ToastCenter.show 又带上了操作按钮参数")
else:
    ok("UG-G01 ToastCenter.show 只管瞬时提示，无 action 参数")

# UG-G02：ToastPayload 不许再携带 action 字段（呈现层不携带领域知识）
payload = re.search(r"struct ToastPayload.*?\n\}", toast, flags=re.S)
if not payload:
    bad("UG-G02 取不出 ToastPayload 定义", "判据失效")
elif re.search(r"\baction", payload.group(0)):
    bad("UG-G02 ToastPayload 又带上了 action 字段")
else:
    ok("UG-G02 ToastPayload 无 action 字段")

# UG-G03：全 MixCut/ 里任何 ToastCenter...show(...) 调用都不许传 actionTitle
hits = []
for root, dirs, files in os.walk(src):
    dirs[:] = [d for d in dirs if d != "bin"]        # 包内二进制不算源码
    for fn in files:
        if not fn.endswith(".swift"):
            continue
        p = os.path.join(root, fn)
        code = strip_comments(read(p))
        for head in ("ToastCenter.shared.show(", ".show("):
            for span in call_spans(code, head):
                if "actionTitle" in span:
                    hits.append(f"{os.path.relpath(p, src)}")
        # 只认 ToastCenter 的 show，别把别的 .show( 算进来
    # 逐文件已判定
if hits:
    bad("UG-G03 仍有调用点把撤销按钮交给 ToastCenter", "、".join(sorted(set(hits))))
else:
    ok("UG-G03 无任何 ToastCenter.show 调用传 actionTitle")

# UG-G04：撤销宽限期必须是 5 秒。这颗门钉的是「别被顺手改」，不是「5 秒永恒正确」——
# 档位本身 2026-10-03 拍回 5 秒（撤销条已搬进专用槽位 UndoSlot，「被普通提示顶掉」那半病因治好了，
# 时长就退回纯产品档位）。改这个数必须同批改这里的期望值 + selftest_undo_guards.sh 的 M4 变异方向。
g = re.search(r"static let graceSeconds:\s*Double\s*=\s*([0-9.]+)", center)
if not g:
    bad("UG-G04 取不出 PendingDeletionCenter.graceSeconds", "判据失效")
elif float(g.group(1)) != 5:
    bad("UG-G04 撤销宽限期不是 5 秒", g.group(1))
else:
    ok("UG-G04 撤销宽限期 = 5 秒")

# UG-G05：ToastOverlay 必须同时读两个槽（撤销槽绑 PendingDeletionCenter，提示槽绑 ToastCenter）
# 结构体到"顶格 }"才结束 —— 用 \n\s*} 会在第一个 if 的收尾处截断，把下面的槽漏掉。
overlay = re.search(r"struct ToastOverlay.*?\n\}", toast, flags=re.S)
if not overlay:
    bad("UG-G05 取不出 ToastOverlay 定义", "判据失效")
else:
    body = overlay.group(0)
    # 必须带词边界：写成 "toastCenter.current" 的话，`toastCenter.currentHidden` 也算命中 ⇒ 恒绿
    needs = [r"visibleTicket\b", r"toastCenter\.current\b"]
    missing = [p for p in needs if not re.search(p, body)]
    if missing:
        bad("UG-G05 ToastOverlay 少读了一个槽", "、".join(missing))
    else:
        ok("UG-G05 ToastOverlay 双槽并存（UndoSlot + NoticeSlot）")

# UG-G06：状态机必须是可见性的唯一来源 —— 中心只经 machine.isStripVisible 决定显示
if not os.path.isfile(machine):
    bad("UG-G06 状态机文件不存在", machine)
else:
    msrc = strip_comments(read(machine))
    # 同上：不带词边界时 `case armedButHidden` 会让这条恒绿
    if not re.search(r"\bcase armed\b", msrc) or "isStripVisible" not in msrc:
        bad("UG-G06 状态机缺 armed 相位或可见性判据")
    else:
        ok("UG-G06 armed 是浮条可见的唯一判据")
    if "isStripVisible" not in center:
        bad("UG-G07 中心没有把可见性交给状态机", "PendingDeletionCenter 里读不到 machine.isStripVisible")
    else:
        ok("UG-G07 浮条可见性只来自状态机")

# UG-G08：只要退出时还有未到点的宽限期 ⇒ "删完马上退程序"会把未真删的项留在库里，正常退出前必须 flushNow()
app = strip_comments(read(os.path.join(src, "App", "MixCutApp.swift")))
hook = app.find("willTerminateNotification")
tail = app[hook:hook + 400] if hook >= 0 else ""
if hook < 0 or "PendingDeletionCenter.shared.flushNow()" not in tail:
    bad("UG-G08 退出钩子缺失或没接 flushNow", "willTerminate 附近取不到收口调用")
else:
    ok("UG-G08 正常退出前收口 pending")

# UG-G09：真删义务落地后必须广播，且广播只由中心做（前案刀 2 的"谁删谁广播"不许散回各条链）
#   钉三处承重：① commit 闭包的**返回类型**是 GraphChange（台账由链交回，中心才知道该剪谁）；
#   ② 两处真删落地点（finish / settle）都走同一个 broadcast helper；③ helper 里空台账不发、
#   中心只有一处 GraphBroadcast.post（否则"不发"这条规则就有了第二份实现）。
sig_commit = re.search(r"commit:\s*@escaping\s*\(\)\s*->\s*GraphChange\b", center)
if not sig_commit:
    bad("UG-G09 schedule 的 commit 闭包不再交回 GraphChange", "台账没人生产，广播必然空转")
else:
    n_bcast = center.count("Self.broadcast(ifNeeded:")
    n_post = center.count("GraphBroadcast.post(")
    no_empty = re.search(r"guard\s*!change\.isEmpty\s*else\s*\{\s*return\s*\}", center)
    if n_bcast != 2:
        bad(f"UG-G09 广播点应为 2 处（finish + settle），实得 {n_bcast}", "少一处就是那条链真删后界面不认识")
    elif n_post != 1:
        bad(f"UG-G09 中心里 GraphBroadcast.post 应为 1 处，实得 {n_post}", "多一处=「空台账不发」就有了第二份实现")
    elif not no_empty:
        bad("UG-G09 空台账不发的规则被摘掉", "否则每条删除都会退化成无载荷全量重载（切页骨架闪烁回归）")
    else:
        ok("UG-G09 真删落地即由中心广播（2 点 1 post，空台账不发）")

# UG-G10：视频删除咽喉同一批**只可能登记一枚** ticket（方案 v3 批 2 预留的编号，提前落）
#   依据是实读的结构：PendingDeletionCenter 同一时刻只维护一枚 pending，`arm()` 登记新的一枚前会
#   先把上一枚 settle —— 而 settle 对 deletion 类就是**即刻真删**（PendingDeletionCenter.swift:79-95/134-138）。
#   所以"把批量删除实现成 `for v in videos { deleteVideo(v, …) }`"不是不够优雅，是数据丢失：
#   循环 20 次 = 前 19 次根本没有那 5 秒宽限期，且用户只看得见最后一枚浮条。
#   这条门把那个形状从"不推荐"变成"构造不出来"：调用点必须恰好 1 处。
n_sched = import_vm.count("PendingDeletionCenter.shared.schedule(")
if n_sched == 0:
    bad("UG-G10 取不出 PendingDeletionCenter.shared.schedule 的调用点",
        "判据失效：视频删除改走了别的登记方式，一枚 ticket 这条前提没人守（不是「通过」）")
elif n_sched != 1:
    bad(f"UG-G10 视频删除的 ticket 登记点应为 1 处，实得 {n_sched}",
        "多于 1 处＝同一文件里存在多条登记路径，批量时极易写成循环单删 ⇒ 前 N−1 条没有宽限期")
else:
    ok("UG-G10 视频删除咽喉只有一处 schedule（一批 = 一枚 ticket）")

# UG-G11：commit 里「先落盘、再判空、才连记录一起删」这个顺序不许被"优化"掉（批 2 预留编号）
#   为什么中间那次 safeSave 绝不能合并到循环外：隐藏只改了 `project.projectVideos` 那一侧，
#   pv 的反向数组要等**落盘后**才被 cascade 摘掉；合并 save 会让 `video.projectVideos.isEmpty`
#   恒 false ⇒ "无引用才连视频记录删"这条主判定永久失效，表现是"删了还在"（同 ModelContextExtension
#   里 ⑭ 格实测的那一条）。所以判据是两条：① 体内 safeSave() ≥ 2；② isEmpty 判定必须在第一次之后。
body = func_body(import_vm, "private func commitDelete")
if body is None:
    bad("UG-G11 取不出 commitDelete 函数体",
        "判据失效：咽喉换了函数名/形状，落盘顺序这条前提没人守（批 2 改名时要同批把锚点搬过去）")
else:
    n_save = body.count("safeSave()")
    p_guard = body.find("projectVideos.isEmpty")
    p_save = body.find("safeSave()")
    if n_save < 2:
        bad(f"UG-G11 commit 内的 safeSave() 应 ≥ 2 处，实得 {n_save}",
            "合并成一次 ⇒ projectVideos.isEmpty 恒 false ⇒ 视频记录永远删不掉（表现为「删了还在」）")
    elif p_guard < 0:
        bad("UG-G11 取不到 projectVideos.isEmpty 主判定", "判据失效：连记录删的判据被摘走")
    elif not (0 <= p_save < p_guard):
        bad("UG-G11 主判定没有排在第一次 safeSave 之后",
            "顺序错 = 判定读的是还没被 cascade 摘干净的反向数组，同「合并 save」一个后果")
    else:
        ok("UG-G11 先落盘再判空（2 次 save 且判定在第一次之后）", f"save={n_save}")

# UG-G13：视频删除咽喉的台账里不许出现 `.video`（方案 v3 批 2 预留的编号，G10/G11/G12 随各自批次落）
#   依据不是注释而是实读的 `UndoGraceMachine.swift:191-195`：`isPrunable` 对「带 .video 却不带 .project」
#   一律判不可剪枝 ⇒ 发布口按无载荷发 ⇒ 观察者走全量重载，而 `loadSegments` 首行是 `flushNow()`
#   （它会执行待删事务并再次广播 ⇒ 同栈递归，前案 §10 健壮-1 记为 P0）。
#   现状：`ImportViewModel.swift:824` 只 note `.segment`。**注释会被删，判据不会** —— 批 2 把咽喉数组化时
#   最省事的写法就是"顺手把视频 id 也记进台账"，这条门要在那一刻先红，而不是等真机上炸出来。
nd = call_spans(import_vm, "noteDeleted(")
if not nd:
    bad("UG-G13 取不出 noteDeleted 调用点", "判据失效：删除咽喉不再记台账，这条前提没人守")
elif any(".video" in span for span in nd):
    bad("UG-G13 台账里出现了 .video",
        "带 video 不带 project ⇒ isPrunable=false ⇒ 降级无载荷全量重载 ⇒ loadSegments 首行 flushNow 同栈递归")
else:
    ok("UG-G13 台账只记非 .video 实体（剪枝资格不被自己降级）", f"{len(nd)} 处调用点")

sys.exit(fail)
PY
rc=$?
if [ "$rc" -gt 1 ]; then
  echo "FAIL 守卫自身异常退出（rc=${rc}）—— 判据未跑完，不算通过"
  exit 1
fi
exit "$rc"
