#!/usr/bin/env bash
# check_asr_guards.sh 的自证：在合成违规树上跑**同一判据**，必须逐条变红。
# 判据不会红的守卫 = 假防线（本项目定过的纪律：自写守卫脚本要先自证）。
#
# 两步：
#   ① 干净探针树必须全绿 —— 否则"红"可能只是文件没拷到，探针本身在造假数字
#   ② 注入探针树必须恰好 33 条红 —— 少了说明某条判据恒绿
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_ROOT="$ROOT/.scratch/asr-guard-probe"
CLEAN="$PROBE_ROOT/clean"
DIRTY="$PROBE_ROOT/dirty"

CORE_FILES=(ASRPolicy ASREngineDecision TextProvenance WhisperModelCatalog DubStaleness AgentToolCatalog
            SegmentTranscribeOutcome)
APP_FILES=(Services/ASR/ASRService.swift Services/ASR/ASRSettings.swift Services/ASR/QwenASRClient.swift
           Services/ASR/SegmentTranscriber.swift Services/VideoProcessing/FFmpegRunner.swift
           App/DebugSelfTest.swift ViewModels/ImportViewModel.swift
           Views/Settings/SettingsView.swift Views/Sidebar/SidebarView.swift
           Models/Segment.swift Models/SegmentDub.swift Models/Video.swift
           Services/MCP/MCPSegmentToolHandlers.swift Services/MCP/MCPToolHandlers.swift
           Views/SegmentLibrary/SegmentVariantInspector.swift)
SCRIPT_FILES=(build_universal_binaries.sh)

build_tree() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest/Sources/MixCutCore" "$dest/scripts"
  for f in "${CORE_FILES[@]}"; do
    cp "$ROOT/Sources/MixCutCore/$f.swift" "$dest/Sources/MixCutCore/"
  done
  for f in "${SCRIPT_FILES[@]}"; do
    cp "$ROOT/scripts/$f" "$dest/scripts/"
  done
  for f in "${APP_FILES[@]}"; do
    mkdir -p "$dest/MixCut/$(dirname "$f")"
    cp "$ROOT/MixCut/$f" "$dest/MixCut/$f"
  done
}

inject() {
  local dirty="$1"
  cat >> "$dirty/Sources/MixCutCore/ASRPolicy.swift" <<'EOF'
let probeG1 = UserDefaults.standard.bool(forKey: "probe")
EOF
  cat >> "$dirty/Sources/MixCutCore/TextProvenance.swift" <<'EOF'
let probeG2 = FileManager.default.temporaryDirectory
EOF
  sed -i '' 's/engineTier: String = "large-v3"/engineTier: String = "base"/' \
    "$dirty/Sources/MixCutCore/ASRPolicy.swift"
  sed -i '' 's/defaultPreference: ASRPreference = .local/defaultPreference: ASRPreference = .auto/' \
    "$dirty/Sources/MixCutCore/ASRPolicy.swift"
  sed -i '' 's/expectedBytes: nil/expectedBytes: 147_951_465/g' \
    "$dirty/Sources/MixCutCore/WhisperModelCatalog.swift"
  sed -i '' 's/public static func checkAll/public static func checkAllRenamedAway/' \
    "$dirty/Sources/MixCutCore/DubStaleness.swift"
  cat >> "$dirty/MixCut/Services/ASR/ASRService.swift" <<'EOF'
extension ASRService {
    static let probeG6a = "ggml-base"
    static let probeG6b = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/probe.bin"
    func probeG7b() async throws -> String? { try? await downloadModelIfNeeded() }
}
EOF
  cat >> "$dirty/MixCut/Services/ASR/ASRSettings.swift" <<'EOF'
let probeG8a = UserDefaults.standard.object(forKey: "extra.read")
EOF
  cat >> "$dirty/MixCut/Services/ASR/QwenASRClient.swift" <<'EOF'
let probeG8b = UserDefaults.standard.string(forKey: "probe")
EOF
  cat >> "$dirty/MixCut/Views/Settings/SettingsView.swift" <<'EOF'
let probeG8c = "asr.enginePreference"
EOF
  cat >> "$dirty/MixCut/Views/Sidebar/SidebarView.swift" <<'EOF'
func probeG7a() async { _ = try? await ASRService().downloadModelIfNeeded() }
EOF
  # --- 2b：来源列 / 唯一写入口 / 陈旧联动 ---
  cat >> "$dirty/MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift" <<'EOF'
func probeG9(_ snap: DubSnapshot) -> CheckResult {
    DubStaleness.check(snapshot: snap, currentStartFrame: 0, currentEndFrame: 0, currentTextHash: "x")
}
func probeG12(_ s: Segment) { s.textSourceRaw = TranscriptSource.manualEdit.rawValue }
EOF
  sed -i '' 's/private(set) var text: String/var text: String/' "$dirty/MixCut/Models/Segment.swift"
  sed -i '' 's/func setText(_ incoming: String, source: TranscriptSource)/func setTextRenamed(_ incoming: String, source: TranscriptSource)/' \
    "$dirty/MixCut/Models/Segment.swift"
  cat >> "$dirty/MixCut/Views/Settings/SettingsView.swift" <<'EOF'
func probeG10c(_ s: Segment) { s.text = "绕过唯一写入口" }
EOF
  sed -i '' '/var generatedForSourceTextHash: String = ""/d' "$dirty/MixCut/Models/SegmentDub.swift"
  # --- 2c：门面（R4/R5） ---
  cat >> "$dirty/MixCut/ViewModels/ImportViewModel.swift" <<'EOF'
func probeG13() { let _ = QwenASRClient() }
func probeG14(_ f: FFmpegRunner) async throws { try await f.extractSegmentPCM(from: "", start: 0, end: 1, to: "") }
func probeG16(_ r: SegmentTranscriber.Result) { if r.outcome == .replaced { print("就地判据") } }
EOF
  sed -i '' 's/func transcribeAudioFile(path:/func transcribeAudioFileRenamed(path:/' "$dirty/MixCut/Services/ASR/ASRService.swift"
  # --- 2d：能力面与打包链 ---
  sed -i '' 's|WMODEL="\$DEST/ggml-large-v3.bin"|WMODEL="$DEST/ggml-base.bin"|' "$dirty/scripts/build_universal_binaries.sh"
  sed -i '' 's/^WMIN=3000000000/WMIN=1600000000/' "$dirty/scripts/build_universal_binaries.sh"
  cat >> "$dirty/MixCut/Services/MCP/MCPSegmentToolHandlers.swift" <<'EOF'
let probeG18 = KeychainHelper.getAPIKey(for: .qwen)
EOF
  sed -i '' 's/case "get_asr_status"/case "get_asr_statusRenamed"/' "$dirty/MixCut/Services/MCP/MCPToolHandlers.swift"
  cat >> "$dirty/MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift" <<'EOF'
let probeG20 = "原台词变了"
EOF
  # --- v5：逐段重听的短窗对策 ---
  # G21：--prompt 出现在第二个文件
  cat >> "$dirty/MixCut/Views/Settings/SettingsView.swift" <<'EOF'
let probeG21 = "--prompt"
EOF
  # G22：锚字面量被复制一份（= 有人开始自己攒 prompt）
  cat >> "$dirty/MixCut/Services/ASR/SegmentTranscriber.swift" <<'EOF'
let probeG22 = "下面是一段简体中文口语旁白，请使用简体中文书写，句子通顺，标点规范。"
EOF
  # G23：VM 自己决定带不带锚 ⇒ 与核心层分家
  cat >> "$dirty/MixCut/ViewModels/ImportViewModel.swift" <<'EOF'
func probeG23(_ e: ASREngine) -> String? { SegmentRetakeRule.styleAnchor(for: e) }
EOF
  # G26：锚回吐判据出现第二份实现
  cat >> "$dirty/MixCut/Services/ASR/ASRService.swift" <<'EOF'
extension ASRService {
    static func containsAnchorEcho(_ text: String, anchor: String) -> Bool { text.contains(anchor) }
}
EOF
  # G27：抹掉"只有测试在调"的登记 ⇒ 死码重新伪装成防线
  sed -i '' '/known-dead:/d' "$dirty/Sources/MixCutCore/SegmentTranscribeOutcome.swift"
}

trap 'rm -rf "$PROBE_ROOT"' EXIT

build_tree "$CLEAN"
echo "== ① 干净探针树（必须全绿，否则探针树与真树不等价）"
if ! GUARD_ROOT="$CLEAN" bash "$ROOT/scripts/check_asr_guards.sh" > "$PROBE_ROOT/clean.log" 2>&1; then
  echo "SELFTEST FAIL：干净探针树上有判据变红，先修守卫的文件清单/基线"
  grep -n "FAIL" "$PROBE_ROOT/clean.log"
  exit 1
fi
clean_pass=$(grep -c "^PASS" "$PROBE_ROOT/clean.log")
echo "SELFTEST 步骤① OK：干净树 $clean_pass 条 PASS、0 FAIL"

build_tree "$DIRTY"
inject "$DIRTY"
echo "== ② 注入探针树（必须 33 条红）"
GUARD_ROOT="$DIRTY" bash "$ROOT/scripts/check_asr_guards.sh" --selftest > "$PROBE_ROOT/dirty.log" 2>&1
rc=$?
red=$(grep -c "^FAIL" "$PROBE_ROOT/dirty.log")
echo "注入树变红条数=$red（期望 33），selftest 退出码=$rc"
grep "^FAIL" "$PROBE_ROOT/dirty.log"
if [[ "$rc" != "0" || "$red" != "33" ]]; then
  echo "SELFTEST FAIL：判据没抓全（某条恒绿，或红数超出预期说明探针污染）"
  exit 1
fi
echo "ASR 守卫自证通过：33 条判据在违规树上全部变红"
