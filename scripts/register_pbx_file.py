#!/usr/bin/env python3
"""把一个新增的 App 侧源文件登记进 project.pbxproj（四段）。

用法：
    ./scripts/register_pbx_file.py <文件名.swift> [模板文件名.swift]

为什么需要它（2026-10-07 实测，本项目已因此连红三次）：
① **沙盒typecheck/silgen 看不出漏登记** —— 它们按文件系统 find 扫描，
   不读 pbxproj 编译单元；只有真机 xcodebuild 才红；
② **ID 冲突最阴险** —— 猜个"看着空闲"的 ID，实际已被别的文件占用，
   Xcode 判定两者同一文件 ⇒ 新文件被**静默踢出编译单元**（它自己不报错），
   报错的是**别的文件**（cannot find type），外加两条 group/duplicate warning；
③ **ID 位数与 path 基准随前缀/分组而变**：App 侧 AE/AF + 组内裸名，
   Core 侧 AC/AD + `name=` + `path = Sources/MixCutCore/...`，写成 4 位 Xcode 解析不出。

脚本自己处理：扫空闲 ID（不猜）、按完整 24 位 ID 断言无冲突、逐段沿模板插入。
**ID 冲突或锚点未命中一律非 0 退出**，不做"看起来成功"的降级。
"""
import io
import os
import re
import sys


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    new_name = argv[1]
    tpl_name = argv[2] if len(argv) > 2 else "VoiceAuditionPlayer.swift"
    pbx = "/Users/yilukaige/mixed_cut-main/MixCut.xcodeproj/project.pbxproj"
    ROOT = os.path.dirname(os.path.dirname(pbx))

    with io.open(pbx, encoding="utf-8") as f:
        text = f.read()
    # 先验文件真的存在：2026-10-09 实测我把一个写错的名字登记进去了，脚本一声没吭
    # —— Xcode 侧的症状是 "Build input file cannot be found"，报错点离根因隔一层。
    found = None
    for cand in (os.path.join(ROOT, "Sources/MixCutCore", new_name),
                 os.path.join(ROOT, "MixCut", new_name)):
        if os.path.isfile(cand):
            found = cand
            break
    if found is None:
        # App 侧文件按功能分在 MixCut 的各级子目录里（Infrastructure/、Services/BGM/…），
        # 只查顶层会把真实存在的文件判成"拼写错了"。递归找，且**唯一命中**才算数：
        # 同名两份时登记哪一份是个真问题，不许默默挑一份。
        hits = [os.path.join(dir_, new_name)
                for dir_, _, files in os.walk(os.path.join(ROOT, "MixCut"))
                if new_name in files]
        if len(hits) == 1:
            found = hits[0]
        elif len(hits) > 1:
            print("ERR %s 在 MixCut 下有 %d 份同名文件：%s ⇒ 先定哪一份是要编译的那个"
                  % (new_name, len(hits), [os.path.relpath(h, ROOT) for h in hits]))
            return 1
    if found is None:
        print("ERR 源文件不存在，拒绝登记：%s（先在 Sources/MixCutCore 与 MixCut 下确认拼写）"
              % new_name)
        return 1
    if new_name in text:
        print("SKIP %s 已在 pbxproj 中" % new_name)
        return 0

    lines = text.split("\n")

    def prefix_of(name, kind):
        """从模板的 PBXBuildFile / PBXFileReference 行取出 ID 前缀。

        本工程pbxproj 里**两种 ID 风格并存**（都是合法的，Xcode 都认）：
        · Xcode 自动生成的旧文件：`FD08F64BC77F45B281D55094`（24 位十六进制，**无字母前缀**）；
        · 手工新增的文件：`AE0000000000000000000041`（AE/AF 或 AC/AD + 22 位）。
        前缀判定必须覆盖两者，否则会把老文件误判成「没登记」。
        """
        key = "isa = PBXBuildFile" if kind == "build" else "PBXFileReference"
        for l in lines:
            if name not in l or key not in l:
                continue
            # build 段与 file 段的行都含 "PBXBuildFile" 字样（fileRef 里也带 fileRef 引用），
            # 故按顺序精确区分：只取自身定义的那一段。
            if kind == "file" and "isa = PBXBuildFile" in l:
                continue
            tok = l.strip().split()[0]
            if re.match(r"^A[EFCD][0-9A-F]{22}$", tok):
                return tok[:2]
            if re.match(r"^[0-9A-F]{24}$", tok):
                return ""      # 无前缀风格（Xcode 自动生成的旧文件）
        return None

    def free_id(prefix, exclude=()):
        """扫已用尾号取空闲。prefix 为 "" 表示沿用 Xcode 的无前缀风格。

        `exclude` 是给第二次调用用的：同一个文件的 PBXBuildFile 与 PBXFileReference
        **必须两个不同 ID**，同前缀时两次独立扫描会给出同一个尾号 —— Xcode 会把两个对象
        判成同一个文件，新文件被静默踢出编译单元。"""
        used = set()
        if prefix:
            pat = re.compile(r"\b%s0*([0-9A-Fa-f]{4})(?=[/\s])" % prefix)
        else:
            # 无前缀风格：只看 24 位纯十六进制 ID 的后4 位。
            pat = re.compile(r"\b([0-9A-F]{24})(?=[/\s])")
        for l in lines:
            for m in pat.finditer(l):
                used.add(int(m.group(1)[-4:], 16))
        excl = {t.upper() for t in exclude}
        for n in range(0x20, 0x400):
            tail = "%04X" % n
            if n not in used and tail not in excl:
                return tail
        raise RuntimeError("ID 空间耗尽")

    build_prefix = prefix_of(tpl_name, "build")
    file_prefix = prefix_of(tpl_name, "file")
    # ⚠️ 判空必须用 `is None` 而不是 `not`：`prefix_of` 对「无前缀风格」返回空串
    #    （这是**合法**结果，不是失败）。写成 `not` 会把老文件模板误报成"没登记"。
    if build_prefix is None or file_prefix is None:
        print("ERR 找不到模板 %s 的 PBX 段（它自己没登记？）" % tpl_name)
        return 1
    def compose_id(prefix, tail4):
        """总长恒为 24（含前缀）。前缀 2 位 ⇒尾数补 20 位；无前缀 ⇒补 24 位。"""
        if prefix:
            return prefix + tail4.rjust(22, "0")
        # 模板是老式无前缀 ID 时，仍按本项目「手工新增」的约定用 AF 前缀：
        # 仓里的自检脚本（check_pbx_registration.py）按 A[EFCD] 认手工段，
        # 生成 `0000…` 这种形态会让登记**看起来完整但没人认得**。
        return "AF" + tail4.rjust(22, "0")

    build_id = compose_id(build_prefix, free_id(build_prefix))
    file_id = compose_id(file_prefix, free_id(file_prefix, exclude=(build_id[-4:],)))
    # 硬断言：同文件的两个 ID 绝不能相同（2026-10-09 实测：这一条漏了，登记"看起来成功"
    # 但 Xcode 直接把文件当重复对象丢弃，报错点在别的文件上）。
    if build_id == file_id:
        print("ERR build/file ID 相同：%s —— Xcode 会静默丢弃该文件" % build_id)
        return 1

    # 位数断言：Xcode 对非 24 位的 ID 直接解析不出（表现为「Build input file cannot
    # be found」，且报错在别处、根因极难定位）—— 当场拦下，不留到真机。
    for label, ident in (("build", build_id), ("file", file_id)):
        if len(ident) != 24:
            print("ERR %s ID 位数错：%s（%d 位，应 24 位）" % (label, ident, len(ident)))
            return 1

    tpl_build = tpl_file = None
    for l in lines:
        if tpl_name in l and "isa = PBXBuildFile" in l:
            tpl_build = l.strip().split()[0]
        if tpl_name in l and "PBXFileReference" in l and "isa = PBXBuildFile" not in l:
            tpl_file = l.strip().split()[0]
    if not tpl_build or not tpl_file:
        print("ERR 模板 ID 定位失败")
        return 1

    # Core 侧的 FileReference 需要 name + 全路径；App 侧是裸名 + 组 path
    # Core/App 的判据只能看模板自己的 FileReference 怎么写的：
    # 按 ID 前缀猜是错的 —— 本工程 Core 侧既有 AC/AD 也有 AF（SegmentationPlanner 就是 AF），
    # 猜错会把 Core 文件登记成裸 path，Xcode 按组路径解析 ⇒ 找不到文件。
    tpl_ref_body = ""
    for l in lines:
        if tpl_name in l and "PBXFileReference" in l and "isa = PBXBuildFile" not in l:
            tpl_ref_body = l
            break
    is_core = "Sources/MixCutCore/" in tpl_ref_body
    if is_core:
        ref_line = ('{isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = '
                    'sourcecode.swift; name = %s; path = Sources/MixCutCore/%s; '
                    'sourceTree = "<group>"; };' % (new_name, new_name))
    else:
        ref_line = ('{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
                    'path = %s; sourceTree = "<group>"; };' % new_name)

    out, done = [], {1: False, 2: False, 3: False, 4: False}
    for line in lines:
        out.append(line)
        st = line.strip()
        if (not done[1] and st.startswith(tpl_build) and tpl_name in st
                and "isa = PBXBuildFile" in st):
            ind = line[:len(line) - len(line.lstrip())]
            out.append("%s%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                       % (ind, build_id, new_name, file_id, new_name))
            done[1] = True
        elif (not done[2] and st.startswith(tpl_file) and tpl_name in st
              and "PBXFileReference" in st and "isa = PBXBuildFile" not in st):
            ind = line[:len(line) - len(line.lstrip())]
            out.append("%s%s /* %s */ = %s" % (ind, file_id, new_name, ref_line))
            done[2] = True
        elif (not done[3] and st.startswith(tpl_file) and st.endswith("*/,")
              and "PBXFileReference" not in st):
            ind = line[:len(line) - len(line.lstrip())]
            out.append("%s%s /* %s */," % (ind, file_id, new_name))
            done[3] = True
        elif (not done[4] and st.startswith(tpl_build) and st.endswith("*/,")
              and "isa = PBXBuildFile" not in st):
            ind = line[:len(line) - len(line.lstrip())]
            out.append("%s%s /* %s in Sources */," % (ind, build_id, new_name))
            done[4] = True

    missing = [k for k, v in done.items() if not v]
    if missing:
        print("ERR 以下段落未插入：%s（锚点未命中，不做降级）" % missing)
        return 1

    result = "\n".join(out)
    # ID 冲突自检：必须按**完整 24 位 ID** 比对；只比后 4 位会把不同前缀混成假冲突。
    # ⚠️ 同一个文件的两类 ID（PBXBuildFile 段与 PBXSourcesBuildPhase 段）注释名不同
    #    （"X.swift" vs "X.swift in Sources"），那是**同一个文件的正常 4 段**，
    #    不是冲突。判据：同一 ID 下的**裸文件名**必须唯一。
    ids = re.findall(r"\b((?:A[EFCD][0-9A-F]{22}|[0-9A-F]{24}))\s+/\* ([^*]+?) \*/", result)
    by = {}
    for full, comment in ids:
        name = comment.strip()
        if name.endswith(" in Sources"):        # 同文件的 Sources 段注释
            name = name[: -len(" in Sources")]
        by.setdefault(full, set()).add(name.strip())
    dup = {k: sorted(v) for k, v in by.items() if len(v) > 1}
    if dup:
        print("ERR 存在 ID 冲突：%s" % dup)
        return 1

    # ⭐ 引用完整性自检（本项目已因此连红三次，每次都是静默失败）：
    #  ① **PBXBuildFile 的 fileRef 值必须能命中某个 PBXFileReference 定义**。
    #     位数不足时 Xcode **静默丢弃整个文件**——不报任何错，只是它不在编译单元里，
    #     于是症状出现在**别的文件**上（`cannot find type 'XxxVM' in scope`），
    #     根因离报错位置隔了三层。2026-10-07 实测：3 个文件因 fileRef 少 2 位而消失。
    #  ② **Group children 的引用必须能命中 fileRef 定义**（少一位 ⇒ 文件不在任何组 ⇒ 同样消失）。
    #  ③ 每条 PBXBuildFile 的 fileRef 存在时，其 PBXFileReference 必须真实存在。
    # 全部按**完整 24 位 ID** 判定，且只在本文件涉及的 ID 上报错（避免全库噪音）。
    mine = {build_id, file_id}
    ref_defs = set(re.findall(r"\b([0-9A-F]{24})\s+/\* [^*]*?\*/ = \{isa = PBXFileReference", result))
    group_refs = set(re.findall(r"^\s+([0-9A-F]{24})\s+/\* [^*]*?\*/,$", result, re.M))
    sources_refs = set(re.findall(r"^\s+([0-9A-F]{24})\s+/\* [^*]*?in Sources \*/,$", result, re.M))

    problems = []
    for label, ident in (("build", build_id), ("file", file_id)):
        if len(ident) != 24:
            problems.append("%s ID 位数 %d（应 24）：%s" % (label, len(ident), ident))
    # 新 PBXBuildFile 的 fileRef 必须命中 fileRef 定义
    m = re.search(r"\b%s /\* %s in Sources \*/ = \{isa = PBXBuildFile; fileRef = (\S+?) /\*"
                  % (re.escape(build_id), re.escape(new_name)), result)
    if not m:
        problems.append("PBXBuildFile 段缺失或格式不符：%s" % new_name)
    else:
        fr = m.group(1)
        if len(fr) != 24:
            problems.append("fileRef 值位数 %d（应 24）：%s" % (len(fr), fr))
        elif fr not in ref_defs:
            problems.append("fileRef 指向不存在的 PBXFileReference：%s" % fr)
    if file_id not in group_refs:
        problems.append("Group children 缺少 fileRef %s（文件会不在任何组）" % file_id)
    if file_id not in ref_defs:
        problems.append("缺少 PBXFileReference 定义：%s" % file_id)
    if build_id not in sources_refs:
        problems.append("PBXSourcesBuildPhase 缺少 PBXBuildFile %s（文件不在编译单元）" % build_id)
    if problems:
        print("ERR 登记不完整，Xcode 会**静默丢弃**该文件（症状报在别的文件上）：")
        for p_ in problems:
            print("     - %s" % p_)
        return 1

    # 语法兜底：让 plutil 校验 pbxproj（它能在真机之前抓住缺分号一类的破坏）
    with io.open(pbx, "w", encoding="utf-8") as f:
        f.write(result)
    lint = os.popen('plutil -lint "%s" 2>&1' % pbx).read().strip()
    if "OK" not in lint:
        print("ERR pbxproj 语法校验失败：%s" % lint)
        return 1
    print("OK %s 已登记四段 build=%s file=%s（出现 %d 次）"
          % (new_name, build_id, file_id, result.count(new_name)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))