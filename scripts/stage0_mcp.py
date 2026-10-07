#!/usr/bin/env python3
"""档 0 取证③的 MCP 探针助手（一次性脚手架，只碰现有前台，不碰产品码）。

存在的理由：shell 里解析 JSON-RPC 会写出一堆 sed 魔法，而那些魔法正是"看着过了其实没验"
的温床。这里把 JSON 处理收在一处，shell 只负责编排与判据。

子命令：
    tools-count                        现前台报出的工具数
    get-code <路径>                     对某个 GET 路径只报 HTTP 码（看现壳会不会给文件）
    oversize <MB>                       发一个超大 POST body，看连接是被断还是回错（4MB 上限那一条）
    call <工具名> '<json参数>'            一行打印 isError / code / job_id / 摘要
    concurrent <路数> [工具名] [参数json]  并发只读调用，报延迟分布与"像串行还是像并行"
    ping                                服务在不在听（不在就非 0 退出）
"""

import json
import statistics
import sys
import time
import urllib.error
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
ARGV = sys.argv[2:]
URL = "http://127.0.0.1:%d/mcp" % PORT
_id = [0]


def envelope(method, name=None, arguments=None):
    _id[0] += 1
    body = {"jsonrpc": "2.0", "id": _id[0], "method": method}
    if name is not None:
        body["params"] = {"name": name, "arguments": arguments or {}}
    return json.dumps(body, ensure_ascii=False).encode("utf-8")


def post(data, timeout=30):
    req = urllib.request.Request(URL, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    return urllib.request.urlopen(req, timeout=timeout)


def one_call(name, arguments):
    t0 = time.time()
    with post(envelope("tools/call", name, arguments)) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    return payload, time.time() - t0


def unwrap(payload):
    """把 MCP 的 result.content[0].text 再解一层 JSON（工具层结构化错误就在这里面）。"""
    result = payload.get("result") or {}
    content = result.get("content") or []
    text = content[0].get("text", "") if content else ""
    try:
        inner = json.loads(text)
    except (ValueError, TypeError):
        inner = {}
    return bool(result.get("isError")), inner, text


def cmd_ping():
    with post(envelope("initialize")) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    info = body.get("result", {})
    print("在线 协议=%s 服务=%s" % (
        info.get("protocolVersion"),
        (info.get("serverInfo") or {}).get("name")))
    return 0


def cmd_tools_count():
    with post(envelope("tools/list")) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    tools = body.get("result", {}).get("tools", [])
    print("工具数=%d" % len(tools))
    print("名单=" + ",".join(t.get("name", "?") for t in tools))
    return 0


def cmd_get_code(path):
    req = urllib.request.Request(URL if path == "" else
                                 "http://127.0.0.1:%d%s" % (PORT, path))
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print("HTTP=%d 长度=%s" % (resp.status,
                                       resp.headers.get("Content-Length")))
    except urllib.error.HTTPError as exc:
        print("HTTP=%d 长度=%s" % (exc.code,
                                   exc.headers.get("Content-Length")))
    except Exception as exc:
        print("无 HTTP 应答（连接层失败）：%s" % type(exc).__name__)
        return 1
    return 0


def cmd_oversize(mb):
    n = int(float(mb) * 1048576)
    # 拿一个合法的 JSON-RPC 外壳，把 arguments 撑到 n 字节，避免"格式错"混进判据
    pad = "x" * max(0, n - 80)
    body = envelope("tools/call", "list_projects", {"pad": pad})
    t0 = time.time()
    try:
        with post(body, timeout=60) as resp:
            print("HTTP=%d（%d 字节请求体居然被接住）" % (resp.status, len(body)))
    except urllib.error.HTTPError as exc:
        print("HTTP=%d（%d 字节请求体回错误码）" % (exc.code, len(body)))
    except Exception as exc:
        # 种类要打得能复核：URLError 是壳，真原因常在 reason 里，两次跑可能显示不同壳
        print("连接被断/无 HTTP 应答：%s: %s（%d 字节请求体，用时 %.2fs）"
              % (type(exc).__name__, str(exc)[:180], len(body), time.time() - t0))
        return 7
    return 0


def cmd_job_state(job_id):
    """只取 state。不复用 call 的摘要行：载荷按字母序排，截断会把 state 切掉，
    那样"未知"会被误读成"还在跑"，轮询读数就失真。"""
    payload, elapsed = one_call("get_job", {"job_id": job_id})
    _is_err, inner, _text = unwrap(payload)
    state = inner.get("state") or "无字段"
    kind = inner.get("kind") or "-"
    print("%s kind=%s 用时=%.2fs" % (state, kind, elapsed))
    return 0


def cmd_call(name, args_json):
    arguments = json.loads(args_json or "{}")
    payload, elapsed = one_call(name, arguments)
    is_err, inner, text = unwrap(payload)
    job = inner.get("job_id") or inner.get("id") or "-"
    code = inner.get("code") or inner.get("error_code") or "-"
    summary = text[:160].replace("\n", " ")
    print("isError=%s code=%s job_id=%s 用时=%.2fs" % (is_err, code, job, elapsed))
    print("载荷摘要=%s" % summary)
    return 1 if is_err else 0


def cmd_concurrent(n, name="list_projects", args_json="{}"):
    arguments = json.loads(args_json or "{}")
    threads = []
    results = []
    import threading

    def run():
        try:
            payload, elapsed = one_call(name, arguments)
            is_err, _, _ = unwrap(payload)
            results.append((elapsed, is_err))
        except Exception as exc:
            results.append((float("nan"), "exc:%s" % type(exc).__name__))

    t0 = time.time()
    for _ in range(n):
        th = threading.Thread(target=run)
        th.start()
        threads.append(th)
    for th in threads:
        th.join()
    wall = time.time() - t0

    good = [r for r in results if isinstance(r[1], bool) and not r[1]]
    bad = len(results) - len(good)
    lat = sorted(r[0] for r in results if r[0] == r[0])
    if not lat:
        print("全失败：%s" % results[:3])
        return 1
    total = sum(lat)
    print("路数=%d 成功=%d 失败=%d" % (n, len(good), bad))
    print("单次延迟 min=%.3fs 中位=%.3fs max=%.3fs"
          % (lat[0], statistics.median(lat), lat[-1]))
    print("并发总墙钟=%.3fs 各次之和=%.3fs 之和/墙钟=%.2f"
          % (wall, total, total / wall if wall else 0))
    print("读法：比值接近 1 = 被串行化了（各次排队走完）；比值接近路数 = 真并行。")
    return 0


def main():
    if not ARGV:
        sys.stderr.write("FAIL 缺子命令\n")
        return 2
    cmd = ARGV[0]
    try:
        if cmd == "ping":
            return cmd_ping()
        if cmd == "tools-count":
            return cmd_tools_count()
        if cmd == "get-code":
            return cmd_get_code(ARGV[1] if len(ARGV) > 1 else "/")
        if cmd == "oversize":
            return cmd_oversize(ARGV[1] if len(ARGV) > 1 else "6")
        if cmd == "call":
            return cmd_call(ARGV[1], ARGV[2] if len(ARGV) > 2 else "{}")
        if cmd == "job-state":
            return cmd_job_state(ARGV[1])
        if cmd == "concurrent":
            return cmd_concurrent(int(ARGV[1]),
                                  ARGV[2] if len(ARGV) > 2 else "list_projects",
                                  ARGV[3] if len(ARGV) > 3 else "{}")
    except urllib.error.HTTPError as exc:
        sys.stderr.write("FAIL HTTP %s\n" % exc.code)
        return 1
    except Exception as exc:
        sys.stderr.write("FAIL %s: %s\n" % (type(exc).__name__, exc))
        return 1
    sys.stderr.write("FAIL 未知子命令：%s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
