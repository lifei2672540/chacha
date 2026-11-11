import SwiftUI

/// 海阔规则入口：规则列表 + 添加（粘贴规则 JSON 地址）+ 左滑删除。
struct HikerHomeView: View {
    @State private var rules: [HikerRule] = HikerStore.all()
    @State private var showAdd = false
    @State private var newURL = ""
    @State private var adding = false
    @State private var addError = ""

    var body: some View {
        NavigationStack {
            Group {
                if rules.isEmpty {
                    VStack(spacing: 12) {
                        Text("还没有规则，点右上角添加")
                            .foregroundColor(.secondary)
                        Text("粘贴一条海阔规则的地址（JSON），就能直接浏览和播放。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(rules) { rule in
                            NavigationLink(value: rule) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rule.name).lineLimit(1)
                                    Text(rule.ruleURL).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("海阔")
            .navigationDestination(for: HikerRule.self) { rule in
                HikerBrowseView(rule: rule)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") { newURL = ""; addError = ""; showAdd = true }
                }
            }
            .sheet(isPresented: $showAdd) {
                NavigationStack {
                    Form {
                        Section("规则地址") {
                            TextField("https://…/规则.json", text: $newURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        if !addError.isEmpty {
                            Text(addError).foregroundColor(.red).font(.caption)
                        }
                        Button(adding ? "添加中…" : "添加") {
                            Task { await addRule() }
                        }
                        .disabled(adding || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .navigationTitle("添加规则")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showAdd = false }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 76) }
        }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { HikerStore.remove(id: rules[i].id) }
        rules = HikerStore.all()
    }

    private func addRule() async {
        adding = true
        defer { adding = false }
        if await HikerStore.add(url: newURL) != nil {
            rules = HikerStore.all()
            showAdd = false
        } else {
            addError = "加不上：地址打不开或不是规则 JSON"
        }
    }
}

/// 海阔浏览页：分类 chips + 本站搜索 + 海报网格 + 滑到底自动加载更多。
struct HikerBrowseView: View {
    var rule: HikerRule
    @State private var items: [HikerItem] = []
    @State private var page = 1
    @State private var loading = false
    @State private var loaded = false
    @State private var error = ""
    @State private var selectedCls = ""
    @State private var searchText = ""
    @State private var searching = false
    @State private var searchKeyword = ""

    /// 分类：全部 + 规则 class_name/class_url 按 & 拆开一一对应。
    private var classes: [(name: String, url: String)] {
        let names = rule.classNames
        let urls = rule.classURLs
        var out: [(String, String)] = [("全部", "")]
        for (i, n) in names.enumerated() {
            out.append((n, i < urls.count ? urls[i] : ""))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            // 本站搜索
            HStack {
                TextField("本站搜索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("搜索") { doSearch() }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            // 分类 chips（搜索时不显示）
            if !searching {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(classes, id: \.name) { c in
                            Button(c.name) {
                                selectedCls = c.url
                                Task { await load(reset: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(selectedCls == c.url ? .red : .gray)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 8)
            }
            ScrollView {
                if !error.isEmpty && items.isEmpty {
                    Text(error).foregroundColor(.secondary).padding()
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(items.indices, id: \.self) { i in
                        let item = items[i]
                        if item.colType.hasPrefix("text_") || (!item.colType.isEmpty && item.colType != "movie_3") {
                            // 分区标题行：占满三列。
                            Text(item.title)
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                                .gridCellColumns(3)
                                .onAppear {
                                    if item.id == items.last?.id {
                                        Task { await loadMore() }
                                    }
                                }
                        } else {
                            // 海报卡（colType 为空或 movie_3）。
                            NavigationLink(value: item) {
                                posterCard(item)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if item.id == items.last?.id {
                                    Task { await loadMore() }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                if loading {
                    ProgressView().padding()
                } else if !items.isEmpty {
                    Button("加载更多") { Task { await loadMore() } }
                        .buttonStyle(.bordered)
                        .padding(.vertical, 8)
                }
                // 底部留空（1.4.7 教训：滚动页的留空必须写在滚动内容里）。
                Color.clear.frame(height: 76)
            }
        }
        .navigationTitle(rule.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: HikerItem.self) { item in
            HikerDetailView(rule: rule, item: item)
        }
        .task {
            guard !loaded else { return }
            loaded = true
            await load(reset: true)
        }
    }

    /// 海报卡：封面 + 标题 + 备注。
    private func posterCard(_ item: HikerItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: URL(string: item.img)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Color.gray.opacity(0.3)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(3 / 4, contentMode: .fit)
            .clipped()
            .cornerRadius(8)
            Text(item.title).font(.subheadline).lineLimit(2)
            if !item.desc.isEmpty {
                Text(item.desc).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
    }

    private func doSearch() {
        let kw = searchText.trimmingCharacters(in: .whitespaces)
        if kw.isEmpty {
            searching = false
            searchKeyword = ""
            Task { await load(reset: true) }
            return
        }
        searching = true
        searchKeyword = kw
        Task { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        if loading { return }
        loading = true
        error = ""
        if reset { page = 1; items = [] }
        let got: [HikerItem]
        if searching {
            got = await HikerEngine.shared.search(rule: rule, keyword: searchKeyword, page: page)
        } else if selectedCls.isEmpty {
            got = await HikerEngine.shared.home(rule: rule, page: page)
        } else {
            got = await HikerEngine.shared.category(rule: rule, cls: selectedCls, page: page)
        }
        if reset { items = got } else { appendUnique(got) }
        if got.isEmpty && items.isEmpty { error = "没有内容" }
        loading = false
    }

    private func loadMore() async {
        if loading { return }
        page += 1
        await load(reset: false)
    }

    private func appendUnique(_ more: [HikerItem]) {
        var seen = Set(items.map { $0.id })
        for it in more where !seen.contains(it.id) {
            seen.insert(it.id)
            items.append(it)
        }
    }
}

/// 海阔详情页：头项 + 简介 + 选集网格；点集先解析，成功进播放器，失败弹提示。
struct HikerDetailView: View {
    var rule: HikerRule
    var item: HikerItem
    @State private var detailItems: [HikerItem] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var error = ""
    @State private var resolving = false
    @State private var playGroup: VodGroup?
    @State private var playEpisode: Episode?
    @State private var showPlayer = false
    @State private var showParseError = false

    /// 头项：第一条带封面的无 colType 项（详情脚本的头项），没有就取第一条。
    private var header: HikerItem? {
        detailItems.first { !$0.img.isEmpty && $0.colType.isEmpty }
            ?? detailItems.first
    }
    /// 简介：全部 rich_text 项清干净拼起来。
    private var synopsis: String {
        detailItems.filter { $0.colType == "rich_text" }.map { cleanRichText($0.title) }.joined(separator: "\n")
    }
    /// 线路标题：第一条 text_1 项（规则里的“播放线路：在线播放”）。
    private var lineTitle: String? {
        detailItems.first { $0.colType == "text_1" }?.title
    }
    /// 选集分组：连续的 text_2~5 项按列数成组（数字就是列数）。
    private var episodeSections: [(cols: Int, items: [HikerItem])] {
        var out: [(cols: Int, items: [HikerItem])] = []
        for it in detailItems {
            guard let n = episodeColumns(of: it.colType) else { continue }
            if let last = out.last, last.cols == n {
                out[out.count - 1].items.append(it)
            } else {
                out.append((cols: n, items: [it]))
            }
        }
        return out
    }

    /// text_2~5 的数字就是列数，其余 colType 不是选集。
    private func episodeColumns(of colType: String) -> Int? {
        guard colType.hasPrefix("text_") else { return nil }
        let suffix = String(colType.dropFirst(5))
        if let n = Int(suffix), (2...5).contains(n) { return n }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loading && detailItems.isEmpty {
                    ProgressView().padding()
                }
                if !error.isEmpty && detailItems.isEmpty {
                    Text(error).foregroundColor(.secondary).padding()
                }
                if let h = header {
                    HStack(alignment: .top, spacing: 12) {
                        AsyncImage(url: URL(string: h.img)) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                Color.gray.opacity(0.3)
                            }
                        }
                        .frame(width: 120, height: 160)
                        .clipped()
                        .cornerRadius(8)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(h.title).font(.title3.bold()).lineLimit(3)
                            if !h.desc.isEmpty {
                                Text(h.desc).font(.subheadline).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                if !synopsis.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("剧情简介").font(.headline)
                        Text(synopsis).font(.subheadline).foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                }
                if let lineTitle = lineTitle {
                    Text(lineTitle).font(.headline).padding(.horizontal)
                }
                ForEach(episodeSections.indices, id: \.self) { si in
                    let sec = episodeSections[si]
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: sec.cols), spacing: 8) {
                        ForEach(sec.items) { ep in
                            Button(ep.title) {
                                play(ep)
                            }
                            .buttonStyle(.bordered)
                            .tint(.gray)
                            .disabled(resolving)
                        }
                    }
                    .padding(.horizontal)
                }
                // 底部留空（1.4.7 教训：滚动页的留空必须写在滚动内容里）。
                Color.clear.frame(height: 76)
            }
            .padding(.top, 12)
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            await loadDetail()
        }
        .alert("解析失败，换集试试", isPresented: $showParseError) {
            Button("好", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let g = playGroup, let ep = playEpisode {
                PlayerView(group: g, sourceIdx: 0, lineIdx: 0, startEpisode: ep,
                           sourceLabel: rule.name, lineLabel: "在线播放",
                           hikerResolver: { e in
                               await HikerEngine.shared.resolveEpisode(rule: rule, episode: e)
                           })
            }
        }
    }

    private func loadDetail() async {
        loading = true
        error = ""
        let got = await HikerEngine.shared.detail(rule: rule, itemURL: item.url)
        detailItems = got
        if got.isEmpty { error = "详情加载失败" }
        loading = false
    }

    /// 点一集：先解析探路，成功再进播放器（播放器里还会再解析一次）；
    /// 失败弹提示，不进播放器。需权益的集也走同一流程。
    private func play(_ ep: HikerItem) {
        guard !resolving else { return }
        resolving = true
        Task {
            let episode = Episode(title: ep.title, url: ep.url)
            let resolved = await HikerEngine.shared.resolveEpisode(rule: rule, episode: episode)
            resolving = false
            if resolved != nil {
                playEpisode = episode
                playGroup = makeGroup()
                showPlayer = true
            } else {
                showParseError = true
            }
        }
    }

    /// 播放用的组：单源单线全集，集地址保持惰性标记，播放时由 hikerResolver 解析。
    private func makeGroup() -> VodGroup {
        let eps = episodeSections.flatMap { $0.items }.map { Episode(title: $0.title, url: $0.url) }
        let line = PlayLine(lineIndex: 1, episodes: eps, label: "在线播放")
        let src = VodSource(sourceLabel: rule.name, remarks: "", actor: "", director: "", lines: [line])
        return VodGroup(name: item.title, pic: header?.img ?? "", typeName: "", year: "",
                        content: synopsis, sources: [src])
    }

    /// rich_text 简介：&nbsp; → 空格，<br/> → 换行，其余标签去掉（换行留着）。
    private func cleanRichText(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let lines = s.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}
