# Vendored 纯 Python 依赖（与 GHT63 iOS 同款）

进仓库的只有桥代码本身：

- `spider_bridge.py`：桥，`run_spider(code, ext, method, argsJson)`。
- `base/spider.py`：BaseSpider + `Spider = BaseSpider` 别名。
- `base/__init__.py`：包标记。

第三方纯 Python 包（requests、urllib3、charset_normalizer、idna、certifi）**不进仓库**，
由 CI 在构建前从源码包解压进 `app/`（见 workflow 的 Vendor pure Python deps 一步），
LICENSE 一并拷进 `app/licenses/`。构建产物里 `find app -name '*.so'` 必须为 0。
