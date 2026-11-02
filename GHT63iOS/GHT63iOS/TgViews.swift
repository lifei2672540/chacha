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
    @State private var videos: [TgVideo] = []
    @State private var page = 1
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var playTarget: TgPlayTarget?

    private let pageSize = 30
    private var pageCount: Int { max(1, (total + pageSize - 1) / pageSize) }

    var body: some View {
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
                            let g = v.toGroup(base: ApiClient.shared.tgBase)
                            Button {
                                playTarget = TgPlayTarget(group: g, episode: g.sources[0].lines[0].episodes[0])
                            } label: {
                                PosterCard(group: g, width: 110)
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
        .fullScreenCover(item: $playTarget) { t in
            PlayerView(group: t.group, sourceIdx: 0, lineIdx: 0, startEpisode: t.episode,
                       sourceLabel: t.group.sources[0].sourceLabel, lineLabel: "")
        }
    }

    private func load(page: Int) async {
        loading = true
        defer { loading = false }
        do {
            let (total, items) = try await ApiClient.shared.getTgFeed(channel: channel.key, page: page, pageSize: pageSize)
            self.total = total
            self.page = page
            self.videos = items
            self.error = nil
        } catch {
            // 失败钉住原因、不闪回（TV 版 PyActivity/JarActivity/TgActivity 同款 UX）
            self.videos = []
            self.error = "加载失败：\(error.localizedDescription)"
        }
    }
}
