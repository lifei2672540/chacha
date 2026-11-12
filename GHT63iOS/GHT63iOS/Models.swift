import Foundation
import SwiftUI

// MARK: - 播放数据模型（与 TV 版 Models.kt 同款字段，CMS 聚合格式）

struct Episode: Identifiable, Codable, Hashable {
    var id: String { title + "|" + url }
    var title: String
    var url: String
    /// 播放请求头（海阔解析出的 Referer/User-Agent；CMS/PY 为空）。
    var headers: [String: String] = [:]
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
    /// 单条线路集数最大值（追剧巡检用；allEpisodes 是所有源线路之和，会多算）。
    var maxLineEpisodes: Int { sources.flatMap { $0.lines }.map { $0.episodes.count }.max() ?? 0 }
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

/// 追剧更新巡检结果（本机存，不走云端）：最新集数 + 是否有更新。
struct FavUpdateInfo: Codable, Hashable {
    var latest: Int
    var hasUpdate: Bool
}

/// 集标题里抠第一个数字（“第12集”→12、“EP12”→12；电影类“正片”→nil，与网页版 /(\d+)/ 同款）。
func episodeNumber(_ title: String) -> Int? {
    guard let r = title.range(of: "\\d+", options: .regularExpression) else { return nil }
    return Int(title[r])
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

// MARK: - Telegram 采集端（与 TV 版 TgChannel/TgVideo 同款，采集端 /api/channels、/api/feed）

struct TgChannel: Identifiable, Hashable {
    var id: String { key }
    var key: String
    var title: String
    var count: Int
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

    func metaLine() -> String {
        [fmtTgDuration(duration), String(date.prefix(10))].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 相对路径按采集端地址拼绝对地址；绝对地址与空串原样返回（TV 同款）。
    func absUrl(_ base: String, _ u: String) -> String {
        if u.isEmpty || u.hasPrefix("http://") || u.hasPrefix("https://") { return u }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + u
    }

    /// 单视频成组：标题即剧名，单源单线单集，点片直进播放器（TV 同款，不走详情页）；
    /// 进度与最近观看按流地址记（播放器本就按集地址记）。
    func toGroup(base: String) -> VodGroup {
        let ep = Episode(title: title, url: absUrl(base, streamUrl))
        let src = VodSource(sourceLabel: channelTitle, remarks: metaLine(), actor: "", director: "",
                            lines: [PlayLine(lineIndex: 1, episodes: [ep], label: "")])
        return VodGroup(name: title, pic: absUrl(base, thumbUrl), typeName: "Telegram",
                        year: String(date.prefix(4)), content: caption, sources: [src])
    }
}

func fmtTgDuration(_ sec: Double) -> String {
    guard sec > 0 else { return "" }
    let s = Int(sec)
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - 当页筛选（网页版 displayGroups 同款）：只筛本页已加载的数据，不多请求。

/// 当页排序：默认（服务端顺序）/ 年份最新 / 集数最多。
enum PageSort: String, CaseIterable {
    case normal = "默认"
    case yearDesc = "年份最新"
    case epsDesc = "集数最多"
}

/// 当页状态：全部 / 已完结 / 连载中。
enum PageStatus: String, CaseIterable {
    case all = "全部"
    case done = "已完结"
    case ongoing = "连载中"
}

/// 一部剧的完结状态：从各源 remarks 推断（常写“已完结”“更新至第X集”）；
/// remarks 为空的判未知，只进“全部”，不硬编状态。
func groupFinishStatus(_ g: VodGroup) -> PageStatus? {
    let remarks = g.sources.map { $0.remarks }.joined(separator: " ")
    if remarks.contains("完结") { return .done }
    if remarks.contains("更新至") || remarks.contains("连载") { return .ongoing }
    return nil
}

/// 当页筛选：类型 / 年份（精确匹配本页数据）+ 状态 + 排序。
func filterGroups(_ groups: [VodGroup], type: String, year: String, sort: PageSort, status: PageStatus) -> [VodGroup] {
    var out = groups
    if !type.isEmpty { out = out.filter { $0.typeName == type } }
    if !year.isEmpty { out = out.filter { $0.year == year } }
    if status != .all { out = out.filter { groupFinishStatus($0) == status } }
    switch sort {
    case .yearDesc: out.sort { ($0.year, $0.name) > ($1.year, $1.name) }
    case .epsDesc: out.sort { $0.allEpisodes > $1.allEpisodes }
    case .normal: break
    }
    return out
}

/// 当页筛选行：类型 / 年份（取自本页数据）+ 排序 + 状态 + 已筛出 N 部 + 清除。
struct PageFilterBar: View {
    @Binding var type: String
    @Binding var year: String
    @Binding var sort: PageSort
    @Binding var status: PageStatus
    var types: [String]
    var years: [String]
    var total: Int
    var shown: Int
    var onClear: () -> Void

    private var filtering: Bool { !type.isEmpty || !year.isEmpty || sort != .normal || status != .all }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !types.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("全部类型") { type = "" }
                            .buttonStyle(.borderedProminent).tint(type.isEmpty ? .red : .gray)
                        ForEach(types, id: \.self) { t in
                            Button(t) { type = t }
                                .buttonStyle(.borderedProminent).tint(type == t ? .red : .gray)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            if !years.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("全部年份") { year = "" }
                            .buttonStyle(.borderedProminent).tint(year.isEmpty ? .red : .gray)
                        ForEach(years, id: \.self) { y in
                            Button(y) { year = y }
                                .buttonStyle(.borderedProminent).tint(year == y ? .red : .gray)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(PageSort.allCases, id: \.self) { s in
                        Button(s.rawValue) { sort = s }
                            .buttonStyle(.borderedProminent).tint(sort == s ? .red : .gray)
                    }
                    Text("|").foregroundColor(.secondary)
                    ForEach(PageStatus.allCases, id: \.self) { s in
                        Button(s.rawValue) { status = s }
                            .buttonStyle(.borderedProminent).tint(status == s ? .red : .gray)
                    }
                }
                .padding(.horizontal)
            }
            if filtering {
                HStack {
                    Text("已筛出 \(shown) 部（共 \(total) 部）").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("清除筛选") { onClear() }.font(.caption)
                }
                .padding(.horizontal)
            }
        }
    }
}
