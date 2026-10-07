#!/usr/bin/env python3
"""档 0 取证② —— 分片上传 + 断点续传（一次性脚手架，不进产品链路）。

要回答的问题：计划里"浏览器切 ≤4MB 一片、服务端顺序追加落盘、全片齐再调 import_videos"
这座桥到底成不成立，成立需要多少代码，以及中途硬死之后**能不能不重传整片**。

三个服务端语义（sink 模式）：
    POST /chunk?upload=ID&index=N   收一片，先写 N.part、fsync、再 rename 成 N（原子性是关键：
                                     被 kill -9 时只会留下 .part，绝不留下"看起来完整"的半片）
    GET  /state?upload=ID           返回已收全的 index 列表（只认 rename 成功的那些）
    POST /finalize?upload=ID        按序拼成 assembled.bin 并回 sha256；有缺口就明确报缺口

客户端语义（push 模式）：先问 /state，只补缺的那几片 —— 续传的证据就是"跳过数 > 0"。

用法（一般由 scripts/stage0_chunked_upload_probe.sh 调用）：
    python3 scripts/stage0_upload_sink.py sink --port 8793 --work <目录>
    python3 scripts/stage0_upload_sink.py push --file <路径> --port 8793 \
        --upload probe1 --chunk 4194304
"""

import argparse
import hashlib
import json
import os
import signal
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATS = {"chunks_ok": 0, "bytes_in": 0, "rejected": 0}
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "stage0-sink"

    def log_message(self, fmt, *args):
        pass

    def _parts_dir(self, upload):
        # upload id 只允许安全字符：这是脚手架，但它替我们演示了不能信查询参数这件事
        safe = "".join(c for c in upload if c.isalnum() or c in "-_")
        if not safe:
            raise ValueError("非法 upload id")
        path = os.path.join(self.server.work, safe)
        os.makedirs(os.path.join(path, "parts"), exist_ok=True)
        return path

    def _json(self, code, obj):
        data = json.dumps(obj, sort_keys=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        if parsed.path != "/state":
            self._json(404, {"code": "NOT_FOUND"})
            return
        try:
            parts = self._parts_dir(qs.get("upload", [""])[0])
        except ValueError as exc:
            self._json(400, {"code": "BAD_UPLOAD_ID", "message": str(exc)})
            return
        got = []
        for name in os.listdir(os.path.join(parts, "parts")):
            if name.isdigit():
                got.append(int(name))
        total = 0
        for n in got:
            total += os.path.getsize(os.path.join(parts, "parts", str(n)))
        self._json(200, {"received": sorted(got), "bytes": total})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)

        if parsed.path == "/chunk":
            self._handle_chunk(qs, body)
        elif parsed.path == "/finalize":
            self._handle_finalize(qs)
        else:
            self._json(404, {"code": "NOT_FOUND"})

    def _handle_chunk(self, qs, body):
        try:
            upload = qs.get("upload", [""])[0]
            index = int(qs.get("index", [""])[0])
            parts = self._parts_dir(upload)
        except (ValueError, KeyError) as exc:
            self._json(400, {"code": "BAD_ARGUMENT", "message": str(exc)})
            return
        if index < 0:
            self._json(400, {"code": "BAD_INDEX"})
            return

        expect = int(qs.get("bytes", ["-1"])[0])
        if expect >= 0 and expect != len(body):
            with LOCK:
                STATS["rejected"] += 1
            self._json(400, {"code": "SIZE_MISMATCH",
                             "expect": expect, "got": len(body)})
            return

        dirpath = os.path.join(parts, "parts")
        tmp = os.path.join(dirpath, "%d.part" % index)
        final = os.path.join(dirpath, str(index))

        if qs.get("break", ["0"])[0] == "1":
            # 故障注入：只写半片就当场死掉（os._exit 不走任何清理），
            # 用来证明"写坏的一半不会被当成已收到"，而不是靠我讲道理
            with open(tmp, "wb") as handle:
                handle.write(body[: len(body) // 2])
                handle.flush()
                os.fsync(handle.fileno())
            sys.stderr.write("[注入] 第 %d 片只写了一半，进程当场死\n" % index)
            sys.stderr.flush()
            os._exit(3)

        with open(tmp, "wb") as handle:
            handle.write(body)
            handle.flush()
            os.fsync(handle.fileno())
        os.rename(tmp, final)  # 到这一行才算"这片收到了"

        with LOCK:
            STATS["chunks_ok"] += 1
            STATS["bytes_in"] += len(body)
        self._json(200, {"ok": True, "index": index, "bytes": len(body)})

    def _handle_finalize(self, qs):
        try:
            upload = qs.get("upload", [""])[0]
            count = int(qs.get("count", ["0"])[0])
            parts = self._parts_dir(upload)
        except (ValueError, KeyError) as exc:
            self._json(400, {"code": "BAD_ARGUMENT", "message": str(exc)})
            return

        dirpath = os.path.join(parts, "parts")
        have = set()
        for name in os.listdir(dirpath):
            if name.isdigit():
                have.add(int(name))
        missing = [n for n in range(count) if n not in have]
        if missing:
            self._json(409, {"code": "INCOMPLETE",
                             "missing": missing[:20],
                             "missing_count": len(missing)})
            return

        out = os.path.join(parts, "assembled.bin")
        digest = hashlib.sha256()
        total = 0
        with open(out, "wb") as sink:
            for n in range(count):
                path = os.path.join(dirpath, str(n))
                with open(path, "rb") as src:
                    while True:
                        block = src.read(1048576)
                        if not block:
                            break
                        digest.update(block)
                        sink.write(block)
                        total += len(block)
            sink.flush()
            os.fsync(sink.fileno())
        sys.stderr.write("[服务端] 拼完 upload=%s 字节=%d\n" % (upload, total))
        self._json(200, {"ok": True, "sha256": digest.hexdigest(),
                         "bytes": total, "path": out})


def run_sink(args):
    os.makedirs(args.work, exist_ok=True)
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    httpd.daemon_threads = True
    httpd.work = args.work

    def stop(*a):
        # SIGTERM 也必须走干净退出，否则 finally 里的总计行会整个丢掉
        threading.Thread(target=httpd.shutdown).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    sys.stderr.write("[自报] sink 只听 127.0.0.1:%d 工作目录=%s\n"
                     % (args.port, args.work))
    sys.stderr.flush()
    print(args.port)
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    finally:
        sys.stderr.write("[总计] 收下片=%d 字节=%d 拒收=%d\n"
                         % (STATS["chunks_ok"], STATS["bytes_in"],
                            STATS["rejected"]))
        httpd.server_close()


def read_state(port, upload):
    url = "http://127.0.0.1:%d/state?upload=%s" % (
        port, urllib.parse.quote(upload, safe=""))
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


def run_push(args):
    size = os.path.getsize(args.file)
    chunk = args.chunk
    count = (size + chunk - 1) // chunk
    if count == 0:
        sys.stderr.write("FAIL 文件为空，测不出东西\n")
        return 1

    state = read_state(args.port, args.upload)
    have = set(state["received"])
    upload_q = urllib.parse.quote(args.upload, safe="")
    sys.stderr.write(
        "[自报] 文件=%s 字节=%d 分片大小=%d 应有片数=%d 已收片数=%d\n"
        % (os.path.basename(args.file), size, chunk, count, len(have)))
    sys.stderr.flush()

    sent_chunks = 0
    sent_bytes = 0
    skipped = 0
    t0 = time.time()
    for n in range(count):
        if n in have:
            skipped += 1
            continue
        start = n * chunk
        end = min(start + chunk, size)
        with open(args.file, "rb") as handle:
            handle.seek(start)
            data = handle.read(end - start)
        url = ("http://127.0.0.1:%d/chunk?upload=%s&index=%d&bytes=%d"
               % (args.port, upload_q, n, len(data)))
        req = urllib.request.Request(url, data=data, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = json.loads(resp.read().decode("utf-8"))
        except Exception as exc:
            sys.stderr.write("FAIL 第 %d 片投递失败：%s\n" % (n, exc))
            _report_push(sent_chunks, sent_bytes, skipped, t0, size, count)
            return 1
        if not body.get("ok"):
            sys.stderr.write("FAIL 第 %d 片服务端拒收：%s\n" % (n, body))
            _report_push(sent_chunks, sent_bytes, skipped, t0, size, count)
            return 1
        sent_chunks += 1
        sent_bytes += len(data)
        if args.stop_after > 0 and sent_chunks >= args.stop_after:
            # 模拟"传到一半断掉"：由客户端停在确定的第 N 片之后，
            # 免得外部轮询去抢时机 —— 回环上整片半秒推完，轮询必然抢不准
            sys.stderr.write(
                "[中途断] 已投 %d/%d 片后主动断开（模拟断网/断电）\n"
                % (sent_chunks, count))
            _report_push(sent_chunks, sent_bytes, skipped, t0, size, count)
            return 7

    fin = urllib.request.urlopen(urllib.request.Request(
        "http://127.0.0.1:%d/finalize?upload=%s&count=%d"
        % (args.port, upload_q, count), data=b"", method="POST"), timeout=120)
    result = json.loads(fin.read().decode("utf-8"))
    if result.get("code") == "INCOMPLETE":
        sys.stderr.write("FAIL 拼接时还缺 %d 片：%s\n"
                         % (result["missing_count"], result["missing"]))
        return 1

    want = hashlib.sha256()
    with open(args.file, "rb") as handle:
        while True:
            block = handle.read(1048576)
            if not block:
                break
            want.update(block)

    ok = result["sha256"] == want.hexdigest()
    sys.stderr.write(
        "[逐字节对账] 原文件 sha256=%s 重组 sha256=%s => %s\n"
        % (want.hexdigest(), result["sha256"], "相同" if ok else "不同"))
    if not ok:
        return 1
    _report_push(sent_chunks, sent_bytes, skipped, t0, size, count)
    print(result["sha256"])
    return 0


def _report_push(sent_chunks, sent_bytes, skipped, t0, size, count):
    elapsed = max(1e-6, time.time() - t0)
    sys.stderr.write(
        "[续传账] 本片数=%d/%d 跳过已收=%d 实发字节=%d（原片 %d）"
        " 落盘吞吐=%.1f MB/s 用时=%.2fs\n"
        % (sent_chunks, count, skipped, sent_bytes, size,
           sent_bytes / 1048576.0 / elapsed, elapsed))
    sys.stderr.flush()


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--work", default="")
    ap.add_argument("--file", default="")
    ap.add_argument("--upload", default="probe")
    ap.add_argument("--chunk", type=int, default=4194304)
    ap.add_argument("--stop-after", type=int, default=0,
                    help="push 模式：投出这么多片之后模拟中断退出（0=不中断）")
    args = ap.parse_args(sys.argv[2:])

    if mode == "sink":
        if not args.work:
            sys.stderr.write("FAIL sink 需要 --work\n")
            return 2
        run_sink(args)
        return 0
    if mode == "state":
        state = read_state(args.port, args.upload)
        print("%d %d" % (len(state["received"]), state["bytes"]))
        return 0
    if mode == "push":
        if not args.file or not os.path.isfile(args.file):
            sys.stderr.write("FAIL push 需要存在的 --file\n")
            return 2
        return run_push(args)
    sys.stderr.write("FAIL 模式只能是 sink 或 push\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
