import SwiftUI

/// 首页顶部三档（截图顺序）：关注 = 本机关注的剧；漫剧 = 源内分类浏览；推荐 = 竖屏 Feed。
enum TopTab: String, CaseIterable {
    case follow = "关注"
    case category = "漫剧"
    case recommend = "推荐"
}

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var topTab: TopTab = .recommend
    @Published var source: PySource?
    @Published var dramas: [Drama] = []
    @Published var classes: [PyClass] = []
    @Published var dramaIdx = 0
    @Published var epIdx = 0
    @Published var lineIdx = 0
    @Published var detail: DramaDetail?
    @Published var loadingDrama = false
    @Published var dramaError: String?
    @Published var hint: String?
    /// 推荐两种状态：false = 浏览（上下滑换一部随机短剧），true = 合集（上下滑换本剧各集）。
    @Published var isBinge = false
    lazy var player = FeedPlayerModel()

    nonisolated init() {}

    private var detailCache: [String: DramaDetail] = [:]
    private var hintTask: Task<Void, Never>?
    private var gotoLast = false

    var currentDrama: Drama? {
        dramas.indices.contains(dramaIdx) ? dramas[dramaIdx] : nil
    }
    var currentEpisode: DramaEpisode? {
        guard let det = detail, det.lines.indices.contains(lineIdx) else { return nil }
        let eps = det.lines[lineIdx].episodes
        guard eps.indices.contains(epIdx) else { return nil }
        return eps[epIdx]
    }

    /// 首进：订阅里按顺序试最多 3 个源，第一个能出首页的留下。
    func initialLoad() async {
        do {
            let sources = try await PyAPI.subscription(url: Store.shared.subURL)
            var lastErr = ""
            for s in sources.prefix(3) {
                do {
                    try await loadHome(source: s)
                    // 首屏先播起来，后台再从另外 2 个源补剧进推荐池，不堵首屏。
                    Task { await self.expandPool(excluding: s) }
                    return
                } catch {
                    lastErr = "\(error)"
                }
            }
            dramaError = "前 3 个源都加载失败：\(lastErr)，请去剧场手动换源"
        } catch {
            dramaError = "订阅加载失败：\(error)"
        }
    }

    /// 加权打乱：源首页越靠前的剧（源自己排的热度顺序）越容易排在前面，
    /// 但顺序是随机的；PY 数据里没有播放量，绝不编造热度数字。
    static func weightedShuffle(_ list: [Drama]) -> [Drama] {
        list.enumerated().map { (idx, d) in
            (key: pow(Double.random(in: 0.0001...1), Double(idx + 1)), drama: d)
        }
        .sorted { $0.key > $1.key }
        .map { $0.drama }
    }

    /// 后台扩池：再拉 2 个源的首页，按剧名去重后打乱追加到推荐池尾部。
    /// 只在还在同一源的浏览模式时追加，避免用户已切源后混进旧源的剧。
    private func expandPool(excluding okSource: PySource) async {
        do {
            let sources = try await PyAPI.subscription(url: Store.shared.subURL)
            var extra: [Drama] = []
            for s in sources.filter({ $0.api != okSource.api }).prefix(2) {
                do {
                    let (_, list) = try await PyAPI.home(source: s)
                    extra += list
                } catch { continue }
                if extra.count >= 40 { break }
            }
            guard !extra.isEmpty, !isBinge, source?.api == okSource.api else { return }
            let seen = Set(dramas.map { $0.name })
            var fresh: [Drama] = []
            for d in extra where !d.name.isEmpty && !seen.contains(d.name)
                && !fresh.contains(where: { $0.name == d.name }) {
                fresh.append(d)
            }
            if !fresh.isEmpty { dramas += Self.weightedShuffle(fresh) }
        } catch { return }
    }

    func loadHome(source: PySource) async throws {
        let (cls, list) = try await PyAPI.home(source: source)
        self.source = source
        classes = cls
        // 推荐池按热度加权打乱：上下滑换的是随机短剧，不是按源顺序挨个播。
        dramas = Self.weightedShuffle(list)
        dramaIdx = 0
        epIdx = 0
        lineIdx = 0
        detail = nil
        isBinge = false
        await loadCurrent()
    }

    func loadCurrent() async {
        guard let d = currentDrama else { return }
        loadingDrama = true
        defer { loadingDrama = false }
        do {
            if let cached = detailCache[d.id] {
                detail = cached
            } else {
                let det = try await PyAPI.detail(source: d.source, drama: d)
                detailCache[d.id] = det
                detail = det
            }
            dramaError = nil
            guard let det = detail, !det.lines.isEmpty else {
                dramaError = "该剧暂无播放线路"
                return
            }
            lineIdx = max(0, min(lineIdx, det.lines.count - 1))
            let eps = det.lines[lineIdx].episodes
            guard !eps.isEmpty else {
                dramaError = "该线路暂无选集"
                return
            }
            if gotoLast {
                gotoLast = false
                epIdx = eps.count - 1
            } else {
                epIdx = max(0, min(epIdx, eps.count - 1))
            }
            playCurrent()
        } catch {
            detail = nil
            dramaError = "详情加载失败：\(error)"
            ErrorLog.append("详情失败 \(d.name)：\(error)")
        }
    }

    func playCurrent() {
        guard let d = currentDrama, let det = detail,
              det.lines.indices.contains(lineIdx),
              det.lines[lineIdx].episodes.indices.contains(epIdx) else { return }
        let ep = det.lines[lineIdx].episodes[epIdx]
        player.onEnded = { [weak self] in
            Task { @MainActor in self?.next() }
        }
        player.load(drama: d, lines: det.lines, lineIdx: lineIdx, episode: ep,
                    source: d.source, resumeFrom: Store.shared.progress(for: ep.id))
    }

    /// 点“合集”进入本剧：之后上下滑换本剧各集，不再换剧。
    func enterBinge() {
        guard let det = detail, !det.lines.isEmpty else {
            showHint("该剧暂无播放线路")
            return
        }
        isBinge = true
        showHint("已进入合集，上下滑切换本剧各集")
    }

    /// 回到推荐浏览：上下滑重新换随机短剧。
    func exitBinge() {
        isBinge = false
    }

    /// 浏览模式下一部随机短剧；池子滑到底就重新加权打乱换一批。
    private func browseNext() {
        if dramaIdx + 1 < dramas.count {
            dramaIdx += 1
            epIdx = 0
            lineIdx = 0
            detail = nil
            Task { await loadCurrent() }
        } else {
            reshufflePool()
        }
    }

    private func reshufflePool() {
        guard !dramas.isEmpty else { return }
        let current = currentDrama
        var shuffled = Self.weightedShuffle(dramas)
        if shuffled.first?.id == current?.id, shuffled.count > 1 {
            shuffled.append(shuffled.removeFirst())
        }
        dramas = shuffled
        dramaIdx = 0
        epIdx = 0
        lineIdx = 0
        detail = nil
        showHint("已为你换一批推荐")
        Task { await loadCurrent() }
    }

    func next() {
        if isBinge {
            // 合集内：先换本剧下一集；到最后一集再上滑，回到推荐换下一部随机短剧。
            guard let det = detail, !det.lines.isEmpty else {
                showHint("该剧暂无播放线路")
                return
            }
            if det.lines.indices.contains(lineIdx),
               det.lines[lineIdx].episodes.indices.contains(epIdx + 1) {
                epIdx += 1
                playCurrent()
                return
            }
            isBinge = false
            browseNext()
            return
        }
        browseNext()
    }

    func prev() {
        if isBinge {
            // 合集内：先换本剧上一集；已在第 1 集再下滑，回到推荐（还是这部剧的卡片）。
            if epIdx > 0 {
                epIdx -= 1
                playCurrent()
                return
            }
            isBinge = false
            showHint("已返回推荐")
            return
        }
        if dramaIdx > 0 {
            dramaIdx -= 1
            epIdx = 0
            lineIdx = 0
            detail = nil
            Task { await loadCurrent() }
            return
        }
        showHint("已经是第一个推荐")
    }

    func jumpTo(drama: Drama, source: PySource, inList: [Drama]?) {
        self.source = source
        if let list = inList, let idx = list.firstIndex(of: drama) {
            dramas = list
            dramaIdx = idx
            // 从列表里挑的剧：浏览模式，上下滑换下一部剧；点合集再进本剧。
            isBinge = false
        } else {
            dramas = [drama]
            dramaIdx = 0
            // 单部剧（关注里点的）：直接进合集，上下滑换本剧各集。
            isBinge = true
        }
        epIdx = 0
        lineIdx = 0
        detail = nil
        topTab = .recommend
        Task { await loadCurrent() }
    }

    func jumpToEpisode(_ idx: Int) {
        guard let det = detail, det.lines.indices.contains(lineIdx),
              det.lines[lineIdx].episodes.indices.contains(idx) else { return }
        // 从选集页挑集 = 进本剧，之后上下滑换本剧各集。
        isBinge = true
        epIdx = idx
        playCurrent()
    }

    func setLine(_ idx: Int) {
        guard let det = detail, det.lines.indices.contains(idx) else { return }
        lineIdx = idx
        if !det.lines[idx].episodes.indices.contains(epIdx) { epIdx = 0 }
        playCurrent()
    }

    func nextLine() {
        guard let det = detail else { return }
        if lineIdx + 1 < det.lines.count {
            setLine(lineIdx + 1)
        } else {
            showHint("没有更多线路")
        }
    }

    func showHint(_ s: String) {
        hint = s
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { hint = nil }
        }
    }
}

// MARK: - 首页

struct FeedView: View {
    @ObservedObject var vm: FeedViewModel
    @Binding var tabSelection: Int
    @State private var showEpisodeSheet = false
    @State private var showSearchSheet = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                switch vm.topTab {
                case .recommend:
                    feedPager
                case .follow:
                    FavoritesGrid(onPick: { f in
                        let s = PySource(name: f.sourceName, api: f.sourceApi, ext: f.sourceExt)
                        vm.jumpTo(drama: f.toDrama(), source: s, inList: nil)
                    })
                case .category:
                    CategoryBrowser(vm: vm, onPick: { d, list in
                        vm.jumpTo(drama: d, source: vm.source ?? d.source, inList: list)
                    })
                }
            }
        }
        .sheet(isPresented: $showEpisodeSheet) {
            if vm.detail != nil { EpisodeSheet(vm: vm) }
        }
        .sheet(isPresented: $showSearchSheet) {
            SearchSheet(vm: vm)
        }
        .task {
            if vm.dramas.isEmpty { await vm.initialLoad() }
        }
    }

    private var topBar: some View {
        HStack {
            if vm.isBinge {
                Button(action: { vm.exitBinge() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("推荐").lineLimit(1)
                    }
                }
                .foregroundColor(.white)
            } else {
                Button(action: { tabSelection = 1 }) {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal")
                        Text(vm.source?.displayName ?? "换源").lineLimit(1)
                    }
                }
                .foregroundColor(.white)
            }
            Spacer()
            HStack(spacing: 20) {
                ForEach(TopTab.allCases, id: \.self) { t in
                    Button(t.rawValue) { vm.topTab = t }
                        .foregroundColor(vm.topTab == t ? .white : .gray)
                        .bold(vm.topTab == t)
                        .overlay(alignment: .bottom) {
                            if vm.topTab == t {
                                Rectangle().fill(Color.orange).frame(height: 2).offset(y: 6)
                            }
                        }
                }
            }
            Spacer()
            Button(action: { showSearchSheet = true }) {
                Image(systemName: "magnifyingglass")
            }
            .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var feedPager: some View {
        ZStack {
            if let drama = vm.currentDrama, vm.detail != nil {
                FeedCell(vm: vm, player: vm.player, drama: drama, showEpisodeSheet: $showEpisodeSheet)
                if vm.loadingDrama {
                    ProgressView().tint(.white)
                }
            } else if vm.loadingDrama {
                ProgressView()
            } else if let err = vm.dramaError {
                VStack(spacing: 12) {
                    Text(err).foregroundColor(.red).multilineTextAlignment(.center).padding()
                    Button("去剧场换源") { tabSelection = 1 }.buttonStyle(.bordered)
                    Button("重试") { Task { await vm.loadCurrent() } }.buttonStyle(.bordered)
                }
                .padding()
            } else {
                VStack(spacing: 12) {
                    Text("暂无内容").foregroundColor(.gray)
                    Button("去剧场选一个源") { tabSelection = 1 }.buttonStyle(.bordered)
                }
            }
            if let hint = vm.hint {
                VStack {
                    Spacer()
                    Text(hint).font(.caption)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.black.opacity(0.7)).cornerRadius(8)
                        .padding(.bottom, 140)
                }
            }
        }
    }
}

// MARK: - 竖屏单条：视频 + 右侧栏 + 底部信息 + 进度条

struct FeedCell: View {
    @ObservedObject var vm: FeedViewModel
    @ObservedObject var player: FeedPlayerModel
    var drama: Drama
    @Binding var showEpisodeSheet: Bool
    @ObservedObject var store = Store.shared
    @State private var showPaused = false
    /// 正在拖进度条时的目标位置（0...1），松手后调用 player.seek。
    @State private var seekFraction: Double?

    var body: some View {
        GeometryReader { _ in
            ZStack {
                PlayerLayerView(player: player.player, gravity: player.gravity)
                    .ignoresSafeArea()
                    .onTapGesture {
                        player.togglePlay()
                        if !player.isPlaying {
                            showPaused = true
                            Task {
                                try? await Task.sleep(nanoseconds: 800_000_000)
                                showPaused = false
                            }
                        }
                    }
                if showPaused {
                    Image(systemName: "pause.fill").font(.system(size: 60))
                        .foregroundColor(.white.opacity(0.8))
                }
                // 右侧栏（不编点赞/评论数：PY 数据里没有，绝不造假数字）
                HStack {
                    Spacer()
                    VStack(spacing: 24) {
                        Button(action: { store.toggleFavorite(drama: drama) }) {
                            ZStack(alignment: .bottomTrailing) {
                                AsyncImage(url: URL(string: drama.pic)) { phase in
                                    if let img = phase.image {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Color(white: 0.2)
                                    }
                                }
                                .frame(width: 48, height: 48)
                                .clipShape(Circle())
                                Image(systemName: store.isFavorite(drama: drama) ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .foregroundColor(store.isFavorite(drama: drama) ? .orange : .white)
                                    .background(Color.black.clipShape(Circle()))
                            }
                        }
                        .buttonStyle(.plain)
                        Button(action: {
                            if let ep = vm.currentEpisode { store.toggleLike(epId: ep.id) }
                        }) {
                            let liked = vm.currentEpisode.map { store.isLiked(epId: $0.id) } ?? false
                            Image(systemName: liked ? "heart.fill" : "heart")
                                .font(.system(size: 30))
                                .foregroundColor(liked ? .red : .white)
                        }
                        .buttonStyle(.plain)
                        Button(action: { showEpisodeSheet = true }) {
                            Image(systemName: "ellipsis.bubble")
                                .font(.system(size: 30))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        if let ep = vm.currentEpisode {
                            ShareLink(item: "\(drama.name) 第\(ep.index + 1)集 \(ep.title)") {
                                Image(systemName: "arrowshape.turn.up.forward")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .padding(.trailing, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                // 底部信息
                VStack(alignment: .leading, spacing: 8) {
                    Text(drama.name).font(.headline).bold().lineLimit(2).foregroundColor(.white)
                    if let ep = vm.currentEpisode {
                        Text("第\(ep.index + 1)集 | \(ep.title)")
                            .font(.subheadline).foregroundColor(.white).lineLimit(1)
                    }
                    if let det = vm.detail, !det.remarks.isEmpty {
                        Text(det.remarks).font(.caption)
                            .foregroundColor(.white.opacity(0.8)).lineLimit(1)
                    }
                    Button(action: {
                        // 浏览时点合集 = 进入本剧（之后上下滑换本剧各集）；
                        // 已在合集里再点 = 打开选集页挑集。
                        if vm.isBinge { showEpisodeSheet = true } else { vm.enterBinge() }
                    }) {
                        HStack(spacing: 4) {
                            Text("合集 · 更新至\(vm.detail?.lines.first?.episodes.count ?? 0)集")
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .font(.subheadline).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.2)).cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                // 进度条（可拖动/点按快进快退）：拖动时显示目标时间，松手跳到该位置。
                VStack(spacing: 4) {
                    Spacer()
                    if let f = seekFraction, player.duration > 0 {
                        Text("\(formatTime(f * player.duration)) / \(formatTime(player.duration))")
                            .font(.caption).foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.black.opacity(0.7)).cornerRadius(6)
                    }
                    GeometryReader { barGeo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.3)).frame(height: 4)
                            Rectangle().fill(Color.orange)
                                .frame(width: barGeo.size.width * (seekFraction ?? player.progress), height: 4)
                        }
                        .frame(height: 28)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    seekFraction = min(max(v.location.x / barGeo.size.width, 0), 1)
                                }
                                .onEnded { v in
                                    let f = min(max(v.location.x / barGeo.size.width, 0), 1)
                                    player.seek(to: f)
                                    seekFraction = nil
                                }
                        )
                    }
                    .frame(height: 28)
                }
                // 加载 / 失败
                if player.loading {
                    ProgressView().tint(.white)
                } else if let err = player.error {
                    VStack(spacing: 10) {
                        Text(err).font(.caption).foregroundColor(.red)
                            .multilineTextAlignment(.center).padding(.horizontal)
                        HStack(spacing: 12) {
                            Button("换线路") { vm.nextLine() }.buttonStyle(.bordered)
                            Button("下一条") { vm.next() }.buttonStyle(.bordered)
                        }
                    }
                    .padding(.bottom, 120)
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { v in
                    if v.translation.height < -50 {
                        vm.next()
                    } else if v.translation.height > 50 {
                        vm.prev()
                    }
                }
        )
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s)
        return "\(i / 60):\(String(format: "%02d", i % 60))"
    }
}

// MARK: - 选集（合集）

struct EpisodeSheet: View {
    @ObservedObject var vm: FeedViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let det = vm.detail, !det.lines.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(det.lines.indices, id: \.self) { li in
                                let label = det.lines[li].label.isEmpty ? "线路\(li + 1)" : det.lines[li].label
                                Button(label) { vm.setLine(li) }
                                    .buttonStyle(.bordered)
                                    .tint(vm.lineIdx == li ? .orange : .gray)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 8)
                    if det.lines.indices.contains(vm.lineIdx) {
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                                ForEach(det.lines[vm.lineIdx].episodes) { ep in
                                    Button("\(ep.index + 1)") {
                                        vm.jumpToEpisode(ep.index)
                                        dismiss()
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(vm.epIdx == ep.index ? .orange : .gray)
                                }
                            }
                            .padding()
                        }
                    }
                    if let ep = vm.currentEpisode {
                        Text("正在播：第\(ep.index + 1)集 \(ep.title)")
                            .font(.caption).foregroundColor(.gray).padding(.bottom)
                    }
                } else {
                    Text("暂无选集").foregroundColor(.gray)
                }
            }
            .navigationTitle(vm.currentDrama?.name ?? "选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 本源搜索

struct SearchSheet: View {
    @ObservedObject var vm: FeedViewModel
    @Environment(\.dismiss) var dismiss
    @State private var wd = ""
    @State private var results: [Drama] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("搜本源剧名", text: $wd)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                    Button("搜索") { Task { await doSearch() } }
                }
                .padding()
                if searching {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if let error = error {
                    Spacer()
                    Text(error).foregroundColor(.red).padding()
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
                            ForEach(results) { d in
                                Button {
                                    if let s = vm.source {
                                        vm.jumpTo(drama: d, source: s, inList: results)
                                    }
                                    dismiss()
                                } label: {
                                    DramaCard(drama: d)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func doSearch() async {
        guard let s = vm.source else {
            error = "请先在剧场选一个源"
            return
        }
        let w = wd.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await PyAPI.search(source: s, wd: w)
            error = nil
        } catch {
            self.error = "搜索失败：\(error)"
        }
    }
}

// MARK: - 关注页 + 漫剧页 + 通用剧卡

struct FavoritesGrid: View {
    @ObservedObject var store = Store.shared
    var onPick: (FavoriteDrama) -> Void

    var body: some View {
        if store.favorites.isEmpty {
            VStack(spacing: 8) {
                Text("还没有关注的剧").foregroundColor(.gray)
                Text("在播放页点头像上的 + 或星星关注").font(.caption).foregroundColor(.gray)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
                    ForEach(store.favorites) { f in
                        Button { onPick(f) } label: {
                            DramaCard(drama: f.toDrama())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
    }
}

struct CategoryBrowser: View {
    @ObservedObject var vm: FeedViewModel
    var onPick: (Drama, [Drama]) -> Void
    @State private var selCat = ""
    @State private var items: [Drama] = []
    @State private var pg = 1
    @State private var pagecount = 1
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if vm.classes.isEmpty {
                Text("该源无分类，显示首页推荐").foregroundColor(.gray).font(.caption)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("全部") { Task { await pickCat("") } }
                            .buttonStyle(.bordered)
                            .tint(selCat.isEmpty ? .orange : .gray)
                        ForEach(vm.classes) { c in
                            Button(c.name) { Task { await pickCat(c.id) } }
                                .buttonStyle(.bordered)
                                .tint(selCat == c.id ? .orange : .gray)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)
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
                        ForEach(items) { d in
                            Button { onPick(d, items) } label: {
                                DramaCard(drama: d)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    if !selCat.isEmpty && pg < pagecount {
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
        .onAppear { if items.isEmpty { items = vm.dramas } }
        .onChange(of: vm.dramas) { new in
            if selCat.isEmpty { items = new }
        }
    }

    private func pickCat(_ id: String) async {
        selCat = id
        pg = 1
        loading = true
        defer { loading = false }
        do {
            if id.isEmpty {
                items = vm.dramas
                pagecount = 1
                error = nil
            } else {
                guard let s = vm.source else {
                    error = "请先在剧场选一个源"
                    return
                }
                let (list, pc) = try await PyAPI.category(source: s, tid: id, pg: 1)
                items = list
                pagecount = pc
                error = nil
            }
        } catch {
            self.error = "分类加载失败：\(error)"
        }
    }

    private func loadMore() async {
        guard let s = vm.source, !selCat.isEmpty, pg < pagecount else { return }
        loading = true
        defer { loading = false }
        do {
            let (list, _) = try await PyAPI.category(source: s, tid: selCat, pg: pg + 1)
            items += list
            pg += 1
        } catch {
            self.error = "翻页失败：\(error)"
        }
    }
}

struct DramaCard: View {
    var drama: Drama
    var width: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: drama.pic)) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.2)
                }
            }
            .frame(width: width, height: width * 1.4)
            .clipped()
            .cornerRadius(8)
            Text(drama.name).font(.caption).lineLimit(2).foregroundColor(.white)
            if !drama.remarks.isEmpty {
                Text(drama.remarks).font(.caption2).foregroundColor(.gray).lineLimit(1)
            }
        }
        .frame(width: width)
    }
}
