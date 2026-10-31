import SwiftUI
import WebKit

/// GHT63 手机版：原生壳 + WKWebView，复用网页端全部功能。
/// 服务器地址存在本机（UserDefaults），默认点播站；设置里改地址后自动重载。
/// 注意：地址不要带 /index.html，App 自己拼。
struct ContentView: View {
    @AppStorage("serverBase") private var serverBase: String = "http://test.lifei555.cloudns.be/点播"
    @State private var showSettings = false
    @State private var webView = WKWebView()
    @State private var reloadToken = 0

    private var panelURL: URL? {
        let base = serverBase.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return nil }
        return URL(string: base + "/index.html")
    }

    var body: some View {
        NavigationStack {
            WebViewWrapper(webView: $webView, url: panelURL, reloadToken: reloadToken)
                .ignoresSafeArea(edges: .bottom)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("刷新") { reloadToken += 1 }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("设置") { showSettings = true }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView(serverBase: $serverBase)
                }
        }
    }
}

private struct WebViewWrapper: UIViewRepresentable {
    @Binding var webView: WKWebView
    let url: URL?
    let reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 网页端用 hls.js 播流：允许内联播放、不强制用户手势才播（点播放键即播），
        // 全屏与画中画走系统默认行为。
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        DispatchQueue.main.async { webView = view }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url = url else { return }
        // 地址变了或点了刷新才重载；网页内跳转不打断。
        if uiView.url?.absoluteString != url.absoluteString || reloadToken != context.coordinator.lastToken {
            context.coordinator.lastToken = reloadToken
            uiView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastToken = -1
    }
}

private struct SettingsView: View {
    @Binding var serverBase: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器地址（不要带 /index.html）") {
                    TextField("http://test.lifei555.cloudns.be/点播", text: $draft)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section {
                    Button("保存") {
                        let v = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if !v.isEmpty { serverBase = v }
                        dismiss()
                    }
                    Button("恢复默认") {
                        serverBase = "http://test.lifei555.cloudns.be/点播"
                        dismiss()
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { draft = serverBase }
        }
    }
}
