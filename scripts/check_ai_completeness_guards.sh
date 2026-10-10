#!/usr/bin/env bash
# AI 完整性守卫（计划 docs/superpowers/plans/2026-09-28-ai-empty-output-diagnosis.md v5 §10.3 守卫层）
#
# 用法：
#   ./scripts/check_ai_completeness_guards.sh                # 审当前工作树，应全绿
#   ./scripts/check_ai_completeness_guards.sh .scratch/before-ai-nested   # 自证：改前快照必须变红
#
# 每条判据都写明"它想抓哪一种失败"，期望值全部来自实测基线，不靠猜。

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
CLIENT="$ROOT/MixCut/Services/AI/OpenAICompatibleClient.swift"
PROVIDER="$ROOT/MixCut/Services/AI/AIProvider.swift"
ANALYSIS="$ROOT/MixCut/Services/AI/AIAnalysisService.swift"
MCPTOOLS="$ROOT/MixCut/Services/MCP/MCPToolHandlers.swift"
CORE="$ROOT/Sources/MixCutCore"
PBXPROJ="$ROOT/MixCut.xcodeproj/project.pbxproj"

failures=0

report_pass() { printf 'PASS  %s\n' "$1"; }
report_fail() { printf 'FAIL  %s（实际 %s，期望 %s）\n' "$1" "$2" "$3"; failures=$((failures + 1)); }

# 只数"代码行"：去掉以 // 或 /// 开头的整行注释，避免注释里提到字段名造成假命中
code_count_in_file() {
  local file="$1" pattern="$2" n
  [ -f "$file" ] || { echo "NOFILE"; return; }
  n=$(grep -h -- "$pattern" "$file" 2>/dev/null | grep -vcE '^[[:space:]]*(///|//)' || true)
  echo "${n:-0}"
}

# 按**出现次数**数，不是按行数：`A && A` 写在同一行，行数取样器看不见第二个 A（实测漏过一次）。
occ_count_in_file() {
  local file="$1" pattern="$2" n
  [ -f "$file" ] || { echo "NOFILE"; return; }
  n=$(grep -h -- "$pattern" "$file" 2>/dev/null | grep -o -- "$pattern" 2>/dev/null | wc -l | tr -d ' ')
  echo "${n:-0}"
}

code_count_in_dir() {
  local dir="$1" pattern="$2" n
  [ -d "$dir" ] || { echo "NODIR"; return; }
  n=$(grep -rh --include='*.swift' -- "$pattern" "$dir" 2>/dev/null | grep -vcE '^[[:space:]]*(///|//)' || true)
  echo "${n:-0}"
}

expect_min() {
  local label="$1" actual="$2" min="$3"
  if [ "$actual" != "NOFILE" ] && [ "$actual" != "NODIR" ] && [ "$actual" -ge "$min" ] 2>/dev/null; then
    report_pass "$label"
  else
    report_fail "$label" "$actual" ">= $min"
  fi
}

expect_zero() {
  local label="$1" actual="$2"
  if [ "$actual" = "0" ]; then
    report_pass "$label"
  else
    report_fail "$label" "$actual" "0"
  fi
}

# 计数型判据：光"≥1"抓不住"又多出一份拷贝"，必须钉死等于几。
expect_eq() {
  local label="$1" actual="$2" want="$3"
  if [ "$actual" = "$want" ]; then
    report_pass "$label"
  else
    report_fail "$label" "$actual" "$want"
  fi
}

echo "== 根因下沉（抓的失败：新规则写在没单测的 App 层 = 等于没测）=="
for f in AIResponseEvidence.swift SegmentationCompleteness.swift; do
  if [ -f "$CORE/$f" ]; then
    report_pass "$CORE/$f 存在"
  else
    report_fail "$CORE/$f 存在" "missing" "存在且可被 swift test 覆盖"
  fi
done

echo
echo "== TC-54 transport 不再把残缺正文当成功（抓的失败：空正文/截断被 return 出去）=="
# 旧形状：函数里维护一个局部 truncatedByLength 标记，最后照样 return content
expect_zero "sendRequest 里不再有 'var truncatedByLength = false' 局部形状" \
  "$(code_count_in_file "$CLIENT" 'var truncatedByLength = false')"
expect_zero "旧文案'AI 输出被 max_tokens 截断'（未经证实的因果推断）已消失" \
  "$(code_count_in_file "$CLIENT" 'AI 输出被 max_tokens 截断')"
expect_min "空正文有显式 throw" \
  "$(code_count_in_file "$CLIENT" 'throw AIProviderError.emptyModelOutput')" 1
expect_min "长度截断有显式 throw" \
  "$(code_count_in_file "$CLIENT" 'throw AIProviderError.outputTruncated')" 1

echo
echo "== TC-57 错误枚举覆盖失败形状 + 确定性失败不重试 =="
expect_min "AIProviderError 新增 3 个 case" \
  "$(( $(code_count_in_file "$PROVIDER" 'case emptyModelOutput') + $(code_count_in_file "$PROVIDER" 'case outputTruncated') + $(code_count_in_file "$PROVIDER" 'case incompleteResult') ))" 3
expect_min "重试循环先问 isDeterministic（否则一次失败烧三次调用）" \
  "$(code_count_in_file "$CLIENT" 'if error.isDeterministic { throw error }')" 1

echo
echo "== TC-55 判定唯一性（抓的失败：同一规则在 4 个 service 各写一遍）=="
# 截断判定必须只在 MixCutCore 的 AIResponseEvidence 里；App 层不许再碰这些上游字段名
expect_zero "App 层不再自己读 finish_reason" \
  "$(code_count_in_dir "$ROOT/MixCut" 'finish_reason')"
expect_zero "App 层不再自己读 stop_reason" \
  "$(code_count_in_dir "$ROOT/MixCut" 'stop_reason')"
expect_min "完整性审计的唯一实现在核心层" \
  "$(code_count_in_file "$CORE/SegmentationCompleteness.swift" 'func audit')" 1
expect_min "分镜链确实调用了审计（只此一处）" \
  "$(code_count_in_dir "$ROOT/MixCut" 'SegmentationCompleteness.audit')" 1
expect_zero "[基线型，非改前变红项] App 层没有自己重写段长/预算规则（防将来分叉）" \
  "$(code_count_in_dir "$ROOT/MixCut" 'maxSegmentSeconds')"
expect_min "18 秒规则的定义只在核心层一处" \
  "$(code_count_in_file "$CORE/SegmentationCompleteness.swift" 'static let promptSegmentLimit')" 1

# prompt 同源（抓的失败：模型听到的秒数与代码判的秒数各说各话，改一处忘另一处）
expect_zero "App 层不再自己写切分粒度的秒数文案" \
  "$(code_count_in_dir "$ROOT/MixCut" '目标片段时长：')"
# 数**调用形状**而不是名字：只 grep `granularityPromptBlock` 时，改名成
# `granularityPromptBlockXX()` 仍含该子串，判据会恒绿（本条判据自己就被变异验证抓出过这一点）。
expect_min "切分粒度整段由规划层 config 生成" \
  "$(code_count_in_file "$ANALYSIS" 'granularityPromptBlock()')" 1

# 两条审计轴必须分开（抓的失败：把规划层合并出来的长段读成"模型漏交付"）
expect_min "提案完整性审计仍在原位（模型漏交付的唯一判定处）" \
  "$(code_count_in_dir "$ROOT/MixCut" 'SegmentationCompleteness.audit(')" 1
expect_min "落库分区有自己的形状审计" \
  "$(code_count_in_dir "$ROOT/MixCut" 'SegmentPartitionAudit.audit(')" 1

echo
echo "== 分镜生产者唯一性（抓的失败：规则只插在一条链上，「重跑分析」绕过 = 同实体多处直写）=="
# 「短视频被切碎」「重跑绕过保护」这两个症状同根：Segment 此前在 5 处直接构造，
# 任何分镜规则都要逐点插一遍，漏一处就分叉。现在只允许 SegmentCommitter 一家构造。
COMMITTER="$ROOT/MixCut/Services/Import/SegmentCommitter.swift"
# 盲区如实写明：只认 `= Segment(` 这个形状；写在数组字面量或裸返回表达式里的
# `Segment(...)` 不带 `= ` 前缀，本判据抓不到。新增构造点若走那种形状，靠 review 兜。
expect_zero "App 层裸构造 Segment 只允许出现在 SegmentCommitter 内部" \
  "$(( $(code_count_in_dir "$ROOT/MixCut" '= Segment(') - $(code_count_in_file "$COMMITTER" '= Segment(') ))"
expect_min "SegmentCommitter 已被 App target 编译（漏挂 pbxproj 时引用方报 cannot find type）" \
  "$(grep -c 'SegmentCommitter.swift in Sources' "$PBXPROJ")" 1

# 控制流也只许一份：W1 收了建段，W1.5 收「AI→落库→逐段重认→缩略图」这条链。
# 这里数的是"某形状出现几次"而不是"有没有"——再拷出一条控制流时数量会变，当场就能认出来。
IVM="$ROOT/MixCut/ViewModels/ImportViewModel.swift"
expect_eq "分镜重建入口只有一份实现（抓的失败：又拷出一条控制流）" \
  "$(code_count_in_file "$IVM" 'commitAIPartition(')" 1
# 指纹必须带**接收者**并转义点号：裸写 `.analyzeVideo(` 里的 `.` 是正则元字符，
# 会把函数定义 `func analyzeVideo(` 和编排调用 `self.analyzeVideo(video)` 一起数进来（实测 4）。
expect_eq "AI 分镜调用点只剩入口里那一处（抓的失败：重跑链自己另调一次 analyzeVideo）" \
  "$(code_count_in_file "$IVM" 'aiAnalysis\.analyzeVideo(')" 1
expect_eq "删旧分镜只出现在重建入口的两条分支里（各 1 处，取消点都必须早于它）" \
  "$(code_count_in_file "$IVM" 'context\.delete(video\.segments)')" 2
expect_eq "重建入口被两条链各调一次（1 定义 + 首跑 + 重跑 = 3）" \
  "$(code_count_in_file "$IVM" 'rebuildSegments(')" 3

# 顺序判据：整片保留的价值就是省下那次付费调用，判定一旦挪到 analyzeVideo 之后，
# 规则照样生效、钱照样烧 —— 只数"存不存在"抓不到这种挪法。
KEEP_LINE=$(grep -n -- 'shouldKeepWholeVideo' "$IVM" 2>/dev/null | head -1 | cut -d: -f1)
AI_LINE=$(grep -n -- 'aiAnalysis\.analyzeVideo(' "$IVM" 2>/dev/null | head -1 | cut -d: -f1)
if [ -z "$KEEP_LINE" ] || [ -z "$AI_LINE" ]; then
  report_fail "整片保留判定排在调模型之前（取不出行号 ⇒ 判据失效，不算通过）" "缺锚点" "两处都在"
else
  ORDER_BAD=0
  [ "$KEEP_LINE" -lt "$AI_LINE" ] || ORDER_BAD=1
  expect_zero "整片保留判定排在调模型之前（挪到之后＝省不到这次调用）" "$ORDER_BAD"
fi

echo
echo "== 失败留证（抓的失败：证据自毁，事后无从复盘）=="
expect_min "落盘用原始响应体而不是只有正文" \
  "$(code_count_in_file "$CLIENT" 'evidence.rawBody')" 1
expect_min "留证目录有轮转上限（不无限堆积用户台词原文）" \
  "$(code_count_in_file "$CLIENT" 'maxFailureArtifacts')" 1

echo
echo "== TC-47 前置：MCP job 面如实回读视频状态（抓的失败：视频失败但 job 报 completed）=="
expect_min "retryPipeline 里出现 video.status == .failed 判定" \
  "$(code_count_in_file "$MCPTOOLS" 'video.status == .failed')" 1
expect_min "retryPipeline 会走 registry.fail 而不只是 finish" \
  "$(code_count_in_file "$MCPTOOLS" 'registry.fail(')" 3

echo
echo "== 分镜链的补值留痕（抓的失败：默认值冒充模型给的数据）=="
expect_min "AnnotatedSegment 记录分数是否真来自模型" \
  "$(code_count_in_file "$ANALYSIS" 'scoreFromModel')" 2
expect_min "lossless 解码累计被丢弃的条数" \
  "$(code_count_in_file "$ANALYSIS" 'skippedUnparsableCount')" 2

echo
echo "== 思考开关与输出预算（抓的失败：界面关了思考、请求里没发出去，推理把 max_tokens 吃光）=="
# 一手证据：两次 AI 切分失败都是 completion=8192 被 reasoning_content(12529~15744 字符) 占满。
# 全部用 code_count_in_file：这些词在文档注释里也会出现，数注释等于造误报机器。
expect_eq "兼容分支真的在用那份预算（不是又写死一个数）" \
  "$(code_count_in_file "$CLIENT" '"max_tokens": providerMaxTokens$')" 1
expect_eq "预算的取值只由 Core 那一张表决定" \
  "$(code_count_in_file "$CLIENT" 'AIThinkingPolicy\.maxOutputTokens')" 1
expect_eq "客户端里 max_tokens 的字面量只许出现在 Claude 原生那条分支" \
  "$(code_count_in_file "$CLIENT" '"max_tokens":')" 2
expect_eq "思考参数按形态分发（只有一个读者）" \
  "$(code_count_in_file "$CLIENT" 'thinkingWireShape(model:')" 1
expect_eq "DeepSeek/Anthropic 形态真的把 enabled|disabled 发出去" \
  "$(code_count_in_file "$CLIENT" '"type": thinkingEnabled ? "enabled" : "disabled"')" 1
expect_eq "App 侧能力表把判断交给 Core（不许两处各判一次）" \
  "$(code_count_in_file "$PROVIDER" 'AIThinkingPolicy\.supportsToggle')" 1
# 这条是当初把用户坑了的旧断言："DeepSeek 无参数可切换思考" —— 官方文档相反，回来一次就红一次
expect_zero "旧的\"思考由模型本身决定、无参数可切换\"表不许复活" \
  "$(code_count_in_file "$PROVIDER" 'case .minimax, .deepseek, .claudeRelay, .custom:')"
# 2026-10-09 现场：一次切分请求挂到进程被杀都没回来（timeoutInterval 不管响应体，默认 resource 是 7 天）
expect_eq "AI 请求带真正的总截止（resource 超时）" \
  "$(code_count_in_file "$CLIENT" 'config\.timeoutIntervalForResource = AIRequestDeadline\.seconds')" 1
expect_zero "不许退回 URLSession.shared（那个会话没有总截止）" \
  "$(code_count_in_file "$CLIENT" 'URLSession\.shared')"
expect_eq "限流要有日志（否则事后分不清 429 与网络挂）" \
  "$(code_count_in_file "$CLIENT" 'AI 被限流 HTTP 429')" 1
expect_eq "网络层失败要有日志（原来静默重试，17 分钟只留下一行'重试第 1 次'）" \
  "$(code_count_in_file "$CLIENT" 'AI 请求第')" 1

echo
echo "== 成本可见：每个 AI 调用申报场景，且白跑的那次也先落账 =="
# 判的是"调用点数 - 场景申报数 = 0"，不是"至少有一处申报"：后者会让漏报的调用点永远隐身
call_sites=$( { grep -rn --include='*.swift' 'generateJSON(\|generateText(' "$ROOT/MixCut" \
  | grep -v 'func generate' | grep -v 'protocol AIProvider' || true; } | wc -l | tr -d ' ')
undeclared=$(( call_sites - $(code_count_in_dir "$ROOT/MixCut" 'scene: \.') ))
if [ "$call_sites" = "0" ]; then
  report_fail "AI 调用点取样面取不出数（判据失效，不算通过）" "0" "> 0"
else
  expect_zero "没申报场景的 AI 调用点" "$undeclared"
fi
expect_eq "用量落账点全工程只有一处（多处各写一行，口径当天分家）" \
  "$(code_count_in_file "$CLIENT" 'AIUsageRecord(')" 1
# 顺序判据：白跑（空正文/截断）照样计费，所以落账必须发生在抛错**之前**；
# 反过来写就会变成"抛了错，这一笔再也没进过账本"
rec_line=$(grep -n 'MixLog.info(AIUsageRecord(' "$CLIENT" | head -1 | cut -d: -f1)
throw_line=$(grep -n 'AIProviderError\.emptyModelOutput(evidence:' "$CLIENT" | head -1 | cut -d: -f1)
if [ -z "$rec_line" ] || [ -z "$throw_line" ]; then
  report_fail "落账必须早于抛错（行号取不出 ⇒ 判据失效）" \
    "落账=${rec_line:-取不出} 抛错=${throw_line:-取不出}" "两行都在且落账 < 抛错"
elif [ "$rec_line" -lt "$throw_line" ]; then
  report_pass "落账($rec_line) 早于空正文抛错($throw_line) ⇒ 白跑的那笔也在账上"
else
  report_fail "落账必须早于抛错" "落账=$rec_line 抛错=$throw_line" "落账 < 抛错"
fi

echo
echo "== 判死只认丢失；超长交给规划层切（抓的失败：拿形状代理误杀整条素材）=="
# 实测：`第 16 段 24.20s 超 18.00s 且吞到片尾` 判死过一条素材，而同趟一手用量写着"成功 completion=1969"
expect_eq "判死分支只有 isProvablyIncomplete 一个入子（行尾带 { 才算没有 || 连档）" \
  "$(code_count_in_file "$ANALYSIS" 'if SegmentationCompleteness\.isProvablyIncomplete(gaps) {')" 1
expect_eq "形状代理只剩告警那一个读者（回到判死分支就重新误杀）" \
  "$(code_count_in_file "$ANALYSIS" 'showsTruncationSignature')" 1
expect_eq "规划层的「超长再切」被执行器真的调用" \
  "$(code_count_in_file "$COMMITTER" 'SegmentationPlanner\.splitOverLong(')" 1
expect_eq "切出来的块按 origin 回溯源提案（下标漂了标签就会静默错位）" \
  "$(code_count_in_file "$COMMITTER" 'split\[\$0\]\.origin')" 1
# 留痕的可观测性：整份历史日志里 grep「过碎」零命中（计划 §AD）⇒ 规则只把结论写进库字段，
# 外面看不见；取证就得开 sqlite3 读列，而这既不可复现也不是用户能看到的东西。
IMPORTVM="$ROOT/MixCut/ViewModels/ImportViewModel.swift"
expect_eq "规划层改写过形状必须落一行日志（只进库字段 = 等于没留痕）" \
  "$(code_count_in_file "$IMPORTVM" '分镜规划改写')" 1
note_line=$(grep -n 'video.segmentationGuardNote = commit.appliedRules.isEmpty' "$IMPORTVM" | head -1 | cut -d: -f1)
log_line=$(grep -n 'MixLog.info(" 分镜规划改写' "$IMPORTVM" | head -1 | cut -d: -f1)
if [ -z "$note_line" ] || [ -z "$log_line" ]; then
  report_fail "留痕日志必须晚于留痕赋值（行号取不出 ⇒ 判据失效）" \
    "赋值=${note_line:-取不出} 日志=${log_line:-取不出}" "两行都在且 赋值 < 日志"
elif [ "$note_line" -lt "$log_line" ]; then
  report_pass "先赋值($note_line) 再落日志($log_line)（反过来就会永远读到 nil）"
else
  report_fail "日志必须落在赋值之后" "赋值=$note_line 日志=$log_line" "赋值 < 日志"
fi
# 顺序判据：先切后并。反过来会把刚按句子边界切开的块又并回去，分区形状取决于谁先跑
split_line=$(grep -n 'SegmentationPlanner\.splitOverLong(' "$COMMITTER" | head -1 | cut -d: -f1)
plan_line=$(grep -n 'SegmentationPlanner\.plan(segments: planTimings' "$COMMITTER" | head -1 | cut -d: -f1)
if [ -z "$split_line" ] || [ -z "$plan_line" ]; then
  report_fail "先切后并（行号取不出 ⇒ 判据失效）" \
    "切=${split_line:-取不出} 并=${plan_line:-取不出}" "两行都在且 切 < 并"
elif [ "$split_line" -lt "$plan_line" ]; then
  report_pass "先切($split_line) 后并($plan_line)"
else
  report_fail "必须先切后并" "切=$split_line 并=$plan_line" "切 < 并"
fi

echo
echo "== 单价与金额：价表只住 Core，App 不许自己算钱（抓的失败：两处各一套价/口径）=="
expect_zero "App 层不许出现单价字段（价表只有一个出处）" \
  "$(code_count_in_dir "$ROOT/MixCut" 'inputPerMTokens')"
expect_eq "客户端查表传价恰好一处" \
  "$(code_count_in_file "$CLIENT" 'AIPriceTable\.price(')" 1
expect_zero "客户端不许自己算金额（只能把单价交给记录去算）" \
  "$(code_count_in_file "$CLIENT" 'AICostCalculator')"
expect_eq "查价表全 App 只有一个读者（多处各查一次，口径当天分家）" \
  "$(code_count_in_dir "$ROOT/MixCut" 'AIPriceTable')" 1

echo
echo "== 连贯性校验（抓的失败：prompt 让模型自检，程序侧只验结构）=="
SCHEME="$ROOT/MixCut/Services/SchemeGeneration/SchemeGenerationService.swift"
CONT="$CORE/NarrativeContinuity.swift"
expect_eq "结构门与连贯门都在（两道门不许退成一道）" \
  "$(occ_count_in_file "$SCHEME" 'NarrativeStructureEngine.isValidVariant(')" 1
expect_eq "两条生成路径都被连贯性门接住（批量 + 叙事各一处）" \
  "$(occ_count_in_file "$SCHEME" 'NarrativeContinuity.issues(')" 2
expect_eq "判出问题就判死，不许只打日志放行（两条路各一处 guard）" \
  "$(occ_count_in_file "$SCHEME" 'guard issues.isEmpty else')" 2
expect_eq "批量路径真的拿到别名表（拿不到就是门被静默关掉）" \
  "$(occ_count_in_file "$ROOT/MixCut/ViewModels/SchemeViewModel.swift" 'segmentByAlias:')" 1
expect_zero "App 层不许再手写 SegmentDescriptor 逐字段构造（工厂只一处）" \
  "$(code_count_in_dir "$ROOT/MixCut" 'tags: seg\.semanticTypes')"
expect_zero "不许绕过 issues 另开一个入口（判据只有一份）" \
  "$(code_count_in_file "$SCHEME" 'NarrativeContinuity.hardIssues(')"
# 跳切规则已按一手读数作废（同素材跳空中位数 26.6s、最大 87.0s —— 正常产出全被点名）。
# 判据钉的是"这条主观线不许换个名字回来"：Core 里不许再有跳空阈值/hard-soft 分层。
expect_zero "跳空阈值不许留在 Core（多少秒算跳是拍脑袋，不是事实）" \
  "$(code_count_in_file "$CONT" 'jumpThresholdSeconds')"
expect_zero "sourceJump 规则不许复活（现场证据：它判的是常态不是缺陷）" \
  "$(code_count_in_file "$CONT" 'sourceJump')"
expect_zero "连贯性不许再分 hard/soft（只剩事实性两条，分层就是给主观线留门）" \
  "$(code_count_in_file "$CONT" 'isHard')"
expect_zero "软告警分支不许回来（判了不判死 = 日志里堆没人看的告警）" \
  "$(code_count_in_file "$SCHEME" 'for soft in issues')"

if [ -f "$PBXPROJ" ]; then
  echo
  echo "== 工程引用（抓的失败：新源文件没进 App target 编译，运行时根本不存在）=="
  for f in AIResponseEvidence SegmentationCompleteness AIThinkingPolicy AIUsageRecord AIModelPricing NarrativeContinuity; do
    expect_min "$f.swift 在 Sources 编译阶段被登记" \
      "$(grep -c "$f.swift in Sources" "$PBXPROJ")" 2
  done
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "ALL PASS（${ROOT}）"
  exit 0
else
  echo "共 $failures 条不达标（${ROOT}）"
  exit 1
fi
