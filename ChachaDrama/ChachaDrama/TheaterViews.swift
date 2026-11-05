import SwiftUI

/// 剧场：源列表 → 本站首页/分类/搜索/翻页，点剧跳回首页 Feed。
struct TheaterView: View {
    @ObservedObject var vm: FeedViewModel
    @Binding var tabSelection: Int
    @State private var sources: [PySource] = []
    @State private var selSource: PySource?
    @State private var classes: [PyClass] = []
    @State private var selCat = ""
    @State private var items: [Drama] = []
    @State private var pg = 1
    @State private var pagecount = 1
    @State private var searchText = ""
    @State private var searching = false
    @State private var loading = false
    @State private var error: String?
    @State private var showSourceSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("本站搜索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                Button("搜索") { Task { await doSearch() } }
            }
            .padding()
            HStack(spacing: 12) {
                Button(action: { showSourceSheet = true }) {
                    HStack(spacing: 4) {
                        Text(selSource?.displayName ?? "选源")
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                Button("用这个源刷首页") {
                    if let s = selSource {
                        Task {
                            do {
                                try await vm.loadHome(source: s)
                                Store.shared.markSourceOK(s.api)
                            } catch {
                                Store.shared.markSourceFailed(s.api)
                            }
                            tabSelection = 0
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                Spacer()
                if loading { ProgressView() }
            }
            .padding(.horizontal)
            if !classes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("全部") { Task { await pickCat("") } }
                            .buttonStyle(.bordered)
                            .tint(selCat.isEmpty ? .orange : .gray)
                        ForEach(classes) { c in
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
                            Button {
                                vm.jumpTo(drama: d, source: d.source, inList: items)
                                tabSelection = 0
                            } label: {
                                DramaCard(drama: d)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    if !searching && pg < pagecount {
                        Button("加载更多") { Task { await loadMore() } }
                            .buttonStyle(.bordered)
                            .padding(.bottom)
                    }
                }
            }
            if let error = error, !items.isEmpty {
                Text(error).font(.caption).foregroundColor(.red).padding(.horizontal)
            }
            Text("PY 源跑在本机内嵌 Python 上（纯 Python 子集）；CMS 源直接拉站；要 Crypto/lxml 的源会显示原因，不闪退。")
                .font(.caption2).foregroundColor(.gray).padding()
        }
        .navigationTitle("剧场")
        .sheet(isPresented: $showSourceSheet) {
            SourcePickerSheet(sources: sources, selSource: selSource) { s in
                selSource = s
                Task { await loadTheaterHome() }
            }
        }
        .task {
            // 每次进剧场都重拉订阅：接口里新加的 PY 源不用杀 App 就能出现。
            // 已选源还在就保持不动；已被接口删掉才回落到新列表的第一个源。
            await loadSubscription()
        }
    }

    private func loadSubscription() async {
        loading = true
        defer { loading = false }
        do {
            sources = try await PyAPI.subscription(url: Store.shared.subURL)
            if let cur = selSource {
                if let match = sources.first(where: { $0.api == cur.api }) {
                    selSource = match
                } else {
                    selSource = sources.first
                    classes = []
                    items = []
                    pg = 1
                    pagecount = 1
                    if selSource != nil { await loadTheaterHome() }
                }
            } else if let first = sources.first {
                selSource = first
                await loadTheaterHome()
            }
            error = nil
        } catch {
            self.error = "订阅加载失败：\(error)"
        }
    }

    private func loadTheaterHome() async {
        guard let s = selSource else { return }
        selCat = ""
        searching = false
        searchText = ""
        pg = 1
        loading = true
        defer { loading = false }
        do {
            let (cls, list) = try await PyAPI.home(source: s)
            Store.shared.markSourceOK(s.api)
            classes = cls
            items = list
            pagecount = 1
            error = nil
        } catch {
            Store.shared.markSourceFailed(s.api)
            self.error = "源加载失败：\(error)"
        }
    }

    private func pickCat(_ id: String) async {
        selCat = id
        searching = false
        searchText = ""
        pg = 1
        loading = true
        defer { loading = false }
        do {
            guard let s = selSource else { return }
            if id.isEmpty {
                let (_, list) = try await PyAPI.home(source: s)
                items = list
                pagecount = 1
            } else {
                let (list, pc) = try await PyAPI.category(source: s, tid: id, pg: 1)
                items = list
                pagecount = pc
            }
            error = nil
        } catch {
            self.error = "分类加载失败：\(error)"
        }
    }

    private func loadMore() async {
        guard let s = selSource, !searching, pg < pagecount else { return }
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

    private func doSearch() async {
        guard let s = selSource else { return }
        let wd = searchText.trimmingCharacters(in: .whitespaces)
        guard !wd.isEmpty else { return }
        searching = true
        loading = true
        defer { loading = false }
        do {
            items = try await PyAPI.search(source: s, wd: wd)
            pagecount = 1
            error = nil
        } catch {
            self.error = "搜索失败：\(error)"
        }
    }
}

struct SourcePickerSheet: View {
    var sources: [PySource]
    var selSource: PySource?
    var onPick: (PySource) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("过滤源名", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .padding()
                List {
                    ForEach(filtered) { s in
                        Button {
                            onPick(s)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                // 源健康：绿=最近成功过，红=最近一次失败，灰=还没试过（由首页/剧场/自检实际跑过后才记）。
                                Circle()
                                    .fill(healthColor(for: s))
                                    .frame(width: 8, height: 8)
                                Text(s.displayName).foregroundColor(.white)
                                Text(s.isCMS ? "CMS" : "PY")
                                    .font(.caption2).foregroundColor(.gray)
                                Spacer()
                                if s.id == selSource?.id {
                                    Image(systemName: "checkmark").foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("选源（\(sources.count) 个）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var filtered: [PySource] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return sources }
        return sources.filter { $0.displayName.contains(f) || $0.name.contains(f) }
    }

    private func healthColor(for s: PySource) -> Color {
        switch Store.shared.sourceHealth(s.api) {
        case .ok: return .green
        case .failed: return .red
        case .unknown: return .gray
        }
    }
}
