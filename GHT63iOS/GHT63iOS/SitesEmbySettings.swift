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
        // 底栏藏掉（写在 TabView 上不生效，1.3.0 的教训）。
        .toolbar(.hidden, for: .tabBar)
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
    @State private var loaded = false
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
                VodGrid(groups: groups) {
                    if page < pageCount && !loading {
                        Task { await browse(reset: false) }
                    }
                }
                .padding()
                if groups.isEmpty && !loading {
                    Text("该站暂无内容").foregroundColor(.secondary).padding()
                }
                if !groups.isEmpty {
                    Button {
                        if page < pageCount && !loading {
                            Task { await browse(reset: false) }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if loading {
                                ProgressView().padding()
                            } else if page < pageCount {
                                Text("上滑加载更多").foregroundColor(.secondary).padding()
                            } else {
                                Text("没有更多了").foregroundColor(.secondary).padding()
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(loading || page >= pageCount)
                }
                if let error = error { Text(error).foregroundColor(.red).padding() }
            }
        }
        .task {
            guard !loaded else { return }
            if station.type == "maccms", !station.url.isEmpty {
                cats = (try? await ApiClient.shared.getSiteTypes(apiUrl: station.url))?.filter { $0.pid == 0 } ?? []
                if cats.isEmpty { cats = (try? await ApiClient.shared.getSiteTypes(apiUrl: station.url)) ?? [] }
            }
            await browse(reset: true)
            if error == nil { loaded = true }
        }
    }

    private func browse(reset: Bool) async {
        if reset { page = 1; groups = [] }
        loading = true
        error = nil
        let wantType = typeId
        do {
            let disabled = allNames.filter { $0 != station.name }
            let (found, _, pc) = try await ApiClient.shared.search(wd: "", type: typeId, pg: page, disabled: disabled)
            guard wantType == typeId else { loading = false; return }
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
        // 底栏藏掉（写在 TabView 上不生效，1.3.0 的教训）。
        .toolbar(.hidden, for: .tabBar)
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

/// 设置页分区头（米色底上的深灰小字）：颜色写死，不跟随深浅模式 ——
/// 1.3.1 的教训：tab 级 preferredColorScheme 只改了状态栏，系统默认分区头还是白字。
private func settingsHeader(_ title: String) -> some View {
    Text(title).font(.footnote).foregroundColor(Color(red: 0.45, green: 0.44, blue: 0.42))
}

struct SettingsView: View {
    @AppStorage("serverBase") private var serverBase = "http://test.lifei555.cloudns.be/点播"
    @AppStorage("tgBase") private var tgBase = "http://192.168.31.254:8899"
    @State private var embyServer = ""
    @State private var embyUser = ""
    @State private var embyPw = ""
    @State private var savedNote = ""
    @State private var pyTestResult = "还没跑过"
    @State private var logUploadResult = ""

    /// 浅色分组底（蚂蚁 2.0.6 设置页同款米色）。
    private let cream = Color(red: 0.96, green: 0.95, blue: 0.92)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink(destination: ViewingExperienceView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 20)).foregroundColor(.green)
                                .frame(width: 36, height: 36)
                                .background(Color.green.opacity(0.12)).cornerRadius(10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("观看体验").font(.headline)
                                Text("调整影视界面、TMDB 资料及播放行为")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .listRowBackground(Color.white)
                Section(header: settingsHeader("服务器（不要带 /index.html）")) {
                    TextField("服务器地址", text: $serverBase)
                        .autocapitalization(.none).disableAutocorrection(true)
                }
                .listRowBackground(Color.white)
                Section(header: settingsHeader("Telegram 采集端（软路由，首页 Telegram 入口用它）")) {
                    TextField("采集端地址", text: $tgBase)
                        .autocapitalization(.none).disableAutocorrection(true)
                    Text("默认软路由 192.168.31.254:8899，改了端口或 IP 后在这里改。")
                        .font(.caption).foregroundColor(.secondary)
                }
                .listRowBackground(Color.white)
                Section(header: settingsHeader("Emby（只存本机，不写进代码）")) {
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
                .listRowBackground(Color.white)
                Section(header: settingsHeader("PY 自检（阶段 2：桥与纯 Python 依赖）")) {
                    Text(pyTestResult).font(.caption).foregroundColor(.secondary)
                    Button("跑一次自检") { runPySelfTest() }
                }
                .listRowBackground(Color.white)
                Section(header: settingsHeader("报错日志（TV 版同款，存到你自己服务器 upde/）")) {
                    Text(logUploadResult.isEmpty ? "播放出问题、闪退、自检失败都记在这里，上传后我能直接看到。" : logUploadResult)
                        .font(.caption).foregroundColor(.secondary)
                    Button("上传报错日志") {
                        Task {
                            let r = await ErrorLog.upload()
                            await MainActor.run { logUploadResult = r }
                        }
                    }
                    Button("清空本地日志") {
                        ErrorLog.clear()
                        logUploadResult = "本地日志已清空"
                    }
                }
                .listRowBackground(Color.white)
                Section {
                    Text("端侧 PY 正在接入：解释器与蜘蛛桥已就绪，订阅浏览界面下一阶段来；Jar 不在 iOS 路线内。")
                        .font(.caption).foregroundColor(.secondary)
                    Text("茶茶点播 iOS 1.4.0（原生版）").font(.caption).foregroundColor(.secondary)
                    Text("内嵌 Python：\(PyRuntime.version)").font(.caption).foregroundColor(.secondary)
                    if !savedNote.isEmpty { Text(savedNote).font(.caption).foregroundColor(.green) }
                }
                .listRowBackground(Color.white)
            }
            .scrollContentBackground(.hidden)
            .background(cream)
            .toolbarBackground(cream, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .navigationTitle("设置")
            .onAppear {
                embyServer = EmbyApi.server
                embyUser = EmbyApi.username
                embyPw = EmbyApi.password
            }
        }
        // 底栏藏掉（写在 TabView 上不生效，1.3.0 的教训）。
        // 浅色必须在这里强制：tab 级的 preferredColorScheme 只改了状态栏，
        // Form/导航栏还按深色渲染（1.3.1 的教训）—— 环境浅色 + 每行的白底才真生效。
        .toolbar(.hidden, for: .tabBar)
        .environment(\.colorScheme, .light)
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
                guard !py.isEmpty else {
                    throw PySpider.PyError.bridge("订阅里没找到 PY 源（共 \(sites.count) 个站）")
                }
                // 先探扩展模块：AltStore 不签 .so（1.2.1 框架重定位也失败），
                // 1.2.2 改由 CI 给 .so 做临时签名；探针须报全文，含 math/re/_struct
                // （math 已证实因签名加载不了，re 可用，_struct 是 gzip 的牵连项）
                var probeStatus = "未探"
                do {
                    let probeCode = """
import sys
class Spider:
    def init(self, ext=""):
        pass
    def homeContent(self, *a):
        out = {}
        for m in ["_hashlib", "_sha2", "_sha256", "_ssl", "ssl", "math", "re", "_struct"]:
            try:
                __import__(m)
                out[m] = "ok"
            except Exception as e:
                out[m] = "FAIL " + str(e)
        return {"class": [], "list": [{"vod_name": str(out), "vod_pic": "", "vod_year": "", "vod_area": "", "vod_remarks": ""}]}
"""
                    let probeJson = try PySpider.run(code: probeCode, ext: "", method: "home", argsJson: "[]")
                    if let d = probeJson.data(using: .utf8),
                       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let lst = o["list"] as? [[String: Any]],
                       let v = lst.first?["vod_name"] as? String {
                        probeStatus = v
                    }
                } catch {
                    probeStatus = "探针失败：\(error)"
                }
                // 阶段 2 还没有 Crypto/lxml 真轮子：跳过要它们的源，找第一个能跑的；
                // 一个源拉取或跑 home 失败就换下一个，不直接判死刑
                var skipped = 0
                var lastErr = ""
                for site in py.prefix(10) {
                    guard let api = site["api"] as? String, !api.isEmpty else { continue }
                    let name = (site["name"] as? String) ?? api
                    let ext = (site["ext"] as? String) ?? ""
                    do {
                        let code = try await fetchText(api)
                        if code.contains("Crypto") || code.contains("lxml") {
                            skipped += 1
                            continue
                        }
                        let json = try PySpider.run(code: code, ext: ext, method: "home", argsJson: "[]")
                        var cls = 0, lst = 0
                        if let d = json.data(using: .utf8),
                           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            cls = (o["class"] as? [Any])?.count ?? 0
                            lst = (o["list"] as? [Any])?.count ?? 0
                        }
                        let out = "扩展：\(probeStatus)；订阅 \(sites.count) 站，PY \(py.count) 个；跳过 \(skipped) 个要 Crypto/lxml 的源，首个能跑的 \(name)：home 分类 \(cls) 个、推荐 \(lst) 条"
                        await MainActor.run { pyTestResult = out }
                        return
                    } catch {
                        lastErr = "\(error)"
                        continue
                    }
                }
                throw PySpider.PyError.bridge("扩展：\(probeStatus)；试了 \(min(10, py.count)) 个源：\(skipped) 个要 Crypto/lxml（等阶段 3），其余跑 home 失败：\(lastErr)")
            } catch {
                let msg = "\(error)"
                ErrorLog.append("PY 自检失败：\(msg)")
                await MainActor.run { pyTestResult = "自检失败：\(msg)" }
            }
        }
    }
}

/// 观看体验（蚂蚁 2.0.6 设置页同款分组）：新版影视界面开关、TMDB 资料配置、视频设置。
/// 弹幕、广告过滤、深度嗅探、M3U8 边下边播这几行蚂蚁有、我们没有：没弹幕通道、
/// 没嗅探线路（线路都来自 PY/CMS 接口）、TG 早已是边下边播 —— 不放假开关。
struct ViewingExperienceView: View {
    @AppStorage("newHomeUI") private var newHomeUI = true
    @AppStorage("detailPosterBackdrop") private var detailPosterBackdrop = true
    private let cream = Color(red: 0.96, green: 0.95, blue: 0.92)

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20)).foregroundColor(.green)
                        .frame(width: 36, height: 36)
                        .background(Color.green.opacity(0.12)).cornerRadius(10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("观看体验").font(.headline)
                        Text("调整影视界面、TMDB 资料及播放行为")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .listRowBackground(Color.white)
            Section {
                Toggle(isOn: $newHomeUI) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("新版影视界面")
                        Text("沉浸式首页与详情、海报背景和玻璃控件；关闭恢复旧版")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                NavigationLink(destination: TmdbConfigView()) {
                    HStack(spacing: 12) {
                        Image(systemName: "film")
                            .font(.system(size: 20)).foregroundColor(.green)
                            .frame(width: 36, height: 36)
                            .background(Color.green.opacity(0.12)).cornerRadius(10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TMDB 资料配置")
                            Text("设置影片资料的来源和匹配规则")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listRowBackground(Color.white)
            Section(header: settingsHeader("视频设置")) {
                Toggle(isOn: $detailPosterBackdrop) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("详情页海报背景")
                        Text("用影视海报作为详情页背景，关闭后使用默认主题背景")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .listRowBackground(Color.white)
        }
        .scrollContentBackground(.hidden)
        .background(cream)
        .toolbarBackground(cream, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .environment(\.colorScheme, .light)
        .navigationTitle("观看体验")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// TMDB 资料配置（蚂蚁 2.0.6 同款页）：开关、卡片匹配、地址、Key、语言、保存、测试连接。
/// Key 是你自己的（themoviedb.org 免费注册），只存本机；不配 Key 时全用接口自带资料。
struct TmdbConfigView: View {
    @AppStorage("tmdbEnabled") private var tmdbEnabled = true
    @AppStorage("tmdbMatchCards") private var tmdbMatchCards = false
    @State private var apiBase = ""
    @State private var imageBase = ""
    @State private var apiKey = ""
    @State private var language = ""
    @State private var showKey = false
    @State private var note = ""
    @State private var testing = false
    private let cream = Color(red: 0.96, green: 0.95, blue: 0.92)

    var body: some View {
        Form {
            Section {
                Text("海报、背景、剧情与剧集预览\n优先展示 TMDB 匹配资料；未匹配或连接失败时使用接口信息。播放线路仍由影视接口提供。")
                    .font(.caption).foregroundColor(.secondary)
            }
            .listRowBackground(Color.white)
            Section {
                Toggle("启用 TMDB 资料", isOn: $tmdbEnabled)
                Toggle(isOn: $tmdbMatchCards) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("首页与搜索卡片匹配 TMDB")
                        Text("默认关闭，使用影视源海报和资料；开启后匹配首页卡片图片，以及搜索结果的海报、评分等资料。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .listRowBackground(Color.white)
            Section(header: settingsHeader("连接配置")) {
                HStack {
                    Text("API 地址")
                    TextField("http://api.tmdb.org", text: $apiBase)
                        .autocapitalization(.none).disableAutocorrection(true)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("图片地址")
                    TextField("http://images.tmdb.org/t/p", text: $imageBase)
                        .autocapitalization(.none).disableAutocorrection(true)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("API Key")
                    Spacer()
                    if showKey {
                        TextField("填你的 Key", text: $apiKey)
                            .autocapitalization(.none).disableAutocorrection(true)
                            .multilineTextAlignment(.trailing)
                    } else {
                        SecureField("填你的 Key", text: $apiKey)
                            .multilineTextAlignment(.trailing)
                    }
                    Button { showKey.toggle() } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Text("资料语言")
                    TextField("zh-CN", text: $language)
                        .autocapitalization(.none).disableAutocorrection(true)
                        .multilineTextAlignment(.trailing)
                }
            }
            .listRowBackground(Color.white)
            Section {
                Button("保存配置") {
                    Store.shared.tmdbApiBase = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
                    Store.shared.tmdbImageBase = imageBase.trimmingCharacters(in: .whitespacesAndNewlines)
                    Store.shared.tmdbLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
                    Store.shared.tmdbKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    note = "TMDB 配置已保存（换 Key 时旧缓存已清）"
                }
                Button("测试连接") {
                    testing = true
                    Task {
                        let r = await TmdbApi.testConnection()
                        await MainActor.run { note = r; testing = false }
                    }
                }
                .disabled(testing)
                Button("清除 TMDB 缓存") {
                    Store.shared.tmdbCacheClear()
                    note = "TMDB 缓存已清除"
                }
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundColor(.green)
                }
            }
            .listRowBackground(Color.white)
            Section {
                Text("影视资料来自 TMDB。本应用使用 TMDB API，但未获得 TMDB 的认可或认证。")
                    .font(.caption).foregroundColor(.secondary)
            }
            .listRowBackground(Color.white)
        }
        .scrollContentBackground(.hidden)
        .background(cream)
        .toolbarBackground(cream, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .environment(\.colorScheme, .light)
        .navigationTitle("TMDB 资料配置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiBase = Store.shared.tmdbApiBase
            imageBase = Store.shared.tmdbImageBase
            apiKey = Store.shared.tmdbKey
            language = Store.shared.tmdbLanguage
        }
    }
}
