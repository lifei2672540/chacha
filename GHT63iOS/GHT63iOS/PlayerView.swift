import SwiftUI
import AVKit
import Combine

/// 播放器（TV 版 PlayerActivity 的触屏版）：
/// AVPlayer 直播 HLS/MP4；断点取本地与云端的大者；每 10 秒存一次进度；
/// 播完自动下一集；失败先走流代理兜底，再自动换线路/换源；片头片尾、倍速按剧记忆。
@MainActor
final class PlayerModel: ObservableObject {
    let group: VodGroup
    @Published var currentEp: Episode
    @Published var currentSourceIdx: Int
    @Published var currentLineIdx: Int
    @Published var errorText: String?
    @Published var speed: Float = 1
    @Published var sleepText: String?
    @Published var notice: String?

    let player = AVPlayer()
    private var statusObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var timeObs: Any?
    private var saveAccumulator = 0.0
    private var proxyTried = false
    private var didSeekIntro = false
    private var sleepWork: DispatchWorkItem?
    private var cloud: [String: ProgressRec] = [:]
    private var started = false

    init(group: VodGroup, sourceIdx: Int, lineIdx: Int, startEpisode: Episode) {
        self.group = group
        self.currentSourceIdx = sourceIdx
        self.currentLineIdx = lineIdx
        self.currentEp = startEpisode
        self.speed = Store.shared.speed(for: group.name)
    }

    var isEmby: Bool { currentEp.url.hasPrefix("emby:") }
    private var currentLine: PlayLine? {
        group.sources.indices.contains(currentSourceIdx)
            ? group.sources[currentSourceIdx].lines.indices.contains(currentLineIdx)
                ? group.sources[currentSourceIdx].lines[currentLineIdx] : nil : nil
    }

    func start() async {
        guard !started else { return }
        started = true
        cloud = (try? await ApiClient.shared.getProgress()) ?? [:]
        buildPlay()
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.nextEpisode(auto: true) }
        }
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] t in
            Task { @MainActor in self?.tick(t.seconds) }
        }
    }

    private func resolveURL() -> URL? {
        if isEmby, let u = EmbyApi.streamUrl(group: group, episode: currentEp) {
            return URL(string: u)
        }
        var raw = currentEp.url
        if proxyTried { raw = ApiClient.shared.streamUrl(raw) }
        return URL(string: raw) ?? URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)
    }

    func buildPlay() {
        errorText = nil
        guard let url = resolveURL() else { errorText = "播放地址无效"; return }
        let item = AVPlayerItem(url: url)
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            if it.status == .failed {
                Task { @MainActor in self?.handleError() }
            }
        }
        player.replaceCurrentItem(with: item)
        // 断点：本地与云端取大者（TV 同款，>5 秒才续）
        let resume = Store.shared.resumeTime(for: currentEp.url, cloud: cloud)
        if resume > 0 {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 1))
        }
        player.rate = speed
        player.play()
        recordRecent()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        // 片头自动跳过（记过片头且当前位置在片头内时一次跳过）
        let (intro, outro) = Store.shared.introOutro(for: group.name)
        if !didSeekIntro, let intro = intro, seconds < intro {
            didSeekIntro = true
            player.seek(to: CMTime(seconds: intro, preferredTimescale: 1))
            return
        }
        if let outro = outro, seconds >= outro {
            nextEpisode(auto: true)
            return
        }
        saveAccumulator += 1
        if saveAccumulator >= 10 {
            saveAccumulator = 0
            saveNow(seconds: seconds)
        }
    }

    private func saveNow(seconds: Double) {
        let dur = player.currentItem?.duration.seconds ?? 0
        Store.shared.saveProgress(url: currentEp.url, time: seconds, duration: dur.isFinite ? dur : 0)
        Task { await ApiClient.shared.saveProgress(url: currentEp.url, time: seconds,
                                                   title: "\(group.name) - \(currentEp.title)", duration: dur.isFinite ? dur : 0) }
    }

    private func recordRecent() {
        let total = group.allEpisodes
        let idx = (currentLine?.episodes.firstIndex(of: currentEp) ?? 0) + 1
        Store.shared.recordRecent(RecentItem(drama: group.name, epTitle: currentEp.title, url: currentEp.url,
                                             pic: group.pic, time: 0, duration: 0, epIndex: idx, totalEps: total,
                                             updated: Date().timeIntervalSince1970))
    }

    private func handleError() {
        if !proxyTried && !isEmby {
            proxyTried = true
            notice = "直连失败，改走代理"
            buildPlay()
            return
        }
        if advance() {
            notice = "该线路播不了，已自动换线路"
            buildPlay()
        } else {
            errorText = "播放失败：换无可换"
        }
    }

    /// 下一集：同线路下一集 → 下一线路 → 下一源；都没有返回 false。
    @discardableResult
    func advance() -> Bool {
        guard let line = currentLine else { return false }
        if let i = line.episodes.firstIndex(of: currentEp), i + 1 < line.episodes.count {
            currentEp = line.episodes[i + 1]
            proxyTried = false
            didSeekIntro = false
            return true
        }
        let lines = group.sources[currentSourceIdx].lines
        if currentLineIdx + 1 < lines.count {
            currentLineIdx += 1
            if let ep = lines[currentLineIdx].episodes.first {
                currentEp = ep; proxyTried = false; didSeekIntro = false
                return true
            }
        }
        if currentSourceIdx + 1 < group.sources.count {
            currentSourceIdx += 1
            currentLineIdx = 0
            if let ep = group.sources[currentSourceIdx].lines.first?.episodes.first {
                currentEp = ep; proxyTried = false; didSeekIntro = false
                return true
            }
        }
        return false
    }

    func nextEpisode(auto: Bool) {
        saveNow(seconds: player.currentTime().seconds)
        if advance() {
            recordRecent()
            buildPlay()
        } else if auto {
            errorText = "已播完"
        }
    }

    func cycleSpeed() {
        let steps: [Float] = [0.5, 1, 1.25, 1.5, 2]
        let next = steps.first { $0 > speed } ?? 0.5
        speed = next
        player.rate = next
        Store.shared.saveSpeed(drama: group.name, speed: next)
    }

    func markIntro() {
        let t = player.currentTime().seconds
        let (_, outro) = Store.shared.introOutro(for: group.name)
        Store.shared.saveIntroOutro(drama: group.name, intro: t, outro: outro)
        notice = "已记片头 \(Int(t)) 秒"
    }

    func markOutroAndNext() {
        let t = player.currentTime().seconds
        let (intro, _) = Store.shared.introOutro(for: group.name)
        Store.shared.saveIntroOutro(drama: group.name, intro: intro, outro: t)
        notice = "已记片尾，下一集"
        nextEpisode(auto: false)
    }

    func setSleep(minutes: Int) {
        sleepWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.player.pause()
                self?.sleepText = nil
                self?.notice = "睡眠定时到，已暂停"
            }
        }
        sleepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(minutes * 60), execute: work)
        sleepText = "睡眠 \(minutes) 分钟"
    }

    func teardown() {
        saveNow(seconds: player.currentTime().seconds)
        if let t = timeObs { player.removeTimeObserver(t) }
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
        statusObs?.invalidate()
        sleepWork?.cancel()
        player.pause()
    }
}

struct PlayerView: View {
    var group: VodGroup
    var sourceIdx: Int
    var lineIdx: Int
    var startEpisode: Episode
    var sourceLabel: String
    var lineLabel: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: Store
    @StateObject private var model: PlayerModel

    init(group: VodGroup, sourceIdx: Int, lineIdx: Int, startEpisode: Episode, sourceLabel: String, lineLabel: String) {
        self.group = group
        self.sourceIdx = sourceIdx
        self.lineIdx = lineIdx
        self.startEpisode = startEpisode
        self.sourceLabel = sourceLabel
        self.lineLabel = lineLabel
        _model = StateObject(wrappedValue: PlayerModel(group: group, sourceIdx: sourceIdx, lineIdx: lineIdx, startEpisode: startEpisode))
    }

    var body: some View {
        ZStack {
            PlayerControllerView(player: model.player)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Button("关闭") { dismiss() }
                    Spacer()
                    Text("\(group.name) - \(model.currentEp.title)").lineLimit(1)
                    Spacer()
                    Button("下一集") { model.nextEpisode(auto: false) }
                }
                .padding()
                .background(Color.black.opacity(0.5))
                Spacer()
                VStack(spacing: 8) {
                    if let n = model.notice { Text(n).font(.caption).foregroundColor(.yellow) }
                    if let e = model.errorText {
                        Text(e).foregroundColor(.red)
                        Button("返回") { dismiss() }
                    }
                    HStack(spacing: 16) {
                        Button("换源") {
                            if model.advance() { model.buildPlay() }
                        }
                        Button("倍速 \(model.speed == 1 ? "1" : "\(model.speed)")x") { model.cycleSpeed() }
                        Button("记片头") { model.markIntro() }
                        Button("记片尾") { model.markOutroAndNext() }
                        Menu(model.sleepText ?? "睡眠定时") {
                            Button("15 分钟") { model.setSleep(minutes: 15) }
                            Button("30 分钟") { model.setSleep(minutes: 30) }
                            Button("60 分钟") { model.setSleep(minutes: 60) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding()
                .background(Color.black.opacity(0.5))
            }
            .foregroundColor(.white)
        }
        .task { await model.start() }
        .onDisappear { model.teardown() }
    }
}

private struct PlayerControllerView: UIViewControllerRepresentable {
    var player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        vc.player = player
    }
}
