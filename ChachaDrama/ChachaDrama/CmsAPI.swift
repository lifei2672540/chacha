import Foundation

/// CMS 采集站（MacCMS 口径）：type 1 返回 JSON，type 0 返回 XML。
/// 直接在本机拉站，不走 PY；详情的 vod_play_from / vod_play_url 口径与 PY 相同，
/// 复用 PyAPI.detailFromList 解析。播放地址就是 vod_play_url 里切出来的那条 URL。
enum CmsAPI {
    /// 拼接 CMS 参数：api 末尾可能已带查询（如 ?ac=list），用 URLComponents 追加；
    /// 同名参数只留新值，避免 ?ac=list&ac=videolist 这种重复导致站端按第一个解析。
    static func cmsURL(api: String, params: [(String, String)]) throws -> URL {
        guard var comps = URLComponents(string: api) else {
            throw PySpider.PyError.bridge("CMS 地址无效：\(api)")
        }
        var items = comps.queryItems ?? []
        for (k, v) in params {
            items.removeAll { $0.name == k }
            items.append(URLQueryItem(name: k, value: v))
        }
        comps.queryItems = items
        guard let url = comps.url else {
            throw PySpider.PyError.bridge("CMS 地址无效：\(api)")
        }
        return url
    }

    static func fetchJSON(api: String, params: [(String, String)]) async throws -> [String: Any] {
        let url = try cmsURL(api: api, params: params)
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PySpider.PyError.bridge("CMS 返回的不是 JSON")
        }
        return o
    }

    static func fetchXML(api: String, params: [(String, String)]) async throws -> (classes: [PyClass], videos: [[String: Any]], pagecount: Int) {
        let url = try cmsURL(api: api, params: params)
        let (data, _) = try await URLSession.shared.data(from: url)
        let text: String
        if let s = String(data: data, encoding: .utf8) {
            text = s
        } else if let s = String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) {
            text = s
        } else {
            throw PySpider.PyError.bridge("CMS 返回的不是可读文本")
        }
        guard let d = text.data(using: .utf8) else {
            throw PySpider.PyError.bridge("CMS 返回的不是可读文本")
        }
        return try CmsXMLParser().parse(data: d)
    }

    static func home(source: PySource) async throws -> (classes: [PyClass], items: [Drama]) {
        if source.cmsType == 0 {
            let r = try await fetchXML(api: source.api, params: [("ac", "list"), ("pg", "1")])
            return (r.classes, PyAPI.dramas(source: source, from: r.videos))
        }
        let o = try await fetchJSON(api: source.api, params: [("ac", "list"), ("pg", "1")])
        return (PyAPI.classes(from: o["class"] as? [[String: Any]] ?? []),
                PyAPI.dramas(source: source, from: o["list"] as? [[String: Any]] ?? []))
    }

    static func category(source: PySource, tid: String, pg: Int) async throws -> (items: [Drama], pagecount: Int) {
        if source.cmsType == 0 {
            let r = try await fetchXML(api: source.api, params: [("ac", "videolist"), ("t", tid), ("pg", "\(pg)")])
            return (PyAPI.dramas(source: source, from: r.videos), max(r.pagecount, 1))
        }
        let o = try await fetchJSON(api: source.api, params: [("ac", "videolist"), ("t", tid), ("pg", "\(pg)")])
        let pc = o["pagecount"] as? Int ?? (Int("\(o["pagecount"] ?? 1)") ?? 1)
        return (PyAPI.dramas(source: source, from: o["list"] as? [[String: Any]] ?? []), max(pc, 1))
    }

    static func search(source: PySource, wd: String) async throws -> [Drama] {
        if source.cmsType == 0 {
            let r = try await fetchXML(api: source.api, params: [("ac", "videolist"), ("wd", wd), ("pg", "1")])
            return PyAPI.dramas(source: source, from: r.videos)
        }
        let o = try await fetchJSON(api: source.api, params: [("ac", "videolist"), ("wd", wd), ("pg", "1")])
        return PyAPI.dramas(source: source, from: o["list"] as? [[String: Any]] ?? [])
    }

    static func detail(source: PySource, drama: Drama) async throws -> DramaDetail {
        if source.cmsType == 0 {
            let r = try await fetchXML(api: source.api, params: [("ac", "detail"), ("ids", drama.vodId)])
            return try PyAPI.detailFromList(drama: drama, list: r.videos)
        }
        let o = try await fetchJSON(api: source.api, params: [("ac", "detail"), ("ids", drama.vodId)])
        return try PyAPI.detailFromList(drama: drama, list: o["list"] as? [[String: Any]] ?? [])
    }
}

/// MacCMS XML 解析：<rss><class><ty><id>/<name>、<list pagecount><video><id>/<name>/<pic>/<remarks>/<type>/<vod_play_from>/<vod_play_url>/<vod_content>。
/// 只取播放需要的字段；解析失败直接抛错，不返回半截数据。
private final class CmsXMLParser: NSObject, XMLParserDelegate {
    private var classes: [PyClass] = []
    private var videos: [[String: Any]] = []
    private var pagecount = 1
    private var curVideo: [String: Any]?
    private var curClass: [String: String]?
    private var curText = ""
    private var curElement = ""
    private var inVideo = false
    private var inTy = false

    func parse(data: Data) throws -> (classes: [PyClass], videos: [[String: Any]], pagecount: Int) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw PySpider.PyError.bridge("CMS XML 解析失败")
        }
        return (classes, videos, max(pagecount, 1))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        curElement = elementName
        curText = ""
        if elementName == "video" {
            inVideo = true
            curVideo = [:]
        } else if elementName == "ty" {
            inTy = true
            curClass = [:]
        } else if elementName == "list", let pc = attributeDict["pagecount"], let n = Int(pc) {
            pagecount = n
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        curText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = curText.trimmingCharacters(in: .whitespacesAndNewlines)
        if inVideo, var v = curVideo {
            switch elementName {
            case "id": v["vod_id"] = text
            case "name": v["vod_name"] = text
            case "pic": v["vod_pic"] = text
            case "remarks": v["vod_remarks"] = text
            case "type": v["type_name"] = text
            case "vod_play_from": v["vod_play_from"] = text
            case "vod_play_url": v["vod_play_url"] = text
            case "vod_content": v["vod_content"] = text
            default: break
            }
            curVideo = v
        } else if inTy, var c = curClass {
            switch elementName {
            case "id": c["type_id"] = text
            case "name": c["type_name"] = text
            default: break
            }
            curClass = c
        }
        if elementName == "video" {
            if let v = curVideo { videos.append(v) }
            curVideo = nil
            inVideo = false
        } else if elementName == "ty" {
            if let c = curClass, let id = c["type_id"], let name = c["type_name"], !name.isEmpty {
                classes.append(PyClass(id: id, name: name))
            }
            curClass = nil
            inTy = false
        }
        curText = ""
    }
}
