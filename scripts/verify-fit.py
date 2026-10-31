#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
#
# verify-fit.py —— verify-images.sh 的内核部分：解析 OpenWrt 的 FIT(.itb)，
# 把 kernel / rootfs 子镜像取出来做体检。单独跑也可以：
#
#   VERIFY_FILE=bin/targets/airoha/an7581/xxx-squashfs-sysupgrade.itb python3 scripts/verify-fit.py
#   VERIFY_FILE=xxx.itb VERIFY_HASH_ONLY=1 python3 scripts/verify-fit.py   # 只打印内核 md5
#
# 环境变量：
#   VERIFY_FILE        要检查的 .itb
#   VERIFY_KIND        sys | init | other（决定要不要做"不许含 cpio"的检查）
#   VERIFY_HASH_ONLY   非空则只输出内核 md5
#   VERIFY_KERNEL_MIN / VERIFY_KERNEL_MAX   解压后内核大小区间（字节）
#   VERIFY_ROOTFS_MIN  rootfs 最小大小（字节）
#
# 退出码：0 通过；1 有问题；2 解析失败

import hashlib
import os
import struct
import sys
import zlib

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9

# rootfs 里必然存在、而普通内核里不会有的路径名（用来识别"内核被 initramfs 顶替"）
ROOTFS_MARKERS = (
    b"etc/openwrt_release",
    b"lib/apk/packages",
    b"etc/config/network",
)


class Bad(Exception):
    pass


def read_fdt(data, off=0):
    """极简 FDT 解析：返回 [(path, {prop: value})]。够用来读 FIT 的 images 节点。"""
    if len(data) < off + 40:
        raise Bad("文件太小，读不到 FDT 头")
    magic, totalsize, off_struct, off_strings = struct.unpack_from(">IIII", data, off)
    if magic != FDT_MAGIC:
        raise Bad("不是 FIT/FDT（magic=%08x）" % magic)
    if off + totalsize > len(data):
        raise Bad("FDT 段超出文件范围（文件被截断？）")

    struct_block = data[off + off_struct:off + totalsize]
    strings_block = data[off + off_strings:off + totalsize]

    def cstr(blob, idx):
        end = blob.find(b"\0", idx)
        return blob[idx:end].decode("utf-8", "replace")

    pos = 0
    path = []
    nodes = []

    while pos + 4 <= len(struct_block):
        (token,) = struct.unpack_from(">I", struct_block, pos)
        pos += 4

        if token == FDT_BEGIN_NODE:
            end = struct_block.find(b"\0", pos)
            name = struct_block[pos:end].decode("utf-8", "replace")
            # 节点名是 NUL 结尾并按 4 字节对齐（FDT 规范），少了这步会对齐错位
            pos = (end + 1 + 3) & ~3
            # 根节点是空名字
            path = path + [name] if name else path[:1] or [""]
            if not name:
                path = [""]
        elif token == FDT_END_NODE:
            if len(path) > 1:
                path = path[:-1]
        elif token == FDT_PROP:
            length, nameoff = struct.unpack_from(">II", struct_block, pos)
            pos += 8
            value = struct_block[pos:pos + length]
            pos += (length + 3) & ~3
            prop = cstr(strings_block, nameoff)
            nodes.append(("/".join(p for p in path if p), prop, value))
        elif token == FDT_NOP:
            pass
        elif token == FDT_END:
            break
        else:
            raise Bad("FDT 结构损坏（token=%d）" % token)

    out = {}
    for node, prop, value in nodes:
        out.setdefault(node, {})[prop] = value
    return out


def u32(blob):
    return struct.unpack(">I", blob[:4])[0] if len(blob) >= 4 else None


def cstr_of(blob):
    return blob.split(b"\0")[0].decode("utf-8", "replace")


def gunzip(data, hard_cap=512 * 1024 * 1024):
    """完整解压（带硬上限，避免病态产物把内存吃光）。返回 (bytes, 是否被上限截断)"""
    d = zlib.decompressobj(31)
    out = bytearray()
    view = memoryview(data)
    step = 1 << 20
    for i in range(0, len(data), step):
        out += d.decompress(view[i:i + step])
        if len(out) > hard_cap:
            return bytes(out[:hard_cap]), True
    out += d.flush()
    return bytes(out), False


def image_data(data, node):
    """取出子镜像原始字节。

    mkimage 生成的 FIT 有两种放数据的方式：
      * data-position（绝对偏移，OpenWrt 用的是这种）
      * data-offset（相对 FIT 结构起点；结构就在文件开头，所以等价）
      * 内联 data 属性（小镜像才会用）
    """
    if "data-position" in node:
        off = u32(node["data-position"])
    elif "data-offset" in node:
        off = u32(node["data-offset"])
    elif "data" in node:
        blob = node["data"]
        return 0, len(blob), blob
    else:
        raise Bad("子镜像既没有 data-position/data-offset，也没有内联 data")

    if "data-size" not in node:
        raise Bad("子镜像缺少 data-size")
    size = u32(node["data-size"])
    if off + size > len(data):
        raise Bad("子镜像数据超出文件范围（offset=%d size=%d file=%d）" % (off, size, len(data)))
    return off, size, data[off:off + size]


def main():
    path = os.environ.get("VERIFY_FILE", "")
    if not path or not os.path.exists(path):
        print("VERIFY_FILE 没给或不存在")
        return 2

    kind = os.environ.get("VERIFY_KIND", "other")
    hash_only = bool(os.environ.get("VERIFY_HASH_ONLY"))
    kmin = int(os.environ.get("VERIFY_KERNEL_MIN", str(8 * 1024 * 1024)))
    kmax = int(os.environ.get("VERIFY_KERNEL_MAX", str(80 * 1024 * 1024)))
    rmin = int(os.environ.get("VERIFY_ROOTFS_MIN", str(5 * 1024 * 1024)))

    data = open(path, "rb").read()
    try:
        tree = read_fdt(data)
    except Bad as exc:
        print("FIT 解析失败：%s" % exc)
        return 2

    images = {}
    for node, props in tree.items():
        if node.startswith("images/") and "/" not in node[len("images/"):]:
            images[node.split("/")[-1]] = props

    if not images:
        print("FIT 里没有 images/ 节点")
        return 2

    problems = []

    kernel_raw = None
    for name, props in sorted(images.items()):
        itype = cstr_of(props.get("type", b""))
        if itype == "kernel":
            kernel_raw = image_data(data, props)[2]
            break

    if kernel_raw is None:
        print("FIT 里找不到 kernel 子镜像")
        return 2

    kdigest = hashlib.md5(kernel_raw).hexdigest()
    if hash_only:
        print(kdigest)
        return 0

    print("kernel 原始 %d 字节  md5=%s" % (len(kernel_raw), kdigest[:12]))

    # FIT 里声明的是什么压缩就用什么解（OpenWrt 的 recovery 镜像是 lzma/none，不能假定 gzip）
    comp = "none"
    for _name, props in sorted(images.items()):
        if cstr_of(props.get("type", b"")) == "kernel":
            comp = cstr_of(props.get("compression", b"none")) or "none"
            break
    print("kernel compression=%s" % comp)

    kernel = None
    if comp == "gzip":
        if kernel_raw[:2] != b"\x1f\x8b":
            problems.append("声明是 gzip，但数据不是（开头 %s）" % kernel_raw[:4].hex())
        else:
            try:
                kernel, capped = gunzip(kernel_raw)
            except zlib.error as exc:
                problems.append("kernel gzip 解压失败：%s" % exc)
                capped = False
            if capped:
                print("kernel 解压超过硬上限，先按上限算")
    elif comp in ("none", ""):
        kernel = kernel_raw
    else:
        print("（%s 压缩，本脚本不解压，只做体积/结构检查）" % comp)

    if kernel is not None:
        print("kernel %s %d 字节 (%.1f MiB)"
              % ("解压后" if comp == "gzip" else "未压缩", len(kernel), len(kernel) / 1048576))

        # arm64 Image 头部的魔数（+0x38 = "ARM\x64"）：确认打进去的确实是个内核
        if len(kernel) >= 64 and kernel[56:60] == b"ARMd":
            declared = struct.unpack_from("<Q", kernel, 16)[0]
            # image_size 含 BSS，允许比文件大，但不该离谱
            print("kernel 头部 image_size=%d（含 BSS，文件 %d）" % (declared, len(kernel)))
            if declared > len(kernel) + 64 * 1024 * 1024:
                problems.append("kernel 头部 image_size=%d 比实际大太多（产物被截断？）" % declared)
        else:
            problems.append("kernel 不是 arm64 Image（缺少 ARM\x64 魔数）")

        if not (kmin <= len(kernel) <= kmax):
            problems.append(
                "kernel 大小异常：%.1f MiB（期望 %d–%d MiB）"
                % (len(kernel) / 1048576, kmin / 1048576, kmax / 1048576))

        # sysupgrade 的普通内核里绝不该出现 rootfs 的文件。
        #
        # 为什么不用 cpio 魔数（070701）：十几 MB 的二进制里那个 6 字节串会**碰巧**出现
        # （实测好内核与坏内核都在同一个偏移 11005304 命中，且附近就有个孤立的
        # "TRAILER!!!"），拿它判会误报。改用 rootfs 里必然存在、而内核里不会有的
        # 路径名做指纹 —— 实测：好内核一个都搜不到，被 initramfs 顶替的内核全中。
        marks = [m for m in ROOTFS_MARKERS if m in kernel]
        if marks:
            msg = "kernel 里出现 rootfs 文件（%s）" % marks[0].decode()
            if kind == "sys":
                problems.append(msg + "：普通内核被 initramfs 内核顶替了")
            else:
                print("  （%s，recovery 镜像里这是正常的）" % msg)

    # rootfs
    rootfs_raw = None
    for name, props in sorted(images.items()):
        itype = cstr_of(props.get("type", b""))
        if itype == "filesystem" or "rootfs" in name:
            rootfs_raw = image_data(data, props)[2]
            break

    if rootfs_raw is None:
        if kind == "sys":
            problems.append("FIT 里找不到 rootfs 子镜像")
        else:
            print("rootfs 没作为独立子镜像（recovery 镜像的 rootfs 在内核里，正常）")
    else:
        print("rootfs %d 字节 (%.1f MiB)" % (len(rootfs_raw), len(rootfs_raw) / 1048576))
        if rootfs_raw[:4] != b"hsqs":
            problems.append("rootfs 不是 squashfs（开头 %s）" % rootfs_raw[:4].hex())
        if len(rootfs_raw) < rmin:
            problems.append("rootfs 太小：%d 字节" % len(rootfs_raw))

    if problems:
        for p in problems:
            print("!! " + p)
        return 1

    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
