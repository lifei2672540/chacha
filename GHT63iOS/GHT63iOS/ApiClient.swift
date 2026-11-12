import Foundation

/// 与 TV 版 ApiClient.kt 同款后端契约：全部走自家 proxy.php。
/// 搜索 wd/type/pg/disabled_sources；进度 get/save/delete_progress；
/// 追剧 get/save_favorites；源列表 get_sources；流代理 stream_url。
final class ApiClient {
    static let shared = ApiClient()
    private init() {}

    var base: String {
        get { UserDefaults.standard.string(forKey: "serverBase") ?? "http://test.lifei555.cloudns.be/点播" }
        set { UserDefaults.standard.set(newValue, forKey: "serverBase") }
    }
    private var baseUrl: String { base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    /// Telegram 采集端地址（软路由，TV 版 Prefs.tgBase 同款默认值，本机存）。
    var tgBase: String {
        get { UserDefaults.standard.string(forKey: "tgBase") ?? "http://192.168.31.254:8899" }
        set { UserDefaults.standard.set(newValue, forKey: "tgBase") }
    }
    var tgBaseUrl: String { tgBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    private let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private func getJSON(_ urlString: String) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw NSError(domain: "GHT63", code: -1, userInfo: [NSLocalizedDescriptionKey: "地址无效"]) }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any] ?? [:]
    }

    private func getJSONArray(_ urlString: String) async throws -> [[String: Any]] {
        guard let url = URL(string: urlString) else { throw NSError(domain: "GHT63", code: -1, userInfo: [NSLocalizedDescriptionKey: "地址无效"]) }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    private func postJSON(_ urlString: String, body: Any) async throws {
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: req)
    }

    private func query(_ params: [(String, String)]) -> String {
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        return comps.percentEncodedQuery ?? ""
    }

    // MARK: 搜索（返回聚合组、页码、总页数）
    func search(wd: String, type: String, pg: Int, disabled: [String] = []) async throws -> ([VodGroup], Int, Int) {
        let q = query([("wd", wd), ("type", type), ("pg", "\(pg)"), ("disabled_sources", disabled.joined(separator: ","))])
        let root = try await getJSON("\(baseUrl)/proxy.php?\(q)")
        let list = (root["list"] as? [[String: Any]]) ?? []
        return (groupByName(list), root["page"] as? Int ?? pg, root["pagecount"] as? Int ?? 1)
    }

    // MARK: 云端进度
    func getProgress() async throws -> [String: ProgressRec] {
        let root = try await getJSON("\(baseUrl)/proxy.php?action=get_progress")
        var out: [String: ProgressRec] = [:]
        for (url, v) in (root["data"] as? [String: [String: Any]]) ?? [:] {
            out[url] = ProgressRec(time: v["time"] as? Double ?? 0, duration: v["duration"] as? Double ?? 0,
                                   title: v["title"] as? String ?? "", updated: v["updated"] as? Double ?? 0)
        }
        return out
    }

    func saveProgress(url: String, time: Double, title: String, duration: Double) async {
        try? await postJSON("\(baseUrl)/proxy.php?action=save_progress",
                            body: ["key": url, "time": time, "title": title, "duration": duration])
    }

    func deleteProgress(url: String, drama: String) async {
        try? await postJSON("\(baseUrl)/proxy.php?action=delete_progress",
                            body: ["key": url, "drama": drama])
    }

    // MARK: 源列表
    func getSources() async throws -> ([String], [SourceInfo]) {
        let root = try await getJSON("\(baseUrl)/proxy.php?action=get_sources")
        let builtin = (root["all_available_sources"] as? [String]) ?? []
        let custom = ((root["custom_sources"] as? [[String: Any]]) ?? []).compactMap { o -> SourceInfo? in
            guard let n = o["name"] as? String, !n.isEmpty else { return nil }
            return SourceInfo(name: n, type: o["type"] as? String ?? "", url: o["url"] as? String ?? "")
        }
        return (builtin, custom)
    }

    /// 首页资源站点对应的 disabled 列表（空 = 全部站聚合；站名不在列表里也回落聚合）。
    func homeDisabled() async throws -> [String] {
        let home = UserDefaults.standard.string(forKey: "homeStation") ?? ""
        guard !home.isEmpty else { return [] }
        let (b, c) = try await getSources()
        let all = b + c.map { $0.name }
        return all.contains(home) ? all.filter { $0 != home } : []
    }

    // MARK: 采集站自己的分类（直接问本站 MacCMS ac=list，浏览器 UA）
    func getSiteTypes(apiUrl: String) async throws -> [SiteType] {
        let sep = apiUrl.contains("?") ? "&" : "?"
        guard let url = URL(string: "\(apiUrl)\(sep)ac=list") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((root["class"] as? [[String: Any]]) ?? []).compactMap { o in
            guard let n = o["type_name"] as? String, !n.isEmpty else { return nil }
            return SiteType(id: o["type_id"] as? Int ?? 0, name: n, pid: o["type_pid"] as? Int ?? 0)
        }
    }

    /// 采集站分类（内置站按站名问服务端，服务端按名找到站地址后代问本站 ac=list）。
    func getSiteTypesByName(_ name: String) async throws -> [SiteType] {
        let q = query([("name", name)])
        let root = try await getJSON("\(baseUrl)/proxy.php?action=get_site_types&\(q)")
        return ((root["types"] as? [[String: Any]]) ?? []).compactMap { o in
            guard let n = o["type_name"] as? String, !n.isEmpty else { return nil }
            return SiteType(id: o["type_id"] as? Int ?? 0, name: n, pid: o["type_pid"] as? Int ?? 0)
        }
    }

    // MARK: 追剧
    func getFavorites() async throws -> [FavItem] {
        let root = try await getJSON("\(baseUrl)/proxy.php?action=get_favorites")
        return ((root["data"] as? [[String: Any]]) ?? []).map { FavItem.fromJSON($0) }
    }

    func saveFavorites(_ list: [FavItem]) async {
        try? await postJSON("\(baseUrl)/proxy.php?action=save_favorites", body: list.map { $0.toJSON() })
    }

    // MARK: Telegram 采集端（TV 版 getTgChannels/getTgFeed 同款）
    func getTgChannels() async throws -> [TgChannel] {
        let arr = try await getJSONArray("\(tgBaseUrl)/api/channels")
        return arr.compactMap { o -> TgChannel? in
            guard let k = o["key"] as? String, !k.isEmpty else { return nil }
            return TgChannel(key: k, title: o["title"] as? String ?? k,
                             count: o["count"] as? Int ?? 0)
        }
    }

    func getTgFeed(channel: String, page: Int, pageSize: Int = 30) async throws -> (Int, [TgVideo]) {
        let q = query([("channel", channel), ("page", "\(page)"), ("page_size", "\(pageSize)")])
        let root = try await getJSON("\(tgBaseUrl)/api/feed?\(q)")
        let total = root["total"] as? Int ?? 0
        let items = ((root["items"] as? [[String: Any]]) ?? []).compactMap { o -> TgVideo? in
            guard let id = o["id"] as? String, !id.isEmpty else { return nil }
            let dur: Double
            if let d = o["duration"] as? Double { dur = d }
            else if let d = o["duration"] as? Int { dur = Double(d) }
            else { dur = 0 }
            return TgVideo(id: id, channel: o["channel"] as? String ?? "",
                           channelTitle: o["channel_title"] as? String ?? "",
                           title: o["title"] as? String ?? "",
                           caption: o["caption"] as? String ?? "",
                           date: o["date"] as? String ?? "", duration: dur,
                           thumbUrl: o["thumb_url"] as? String ?? "",
                           streamUrl: o["stream_url"] as? String ?? "")
        }
        return (total, items)
    }

    // MARK: 云端字幕（网页版 autoFetchSubtitle 同款：proxy.php 问 assrt）
    func getSubtitle(title: String) async throws -> (String, String) {
        let q = query([("title", title)])
        let root = try await getJSON("\(baseUrl)/proxy.php?action=get_subtitle&\(q)")
        return (root["sub_url"] as? String ?? "", root["sub_name"] as? String ?? "")
    }

    /// 取字幕文件文本（UTF-8 优先，GBK 兜底）。
    func fetchText(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw NSError(domain: "GHT63", code: -1, userInfo: [NSLocalizedDescriptionKey: "地址无效"]) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        if let s = String(data: data, encoding: .utf8) { return s }
        let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_2312_80.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gbk)) { return s }
        return ""
    }

    // MARK: 流代理（防盗链兜底，播放失败时用）
    func streamUrl(_ raw: String) -> String {
        "\(baseUrl)/proxy.php?stream_url=\(raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)"
    }
}
