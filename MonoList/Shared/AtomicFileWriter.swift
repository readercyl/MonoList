import Darwin
import Foundation

protocol AtomicWriting {
    func write(_ data: Data, to destinationURL: URL) throws
}

struct AtomicFileWriter: AtomicWriting {
    func write(_ data: Data, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
        )

        do {
            // 先落盘再改名：否则崩溃/断电会留下 0 字节的正式文件，而旧内容已被覆盖。
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw POSIXError(.EIO)
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: temporaryURL.path))
            try handle.synchronize()
            try handle.close()
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            guard Darwin.rename(temporaryURL.path, destinationURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let directoryFD = Darwin.open(directoryURL.path, O_RDONLY)
            if directoryFD >= 0 {
                fsync(directoryFD)
                close(directoryFD)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
