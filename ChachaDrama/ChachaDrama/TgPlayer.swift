import AVFoundation
import SwiftUI

// MARK: - TG 流本地缓存（与茶茶点播 PlayerView.swift 同款，1.2.7 在真机上验过）
// 分片下载（2MB 一片）+ 断点续传，失败重试，完工后落盘，超 2GB 清最旧。
// 未完成的文件留 .part 续传，完工的文件才改名进缓存，缓存文件恒为完整文件。

enum TGCache {
    static let segment = 512 * 1024
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
    /// Read-ahead: segment starts currently being prefetched in the background.
    /// One segment is fetched on demand; these extra ones download concurrently
    /// so playback stays ahead of a slow link. A prefetched segment that is
    /// never played is just wasted bandwidth, bounded by `prefetchCount`.
    /// Prefetch tasks hold `self` weakly and exit when the store is gone,
    /// so no explicit cancellation is needed on teardown.
    private var prefetching: Set<Int> = []
    private static let prefetchCount = 2
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
        cfg.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: cfg)
        let fm = FileManager.default
        if fm.fileExists(atPath: finalURL.path) {
            try? fm.removeItem(at: partURL)
            try? fm.removeItem(at: sidecarURL)
        } else if let data = try? Data(contentsOf: sidecarURL),
                  let pairs = try? JSONDecoder().decode([[Int]].self, from: data) {
            intervals = pairs.compactMap { $0.count == 2 && $0[0] < $0[1] ? $0[0]..<$0[1] : nil }.sorted { $0.lowerBound < $1.lowerBound }
        } else if let size = (try? fm.attributesOfItem(atPath: partURL.path)[.size] as? Int), size > 0 {
            intervals = [0..<size]
        }
    }

    func totalSize() -> Int { total }

    func downloadedBytes() -> Int { intervals.reduce(0) { $0 + $1.count } }

    /// 确保 range 全在缓存里，然后从文件读出来。缺失的洞按 512KB 切分补齐；
    /// 每补一段失败重试 4 次，仍失败则抛错（上层按播放失败处理）。
    /// range 超出文件尾时截到 total 内（超出的部分本就不存在）；完全在尾外则抛 416。
    /// 补齐后顺手预取后面两段（并发下），让下载跑在播放前面。
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
            if total > 0, effective.upperBound > total {
                effective = effective.lowerBound..<total
                guard !effective.isEmpty else {
                    throw NSError(domain: "TGCache", code: 416, userInfo: [NSLocalizedDescriptionKey: "超出文件尾"])
                }
            }
        }
        // Read-ahead prefetch is DISABLED (1.2.6): the 1.2.5 concurrent prefetch
        // made playback fail outright on device (no buffering at all), so the
        // store is back to on-demand fetching only. prefetchAhead stays in
        // the file, unused, until the failure is reproduced and understood.
        return try read(effective)
    }

    /// Remove a finished prefetch entry. The prefetch task runs outside the
    /// actor, so it calls this isolated method (the compiler requires it).
    private func _prefetchDone(_ start: Int) {
        prefetching.remove(start)
    }

    /// Fetch the next `prefetchCount` segments past `offset` concurrently,
    /// so the download runs ahead of playback. Failures are swallowed:
    /// the on-demand fetch retries the segment later.
    private func prefetchAhead(from offset: Int) {
        guard total > 0 else { return }
        var start = ((offset + TGCache.segment - 1) / TGCache.segment) * TGCache.segment
        var n = 0
        while n < Self.prefetchCount, start < total {
            let segStart = start
            let segEnd = min(segStart + TGCache.segment, total)
            if !isCovered(segStart..<segEnd), !prefetching.contains(segStart) {
                prefetching.insert(segStart)
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.fetchSegment(segStart..<segEnd)
                    } catch {
                        // Prefetch failure is not fatal; on-demand fetch retries later.
                    }
                    await self._prefetchDone(segStart)
                }
                n += 1
            }
            start += TGCache.segment
        }
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
        if total > 0, intervals.count == 1, intervals[0].lowerBound == 0, intervals[0].upperBound >= total {
            let fm = FileManager.default
            if fm.fileExists(atPath: finalURL.path) { try? fm.removeItem(at: finalURL) }
            try? fm.moveItem(at: partURL, to: finalURL)
            try? fm.removeItem(at: sidecarURL)
            TGCache.prune(except: finalURL)
        }
    }

    private func read(_ range: Range<Int>) throws -> Data {
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

    /// 先取头一段（建播放器之前调）：首段到手后，播放器的首批请求直接读本地，不用等采集端。
    func prefetchHead() async throws {
        _ = try await store.bytes(for: 0..<TGCache.segment)
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
                if data.count < (chunkEnd - before) { break }
                if end == nil {
                    let total = await store.totalSize()
                    if total > 0 { end = total }
                }
            }
            request.finishLoading()
        } catch {
            if Task.isCancelled { return }
            if (error as NSError).code == 416, cur > off {
                request.finishLoading()
            } else {
                request.finishLoading(with: error)
            }
        }
    }
}

// MARK: - TG 播放器：采集端流地址 → AVPlayer（边下边播，播完自动下一集）
// 接口与 FeedPlayerModel 对齐（player/loading/error/progress/duration/currentTime/isPlaying/gravity），
// 续播按流地址记（Store.saveProgress），继续观看记进 TgStore（按剧 + 集）。

@MainActor
final class TgPlayerModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var loading = false
    @Published var error: String?
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var gravity: AVLayerVideoGravity = .resizeAspect
    /// 视频是不是横屏（按实际尺寸定，播放页转屏就看它，不看 gravity）。
    @Published var isLandscape = false
    @Published var cacheProgress: Double?
    @Published var cacheMB: Double = 0
    /// 无画面时的原因（屏幕上直接显示）：没有视频轨道，或视频编码系统播不了。
    @Published var videoHint: String?
    @Published var currentIndex = 0
    /// 全部播完（最后一集播完）时回调，View 决定是退出还是提示。
    var onAllEnded: (() -> Void)?

    private var episodes: [TgVideo] = []
    private var showId = ""
    private var showName = ""
    private var showCover = ""
    private var item: AVPlayerItem?
    private var statusObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var timeObs: Any?
    private var watchdog: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var tgLoader: TGResourceLoader?
    private var lastSave = Date.distantPast
    private var ready = false

    var currentVideo: TgVideo? {
        episodes.indices.contains(currentIndex) ? episodes[currentIndex] : nil
    }
    var hasNext: Bool { currentIndex + 1 < episodes.count }

    func load(episodes: [TgVideo], index: Int, showId: String, showName: String, cover: String) {
        self.episodes = episodes
        self.showId = showId
        self.showName = showName
        self.showCover = cover
        currentIndex = max(0, min(index, max(0, episodes.count - 1)))
        buildCurrent()
    }

    private func buildCurrent() {
        cleanupItem()
        guard let v = currentVideo else {
            error = "没有可播的视频"
            return
        }
        let raw = v.absUrl(TgAPI.baseUrl, v.streamUrl)
        guard !raw.isEmpty, let url = URL(string: raw) else {
            error = "播放地址无效"
            return
        }
        loading = true
        error = nil
        videoHint = nil
        progress = 0
        duration = 0
        currentTime = 0
        isPlaying = false
        gravity = .resizeAspect
        isLandscape = false
        cacheProgress = nil
        cacheMB = 0
        ready = false
        // 整文件已缓存：直接播本地文件，不走采集端。
        let final = TGCache.finalFile(for: url.absoluteString)
        if FileManager.default.fileExists(atPath: final.path),
           ((try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? Int) ?? 0) > 0 {
            ErrorLog.append("TG读缓存 \(showName) - \(v.epLabel)")
            playItem(AVPlayerItem(asset: AVURLAsset(url: final)))
            return
        }
        // 边下边播：自定义 scheme，强制全部请求走 delegate，不让 AVPlayer 自己直连采集端
        //（直连在 1.2.5 之前试过：数据来得不可靠，60 秒都拿不到可播状态）。
        ErrorLog.append("TG边下边播 \(showName) - \(v.epLabel)")
        cacheProgress = 0
        let loader = TGResourceLoader(remote: url, onProgress: { [weak self] done, total in
            self?.cacheMB = Double(done) / 1_000_000
            self?.cacheProgress = total > 0 ? Double(done) / Double(total) : -1
        })
        tgLoader = loader
        // 先把头一段取回来再建播放器：采集端取流慢时，AVPlayer 等首段的耐心只有几十秒，
        // 空手建播放器会一上来就超时失败；先取好再建，建完立刻就能播。
        let assetURL = URL(string: "tgcache://\(TGCache.fileName(for: url.absoluteString))")!
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await loader.prefetchHead()
                guard !Task.isCancelled else { return }
                let asset = AVURLAsset(url: assetURL)
                asset.resourceLoader.setDelegate(loader, queue: TGResourceLoader.queue)
                self.playItem(AVPlayerItem(asset: asset))
            } catch {
                guard !Task.isCancelled else { return }
                self.loading = false
                self.cacheProgress = nil
                self.error = "取流失败：" + error.localizedDescription + "，点重试再试一次"
            }
        }
    }

    private func playItem(_ it: AVPlayerItem) {
        item = it
        let p = AVPlayer(playerItem: it)
        player = p
        let resumeFrom = Store.shared.progress(for: currentVideo?.streamUrl ?? "")
        statusObs = it.observe(\.status, options: [.new]) { [weak self] it, _ in
            Task { @MainActor in self?.handleStatus(it, resumeFrom: resumeFrom) }
        }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: it, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleEnded() }
        }
        timeObs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time: time) }
        }
        // TG 看门狗 60 秒：采集端取流慢，直连时代 60 秒都拿不到可播状态；边下边播一般几秒就绪。
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, !Task.isCancelled, !self.ready else { return }
            self.loading = false
            self.error = "加载超时 60s：采集端取流太慢或连不上，检查软路由上的采集端"
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
            cacheProgress = nil
            let size = it.presentationSize
            if size.width > 0, size.height > 0 {
                gravity = .resizeAspect
                isLandscape = size.width > size.height
            }
            // 视频轨道诊断：有声音没画面时，屏幕上直接报编码（VP9/AV1 等系统播不了的），
            // 也记进错误日志，方便确认是哪种编码再决定接不接软件解码。
            let videoTracks = it.asset.tracks(withMediaType: .video)
            var codec = ""
            if let vt = videoTracks.first,
               let fd = vt.formatDescriptions.first as? CMFormatDescription {
                codec = Self.fourCC(CMFormatDescriptionGetMediaSubType(fd))
            }
            let epLabel = currentVideo?.epLabel ?? ""
            if videoTracks.isEmpty {
                videoHint = "这条视频没有视频轨道，只有声音"
                ErrorLog.append("TG无视频轨 \(showName) - \(epLabel)")
            } else if size.width <= 0 || size.height <= 0 {
                videoHint = "有声音没画面：视频编码 \(codec.isEmpty ? "未知" : codec)，系统播不了"
                ErrorLog.append("TG视频轨不可播 \(showName) - \(epLabel) codec=\(codec)")
            } else {
                videoHint = nil
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
            cacheProgress = nil
            error = "播放器失败：" + (it.error?.localizedDescription ?? "未知错误")
        default:
            break
        }
    }

    /// FourCharCode 转成 "avc1"/"vp09" 这样的编码名；非 ASCII 时给十六进制。
    private static func fourCC(_ code: FourCharCode) -> String {
        let b: [UInt8] = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                          UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? String(format: "%08X", code)
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
            saveState(time: cur)
        }
    }

    private func save(video: TgVideo, time: Double) {
        Store.shared.saveProgress(epId: video.streamUrl, time: time)
        TgStore.shared.saveResume(showId: showId, showName: showName, cover: showCover, video: video, time: time)
    }

    private func saveState(time: Double) {
        guard let v = currentVideo else { return }
        save(video: v, time: time)
    }

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
        saveState(time: t)
    }

    func seekBy(seconds: Double) {
        guard let p = player, let it = p.currentItem else { return }
        let dur = it.duration.seconds
        guard dur.isFinite && dur > 0 else { return }
        let t = min(max(p.currentTime().seconds + seconds, 0), dur)
        progress = t / dur
        currentTime = t
        p.seek(to: CMTime(seconds: t, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
        saveState(time: t)
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

    /// 出错后重试：重建当前这一集（不断开播放页）。
    func retry() {
        buildCurrent()
    }

    /// 下一集：有就播，没有就回调 onAllEnded（View 决定退出还是提示）。
    func nextEpisode(auto: Bool) {
        if hasNext {
            // 先把旧这一集的进度存好，再切 index：buildCurrent 里的 teardown
            // 是按新 index 存的，顺序反了会把旧时间记到新集上。
            if let v = currentVideo, let cur = player?.currentTime().seconds, cur > 0 {
                save(video: v, time: cur)
            }
            currentIndex += 1
            buildCurrent()
        } else {
            onAllEnded?()
        }
    }

    private func handleEnded() {
        isPlaying = false
        nextEpisode(auto: true)
    }

    private func cleanupItem() {
        watchdog?.cancel()
        watchdog = nil
        prefetchTask?.cancel()
        prefetchTask = nil
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
        // 不在这里存进度：调用方（切集/退出）按正确的集显式存，
        // 这里按 currentVideo 存会在切集时把旧时间记到新集上。
        tgLoader?.cancelAll()
        tgLoader = nil
        player?.pause()
        player = nil
        item = nil
        ready = false
    }

    func cleanup() {
        if let v = currentVideo, let cur = player?.currentTime().seconds, cur > 0 {
            save(video: v, time: cur)
        }
        cleanupItem()
        episodes = []
    }
}
