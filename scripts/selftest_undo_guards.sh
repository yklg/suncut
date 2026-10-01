#!/usr/bin/env bash
# check_undo_guards.sh 的自证：在合成违规树上跑**同一判据**，必须逐条变红。
# 没跑过这一轮，就不能说那 8 条判据是防线 —— 恒绿的守卫比没有守卫更糟。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.scratch/undo_guard_selftest"
GUARD="$ROOT/scripts/check_undo_guards.sh"

rm -rf "$WORK"
fail=0

fresh() {
  local case_dir="$1"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/MixCut/Views/Shared" "$case_dir/MixCut/Views/SegmentLibrary" \
           "$case_dir/MixCut/App" "$case_dir/Sources/MixCutCore"
  cp "$ROOT/MixCut/Views/Shared/Toast.swift" "$case_dir/MixCut/Views/Shared/"
  cp "$ROOT/MixCut/Views/Shared/PendingDeletionCenter.swift" "$case_dir/MixCut/Views/Shared/"
  cp "$ROOT/MixCut/Views/SegmentLibrary/SegmentLibraryView.swift" "$case_dir/MixCut/Views/SegmentLibrary/"
  cp "$ROOT/MixCut/App/MixCutApp.swift" "$case_dir/MixCut/App/"
  cp "$ROOT/Sources/MixCutCore/UndoGraceMachine.swift" "$case_dir/Sources/MixCutCore/"
}

# mutate <file> <old> <new> —— 旧串必须存在，否则这次变异根本没落地，测的是空气
mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
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
mutate "$D/MixCut/Views/SegmentLibrary/SegmentLibraryView.swift" \
  'ToastCenter.shared.show("台词已更新", icon: "checkmark.circle.fill")' \
  'ToastCenter.shared.show("台词已更新", icon: "checkmark.circle.fill", actionTitle: "撤销")' \
  && check_case "M3 调用点把撤销按钮交回 ToastCenter" "UG-G03" "$D" "$WORK/m3.log"

D="$WORK/m4"; fresh "$D"
mutate "$D/MixCut/Views/Shared/PendingDeletionCenter.swift" \
  'static let graceSeconds: Double = 300' 'static let graceSeconds: Double = 5' \
  && check_case "M4 宽限期退回 5 秒" "UG-G04" "$D" "$WORK/m4.log"

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

echo
if [ "$fail" = "0" ]; then
  echo "全部自证通过：8 条判言逐条可被对应违规变红"
else
  echo "有自证未通过 —— 那几条判据不算防线"
fi
exit "$fail"
