import SwiftUI

// MARK: - 通用卡片与横排

struct PosterCard: View {
    var group: VodGroup
    var width: CGFloat = 110
    /// 首个源的备注（如“更新至32集”“HD”）作角标，比光秃的海报像个视频 App。
    private var badge: String { group.sources.first?.remarks ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: URL(string: group.pic)) { phase in
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

// MARK: - 首页（TV 版 Leanback 首页的触屏版：最近 / 追剧 / 分类横排）

struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var cats: [String: [VodGroup]] = [:]
    @State private var loading = false
    @State private var error: String?

    private let catDefs = [
        ("今日热播", "", ""), ("电影大片", "", "1"), ("连续剧集", "", "2"),
        ("热门综艺", "", "3"), ("动漫番剧", "", "4"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 顶栏品牌行（不再用系统大标题）+ 横幅大图（TV 横幅首页同款）
                    HStack(alignment: .bottom, spacing: 8) {
                        Text("GHT63").font(.title.bold()).foregroundColor(.white)
                        Text("多源聚合点播").font(.caption).foregroundColor(.gray)
                        Spacer()
                        Button("刷新") { Task { await load() } }
                    }
                    .padding(.horizontal)
                    if let hero = cats["今日热播"]?.first {
                        NavigationLink(value: hero) {
                            HeroBanner(group: hero)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
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
                    ForEach(catDefs, id: \.0) { def in
                        SectionRow(title: def.0, groups: cats[def.0] ?? [])
                    }
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    if let error = error {
                        Text(error).foregroundColor(.red).padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .refreshable { await load() }
            .task { await load() }
            .navigationDestination(for: VodGroup.self) { g in DetailView(group: g) }
            .navigationDestination(for: RecentItem.self) { r in
                // 最近观看点开：按剧名搜回详情（与 TV 版续播同款思路）
                RecentDetailLoader(recent: r)
            }
        }
    }

    private var favGroups: [VodGroup] {
        store.favorites.map { f in
            VodGroup(name: f.name, pic: f.pic, typeName: "", year: "", content: "", sources: [])
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            async let cloudProgress = ApiClient.shared.getProgress()
            async let cloudFavs = ApiClient.shared.getFavorites()
            let (cp, cf) = try await (cloudProgress, cloudFavs)
            await MainActor.run { store.mergeCloudFavorites(cf) }
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
        if reset { page = 1; groups = [] }
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
