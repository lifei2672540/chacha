import SwiftUI
import CoreImage

// MARK: - Telegram 短剧（采集端 tg_collect：剧聚合 + 频道 + 收藏/继续观看 + 频道管理 + 扫码登录）
// 入口是首页顶部第 5 个档位“TG”。播放走 TgPlayerModel（边下边播，茶茶点播 1.2.7 同款）。

/// 播哪个：集列表 + 起播下标 + 剧信息。必须是 internal：TgShowDetailView / TgBrowseView
/// 的 @Binding 属性要公开它的类型，private 会报“property must be declared fileprivate”。
struct TgPlayTarget: Identifiable {
    var id: String { showId + "|" + (episodes.indices.contains(index) ? episodes[index].id : "\(index)") }
    var episodes: [TgVideo]
    var index: Int
    var showId: String
    var showName: String
    var cover: String
}

private func tgFormatTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let i = Int(s)
    return "\(i / 60):\(String(format: "%02d", i % 60))"
}

// MARK: - TG 首页：继续观看 + 收藏 + 剧集 + 频道

struct TgHomeView: View {
    @ObservedObject var tgStore = TgStore.shared
    @State private var channels: [TgChannel] = []
    @State private var shows: [TgShow] = []
    @State private var showPage = 1
    @State private var showTotal = 0
    @State private var loading = false
    @State private var error: String?
    @State private var authPhase = ""
    @State private var authAuthorized = true
    @State private var showManage = false
    @State private var showAuth = false
    @State private var playTarget: TgPlayTarget?

    private let pageSize = 30
    private var pageCount: Int { max(1, (showTotal + pageSize - 1) / pageSize) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !authAuthorized, authPhase == "unauthorized" || authPhase == "password" {
                        Button { showAuth = true } label: {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                Text(authPhase == "password" ? "扫码通过，还差两步验证密码，点我补密码" : "采集端未登录：只能看已收录的，点我扫码登录")
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .foregroundColor(.yellow)
                            .padding()
                            .background(Color.yellow.opacity(0.12))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                    if !tgStore.resumes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("继续观看").font(.headline).padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(tgStore.resumes) { r in
                                        Button { playResume(r) } label: {
                                            TgResumeCard(resume: r)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    if !tgStore.favorites.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("收藏").font(.headline)
                                Spacer()
                            }
                            .padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(tgStore.favorites) { f in
                                        NavigationLink(value: TgShow(id: f.id, name: f.name, epCount: 0, total: 0,
                                                                    cover: f.cover, latest: "", channels: [])) {
                                            TgShowCard(show: TgShow(id: f.id, name: f.name, epCount: 0, total: 0,
                                                                    cover: f.cover, latest: "", channels: []))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("剧集").font(.headline)
                            Spacer()
                            if showTotal > pageSize {
                                Text("第 \(showPage) / \(pageCount) 页").font(.caption).foregroundColor(.gray)
                            }
                        }
                        .padding(.horizontal)
                        if shows.isEmpty && !loading {
                            Text("还没有剧：采集端收录的视频带 #剧名 标签时会自动聚成剧。")
                                .font(.caption).foregroundColor(.gray).padding(.horizontal)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
                                ForEach(shows) { s in
                                    NavigationLink(value: s) {
                                        TgShowCard(show: s)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                            if showTotal > pageSize {
                                HStack(spacing: 20) {
                                    Button("上一页") { Task { await loadShows(page: max(1, showPage - 1)) } }
                                        .disabled(showPage <= 1)
                                    Button("下一页") { Task { await loadShows(page: min(pageCount, showPage + 1)) } }
                                        .disabled(showPage >= pageCount)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("频道").font(.headline).padding(.horizontal)
                        if channels.isEmpty && !loading {
                            Text("还没有频道：先在软路由上跑通采集端（填配置、登录、拉取），再回来。")
                                .font(.caption).foregroundColor(.gray).padding(.horizontal)
                        } else {
                            ForEach(channels) { ch in
                                NavigationLink(value: ch) {
                                    HStack {
                                        Text(ch.title).foregroundColor(.white)
                                        if !ch.enabled {
                                            Text("已停用").font(.caption2).foregroundColor(.gray)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Color.gray.opacity(0.3)).cornerRadius(4)
                                        }
                                        Spacer()
                                        Text("\(ch.count) 条").font(.caption).foregroundColor(.gray)
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Telegram 短剧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button("频道管理") { showManage = true }
                        Button(authAuthorized ? "已登录" : "登录") { showAuth = true }
                    }
                }
            }
            .overlay {
                if loading && shows.isEmpty && channels.isEmpty {
                    ProgressView()
                } else if let error = error, shows.isEmpty, channels.isEmpty {
                    VStack(spacing: 12) {
                        Text("采集端连不上：\(error)").foregroundColor(.red)
                        Text("设置 → 我的里检查采集端地址，软路由上确认服务在跑。")
                            .font(.caption).foregroundColor(.secondary)
                        Button("重试") { Task { await reload() } }
                    }
                    .padding()
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
            .sheet(isPresented: $showManage) {
                TgChannelManageView(channels: channels) { Task { await reload() } }
            }
            .sheet(isPresented: $showAuth) {
                TgAuthView() { Task { await checkAuth() } }
            }
            .navigationDestination(for: TgShow.self) { s in
                TgShowDetailView(show: s, playTarget: $playTarget)
            }
            .navigationDestination(for: TgChannel.self) { ch in
                TgBrowseView(channel: ch, playTarget: $playTarget)
            }
            .fullScreenCover(item: $playTarget) { t in
                TgPlayerView(episodes: t.episodes, index: t.index, showId: t.showId,
                             showName: t.showName, cover: t.cover)
            }
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        await checkAuth()
        do {
            channels = try await TgAPI.getChannels()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await loadShows(page: 1)
    }

    private func checkAuth() async {
        do {
            let st = try await TgAPI.getAuthStatus()
            authAuthorized = st.authorized
            authPhase = st.phase
        } catch {
            authAuthorized = true
            authPhase = ""
        }
    }

    private func loadShows(page: Int) async {
        do {
            let (total, list) = try await TgAPI.getShows(page: page, pageSize: pageSize)
            showTotal = total
            showPage = page
            shows = list
        } catch {
            if shows.isEmpty { self.error = error.localizedDescription }
        }
    }

    private func playResume(_ r: TgResume) {
        let v = TgVideo(id: r.id, channel: "", channelTitle: "", title: r.epTitle, caption: "",
                        date: "", duration: 0, thumbUrl: r.thumbUrl, streamUrl: r.streamUrl,
                        show: r.showName, episodeNo: r.epNo)
        playTarget = TgPlayTarget(episodes: [v], index: 0, showId: r.showId,
                                  showName: r.showName, cover: r.cover)
    }
}

private struct TgResumeCard: View {
    var resume: TgResume

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: resume.thumbUrl.isEmpty ? "" : TgAPI.baseUrl + resume.thumbUrl)) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.2)
                }
            }
            .frame(width: 110, height: 154)
            .clipped()
            .cornerRadius(8)
            Text(resume.showName).font(.caption).lineLimit(2).foregroundColor(.white)
            Text(resume.epNo > 0 ? "第\(resume.epNo)集 · 已看 \(tgFormatTime(resume.time))" : "已看 \(tgFormatTime(resume.time))")
                .font(.caption2).foregroundColor(.orange).lineLimit(1)
        }
        .frame(width: 110)
    }
}

private struct TgShowCard: View {
    var show: TgShow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: show.cover.isEmpty ? "" : TgAPI.baseUrl + show.cover)) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.2)
                }
            }
            .frame(width: 110, height: 154)
            .clipped()
            .cornerRadius(8)
            Text(show.name).font(.caption).lineLimit(2).foregroundColor(.white)
            Text(show.epCount > 0 ? "更新至 \(show.epCount) 集" : "共 \(show.total) 条")
                .font(.caption2).foregroundColor(.gray).lineLimit(1)
        }
        .frame(width: 110)
    }
}

// MARK: - 剧详情：封面 + 收藏 + 选集表（带进度点）+ 缺集补全

struct TgShowDetailView: View {
    var show: TgShow
    @Binding var playTarget: TgPlayTarget?
    @ObservedObject var tgStore = TgStore.shared
    @State private var detail: TgShowDetail?
    @State private var loading = false
    @State private var error: String?
    @State private var filling = false
    @State private var fillHint = ""

    var body: some View {
        NavigationStack {
            Group {
                if loading && detail == nil {
                    ProgressView()
                } else if let error = error, detail == nil {
                    VStack(spacing: 12) {
                        Text(error).foregroundColor(.red)
                        Button("重试") { Task { await load() } }
                    }
                    .padding()
                } else if let det = detail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top, spacing: 12) {
                                AsyncImage(url: URL(string: show.cover.isEmpty ? "" : TgAPI.baseUrl + show.cover)) { phase in
                                    if let img = phase.image {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Color(white: 0.2)
                                    }
                                }
                                .frame(width: 110, height: 154)
                                .clipped()
                                .cornerRadius(8)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(det.show.name).font(.headline).foregroundColor(.white)
                                    Text(det.show.epCount > 0 ? "更新至 \(det.show.epCount) 集" : "共 \(det.show.total) 条")
                                        .font(.caption).foregroundColor(.gray)
                                    if !det.missing.isEmpty {
                                        Text("缺第 \(det.missing.map { "\($0)" }.joined(separator: "、")) 集")
                                            .font(.caption).foregroundColor(.yellow)
                                    }
                                    Button(filling ? "正在补全…" : "搜索补全缺集") {
                                        Task { await fill() }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(filling || det.missing.isEmpty)
                                    if !fillHint.isEmpty {
                                        Text(fillHint).font(.caption).foregroundColor(.gray)
                                    }
                                    Button(tgStore.isFavorite(showId: det.show.id) ? "取消收藏" : "收藏这部剧") {
                                        tgStore.toggleFavorite(show: det.show)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.horizontal)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                                ForEach(det.episodes) { ep in
                                    Button {
                                        if let idx = det.episodes.firstIndex(of: ep) {
                                            playTarget = TgPlayTarget(episodes: det.episodes, index: idx,
                                                                     showId: det.show.id, showName: det.show.name,
                                                                     cover: det.show.cover)
                                        }
                                    } label: {
                                        ZStack(alignment: .topTrailing) {
                                            Text(ep.episodeNo > 0 ? "\(ep.episodeNo)" : "•")
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 10)
                                                .background(Color.white.opacity(0.12))
                                                .cornerRadius(8)
                                                .foregroundColor(.white)
                                            if Store.shared.progress(for: ep.streamUrl) > 0 {
                                                Circle().fill(Color.orange).frame(width: 7, height: 7)
                                                    .offset(x: -4, y: 4)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                            Text("橙点 = 这集看过一部分，点进去接着播。")
                                .font(.caption).foregroundColor(.gray).padding(.horizontal)
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle(show.name)
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            detail = try await TgAPI.getShowDetail(show: show)
            error = nil
        } catch {
            self.error = "加载失败：\(error.localizedDescription)"
        }
    }

    private func fill() async {
        guard let det = detail, !det.missing.isEmpty else { return }
        filling = true
        defer { filling = false }
        do {
            let (added, stillMissing) = try await TgAPI.fillShow(show: det.show)
            if added > 0 {
                fillHint = "补回 \(added) 集，正在刷新选集…"
                await load()
                fillHint = stillMissing.isEmpty ? "已补全" : "补回 \(added) 集，还缺第 \(stillMissing.map { "\($0)" }.joined(separator: "、")) 集"
            } else {
                fillHint = "频道里没搜到缺的集（可能还没人发，或标签不是 #\(det.show.name)）"
            }
        } catch {
            fillHint = "补全失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 频道视频列表（茶茶点播 TgBrowseView 同款：网格 + 分页 + 点片直播）

struct TgBrowseView: View {
    var channel: TgChannel
    @Binding var playTarget: TgPlayTarget?
    @State private var videos: [TgVideo] = []
    @State private var page = 1
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?

    private let pageSize = 30
    private var pageCount: Int { max(1, (total + pageSize - 1) / pageSize) }

    var body: some View {
        NavigationStack {
            VStack {
                if let error = error, videos.isEmpty {
                    VStack(spacing: 12) {
                        Text(error).foregroundColor(.red)
                        Button("重试") { Task { await load(page: 1) } }
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
                            ForEach(videos) { v in
                                Button {
                                    if let idx = videos.firstIndex(of: v) {
                                        playTarget = TgPlayTarget(episodes: videos, index: idx,
                                                                 showId: v.show ?? "", showName: v.show ?? v.title,
                                                                 cover: v.thumbUrl)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        AsyncImage(url: URL(string: v.absUrl(TgAPI.baseUrl, v.thumbUrl))) { phase in
                                            if let img = phase.image {
                                                img.resizable().aspectRatio(contentMode: .fill)
                                            } else {
                                                Color(white: 0.2)
                                            }
                                        }
                                        .frame(width: 110, height: 154)
                                        .clipped()
                                        .cornerRadius(8)
                                        Text(v.title).font(.caption).lineLimit(2).foregroundColor(.white)
                                        Text(v.metaLine()).font(.caption2).foregroundColor(.gray).lineLimit(1)
                                    }
                                    .frame(width: 110)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                    HStack(spacing: 20) {
                        Button("上一页") { Task { await load(page: max(1, page - 1)) } }
                            .disabled(page <= 1)
                        Text("第 \(page) / \(pageCount) 页").font(.caption).foregroundColor(.gray)
                        Button("下一页") { Task { await load(page: min(pageCount, page + 1)) } }
                            .disabled(page >= pageCount)
                    }
                    .padding(.bottom)
                }
                if loading { ProgressView() }
            }
            .navigationTitle(channel.title)
            .navigationBarTitleDisplayMode(.inline)
            .task { await load(page: 1) }
        }
    }

    private func load(page: Int) async {
        loading = true
        defer { loading = false }
        do {
            let (total, items) = try await TgAPI.getFeed(channel: channel.key, page: page, pageSize: pageSize)
            self.total = total
            self.page = page
            self.videos = items
            self.error = nil
        } catch {
            self.videos = []
            self.error = "加载失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 频道管理：开关停用/启用（停用后采集端不再拉该频道的新消息，旧的还能播）

struct TgChannelManageView: View {
    var channels: [TgChannel]
    var onChanged: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var toggles: [String: Bool] = [:]
    @State private var busyKey: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if channels.isEmpty {
                    Text("还没有频道").foregroundColor(.gray)
                }
                ForEach(channels) { ch in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ch.title).foregroundColor(.white)
                            Text("\(ch.count) 条").font(.caption).foregroundColor(.gray)
                        }
                        Spacer()
                        if busyKey == ch.key {
                            ProgressView()
                        } else {
                            Toggle("", isOn: Binding(
                                get: { toggles[ch.key] ?? ch.enabled },
                                set: { v in Task { await toggle(ch: ch, to: v) } }
                            ))
                            .labelsHidden()
                        }
                    }
                }
                Text("停用只停新拉取，不删已收录的视频；再打开就恢复拉取。")
                    .font(.caption).foregroundColor(.gray)
                if let error = error {
                    Text(error).font(.caption).foregroundColor(.red)
                }
            }
            .navigationTitle("频道管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                for ch in channels { toggles[ch.key] = ch.enabled }
            }
        }
    }

    private func toggle(ch: TgChannel, to enabled: Bool) async {
        busyKey = ch.key
        defer { busyKey = nil }
        toggles[ch.key] = enabled
        do {
            let back = try await TgAPI.toggleChannel(key: ch.key, enabled: enabled)
            toggles[ch.key] = back
            error = nil
            onChanged()
        } catch {
            toggles[ch.key] = ch.enabled
            self.error = "切换失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 扫码登录：采集端会话失效时用 Telegram 扫码重登（App 里渲染二维码，不用上路由器输验证码）

struct TgAuthView: View {
    var onChanged: () -> Void = {}
    @Environment(\.dismiss) var dismiss
    @State private var phase = ""
    @State private var authorized = false
    @State private var qrURL: String?
    @State private var qrImage: UIImage?
    @State private var password = ""
    @State private var message = ""
    @State private var busy = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if authorized {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60)).foregroundColor(.green)
                    Text("采集端已登录").font(.headline)
                    Text("拉取正常进行。会话过期时再来这里扫码重登。")
                        .font(.caption).foregroundColor(.gray).multilineTextAlignment(.center)
                } else if phase == "password" {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 44)).foregroundColor(.orange)
                    Text("扫码通过，还差一步").font(.headline)
                    Text("账号开了两步验证，输入 Telegram 的两步验证密码完成登录（密码只发给采集端一次，不存本机）。")
                        .font(.caption).foregroundColor(.gray).multilineTextAlignment(.center)
                    SecureField("两步验证密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 40)
                    Button(busy ? "提交中…" : "提交密码") { Task { await submitPassword() } }
                        .buttonStyle(.bordered)
                        .disabled(busy || password.isEmpty)
                } else if let img = qrImage {
                    Text("用 Telegram 扫码登录采集端").font(.headline)
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 240, height: 240)
                        .background(Color.white)
                        .cornerRadius(12)
                    Text("打开 Telegram → 设置 → 设备 → 关联桌面设备，扫这个码。")
                        .font(.caption).foregroundColor(.gray).multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("二维码过期了，重新获取") { Task { await fetchQR() } }
                        .buttonStyle(.bordered)
                } else {
                    ProgressView()
                    Text(message.isEmpty ? "正在取二维码…" : message)
                        .font(.caption).foregroundColor(.gray)
                    Button("重试") { Task { await fetchQR() } }
                        .buttonStyle(.bordered)
                }
                if !message.isEmpty, !authorized {
                    Text(message).font(.caption).foregroundColor(.red).multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("采集端登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await start() }
            .onDisappear {
                pollTask?.cancel()
                onChanged()
            }
        }
    }

    private func start() async {
        await refreshStatus()
        if !authorized { await fetchQR() }
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                await refreshStatus()
                if authorized { break }
            }
        }
    }

    private func refreshStatus() async {
        do {
            let st = try await TgAPI.getAuthStatus()
            authorized = st.authorized
            phase = st.phase
            if authorized { message = "" }
        } catch {
            message = "状态查询失败：\(error.localizedDescription)"
        }
    }

    private func fetchQR() async {
        busy = true
        defer { busy = false }
        do {
            let r = try await TgAPI.getAuthQR()
            if r.authorized {
                authorized = true
                phase = "authorized"
                qrImage = nil
                qrURL = nil
                return
            }
            guard let url = r.url, !url.isEmpty else {
                message = "没拿到二维码内容，点重试"
                return
            }
            qrURL = url
            qrImage = makeQRImage(from: url)
            if qrImage == nil { message = "二维码生成失败，点重试" }
        } catch {
            message = "取二维码失败：\(error.localizedDescription)"
        }
    }

    private func submitPassword() async {
        busy = true
        defer { busy = false }
        do {
            let ok = try await TgAPI.submitAuthPassword(password)
            if ok {
                authorized = true
                phase = "authorized"
                password = ""
                message = ""
            } else {
                message = "密码没通过，再试一次"
            }
        } catch {
            message = "提交失败：\(error.localizedDescription)"
        }
    }

    private func makeQRImage(from string: String) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return UIImage(ciImage: scaled)
    }
}

// MARK: - TG 播放页（全屏：同一 AVPlayer 铺满；点视频空白处显隐控制条，播放中 3 秒自动隐藏）

struct TgPlayerView: View {
    var episodes: [TgVideo]
    var index: Int
    var showId: String
    var showName: String
    var cover: String
    @Environment(\.dismiss) var dismiss
    @StateObject private var model = TgPlayerModel()
    @State private var showControls = true
    @State private var seekFraction: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var finished = false

    var body: some View {
        ZStack {
            PlayerLayerView(player: model.player, gravity: model.gravity)
                .ignoresSafeArea()
            // 点按层：盖在视频上、控制条下，点空白处显隐控制条；控制条上的按钮自己响应，不会误触。
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
            if showControls {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(showName).font(.headline).bold().foregroundColor(.white).lineLimit(1)
                            if let v = model.currentVideo {
                                Text(v.epLabel + (v.title.isEmpty ? "" : " | \(v.title)"))
                                    .font(.subheadline).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 20)).foregroundColor(.white)
                                .padding(8).background(Color.black.opacity(0.5)).clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    Spacer()
                    Button(action: { model.togglePlay() }) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 56)).foregroundColor(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    VStack(spacing: 10) {
                        if let p = model.cacheProgress {
                            Text(p >= 0 ? "正在缓冲 \(Int(p * 100))%（\(Int(model.cacheMB))MB）" : "正在缓冲 \(Int(model.cacheMB))MB")
                                .font(.caption).foregroundColor(.yellow)
                        }
                        if let err = model.error {
                            Text(err).font(.caption).foregroundColor(.red).multilineTextAlignment(.center)
                            HStack(spacing: 12) {
                                Button("重试") { model.retry() }.buttonStyle(.bordered)
                                Button("返回") { dismiss() }.buttonStyle(.bordered)
                            }
                        }
                        if finished {
                            Text("已播完").font(.caption).foregroundColor(.gray)
                            Button("返回") { dismiss() }.buttonStyle(.bordered)
                        }
                        HStack(spacing: 20) {
                            Button(action: { model.seekBy(seconds: -10); scheduleHide() }) {
                                Image(systemName: "gobackward.10")
                                    .font(.system(size: 26)).foregroundColor(.white)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Text("\(tgFormatTime(model.currentTime)) / \(tgFormatTime(model.duration))")
                                .font(.caption).foregroundColor(.white)
                            Spacer()
                            Button(action: { model.seekBy(seconds: 10); scheduleHide() }) {
                                Image(systemName: "goforward.10")
                                    .font(.system(size: 26)).foregroundColor(.white)
                            }
                            .buttonStyle(.plain)
                        }
                        GeometryReader { barGeo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.white.opacity(0.3)).frame(height: 4)
                                Rectangle().fill(Color.orange)
                                    .frame(width: barGeo.size.width * (seekFraction ?? model.progress), height: 4)
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
                                        model.seek(to: f)
                                        seekFraction = nil
                                        scheduleHide()
                                    }
                            )
                        }
                        .frame(height: 28)
                        if model.hasNext {
                            Button("下一集") { model.nextEpisode(auto: false) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            if model.loading {
                ProgressView().tint(.white)
            }
        }
        .background(Color.black)
        .onAppear {
            model.onAllEnded = { finished = true }
            model.load(episodes: episodes, index: index, showId: showId, showName: showName, cover: cover)
            scheduleHide()
        }
        .onChange(of: model.isLandscape) { landscape in
            // 横屏视频进播自动转横屏铺满，竖屏保持竖屏铺满；退出时转回竖屏。
            ScreenRotation.rotate(to: landscape ? .landscapeRight : .portrait)
        }
        // 暂停时留着控制条，恢复播放 3 秒后再藏。
        .onChange(of: model.isPlaying) { playing in
            if playing { scheduleHide() } else { hideTask?.cancel() }
        }
        .onDisappear {
            hideTask?.cancel()
            model.cleanup()
            ScreenRotation.rotate(to: .portrait)
        }
    }

    private func toggleControls() {
        showControls.toggle()
        if showControls { scheduleHide() } else { hideTask?.cancel() }
    }

    /// 3 秒无操作自动藏控制条：没播（暂停/缓冲）就一直等，播了再等 3 秒藏；
    /// 一次性的检查不可靠（正好卡在暂停那一刻就永远不藏了），所以循环等。
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                if model.isPlaying {
                    showControls = false
                    return
                }
            }
        }
    }
}
