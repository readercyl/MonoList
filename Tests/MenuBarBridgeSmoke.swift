import Foundation

@main
struct MenuBarBridgeSmoke {
    static func main() {
        precondition(
            MenuBarBridgeProtocol.helperBundleIdentifier ==
                "com.qingcheng.monolist.menubar.v2"
        )
        precondition(MenuBarBridgeProtocol.title(pendingCount: 8) == "8")
        precondition(MenuBarBridgeProtocol.title(pendingCount: 0).isEmpty)
        precondition(MenuBarBridgeProtocol.toolTip() == "MonoList")
        let channel = MenuBarBridgeProtocol.channel(parentProcessID: 111)
        let otherChannel = MenuBarBridgeProtocol.channel(parentProcessID: 222)
        precondition(channel != otherChannel)
        let center = DistributedNotificationCenter.default()
        let name = Notification.Name("MonoList.BridgeSmoke.\(UUID().uuidString)")
        var received = 0
        let observer = center.addObserver(forName: name, object: channel, queue: .main) { _ in
            received += 1
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(name, object: otherChannel, userInfo: nil, deliverImmediately: true)
        center.postNotificationName(name, object: channel, userInfo: nil, deliverImmediately: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        precondition(received == 1, "A helper channel must ignore other app instances")

        let appDelegateSource = try! String(
            contentsOfFile: "MonoList/App/AppDelegate.swift",
            encoding: .utf8
        )
        precondition(
            appDelegateSource.contains("MenuBarStatus(") &&
                appDelegateSource.contains("pendingCount: TaskStore.pendingActionCount(in: tasks)")
        )
        precondition(!appDelegateSource.contains("focusTaskCount"))
        precondition(!appDelegateSource.contains("focusSelection"))
        print("Menu bar bridge smoke passed.")
    }
}
