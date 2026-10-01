#!/usr/bin/env bash
# 批 1 · 1.3-A 撤销事务守卫：防"撤销条又退回普通提示的单槽"。
# 计划出处：.scratch/preview-1.3-scope.md §A
#
# 为什么要有这条：A 方案的全部收益挂在一个不变量上 ——
#   **撤销浮条的可见性只来自 PendingDeletionCenter（状态机 armed），不经过 ToastCenter。**
# 一旦有人图省事把 `actionTitle` 加回 `ToastCenter.show`，撤销条就又会被任意一条 2.2 秒提示顶掉，
# 而 5 分钟的宽限期在界面上仍然是"看起来有 5 分钟"的装饰 —— 正是本轮审查判为表面修补的那个形状。
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

toast = strip_comments(read(os.path.join(src, "Views", "Shared", "Toast.swift")))
center = strip_comments(read(os.path.join(src, "Views", "Shared", "PendingDeletionCenter.swift")))
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

# UG-G04：宽限期必须是 300（槽位语义已按"撤销条常驻"设计，改回 5 就是半吊子状态）
g = re.search(r"static let graceSeconds:\s*Double\s*=\s*([0-9.]+)", center)
if not g:
    bad("UG-G04 取不出 PendingDeletionCenter.graceSeconds", "判据失效")
elif float(g.group(1)) != 300:
    bad("UG-G04 撤销宽限期不是 300 秒", g.group(1))
else:
    ok("UG-G04 撤销宽限期 = 300 秒")

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

# UG-G08：宽限期 300 秒 ⇒ "删完马上退程序"会把未真删的项留在库里，正常退出前必须 flushNow()
app = strip_comments(read(os.path.join(src, "App", "MixCutApp.swift")))
hook = app.find("willTerminateNotification")
tail = app[hook:hook + 400] if hook >= 0 else ""
if hook < 0 or "PendingDeletionCenter.shared.flushNow()" not in tail:
    bad("UG-G08 退出钩子缺失或没接 flushNow", "willTerminate 附近取不到收口调用")
else:
    ok("UG-G08 正常退出前收口 pending")

sys.exit(fail)
PY
rc=$?
if [ "$rc" -gt 1 ]; then
  echo "FAIL 守卫自身异常退出（rc=${rc}）—— 判据未跑完，不算通过"
  exit 1
fi
exit "$rc"
