import AppKit

@main
struct MonoListMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--cli" {
            exit(TaskCLI.run(arguments: Array(CommandLine.arguments.dropFirst(2)),
                bundleID: Bundle.main.bundleIdentifier ?? "com.qingcheng.monolist.dev"))
        }
        AppDelegate.run()
    }
}
