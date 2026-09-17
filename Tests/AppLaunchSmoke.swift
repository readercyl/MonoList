import AppKit
import Foundation

enum SmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

@main
struct AppLaunchSmoke {
    static func main() throws {
        let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let iconPNGURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let expectedBundleID = CommandLine.arguments.dropFirst(3).first ??
            "com.qingcheng.monolist.dev"
        let expectedHelperBundleID = CommandLine.arguments.dropFirst(4).first ??
            "com.qingcheng.monolist.dev.menubar"
        let expectedDisplayName = CommandLine.arguments.dropFirst(5).first ??
            "MonoList 开发版"
        let contentsURL = appURL.appendingPathComponent("Contents")
        let executableURL = contentsURL.appendingPathComponent("MacOS/MonoList")
        let helperURL = contentsURL.appendingPathComponent(
            "Library/Helpers/MenuBarService.app"
        )
        let helperExecutableURL = helperURL.appendingPathComponent(
            "Contents/MacOS/MenuBarService"
        )
        let plistURL = contentsURL.appendingPathComponent("Info.plist")

        try requireDirectory(appURL, message: "MonoList.app 不存在")
        try requireExecutable(executableURL)
        try requireExecutable(helperExecutableURL)

        let data = try Data(contentsOf: plistURL)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let plist = object as? [String: Any] else {
            throw SmokeFailure.failed("Info.plist 格式无效")
        }

        try require(plist["CFBundleIdentifier"] as? String == expectedBundleID,
                    "Bundle ID 不正确")
        try require(plist["CFBundleDisplayName"] as? String == expectedDisplayName,
                    "应用显示名称不正确")
        try require(plist["CFBundleExecutable"] as? String == "MonoList",
                    "可执行文件名称不正确")
        try require(plist["CFBundleIconFile"] as? String == "AppIcon.icns",
                    "应用图标配置不正确")
        try require(
            FileManager.default.fileExists(
                atPath: contentsURL.appendingPathComponent("Resources/AppIcon.icns").path
            ),
            "构建产物缺少 AppIcon.icns"
        )
        try require(plist["LSUIElement"] as? Bool == false,
                    "MonoList 必须同时保留 Dock 与菜单栏入口")
        try require(plist["LSMinimumSystemVersion"] as? String == "14.0",
                    "最低系统版本必须为 macOS 14.0")
        let helperData = try Data(
            contentsOf: helperURL.appendingPathComponent("Contents/Info.plist")
        )
        let helperObject = try PropertyListSerialization.propertyList(
            from: helperData,
            format: nil
        )
        guard let helperPlist = helperObject as? [String: Any] else {
            throw SmokeFailure.failed("菜单栏服务 Info.plist 格式无效")
        }
        try require(
            helperPlist["CFBundleIdentifier"] as? String == expectedHelperBundleID,
            "菜单栏服务必须使用新的独立 Bundle ID"
        )
        try require(helperPlist["LSUIElement"] as? Bool == true,
                    "菜单栏服务不能额外显示 Dock 图标")
        try requireNormalIconSafeArea(iconPNGURL)
        try requireSimplifiedIcon(iconPNGURL)

        print("App launch smoke passed.")
    }

    private static func requireNormalIconSafeArea(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let image = NSBitmapImageRep(data: data) else {
            throw SmokeFailure.failed("无法读取 AppIcon PNG")
        }
        var minX = image.pixelsWide
        var maxX = 0
        var minY = image.pixelsHigh
        var maxY = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide
            where image.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.01 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        let occupiedWidth = maxX - minX + 1
        let occupiedHeight = maxY - minY + 1
        try require(
            occupiedWidth <= 840 && occupiedHeight <= 840,
            "Dock 图标安全边距不足"
        )
        try require(
            occupiedWidth >= 780 && occupiedHeight >= 780,
            "Dock 图标缩得过小"
        )
    }

    private static func requireSimplifiedIcon(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let image = NSBitmapImageRep(data: data) else {
            throw SmokeFailure.failed("无法读取 AppIcon PNG")
        }
        let background = image.colorAt(
            x: image.pixelsWide / 2,
            y: image.pixelsHigh * 78 / 100
        )
        let symbol = image.colorAt(
            x: image.pixelsWide * 28 / 100,
            y: image.pixelsHigh / 2
        )
        try require(
            (background?.brightnessComponent ?? 0) >= 0.9,
            "Dock 图标必须使用白色背景"
        )
        try require(
            symbol?.brightnessComponent ?? 1 < 0.2,
            "Dock 图标必须使用黑色圆圈"
        )
    }

    private static func requireDirectory(_ url: URL, message: String) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        try require(exists && isDirectory.boolValue, message)
    }

    private static func requireExecutable(_ url: URL) throws {
        try require(FileManager.default.isExecutableFile(atPath: url.path),
                    "MonoList 可执行文件不存在或不可执行")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw SmokeFailure.failed(message)
        }
    }
}
