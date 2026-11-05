import SwiftUI

/// PY 订阅源（TV 版 PyActivity 同款口径）。
struct PySource: Identifiable, Hashable {
    var id: String { api }
    var name: String
    var api: String
    var ext: String
    /// 去掉开头的表情/符号前缀（TV 同款）。
    var displayName: String {
        var s = name
        while let f = s.unicodeScalars.first, !CharacterSet.alphanumerics.contains(f) {
            s.removeFirst()
        }
        return s.isEmpty ? name : s
    }
    /// CMS 站：ext 记为 "cms:0"（XML）或 "cms:1"（JSON），不走 PY。
    var isCMS: Bool { ext.hasPrefix("cms:") }
    var cmsType: Int? { ext == "cms:0" ? 0 : ext == "cms:1" ? 1 : nil }
}

struct PyClass: Identifiable, Hashable {
    var id: String
    var name: String
}

/// 短剧：一部剧（home/分类/搜索列表里的一项）。
struct Drama: Identifiable, Hashable {
    var id: String { source.api + "|" + vodId }
    var vodId: String
    var name: String
    var pic: String
    var remarks: String
    var source: PySource
}

/// 一集：detail 里某条线路下的一项。id 用剧 id + 线路内序号，保证唯一。
struct DramaEpisode: Identifiable, Hashable {
    var id: String
    var index: Int
    var title: String
    var url: String // playId，传给 playerContent
}

struct DramaLine: Hashable {
    var label: String // pyFlag，即 vod_play_from 里的一项
    var episodes: [DramaEpisode]
}

struct DramaDetail {
    var drama: Drama
    var content: String
    var remarks: String
    var lines: [DramaLine]
}

/// 收藏的剧（存本机，供“关注”页用）。
struct FavoriteDrama: Identifiable, Codable, Hashable {
    var id: String
    var vodId: String
    var name: String
    var pic: String
    var sourceApi: String
    var sourceName: String
    var sourceExt: String
    func toDrama() -> Drama {
        Drama(vodId: vodId, name: name, pic: pic, remarks: "",
              source: PySource(name: sourceName, api: sourceApi, ext: sourceExt))
    }
}

enum PyAPI {
    static let defaultSubscription = "http://test.lifei555.cloudns.be/影视/v1/ok海豚.json"
    private static var scriptCache: [String: String] = [:]
    private static let cacheQueue = DispatchQueue(label: "com.chacha.drama.pyscriptcache")

    static func fetchText(_ urlString: String) async throws -> String {
        guard let enc = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: enc) else {
            throw PySpider.PyError.bridge("地址无效：\(urlString)")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let s = String(data: data, encoding: .utf8) else {
            throw PySpider.PyError.bridge("返回的不是 UTF-8 文本")
        }
        return s
    }

    /// 订阅解析（TV 同款口径：type==3 且 api 以 .py 结尾或含 .py?；另接 CMS 站：type 1 JSON、type 0 XML）。
    static func subscription(url: String = defaultSubscription) async throws -> [PySource] {
        let text = try await fetchText(url)
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sites = o["sites"] as? [[String: Any]] else {
            throw PySpider.PyError.bridge("订阅解析失败")
        }
        return sites.compactMap { s in
            guard let type = s["type"] as? Int,
                  let api = s["api"] as? String else { return nil }
            if type == 3 {
                let low = api.lowercased()
                guard low.hasSuffix(".py") || low.contains(".py?") else { return nil }
                return PySource(name: s["name"] as? String ?? api, api: api, ext: s["ext"] as? String ?? "")
            }
            if type == 0 || type == 1 {
                return PySource(name: s["name"] as? String ?? api, api: api, ext: "cms:\(type)")
            }
            return nil
        }
    }

    static func script(api: String) async throws -> String {
        if let c = cacheQueue.sync(execute: { scriptCache[api] }) { return c }
        let code = try await fetchText(api)
        cacheQueue.sync { scriptCache[api] = code }
        return code
    }

    /// 刷新订阅时清掉已缓存的 PY 脚本：接口里新加的源、或改过的脚本，下次用时重新拉，不吃旧缓存。
    static func clearScriptCache() {
        cacheQueue.sync { scriptCache.removeAll() }
    }

    /// 桥调用必须离主线程：PySpider.run 是同步调用，蜘蛛里有网络时会堵住调用线程。
    static func runOffMain(code: String, ext: String, method: String, argsJson: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try PySpider.run(code: code, ext: ext, method: method, argsJson: argsJson)
        }.value
    }

    static func call(source: PySource, method: String, argsJson: String) async throws -> [String: Any] {
        let code = try await script(api: source.api)
        let json = try await runOffMain(code: code, ext: source.ext, method: method, argsJson: argsJson)
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw PySpider.PyError.bridge("桥返回的不是 JSON")
        }
        if let err = o["__error__"] as? String { throw PySpider.PyError.bridge(err) }
        return o
    }

    private static func jsonArgs(_ values: [Any]) -> String {
        let d = try? JSONSerialization.data(withJSONObject: values)
        return d.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func dramas(source: PySource, from list: [[String: Any]]) -> [Drama] {
        list.map { v in
            Drama(vodId: "\(v["vod_id"] ?? "")",
                  name: v["vod_name"] as? String ?? "",
                  pic: v["vod_pic"] as? String ?? "",
                  remarks: v["vod_remarks"] as? String ?? "",
                  source: source)
        }
    }

    /// 分类列表：PY 与 CMS 返回的 class 字段口径相同。
    static func classes(from list: [[String: Any]]) -> [PyClass] {
        list.compactMap { c -> PyClass? in
            guard let n = c["type_name"] as? String, !n.isEmpty else { return nil }
            return PyClass(id: "\(c["type_id"] ?? "")", name: n)
        }
    }

    /// home：返回（分类，推荐列表）。
    static func home(source: PySource) async throws -> (classes: [PyClass], items: [Drama]) {
        if source.isCMS { return try await CmsAPI.home(source: source) }
        let o = try await call(source: source, method: "home", argsJson: "[]")
        return (classes(from: o["class"] as? [[String: Any]] ?? []),
                dramas(source: source, from: o["list"] as? [[String: Any]] ?? []))
    }

    /// category：返回（本页列表，总页数）。
    static func category(source: PySource, tid: String, pg: Int) async throws -> (items: [Drama], pagecount: Int) {
        if source.isCMS { return try await CmsAPI.category(source: source, tid: tid, pg: pg) }
        let o = try await call(source: source, method: "category", argsJson: jsonArgs([tid, pg]))
        let items = dramas(source: source, from: o["list"] as? [[String: Any]] ?? [])
        let pc = o["pagecount"] as? Int ?? (Int("\(o["pagecount"] ?? 1)") ?? 1)
        return (items, max(pc, 1))
    }

    static func search(source: PySource, wd: String) async throws -> [Drama] {
        if source.isCMS { return try await CmsAPI.search(source: source, wd: wd) }
        let o = try await call(source: source, method: "search", argsJson: jsonArgs([wd, 1]))
        return dramas(source: source, from: o["list"] as? [[String: Any]] ?? [])
    }

    /// detail 列表解析：PY 与 CMS 详情返回的字段口径相同
    ///（vod_play_from 按 $$$ 切线路，vod_play_url 按 $$$/ # /首个 $ 切集）。
    static func detailFromList(drama: Drama, list: [[String: Any]]) throws -> DramaDetail {
        guard let v = list.first else {
            throw PySpider.PyError.bridge("详情为空")
        }
        let froms = (v["vod_play_from"] as? String ?? "").components(separatedBy: "$$$")
        let urlGroups = (v["vod_play_url"] as? String ?? "").components(separatedBy: "$$$")
        var lines: [DramaLine] = []
        for (idx, from) in froms.enumerated() {
            guard idx < urlGroups.count else { break }
            var eps: [DramaEpisode] = []
            for (ei, item) in urlGroups[idx].components(separatedBy: "#").enumerated() {
                guard let d = item.firstIndex(of: "$"), d != item.startIndex else { continue }
                eps.append(DramaEpisode(id: drama.id + "|\(idx)|\(ei)",
                                        index: ei,
                                        title: String(item[..<d]),
                                        url: String(item[item.index(after: d)...])))
            }
            lines.append(DramaLine(label: from, episodes: eps))
        }
        return DramaDetail(drama: drama,
                           content: v["vod_content"] as? String ?? "",
                           remarks: v["vod_remarks"] as? String ?? "",
                           lines: lines)
    }

    /// detail：vod_play_from 按 $$$ 切线路（即 pyFlag），vod_play_url 按 $$$/ # /首个 $ 切集。
    static func detail(source: PySource, drama: Drama) async throws -> DramaDetail {
        if source.isCMS { return try await CmsAPI.detail(source: source, drama: drama) }
        let o = try await call(source: source, method: "detail", argsJson: jsonArgs([drama.vodId]))
        return try detailFromList(drama: drama, list: o["list"] as? [[String: Any]] ?? [])
    }

    /// play：返回（parse，真实地址，防盗链头）。parse!=0 或地址空 = 这条线路播不了。
    /// CMS 站没有 play 解析这一步，vod_play_url 里切出来的就是直链。
    static func play(source: PySource, flag: String, playId: String) async throws -> (parse: Int, url: String, headers: [String: String]) {
        if source.isCMS { return (0, playId, [:]) }
        let o = try await call(source: source, method: "play", argsJson: jsonArgs([flag, playId]))
        let parse = o["parse"] as? Int ?? (Int("\(o["parse"] ?? 0)") ?? 0)
        var headers: [String: String] = [:]
        if let h = o["header"] as? [String: Any] {
            for (k, v) in h { headers[k] = "\(v)" }
        } else if let hs = o["header"] as? String,
                  let d = hs.data(using: .utf8),
                  let h = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in h { headers[k] = "\(v)" }
        }
        return (parse, o["url"] as? String ?? "", headers)
    }
}

/// 继续观看的一条记录：某部剧看到第几集、看到几秒。按更新时间倒序，只留最近 20 条。
struct ResumeItem: Identifiable, Codable, Hashable {
    var id: String // 集 id（剧 id + 线路 + 集序号）
    var vodId: String
    var dramaId: String
    var name: String
    var pic: String
    var sourceApi: String
    var sourceName: String
    var sourceExt: String
    var lineIdx: Int
    var epIdx: Int
    var epTitle: String
    var time: Double
    var updatedAt: Date
    func toDrama() -> Drama {
        Drama(vodId: vodId, name: name, pic: pic, remarks: "",
              source: PySource(name: sourceName, api: sourceApi, ext: sourceExt))
    }
}

/// 本机状态：关注、点赞、续播、继续观看、源健康、订阅地址（全部只存本机）。
@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published private(set) var favorites: [FavoriteDrama] = []
    @Published private(set) var liked: Set<String> = []
    @Published private(set) var resumes: [ResumeItem] = []
    private var progress: [String: Double] = [:]

    private init() {
        if let d = UserDefaults.standard.data(forKey: "dramaFavorites"),
           let arr = try? JSONDecoder().decode([FavoriteDrama].self, from: d) {
            favorites = arr
        }
        if let arr = UserDefaults.standard.array(forKey: "dramaLiked") as? [String] {
            liked = Set(arr)
        }
        if let dict = UserDefaults.standard.object(forKey: "dramaProgress") as? [String: Double] {
            progress = dict
        }
        if let d = UserDefaults.standard.data(forKey: "dramaResumes"),
           let arr = try? JSONDecoder().decode([ResumeItem].self, from: d) {
            resumes = arr
        }
    }

    nonisolated var subURL: String {
        get { UserDefaults.standard.string(forKey: "dramaSubUrl") ?? PyAPI.defaultSubscription }
        set { UserDefaults.standard.set(newValue, forKey: "dramaSubUrl") }
    }

    /// 多订阅地址列表（新）。老用户只有单个 dramaSubUrl 时，列表就是 [那个地址]，不丢用户自己的地址。
    nonisolated var subURLs: [String] {
        get {
            if let arr = UserDefaults.standard.array(forKey: "dramaSubUrls") as? [String], !arr.isEmpty {
                return arr
            }
            return [subURL]
        }
        set {
            let cleaned = newValue.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            UserDefaults.standard.set(cleaned.isEmpty ? [PyAPI.defaultSubscription] : cleaned, forKey: "dramaSubUrls")
        }
    }

    nonisolated func setActiveSubURL(_ url: String) {
        subURL = url
        if !subURLs.contains(url) { subURLs = subURLs + [url] }
    }

    nonisolated func removeSubURL(_ url: String) {
        var list = subURLs.filter { $0 != url }
        if list.isEmpty { list = [PyAPI.defaultSubscription] }
        subURLs = list
        if subURL == url { subURL = list[0] }
    }

    func isFavorite(drama: Drama) -> Bool {
        favorites.contains { $0.id == drama.id }
    }
    func toggleFavorite(drama: Drama) {
        if let i = favorites.firstIndex(where: { $0.id == drama.id }) {
            favorites.remove(at: i)
        } else {
            favorites.append(FavoriteDrama(id: drama.id, vodId: drama.vodId, name: drama.name,
                                           pic: drama.pic, sourceApi: drama.source.api,
                                           sourceName: drama.source.name, sourceExt: drama.source.ext))
        }
        saveFavorites()
    }
    private func saveFavorites() {
        if let d = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(d, forKey: "dramaFavorites")
        }
    }

    func isLiked(epId: String) -> Bool { liked.contains(epId) }
    func toggleLike(epId: String) {
        if liked.contains(epId) { liked.remove(epId) } else { liked.insert(epId) }
        UserDefaults.standard.set(Array(liked), forKey: "dramaLiked")
    }

    func progress(for epId: String) -> Double { progress[epId] ?? 0 }
    func saveProgress(epId: String, time: Double) {
        guard !epId.isEmpty, time > 0 else { return }
        progress[epId] = time
        UserDefaults.standard.set(progress, forKey: "dramaProgress")
    }

    /// 继续观看：只记看到 5 秒以上的集；同一集反复写只更新时间，不重复占位。
    func saveResume(drama: Drama, lineIdx: Int, episode: DramaEpisode, time: Double) {
        guard time > 5, !episode.id.isEmpty else { return }
        let item = ResumeItem(id: episode.id, vodId: drama.vodId, dramaId: drama.id,
                              name: drama.name, pic: drama.pic,
                              sourceApi: drama.source.api, sourceName: drama.source.name,
                              sourceExt: drama.source.ext, lineIdx: lineIdx, epIdx: episode.index,
                              epTitle: episode.title, time: time, updatedAt: Date())
        if let i = resumes.firstIndex(where: { $0.id == item.id }) {
            resumes[i] = item
        } else {
            resumes.insert(item, at: 0)
        }
        resumes = Array(resumes.prefix(20))
        saveResumes()
    }
    func removeResume(id: String) {
        resumes.removeAll { $0.id == id }
        saveResumes()
    }
    func clearResumes() {
        resumes = []
        saveResumes()
    }
    private func saveResumes() {
        if let d = try? JSONEncoder().encode(resumes) {
            UserDefaults.standard.set(d, forKey: "dramaResumes")
        }
    }

    /// 源健康：只记最近一次成功/失败的时间戳，用时才比。绿=最近成功过，红=最近一次是失败，灰=没试过。
    enum SourceHealth { case ok, failed, unknown }
    nonisolated func markSourceOK(_ api: String) {
        var d = UserDefaults.standard.object(forKey: "dramaSourceOk") as? [String: Double] ?? [:]
        d[api] = Date().timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: "dramaSourceOk")
    }
    nonisolated func markSourceFailed(_ api: String) {
        var d = UserDefaults.standard.object(forKey: "dramaSourceFailed") as? [String: Double] ?? [:]
        d[api] = Date().timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: "dramaSourceFailed")
    }
    nonisolated func sourceHealth(_ api: String) -> SourceHealth {
        let ok = (UserDefaults.standard.object(forKey: "dramaSourceOk") as? [String: Double] ?? [:])[api] ?? 0
        let fail = (UserDefaults.standard.object(forKey: "dramaSourceFailed") as? [String: Double] ?? [:])[api] ?? 0
        if fail > ok && fail > 0 { return .failed }
        if ok > 0 { return .ok }
        return .unknown
    }
}
