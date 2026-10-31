# 纯 Python 依赖（阶段 2，全部为源码包、无编译产物）

CI 里用 pip download --no-binary :all: 拉取并解进 app/，不进仓库：
- requests 2.34.2（Apache-2.0）
- urllib3 2.8.0（MIT）
- charset_normalizer 3.5.2（MIT）
- idna 3.20（BSD）
- certifi 2026.10.23（MPL-2.0，含 cacert.pem，供蜘蛛 https 用）

各包 LICENSE 文本同样由 CI 拷进 app/licenses/。
仓库里只放桥代码：spider_bridge.py 与 base/spider.py（TV 端同款，纯标准库）。
