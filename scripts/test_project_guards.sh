#!/usr/bin/env bash
# 残留清除与生成器守卫的自检（计划 2026-09-28-strip-original-author-identity §8 TC-03/05/06/07）
# TC-03/07 用 .scratch 里的隔离副本探测，绝不在仓库根直接跑 generate_xcodeproj.py，
# 并在探测前后比对真实 pbxproj 的校验和 —— 万一守卫漏了，也能立刻发现工程有没有被改写。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBX="$ROOT/MixCut.xcodeproj/project.pbxproj"
PROBE="$ROOT/.scratch/guard_probe"
fail=0

expect_absent() {
  local label="$1" pattern="$2" path="$3" want="$4"
  local got
  # grep 无命中时退出码为 1，会让 set -e 在断言之前静默中止 —— 这里显式吞掉它，把判定交给计数
  got=$( { grep -rc "$pattern" "$path" 2>/dev/null || true; } | awk -F: '{s+=$2} END{print s+0}')
  if [ "$got" = "$want" ]; then
    echo "PASS $label（命中 $got，期望 $want）"
  else
    echo "FAIL $label（命中 $got，期望 $want）"
    grep -rn "$pattern" "$path" 2>/dev/null | head -5
    fail=1
  fi
}

# TC-06：原作者身份字样必须整棵 App 源码树归零
expect_absent "TC-06 原作者署名/仓库字样" 'MengGang\|13462890087\|RoshanGH\|jinxiushanhehao' "$ROOT/MixCut" 0
# TC-06b：更新检查组件不得再被任何地方引用
expect_absent "TC-06b UpdateChecker/UpdateBanner 引用" 'UpdateChecker\|UpdateBanner\|updateChecker' "$ROOT/MixCut" 0
# TC-05：悬空承诺文案归零；日志路径字面量已收进 Brand.swift，MixCut/ 里只允许引用真源
# 期望值从 Brand.swift 现场读出，不写死字面量：将来换品牌，这条判据跟着变口径而不是悄悄恒真。
BRAND_SWIFT="$ROOT/Sources/MixCutCore/Brand.swift"
BUNDLE_ID=$(sed -n 's/.*static let bundleID = "\(.*\)".*/\1/p' "$BRAND_SWIFT")
if [ -z "$BUNDLE_ID" ]; then
  echo "FAIL 取不出 Brand.bundleID —— 判据失效，不算通过"
  fail=1
fi
expect_absent "TC-05 「导出诊断日志」悬空文案" '导出诊断日志' "$ROOT/MixCut" 0
expect_absent "TC-05 日志路径字面量残留处数" "$BUNDLE_ID/logs" "$ROOT/MixCut" 0
expect_absent "TC-05 日志目录真源引用处数" 'Brand\.logDirectoryComponent' "$ROOT/MixCut" 1
# TC-05b：用户文案必须各自引用真源（数 MixLog.logFileURL 的限定用法，不是数总行数）
# 基线 3 → 4：2026-09-28 第 2 期给 AIProviderError 的三条完整性文案共用了一处 evidenceHint
# （见 AIProvider.swift 的 evidenceHint，故意合并成 1 处而不是各写一遍）。新增的是 1 处真源引用，
# 不是放宽 —— 若将来有人再散着写路径，这里会变红。
expect_absent "TC-05b 文案引用 MixLog.logFileURL 处数" 'MixLog\.logFileURL' "$ROOT/MixCut" 4

# TC-03/07：生成器守卫探测
rm -rf "$PROBE"; mkdir -p "$PROBE/Sources/MixCutCore"
cp "$ROOT/generate_xcodeproj.py" "$PROBE/"
printf '// probe\n' > "$PROBE/Sources/MixCutCore/Probe.swift"
before=$(shasum -a 256 "$PBX" | awk '{print $1}')

set +e
out=$(python3 "$PROBE/generate_xcodeproj.py" 2>&1); rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "拒绝运行"; then
  echo "PASS TC-03 生成器被守卫拦下（退出码 $rc，含拒绝原因与正确做法）"
else
  echo "FAIL TC-03 生成器未被拦下（退出码 $rc）—— 工程有被生成器改坏的风险"
  printf '%s\n' "$out" | head -5
  fail=1
fi

set +e
out=$(python3 "$PROBE/generate_xcodeproj.py" --force 2>&1); rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "PASS TC-07 无旁路：--force 仍被拦下（退出码 $rc）"
else
  echo "FAIL TC-07 存在旁路：--force 绕过了守卫"
  fail=1
fi

if [ -e "$PROBE/MixCut.xcodeproj" ]; then
  echo "FAIL 探测目录里生成了工程文件，说明守卫没在写入前退出"
  fail=1
fi
after=$(shasum -a 256 "$PBX" | awk '{print $1}')
if [ "$before" = "$after" ]; then
  echo "PASS 探测全程未触碰仓库真实 pbxproj"
else
  echo "FAIL 探测改写了真实 pbxproj（校验和变化）"
  fail=1
fi

rm -rf "$PROBE"
exit "$fail"
