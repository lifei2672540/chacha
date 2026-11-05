import AVFoundation
import SwiftUI
import UIKit

/// 全屏竖屏播放层：不走 AVPlayerViewController。竖屏视频直填全屏，
/// 横屏视频自动改完整显示（不裁切），按视频实际尺寸在可播时决定。
struct PlayerLayerView: UIViewRepresentable {
    var player: AVPlayer?
    var gravity: AVLayerVideoGravity
    func makeUIView(context: Context) -> PlayerUIView { PlayerUIView() }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.setPlayer(player)
        uiView.setGravity(gravity)
    }

    final class PlayerUIView: UIView {
        private let playerLayer = AVPlayerLayer()
        override init(frame: CGRect) {
            super.init(frame: frame)
            playerLayer.videoGravity = .resizeAspectFill
            self.layer.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer.frame = bounds
        }
        func setPlayer(_ p: AVPlayer?) { playerLayer.player = p }
        func setGravity(_ g: AVLayerVideoGravity) { playerLayer.videoGravity = g }
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
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var gravity: AVLayerVideoGravity = .resizeAspectFill
    var onEnded: (() -> Void)?

    private var item: AVPlayerItem?
    private var statusObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var timeObs: Any?
    private var watchdog: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var lastSave = Date.distantPast
    private var curEpId = ""
    private var curDrama: Drama?
    private var curSource: PySource?
    private var curLineIdx = 0
    private var curEpisode: DramaEpisode?
    private var savedRate: Float = 1
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
        duration = 0
        currentTime = 0
        isPlaying = false
        gravity = .resizeAspectFill
        ready = false
        curEpId = episode.id
        curDrama = drama
        curSource = source
        curLineIdx = lineIdx
        curEpisode = episode
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
            // 按视频实际尺寸定显示方式：竖屏直填，横屏完整显示不裁切
            let size = it.presentationSize
            if size.width > 0, size.height > 0 {
                gravity = size.height >= size.width ? .resizeAspectFill : .resizeAspect
            }
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
            duration = dur
            currentTime = cur
        }
        isPlaying = (player?.rate ?? 0) > 0
        if Date().timeIntervalSince(lastSave) >= 10 {
            lastSave = Date()
            Store.shared.saveProgress(epId: curEpId, time: cur)
            if let d = curDrama, let e = curEpisode {
                Store.shared.saveResume(drama: d, lineIdx: curLineIdx, episode: e, time: cur)
            }
        }
    }

    /// 快进/快退：拖动或点按进度条跳到指定位置；暂停时跳完仍暂停，播放中跳完继续播。
    func seek(to fraction: Double) {
        guard let p = player, let it = p.currentItem else { return }
        let dur = it.duration.seconds
        guard dur.isFinite && dur > 0 else { return }
        let f = min(max(fraction, 0), 1)
        let t = f * dur
        progress = f
        currentTime = t
        p.seek(to: CMTime(seconds: t, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
        Store.shared.saveProgress(epId: curEpId, time: t)
        if let d = curDrama, let e = curEpisode {
            Store.shared.saveResume(drama: d, lineIdx: curLineIdx, episode: e, time: t)
        }
    }

    /// 双击左右快进/快退固定秒数（到头或到尾就停住，不循环）。
    func seekBy(seconds: Double) {
        guard let p = player, let it = p.currentItem else { return }
        let dur = it.duration.seconds
        guard dur.isFinite && dur > 0 else { return }
        let t = min(max(p.currentTime().seconds + seconds, 0), dur)
        progress = t / dur
        currentTime = t
        p.seek(to: CMTime(seconds: t, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
        Store.shared.saveProgress(epId: curEpId, time: t)
        if let d = curDrama, let e = curEpisode {
            Store.shared.saveResume(drama: d, lineIdx: curLineIdx, episode: e, time: t)
        }
    }

    /// 长按 2 倍速：按住时记下当前速率（暂停就是 0），松开恢复原速率。
    func startFastForward() {
        guard let p = player else { return }
        savedRate = p.rate
        p.rate = 2
        isPlaying = true
    }
    func stopFastForward() {
        guard let p = player else { return }
        p.rate = savedRate
        isPlaying = savedRate > 0
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
            if let d = curDrama, let e = curEpisode {
                Store.shared.saveResume(drama: d, lineIdx: curLineIdx, episode: e, time: cur)
            }
        }
        player?.pause()
        player = nil
        item = nil
        ready = false
        curDrama = nil
        curSource = nil
        curEpisode = nil
    }
}
