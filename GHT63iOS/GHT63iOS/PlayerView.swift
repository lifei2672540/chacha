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
    private var watchdog: Task<Void, Never>?
    private var pyTask: Task<Void, Never>?

    init(group: VodGroup, sourceIdx: Int, lineIdx: Int, startEpisode: Episode) {
        self.group = group
        self.currentSourceIdx = sourceIdx
        self.currentLineIdx = lineIdx
        self.currentEp = startEpisode
        self.speed = Store.shared.speed(for: group.name)
        ErrorLog.append("播放器创建 \(group.name) - \(startEpisode.title)")
    }

    var isEmby: Bool { currentEp.url.hasPrefix("emby:") }
    /// PY 组：pyApi 非空即走 playerContent 解析，不走 CMS 直链、不走流代理。
    var isPY: Bool { !group.pyApi.isEmpty }
    private var currentLine: PlayLine? {
        group.sources.indices.contains(currentSourceIdx)
            ? group.sources[currentSourceIdx].lines.indices.contains(currentLineIdx)
                ? group.sources[currentSourceIdx].lines[currentLineIdx] : nil : nil
    }

    func start() async {
        guard !started else { return }
        started = true
        // 云端进度最多等 8 秒，超时直接播，不让播放卡在黑屏上等网络
        cloud = await withTaskGroup(of: [String: ProgressRec]?.self) { group in
            group.addTask { try? await ApiClient.shared.getProgress() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? [:]
        }
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
        watchdog?.cancel()
        if isPY {
            pyTask?.cancel()
            pyTask = Task { await buildPlayPY() }
            return
        }
        guard !currentEp.url.isEmpty, let url = resolveURL() else {
            errorText = "播放地址为空"
            ErrorLog.append("播不了：地址为空 \(group.name) - \(currentEp.title) 源\(currentSourceIdx) 线\(currentLineIdx)")
            return
        }
        ErrorLog.append("播放 \(group.name) - \(currentEp.title) 源\(currentSourceIdx) 线\(currentLineIdx) \(url.absoluteString)")
        playURL(url, headers: nil)
    }

    /// PY：按当前线路 pyFlag + 集 url（播放 id）调 playerContent；parse!=0 或空地址 = 换线路。
    private func buildPlayPY() async {
        guard !currentEp.url.isEmpty else {
            errorText = "播放地址为空"
            ErrorLog.append("PY播不了：地址为空 \(group.name) - \(currentEp.title) 线\(currentLineIdx)")
            return
        }
        let flag = currentLine?.pyFlag ?? ""
        let src = PySource(name: "", api: group.pyApi, ext: group.pyExt)
        do {
            let r = try await PyAPI.play(source: src, flag: flag, playId: currentEp.url)
            guard !Task.isCancelled else { return }
            if r.parse != 0 || r.url.isEmpty {
                ErrorLog.append("PY解析换线路 parse=\(r.parse) \(group.name) - \(currentEp.title) 线\(currentLineIdx)")
                if pyAdvance() { buildPlay() } else { errorText = "该源播不了：解析无结果" }
                return
            }
            guard let url = URL(string: r.url) ?? URL(string: r.url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? r.url) else {
                if pyAdvance() { buildPlay() } else { errorText = "该源播不了：地址无效" }
                return
            }
            ErrorLog.append("PY播放 \(group.name) - \(currentEp.title) 源\(currentSourceIdx) 线\(currentLineIdx) \(url.absoluteString)")
            playURL(url, headers: r.headers)
        } catch {
            guard !Task.isCancelled else { return }
            ErrorLog.append("PY解析失败 \(group.name) - \(currentEp.title) 线\(currentLineIdx)：\(error)")
            if pyAdvance() { buildPlay() } else { errorText = "PY解析失败：\(String("\(error)").prefix(120))" }
        }
    }

    /// 播真实地址：PY 的防盗链头（Referer/UA）走 AVURLAsset 选项带上。
    private func playURL(_ url: URL, headers: [String: String]?) {
        let item: AVPlayerItem
        if let headers = headers, !headers.isEmpty {
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            item = AVPlayerItem(asset: asset)
        } else {
            item = AVPlayerItem(url: url)
        }
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            if it.status == .failed {
                Task { @MainActor in self?.handleError() }
            } else if it.status == .readyToPlay {
                Task { @MainActor in self?.watchdog?.cancel() }
            }
        }
        player.replaceCurrentItem(with: item)
        // 看门狗：15 秒还不出画面就按失败处理（走代理/换线路/报错），不许静默黑屏
        watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            if player.currentItem?.status != .readyToPlay {
                ErrorLog.append("加载超时 15s \(group.name) - \(currentEp.title)")
                handleError()
            }
        }
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
                                             updated: Date().timeIntervalSince1970,
                                             pyApi: group.pyApi, pyFlag: currentLine?.pyFlag ?? "", pyExt: group.pyExt))
    }

    private func handleError() {
        // PY 不走流代理（TV 同款），失败直接换线路
        if !proxyTried && !isEmby && !isPY {
            proxyTried = true
            notice = "直连失败，改走代理"
            ErrorLog.append("播放失败走代理 \(group.name) - \(currentEp.title)")
            buildPlay()
            return
        }
        let moved = isPY ? pyAdvance() : advance()
        if moved {
            notice = "该线路播不了，已自动换线路"
            ErrorLog.append("换线路 \(group.name) - \(currentEp.title) → 源\(currentSourceIdx) 线\(currentLineIdx)")
            buildPlay()
        } else {
            errorText = "播放失败：换无可换"
            ErrorLog.append("播放失败换无可换 \(group.name) - \(currentEp.title)")
        }
    }

    /// PY 解析/播放失败时换线路：同集在下一线路 → 下一源同集（越界取首集）；都没有返回 false。
    private func pyAdvance() -> Bool {
        guard let line = currentLine else { return false }
        let epIdx = line.episodes.firstIndex(of: currentEp) ?? 0
        let lines = group.sources[currentSourceIdx].lines
        if currentLineIdx + 1 < lines.count {
            let next = lines[currentLineIdx + 1]
            let ep = next.episodes.indices.contains(epIdx) ? next.episodes[epIdx] : next.episodes.first
            if let ep = ep {
                currentLineIdx += 1
                currentEp = ep; proxyTried = false; didSeekIntro = false
                return true
            }
        }
        if currentSourceIdx + 1 < group.sources.count {
            currentSourceIdx += 1
            currentLineIdx = 0
            if let first = group.sources[currentSourceIdx].lines.first {
                let ep = first.episodes.indices.contains(epIdx) ? first.episodes[epIdx] : first.episodes.first
                if let ep = ep {
                    currentEp = ep; proxyTried = false; didSeekIntro = false
                    return true
                }
            }
        }
        return false
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
        watchdog?.cancel()
        pyTask?.cancel()
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
        // 绝不自动进系统全屏：全屏后自家关闭按钮和报错文字全没了，播不了就是纯黑屏
        vc.entersFullScreenWhenPlaybackBegins = false
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        vc.player = player
    }
}
