import SwiftUI

/// 追剧清单页（网页版追剧清单弹窗同款）：四分组筛选项 + 每行状态下拉 +
/// 更新提示 + 立即检查；首页“我的追剧”标题点进来。
struct FollowListView: View {
    @EnvironmentObject var store: Store
    @State private var filter = "all"
    @State private var checking = false

    private var filtered: [FavItem] {
        filter == "all" ? store.favorites : store.favorites.filter { $0.status == filter }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 四分组 + 立即检查（网页版弹窗顶上一行同款）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([("all", "全部"), ("watching", "在追"), ("done", "已看完"), ("want", "想看")], id: \.0) { f in
                            Button(f.1) { filter = f.0 }
                                .buttonStyle(.borderedProminent).tint(filter == f.0 ? .red : .gray)
                        }
                        Button(checking ? "检查中…" : "🔄 立即检查") {
                            Task { await checkFavUpdates(force: true) }
                        }
                        .buttonStyle(.borderedProminent).tint(.gray)
                        .disabled(checking)
                    }
                    .padding(.horizontal)
                }
                if store.favorites.isEmpty {
                    Text("暂无追剧记录").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else if filtered.isEmpty {
                    Text("该分组暂无追剧").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else {
                    VStack(spacing: 10) {
                        ForEach(filtered) { fav in
                            FollowRow(fav: fav)
                        }
                    }
                    .padding(.horizontal)
                }
                // 底栏留空：直接写在滚动内容里（栈上的 safeAreaInset 进不了 ScrollView 的底边距，1.4.5）。
                Color.clear.frame(height: 76)
            }
            .padding(.vertical)
        }
        .navigationTitle("我的追剧")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: FavItem.self) { fav in FavDetailLoader(fav: fav) }
        .task { await checkFavUpdates() }
    }

    /// 更新巡检（网页版 checkFavUpdates 同款）：进清单页触发，1 小时节流，
    /// 3 路并发，按剧名精确匹配搜，只算同名组，最新集数取单条线路集数最大值。
    private func checkFavUpdates(force: Bool = false) async {
        guard !checking else { return }
        let now = Date().timeIntervalSince1970
        if !force, now - store.favCheckTs < 3600 { return }
        guard !store.favorites.isEmpty else { return }
        checking = true
        store.favCheckTs = now
        let disabled = (try? await ApiClient.shared.homeDisabled()) ?? []
        let favs = store.favorites
        let s = store
        var idx = 0
        while idx < favs.count {
            let chunk = Array(favs[idx..<min(idx + 3, favs.count)])
            await withTaskGroup(of: Void.self) { g in
                for fav in chunk {
                    g.addTask {
                        if let latest = await Self.latestEpisodes(for: fav.name, disabled: disabled) {
                            await MainActor.run { s.applyFavUpdate(name: fav.name, latest: latest) }
                        }
                    }
                }
            }
            idx += 3
        }
        checking = false
    }

    private static func latestEpisodes(for name: String, disabled: [String]) async -> Int? {
        guard let (groups, _, _) = try? await ApiClient.shared.search(wd: name, type: "", pg: 1, disabled: disabled) else { return nil }
        var latest = 0
        for g in groups where g.name == name { latest = max(latest, g.maxLineEpisodes) }
        return latest > 0 ? latest : nil
    }
}

private struct FollowRow: View {
    @EnvironmentObject var store: Store
    var fav: FavItem

    private var statusName: String {
        switch fav.status {
        case "done": return "已看完"
        case "want": return "想看"
        default: return "在追"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: fav) {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: fav.pic)) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Color.gray.opacity(0.3)
                        }
                    }
                    .frame(width: 42, height: 58).clipped().cornerRadius(4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fav.name).font(.subheadline.bold()).lineLimit(1)
                        Text(fav.lastEp.isEmpty ? "未开播" : "看至：\(fav.lastEp)")
                            .font(.caption).foregroundColor(.secondary)
                        if let u = store.favUpdates[fav.name], u.hasUpdate {
                            Text("🆕 已更新至 \(u.latest) 集").font(.caption).foregroundColor(.orange)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            Menu {
                Button("在追") { store.setFavStatus(name: fav.name, status: "watching") }
                Button("已看完") { store.setFavStatus(name: fav.name, status: "done") }
                Button("想看") { store.setFavStatus(name: fav.name, status: "want") }
            } label: {
                Text(statusName).font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white.opacity(0.1)).cornerRadius(6)
            }
            .buttonStyle(.plain)
            Button { store.removeFavorite(name: fav.name) } label: {
                Image(systemName: "xmark").foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.white.opacity(0.08))
        .cornerRadius(8)
    }
}

/// 追剧点开：按剧名搜回详情（最近观看 RecentDetailLoader 同款路子）。
private struct FavDetailLoader: View {
    var fav: FavItem
    @State private var group: VodGroup?
    @State private var error: String?
    var body: some View {
        Group {
            if let group = group {
                DetailView(group: group)
            } else if let error = error {
                Text(error).foregroundColor(.red)
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                let (groups, _, _) = try await ApiClient.shared.search(wd: fav.name, type: "", pg: 1)
                group = groups.first { $0.name == fav.name } ?? groups.first
                if group == nil { error = "源里没搜到这部" }
            } catch {
                self.error = "加载失败：\(error.localizedDescription)"
            }
        }
    }
}
