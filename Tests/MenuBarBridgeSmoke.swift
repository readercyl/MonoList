import Foundation

@main
struct MenuBarBridgeSmoke {
    static func main() {
        precondition(
            MenuBarBridgeProtocol.helperBundleIdentifier ==
                "com.qingcheng.monolist.menubar.v2"
        )
        precondition(
            MenuBarBridgeProtocol.statusItemAutosaveName ==
                "MonoList.MenuBarService.v2"
        )
        precondition(MenuBarBridgeProtocol.title(pendingCount: 0).isEmpty)
        precondition(MenuBarBridgeProtocol.title(pendingCount: 3) == "3")
        precondition(
            MenuBarBridgeProtocol.title(
                pendingCount: 8,
                focusTaskCount: 3,
                focusCompleted: false
            ) == "专注 3"
        )
        precondition(
            MenuBarBridgeProtocol.title(
                pendingCount: 8,
                focusTaskCount: 3,
                focusCompleted: true
            ) == "专注 ✓"
        )
        precondition(
            MenuBarBridgeProtocol.toolTip(
                currentFocusText: "写完规格",
                focusCompleted: false
            ) == "当前专注：写完规格"
        )
        precondition(
            MenuBarBridgeProtocol.toolTip(
                currentFocusText: nil,
                focusCompleted: true
            ) == "今日专注已完成"
        )
        let appDelegateSource = try! String(
            contentsOfFile: "MonoList/App/AppDelegate.swift",
            encoding: .utf8
        )
        precondition(
            appDelegateSource.contains("focusTaskCount: focusTasks.count"),
            "菜单栏应显示今日专注总数，而不是剩余数"
        )
        precondition(
            appDelegateSource.contains(".map { tasks, selection in"),
            "菜单栏同步必须使用专注订阅传入的新状态"
        )
        precondition(
            appDelegateSource.contains(
                "menuBarStatus(tasks: tasks, focusSelection: selection)"
            ),
            "菜单栏不能在 Published 更新完成前重新读取旧专注状态"
        )
        precondition(MenuBarBridgeProtocol.showMainPanel.rawValue.hasPrefix(
            "com.qingcheng.monolist."
        ))
        precondition(MenuBarBridgeProtocol.openSettings.rawValue.hasPrefix(
            "com.qingcheng.monolist."
        ))
        precondition(MenuBarBridgeProtocol.pendingCountChanged.rawValue.hasPrefix(
            "com.qingcheng.monolist."
        ))
        precondition(MenuBarBridgeProtocol.statusItemFrameChanged.rawValue.hasPrefix(
            "com.qingcheng.monolist."
        ))
        precondition(MenuBarBridgeProtocol.quit.rawValue.hasPrefix(
            "com.qingcheng.monolist."
        ))

        print("Menu bar bridge smoke passed.")
    }
}
