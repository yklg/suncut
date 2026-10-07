#!/usr/bin/env python3
"""在 pbxproj 里给 App 层加一个 unit-test target（bundle.unit-test）。

本项目 pbxproj 已因「猜 ID / 位数错 / fileRef 未接线」翻车 4 次，本脚本据此设计：
① **不猜 ID**：扫描全文已用的 24 位 ID，取未占用的；
② **位数断言**：每个写入的 ID 必须恰好 24 位（Xcode 对非 24 位解析不出）；
③ **写完plutil -lint**：语法坏当场拦；
④ **引用完整性校验**：新 PBXBuildFile 的 fileRef 必须命中某个 PBXFileReference 定义；
⑤ **改动前备份**到 /tmp。

用法：python3 scripts/add_test_target.py
"""
import io
import os
import re
import shutil
import subprocess
import sys

PBX = "MixCut.xcodeproj/project.pbxproj"
TEST_TARGET_NAME = "MixCutAppTests"
PRODUCT_NAME = "MixCutAppTests"          # 与 target 名一致（App 侧是 SunCut ≠ MixCut）
APP_TARGET_NAME = "MixCut"
APP_PRODUCT_NAME = "SunCut"             # ⚠️ App 的 PRODUCT_NAME，与 target 名不同
TEST_FILES = ["VoiceCloneServiceTests.swift"]   # 首批：EN 组

MARK = " /* MixCutAppTests */"


def die(msg):
    print("ERR %s" % msg)
    sys.exit(1)


def main():
    if not os.path.exists(PBX):
        die("找不到 %s" % PBX)
    backup = "/tmp/pbxproj-before-testtarget.bak"
    if not os.path.exists(backup):
        shutil.copy(PBX, backup)
        print("已备份 → %s" % backup)

    text = io.open(PBX, encoding="utf-8").read()
    if MARK in text:
        print("SKIP test target 已存在")
        return 0

    used = set(re.findall(r"\b([0-9A-F]{24})\b", text))

    def new_id():
        # 顺序尝试：确定性前缀 + 递增尾号（不用随机，避免每次运行结果不同）
        n = 0
        while True:
            for pre in ("5A", "5B", "5C", "5D", "5E"):
                cand = pre + "%022X" % n
                if cand not in used:
                    used.add(cand)
                    return cand
            n += 1

    ids = {k: new_id() for k in
           ("target", "product", "sources_phase", "group", "config_list",
            "config_debug", "config_release", "proxy", "dependency")}

    for k, v in ids.items():
        if len(v) != 24:
            die("生成的 ID 位数不对：%s = %d 位" % (k, len(v)))

    print("新分配的 ID：")
    for k, v in ids.items():
        print("  %-16s %s" % (k, v))

    # ---- 1) PBXFileReference（测试产物）----
    ref = ('%s%s = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; '
           'includeInIndex = 0; path = %s.xctest; sourceTree = BUILT_PRODUCTS_DIR; };'
           % (ids["product"], MARK, PRODUCT_NAME))

    # ---- 2) PBXGroup（Tests 目录 + 挂进 Products 组）----
    tests_group = ('%s%s = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n'
                   '%s /* VoiceCloneServiceTests.swift */,\n\t\t\t);\n'
                   '\t\t\tpath = %s;\n\t\t\tsourceTree = "<group>";\n\t\t};'
                   % (ids["group"], MARK, ids["sources_phase"], TEST_TARGET_NAME))

    # ---- 3) PBXSourcesBuildPhase（测试文件的编译阶段）----
    file_refs = []
    for f in TEST_FILES:
        fr = new_id()
        file_refs.append((fr, f))
    phase = ('%s%s = {\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n'
             '\t\t\tfiles = (\n' % (ids["sources_phase"], MARK)
             + "".join("\t\t\t\t%s /* %s in Sources */,\n" % (fr, f) for fr, f in file_refs)
             + '\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};')

    # ---- 4) 容器代理 + 目标依赖（test 依赖 app，才能 @testable import）----
    proxy = ('%s%s = {\n\t\t\tisa = PBXContainerItemProxy;\n'
             '\t\t\tcontainerPortal = %s /* Project object */;\n'
             '\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = %s;\n'
             '\t\t\tremoteInfo = %s;\n\t\t};'
             % (ids["proxy"], MARK, None, None, APP_TARGET_NAME))  # 占位，下面替换
    # ⚠️ 锚点必须用「isa = PBXNativeTarget」定位，**不能**用 `/* MixCut */` ——
    # 实测踩坑：`/* MixCut */` 命中的是 **mainGroup**（PBXGroup也叫这个名字），
    # 会把 group 的字段顺序当成 target 的。判据：同段落里必须出现 `productType`。
    app_target_id = None
    for m in re.finditer(
            r"([0-9A-F]{24}) /\* [^*]*? \*/ = \{\s*\n\s*isa = PBXNativeTarget;(.*?)\n\t\t\};",
            text, re.S):
        if "productType" in m.group(2) and APP_TARGET_NAME in m.group(0)[:200]:
            app_target_id = m.group(1)
            break
    if not app_target_id:
        die("找不到 App 的 PBXNativeTarget（按 isa + productType 定位失败）")
    print("App target ID = %s" % app_target_id)
    portal = re.search(r"([0-9A-F]{24}) /\* Project object \*/ = \{", text)
    if not portal:
        die("找不到 Project object ID")
    proxy = proxy.replace("None /* Project object */", portal.group(1))
    proxy = proxy.replace("None;\n\t\t\tremoteGlobalIDString", app_target_id + ";\n\t\t\tremoteGlobalIDString")
    proxy = proxy.replace("None,\n\t\t};", APP_TARGET_NAME + ",\n\t\t};")

    dep = (ids["dependency"] + MARK + ' = {\n\t\t\tisa = PBXTargetDependency;\n'
           '\t\t\tname = ' + APP_TARGET_NAME + ';\n'
           '\t\t\ttarget = ' + app_target_id + ' /* ' + APP_TARGET_NAME + ' */;\n'
           '\t\t\ttargetProxy = ' + ids["proxy"] + ' /* PBXContainerItemProxy */;\n\t\t};')

    # ---- 5) XCBuildConfiguration（Debug 关键：TEST_HOST 指向 SunCut 可执行文件）----
    test_host = ('"$(BUILT_PRODUCTS_DIR)/%s.app/Contents/MacOS/%s"'
                 % (APP_PRODUCT_NAME, APP_PRODUCT_NAME))
    # ⚠️ 先把 PRODUCT_NAME 格式化掉：common 里有 `%s`，若留到 cfg_* 里再 % 一次，
    # 会与 cfg 自己的 %s 抢参数 ⇒ "not all arguments converted"。
    common = ('\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n'
              '\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
              '\t\t\t\tDEVELOPMENT_TEAM = "";\n'
              '\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n'
              '\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;\n'
              '\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.suncut.app.tests;\n'
              '\t\t\t\tPRODUCT_NAME = "' + PRODUCT_NAME + '";\n'
              '\t\t\t\tSWIFT_VERSION = 5.0;\n')
    # ⚠️ 全部用 `+` 拼接，**不用 `%` 格式化**。
    # Python 里 `+` 优先级高于 `%`，所以 `a + b + "...%s..." % x` 只会格式化最后一段，
    # 早先因此报 "not all arguments converted"（拼接的左侧还有 %s）。
    cfg_debug = (ids["config_debug"] + MARK
                 + ' /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n'
                 + common
                 + '\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";\n'
                 + '\t\t\t\tTEST_HOST = ' + test_host + ';\n'
                 + '\t\t\t};\n\t\t\tname = Debug;\n\t\t};')
    cfg_release = (ids["config_release"] + MARK
                   + ' /* Release */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n'
                   + common
                   + '\t\t\t};\n\t\t\tname = Release;\n\t\t};')
    cfg_list = (ids["config_list"] + MARK
                + ' /* Build configuration list for PBXNativeTarget "' + TEST_TARGET_NAME
                + '" */ = {\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n'
                + '\t\t\t\t' + ids["config_debug"] + ' /* Debug */,\n'
                + '\t\t\t\t' + ids["config_release"] + ' /* Release */,\n\t\t\t);\n'
                + '\t\t\tdefaultConfigurationIsVisible = 0;\n'
                + '\t\t\tdefaultConfigurationName = Release;\n\t\t};')

    # ---- 6) PBXNativeTarget ----
    target = ('%s%s = {\n\t\t\tisa = PBXNativeTarget;\n'
              '\t\t\tbuildConfigurationList = %s /* Build configuration list */;\n'
              '\t\t\tbuildPhases = (\n\t\t\t\t%s /* Sources */,\n\t\t\t);\n'
              '\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t\t%s /* PBXTargetDependency */,\n\t\t\t);\n'
              '\t\t\tname = %s;\n\t\t\tproductName = %s;\n'
              '\t\t\tproductReference = %s /* %s.xctest */;\n'
              '\t\t\tproductType = "com.apple.product-type.bundle.unit-test";\n\t\t};'
              % (ids["target"], MARK, ids["config_list"], ids["sources_phase"],
                 ids["dependency"], TEST_TARGET_NAME, PRODUCT_NAME,
                 ids["product"], PRODUCT_NAME))

    # ---- 7) 测试文件自身的 PBXFileReference + PBXBuildFile 段 ----
    file_sections = []
    for fr, f in file_refs:
        file_sections.append(
            '%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
            'path = %s; sourceTree = "<group>"; };' % (fr, f, f))

    # ---- PBXBuildFile 定义（⚠️ 必须有！Sources phase 的 files 里引用了它，
    #      但若PBXBuildFile 段没有对应定义，Xcode 报
    #      `-[PBXFileReference buildPhase]: unrecognized selector`（且 plutil 校验通过）——
    #      早先漏了这一段，二分法定位才发现 Sources 段是元凶）----
    buildfile_sections = []
    for fr, f in file_refs:
        bf = new_id()
        buildfile_sections.append(
            '%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
            % (bf, f, fr, f))

    # ---- 组装：各段插到对应 section ----
    out = text
    # PBXBuildFile：测试源文件不进 app target 的 Sources，但要进 test target 的 phase
    #   ⇒ 这里只加 PBXFileReference（编译单元由 test target 的 phase 引用）
    anchor = "/* End PBXBuildFile section */"
    if anchor not in out:
        die("找不到 PBXBuildFile section 锚点")
    out = out.replace(anchor, "\n".join(buildfile_sections) + "\n" + anchor, 1)

    anchor = "/* End PBXFileReference section */"
    if anchor not in out:
        die("找不到 PBXFileReference section 锚点")
    out = out.replace(anchor, "\n".join(file_sections) + "\n" + anchor, 1)

    anchor = "/* End PBXGroup section */"
    if anchor not in out:
        die("找不到 PBXGroup section 锚点")
    out = out.replace(anchor, tests_group + "\n" + anchor, 1)

    anchor = "/* End PBXSourcesBuildPhase section */"
    if anchor not in out:
        die("找不到 PBXSourcesBuildPhase section 锚点")
    out = out.replace(anchor, phase + "\n" + anchor, 1)

    anchor = "/* End PBXNativeTarget section */"
    if anchor not in out:
        die("找不到 PBXNativeTarget section 锚点")
    out = out.replace(anchor, target + "\n" + anchor, 1)

    anchor = "/* End PBXFileReference section */"
    out = out.replace(anchor, ref + "\n" + anchor, 1)

    # ContainerItemProxy / TargetDependency 需新建 section（本项目原本没有这两个段）
    if "/* Begin PBXContainerItemProxy section */" not in out:
        out = out.replace("/* End PBXNativeTarget section */",
                          "/* End PBXNativeTarget section */\n\n"
                          "/* Begin PBXContainerItemProxy section */\n" + proxy
                          + "\n/* End PBXContainerItemProxy section */\n\n"
                          "/* Begin PBXTargetDependency section */\n" + dep
                          + "\n/* End PBXTargetDependency section */", 1)

    anchor = "/* End XCConfigurationList section */"
    if anchor not in out:
        die("找不到 XCConfigurationList section 锚点")
    out = out.replace(anchor, cfg_list + "\n" + anchor, 1)

    anchor = "/* End XCBuildConfiguration section */"
    if anchor not in out:
        die("找不到 XCBuildConfiguration section 锚点")
    out = out.replace(anchor, cfg_debug + "\n" + cfg_release + "\n" + anchor, 1)

    # PBXProject：targets 加新 target
    m = re.search(r"(/\* Begin PBXProject section \*/.*?targets = \(\n)(.*?)(\t\t\t\);)", out, re.S)
    if not m:
        die("找不到 PBXProject.targets")
    out = out[:m.start(2)] + "\t\t\t\t%s /* MixCutAppTests */,\n" % ids["target"] \
        + out[m.end(2):]

    # attributes 加 TargetAttributes（TestTargetID 指向 App target）
    m = re.search(r"attributes = \{\n(.*?)\n\t\t\t\};", out, re.S)
    if not m:
        die("找不到 PBXProject.attributes")
    out = out[:m.start(1)] + (
        m.group(1)
        + "\n\t\t\t\tTargetAttributes = {\n"
          "\t\t\t\t\t%s = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;\n"
          "\t\t\t\t\t\tTestTargetID = %s;\n\t\t\t\t\t};\n\t\t\t\t};"
        % (ids["target"], app_target_id)
    ) + out[m.end(1):]

    # ---- 校验 ----
    # ⚠️ 只校验**本脚本生成的 ID**，不要扫全文件：
    # 全文件里本来就有各种 24 位 ID（含 Xcode 的target 运行时 ID 如 C00…/5A…），
    # 早先按"全文件所有长十六进制"校验 ⇒ 把合法 ID 误报成位数错误。
    for k, v in ids.items():
        if len(v) != 24:
            die("生成的 %s ID 位数不对：%d 位" % (k, len(v)))

    allids = re.findall(r"\b([0-9A-F]{24})\b", out)
    if len(allids) != len(set(allids)) and False:
        pass  # 同一 ID 在多处引用是正常的，只查冲突分配（脚本已保证）

    io.open(PBX, "w", encoding="utf-8").write(out)
    print("已写入 %s" % PBX)

    lint = subprocess.run(["plutil", "-lint", PBX], capture_output=True, text=True)
    print("plutil -lint: %s" % (lint.stdout + lint.stderr).strip())
    if "OK" not in lint.stdout:
        print("⚠️ 语法有问题，用备份回滚：cp %s %s" % (backup, PBX))
        return 1

    # 引用完整性：test target 的 phase 里每个 PBXBuildFile 的 fileRef 必须有定义
    # ⚠️ 正则必须容忍 `ID /* 名字 */ = {isa = PBXFileReference; ... }` 这种
    # 「注释在 isa 之前」的形态（pbxproj 的 PBXFileReference 段就是这个写法）；
    # 早先写成 `= \{isa = PBXFileReference` 要求 isa 紧跟 = 之后 ⇒ 漏判 ⇒ 误报"引用不完整"。
    refs_defined = set(re.findall(
        r"\b([0-9A-F]{24})\s*(?:/\*[^*]*\*/\s*)?= \{isa = PBXFileReference", out))
    for fr, f in file_refs:
        if fr not in refs_defined:
            print("⚠️ 引用不完整：%s 的 fileRef %s 无定义" % (f, fr))
            return 1
    print("引用完整性：OK（%d 个测试文件）" % len(file_refs))
    print("TEST_HOST = %s" % test_host)
    print("\n下一步：创建 shared scheme +跑 MODE=xcodebuild 验证")
    return 0


if __name__ == "__main__":
    sys.exit(main())