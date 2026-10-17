#!/usr/bin/env python3
"""集成层两条**计费判据**的形状侧台架：不起 App、不派单、不花一分钱，只用假件喂读数。

为什么要有这个文件（2026-10-17）：API-09 与 API-17 的真机格都要云端计费
（`generate_schemes` 一发起就是计费 + 转写 + 导出），于是它们「有没有牙」这件事
本来只能靠一次花钱来复验。本文件把可复验的那一半搬进仓库：
坏读数必须红、好读数必须绿、超时与失能分支不许静默通过 —— 全部不花钱。

三条台架自守（缺一条，这个文件自己就会变成一台产假绿意的机器）：
 ① 判据调了假件没登记的入口 ⇒ 报「台架失能」并以 2 退出，绝不读成绿；
 ② 判据抛的不是 GuardFail（TypeError/AttributeError/KeyError…）⇒ 同样按台架失能处理
    —— 那是假件与判据形状不匹配，不是"这条判据红了"；
 ③ 绿侧与红侧都必须至少出现一次 ⇒ 任一侧全空说明喂进去的读数整批没生效。

期望串一律**从 scripts/mcp_api_guards.py 的报错文案里复制**，不凭记忆手打
（凭记忆写过一次，17 格里 6 格报"该红的没红"，其实是我的子串对不上文案）。

用法：python3 scripts/selftest_mcp_leg_shapes.py
（由 scripts/selftest_mcp_api_guards.sh 的 自证 17 调用；也可单独跑）
"""
import importlib.util
import os
import shutil
import sys
import tempfile
import time as _t

HERE = os.path.dirname(os.path.abspath(__file__))
GUARDS = os.path.join(HERE, "mcp_api_guards.py")


def load_guards():
    spec = importlib.util.spec_from_file_location("mcp_api_guards_under_test", GUARDS)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class HarnessFail(Exception):
    """台架自己坏了 —— 必须与「判据判红」分开报，否则红绿都不可信。"""


class FakeClient:
    """按工具名分轨发读数：同名第 n 次调用取第 n 项，取完重复最后一项（轮询类判据要用）。"""

    def __init__(self, by_name):
        self.tracks = {k: list(v) for k, v in by_name.items()}
        self.count = {}

    def call(self, name, arguments=None, timeout=60):
        if name not in self.tracks:
            raise HarnessFail("判据调了假件没登记的入口 %r —— 台架失能，不是判据红" % name)
        seq = self.tracks[name]
        i = self.count.get(name, 0)
        self.count[name] = i + 1
        return seq[min(i, len(seq) - 1)]


class Clock:
    """每次取时间前进 20 秒：让 300s / 45s / 30s 这些等待在几步内自然到期，不真等。"""

    def __init__(self):
        self.i = 0

    def time(self):
        v = float(self.i * 20)
        self.i += 1
        return v


def run(fn_name, by_name, seed="P-SEED", jobs=None):
    g = load_guards()
    fn = getattr(g, fn_name, None)
    if fn is None:
        raise HarnessFail("判据函数 %s 不存在（改名了？别把这条读成红）" % fn_name)
    real_time, real_sleep, real_mkdtemp = _t.time, _t.sleep, tempfile.mkdtemp
    clock = Clock()
    _t.time = clock.time
    _t.sleep = lambda *_: None
    bench_root = tempfile.mkdtemp(prefix="mcp-leg-shapes-", dir=tempfile.gettempdir())
    tempfile.mkdtemp = lambda *a, **k: os.path.join(bench_root, "out")
    ctx = {"jobs": list(jobs) if jobs is not None else [], "seed_project": seed,
           "all_codes": {"JOB_ALREADY_RUNNING", "INVALID_ARGUMENT"}}
    try:
        try:
            detail = fn(FakeClient(by_name), ctx)
            return detail, None, ctx
        except g.GuardFail as exc:
            return None, str(exc), ctx
        except HarnessFail:
            raise
        except Exception as exc:                      # ②：非 GuardFail 一律当台架失能
            raise HarnessFail("%s 抛了 %s：%s（假件与判据形状不匹配，不许读成判据红）"
                              % (fn_name, type(exc).__name__, exc))
    finally:
        _t.time, _t.sleep, tempfile.mkdtemp = real_time, real_sleep, real_mkdtemp
        shutil.rmtree(bench_root, ignore_errors=True)


HELD = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
MINE = "11111111-2222-3333-4444-555555555555"
REFUSE = (True, {"code": "JOB_ALREADY_RUNNING",
                 "message": "已有任务在运行（job_id: %s），请等它完成后再发起" % HELD}, "refuse")
REFUSE_NO_UUID = (True, {"code": "JOB_ALREADY_RUNNING", "message": "已有任务在运行"}, "refuse")
ACCEPT = (False, {"job_id": MINE}, "accepted")
HELD_RUNNING = (False, {"kind": "selftest_gate_hold", "state": "running", "project_id": None}, "job")
HELD_RELEASED = (False, {"kind": "selftest_gate_hold", "state": "failed",
                         "failure_message": "自检占位作业到期释放"}, "job")
REAL_RUNNING = (False, {"kind": "generate_schemes", "state": "running", "project_id": "P"}, "job")
MINE_DONE = (False, {"kind": "export_segments", "state": "failed"}, "job")
MINE_STUCK = (False, {"kind": "export_segments", "state": "running"}, "job")
SEGS = (False, {"segments": [{"id": "seeded-segment-id"}], "count": 1}, "segments")

# (判据函数, 格名, 喂进去的读数, seed, jobs, 期望命中的红因片段或 None=期望绿)
LEGS = [
    # ---- API-09：completed 必须带产物计数（真机那格要花钱，形状侧在这一格上钉死） ----
    ("api09_job_terminal_state", "09-K1 completed 带 result.scheme_count ⇒ 绿",
     {"get_job": [(False, {"state": "completed",
                           "result": {"scheme_count": 7, "failed_strategies": 1}}, "t")]},
     "P", ["JOB-1"], None),
    ("api09_job_terminal_state", "09-K2 completed 却没有 result ⇒ 必须红",
     {"get_job": [(False, {"state": "completed"}, "t")]},
     "P", ["JOB-1"], "completed 却没带 result.scheme_count"),
    ("api09_job_terminal_state", "09-K3 result 不是对象 ⇒ 必须红",
     {"get_job": [(False, {"state": "completed", "result": "oops"}, "t")]},
     "P", ["JOB-1"], "completed 却没带 result.scheme_count"),
    ("api09_job_terminal_state", "09-K4 failed 带 failure_message ⇒ 绿（不要求产物）",
     {"get_job": [(False, {"state": "failed", "failure_message": "apiKeyNotConfigured"}, "t")]},
     "P", ["JOB-1"], None),
    ("api09_job_terminal_state", "09-K5 一直 running ⇒ 超时分支必须红，不许静默通过",
     {"get_job": [(False, {"state": "running"}, "t")]},
     "P", ["JOB-1"], "300s 内没到终态"),
    # ---- API-17：闸门占位那对读数（拒 / 反查 kind / 释放 / 不拒 / 收尾） ----
    ("api17_gate_hold_refuses_free_entry", "17-K1 全对那一整对 ⇒ 绿",
     {"list_segments": [SEGS], "export_segments": [REFUSE, ACCEPT],
      "get_job": [HELD_RUNNING, HELD_RELEASED, MINE_DONE]}, "P-SEED", None, None),
    ("api17_gate_hold_refuses_free_entry", "17-K2 钉住期竞没被拒 ⇒ 必须红",
     {"list_segments": [SEGS], "export_segments": [ACCEPT]}, "P-SEED", None, "竞没被拒"),
    ("api17_gate_hold_refuses_free_entry", "17-K3 拦住我的是别的真活 ⇒ 必须红",
     {"list_segments": [SEGS], "export_segments": [REFUSE], "get_job": [REAL_RUNNING]},
     "P-SEED", None, "不是自检占位作业"),
    ("api17_gate_hold_refuses_free_entry", "17-K4 释放后同一份参数仍被拒 ⇒ 必须红",
     {"list_segments": [SEGS], "export_segments": [REFUSE, REFUSE],
      "get_job": [HELD_RUNNING, HELD_RELEASED]}, "P-SEED", None, "仍被闸门拒"),
    ("api17_gate_hold_refuses_free_entry", "17-K5 本腿作业卡 running 就返回 ⇒ 必须红",
     {"list_segments": [SEGS], "export_segments": [REFUSE, ACCEPT],
      "get_job": [HELD_RUNNING, HELD_RELEASED, MINE_STUCK]}, "P-SEED", None, "挂在 running"),
    ("api17_gate_hold_refuses_free_entry", "17-K6 拒因不带 job_id（无从归因）⇒ 必须红",
     {"list_segments": [SEGS], "export_segments": [REFUSE_NO_UUID]}, "P-SEED", None, "没带 job_id"),
    ("api17_gate_hold_refuses_free_entry", "17-K7 占位作业一进来就不是 running ⇒ 必须红",
     {"list_segments": [SEGS], "export_segments": [REFUSE], "get_job": [HELD_RELEASED]},
     "P-SEED", None, "不是 running"),
    ("api17_gate_hold_refuses_free_entry", "17-K8 夹具没种上 ⇒ 必须红（不许静默跳过本腿）",
     {"list_segments": [SEGS]}, None, None, "没有夹具项目"),
]


def main():
    fail = 0
    greens = reds = 0
    for fn_name, name, by_name, seed, jobs, want in LEGS:
        try:
            detail, err, ctx = run(fn_name, by_name, seed=seed, jobs=jobs)
        except HarnessFail as exc:
            print("FAIL[台架失能] %-58s %s" % (name, exc))
            return 2
        if want is None:
            ok = err is None
            note = ("绿：%s" % (detail or ""))[:96]
            if ok and jobs is None and ctx["jobs"]:
                ok, note = False, "它往 ctx['jobs'] 里塞了东西 ⇒ 计费腿 API-09 会轮错对象"
            greens += 1 if ok else 0
        else:
            ok = err is not None and want in err
            note = ("红因：%s" % (err or "没红"))[:96]
            reds += 1 if ok else 0
        print(f"{'PASS' if ok else 'FAIL'} {name:58s} {note}")
        if not ok:
            fail = 1
    # ③ 一侧全空 = 台架自己坏了
    if greens == 0 or reds == 0:
        print("FAIL[台架失能] 绿侧 %d 格、红侧 %d 格 —— 任一侧为 0 都不许宣布通过" % (greens, reds))
        return 2
    print("形状侧合计 %d 格（绿 %d / 红 %d），全部按期望 —— 这两条计费判据的牙已被不花钱地复验"
          % (len(LEGS), greens, reds))
    return fail


if __name__ == "__main__":
    sys.exit(main())
