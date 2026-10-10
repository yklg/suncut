#!/usr/bin/env bash
# check_undo_guards.sh 的自证：在合成违规树上跑**同一判据**，必须逐条变红。
# 没跑过这一轮，就不能说那些判据是防线 —— 恒绿的守卫比没有守卫更糟。
# ⚠️ 条数不再手写（原先硬编码「9 条判言」，加一颗门就得记得改文案 —— 忘了就是自证与守卫脱钩，
#    正是本脚本自己写的「判据缺席比判据变红危险」）。现在由 check_case 成功一次计一次，末尾报实得数。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.scratch/undo_guard_selftest"
GUARD="$ROOT/scripts/check_undo_guards.sh"

rm -rf "$WORK"
fail=0
teeth=0

fresh() {
  local case_dir="$1"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/MixCut/Views/Shared" "$case_dir/MixCut/Views/SegmentLibrary" \
           "$case_dir/MixCut/App" "$case_dir/MixCut/ViewModels" "$case_dir/Sources/MixCutCore"
  cp "$ROOT/MixCut/Views/Shared/Toast.swift" "$case_dir/MixCut/Views/Shared/"
  cp "$ROOT/MixCut/Views/Shared/PendingDeletionCenter.swift" "$case_dir/MixCut/Views/Shared/"
  cp "$ROOT/MixCut/Views/SegmentLibrary/SegmentLibraryView.swift" "$case_dir/MixCut/Views/SegmentLibrary/"
  cp "$ROOT/MixCut/App/MixCutApp.swift" "$case_dir/MixCut/App/"
  cp "$ROOT/MixCut/ViewModels/ImportViewModel.swift" "$case_dir/MixCut/ViewModels/"
  cp "$ROOT/Sources/MixCutCore/UndoGraceMachine.swift" "$case_dir/Sources/MixCutCore/"
}

# mutate <file> <old> <new> —— 旧串必须存在且唯一，否则这次变异根本没落地，测的是空气。
# ⚠️ 未落地/有歧义必须自己登记成失败：调用形状是 `mutate … && check_case …`，
#    短路会让那条腿一声不响地没跑而脚本仍 rc=0（M3 就被这样静默吞过一轮 —— 靶文案在
#    `a06361d` 改名后原串已不存在）。判据缺席比判据变红危险。
# ⚠️ 别写成 `local rc` 再 `rc=$?`：`local` 自己返回 0 会把上一条命令的退出码抹掉
#    （探针实测过一次 —— 变异失败却当成成功往下跑，check_case 在没改过的副本上测空气）。
mutate() {
  if python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding="utf-8").read()
if old not in s:
    print(f"  变异未落地：{path} 里取不到 {old!r}")
    sys.exit(3)
if s.count(old) > 1:
    print(f"  变异有歧义：{old!r} 命中 {s.count(old)} 处")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(s.replace(old, new))
PY
  then
    return 0
  fi
  fail=1
  echo "  判据失效：本条变异没落地 ⇒ 这条腿根本没跑，不许算通过"
  return 3
}

run_guard() {
  SRC_DIR="$1/MixCut" CORE_DIR="$1/Sources/MixCutCore" LC_ALL=en_US.UTF-8 bash "$GUARD" >"$2" 2>&1
  echo "$?"
}

check_case() {
  local label="$1" expect="$2" case_dir="$3" log="$4"
  local rc
  rc="$(run_guard "$case_dir" "$log")"
  if [ "$rc" = "1" ] && grep -q "FAIL ${expect}" "$log"; then
    teeth=$((teeth + 1))
    echo "PASS ${label} → ${expect} 变红"
  else
    echo "FAIL ${label} 未把 ${expect} 判红（rc=${rc}）"
    tail -8 "$log" | sed 's/^/      /'
    fail=1
  fi
}

# 先证基线：干净副本必须全绿，否则"变红"说明不了任何事
CLEAN="$WORK/clean"
fresh "$CLEAN"
rc="$(run_guard "$CLEAN" "$WORK/clean.log")"
if [ "$rc" != "0" ]; then
  echo "FAIL 基线不干净（rc=${rc}）—— 变异结论全部作废"
  cat "$WORK/clean.log"
  exit 1
fi
echo "PASS 基线：未改动的副本全绿（$(grep -c '^PASS' "$WORK/clean.log") 条）"

D="$WORK/m1"; fresh "$D"
mutate "$D/MixCut/Views/Shared/Toast.swift" 'duration: Double = 2.2)' 'duration: Double = 2.2, actionTitle: String? = nil)' \
  && check_case "M1 show 参数表塞回 actionTitle" "UG-G01" "$D" "$WORK/m1.log"

D="$WORK/m2"; fresh "$D"
mutate "$D/MixCut/Views/Shared/Toast.swift" '    let style: InlineBanner.Style
}' '    let style: InlineBanner.Style
    let action: (() -> Void)?
}' \
  && check_case "M2 ToastPayload 塞回 action 字段" "UG-G02" "$D" "$WORK/m2.log"

D="$WORK/m3"; fresh "$D"
# 靶必须是**现在还活着**的调用点：旧靶「台词已更新」那句文案已在 a06361d 改名，
# 那条腿因此静默空转过一轮（现在 mutate 会把这种空转判成失败，不会再混过 rc=0）。
mutate "$D/MixCut/Views/SegmentLibrary/SegmentLibraryView.swift" \
  'ToastCenter.shared.show("自定义方案已生成", icon: "checkmark.circle.fill", style: .success)' \
  'ToastCenter.shared.show("自定义方案已生成", icon: "checkmark.circle.fill", style: .success, actionTitle: "撤销")' \
  && check_case "M3 调用点把撤销按钮交回 ToastCenter" "UG-G03" "$D" "$WORK/m3.log"

D="$WORK/m4"; fresh "$D"
mutate "$D/MixCut/Views/Shared/PendingDeletionCenter.swift" \
  'static let graceSeconds: Double = 5' 'static let graceSeconds: Double = 300' \
  && check_case "M4 宽限期被顺手改回 300 秒（档位漂移）" "UG-G04" "$D" "$WORK/m4.log"

D="$WORK/m5"; fresh "$D"
mutate "$D/MixCut/Views/Shared/Toast.swift" 'if let payload = toastCenter.current {' 'if let payload = toastCenter.currentHidden {' \
  && check_case "M5 提示槽被摘掉（退回单槽）" "UG-G05" "$D" "$WORK/m5.log"

D="$WORK/m6"; fresh "$D"
mutate "$D/Sources/MixCutCore/UndoGraceMachine.swift" '    case armed' '    case armedButHidden' \
  && check_case "M6 状态机丢了 armed 判据" "UG-G06" "$D" "$WORK/m6.log"

D="$WORK/m7"; fresh "$D"
mutate "$D/MixCut/Views/Shared/PendingDeletionCenter.swift" \
  'if machine.isStripVisible {' 'if visibleTicket != nil {' \
  && check_case "M7 可见性不再来自状态机" "UG-G07" "$D" "$WORK/m7.log"

D="$WORK/m8"; fresh "$D"
mutate "$D/MixCut/App/MixCutApp.swift" \
  'forName: NSApplication.willTerminateNotification,' 'forName: NSApplication.didBecomeActiveNotification,' \
  && check_case "M8 退出钩子被摘掉" "UG-G08" "$D" "$WORK/m8.log"

D="$WORK/m9"; fresh "$D"
# 把 commit 闭包的返回类型退回 `() -> Void`：链不再交台账 ⇒ 中心的广播永远空转
mutate "$D/MixCut/Views/Shared/PendingDeletionCenter.swift" \
  'commit: @escaping () -> GraphChange' 'commit: @escaping () -> Void' \
  && check_case "M9 删除链不再交回被删 id 台账" "UG-G09" "$D" "$WORK/m9.log"

D="$WORK/m10"; fresh "$D"
# 批 2 最省事的那个写法：视频 id 也顺手记进台账。isPrunable 会因此整条降级 ⇒ 这条门必须先咬。
mutate "$D/MixCut/ViewModels/ImportViewModel.swift" \
  'change.noteDeleted(Set(segmentsToDelete.map(\.id)), of: .segment)' \
  $'change.noteDeleted(Set(segmentsToDelete.map(\\.id)), of: .segment)\n        change.noteDeleted([video.id], of: .video)' \
  && check_case "M10 台账里加回 .video（带 video 不带 project 的形状）" "UG-G13" "$D" "$WORK/m10.log"

D="$WORK/m11"; fresh "$D"
# 批量删除被实现成"再走一遍单删"⇒ 同一文件里出现第二条登记路径，前 N−1 条没有宽限期
mutate "$D/MixCut/ViewModels/ImportViewModel.swift" \
  'PendingDeletionCenter.shared.schedule(' \
  $'PendingDeletionCenter.shared.schedule(\n            message: "探针：第二条登记路径",\n            commit: { GraphChange() },\n            undo: {}\n        )\n        PendingDeletionCenter.shared.schedule(' \
  && check_case "M11 多出一枚 ticket 的登记点（循环单删的形状）" "UG-G10" "$D" "$WORK/m11.log"

D="$WORK/m12"; fresh "$D"
# 反向刀：把那唯一一处摘光 ⇒ 必须报"判据失效"，不许把 0 当成"通过"
mutate "$D/MixCut/ViewModels/ImportViewModel.swift" \
  'PendingDeletionCenter.shared.schedule(' \
  'ProbeRenamedAway.schedule(' \
  && check_case "M12 登记点被摘走 ⇒ 报判据失效而不是静默放行" "UG-G10" "$D" "$WORK/m12.log"

D="$WORK/m13"; fresh "$D"
# 把中间那次落盘"优化"掉：合并 save 会让 projectVideos.isEmpty 恒 false ⇒ 视频记录删不掉
mutate "$D/MixCut/ViewModels/ImportViewModel.swift" \
  $'for pv in pendingPVs { context.delete(pv) }\n        context.safeSave()' \
  'for pv in pendingPVs { context.delete(pv) }' \
  && check_case "M13 中间那次 safeSave 被合并掉" "UG-G11" "$D" "$WORK/m13.log"

D="$WORK/m14"; fresh "$D"
# 顺序刀：主判定挪到第一次落盘**之前** —— 次数还是 2，读到的却是还没被 cascade 摘干净的反向数组
mutate "$D/MixCut/ViewModels/ImportViewModel.swift" \
  $'for pv in pendingPVs { context.delete(pv) }\n        context.safeSave()' \
  $'guard video.projectVideos.isEmpty else { return (false, GraphChange()) }\n        for pv in pendingPVs { context.delete(pv) }\n        context.safeSave()' \
  && check_case "M14 主判定排在第一次 safeSave 之前（次数没变、顺序变了）" "UG-G11" "$D" "$WORK/m14.log"

echo
if [ "$fail" = "0" ]; then
  echo "全部自证通过：实得 ${teeth} 条判言逐条可被对应违规变红（条数由自证自己数，不手写）"
else
  echo "有自证未通过（变红的只有 ${teeth} 条）—— 未变红的那几条判据不算防线"
fi
exit "$fail"
