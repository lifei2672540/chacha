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

/// 我的追剧行：标题可点进清单页，标题旁挂红色“N 部更新”角标（有更新才显示）；
/// 横排海报本身不动（放不下分组，清单页里分）。
struct FavSectionRow: View {
    @EnvironmentObject var store: Store
    var groups: [VodGroup]
    var body: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                NavigationLink(destination: FollowListView()) {
                    HStack(spacing: 6) {
                        Text("我的追剧").font(.title3.bold()).foregroundColor(.white)
                        if store.favUpdateCount > 0 {
                            Text("\(store.favUpdateCount) 部更新")
                                .font(.caption2.bold()).foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.red).cornerRadius(8)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundColor(.gray)
                    }
                    .padding(.horizontal)
                }
                .buttonStyle(.plain)
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
    var onLastAppear: (() -> Void)? = nil
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
            ForEach(groups) { g in
                NavigationLink(value: g) { PosterCard(group: g, width: 110) }
                    .buttonStyle(.plain)
                    .onAppear {
                        if g.id == groups.last?.id { onLastAppear?() }
                    }
            }
        }
    }
}

/// 网页版分类表（点播 index.html categoryList 同款）：大类 + 子类；
/// 子类 id 直接当 type 传给搜索接口，keyword 类子类（刑警/缉毒…）走关键词搜索。
struct WebSubCategory: Hashable {
    let name: String
    let typeId: String
    let keyword: String?
}
struct WebCategory: Hashable {
    let name: String
    let typeId: String
    let subs: [WebSubCategory]
}
enum WebCategories {
    static let all: [WebCategory] = [
        WebCategory(name: "今日热播", typeId: "", subs: []),
        WebCategory(name: "电影大片", typeId: "1", subs: [
            WebSubCategory(name: "全部电影", typeId: "1", keyword: nil),
            WebSubCategory(name: "恐怖惊悚", typeId: "10", keyword: nil),
            WebSubCategory(name: "喜剧搞笑", typeId: "7", keyword: nil),
            WebSubCategory(name: "科幻魔幻", typeId: "9", keyword: nil),
            WebSubCategory(name: "动作大片", typeId: "6", keyword: nil),
            WebSubCategory(name: "爱情浪漫", typeId: "8", keyword: nil),
            WebSubCategory(name: "战争史诗", typeId: "12", keyword: nil),
            WebSubCategory(name: "悬疑剧情", typeId: "11", keyword: nil),
            WebSubCategory(name: "动画电影", typeId: "23", keyword: nil),
        ]),
        WebCategory(name: "连续剧集", typeId: "2", subs: [
            WebSubCategory(name: "全部剧集", typeId: "2", keyword: nil),
            WebSubCategory(name: "刑侦破案", typeId: "", keyword: "刑警"),
            WebSubCategory(name: "悬疑探案", typeId: "", keyword: "提刑官"),
            WebSubCategory(name: "警匪缉毒", typeId: "", keyword: "缉毒"),
            WebSubCategory(name: "谍战风云", typeId: "", keyword: "谍战"),
            WebSubCategory(name: "国产剧", typeId: "13", keyword: nil),
            WebSubCategory(name: "港台剧", typeId: "14", keyword: nil),
            WebSubCategory(name: "日韩剧", typeId: "15", keyword: nil),
            WebSubCategory(name: "欧美剧", typeId: "16", keyword: nil),
        ]),
        WebCategory(name: "热门综艺", typeId: "3", subs: []),
        WebCategory(name: "动漫番剧", typeId: "4", subs: [
            WebSubCategory(name: "全部动漫", typeId: "4", keyword: nil),
            WebSubCategory(name: "国产动漫", typeId: "20", keyword: nil),
            WebSubCategory(name: "日韩动漫", typeId: "21", keyword: nil),
            WebSubCategory(name: "欧美动漫", typeId: "22", keyword: nil),
        ]),
    ]
    static func parent(forType typeId: String) -> WebCategory? { all.first { $0.typeId == typeId } }
}

// MARK: - 首页数据（新版沉浸式与旧版共用：分类搜索 + 云端合并）

@MainActor
final class HomeData: ObservableObject {
    @Published var cats: [String: [VodGroup]] = [:]
    @Published var trending: [TmdbTrendItem] = []
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
            async let trend = TmdbApi.trending()
            let (cp, cf) = try await (cloudProgress, cloudFavs)
            await MainActor.run { Store.shared.mergeCloudFavorites(cf) }
            _ = cp
            trending = await trend
            // 首页资源站点：只用这一个站出首页各分类（空 = 全部站聚合）。
            let disabled = try await ApiClient.shared.homeDisabled()
            for def in catDefs {
                let (groups, _, _) = try await ApiClient.shared.search(wd: def.1, type: def.2, pg: 1, disabled: disabled)
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
            .navigationDestination(for: TmdbTrendItem.self) { t in TrendDetailLoader(item: t) }
            .navigationDestination(for: RecentItem.self) { r in
                // 最近观看点开：按剧名搜回详情（与 TV 版续播同款思路）
                RecentDetailLoader(recent: r)
            }
        }
        // 底栏藏掉（写在 TabView 上不生效，1.3.0 的教训）；栈里推出的详情页也一样藏。
        .toolbar(.hidden, for: .tabBar)
        // 给玻璃底栏留空：写在栈上才能进滚动视图的底边距（写 TabView 上传不进去，1.4.3）。
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 76) }
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
                    FavSectionRow(groups: favGroups)
                }
                ForEach(data.catDefs, id: \.0) { def in
                    SectionRow(title: def.0, groups: data.cats[def.0] ?? [])
                }
                if data.loading { ProgressView().frame(maxWidth: .infinity) }
                if let error = data.error {
                    Text(error).foregroundColor(.red).padding(.horizontal)
                }
                // 底栏留空：直接写在滚动内容里（栈上的 safeAreaInset 进不了 ScrollView 的底边距，1.4.5）。
                Color.clear.frame(height: 76)
            }
            .padding(.vertical)
        }
        .refreshable { await data.load() }
    }
}

/// 顶部浮钮：只留搜索和刷新两个小圆钮（不挡海报），标题去掉了；
/// 搜索也可以走底部“搜索”页，下拉也能刷新。
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
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18)).foregroundColor(.white)
                    .padding(10).background(Color.black.opacity(0.35)).clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
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

/// TMDB 趋势轮播：横图全幅铺底 + 底部渐变 + 大标题 + TMDB 评分徽章，点海报按片名去源里搜。
private struct TrendHeroCarousel: View {
    var items: [TmdbTrendItem]
    @Binding var selected: Int
    var body: some View {
        TabView(selection: $selected) {
            ForEach(items.indices, id: \.self) { i in
                let t = items[i]
                NavigationLink(value: t) {
                    ZStack(alignment: .bottomLeading) {
                        AsyncImage(url: URL(string: t.backdrop)) { phase in
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
                            Text(t.title).font(.largeTitle.bold()).foregroundColor(.white).lineLimit(1)
                            HStack(spacing: 8) {
                                if t.score > 0 {
                                    Text(String(format: "TMDB %.1f", t.score))
                                        .font(.caption.bold()).foregroundColor(.white)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.teal).cornerRadius(10)
                                }
                                Text([(t.mediaType == "tv" ? "剧集" : "电影"), t.year].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.subheadline).foregroundColor(.white.opacity(0.7))
                            }
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
    @State private var chipParent = ""
    @State private var chipSub: WebSubCategory?
    @AppStorage("homeStation") private var homeStation = ""
    private var currentSubs: [WebSubCategory] { WebCategories.parent(forType: chipParent)?.subs ?? [] }
    @State private var gridGroups: [VodGroup] = []
    /// 当页筛选（只筛已加载的 gridGroups，不多请求）。
    @State private var fType = ""
    @State private var fYear = ""
    @State private var fSort = PageSort.normal
    @State private var fStatus = PageStatus.all
    private var filteredGridGroups: [VodGroup] { filterGroups(gridGroups, type: fType, year: fYear, sort: fSort, status: fStatus) }
    private var filterTypes: [String] { Array(Set(gridGroups.map { $0.typeName }.filter { !$0.isEmpty })).sorted() }
    private var filterYears: [String] { Array(Set(gridGroups.map { $0.year }.filter { !$0.isEmpty })).sorted(by: >) }
    private func clearFilter() { fType = ""; fYear = ""; fSort = .normal; fStatus = .all }
    @State private var gridPage = 1
    @State private var gridPageCount = 1
    @State private var gridLoading = false
    @State private var gridError: String?

    private var heroes: [VodGroup] { Array((data.cats["今日热播"] ?? []).prefix(5)) }
    private var trendHeroes: [TmdbTrendItem] { Array(data.trending.prefix(5)) }
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
                        if !trendHeroes.isEmpty {
                            TrendHeroCarousel(items: trendHeroes, selected: $heroIdx)
                            HStack(spacing: 6) {
                                ForEach(trendHeroes.indices, id: \.self) { i in
                                    Capsule()
                                        .fill(i == heroIdx ? Color.white : Color.white.opacity(0.35))
                                        .frame(width: i == heroIdx ? 22 : 7, height: 7)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        } else if !heroes.isEmpty {
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
                        if !homeStation.isEmpty {
                            HStack {
                                Text("首页只用「\(homeStation)」").font(.caption).foregroundColor(.secondary)
                                Button("取消") { homeStation = ""; Task { await data.load(); await searchGrid(reset: true) } }
                                    .font(.caption)
                            }
                            .padding(.horizontal)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(WebCategories.all, id: \.typeId) { c in
                                    Button(c.name) {
                                        chipParent = c.typeId
                                        chipSub = nil
                                        Task { await searchGrid(reset: true) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(chipParent == c.typeId ? .red : .gray)
                                }
                            }
                            .padding(.horizontal)
                        }
                        if !currentSubs.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(currentSubs, id: \.self) { s in
                                        Button(s.name) {
                                            chipSub = s
                                            Task { await searchGrid(reset: true) }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(chipSub == s ? .red : .gray)
                                    }
                                }
                                .padding(.horizontal)
                            }
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
                            FavSectionRow(groups: favGroups)
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
                        if !gridGroups.isEmpty {
                            PageFilterBar(type: $fType, year: $fYear, sort: $fSort, status: $fStatus, types: filterTypes, years: filterYears, total: gridGroups.count, shown: filteredGridGroups.count) { clearFilter() }
                        }
                        VodGrid(groups: filteredGridGroups).padding(.horizontal)
                        if gridPage < gridPageCount {
                            Button("加载更多") { Task { await searchGrid(reset: false) } }
                                .frame(maxWidth: .infinity).padding()
                        }
                        if gridLoading { ProgressView().frame(maxWidth: .infinity) }
                        if let e = gridError { Text(e).foregroundColor(.red).padding(.horizontal) }
                        if data.loading { ProgressView().frame(maxWidth: .infinity) }
                        if let e = data.error { Text(e).foregroundColor(.red).padding(.horizontal) }
                        // 底栏留空：直接写在滚动内容里（栈上的 safeAreaInset 进不了 ScrollView 的底边距，1.4.5）。
                        Color.clear.frame(height: 76)
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
        if reset { gridPage = 1; gridGroups = []; clearFilter() }
        gridLoading = true
        gridError = nil
        do {
            // 子类优先：keyword 类子类走关键词搜索，其余子类 id 直接当 type 传。
            let wd = chipSub?.keyword ?? ""
            let type = chipSub?.typeId ?? chipParent
            let (found, _, pc) = try await ApiClient.shared.search(wd: wd, type: type, pg: gridPage, disabled: try await ApiClient.shared.homeDisabled())
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
/// “继续观看”全部列表：左滑删单条；工具栏有清空（带确认）和补海报。
private struct RecentHistoryView: View {
    @EnvironmentObject var store: Store
    @State private var showClearConfirm = false

    var body: some View {
        List {
            ForEach(store.recents) { r in
                RecentCard(recent: r)
            }
            .onDelete { idx in
                let urls = idx.map { store.recents[$0].url }
                for u in urls { store.removeRecent(url: u) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("继续观看")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("🖼️ 补海报") { Task { await store.backfillRecentPics() } }
                    .disabled(store.recents.isEmpty)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空") { showClearConfirm = true }
                    .disabled(store.recents.isEmpty)
            }
        }
        .alert("清空最近观看？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) { store.clearRecents() }
        } message: {
            Text("全部最近观看记录都会删掉，不能恢复。")
        }
        .task { await store.backfillRecentPics() }
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
                    case .failure:
                        // 海报地址坏了（404 等）：只重试一次，清掉坏地址再回填（retryPoster 里防循环）。
                        Color.gray.opacity(0.3)
                            .onAppear { store.retryPoster(for: recent.drama) }
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

/// 趋势轮播点开：TMDB 只有资料没有播放地址，按片名去自家源里搜第一条进详情。
private struct TrendDetailLoader: View {
    var item: TmdbTrendItem
    @State private var group: VodGroup?
    @State private var error: String?
    var body: some View {
        Group {
            if let group = group {
                DetailView(group: group)
            } else if let error = error {
                Text(error).foregroundColor(.red)
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                let (groups, _, _) = try await ApiClient.shared.search(wd: item.title, type: "", pg: 1)
                group = groups.first { $0.name == item.title } ?? groups.first
                if group == nil { error = "源里没搜到这部" }
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
    @State private var sub: WebSubCategory?
    private var currentSubs: [WebSubCategory] { WebCategories.parent(forType: type)?.subs ?? [] }
    @State private var groups: [VodGroup] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var error: String?
    /// 当页筛选（只筛已加载的 groups，不多请求）。
    @State private var fType = ""
    @State private var fYear = ""
    @State private var fSort = PageSort.normal
    @State private var fStatus = PageStatus.all
    private var filteredGroups: [VodGroup] { filterGroups(groups, type: fType, year: fYear, sort: fSort, status: fStatus) }
    private var filterTypes: [String] { Array(Set(groups.map { $0.typeName }.filter { !$0.isEmpty })).sorted() }
    private var filterYears: [String] { Array(Set(groups.map { $0.year }.filter { !$0.isEmpty })).sorted(by: >) }
    private func clearFilter() { fType = ""; fYear = ""; fSort = .normal; fStatus = .all }
    /// 果鉴式最近搜索：本机存，最多 8 条，点词直接搜。
    @State private var recentKeywords: [String] = UserDefaults.standard.stringArray(forKey: "recentKeywords") ?? []
    /// 搜索联想：输入停 400ms 后搜一页，取前 6 个不重复剧名当联想词（照电视版）。
    @State private var suggestions: [String] = []
    @State private var suggestTask: Task<Void, Never>?
    private let types = [("全部", ""), ("电影", "1"), ("剧集", "2"), ("综艺", "3"), ("动漫", "4")]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("搜剧名", text: $keyword, onCommit: { sub = nil; Task { await search(reset: true) } })
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: keyword) { _ in scheduleSuggestions() }
                    Button("搜索") { sub = nil; Task { await search(reset: true) } }
                }
                .padding()
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.self) { s in
                            Button {
                                keyword = s
                                suggestions = []
                                sub = nil
                                Task { await search(reset: true) }
                            } label: {
                                HStack {
                                    Text(s).foregroundColor(.primary)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal)
                            }
                            .buttonStyle(.plain)
                            if s != suggestions.last {
                                Divider().padding(.leading)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .padding(.horizontal)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(types, id: \.1) { t in
                            Button(t.0) {
                                type = t.1
                                sub = nil
                                Task { await search(reset: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(type == t.1 ? .red : .gray)
                        }
                    }
                    .padding(.horizontal)
                }
                if !currentSubs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(currentSubs, id: \.self) { s in
                                Button(s.name) {
                                    sub = s
                                    Task { await search(reset: true) }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(sub == s ? .red : .gray)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                if !recentKeywords.isEmpty {
                    HStack {
                        Text("最近搜索").font(.caption).foregroundColor(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(recentKeywords, id: \.self) { k in
                                    Button(k) {
                                        keyword = k
                                        sub = nil
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
                if !groups.isEmpty {
                    PageFilterBar(type: $fType, year: $fYear, sort: $fSort, status: $fStatus, types: filterTypes, years: filterYears, total: groups.count, shown: filteredGroups.count) { clearFilter() }
                }
                ScrollView {
                    VodGrid(groups: filteredGroups).padding()
                    if page < pageCount {
                        Button("加载更多") { Task { await search(reset: false) } }
                            .padding()
                    }
                    if loading { ProgressView().padding() }
                    if let error = error { Text(error).foregroundColor(.red).padding() }
                    // 底栏留空：直接写在滚动内容里（栈上的 safeAreaInset 进不了 ScrollView 的底边距，1.4.5）。
                    Color.clear.frame(height: 76)
                }
            }
            .navigationTitle("搜索")
            .navigationDestination(for: VodGroup.self) { g in DetailView(group: g) }
        }
        // 底栏藏掉（写在 TabView 上不生效，1.3.0 的教训）。
        .toolbar(.hidden, for: .tabBar)
        // 给玻璃底栏留空：写在栈上才能进滚动视图的底边距（写 TabView 上传不进去，1.4.3）。
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 76) }
    }

    /// 输入联想：停 400ms 后搜一页，取前 6 个不重复剧名；失败静默留空。
    private func scheduleSuggestions() {
        suggestTask?.cancel()
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { suggestions = []; return }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            do {
                let (found, _, _) = try await ApiClient.shared.search(wd: kw, type: type, pg: 1)
                guard !Task.isCancelled else { return }
                // 只认当前还在输入的词：用户又改了词就丢弃这次结果。
                guard keyword.trimmingCharacters(in: .whitespaces) == kw else { return }
                var seen = Set<String>()
                var out: [String] = []
                for g in found {
                    let n = g.name.trimmingCharacters(in: .whitespaces)
                    if n.isEmpty || seen.contains(n) { continue }
                    seen.insert(n)
                    out.append(n)
                    if out.count >= 6 { break }
                }
                suggestions = out
            } catch {
                // 联想失败不打扰：静默留空。
            }
        }
    }

    private func search(reset: Bool) async {
        suggestions = []
        if reset {
            page = 1; groups = []; clearFilter()
            // 子类优先：keyword 类子类用它的关键词，其余子类 id 当 type 传。
            let k = (sub?.keyword ?? keyword).trimmingCharacters(in: .whitespaces)
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
            let wd = sub?.keyword ?? keyword
            let t = sub?.typeId ?? type
            let (found, _, pc) = try await ApiClient.shared.search(wd: wd, type: t, pg: page)
            groups.append(contentsOf: found)
            pageCount = pc
            page += 1
        } catch {
            self.error = "搜索失败：\(error.localizedDescription)"
        }
        loading = false
    }
}
