#!/usr/bin/env python3
"""给 lxml sdist 里的 buildlibxml.py 打交叉编译补丁。

背景（茶茶短剧 1.0.8，构建 #40）：
STATIC_DEPS 下 buildlibxml.py 给 libiconv / libxml2 / libxslt 调 ./configure 时
不传 --host，交叉编译器（BeeWare 的 arm64-apple-ios-clang）下 autoconf 会试图
运行刚编出的测试程序，报 "cannot run C compiled programs"，etree 根本没开始编。

修法（沙箱用真 aarch64 交叉编译器复现并验证，2026-11-06）：
- configure_cmd 里加 '--host=arm64-apple-ios'：不带 --host 时 libiconv configure
  exit 77 报上述错误；带 --host 后 libiconv / libxml2 2.15.4 / libxslt 1.1.45
  三家的 configure + make 全通；libiconv 1.18 的 config.sub 认 arm64-apple-ios。
- 再加 '--disable-nls'：不加时 libiconv 的 make 在 po/ 翻译目录失败（缺 msgfmt，
  沙箱实测 exit 2，库本身已编出但 make 整体失败）；加后 make exit 0。
  libxslt 对 --disable-nls 只报 unrecognized options 警告，无害。

用法：python3 patch_lxml_buildlibxml.py <buildlibxml.py 路径>
幂等：已打过补丁时直接退出。锚文本找不到时报错退出，不静默跳过。
"""
import sys

HOST = "'--host=arm64-apple-ios',"
NLS = "'--disable-nls',"

ANCHOR = """    configure_cmd = ['./configure',
                     '--disable-dependency-tracking',
                     '--disable-shared',
                     '--prefix=%s' % prefix,
                     ]"""

PATCHED = """    configure_cmd = ['./configure',
                     '--disable-dependency-tracking',
                     '--disable-shared',
                     '--disable-nls',
                     '--host=arm64-apple-ios',
                     '--prefix=%s' % prefix,
                     ]"""


def main(path):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if HOST in src and NLS in src:
        print("patch_lxml_buildlibxml: already patched")
        return 0
    if ANCHOR not in src:
        print("patch_lxml_buildlibxml: anchor not found in %s "
              "(buildlibxml.py layout changed?)" % path, file=sys.stderr)
        return 1
    with open(path, "w", encoding="utf-8") as f:
        f.write(src.replace(ANCHOR, PATCHED, 1))
    print("patch_lxml_buildlibxml: patched %s" % path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1]))
