import Foundation

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
        if entries.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw TransferError(message: "A file or folder named ‘\(name)’ already exists on the phone. Rename your local file before uploading.")
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
