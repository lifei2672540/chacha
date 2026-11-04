# Bridge between Java (Chaquopy) and user PY spiders.
# Java calls run_spider(code, ext, method, args_json) -> JSON string.
# User code is exec'd in its own namespace; its `Spider` class is found,
# instantiated once per (code, ext) and cached. Method arity differences
# between spider generations are absorbed here.
import inspect
import json
import traceback

_cache = {}


def _get_spider(code, ext):
    # 缓存键直接用 (脚本, 扩展) 本身：iOS 的 BeeWare 精简版 Python 里
    # hashlib.sha256 不可用（缺 _hashlib/_sha2），绝不能在这里依赖 hashlib
    key = (code, ext or "")
    if key in _cache:
        return _cache[key]
    ns = {"__name__": "user_spider", "__file__": "<spider>"}
    exec(compile(code, "<spider>", "exec"), ns)
    cls = ns.get("Spider")
    if cls is None:
        # fall back: any class defined by the script with playerContent
        for v in ns.values():
            if inspect.isclass(v) and hasattr(v, "playerContent"):
                cls = v
                break
    if cls is None:
        raise RuntimeError("脚本中没有找到 Spider 类")
    spider = cls()
    try:
        spider.init(ext or "")
    except TypeError:
        spider.init()
    _cache[key] = spider
    return spider


def _call(fn, *candidate_arglists):
    """Try arities in order; re-raise the last TypeError if all fail."""
    last = None
    for args in candidate_arglists:
        try:
            return fn(*args)
        except TypeError as e:
            last = e
    raise last


def run_spider(code, ext, method, args_json):
    try:
        args = json.loads(args_json or "[]")
        spider = _get_spider(code, ext or "")
        if method == "home":
            r = _call(spider.homeContent, (False,), ())
            if isinstance(r, dict) and not r.get("list"):
                try:
                    hv = spider.homeVideoContent()
                    if isinstance(hv, dict) and hv.get("list"):
                        r["list"] = hv["list"]
                except Exception:
                    pass
        elif method == "category":
            tid, page = args[0], int(args[1])
            r = _call(spider.categoryContent,
                      (tid, str(page), False, {}), (tid, page, False, {}),
                      (tid, str(page)))
        elif method == "detail":
            r = _call(spider.detailContent, ([args[0]],), (args[0],))
        elif method == "search":
            key, page = args[0], int(args[1])
            r = _call(spider.searchContent,
                      (key, False, str(page)), (key, False), (key,))
        elif method == "play":
            r = _call(spider.playerContent,
                      (args[0], args[1], []), (args[0], args[1]))
        elif method == "init":
            r = {}
        else:
            raise RuntimeError("未知方法: %s" % method)
        if r is None:
            r = {}
        if isinstance(r, str):
            return r
        return json.dumps(r, ensure_ascii=False, default=str)
    except Exception:
        return json.dumps({"__error__": traceback.format_exc()},
                          ensure_ascii=False)
