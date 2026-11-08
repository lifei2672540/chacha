import SwiftUI

/// 详情页（TV 版大屏详情页的触屏版）：海报、简介、源/线路切换、选集网格带进度、
/// 续播、追剧；TMDB 有 Key 时横图换高清（TV 1.1.29 同款，卡片海报不动）。
struct DetailView: View {
    var group: VodGroup
    var resumeEpisodeTitle: String? = nil
    @EnvironmentObject var store: Store
    @State private var sourceIdx = 0
    @State private var lineIdx = 0
    /// 大海报地址（先上接口海报，TMDB 有竖图再换）：蚂蚁详情页同款通顶大图。
    @State private var heroURL: URL?
    @State private var tmdbScore: Double = 0
    @State private var synopsisExpanded = false
    @State private var sortDesc = false
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
        let slice = Array(eps.dropFirst(g * 30).prefix(30))
        // 倒序只反当前这 30 集的显示顺序，分组本身不动，续播定位不受影响。
        return sortDesc ? slice.reversed() : slice
    }
    /// 简介：有些源把同一段拼了两遍（中缝可带空白），掐掉重复的一半再显示。
    private var synopsis: String {
        let t = cleanHtmlText(group.content).trimmingCharacters(in: .whitespacesAndNewlines)
        let n = t.count
        guard n > 40 else { return t }
        let chars = Array(t)
        for start in [n / 2 - 2, n / 2 - 1, n / 2, n / 2 + 1, n / 2 + 2] {
            guard start > 10, start < n - 10 else { continue }
            let a = String(chars[..<start]).trimmingCharacters(in: .whitespaces)
            let b = String(chars[start...]).trimmingCharacters(in: .whitespaces)
            if !a.isEmpty, a == b { return a }
        }
        return t
    }
    /// 海报下的元数据行：集数 · 年份 · 类型（蚂蚁详情页同款）。
    private var metaLine: String {
        var parts: [String] = []
        if eps.count > 0 { parts.append("\(eps.count) 集") }
        if !group.year.isEmpty { parts.append(group.year) }
        if !group.typeName.isEmpty { parts.append(group.typeName) }
        return parts.joined(separator: " · ")
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
            VStack(alignment: .leading, spacing: 0) {
                // 大海报（蚂蚁详情页同款）：清晰海报通顶，下沿渐隐，标题压在图上
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: heroURL) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Color.gray.opacity(0.3)
                        }
                    }
                    .frame(height: 440).clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 440)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.name).font(.largeTitle.bold()).foregroundColor(.white)
                            .lineLimit(2)
                        if !metaLine.isEmpty {
                            Text(metaLine).foregroundColor(.white.opacity(0.9))
                        }
                    }
                    .padding()
                }
                VStack(alignment: .leading, spacing: 16) {
                    // TMDB 评分（有 Key 且匹配到才有）
                    if tmdbScore > 0 {
                        Text("TMDB \(String(format: "%.1f", tmdbScore))")
                            .font(.subheadline.bold())
                            .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.8))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(8)
                    }
                    // 简介：默认只露 3 行，点展开看全文（蚂蚁同款）
                    if !synopsis.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(synopsis).font(.body)
                                .lineLimit(synopsisExpanded ? nil : 3)
                            if synopsis.count > 120 {
                                Button(synopsisExpanded ? "收起简介 ⌃" : "展开简介 ⌄") {
                                    synopsisExpanded.toggle()
                                }
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    // 大播放键（蚂蚁同款白底通栏）+ 追剧圆钮
                    HStack(spacing: 12) {
                        Button {
                            if let ep = resumeEp ?? line?.episodes.first {
                                ErrorLog.append("点播放 \(group.name) - \(ep.title) url=\(ep.url)")
                                playEp = ep
                            } else {
                                ErrorLog.append("点播放无集可播 \(group.name)")
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text(resumeEp == nil ? "立即播放" : "继续播放")
                            }
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.white)
                            .cornerRadius(26)
                        }
                        .buttonStyle(.plain)
                        Button {
                            let total = group.allEpisodes
                            store.toggleFavorite(FavItem(name: group.name, pic: group.pic,
                                                         lastEp: resumeEp?.title ?? "", totalEps: total, status: "watching"))
                        } label: {
                            Image(systemName: isFav ? "bookmark.fill" : "bookmark")
                                .font(.system(size: 20))
                                .foregroundColor(isFav ? .red : .white)
                                .frame(width: 52, height: 52)
                                .background(Color.white.opacity(0.12))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
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
                            Text("剧集").font(.title2.bold())
                            Text("\(eps.count)").font(.title3).foregroundColor(.secondary)
                            Spacer()
                            Button {
                                sortDesc.toggle()
                                if resumeEp != nil { resetEpGroup() }
                                else { epGroup = sortDesc ? epGroupCount - 1 : 0 }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.arrow.down").font(.caption)
                                    Text(sortDesc ? "倒序" : "正序").font(.subheadline)
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.gray)
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
                                    playEp = ep
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
                .padding(.top, 16)
                // 别让悬浮玻璃底栏盖住最下面一行
                .padding(.bottom, 96)
            }
        }
        // 标题在海报上，导航栏只留返回键（蚂蚁同款）。
        .task { await loadTmdb() }
        // 源/线路切换已在 chips 回调里调 resetEpGroup；onAppear 覆盖进页与播完返回
        .onAppear { resetEpGroup() }
        // 以集本身驱动打开：集不到位 cover 就打不开，杜绝“开了个空壳”这一类问题
        .fullScreenCover(item: $playEp) { ep in
            // 续播的集可能不在当前选中的源/线路里，按集实际位置起播
            let idx = indices(for: ep)
            PlayerView(group: group, sourceIdx: idx.0, lineIdx: idx.1, startEpisode: ep,
                       sourceLabel: group.sources[idx.0].sourceLabel,
                       lineLabel: group.sources[idx.0].lines[idx.1].label)
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

    private func loadTmdb() async {
        // 先上接口自带海报，TMDB 有竖图再换高清竖图（大海报用竖图，横图裁得太狠）。
        if !group.pic.isEmpty { heroURL = URL(string: group.pic) }
        // 详情页海报背景开关（设置 → 观看体验 → 视频设置）：关了不用 TMDB 海报与评分。
        guard await Store.shared.detailPosterBackdrop else { return }
        guard let hit = await TmdbApi.lookup(title: group.name, year: group.year) else { return }
        tmdbScore = hit.score
        if !hit.poster.isEmpty {
            // 竖图取 w780（卡片用的 w500 在大海报上偏糊）。
            let big = hit.poster.replacingOccurrences(of: "/w500/", with: "/w780/")
            heroURL = URL(string: big)
        } else if heroURL == nil, !hit.backdrop.isEmpty {
            heroURL = URL(string: hit.backdrop)
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
