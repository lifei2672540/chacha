#!/usr/bin/env python3
"""给 vendored 的 Crypto/Util/_raw_api.py 打补丁：iOS 框架化打包后，.abi3.so 已转成
独立 .framework，包内只留 .fwork 指针（内容为相对 bundle 的框架二进制路径）。
ctypes/cffi 加载走文件路径，import 钩子覆盖不到这里；先解析指针再 dlopen。
幂等：已打过补丁时直接退出。用法：python3 patch_raw_api.py <_raw_api.py 路径>"""
import sys

MARKER = "# [ChachaDrama] .fwork pointer support for iOS framework packaging"
PATCH = '''
    # [ChachaDrama] .fwork pointer support for iOS framework packaging
    # iOS 上 .so 已转成独立 .framework，包内只留 .fwork 指针（相对 bundle 的
    # 框架二进制路径）；ctypes/cffi 走文件路径加载，import 钩子覆盖不到这里，
    # 先解析指针再 dlopen。指针不存在时走原流程。
    try:
        fwork_name = pycryptodome_filename(dir_comps, basename + ".fwork")
        if os.path.isfile(fwork_name):
            with open(fwork_name, "r", encoding="utf-8") as _f:
                _pointer = _f.read().strip()
            if _pointer:
                _bundle = os.environ.get("CHACHA_BUNDLE", "")
                _bin = _pointer if os.path.isabs(_pointer) else os.path.join(_bundle, _pointer)
                if os.path.isfile(_bin):
                    return load_lib(_bin, cdecl)
    except OSError:
        pass
'''


def main():
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    if MARKER in src:
        print("patch_raw_api: already patched, skip")
        return 0
    anchor = '    split = name.split(".")\n    dir_comps, basename = split[:-1], split[-1]\n    attempts = []\n'
    if anchor not in src:
        print("patch_raw_api: ERROR anchor not found in _raw_api.py", file=sys.stderr)
        return 1
    src = src.replace(anchor, anchor + PATCH, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print("patch_raw_api: patched", path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
