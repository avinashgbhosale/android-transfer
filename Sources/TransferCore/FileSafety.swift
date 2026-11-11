import Foundation

public final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isCancelled: Bool { lock.withLock { value } }
    public func request() { lock.withLock { value = true } }
    public func reset() { lock.withLock { value = false } }
}

public enum TransferMetrics {
    public static func summary(bytes: UInt64, total: UInt64, elapsed: TimeInterval) -> String {
        guard elapsed > 0, bytes > 0 else { return "Calculating speed…" }
        let speed = Double(bytes) / elapsed
        let speedText = ByteCountFormatter.string(fromByteCount: Int64(min(speed, Double(Int64.max))), countStyle: .file) + "/s"
        guard total > bytes, speed > 0 else { return speedText }
        let seconds = Int(ceil(Double(total - bytes) / speed))
        if seconds < 60 { return "\(speedText) · \(seconds)s left" }
        return "\(speedText) · \(Int(ceil(Double(seconds) / 60)))m left"
    }
}

public struct PhoneEntry: Identifiable, Hashable {
    public let object: UInt32
    public let storage: UInt32
    public let name: String
    public let size: UInt64
    public let folder: Bool
    public init(object: UInt32, storage: UInt32, name: String, size: UInt64, folder: Bool) {
        self.object = object; self.storage = storage; self.name = name; self.size = size; self.folder = folder
    }
    public var id: String { "\(storage):\(object)" }
}
public struct TransferError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum FileSafety {
    public static func safeName(_ name: String) -> String {
        let last = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "Download"
        return last == "." || last == ".." ? "Download" : last
    }
    public static func checkUpload(name: String, entries: [PhoneEntry]) throws {
        try validatePhoneName(name)
        if entries.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw TransferError(message: "A file or folder named ‘\(name)’ already exists on the phone. Rename your local file before uploading.")
        }
    }
    public static func validatePhoneName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." ||
            name.contains("/") || name.contains("\\") || name.contains("\0") || name.utf8.count > 240 {
            throw TransferError(message: "Use a name under 240 bytes without slashes, null characters, or dot-only paths.")
        }
    }
    // Keep partial data beside the destination; publish only after a successful transfer.
    public static func download(to destination: URL, write: (Int32) throws -> Void) throws {
        var template = Array(destination.deletingLastPathComponent().appendingPathComponent(".android-transfer-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw TransferError(message: "Cannot create a temporary download in this folder.") }
        let temporary = String(cString: template)
        defer { close(fd); unlink(temporary) }
        try write(fd)
        guard fsync(fd) == 0 else { throw TransferError(message: "Could not finish saving the file. Check available disk space.") }
        guard rename(temporary, destination.path) == 0 else {
            throw TransferError(message: "Cannot save the completed download: \(String(cString: strerror(errno)))")
        }
    }
    public static func downloadDirectory(to destination: URL, write: (URL) throws -> Void) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            throw TransferError(message: "A file or folder named ‘\(destination.lastPathComponent)’ already exists on this Mac.")
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".android-transfer-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try write(temporary)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw TransferError(message: "Cannot publish the completed folder: \(error.localizedDescription)")
        }
    }
}

public struct LocalUploadNode: Sendable {
    public let url: URL
    public let name: String
    public let size: UInt64
    public let children: [LocalUploadNode]?
    public var isDirectory: Bool { children != nil }
    public var fileCount: Int { children?.reduce(0) { $0 + $1.fileCount } ?? 1 }
}

public enum UploadScanner {
    public static func scan(_ url: URL) throws -> LocalUploadNode {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true {
            throw TransferError(message: "Symbolic links are not transferred: \(url.lastPathComponent)")
        }
        if values.isRegularFile == true {
            return LocalUploadNode(url: url, name: url.lastPathComponent,
                                   size: UInt64(max(0, values.fileSize ?? 0)), children: nil)
        }
        if values.isDirectory == true {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let children = try urls.map(scan)
            return LocalUploadNode(url: url, name: url.lastPathComponent,
                                   size: children.reduce(0) { $0 + $1.size }, children: children)
        }
        throw TransferError(message: "Only regular files and folders can be transferred: \(url.lastPathComponent)")
    }
}
