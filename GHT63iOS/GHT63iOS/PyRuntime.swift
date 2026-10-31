import Foundation
import Python

/// 内嵌 CPython（BeeWare 3.11）：App 启动时初始化一次。
/// 阶段 1 只验证解释器能跑：设置页显示实测版本号。
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
        Py_Initialize()
        guard let sysMod = PyImport_ImportModule("sys") else {
            version = "import sys 失败"
            return
        }
        defer { Py_DecRef(sysMod) }
        guard let verObj = PyObject_GetAttrString(sysMod, "version"),
              let cstr = PyUnicode_AsUTF8(verObj) else {
            version = "读 version 失败"
            return
        }
        defer { Py_DecRef(verObj) }
        version = String(cString: cstr)
    }
}
