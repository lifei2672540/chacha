import SwiftUI
import UIKit
import Foundation

// MARK: - 生成蜘蛛：粘一个网址，爬页面，认出分类与内容链接，按模板生成 py 蜘蛛，存成本地 PY 源。
// 识别逻辑已离线验过（合成页：内容组/分类组/搜索表单/翻页后缀全认对）；
// 模板已离线验过（首页/分类/详情/搜索/播放全通）。只认静态页面，靠脚本渲染的站认不准。

struct GenLink: Identifiable, Hashable {
    var id: String { url.absoluteString }
    var url: URL
    var text: String
}

struct GenCategory: Identifiable, Hashable {
    var id: String { url }
    var name: String
    var url: String
    var included: Bool
}

struct CrawlResult {
    var pageURL: URL
    var siteBase: String
    var siteName: String
    var title: String
    var totalLinks: Int
    var contentParents: [String]
    var contentLinks: [GenLink]
    var categories: [GenCategory]
    var contentRe: String
    var searchURL: String
    var searchParam: String
    var pageSuffix: String
    var warnings: [String]
}

enum SpiderGen {
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static let skipExt: Set<String> = ["jpg", "jpeg", "png", "gif", "css", "js", "svg", "ico", "webp", "mp4", "m3u8", "mkv", "zip", "pdf"]
    private static let utilPaths: Set<String> = ["/about", "/contact", "/login", "/register", "/privacy", "/terms", "/help", "/faq", "/search", "/sitemap", "/dmca"]
    private static let searchNames: Set<String> = ["q", "s", "keyword", "wd", "search", "query", "k"]

    // MARK: - 正则小工具

    private static func regexGroups(_ pattern: String, in text: String,
                                    options: NSRegularExpression.Options = []) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, options: [], range: range).map { m in
            (0..<m.numberOfRanges).map { i in
                guard let r = Range(m.range(at: i), in: text) else { return "" }
                return String(text[r])
            }
        }
    }

    private static func stripTags(_ s: String) -> String {
        var out = s
        if let re = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            out = re.stringByReplacingMatches(in: out, options: [],
                                              range: NSRange(out.startIndex..., in: out), withTemplate: " ")
        }
        out = out.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        if let re = try? NSRegularExpression(pattern: "\\s+", options: []) {
            out = re.stringByReplacingMatches(in: out, options: [],
                                              range: NSRange(out.startIndex..., in: out), withTemplate: " ")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hostOf(_ url: URL) -> String {
        var h = url.host ?? ""
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }

    private static func parentOf(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if parts.count <= 1 { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    private static func looksLikeId(_ last: String) -> Bool {
        if last.isEmpty { return false }
        if last.contains(where: { $0.isNumber }) { return true }
        let low = last.lowercased()
        if low.hasSuffix(".html") || low.hasSuffix(".htm") || low.hasSuffix(".php") { return true }
        return last.count > 25
    }

    private static func isPagination(_ url: URL) -> Bool {
        let path = url.path
        if path.range(of: "/(page|p)/\\d+/?$", options: .regularExpression) != nil { return true }
        guard let q = url.query else { return false }
        return q.range(of: "(^|&)page=\\d+", options: .regularExpression) != nil
    }

    private static func isUtilPath(_ path: String) -> Bool {
        if utilPaths.contains(path) { return true }
        return utilPaths.contains { path.hasPrefix($0 + "/") }
    }

    /// 语言切换链接（如 /zh、/en、/zh_TW），不是分类也不是内容。
    private static func isLangPath(_ last: String) -> Bool {
        let langs: Set<String> = ["zh", "en", "zh_tw", "zh_cn", "zh_hk", "ja", "ko",
                                  "fr", "de", "es", "pt", "ru", "th", "vi", "id", "ms"]
        return langs.contains(last.lowercased())
    }

    // MARK: - 爬取与识别

    static func crawl(urlString: String) async throws -> CrawlResult {
        var text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard let pageURL = URL(string: text) else {
            throw PySpider.PyError.bridge("地址无效：\(urlString)")
        }
        var req = URLRequest(url: pageURL, timeoutInterval: 30)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                     forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let html = String(data: data, encoding: .utf8) ??
              String(data: data, encoding: .isoLatin1) else {
            throw PySpider.PyError.bridge("页面不是文本")
        }
        return analyze(html: html, pageURL: pageURL)
    }

    static func analyze(html: String, pageURL: URL) -> CrawlResult {
        let siteHost = hostOf(pageURL)
        var siteBase = ""
        if let scheme = pageURL.scheme, let host = pageURL.host {
            siteBase = "\(scheme)://\(host)"
            if let port = pageURL.port { siteBase += ":\(port)" }
        }
        // 标题
        var title = ""
        if let m = regexGroups("<title>(.*?)</title>", in: html,
                               options: [.caseInsensitive, .dotMatchesLineSeparators]).first,
           m.count > 1 {
            title = stripTags(m[1])
        }
        var siteName = title
        if let cut = siteName.firstIndex(where: { $0 == "|" || $0 == "-" || $0 == "_" }) {
            siteName = String(siteName[..<cut]).trimmingCharacters(in: .whitespaces)
        }
        if siteName.isEmpty { siteName = siteHost }
        // 全部链接
        var links: [String: String] = [:]
        let anchorPat = #"<a\s[^>]*href\s*=\s*"([^"]+)"[^>]*>(.*?)</a>"#
        for m in regexGroups(anchorPat, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            guard m.count > 2 else { continue }
            let href = m[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let text = stripTags(m[2])
            if href.isEmpty || href.hasPrefix("#") { continue }
            let low = href.lowercased()
            if low.hasPrefix("javascript:") || low.hasPrefix("mailto:") || low.hasPrefix("tel:") { continue }
            guard let full = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                  let scheme = full.scheme, scheme == "http" || scheme == "https",
                  hostOf(full) == siteHost else { continue }
            let path = full.path.isEmpty ? "/" : full.path
            if let ext = path.split(separator: ".").last.map(String.init)?.lowercased(),
               skipExt.contains(ext), path.contains(".") { continue }
            if path == "/" { continue }
            let key = full.absoluteString
            if let old = links[key] {
                if text.count > old.count { links[key] = text }
            } else {
                links[key] = text
            }
        }
        // 翻页链接只用来认翻页后缀，不进分组
        var pageLinks: [URL] = []
        var kept: [String: String] = [:]
        for (u, t) in links {
            guard let url = URL(string: u) else { continue }
            if isPagination(url) { pageLinks.append(url) } else { kept[u] = t }
        }
        // 按父目录分组
        struct GroupInfo { var items: [(url: URL, text: String, isId: Bool)] = [] }
        var groups: [String: GroupInfo] = [:]
        for (u, t) in kept {
            guard let url = URL(string: u) else { continue }
            let path = url.path.isEmpty ? "/" : url.path
            let parent = parentOf(path)
            let last = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }.last ?? ""
            groups[parent, default: GroupInfo()].items.append((url, t, looksLikeId(last)))
        }
        var contentParents: [String] = []
        for (parent, g) in groups {
            let n = g.items.count
            let idn = g.items.filter { $0.isId }.count
            let ratio = n > 0 ? Double(idn) / Double(n) : 0
            if (n >= 3 && ratio >= 0.8) || (n >= 5 && ratio >= 0.5) || n >= 10 {
                contentParents.append(parent)
            }
        }
        contentParents.sort()
        var contentLinks: [GenLink] = []
        var categories: [GenCategory] = []
        for (u, t) in kept {
            guard let url = URL(string: u) else { continue }
            let path = url.path.isEmpty ? "/" : url.path
            let parent = parentOf(path)
            let last = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }.last ?? ""
            if contentParents.contains(parent) {
                // 根目录常混着视频与栏目：非编号的根链接是栏目，不是内容。
                if parent == "/" && !looksLikeId(last) {
                    if !isUtilPath(path) && !isLangPath(last) {
                        let name = t.isEmpty ? last : t
                        categories.append(GenCategory(name: name, url: path, included: true))
                    }
                } else {
                    contentLinks.append(GenLink(url: url, text: t))
                }
            } else {
                if !looksLikeId(last) && !isUtilPath(path) && !isLangPath(last) {
                    let name = t.isEmpty ? last : t
                    categories.append(GenCategory(name: name, url: path, included: true))
                }
            }
        }
        contentLinks.sort { $0.url.absoluteString < $1.url.absoluteString }
        categories.sort { $0.url < $1.url }
        // 内容正则（只对 path 匹配，防跨站绝对地址误中；根目录只写一次斜杠）
        let contentRe: String
        if contentParents.isEmpty {
            contentRe = ""
        } else {
            let parts = contentParents.map { ($0 == "/" ? "" : NSRegularExpression.escapedPattern(for: $0)) + #"/[^\"/]+"# }
            contentRe = "(?:" + parts.joined(separator: "|") + ")"
        }
        // 搜索表单
        var searchURL = ""
        var searchParam = ""
        let formPat = #"<form[^>]*action\s*=\s*"([^"]*)"[^>]*>(.*?)</form>"#
        for m in regexGroups(formPat, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            guard m.count > 2 else { continue }
            let body = m[2]
            let inps = regexGroups(#"<input[^>]*name\s*=\s*"([^"]+)""#, in: body, options: .caseInsensitive)
            for inp in inps where inp.count > 1 {
                if searchNames.contains(inp[1].lowercased()) {
                    let act = m[1]
                    let full = URL(string: act, relativeTo: pageURL)?.absoluteURL ?? pageURL
                    searchURL = full.path.isEmpty ? "/" : full.path
                    searchParam = inp[1]
                    break
                }
            }
            if !searchURL.isEmpty { break }
        }
        // 翻页后缀
        var pageSuffix = ""
        for url in pageLinks {
            if url.path.range(of: "/page/\\d+", options: .regularExpression) != nil {
                pageSuffix = "/page/{pg}"
                break
            }
            if url.path.range(of: "/p/\\d+", options: .regularExpression) != nil {
                pageSuffix = "/p/{pg}"
                break
            }
        }
        if pageSuffix.isEmpty {
            for url in pageLinks where (url.query ?? "").range(of: "(^|&)page=\\d+", options: .regularExpression) != nil {
                pageSuffix = "?page={pg}"
                break
            }
        }
        if pageSuffix.isEmpty { pageSuffix = "?page={pg}" }
        var warnings: [String] = []
        if contentParents.isEmpty {
            warnings.append("没认出内容链接：页面上没找到成组的内容页，生成的蜘蛛可能只有分类。")
        }
        if searchURL.isEmpty {
            warnings.append("没找到搜索框：搜索会改成在首页里按片名过滤。")
        }
        if categories.isEmpty {
            warnings.append("没认出分类：生成的蜘蛛只有“全部”。")
        }
        return CrawlResult(pageURL: pageURL, siteBase: siteBase, siteName: siteName, title: title,
                           totalLinks: kept.count, contentParents: contentParents,
                           contentLinks: contentLinks, categories: categories, contentRe: contentRe,
                           searchURL: searchURL, searchParam: searchParam,
                           pageSuffix: pageSuffix, warnings: warnings)
    }

    // MARK: - 模板（已离线验过）与生成

    /// 生成的 py 蜘蛛模板。占位符由 buildSpiderCode 替换。模板本身不含中文注释。
    private static let spiderTemplate = #"""
import re
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        def __init__(self):
            self.extend = ""
            self.headers = {}

        def fetch(self, url, params=None, headers=None, timeout=20, **kw):
            raise RuntimeError("requests unavailable")


SITE = "__SITE__"
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
HEADERS = {
    "User-Agent": UA,
    "Referer": SITE + "/",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
}

CLASSES = __CLASSES_JSON__

CONTENT_RE = r"__CONTENT_RE__"
SEARCH_URL = "__SEARCH_URL__"
SEARCH_PARAM = "__SEARCH_PARAM__"
PAGE_SUFFIX = "__PAGE_SUFFIX__"


def _chr_dec(m):
    try:
        return chr(int(m.group(1)) % 0x110000)
    except Exception:
        return ""


def _chr_hex(m):
    try:
        return chr(int(m.group(1), 16) % 0x110000)
    except Exception:
        return ""


class Spider(BaseSpider):
    def getName(self):
        return "__SITE_NAME__"

    def _get_html(self, url, timeout=15):
        for _ in range(2):
            try:
                resp = self.fetch(url, headers=HEADERS, timeout=timeout)
                text = getattr(resp, "text", None)
                if text:
                    return text
            except Exception:
                pass
            try:
                req = urllib.request.Request(url, headers=HEADERS)
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    text = r.read().decode("utf-8", "ignore")
                    if text:
                        return text
            except Exception:
                pass
        return ""

    def _unesc(self, s):
        if not s:
            return ""
        out = s.replace("\\/", "/")
        out = out.replace("&amp;", "&").replace("&quot;", '"').replace("&#39;", "'")
        out = out.replace("&lt;", "<").replace("&gt;", ">")
        out = re.sub(r"&#(\d+);", _chr_dec, out)
        out = re.sub(r"&#x([0-9a-fA-F]+);", _chr_hex, out)
        return out

    def _fix_url(self, u):
        if not u:
            return ""
        u = u.strip()
        if u.startswith("http://") or u.startswith("https://"):
            return u
        if u.startswith("//"):
            return "https:" + u
        if u.startswith("/"):
            return SITE + u
        return urllib.parse.urljoin(SITE + "/", u)

    def _clean_text(self, s):
        s = re.sub(r"<[^>]+>", " ", s or "")
        s = self._unesc(s)
        return re.sub(r"\s+", " ", s).strip()

    def _cards(self, html):
        out = []
        if not html or not isinstance(html, str):
            return out
        seen = set()
        site_host = urllib.parse.urlparse(SITE).netloc
        cat_paths = set()
        for c in CLASSES:
            tid = str(c.get("type_id") or "")
            if tid.startswith("http://") or tid.startswith("https://"):
                cat_paths.add(urllib.parse.urlparse(tid).path or "")
            elif tid:
                cat_paths.add(tid)
        generic = {"在線看", "在线看", "觀看", "观看", "播放", "詳情", "详情",
                   "更多", "查看", "線上看", "线上看", "看片", "watermark"}
        for m in re.finditer(r'<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', html, re.S | re.I):
            href = m.group(1)
            url = self._fix_url(href)
            if not url or url in seen:
                continue
            u = urllib.parse.urlparse(url)
            if u.netloc != site_host:
                continue
            path = u.path or ""
            if not re.search(CONTENT_RE, path):
                continue
            if path in cat_paths:
                continue
            seen.add(url)
            inner = m.group(2)
            pic = ""
            alt = ""
            for im in re.finditer(r"<img[^>]+>", inner):
                tag = im.group(0)
                ds = (re.search(r'data-src="([^"]+)"', tag)
                      or re.search(r'data-original="([^"]+)"', tag)
                      or re.search(r'data-lazy-src="([^"]+)"', tag))
                sr = re.search(r'\ssrc="([^"]+)"', tag)
                al = re.search(r'alt="([^"]*)"', tag)
                cand = ds.group(1) if ds else (sr.group(1) if sr else "")
                if not cand:
                    continue
                low = cand.lower()
                if "button_logo" in low or "no_preview" in low:
                    continue
                pic = self._fix_url(cand)
                alt = self._unesc(al.group(1)).strip() if al else ""
                if ds:
                    break
            last = path.rstrip("/").split("/")[-1]
            if not pic:
                continue
            title = ""
            if alt and alt.lower() != "watermark":
                title = alt
            if not title:
                t = self._clean_text(inner)
                if t and t not in generic:
                    title = t
            if not title:
                title = last
            title = re.sub(r"\s+", " ", title).strip()
            if not title:
                continue
            out.append({
                "vod_id": url,
                "vod_name": title,
                "vod_pic": pic,
                "vod_remarks": "",
                "vod_year": "",
                "vod_content": "",
            })
        return out

    def _page_url(self, base, pg):
        if pg <= 1:
            return base
        if not PAGE_SUFFIX:
            return base
        suf = PAGE_SUFFIX.replace("{pg}", str(pg))
        if suf.startswith("?"):
            sep = "&" if "?" in base else "?"
            return base + sep + suf[1:]
        return base.rstrip("/") + suf

    def homeContent(self, filter=False):
        html = self._get_html(SITE + "/")
        return {"class": CLASSES, "list": self._cards(html)}

    def homeVideoContent(self):
        html = self._get_html(SITE + "/")
        return {"list": self._cards(html)}

    def categoryContent(self, tid, pg, filter, extend):
        pg = int(pg) if str(pg).isdigit() else 1
        tid = str(tid or "")
        if tid.startswith("http://") or tid.startswith("https://"):
            base = tid
        else:
            base = SITE + tid
        html = self._get_html(self._page_url(base, pg))
        items = self._cards(html)
        return {
            "page": pg,
            "pagecount": 1,
            "limit": 20,
            "total": len(items),
            "list": items,
        }

    def detailContent(self, ids):
        vid = ids[0] if isinstance(ids, list) else str(ids)
        html = self._get_html(vid)
        if not html:
            return {"list": []}
        title = ""
        m = re.search(r"<title>(.*?)</title>", html, re.S | re.I)
        if m:
            title = self._clean_text(m.group(1))
            title = re.split(r"[|\-]", title)[0].strip() or title
        pic = ""
        m = re.search(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"', html, re.I)
        if m:
            pic = self._fix_url(m.group(1))
        if not pic:
            m = re.search(r'<img[^>]+(?:data-src|src)="([^"]+)"', html)
            if m:
                pic = self._fix_url(m.group(1))
        vids = []
        seen = set()
        for m in re.finditer(r'https?://[^\s"\'<>]+\.(?:m3u8|mp4)(?:\?[^\s"\'<>]*)?', html):
            u = m.group(0)
            if u not in seen:
                seen.add(u)
                vids.append(u)
        if not vids:
            for m in re.finditer(r'<(?:video|source)[^>]+src="([^"]+)"', html, re.I):
                u = self._fix_url(m.group(1))
                if u and u not in seen:
                    seen.add(u)
                    vids.append(u)
        if vids:
            eps = ["第%d集$%s" % (i + 1, u) for i, u in enumerate(vids)]
            play_url = "#".join(eps)
        else:
            m = re.search(r'<iframe[^>]+src="([^"]+)"', html, re.I)
            target = self._fix_url(m.group(1)) if m else vid
            play_url = "第1集$" + target
        vod = {
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": pic,
            "vod_remarks": "",
            "vod_year": "",
            "vod_content": "",
            "vod_play_from": "在线播放",
            "vod_play_url": play_url,
        }
        return {"list": [vod]}

    def searchContent(self, key, quick, pg="1"):
        pg = int(pg) if str(pg).isdigit() else 1
        if SEARCH_URL and SEARCH_PARAM:
            url = SITE + SEARCH_URL
            q = urllib.parse.quote(str(key))
            sep = "&" if "?" in url else "?"
            url = url + sep + SEARCH_PARAM + "=" + q
            if pg > 1:
                url = url + "&page=" + str(pg)
            html = self._get_html(url)
            items = self._cards(html)
            return {"page": pg, "pagecount": 1, "limit": 20, "total": len(items), "list": items}
        html = self._get_html(SITE + "/")
        items = [c for c in self._cards(html) if str(key) in c["vod_name"]]
        return {"page": 1, "pagecount": 1, "limit": 20, "total": len(items), "list": items}

    def playerContent(self, flag, id, vipFlags):
        url = str(id)
        if self.isVideoFormat(url):
            return {"parse": 0, "playUrl": "", "url": url, "header": {"User-Agent": UA, "Referer": SITE + "/"}}
        html = self._get_html(url)
        for m in re.finditer(r'https?://[^\s"\'<>]+\.(?:m3u8|mp4)(?:\?[^\s"\'<>]*)?', html or ""):
            return {"parse": 0, "playUrl": "", "url": m.group(0), "header": {"User-Agent": UA, "Referer": SITE + "/"}}
        return {"parse": 1, "playUrl": "", "url": url, "header": {"User-Agent": UA, "Referer": SITE + "/"}}

    def isVideoFormat(self, url):
        u = str(url or "").split("?")[0].lower()
        return u.endswith(".m3u8") or u.endswith(".mp4") or u.endswith(".mkv")

    def manualVideoCheck(self):
        return False
"""#

    /// 按爬到的结果生成 py 蜘蛛代码。contentParent 为空 = 用全部认出的内容组。
    static func buildSpiderCode(result: CrawlResult, siteName: String,
                                categories: [GenCategory], contentParent: String) -> String {
        let cats = categories.filter { $0.included }.map { ["type_id": $0.url, "type_name": $0.name] }
        let classesData = (try? JSONSerialization.data(withJSONObject: cats,
                                                       options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
        let classesJson = String(data: classesData, encoding: .utf8) ?? "[]"
        let contentRe: String
        if contentParent.isEmpty {
            contentRe = result.contentRe
        } else {
            contentRe = "(?:" + (contentParent == "/" ? "" : NSRegularExpression.escapedPattern(for: contentParent)) + #"/[^\"/]+)"#
        }
        return spiderTemplate
            .replacingOccurrences(of: "__SITE__", with: result.siteBase)
            .replacingOccurrences(of: "__SITE_NAME__", with: siteName)
            .replacingOccurrences(of: "__CLASSES_JSON__", with: classesJson)
            .replacingOccurrences(of: "__CONTENT_RE__", with: contentRe)
            .replacingOccurrences(of: "__SEARCH_URL__", with: result.searchURL)
            .replacingOccurrences(of: "__SEARCH_PARAM__", with: result.searchParam)
            .replacingOccurrences(of: "__PAGE_SUFFIX__", with: result.pageSuffix)
    }

    // MARK: - 本地 PY 源（存文件 + 记 UserDefaults，PyAPI 直接读）

    static let localDirName = "pyspiders"
    private static let localListKey = "localPySources"

    static func localDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(localDirName, isDirectory: true)
    }

    static func localFileName(for pageURL: URL) -> String {
        var host = pageURL.host ?? "site"
        host = host.replacingOccurrences(of: ".", with: "-")
        host = host.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        if host.isEmpty { host = "site" }
        return host + ".py"
    }

    /// 存生成的蜘蛛，返回本地源。同一站重复生成会覆盖旧文件并清脚本缓存。
    static func saveSpider(result: CrawlResult, siteName: String, code: String) throws -> PySource {
        let dir = localDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = localFileName(for: result.pageURL)
        let url = dir.appendingPathComponent(file)
        try code.write(to: url, atomically: true, encoding: .utf8)
        let api = "local://" + file
        PyAPI.forgetScript(api: api)
        var list = localSourcesRaw()
        list.removeAll { ($0["file"] as? String) == file }
        list.append(["name": siteName, "file": file])
        let data = try JSONSerialization.data(withJSONObject: list)
        UserDefaults.standard.set(data, forKey: localListKey)
        return PySource(name: siteName, api: api, ext: "")
    }

    static func localSourcesRaw() -> [[String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: localListKey),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return list
    }

    static func localSources() -> [PySource] {
        localSourcesRaw().compactMap { d in
            guard let name = d["name"] as? String, let file = d["file"] as? String else { return nil }
            return PySource(name: name, api: "local://" + file, ext: "")
        }
    }

    static func deleteLocalSource(_ source: PySource) {
        let file = source.api.replacingOccurrences(of: "local://", with: "")
        try? FileManager.default.removeItem(at: localDir().appendingPathComponent(file))
        PyAPI.forgetScript(api: source.api)
        var list = localSourcesRaw()
        list.removeAll { ($0["file"] as? String) == file }
        if let data = try? JSONSerialization.data(withJSONObject: list) {
            UserDefaults.standard.set(data, forKey: localListKey)
        }
    }
}

// MARK: - 生成器界面

struct SpiderGenView: View {
    @State private var urlText = ""
    @State private var crawling = false
    @State private var generating = false
    @State private var result: CrawlResult?
    @State private var error: String?
    @State private var categories: [GenCategory] = []
    @State private var contentChoice = ""
    @State private var siteName = ""
    @State private var generatedCode: String?
    @State private var savedSource: PySource?
    @State private var showCode = false
    @State private var showLinks = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("粘一个站的网址，爬它的页面，认出分类与内容链接，一键生成 py 蜘蛛，存成本地 PY 源，直接能浏览。只认静态页面，靠脚本渲染的站认不准。")
                    .font(.caption)
                    .foregroundColor(.gray)
                HStack {
                    TextField("输入网址，如 https://example.com", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("爬取") { Task { await doCrawl() } }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || crawling)
                }
                if crawling {
                    HStack { ProgressView(); Text("正在爬取…").foregroundColor(.gray) }
                }
                if let error = error {
                    Text(error).foregroundColor(.red)
                }
                if let result = result {
                    resultSection(result)
                }
                if let code = generatedCode, let saved = savedSource {
                    generatedSection(code: code, source: saved)
                }
                Color.clear.frame(height: 76)
            }
            .padding()
        }
        .navigationTitle("生成蜘蛛")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func resultSection(_ r: CrawlResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(r.title.isEmpty ? r.siteName : r.title)
                .font(.headline)
                .foregroundColor(.white)
            Text("共 \(r.totalLinks) 条链接 · 内容 \(r.contentLinks.count) 条 · 分类 \(r.categories.count) 个")
                .font(.caption)
                .foregroundColor(.gray)
            if !r.warnings.isEmpty {
                ForEach(r.warnings, id: \.self) { w in
                    Text("⚠️ \(w)").font(.caption).foregroundColor(.yellow)
                }
            }
            // 内容组选择
            if !r.contentParents.isEmpty {
                Text("内容链接长这样：").font(.subheadline).foregroundColor(.white)
                Picker("内容组", selection: $contentChoice) {
                    Text("全部（\(r.contentParents.count) 组）").tag("")
                    ForEach(r.contentParents, id: \.self) { p in
                        Text("\(p)/*").tag(p)
                    }
                }
                .pickerStyle(.menu)
            }
            // 分类开关
            if !categories.isEmpty {
                Text("分类（点掉不需要的）：").font(.subheadline).foregroundColor(.white)
                ForEach(categories.indices, id: \.self) { i in
                    Toggle(categories[i].name, isOn: $categories[i].included)
                        .foregroundColor(.white)
                }
            }
            Button("查看爬到的链接（\(r.totalLinks) 条）") { showLinks = true }
                .buttonStyle(.bordered)
            Button("一键生成 py 蜘蛛") { Task { await doGenerate() } }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(generating)
            if generating {
                HStack { ProgressView(); Text("正在生成…").foregroundColor(.gray) }
            }
        }
        .sheet(isPresented: $showLinks) {
            NavigationView {
                List {
                    ForEach(r.contentLinks) { l in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.text.isEmpty ? l.url.absoluteString : l.text)
                                .foregroundColor(.white)
                                .lineLimit(2)
                            Text(l.url.absoluteString)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                    }
                }
                .navigationTitle("内容链接（\(r.contentLinks.count) 条）")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showLinks = false }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func generatedSection(code: String, source: PySource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已生成：\(source.name)").font(.headline).foregroundColor(.white)
            Text("已存成本地 PY 源，打开就能浏览。分类、详情、搜索、播放按模板生成，复杂站可能要手动改改。")
                .font(.caption)
                .foregroundColor(.gray)
            HStack(spacing: 12) {
                Button("查看代码") { showCode = true }
                    .buttonStyle(.bordered)
                NavigationLink(destination: PyBrowseView(source: source)) {
                    Text("打开这个源")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .sheet(isPresented: $showCode) {
            NavigationView {
                ScrollView {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle("\(source.name).py")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showCode = false }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("复制") { UIPasteboard.general.string = code }
                    }
                }
            }
        }
    }

    private func doCrawl() async {
        crawling = true
        error = nil
        result = nil
        generatedCode = nil
        savedSource = nil
        defer { crawling = false }
        do {
            let r = try await SpiderGen.crawl(urlString: urlText)
            result = r
            categories = r.categories
            contentChoice = ""
            siteName = r.siteName
        } catch {
            self.error = "爬取失败：\(error)"
        }
    }

    private func doGenerate() async {
        guard let r = result else { return }
        generating = true
        defer { generating = false }
        let name = siteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = SpiderGen.buildSpiderCode(result: r, siteName: name.isEmpty ? r.siteName : name,
                                             categories: categories, contentParent: contentChoice)
        do {
            let source = try SpiderGen.saveSpider(result: r, siteName: name.isEmpty ? r.siteName : name, code: code)
            generatedCode = code
            savedSource = source
        } catch {
            self.error = "保存失败：\(error)"
        }
    }
}
