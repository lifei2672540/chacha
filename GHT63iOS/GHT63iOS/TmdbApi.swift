import Foundation

/// TMDB v3（与 TV 版 TmdbApi.kt 同款）：search/multi，zh-CN，不过滤外语；
/// 年份优先匹配，退回首个带横图的 movie/tv；海报 w500、横图 w1280。
/// 网络失败不写缓存；空串表示查过无匹配。
enum TmdbApi {
    static func lookup(title: String, year: String) async -> (poster: String, backdrop: String)? {
        let key = await Store.shared.tmdbKey
        guard !key.isEmpty else { return nil }
        let cacheKey = "\(title)|\(year)"
        if let hit = await Store.shared.tmdbCacheGet(cacheKey) { return hit }
        var comps = URLComponents(string: "https://api.themoviedb.org/3/search/multi")!
        comps.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        guard let url = comps.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let results = (root["results"] as? [[String: Any]]) ?? []
            var firstWithBackdrop: (String, String)?
            var firstWithPoster: (String, String)?
            for r in results {
                let poster = (r["poster_path"] as? String).map { "https://image.tmdb.org/t/p/w500\($0)" } ?? ""
                let backdrop = (r["backdrop_path"] as? String).map { "https://image.tmdb.org/t/p/w1280\($0)" } ?? ""
                let date = (r["release_date"] as? String ?? r["first_air_date"] as? String ?? "")
                if firstWithBackdrop == nil && !backdrop.isEmpty { firstWithBackdrop = (poster, backdrop) }
                if firstWithPoster == nil && !poster.isEmpty { firstWithPoster = (poster, backdrop) }
                if !year.isEmpty && date.hasPrefix(year) && !backdrop.isEmpty {
                    await Store.shared.tmdbCachePut(cacheKey, poster: poster, backdrop: backdrop)
                    return (poster, backdrop)
                }
            }
            let hit = firstWithBackdrop ?? firstWithPoster ?? ("", "")
            await Store.shared.tmdbCachePut(cacheKey, poster: hit.0, backdrop: hit.1)
            return hit
        } catch {
            return nil
        }
    }
}
