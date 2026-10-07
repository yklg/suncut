#!/usr/bin/env bash
# 产品脚本成片 M4（逆向成片 + dubOnly 导出闭环 + txt/md 导出 + 真删回退）源码守卫。
#
# 守的是四件"静默退化就等于功能没做"的事：
#   G-S1 dubOnly 声音策略必须真接线：导出层读 AudioTrackPolicy、经 Core 判据，
#        且导出层不允许出现任何业务模式词（productScript/creationMode/userScriptReverse）
#        —— 导出只认策略，业务模式改名字不该牵动导出；
#   G-S2 grounding 必须过 ScriptGroundingGate 方向门：逆向用户原文无资料可引，
#        漏门会把所有含数字的带货文案永久拦在物化前；
#   G-S3 dubOnly 缺配音必须结构化报错（from throws + 调用方 do/catch 入失败清单），
#        严禁退回旧的 `guard let ... else { continue }` 静默跳过；
#   G-S4 W3：向导 VM 必须订阅真删广播并经 Core 纯判据回退 unmatched；
#   G-S5 向导视图不得出现 isLoading（G01 同纪律，phase 枚举驱动）；
#   G-S7 产品脚本成片容器三锚点：物化经 ensureScriptGroup 懒建专属 MixStrategy、
#        AI 策略列表三字段排除（防脚本组在 AI 区重复陈列）、fan-out 清理白名单排除容器；
#   G-S8 向导分镜选择必须走中立 SegmentGridPickerSheet：禁内联 candidates.prefix/
#        「全部片段」菜单，过滤经 Core SegmentGridPicker 纯函数，选择器视图不得引用向导 VM；
#   G-S9 方案选中必须经 Core SchemeSelection 纯策略：loadSchemes 禁止硬编码默认
#        （空「自定义组合」随项目出生、createdAt 最早，旧 strategies.first 默认必选空组，
#        物化跳转第二次 onAppear 重载会把新方案焦点覆盖成空白页），同项目连续性/切项目
#        /焦点令牌消费口径全在 Core 判据 + 单测，VM 只投影应用。
#
# 用法：./scripts/check_script_pipeline_guards.sh
#   ROOT_OVERRIDE=<目录> 指向探针树（selftest 自证变红用）
#
# 刻意不开 set -e：grep 无命中退出码 1，会在断言打印前静默中止（本仓踩过）。
set -uo pipefail

ROOT="${ROOT_OVERRIDE:-$(cd "$(dirname "$0")/.." && pwd)}"
EXPORT_DIR="$ROOT/MixCut/Services/Export"
DUB_EXPORT="$EXPORT_DIR/DubExportService.swift"
MATERIALIZE="$ROOT/MixCut/Services/Script/MaterializationService.swift"
WIZARD_VM="$ROOT/MixCut/ViewModels/ScriptWizardViewModel.swift"
WIZARD_VIEW="$ROOT/MixCut/Views/Script/ScriptWizardView.swift"
SCHEMES_VIEWS="$ROOT/MixCut/Views/Schemes"
SVM_VIEWMODEL="$ROOT/MixCut/ViewModels/SchemeViewModel.swift"
EXPORT_VIEW="$ROOT/MixCut/Views/Export/ExportView.swift"
CORE="$ROOT/Sources/MixCutCore"
TESTS="$ROOT/Tests/MixCutCoreTests"
fail=0

# ---- 判据执行环境根治：不让 shim 的 grep 进PATH -------------------------------
# 见下面 code_count 的注释：本机两套 grep 对 `\|` 交替结论相反，会让守卫时绿时红，
# 且「命中==0」类判据会退化成恒假绿。这里把 shim 目录摘掉，判据永远跑系统 grep。
if [ -d "/Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/vendor/shim/brokered-bin" ]; then
  PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'WorkBuddy.app/.*/vendor/shim' | paste -sd ':' -)"
  export PATH
fi
# -----------------------------------------------------------------------------

# 只数代码行（去掉 // / /// 整行注释），避免注释里的字段名造成假命中。
#
# ⚠️ 判据不许依赖 PATH 里的 grep 实现（2026-10-07 实测踩坑，诊断一度搞反）：
# 本机同时存在两套 grep，对同一模式 `'a\|b'` 结论**相反**：
#   · /usr/bin/grep（BSD）→ 交替**有效**；
#   · WorkBuddy 的 brokered-bin/grep（shim）→ 同一模式**恒 0**。
# 于是同一份守卫会「在一个 shell 里绿、在另一个里红」，而最坏的一类是
# **「命中 == 0」的判据退化成恒假绿**（守卫看着绿，实际一次检查都没做）。
# 两道防线：① 脚本开头已把 shim 目录从 PATH 摘掉（根治）；
#            ② 这里再把含 `\|` 的模式统一归一成 `-E`（两种 grep 上都正确）。
# 另外：源码里的字面符号（? * ( ) |）一律用 code_count_f（-F），不写 BRE 转义
#（`\?` 在 BSD 与 GNU 上语义不同：BSD 按字面「反斜杠+问号」）。
grep_ce() {
  local file="$1" pattern="$2"
  case "$pattern" in
    *'\|'*) grep -hE -- "$(printf '%s' "$pattern" | sed 's/\\|/|/g')" "$file" 2>/dev/null ;;
    *)      grep -h  -- "$pattern" "$file" 2>/dev/null ;;
  esac
}

code_count() {
  local file="$1" pattern="$2"
  [ -f "$file" ] || { echo 0; return; }
  grep_ce "$file" "$pattern" | grep -vcE '^[[:space:]]*(///|//)' || true
}

# 固定串版：模式要按**字面**匹配源码符号（? * ( ) | 等）时用这个。
# BRE 里 `\?` 在 BSD 与 GNU 上语义不同（BSD 按字面「反斜杠+问号」），字面符号
# 一律走 -F，判据不随 grep 实现漂移。
code_count_f() {
  local file="$1" pattern="$2"
  [ -f "$file" ] || { echo 0; return; }
  grep -hF -- "$pattern" "$file" 2>/dev/null | grep -vcE '^[[:space:]]*(///|//)' || true
}

# 目标级计数。**同时支持两种调用形态**（历史坑：本仓调用点按「带 label」传参，
# 而原定义只有 2 参 → label 被当成路径、`[ -d ]` 失败 → 直接 echo 0，
# 于是「禁业务模式词」那两条判据从来没真正工作过，且形态是**恒假绿**）：
#   ① dir_count <path> <pattern>= count，仅回计数（供 $( ) 包裹）
#   ② dir_count <label> <path> <pattern> <expected>  → 自带 expect 语义，自打 PASS/FAIL
# 判别方式：第 1 参若是已存在的文件或目录 → 形态 ①；否则按形态 ② 处理。
# <path> 既可以是目录（-r 递归 + --include过滤），也可以是单个文件。
dir_count() {
  local path pattern label="" expected=""
  if [ -e "${1:-}" ]; then
    path="$1"; pattern="$2"
  else
    label="$1"; path="$2"; pattern="$3"; expected="${4:-0}"
  fi
  if [ ! -e "$path" ]; then
    if [ -n "$label" ]; then echo 0; return 1; fi
    echo 0; return
  fi
  local hit
  # ⚠️ --include 的值必须带引号，否则 `*.swift` 会被 shell 在**当前目录**展开成
  # 一串文件名塞进参数列表，grep 于是按「显式文件列表」模式工作 → 目录被忽略 → 恒 0。
  # （这条是 dir_count 长期恒返 0 的第二个根因，与前面的参数形态不匹配叠加在一起。）
  if [ -d "$path" ]; then
    hit=$(grep -r --include='*.swift' -E -- "$(printf '%s' "$pattern" | sed 's/\\|/|/g')" "$path" 2>/dev/null | grep -vcE '^[[:space:]]*(///|//)' || true)
  else
    hit=$(grep -hE -- "$(printf '%s' "$pattern" | sed 's/\\|/|/g')" "$path" 2>/dev/null | grep -vcE '^[[:space:]]*(///|//)' || true)
  fi
  if [ -n "$label" ]; then
    expect_eq "$label" "$hit" "$expected"
    return $?
  fi
  echo "$hit"
}

expect_ge() {
  local label="$1" got="$2" want="$3"
  if [ "$got" -ge "$want" ] 2>/dev/null; then
    echo "PASS ${label}（命中 ${got}，>= ${want}）"
  else
    echo "FAIL ${label}（命中 ${got}，期望 >= ${want}）"
    fail=1
  fi
}

expect_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "PASS ${label}（命中 ${got}）"
  else
    echo "FAIL ${label}（命中 ${got}，期望 ${want}）"
    fail=1
  fi
}

expect_file() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    echo "PASS ${label}"
  else
    echo "FAIL ${label}（缺失：${path}）"
    fail=1
  fi
}

echo "== G-S1 dubOnly 策略真接线（抓：枚举空挂/导出层按业务模式分叉） =="
expect_ge "DubExportService 读取 scheme.audioTrackPolicy" \
  "$(dir_count "$EXPORT_DIR" 'audioTrackPolicy')" 3
expect_ge "导出层经 Core DubOnlyExportPolicy 判据（plan + feasibleCount）" \
  "$(code_count "$DUB_EXPORT" 'DubOnlyExportPolicy\.')" 2
expect_eq "导出层禁止业务模式词（productScript/creationMode/userScriptReverse）" \
  "$(dir_count "$EXPORT_DIR" 'productScript\|creationMode\|userScriptReverse')" 0

echo "== G-S2 grounding 方向门（抓：逆向含数字文案被 grounding 永久拦截） =="
expect_file "Core ScriptGroundingGate.swift 存在" "$CORE/ScriptGroundingGate.swift"
expect_ge "物化终检 grounding 必须经过方向门" \
  "$(code_count "$MATERIALIZE" 'ScriptGroundingGate\.requiresExternalEvidence')" 1
expect_ge "向导确认页校验必须经过方向门" \
  "$(code_count "$WIZARD_VM" 'ScriptGroundingGate\.requiresExternalEvidence')" 1

echo "== G-S3 dubOnly 缺配音结构化报错（抓：静默 continue 悄悄少片/回退原声） =="
expect_ge "DubExportInput.from 签名为 throws" \
  "$(code_count "$DUB_EXPORT" 'func from(scheme:.*throws')" 1
expect_ge "from 定义 dubOnlyBlocked 阻塞错误" \
  "$(code_count "$DUB_EXPORT" 'dubOnlyBlocked')" 2
expect_ge "ExportView 以 try 调用 from 并准备接住错误" \
  "$(code_count "$EXPORT_VIEW" 'try DubExportInput\.from')" 1
expect_eq "ExportView 不得再用 guard-let-else-continue 静默跳过构建失败" \
  "$(code_count "$EXPORT_VIEW" 'guard let input = DubExportInput\.from')" 0

echo "== G-S4 W3 素材真删回退 unmatched（抓：边 nullify 后 matchStatus 仍停 matched） =="
expect_ge "向导 VM 订阅 mixCutDataDidUndo 广播" \
  "$(code_count "$WIZARD_VM" 'name: \.mixCutDataDidUndo')" 1
expect_ge "回退判定经 Core ScriptMatchRepair 纯判据" \
  "$(code_count "$WIZARD_VM" 'ScriptMatchRepair\.affectedSceneIDs')" 1
expect_ge "VM 持有 scene→segment 纯 UUID 快照（不靠关系边判存活）" \
  "$(code_count "$WIZARD_VM" 'sceneToSegmentID')" 3
expect_ge "selector 跳板必须经 Task @MainActor hop 出 post 同步栈（hop 后才允许 fetch/save）" \
  "$(code_count "$WIZARD_VM" 'Task { @MainActor')" 1
expect_ge "回退处理必须把命中场景 matchStatus 置回 unmatched" \
  "$(code_count "$WIZARD_VM" 'matchStatus = \.unmatched')" 1

echo "== G-S5 向导视图零 isLoading（进度一律 switch ScriptFlowPhase） =="
expect_eq "ScriptWizardView 内 isLoading token" \
  "$(code_count "$WIZARD_VIEW" 'isLoading')" 0

echo "== G-S6 M4 Core 纯逻辑与单测齐备（SwiftPM 覆盖；缺失即防线没落地） =="
for f in ScriptGroundingGate ScriptMatchRepair DubOnlyExportPolicy ScriptTextExporter; do
  expect_file "Core/$f.swift" "$CORE/$f.swift"
done
for f in PastedScriptLinesTests AudioTrackPolicyTests ScriptTextExporterTests; do
  expect_file "Tests/$f.swift" "$TESTS/$f.swift"
done

# 新增容器/选择器文件登记
for f in SegmentGridPicker SchemeFocus; do
  expect_file "Core/$f.swift" "$CORE/$f.swift"
done
expect_file "App SegmentGridPickerSheet.swift" "$SCHEMES_VIEWS/SegmentGridPickerSheet.swift"
expect_file "Tests SegmentGridPickerTests.swift" "$TESTS/SegmentGridPickerTests.swift"

echo
echo "== G-S7 产品脚本成片容器三锚点（容器归属防回归） =="
MAT="$MATERIALIZE"
SVM="$SVM_VIEWMODEL"
DST="$ROOT/MixCut/App/DebugSelfTest.swift"
# ① 物化必须经 ensureScriptGroup 给 scheme.strategy 赋值
expect_ge "物化经 ensureScriptGroup" \
  "$(code_count "$MAT" 'ensureScriptGroup')" 1
expect_ge "物化设置 scheme.strategy = group" \
  "$(code_count "$MAT" 'scheme\.strategy = group')" 1
# ② AI 策略过滤必须三字段排除（否则脚本组在 AI 区重复出现）
expect_ge "aiStrategies 三字段排除 isScriptGroup" \
  "$(code_count "$SVM" '!\$0\.isScriptGroup')" 1
# 内存占位工厂存在（空组恒定可见；占位不 insert 的纪律靠 Service 唯一 ensure 锚点 + 评审，
# grep 无法区分工厂内的标志位赋值与 insert，故不在此加易错锚点）。
expect_ge "SchemeViewModel 提供内存占位工厂 makeScriptPlaceholder" \
  "$(code_count "$SVM" 'makeScriptPlaceholder')" 1
# ③ fan-out 清理白名单必须排除脚本容器
expect_ge "DebugSelfTest fan-out 白名单排除 isScriptGroup" \
  "$(code_count "$DST" '!st\.isScriptGroup')" 1

echo
echo "== G-S8 向导必须走中立分镜选择器（禁内联陈列/禁选择器耦合向导 VM） =="
PICKER="$SCHEMES_VIEWS/SegmentGridPickerSheet.swift"
# 内联硬截断/无缩略图菜单必须移除
expect_eq "向导视图不得再内联 candidates.prefix（大池子浏览交给选择器）" \
  "$(code_count "$WIZARD_VIEW" 'candidates\.prefix')" 0
expect_eq "向导视图不得再有「全部片段」内联 Menu" \
  "$(code_count "$WIZARD_VIEW" '全部片段')" 0
# VM 必须经 Core 纯函数过滤
expect_ge "VM 调用 SegmentGridPicker.filter" \
  "$(code_count "$WIZARD_VM" 'SegmentGridPicker\.filter')" 1
expect_ge "VM 提供 pickerSegments 纯值投影" \
  "$(code_count "$WIZARD_VM" 'pickerSegments')" 1
# 移动只能走既有收口（P1-3）：pickerMoveSegment 内必须出现 clearSelection + selectSegment
expect_ge "占用移动复用 clearSelection 收口" \
  "$(code_count "$WIZARD_VM" 'clearSelection(for: ownerRow)')" 1
# 选择器视图中立：不得引用向导 VM 类型
expect_eq "选择器视图不得引用 ScriptWizardViewModel（场景中立，M5 复用前提）" \
  "$(code_count "$PICKER" 'ScriptWizardViewModel')" 0
expect_file "App 选择器文件存在" "$PICKER"

echo
echo "== G-S9 方案选中必须经 Core SchemeSelection 策略（抓：物化后被第二次重载夺选落空白空组） =="
SELECTION_CORE="$CORE/SchemeSelection.swift"
SELECTION_TESTS="$TESTS/SchemeSelectionTests.swift"
expect_file "Core SchemeSelection.swift 存在" "$SELECTION_CORE"
expect_file "Tests SchemeSelectionTests.swift 存在" "$SELECTION_TESTS"
expect_ge "loadSchemes 选中裁决必须经 SchemeSelection.resolve" \
  "$(code_count "$SVM" 'SchemeSelection\.resolve')" 1
expect_ge "VM 以 lastLoadedProjectID 区分同项目重载与切项目（声明+读+写至少 3 处）" \
  "$(code_count "$SVM" 'lastLoadedProjectID')" 3
expect_ge "SchemeSelection 各分支必须有单测（resolve 调用 >= 8）" \
  "$(code_count "$SELECTION_TESTS" 'SchemeSelection\.resolve')" 8
expect_eq "旧硬编码默认 let first = strategies.first 禁止复活（空自定义组必空白）" \
  "$(code_count "$SVM" 'let first = strategies\.first')" 0
expect_eq "旧一次性消费函数 consumePendingFocus 禁止复活（裁决已归 Core 策略）" \
  "$(code_count "$SVM" 'consumePendingFocus')" 0

# ============================================================================
# G-V1…G-V5 全局配音音色（解析单一真源 / 引擎路由 / 脚本绑定 / 清理豁免 / MCP 同入口）
# ============================================================================
INSPECTOR_VIEW="$ROOT/MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"
MCP_HANDLERS="$ROOT/MixCut/Services/MCP/MCPSegmentToolHandlers.swift"
VOICE_PREFS="$ROOT/MixCut/Utilities/VoicePreferences.swift"
VOICE_CORE="$CORE/VoiceChoice.swift"
BINDING_CORE="$CORE/ScriptDubBinding.swift"
DUB_VM="$ROOT/MixCut/ViewModels/DubbingViewModel.swift"
SCHEME_DETAIL="$SCHEMES_VIEWS/SchemeDetailView.swift"
DUB_SETTINGS="$ROOT/MixCut/Views/SegmentLibrary/DubSettingsBar.swift"
SETTINGS_VIEW="$ROOT/MixCut/Views/Settings/SettingsView.swift"
AUDITION_PLAYER="$ROOT/MixCut/Services/TTS/VoiceAuditionPlayer.swift"

echo
echo "== G-V1 配音音色必须经 Core VoiceResolver 解析（禁视图/管线各写优先级） =="
expect_file "Core VoiceChoice 存在" "$VOICE_CORE"
expect_ge "VM 素材库链路经 VoicePreferences/VoiceResolver 解析" \
  "$(code_count "$DUB_VM" 'VoicePreferences\.resolveForLegacy\|VoiceResolver\.resolveForLegacyDub')" 1
expect_ge "VM 脚本链路经 VoicePreferences/VoiceResolver 解析" \
  "$(code_count "$DUB_VM" 'VoicePreferences\.resolveForScript\|VoiceResolver\.resolveForScript')" 1
expect_ge "素材库栏经 VoicePreferences 展示生效音色" \
  "$(code_count "$DUB_SETTINGS" 'VoicePreferences\.resolveForLegacy')" 1
expect_ge "方案详情经 VoicePreferences/VoiceChoiceCoder 判配置态" \
  "$(code_count "$SCHEME_DETAIL" 'VoicePreferences\.globalDefaultChoice\|VoiceChoiceCoder\.decode')" 1

echo
echo "== G-V2 合成按引擎路由、守卫三分支，DubbingVM 禁业务模式词 =="
expect_ge "generateAudio 经 VoiceSynthesisGate 校验音色合法性" \
  "$(code_count "$DUB_VM" 'VoiceSynthesisGate\.isUsable')" 1
expect_ge "合成客户端按 VoiceChoice.engine 路由" \
  "$(code_count "$DUB_VM" 'synthesisClient(for:')" 1
expect_ge "脚本合成显式传 resolvedChoice（空壳不猜音色）" \
  "$(code_count "$DUB_VM" 'resolvedChoice:')" 1
# ⚠️ 判据范围（2026-10-07 修正，守卫此前从未真正工作过，修好后才暴露这条）：
# 本门原意是「TTS/合成路由不许按业务模式分叉」（引擎只看 VoiceChoice.engine）。
# 但用词太宽：DubbingViewModel.scriptDirection() 里 `isReverse ? .userScriptReverse : .productScript`
# 是**合法的 provenance 标注**（记录这条 dub 的台词来源，供删除归属 Reap 判定），
# 与「路由分叉」无关。守卫要禁的是「在合成/路由决策处读业务模式词」，
# 不是「仓库里不许出现这个词」——后者会把 provenance 机制一并禁掉。
# 故改为：文件内**除 provenance 标注函数外**不得出现业务模式词。
provenance_hits="$(grep -nE 'productScript|creationMode|userScriptReverse' "$DUB_VM" 2>/dev/null \
  | grep -vE 'scriptDirection|TranscriptSource|isReverse \?|setProvenance' | grep -vE '^[0-9]+:[[:space:]]*(///|//)' || true)"
if [ -z "$provenance_hits" ]; then
  echo "PASS 配音 VM 禁出现业务模式词（路由只认引擎；provenance 标注除外）"
else
  echo "FAIL 配音 VM 禁出现业务模式词（路由只认引擎；provenance 标注除外）"
  echo "$provenance_hits" | sed 's/^/    /'
  fail=1
fi

echo
echo "== G-V3 脚本空壳绑定必经 Core ScriptDubBinding（禁直接给壳赋 voiceId） =="
expect_file "Core ScriptDubBinding 存在" "$BINDING_CORE"
expect_ge "VM 绑定经 ScriptDubBinding.resolve" \
  "$(code_count "$DUB_VM" 'ScriptDubBinding\.resolve')" 1
expect_ge "物化空壳 index 经分配器（禁从 0 硬起）" \
  "$(code_count "$MATERIALIZE" 'ScriptDubIndexAllocator\.nextIndex')" 1
# 物化仍创建空壳（voiceId 空），不得在物化阶段写死音色
expect_eq "物化创建的脚本 dub 仍是空 voiceId（音色在生成时绑定）" \
  "$(code_count "$MATERIALIZE" 'voiceId: \"\"')" 1

echo
echo "== G-V4 清理任务必须豁免脚本族空壳（防打开方案详情删载体） =="
expect_ge "SchemeDetailView 清理含 ScriptDubReap 脚本族豁免" \
  "$(code_count "$SCHEME_DETAIL" 'ScriptDubReap\.scriptProvenanceRaws')" 1

echo
echo "== G-V5 MCP 改写与 UI 同解析入口（禁 MCP 自带克隆前置） =="
expect_ge "MCP 改写传项目覆盖串给统一 rewrite" \
  "$(code_count "$MCP_HANDLERS" 'projectOverrideRaw:')" 1
expect_eq "MCP 改写前不得再自带 ensureClonedVoice 前置（克隆由 VM 按解析决定）" \
  "$(code_count "$MCP_HANDLERS" 'await vm\.ensureClonedVoice')" 0

echo
echo "== G-V6 音色试听必须经进程级 VoiceAuditionPlayer（禁设置页造临时 VM） =="
expect_file "VoiceAuditionPlayer 存在" "$AUDITION_PLAYER"
expect_ge "设置试听调用 VoiceAuditionPlayer.playPreset" \
  "$(code_count "$SETTINGS_VIEW" 'auditionPlayer\.playPreset\|VoiceAuditionPlayer\.shared\.playPreset')" 1
expect_eq "设置页不得新建临时 DubbingViewModel 做试听（播放器随栈释放即止）" \
  "$(code_count "$SETTINGS_VIEW" 'DubbingViewModel()')" 0
expect_eq "DubbingVM 的临时 audition 入口应已移除（试听统一在 VoiceAuditionPlayer）" \
  "$(code_count "$DUB_VM" 'func audition(')" 0

# M1b：音色三级覆盖 UI + R3 变体选择（中立弹窗 / VM 写入收口 / Core 判据 / pbxproj 登记）。
VOICE_PICKER="$ROOT/MixCut/Views/Shared/VoicePickerSheet.swift"
VIDEO_MODEL="$ROOT/MixCut/Models/Video.swift"
SCHEME_SEG_MODEL="$ROOT/MixCut/Models/SchemeSegment.swift"
PROJECT_VM="$ROOT/MixCut/ViewModels/ProjectViewModel.swift"
SEGMENTDUB_MODEL="$ROOT/MixCut/Models/SegmentDub.swift"
CORE_DUB_SELECTOR="$CORE/DubVariantSelector.swift"
CORE_VOICE_FILTER="$CORE/VoiceCatalogFilter.swift"
SELFTEST="$ROOT/MixCut/App/DebugSelfTest.swift"

echo
echo "== G-V7 M1b 三级覆盖 UI + R3 变体选择 =="
# ① legacy 解析必须透传视频级「跟随全局」开关（漏传=开关写了不生效）。
expect_file "Video 模型存在" "$VIDEO_MODEL"
expect_ge "Video.voiceFollowsGlobal 字段存在" \
  "$(code_count "$VIDEO_MODEL" 'var voiceFollowsGlobal')" 1
expect_ge "legacy 改写解析透传 suppressVideoClone: video.voiceFollowsGlobal" \
  "$(code_count "$DUB_VM" 'suppressVideoClone: video\.voiceFollowsGlobal')" 1
expect_ge "DubSettingsBar 状态解析同步透传 voiceFollowsGlobal" \
  "$(code_count "$DUB_SETTINGS" 'suppressVideoClone: video\.voiceFollowsGlobal')" 1

# ② 段覆盖：模型字段 + VM 段覆盖 decode 锚点 + 三个写入收口函数名（视图禁直写）。
expect_file "SchemeSegment 模型存在" "$SCHEME_SEG_MODEL"
expect_ge "SchemeSegment.preferredVoiceChoiceRaw 段覆盖字段存在" \
  "$(code_count "$SCHEME_SEG_MODEL" 'var preferredVoiceChoiceRaw')" 1
expect_ge "VM 段覆盖优先于方案级解析（decode(schemeSeg.preferredVoiceChoiceRaw)）" \
  "$(code_count "$DUB_VM" 'VoiceChoiceCoder\.decode(schemeSeg\.preferredVoiceChoiceRaw)')" 1
expect_ge "VM 视频跟随开关写入收口 setVideoFollowsGlobal" \
  "$(code_count "$DUB_VM" 'func setVideoFollowsGlobal')" 1
expect_ge "VM 段覆盖写入收口 setScriptSlotVoiceOverride" \
  "$(code_count "$DUB_VM" 'func setScriptSlotVoiceOverride')" 1
expect_ge "ProjectVM 项目覆盖写入收口 setProjectVoiceOverride" \
  "$(code_count "$PROJECT_VM" 'func setProjectVoiceOverride')" 1

# ③ 中立弹窗：存在；零 VM 耦合；关闭停试听。
expect_file "VoicePickerSheet 存在" "$VOICE_PICKER"
expect_eq "VoicePickerSheet 不得引用 DubbingViewModel（中立性）" \
  "$(code_count "$VOICE_PICKER" 'DubbingViewModel')" 0
expect_eq "VoicePickerSheet 不得引用 ScriptWizardViewModel（中立性）" \
  "$(code_count "$VOICE_PICKER" 'ScriptWizardViewModel')" 0
expect_eq "VoicePickerSheet 不得引用 ProjectViewModel（中立性）" \
  "$(code_count "$VOICE_PICKER" 'ProjectViewModel')" 0
expect_ge "VoicePickerSheet 关闭必须停试听（onDisappear stop）" \
  "$(code_count "$VOICE_PICKER" 'VoiceAuditionPlayer\.shared\.stop\(\)')" 1

# ④ R3/stale 必须经 Core 判据（禁视图/VM 自写去重与 stale 比对）。
expect_file "Core DubVariantSelector 存在" "$CORE_DUB_SELECTOR"
expect_file "Core VoiceCatalogFilter 存在" "$CORE_VOICE_FILTER"
expect_ge "Core DubVariantSelector.effective 判据存在" \
  "$(grep -h 'static func effective' "$CORE_DUB_SELECTOR" 2>/dev/null | grep -vcE '^///|//')" 1
expect_ge "Core DubVariantSelector.isStale 判据存在" \
  "$(grep -h 'static func isStale' "$CORE_DUB_SELECTOR" 2>/dev/null | grep -vcE '^///|//')" 1
expect_ge "模型带参口径必须经 DubVariantSelector.effective（R3 单一判据）" \
  "$(code_count "$SEGMENTDUB_MODEL" 'DubVariantSelector\.effective')" 1
expect_ge "VM 必须经 DubVariantSelector.isStale（staleVoice 唯一判据）" \
  "$(code_count "$DUB_VM" 'DubVariantSelector\.isStale')" 1

# ⑤ pbxproj 四段登记（沙盒 check_app_build 按文件系统 find 扫描，漏登记会假绿，真机 xcodebuild 才红）。
expect_ge "VoicePickerSheet 必须四段登记进 project.pbxproj" \
  "$(grep -c 'VoicePickerSheet\.swift' "$ROOT/MixCut.xcodeproj/project.pbxproj")" 4

echo
echo "== G-V8 配音就绪腿（M1a/M1b 遗留；rewrite 全链路的唯一机械判据）=="
# 这条腿替代「真机点四层界面 + 真调 AI/TTS 花钱」的人工验收，是「零克隆直合成」主张的
# **唯一可证伪**证据。腿被删/ 被改成真调 API / 判据被删掉，都必须变红。
expect_file "DebugSelfTest 存在" "$SELFTEST"
expect_ge "就绪腿入口已注册（MIXCUT_SELFTEST_VOICEREADY）" \
  "$(code_count "$SELFTEST" 'MIXCUT_SELFTEST_VOICEREADY')" 1
expect_ge "就绪腿实现存在 runVoiceReady" \
  "$(code_count "$SELFTEST" 'static func runVoiceReady')" 1

# 隔离纪律（这条腿跑在用户机器上，弄脏用户库/改用户配置是不可接受的回归）：
expect_ge "就绪腿必须自建内存容器（isStoredInMemoryOnly，绝不碰用户库）" \
  "$(code_count "$SELFTEST" 'isStoredInMemoryOnly: true')" 1
expect_ge "就绪腿必须保存并还原全局偏好串（不给用户留配置污染）" \
  "$(code_count "$SELFTEST" 'savedGlobalRaw')" 2
expect_ge "就绪腿必须清理 finalize 产物（唯一写盘物）" \
  "$(code_count "$SELFTEST" 'writtenPaths')" 3

# 零真实 API：假 provider + 假 TTS 必须都在，且 provider 只支持 RewriteResultDTO
# （若哪天改成"顺手调真provider"，这句会红）。
expect_ge "就绪腿必须注入假 provider（RewriteProvider）" \
  "$(code_count "$SELFTEST" 'SelfRewriteProvider')" 1
expect_ge "就绪腿必须注入假 TTS 客户端" \
  "$(code_count "$SELFTEST" 'SelfFakeTTS')" 2
expect_eq "就绪腿的假 provider 不得触达真实网络客户端" \
  "$(code_count "$SELFTEST" 'QwenTTSClient|CosyVoiceTTSClient\(')" 0

# 核心判据 D3「零克隆调用」：必须有独立的克隆引擎调用计数判据，
# 少了它这条腿就退化成"没报错就算过"，正好丢掉它要防的那个回归。
expect_ge "D3 零克隆判据：必须独立统计克隆引擎(qwen-vc)调用数" \
  "$(code_count "$SELFTEST" 'vcCalls == 0')" 1

# rewriteService 必须可注入，否则就绪腿跑不了 rewrite() 全链路（M1a 计划遗留项的接缝）。
# 终判据：DubbingViewModel init 必须支持注入 rewriteService（默认值不变）。
# ⚠️ 这两条刻意用 `-F` 固定串而非正则：本条判据自身被这个坑绊过一次 ——
# BSD grep（macOS 自带）**不认 `\?`**（它只认 GNU 的 `\?` 可选量词扩展，BSD 按字面
# 「反斜杠+问号」处理），于是 `'…ScriptRewriteService\? = nil'` 恒匹配 0。
# 而不同调用方 PATH 里的 grep 可能不同（同一台机器上 shim grep 与 /usr/bin/grep
# 对同一模式给出相反结论），正则判据因此**随执行环境漂移**。
# 凡是「要匹配源码里的字面符号（? * ( ) | 等）」，一律走 -F，不写转义。
expect_ge "DubbingViewModel init 必须支持注入 rewriteService（默认值不变）" \
  "$(code_count_f "$DUB_VM" 'rewriteService: ScriptRewriteService? = nil')" 1
expect_ge "rewriteService 注入后必须仍回落生产实现 ScriptRewriteService()" \
  "$(code_count_f "$DUB_VM" 'rewriteService ?? ScriptRewriteService()')" 1

echo
echo "== G-C M3 原始 TTS 音频缓存（只缓存原始层、绝不复用成品 m4a）=="
RAW_CACHE_CORE="$CORE/RawAudioCache.swift"
RAW_CACHE_STORE="$ROOT/MixCut/Services/TTS/RawAudioCacheStore.swift"
expect_file "Core RawAudioCache 存在（键/LRU 判据纯值层）" "$RAW_CACHE_CORE"
expect_file "App RawAudioCacheStore 存在（磁盘动作层）" "$RAW_CACHE_STORE"

# ① 核心纪律：缓存原始层，**严禁**把成品 m4a 当缓存复用。
# 这是 M3 的全部价值所在 —— 成品与targetDuration/fps 强绑定（atempo+补帧），
# 同一文案在不同时长的分镜里复用成品会得到错误时长。
# 判据锚在**代码**上而非注释上（code_count 刻意剥掉注释行，注释里的声明不算证据）：
# 缓存目录必须是独立的 TTSCache（与成品 Dubs 分属不同命名空间），
# 且落盘后缀是 .audio（原始音频）而非 .m4a。
expect_ge "缓存目录必须与成品 Dubs 分离（独立命名空间，物理上不可能误用成品）" \
  "$(code_count_f "$RAW_CACHE_STORE" 'appendingPathComponent("TTSCache", isDirectory: true)')" 1
expect_ge "缓存落盘后缀必须是 .audio（原始音频），不得是 .m4a" \
  "$(code_count_f "$RAW_CACHE_STORE" '.audio')" 1
expect_ge "命中时必须复制副本（finalize 会删传入文件，直接给缓存真身会把缓存删空）" \
  "$(code_count "$RAW_CACHE_STORE" 'copyItem')" 1
expect_ge "命中路径必须复制到临时副本而非直接使用缓存路径" \
  "$(code_count "$DUB_VM" 'copyingTo')" 1

# ② 键的构成：engine+model+voice+textHash+rate 桶+采样率+格式，缺一即误命中。
expect_ge "Core 键必须含 engine 维度" "$(code_count_f "$RAW_CACHE_CORE" 'engine: Engine')" 1
expect_ge "Core 键必须含 model 维度" "$(code_count_f "$RAW_CACHE_CORE" 'model: String')" 1
expect_ge "Core 键必须含 voiceID 维度" "$(code_count_f "$RAW_CACHE_CORE" 'voiceID: String')" 1
expect_ge "Core 键必须含 sampleRate 维度" "$(code_count_f "$RAW_CACHE_CORE" 'sampleRate: Int')" 1
expect_ge "Core 键必须含 format 维度" "$(code_count_f "$RAW_CACHE_CORE" 'format: String')" 1
expect_ge "Core 键必须含 rate 分桶（否则命中率崩）" \
  "$(code_count_f "$RAW_CACHE_CORE" 'bucket(for rate: Double)')" 1

# ③ 键的构造只有一处（禁止 App 层自己拼 stem —— 拼错就是「界面显示已缓存却永远不命中」）。
expect_ge "键构造必须收口在 Core（App 层唯一入口）" \
  "$(code_count_f "$RAW_CACHE_CORE" 'normalizedTextHash')" 1

# ④ LRU 与孤儿判据必须在 Core（纯函数可单测），App 层只做磁盘动作。
expect_ge "LRU 淘汰判据必须在 Core" "$(code_count_f "$RAW_CACHE_CORE" 'func victims')" 1
expect_ge "App 层淘汰必须经 Core 判据（禁自己写淘汰顺序）" \
  "$(code_count "$RAW_CACHE_STORE" 'RawAudioCacheEvictor.victims')" 1

# ⑤ App 层不得出现第二份哈希实现（本仓最忌讳「两处各算」，一旦漂移缓存永不命中）。
expect_eq "App 层禁止自实现哈希/FNV（必须用 Core 的 fileStem）" \
  "$(code_count "$RAW_CACHE_STORE" '0x811c9dc5')" 0
expect_ge "App 层落盘文件名必须用 Core 的 fileStem" \
  "$(code_count "$RAW_CACHE_STORE" 'fileStem')" 1

# ⑥ pbxproj 四段登记（漏登记沙盒门禁假绿、真机才红）。
expect_ge "RawAudioCacheStore 必须四段登记进 project.pbxproj" \
  "$(grep -c 'RawAudioCacheStore\.swift' "$ROOT/MixCut.xcodeproj/project.pbxproj")" 4

# ⑦ 单测覆盖（RA 系列：键构成/分桶/归一化/LRU）。
expect_file "RawAudioCache 单测存在" "$TESTS/RawAudioCacheTests.swift"
expect_ge "RA 系列用例 ≥ 20 条" \
  "$(code_count "$TESTS/RawAudioCacheTests.swift" '@Test')" 20
expect_ge "rewriteService 注入后必须仍回落生产实现 ScriptRewriteService()" \
  "$(code_count_f "$DUB_VM" 'rewriteService ?? ScriptRewriteService()')" 1

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS 脚本管线守卫全部成立"
else
  echo "FAIL 有门未成立 —— 见上面 FAIL 条目"
fi
exit "$fail"
