import Foundation
import JavaScriptCore

/// 海阔规则 v1：规则 JSON 只当数据，脚本在 JSContext 里跑。
/// MY_URL 在 v1 里取规则 JSON 地址：脚本只按 ## 切分类（首页无 ## → 空分类；
/// 分类 `地址##分类` → 切出分类），search/detail 用各自模板与条目地址，所以成立。
struct HikerRule: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// 规则 JSON 的地址（添加时用户粘贴的地址）。
    var ruleURL: String
    /// 规则原文（find_rule 等脚本都从这里取）。
    var rawJSON: String

    /// 规则原文解析成字典（解析失败当空规则）。
    var json: [String: Any] {
        guard let data = rawJSON.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return o
    }
    var title: String { json["title"] as? String ?? "" }
    /// 首页/分类脚本（去掉 `js:` 前缀）。
    var findRule: String { (json["find_rule"] as? String ?? "").hikerScriptBody }
    /// 搜索脚本。
    var searchFind: String { (json["searchFind"] as? String ?? "").hikerScriptBody }
    /// 详情脚本（同时定义 playFn/toPlay，解析也跑它）。
    var detailRule: String { (json["detail_find_rule"] as? String ?? "").hikerScriptBody }
    /// 搜索地址模板（** 是关键词占位）。
    var searchURLTemplate: String { json["search_url"] as? String ?? "" }
    /// 分类名（class_name 按 & 拆）。
    var classNames: [String] { (json["class_name"] as? String ?? "").components(separatedBy: "&").filter { !$0.isEmpty } }
    /// 分类值（class_url 按 & 拆，与 classNames 一一对应）。
    var classURLs: [String] { (json["class_url"] as? String ?? "").components(separatedBy: "&").filter { !$0.isEmpty } }
    /// 规则自带 UA（fetch 默认头用它，无则浏览器 UA）。
    var ua: String { json["ua"] as? String ?? "" }

    /// 标题生成稳定 id：只留字母数字与 -，全被滤掉就用哈希兜底。
    static func slug(from title: String) -> String {
        let kept = title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let s = String(kept).components(separatedBy: "-").filter { !$0.isEmpty }.joined(separator: "-")
        if !s.isEmpty { return s }
        return "rule-\(abs(title.hashValue) % 100000)"
    }
}

private extension String {
    /// 规则脚本都带 `js:` 前缀，跑之前去掉。
    var hikerScriptBody: String {
        hasPrefix("js:") ? String(dropFirst(3)) : self
    }
}

/// 规则跑出来的一个条目（海报卡 / 分区标题 / 选集 / 简介都用它）。
struct HikerItem: Identifiable, Hashable {
    var id: String { title + "|" + url }
    var title: String
    var img: String
    var desc: String
    var url: String
    /// 排版："" 或 movie_3 是海报卡，text_1 是分区标题，text_2~5 是选集（数字=列数），rich_text 是简介。
    var colType: String

    init(title: String, img: String = "", desc: String = "", url: String = "", colType: String = "") {
        self.title = title
        self.img = img
        self.desc = desc
        self.url = url
        self.colType = colType
    }

    init?(dict: [String: Any]) {
        let title = (dict["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        self.title = title
        self.img = dict["img"] as? String ?? ""
        self.desc = dict["desc"] as? String ?? ""
        self.url = dict["url"] as? String ?? ""
        self.colType = dict["col_type"] as? String ?? ""
    }
}

/// setResult 收到的结果（JS 回调里暂存，跑完一次取走）。
private final class HikerResultBox {
    var items: [HikerItem]?
}

/// 海阔引擎：一条串行队列上跑规则，每次运行新建一个 JSContext；
/// JSContext 不在主线程建、不在主线程跑脚本；JS 值一律安全转换，不强解包。
final class HikerEngine {
    static let shared = HikerEngine()
    /// 惰性播放地址标记：hiker://lazy/<规则id>/<arg 的 URL 编码>。
    static let lazyPrefix = "hiker://lazy/"

    private let queue = DispatchQueue(label: "com.ght63.ios.hiker")
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()
    private let fallbackUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private init() {}

    // MARK: - 对外接口（async，内部走串行队列）

    /// 首页：MY_URL 取规则地址，MY_PAGE 递增翻页。
    func home(rule: HikerRule, page: Int) async -> [HikerItem] {
        await run(rule: rule, script: rule.findRule, myURL: rule.ruleURL, myPage: page, myKeyword: "")
    }

    /// 分类：MY_URL 取 `规则地址##分类`，空分类走首页。
    func category(rule: HikerRule, cls: String, page: Int) async -> [HikerItem] {
        let myURL = cls.isEmpty ? rule.ruleURL : "\(rule.ruleURL)##\(cls)"
        return await run(rule: rule, script: rule.findRule, myURL: myURL, myPage: page, myKeyword: "")
    }

    /// 搜索：MY_URL 取 search_url 模板（** 换成关键词），MY_KEYWORD 传原词。
    func search(rule: HikerRule, keyword: String, page: Int) async -> [HikerItem] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let myURL = rule.searchURLTemplate.isEmpty ? "" : rule.searchURLTemplate.replacingOccurrences(of: "**", with: encoded)
        return await run(rule: rule, script: rule.searchFind, myURL: myURL, myPage: page, myKeyword: keyword)
    }

    /// 详情：MY_URL 取条目地址。
    func detail(rule: HikerRule, itemURL: String, page: Int = 1) async -> [HikerItem] {
        await run(rule: rule, script: rule.detailRule, myURL: itemURL, myPage: page, myKeyword: "")
    }

    /// 解析一集的惰性地址：跑详情脚本（解析模式）再调 toPlay(arg)。
    /// 成功返回带真实地址 + 请求头的 Episode；toast:// 或解析失败返回 nil。
    func resolveEpisode(rule: HikerRule, episode: Episode) async -> Episode? {
        guard episode.url.hasPrefix(Self.lazyPrefix) else { return nil }
        let rest = String(episode.url.dropFirst(Self.lazyPrefix.count))
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let encodedArg = String(rest[rest.index(after: slash)...])
        guard let arg = encodedArg.removingPercentEncoding, !arg.isEmpty else { return nil }
        // 详情脚本从 MY_URL 里取剧名 slug（arg 首段就是 slug），MY_URL 只给它 /drama/<slug> 即可；
        // 站地址脚本里写死了，不用 MY_URL 拼。
        let slug = arg.components(separatedBy: "|").first ?? ""
        let myURL = slug.isEmpty ? "" : "/drama/\(slug)"
        let escaped = arg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        guard let result = await evalExpression(rule: rule, script: rule.detailRule,
                                                myURL: myURL, myPage: 1, myKeyword: "",
                                                expression: "toPlay('\(escaped)')"),
              !result.isEmpty else {
            ErrorLog.append("海阔解析无结果 \(rule.name) - \(episode.title)")
            return nil
        }
        if result.hasPrefix("toast://") {
            ErrorLog.append("海阔解析失败 \(rule.name) - \(episode.title)：\(result)")
            return nil
        }
        // `地址;{Referer@...&&User-Agent@...}` → 地址 + 头字典。
        let parts = result.components(separatedBy: ";{")
        let urlPart = parts[0]
        guard !urlPart.isEmpty else { return nil }
        var headers: [String: String] = [:]
        if parts.count > 1 {
            var head = parts[1]
            if head.hasSuffix("}") { head = String(head.dropLast()) }
            for pair in head.components(separatedBy: "&&") {
                guard let at = pair.firstIndex(of: "@") else { continue }
                let k = String(pair[..<at])
                let v = String(pair[pair.index(after: at)...])
                if !k.isEmpty { headers[k] = v }
            }
        }
        return Episode(title: episode.title, url: urlPart, headers: headers)
    }

    // MARK: - 跑脚本（串行队列）

    private func run(rule: HikerRule, script: String, myURL: String, myPage: Int, myKeyword: String) async -> [HikerItem] {
        guard !script.isEmpty else { return [] }
        return await withCheckedContinuation { cont in
            queue.async {
                let items = self.runSync(rule: rule, script: script, myURL: myURL,
                                         myPage: myPage, myKeyword: myKeyword, resolveMode: false)
                cont.resume(returning: items ?? [])
            }
        }
    }

    /// 跑脚本并取表达式的值（解析模式用：先跑详情脚本定义 playFn/toPlay，再调 toPlay(arg)）。
    private func evalExpression(rule: HikerRule, script: String, myURL: String, myPage: Int, myKeyword: String, expression: String) async -> String? {
        guard !script.isEmpty else { return nil }
        return await withCheckedContinuation { cont in
            queue.async {
                let box = HikerResultBox()
                guard let context = self.makeContext(rule: rule, resolveMode: true, box: box) else {
                    cont.resume(returning: nil)
                    return
                }
                context.setObject(myURL, forKeyedSubscript: "MY_URL" as NSString)
                context.setObject(myPage, forKeyedSubscript: "MY_PAGE" as NSString)
                context.setObject(myKeyword, forKeyedSubscript: "MY_KEYWORD" as NSString)
                context.evaluateScript(script)
                if context.exception != nil {
                    ErrorLog.append("海阔解析脚本异常 \(rule.name)")
                    cont.resume(returning: nil)
                    return
                }
                let value = context.evaluateScript(expression)?.toString()
                cont.resume(returning: (value?.isEmpty == true) ? nil : value)
            }
        }
    }

    private func runSync(rule: HikerRule, script: String, myURL: String, myPage: Int, myKeyword: String, resolveMode: Bool) -> [HikerItem]? {
        let box = HikerResultBox()
        guard let context = makeContext(rule: rule, resolveMode: resolveMode, box: box) else { return nil }
        context.setObject(myURL, forKeyedSubscript: "MY_URL" as NSString)
        context.setObject(myPage, forKeyedSubscript: "MY_PAGE" as NSString)
        context.setObject(myKeyword, forKeyedSubscript: "MY_KEYWORD" as NSString)
        context.evaluateScript(script)
        if let exc = context.exception {
            ErrorLog.append("海阔脚本异常 \(rule.name)：\(exc.toString() ?? "?")")
            return nil
        }
        return box.items
    }

    /// 新建一个 JSContext 并注入海阔接口：fetch（同步）、setResult、$().lazyRule。
    private func makeContext(rule: HikerRule, resolveMode: Bool, box: HikerResultBox) -> JSContext? {
        guard let context = JSContext() else { return nil }
        context.exceptionHandler = { _, exc in
            ErrorLog.append("海阔 JS 异常 \(rule.name)：\(exc?.toString() ?? "?")")
        }
        // fetch(url, {method, headers, body})：同步取页面，失败回空串（脚本里 try/catch 兜底）。
        // body 可以是字符串，也可以是对象/数组（转 JSON 发）。
        let fetchBlock: @convention(block) (String, JSValue) -> String = { [weak self] urlString, options in
            guard let self = self else { return "" }
            var headers: [String: String] = [:]
            var method = "GET"
            var body: Data? = nil
            if !options.isUndefined {
                if let raw = options.forProperty("headers")?.toDictionary() {
                    for (k, v) in raw {
                        if let ks = k as? String, let vs = v as? String { headers[ks] = vs }
                    }
                }
                if let m = options.forProperty("method")?.toString(), !m.isEmpty {
                    method = m.uppercased()
                }
                if let bv = options.forProperty("body"), !bv.isUndefined, !bv.isNull {
                    if bv.isArray, let arr = bv.toArray() {
                        body = try? JSONSerialization.data(withJSONObject: arr)
                    } else if bv.isObject, let dict = bv.toDictionary() {
                        body = try? JSONSerialization.data(withJSONObject: dict)
                    } else if let s = bv.toString() {
                        body = s.data(using: .utf8)
                    }
                }
            }
            return self.syncFetch(urlString: urlString, method: method, body: body, headers: headers, rule: rule)
        }
        context.setObject(fetchBlock, forKeyedSubscript: "fetch" as NSString)
        // setResult(items)：收结果数组转 [HikerItem]。
        let setResultBlock: @convention(block) (JSValue) -> Void = { value in
            let raw: [Any] = value.toArray() ?? []
            box.items = raw.compactMap { ($0 as? [String: Any]).flatMap(HikerItem.init(dict:)) }
        }
        context.setObject(setResultBlock, forKeyedSubscript: "setResult" as NSString)
        // $().lazyRule(fn, arg)：浏览模式返回惰性标记，解析模式直接执行 fn(arg)。
        let lazyRuleBlock: @convention(block) (JSValue, JSValue) -> String = { fn, arg in
            let argString = arg.toString() ?? ""
            if resolveMode {
                return fn.call(withArguments: [argString])?.toString() ?? ""
            }
            let encoded = argString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? argString
            return "\(Self.lazyPrefix)\(rule.id)/\(encoded)"
        }
        context.setObject(lazyRuleBlock, forKeyedSubscript: "__hikerLazyRule" as NSString)
        context.evaluateScript("function $() { return { lazyRule: __hikerLazyRule }; }")
        return context
    }

    /// 同步取页面（信号量 + 15 秒超时，跑在串行队列上，不会卡主线程）。
    /// 默认头：UA 取规则 ua（无则浏览器 UA），Referer 取规则地址的根；脚本自带头优先。
    /// 带 body 时默认 Content-Type: application/json（脚本自己带了头就用脚本的）。
    private func syncFetch(urlString: String, method: String = "GET", body: Data? = nil, headers: [String: String], rule: HikerRule) -> String {
        guard let url = URL(string: urlString) else { return "" }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.httpBody = body
        var all: [String: String] = [:]
        all["User-Agent"] = rule.ua.isEmpty ? fallbackUA : rule.ua
        if let origin = URL(string: rule.ruleURL), let scheme = origin.scheme, let host = origin.host {
            all["Referer"] = "\(scheme)://\(host)/"
        }
        for (k, v) in headers { all[k] = v }
        if body != nil && !all.keys.contains(where: { $0.lowercased() == "content-type" }) {
            all["Content-Type"] = "application/json"
        }
        for (k, v) in all { request.setValue(v, forHTTPHeaderField: k) }
        var out = ""
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, _, _ in
            if let data = data {
                out = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 16)
        if out.isEmpty { task.cancel() }
        return out
    }
}

/// 规则存取：UserDefaults 存 `hikerRules`（JSON 编码的 [HikerRule]）。
struct HikerStore {
    private static let key = "hikerRules"

    static func all() -> [HikerRule] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rules = try? JSONDecoder().decode([HikerRule].self, from: data) else { return [] }
        return rules
    }

    private static func save(_ rules: [HikerRule]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: key)
    }

    /// 抓规则 JSON 解析标题后保存；标题空则用地址当名。同名规则覆盖旧的。
    /// 地址也可以是合集：{"rules": [地址, ...]} 或 [地址, ...]，一次加多个。返回加上的个数，失败记日志。
    static func add(url: String) async -> Int {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        let full = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) ? trimmed : "https://\(trimmed)"
        guard let u = URL(string: full) else {
            ErrorLog.append("海阔加规则失败：地址无效 \(trimmed)")
            return 0
        }
        do {
            var request = URLRequest(url: u, timeoutInterval: 15)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            var text = String(data: data, encoding: .utf8) ?? ""
            if text.hasPrefix("\u{FEFF}") { text = String(text.dropFirst()) }
            guard !text.isEmpty else { return 0 }
            if let urls = Self.indexURLs(from: text), !urls.isEmpty {
                var added = 0
                for sub in urls { added += await Self.addOne(url: sub) }
                return added
            }
            return Self.addOneText(text, url: full) ? 1 : 0
        } catch {
            ErrorLog.append("海阔加规则失败 \(full)：\(error)")
            return 0
        }
    }

    /// 合集解析：{"rules": [...]} 或直接 [...]，元素全是地址字符串；不是合集返回 nil。
    private static func indexURLs(from text: String) -> [String]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = obj as? [String] { return arr }
        if let dict = obj as? [String: Any], let arr = dict["rules"] as? [String] { return arr }
        return nil
    }

    /// 只加一条规则（不识别合集，避免合集套合集循环）。
    private static func addOne(url: String) async -> Int {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        let full = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) ? trimmed : "https://\(trimmed)"
        guard let u = URL(string: full) else { return 0 }
        do {
            var request = URLRequest(url: u, timeoutInterval: 15)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            var text = String(data: data, encoding: .utf8) ?? ""
            if text.hasPrefix("\u{FEFF}") { text = String(text.dropFirst()) }
            return Self.addOneText(text, url: full) ? 1 : 0
        } catch { return 0 }
    }

    /// 把一段规则 JSON 文本存进列表；不是规则 JSON 返回 false。
    private static func addOneText(_ text: String, url: String) -> Bool {
        guard !text.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            ErrorLog.append("海阔加规则失败：不是规则 JSON \(url)")
            return false
        }
        let title = (json["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let name = title.isEmpty ? url : title
        let rule = HikerRule(id: HikerRule.slug(from: name), name: name, ruleURL: url, rawJSON: text)
        var rules = all()
        rules.removeAll { $0.id == rule.id }
        rules.append(rule)
        save(rules)
        return true
    }

    static func remove(id: String) {
        var rules = all()
        rules.removeAll { $0.id == id }
        save(rules)
    }
}
