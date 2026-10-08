import Foundation
import CryptoKit
import Darwin

public struct FileMetadata: Sendable {
    public let url: URL
    public let identity: FileIdentity
    public let size: Int64
    public let modifiedNanos: Int64
    public let capturedAt: Date

    public var modifiedDate: Date {
        Date(timeIntervalSince1970: Double(modifiedNanos) / 1_000_000_000.0)
    }
}

public enum FileOperations {
    /// Reads inode, dev, size, mtime (nanos), and birthtime via stat().
    public static func metadata(for url: URL) -> FileMetadata? {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            return nil
        }

        let dev = Int64(st.st_dev)
        let ino = UInt64(st.st_ino)
        let size = Int64(st.st_size)
        let mtimeNanos = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)

        let birthSec = TimeInterval(st.st_birthtimespec.tv_sec) + TimeInterval(st.st_birthtimespec.tv_nsec) / 1_000_000_000.0
        let birthDate: Date
        if birthSec > 0 {
            birthDate = Date(timeIntervalSince1970: birthSec)
        } else {
            // Fallback to mtime if birthtime is not available on filesystem
            birthDate = Date(timeIntervalSince1970: Double(mtimeNanos) / 1_000_000_000.0)
        }

        return FileMetadata(
            url: url,
            identity: FileIdentity(device: dev, inode: ino),
            size: size,
            modifiedNanos: mtimeNanos,
            capturedAt: birthDate
        )
    }

    /// Computes SHA-256 of file streaming in chunks, avoiding loading large files into RAM.
    public static func computeSHA256(for url: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let bufferSize = 64 * 1024 // 64 KB chunks
        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Moves a file to the macOS Trash using native FileManager API.
    public static func moveToTrash(url: URL) throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    /// Permanently deletes a file.
    public static func deletePermanently(url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Performs cleanup according to the configured action.
    public static func performCleanup(url: URL, action: CleanupAction) throws {
        switch action {
        case .trash:
            try moveToTrash(url: url)
        case .delete:
            try deletePermanently(url: url)
        case .keep:
            break
        }
    }

    /// Scans directory shallowly (no recursive traversal), filtering out hidden files and subdirectories.
    public static func listDirectoryItems(at directoryURL: URL) -> [URL] {
        do {
            let itemURLs = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            return itemURLs.filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
        } catch {
            return []
        }
    }

    /// Acquires an advisory file lock (flock) on a file descriptor.
    /// Returns the file descriptor on success, or -1 if already locked / failed.
    public static func tryLock(at url: URL) -> Int32 {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return -1 }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return fd
        } else {
            close(fd)
            return -1
        }
    }

    public static func unlock(fd: Int32) {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// Copies an image file directly onto the macOS system pasteboard via osascript.
    /// Does not require AppKit, allowing background CLI workers to put image data on the clipboard.
    public static func copyImageToClipboard(at url: URL) {
        let path = url.path
        let ext = url.pathExtension.lowercased()
        let classType: String
        switch ext {
        case "png": classType = "«class PNGf»"
        case "jpg", "jpeg": classType = "«class JPEG»"
        case "tiff", "tif": classType = "«class TIFF»"
        default: classType = "«class PNGf»"
        }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "set the clipboard to (read (POSIX file \"\(escaped)\") as \(classType))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        process.waitUntilExit()
    }

    /// Copies a UTF-8 string onto the macOS system pasteboard via pbcopy.
    public static func copyTextToClipboard(_ text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        try? process.run()
        if let data = text.data(using: .utf8) {
            pipe.fileHandleForWriting.write(data)
            try? pipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
    }
}
