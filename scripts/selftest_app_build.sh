#!/usr/bin/env bash
# check_app_build.sh 的自检腿 —— 自证这道门禁不是恒绿伪装：
# 1. 当前工作树在 typecheck 腿下必须 PASS（含宏展开、跨文件类型）；
# 2. 构造语法损坏文件，parse 机制必须判红；
# 3. 构造「语法正确但类型错误」文件：parse 必须判绿、typecheck 必须判红
#    —— 证明 typecheck 腿真实承重，比 parse 多守住一层；
# 4. 构造「语法/类型都正确但函数体缺 return」文件：parse/typecheck 都判绿、
#    SILGen（-emit-sil）必须判红 —— 证明 silgen 腿真实承重。
#    背景：missing-return 是 SILGen 发射期诊断，-typecheck 只给 unused-result warning
#    放行，曾导致 typecheck 假绿、xcodebuild 才红（2026-10-06 实测）。
# 用法：./scripts/selftest_app_build.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos14"
PLUGIN_DIR="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[1/4] 当前工作树 typecheck 腿应判绿"
MODE=typecheck "$ROOT/scripts/check_app_build.sh"

echo "[2/4] 语法损坏文件必须被 parse 判红"
cat > "$TMP/broken.swift" <<'EOF'
struct Broken { let x
EOF
set +e
xcrun swiftc -parse -sdk "$SDK" -target "$TARGET" "$TMP/broken.swift" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "SELFTEST FAIL：语法损坏文件未被识别 —— 门禁是假的"
  exit 1
fi

echo "[3/4] 语法正确但类型错误：parse 判绿、typecheck 必须判红"
cat > "$TMP/typebad.swift" <<'EOF'
struct TypeBad { let x: Int = "not an int" }
EOF
xcrun swiftc -parse -sdk "$SDK" -target "$TARGET" "$TMP/typebad.swift" >/dev/null 2>&1 \
  || { echo "SELFTEST FAIL：该样本 parse 阶段就该通过"; exit 1; }

set +e
xcrun swiftc -typecheck -sdk "$SDK" -target "$TARGET" "$TMP/typebad.swift" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "SELFTEST FAIL：类型错误未被 typecheck 抓住 —— typecheck 腿是假的"
  exit 1
fi

echo "[4/4] 缺 return：parse/typecheck 判绿、SILGen 必须判红（防 typecheck 假绿灯复发）"
cat > "$TMP/silbad.swift" <<'EOF'
func silBad() -> Int {
    let x = 1
    x
}
EOF
xcrun swiftc -parse -sdk "$SDK" -target "$TARGET" "$TMP/silbad.swift" >/dev/null 2>&1 \
  || { echo "SELFTEST FAIL：该样本 parse 阶段就该通过"; exit 1; }
xcrun swiftc -typecheck -sdk "$SDK" -target "$TARGET" "$TMP/silbad.swift" >/dev/null 2>&1 \
  || { echo "SELFTEST FAIL：该样本 typecheck 阶段就该通过（只应有 warning）"; exit 1; }

set +e
xcrun swift-frontend -frontend -emit-sil -sdk "$SDK" -target "$TARGET" \
  -primary-file "$TMP/silbad.swift" "$TMP/silbad.swift" -o "$TMP/out.sil" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "SELFTEST FAIL：missing-return 未被 SILGen 抓住 —— silgen 腿是假的，xcodebuild 会在交付后才红"
  exit 1
fi

# 门禁自身在好树上的 silgen 腿也必须绿（确认真实工程的 batch 循环跑得通，不只是样本）。
MODE=silgen "$ROOT/scripts/check_app_build.sh"

echo "SELFTEST APP BUILD GATE: PASS（好树判绿、语法坏判红、类型坏判红、缺return silgen 判红，判据有效）"
