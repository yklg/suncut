#!/usr/bin/env python3
"""档 0 取证①的播放服务端（一次性脚手架，不进产品链路）。

它只回答一个问题：**局域网里用浏览器拖进度条到底稳不稳**，以及"带 Range（206）"
和"整片 200 响应"两种做法的差别有多大。所以两种模式必须都能开，互为对照 ——
只测好那一档就等于没测。

用法（一般由 scripts/stage0_lan_playback_probe.sh 调用）：
    python3 scripts/stage0_media_server.py --file <真实视频绝对路径> \
        --port 8790 --range off

--range off  : 故意无视请求里的 Range 头，一律 200 整片返回（= 现有前台唯一能做到的形状）
--range on   : 正确实现单段 Range（206 / 416 / Content-Range），= 计划里"新专职前台"要做的形状

每处理完一个请求往 stderr 打一行读数；退出时打总计（请求数、字节数、吞吐、模式）。
"""

import argparse
import html
import os
import signal
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {
    "requests": 0,
    "bytes_sent": 0,
    "range_hits": 0,
    "full_hits": 0,
    "range_ignored": 0,
    "reject_416": 0,
    "started": 0.0,
}

LOCK = threading.Lock()


def parse_single_range(value, size):
    """只认单段 Range（浏览器拖条就是单段）。返回 (start, end) 或 None。"""
    if not value:
        return None
    value = value.strip()
    if not value.lower().startswith("bytes="):
        return None
    spec = value[6:]
    if "," in spec:
        # 多段 Range 不在本次取证范围内，明确让读数能看出来
        return None
    if "-" not in spec:
        return None
    left, right = spec.split("-", 1)
    try:
        if left == "":
            length = int(right)
            if length <= 0:
                return None
            start, end = max(0, size - length), size - 1
        else:
            start = int(left)
            end = int(right) if right else size - 1
    except ValueError:
        return None
    if start < 0 or start >= size or end < start:
        return None
    return start, min(end, size - 1)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "stage0-probe"

    def log_message(self, fmt, *args):  # 静音默认访问日志，改用自家读数
        pass

    def _media_path(self, path):
        if path == "/media":
            return True
        if path.startswith("/video/"):
            return True
        return False

    def _stats_line(self):
        srv = self.server
        mode = "range=on" if srv.honor_range else "range=off"
        size_mb = srv.file_size / 1048576.0
        return "file=%s (%.1f MB) mode=%s" % (
            os.path.basename(srv.args.file), size_mb, mode)

    def _plain(self, code, text):
        body = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        raw_path = self.path
        # 浏览器会把中文/空格按它自己的规则转义，这里留原始行以便对账
        decoded = self.path.split("?", 1)[0]

        if raw_path == "/" :
            self._serve_index()
            return
        if not self._media_path(decoded):
            # 浏览器还会自己请求 /favicon.ico 之类，这里必须给真响应而不是抛异常
            self._plain(404, "not found")
            return

        size = self.server.file_size
        range_header = self.headers.get("Range")
        honored = self.server.honor_range

        start, end, status = 0, size - 1, 200
        parsed = parse_single_range(range_header, size) if honored else None
        if honored and range_header:
            if parsed is None:
                status, start, end = 416, 0, 0
                with LOCK:
                    STATE["reject_416"] += 1
            else:
                start, end = parsed
                status = 206
                with LOCK:
                    STATE["range_hits"] += 1
        else:
            # range_ignored 是本取证的关键读数：客户端确实发了 Range，但"整片 200"这档故意当没看见
            with LOCK:
                STATE["full_hits"] += 1
                if honored is False and range_header:
                    STATE["range_ignored"] += 1

        length = 0 if status == 416 else (end - start + 1)
        self.send_response(status)
        self.send_header("Content-Type", self.server.content_type)
        self.send_header("Accept-Ranges", "bytes" if honored else "none")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header(
                "Content-Range", "bytes %d-%d/%d" % (start, end, size))
        if status == 416:
            self.send_header("Content-Range", "bytes */%d" % size)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

        if status == 416:
            self.close_connection = True
            with LOCK:
                STATE["requests"] += 1
            self._report(raw_path, status, 0, range_header, honored)
            return

        t0 = time.time()
        sent = 0
        chunk = self.server.chunk_bytes
        aborted = False
        try:
            with open(self.server.args.file, "rb") as handle:
                handle.seek(start)
                remaining = length
                while remaining > 0:
                    data = handle.read(min(chunk, remaining))
                    if not data:
                        break
                    self.wfile.write(data)
                    self.wfile.flush()
                    remaining -= len(data)
                    sent += len(data)
        except (BrokenPipeError, ConnectionResetError, OSError):
            # 浏览器 seek 会直接掐断连接，这正是要观察的现象之一
            aborted = True
        elapsed = time.time() - t0
        with LOCK:
            STATE["requests"] += 1
            STATE["bytes_sent"] += sent
        self._report(raw_path, 499 if aborted else status, sent,
                     range_header, honored, elapsed)

    def _report(self, path, status, sent, range_header, honored, elapsed=0.0):
        mbps = (sent / 1048576.0 / elapsed) if elapsed > 0 else 0.0
        client = "%s:%s" % (self.client_address[0], self.client_address[1])
        sys.stderr.write(
            "[读数] client=%s status=%s bytes=%s %.2f MB/s "
            "range_req=%s honored=%s path=%s\n"
            % (client, status, sent, mbps,
               (range_header or "-"), ("on" if honored else "off"), path)
        )
        sys.stderr.flush()

    def _serve_index(self):
        srv = self.server
        size_mb = srv.file_size / 1048576.0
        mode = "带 Range（206）" if srv.honor_range else "无视 Range（整片 200）"
        page = (
            "<!doctype html><meta charset=utf-8>"
            "<h2>档 0 取证① · 本档 = %s</h2>"
            "<p>文件：%s ｜ %.1f MB ｜ 服务器：%s</p>"
            "<video controls preload=metadata width=360 "
            "src=\"/media\"></video>"
            "<p><b>要做的动作：</b>把播放条拖到中段 3 次、快到底部 1 次。"
            "记下：能不能立刻出画、有没有黑屏/卡住/从头重播。</p>"
            "<p>第二个对照 URL（路径里带中文与空格，用来看转义）："
            "<a href=\"/video/%s\">/video/&lt;原始文件名&gt;</a></p>"
            % (html.escape(mode), html.escape(os.path.basename(srv.args.file)),
               size_mb, srv.ip_port, html.escape(srv.url_encoded_name))
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--range", choices=["on", "off"], default="off")
    ap.add_argument("--chunk", type=int, default=1048576)
    args = ap.parse_args()

    if not os.path.isfile(args.file):
        sys.stderr.write("FAIL 文件不存在：%s\n" % args.file)
        return 1
    size = os.path.getsize(args.file)
    if size <= 0:
        sys.stderr.write("FAIL 文件是 0 字节，测不出任何东西\n")
        return 1

    from urllib.parse import quote
    import mimetypes

    httpd = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    httpd.daemon_threads = True
    httpd.args = args
    httpd.file_size = size
    httpd.honor_range = (args.range == "on")
    httpd.chunk_bytes = args.chunk
    httpd.content_type = mimetypes.guess_type(args.file)[0] or "video/mp4"
    lan = ""
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("8.8.8.8", 80))
        lan = probe.getsockname()[0]
        probe.close()
    except OSError:
        pass
    httpd.ip_port = "%s:%d" % (lan or "127.0.0.1", args.port)
    httpd.url_encoded_name = quote(os.path.basename(args.file))

    STATE["started"] = time.time()
    # SIGTERM 必须走干净退出：默认 SIGTERM 不执行 finally，总计行会整个丢掉
    signal.signal(signal.SIGTERM,
                  lambda *a: threading.Thread(target=httpd.shutdown).start())
    sys.stderr.write(
        "[自报] 模式=%s 文件=%s 字节=%d (%.1f MB) 监听=0.0.0.0:%d "
        "局域网=%s 分块=%d\n"
        % (("206 Range" if httpd.honor_range else "整片 200"), args.file,
           size, size / 1048576.0, args.port, httpd.ip_port, args.chunk)
    )
    sys.stderr.flush()
    print(httpd.ip_port)
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        elapsed = max(1e-6, time.time() - STATE["started"])
        sys.stderr.write(
            "[总计] 媒体请求=%d（不含首页） 发出=%d 字节 (%.1f MB) 平均=%.2f MB/s "
            "range命中=%d 整片命中=%d 被无视的Range=%d 416=%d 模式=%s\n"
            % (STATE["requests"], STATE["bytes_sent"],
               STATE["bytes_sent"] / 1048576.0,
               STATE["bytes_sent"] / 1048576.0 / elapsed,
               STATE["range_hits"], STATE["full_hits"],
               STATE["range_ignored"], STATE["reject_416"],
               ("206" if httpd.honor_range else "200"))
        )
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
