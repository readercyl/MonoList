import Combine
import ServiceManagement

enum LoginItemControllerError: LocalizedError {
    case developmentBuildReadOnly

    var errorDescription: String? {
        "开发版不修改正式版的开机启动设置，请在正式版中管理。"
    }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    let isDevelopmentBuild: Bool

    init(
        isDevelopmentBuild: Bool =
            Bundle.main.bundleIdentifier == "com.qingcheng.monolist.dev"
    ) {
        self.isDevelopmentBuild = isDevelopmentBuild
        status = isDevelopmentBuild ? .notRegistered : SMAppService.mainApp.status
    }

    var statusText: String {
        switch status {
        case .enabled:
            return "已启用"
        case .requiresApproval:
            return "需用户批准"
        case .notRegistered:
            return "关闭"
        case .notFound:
            return "注册失败"
        @unknown default:
            return "未知状态"
        }
    }

    func refresh() {
        status = isDevelopmentBuild ? .notRegistered : SMAppService.mainApp.status
    }

    func removeDevelopmentRegistration() {
        guard isDevelopmentBuild else { return }
        try? SMAppService.mainApp.unregister()
        refresh()
    }

    func setEnabled(_ enabled: Bool) throws {
        guard !isDevelopmentBuild else {
            throw LoginItemControllerError.developmentBuildReadOnly
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            errorMessage = nil
        } catch {
            refresh()
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
