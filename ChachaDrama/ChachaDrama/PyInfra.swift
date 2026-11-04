import Foundation
// 注意：Python C API 经 ChachaDrama-Bridging-Header.h（#import <Python/Python.h>）引入，
// 不写 import Python——BeeWare 的 module.modulemap 在 Headers/ 下，Swift 找不到它。

/// 内嵌 CPython（BeeWare 3.11）：App 启动时初始化一次。
/// PYTHONPATH 指向 bundle 内的 app/（蜘蛛桥 + 纯 Python 依赖），
/// 证书指向 app/certifi/cacert.pem；启动末尾 SaveThread 释放主线程的 GIL，
/// 之后所有 Python 调用统一经 PySpider 的串行队列 + PyGILState_Ensure/Release。
enum PyRuntime {
    private static var started = false
    static var version: String = "未启动"

    static func start() {
        guard !started else { return }
        started = true
        guard let home = Bundle.main.path(forResource: "python", ofType: nil) else {
            version = "缺 python 资源"
            return
        }
        setenv("PYTHONHOME", home, 1)
        if let appPath = Bundle.main.path(forResource: "app", ofType: nil) {
            // 签名墙：扩展模块 .so 已移进 Python.framework/lib-dynload（AltStore
            // 签名框架时一并覆盖），把该目录也放进 PYTHONPATH，让 import 找得到它们；
            // 目录不存在（旧包）时只用 app/，行为与原来一致
            var paths = [appPath]
            let fwDyn = Bundle.main.bundleURL.appendingPathComponent("Frameworks/Python.framework/lib-dynload").path
            if FileManager.default.fileExists(atPath: fwDyn) {
                paths.append(fwDyn)
            }
            setenv("PYTHONPATH", paths.joined(separator: ":"), 1)
            let cert = (appPath as NSString).appendingPathComponent("certifi/cacert.pem")
            if FileManager.default.fileExists(atPath: cert) {
                setenv("SSL_CERT_FILE", cert, 1)
            }
        }
        Py_Initialize()
        var v: String
        if let sysMod = PyImport_ImportModule("sys") {
            defer { Py_DecRef(sysMod) }
            if let verObj = PyObject_GetAttrString(sysMod, "version"),
               let cstr = PyUnicode_AsUTF8(verObj) {
                defer { Py_DecRef(verObj) }
                v = String(cString: cstr)
            } else {
                v = "读 version 失败"
            }
        } else {
            v = "import sys 失败"
        }
        // 释放主线程持有的 GIL，之后调用方用 PyGILState_Ensure/Release
        PyEval_SaveThread()
        version = v
    }
}

/// Swift 侧蜘蛛桥：与 TV 端 PySpider.kt 同款 JSON 契约。
/// 所有 Python 调用都在一条串行队列上跑，并持 GIL
///（解释器启动时已 SaveThread 释放主线程的 GIL）。
enum PySpider {
    enum PyError: Error, CustomStringConvertible {
        case bridge(String)
        var description: String {
            switch self {
            case .bridge(let s): return s
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.chacha.drama.pyspider")
    private static var bridgeModule: UnsafeMutablePointer<PyObject>?

    /// 同步调用桥函数，返回 JSON 字符串；桥内异常时抛 PyError（内含 traceback）。
    static func run(code: String, ext: String, method: String, argsJson: String) throws -> String {
        try queue.sync {
            PyRuntime.start()
            let state = PyGILState_Ensure()
            defer { PyGILState_Release(state) }
            if bridgeModule == nil {
                guard let m = PyImport_ImportModule("spider_bridge") else {
                    PyErr_Print()
                    throw PyError.bridge("import spider_bridge 失败")
                }
                bridgeModule = m
            }
            guard let fn = PyObject_GetAttrString(bridgeModule, "run_spider") else {
                PyErr_Print()
                throw PyError.bridge("桥里没有 run_spider")
            }
            defer { Py_DecRef(fn) }
            guard let tuple = PyTuple_New(4) else {
                throw PyError.bridge("建参数失败")
            }
            defer { Py_DecRef(tuple) }
            for (i, s) in [code, ext, method, argsJson].enumerated() {
                guard let u = PyUnicode_FromString(s) else {
                    throw PyError.bridge("编码参数失败")
                }
                PyTuple_SetItem(tuple, i, u) // 夺引用
            }
            guard let result = PyObject_CallObject(fn, tuple) else {
                PyErr_Print()
                throw PyError.bridge("桥调用失败")
            }
            defer { Py_DecRef(result) }
            guard let cstr = PyUnicode_AsUTF8(result) else {
                throw PyError.bridge("桥返回值不是字符串")
            }
            let json = String(cString: cstr)
            // 桥内异常以 __error__ 形式返回
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["__error__"] as? String {
                throw PyError.bridge(err)
            }
            return json
        }
    }
}

/// 本地报错日志（只存本机，不上传）：播放失败、PY 失败的轨迹，供“我的”页查看。
enum ErrorLog {
    private static let fileName = "chachadrama_error.log"
    private static let queue = DispatchQueue(label: "com.chacha.drama.errorlog")
    private static let formatter = ISO8601DateFormatter()
    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
    }
    static func append(_ line: String) {
        queue.async {
            guard let url = url else { return }
            let entry = "[\(formatter.string(from: Date()))] \(line)\n"
            guard let data = entry.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile()
                    h.write(data)
                    try? h.close()
                }
            } else {
                try? data.write(to: url)
            }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 65536,
               let d = try? Data(contentsOf: url) {
                try? d.suffix(65536).write(to: url)
            }
        }
    }
    static func read() -> String {
        guard let url = url, let d = try? Data(contentsOf: url) else { return "暂无日志" }
        return String(data: d, encoding: .utf8) ?? "日志解码失败"
    }
    static func clear() {
        queue.async { if let url = url { try? FileManager.default.removeItem(at: url) } }
    }
}
