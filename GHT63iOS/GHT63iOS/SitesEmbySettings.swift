import SwiftUI

/// 采集站（TV 版 SitesActivity 的触屏版）：站列表 → 本站分类 → 单站浏览。
/// 浏览走聚合搜索的 disabled 反选（除本站外全停用），与 TV 同款；
/// 内置站无地址无分类，只出最新；空站显示“该站暂无内容”。
struct SitesView: View {
    @State private var builtin: [String] = []
    @State private var custom: [SourceInfo] = []
    @State private var selected: SourceInfo?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let station = selected {
                    SiteBrowseView(station: station, allNames: builtin + custom.map { $0.name }) {
                        selected = nil
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let error = error { Text(error).foregroundColor(.red).padding(.horizontal) }
                            Text("内置站").font(.headline).padding(.horizontal)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                                ForEach(builtin, id: \.self) { name in
                                    Button(name) { selected = SourceInfo(name: name, type: "", url: "") }
                                        .buttonStyle(.bordered)
                                }
                            }
                            .padding(.horizontal)
                            if !custom.isEmpty {
                                Text("自定义站").font(.headline).padding(.horizontal)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                                    ForEach(custom) { s in
                                        Button(s.name) { selected = s }
                                            .buttonStyle(.bordered)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("采集站")
            .task { await load() }
            .navigationDestination(for: VodGroup.self) { g in DetailView(group: g) }
        }
    }

    private func load() async {
        do {
            let (b, c) = try await ApiClient.shared.getSources()
            builtin = b; custom = c
        } catch {
            self.error = "加载失败：\(error.localizedDescription)"
        }
    }
}

private struct SiteBrowseView: View {
    var station: SourceInfo
    var allNames: [String]
    var onBack: () -> Void
    @State private var cats: [SiteType] = []
    @State private var typeId = ""
    @State private var groups: [VodGroup] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("‹ 换站") { onBack() }
                Spacer()
                Text(station.name).font(.headline).lineLimit(1)
                Spacer()
                Button("刷新") { Task { await browse(reset: true) } }
            }
            .padding()
            if !cats.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("全部") { typeId = ""; Task { await browse(reset: true) } }
                            .buttonStyle(.borderedProminent).tint(typeId.isEmpty ? .blue : .gray)
                        ForEach(cats) { c in
                            Button(c.name) { typeId = "\(c.id)"; Task { await browse(reset: true) } }
                                .buttonStyle(.borderedProminent).tint(typeId == "\(c.id)" ? .blue : .gray)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            ScrollView {
                VodGrid(groups: groups).padding()
                if groups.isEmpty && !loading {
                    Text("该站暂无内容").foregroundColor(.secondary).padding()
                }
                if page < pageCount {
                    Button("加载更多") { Task { await browse(reset: false) } }.padding()
                }
                if loading { ProgressView().padding() }
                if let error = error { Text(error).foregroundColor(.red).padding() }
            }
        }
        .task {
            if station.type == "maccms", !station.url.isEmpty {
                cats = (try? await ApiClient.shared.getSiteTypes(apiUrl: station.url))?.filter { $0.pid == 0 } ?? []
                if cats.isEmpty { cats = (try? await ApiClient.shared.getSiteTypes(apiUrl: station.url)) ?? [] }
            }
            await browse(reset: true)
        }
    }

    private func browse(reset: Bool) async {
        if reset { page = 1; groups = [] }
        loading = true
        error = nil
        do {
            let disabled = allNames.filter { $0 != station.name }
            let (found, _, pc) = try await ApiClient.shared.search(wd: "", type: typeId, pg: page, disabled: disabled)
            groups.append(contentsOf: found)
            pageCount = pc
            page += 1
        } catch {
            self.error = "加载失败：\(error.localizedDescription)"
        }
        loading = false
    }
}

// MARK: - Emby（片库横排 + 详情复用，季分线）

struct EmbyView: View {
    @State private var views: [EmbyApi.View] = []
    @State private var selected: EmbyApi.View?
    @State private var groups: [VodGroup] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if !EmbyApi.configured {
                    VStack(spacing: 12) {
                        Text("Emby 还没填账号").font(.headline)
                        Text("去“设置”里填服务器、用户名和密码，只存本机。")
                            .foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                } else if let v = selected {
                    ScrollView {
                        VodGrid(groups: groups).padding()
                        if loading { ProgressView().padding() }
                        if let error = error { Text(error).foregroundColor(.red).padding() }
                    }
                    .navigationTitle(v.name)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("‹ 片库") { selected = nil; groups = [] }
                        }
                    }
                    .task { await loadItems(v) }
                } else {
                    List(views) { v in
                        Button(v.name) { selected = v }
                    }
                    .task { await loadViews() }
                    if loading { ProgressView() }
                    if let error = error { Text(error).foregroundColor(.red).padding() }
                }
            }
            .navigationTitle("Emby")
            .navigationDestination(for: VodGroup.self) { g in DetailView(group: g) }
        }
    }

    private func loadViews() async {
        loading = true
        error = nil
        do { views = try await EmbyApi.views() } catch {
            self.error = "Emby 加载失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func loadItems(_ v: EmbyApi.View) async {
        loading = true
        error = nil
        do { groups = try await EmbyApi.items(viewId: v.id) } catch {
            self.error = "Emby 加载失败：\(error.localizedDescription)"
        }
        loading = false
    }
}

// MARK: - 设置

struct SettingsView: View {
    @AppStorage("serverBase") private var serverBase = "http://test.lifei555.cloudns.be/点播"
    @State private var tmdbKey = ""
    @State private var embyServer = ""
    @State private var embyUser = ""
    @State private var embyPw = ""
    @State private var savedNote = ""
    @State private var pyTestResult = "还没跑过"

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器（不要带 /index.html）") {
                    TextField("服务器地址", text: $serverBase)
                        .autocapitalization(.none).disableAutocorrection(true)
                }
                Section("TMDB（自己的 Key，themoviedb.org 免费注册）") {
                    SecureField("TMDB v3 Key", text: $tmdbKey)
                    Button("保存 Key（同时清掉旧缓存）") {
                        Store.shared.tmdbKey = tmdbKey
                        savedNote = "TMDB Key 已保存"
                    }
                    Button("清除 TMDB 缓存") {
                        Store.shared.tmdbCacheClear()
                        savedNote = "TMDB 缓存已清除"
                    }
                }
                Section("Emby（只存本机，不写进代码）") {
                    TextField("服务器", text: $embyServer)
                        .autocapitalization(.none).disableAutocorrection(true)
                    TextField("用户名", text: $embyUser)
                        .autocapitalization(.none).disableAutocorrection(true)
                    SecureField("密码", text: $embyPw)
                    Button("保存 Emby 账号") {
                        EmbyApi.server = embyServer
                        EmbyApi.username = embyUser
                        EmbyApi.password = embyPw
                        EmbyApi.token = ""
                        EmbyApi.userId = ""
                        savedNote = "Emby 账号已保存"
                    }
                }
                Section("PY 自检（阶段 2：桥与纯 Python 依赖）") {
                    Text(pyTestResult).font(.caption).foregroundColor(.secondary)
                    Button("跑一次自检") { runPySelfTest() }
                }
                Section {
                    Text("端侧 PY 正在接入：解释器与蜘蛛桥已就绪，订阅浏览界面下一阶段来；Jar 不在 iOS 路线内。")
                        .font(.caption).foregroundColor(.secondary)
                    Text("GHT63 iOS 1.1.1（原生版）").font(.caption).foregroundColor(.secondary)
                    Text("内嵌 Python：\(PyRuntime.version)").font(.caption).foregroundColor(.secondary)
                    if !savedNote.isEmpty { Text(savedNote).font(.caption).foregroundColor(.green) }
                }
            }
            .navigationTitle("设置")
            .onAppear {
                tmdbKey = Store.shared.tmdbKey
                embyServer = EmbyApi.server
                embyUser = EmbyApi.username
                embyPw = EmbyApi.password
            }
        }
    }

    // MARK: - PY 自检（阶段 2 验收：订阅拉取 + 首个 PY 源的 homeContent）
    private func encodedURL(_ raw: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~:/?#[]@!$&'()*+,;=")
        guard let s = raw.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: s)
    }

    private func fetchText(_ raw: String) async throws -> String {
        guard let url = encodedURL(raw) else {
            throw PySpider.PyError.bridge("URL 编码失败：\(raw)")
        }
        let req = URLRequest(url: url, timeoutInterval: 30)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PySpider.PyError.bridge("HTTP 失败：\(raw)")
        }
        guard let s = String(data: data, encoding: .utf8) else {
            throw PySpider.PyError.bridge("响应不是 UTF-8 文本")
        }
        return s
    }

    private func runPySelfTest() {
        pyTestResult = "跑着呢…"
        // TV 端同款默认订阅
        let subURL = "http://test.lifei555.cloudns.be/影视/v1/ok海豚.json"
        Task.detached {
            do {
                let text = try await fetchText(subURL)
                guard let data = text.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sites = root["sites"] as? [[String: Any]] else {
                    throw PySpider.PyError.bridge("订阅不是预期的 sites 结构")
                }
                // TV 端同款筛选：type=3 且 api 以 .py 结尾（或含 .py?）
                let py = sites.filter { site in
                    guard (site["type"] as? Int) == 3,
                          let api = site["api"] as? String else { return false }
                    let lower = api.lowercased()
                    return lower.hasSuffix(".py") || lower.contains(".py?")
                }
                guard let first = py.first,
                      let api = first["api"] as? String, !api.isEmpty else {
                    throw PySpider.PyError.bridge("订阅里没找到 PY 源（共 \(sites.count) 个站）")
                }
                let name = (first["name"] as? String) ?? api
                let ext = (first["ext"] as? String) ?? ""
                let code = try await fetchText(api)
                let json = try PySpider.run(code: code, ext: ext, method: "home", argsJson: "[]")
                var cls = 0, lst = 0
                if let d = json.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    cls = (o["class"] as? [Any])?.count ?? 0
                    lst = (o["list"] as? [Any])?.count ?? 0
                }
                let out = "订阅 \(sites.count) 站，PY \(py.count) 个；首个 PY 源 \(name)：home 分类 \(cls) 个、推荐 \(lst) 条"
                await MainActor.run { pyTestResult = out }
            } catch {
                let msg = String("\(error)".prefix(300))
                await MainActor.run { pyTestResult = "自检失败：\(msg)" }
            }
        }
    }
}
