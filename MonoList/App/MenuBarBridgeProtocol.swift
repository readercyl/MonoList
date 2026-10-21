import Foundation

enum MenuBarBridgeProtocol {
    // A helper belongs to one running app, including when release and development coexist.
    static func channel(parentProcessID: Int32) -> String {
        "com.qingcheng.monolist.menubar.parent.\(parentProcessID)"
    }

    static let helperBundleIdentifier = "com.qingcheng.monolist.menubar.v2"
    static let statusItemAutosaveName = "MonoList.MenuBarService.v2"
    static let showMainPanel = Notification.Name(
        "com.qingcheng.monolist.menubar.v2.showMainPanel"
    )
    static let openSettings = Notification.Name(
        "com.qingcheng.monolist.menubar.v2.openSettings"
    )
    static let pendingCountChanged = Notification.Name(
        "com.qingcheng.monolist.menubar.v2.pendingCountChanged"
    )
    static let statusItemFrameChanged = Notification.Name(
        "com.qingcheng.monolist.menubar.v2.statusItemFrameChanged"
    )
    static let quit = Notification.Name(
        "com.qingcheng.monolist.menubar.v2.quit"
    )

    static func title(pendingCount: Int) -> String {
        pendingCount == 0 ? "" : "\(pendingCount)"
    }

    static func toolTip() -> String {
        "MonoList"
    }
}
