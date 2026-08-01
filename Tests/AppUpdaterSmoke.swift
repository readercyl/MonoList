import Foundation

@main
struct AppUpdaterSmoke {
    @MainActor
    static func main() async throws {
        precondition(AppUpdater.compareVersions("v1.2.0", "1.1.9") == .orderedDescending)
        precondition(AppUpdater.compareVersions("v1.0.0", "1.0.0") == .orderedSame)
        precondition(AppUpdater.isValidVersionTag("v0.1.0"))
        precondition(!AppUpdater.isValidVersionTag("1.0"))
        precondition(!AppUpdater.isValidVersionTag("v1.0.0-beta"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        ReleaseURLProtocol.requestedHosts = []
        ReleaseURLProtocol.requestedPaths = []
        let networkUpdater = AppUpdater(
            currentVersion: "0.4.7",
            session: session
        )
        let networkResult = await networkUpdater.checkForUpdate()
        guard case let .available(networkUpdate) = networkResult else {
            preconditionFailure("Release 页面没有返回升级")
        }
        precondition(networkUpdate.version == "v0.4.8")
        precondition(ReleaseURLProtocol.requestedHosts == ["api.github.com"])
        precondition(ReleaseURLProtocol.requestedPaths == ["/repos/readercyl/MonoList/releases/latest"])
        precondition(
            networkUpdate.dmgURL.absoluteString ==
                "https://github.com/readercyl/MonoList/releases/download/v0.4.8/MonoList-v0.4.8.dmg"
        )
        let fallbackResult = AppUpdater.parseLatestReleaseURL(
            URL(string: "https://github.com/readercyl/MonoList/releases/tag/v0.4.6")!,
            currentVersion: "0.4.5"
        )
        guard case let .available(fallbackUpdate) = fallbackResult else {
            preconditionFailure("GitHub Release 跳转没有返回升级")
        }
        precondition(fallbackUpdate.version == "v0.4.6")
        precondition(
            fallbackUpdate.dmgURL.absoluteString ==
                "https://github.com/readercyl/MonoList/releases/download/v0.4.6/MonoList-v0.4.6.dmg"
        )

        precondition(AppUpdater.shouldAutomaticallyCheck(lastCheckedAt: nil))
        precondition(!AppUpdater.shouldAutomaticallyCheck(
            lastCheckedAt: Date(),
            now: Date()
        ))

        let settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoListUpdaterTests-\(UUID().uuidString)")
        let settings = AppSettings(
            fileURL: settingsDirectory.appendingPathComponent("settings.json")
        )
        ReleaseURLProtocol.requestedHosts = []
        ReleaseURLProtocol.requestedPaths = []
        let automaticUpdater = AppUpdater(currentVersion: "0.4.7", session: session)
        let automaticUpdate = await automaticUpdater.check(
            manual: false,
            settings: settings
        )
        precondition(automaticUpdate?.version == "v0.4.8")
        precondition(settings.lastAutomaticUpdateCheckAt != nil)

        try settings.update { $0.automaticUpdatesEnabled = false }
        ReleaseURLProtocol.requestedHosts = []
        let disabledResult = await automaticUpdater.check(
            manual: false,
            settings: settings
        )
        precondition(disabledResult == nil)
        precondition(
            ReleaseURLProtocol.requestedHosts.isEmpty,
            "关闭自动更新后不应发起后台版本检测"
        )

        let appDelegateSource = try String(
            contentsOfFile: "MonoList/App/AppDelegate.swift",
            encoding: .utf8
        )
        precondition(
            appDelegateSource.contains("await installUpdate(update, offersRetry: false)"),
            "后台发现新版本后应自动进入安装流程"
        )
        let updater = AppUpdater(currentVersion: "0.4.3")
        updater.beginInstallation()
        precondition(updater.isInstalling)
        precondition(updater.statusText == "下载并安装中…")
        updater.installationFailed()
        precondition(!updater.isInstalling)
        precondition(updater.statusText == "升级失败")
        print("App updater smoke passed.")
    }
}

private final class ReleaseURLProtocol: URLProtocol {
    static var requestedHosts: [String] = []
    static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.requestedHosts.append(url.host ?? "")
        Self.requestedPaths.append(url.path)

        let response: HTTPURLResponse
        if url.host == "api.github.com",
           url.path == "/repos/readercyl/MonoList/releases/latest" {
            response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(
                self,
                didLoad: Data(
                    """
                    {
                      "tag_name": "v0.4.8",
                      "assets": [
                        {
                          "name": "MonoList-v0.4.8.dmg",
                          "browser_download_url": "https://github.com/readercyl/MonoList/releases/download/v0.4.8/MonoList-v0.4.8.dmg"
                        }
                      ]
                    }
                    """.utf8
                )
            )
            client?.urlProtocolDidFinishLoading(self)
        } else {
            response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
