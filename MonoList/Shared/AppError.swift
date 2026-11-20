import Foundation

enum AppError: LocalizedError {
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed:
            return "保存失败，请重试"
        }
    }
}

extension Notification.Name {
    /// 菜单栏主面板关闭后广播，供视图结束行内编辑并释放键盘监视器。
    static let monoListMainPanelDidClose = Notification.Name("MonoList.mainPanelDidClose")
}
