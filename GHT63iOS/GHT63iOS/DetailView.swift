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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 背景：先上 CMS 海报，TMDB 有横图再换锐图
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: URL(string: backdrop ?? group.pic)) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Color.gray.opacity(0.3)
                        }
                    }
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
                                playEp = ep
                                showPlayer = true
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
                            sourceIdx = i; lineIdx = 0
                        }
                    }
                    // 线路切换
                    if let lines = source?.lines, lines.count > 1 {
                        Text("线路").font(.headline)
                        FlowChips(items: lines.map { $0.label.isEmpty ? "线路\($0.lineIndex)" : $0.label }, selected: lineIdx) { i in
                            lineIdx = i
                        }
                    }
                    // 选集
                    if let eps = line?.episodes, !eps.isEmpty {
                        HStack {
                            Text("选集").font(.headline)
                            Spacer()
                            Text("\(eps.count) 集").font(.caption).foregroundColor(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                            ForEach(eps) { ep in
                                Button {
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
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
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
        .fullScreenCover(isPresented: $showPlayer) {
            if let ep = playEp {
                // 续播的集可能不在当前选中的源/线路里，按集实际位置起播
                let idx = indices(for: ep)
                PlayerView(group: group, sourceIdx: idx.0, lineIdx: idx.1, startEpisode: ep,
                           sourceLabel: group.sources[idx.0].sourceLabel,
                           lineLabel: group.sources[idx.0].lines[idx.1].label)
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
