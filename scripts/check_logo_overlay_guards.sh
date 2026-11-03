#!/usr/bin/env bash
# LogoOverlay 结构守卫：
#   G-LO-01 Project.logoOverlayRaw 只能由 ProjectViewModel.setProjectLogoOverlay 写；
#   G-LO-02 全仓禁止 BrandOverlay 命名（Brand 是 App 自身 SunCut 身份，不能混用）。
# 用法：bash scripts/check_logo_overlay_guards.sh
# 自证：SRC_DIR=<违规树> bash scripts/check_logo_overlay_guards.sh 必须变红。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC_DIR:-${ROOT}/MixCut}"
CORE="${CORE_DIR:-${ROOT}/Sources/MixCutCore}"
fail=0

ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

if [ ! -d "${SRC}" ]; then
  bad "取样面不存在：${SRC} —— 判据无法成立"
  exit 1
fi

# G-LO-01：只允许 ProjectViewModel 的 setter 写这个字段
writes=$(grep -rn "logoOverlayRaw[[:space:]]*=" "${SRC}" "${CORE}" --include="*.swift" 2>/dev/null \
  | grep -v "/Models/Project.swift:" \
  | grep -v "/ViewModels/ProjectViewModel.swift:" || true)
if [ -n "${writes}" ]; then
  bad "G-LO-01 logoOverlayRaw 出现直写："
  printf '%s\n' "${writes}"
else
  ok "G-LO-01 logoOverlayRaw 单写点（ProjectViewModel.setProjectLogoOverlay）"
fi

# G-LO-02：禁止 BrandOverlay 命名
legacy=$(grep -rn "BrandOverlay" "${SRC}" "${CORE}" "${ROOT}/MixCutAppTests" "${ROOT}/Tests" \
  --include="*.swift" 2>/dev/null || true)
if [ -n "${legacy}" ]; then
  bad "G-LO-02 仍存在 BrandOverlay 命名（必须用 LogoOverlay）："
  printf '%s\n' "${legacy}"
else
  ok "G-LO-02 无 BrandOverlay 命名"
fi

# 单写点函数必须真的存在，防止守卫只靠"没搜到"
if grep -q "func setProjectLogoOverlay" "${SRC}/ViewModels/ProjectViewModel.swift"; then
  ok "G-LO-01b 收口函数存在"
else
  bad "G-LO-01b 找不到 setProjectLogoOverlay 收口函数"
fi

if [ "${fail}" -ne 0 ]; then
  echo "LOGO OVERLAY GUARD: FAIL"
  exit 1
fi
echo "LOGO OVERLAY GUARD: PASS"
