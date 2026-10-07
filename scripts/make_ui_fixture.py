#!/usr/bin/env python3
"""代码驱动造 UI 测试数据（分层重排 §用代码造测试数据）。

存在的理由：造一个"有项目的库"原本要靠鼠标点「创建新项目」→ 填名 → 点「创建」，
而实测告诉我们那条路又慢又脆（键盘通道打不进中文、点击对禁用控件静默无操作）。
本脚本一次 HTTP 调用办完，全程不碰界面。

侧栏解禁的门槛在 MixCut/Views/Shared/SidebarView.swift:328 的
`.disabled(projectVM.selectedProject == nil)`，而"当前选中项目"只由界面点击 / 欢迎页 /
启动恢复三条路赋值（ProjectViewModel.swift:113-119 读 UserDefaults 键 lastSelectedProjectID），
MCP 没有"选中项目"这个工具。⇒ 用 **启动参数域** 注入该键：
`-lastSelectedProjectID <uuid>` 走 NSUserDefaults argument domain。

⚠️ 但参数域**不是进程级的**（2026-10-04 实测推翻本脚本原假设）：App 在
`ProjectViewModel.swift:18` 的 `selectedProject` didSet 里会把该键**写回标准域**，
而 Debug 与 Release 共用 bundle id `com.suncut.app` ⇒ 一次带参启动就会污染用户真实偏好。
所以任何用这套启动参数的会话，必须用 `--prefs-guard` 前后包夹（快照 + 还原）。

用法：
    python3 scripts/make_ui_fixture.py                       # 建 2 个项目，打印清单
    python3 scripts/make_ui_fixture.py --emit <路径>          # 同时把清单写成 JSON
    python3 scripts/make_ui_fixture.py --cleanup <清单>       # 按清单把项目删回去
    python3 scripts/make_ui_fixture.py --prefs-snapshot <路径> # 启动被测 App 前调
    python3 scripts/make_ui_fixture.py --prefs-restore <路径>   # 会话结束后调（放 finally）
"""

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request

MARKER = "UITEST"  # 名字前缀，便于识别与清理，绝不与用户真项目撞名
PREFS_DOMAIN = "com.suncut.app"
PREFS_KEY = "lastSelectedProjectID"


def prefs_snapshot(path):
    """把用户当前该键的原值存盘；本来没有就记 null，还原时按 null 删掉。"""
    proc = subprocess.run(
        ["defaults", "read", PREFS_DOMAIN, PREFS_KEY],
        capture_output=True, text=True,
    )
    value = proc.stdout.strip() if proc.returncode == 0 else None
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"domain": PREFS_DOMAIN, "key": PREFS_KEY, "value": value}, fh, ensure_ascii=False)
    print("已快照 %s.%s = %s → %s" % (
        PREFS_DOMAIN, PREFS_KEY, value if value else "(原本没有)", path))
    return 0


def prefs_restore(path):
    snap = json.load(open(path, encoding="utf-8"))
    if snap.get("value"):
        subprocess.run(["defaults", "write", snap["domain"], snap["key"],
                        "-string", snap["value"]], check=True)
        print("已还原原值 %s" % snap["value"])
    else:
        subprocess.run(["defaults", "delete", snap["domain"], snap["key"]],
                       capture_output=True)
        print("原本没有该键，已删除（回到未写入状态）")
    now = subprocess.run(["defaults", "read", snap["domain"], snap["key"]],
                         capture_output=True, text=True).stdout.strip()
    if (now or None) != (snap.get("value") or None):
        sys.stderr.write("FAIL 还原后读数与快照不符：现值=%r 快照=%r\n" % (now, snap.get("value")))
        return 1
    print("还原对账 ✓")
    return 0


def rpc(port, method, params=None, req_id=[0]):
    req_id[0] += 1
    body = {"jsonrpc": "2.0", "id": req_id[0], "method": method}
    if params is not None:
        body["params"] = params
    req = urllib.request.Request(
        "http://127.0.0.1:%d/mcp" % port,
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        method="POST",
    )
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=60) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    if "error" in payload:
        raise RuntimeError("协议层错误 %s：%s" % (
            payload["error"].get("code"), payload["error"].get("message")))
    result = payload.get("result") or {}
    content = result.get("content") or []
    text = content[0].get("text", "") if content else ""
    try:
        inner = json.loads(text)
    except (ValueError, TypeError):
        inner = {"raw": text}
    if result.get("isError"):
        raise RuntimeError("工具层报错：%s" % text[:300])
    return inner


def tool(port, name, arguments):
    return rpc(port, "tools/call", {"name": name, "arguments": arguments})


def build(port, count, product_name):
    projects = []
    for i in range(1, count + 1):
        created = tool(port, "create_project", {
            "name": "%s-项目-%d" % (MARKER, i),
            "product_name": product_name,
        })
        pid = created.get("id") or created.get("project_id")
        if not pid:
            raise RuntimeError("建项目没拿到 id：%s" % json.dumps(created, ensure_ascii=False)[:300])
        projects.append({"id": pid, "name": "%s-项目-%d" % (MARKER, i)})
        print("  已建 %s  id=%s" % (projects[-1]["name"], pid))

    # 回读对账：名字与所属产品必须真落库，否则后面所有 UI 断言都建在空气上
    listed = tool(port, "list_projects", {})
    rows = listed.get("projects") if isinstance(listed, dict) else listed
    if not isinstance(rows, list):
        raise RuntimeError("list_projects 回读形状不认识：%s" % str(listed)[:200])
    by_id = {r.get("id"): r for r in rows if isinstance(r, dict)}
    for p in projects:
        row = by_id.get(p["id"])
        if row is None:
            raise RuntimeError("建出来的项目回读不到：%s（写链或读链断了）" % p["id"])
        if row.get("name") != p["name"]:
            raise RuntimeError("回读名字不符：%r != %r" % (row.get("name"), p["name"]))
    print("  回读对账 ✓ 名称与 id 逐项一致（共 %d 个）" % len(projects))

    manifest = {
        "product_name": product_name,
        "projects": projects,
        "selected_project_id": projects[0]["id"],
        # 用这行参数启动被测 App，侧栏才会解禁
        "launch_args": [
            "-lastSelectedProjectID", projects[0]["id"],
            "-ApplePersistenceIgnoreState", "YES",
        ],
    }
    return manifest


def cleanup(port, manifest_path):
    manifest = json.load(open(manifest_path, encoding="utf-8"))
    for p in manifest.get("projects", []):
        pid = p["id"]
        preview = tool(port, "delete_project", {"project_id": pid})
        print("  预览 %s：%s" % (pid, json.dumps(preview, ensure_ascii=False)[:160]))
        tool(port, "delete_project", {"project_id": pid, "confirm": True})
        print("  已删 %s" % pid)
    listed = tool(port, "list_projects", {})
    rows = listed.get("projects") if isinstance(listed, dict) else listed
    left = {r.get("id") for r in rows if isinstance(r, dict)}
    leaked = [p["id"] for p in manifest.get("projects", []) if p["id"] in left]
    if leaked:
        raise RuntimeError("清理后仍存在，属真缺陷：%s" % leaked)
    print("  清理对账 ✓ 清单内项目已全部消失")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--projects", type=int, default=2)
    ap.add_argument("--product", default="%s-产品" % MARKER)
    ap.add_argument("--emit", help="把清单写成 JSON，供门禁与清理复用")
    ap.add_argument("--cleanup", metavar="MANIFEST", help="按清单删除本脚本建过的项目")
    ap.add_argument("--prefs-snapshot", metavar="PATH", help="启动被测 App 前快照用户偏好原值")
    ap.add_argument("--prefs-restore", metavar="PATH", help="会话结束后还原用户偏好原值")
    args = ap.parse_args()

    if args.prefs_snapshot:
        return prefs_snapshot(args.prefs_snapshot)
    if args.prefs_restore:
        return prefs_restore(args.prefs_restore)

    try:
        if args.cleanup:
            print("== 清理清单 %s ==" % args.cleanup)
            cleanup(args.port, args.cleanup)
            return 0
        print("== 建 %d 个项目（产品：%s）==" % (args.projects, args.product))
        manifest = build(args.port, args.projects, args.product)
    except (urllib.error.URLError, RuntimeError) as exc:
        sys.stderr.write("FAIL %s\n" % exc)
        return 1

    print("\n清单：")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    if args.emit:
        with open(args.emit, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, ensure_ascii=False, indent=2)
        print("\n已写 %s" % args.emit)
    print("\n启动被测 App 时用这组参数（进程级，不落盘）：")
    print("  " + " ".join(manifest["launch_args"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
