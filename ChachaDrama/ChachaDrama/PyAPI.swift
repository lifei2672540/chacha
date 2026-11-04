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

    /// 订阅解析（TV 同款口径：type==3 且 api 以 .py 结尾或含 .py?）。
    static func subscription(url: String = defaultSubscription) async throws -> [PySource] {
        let text = try await fetchText(url)
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sites = o["sites"] as? [[String: Any]] else {
            throw PySpider.PyError.bridge("订阅解析失败")
        }
        return sites.compactMap { s in
            guard let type = s["type"] as? Int, type == 3,
                  let api = s["api"] as? String else { return nil }
            let low = api.lowercased()
            guard low.hasSuffix(".py") || low.contains(".py?") else { return nil }
            return PySource(name: s["name"] as? String ?? api, api: api, ext: s["ext"] as? String ?? "")
        }
    }

    static func script(api: String) async throws -> String {
        if let c = cacheQueue.sync(execute: { scriptCache[api] }) { return c }
        let code = try await fetchText(api)
        cacheQueue.sync { scriptCache[api] = code }
        return code
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

    private static func dramas(source: PySource, from list: [[String: Any]]) -> [Drama] {
        list.map { v in
            Drama(vodId: "\(v["vod_id"] ?? "")",
                  name: v["vod_name"] as? String ?? "",
                  pic: v["vod_pic"] as? String ?? "",
                  remarks: v["vod_remarks"] as? String ?? "",
                  source: source)
        }
    }

    /// home：返回（分类，推荐列表）。
    static func home(source: PySource) async throws -> (classes: [PyClass], items: [Drama]) {
        let o = try await call(source: source, method: "home", argsJson: "[]")
        let classes = (o["class"] as? [[String: Any]] ?? []).compactMap { c -> PyClass? in
            guard let n = c["type_name"] as? String, !n.isEmpty else { return nil }
            return PyClass(id: "\(c["type_id"] ?? "")", name: n)
        }
        return (classes, dramas(source: source, from: o["list"] as? [[String: Any]] ?? []))
    }

    /// category：返回（本页列表，总页数）。
    static func category(source: PySource, tid: String, pg: Int) async throws -> (items: [Drama], pagecount: Int) {
        let o = try await call(source: source, method: "category", argsJson: jsonArgs([tid, pg]))
        let items = dramas(source: source, from: o["list"] as? [[String: Any]] ?? [])
        let pc = o["pagecount"] as? Int ?? (Int("\(o["pagecount"] ?? 1)") ?? 1)
        return (items, max(pc, 1))
    }

    static func search(source: PySource, wd: String) async throws -> [Drama] {
        let o = try await call(source: source, method: "search", argsJson: jsonArgs([wd, 1]))
        return dramas(source: source, from: o["list"] as? [[String: Any]] ?? [])
    }

    /// detail：vod_play_from 按 $$$ 切线路（即 pyFlag），vod_play_url 按 $$$/ # /首个 $ 切集。
    static func detail(source: PySource, drama: Drama) async throws -> DramaDetail {
        let o = try await call(source: source, method: "detail", argsJson: jsonArgs([drama.vodId]))
        guard let v = (o["list"] as? [[String: Any]])?.first else {
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

    /// play：返回（parse，真实地址，防盗链头）。parse!=0 或地址空 = 这条线路播不了。
    static func play(source: PySource, flag: String, playId: String) async throws -> (parse: Int, url: String, headers: [String: String]) {
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

/// 本机状态：关注、点赞、续播、订阅地址（全部只存本机）。
@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published private(set) var favorites: [FavoriteDrama] = []
    @Published private(set) var liked: Set<String> = []
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
    }

    nonisolated var subURL: String {
        get { UserDefaults.standard.string(forKey: "dramaSubUrl") ?? PyAPI.defaultSubscription }
        set { UserDefaults.standard.set(newValue, forKey: "dramaSubUrl") }
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
}
