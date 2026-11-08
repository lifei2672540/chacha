import SwiftUI

// MARK: - 通用卡片与横排

struct PosterCard: View {
    var group: VodGroup
    var width: CGFloat = 110
    /// 首个源的备注（如“更新至32集”“HD”）作角标，比光秃的海报像个视频 App。
    private var badge: String { group.sources.first?.remarks ?? "" }
    /// 首页与搜索卡片匹配 TMDB（设置里开）：有 TMDB 海报就用它，没有回落到源海报。
    @State private var tmdbPoster: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: URL(string: tmdbPoster ?? group.pic)) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Color.gray.opacity(0.3)
                    }
                }
                .frame(width: width, height: width * 1.4)
                .clipped()
                .cornerRadius(12)
                if !badge.isEmpty {
                    Text(badge)
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(6)
                        .padding(6)
                        .lineLimit(1)
                }
            }
            Text(group.name).font(.subheadline).foregroundColor(.white).lineLimit(1)
            Text([group.typeName, group.year].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundColor(.gray).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .task {
            guard tmdbPoster == nil, await Store.shared.tmdbMatchCards else { return }
            if let hit = await TmdbApi.lookup(title: group.name, year: group.year), !hit.poster.isEmpty {
                tmdbPoster = hit.poster
            }
        }
    }
}

struct SectionRow: View {
    var title: String
    var groups: [VodGroup]
    var body: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.bold()).foregroundColor(.white).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(groups) { g in
                            NavigationLink(value: g) { PosterCard(group: g) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

/// 首页横幅：大图 + 底部渐变 + 标题 + 播放入口。
struct HeroBanner: View {
    var group: VodGroup
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: group.pic)) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: Color.gray.opacity(0.3)
                }
            }
            .frame(height: 200)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .frame(height: 200)
            VStack(alignment: .leading, spacing: 6) {
                Text(group.name).font(.title2.bold()).foregroundColor(.white).lineLimit(1)
                Text([group.typeName, group.year].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundColor(.white.opacity(0.8))
                Text("▶ 播放").font(.subheadline.bold()).foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.red).cornerRadius(20)
            }
            .padding()
        }
        .cornerRadius(16)
    }
}

struct VodGrid: View {
    var groups: [VodGroup]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
            ForEach(groups) { g in
                NavigationLink(value: g) { PosterCard(group: g, width: 110) }
                    .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 首页数据（新版沉浸式与旧版共用：分类搜索 + 云端合并）

@MainActor
final class HomeData: ObservableObject {
    @Published var cats: [String: [VodGroup]] = [:]
    @Published var loading = false
    @Published var error: String?

    let catDefs = [
        ("今日热播", "", ""), ("电影大片", "", "1"), ("连续剧集", "", "2"),
        ("热门综艺", "", "3"), ("动漫番剧", "", "4"),
    ]

    func load() async {
        loading = true
        error = nil
        do {
            async let cloudProgress = ApiClient.shared.getProgress()
            async let cloudFavs = ApiClient.shared.getFavorites()
            let (cp, cf) = try await (cloudProgress, cloudFavs)
            await MainActor.run { Store.shared.mergeCloudFavorites(cf) }
            _ = cp
            for def in catDefs {
                let (groups, _, _) = try await ApiClient.shared.search(wd: def.1, type: def.2, pg: 1)
                cats[def.0] = groups
            }
        } catch {
            self.error = "加载失败：\(error.localizedDescription)"
        }
        loading = false
    }
}

// MARK: - 首页（新版沉浸式 / 旧版切换，开关在设置 → 观看体验）

struct HomeView: View {
    @EnvironmentObject var store: Store
    @StateObject private var data = HomeData()
    @AppStorage("newHomeUI") private var newHomeUI = true

    var body: some View {
        NavigationStack {
            Group {
                if newHomeUI {
                    ImmersiveHomeView(data: data)
                } else {
                    ClassicHomeView(data: data)
                }
            }
            .navigationDestination(for: VodGroup.self) { g in DetailView(group: g) }
            .navigationDestination(for: RecentItem.self) { r in
                // 最近观看点开：按剧名搜回详情（与 TV 版续播同款思路）
                RecentDetailLoader(recent: r)
            }
        }
        .task { await data.load() }
    }
}

/// 旧版首页（TV 版 Leanback 首页的触屏版：最近 / 追剧 / 分类横排）。
struct ClassicHomeView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var data: HomeData

    private var favGroups: [VodGroup] {
        store.favorites.map { f in
            VodGroup(name: f.name, pic: f.pic, typeName: "", year: "", content: "", sources: [])
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 顶栏品牌行（不再用系统大标题）+ 横幅大图（TV 横幅首页同款）
                HStack(alignment: .bottom, spacing: 8) {
                    Text("茶茶点播").font(.title.bold()).foregroundColor(.white)
                    Text("多源聚合点播").font(.caption).foregroundColor(.gray)
                    Spacer()
                    Button("刷新") { Task { await data.load() } }
                }
                .padding(.horizontal)
                if let hero = data.cats["今日热播"]?.first {
                    NavigationLink(value: hero) {
                        HeroBanner(group: hero)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                }
                // PY 订阅入口（TV 版首页 PY 订阅卡同款；纯 Python 子集）
                NavigationLink(destination: PyHomeView()) {
                    HStack {
                        Text("🐍 PY订阅").font(.headline).foregroundColor(.white)
                        Spacer()
                        Text("纯 Python 子集，能跑的源").font(.caption).foregroundColor(.gray)
                        Image(systemName: "chevron.right").foregroundColor(.gray)
                    }
                    .padding()
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                // Telegram 入口（TV 版 1.1.32 同款：软路由采集端，频道 → 视频网格 → 直播）
                NavigationLink(destination: TgHomeView()) {
                    HStack {
                        Text("✈️ Telegram").font(.headline).foregroundColor(.white)
                        Spacer()
                        Text("软路由采集的短剧").font(.caption).foregroundColor(.gray)
                        Image(systemName: "chevron.right").foregroundColor(.gray)
                    }
                    .padding()
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                if !store.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("最近观看").font(.title3.bold()).foregroundColor(.white).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(store.recents) { r in
                                    RecentCard(recent: r)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                if !store.favorites.isEmpty {
                    SectionRow(title: "我的追剧", groups: favGroups)
                }
                ForEach(data.catDefs, id: \.0) { def in
                    SectionRow(title: def.0, groups: data.cats[def.0] ?? [])
                }
                if data.loading { ProgressView().frame(maxWidth: .infinity) }
                if let error = data.error {
                    Text(error).foregroundColor(.red).padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .refreshable { await data.load() }
    }
}

/// 顶部玻璃条：搜索 + 品牌 + 刷新，浮在海报上。
private struct TopGlassBar: View {
    var onSearch: () -> Void
    var onRefresh: () -> Void
    var body: some View {
        HStack {
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18)).foregroundColor(.white)
                    .padding(10).background(Color.black.opacity(0.35)).clipShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text("茶茶点播").font(.headline.bold()).foregroundColor(.white)
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18)).foregroundColor(.white)
                    .padding(10).background(Color.black.opacity(0.35)).clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }
}

/// 海报轮播：横图全幅铺底 + 底部渐变 + 大标题 + 备注，点海报进详情。
/// 横图优先用 TMDB（有 Key 才查），没有回落到源海报。
private struct HeroCarousel: View {
    var groups: [VodGroup]
    var backdrops: [String: String]
    @Binding var selected: Int
    var body: some View {
        TabView(selection: $selected) {
            ForEach(groups.indices, id: \.self) { i in
                let g = groups[i]
                NavigationLink(value: g) {
                    ZStack(alignment: .bottomLeading) {
                        AsyncImage(url: URL(string: backdrops[g.name] ?? g.pic)) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            default: Color.gray.opacity(0.3)
                            }
                        }
                        .frame(height: 520)
                        .clipped()
                        LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                            .frame(height: 520)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(g.name).font(.largeTitle.bold()).foregroundColor(.white).lineLimit(1)
                            if let r = g.sources.first?.remarks, !r.isEmpty {
                                Text(r).font(.subheadline).foregroundColor(.white.opacity(0.85))
                            }
                            Text([g.typeName, g.year].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline).foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                    }
                }
                .buttonStyle(.plain)
                .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 520)
    }
}

/// 新版沉浸式首页（蚂蚁 2.0.6 海报 UI 同款）：海报轮播 + 圆点 + 分类胶囊 +
/// 继续观看 + 我的追剧 + PY/TG 入口 + 分类网格；顶部玻璃条浮在海报上。
struct ImmersiveHomeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tabNav: TabNav
    @ObservedObject var data: HomeData
    @State private var heroIdx = 0
    @State private var backdrops: [String: String] = [:]
    @State private var chipType = ""
    @State private var gridGroups: [VodGroup] = []
    @State private var gridPage = 1
    @State private var gridPageCount = 1
    @State private var gridLoading = false
    @State private var gridError: String?

    private let chips = [("全部", ""), ("电视剧", "2"), ("电影", "1"), ("综艺", "3"), ("动漫", "4")]
    private var heroes: [VodGroup] { Array((data.cats["今日热播"] ?? []).prefix(5)) }
    private var favGroups: [VodGroup] {
        store.favorites.map { f in
            VodGroup(name: f.name, pic: f.pic, typeName: "", year: "", content: "", sources: [])
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !heroes.isEmpty {
                            HeroCarousel(groups: heroes, backdrops: backdrops, selected: $heroIdx)
                            HStack(spacing: 6) {
                                ForEach(heroes.indices, id: \.self) { i in
                                    Capsule()
                                        .fill(i == heroIdx ? Color.white : Color.white.opacity(0.35))
                                        .frame(width: i == heroIdx ? 22 : 7, height: 7)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(chips, id: \.1) { c in
                                    Button(c.0) {
                                        chipType = c.1
                                        Task { await searchGrid(reset: true) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(chipType == c.1 ? .red : .gray)
                                }
                            }
                            .padding(.horizontal)
                        }
                        if !store.recents.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("继续观看").font(.title3.bold()).foregroundColor(.white)
                                    Spacer()
                                    NavigationLink(destination: RecentHistoryView()) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundColor(.gray)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(store.recents) { r in
                                            RecentCard(recent: r)
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                            }
                        }
                        if !store.favorites.isEmpty {
                            SectionRow(title: "我的追剧", groups: favGroups)
                        }
                        NavigationLink(destination: PyHomeView()) {
                            HStack {
                                Text("🐍 PY订阅").font(.headline).foregroundColor(.white)
                                Spacer()
                                Text("纯 Python 子集，能跑的源").font(.caption).foregroundColor(.gray)
                                Image(systemName: "chevron.right").foregroundColor(.gray)
                            }
                            .padding()
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                        NavigationLink(destination: TgHomeView()) {
                            HStack {
                                Text("✈️ Telegram").font(.headline).foregroundColor(.white)
                                Spacer()
                                Text("软路由采集的短剧").font(.caption).foregroundColor(.gray)
                                Image(systemName: "chevron.right").foregroundColor(.gray)
                            }
                            .padding()
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                        VodGrid(groups: gridGroups).padding(.horizontal)
                        if gridPage < gridPageCount {
                            Button("加载更多") { Task { await searchGrid(reset: false) } }
                                .frame(maxWidth: .infinity).padding()
                        }
                        if gridLoading { ProgressView().frame(maxWidth: .infinity) }
                        if let e = gridError { Text(e).foregroundColor(.red).padding(.horizontal) }
                        if data.loading { ProgressView().frame(maxWidth: .infinity) }
                        if let e = data.error { Text(e).foregroundColor(.red).padding(.horizontal) }
                    }
                    .padding(.vertical)
                }
                .ignoresSafeArea(edges: .top)
                .refreshable {
                    await data.load()
                    await searchGrid(reset: true)
                }
                TopGlassBar(
                    onSearch: { tabNav.selected = 1 },
                    onRefresh: {
                        Task {
                            await data.load()
                            await searchGrid(reset: true)
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, geo.safeAreaInsets.top + 8)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await searchGrid(reset: true) }
        .onChange(of: data.cats) { _ in Task { await loadHeroBackdrops() } }
    }

    private func searchGrid(reset: Bool) async {
        if reset { gridPage = 1; gridGroups = [] }
        gridLoading = true
        gridError = nil
        do {
            let (found, _, pc) = try await ApiClient.shared.search(wd: "", type: chipType, pg: gridPage)
            gridGroups.append(contentsOf: found)
            gridPageCount = pc
            gridPage += 1
        } catch {
            gridError = "加载失败：\(error.localizedDescription)"
        }
        gridLoading = false
    }

    private func loadHeroBackdrops() async {
        for g in heroes {
            guard backdrops[g.name] == nil else { continue }
            if let hit = await TmdbApi.lookup(title: g.name, year: g.year), !hit.backdrop.isEmpty {
                backdrops[g.name] = hit.backdrop
            }
        }
    }
}

/// 继续观看全部记录（最近观看本地上限 24 条，点开按剧名搜回详情）。
private struct RecentHistoryView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(store.recents) { r in
                    RecentCard(recent: r)
                }
            }
            .padding()
        }
        .navigationTitle("继续观看")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RecentCard: View {
    var recent: RecentItem
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationLink(value: recent) {
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: URL(string: recent.pic)) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Color.gray.opacity(0.3)
                    }
                }
                .frame(width: 110, height: 154).clipped().cornerRadius(8)
                Text(recent.drama).font(.subheadline).lineLimit(1)
                Text("看至\(recent.epTitle)").font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除这条", role: .destructive) { store.removeRecent(url: recent.url) }
        }
    }
}

/// 最近观看没有完整详情时：按剧名搜第一条进详情（TV 版续播后选集按标题匹配）。
private struct RecentDetailLoader: View {
    var recent: RecentItem
    @State private var group: VodGroup?
    @State private var error: String?
    var body: some View {
        Group {
            if let group = group {
                DetailView(group: group, resumeEpisodeTitle: recent.epTitle)
            } else if let error = error {
                Text(error).foregroundColor(.red)
            } else {
                ProgressView()
            }
        }
        .task {
            // Telegram 最近：url 就是采集端流地址（以采集端地址开头），CMS 搜不到，
            // 直接拼单集组进详情页续播（TV 版按流地址记进度同款思路）
            if recent.url.hasPrefix(ApiClient.shared.tgBaseUrl) {
                let ep = Episode(title: recent.epTitle, url: recent.url)
                let line = PlayLine(lineIndex: 1, episodes: [ep], label: "")
                let src = VodSource(sourceLabel: "Telegram", remarks: "", actor: "", director: "", lines: [line])
                group = VodGroup(name: recent.drama, pic: recent.pic, typeName: "Telegram", year: "", content: "",
                                 sources: [src])
                return
            }
            // PY 最近：url 就是蜘蛛播放 id，CMS 搜不到，直接拼单线路组进播放器解析
            if !recent.pyApi.isEmpty {
                let ep = Episode(title: recent.epTitle, url: recent.url)
                let line = PlayLine(lineIndex: 1, episodes: [ep], label: "", pyFlag: recent.pyFlag)
                let src = VodSource(sourceLabel: "PY", remarks: "", actor: "", director: "", lines: [line])
                group = VodGroup(name: recent.drama, pic: recent.pic, typeName: "", year: "", content: "",
                                 sources: [src], pyApi: recent.pyApi, pyExt: recent.pyExt)
                return
            }
            do {
                let (groups, _, _) = try await ApiClient.shared.search(wd: recent.drama, type: "", pg: 1)
                group = groups.first { $0.name == recent.drama } ?? groups.first
                if group == nil { error = "没搜到这部剧" }
            } catch {
                self.error = "加载失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 搜索（分页 + 类型筛选）

struct SearchView: View {
    @State private var keyword = ""
    @State private var type = ""
    @State private var groups: [VodGroup] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var error: String?
    /// 果鉴式最近搜索：本机存，最多 8 条，点词直接搜。
    @State private var recentKeywords: [String] = UserDefaults.standard.stringArray(forKey: "recentKeywords") ?? []
    private let types = [("全部", ""), ("电影", "1"), ("剧集", "2"), ("综艺", "3"), ("动漫", "4")]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("搜剧名", text: $keyword, onCommit: { Task { await search(reset: true) } })
                        .textFieldStyle(.roundedBorder)
                    Button("搜索") { Task { await search(reset: true) } }
                }
                .padding()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(types, id: \.1) { t in
                            Button(t.0) {
                                type = t.1
                                Task { await search(reset: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(type == t.1 ? .red : .gray)
                        }
                    }
                    .padding(.horizontal)
                }
                if !recentKeywords.isEmpty {
                    HStack {
                        Text("最近搜索").font(.caption).foregroundColor(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(recentKeywords, id: \.self) { k in
                                    Button(k) {
                                        keyword = k
                                        Task { await search(reset: true) }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        Button("清空") { recentKeywords = []; UserDefaults.standard.set([], forKey: "recentKeywords") }
                            .font(.caption)
                    }
                    .padding(.horizontal)
                }
                ScrollView {
                    VodGrid(groups: groups).padding()
                    if page < pageCount {
                        Button("加载更多") { Task { await search(reset: false) } }
                            .padding()
                    }
                    if loading { ProgressView().padding() }
                    if let error = error { Text(error).foregroundColor(.red).padding() }
                }
            }
            .navigationTitle("搜索")
            .navigationDestination(for: VodGroup.self) { g in DetailView(group: g) }
        }
    }

    private func search(reset: Bool) async {
        if reset {
            page = 1; groups = []
            let k = keyword.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty {
                recentKeywords.removeAll { $0 == k }
                recentKeywords.insert(k, at: 0)
                recentKeywords = Array(recentKeywords.prefix(8))
                UserDefaults.standard.set(recentKeywords, forKey: "recentKeywords")
            }
        }
        loading = true
        error = nil
        do {
            let (found, _, pc) = try await ApiClient.shared.search(wd: keyword, type: type, pg: page)
            groups.append(contentsOf: found)
            pageCount = pc
            page += 1
        } catch {
            self.error = "搜索失败：\(error.localizedDescription)"
        }
        loading = false
    }
}
