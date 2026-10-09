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
expect_eq "删旧分镜只由入口按参数执行（抓的失败：取消点被挪到删除之后，会留下空库）" \
  "$(code_count_in_file "$IVM" 'context\.delete(video\.segments)')" 1
expect_eq "重建入口被两条链各调一次（1 定义 + 首跑 + 重跑 = 3）" \
  "$(code_count_in_file "$IVM" 'rebuildSegments(')" 3

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

if [ -f "$PBXPROJ" ]; then
  echo
  echo "== 工程引用（抓的失败：新源文件没进 App target 编译，运行时根本不存在）=="
  for f in AIResponseEvidence SegmentationCompleteness; do
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
