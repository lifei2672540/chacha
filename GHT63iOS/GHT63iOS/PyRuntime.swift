import Foundation
// 注意：Python C API 经 GHT63iOS-Bridging-Header.h（#import <Python/Python.h>）引入，
// 不写 import Python——BeeWare 的 module.modulemap 在 Headers/ 下，Swift 找不到它。

/// 内嵌 CPython（BeeWare 3.11）：App 启动时初始化一次。
/// 阶段 2：PYTHONPATH 指向 bundle 内的 app/（蜘蛛桥 + 纯 Python 依赖），
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
            // 签名墙实验：扩展模块 .so 已移进 Python.framework/lib-dynload（AltStore
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
