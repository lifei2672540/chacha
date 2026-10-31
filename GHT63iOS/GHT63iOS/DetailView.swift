import SwiftUI

/// 详情页（TV 版大屏详情页的触屏版）：海报、简介、源/线路切换、选集网格带进度、
/// 续播、追剧；TMDB 有 Key 时横图换高清（TV 1.1.29 同款，卡片海报不动）。
struct DetailView: View {
    var group: VodGroup
    var resumeEpisodeTitle: String? = nil
    @EnvironmentObject var store: Store
    @State private var sourceIdx = 0
    @State private var lineIdx = 0
    @State private var backdrop: String?
    @State private var showPlayer = false
    @State private var playEp: Episode?
    /// 果鉴式选集分组：每组 30 集，默认停在续播集所在组。
    @State private var epGroup = 0

    private var source: VodSource? { group.sources.indices.contains(sourceIdx) ? group.sources[sourceIdx] : nil }
    private var line: PlayLine? {
        guard let lines = source?.lines, lines.indices.contains(lineIdx) else { return nil }
        return lines[lineIdx]
    }
    private var resumeEp: Episode? {
        guard let r = store.recents.first(where: { $0.drama == group.name }) else { return nil }
        return group.sources.flatMap { $0.lines }.flatMap { $0.episodes }.first { $0.title == r.epTitle }
    }
    private var isFav: Bool { store.isFavorite(group.name) }
    private var eps: [Episode] { line?.episodes ?? [] }
    private var epGroupCount: Int { max(1, (eps.count + 29) / 30) }
    private var shownEps: [Episode] {
        let g = min(epGroup, epGroupCount - 1)
        return Array(eps.dropFirst(g * 30).prefix(30))
    }
    private func groupLabel(_ g: Int) -> String {
        "\(g * 30 + 1)-\(min((g + 1) * 30, eps.count))"
    }
    /// 换源/换线路/进页时：续播集在当前线路里就停它那组，否则回第一组。
    private func resetEpGroup() {
        if let r = resumeEp, let idx = eps.firstIndex(of: r) { epGroup = idx / 30 }
        else { epGroup = 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 背景：封面模糊作底（果鉴式），先上 CMS 海报，TMDB 有横图再换锐图
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: URL(string: backdrop ?? group.pic)) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Color.gray.opacity(0.3)
                        }
                    }
                    .blur(radius: 18)
                    .scaleEffect(1.1)
                    .frame(height: 220).clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 220)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.name).font(.largeTitle.bold()).foregroundColor(.white)
                        Text([group.typeName, group.year].filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding()
                }
                VStack(alignment: .leading, spacing: 12) {
                    if !group.content.isEmpty {
                        Text(cleanHtmlText(group.content)).font(.body)
                    }
                    HStack(spacing: 12) {
                        Button(resumeEp == nil ? "播放" : "继续播放") {
                            if let ep = resumeEp ?? line?.episodes.first {
                                ErrorLog.append("点播放 \(group.name) - \(ep.title) url=\(ep.url)")
                                playEp = ep
                                showPlayer = true
                            } else {
                                ErrorLog.append("点播放无集可播 \(group.name)")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button(isFav ? "已追剧" : "追剧") {
                            let total = group.allEpisodes
                            store.toggleFavorite(FavItem(name: group.name, pic: group.pic,
                                                         lastEp: resumeEp?.title ?? "", totalEps: total, status: "watching"))
                        }
                        .buttonStyle(.bordered)
                    }
                    // 源切换
                    if group.sources.count > 1 {
                        Text("源").font(.headline)
                        FlowChips(items: group.sources.map { $0.sourceLabel }, selected: sourceIdx) { i in
                            sourceIdx = i; lineIdx = 0; resetEpGroup()
                        }
                    }
                    // 线路切换
                    if let lines = source?.lines, lines.count > 1 {
                        Text("线路").font(.headline)
                        FlowChips(items: lines.map { $0.label.isEmpty ? "线路\($0.lineIndex)" : $0.label }, selected: lineIdx) { i in
                            lineIdx = i; resetEpGroup()
                        }
                    }
                    // 选集：每组 30 集；看过的集变浅，续播集红框高亮
                    if !eps.isEmpty {
                        HStack {
                            Text("选集").font(.headline)
                            Spacer()
                            Text("\(eps.count) 集").font(.caption).foregroundColor(.secondary)
                        }
                        if epGroupCount > 1 {
                            FlowChips(items: (0..<epGroupCount).map { groupLabel($0) },
                                      selected: min(epGroup, epGroupCount - 1)) { i in epGroup = i }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                            ForEach(shownEps) { ep in
                                let watched = (store.localProgress[ep.url]?.0 ?? 0) > 5
                                let isResume = resumeEp.map { $0 == ep } ?? false
                                Button {
                                    ErrorLog.append("点选集 \(group.name) - \(ep.title) url=\(ep.url)")
                                    playEp = ep; showPlayer = true
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(ep.title).font(.subheadline).lineLimit(1)
                                        if let p = store.localProgress[ep.url], p.0 > 5 {
                                            Text("看到 \(Int(p.0 / 60)) 分钟").font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(isResume ? Color.red.opacity(0.25) : Color.white.opacity(0.1))
                                    .cornerRadius(8)
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(isResume ? Color.red : Color.clear, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .opacity(watched && !isResume ? 0.45 : 1)
                            }
                        }
                    } else {
                        Text("这个源没有可播的集").foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadBackdrop() }
        // 源/线路切换已在 chips 回调里调 resetEpGroup；onAppear 覆盖进页与播完返回
        .onAppear { resetEpGroup() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let ep = playEp {
                // 续播的集可能不在当前选中的源/线路里，按集实际位置起播
                let idx = indices(for: ep)
                PlayerView(group: group, sourceIdx: idx.0, lineIdx: idx.1, startEpisode: ep,
                           sourceLabel: group.sources[idx.0].sourceLabel,
                           lineLabel: group.sources[idx.0].lines[idx.1].label)
            } else {
                // 空 cover 绝不能再是纯黑：给个能退出的界面
                VStack(spacing: 16) {
                    Text("没有可播的集").foregroundColor(.white)
                    Button("关闭") { showPlayer = false }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .onAppear { ErrorLog.append("播放器空壳：showPlayer 已开但 playEp 为空 \(group.name)") }
            }
        }
    }

    /// 集所在的 (源下标, 线路下标)，找不到回落到当前选中。
    private func indices(for ep: Episode) -> (Int, Int) {
        for (si, s) in group.sources.enumerated() {
            for (li, l) in s.lines.enumerated() where l.episodes.contains(ep) {
                return (si, li)
            }
        }
        return (sourceIdx, lineIdx)
    }

    private func loadBackdrop() async {
        guard backdrop == nil else { return }
        if let hit = await TmdbApi.lookup(title: group.name, year: group.year), !hit.backdrop.isEmpty {
            backdrop = hit.backdrop
        }
    }
}

/// 简单流式 chips（自动换行）。
struct FlowChips: View {
    var items: [String]
    var selected: Int
    var onTap: (Int) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                Button(items[i]) { onTap(i) }
                    .buttonStyle(.borderedProminent)
                    .tint(selected == i ? .red : .gray)
            }
        }
    }
}
