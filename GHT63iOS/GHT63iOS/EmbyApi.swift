import Foundation

/// Emby（与 TV 版 EmbyApi.kt 同款 REST 契约）：
/// 服务器与账号不在代码里写死，设置里填一次、本机保存（iOS 源码在公开仓库，
/// 明文写账号等于公开账号；TV 版内置是另一回事）。
/// token 缓存，401 时重登一次重试；全部请求浏览器 UA（过 Cloudflare）。
/// 进度不回同步 Emby，只走 GHT63 本地最近观看（TV 同款限度）。
enum EmbyApi {
    static var server: String {
        get { UserDefaults.standard.string(forKey: "embyServer") ?? "https://bb.emby.edu.kg" }
        set { UserDefaults.standard.set(newValue, forKey: "embyServer") }
    }
    static var username: String {
        get { UserDefaults.standard.string(forKey: "embyUser") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "embyUser") }
    }
    static var password: String {
        get { UserDefaults.standard.string(forKey: "embyPw") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "embyPw") }
    }
    static var token: String {
        get { UserDefaults.standard.string(forKey: "embyToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "embyToken") }
    }
    static var userId: String {
        get { UserDefaults.standard.string(forKey: "embyUserId") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "embyUserId") }
    }
    static var configured: Bool { !username.isEmpty }

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static var authHeader: String {
        "MediaBrowser Client=\"GHT63iOS\", Device=\"iPhone\", DeviceId=\"ght63ios\", Version=\"1.0.0\""
    }

    private static func req(_ path: String, method: String = "GET", body: Any? = nil, authed: Bool = true) -> URLRequest? {
        guard let url = URL(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.httpMethod = method
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        if authed { r.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization") }
        if let body = body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private static func call(_ path: String, method: String = "GET", body: Any? = nil, retry: Bool = true) async throws -> [String: Any] {
        guard var r = req(path, method: method, body: body) else { throw NSError(domain: "Emby", code: -1) }
        if !token.isEmpty, let u = URL(string: r.url!.absoluteString + (r.url!.absoluteString.contains("?") ? "&" : "?") + "api_key=\(token)") {
            r.url = u
        }
        let (data, resp) = try await URLSession.shared.data(for: r)
        if (resp as? HTTPURLResponse)?.statusCode == 401, retry {
            try await login()
            return try await call(path, method: method, body: body, retry: false)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func login() async throws {
        guard let r = req("/Users/AuthenticateByName", method: "POST",
                          body: ["Username": username, "Pw": password], authed: true) else { return }
        let (data, _) = try await URLSession.shared.data(for: r)
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        token = root["AccessToken"] as? String ?? ""
        userId = (root["User"] as? [String: Any])?["Id"] as? String ?? ""
    }

    struct View: Identifiable {
        var id: String
        var name: String
    }

    /// 片库（排除音乐/图书/游戏/播放列表/合集，与 TV 同款）。
    static func views() async throws -> [View] {
        if token.isEmpty { try await login() }
        let root = try await call("/Users/\(userId)/Views")
        let excluded = ["music", "books", "games", "playlists", "boxsets"]
        return ((root["Items"] as? [[String: Any]]) ?? []).compactMap { o in
            let type = (o["CollectionType"] as? String ?? "").lowercased()
            guard !excluded.contains(type) else { return nil }
            return View(id: o["Id"] as? String ?? "", name: o["Name"] as? String ?? "")
        }
    }

    /// 每库最新 100 部（TV 同款限度），电影直出、剧集按季分线。
    static func items(viewId: String) async throws -> [VodGroup] {
        let root = try await call("/Users/\(userId)/Items?ParentId=\(viewId)&IncludeItemTypes=Movie,Series&SortBy=DateCreated&SortOrder=Descending&Limit=100&Recursive=true")
        var out: [VodGroup] = []
        for o in (root["Items"] as? [[String: Any]]) ?? [] {
            let id = o["Id"] as? String ?? ""
            let name = o["Name"] as? String ?? ""
            let year = "\(o["ProductionYear"] as? Int ?? 0)"
            let pic = "\(server)/Items/\(id)/Images/Primary?api_key=\(token)&maxWidth=400&quality=90"
            let overview = o["Overview"] as? String ?? ""
            let type = o["Type"] as? String ?? ""
            if type == "Movie" {
                let line = PlayLine(lineIndex: 1, episodes: [Episode(title: name, url: "emby:\(id)")], label: "")
                out.append(VodGroup(name: name, pic: pic, typeName: "电影", year: year == "0" ? "" : year,
                                    content: overview, sources: [VodSource(sourceLabel: "Emby", remarks: "", actor: "", director: "", lines: [line])],
                                    embyId: id, embyServer: server, embyToken: token))
            } else if type == "Series" {
                let eps = try await episodes(seriesId: id)
                var seasons: [Int: [Episode]] = [:]
                for e in eps { seasons[e.0, default: []].append(e.1) }
                let lines = seasons.keys.sorted().enumerated().map { (i, s) in
                    PlayLine(lineIndex: i + 1, episodes: seasons[s] ?? [], label: s == 0 ? "特别篇" : "第\(s)季")
                }
                out.append(VodGroup(name: name, pic: pic, typeName: "剧集", year: year == "0" ? "" : year,
                                    content: overview, sources: [VodSource(sourceLabel: "Emby", remarks: "", actor: "", director: "", lines: lines)],
                                    embyId: id, embyServer: server, embyToken: token))
            }
        }
        return out
    }

    /// 返回 (季号, 集)；按季号、集号排序。
    private static func episodes(seriesId: String) async throws -> [(Int, Episode)] {
        let root = try await call("/Shows/\(seriesId)/Episodes?UserId=\(userId)&Fields=Overview&Limit=500")
        var out: [(Int, Episode)] = []
        for o in (root["Items"] as? [[String: Any]]) ?? [] {
            let season = o["ParentIndexNumber"] as? Int ?? 0
            let idx = o["IndexNumber"] as? Int ?? 0
            let title = "第\(idx)集"
            out.append((season, Episode(title: title, url: "emby:\(o["Id"] as? String ?? "")")))
        }
        return out.sorted { ($0.0, $0.1.title) < ($1.0, $1.1.title) }
    }

    static func streamUrl(group: VodGroup, episode: Episode) -> String? {
        guard episode.url.hasPrefix("emby:") else { return nil }
        let id = String(episode.url.dropFirst(5))
        return "\(group.embyServer)/Videos/\(id)/stream?api_key=\(group.embyToken)&Static=true"
    }
}
