#!/usr/bin/env bash
# App target 编译验收门禁 —— 守「MixCut/** 与 Sources/MixCutCore/** 全部源码在真实工具链下可编译」。
#
# 为什么需要这道门（架构根因，2026-10-05）：
# 本工程的验证面是刻意劈开的 —— SwiftPM（swift test）只覆盖 Sources/MixCutCore 纯逻辑库；
# MixCut/** 全部 app 侧源码只由 xcodebuild 编译。Agent 执行环境套在 sandbox-exec 里，
# 禁止拉起 swift-plugin-server（@Observable / @Model / #Predicate 等宏无法展开），所以 app 侧的
# 类型级错误（嵌套类型不存在、方法改名、漏挂 pbxproj、旧 API 重载被移除）一度没有任何机械手段
# 能在交付前发现，只能由用户在 xcodebuild 验收时撞上，且已反复发生。
#
# 突破（同日）：用 `-load-plugin-library` 直接在编译器进程内加载宏 dylib，绕过被沙盒禁掉的
# plugin-server —— 沙盒内因此可以执行与正式编译同口径的全量 -typecheck（含宏展开 + 跨文件类型），
# 不再只能做语法 parse。
#
#   ./scripts/check_app_build.sh             # 自动：真实终端跑 xcodebuild；沙盒跑 typecheck+silgen
#   MODE=typecheck ./scripts/check_app_build.sh  # 仅 WMO 类型检查（快；不覆盖 SILGen 期错误）
#   MODE=silgen ./scripts/check_app_build.sh # 仅 batch SILGen（函数体完整性；不含类型跨文件）
#   MODE=parse ./scripts/check_app_build.sh  # 强制仅语法级（最快，兜底）
#
# 判据语义：
# - xcodebuild 腿（非沙盒，整工程含链接/资源）：build 成功才绿，失败打印全部 error 行并保留日志；
# - silgen 腿（沙盒，与 xcodebuild 同编译阶段）：batch 模式（同 Xcode 的 -enable-batch-mode
#   + -primary-file 分组）跑到 SILGen —— 这是 xcodebuild `-c` 的最后一个纯语义阶段，
#   覆盖「missing return」等只在 SILGen 发射期才报的函数体完整性错误（实测 -typecheck
#   对这类错误只降级为 warning，曾导致 typecheck 假绿、xcodebuild 才红，2026-10-06）；
# - typecheck 腿（沙盒）：WMO 一次语义类型检查，覆盖宏展开与跨文件契约，
#   但不做函数体 SILGen/代码生成/链接/资源 —— 输出诚实标注这一范围，且不得单独作为绿灯依据；
# - parse 腿（typecheck 跑不起来时的降级）：只保证语法层，抓不到类型错误。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos14"
PLUGIN_DIR="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

SWIFT_FILES=()
# 不用 IFS= 前缀（bash 3.2 残留问题，见 run_typecheck）；本工程路径无空白。
while read -r f; do
  SWIFT_FILES+=("$f")
done < <(find "$ROOT/MixCut" "$ROOT/Sources/MixCutCore" -name '*.swift' -type f | sort)
echo "编译单元：${#SWIFT_FILES[@]} 个 swift 文件"

# 沙盒探测：尝试经 plugin-server 展开一个最小宏。sandbox-exec 拒绝 exec 时必然失败。
detect_sandbox() {
  local probe_dir
  probe_dir="$(mktemp -d)"
  cat > "$probe_dir/probe.swift" <<'EOF'
import Observation
@Observable
final class Probe { var x = 0 }
EOF
  if xcrun swiftc -typecheck -sdk "$SDK" -target "$TARGET" \
      "$probe_dir/probe.swift" >/dev/null 2>&1; then
    echo 0
  else
    echo 1
  fi
  rm -rf "$probe_dir"
}

# 宏 dylib（经 -load-plugin-library 在进程内加载，不需要 plugin-server）。
plugin_flags() {
  local flags=()
  for lib in libObservationMacros libSwiftDataMacros libFoundationMacros; do
    [ -f "$PLUGIN_DIR/$lib.dylib" ] && flags+=("-load-plugin-library" "$PLUGIN_DIR/$lib.dylib")
  done
  printf '%s\0' "${flags[@]}"
}

# 构造 @response file（路径安全）。
make_response() {
  local resp
  resp="$(mktemp -t mixcut-resp)"
  for f in "${SWIFT_FILES[@]}"; do printf '"%s"\n' "$f" >> "$resp"; done
  echo "$resp"
}

run_parse() {
  echo "[parse 腿] swiftc -parse 全量源码（语法级；不展开宏、不验证跨文件类型）"
  local errors
  errors="$(xcrun swiftc -parse -sdk "$SDK" -target "$TARGET" \
      "${SWIFT_FILES[@]}" 2>&1 | grep -E "error:" || true)"
  if [ -n "$errors" ]; then
    echo "$errors"
    echo "APP BUILD GATE [parse]: FAIL —— 存在语法错误，修复后重跑"
    return 1
  fi
  echo "APP BUILD GATE [parse]: PASS（仅语法层；不代表类型契约正确）"
}

run_typecheck() {
  echo "[typecheck 腿] 全量源码语义检查（宏经 -load-plugin-library 进程内展开；含跨文件类型）"
  local resp
  resp="$(make_response)"
  local flags=()
  # 不用 IFS= 前缀：bash 3.2 下 read 以非零退出（NUL 列表读完）时空 IFS 会残留，
  # 污染后面的 [ 内建（实测 missing ']'）；本处输入项无空白前缀，直接读即可。
  while read -r -d '' item; do flags+=("$item"); done < <(plugin_flags)
  if [ "${#flags[@]}" -lt 2 ]; then
    echo "宏 dylib 不可用（${PLUGIN_DIR}），typecheck 腿无法成立"
    rm -f "$resp"
    return 2
  fi

  local errors rc
  set +e
  errors="$(xcrun swiftc -typecheck -sdk "$SDK" -target "$TARGET" \
      "${flags[@]}" @"$resp" 2>&1 | grep -E "error:" || true)"
  rc=$?
  set -e
  rm -f "$resp"
  if [ -n "$errors" ]; then
    echo "$errors" | sort -u | head -40
    echo "APP BUILD GATE [typecheck]: FAIL —— 存在类型错误，修复后重跑"
    return 1
  fi
  echo "APP BUILD GATE [typecheck]: PASS（跨文件类型/宏层；SILGen 完整性由 silgen 腿负责）"
}

# 每批 primary 文件数（实测：8 个/批 ≈160s，16 个/批 ≈36s，32 个/批 ≈32s —— 16 为拐点）。
SILGEN_BATCH_SIZE="${SILGEN_BATCH_SIZE:-16}"

# SILGen 腿：按 Xcode batch 形态逐批把每个文件当 primary 跑到 SILGen（-emit-sil，
# 不做 LLVM/链接）。为什么必须有这条腿：
#   swift -typecheck 在 WMO 与 primary 两种形态下都不执行 SILGen，而
#   「missing return in function expected to return X」「某些 switch 不穷尽」等
#   函数体完整性诊断只在 SILGen 发射期产出 —— typecheck 只会给一条
#   "result unused" warning 就放行，xcodebuild -c 才报错。2026-10-06 实测漏报一次。
run_silgen() {
  echo "[silgen 腿] batch 模式逐文件 SILGen（${SILGEN_BATCH_SIZE} 个/批；与 xcodebuild -c 同阶段）"
  local flags=()
  while read -r -d '' item; do flags+=("$item"); done < <(plugin_flags)
  if [ "${#flags[@]}" -lt 2 ]; then
    echo "宏 dylib 不可用（${PLUGIN_DIR}），silgen 腿无法成立"
    return 2
  fi

  local list
  list="$(mktemp -t mixcut-filelist)"
  printf '%s\n' "${SWIFT_FILES[@]}" > "$list"
  local outdir
  outdir="$(mktemp -d -t mixcut-silgen)"

  local total="${#SWIFT_FILES[@]}"
  local batches=$(( (total + SILGEN_BATCH_SIZE - 1) / SILGEN_BATCH_SIZE ))
  local all_errors=""
  local b=0
  set +e
  for ((start = 0; start < total; start += SILGEN_BATCH_SIZE)); do
    b=$((b + 1))
    local p_args=()
    local end=$((start + SILGEN_BATCH_SIZE)); [ "$end" -gt "$total" ] && end=$total
    for ((i = start; i < end; i++)); do
      local f="${SWIFT_FILES[$i]}"
      # 每个 primary 一个 -o（batch 形态要求与 primary 一一对应；.sil 仅落临时目录）。
      p_args+=("-primary-file" "$f" "-o" "$outdir/$(basename "$f").sil")
    done
    local out
    # -module-name 显式给出：当最后一批只剩 1 个 primary 时，batch mode 会退化到从
    # 输出文件名推导 module 名（形如 "WhisperModelCatalog.swift"，含点号非法 → 编译失败）。
    # 该名只用于 SILGen 语法/函数体检查，不参与链接，与 app target 同名即可。
    out="$(xcrun swift-frontend -frontend -emit-sil -enable-batch-mode \
        -enable-objc-interop -sdk "$SDK" -target "$TARGET" -module-name MixCut \
        "${flags[@]}" -filelist "$list" "${p_args[@]}" 2>&1 | grep -E "error:" || true)"
    if [ -n "$out" ]; then
      all_errors="${all_errors}${out}"$'\n'
    fi
    if [ $((b % 5)) -eq 0 ] || [ "$b" -eq "$batches" ]; then
      echo "    silgen 批次 $b/$batches"
    fi
  done
  set -e
  rm -rf "$outdir" "$list"

  if [ -n "$all_errors" ]; then
    echo "$all_errors" | sort -u | head -40
    echo "APP BUILD GATE [silgen]: FAIL —— 存在 SILGen 期错误（typecheck 抓不到的一类，如 missing return），修复后重跑"
    return 1
  fi
  echo "APP BUILD GATE [silgen]: PASS（函数体完整性；与 xcodebuild -c 同阶段，不含代码生成/链接/资源）"
}

run_xcodebuild() {
  echo "[xcodebuild 腿] 全工程编译（权威；含链接/资源；增量构建）"
  local log rc
  log="$(mktemp -t mixcut-appbuild).log"
  set +e
  # ⚠️ 先按 scheme 跑。**scheme 可能不存在或写坏**（本工程原先靠 Xcode 自动生成的
  # managed scheme，见 M2 test target 计划；一旦改为显式 shared scheme，它就成了单点故障）。
  # ⇒ 失败且日志显示是 scheme 问题时，**自动回退到 -target**（带 target 的 build 不依赖 scheme）。
  # 这样守卫不会被「一个文件写错」整体拖垮。
  xcodebuild -project "$ROOT/MixCut.xcodeproj" -scheme MixCut build >"$log" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # 判据：scheme 层面的问题才回退。**必须用实测到的确切文案**，不能猜：
    # 实测（注入坏 scheme 后 xcodebuild 的真实输出）：
    #   "xcodebuild: error: Scheme MixCut is not currently configured for the build action."
    #   "xcodebuild: error: Unable to find a scheme named ..."
    #   "xcodebuild: error: The workspace does not contain a scheme ..."
    # ⚠️ 不对「编译错误」回退 —— 那样真实错误会被二次尝试掩盖，只会让排查变慢。
    if grep -Eqi "not currently configured for the build action|unable to find a scheme|does not contain a scheme|could not find scheme|scheme .*not found" "$log"; then
      echo "[xcodebuild 腿] scheme 不可用，回退到 -target MixCut（不依赖 scheme）"
      local log2
      log2="$(mktemp -t mixcut-appbuild-target).log"
      set +e
      xcodebuild -project "$ROOT/MixCut.xcodeproj" -target MixCut build >"$log2" 2>&1
      rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        grep -E "error:|The following build commands failed" "$log2" | head -40 || true
        echo "APP BUILD GATE [xcodebuild]: FAIL（已回退到 -target）—— 完整日志：$log2"
        return 1
      fi
      rm -f "$log2"
      echo "APP BUILD GATE [xcodebuild]: PASS（-target 回退路径）"
      rm -f "$log"
      return 0
    fi
    grep -E "error:|The following build commands failed" "$log" | head -40 || true
    echo "APP BUILD GATE [xcodebuild]: FAIL —— 完整日志：$log"
    return 1
  fi
  rm -f "$log"
  echo "APP BUILD GATE [xcodebuild]: PASS"
}

MODE="${MODE:-auto}"
case "$MODE" in
  parse)     run_parse ;;
  typecheck) run_typecheck ;;
  silgen)    run_silgen ;;
  xcodebuild) run_xcodebuild ;;
  auto)
    if [ "$(detect_sandbox)" = "1" ]; then
      echo "检测到沙盒环境（plugin-server 被禁）：typecheck + silgen 两腿。"
      set +e
      run_typecheck
      rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        if [ "$rc" = "2" ]; then run_parse; else exit "$rc"; fi
      else
        # typecheck 绿不等于可编译：SILGen 期错误（missing return 等）必须另跑此腿。
        run_silgen
      fi
    else
      run_xcodebuild
    fi
    ;;
  *) echo "未知 MODE=${MODE}（可用：auto/typecheck/silgen/parse/xcodebuild）"; exit 2 ;;
esac
