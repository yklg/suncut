#!/usr/bin/env python3
"""集成 / API 层功能门禁：用 JSON-RPC 直打活运行的 SunCut，不碰鼠标。

为什么在这一层测（2026-10-04 分层重排）：Mac2 黑盒 UI 自动化实测成本是每会话约 35 秒、
键盘通道打不进中文、点击对禁用控件静默无操作；而这 24 个工具本身就是功能语义的完整入口，
一次 HTTP 调用即覆盖同一功能面。UI 层只保留它唯一看得见的那 10 件事。

判据全部来自 2026-10-04 实测读数，不是照文档猜的：
  · 缺必填        → isError=true, code=INVALID_ARGUMENT
  · 多余未知参数  → **被静默接受**（isError=false）—— 现前台没有严格 schema 校验，本文件如实记为现状
  · 不存在的工具  → HTTP 200 + 工具层 INVALID_ARGUMENT（不是协议层 -32601）
  · GET /mcp      → HTTP 404，体长 9 字节
  · 同名产品      → 复用同一个 product_id
  · 不带 confirm  → requires_confirmation=true 且项目仍在

副作用纪律（照 stage0_concurrent_job_probe.sh）：
  tier=read     只读，永远跑
  tier=write    写库，只允许跑在假库实例上；本脚本结束会把自己建的项目删回去
  tier=dispatch 真派单（云端计费 / ffmpeg / 导出），必须同时给 --allow-dispatch 与
                --i-understand-real-calls，缺一个就拒绝执行

用法：
    python3 scripts/mcp_api_guards.py [--port 8787] [--catalog <路径>] [--list]
    python3 scripts/mcp_api_guards.py --allow-dispatch --i-understand-real-calls
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

PREFIX = "GUARD"  # 本脚本建的项目一律带此前缀，便于识别与清理
READ, WRITE, DISPATCH = "read", "write", "dispatch"

_results = []
_created = []  # [(port, project_id, name)]


class GuardFail(Exception):
    pass


# ---------------------------------------------------------------- JSON-RPC 客户端
class Client:
    def __init__(self, port):
        self.port = port
        self.url = "http://127.0.0.1:%d/mcp" % port
        self._id = 0

    def raw(self, method, params=None, timeout=60):
        self._id += 1
        body = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            body["params"] = params
        req = urllib.request.Request(self.url, data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
                                     method="POST")
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))

    def call(self, name, arguments=None, timeout=60):
        """返回 (isError, 内层 dict, 原始文本)。"""
        _status, payload = self.raw("tools/call", {"name": name, "arguments": arguments or {}}, timeout)
        result = payload.get("result") or {}
        content = result.get("content") or []
        text = content[0].get("text", "") if content else ""
        try:
            inner = json.loads(text) if text else {}
        except (ValueError, TypeError):
            inner = {"_raw": text}
        return bool(result.get("isError")), inner, text

    def create_project(self, name, product_name=None):
        arguments = {"name": name}
        if product_name:
            arguments["product_name"] = product_name
        is_err, inner, text = self.call("create_project", arguments)
        if is_err:
            raise GuardFail("create_project(%s) 失败：%s" % (name, text[:200]))
        pid = inner.get("id")
        if not pid:
            raise GuardFail("create_project 没返回 id：%s" % text[:200])
        _created.append((self.port, pid, name))
        return inner


# ---------------------------------------------------------------- 目录真源解析
def parse_catalog(path):
    """从 Swift 目录里解析出 {工具名: [必填字段...]}。解析不出来就抛错，绝不静默放行。"""
    if not os.path.isfile(path):
        raise GuardFail("取不到目录真源：%s" % path)
    text = open(path, encoding="utf-8").read()
    start = text.find("static let all:")
    if start < 0:
        raise GuardFail("目录真源里取不到 `static let all:` 锚点")
    end = text.find("\n    ]", start)
    body = text[start:end if end > start else len(text)]
    defs = re.findall(r'MCPToolDefinition\(\s*name:\s*"([A-Za-z0-9_\-]+)"(.*?)inputSchemaJSON:\s*#"(.*?)"#',
                      body, re.S)
    if len(defs) != len(re.findall(r'MCPToolDefinition\(', body)):
        raise GuardFail("目录解析漏抓：定义 %d 个、解出 %d 个"
                        % (len(re.findall(r'MCPToolDefinition\(', body)), len(defs)))
    catalog = {}
    for name, _mid, schema_raw in defs:
        try:
            schema = json.loads(schema_raw.replace('#"', '"').strip())
        except ValueError:
            schema = json.loads(re.sub(r'^"|"$', '', schema_raw))
        catalog[name] = list(schema.get("required") or [])
    return catalog


def expect(cond, msg):
    if not cond:
        raise GuardFail(msg)


# ---------------------------------------------------------------- 用例
def api01_tools_list_matches_catalog(c, ctx):
    """活服务报出的工具清单与代码里的目录真源逐一对齐。"""
    _status, payload = c.raw("tools/list")
    live = sorted(t["name"] for t in payload["result"]["tools"])
    truth = sorted(ctx["catalog"].keys())
    expect(live == truth, "名单不符 只在真源=%s 只在现前台=%s"
           % (sorted(set(truth) - set(live)), sorted(set(live) - set(truth))))
    return "%d 个工具逐项一致" % len(live)


def api02_get_rejected(c, ctx):
    """非 POST 一律 404，且不回 JSON-RPC 体。"""
    try:
        with urllib.request.urlopen(urllib.request.Request(c.url), timeout=10) as resp:
            raise GuardFail("GET 竞被接住：HTTP %d" % resp.status)
    except urllib.error.HTTPError as exc:
        body = exc.read()
        expect(exc.code == 404, "GET 期望 404，实际 %d" % exc.code)
        expect(b"jsonrpc" not in body, "404 里竞带了 JSON-RPC 体")
        return "HTTP 404，体长 %d 字节" % len(body)


def api03_unknown_method(c, ctx):
    """未知方法回协议层 -32601，HTTP 仍是 200。"""
    status, payload = c.raw("resources/list")
    expect(status == 200, "HTTP 期望 200，实际 %d" % status)
    expect((payload.get("error") or {}).get("code") == -32601, "期望 -32601，实际 %s" % payload)
    return "-32601 且 HTTP 200"


def api04_missing_required_per_tool(c, ctx):
    """逐个工具去掉一个必填字段 ⇒ 必须回 INVALID_ARGUMENT，不能 500、不能拖垮服务。"""
    checked = 0
    for name, required in ctx["catalog"].items():
        if not required:
            continue
        for field in required:
            # 用一个"字段存在但值非法"的探针绕开必填校验不可行，这里直接整体缺省该字段
            probe = {f: _dummy(f) for f in required if f != field}
            is_err, inner, text = c.call(name, probe, timeout=20)
            expect(is_err, "%s 缺必填 %s 竞没报错：%s" % (name, field, text[:120]))
            expect(inner.get("code") == "INVALID_ARGUMENT",
                   "%s 缺必填 %s 回了非 INVALID_ARGUMENT：%s" % (name, field, inner.get("code")))
            checked += 1
    return "覆盖 %d 个「缺必填」组合" % checked


def api05_error_codes_reachable(c, ctx):
    """错误码枚举里可低成本触达的几个，逐个确认真前台用得到。"""
    # 注意 job_id 必须给**格式合法但不存在**的 UUID：给 "no-such-job" 这种非 UUID，
    # 前台回的是 INVALID_ARGUMENT（"job_id 不是合法 UUID"）而不是 JOB_NOT_FOUND —— 那是
    # 参数校验层先拦下了，测不到"作业失踪"这条语义。（2026-10-04 实测）
    reachable = {"PROJECT_NOT_FOUND": ("get_project", {"project_id": "00000000-0000-0000-0000-000000000000"}),
                 "INVALID_ARGUMENT": ("get_project", {}),
                 "JOB_NOT_FOUND": ("get_job", {"job_id": "00000000-0000-0000-0000-000000000001"})}
    seen = []
    for code, (tool, args) in reachable.items():
        is_err, inner, text = c.call(tool, args, timeout=20)
        expect(is_err, "%s 应报错却没报" % tool)
        expect(inner.get("code") == code, "%s 期望码 %s，实际 %s（%s）" % (tool, code, inner.get("code"), text[:160]))
        seen.append(code)
    untested = sorted(set(ctx["all_codes"]) - set(seen))
    return "已确认可达 %s；其余 %s 需真实数据/派单，见 API-08/09" % (",".join(seen), ",".join(untested) or "-")


def api06_create_then_read_back(c, ctx):
    """建项目后回读，名称与 id 必须逐项一致。"""
    made = c.create_project(PREFIX + "-回读-A", PREFIX + "-产品-回读")
    _is_err, listed, text = c.call("list_projects")
    rows = listed.get("projects") or []
    row = next((r for r in rows if r.get("id") == made["id"]), None)
    expect(row is not None, "建出来的项目 list 不到：%s（%s）" % (made["id"], text[:160]))
    expect(row.get("name") == made["name"], "回读名称不符 %r != %r" % (row.get("name"), made["name"]))
    for field in ("status", "video_count", "segment_count", "scheme_count"):
        expect(field in row, "回读缺字段 %s" % field)
    return "id/名称/状态/三个计数齐全，status=%s" % row.get("status")


def api07_same_product_reused(c, ctx):
    """同名产品复用，不重复建。"""
    product = PREFIX + "-产品-复用"
    a = c.create_project(PREFIX + "-复用-A", product)
    b = c.create_project(PREFIX + "-复用-B", product)
    expect(a["product_id"] == b["product_id"],
           "同名产品竞建出两个 product_id：%s vs %s" % (a["product_id"], b["product_id"]))
    expect(a["id"] != b["id"], "两个项目 id 撞了")
    return "复用同一 product_id=%s…" % a["product_id"][:8]


def api08_job_gate_serializes(c, ctx):
    """全局唯一作业闸门：第二路派单必须拿 JOB_ALREADY_RUNNING。"""
    first = c.call("generate_schemes", {"project_id": ctx["seed_project"], "target_count": 2}, timeout=30)
    expect(not first[0], "第一路派单就失败：%s" % first[2][:200])
    job_id = first[1].get("job_id")
    expect(job_id, "没拿到 job_id：%s" % first[2][:200])
    second = c.call("generate_schemes", {"project_id": ctx["seed_project"], "target_count": 2}, timeout=30)
    expect(second[0] and second[1].get("code") == "JOB_ALREADY_RUNNING",
           "第二路竞没被闸门拦住：%s" % second[2][:200])
    ctx["jobs"].append(job_id)
    return "第二路正确拿到 JOB_ALREADY_RUNNING"


def api09_job_terminal_state(c, ctx):
    """作业终态可轮询、带报告，且状态机没有 pending。"""
    import time
    job_id = ctx["jobs"][0] if ctx["jobs"] else None
    expect(job_id, "没有可等的作业（API-08 未跑）")
    deadline = time.time() + 300
    last = None
    while time.time() < deadline:
        is_err, inner, text = c.call("get_job", {"job_id": job_id}, timeout=30)
        expect(not is_err, "get_job 报错：%s" % text[:200])
        last = inner
        if inner.get("state") != "running":
            break
        time.sleep(3)
    expect(last and last.get("state") in ("completed", "failed"),
           "300s 内没到终态，最后读数=%s" % json.dumps(last, ensure_ascii=False)[:200])
    expect("pending" not in json.dumps(last), "状态机竞出现 pending")
    return "终态=%s，带 report=%s" % (last.get("state"), bool(last.get("report")))


def api10_job_lost_after_restart(c, ctx):
    """重启后作业失踪，必须报 JOB_NOT_FOUND 并提示改查项目。"""
    is_err, inner, text = c.call("get_job", {"job_id": "00000000-0000-0000-0000-000000000000"}, timeout=20)
    expect(is_err and inner.get("code") == "JOB_NOT_FOUND", "失踪作业应报 JOB_NOT_FOUND，实际 %s" % text[:160])
    return "JOB_NOT_FOUND ✓（完整「派单后真重启」一档需门禁侧配合重启，标待生成）"


def api11_list_segments_requires_one_selector(c, ctx):
    """list_segments 的 project_id / video_id 二选一契约。"""
    is_err, inner, text = c.call("list_segments", {}, timeout=20)
    expect(is_err, "两个都不给竞没报错")
    expect(inner.get("code") == "INVALID_ARGUMENT", "期望 INVALID_ARGUMENT，实际 %s" % inner.get("code"))
    is_err2, inner2, text2 = c.call("list_segments",
                                    {"project_id": "00000000-0000-0000-0000-000000000000",
                                     "video_id": "00000000-0000-0000-0000-000000000000"}, timeout=20)
    expect(is_err2, "两个同时给竞没报错（契约写明同时提供报错）")
    return "都不给 / 都给 两种违规都被拒"


def api12_delete_needs_confirmation(c, ctx):
    """delete_project 不带 confirm 只回预览，一个字节都不删。"""
    made = c.create_project(PREFIX + "-删除预览", PREFIX + "-产品-删除")
    is_err, preview, text = c.call("delete_project", {"project_id": made["id"]})
    expect(not is_err, "预览竞报错：%s" % text[:200])
    expect(preview.get("requires_confirmation") is True, "预览没带 requires_confirmation：%s" % text[:200])
    _is_err, listed, _t = c.call("list_projects")
    still = [r for r in (listed.get("projects") or []) if r.get("id") == made["id"]]
    expect(still, "只发预览就把项目删了 —— 两步确认失效")
    c.call("delete_project", {"project_id": made["id"], "confirm": True})
    _is_err, listed2, _t2 = c.call("list_projects")
    gone = [r for r in (listed2.get("projects") or []) if r.get("id") == made["id"]]
    expect(not gone, "confirm=true 却没删掉")
    return "预览不删、confirm 才删，双向都对"


def api13_oversize_body_no_response(c, ctx):
    """超过 4MB 的请求体应在连接层失败，不给 HTTP 应答。"""
    pad = "x" * (5 * 1048576)
    body = json.dumps({"jsonrpc": "2.0", "id": 999, "method": "tools/call",
                       "params": {"name": "list_projects", "arguments": {"pad": pad}}},
                      ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(c.url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raise GuardFail("%d 字节请求体竞被接住（HTTP %d）—— 4MB 上限失效" % (len(body), resp.status))
    except urllib.error.HTTPError as exc:
        raise GuardFail("%d 字节请求体回了 HTTP %d 而不是断连" % (len(body), exc.code))
    except Exception as exc:
        return "连接层失败 %s（%d 字节请求体，无 HTTP 应答）" % (type(exc).__name__, len(body))


def api14_odd_names(c, ctx):
    """中文 / emoji / 超长 / 注入串项目名，建得成也读得回。"""
    names = {
        "CJK": "混剪冒烟-项目「带引号」，逗号",
        "emoji": PREFIX + "-🎬✨",
        "超长": PREFIX + "-" + "长" * 300,
        "注入串": PREFIX + "'; DROP TABLE ZPROJECT; --",
        "换行制表": PREFIX + "-a\nb\tc",
    }
    for tag, name in names.items():
        made = c.create_project(name, PREFIX + "-产品-怪名")
        _is_err, listed, text = c.call("list_projects")
        row = next((r for r in (listed.get("projects") or []) if r.get("id") == made["id"]), None)
        expect(row is not None, "%s 名建完读不回：%r" % (tag, name[:40]))
        expect(row.get("name") == name, "%s 名被改写：%r → %r" % (tag, name[:40], row.get("name")[:40]))
    return "%d 类怪名全部原样往返（含换行与注入串）" % len(names)


def api15_loopback_only(c, ctx):
    """服务必须只绑回环 —— 一旦转发等于把 delete_project 开放内网。"""
    out = subprocess.run(["lsof", "-nP", "-iTCP:%d" % c.port, "-sTCP:LISTEN"],
                         capture_output=True, text=True).stdout
    addrs = re.findall(r'\d+\.\d+\.\d+\.\d+:%d' % c.port, out)
    expect(addrs, "lsof 取不到 %d 端口的监听地址 —— 判据失效，不算通过" % c.port)
    bad = [a for a in addrs if not a.startswith("127.0.0.1")]
    expect(not bad, "服务竞监听在非回环地址：%s（删除面已暴露）" % bad)
    return "仅 127.0.0.1:%d 监听" % c.port


def api16_failed_job_has_message(c, ctx):
    """失败作业必须带人可读原因，且码在枚举内。"""
    is_err, inner, text = c.call("export_scheme",
                                 {"scheme_ids": ["00000000-0000-0000-0000-000000000000"],
                                  "output_dir": "/nonexistent-dir-for-guard"}, timeout=30)
    expect(is_err, "非法导出参数竞没报错：%s" % text[:200])
    expect(inner.get("code") in ctx["all_codes"],
           "错误码 %r 不在枚举表内" % inner.get("code"))
    expect(bool((inner.get("message") or "").strip()), "报错没有 message：%s" % text[:200])
    return "码=%s，message 非空" % inner.get("code")


def _dummy(field):
    if field.endswith("_ids") or field.endswith("_nos") or field.endswith("indexes"):
        return ["00000000-0000-0000-0000-000000000000"]
    if field in ("confirm", "keep_original", "participates"):
        return True
    if field in ("target_count", "frame_delta", "seconds"):
        return 1
    return "00000000-0000-0000-0000-000000000000"


CASES = [
    ("API-01", "活服务工具清单与目录真源一致", READ, api01_tools_list_matches_catalog),
    ("API-02", "非 POST 一律 404 且不带 JSON-RPC 体", READ, api02_get_rejected),
    ("API-03", "未知方法回 -32601、HTTP 仍 200", READ, api03_unknown_method),
    ("API-04", "逐工具缺必填回 INVALID_ARGUMENT 且不拖垮服务", READ, api04_missing_required_per_tool),
    ("API-05", "错误码枚举逐个可达", READ, api05_error_codes_reachable),
    ("API-06", "建项目后回读字段齐全", WRITE, api06_create_then_read_back),
    ("API-07", "同名产品复用不重复建", WRITE, api07_same_product_reused),
    ("API-08", "全局唯一作业闸门拦第二路", DISPATCH, api08_job_gate_serializes),
    ("API-09", "作业终态可轮询、带报告、无 pending", DISPATCH, api09_job_terminal_state),
    ("API-10", "失踪作业报 JOB_NOT_FOUND", READ, api10_job_lost_after_restart),
    ("API-11", "list_segments 二选一契约", READ, api11_list_segments_requires_one_selector),
    ("API-12", "删除两步确认：预览不删、confirm 才删", WRITE, api12_delete_needs_confirmation),
    ("API-13", "超 4MB 请求体在连接层失败", READ, api13_oversize_body_no_response),
    ("API-14", "中文/emoji/超长/注入/换行名原样往返", WRITE, api14_odd_names),
    ("API-15", "服务只绑回环，非回环监听即红", READ, api15_loopback_only),
    ("API-16", "失败作业带枚举内错误码与人话原因", READ, api16_failed_job_has_message),
]

ERROR_CODE_RE = re.compile(r'case \w+ = "([A-Z_]+)"')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--catalog", default=None)
    ap.add_argument("--only", help="只跑指定编号，逗号分隔")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--allow-dispatch", action="store_true")
    ap.add_argument("--i-understand-real-calls", action="store_true")
    ap.add_argument("--out", help="把结果写成 JSON 报告")
    args = ap.parse_args()

    if args.list:
        for cid, title, tier, _fn in CASES:
            print("%-8s %-9s %s" % (cid, tier, title))
        return 0

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    catalog_path = args.catalog or os.path.join(root, "Sources/MixCutCore/AgentToolCatalog.swift")
    c = Client(args.port)

    try:
        c.raw("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                             "clientInfo": {"name": "api_guards", "version": "1"}})
    except Exception as exc:
        sys.stderr.write("FAIL 连不上 127.0.0.1:%d —— 被测 App 没在跑？%s\n" % (args.port, exc))
        return 2

    try:
        catalog = parse_catalog(catalog_path)
        all_codes = ERROR_CODE_RE.findall(open(catalog_path, encoding="utf-8").read())
    except (GuardFail, OSError) as exc:
        sys.stderr.write("FAIL[判据失效] %s\n" % exc)
        return 2

    ctx = {"catalog": catalog, "all_codes": set(all_codes), "jobs": [], "seed_project": None}
    want = set(args.only.split(",")) if args.only else None
    passed = failed = skipped = 0

    for cid, title, tier, fn in CASES:
        if want and cid not in want:
            continue
        if tier == DISPATCH and not (args.allow_dispatch and args.i_understand_real_calls):
            print("%-8s SKIP  %-52s 需要 --allow-dispatch --i-understand-real-calls 双开关" % (cid, title))
            skipped += 1
            _results.append({"id": cid, "title": title, "tier": tier, "status": "skip"})
            continue
        if tier == DISPATCH and not (args.allow_dispatch or args.i_understand_real_calls):
            sys.stderr.write("FAIL 派单类要求两个开关同时给，缺一个即拒绝\n")
            return 3
        try:
            detail = fn(c, ctx)
            print("%-8s PASS  %-52s %s" % (cid, title, detail))
            _results.append({"id": cid, "title": title, "tier": tier, "status": "pass", "detail": detail})
            passed += 1
        except GuardFail as exc:
            print("%-8s FAIL  %-52s %s" % (cid, title, exc))
            _results.append({"id": cid, "title": title, "tier": tier, "status": "fail", "detail": str(exc)})
            failed += 1
        except Exception as exc:
            print("%-8s ERROR %-52s %s: %s" % (cid, title, type(exc).__name__, str(exc)[:160]))
            _results.append({"id": cid, "title": title, "tier": tier, "status": "error",
                             "detail": "%s: %s" % (type(exc).__name__, str(exc)[:200])})
            failed += 1

    # 清理本脚本建的项目（两步删除）。已经被用例自己删掉的算成功 ——
    # PROJECT_NOT_FOUND 在这里是"确实没留下垃圾"的证据，不是失败。
    leaked = 0
    for port, pid, name in list(_created):
        try:
            gc = Client(port)
            gc.call("delete_project", {"project_id": pid})
            is_err, inner, text = gc.call("delete_project", {"project_id": pid, "confirm": True})
            if is_err and inner.get("code") != "PROJECT_NOT_FOUND":
                print("清理失败 %-40s %s" % (name, text[:120]))
                leaked += 1
        except Exception as exc:
            print("清理失败 %s：%s" % (name, exc))
            leaked += 1
    if leaked:
        print("有 %d 个临时项目没清掉，会污染下一轮" % leaked)
        failed += leaked

    print("\n通过 %d / 失败 %d / 跳过 %d（共 %d 条，另有 %d 个临时项目已清理）"
          % (passed, failed, skipped, passed + failed + skipped, len(_created)))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump({"port": args.port, "passed": passed, "failed": failed, "skipped": skipped,
                       "cases": _results}, fh, ensure_ascii=False, indent=2)
        print("报告已写 %s" % args.out)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
