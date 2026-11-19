import SwiftUI

// MARK: - Telegram 短剧（TV 版 TgActivity 的触屏版：频道 → 视频网格 → 点片直进播放器）

struct TgHomeView: View {
    @State private var channels: [TgChannel] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if loading && channels.isEmpty {
                ProgressView()
            } else if let error = error, channels.isEmpty {
                VStack(spacing: 12) {
                    Text("采集端连不上：\(error)").foregroundColor(.red)
                    Text("设置里检查采集端地址，软路由上确认服务在跑。")
                        .font(.caption).foregroundColor(.secondary)
                    Button("重试") { Task { await load() } }
                }
                .padding()
            } else if channels.isEmpty {
                Text("还没有频道：先在软路由上跑通采集端（填配置、--login、--once），再回来。")
                    .foregroundColor(.secondary).padding()
            } else {
                List(channels) { ch in
                    NavigationLink(destination: TgBrowseView(channel: ch)) {
                        HStack {
                            Text(ch.title).foregroundColor(.white)
                            Spacer()
                            Text("\(ch.count) 条").font(.caption).foregroundColor(.gray)
                        }
                    }
                }
            }
        }
        .navigationTitle("Telegram 短剧")
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            channels = try await ApiClient.shared.getTgChannels()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct TgPlayTarget: Identifiable {
    var id: String { group.name + "|" + episode.url }
    var group: VodGroup
    var episode: Episode
}

struct TgBrowseView: View {
    var channel: TgChannel
    @State private var shows: [TgShow] = []
    @State private var page = 1
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?

    private let pageSize = 30
    private var pageCount: Int { max(1, (total + pageSize - 1) / pageSize) }

    var body: some View {
        VStack {
            if let error = error, shows.isEmpty {
                VStack(spacing: 12) {
                    Text(error).foregroundColor(.red)
                    Button("重试") { Task { await load(page: 1) } }
                }
                .padding()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
                        ForEach(shows) { s in
                            NavigationLink(destination: TgShowDetailView(show: s)) {
                                PosterCard(group: s.toGroup(base: ApiClient.shared.tgBase), width: 110)
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
        .task { await load(page: 1) }
    }

    private func load(page: Int) async {
        loading = true
        defer { loading = false }
        do {
            let (total, items) = try await ApiClient.shared.getTgShows(channel: channel.key, page: page, pageSize: pageSize)
            self.total = total
            self.page = page
            self.shows = items
            self.error = nil
        } catch {
            // 失败钉住原因、不闪回（TV 版 PyActivity/JarActivity/TgActivity 同款 UX）
            self.shows = []
            self.error = "加载失败：\(error.localizedDescription)"
        }
    }
}

/// 某剧选集页（TV 版 loadShow 的触屏版）：先拉选集表，点集进播放器，集间可上一集/下一集。
struct TgShowDetailView: View {
    var show: TgShow
    @State private var episodes: [TgVideo] = []
    @State private var loading = false
    @State private var error: String?
    @State private var playTarget: TgPlayTarget?

    var body: some View {
        VStack {
            if loading && episodes.isEmpty {
                ProgressView()
            } else if let error = error, episodes.isEmpty {
                VStack(spacing: 12) {
                    Text(error).foregroundColor(.red)
                    Button("重试") { Task { await load() } }
                }
                .padding()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                        ForEach(episodes) { ep in
                            Button {
                                playTarget = TgPlayTarget(group: playGroup(), episode: Episode(title: ep.episodeLabel(), url: ep.absUrl(ApiClient.shared.tgBase, ep.streamUrl)))
                            } label: {
                                Text(ep.episodeLabel())
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Color.blue.opacity(0.85))
                                    .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            if loading { ProgressView() }
        }
        .navigationTitle(show.name)
        .task { await load() }
        .fullScreenCover(item: $playTarget) { t in
            PlayerView(group: t.group, sourceIdx: 0, lineIdx: 0, startEpisode: t.episode,
                       sourceLabel: t.group.sources[0].sourceLabel, lineLabel: "")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let (_, eps) = try await ApiClient.shared.getTgShowDetail(showId: show.id)
            self.episodes = eps
            self.error = nil
        } catch {
            self.episodes = []
            self.error = "加载失败：\(error.localizedDescription)"
        }
    }

    /// 一剧成组：全部集放同一线路，播放器内可上一集/下一集（TV 版同款）。
    private func playGroup() -> VodGroup {
        let eps = episodes.map { v in
            Episode(title: v.episodeLabel(), url: v.absUrl(ApiClient.shared.tgBase, v.streamUrl))
        }
        let src = VodSource(sourceLabel: show.name, remarks: "共 \(episodes.count) 集", actor: "", director: "",
                            lines: [PlayLine(lineIndex: 1, episodes: eps, label: "")])
        return VodGroup(name: show.name, pic: "", typeName: "Telegram",
                        year: String(show.latest.prefix(4)), content: "", sources: [src])
    }
}
