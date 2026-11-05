#!/usr/bin/env python3
"""Archive 后把 app/Crypto/** 与 app/lxml/** 下的 .so 转成独立 .framework
（与 lib-dynload 的标准库扩展同一套打法），包内只留 .fwork 指针。
框架名用完整导入路径加点分（Crypto.Cipher._raw_aes），防不同子包同名冲突。
用法：python3 convert_pkg_modules.py <ChachaDrama.app 路径>
没有 .so 时静默成功（Crypto/lxml 没编出来时构建照常走）。"""
import os
import plistlib
import subprocess
import sys


def run_quiet(argv):
    """codesign / install_name_tool 只在 macOS 上有；缺失时跳过，不中断转换。"""
    try:
        subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def convert(app_path):
    fwdir = os.path.join(app_path, "Frameworks")
    app_res = os.path.join(app_path, "app")
    total = 0
    for pkg in ("Crypto", "lxml"):
        base = os.path.join(app_res, pkg)
        if not os.path.isdir(base):
            continue
        for root, _dirs, files in os.walk(base):
            for fn in sorted(files):
                if not fn.endswith(".so"):
                    continue
                so_path = os.path.join(root, fn)
                rel = os.path.relpath(so_path, app_res)  # 如 Crypto/Cipher/_raw_aes.abi3.so
                stem = rel[:-3]  # 去 .so
                if stem.endswith(".abi3"):
                    stem = stem[: -len(".abi3")]
                if ".cpython-" in stem:
                    stem = stem.split(".cpython-")[0]
                dotted = stem.replace(os.sep, ".")  # Crypto.Cipher._raw_aes
                fw_path = os.path.join(fwdir, dotted + ".framework")
                os.makedirs(fw_path, exist_ok=True)
                bin_path = os.path.join(fw_path, dotted)
                with open(so_path, "rb") as f:
                    data = f.read()
                with open(bin_path, "wb") as f:
                    f.write(data)
                run_quiet(["install_name_tool", "-id", "@rpath/%s.framework/%s" % (dotted, dotted), bin_path])
                plist = {
                    "CFBundleExecutable": dotted,
                    "CFBundleIdentifier": "org.python." + dotted,
                    "CFBundleName": dotted,
                    "CFBundlePackageType": "FMWK",
                    "CFBundleShortVersionString": "3.11",
                    "CFBundleVersion": "1",
                    "MinimumOSVersion": "16.0",
                }
                with open(os.path.join(fw_path, "Info.plist"), "wb") as f:
                    plistlib.dump(plist, f)
                # .fwork 指针放在 .so 原来的位置旁边，文件名用模块本名
                mod_name = stem.rsplit(os.sep, 1)[-1]
                with open(os.path.join(root, mod_name + ".fwork"), "w", encoding="utf-8") as f:
                    f.write("Frameworks/%s.framework/%s" % (dotted, dotted))
                run_quiet(["codesign", "--force", "--sign", "-", bin_path])
                os.remove(so_path)
                total += 1
                print("converted %s -> %s.framework" % (rel, dotted))
    print("pkg modules converted: %d" % total)
    return 0


if __name__ == "__main__":
    raise SystemExit(convert(sys.argv[1]))
