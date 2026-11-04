#!/usr/bin/env python3
"""把已存在的测试源文件挂进 Xcode 建的 unit-test target。

与 `add_test_target.py` 的区别（那次失败的原因）：
-那次是**从零建 target**，要生成 PBXContainerItemProxy / TargetDependency /
  XCConfigurationList 等 7 类结构，其中两处结构语义猜错 ⇒
  `-[PBXFileReference buildPhase]: unrecognized selector`，Xcode 读不出工程。
- 这次**target 已由 Xcode GUI 建好**（`MixCutAppTests` 已在 PBXNativeTarget 里、
  productType 正确、Host Application 已设），只需补**一个文件的四段登记**，
  形态完全照抄同文件里已有的 App 侧样例 ⇒ 不猜任何结构语义。

幂等：已登记则 SKIP。

用法：
    python3 Scripts/link_test_files.py                      # 首批那颗（默认）
    python3 Scripts/link_test_files.py ExportCanvasReadbackTests.swift

⚠️ 2026-11-04 起：`MixCutAppTests` 这颗 target 已经是**同步组目录**
   （`fileSystemSynchronizedGroups` ⇒ Xcode 按目录自动收文件），给它里面的文件补登记是冗余，
   每构建一次多响一条 `Skipping duplicate build file`。本脚本对这种情况**默认拒绝**，
   需要强行写入才加 `--force`。历史遗留的 10 颗冗余登记由
   `check_pbx_registration.py` 的 `SYNC_REGISTERED` 名册钉住（不许再涨，清一颗就得同轮改小名册）。
"""
import io
import os
import re
import shutil
import subprocess
import sys

PBX = "MixCut.xcodeproj/project.pbxproj"
TEST_TARGET = "MixCutAppTests"
TEST_FILE = "VoiceCloneServiceTests.swift"
TEST_DIR = "MixCutAppTests"          # 磁盘上真实目录
BACKUP = "/tmp/pbxproj-before-linking-tests.bak"


def die(msg):
    print("ERR %s" % msg)
    sys.exit(1)


def free_ids(used, n):
    """取 n 个未占用的 24 位 ID（不猜前缀，只保证唯一）。"""
    out = []
    i = 0
    while len(out) < n:
        for pre in ("7A", "7B", "7C", "7D"):
            cand = pre + "%022X" % i
            if cand not in used:
                used.add(cand)
                out.append(cand)
                if len(out) == n:
                    return out
        i += 1
    return out


def main():
    global TEST_FILE
    # 默认沿用首批那颗文件；`python3 Scripts/link_test_files.py <文件名.swift>` 登记后续新增的。
    # 原先文件名写死在模块常量里，导致"给 App 测试目标加第二个文件"必须改脚本本体。
    if len(sys.argv) > 1:
        TEST_FILE = sys.argv[1]
    if not os.path.exists(PBX):
        die("找不到 %s" % PBX)
    src = os.path.join(TEST_DIR, TEST_FILE)
    if not os.path.exists(src):
        die("找不到测试源文件 %s" % src)

    text = io.open(PBX, encoding="utf-8").read()
    if TEST_FILE in text:
        print("SKIP %s 已在pbxproj 中" % TEST_FILE)
        return 0

    # 〔2026-11-04 新增的这道拦子〕同步组目录**不需要**手工登记，登记只会让它进两遍。
    # 起因：给 `MixCutAppTests/FolderMixCategoryLimitTests.swift` 补登记时，App 腿实测那颗文件
    # 本来就一直在编译执行（`Compiling …` 在册、判据跑绿、登记数为 0），而补完反而多响一条
    # `Skipping duplicate build file`。⇒ 这支脚本对同步组 target 是一台**制造冗余**的机器，
    # 必须默认拒绝，而不是靠用的人记得这件事。
    # 生效条件：目标 target 声明了 `fileSystemSynchronizedGroups`，且本次要登记的目录正是它。
    # 拦不住什么：只认"同一颗 target 同一颗目录"，别的 target 若确为经典分组照旧放行。
    # 最坏代价：需要强行写入时用 `--force`（例如将来目录被改回经典分组）。
    if "--force" not in sys.argv[1:]:
        sync_ids = {}
        for line in text.splitlines():
            m = re.search(r"([0-9A-F]{24}) /\* .*? \*/ = \{isa = PBXFileSystemSynchronizedRootGroup;"
                          r".*?path = ([^;]+);", line)
            if m:
                sync_ids[m.group(1)] = m.group(2).strip().strip('"')
        tm0 = re.search(r'([A-F0-9]{24}) /\* %s \*/ = \{\s*\n\s*isa = PBXNativeTarget;(.*?)\n\t\t\};'
                        % re.escape(TEST_TARGET), text, re.S)
        fsg = re.search(r"fileSystemSynchronizedGroups = \((.*?)\);", tm0.group(2), re.S) if tm0 else None
        owned = {sync_ids[i] for i in re.findall(r"([0-9A-F]{24})", fsg.group(1)) if i in sync_ids} if fsg else set()
        if TEST_DIR in owned:
            die("%s 是 %s 的**同步组目录**（fileSystemSynchronizedGroups），"
                "Xcode 按目录自动收文件 ⇒ 手工登记是冗余，只会多一条 `Skipping duplicate build file`。"
                "确实需要强行写入时加 --force" % (TEST_DIR, TEST_TARGET))

    # 备份（改工程前必做——本项目已因此翻车 5 次）
    if not os.path.exists(BACKUP):
        shutil.copy(PBX, BACKUP)
        print("已备份 → %s" % BACKUP)

    used = set(re.findall(r"\b([0-9A-F]{24})\b", text))
    build_id, file_id = free_ids(used, 2)
    assert len(build_id) == 24 and len(file_id) == 24, "生成的 ID 位数不对"

    # ---- 定位 test target 的 Sources phase（必须由 Xcode 已存在，不自己造）----
    tm = re.search(
        r'([A-F0-9]{24}) /\* %s \*/ = \{\s*\n\s*isa = PBXNativeTarget;(.*?)\n\t\t\};'
        % re.escape(TEST_TARGET), text, re.S)
    if not tm:
        die("找不到 %s 的 PBXNativeTarget（target 没建？）" % TEST_TARGET)
    target_id = tm.group(1)
    phases = re.search(r"buildPhases = \((.*?)\);", tm.group(2), re.S)
    if not phases:
        die("%s 没有 buildPhases" % TEST_TARGET)
    sources_id = re.search(r"([A-F0-9]{24})", phases.group(1))
    sources_id = sources_id.group(1) if sources_id else None
    if not sources_id:
        die("%s 的 buildPhases 里没有 phase" % TEST_TARGET)

    # ---- 定位（或建）test target 的源文件组 ----
    gm = re.search(
        r'([A-F0-9]{24}) /\* %s \*/ = \{\s*\n\s*isa = PBXGroup;(.*?)\n\t\t\};'
        % re.escape(TEST_TARGET), text, re.S)
    if gm:
        group_id = gm.group(1)
        print("复用已有源文件组：%s" % group_id)
        insert_group_member = False
    else:
        group_id = free_ids(used, 1)[0]
        insert_group_member = True
        print("新建源文件组：%s" % group_id)

    # ---- 1) PBXBuildFile ----
    buildfile = ('%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
                 % (build_id, TEST_FILE, file_id, TEST_FILE))
    anchor = "/* End PBXBuildFile section */"
    if anchor not in text:
        die("找不到 PBXBuildFile section 锚点")
    text = text.replace(anchor, buildfile + "\n" + anchor, 1)

    # ---- 2) PBXFileReference ----
    # 形态照抄同段里 App 侧已有样例：注释在 isa 之前、sourceTree = "<group>"
    fileref = ('%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
               'path = %s; sourceTree = "<group>"; };' % (file_id, TEST_FILE, TEST_FILE))
    anchor = "/* End PBXFileReference section */"
    if anchor not in text:
        die("找不到 PBXFileReference section 锚点")
    text = text.replace(anchor, fileref + "\n" + anchor, 1)

    # ---- 3) Sources phase 的 files 里加一行 ----
    pm = re.search(re.escape(sources_id) +
                   r' /\* Sources \*/ = \{(.*?)\n\t\t\};', text, re.S)
    if not pm:
        die("找不到 %s 的 Sources phase 定义" % sources_id)
    body = pm.group(1)
    if "files = (" in body:
        new_body = body.replace(
            "files = (",
            "files = (\n\t\t\t\t%s /* %s in Sources */," % (build_id, TEST_FILE), 1)
    else:
        # phase 是空的（Xcode 刚建、没加过文件）⇒ files = (); 要替换成带内容的形式
        new_body = re.sub(r"files = \(\s*\);",
                          "files = (\n\t\t\t\t%s /* %s in Sources */,\n\t\t\t);"
                          % (build_id, TEST_FILE), body, count=1)
        if new_body == body:
            die("Sources phase 的 files 段形态异常：%s" % body[:120])
    text = text[:pm.start(1)] + new_body + text[pm.end(1):]

    # ---- 4) 源文件组成员 ----
    if insert_group_member:
        group = ('%s /* %s */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n'
                 '\t\t\t\t%s /* %s */,\n\t\t\t);\n'
                 '\t\t\tpath = %s;\n\t\t\tsourceTree = "<group>";\n\t\t};'
                 % (group_id, TEST_TARGET, file_id, TEST_FILE, TEST_TARGET))
        # 挂到 mainGroup 下（与 Xcode 自己挂 target 的位置一致）
        mm = re.search(r"(%s = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \()" % re.escape(
            re.search(r"mainGroup = ([A-F0-9]{24})", text).group(1)), text)
        if not mm:
            die("找不到 mainGroup 的 children 起点")
        text = text[:mm.end(1)] + "\n\t\t\t\t%s /* %s */," % (group_id, TEST_TARGET) \
            + text[mm.end(1):]
        anchor = "/* End PBXGroup section */"
        text = text.replace(anchor, group + "\n" + anchor, 1)
    else:
        gm2 = re.search(re.escape(group_id) +
                        r' /\* %s \*/ = \{\s*\n\s*isa = PBXGroup;(.*?)\n\t\t\};'
                        % re.escape(TEST_TARGET), text, re.S)
        body2 = gm2.group(1)
        if "children = (" in body2:
            nb = body2.replace("children = (",
                                "children = (\n\t\t\t\t%s /* %s */," % (file_id, TEST_FILE), 1)
        else:
            nb = re.sub(r"children = \(\s*\);",
                        "children = (\n\t\t\t\t%s /* %s */,\n\t\t\t);" % (file_id, TEST_FILE),
                        body2, count=1)
        text = text[:gm2.start(1)] + nb + text[gm2.end(1):]

    # ---- 校验（ID 位数 + 引用完整性）----
    for v in (build_id, file_id, group_id):
        if len(v) != 24:
            die("ID 位数不对：%s" % v)
    if TEST_FILE not in text:
        die("写入后仍找不到 %s" % TEST_FILE)

    io.open(PBX, "w", encoding="utf-8").write(text)
    print("已写入 %s" % PBX)

    lint = subprocess.run(["plutil", "-lint", PBX], capture_output=True, text=True)
    print("plutil -lint: %s" % (lint.stdout + lint.stderr).strip())

    # 权威校验：Xcode 能否读出（plutil 只验plist 语法，验不出结构错）
    print("xcodebuild -list:")
    r = subprocess.run(["xcodebuild", "-list", "-project", "MixCut.xcodeproj"],
                       capture_output=True, text=True)
    tail = (r.stdout + r.stderr).strip().split("\n")[-4:]
    for l in tail:
        print("   ", l)
    if "damaged" in (r.stdout + r.stderr).lower():
        print("❌ Xcode 读不出工程⇒ 用备份回滚：cp %s %s" % (BACKUP, PBX))
        return 1
    print("✅ Xcode 能读出工程")
    print("\nbuildID=%s  fileID=%s  groupID=%s" % (build_id, file_id, group_id))
    return 0


if __name__ == "__main__":
    sys.exit(main())