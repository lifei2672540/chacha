import Foundation

// MARK: - 磁力引擎封装（libtorrent C 桥接层）
//
// C API 见 GHT63iOS/libtorrent/torrent_bridge.h，经桥接头导入 Swift。
// 关键约定（核对过 torrent_bridge.cpp 实现）：
// - lt_add_magnet / lt_start_stream 失败返回 -1，成功返回 >= 0 的 id（id 从 0 开始，0 不是失败）。
// - lt_get_status / lt_get_stream_status 返回 1 成功、0 失败；lt_get_files 返回实际取到的条数。
// - lt_create_session(nil, 0, 0) 安全：空地址用默认监听，0 限速即不限速。
// - 流地址格式 http://127.0.0.1:<端口>/stream/<40位hash>/<文件下标>，无媒体后缀，
//   播放器会先嗅探（HEAD/Range），桥接层内建服务器支持 Range，嗅不到就直接播。
// - C 层自带锁，线程安全；Swift 侧只有 session 一个共享状态，用 NSLock 保护。
// - 所有同步方法都很快（读状态/触发异步工作），但仍约定只在后台线程调用，
//   不在主线程直接调；异步包装把回调送回主线程。

final class TorrentEngine {
    static let shared = TorrentEngine()
    private init() {}

    // MARK: 状态常量（与 torrent_bridge.h 的 LT_STATE_* / LT_STREAM_* 一致）

    static let stateError = -2
    static let stateUnknown = -1
    static let stateCheckingFiles = 0
    static let stateDownloadingMeta = 1
    static let stateDownloading = 2
    static let stateFinished = 3
    static let stateSeeding = 4
    static let stateAllocating = 5
    static let stateCheckingResume = 6

    static let streamIdle = 0
    static let streamBuffering = 1
    static let streamReady = 2
    static let streamSeeking = 3
    static let streamError = 4

    /// 串流缓存上限（64MB），传给 lt_start_stream。
    static let defaultMaxCacheBytes: Int64 = 64 * 1024 * 1024
    /// 等流地址就绪的最长等待（秒）。
    static let defaultStreamTimeout: TimeInterval = 60

    // MARK: 数据结构

    struct TorrentStatus {
        var id: Int64
        var name: String
        var state: Int32
        var progress: Float          // 0...1
        var downloadRate: Int32      // bytes/s
        var uploadRate: Int32
        var totalDone: Int64
        var totalWanted: Int64
        var numPeers: Int32
        var numSeeds: Int32
        var hasMetadata: Bool
        var isFinished: Bool
        var isPaused: Bool
        var errorMessage: String

        var stateText: String {
            switch Int(state) {
            case TorrentEngine.stateError: return "出错"
            case TorrentEngine.stateUnknown: return "未知"
            case TorrentEngine.stateCheckingFiles: return "校验文件"
            case TorrentEngine.stateDownloadingMeta: return "获取信息"
            case TorrentEngine.stateDownloading: return "下载中"
            case TorrentEngine.stateFinished: return "已完成"
            case TorrentEngine.stateSeeding: return "做种中"
            case TorrentEngine.stateAllocating: return "分配空间"
            case TorrentEngine.stateCheckingResume: return "校验续传"
            default: return "未知"
            }
        }
    }

    struct TorrentFile: Identifiable {
        var id: Int32 { index }
        var index: Int32
        var name: String
        var path: String
        var size: Int64
        var isStreamable: Bool
    }

    struct StreamStatus {
        var id: Int64
        var torrentId: Int64
        var fileIndex: Int32
        var url: String
        var fileSize: Int64
        var state: Int32
        var bufferSeconds: Float
        var downloadRate: Int32
    }

    // MARK: 会话

    private let lock = NSLock()
    private var _session: OpaquePointer?

    /// 下载保存目录：Caches/Torrents（系统可清，不进备份）。
    private lazy var saveDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("Torrents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 懒创建会话（首次用时）。只在后台线程调。
    private func ensureSession() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        if let s = _session { return s }
        let s = lt_create_session(nil, 0, 0)
        _session = s
        return s
    }

    // MARK: C char 数组 -> String（按首个 NUL 截断；无 NUL 时取整段，永不越界）

    private static func stringFromBytes(_ bytes: UnsafeRawBufferPointer) -> String {
        var end = 0
        while end < bytes.count && bytes[end] != 0 { end += 1 }
        guard end > 0, let base = bytes.baseAddress else { return "" }
        let data = Data(bytes: base, count: end)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func cStringField<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { stringFromBytes($0) }
    }

    // MARK: 同步 API（只在后台线程调用）

    /// 加磁力链接。stream_only=1：稀疏存储，拿到元数据后暂停，串流时再恢复。
    /// 返回种子 id（>= 0），失败返回 -1（原因见 lastError()）。
    func addMagnetSync(_ magnet: String) -> Int64 {
        guard let s = ensureSession() else { return -1 }
        let dir = saveDir.path
        return magnet.withCString { m in
            dir.withCString { d in
                lt_add_magnet(s, m, d, 1)
            }
        }
    }

    /// 查种子状态。种子不存在返回 nil。
    func statusSync(for id: Int64) -> TorrentStatus? {
        guard let s = ensureSession() else { return nil }
        var st = lt_torrent_status()
        guard lt_get_status(s, id, &st) == 1 else { return nil }
        return TorrentStatus(
            id: st.id,
            name: Self.cStringField(st.name),
            state: st.state,
            progress: st.progress,
            downloadRate: st.download_rate,
            uploadRate: st.upload_rate,
            totalDone: st.total_done,
            totalWanted: st.total_wanted,
            numPeers: st.num_peers,
            numSeeds: st.num_seeds,
            hasMetadata: st.has_metadata != 0,
            isFinished: st.is_finished != 0,
            isPaused: st.is_paused != 0,
            errorMessage: Self.cStringField(st.error_msg)
        )
    }

    /// 查文件列表。无元数据时返回空数组。
    func filesSync(for id: Int64) -> [TorrentFile] {
        guard let s = ensureSession() else { return [] }
        let count = lt_get_file_count(s, id)
        guard count > 0 else { return [] }
        var buf = [lt_file_info](repeating: lt_file_info(), count: Int(count))
        let n = lt_get_files(s, id, &buf, count)
        guard n > 0 else { return [] }
        var out: [TorrentFile] = []
        out.reserveCapacity(Int(n))
        for i in 0..<Int(n) {
            let f = buf[i]
            out.append(TorrentFile(
                index: f.index,
                name: Self.cStringField(f.name),
                path: Self.cStringField(f.path),
                size: f.size,
                isStreamable: f.is_streamable != 0
            ))
        }
        return out
    }

    /// 开始串流某文件。fileIndex < 0 时桥接层自动选最大的可播文件。
    /// 返回流 id（>= 0），失败返回 -1（无元数据/下标越界时就是 -1）。
    func startStreamSync(torrentId: Int64, fileIndex: Int32) -> Int64 {
        guard let s = ensureSession() else { return -1 }
        return lt_start_stream(s, torrentId, fileIndex, Self.defaultMaxCacheBytes)
    }

    /// 查流状态。流不存在返回 nil。
    func streamStatusSync(for streamId: Int64) -> StreamStatus? {
        guard let s = ensureSession() else { return nil }
        var ss = lt_stream_status()
        guard lt_get_stream_status(s, streamId, &ss) == 1 else { return nil }
        return StreamStatus(
            id: ss.id,
            torrentId: ss.torrent_id,
            fileIndex: ss.file_index,
            url: Self.cStringField(ss.url),
            fileSize: ss.file_size,
            state: ss.stream_state,
            bufferSeconds: ss.buffer_seconds,
            downloadRate: ss.download_rate
        )
    }

    func stopStreamSync(_ streamId: Int64) {
        guard let s = ensureSession() else { return }
        lt_stop_stream(s, streamId)
    }

    /// 删种子。deleteFiles=true 时连下载文件一起删。
    func removeTorrentSync(_ id: Int64, deleteFiles: Bool) {
        guard let s = ensureSession() else { return }
        lt_remove_torrent(s, id, deleteFiles ? 1 : 0)
    }

    /// 最近一次 C 层错误文本（addMagnet 等返回 -1 时看这个）。
    func lastError() -> String {
        guard let c = lt_last_error() else { return "" }
        return String(cString: c)
    }

    /// 桥接层 libtorrent 版本（设置页/日志用）。
    func version() -> String {
        guard let c = lt_version() else { return "" }
        return String(cString: c)
    }

    // MARK: 异步包装（C 调用放后台线程，回调回主线程）

    /// 加磁力链接。回调：种子 id（>= 0），失败 -1。
    func addMagnet(_ magnet: String, completion: @escaping (Int64) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let id = self.addMagnetSync(magnet)
            DispatchQueue.main.async { completion(id) }
        }
    }

    /// 等流地址就绪（轮询 0.5 秒一次）。READY 时回调流地址，超时/出错/流没了回调 nil。
    func waitForStreamURL(streamId: Int64, timeout: TimeInterval = defaultStreamTimeout,
                          completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let ss = self.streamStatusSync(for: streamId) {
                    if ss.state == Int32(Self.streamReady) {
                        let url = ss.url
                        DispatchQueue.main.async { completion(url.isEmpty ? nil : url) }
                        return
                    }
                    if ss.state == Int32(Self.streamError) { break }
                } else {
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async { completion(nil) }
        }
    }
}
