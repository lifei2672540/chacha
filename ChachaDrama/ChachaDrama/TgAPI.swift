import Foundation
import SwiftUI

// MARK: - Telegram 采集端（软路由 tg_collect，8899）
// 与茶茶点播的 TgViews/ApiClient 同款口径，另接新版采集端的剧聚合、频道开关、补全、扫码登录。

struct TgChannel: Identifiable, Hashable {
    var id: String { key }
    var key: String
    var title: String
    var count: Int
    var enabled: Bool
}

struct TgVideo: Identifiable, Hashable {
    var id: String
    var channel: String
    var channelTitle: String
    var title: String
    var caption: String
    var date: String
    var duration: Double
    var thumbUrl: String
    var streamUrl: String
    var show: String?
    var episodeNo: Int

    func metaLine() -> String {
        [fmtTgDuration(duration), String(date.prefix(10))].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 相对路径按采集端地址拼绝对地址；绝对地址与空串原样返回。
    func absUrl(_ base: String, _ u: String) -> String {
        if u.isEmpty || u.hasPrefix("http://") || u.hasPrefix("https://") { return u }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + u
    }

    /// 第几集的显示：集数识别到了就显示“第 N 集”，否则显示标题。
    var epLabel: String {
        episodeNo > 0 ? "第\(episodeNo)集" : title
    }
}

struct TgShow: Identifiable, Hashable {
    var id: String // 采集端给的 id（剧名 URL 编码）
    var name: String
    var epCount: Int
    var total: Int
    var cover: String // /thumb/<item_id> 或空
    var latest: String
    var channels: [String]
}

struct TgShowDetail {
    var show: TgShow
    var episodes: [TgVideo]

    /// 缺哪些集：1..最大集号之间没出现的集号（采集端同款算法）。
    var missing: [Int] {
        let nums = Set(episodes.map { $0.episodeNo }.filter { $0 > 0 })
        guard let maxNo = nums.max() else { return [] }
        return (1...maxNo).filter { !nums.contains($0) }
    }
}

enum TgAPI {
    /// 采集端地址（本机存，与茶茶点播同款默认值、同一个 UserDefaults 键名但各 App 各存各的）。
    static var base: String {
        get { UserDefaults.standard.string(forKey: "tgBase") ?? "http://192.168.31.254:8899" }
        set { UserDefaults.standard.set(newValue, forKey: "tgBase") }
    }
    static var baseUrl: String { base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static func getJSON(_ urlString: String, timeout: TimeInterval = 60) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw NSError(domain: "TG", code: -1, userInfo: [NSLocalizedDescriptionKey: "地址无效"]) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func getJSONArray(_ urlString: String) async throws -> [[String: Any]] {
        guard let url = URL(string: urlString) else { throw NSError(domain: "TG", code: -1, userInfo: [NSLocalizedDescriptionKey: "地址无效"]) }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    private static func postJSON(_ urlString: String, body: [String: Any], timeout: TimeInterval = 60) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw NSError(domain: "TG", code: -1, userInfo: [NSLocalizedDescriptionKey: "地址无效"]) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(domain: "TG", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg ?? "请求失败（\(http.statusCode)）"])
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func duration(from o: [String: Any]) -> Double {
        if let d = o["duration"] as? Double { return d }
        if let d = o["duration"] as? Int { return Double(d) }
        return 0
    }

    private static func video(from o: [String: Any]) -> TgVideo? {
        guard let id = o["id"] as? String, !id.isEmpty else { return nil }
        return TgVideo(id: id, channel: o["channel"] as? String ?? "",
                       channelTitle: o["channel_title"] as? String ?? "",
                       title: o["title"] as? String ?? "",
                       caption: o["caption"] as? String ?? "",
                       date: o["date"] as? String ?? "", duration: duration(from: o),
                       thumbUrl: o["thumb_url"] as? String ?? "",
                       streamUrl: o["stream_url"] as? String ?? "",
                       show: o["show"] as? String,
                       episodeNo: o["episode_no"] as? Int ?? 0)
    }

    private static func show(from o: [String: Any]) -> TgShow? {
        guard let id = o["id"] as? String, !id.isEmpty else { return nil }
        return TgShow(id: id, name: o["name"] as? String ?? "",
                      epCount: o["ep_count"] as? Int ?? 0,
                      total: o["total"] as? Int ?? 0,
                      cover: o["cover"] as? String ?? "",
                      latest: o["latest"] as? String ?? "",
                      channels: o["channels"] as? [String] ?? [])
    }

    // MARK: 频道
    static func getChannels() async throws -> [TgChannel] {
        let arr = try await getJSONArray("\(baseUrl)/api/channels")
        return arr.compactMap { o -> TgChannel? in
            guard let k = o["key"] as? String, !k.isEmpty else { return nil }
            return TgChannel(key: k, title: o["title"] as? String ?? k,
                             count: o["count"] as? Int ?? 0,
                             enabled: o["enabled"] as? Bool ?? true)
        }
    }

    static func toggleChannel(key: String, enabled: Bool) async throws -> Bool {
        let root = try await postJSON("\(baseUrl)/api/chats/toggle", body: ["key": key, "enabled": enabled])
        return root["enabled"] as? Bool ?? enabled
    }

    // MARK: 视频列表（老接口，照常可用）
    static func getFeed(channel: String, page: Int, pageSize: Int = 30) async throws -> (Int, [TgVideo]) {
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "channel", value: channel),
                            URLQueryItem(name: "page", value: "\(page)"),
                            URLQueryItem(name: "page_size", value: "\(pageSize)")]
        let root = try await getJSON("\(baseUrl)/api/feed?\(comps.percentEncodedQuery ?? "")")
        let total = root["total"] as? Int ?? 0
        let items = ((root["items"] as? [[String: Any]]) ?? []).compactMap { video(from: $0) }
        return (total, items)
    }

    // MARK: 剧聚合
    static func getShows(page: Int, pageSize: Int = 30) async throws -> (Int, [TgShow]) {
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "page", value: "\(page)"),
                            URLQueryItem(name: "page_size", value: "\(pageSize)")]
        let root = try await getJSON("\(baseUrl)/api/shows?\(comps.percentEncodedQuery ?? "")")
        let total = root["total"] as? Int ?? 0
        let shows = ((root["shows"] as? [[String: Any]]) ?? []).compactMap { show(from: $0) }
        return (total, shows)
    }

    static func getShowDetail(show: TgShow) async throws -> TgShowDetail {
        let root = try await getJSON("\(baseUrl)/api/shows/\(show.id)")
        // 参数名 show 会盖住下面同名的静态解析函数 show(from:)，
        // 这里必须写全 TgAPI.show(from:) 才能调到它。
        guard let s = TgAPI.show(from: root) else {
            throw NSError(domain: "TG", code: -1, userInfo: [NSLocalizedDescriptionKey: "剧详情解析失败"])
        }
        let eps = ((root["episodes"] as? [[String: Any]]) ?? []).compactMap { video(from: $0) }
        return TgShowDetail(show: s, episodes: eps)
    }

    /// 缺集补全：采集端用 #剧名 在频道里搜，把漏的集找回来。返回（补回集数，仍缺的集号）。
    static func fillShow(show: TgShow) async throws -> (Int, [Int]) {
        let root = try await postJSON("\(baseUrl)/api/shows/\(show.id)/fill", body: [:], timeout: 200)
        let added = root["added"] as? Int ?? 0
        let missing = (root["missing"] as? [Int]) ?? []
        return (added, missing)
    }

    // MARK: 扫码登录
    static func getAuthStatus() async throws -> (authorized: Bool, phase: String) {
        let root = try await getJSON("\(baseUrl)/api/auth/status")
        return (root["authorized"] as? Bool ?? false, root["phase"] as? String ?? "")
    }

    /// 取扫码登录二维码内容（App 端渲染成二维码图）；已登录返回 authorized=true、无 url。
    static func getAuthQR() async throws -> (authorized: Bool, url: String?) {
        let root = try await getJSON("\(baseUrl)/api/auth/qr", timeout: 30)
        if let err = root["error"] as? String {
            throw NSError(domain: "TG", code: -1, userInfo: [NSLocalizedDescriptionKey: err])
        }
        return (root["authorized"] as? Bool ?? false, root["url"] as? String)
    }

    /// 扫码通过后补两步验证密码（密码只当次用，不落盘、不存本机）。
    static func submitAuthPassword(_ password: String) async throws -> Bool {
        let root = try await postJSON("\(baseUrl)/api/auth/password", body: ["password": password], timeout: 60)
        if let err = root["error"] as? String {
            throw NSError(domain: "TG", code: -1, userInfo: [NSLocalizedDescriptionKey: err])
        }
        return root["authorized"] as? Bool ?? false
    }
}

func fmtTgDuration(_ sec: Double) -> String {
    guard sec > 0 else { return "" }
    let s = Int(sec)
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - TG 本机状态：收藏的剧、继续观看（只存本机，不走采集端）

struct TgFavShow: Identifiable, Codable, Hashable {
    var id: String // 剧名（采集端 show id 即剧名编码，收藏按名认剧）
    var name: String
    var cover: String
}

struct TgResume: Identifiable, Codable, Hashable {
    var id: String // 流地址，唯一
    var showId: String
    var showName: String
    var cover: String
    var epNo: Int
    var epTitle: String
    var streamUrl: String
    var thumbUrl: String
    var time: Double
    var updatedAt: Date
}

@MainActor
final class TgStore: ObservableObject {
    static let shared = TgStore()
    @Published private(set) var favorites: [TgFavShow] = []
    @Published private(set) var resumes: [TgResume] = []

    private init() {
        if let d = UserDefaults.standard.data(forKey: "tgFavorites"),
           let arr = try? JSONDecoder().decode([TgFavShow].self, from: d) {
            favorites = arr
        }
        if let d = UserDefaults.standard.data(forKey: "tgResumes"),
           let arr = try? JSONDecoder().decode([TgResume].self, from: d) {
            resumes = arr
        }
    }

    func isFavorite(showId: String) -> Bool {
        favorites.contains { $0.id == showId }
    }

    func toggleFavorite(show: TgShow) {
        if let i = favorites.firstIndex(where: { $0.id == show.id }) {
            favorites.remove(at: i)
        } else {
            favorites.append(TgFavShow(id: show.id, name: show.name, cover: show.cover))
        }
        if let d = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(d, forKey: "tgFavorites")
        }
    }

    /// 继续观看：只记看到 5 秒以上的集；同一流地址反复写只更新时间，不重复占位；只留最近 20 条。
    func saveResume(showId: String, showName: String, cover: String, video: TgVideo, time: Double) {
        guard time > 5, !video.streamUrl.isEmpty else { return }
        let item = TgResume(id: video.streamUrl, showId: showId, showName: showName,
                            cover: cover, epNo: video.episodeNo, epTitle: video.title,
                            streamUrl: video.streamUrl, thumbUrl: video.thumbUrl,
                            time: time, updatedAt: Date())
        if let i = resumes.firstIndex(where: { $0.id == item.id }) {
            resumes[i] = item
        } else {
            resumes.insert(item, at: 0)
        }
        resumes = Array(resumes.prefix(20))
        if let d = try? JSONEncoder().encode(resumes) {
            UserDefaults.standard.set(d, forKey: "tgResumes")
        }
    }

    func removeResume(id: String) {
        resumes.removeAll { $0.id == id }
        if let d = try? JSONEncoder().encode(resumes) {
            UserDefaults.standard.set(d, forKey: "tgResumes")
        }
    }

    func clearResumes() {
        resumes = []
        if let d = try? JSONEncoder().encode(resumes) {
            UserDefaults.standard.set(d, forKey: "tgResumes")
        }
    }
}
