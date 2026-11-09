import Foundation

/// TMDB v3（与 TV 版 TmdbApi.kt 同款）：search/multi，不过滤外语；
/// 年份优先匹配，退回首个带横图的 movie/tv；海报 w500、横图 w1280。
/// 地址、语言、开关都走设置页（蚂蚁 2.0.6 同款 TMDB 配置页）：根地址或含 /3 的地址都行，
/// 未启用或没 Key 时直接返回 nil，不发请求；网络失败不写缓存；空串表示查过无匹配。
/// 趋势榜一项：只有 TMDB 资料（片名/海报/横图/评分），没有播放地址；
/// 点开后拿片名去自家源里搜（TrendDetailLoader），搜到才进详情。
struct TmdbTrendItem: Identifiable, Hashable {
    var id: String
    var title: String
    var poster: String
    var backdrop: String
    var score: Double
    var mediaType: String   // movie / tv
    var year: String
}

enum TmdbApi {
    /// 趋势榜（网站首页“趋势 今日”同款）：/trending/all/day，电影+剧集混合取前 10；
    /// 没开 TMDB、没 Key 或请求失败都返回空，首页回落到源推荐轮播。
    static func trending() async -> [TmdbTrendItem] {
        guard await Store.shared.tmdbEnabled else { return [] }
        let key = await Store.shared.tmdbKey
        guard !key.isEmpty else { return [] }
        let apiBase = await Store.shared.tmdbApiBase
        let imgBase = await Store.shared.tmdbImageBase
        let lang = await Store.shared.tmdbLanguage
        var comps = URLComponents(string: apiRoot(base: apiBase) + "/trending/all/day")
        guard comps != nil else { return [] }
        comps!.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "language", value: lang.isEmpty ? "zh-CN" : lang),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "page", value: "1"),
        ]
        guard let url = comps!.url else { return [] }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let results = (root["results"] as? [[String: Any]]) ?? []
            let img = imageRoot(base: imgBase)
            var out: [TmdbTrendItem] = []
            for r in results {
                guard let rawId = r["id"] as? Int else { continue }
                let mt = (r["media_type"] as? String) ?? ""
                guard mt == "movie" || mt == "tv" else { continue }
                let title = (r["title"] as? String) ?? (r["name"] as? String) ?? ""
                guard !title.isEmpty else { continue }
                let backdrop = (r["backdrop_path"] as? String).map { "\(img)/w1280\($0)" } ?? ""
                guard !backdrop.isEmpty else { continue }
                let poster = (r["poster_path"] as? String).map { "\(img)/w500\($0)" } ?? ""
                let score = (r["vote_average"] as? Double) ?? 0
                let date = (r["release_date"] as? String) ?? (r["first_air_date"] as? String) ?? ""
                out.append(TmdbTrendItem(id: "\(mt)-\(rawId)", title: title, poster: poster,
                                         backdrop: backdrop, score: score, mediaType: mt,
                                         year: String(date.prefix(4))))
                if out.count >= 10 { break }
            }
            return out
        } catch {
            return []
        }
    }

    /// 根地址归一化：去掉尾部 /，没有 /3 就补 /3。
    static func apiRoot(base: String) -> String {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.isEmpty { return "http://api.tmdb.org/3" }
        return b.hasSuffix("/3") ? b : b + "/3"
    }

    static func imageRoot(base: String) -> String {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return b.isEmpty ? "http://images.tmdb.org/t/p" : b
    }

    static func lookup(title: String, year: String) async -> (poster: String, backdrop: String, score: Double)? {
        guard await Store.shared.tmdbEnabled else { return nil }
        let key = await Store.shared.tmdbKey
        guard !key.isEmpty else { return nil }
        let cacheKey = "\(title)|\(year)"
        if let hit = await Store.shared.tmdbCacheGet(cacheKey) { return hit }
        let apiBase = await Store.shared.tmdbApiBase
        let imgBase = await Store.shared.tmdbImageBase
        let lang = await Store.shared.tmdbLanguage
        guard let found = await search(title: title, year: year, key: key, apiBase: apiBase, imgBase: imgBase, lang: lang) else {
            return nil
        }
        await Store.shared.tmdbCachePut(cacheKey, poster: found.0, backdrop: found.1, score: found.2)
        return found
    }

    /// 测试连接：拿一个固定片名查一次，返回能不能通（设置页“测试连接”用）。
    static func testConnection() async -> String {
        guard await Store.shared.tmdbEnabled else { return "TMDB 资料没启用，先打开“启用 TMDB 资料”" }
        let key = await Store.shared.tmdbKey
        guard !key.isEmpty else { return "还没填 API Key" }
        let apiBase = await Store.shared.tmdbApiBase
        let imgBase = await Store.shared.tmdbImageBase
        let lang = await Store.shared.tmdbLanguage
        if let hit = await search(title: "肖申克的救赎", year: "1994", key: key, apiBase: apiBase, imgBase: imgBase, lang: lang) {
            return hit.0.isEmpty && hit.1.isEmpty ? "连接通了，但这部没匹配到海报" : "连接成功，已匹配到海报"
        }
        return "连接失败：检查 API 地址和 Key 是否正确"
    }

    private static func search(title: String, year: String, key: String, apiBase: String, imgBase: String, lang: String) async -> (String, String, Double)? {
        var comps = URLComponents(string: apiRoot(base: apiBase) + "/search/multi")
        guard comps != nil else { return nil }
        comps!.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "language", value: lang.isEmpty ? "zh-CN" : lang),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        guard let url = comps!.url else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let results = (root["results"] as? [[String: Any]]) ?? []
            let img = imageRoot(base: imgBase)
            var firstWithBackdrop: (String, String, Double)?
            var firstWithPoster: (String, String, Double)?
            for r in results {
                let poster = (r["poster_path"] as? String).map { "\(img)/w500\($0)" } ?? ""
                let backdrop = (r["backdrop_path"] as? String).map { "\(img)/w1280\($0)" } ?? ""
                let score = (r["vote_average"] as? Double) ?? 0
                let date = (r["release_date"] as? String ?? r["first_air_date"] as? String ?? "")
                if firstWithBackdrop == nil && !backdrop.isEmpty { firstWithBackdrop = (poster, backdrop, score) }
                if firstWithPoster == nil && !poster.isEmpty { firstWithPoster = (poster, backdrop, score) }
                if !year.isEmpty && date.hasPrefix(year) && !backdrop.isEmpty {
                    return (poster, backdrop, score)
                }
            }
            return firstWithBackdrop ?? firstWithPoster ?? ("", "", 0)
        } catch {
            return nil
        }
    }
}
