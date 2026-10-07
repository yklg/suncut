#!/usr/bin/env python3
"""档 0 取证用的一次性 TCP 转发器（不进产品链路）。

存在理由：现有前台把监听地址钉死在回环（`MCPServer.swift:23`），而取证要回答
"同事的网络到底够不够得着这台机器"。不改仓库代码就能拿到这个答案的唯一办法，
是在网卡上开个口、把字节原样搬到 127.0.0.1:8787。

这段窗口里服务**零鉴权** —— 同网络任何人都能调那 24 个工具，含 delete_project。
所以本文件只在 stage0_lan_playback_probe.sh 里被显式确认后才启动，进程一退就无残留。

用法：
    python3 scripts/stage0_tcp_forward.py --listen-port 8792 \
        --target-host 127.0.0.1 --target-port 8787
"""

import argparse
import signal
import socket
import sys
import threading
import time

STATS = {"connections": 0, "client_to_target": 0, "target_to_client": 0}
LOCK = threading.Lock()
RUNNING = [True]


def pump(src, dst, key):
    total = 0
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
            total += len(data)
    except OSError:
        pass
    finally:
        with LOCK:
            STATS[key] += total
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(conn, addr, target):
    with LOCK:
        STATS["connections"] += 1
        n = STATS["connections"]
    sys.stderr.write("[连接] #%d 来自 %s:%s -> %s:%d\n"
                     % (n, addr[0], addr[1], target[0], target[1]))
    sys.stderr.flush()
    t0 = time.time()
    try:
        upstream = socket.create_connection(target, timeout=10)
    except OSError as exc:
        sys.stderr.write("[失败] #%d 连不上目标：%s\n" % (n, exc))
        conn.close()
        return
    a = threading.Thread(target=pump, args=(conn, upstream, "client_to_target"))
    b = threading.Thread(target=pump, args=(upstream, conn, "target_to_client"))
    a.start()
    b.start()
    a.join()
    b.join()
    conn.close()
    upstream.close()
    sys.stderr.write("[结束] #%d 用时 %.2fs\n" % (n, time.time() - t0))
    sys.stderr.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen-port", type=int, required=True)
    ap.add_argument("--target-host", default="127.0.0.1")
    ap.add_argument("--target-port", type=int, required=True)
    args = ap.parse_args()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("0.0.0.0", args.listen_port))
    listener.listen(32)
    listener.settimeout(1.0)
    # SIGTERM 默认不执行 finally，总计行会丢；这里显式收旗
    signal.signal(signal.SIGTERM, lambda *a: RUNNING.__setitem__(0, False))
    target = (args.target_host, args.target_port)
    sys.stderr.write(
        "[自报] 监听 0.0.0.0:%d -> %s:%d（这段窗口零鉴权，测完请立刻停）\n"
        % (args.listen_port, args.target_host, args.target_port))
    sys.stderr.flush()
    print(args.listen_port)
    sys.stdout.flush()
    try:
        while RUNNING[0]:
            try:
                conn, addr = listener.accept()
            except socket.timeout:
                continue
            threading.Thread(target=handle, args=(conn, addr, target),
                             daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        listener.close()
        sys.stderr.write(
            "[总计] 连接=%d 上行=%d 下行=%d 字节\n"
            % (STATS["connections"], STATS["client_to_target"],
               STATS["target_to_client"]))


if __name__ == "__main__":
    main()
