import SwiftUI
import UIKit

// MARK: - 磁力页 ViewModel
//
// 种子只在本次启动内有效（会话在内存里，App 重启后须重新添加；见 INTEGRATION_NOTES）。
// 轮询：每 1 秒在后台线程刷一遍各种子状态，回主线程整表替换；
// 只覆盖仍在列表里的种子，中途删掉的不会被复活。

final class MagnetViewModel: ObservableObject {
    struct TorrentItem: Identifiable {
        var id: Int64
        var magnet: String
        var status: TorrentEngine.TorrentStatus?
        var files: [TorrentEngine.TorrentFile] = []
        var filesLoaded = false
        var streamId: Int64?
        var streamingFileIndex: Int32?
        var isStartingStream = false
        var streamError: String?
    }

    @Published var items: [TorrentItem] = []
    @Published var input = ""
    @Published var addError: String?
    @Published var showPlayer = false
    @Published var playGroup: VodGroup?
    @Published var playEpisode: Episode?

    private var timer: Timer?

    // MARK: 轮询

    func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func pollOnce() {
        let snapshot = items
        guard !snapshot.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var updated = snapshot
            for i in updated.indices {
                guard let st = TorrentEngine.shared.statusSync(for: updated[i].id) else { continue }
                updated[i].status = st
                if st.hasMetadata && !updated[i].filesLoaded {
                    updated[i].filesLoaded = true
                    updated[i].files = TorrentEngine.shared.filesSync(for: updated[i].id)
                        .filter { Self.isVideoFile($0.name) }
                        .sorted { $0.size > $1.size }
                }
            }
            let result = updated
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                var merged = self.items
                for u in result {
                    guard let idx = merged.firstIndex(where: { $0.id == u.id }) else { continue }
                    merged[idx].status = u.status
                    if u.filesLoaded {
                        merged[idx].files = u.files
                        merged[idx].filesLoaded = true
                    }
                }
                self.items = merged
            }
        }
    }

    // MARK: 添加 / 删除

    func pasteFromClipboard() {
        if let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            input = s
        }
    }

    func addCurrent() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.hasPrefix("magnet:?") else {
            addError = "不是磁力链接（应以 magnet:? 开头）"
            return
        }
        if items.contains(where: { $0.magnet == text }) {
            addError = "这个链接已经添加过了"
            return
        }
        addError = nil
        input = ""
        TorrentEngine.shared.addMagnet(text) { [weak self] id in
            guard let self = self else { return }
            if id < 0 {
                let reason = TorrentEngine.shared.lastError()
                self.addError = reason.isEmpty ? "添加失败" : "添加失败：\(reason)"
                return
            }
            self.items.append(TorrentItem(id: id, magnet: text))
        }
    }

    func remove(_ item: TorrentItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let streamId = items[idx].streamId
        let torrentId = item.id
        items.remove(at: idx)
        DispatchQueue.global(qos: .userInitiated).async {
            if let sid = streamId { TorrentEngine.shared.stopStreamSync(sid) }
            TorrentEngine.shared.removeTorrentSync(torrentId, deleteFiles: true)
        }
    }

    // MARK: 串流播放

    /// 点文件 -> 开流 -> 等流地址 READY -> 组一个单集直链 VodGroup 进播放器。
    /// 流地址是桥接层内建服务器的本地直链（http://127.0.0.1:端口/stream/...），
    /// 播放器走直连分支（非 PY/TG/海阔/Emby），无媒体后缀时会先嗅探，嗅不到直接播。
    func playFile(_ file: TorrentEngine.TorrentFile, in item: TorrentItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard !items[idx].isStartingStream else { return }
        let torrentId = item.id
        let fileIndex = file.index
        let fileName = file.name
        let oldStreamId = items[idx].streamId
        items[idx].isStartingStream = true
        items[idx].streamingFileIndex = file.index
        items[idx].streamError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            if let old = oldStreamId { TorrentEngine.shared.stopStreamSync(old) }
            let sid = TorrentEngine.shared.startStreamSync(torrentId: torrentId, fileIndex: fileIndex)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let idx = self.items.firstIndex(where: { $0.id == torrentId }) else { return }
                if sid < 0 {
                    self.items[idx].isStartingStream = false
                    let reason = TorrentEngine.shared.lastError()
                    self.items[idx].streamError = reason.isEmpty ? "串流失败" : "串流失败：\(reason)"
                    return
                }
                self.items[idx].streamId = sid
                TorrentEngine.shared.waitForStreamURL(streamId: sid) { [weak self] url in
                    guard let self = self, let idx = self.items.firstIndex(where: { $0.id == torrentId }) else { return }
                    self.items[idx].isStartingStream = false
                    guard let url = url else {
                        self.items[idx].streamError = "等流地址超时：种子没速度，或文件还没下到可播的部分"
                        return
                    }
                    let ep = Episode(title: fileName, url: url)
                    let src = VodSource(sourceLabel: "磁力", remarks: "", actor: "", director: "",
                                        lines: [PlayLine(lineIndex: 1, episodes: [ep], label: "")])
                    let name = self.items[idx].status?.name ?? fileName
                    self.playGroup = VodGroup(name: name, pic: "", typeName: "磁力", year: "",
                                              content: "", sources: [src])
                    self.playEpisode = ep
                    self.showPlayer = true
                }
            }
        }
    }

    // MARK: 工具

    /// 只列视频文件（按大小从大到小排）。rmvb 桥接层不标可播，但显式下标仍能开流，
    /// 播不播得了由播放器决定（AVPlayer 不支持 rmvb 会报错）。
    static func isVideoFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        for ext in ["mp4", "mkv", "avi", "mov", "rmvb", "webm", "m4v"] {
            if lower.hasSuffix("." + ext) { return true }
        }
        return false
    }

    static func fmtSize(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.0f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f KB", Double(bytes) / 1_000) }
        return "\(bytes) B"
    }

    static func fmtRate(_ bps: Int32) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f MB/s", Double(bps) / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f KB/s", Double(bps) / 1_000) }
        return "\(bps) B/s"
    }
}

// MARK: - 磁力页

struct MagnetView: View {
    @StateObject private var vm = MagnetViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("粘贴磁力链接，添加后等出文件列表，点文件就播。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            TextField("magnet:?xt=urn:btih:…", text: $vm.input)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                            Button("粘贴") { vm.pasteFromClipboard() }
                            Button("添加") { vm.addCurrent() }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .disabled(vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    if let err = vm.addError {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                    if vm.items.isEmpty {
                        Text("还没添加磁力链接。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ForEach(vm.items) { item in
                        MagnetTorrentRow(item: item,
                                         onPlay: { vm.playFile($0, in: item) },
                                         onRemove: { vm.remove(item) })
                    }
                    // 底部留空（1.4.7 教训：滚动页的留空必须写在滚动内容里）。
                    Color.clear.frame(height: 76)
                }
                .padding()
            }
            .navigationTitle("磁力")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { vm.startPolling() }
            .onDisappear { vm.stopPolling() }
            .fullScreenCover(isPresented: $vm.showPlayer) {
                if let g = vm.playGroup, let ep = vm.playEpisode {
                    PlayerView(group: g, sourceIdx: 0, lineIdx: 0, startEpisode: ep,
                               sourceLabel: "磁力", lineLabel: "在线播放")
                }
            }
        }
    }
}

// MARK: - 单个种子行

private struct MagnetTorrentRow: View {
    var item: MagnetViewModel.TorrentItem
    var onPlay: (TorrentEngine.TorrentFile) -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.status?.name ?? "正在获取信息…")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            if let st = item.status, st.totalWanted > 0 {
                ProgressView(value: Double(st.progress))
                    .tint(.red)
            }
            if let err = item.status?.errorMessage, !err.isEmpty {
                Text(err).font(.caption).foregroundColor(.red)
            }
            if let serr = item.streamError, !serr.isEmpty {
                Text(serr).font(.caption).foregroundColor(.red)
            }
            if item.isStartingStream {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("正在准备串流…").font(.caption).foregroundColor(.secondary)
                }
            }
            if item.filesLoaded {
                if item.files.isEmpty {
                    Text("没有可播的视频文件。").font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(item.files) { file in
                        Button {
                            onPlay(file)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(MagnetViewModel.fmtSize(file.size))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if item.isStartingStream && item.streamingFileIndex == file.index {
                                    ProgressView()
                                } else {
                                    Image(systemName: "play.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.title3)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            } else if item.status?.hasMetadata == true {
                Text("正在取文件列表…").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var statusLine: String {
        guard let st = item.status else { return "正在连接…" }
        var parts: [String] = [st.stateText]
        if st.state == TorrentEngine.stateDownloading || st.state == TorrentEngine.stateDownloadingMeta {
            parts.append("↓ \(MagnetViewModel.fmtRate(st.downloadRate))")
            parts.append("\(st.numPeers) 人")
            if st.totalWanted > 0 {
                parts.append("\(MagnetViewModel.fmtSize(st.totalDone)) / \(MagnetViewModel.fmtSize(st.totalWanted))")
            }
        } else if st.state == TorrentEngine.stateFinished || st.state == TorrentEngine.stateSeeding {
            parts.append("\(MagnetViewModel.fmtSize(st.totalWanted))")
            parts.append("\(st.numPeers) 人")
        }
        return parts.joined(separator: " · ")
    }
}
