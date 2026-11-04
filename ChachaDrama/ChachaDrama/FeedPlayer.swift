import AVFoundation
import SwiftUI
import UIKit

/// 全屏竖屏播放层：AVPlayerLayer 直填（短剧全屏形态），不走 AVPlayerViewController。
struct PlayerLayerView: UIViewRepresentable {
    var player: AVPlayer?
    func makeUIView(context: Context) -> PlayerUIView { PlayerUIView() }
    func updateUIView(_ uiView: PlayerUIView, context: Context) { uiView.setPlayer(player) }

    final class PlayerUIView: UIView {
        private let layer = AVPlayerLayer()
        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.videoGravity = .resizeAspectFill
            self.layer.addSublayer(layer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.frame = bounds
        }
        func setPlayer(_ p: AVPlayer?) { layer.player = p }
    }
}

/// Feed 播放器：PY 解析 → AVPlayer，线路按顺序自动试，全部失败才报原因。
/// 看门狗 15 秒；播完回调 onEnded（Feed 切下一条）；进度每 10 秒存一次本机续播。
@MainActor
final class FeedPlayerModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var loading = false
    @Published var error: String?
    @Published var progress: Double = 0
    @Published var isPlaying = false
    var onEnded: (() -> Void)?

    private var item: AVPlayerItem?
    private var statusObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var timeObs: Any?
    private var watchdog: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var lastSave = Date.distantPast
    private var curEpId = ""
    private var ready = false

    func load(drama: Drama, lines: [DramaLine], lineIdx: Int, episode: DramaEpisode, source: PySource, resumeFrom: Double) {
        cleanup()
        guard !lines.isEmpty else {
            error = "该剧暂无播放线路"
            return
        }
        loading = true
        error = nil
        progress = 0
        isPlaying = false
        ready = false
        curEpId = episode.id
        resolveTask = Task { [weak self] in
            guard let self else { return }
            // 先试当前线路，之后按顺序试其余线路（不绕回，避免重复）
            let order = Array(lineIdx..<lines.count) + Array(0..<lineIdx)
            var lastErr = ""
            for li in order {
                if Task.isCancelled { return }
                let line = lines[li]
                do {
                    let (parse, url, headers) = try await PyAPI.play(source: source, flag: line.label, playId: episode.url)
                    if parse != 0 { lastErr = "线路 \(line.label.isEmpty ? "线路\(li + 1)" : line.label) 需解析服务"; continue }
                    if url.isEmpty { lastErr = "线路未返回地址"; continue }
                    guard let u = URL(string: url) else { lastErr = "地址无效"; continue }
                    self.buildItem(url: u, headers: headers, resumeFrom: resumeFrom)
                    return
                } catch {
                    lastErr = "\(error)"
                }
            }
            self.loading = false
            self.error = "所有线路都播不了：" + lastErr
            ErrorLog.append("播放失败 \(drama.name) 第\(episode.index + 1)集 \(lastErr)")
        }
    }

    private func buildItem(url: URL, headers: [String: String], resumeFrom: Double) {
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let it = AVPlayerItem(asset: asset)
        item = it
        let p = AVPlayer(playerItem: it)
        player = p
        statusObs = it.observe(\.status, options: [.new]) { [weak self] it, _ in
            Task { @MainActor in self?.handleStatus(it, resumeFrom: resumeFrom) }
        }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: it, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleEnded() }
        }
        timeObs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time: time) }
        }
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled, !self.ready else { return }
            self.loading = false
            self.error = "加载超时 15s"
            self.player?.pause()
            self.isPlaying = false
        }
    }

    private func handleStatus(_ it: AVPlayerItem, resumeFrom: Double) {
        guard it == item else { return }
        switch it.status {
        case .readyToPlay:
            ready = true
            watchdog?.cancel()
            loading = false
            if resumeFrom > 5,
               let dur = player?.currentItem?.duration.seconds, dur.isFinite,
               resumeFrom < dur - 10 {
                player?.seek(to: CMTime(seconds: resumeFrom, preferredTimescale: 600))
            }
            player?.play()
            isPlaying = true
        case .failed:
            loading = false
            error = "播放器失败：" + (it.error?.localizedDescription ?? "未知错误")
        default:
            break
        }
    }

    private func tick(time: CMTime) {
        guard let it = player?.currentItem else { return }
        let dur = it.duration.seconds
        let cur = time.seconds
        if dur.isFinite && dur > 0 {
            progress = min(max(cur / dur, 0), 1)
        }
        isPlaying = (player?.rate ?? 0) > 0
        if Date().timeIntervalSince(lastSave) >= 10 {
            lastSave = Date()
            Store.shared.saveProgress(epId: curEpId, time: cur)
        }
    }

    private func handleEnded() {
        isPlaying = false
        onEnded?()
    }

    func togglePlay() {
        guard let p = player else { return }
        if p.rate > 0 {
            p.pause()
            isPlaying = false
        } else {
            p.play()
            isPlaying = true
        }
    }

    func cleanup() {
        resolveTask?.cancel()
        resolveTask = nil
        watchdog?.cancel()
        watchdog = nil
        statusObs?.invalidate()
        statusObs = nil
        if let o = endObs {
            NotificationCenter.default.removeObserver(o)
            endObs = nil
        }
        if let t = timeObs {
            player?.removeTimeObserver(t)
            timeObs = nil
        }
        if !curEpId.isEmpty, let cur = player?.currentTime().seconds, cur > 0 {
            Store.shared.saveProgress(epId: curEpId, time: cur)
        }
        player?.pause()
        player = nil
        item = nil
        ready = false
    }
}
