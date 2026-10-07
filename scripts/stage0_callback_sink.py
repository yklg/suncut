#!/usr/bin/env python3
"""档 0 取证④的回调接收端（一次性脚手架）。

只回答一件事：**公司登录平台能不能把浏览器重定向回一个内网地址**。
它不换 token、不接任何密钥，因此也不产生任何真实授权后果 —— 它只是把回调 URL 上
带来的查询参数收下来、脱敏打印，然后告诉你来源 IP 是哪台机器。

为什么必须绑 0.0.0.0：回调是**同事的浏览器**发起的跳转，只有网卡可达才谈得上"走通"。
这一段窗口内该端口对整个内网开放，但它除了打印参数什么都不做，进程一退即无残留。

用法：
    python3 scripts/stage0_callback_sink.py --port 8794 --path /callback

退出时（Ctrl-C 或收到 SIGTERM）打总计：回调次数、来源 IP、是否出现过非本机来源。
"""

import argparse
import os
import signal
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"hits": 0, "nonlocal_hits": 0, "clients": [], "errors": [],
         "started": 0.0}
LOCK = threading.Lock()

LOCAL_IPS = {"127.0.0.1", "::1"}


def mask(value):
    """一次性授权码是凭据，绝不整段打印：只报长度与前 4 位。"""
    if not value:
        return "(空)"
    return "len=%d 前4=%s" % (len(value), value[:4])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "stage0-callback"

    def log_message(self, fmt, *args):
        pass

    def _page(self, code, text, content_type="text/html; charset=utf-8"):
        body = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        client = self.client_address[0]

        if parsed.path == "/":
            self._page(200, "<h3>档 0 取证④回调接收端在线</h3>"
                            "<p>回调路径：<code>%s</code> ｜ 本机局域网地址：%s:%s</p>"
                            % (self.server.callback_path,
                               self.server.lan_ip, self.server.port))
            return

        if parsed.path != self.server.callback_path:
            # 平台若把回调打到别的路径，这本身就是要紧的读数，不能默默 404 掉
            sys.stderr.write("[路径不符] 来自 %s 命中 %s（期望 %s）\n"
                             % (client, parsed.path, self.server.callback_path))
            self._page(404, "not found", "text/plain; charset=utf-8")
            return

        is_local = client in LOCAL_IPS
        with LOCK:
            STATE["hits"] += 1
            STATE["clients"].append(client)
            if not is_local:
                STATE["nonlocal_hits"] += 1
            if "error" in qs or "error_description" in qs:
                STATE["errors"].append((client, parsed.path, qs))

        keys = ",".join(sorted(qs.keys()))
        sys.stderr.write(
            "[回调] 来自 %s%s 参数键=%s code=%s state=%s error=%s\n"
            % (client, "（本机）" if is_local else "（外部机器 —— 这就是走通的证据）",
               keys or "(无)",
               mask(qs.get("code", [""])[0]),
               qs.get("state", ["-"])[0][:16],
               qs.get("error", ["-"])[0])
        )
        sys.stderr.flush()
        self._page(200, "<h3>取证④已收到回调</h3>"
                        "<p>参数键：%s</p><p>现在可以关掉这个标签页。</p>"
                        % (keys or "(无)"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--path", default="/callback")
    ap.add_argument("--lan", default="")
    args = ap.parse_args()

    httpd = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    httpd.daemon_threads = True
    httpd.callback_path = args.path
    httpd.port = args.port
    httpd.lan_ip = args.lan or "未知"

    def stop(*a):
        threading.Thread(target=httpd.shutdown).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    STATE["started"] = time.time()
    sys.stderr.write(
        "[自报] 监听 0.0.0.0:%d 回调路径=%s 局域网=%s "
        "pid=%d（不接密钥、不换 token，只打印脱敏参数）\n"
        % (args.port, args.path, httpd.lan_ip, os.getpid()))
    sys.stderr.flush()
    print("http://%s:%d%s" % (httpd.lan_ip, args.port, args.path))
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    finally:
        elapsed = time.time() - STATE["started"]
        uniq = sorted(set(STATE["clients"]))
        sys.stderr.write(
            "[总计] 回调命中=%d 其中来自外部机器=%d 来源=%s 错误回调=%d 时长=%.0fs\n"
            % (STATE["hits"], STATE["nonlocal_hits"], ",".join(uniq) or "无",
               len(STATE["errors"]), elapsed))
        if STATE["errors"]:
            for client, path, qs in STATE["errors"]:
                sys.stderr.write("  错误回调详情 来自=%s path=%s 参数=%s\n"
                                 % (client, path,
                                    {k: v[:1] for k, v in qs.items()}))
        if STATE["hits"] == 0:
            sys.stderr.write("  本轮一次回调都没收到 —— 结论就是「没走通」，不是脚手架坏了\n")
        elif STATE["nonlocal_hits"] == 0:
            sys.stderr.write("  只有本机来源：说明平台愿意往内网地址跳转，"
                             "但「同事浏览器实际完成一次」还没证到\n")
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
