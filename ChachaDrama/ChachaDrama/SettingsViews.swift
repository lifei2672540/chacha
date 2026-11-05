import SwiftUI

/// 我的：订阅地址、内嵌 Python 版本、PY 自检、本地报错日志。
struct SettingsView: View {
    @State private var subURLs = Store.shared.subURLs
    @State private var activeURL = Store.shared.subURL
    @State private var newURLText = ""
    @State private var savedHint = ""
    @State private var refreshing = false
    @State private var selfTestResult = ""
    @State private var testing = false
    @State private var logText = ErrorLog.read()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("订阅接口").font(.headline)
                    ForEach(subURLs, id: \.self) { url in
                        HStack {
                            Button {
                                activateSubURL(url)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: url == activeURL ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(url == activeURL ? .orange : .gray)
                                    Text(url).font(.caption).lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            if subURLs.count > 1 {
                                Button {
                                    Store.shared.removeSubURL(url)
                                    syncSubURLs()
                                    savedHint = "已删除该接口"
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    TextField("新增订阅地址", text: $newURLText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                    HStack {
                        Button("添加并切换") {
                            let url = newURLText.trimmingCharacters(in: .whitespaces)
                            guard !url.isEmpty else {
                                savedHint = "地址不能为空"
                                return
                            }
                            if subURLs.contains(url) {
                                activateSubURL(url)
                                savedHint = "已在列表中，已切换为当前接口"
                            } else {
                                Store.shared.subURLs = subURLs + [url]
                                Store.shared.setActiveSubURL(url)
                                newURLText = ""
                                syncSubURLs()
                                savedHint = "已添加并切换为当前接口"
                            }
                        }
                        .buttonStyle(.bordered)
                        Button(refreshing ? "刷新中…" : "刷新订阅") {
                            Task { await refreshSubscription() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(refreshing)
                        Button("恢复默认") {
                            Store.shared.subURLs = [PyAPI.defaultSubscription]
                            Store.shared.subURL = PyAPI.defaultSubscription
                            syncSubURLs()
                            savedHint = "已恢复默认 ok海豚订阅"
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("点地址切换当前接口；刷新会重新拉当前接口并清掉已缓存的 PY 脚本，新加的源去剧场就能看到。")
                        .font(.caption).foregroundColor(.gray)
                    if !savedHint.isEmpty {
                        Text(savedHint).font(.caption).foregroundColor(.gray)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("内嵌 Python").font(.headline)
                    Text(PyRuntime.version).font(.caption).foregroundColor(.gray)
                        .lineLimit(2)
                    Text("与 GHT63 iOS 同款 BeeWare 3.11 内嵌解释器；扩展模块的加载情况见自检结果。")
                        .font(.caption).foregroundColor(.gray)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("PY 自检").font(.headline)
                    Button(testing ? "自检中…" : "开始自检") {
                        Task { await runSelfTest() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(testing)
                    if !selfTestResult.isEmpty {
                        Text(selfTestResult).font(.system(.caption, design: .monospaced))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("报错日志（本机）").font(.headline)
                    ScrollView {
                        Text(logText).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                    HStack {
                        Button("刷新") { logText = ErrorLog.read() }.buttonStyle(.bordered)
                        Button("清空") {
                            ErrorLog.clear()
                            logText = "暂无日志"
                        }.buttonStyle(.bordered)
                        ShareLink(item: logText) { Text("分享") }.buttonStyle(.bordered)
                    }
                }
                Text("茶茶短剧 1.0.7（原生版）")
                    .font(.caption).foregroundColor(.gray)
                Text("说明：本版接订阅里的 PY 源与 CMS 源；要 Crypto/lxml 的源能不能跑，看上面自检里 Crypto.Cipher.AES / lxml.etree 两行（自签下扩展模块要转成框架才能加载）。")
                    .font(.caption).foregroundColor(.gray)
            }
            .padding()
        }
        .navigationTitle("我的")
    }

    private func syncSubURLs() {
        subURLs = Store.shared.subURLs
        activeURL = Store.shared.subURL
    }

    private func activateSubURL(_ url: String) {
        Store.shared.setActiveSubURL(url)
        syncSubURLs()
        savedHint = "已切换为当前接口，去剧场查看"
    }

    private func refreshSubscription() async {
        refreshing = true
        defer { refreshing = false }
        do {
            let sources = try await PyAPI.subscription(url: Store.shared.subURL)
            PyAPI.clearScriptCache()
            let py = sources.filter { !$0.isCMS }.count
            let cms = sources.count - py
            savedHint = "已刷新：当前接口共 \(sources.count) 个源（PY \(py) 个、CMS \(cms) 个），去剧场查看"
        } catch {
            savedHint = "刷新失败：\(firstLine("\(error)"))"
        }
    }

    private func probeScript(_ mod: String) -> String {
        "import \(mod)\nfrom base.spider import BaseSpider\nclass Spider(BaseSpider):\n    def homeContent(self, filter=False):\n        return {'class': [], 'list': []}\n"
    }

    private func firstLine(_ s: String, max: Int = 200) -> String {
        let line = s.components(separatedBy: .newlines).first ?? s
        return line.count > max ? String(line.prefix(max)) + "…" : line
    }

    private func runSelfTest() async {
        testing = true
        defer { testing = false }
        var lines: [String] = []
        // 标准库扩展 + Crypto/lxml：后两行就是要 Crypto/lxml 的源能不能跑的答案。
        for mod in ["_hashlib", "_sha2", "_sha256", "_ssl", "ssl", "math", "re", "_struct", "Crypto.Cipher.AES", "lxml.etree"] {
            do {
                _ = try await PyAPI.runOffMain(code: probeScript(mod), ext: "", method: "home", argsJson: "[]")
                lines.append("✓ \(mod)")
            } catch {
                lines.append("✗ \(mod)：\(firstLine("\(error)"))")
            }
        }
        do {
            let sources = try await PyAPI.subscription(url: Store.shared.subURL)
            let py = sources.filter { !$0.isCMS }.count
            let cms = sources.count - py
            lines.append("订阅 PY 源 \(py) 个、CMS 源 \(cms) 个")
            var tried = 0
            for s in sources where tried < 3 {
                // CMS 源不用脚本，直接拉首页测；PY 源先看脚本是否要 Crypto/lxml。
                if s.isCMS {
                    tried += 1
                    do {
                        let (cls, list) = try await PyAPI.home(source: s)
                        Store.shared.markSourceOK(s.api)
                        lines.append("✓ \(s.displayName) [CMS]：分类 \(cls.count) 个、推荐 \(list.count) 条")
                    } catch {
                        Store.shared.markSourceFailed(s.api)
                        lines.append("✗ \(s.displayName) [CMS]：\(firstLine("\(error)"))")
                    }
                    continue
                }
                let code = (try? await PyAPI.script(api: s.api)) ?? ""
                if code.contains("Crypto") || code.contains("lxml") { continue }
                tried += 1
                do {
                    let (cls, list) = try await PyAPI.home(source: s)
                    Store.shared.markSourceOK(s.api)
                    lines.append("✓ \(s.displayName)：分类 \(cls.count) 个、推荐 \(list.count) 条")
                } catch {
                    Store.shared.markSourceFailed(s.api)
                    lines.append("✗ \(s.displayName)：\(firstLine("\(error)"))")
                }
            }
            if tried == 0 {
                lines.append("前几个源都要 Crypto/lxml，跳过源测试")
            }
        } catch {
            lines.append("订阅加载失败：\(firstLine("\(error)"))")
        }
        selfTestResult = lines.joined(separator: "\n")
    }
}
