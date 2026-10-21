import Foundation

@main
struct UpdateInstallerSmoke {
    static func main() throws {
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--emit-script" {
            try UpdateInstaller.updaterScript.write(
                toFile: CommandLine.arguments[2],
                atomically: true,
                encoding: .utf8
            )
            return
        }
        let script = UpdateInstaller.updaterScript
        precondition(script.contains("hdiutil verify"))
        precondition(script.contains("BACKUP_PATH"))
        precondition(script.contains("ditto"))
        precondition(script.contains("restore_old_app"))
        precondition(script.contains("com.qingcheng.monolist.mac"))
        precondition(!script.contains("pgrep"))
        precondition(script.contains("if ! wait_for_processes 30"))
        precondition(script.contains("PARENT_PID=\"${5:?"))
        precondition(script.contains("HELPER_PID=\"${6:?"))
        precondition(script.contains("codesign --verify"))
        precondition(script.contains("xattr -dr com.apple.quarantine"))
        precondition(!script.contains("github.com"))
        // Simulate another running instance: only the supplied PIDs may be queried.
        try checkWait("""
        PARENT_PID=111
        HELPER_PID=222
        kill() {
          case "$2" in
            111|222) return 1 ;;
            *) exit 99 ;;
          esac
        }
        wait_for_processes 1
        """, expected: 0)
        try checkWait("""
        PARENT_PID=111
        HELPER_PID=0
        kill() { return 0; }
        wait_for_processes 0
        """, expected: 1)
        try checkWait("""
        PARENT_PID=111
        HELPER_PID=222
        kill() { [[ "$2" == 222 ]]; }
        wait_for_processes 0
        """, expected: 1)
        print("Update installer smoke passed.")
    }

    private static func checkWait(_ scenario: String, expected: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", UpdateInstaller.processWaitScript + "\n" + scenario]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == expected)
    }
}
