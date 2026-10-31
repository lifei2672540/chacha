# BaseSpider shim: the class TVBox PY spiders inherit from
# (`from base.spider import BaseSpider`, or `from base.spider import Spider`
# as in the drpy-style scripts that then do `class Spider(Spider)`).
# Mirrors the CatVod PY contract: override
# homeContent/categoryContent/detailContent/searchContent/
# playerContent and return plain dicts in CMS vod_* shape.
import json

import requests


class BaseSpider:
    def __init__(self):
        self.extend = ""
        self.session = requests.Session()
        self.headers = {}

    # --- lifecycle -------------------------------------------------
    def init(self, extend=""):
        self.extend = extend or ""

    def getName(self):
        return self.__class__.__name__

    def getDependence(self):
        return []

    def destroy(self):
        pass

    # --- content methods (override) --------------------------------
    def homeContent(self, filter=False):
        return {"class": [], "list": []}

    def homeVideoContent(self):
        return {"list": []}

    def categoryContent(self, tid, pg, filter, extend):
        return {"page": int(pg or 1), "pagecount": 1, "limit": 20, "total": 0, "list": []}

    def detailContent(self, ids):
        return {"list": []}

    def searchContent(self, key, quick, pg="1"):
        return {"page": int(pg or 1), "pagecount": 1, "limit": 20, "total": 0, "list": []}

    def playerContent(self, flag, id, vipFlags):
        return {"parse": 0, "playUrl": "", "url": id, "header": {}}

    def localProxy(self, param):
        return None

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

    # --- helpers spiders rely on ------------------------------------
    def fetch(self, url, params=None, headers=None, timeout=20, **kw):
        hdrs = dict(self.headers)
        if headers:
            hdrs.update(headers)
        return self.session.get(url, params=params, headers=hdrs,
                                timeout=timeout, **kw)

    def post(self, url, data=None, headers=None, timeout=20, **kw):
        hdrs = dict(self.headers)
        if headers:
            hdrs.update(headers)
        return self.session.post(url, data=data, headers=hdrs,
                                 timeout=timeout, **kw)

    def fetchJson(self, url, **kw):
        return self.fetch(url, **kw).json()

    def log(self, msg):
        print("[spider] %s" % msg)

    def getProxyUrl(self):
        return ""

    @staticmethod
    def str2json(s):
        return json.loads(s) if isinstance(s, str) else s

    @staticmethod
    def json2str(d):
        return json.dumps(d, ensure_ascii=False)


# Alias for the drpy-style import line `from base.spider import Spider`
# (and `import Spider as BaseSpider` variants): the scripts subclass it,
# so the alias must be the very same class, not a copy.
Spider = BaseSpider
