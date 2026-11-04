"""蚂蚁式框架模块加载器：扩展模块不再是裸 .so，而是 .framework；
lib-dynload 里对应位置放 .fwork 指针文件（内容为相对 bundle 的框架二进制路径，
例如 "Frameworks/_ssl.framework/_ssl"）。

本模块在解释器启动后由 Swift 侧 import，往 sys.meta_path 队首挂一个 Finder：
import X 时，若在 lib-dynload 或 sys.path 包目录下找到 X.fwork，就用
ExtensionFileLoader 直接 dlopen 框架二进制（框架是标准签名对象，签名工具签得上）。
找不到 .fwork 时返回 None，走正常 import 流程，不影响纯 Python 模块。
"""
import os
import sys
from importlib.machinery import ExtensionFileLoader
from importlib.util import spec_from_loader

_BUNDLE = os.environ.get("CHACHA_BUNDLE", "")
_DYNLOAD = os.path.join(_BUNDLE, "Frameworks", "Python.framework", "lib-dynload")


class _FrameworkFinder:
    def find_spec(self, fullname, path=None, target=None):
        parts = fullname.split(".")
        search_dirs = [_DYNLOAD] + [p for p in sys.path if p]
        for base in search_dirs:
            if not base:
                continue
            if len(parts) > 1:
                cand = os.path.join(base, *parts[:-1], parts[-1] + ".fwork")
            else:
                cand = os.path.join(base, parts[0] + ".fwork")
            if not os.path.isfile(cand):
                continue
            try:
                with open(cand, "r", encoding="utf-8") as f:
                    pointer = f.read().strip()
            except OSError:
                continue
            if not pointer:
                continue
            bin_path = pointer if os.path.isabs(pointer) else os.path.join(_BUNDLE, pointer)
            if os.path.isfile(bin_path):
                loader = ExtensionFileLoader(fullname, bin_path)
                return spec_from_loader(fullname, loader)
        return None


sys.meta_path.insert(0, _FrameworkFinder())
