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
    /// 测速状态：测当前线路首集（续播集优先）的直链。
    @State private var speedTesting = false
    @State private var speedResult: String?
    @State private var speedOK = false
    /// 全部源测速：每行一条源+线路的速度（nil = 打不开），最快在前。
    @State private var allSpeedResults: [SpeedResult] = []
    @State private var allSpeedTesting = false
    @State private var allSpeedDone = 0
    @State private var allSpeedTotal = 0

    /// 全部源/线路加起来有几条可测的路线（只有一条时不显示“测全部源”）。
    private var totalRoutes: Int { group.sources.flatMap { $0.lines }.count }

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

    /// 待测地址：PY 组是待解析的站内地址、测不了直链；Emby 伪地址先换成真实流地址。
    private var testURL: String? {
        guard group.pyApi.isEmpty else { return nil }
        guard let ep = resumeEp ?? line?.episodes.first else { return nil }
        let u = ep.url
        if u.hasPrefix("emby:") { return EmbyApi.streamUrl(group: group, episode: ep) }
        return u.isEmpty ? nil : u
    }

    private func runSpeedTest() async {
        guard let u = testURL else { return }
        speedTesting = true
        speedResult = nil
        let (ok, mbps) = await Self.testSpeed(urlString: u)
        speedTesting = false
        if ok {
            speedOK = true
            if let m = mbps {
                speedResult = "能看 · \(formatSpeed(m))"
            } else {
                speedResult = "能看 · 速度未知"
            }
        } else {
            speedOK = false
            speedResult = "打不开或超时，换条线路试试"
        }
    }

    /// 速度显示：≥1 用 MB/s，否则用 KB/s。
    private func formatSpeed(_ mbps: Double) -> String {
        mbps >= 1 ? String(format: "%.1f MB/s", mbps) : "\(Int(mbps * 1000)) KB/s"
    }

    /// 测全部源：同一集在每个源每条线路上都测一遍，并行测，最快在前。
    /// 点结果行就切到那条线路并直接播放（集按地址认源，不会串到别的源）。
    private func runAllSpeedTest() async {
        guard let target = resumeEp ?? line?.episodes.first else { return }
        // 每条线路里找同名集（没有这集的源跳过；同一地址只测一次）。
        var jobs: [(sourceIdx: Int, lineIdx: Int, label: String, url: String, episode: Episode)] = []
        var seenURLs: Set<String> = []
        for (si, s) in group.sources.enumerated() {
            for (li, l) in s.lines.enumerated() {
                guard let ep = l.episodes.first(where: { $0.title == target.title }) else { continue }
                var u = ep.url
                if u.hasPrefix("emby:") {
                    guard let real = EmbyApi.streamUrl(group: group, episode: ep) else { continue }
                    u = real
                }
                guard !u.isEmpty, seenURLs.insert(u).inserted else { continue }
                let lineName = l.label.isEmpty ? "线路\(l.lineIndex)" : l.label
                jobs.append((si, li, "\(s.sourceLabel) · \(lineName)", u, ep))
            }
        }
        allSpeedResults = []
        allSpeedDone = 0
        allSpeedTotal = jobs.count
        allSpeedTesting = true
        speedResult = nil
        let results = await withTaskGroup(of: SpeedResult.self) { g in
            for job in jobs {
                g.addTask {
                    let (ok, mbps) = await Self.testSpeed(urlString: job.url)
                    return SpeedResult(sourceIdx: job.sourceIdx, lineIdx: job.lineIdx,
                                       label: job.label, mbps: ok ? mbps : nil, episode: job.episode)
                }
            }
            var out: [SpeedResult] = []
            for await r in g {
                out.append(r)
                allSpeedDone += 1
            }
            return out
        }
        allSpeedTesting = false
        // 最快在前，打不开的沉底。
        allSpeedResults = results.sorted {
            switch ($0.mbps, $1.mbps) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return false
            }
        }
    }

    /// 测速：m3u8 先取播放列表、再下首个分片；直链直接下前 1MB；最多 15 秒。
    /// 返回（能看，速度 MB/s；速度测不出时为 nil）。
    /// static：测全部源时在并发任务里调，不碰页面状态。
    private static func testSpeed(urlString: String) async -> (Bool, Double?) {
        guard let url = URL(string: urlString) else { return (false, nil) }
        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 15
        let session = URLSession(configuration: cfg)
        // 只读首字节探响应头：有些地址不带 .m3u8 后缀，靠 Content-Type 认播放列表。
        // 探头只认类型、不判生死（生死由正式下载定，避免不支持 Range 的站被误判）。
        var isPlaylist = urlString.lowercased().contains(".m3u8")
        var probe = URLRequest(url: url, timeoutInterval: 10)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        probe.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let (_, resp) = try? await session.data(for: probe),
           let http = resp as? HTTPURLResponse,
           let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           ct.contains("mpegurl") { isPlaylist = true }
        // 播放列表：沿首条非注释行最多跟 2 层（主列表 → 分列表 → 分片）。
        var target = url
        if isPlaylist {
            var hops = 0
            while hops < 2 {
                guard let (data, _) = try? await session.data(from: target),
                      let text = String(data: data, encoding: .utf8) else { break }
                var next: URL?
                for line in text.components(separatedBy: .newlines) {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || t.hasPrefix("#") { continue }
                    next = URL(string: t, relativeTo: target)?.absoluteURL
                    break
                }
                guard let n = next else { break }
                target = n
                hops += 1
                if !target.absoluteString.lowercased().contains(".m3u8") { break }
            }
            // 跟完还是列表（没找到分片）：地址通、速度测不出。
            if target.absoluteString.lowercased().contains(".m3u8") { return (true, nil) }
        }
        return await Self.downloadFirstMB(target, ua: ua, session: session)
    }

    /// 下前 1MB 计时（分片不足 1MB 就整段测；读满即停，不下全文）。
    /// 站不支持 Range 时（416）改不带 Range 重试一次，照样只读 1MB。
    private static func downloadFirstMB(_ url: URL, ua: String, session: URLSession) async -> (Bool, Double?) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse else { return (false, nil) }
            if http.statusCode == 416 {
                var plain = req
                plain.setValue(nil, forHTTPHeaderField: "Range")
                return await Self.downloadFirstMBPlain(plain, session: session)
            }
            guard (200...299).contains(http.statusCode) || http.statusCode == 206 else { return (false, nil) }
            var total = 0
            let start = Date()
            for try await _ in bytes {
                total += 1
                if total >= 1_048_576 { break }
            }
            guard total > 0 else { return (false, nil) }
            let secs = max(Date().timeIntervalSince(start), 0.01)
            return (true, Double(total) / 1_000_000 / secs)
        } catch {
            return (false, nil)
        }
    }

    /// 不带 Range 下前 1MB（downloadFirstMB 遇 416 时的重试路径）。
    private static func downloadFirstMBPlain(_ req: URLRequest, session: URLSession) async -> (Bool, Double?) {
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return (false, nil) }
            var total = 0
            let start = Date()
            for try await _ in bytes {
                total += 1
                if total >= 1_048_576 { break }
            }
            guard total > 0 else { return (false, nil) }
            let secs = max(Date().timeIntervalSince(start), 0.01)
            return (true, Double(total) / 1_000_000 / secs)
        } catch {
            return (false, nil)
        }
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
                            sourceIdx = i; lineIdx = 0; resetEpGroup(); speedResult = nil
                        }
                    }
                    // 线路切换
                    if let lines = source?.lines, lines.count > 1 {
                        Text("线路").font(.headline)
                        FlowChips(items: lines.map { $0.label.isEmpty ? "线路\($0.lineIndex)" : $0.label }, selected: lineIdx) { i in
                            lineIdx = i; resetEpGroup(); speedResult = nil
                        }
                    }
                    // 测速：先测当前线路首集能不能看、多快（换源/换线路后结果清空）
                    if !group.pyApi.isEmpty {
                        Text("PY 源需解析后才能播，测速不适用").font(.subheadline).foregroundColor(.secondary)
                    } else {
                        HStack(spacing: 10) {
                            Button(speedTesting ? "测速中…" : "测速") {
                                Task { await runSpeedTest() }
                            }
                            .buttonStyle(.bordered)
                            .tint(.gray)
                            .disabled(speedTesting || allSpeedTesting || testURL == nil)
                            if totalRoutes > 1 {
                                Button(allSpeedTesting ? "测速中 \(allSpeedDone)/\(allSpeedTotal)…" : "测全部源") {
                                    Task { await runAllSpeedTest() }
                                }
                                .buttonStyle(.bordered)
                                .tint(.gray)
                                .disabled(speedTesting || allSpeedTesting)
                            }
                            if let r = speedResult {
                                Text(r).font(.subheadline).foregroundColor(speedOK ? .green : .red)
                            }
                        }
                        // 全部源测速结果：最快在前，点一行就切到那条线路并直接播放
                        if !allSpeedResults.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                if let best = allSpeedResults.first, let m = best.mbps {
                                    Text("推荐：\(best.label) · \(formatSpeed(m))")
                                        .font(.subheadline).foregroundColor(.green)
                                }
                                ForEach(allSpeedResults) { r in
                                    Button {
                                        sourceIdx = r.sourceIdx; lineIdx = r.lineIdx; resetEpGroup()
                                        playEp = r.episode
                                    } label: {
                                        HStack {
                                            Text(r.label).font(.subheadline)
                                            Spacer()
                                            Text(r.mbps.map { formatSpeed($0) } ?? "打不开")
                                                .font(.subheadline)
                                                .foregroundColor(r.mbps == nil ? .red : .primary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
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

/// 全部源测速的一行结果：某源某线路的同名集、速度（nil = 打不开）。
struct SpeedResult: Identifiable {
    var id: String { "\(sourceIdx)-\(lineIdx)" }
    var sourceIdx: Int
    var lineIdx: Int
    var label: String
    var mbps: Double?
    var episode: Episode
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
