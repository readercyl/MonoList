import AppKit
import Foundation

enum UpdateInstallerError: LocalizedError {
    case downloadFailed
    case invalidPackage
    case appNotWritable
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "下载安装包失败，请重试"
        case .invalidPackage:
            return "更新包验证失败，请重试"
        case .appNotWritable:
            return "MonoList 所在位置不可写，请移动到可写文件夹后重试"
        case .launchFailed:
            return "无法启动升级程序，请重试"
        }
    }
}

@MainActor
final class UpdateInstaller {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func install(
        _ update: AppUpdate,
        replacing appURL: URL = Bundle.main.bundleURL,
        helperProcessID: Int32? = nil
    ) async throws {
        guard FileManager.default.isWritableFile(
            atPath: appURL.deletingLastPathComponent().path
        ) else {
            throw UpdateInstallerError.appNotWritable
        }

        let dmgURL = try await download(update)
        do {
            try validateDMG(dmgURL, version: update.version, currentAppURL: appURL)
            let scriptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("monolist-updater-\(UUID().uuidString).sh")
            try Self.updaterScript.write(
                to: scriptURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                scriptURL.path,
                appURL.path,
                dmgURL.path,
                update.version,
                scriptURL.path,
                String(ProcessInfo.processInfo.processIdentifier),
                String(helperProcessID ?? 0),
            ]
            try process.run()
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: dmgURL)
            throw error
        }
    }

    private func download(_ update: AppUpdate) async throws -> URL {
        guard update.dmgURL.scheme == "https" else {
            throw UpdateInstallerError.downloadFailed
        }
        var lastError: Error?
        for attempt in 1...2 {
            do {
                return try await downloadOnce(update)
            } catch {
                lastError = error
                if attempt == 1 {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
            }
        }
        throw lastError ?? UpdateInstallerError.downloadFailed
    }

    private func downloadOnce(_ update: AppUpdate) async throws -> URL {
        var request = URLRequest(url: update.dmgURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("MonoList", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 90
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.url?.scheme == "https" else {
            throw UpdateInstallerError.downloadFailed
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoList-\(update.version)-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func validateDMG(
        _ dmgURL: URL,
        version: String,
        currentAppURL: URL
    ) throws {
        try Self.run("/usr/bin/hdiutil", ["verify", dmgURL.path])
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoListMount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: mountURL,
            withIntermediateDirectories: true
        )
        defer {
            try? Self.run("/usr/bin/hdiutil", ["detach", mountURL.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountURL)
        }
        try Self.run(
            "/usr/bin/hdiutil",
            [
                "attach", dmgURL.path,
                "-nobrowse", "-readonly", "-mountpoint", mountURL.path,
            ]
        )
        let candidateURL = mountURL.appendingPathComponent("MonoList.app")
        try Self.validateApp(
            candidateURL,
            version: version,
            currentAppURL: currentAppURL
        )
    }

    private static func validateApp(
        _ appURL: URL,
        version: String,
        currentAppURL: URL
    ) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let plist = NSDictionary(contentsOf: plistURL),
              plist["CFBundleIdentifier"] as? String == "com.qingcheng.monolist.mac",
              plist["CFBundleShortVersionString"] as? String == String(version.dropFirst())
        else {
            throw UpdateInstallerError.invalidPackage
        }

        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
        let newRequirement = try output(
            "/usr/bin/codesign",
            ["-dr", "-", appURL.path]
        )
        let oldRequirement = try output(
            "/usr/bin/codesign",
            ["-dr", "-", currentAppURL.path]
        )
        guard !newRequirement.contains("designated => cdhash "),
              normalizedRequirement(newRequirement) == normalizedRequirement(oldRequirement)
        else {
            throw UpdateInstallerError.invalidPackage
        }
    }

    private static func normalizedRequirement(_ value: String) -> String {
        value
            .split(separator: "\n")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? value
    }

    @discardableResult
    private static func output(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateInstallerError.invalidPackage
        }
        return String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        _ = try output(executable, arguments)
    }

    static let processWaitScript = """
    wait_for_processes() {
      local deadline=$((SECONDS + $1))
      while kill -0 "$PARENT_PID" 2>/dev/null ||
            { [[ "$HELPER_PID" -gt 0 ]] && kill -0 "$HELPER_PID" 2>/dev/null; }; do
        if [[ "$SECONDS" -ge "$deadline" ]]; then
          return 1
        fi
        sleep 0.2
      done
    }
    """

    static let updaterScript = """
    #!/usr/bin/env bash
    set -euo pipefail

    APP_PATH="$1"
    DMG_PATH="$2"
    TARGET_VERSION="$3"
    SCRIPT_PATH="$4"
    PARENT_PID="${5:?Missing application PID}"
    HELPER_PID="${6:?Missing helper PID}"
    BUNDLE_ID="com.qingcheng.monolist.mac"
    BACKUP_PATH="${APP_PATH}.update-backup"
    MOUNT_DIR="$(mktemp -d)"
    INSTALLED_NEW_APP=0

    cleanup() {
      hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
      rm -rf "$MOUNT_DIR" "$DMG_PATH" "$SCRIPT_PATH" 2>/dev/null || true
    }

    restore_old_app() {
      if [[ -d "$BACKUP_PATH" ]]; then
        rm -rf "$APP_PATH"
        mv "$BACKUP_PATH" "$APP_PATH"
        open "$APP_PATH" || true
      fi
    }

    fail() {
      restore_old_app
      cleanup
      exit 1
    }

    \(processWaitScript)

    trap fail ERR
    if ! wait_for_processes 30; then
      # Keep the installed app intact if this instance cannot exit in time.
      open "$APP_PATH" || true
      cleanup
      exit 1
    fi

    hdiutil verify "$DMG_PATH" >/dev/null
    hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null
    SOURCE_APP="$MOUNT_DIR/MonoList.app"
    test -d "$SOURCE_APP"
    test "$(plutil -extract CFBundleIdentifier raw "$SOURCE_APP/Contents/Info.plist")" = "$BUNDLE_ID"
    test "$(plutil -extract CFBundleShortVersionString raw "$SOURCE_APP/Contents/Info.plist")" = "${TARGET_VERSION#v}"
    codesign --verify --deep --strict "$SOURCE_APP"

    rm -rf "$BACKUP_PATH"
    mv "$APP_PATH" "$BACKUP_PATH"
    ditto "$SOURCE_APP" "$APP_PATH"
    INSTALLED_NEW_APP=1
    test "$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")" = "$BUNDLE_ID"
    test "$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")" = "${TARGET_VERSION#v}"
    codesign --verify --deep --strict "$APP_PATH"
    xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
    open "$APP_PATH"
    rm -rf "$BACKUP_PATH"
    trap - ERR
    cleanup
    """
}
