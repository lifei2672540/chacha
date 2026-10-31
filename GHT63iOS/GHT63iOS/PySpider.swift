import Foundation

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

    private static let queue = DispatchQueue(label: "com.ght63.ios.pyspider")
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
