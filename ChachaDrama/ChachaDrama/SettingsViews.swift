import SwiftUI

/// 我的：订阅地址、内嵌 Python 版本、PY 自检、本地报错日志。
struct SettingsView: View {
    @State private var subURLText = Store.shared.subURL
    @State private var savedHint = ""
    @State private var selfTestResult = ""
    @State private var testing = false
    @State private var logText = ErrorLog.read()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("订阅").font(.headline)
                    TextField("订阅地址", text: $subURLText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                    HStack {
                        Button("保存") {
                            Store.shared.subURL = subURLText.trimmingCharacters(in: .whitespaces)
                            savedHint = "已保存，去剧场重新加载生效"
                        }
                        .buttonStyle(.bordered)
                        Button("恢复默认") {
                            subURLText = PyAPI.defaultSubscription
                            Store.shared.subURL = PyAPI.defaultSubscription
                            savedHint = "已恢复默认 ok海豚订阅"
                        }
                        .buttonStyle(.bordered)
                    }
                    if !savedHint.isEmpty {
                        Text(savedHint).font(.caption).foregroundColor(.gray)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("内嵌 Python").font(.headline)
                    Text(PyRuntime.version).font(.caption).foregroundColor(.gray)
                        .lineLimit(2)
                    Text("与 GHT63 iOS 同款 BeeWare 3.11 内嵌解释器；扩展模块受 AltStore 自签限制，见自检结果。")
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
                Text("茶茶短剧 1.0.0（原生版）")
                    .font(.caption).foregroundColor(.gray)
                Text("说明：本版只接订阅里的 PY 源（CMS 源后续可加）；要 Crypto/lxml、或走 HTTPS 的源暂不可用——这是 AltStore 自签下扩展模块加载不了的限制，不是代码问题；蚂蚁那种正式签名的包不受此限。")
                    .font(.caption).foregroundColor(.gray)
            }
            .padding()
        }
        .navigationTitle("我的")
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
        for mod in ["_hashlib", "_sha2", "_sha256", "_ssl", "ssl", "math", "re", "_struct"] {
            do {
                _ = try await PyAPI.runOffMain(code: probeScript(mod), ext: "", method: "home", argsJson: "[]")
                lines.append("✓ \(mod)")
            } catch {
                lines.append("✗ \(mod)：\(firstLine("\(error)"))")
            }
        }
        do {
            let sources = try await PyAPI.subscription(url: Store.shared.subURL)
            lines.append("订阅 PY 源 \(sources.count) 个")
            var tried = 0
            for s in sources where tried < 3 {
                let code = (try? await PyAPI.script(api: s.api)) ?? ""
                if code.contains("Crypto") || code.contains("lxml") { continue }
                tried += 1
                do {
                    let (cls, list) = try await PyAPI.home(source: s)
                    lines.append("✓ \(s.displayName)：分类 \(cls.count) 个、推荐 \(list.count) 条")
                } catch {
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
