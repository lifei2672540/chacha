import SwiftUI

/// PY 订阅浏览（TV 版 PyActivity 的触屏版，纯 Python 子集）：
/// 订阅 → 源列表 → 分类/搜索/翻页 → 详情（复用 DetailView）→ 播放（PlayerView PY 分支）。
/// 能跑 = 只用 requests + base.spider + 纯 Python 标准库；要 Crypto/lxml、蜘蛛自身用
/// hashlib 等缺失扩展、或走 HTTPS（_ssl 在 AltStore 签名下加载不了）的源，显示原因、不闪退。

struct PyClass: Identifiable, Hashable {
    var id: String
    var name: String
}

struct PySource: Identifiable, Hashable {
    var id: String { api }
    var name: String
    var api: String
    var ext: String
    /// 去掉开头的表情/符号前缀（TV 同款）。
    var displayName: String {
        var s = name
        while let f = s.unicodeScalars.first, !CharacterSet.alphanumerics.contains(f) {
            s.removeFirst()
        }
        return s.isEmpty ? name : s
    }
}

enum PyAPI {
    static let defaultSubscription = "http://test.lifei555.cloudns.be/影视/v1/ok海豚.json"
    private static var scriptCache: [String: String] = [:]
    private static let cacheQueue = DispatchQueue(label: "com.ght63.ios.pyscriptcache")

    static func fetchText(_ urlString: String) async throws -> String {
        guard let enc = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: enc) else {
            throw PySpider.PyError.bridge("地址无效：\(urlString)")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let s = String(data: data, encoding: .utf8) else {
            throw PySpider.PyError.bridge("返回的不是 UTF-8 文本")
        }
        return s
    }

    /// 订阅解析（TV 同款口径：type==3 且 api 以 .py 结尾或含 .py?）。
    static func subscription() async throws -> [PySource] {
        let text = try await fetchText(defaultSubscription)
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sites = o["sites"] as? [[String: Any]] else {
            throw PySpider.PyError.bridge("订阅解析失败")
        }
        return sites.compactMap { s in
            guard let type = s["type"] as? Int, type == 3,
                  let api = s["api"] as? String else { return nil }
            let low = api.lowercased()
            guard low.hasSuffix(".py") || low.contains(".py?") else { return nil }
            return PySource(name: s["name"] as? String ?? api, api: api, ext: s["ext"] as? String ?? "")
        }
    }

    static func script(api: String) async throws -> String {
        if let c = cacheQueue.sync(execute: { scriptCache[api] }) { return c }
        let code = try await fetchText(api)
        cacheQueue.sync { scriptCache[api] = code }
        return code
    }

    /// 桥调用必须离主线程：PySpider.run 是同步调用，蜘蛛里有网络时会堵住调用线程。
    static func runOffMain(code: String, ext: String, method: String, argsJson: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try PySpider.run(code: code, ext: ext, method: method, argsJson: argsJson)
        }.value
    }

    static func call(source: PySource, method: String, argsJson: String) async throws -> [String: Any] {
        let code = try await script(api: source.api)
        let json = try await runOffMain(code: code, ext: source.ext, method: method, argsJson: argsJson)
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw PySpider.PyError.bridge("桥返回的不是 JSON")
        }
        if let err = o["__error__"] as? String { throw PySpider.PyError.bridge(err) }
        return o
    }

    private static func jsonArgs(_ values: [Any]) -> String {
        let d = try? JSONSerialization.data(withJSONObject: values)
        return d.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func groups(from list: [[String: Any]]) -> [VodGroup] {
        list.map { v in
            VodGroup(name: v["vod_name"] as? String ?? "",
                     pic: v["vod_pic"] as? String ?? "",
                     typeName: v["type_name"] as? String ?? "",
                     year: "\(v["vod_year"] ?? "")",
                     content: v["vod_content"] as? String ?? "",
                     sources: [],
                     vodId: "\(v["vod_id"] ?? "")")
        }
    }

    /// home：返回（分类，推荐列表）。分类为空时只有“全部”。
    static func home(source: PySource) async throws -> (classes: [PyClass], items: [VodGroup]) {
        let o = try await call(source: source, method: "home", argsJson: "[]")
        let classes = (o["class"] as? [[String: Any]] ?? []).compactMap { c -> PyClass? in
            guard let n = c["type_name"] as? String, !n.isEmpty else { return nil }
            return PyClass(id: "\(c["type_id"] ?? "")", name: n)
        }
        let items = groups(from: o["list"] as? [[String: Any]] ?? [])
        return (classes, items)
    }

    /// category：返回（本页列表，总页数）。
    static func category(source: PySource, tid: String, pg: Int) async throws -> (items: [VodGroup], pagecount: Int) {
        let o = try await call(source: source, method: "category", argsJson: jsonArgs([tid, pg]))
        let items = groups(from: o["list"] as? [[String: Any]] ?? [])
        let pc = o["pagecount"] as? Int ?? (Int("\(o["pagecount"] ?? 1)") ?? 1)
        return (items, max(pc, 1))
    }

    static func search(source: PySource, wd: String) async throws -> [VodGroup] {
        let o = try await call(source: source, method: "search", argsJson: jsonArgs([wd, 1]))
        return groups(from: o["list"] as? [[String: Any]] ?? [])
    }

    /// detail：vod_play_from 按 $$$ 切线路（即 pyFlag），vod_play_url 按 $$$/ # /首个 $ 切集。
    static func detail(source: PySource, vodId: String) async throws -> VodGroup {
        let o = try await call(source: source, method: "detail", argsJson: jsonArgs([vodId]))
        guard let v = (o["list"] as? [[String: Any]])?.first else {
            throw PySpider.PyError.bridge("详情为空")
        }
        let froms = (v["vod_play_from"] as? String ?? "").components(separatedBy: "$$$")
        let urlGroups = (v["vod_play_url"] as? String ?? "").components(separatedBy: "$$$")
        var lines: [PlayLine] = []
        for (idx, from) in froms.enumerated() {
            guard idx < urlGroups.count else { break }
            var eps: [Episode] = []
            for item in urlGroups[idx].components(separatedBy: "#") {
                guard let d = item.firstIndex(of: "$"), d != item.startIndex else { continue }
                eps.append(Episode(title: String(item[..<d]),
                                   url: String(item[item.index(after: d)...])))
            }
            lines.append(PlayLine(lineIndex: idx + 1, episodes: eps, label: from, pyFlag: from))
        }
        let src = VodSource(sourceLabel: source.displayName, remarks: v["vod_remarks"] as? String ?? "",
                            actor: v["vod_actor"] as? String ?? "", director: v["vod_director"] as? String ?? "",
                            lines: lines)
        return VodGroup(name: v["vod_name"] as? String ?? "", pic: v["vod_pic"] as? String ?? "",
                        typeName: "", year: "\(v["vod_year"] ?? "")",
                        content: v["vod_content"] as? String ?? "", sources: [src],
                        pyApi: source.api, pyExt: source.ext, vodId: vodId)
    }

    /// play：返回（parse，真实地址，防盗链头）。parse!=0 或地址空 = 这条线路播不了。
    static func play(source: PySource, flag: String, playId: String) async throws -> (parse: Int, url: String, headers: [String: String]) {
        let o = try await call(source: source, method: "play", argsJson: jsonArgs([flag, playId]))
        let parse = o["parse"] as? Int ?? (Int("\(o["parse"] ?? 0)") ?? 0)
        var headers: [String: String] = [:]
        if let h = o["header"] as? [String: Any] {
            for (k, v) in h { headers[k] = "\(v)" }
        } else if let hs = o["header"] as? String,
                  let d = hs.data(using: .utf8),
                  let h = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in h { headers[k] = "\(v)" }
        }
        return (parse, o["url"] as? String ?? "", headers)
    }
}

// MARK: - 源列表

struct PyHomeView: View {
    @State private var sources: [PySource] = []
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        Group {
            if loading && sources.isEmpty {
                ProgressView()
            } else if let error = error, sources.isEmpty {
                Text(error).foregroundColor(.red).padding()
            } else {
                List {
                    Section {
                        ForEach(sources) { s in
                            NavigationLink(destination: PyBrowseView(source: s)) {
                                Text(s.displayName).foregroundColor(.white)
                            }
                        }
                    } header: {
                        Text("PY 订阅（\(sources.count) 个源，纯 Python 子集）").foregroundColor(.gray)
                    } footer: {
                        Text("要 Crypto/lxml、或走 HTTPS 的源会显示原因（扩展模块在 AltStore 签名下加载不了），不闪退。")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .navigationTitle("PY订阅")
        .task { await load() }
    }
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            sources = try await PyAPI.subscription()
        } catch {
            self.error = "订阅加载失败：\(error)"
        }
    }
}

// MARK: - 源内浏览：分类 / 搜索 / 翻页

struct PyBrowseView: View {
    var source: PySource
    @State private var classes: [PyClass] = []
    @State private var selCat = ""
    @State private var items: [VodGroup] = []
    @State private var pg = 1
    @State private var pagecount = 1
    @State private var searchText = ""
    @State private var searching = false
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("本站搜索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                Button("搜索") { Task { await doSearch() } }
            }
            .padding()
            if !classes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("全部") { Task { await pickCat("") } }
                            .buttonStyle(.bordered)
                            .tint(selCat.isEmpty ? .red : .gray)
                        ForEach(classes, id: \.id) { c in
                            Button(c.name) { Task { await pickCat(c.id) } }
                                .buttonStyle(.bordered)
                                .tint(selCat == c.id ? .red : .gray)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            if loading && items.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if let error = error, items.isEmpty {
                Spacer()
                Text(error).foregroundColor(.red).padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
                        ForEach(items) { g in
                            NavigationLink(destination: PyDetailLoader(source: source, vodId: g.vodId)) {
                                PosterCard(group: g, width: 110)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    if !searching && pg < pagecount {
                        Button("加载更多") { Task { await loadMore() } }
                            .buttonStyle(.bordered)
                            .padding(.bottom)
                    }
                }
            }
            if let error = error, !items.isEmpty {
                Text(error).font(.caption).foregroundColor(.red).padding(.horizontal)
            }
        }
        .navigationTitle(source.displayName)
        .task { await loadHome() }
    }
    private func loadHome() async {
        loading = true
        defer { loading = false }
        do {
            let (cls, list) = try await PyAPI.home(source: source)
            classes = cls
            items = list
            pg = 1
            pagecount = 1
            error = nil
        } catch {
            self.error = "源加载失败：\(error)"
        }
    }
    private func pickCat(_ id: String) async {
        selCat = id
        searching = false
        searchText = ""
        pg = 1
        loading = true
        defer { loading = false }
        do {
            if id.isEmpty {
                let (_, list) = try await PyAPI.home(source: source)
                items = list
                pagecount = 1
            } else {
                let (list, pc) = try await PyAPI.category(source: source, tid: id, pg: 1)
                items = list
                pagecount = pc
            }
            error = nil
        } catch {
            self.error = "分类加载失败：\(error)"
        }
    }
    private func loadMore() async {
        guard !searching, pg < pagecount else { return }
        loading = true
        defer { loading = false }
        do {
            let (list, _) = try await PyAPI.category(source: source, tid: selCat, pg: pg + 1)
            items += list
            pg += 1
        } catch {
            self.error = "翻页失败：\(error)"
        }
    }
    private func doSearch() async {
        let wd = searchText.trimmingCharacters(in: .whitespaces)
        guard !wd.isEmpty else { return }
        searching = true
        loading = true
        defer { loading = false }
        do {
            items = try await PyAPI.search(source: source, wd: wd)
            pagecount = 1
            error = nil
        } catch {
            self.error = "搜索失败：\(error)"
        }
    }
}

// MARK: - 详情加载（取到完整 VodGroup 后复用 DetailView）

struct PyDetailLoader: View {
    var source: PySource
    var vodId: String
    @State private var group: VodGroup?
    @State private var error: String?
    var body: some View {
        Group {
            if let group = group {
                DetailView(group: group)
            } else if let error = error {
                Text(error).foregroundColor(.red).padding()
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                group = try await PyAPI.detail(source: source, vodId: vodId)
            } catch {
                self.error = "详情加载失败：\(error)"
            }
        }
    }
}
