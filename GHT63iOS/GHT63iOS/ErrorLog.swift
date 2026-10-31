import Foundation
import UIKit

/// 本机报错日志：TV 版 crash.log 的 iOS 对照。
/// 播放器关键步骤、桥异常、自检失败、未捕获异常都记进来（最新在后，超 64KB 截掉最旧的）。
/// 设置页“上传报错日志”按 TV 的约定 POST 到 {serverBase}/upde/upload_crash.php（log 字段），
/// 服务器按 crash-时间戳.log 保存（TV 与 iOS 的日志落同一个目录，内容头一行标明来源版本）。
enum ErrorLog {
    private static let fileName = "ght63ios_error.log"
    private static let cap = 64 * 1024
    private static let queue = DispatchQueue(label: "com.ght63.ios.errorlog")

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    static func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(stamp)] \(line)\n"
        queue.async {
            var old = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            old += entry
            let data = Data(old.utf8)
            if data.count > cap {
                old = String(decoding: data.suffix(cap), as: UTF8.self)
            }
            try? old.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static func read() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "（暂无日志）"
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 捕获未处理的 ObjC/Swift 异常（Swift 底层 trap 如强制解包 iOS 层面抓不到，
    /// 那类问题靠播放器轨迹与自检日志定位）。下次启动后日志仍在，可上传。
    /// 注意：这个闭包会被转成 C 函数指针，里面不能引用任何 Swift 静态量
    /// （FileManager.default、fileName 都会被判为捕获上下文而编译失败），
    /// 只用 C 函数与字面量。
    static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exc in
            let stack = exc.callStackSymbols.prefix(20).joined(separator: "\n")
            let entry = "[uncaught] \(exc.name) \(exc.reason ?? "?")\n\(stack)\n"
            let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
            let path = (dir as NSString).appendingPathComponent("ght63ios_error.log")
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(Data(entry.utf8))
                h.closeFile()
            } else {
                try? entry.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 按 TV 约定上传：POST 表单 log 字段到 {serverBase}/upde/upload_crash.php。
    static func upload() async -> String {
        let serverBase = UserDefaults.standard.string(forKey: "serverBase")
            ?? "http://test.lifei555.cloudns.be/点播"
        guard let url = URL(string: "\(serverBase)/upde/upload_crash.php") else {
            return "上传失败：服务器地址无效"
        }
        let info = Bundle.main.infoDictionary
        let ver = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let deviceModel = await UIDevice.current.model
        let sysVer = await UIDevice.current.systemVersion
        let header = "GHT63 iOS \(ver) build \(build) \(deviceModel) iOS \(sysVer)\n"
        let body = header + read()
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8",
                     forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "log", value: body)]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               o["ok"] as? Bool == true {
                return "上传成功：\(o["file"] as? String ?? "")"
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return "上传失败：HTTP \(code)"
        } catch {
            return "上传失败：\(error.localizedDescription)"
        }
    }
}
