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

        let appDelegateSource = try! String(
            contentsOfFile: "MonoList/App/AppDelegate.swift",
            encoding: .utf8
        )
        precondition(
            appDelegateSource.contains("MenuBarStatus(") &&
                appDelegateSource.contains("pendingCount: tasks.filter")
        )
        precondition(!appDelegateSource.contains("focusTaskCount"))
        precondition(!appDelegateSource.contains("focusSelection"))
        print("Menu bar bridge smoke passed.")
    }
}
