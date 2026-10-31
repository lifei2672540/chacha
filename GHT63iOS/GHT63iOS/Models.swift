import Foundation

// MARK: - 播放数据模型（与 TV 版 Models.kt 同款字段，CMS 聚合格式）

struct Episode: Identifiable, Codable, Hashable {
    var id: String { title + "|" + url }
    var title: String
    var url: String
}

struct PlayLine: Identifiable, Codable, Hashable {
    var id: Int { lineIndex }
    var lineIndex: Int
    var episodes: [Episode]
    var label: String
    /// PY 线路在 vod_play_from 里的 flag，播放时传给 playerContent（TV 同款）。
    var pyFlag: String = ""
}

struct VodSource: Identifiable, Codable, Hashable {
    var id: String { sourceLabel }
    var sourceLabel: String
    var remarks: String
    var actor: String
    var director: String
    var lines: [PlayLine]
}

struct VodGroup: Identifiable, Codable, Hashable {
    var id: String { name }
    var name: String
    var pic: String
    var typeName: String
    var year: String
    var content: String
    var sources: [VodSource]
    /// Emby 组：embyId 非空即 Emby 组，播放走 Emby 直链，不走 CMS 线路。
    var embyId: String = ""
    var embyServer: String = ""
    var embyToken: String = ""
    /// PY 组：pyApi 非空即 PY 组，播放走 playerContent 解析，不走 CMS 直链。
    var pyApi: String = ""
    var pyExt: String = ""
    /// PY 浏览列表项的 vod_id（详情页用它调 detailContent；CMS 组不用）。
    var vodId: String = ""

    var allEpisodes: Int { sources.flatMap { $0.lines }.flatMap { $0.episodes }.count }
}

/// 按剧名聚合（与 TV 版 groupByName 一致）：同名不同源并到一组。
func groupByName(_ items: [[String: Any]]) -> [VodGroup] {
    var order: [String] = []
    var map: [String: VodGroup] = [:]
    for vod in items {
        let name = (vod["vod_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { continue }
        let src = VodSource(
            sourceLabel: vod["source_label"] as? String ?? "聚合源",
            remarks: vod["vod_remarks"] as? String ?? "",
            actor: vod["vod_actor"] as? String ?? "",
            director: vod["vod_director"] as? String ?? "",
            lines: parsePlayUrl(vod["vod_play_url"] as? String ?? "")
        )
        if map[name] == nil {
            order.append(name)
            map[name] = VodGroup(
                name: name,
                pic: vod["vod_pic"] as? String ?? "",
                typeName: vod["type_name"] as? String ?? "",
                year: vod["vod_year"] as? String ?? "",
                content: vod["vod_content"] as? String ?? "",
                sources: []
            )
        }
        map[name]!.sources.append(src)
    }
    return order.compactMap { map[$0] }
}

/// 线路 $$$、集 #、集名/地址按第一个 $ 切（与 TV 版 parsePlayUrl 一致）。
func parsePlayUrl(_ raw: String) -> [PlayLine] {
    guard !raw.isEmpty else { return [] }
    var out: [PlayLine] = []
    for (idx, lineGroup) in raw.components(separatedBy: "$$$").enumerated() {
        guard !lineGroup.isEmpty else { continue }
        var eps: [Episode] = []
        for item in lineGroup.components(separatedBy: "#") {
            guard let d = item.firstIndex(of: "$"), d != item.startIndex else { continue }
            eps.append(Episode(title: String(item[..<d]), url: String(item[item.index(after: d)...])))
        }
        out.append(PlayLine(lineIndex: idx + 1, episodes: eps, label: ""))
    }
    return out
}

/// CMS 简介常带 HTML 标签与实体，显示前清掉（与 TV 版 cleanHtmlText 一致）。
func cleanHtmlText(_ raw: String) -> String {
    guard !raw.isEmpty else { return raw }
    var s = raw.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
    return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

// MARK: - 追剧 / 最近 / 进度（与 TV 版云端字段一致，可与 TV、网页端互通）

struct FavItem: Identifiable, Codable, Hashable {
    var id: String { name }
    var name: String
    var pic: String
    var lastEp: String
    var totalEps: Int
    var status: String
    var hasUpdate: Bool = false

    func toJSON() -> [String: Any] {
        ["name": name, "pic": pic, "lastEp": lastEp,
         "totalEps": totalEps, "status": status, "hasUpdate": hasUpdate]
    }
    static func fromJSON(_ o: [String: Any]) -> FavItem {
        FavItem(name: o["name"] as? String ?? "",
                pic: o["pic"] as? String ?? "",
                lastEp: o["lastEp"] as? String ?? "",
                totalEps: o["totalEps"] as? Int ?? 0,
                status: (o["status"] as? String ?? "").isEmpty ? "watching" : (o["status"] as? String ?? ""),
                hasUpdate: o["hasUpdate"] as? Bool ?? false)
    }
}

struct RecentItem: Identifiable, Codable, Hashable {
    var id: String { drama + "|" + epTitle }
    var drama: String
    var epTitle: String
    var url: String
    var pic: String
    var time: Double
    var duration: Double
    var epIndex: Int
    var totalEps: Int
    var updated: Double
    /// PY 剧续播用：url 是蜘蛛播放 id，须凭这三个字段重新解析（TV 同款）。
    var pyApi: String = ""
    var pyFlag: String = ""
    var pyExt: String = ""
}

struct ProgressRec {
    var time: Double
    var duration: Double
    var title: String
    var updated: Double
}

struct SourceInfo: Identifiable {
    var id: String { name }
    var name: String
    var type: String
    var url: String
}

struct SiteType: Identifiable {
    var id: Int
    var name: String
    var pid: Int
}
