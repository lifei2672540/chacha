import SwiftUI
import AVKit
import Combine
import UIKit

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
    @Published var cacheProgress: Double?
    @Published var cacheMB: Int = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying: Bool = false
    /// 画面模式：适应（完整显示）/ 填充（裁切铺满），AVPlayerViewController 直接吃。
    @Published var videoGravity: AVLayerVideoGravity = .resizeAspect

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
    private var sniffTask: Task<Void, Never>?
    private var tgLoader: TGResourceLoader?

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
    /// Telegram 组：流地址以采集端地址开头，本身就是直连地址，不走 GHT63 流代理
    /// （代理取不到局域网地址；TV 版 PlayerActivity.isTg 同款）。
    var isTG: Bool { currentEp.url.hasPrefix(ApiClient.shared.tgBaseUrl) }
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
        cacheProgress = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        watchdog?.cancel()
        sniffTask?.cancel()
        if isPY {
            pyTask?.cancel()
            pyTask = Task { await buildPlayPY() }
            return
        }
        if isTG {
            buildPlayTG()
            return
        }
        // 直连且地址无媒体后缀时先嗅探（TV 版 PlayerActivity 同款）：
        // 金鹰这类源的首线路常给网页播放页（hd.kuktxu.com/play/xxx），直接喂给 AVPlayer
        // 只会 -11828 报错；嗅到 text/html 就同集切下一线路（第 2 线路就是同地址 + /index.m3u8）。
        // 代理地址不嗅探（流代理会把所有内容都标成 m3u8），Emby 地址是本机伪地址也不嗅探。
        if !isEmby, !proxyTried, !currentEp.url.isEmpty, needsSniff(currentEp.url) {
            let url = currentEp.url
            sniffTask = Task { [weak self] in
                let res = await self?.sniffUrl(url)
                guard let self, !Task.isCancelled, self.currentEp.url == url else { return }
                if res == "html" {
                    if self.nextLine() {
                        self.notice = "该线路是网页，已自动切到下一线路"
                        ErrorLog.append("网页线路自动切线 \(self.group.name) - \(self.currentEp.title) → 源\(self.currentSourceIdx) 线\(self.currentLineIdx)")
                        self.buildPlay()
                    } else {
                        self.errorText = "播放失败：换无可换"
                        ErrorLog.append("播放失败换无可换 \(self.group.name) - \(self.currentEp.title)")
                    }
                } else {
                    self.playDirect()
                }
            }
            return
        }
        playDirect()
    }

    /// CMS 直连/代理的起播（嗅探通过或无需嗅探时走这里）。
    private func playDirect() {
        guard !currentEp.url.isEmpty, let url = resolveURL() else {
            errorText = "播放地址为空"
            ErrorLog.append("播不了：地址为空 \(group.name) - \(currentEp.title) 源\(currentSourceIdx) 线\(currentLineIdx)")
            return
        }
        ErrorLog.append("播放 \(group.name) - \(currentEp.title) 源\(currentSourceIdx) 线\(currentLineIdx) \(url.absoluteString)")
        playURL(url, headers: nil)
    }

    /// TG 边下边播：1.2.6 的先下载完再播能播，但长视频要等整部下完。
    /// 改走 AVAssetResourceLoaderDelegate：播放器要哪段，App 就去采集端取哪段
    /// （分片 + 失败重试 + 落盘缓存）喂给它；网卡了只暂停缓冲，不断线。
    /// 1.2.6 下好的整文件直接复用，不重下。
    private func buildPlayTG() {
        guard !currentEp.url.isEmpty, let url = resolveURL() else {
            errorText = "播放地址为空"
            return
        }
        let final = TGCache.finalFile(for: url.absoluteString)
        if FileManager.default.fileExists(atPath: final.path),
           ((try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? Int) ?? 0) > 0 {
            ErrorLog.append("TG读缓存 \(group.name) - \(currentEp.title)")
            cacheProgress = nil
            playURL(final, headers: nil)
            return
        }
        cacheProgress = 0
        cacheMB = 0
        ErrorLog.append("TG边下边播 \(group.name) - \(currentEp.title)")
        let loader = TGResourceLoader(remote: url, onProgress: { [weak self] done, total in
            self?.cacheMB = done / 1_000_000
            self?.cacheProgress = total > 0 ? Double(done) / Double(total) : -1
        })
        tgLoader = loader
        // 自定义 scheme，强制全部请求走 delegate，不让 AVPlayer 自己直连采集端
        let assetURL = URL(string: "tgcache://\(TGCache.fileName(for: url.absoluteString))")!
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(loader, queue: TGResourceLoader.queue)
        playItem(AVPlayerItem(asset: asset))
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
        playItem(item)
    }

    /// 接管一个已建好的 AVPlayerItem（直链、PY 解析地址、TG 边下边播共用后半段）。
    private func playItem(_ item: AVPlayerItem) {
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            if it.status == .failed {
                let err = String(describing: it.error)
                Task { @MainActor in
                    ErrorLog.append("播放器失败 \(self?.group.name ?? "") - \(self?.currentEp.title ?? "") err=\(err)")
                    self?.handleError()
                }
            } else if it.status == .readyToPlay {
                Task { @MainActor in
                    self?.watchdog?.cancel()
                    let d = it.duration.seconds
                    if d.isFinite { self?.duration = d }
                }
            }
        }
        player.replaceCurrentItem(with: item)
        // TG：采集端取流慢，AVPlayer 默认会等缓冲够了再播，结果就是首帧出来后一直卡着
        // （出帧后看门狗已撤，之后再无报错，只会静默卡住）。仅 TG 不等缓冲，有数据先动起来。
        if isTG {
            player.automaticallyWaitsToMinimizeStalling = false
            ErrorLog.append("TG 不等缓冲起播 \(group.name) - \(currentEp.title)")
        }
        // 看门狗：还不出画面就按失败处理（走代理/换线路/报错），不许静默黑屏。
        // TG 流要经采集端现从 Telegram 取文件（探头 + 尾部 moov 两次慢取），15 秒不够，
        // 仅 TG 放宽到 60 秒，其余源保持 15 秒。
        let timeoutSec: UInt64 = isTG ? 60 : 15
        watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: timeoutSec * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if player.currentItem?.status != .readyToPlay {
                ErrorLog.append("加载超时 \(timeoutSec)s \(group.name) - \(currentEp.title)")
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
        // 进度条与播放状态：每秒同步一次（暂停时 rate 为 0，控制条就一直留着）。
        currentTime = seconds
        if let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
        isPlaying = player.rate > 0
        // 缓冲提示只在卡住时留着；播起来了就撤掉（卡住时 rate 为 0，提示继续留着）
        if cacheProgress != nil && player.rate > 0 { cacheProgress = nil }
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
        // PY/Telegram 不走流代理（TV 同款），失败直接换线路
        if !proxyTried && !isEmby && !isPY && !isTG {
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

    /// 地址无媒体后缀时才嗅探（TV 版 needsSniff 同款）。
    private func needsSniff(_ url: String) -> Bool {
        let path = url.components(separatedBy: "?").first?.components(separatedBy: "#").first?.lowercased() ?? ""
        let mediaExt = [".m3u8", ".mp4", ".mkv", ".flv", ".mov", ".ts", ".m4v",
                        ".avi", ".wmv", ".mpg", ".mpeg", ".webm", ".m4a", ".mp3"]
        return !mediaExt.contains { path.hasSuffix($0) }
    }

    /// 只读响应头就关流，不下载正文（TV 版 sniffUrl 同款）：
    /// 返回 "html"（网页播放页，播不了）、"m3u8"（已确认的流类型）、nil（未知/嗅探失败，照常播）。
    /// HEAD 优先，个别站不支持 HEAD 时改 Range GET 首字节。
    private func sniffUrl(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 8
        let session = URLSession(configuration: cfg)
        func classify(_ ct: String?) -> String? {
            guard let ct = ct?.lowercased() else { return nil }
            if ct.contains("text/html") { return "html" }
            if ct.contains("mpegurl") || ct.contains("x-mpegurl") { return "m3u8" }
            return nil
        }
        var head = URLRequest(url: url, timeoutInterval: 8)
        head.httpMethod = "HEAD"
        head.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let (_, resp) = try? await session.data(for: head),
           let http = resp as? HTTPURLResponse,
           let r = classify(http.value(forHTTPHeaderField: "Content-Type")) { return r }
        var range = URLRequest(url: url, timeoutInterval: 8)
        range.setValue(ua, forHTTPHeaderField: "User-Agent")
        range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let (_, resp) = try? await session.data(for: range),
           let http = resp as? HTTPURLResponse {
            return classify(http.value(forHTTPHeaderField: "Content-Type"))
        }
        return nil
    }

    /// 换源（TV 版 advanceForHtml 同款）：同源下一线路（同集序号），
    /// 否则下一源的首线路；无路可走返回 false。注意与 advance() 不同：这里不跳集，
    /// 只换线路——网页线路的同集在下一线路往往就是能播的直链。
    func nextLine() -> Bool {
        let lines = group.sources.indices.contains(currentSourceIdx) ? group.sources[currentSourceIdx].lines : []
        let epIdx = lines.indices.contains(currentLineIdx) ? (lines[currentLineIdx].episodes.firstIndex(of: currentEp) ?? 0) : 0
        var nextLine = currentLineIdx + 1
        while nextLine < lines.count {
            let eps = lines[nextLine].episodes
            if !eps.isEmpty {
                currentLineIdx = nextLine
                currentEp = eps.indices.contains(epIdx) ? eps[epIdx] : eps[0]
                proxyTried = false; didSeekIntro = false
                return true
            }
            nextLine += 1
        }
        var nextSrc = currentSourceIdx + 1
        while nextSrc < group.sources.count {
            if let eps = group.sources[nextSrc].lines.first?.episodes, !eps.isEmpty {
                currentSourceIdx = nextSrc
                currentLineIdx = 0
                currentEp = eps.indices.contains(epIdx) ? eps[epIdx] : eps[0]
                proxyTried = false; didSeekIntro = false
                return true
            }
            nextSrc += 1
        }
        return false
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

    func togglePlay() {
        if player.rate > 0 { player.pause(); isPlaying = false } else { player.play(); isPlaying = true }
    }

    /// 进度条拖拽：拖到哪播到哪（茶茶短剧同款，松手才真正跳，拖动时只改显示）。
    func seek(to fraction: Double) {
        guard let it = player.currentItem else { return }
        let dur = it.duration.seconds
        guard dur.isFinite && dur > 0 else { return }
        let f = min(max(fraction, 0), 1)
        let t = f * dur
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        saveNow(seconds: t)
    }

    /// 画面模式：适应（完整显示，不裁切）/ 填充（裁切铺满）来回切。
    func cycleGravity() {
        videoGravity = videoGravity == .resizeAspect ? .resizeAspectFill : .resizeAspect
    }

    /// 选集：同源同线路换集。
    func jumpToEpisode(_ ep: Episode) {
        currentEp = ep
        proxyTried = false; didSeekIntro = false
        buildPlay()
    }

    /// 线路表：同集切到指定源/线路（序号越界取首集）。
    func switchLine(sourceIdx: Int, lineIdx: Int) {
        guard group.sources.indices.contains(sourceIdx),
              group.sources[sourceIdx].lines.indices.contains(lineIdx) else { return }
        let eps = group.sources[sourceIdx].lines[lineIdx].episodes
        guard !eps.isEmpty else { return }
        let idx = group.sources[currentSourceIdx].lines.indices.contains(currentLineIdx)
            ? (group.sources[currentSourceIdx].lines[currentLineIdx].episodes.firstIndex(of: currentEp) ?? 0) : 0
        currentSourceIdx = sourceIdx
        currentLineIdx = lineIdx
        currentEp = eps.indices.contains(idx) ? eps[idx] : eps[0]
        proxyTried = false; didSeekIntro = false
        buildPlay()
    }

    func cancelSleep() {
        sleepWork?.cancel()
        sleepWork = nil
        sleepText = nil
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
        sniffTask?.cancel()
        pyTask?.cancel()
        tgLoader?.cancelAll()
        tgLoader = nil
        saveNow(seconds: player.currentTime().seconds)
        if let t = timeObs { player.removeTimeObserver(t) }
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
        statusObs?.invalidate()
        sleepWork?.cancel()
        player.pause()
    }
}

/// TG 流本地缓存：分片下载（2MB 一片）+ 断点续传，失败重试，完工后落盘，超 2GB 清最旧。
/// 未完成的文件留 .part 续传，完工的文件才改名进缓存，缓存文件恒为完整文件。
enum TGCache {
    static let segment = 2 * 1024 * 1024
    static let cap: Int64 = 2_000_000_000

    static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TGCache")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func fileName(for urlString: String) -> String {
        let raw = urlString.components(separatedBy: "/stream/").last ?? urlString
        let kept = raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" }
        return String(kept.prefix(64)) + ".mp4"
    }

    static func finalFile(for urlString: String) -> URL { dir.appendingPathComponent(fileName(for: urlString)) }
    static func partFile(for urlString: String) -> URL { dir.appendingPathComponent(fileName(for: urlString) + ".part") }
    static func sidecarFile(for urlString: String) -> URL { dir.appendingPathComponent(fileName(for: urlString) + ".ranges.json") }

    static func prune(except keep: URL) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        var total: Int64 = 0
        var items: [(URL, Date, Int64)] = []
        for f in files {
            guard f != keep, !f.path.hasSuffix(".part") else { continue }
            let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            total += Int64(v?.fileSize ?? 0)
            items.append((f, v?.contentModificationDate ?? .distantPast, Int64(v?.fileSize ?? 0)))
        }
        guard total > cap else { return }
        for (f, _, size) in items.sorted(by: { $0.1 < $1.1 }) {
            if total <= cap { break }
            try? fm.removeItem(at: f)
            total -= size
        }
    }
}

/// TG 边下边播的字节源：播放器要哪段就从采集端取哪段（2MB 分片、失败重试），
/// 取回的段按偏移写进同一个 .part 文件并记区间；下完改名进缓存，1.2.6 下好的整文件直接复用。
/// actor 保证区间表与文件写互不交错；同段重复取只会写进相同字节，不会写坏。
/// final 已存在时不再写 part（整文件恒为完整文件），读优先走 final。
actor TGProgressiveStore {
    let remote: URL
    let finalURL: URL
    let partURL: URL
    let sidecarURL: URL
    private var intervals: [Range<Int>] = []
    private var total: Int = -1
    private var onProgress: (@MainActor (Int, Int) -> Void)?
    private let session: URLSession

    init(remote: URL, onProgress: (@MainActor (Int, Int) -> Void)?) {
        self.remote = remote
        self.finalURL = TGCache.finalFile(for: remote.absoluteString)
        self.partURL = TGCache.partFile(for: remote.absoluteString)
        self.sidecarURL = TGCache.sidecarFile(for: remote.absoluteString)
        self.onProgress = onProgress
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: cfg)
        let fm = FileManager.default
        if fm.fileExists(atPath: finalURL.path) {
            // 整文件已在，残留的 .part 与区间表一律作废
            try? fm.removeItem(at: partURL)
            try? fm.removeItem(at: sidecarURL)
        } else if let data = try? Data(contentsOf: sidecarURL),
                  let pairs = try? JSONDecoder().decode([[Int]].self, from: data) {
            intervals = pairs.compactMap { $0.count == 2 && $0[0] < $0[1] ? $0[0]..<$0[1] : nil }.sorted { $0.lowerBound < $1.lowerBound }
        } else if let size = (try? fm.attributesOfItem(atPath: partURL.path)[.size] as? Int), size > 0 {
            // 无区间表：1.2.6 的 .part 是从头顺序下的前缀
            intervals = [0..<size]
        }
    }

    func totalSize() -> Int { total }

    func downloadedBytes() -> Int { intervals.reduce(0) { $0 + $1.count } }

    /// 确保 range 全在缓存里，然后从文件读出来。缺失的洞按 2MB 切分补齐；
    /// 每补一段失败重试 4 次，仍失败则抛错（上层按播放失败处理）。
    /// range 超出文件尾时截到 total 内（超出的部分本就不存在）；完全在尾外则抛 416。
    func bytes(for range: Range<Int>) async throws -> Data {
        var effective = range
        if total > 0 { effective = range.lowerBound..<min(range.upperBound, total) }
        guard !effective.isEmpty else {
            throw NSError(domain: "TGCache", code: 416, userInfo: [NSLocalizedDescriptionKey: "超出文件尾"])
        }
        while !isCovered(effective) {
            try Task.checkCancellation()
            guard let hole = firstMissing(in: effective) else { break }
            let segEnd = min(hole.lowerBound + TGCache.segment, hole.upperBound)
            try await fetchSegment(hole.lowerBound..<segEnd)
            // 学到 total 后，把 effective 截到 total 内（超出的部分不存在）
            if total > 0, effective.upperBound > total {
                effective = effective.lowerBound..<total
                guard !effective.isEmpty else {
                    throw NSError(domain: "TGCache", code: 416, userInfo: [NSLocalizedDescriptionKey: "超出文件尾"])
                }
            }
        }
        return try read(effective)
    }

    private func isCovered(_ range: Range<Int>) -> Bool {
        var cur = range.lowerBound
        for iv in intervals {
            if iv.lowerBound > cur { return false }
            if iv.upperBound > cur { cur = iv.upperBound }
            if cur >= range.upperBound { return true }
        }
        return cur >= range.upperBound
    }

    private func firstMissing(in range: Range<Int>) -> Range<Int>? {
        var cur = range.lowerBound
        for iv in intervals {
            if iv.lowerBound > cur { return cur..<min(iv.lowerBound, range.upperBound) }
            if iv.upperBound > cur { cur = iv.upperBound }
            if cur >= range.upperBound { return nil }
        }
        return cur < range.upperBound ? cur..<range.upperBound : nil
    }

    private func fetchSegment(_ seg: Range<Int>) async throws {
        var lastError: Error?
        for _ in 0..<4 {
            try Task.checkCancellation()
            var req = URLRequest(url: remote)
            req.setValue("bytes=\(seg.lowerBound)-\(seg.upperBound - 1)", forHTTPHeaderField: "Range")
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw NSError(domain: "TGCache", code: 2, userInfo: [NSLocalizedDescriptionKey: "无响应"])
                }
                if data.isEmpty {
                    throw NSError(domain: "TGCache", code: 4, userInfo: [NSLocalizedDescriptionKey: "空数据"])
                }
                if http.statusCode == 206 {
                    if total < 0, let cr = http.value(forHTTPHeaderField: "Content-Range"),
                       let slash = cr.lastIndex(of: "/"), let n = Int(cr[cr.index(after: slash)...]) {
                        total = n
                    }
                    try write(data, at: seg.lowerBound)
                    addInterval(seg.lowerBound..<(seg.lowerBound + data.count))
                    await onProgress?(downloadedBytes(), total)
                    return
                } else if http.statusCode == 200, seg.lowerBound == 0 {
                    // 服务器没接 Range：它给的就是从头开始的全文
                    if total < 0, let len = http.value(forHTTPHeaderField: "Content-Length"), let n = Int(len) {
                        total = n
                    } else if total < 0 {
                        total = data.count
                    }
                    try write(data, at: 0)
                    addInterval(0..<data.count)
                    await onProgress?(downloadedBytes(), total)
                    return
                } else {
                    throw NSError(domain: "TGCache", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                }
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw lastError ?? NSError(domain: "TGCache", code: 3, userInfo: [NSLocalizedDescriptionKey: "下载失败"])
    }

    private func write(_ data: Data, at offset: Int) throws {
        let fm = FileManager.default
        // 整文件已在：这段必然已覆盖，跳过写（防并发取段在落盘后重建出残缺 part）
        if fm.fileExists(atPath: finalURL.path) { return }
        if !fm.fileExists(atPath: partURL.path) { fm.createFile(atPath: partURL.path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: partURL.path) else {
            throw NSError(domain: "TGCache", code: 1, userInfo: [NSLocalizedDescriptionKey: "打不开缓存文件"])
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    private func addInterval(_ iv: Range<Int>) {
        intervals.append(iv)
        intervals.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for r in intervals {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        intervals = merged
        let pairs = intervals.map { [$0.lowerBound, $0.upperBound] }
        if let data = try? JSONEncoder().encode(pairs) { try? data.write(to: sidecarURL) }
        // 刚好下完：落盘进缓存（已打开的文件句柄不受改名影响，后续读自动走整文件）
        if total > 0, intervals.count == 1, intervals[0].lowerBound == 0, intervals[0].upperBound >= total {
            let fm = FileManager.default
            if fm.fileExists(atPath: finalURL.path) { try? fm.removeItem(at: finalURL) }
            try? fm.moveItem(at: partURL, to: finalURL)
            try? fm.removeItem(at: sidecarURL)
            TGCache.prune(except: finalURL)
        }
    }

    private func read(_ range: Range<Int>) throws -> Data {
        // 整文件优先（完整）；在播的走 part（已打开的句柄不受落盘改名影响）
        let fm = FileManager.default
        let path = fm.fileExists(atPath: finalURL.path) ? finalURL : partURL
        guard let handle = FileHandle(forReadingAtPath: path.path) else {
            throw NSError(domain: "TGCache", code: 5, userInfo: [NSLocalizedDescriptionKey: "打不开缓存文件"])
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        guard let data = try handle.read(upToCount: range.count), data.count == range.count else {
            throw NSError(domain: "TGCache", code: 6, userInfo: [NSLocalizedDescriptionKey: "缓存不完整"])
        }
        return data
    }
}

/// TG 边下边播的资源中转：AVPlayer 的每个字节请求都经这里，
/// 从 TGProgressiveStore 取段（缺失就现取），网卡了只让请求挂着等，不直接失败。
final class TGResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let queue = DispatchQueue(label: "tgloader")
    private let store: TGProgressiveStore
    private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let lock = NSLock()

    init(remote: URL, onProgress: (@MainActor (Int, Int) -> Void)?) {
        self.store = TGProgressiveStore(remote: remote, onProgress: onProgress)
    }

    func cancelAll() {
        lock.lock()
        let tasks = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let task = Task { [weak self] in
            await self?.serve(loadingRequest)
            self?.remove(loadingRequest)
        }
        lock.lock()
        pending[ObjectIdentifier(loadingRequest)] = task
        lock.unlock()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.lock()
        let task = pending.removeValue(forKey: ObjectIdentifier(loadingRequest))
        lock.unlock()
        task?.cancel()
    }

    private func remove(_ request: AVAssetResourceLoadingRequest) {
        lock.lock()
        pending.removeValue(forKey: ObjectIdentifier(request))
        lock.unlock()
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) async {
        // 无数据请求：只填信息（total 已知就直接填，未知取 1 字节学 total）
        guard let dr = request.dataRequest else {
            do {
                var total = await store.totalSize()
                if total < 0 {
                    _ = try await store.bytes(for: 0..<1)
                    total = await store.totalSize()
                }
                if let info = request.contentInformationRequest, total > 0 {
                    info.contentType = "public.mpeg-4"
                    info.contentLength = Int64(total)
                    info.isByteRangeAccessSupported = true
                }
                request.finishLoading()
            } catch {
                if !Task.isCancelled { request.finishLoading(with: error) }
            }
            return
        }
        let off = Int(dr.requestedOffset)
        var end: Int? = dr.requestsAllDataToEndOfResource ? nil : off + Int(dr.requestedLength)
        var cur = off
        var filledInfo = false
        do {
            while true {
                if let e = end, cur >= e { break }
                let chunkEnd = end.map { min(cur + TGCache.segment, $0) } ?? (cur + TGCache.segment)
                let data = try await store.bytes(for: cur..<chunkEnd)
                if data.isEmpty {
                    throw NSError(domain: "TGCache", code: 4, userInfo: [NSLocalizedDescriptionKey: "空数据"])
                }
                if !filledInfo, let info = request.contentInformationRequest {
                    let total = await store.totalSize()
                    if total > 0 {
                        info.contentType = "public.mpeg-4"
                        info.contentLength = Int64(total)
                        info.isByteRangeAccessSupported = true
                        filledInfo = true
                    }
                }
                dr.respond(with: data)
                let before = cur
                cur += data.count
                // 读到短段 = 到文件尾（服务器按剩余字节截断），后面没有了
                if data.count < (chunkEnd - before) { break }
                // allData 且 total 刚学到：收尾位置就定下来
                if end == nil {
                    let total = await store.totalSize()
                    if total > 0 { end = total }
                }
            }
            request.finishLoading()
        } catch {
            if Task.isCancelled { return }
            // 416 且前面已给过数据 = 到文件尾，正常结束；否则按失败处理
            if (error as NSError).code == 416, cur > off {
                request.finishLoading()
            } else {
                request.finishLoading(with: error)
            }
        }
    }
}

/// 转屏（茶茶短剧同款）：iOS 16+ 用 requestGeometryUpdate，老办法只当回退。
enum ScreenRotation {
    static func rotate(to orientation: UIInterfaceOrientation) {
        let mask: UIInterfaceOrientationMask = orientation.isLandscape ? .landscapeRight : .portrait
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in
                rotateLegacy(to: orientation)
            }
            return
        }
        rotateLegacy(to: orientation)
    }

    private static func rotateLegacy(to orientation: UIInterfaceOrientation) {
        UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
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
    @State private var showControls = true
    @State private var controlsLocked = false
    @State private var seekFraction: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var showEpisodes = false
    @State private var showLines = false

    init(group: VodGroup, sourceIdx: Int, lineIdx: Int, startEpisode: Episode, sourceLabel: String, lineLabel: String) {
        self.group = group
        self.sourceIdx = sourceIdx
        self.lineIdx = lineIdx
        self.startEpisode = startEpisode
        self.sourceLabel = sourceLabel
        self.lineLabel = lineLabel
        _model = StateObject(wrappedValue: PlayerModel(group: group, sourceIdx: sourceIdx, lineIdx: lineIdx, startEpisode: startEpisode))
    }

    private var progress: Double {
        model.duration > 0 ? min(max(model.currentTime / model.duration, 0), 1) : 0
    }

    private var currentOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }.first ?? .portrait
    }

    var body: some View {
        ZStack {
            PlayerControllerView(player: model.player, gravity: model.videoGravity)
                .ignoresSafeArea()
            // 点按层：点空白处显隐控制条；锁定时点按无效。
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { if !controlsLocked { toggleControls() } }
            if showControls {
                VStack(spacing: 0) {
                    // 顶栏：返回 + 剧名/集数 + 睡眠 + 更多
                    HStack(alignment: .top, spacing: 10) {
                        glassButton(systemName: "chevron.left", size: 18) { dismiss() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).font(.headline).bold().foregroundColor(.white).lineLimit(1)
                            Text(model.currentEp.title).font(.subheadline).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                        }
                        Spacer()
                        if let s = model.sleepText {
                            Text(s).font(.caption).foregroundColor(.red).padding(.top, 12)
                        }
                        Menu {
                            Button("15 分钟") { model.setSleep(minutes: 15) }
                            Button("30 分钟") { model.setSleep(minutes: 30) }
                            Button("60 分钟") { model.setSleep(minutes: 60) }
                            Button("取消睡眠定时") { model.cancelSleep() }
                        } label: {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 17)).foregroundColor(model.sleepText == nil ? .white : .red)
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Menu {
                            Button("下一集") { model.nextEpisode(auto: false) }
                            Button("换源") { if model.nextLine() { model.buildPlay() } }
                            Button("记片头") { model.markIntro() }
                            Button("记片尾") { model.markOutroAndNext() }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .background(
                        LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)
                    )
                    Spacer()
                    // 中间：播放/暂停
                    Button(action: { model.togglePlay(); scheduleHide() }) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 54)).foregroundColor(.white.opacity(0.92))
                            .shadow(radius: 8)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    // 底部：提示 + 进度条 + 功能行
                    VStack(spacing: 10) {
                        if let n = model.notice { Text(n).font(.caption).foregroundColor(.yellow) }
                        if let p = model.cacheProgress {
                            Text(p >= 0 ? "正在缓冲 \(Int(p * 100))%（\(model.cacheMB)MB）" : "正在缓冲 \(model.cacheMB)MB").font(.caption).foregroundColor(.yellow)
                        }
                        if let e = model.errorText {
                            Text(e).foregroundColor(.red)
                            Button("返回") { dismiss() }
                        }
                        // 可拖进度条 + 时间
                        HStack(spacing: 10) {
                            Text(formatTime(seekFraction.map { $0 * model.duration } ?? model.currentTime))
                                .font(.caption).foregroundColor(.white).frame(width: 44, alignment: .trailing)
                            GeometryReader { barGeo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.3)).frame(height: 4)
                                    Capsule().fill(Color.red)
                                        .frame(width: max(barGeo.size.width * (seekFraction ?? progress), 0), height: 4)
                                    Circle().fill(Color.white).frame(width: 14, height: 14)
                                        .offset(x: max(barGeo.size.width * (seekFraction ?? progress) - 7, 0))
                                }
                                .frame(height: 28)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { v in
                                            guard barGeo.size.width > 0 else { return }
                                            seekFraction = min(max(v.location.x / barGeo.size.width, 0), 1)
                                        }
                                        .onEnded { v in
                                            guard barGeo.size.width > 0 else { return }
                                            let f = min(max(v.location.x / barGeo.size.width, 0), 1)
                                            model.seek(to: f)
                                            seekFraction = nil
                                            scheduleHide()
                                        }
                                )
                            }
                            .frame(height: 28)
                            Text(formatTime(model.duration))
                                .font(.caption).foregroundColor(.white).frame(width: 44, alignment: .leading)
                        }
                        // 功能行：左 倍速/画面，右 选集/线路/全屏
                        HStack(spacing: 0) {
                            HStack(spacing: 10) {
                                pillButton("倍速 \(model.speed == 1 ? "1" : "\(model.speed)")x") {
                                    model.cycleSpeed(); scheduleHide()
                                }
                                pillButton("画面 \(model.videoGravity == .resizeAspect ? "适应" : "填充")") {
                                    model.cycleGravity(); scheduleHide()
                                }
                            }
                            Spacer()
                            HStack(spacing: 10) {
                                pillButton("选集") { showEpisodes = true }
                                pillButton("线路") { showLines = true }
                                Button(action: { toggleOrientation() }) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 16)).foregroundColor(.white)
                                        .frame(width: 36, height: 36)
                                        .background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // 锁定按钮：控制条显示时在右缘；锁定时单独留在右缘，点它解锁。
            if showControls || controlsLocked {
                HStack {
                    Spacer()
                    Button(action: { toggleLock() }) {
                        Image(systemName: controlsLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 18)).foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .onAppear { scheduleHide() }
        // 暂停时留着控制条，恢复播放 3 秒后再藏（茶茶短剧同款）。
        .onChange(of: model.isPlaying) { playing in
            if playing { scheduleHide() } else { hideTask?.cancel() }
        }
        .onDisappear {
            hideTask?.cancel()
            if currentOrientation.isLandscape { ScreenRotation.rotate(to: .portrait) }
            model.teardown()
        }
        .sheet(isPresented: $showEpisodes) { EpisodePickerSheet(model: model) }
        .sheet(isPresented: $showLines) { LinePickerSheet(model: model) }
        .task { await model.start() }
    }

    /// 玻璃圆角图标钮（顶栏返回/睡眠/更多、右缘锁定同款）。
    private func glassButton(systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold)).foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// 玻璃文字 pill（倍速/画面/选集/线路同款）。
    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline).foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func toggleControls() {
        showControls.toggle()
        if showControls { scheduleHide() } else { hideTask?.cancel() }
    }

    private func toggleLock() {
        if controlsLocked {
            controlsLocked = false
            showControls = true
            scheduleHide()
        } else {
            controlsLocked = true
            showControls = false
            hideTask?.cancel()
        }
    }

    private func toggleOrientation() {
        ScreenRotation.rotate(to: currentOrientation.isLandscape ? .portrait : .landscapeRight)
    }

    /// 3 秒无操作自动藏控制条：没播（暂停/缓冲）就一直等，播了再等 3 秒藏；
    /// 一次性的检查不可靠（正好卡在暂停那一刻就永远不藏了），所以循环等（茶茶短剧同款）。
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

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s)
        return "\(i / 60):\(String(format: "%02d", i % 60))"
    }
}

/// 选集表：当前线路的全部集数，当前集红色高亮。
private struct EpisodePickerSheet: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    private var episodes: [Episode] {
        guard model.group.sources.indices.contains(model.currentSourceIdx),
              model.group.sources[model.currentSourceIdx].lines.indices.contains(model.currentLineIdx) else { return [] }
        return model.group.sources[model.currentSourceIdx].lines[model.currentLineIdx].episodes
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(episodes) { ep in
                        Button(ep.title) {
                            model.jumpToEpisode(ep)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .tint(ep == model.currentEp ? .red : .gray)
                    }
                }
                .padding()
            }
            .navigationTitle("\(model.group.name) · 选集")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 线路表：全部源 × 线路，当前线路红色高亮，点哪条切哪条（同集）。
private struct LinePickerSheet: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.group.sources.indices, id: \.self) { si in
                    Section(model.group.sources[si].sourceLabel) {
                        ForEach(model.group.sources[si].lines.indices, id: \.self) { li in
                            let line = model.group.sources[si].lines[li]
                            Button(line.label.isEmpty ? "线路 \(li + 1)" : line.label) {
                                model.switchLine(sourceIdx: si, lineIdx: li)
                                dismiss()
                            }
                            .foregroundColor(si == model.currentSourceIdx && li == model.currentLineIdx ? .red : .primary)
                        }
                    }
                }
            }
            .navigationTitle("线路")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct PlayerControllerView: UIViewControllerRepresentable {
    var player: AVPlayer
    var gravity: AVLayerVideoGravity
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        // 系统控制条关掉：全套控制条自家画（进度条可拖、3 秒自动藏），
        // 和系统那套叠在一起会打架；绝不自动进系统全屏（全屏后自家关闭按钮和报错文字全没了）。
        vc.showsPlaybackControls = false
        vc.videoGravity = gravity
        vc.entersFullScreenWhenPlaybackBegins = false
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        vc.player = player
        vc.videoGravity = gravity
    }
}
