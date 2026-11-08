import Foundation

/// 本地存储 + 云端合并（与 TV 版 Prefs 同款语义）：
/// 进度取本地与云端的大者；最近观看本地上限 24 条；追剧本地与云端并集；
/// 片头片尾、倍速按剧记忆；TMDB 缓存与 Key 只存本机。
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var recents: [RecentItem] = []
    @Published var favorites: [FavItem] = []
    /// 本地进度：episode url -> (time, duration)
    @Published var localProgress: [String: (Double, Double)] = [:]

    private let enc = JSONEncoder()
    private let dec = JSONDecoder()

    private init() { loadLocal() }

    // MARK: 本地读写
    private func loadLocal() {
        if let d = UserDefaults.standard.data(forKey: "recents"),
           let v = try? dec.decode([RecentItem].self, from: d) { recents = v }
        if let d = UserDefaults.standard.data(forKey: "favorites"),
           let v = try? dec.decode([FavItem].self, from: d) { favorites = v }
        if let d = UserDefaults.standard.data(forKey: "localProgress"),
           let v = try? dec.decode([String: [Double]].self, from: d) {
            localProgress = v.compactMapValues { $0.count >= 2 ? ($0[0], $0[1]) : nil }
        }
    }
    private func saveLocal() {
        UserDefaults.standard.set(try? enc.encode(recents), forKey: "recents")
        UserDefaults.standard.set(try? enc.encode(favorites), forKey: "favorites")
        UserDefaults.standard.set(try? enc.encode(localProgress.mapValues { [$0.0, $0.1] }), forKey: "localProgress")
    }

    // MARK: 最近观看
    func recordRecent(_ item: RecentItem) {
        recents.removeAll { $0.url == item.url }
        recents.insert(item, at: 0)
        if recents.count > 24 { recents = Array(recents.prefix(24)) }
        saveLocal()
    }
    func removeRecent(url: String) {
        recents.removeAll { $0.url == url }
        saveLocal()
    }
    func clearRecents() { recents = []; saveLocal() }

    // MARK: 进度（本地 + 云端取大者）
    func resumeTime(for url: String, cloud: [String: ProgressRec]) -> Double {
        let local = localProgress[url]?.0 ?? 0
        let remote = cloud[url]?.time ?? 0
        let t = max(local, remote)
        return t > 5 ? t : 0
    }
    func saveProgress(url: String, time: Double, duration: Double) {
        localProgress[url] = (time, duration)
        saveLocal()
    }

    // MARK: 追剧
    func isFavorite(_ name: String) -> Bool { favorites.contains { $0.name == name } }
    func toggleFavorite(_ item: FavItem) {
        if let i = favorites.firstIndex(where: { $0.name == item.name }) {
            favorites.remove(at: i)
        } else {
            favorites.append(item)
        }
        saveLocal()
        Task { await ApiClient.shared.saveFavorites(favorites) }
    }
    /// 云端并集合并（TV 同款）：云端有、本地无的补进来。
    func mergeCloudFavorites(_ cloud: [FavItem]) {
        for c in cloud where !favorites.contains(where: { $0.name == c.name }) {
            favorites.append(c)
        }
        saveLocal()
    }

    // MARK: 按剧记忆：片头 / 片尾 / 倍速
    func introOutro(for drama: String) -> (Double?, Double?) {
        let d = UserDefaults.standard.dictionary(forKey: "intro_outro_\(drama)") as? [String: Double]
        return (d?["intro"], d?["outro"])
    }
    func saveIntroOutro(drama: String, intro: Double?, outro: Double?) {
        var d: [String: Double] = [:]
        if let intro = intro { d["intro"] = intro }
        if let outro = outro { d["outro"] = outro }
        UserDefaults.standard.set(d, forKey: "intro_outro_\(drama)")
    }
    func speed(for drama: String) -> Float {
        UserDefaults.standard.float(forKey: "speed_\(drama)") == 0 ? 1 : UserDefaults.standard.float(forKey: "speed_\(drama)")
    }
    func saveSpeed(drama: String, speed: Float) {
        UserDefaults.standard.set(speed, forKey: "speed_\(drama)")
    }

    // MARK: TMDB Key 与缓存（只存本机，不进备份外的任何地方）
    var tmdbKey: String {
        get { UserDefaults.standard.string(forKey: "tmdbKey") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "tmdbKey")
            UserDefaults.standard.removeObject(forKey: "tmdbCache")
        }
    }
    /// 新版影视界面（蚂蚁 2.0.6 同款开关）：开 = 沉浸式首页 + 玻璃底栏，关 = 恢复旧版首页。
    var newHomeUI: Bool {
        get { UserDefaults.standard.object(forKey: "newHomeUI") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "newHomeUI") }
    }
    /// 启用 TMDB 资料（关了全不走 TMDB，只用接口自带海报和资料）。
    var tmdbEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "tmdbEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tmdbEnabled") }
    }
    /// 首页与搜索卡片匹配 TMDB（默认关：用影视源海报；开后匹配首页卡片图片与搜索结果的海报、评分等资料）。
    var tmdbMatchCards: Bool {
        get { UserDefaults.standard.bool(forKey: "tmdbMatchCards") }
        set { UserDefaults.standard.set(newValue, forKey: "tmdbMatchCards") }
    }
    /// 详情页海报背景（关了用默认主题背景，不用影视海报）。
    var detailPosterBackdrop: Bool {
        get { UserDefaults.standard.object(forKey: "detailPosterBackdrop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "detailPosterBackdrop") }
    }
    /// TMDB 地址（蚂蚁同款默认 http://api.tmdb.org；根地址或含 /3 的地址都行）。
    var tmdbApiBase: String {
        get { UserDefaults.standard.string(forKey: "tmdbApiBase") ?? "http://api.tmdb.org" }
        set { UserDefaults.standard.set(newValue, forKey: "tmdbApiBase") }
    }
    var tmdbImageBase: String {
        get { UserDefaults.standard.string(forKey: "tmdbImageBase") ?? "http://images.tmdb.org/t/p" }
        set { UserDefaults.standard.set(newValue, forKey: "tmdbImageBase") }
    }
    var tmdbLanguage: String {
        get { UserDefaults.standard.string(forKey: "tmdbLanguage") ?? "zh-CN" }
        set { UserDefaults.standard.set(newValue, forKey: "tmdbLanguage") }
    }
    func tmdbCacheGet(_ key: String) -> (String, String, Double)? {
        let d = UserDefaults.standard.dictionary(forKey: "tmdbCache") as? [String: [String]] ?? [:]
        guard let v = d[key], v.count >= 2 else { return nil }
        // 旧缓存只有两项（无评分），读不到评分就当 0，不清缓存。
        return (v[0], v[1], v.count >= 3 ? Double(v[2]) ?? 0 : 0)
    }
    func tmdbCachePut(_ key: String, poster: String, backdrop: String, score: Double) {
        var d = UserDefaults.standard.dictionary(forKey: "tmdbCache") as? [String: [String]] ?? [:]
        if d.count > 500 { d = [:] }
        d[key] = [poster, backdrop, String(score)]
        UserDefaults.standard.set(d, forKey: "tmdbCache")
    }
    func tmdbCacheClear() { UserDefaults.standard.removeObject(forKey: "tmdbCache") }
}
