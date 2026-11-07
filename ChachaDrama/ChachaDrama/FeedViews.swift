import SwiftUI
import UIKit

/// 首页顶部档位（截图顺序）：关注 = 本机关注的剧；漫剧 = 源内分类浏览；推荐 = 竖屏 Feed；继续 = 本机继续观看。
enum TopTab: String, CaseIterable {
    case follow = "关注"
    case category = "漫剧"
    case recommend = "推荐"
    case resume = "继续"
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
    /// 从“继续观看”点进来时要恢复的线路/集，loadCurrent 拉到详情后一次性用掉。
    private var pendingResumeLine: Int?
    private var pendingResumeEp: Int?

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
                    Store.shared.markSourceOK(s.api)
                    // 首屏先播起来，后台再从另外 2 个源补剧进推荐池，不堵首屏。
                    Task { await self.expandPool(excluding: s) }
                    return
                } catch {
                    Store.shared.markSourceFailed(s.api)
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
                    Store.shared.markSourceOK(s.api)
                    extra += list
                } catch {
                    Store.shared.markSourceFailed(s.api)
                    continue
                }
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
            if let pr = pendingResumeLine {
                pendingResumeLine = nil
                lineIdx = max(0, min(pr, det.lines.count - 1))
            }
            let eps = det.lines[lineIdx].episodes
            guard !eps.isEmpty else {
                dramaError = "该线路暂无选集"
                return
            }
            if gotoLast {
                gotoLast = false
                epIdx = eps.count - 1
            } else if let pr = pendingResumeEp {
                pendingResumeEp = nil
                epIdx = max(0, min(pr, eps.count - 1))
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

    /// 从“继续观看”点进来：直接进合集，恢复到当时那条线路、那一集，播到上次的进度。
    func jumpToResume(_ item: ResumeItem) {
        let d = item.toDrama()
        pendingResumeLine = item.lineIdx
        pendingResumeEp = item.epIdx
        jumpTo(drama: d, source: d.source, inList: nil)
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
                case .resume:
                    ResumeList(vm: vm)
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
    /// 双击快进/快退时闪一下的提示；长按 2 倍速进行中；长按松手后短暂屏蔽随之而来的单击（否则会误暂停）。
    @State private var seekFlash: String?
    @State private var fastForward = false
    @State private var suppressTap = false
    @State private var flashTask: Task<Void, Never>?
    /// 全屏播放开关：弹出全屏播放页（同一 AVPlayer 换一层铺满），退出时转回竖屏。
    @State private var isFullScreen = false

    /// 左右两半屏的手势区：单击暂停/续播，双击左右快进/快退 10 秒，长按 2 倍速。
    /// 单击和双击都挂在同一半屏上，系统自己区分；长按松手后屏蔽一次单击，防误暂停。
    @ViewBuilder
    private func tapHalf(isLeft: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                player.seekBy(seconds: isLeft ? -10 : 10)
                seekFlash = isLeft ? "快退 10 秒" : "快进 10 秒"
                flashTask?.cancel()
                flashTask = Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    seekFlash = nil
                }
            }
            .onTapGesture(count: 1) {
                if suppressTap { return }
                player.togglePlay()
                if !player.isPlaying {
                    showPaused = true
                    Task {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        showPaused = false
                    }
                }
            }
            .onLongPressGesture(minimumDuration: 0.35, pressing: { pressing in
                if pressing {
                    player.startFastForward()
                    fastForward = true
                } else {
                    player.stopFastForward()
                    fastForward = false
                    suppressTap = true
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        suppressTap = false
                    }
                }
            }, perform: {})
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                PlayerLayerView(player: player.player, gravity: player.gravity)
                    .ignoresSafeArea()
                HStack(spacing: 0) {
                    tapHalf(isLeft: true)
                    tapHalf(isLeft: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if fastForward {
                    Text("2× 快进中").font(.subheadline).bold().foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.black.opacity(0.7)).cornerRadius(8)
                        .padding(.top, 90)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                if let flash = seekFlash {
                    Text(flash).font(.subheadline).bold().foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.black.opacity(0.7)).cornerRadius(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                // 全屏按钮（有视频且无报错时才显示）：点进全屏，横屏视频自动转横屏铺满，竖屏视频保持竖屏铺满。
                if player.player != nil && player.error == nil {
                    Button(action: { isFullScreen = true }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, 44)
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
        .fullScreenCover(isPresented: $isFullScreen) {
            FullScreenPlayerView(vm: vm, player: player)
        }
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s)
        return "\(i / 60):\(String(format: "%02d", i % 60))"
    }
}

// MARK: - 全屏播放：同一 AVPlayer 换一层铺满全屏；横屏视频进全屏自动转横屏，退出转回竖屏。
// 点视频空白处显隐控制条（播放中 3 秒无操作自动隐藏）；播完自动下一条时全屏页跟着换，不退出。

struct FullScreenPlayerView: View {
    @ObservedObject var vm: FeedViewModel
    @ObservedObject var player: FeedPlayerModel
    @Environment(\.dismiss) var dismiss
    @State private var showControls = true
    @State private var seekFraction: Double?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            PlayerLayerView(player: player.player, gravity: .resizeAspectFill)
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }
            if showControls {
                VStack(spacing: 0) {
                    // 顶部：剧名/集数 + 退出全屏
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.currentDrama?.name ?? "")
                                .font(.headline).bold().foregroundColor(.white).lineLimit(1)
                            if let ep = vm.currentEpisode {
                                Text("第\(ep.index + 1)集 | \(ep.title)")
                                    .font(.subheadline).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button(action: { dismiss() }) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 20)).foregroundColor(.white)
                                .padding(8).background(Color.black.opacity(0.5)).clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    Spacer()
                    // 中间：播放/暂停
                    Button(action: { player.togglePlay() }) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 56)).foregroundColor(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    // 底部：快退 10 秒 / 时间 / 快进 10 秒 + 可拖进度条
                    VStack(spacing: 10) {
                        HStack(spacing: 20) {
                            Button(action: { player.seekBy(seconds: -10) }) {
                                Image(systemName: "gobackward.10")
                                    .font(.system(size: 26)).foregroundColor(.white)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                                .font(.caption).foregroundColor(.white)
                            Spacer()
                            Button(action: { player.seekBy(seconds: 10) }) {
                                Image(systemName: "goforward.10")
                                    .font(.system(size: 26)).foregroundColor(.white)
                            }
                            .buttonStyle(.plain)
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
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .onAppear {
            // 横屏视频（Feed 里是完整显示、带黑边的那个）进全屏转横屏铺满；竖屏视频保持竖屏铺满。
            if player.gravity == .resizeAspect {
                ScreenRotation.rotate(to: .landscapeRight)
            }
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            ScreenRotation.rotate(to: .portrait)
        }
    }

    private func toggleControls() {
        showControls.toggle()
        if showControls { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled, player.isPlaying { showControls = false }
        }
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

// MARK: - 跨源搜索：一次搜订阅里的前 5 个源（PY + CMS），按剧名去重，边搜边出结果。

struct SearchSheet: View {
    @ObservedObject var vm: FeedViewModel
    @Environment(\.dismiss) var dismiss
    @State private var wd = ""
    @State private var results: [Drama] = []
    @State private var searching = false
    @State private var status = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("搜全部源剧名", text: $wd)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                    Button("搜索") { Task { await doSearch() } }
                }
                .padding()
                if searching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(status).font(.caption).foregroundColor(.gray)
                    }
                    .padding(.bottom, 8)
                }
                if let error = error {
                    Text(error).foregroundColor(.red).padding()
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
                        ForEach(results) { d in
                            Button {
                                // 结果来自哪个源就用哪个源播，别用当前源去播别的源的剧。
                                vm.jumpTo(drama: d, source: d.source, inList: results)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    DramaCard(drama: d)
                                    Text(d.source.displayName).font(.caption2)
                                        .foregroundColor(.gray).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
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
        let w = wd.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        searching = true
        error = nil
        results = []
        status = "正在拉订阅…"
        defer { searching = false }
        do {
            let sources = try await PyAPI.subscription(url: Store.shared.subURL)
            var found: [Drama] = []
            var tried = 0
            for s in sources.prefix(5) {
                // PY 源先看脚本是否要 Crypto/lxml：要的话本机跑不起来，直接跳过，不浪费一次桥调用。
                if !s.isCMS {
                    do {
                        let code = try await PyAPI.script(api: s.api)
                        if code.contains("Crypto") || code.contains("lxml") { continue }
                    } catch { continue }
                }
                tried += 1
                status = "正在搜第 \(tried) 个源…"
                do {
                    let list = try await PyAPI.search(source: s, wd: w)
                    let seen = Set(found.map { $0.name })
                    found += list.filter { !$0.name.isEmpty && !seen.contains($0.name) }
                    results = found
                    status = "已搜 \(tried) 个源，共 \(found.count) 部"
                } catch { continue }
            }
            if found.isEmpty {
                error = "前 5 个源都没搜到“\(w)”"
            } else {
                error = nil
            }
        } catch {
            self.error = "订阅加载失败：\(error)"
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

// MARK: - 继续观看：本机存的进度（看满 5 秒的集），点进去恢复到当时那集、那个进度。

struct ResumeList: View {
    @ObservedObject var vm: FeedViewModel
    @ObservedObject var store = Store.shared

    var body: some View {
        if store.resumes.isEmpty {
            VStack(spacing: 8) {
                Text("还没有继续观看的记录").foregroundColor(.gray)
                Text("看满 5 秒的剧会自动出现在这里").font(.caption).foregroundColor(.gray)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.resumes) { item in
                        HStack(spacing: 12) {
                            Button { vm.jumpToResume(item) } label: {
                                HStack(spacing: 12) {
                                    AsyncImage(url: URL(string: item.pic)) { phase in
                                        if let img = phase.image {
                                            img.resizable().aspectRatio(contentMode: .fill)
                                        } else {
                                            Color(white: 0.2)
                                        }
                                    }
                                    .frame(width: 56, height: 78)
                                    .clipped()
                                    .cornerRadius(6)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name).font(.subheadline).bold()
                                            .foregroundColor(.white).lineLimit(1)
                                        Text("第\(item.epIdx + 1)集 \(item.epTitle)")
                                            .font(.caption).foregroundColor(.gray).lineLimit(1)
                                        Text("已看 \(formatTime(item.time))")
                                            .font(.caption).foregroundColor(.orange)
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle")
                                        .font(.title2).foregroundColor(.orange)
                                }
                            }
                            .buttonStyle(.plain)
                            Button { store.removeResume(id: item.id) } label: {
                                Image(systemName: "trash").foregroundColor(.gray)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal)
                    }
                    Button("清空全部") { store.clearResumes() }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                }
                .padding(.vertical)
            }
        }
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s)
        return "\(i / 60):\(String(format: "%02d", i % 60))"
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
