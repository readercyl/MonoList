import CryptoKit
import CoreFoundation
import Foundation

/// Local message ports route all writes to the running app's main-thread store.
final class TaskCLIService {
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    let handler: (Data) -> Data

    init(name: String, handler: @escaping (Data) -> Data) throws {
        self.handler = handler
        var context = CFMessagePortContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        var shouldFree = DarwinBoolean(false)
        port = CFMessagePortCreateLocal(nil, name as CFString, { _, _, data, info in
            guard let data, let info else { return nil }
            let server = Unmanaged<TaskCLIService>.fromOpaque(info).takeUnretainedValue()
            let request = data as Data
            let response = request.count <= TaskCLI.maximumBytes
                ? server.handler(request)
                : TaskCLI.failure("request_too_large")
            return Unmanaged.passRetained(response as CFData)
        }, &context, &shouldFree)
        guard let port else { throw TaskCLIError.message("CLI 服务名已被占用") }
        source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
    }
}

enum TaskCLI {
    static let maximumBytes = 1_048_576
    static func isolatedDirectory(bundleID: String) -> String? {
        guard bundleID == "com.qingcheng.monolist.dev" else { return nil }
        return ProcessInfo.processInfo.environment["MONOLIST_CLI_TEST_DIRECTORY"]
    }

    static func serviceName(bundleID: String) -> String {
        var name = "\(bundleID).cli.\(getuid())"
        if let directory = isolatedDirectory(bundleID: bundleID) {
            name += ".test." + SHA256.hash(data: Data(directory.utf8)).prefix(8)
                .map { String(format: "%02x", $0) }.joined()
        }
        return name
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func revision<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func failure(_ message: String) -> Data {
        // No task text, request payload, or filesystem contents are logged.
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message])) ?? Data()
    }

    static func send(_ request: Data, name: String) throws -> Data {
        guard request.count <= maximumBytes else { throw TaskCLIError.message("request_too_large") }
        guard let remote = CFMessagePortCreateRemote(nil, name as CFString) else {
            throw TaskCLIError.message("app_not_running: 请先打开对应版本的 MonoList")
        }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(remote, 1, request as CFData, 5, 20,
                                             CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let reply else {
            throw TaskCLIError.message("result_unknown: 通信失败，请读取当前状态后再决定是否重试")
        }
        return reply.takeRetainedValue() as Data
    }

    static func run(arguments: [String], bundleID: String) -> Int32 {
        do {
            guard arguments.count == 1 else { throw TaskCLIError.message("用法: monolist help | <command>，参数 JSON 从标准输入读取") }
            let command = arguments[0]
            if command == "help" || command == "--help" {
                print(help)
                return 0
            }
            let withoutInput = ["list", "status", "settings.get", "view.get", "update.status",
                "window.home", "window.settings", "window.panel", "window.hide", "reminder.test",
                "reminder.close", "update.check", "data.retry-save"]
            var input = Data()
            if !withoutInput.contains(command) {
                guard isatty(STDIN_FILENO) == 0 else {
                    throw TaskCLIError.message("此命令需要从标准输入读取 JSON")
                }
                while let chunk = try FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
                    input.append(chunk)
                    guard input.count <= maximumBytes else { throw TaskCLIError.message("request_too_large") }
                }
            }
            var object: [String: Any] = [:]
            if !input.isEmpty {
                guard let decoded = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
                    throw TaskCLIError.message("输入必须是 JSON 对象")
                }
                object = decoded
            }
            object["command"] = command
            let response = try send(JSONSerialization.data(withJSONObject: object),
                                    name: serviceName(bundleID: bundleID))
            FileHandle.standardOutput.write(response + Data([10]))
            let json = try JSONSerialization.jsonObject(with: response) as? [String: Any]
            return json?["ok"] as? Bool == true ? 0 : 1
        } catch {
            FileHandle.standardOutput.write(failure(error.localizedDescription) + Data([10]))
            return 1
        }
    }

    static func connectionStatus(bundleURL: URL, bundleID: String) async -> String {
        let launcherPath = launcherURL(in: bundleURL).path
        return await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    guard FileManager.default.isExecutableFile(atPath: launcherPath) else {
                        return "检测失败：当前 App 缺少 CLI 入口，请使用包含 CLI 的版本。"
                    }
                    let data = try TaskCLI.send(Data("{\"command\":\"status\"}".utf8),
                        name: TaskCLI.serviceName(bundleID: bundleID))
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object["ok"] as? Bool == true,
                          let result = object["result"] as? [String: Any],
                          let development = result["development"] as? Bool,
                          development == (bundleID == "com.qingcheng.monolist.dev") else {
                        return "检测失败：接口未返回正确的版本身份。"
                    }
                    let version = result["version"] as? String ?? ""
                    return "接口可用 · " + (development ? "开发版 " : "正式版 ") + version
                } catch { return "检测失败：" + error.localizedDescription }
        }.value
    }

    static func launcherURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/MacOS/monolist-cli")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func agentInstructions(bundleURL: URL, bundleID: String) -> String {
        let command = shellQuote(launcherURL(in: bundleURL).path)
        let edition = bundleID == "com.qingcheng.monolist.dev" ? "MonoList 开发版" : "MonoList 正式版"
        return """
        请通过此 CLI 管理我的 \(edition)：\(command)。先运行 help，再运行 list 验证连接。首次成功读取清单后，在当前会话展示一次以下提示：
        已连接 MonoList，你可以这样说：
        1. 根据任务的轻重缓急，重排一下当前未完成任务的顺序。
        2. 把任务正文简单整理一下，保留原意，不要过度润色。
        3. 结合现有任务，把下面这段话拆成任务和子任务，添加到未完成清单：……
        接入成功先展示提示，收到我的指令后再修改任务。
        """
    }

    static let help = """
    MonoList CLI v1 — 输出 JSON；操作运行中的同版本 App，不直接改任务文件。
    用法: monolist <command> < request.json
    list / status                  读取所有任务、revision / 应用状态
    apply                          原子执行任务批次，必填 expectedRevision、operations
      kind: add, edit, complete, restore, delete, clear.pending, clear.history,
            clear.all, indent, outdent, parent, move, reorder, reminder
      add: text, 可选 id/parentID/afterID；edit: id/text；move: id/offset
      move 定位: id/beforeID/parentID；reorder: ids（全部未完成任务 UUID）
      reminder: id/reminder（null 清除；once/date 或 daily/minuteOfDay/recurrenceID）
      delete、clear.* 另需 confirm:true；日期为 ISO 8601，UUID 为字符串。
    login.set（enabled、confirm:true，开发版禁止修改）
    settings.get / settings.set    读取 / 修改设置；set 需 expectedRevision、values（局部字段）
    view.get / view.set            读取 / 设置 collapsedIDs、homeHistory、panelHistory
    window.home / window.settings / window.panel / window.hide
    reminder.test / reminder.close
    update.check / update.status / update.install（需 confirm:true，开发版禁止安装）
    app.quit（需 confirm:true） / data.retry-load / data.retry-save
    写入先 list 取得 revision。超时后读取状态，禁止盲目重试。
    """
}
