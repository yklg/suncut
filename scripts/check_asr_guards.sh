#!/usr/bin/env bash
# ASR 规则层的边界守卫（计划 v9 §10.4 TC-86 及其同族，本轮只做"纯函数层"那几条）
# 用法：  ./scripts/check_asr_guards.sh              正常校验
#         ./scripts/check_asr_guards.sh --selftest   在合成违规树上跑同一判据，必须变红
# GUARD_ROOT 可指向别的源码树根（selftest 用它跑探针）
set -uo pipefail

SELFTEST=0
for arg in "$@"; do
  [[ "$arg" == "--selftest" ]] && SELFTEST=1
done

ROOT="${GUARD_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CORE="$ROOT/Sources/MixCutCore"
FAILED=0

fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
pass() { echo "PASS $1"; }

# G1 规则层不得读写用户偏好存储（破一次，"下沉=可测"这条前提就废了）
# 只匹配真实用法：文档注释里也会写这个词（例如本策略的说明），数注释会把守卫变成误报机器
hits=$(grep -rn --include="*.swift" "UserDefaults\.standard" "$CORE" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$hits" == "0" ]]; then
  pass "G1 Sources/MixCutCore 内 UserDefaults.standard 命中数=0"
else
  fail "G1 Sources/MixCutCore 里用了 UserDefaults.standard（$hits 处）：偏好读写必须留在 App 侧 ASRSettings"
fi

# G2 规则层不得碰文件系统 / SwiftData / 子进程
for pat in 'FileManager' 'import SwiftData' 'Process()' 'KeychainHelper'; do
  hits=$(grep -rn "$pat" "$CORE/WhisperModelCatalog.swift" "$CORE/ASREngineDecision.swift" "$CORE/TextProvenance.swift" "$CORE/ASRPolicy.swift" "$CORE/SegmentTranscribeOutcome.swift" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$hits" == "0" ]]; then
    pass "G2 五个规则文件内无 '$pat'"
  else
    fail "G2 规则文件里出现 '$pat'（$hits 处）：读磁盘/读库的活只能由 App 侧做完再传入"
  fi
done

# G3 三条裁定项不许被静默改动（档位、默认偏好、根顺序）
if grep -q 'engineTier: String = "large-v3"' "$CORE/ASRPolicy.swift" 2>/dev/null; then
  pass "G3a 恒用档位仍是 large-v3"
else
  fail "G3a ASRPolicy.engineTier 不再是 \"large-v3\"（档位是用户裁定项，改动要回计划对齐）"
fi
if grep -q 'defaultPreference: ASRPreference = .local' "$CORE/ASRPolicy.swift" 2>/dev/null; then
  pass "G3b 默认偏好仍是强制本地"
else
  fail "G3b ASRPolicy.defaultPreference 被改动（默认引擎是用户裁定项）"
fi
if grep -q 'case userDirectory' "$CORE/WhisperModelCatalog.swift" 2>/dev/null \
   && grep -q 'case appBundle' "$CORE/WhisperModelCatalog.swift" 2>/dev/null; then
  pass "G3c 根类型里有 userDirectory/appBundle 两档（磁盘优先的前提）"
else
  fail "G3c ModelRoot 缺 userDirectory 或 appBundle"
fi

# G4 未校验档位不得放近似值冒充预期值
if grep -q 'expectedBytes: nil' "$CORE/WhisperModelCatalog.swift" 2>/dev/null; then
  pass "G4 未取到精确字节的档位以 nil 表示（没拿四舍五入值冒充）"
else
  fail "G4 表里找不到 expectedBytes: nil —— 要么精确值已取齐并更新了测试，要么有人塞了近似值"
fi

# G5 陈旧判定要有聚合入口（否则三个消费点各拼一次）
# 判据精确到**签名**而不是前缀：只写 'checkAll' 的话，改名成 checkAllDeprecated 仍然命中，守卫会假绿
if grep -q 'func checkAll(snapshot:' "$CORE/DubStaleness.swift" 2>/dev/null; then
  pass "G5 DubStaleness.checkAll 存在"
else
  fail "G5 缺少 DubStaleness.checkAll 聚合入口"
fi

# App 侧守卫的两个根。**必须先定义再用**：set -u 下引用未定义变量只会让命令替换空掉，
# 于是 grep 拿到空路径、守卫"全绿"——那是假防线（本项目栽过的那类形状）。
APP="$ROOT/MixCut"
ASR_DIR="$APP/Services/ASR"
for must in "$APP" "$CORE"; do
  if [[ ! -d "$must" ]]; then
    echo "FAIL 守卫根缺失：${must}（探针树没拷全，后面的判定不作数）"
    exit 1
  fi
done
# 逐文件前置：守卫里凡是 grep -c 单个文件的地方，**文件不存在时只会输出空串**，
# 于是判定"看起来通过了"。这是探针树最容易造出的假绿，必须先炸掉而不是让它比空值。
for must in "$CORE/ASRPolicy.swift" "$CORE/WhisperModelCatalog.swift" "$CORE/ASREngineDecision.swift" \
            "$CORE/TextProvenance.swift" "$CORE/DubStaleness.swift" "$CORE/AgentToolCatalog.swift" \
            "$ASR_DIR/ASRSettings.swift" "$ASR_DIR/ASRService.swift" "$ASR_DIR/SegmentTranscriber.swift" \
            "$APP/Models/Segment.swift" "$APP/Models/SegmentDub.swift" "$APP/Models/Video.swift" \
            "$APP/Services/MCP/MCPToolHandlers.swift" "$APP/Views/Settings/SettingsView.swift" \
            "$ROOT/scripts/build_universal_binaries.sh"; do
  if [[ ! -f "$must" ]]; then
    echo "FAIL 守卫要读的文件不存在：$must"
    exit 1
  fi
done

# ---------- 2c：逐段重听门面（R4/R5） ----------

# G13 云端客户端只许门面构造（TC-83）。DebugSelfTest 是 #if DEBUG 探针，进允许清单
bad=$(grep -rl --include="*.swift" 'QwenASRClient(' "$APP" 2>/dev/null | sed "s|$APP/||" \
      | grep -v '^Services/ASR/SegmentTranscriber.swift$' | grep -v '^App/DebugSelfTest.swift$' | sort | tr '\n' ' ')
if [[ -z "$bad" ]]; then
  pass "G13 云端 ASR 客户端只在门面里构造（VM 不再自己 new）"
else
  fail "G13 这些地方绕过门面自己连云端：${bad}（R4 破口 ⇒ 用哪台引擎的答案会分家）"
fi

# G14 逐段切音频也只许门面做（格式由引擎定，R5）：VM 里再出现切段调用就是第四处实现
bad=$(grep -rl --include="*.swift" 'extractSegmentPCM' "$APP" 2>/dev/null | sed "s|$APP/||" \
      | grep -v '^Services/ASR/SegmentTranscriber.swift$' \
      | grep -v '^Services/VideoProcessing/FFmpegRunner.swift$' \
      | grep -v '^App/DebugSelfTest.swift$' | sort | tr '\n' ' ')
if [[ -z "$bad" ]]; then
  pass "G14 逐段切音频只在门面里做（三处实现已收敛）"
else
  fail "G14 这些文件还在自己切逐段音频：${bad}"
fi

# G15 本机那条腿必须有"对已切好音频直接识别"的入口，否则门面只能整片重抽（慢且分家）
if grep -q 'func transcribeAudioFile(path:' "$ASR_DIR/ASRService.swift" 2>/dev/null \
   && grep -q 'transcribeAudioFile(path:' "$ASR_DIR/SegmentTranscriber.swift" 2>/dev/null; then
  pass "G15 ASRService.transcribeAudioFile 存在且被门面使用"
else
  fail "G15 本机逐段入口缺失或没接上（门面会退化回'只能跑云端'）"
fi

# G16 outcome 档位不许被就地拆成私有判据（分类只有核心层一个出处）
bad=$(grep -rn --include="*.swift" 'outcome == .replaced\|outcome != .replaced' "$APP/ViewModels" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$bad" == "0" ]]; then
  pass "G16 VM 只问 gotText，不自建 outcome 判据"
else
  fail "G16 有 $bad 处就地判 outcome==.replaced（分类规则会分家）"
fi

# ---------- 2d：能力面与打包链 ----------

# G17 红线 R7：打包脚本内置的模型必须与运行期裁定同一档（否则发布版与本机版跑的不是同一颗）
policy_file=$(grep -o 'engineFileName: String = "[^"]*"' "$CORE/ASRPolicy.swift" 2>/dev/null | sed 's/.*= "//; s/"$//')
script_file=$(grep -o 'WMODEL="\$DEST/[^"]*"' "$ROOT/scripts/build_universal_binaries.sh" 2>/dev/null | sed 's|.*DEST/||; s/"$//')
if [[ -n "$policy_file" && "$policy_file" == "$script_file" ]]; then
  pass "G17 打包内置模型 == ASRPolicy.engineFileName（${policy_file}）"
else
  fail "G17 打包链与运行期分家：脚本装的是 '${script_file:-取不到}'，ASRPolicy 裁定的是 '${policy_file:-取不到}'"
fi
# 精确体积闸门也要跟档位表同源（表里 large-v3 = 3,095,033,483）
wmin=$(grep -o '^WMIN=[0-9]*' "$ROOT/scripts/build_universal_binaries.sh" 2>/dev/null | cut -d= -f2)
if [[ -n "$wmin" && "$wmin" -le 3095033483 && "$wmin" -gt 2900000000 ]]; then
  pass "G17b 打包体积闸门 $wmin 落在 large-v3 真实字节数量级内"
else
  fail "G17b 打包体积闸门异常（${wmin}）：太低会把半截文件当成功，太高会把正常文件判成要重下"
fi

# G18 能力面只许问 `ASRSettings.hasCloudKey`（布尔），不许在 MCP 目录里直接读 Keychain
hits=$(grep -rn --include="*.swift" 'KeychainHelper' "$APP/Services/MCP" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$hits" == "0" ]]; then
  pass "G18 MCP 目录内零 KeychainHelper 引用（凭据只以布尔出现在能力面上，TC-100 的前提）"
else
  fail "G18 MCP 里直接读 Keychain（$hits 处）：能力面存在把 Key 片段带进返回值的风险"
fi

# G19 get_asr_status 必须"声明了、也接上了"——只在一处出现就是假工具
decl=$(grep -c 'name: "get_asr_status"' "$CORE/AgentToolCatalog.swift" 2>/dev/null || true)
wired=$(grep -c 'case "get_asr_status"' "$APP/Services/MCP/MCPToolHandlers.swift" 2>/dev/null || true)
if [[ "$decl" == "1" && "$wired" == "1" ]]; then
  pass "G19 get_asr_status 在目录声明 1 次、在派发接上 1 次"
else
  fail "G19 能力面接线不完整（声明 $decl / 派发 ${wired}）：写了却没人能跑 = 伪装成防线的死代码"
fi

# G20 陈旧联动的原因措辞不许在界面/能力面各写一遍
# 只算**代码**里的字符串：注释里引用这个词是为了说明"为什么要分两档"，数注释就把守卫变成误报机器
bad=$(grep -rn --include="*.swift" '"原台词变了"' "$APP" 2>/dev/null | awk -F: '{
        line=""; for (i=3; i<=NF; i++) line = line $i ((i<NF)?":" : "");
        gsub(/^[ \t]+/, "", line);
        if (line !~ /^\/\//) print
      }' | wc -l | tr -d ' ')
if [[ "$bad" == "0" ]]; then
  pass "G20 App 侧没有复写陈旧原因（一律用 StalenessReason.userText）"
else
  fail "G20 有 $bad 处在 App 侧硬写'原台词变了'：核心层改了措辞这边不会跟着变"
fi

# G6 档位名与下载 URL 只许住在核心表里（红线 R3/R7：出现第二份就会分家）
hits=$(grep -rn --include="*.swift" 'ggml-large\|ggml-base\|ggml-small\|ggml-medium' "$APP" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$hits" == "0" ]]; then
  pass "G6a App 侧无第二份 whisper 档位文件名"
else
  fail "G6a App 侧写死了 whisper 档位文件名（$hits 处）：档位只能来自 ASRPolicy/WhisperModelCatalog"
fi
hits=$(grep -rn --include="*.swift" 'https://hf-mirror\.com\|https://huggingface\.co' "$ASR_DIR" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$hits" == "0" ]]; then
  pass "G6b App 侧 ASR 目录内无第二份模型下载 URL"
else
  fail "G6b ASR 服务里硬编码了下载 URL（$hits 处）：换镜像/换档位会只改一处，正是本轮要消灭的形状"
fi

# G7 红线 R1：识别路径里不许有下载。downloadModelIfNeeded 只允许「1 处定义 + 设置页 1 处调用」
callers=$(grep -rl --include="*.swift" 'downloadModelIfNeeded' "$APP" 2>/dev/null | sed "s|$APP/||" | sort | tr '\n' ' ')
expected="Services/ASR/ASRService.swift Views/Settings/SettingsView.swift "
if [[ "$callers" == "$expected" ]]; then
  pass "G7a downloadModelIfNeeded 只有定义 + 设置页一个调用点"
else
  fail "G7a 下载调用点变了（实际：${callers}）：期望仅 设置页 触发，识别路径必须直接失败"
fi
hits=$(grep -c 'downloadModelIfNeeded' "$ASR_DIR/ASRService.swift" 2>/dev/null || true)
if [[ "$hits" == "1" ]]; then
  pass "G7b ASRService 内 downloadModelIfNeeded 只出现 1 次（即定义本身，识别路径已拆干净）"
else
  fail "G7b ASRService 里 downloadModelIfNeeded 出现 $hits 次（>1 说明识别路径又在偷偷下载）"
fi

# ---------- 2b：来源列 / 唯一写入口 / 陈旧联动 ----------

# G9 陈旧判定只能走聚合入口（计划 §3.3③：两处各拼一次 ⇒ 第三处必漏）
hits=$(grep -rn --include="*.swift" 'DubStaleness\.check(' "$APP" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$hits" == "0" ]]; then
  pass "G9 App 侧无 DubStaleness.check( 直调（一律走 checkAll）"
else
  fail "G9 又有消费点直调 check（$hits 处）：改写版与原台词两维会被拆开，其中一维会静默失效"
fi
# G10 唯一写入口靠**编译器**守：private(set) 在，类外写 Segment.text 直接编不过
if grep -q 'private(set) var text: String' "$APP/Models/Segment.swift" 2>/dev/null; then
  pass "G10a Segment.text 是 private(set)（外部赋值编不过，不需要再靠 grep 数裸赋值）"
else
  fail "G10a Segment.text 不再是 private(set)：唯一写入口退化成'约定'，10 个裸赋值点会长回来"
fi
if grep -q 'func setText(_ incoming: String, source: TranscriptSource)' "$APP/Models/Segment.swift" 2>/dev/null; then
  pass "G10b Segment.setText(_:source:) 存在且签名未变"
else
  fail "G10b 找不到 Segment.setText(_:source:)（签名变了要连同 10 个调用点与计划一起对齐）"
fi
hits=$(grep -rn '\.text\s*=[^=]' "$APP" --include='*.swift' 2>/dev/null | grep -v 'Models/Segment.swift' | grep -v 'sentences\[' | grep -v '\.text == ' | grep -vE 'self\.text\s*=[^=]' | wc -l | tr -d ' ')
if [[ "$hits" == "0" ]]; then
  pass "G10c 除 Segment 自身外没有 .text = 赋值（句子级载体 sentences[i].text 不在此列）"
else
  fail "G10c 出现 $hits 处类外 .text 赋值：请改走 setText(_:source:)"
fi

# G11 三个 schema 字段必须同轮在场（P1-5：半个来源体系比一次都不做更难解释）
missing=""
grep -q 'var textSourceRaw: String' "$APP/Models/Segment.swift" 2>/dev/null || missing="$missing Segment.textSourceRaw"
grep -q 'var generatedForSourceTextHash: String' "$APP/Models/SegmentDub.swift" 2>/dev/null || missing="$missing SegmentDub.generatedForSourceTextHash"
grep -q 'var asrEngineRaw: String' "$APP/Models/Video.swift" 2>/dev/null || missing="$missing Video.asrEngineRaw"
if [[ -z "$missing" ]]; then
  pass "G11 三个来源字段同轮在场（段级来源 / 配音原台词哈希 / 片级引擎标记）"
else
  fail "G11 缺字段：$missing —— 半个来源体系不允许当成渐进交付"
fi

# G12 来源列本身也只能被 setText 写（否则"来源"会与实际内容分家）
hits=$(grep -rn --include="*.swift" '\.textSourceRaw\s*=' "$APP" 2>/dev/null | grep -v 'Models/Segment.swift' | wc -l | tr -d ' ')
if [[ "$hits" == "0" ]]; then
  pass "G12 类外无 textSourceRaw 赋值（来源与内容同进同退）"
else
  fail "G12 有 $hits 处绕过 setText 直接改来源列"
fi

# G8 ASR 偏好只有一个存储宿主（SettingsView 走 @AppStorage(ASRSettings.preferenceKey)，不碰 standard）
hits=$(grep -c 'UserDefaults\.standard' "$ASR_DIR/ASRSettings.swift" 2>/dev/null || true)
if [[ "$hits" == "3" ]]; then
  pass "G8a ASRSettings 是唯一的 UserDefaults 读写点（get/set/remove 共 3 处）"
else
  fail "G8a ASRSettings 内 UserDefaults.standard 为 $hits 处（基线 3）：读法变了要连同本守卫与计划一起对齐"
fi
hits=$(grep -rn 'UserDefaults\.standard' "$ASR_DIR/ASRService.swift" "$ASR_DIR/QwenASRClient.swift" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$hits" == "0" ]]; then
  pass "G8b ASRService / QwenASRClient 不自己读偏好（否则出现第二个默认值）"
else
  fail "G8b ASR 服务里直接读 UserDefaults（$hits 处）"
fi
hits=$(grep -rl --include="*.swift" 'asr\.enginePreference' "$ROOT/MixCut" "$ROOT/Sources" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$hits" == "1" ]]; then
  pass "G8c 偏好 key 字面量全仓只出现 1 个文件（宿主唯一）"
else
  fail "G8c 偏好 key 字面量散落在 $hits 个文件：会出现第二个 key / 第二个默认值"
fi

# ============ 逐段重听的短窗对策（计划 v5 §守卫） ============

# G21 --prompt 的**使用点**全仓必须唯一，且就在 ASRService.swift（整片与逐段共用同一个进程构造器，别处传就分家）
# 取样面三件事，少一件这条门就说假话（2026-09-30 的恒红就是这么来的）：
#   ① 只扫 *.swift —— 旧写法 `grep -rl -- '--prompt' $APP` 会把包内 whisper、whisper-cpu 两颗二进制
#      当成命中文件（它们自带的帮助文本里有这个词），于是在真树上永远报"散落在 3 个文件"。
#   ② 盯字面量形态 `"--prompt"` 而不是词本身 —— 核心层那两处（ASRPolicy.swift、
#      SegmentTranscribeOutcome.swift）是文档注释里用反引号提它，属正当提及，不该算分家。
#   ③ 注释行再保险地滤一遍，免得有人拿注释试参数。
hits=$(grep -rn --include="*.swift" -F -- '"--prompt"' "$APP" "$CORE" 2>/dev/null \
       | grep -v ':[0-9]*:[[:space:]]*\(//\|///\|\*\)' || true)
n=$(printf '%s' "$hits" | grep -c .)
ufiles=$(printf '%s\n' "$hits" | cut -d: -f1 | sort -u | wc -l | tr -d ' ')
if [[ "$n" == "1" && "$ufiles" == "1" && "$hits" == *"/ASRService.swift:"* ]]; then
  pass "G21 --prompt 使用点唯一且在 ASRService.swift（注释提及不计）"
else
  fail "G21 --prompt 使用点 $n 处、分布在 $ufiles 个文件：识别参数必须只有一个出口（多出来的那份会让整片与逐段走两套设置）"
  printf '%s\n' "$hits" | sed 's/^/     /'
fi

# G22 风格锚字面量全仓只 1 处，且传给 --prompt 的实参不得是拼出来的
anchor_files=$(grep -rl --include="*.swift" '下面是一段简体中文口语旁白' "$ROOT/Sources" "$ROOT/MixCut" 2>/dev/null | wc -l | tr -d ' ')
prompt_line=$(grep -n -- '"--prompt"' "$ASR_DIR/ASRService.swift" 2>/dev/null | head -1)
if [[ "$anchor_files" == "1" ]] && [[ -n "$prompt_line" ]] \
   && ! grep -q -- '--prompt.*[+]\|--prompt.*\\(' <<<"$prompt_line"; then
  pass "G22 锚字面量唯一 + --prompt 实参不是拼接出来的"
else
  fail "G22 锚被复制或拼接（字面量出现在 $anchor_files 个文件）：邻居台词当 prompt 已被实测证明会写坏正确台词"
fi

# G23 锚与回吐判据只能由门面问核心层，VM 不许自己决定带不带锚
# （v8：这里原本数的是"算窗与裁回"，那套实现已随宽窗删除 ⇒ 判据对象换成锚这一族）
facade_hits=$(grep -c 'SegmentRetakeRule\.' "$ASR_DIR/SegmentTranscriber.swift" 2>/dev/null || true)
vm_hits=$(grep -rn --include="*.swift" 'SegmentRetakeRule\.' "$APP/ViewModels" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$facade_hits" -ge 2 ]] && [[ "$vm_hits" == "0" ]]; then
  pass "G23 锚与回吐判据只在门面里问核心层（$facade_hits 处），VM 零处"
else
  fail "G23 门面调用 $facade_hits 处、VM 出现 $vm_hits 处：调用方自己决定带不带锚就会与核心层分家"
fi

# G26 锚回吐判据只有一份（单测与探针共用，否则两边口径会分家）
def_hits=$(grep -rn --include="*.swift" 'func containsAnchorEcho' "$ROOT/Sources" "$ROOT/MixCut" 2>/dev/null | wc -l | tr -d ' ')
use_hits=$(grep -rn --include="*.swift" 'containsAnchorEcho' "$ASR_DIR" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$def_hits" == "1" ]] && [[ "$use_hits" -ge 1 ]]; then
  pass "G26 锚回吐判据唯一且被门面使用"
else
  fail "G26 锚回吐判据定义 $def_hits 处、使用 $use_hits 处：出现两份实现就等于没有判据"
fi

# G27 规则层的函数不得"只有测试在调"：无生产调用者就必须在定义处登记去向
# 守的形状：给一颗没人调的规则函数配一条绿测试，看着是防线，实际守的是死码（本轮 joinWordTexts 实测踩过）
RULE_FILE="$CORE/SegmentTranscribeOutcome.swift"
unaccounted=""
while read -r fname; do
  callers=$(grep -rn --include="*.swift" "$fname(" "$ROOT/MixCut" "$CORE" 2>/dev/null | grep -v "func $fname(" | wc -l | tr -d ' ')
  if [[ "$callers" == "0" ]]; then
    defline=$(grep -n "public static func $fname(" "$RULE_FILE" | head -1 | cut -d: -f1)
    if [[ -z "$defline" ]] || [[ "$(sed -n "$((defline - 1))p" "$RULE_FILE" | grep -c 'known-dead:')" == "0" ]]; then
      unaccounted="$unaccounted $fname"
    fi
  fi
done < <(awk '/public enum SegmentRetakeRule/,/^}/' "$RULE_FILE" | grep -o 'public static func [a-zA-Z]*' | awk '{print $4}')
if [[ -z "$unaccounted" ]]; then
  pass "G27 逐段重听规则层每个函数的调用去向都可查（有调用者，或已登记为何只有测试调）"
else
  fail "G27 SegmentRetakeRule 里这些函数只有测试在调且没登记去向：$unaccounted —— 单测绿不代表生产路径接了它"
fi

# （v8：这里原本还有 G28「裁回放行判据只由门面读」与 G29「keptCoverage 不许写死数字」两条，
#   它们守的是宽窗裁回那条路 ⇒ 随实现一起删除。守卫 41 → 37 项。）

if [[ "$SELFTEST" == "1" ]]; then
  if [[ "$FAILED" -gt 0 ]]; then
    echo "SELFTEST PASS：探针树上判据变红 $FAILED 条"
    exit 0
  fi
  echo "SELFTEST FAIL：探针树上的违规没被抓到（判据恒绿 = 假防线）"
  exit 1
fi

if [[ "$FAILED" -gt 0 ]]; then
  echo "ASR 规则层守卫：$FAILED 条失败"
  exit 1
fi
echo "ASR 规则层守卫：全绿"
