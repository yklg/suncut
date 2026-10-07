#!/usr/bin/env bash
# check_script_pipeline_guards.sh 的自证：在合成违规树上跑**同一判据**，必须变红。
# 判据不会红的守卫 = 假防线（本项目守卫纪律）。
#
# ① 干净探针树必须全绿（防止"红"只是文件没拷到的假数字）；
# ② 注入探针树必须 FAIL（至少一条变红），退出码非 0。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_ROOT="$ROOT/.scratch/script-guard-probe"
CLEAN="$PROBE_ROOT/clean"
DIRTY="$PROBE_ROOT/dirty"

CORE_FILES=(ScriptGroundingGate ScriptMatchRepair DubOnlyExportPolicy ScriptTextExporter
            SegmentGridPicker SchemeFocus SchemeSelection
            VoiceChoice ScriptDubBinding
            VoiceCatalogFilter DubVariantSelector
            RawAudioCache)
APP_FILES=(Services/Export/DubExportService.swift
           Services/Script/MaterializationService.swift
           ViewModels/ScriptWizardViewModel.swift
           ViewModels/SchemeViewModel.swift
           ViewModels/ProjectViewModel.swift
           ViewModels/DubbingViewModel.swift
           Services/MCP/MCPSegmentToolHandlers.swift
           Utilities/VoicePreferences.swift
           App/DebugSelfTest.swift
           Views/Script/ScriptWizardView.swift
           Views/Schemes/SegmentGridPickerSheet.swift
           Views/Shared/VoicePickerSheet.swift
           Views/Schemes/SchemeDetailView.swift
           Views/SegmentLibrary/DubSettingsBar.swift
           Views/Settings/SettingsView.swift
           Models/Video.swift
           Models/SchemeSegment.swift
           Models/SegmentDub.swift
           Services/TTS/VoiceAuditionPlayer.swift
           Services/TTS/RawAudioCacheStore.swift
           Views/Export/ExportView.swift)
TEST_FILES=(PastedScriptLinesTests AudioTrackPolicyTests ScriptTextExporterTests
            SegmentGridPickerTests SchemeSelectionTests
            VoiceCatalogFilterTests DubVariantSelectorTests
            RawAudioCacheTests)

build_tree() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest/Sources/MixCutCore" "$dest/Tests/MixCutCoreTests"
  for f in "${CORE_FILES[@]}"; do
    cp "$ROOT/Sources/MixCutCore/$f.swift" "$dest/Sources/MixCutCore/"
  done
  for f in "${TEST_FILES[@]}"; do
    cp "$ROOT/Tests/MixCutCoreTests/$f.swift" "$dest/Tests/MixCutCoreTests/"
  done
  for f in "${APP_FILES[@]}"; do
    mkdir -p "$dest/MixCut/$(dirname "$f")"
    cp "$ROOT/MixCut/$f" "$dest/MixCut/$f"
  done
  # G-V7⑤ 需要 pbxproj 锚点：守卫只 grep VoicePickerSheet 登记计数，
  # pbxproj 引用的其它文件在探针树缺失不影响该判据。
  mkdir -p "$dest/MixCut.xcodeproj"
  cp "$ROOT/MixCut.xcodeproj/project.pbxproj" "$dest/MixCut.xcodeproj/project.pbxproj"
}

run_guards() { ROOT_OVERRIDE="$1" "$ROOT/scripts/check_script_pipeline_guards.sh" >/dev/null 2>&1; }

# ① 干净树全绿
build_tree "$CLEAN"
if run_guards "$CLEAN"; then
  echo "PASS 干净探针树全绿"
else
  echo "FAIL 干净探针树应当全绿（判据或文件清单有问题）"
  ROOT_OVERRIDE="$CLEAN" "$ROOT/scripts/check_script_pipeline_guards.sh" 2>&1 | grep -E '^FAIL' || echo "  （守卫无 FAIL 行，但退出码非 0 —— 判据自身崩了）"
  exit 1
fi

# ② 变异树：每个 Core/App 关键文件注入违规，判据必须至少红一条。
build_tree "$DIRTY"

# G-S1：导出层冒出业务模式词（禁止按业务模式分叉）
cat >> "$DIRTY/MixCut/Services/Export/DubExportService.swift" <<'EOF'
let probeS1 = "productScript export branch"
EOF

# G-S2：物化终检绕过方向门（无条件 grounding = 逆向文案被永久拦截）
cat >> "$DIRTY/MixCut/Services/Script/MaterializationService.swift" <<'EOF'
// probe: unconditional grounding regardless of direction
func probeS2() { _ = GroundingChecker.check(text: "99元", sources: []) }
EOF

# G-S3：调用方退回静默跳过（guard let + continue）
python3 - "$DIRTY/MixCut/Views/Export/ExportView.swift" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("let input = try DubExportInput.from(scheme: scheme, combo: combo.choices,\n                                                                useVocalsOnly: globalBGM != nil)",
              "guard let input = DubExportInput.from(scheme: scheme, combo: combo.choices,\n                                                              useVocalsOnly: globalBGM != nil) else { continue }")
open(p, "w", encoding="utf-8").write(s)
PY

# G-S4：删掉向导 VM 的广播订阅 + Task hop（真删回退失效）
python3 - "$DIRTY/MixCut/ViewModels/ScriptWizardViewModel.swift" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("name: .mixCutDataDidUndo", "name: .mixCutNavigateProbeRemoved")
s = s.replace("ScriptMatchRepair.affectedSceneIDs", "ScriptMatchRepairProbe.affectedSceneIDs")
s = s.replace("Task { @MainActor [weak self] in", "ProbeNoHop {")
s = s.replace("row.scene.matchStatus = .unmatched", "row.scene.matchStatus = .matchedProbe")
open(p, "w", encoding="utf-8").write(s)
PY

# G-S5：向导视图冒出 isLoading
cat >> "$DIRTY/MixCut/Views/Script/ScriptWizardView.swift" <<'EOF'
private var probeS5IsLoading: Bool { false }
EOF

# G-S6：删掉一个 Core 文件与一个测试文件
rm "$DIRTY/Sources/MixCutCore/ScriptGroundingGate.swift"
rm "$DIRTY/Tests/MixCutCoreTests/AudioTrackPolicyTests.swift"

# G-S7：AI 策略列表漏排除脚本容器（脚本组将在 AI 区重复陈列）；
#       且 fan-out 清理白名单漏掉容器保护（空组会被当垃圾策略清掉）。
python3 - "$DIRTY/MixCut/ViewModels/SchemeViewModel.swift" "$DIRTY/MixCut/App/DebugSelfTest.swift" <<'PY'
import sys
vm, dst = sys.argv[1], sys.argv[2]
s = open(vm, encoding="utf-8").read()
s = s.replace("!$0.isScriptGroup", "!$0.isScriptGroupProbe")
open(vm, "w", encoding="utf-8").write(s)
s = open(dst, encoding="utf-8").read()
s = s.replace("!st.isScriptGroup", "!st.isScriptGroupProbe")
open(dst, "w", encoding="utf-8").write(s)
PY

# G-S8：向导视图退回内联陈列；选择器视图耦合向导 VM（失去场景中立性）。
cat >> "$DIRTY/MixCut/Views/Script/ScriptWizardView.swift" <<'EOF'
// probe: inline candidate list revived
private func probeS8InlinePrefix<C>(_ candidates: [C]) -> Array<C>.SubSequence { candidates.prefix(6) }
EOF
cat >> "$DIRTY/MixCut/Views/Schemes/SegmentGridPickerSheet.swift" <<'EOF'
// probe: picker coupled to wizard VM
private var probeS8WizardVM: ScriptWizardViewModel.MatchRow? { nil }
EOF

# G-S9：删掉 Core 选中策略文件；VM 绕过策略裁决并复活空组硬编码默认 + 旧消费函数。
rm "$DIRTY/Sources/MixCutCore/SchemeSelection.swift"
python3 - "$DIRTY/MixCut/ViewModels/SchemeViewModel.swift" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("SchemeSelection.resolve", "SchemeSelectionProbe.resolve")
s = s.replace("lastLoadedProjectID", "lastLoadedProjectIDProbe")
open(p, "w", encoding="utf-8").write(s)
PY
cat >> "$DIRTY/MixCut/ViewModels/SchemeViewModel.swift" <<'EOF'
// probe: revived hardcoded default + one-shot consume (G-S9 regression)
private func probeS9RevivedDefault() {
    if let first = strategies.first { _ = first }
    consumePendingFocus()
}
EOF

# ===== G-V 全局配音音色变异腿（G-V2/V3/V4/V5 代表性门） =====
# G-V2 合成绕过 VoiceSynthesisGate 音色合法性门
sed -i '' 's/VoiceSynthesisGate\.isUsable/VoiceSynthesisGate_PROBE.isUsable/g' \
  "$DIRTY/MixCut/ViewModels/DubbingViewModel.swift"
# G-V3 物化空壳绕开 index 分配器（回到撞号）
sed -i '' 's/ScriptDubIndexAllocator\.nextIndex(/(/g' \
  "$DIRTY/MixCut/Services/Script/MaterializationService.swift"
# G-V4 清理任务去掉脚本族豁免
sed -i '' 's/ScriptDubReap\.scriptProvenanceRaws/ScriptDubReap_PROBE.scriptProvenanceRaws/g' \
  "$DIRTY/MixCut/Views/Schemes/SchemeDetailView.swift"
# G-V5 MCP 改写加回克隆前置（UI/MCP 双行为）
sed -i '' 's|// 统一改写入口（single 作用域）。|await vm.ensureClonedVoice(for: video, context: ctx)\n// PROBE 统一改写入口。|' \
  "$DIRTY/MixCut/Services/MCP/MCPSegmentToolHandlers.swift"
# G-V6 设置试听退回临时 DubbingViewModel（生命周期挂错宿主，播放即止）
cat >> "$DIRTY/MixCut/Views/Settings/SettingsView.swift" <<'EOF'
// probe: audition back to stack-local VM
private func probeAuditionVM() { let _ = DubbingViewModel() }
EOF

# ===== G-V7 M1b 三级覆盖/R3/中立弹窗/pbxproj 变异腿（每条独立跑，互不干扰计数） =====
run_isolated_guard() {  # $1=探针树路径 $2=期望必须命中的 FAIL 文案片段
  # 注意：本脚本 set -o pipefail，而守卫在变异树上**预期 exit 1**——
  # 不能直接 `守卫 | grep -q`（pipefail 会取守卫的 1 让整条管道失败，即使 grep 命中）。
  # 先捕获输出（守卫退出码显式吞掉），再在变量上 grep。
  local root="$1" want="$2" out
  out=$(ROOT_OVERRIDE="$root" "$ROOT/scripts/check_script_pipeline_guards.sh" 2>&1 || true)
  grep -q "$want" <<<"$out"
}

# G-V7① 透传删掉：legacy 解析不再传 suppressVideoClone（开关写了不生效）
build_tree "$DIRTY"
sed -i '' 's/suppressVideoClone: video\.voiceFollowsGlobal//g' \
  "$DIRTY/MixCut/ViewModels/DubbingViewModel.swift"
if run_isolated_guard "$DIRTY" "legacy 改写解析透传"; then
  :
else
  echo "FAIL G-V7① 变异腿：透传删掉应红却没红"
  exit 1
fi

# G-V7③ 弹窗耦合 VM（中立性破坏）
build_tree "$DIRTY"
cat >> "$DIRTY/MixCut/Views/Shared/VoicePickerSheet.swift" <<'EOF'
// probe: picker coupled to concrete VM
private func probeCoupledVM(_ vm: DubbingViewModel) { _ = vm }
EOF
if run_isolated_guard "$DIRTY" "不得引用 DubbingViewModel"; then
  :
else
  echo "FAIL G-V7③ 变异腿：弹窗耦合 VM 应红却没红"
  exit 1
fi

# G-V7④ 绕过 Core R3 判据
build_tree "$DIRTY"
sed -i '' 's/DubVariantSelector\.isStale/DubVariantSelector_PROBE.isStale/g' \
  "$DIRTY/MixCut/ViewModels/DubbingViewModel.swift"
if run_isolated_guard "$DIRTY" "staleVoice 唯一判据"; then
  :
else
  echo "FAIL G-V7④ 变异腿：绕过 Core isStale 应红却没红"
  exit 1
fi

# G-V7⑤ 漏 pbxproj 登记：删探针树 pbxproj 中全部 VoicePickerSheet 行（4 行）
build_tree "$DIRTY"
sed -i '' '/VoicePickerSheet\.swift/d' "$DIRTY/MixCut.xcodeproj/project.pbxproj"
if run_isolated_guard "$DIRTY" "四段登记进 project.pbxproj"; then
  :
else
  echo "FAIL G-V7⑤ 变异腿：漏 pbxproj 登记应红却没红"
  exit 1
fi

# ===== G-V8 配音就绪腿变异腿 =====
# 这条腿是「零克隆直合成」的唯一可证伪证据，所以它的**退化路径**必须各自能变红：
# 最危险的不是它跑不起来，而是它悄悄退化成「不跑/不判/调真 API」还照样绿。

# ① 腿被删（或入口被摘掉）——M1a 遗留项复活，验收退回到真机人工点击
build_tree "$DIRTY"
python3 - "$DIRTY/MixCut/App/DebugSelfTest.swift" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace('if env["MIXCUT_SELFTEST_VOICEREADY"] == "1" { runVoiceReady(container: container); return }', '')
open(p, "w", encoding="utf-8").write(s)
PY
if run_isolated_guard "$DIRTY" "就绪腿入口已注册"; then
  :
else
  echo "FAIL G-V8① 变异腿：摘掉就绪腿入口应红却没红"
  exit 1
fi

# ② D3「零克隆调用」判据被删——腿退化成"没报错就算过"，恰好丢掉它要防的那个回归
build_tree "$DIRTY"
python3 - "$DIRTY/MixCut/App/DebugSelfTest.swift" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("vcCalls == 0", "vcCalls >= 0")
open(p, "w", encoding="utf-8").write(s)
PY
if run_isolated_guard "$DIRTY" "零克隆判据"; then
  :
else
  echo "FAIL G-V8② 变异腿：删掉零克隆判据应红却没红"
  exit 1
fi

# ③ 隔离纪律被破坏：就绪腿改用真实容器（会污染用户库）或不再还原全局偏好串
build_tree "$DIRTY"
python3 - "$DIRTY/MixCut/App/DebugSelfTest.swift" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("isStoredInMemoryOnly: true", "isStoredInMemoryOnly: false")
s = s.replace("let savedGlobalRaw = VoicePreferences.globalDefaultRaw", "let savedGlobalRaw: String? = nil")
open(p, "w", encoding="utf-8").write(s)
PY
if run_isolated_guard "$DIRTY" "内存容器"; then
  :
else
  echo "FAIL G-V8③ 变异腿：破坏隔离纪律（真实容器/不还原偏好）应红却没红"
  exit 1
fi

# ④ 就绪腿"顺手"改成调真实 TTS/AI 客户端（每跑一次就花钱，且失去零成本可重复性）
build_tree "$DIRTY"
cat >> "$DIRTY/MixCut/App/DebugSelfTest.swift" <<'EOF'
// probe: selftest leg starts calling real paid clients
private func probeVoiceReadyRealAPI() {
    _ = CosyVoiceTTSClient()
    _ = QwenTTSClient(model: "probe")
}
EOF
if run_isolated_guard "$DIRTY" "不得触达真实网络客户端"; then
  :
else
  echo "FAIL G-V8④ 变异腿：就绪腿调真实 API 客户端应红却没红"
  exit 1
fi

# ⑤ PATH 根治自证（本轮真正的根因，2026-10-07）：
#    本机PATH 里可能混进 WorkBuddy 的 brokered-bin/grep（shim）。实测它对 `'\|'`
#    交替恒返0，而 /usr/bin/grep 完全正常 —— 同一份守卫因此会「时绿时红」，
#    且「命中 == 0」的判据会退化成**恒假绿**（看着绿，实际一次检查都没做）。
#    守卫脚本开头的 PATH 根治就是为此。三段式：
#    A) 强制 shim 优先 + 违规树 → 必须 FAIL（证明 shim 下判据抓不到 =恒假绿真实存在）
#    B) 强制 shim 优先 + 干净树 → 必须 FAIL 或至少与 A 同态（记录 shim 影响面）
#    C) 正常环境 + 违规树      → 必须 FAIL（证明根治后判据真在工作）
#    D) 正常环境 + 干净树      → 必须全绿
#    C 与 D 成立 ⇒ 根治有效。A 若不成立则本腿如实报告「shim 对本批模式无害」。
SHIM_BIN="/Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/vendor/shim/brokered-bin"

build_tree "$DIRTY"
# 探针落在「非 provenance」上下文（判据豁免 scriptDirection/TranscriptSource 那几行）。
cat >> "$DIRTY/MixCut/ViewModels/DubbingViewModel.swift" <<'EOF'
// probe: business-mode word driving routing decision (must be caught)
private func probeRouteByBusinessMode(_ mode: String) -> String {
    mode == "creationMode" ? "cosyvoice" : "qwen3-tts-vc"
}
EOF

# 用shim 优先的 PATH 跑同一个守卫（模拟「脚本没摘 shim」的旧世界）。
# 注意脚本开头会自己摘 shim，所以这里改用一个把 shim 塞到最前的**替身**：
# 直接调 grep 不现实（判据在脚本内），故改为验证「摘掉 shim 后仍绿」+
#「把摘 shim 那段删掉后是否变红」——后者才是根治有效性的直接证据。
cat > "$PROBE_ROOT/guards-norootfix.sh" <<EOF2
#!/usr/bin/env bash
# 删掉「摘 shim」那段（保留其余全部），并把 shim 目录塞回 PATH 最前。
$(sed '/判据执行环境根治/,/^# ----*$/d' "$ROOT/scripts/check_script_pipeline_guards.sh")
EOF2
chmod +x "$PROBE_ROOT/guards-norootfix.sh" 2>/dev/null || true

NOROOTFIX_OUT=$(PATH="$SHIM_BIN:$PATH" ROOT_OVERRIDE="$DIRTY" \
  bash "$PROBE_ROOT/guards-norootfix.sh" 2>&1 || true)
NORMAL_DIRTY_OUT=$(ROOT_OVERRIDE="$DIRTY" "$ROOT/scripts/check_script_pipeline_guards.sh" 2>&1 || true)
NORMAL_CLEAN_OUT=$(ROOT_OVERRIDE="$CLEAN" "$ROOT/scripts/check_script_pipeline_guards.sh" 2>&1 || true)

# C) 正常环境 + 违规树必须红（根治后判据在工作）。
if grep -qE '^FAIL 配音 VM 禁出现业务模式词' <<<"$NORMAL_DIRTY_OUT"; then
  :
else
  echo "FAIL G-V8⑤：正常环境在违规树上应抓到「禁业务模式词」（判据没在工作）"
  exit 1
fi
# D) 正常环境 + 干净树必须全绿。
if grep -qE '全部成立' <<<"$NORMAL_CLEAN_OUT"; then
  :
else
  echo "FAIL G-V8⑤：正常环境在干净树上应全绿"
  echo "$NORMAL_CLEAN_OUT" | grep -E '^FAIL' | head -5
  exit 1
fi
# A) 记录 shim 的实际影响（两种可能都如实接受，但必须给出可读结论）。
if grep -qE '^FAIL 配音 VM 禁出现业务模式词' <<<"$NOROOTFIX_OUT"; then
  echo "NOTE G-V8⑤：shim 优先环境下该门仍能抓到违规（shim 对本模式无害，根治属纵深防御）"
else
  echo "NOTE G-V8⑤：shim 优先环境下该门**抓不到**违规 = 恒假绿形态真实存在，PATH 根治是必要防线"
fi


# ===== G-C M3 原始音频缓存变异腿 =====
# 这条缓存链的两条核心主张各自可能退化，判据必须能抓住：
#   ①「命中必须复制副本」退化为「直接用缓存真身」⇒ finalize 会把缓存删空，缓存永续为空；
#   ②「App 层自实现哈希」⇒ 与 Core 的 fileStem 漂移，界面显示已缓存却永远不命中。

# G-C① 命中不复制（把 copyingTo 改成直接返回缓存路径）
build_tree "$DIRTY"
python3 - "$DIRTY/MixCut/ViewModels/DubbingViewModel.swift" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("copyingTo: hitURL", "copyingTo: URL(fileURLWithPath: \"/dev/null\")")
open(p, "w", encoding="utf-8").write(s)
PY
if run_isolated_guard "$DIRTY" "命中路径必须复制到临时副本"; then
  :
else
  echo "FAIL G-C① 变异腿：命中不复制副本应红却没红"
  exit 1
fi

# G-C② App 层绕过 Core fileStem（自实现 stem）
build_tree "$DIRTY"
cat >> "$DIRTY/MixCut/Services/TTS/RawAudioCacheStore.swift" <<'EOF'
// probe: app layer grows its own file naming (drifts from Core fileStem)
private func probeOwnStem(_ key: RawAudioCacheKey) -> String { key.voiceID + key.textHash }
EOF
if run_isolated_guard "$DIRTY" "App 层落盘文件名必须用 Core 的 fileStem"; then
  :
else
  echo "FAIL G-C② 变异腿：App 层自实现命名应红却没红"
  exit 1
fi

# G-C③ 缓存目录与成品 Dubs 混用（退化成"缓存成品 m4a"这一 M3 最核心的反面）
build_tree "$DIRTY"
sed -i '' 's/appendingPathComponent("TTSCache", isDirectory: true)/appendingPathComponent("Dubs", isDirectory: true)/' \
  "$DIRTY/MixCut/Services/TTS/RawAudioCacheStore.swift"
if run_isolated_guard "$DIRTY" "缓存目录必须与成品 Dubs 分离"; then
  :
else
  echo "FAIL G-C③ 变异腿：缓存目录混入成品 Dubs 应红却没红"
  exit 1
fi

# 综合脏树：在最终脏树上叠加全部 G-V7 变异（供既有「总体应红」总判）
build_tree "$DIRTY"
sed -i '' 's/suppressVideoClone: video\.voiceFollowsGlobal//g' \
  "$DIRTY/MixCut/ViewModels/DubbingViewModel.swift"
sed -i '' 's/DubVariantSelector\.isStale/DubVariantSelector_PROBE.isStale/g' \
  "$DIRTY/MixCut/ViewModels/DubbingViewModel.swift"
cat >> "$DIRTY/MixCut/Views/Shared/VoicePickerSheet.swift" <<'EOF'
private func probeCoupledVM2(_ vm: ProjectViewModel) { _ = vm }
EOF
sed -i '' '/VoicePickerSheet\.swift/d' "$DIRTY/MixCut.xcodeproj/project.pbxproj"

if run_guards "$DIRTY"; then
  echo "FAIL 变异探针树应当变红却全绿（判据失效）"
  exit 1
fi
echo "PASS 变异探针树如期变红（守卫非恒绿）"

# 清理
rm -rf "$PROBE_ROOT"
echo "SELFTEST PASS"
