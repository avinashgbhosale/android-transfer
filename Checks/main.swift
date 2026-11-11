import Foundation
import TransferCore
import MTPBridge

// Standalone checks also work with Command Line Tools, without full Xcode/XCTest.
var count = 0
func check(_ condition: Bool, _ message: String) {
    guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    count += 1
}
func expectFailure(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); check(false, message) } catch { count += 1 }
}
check(FileSafety.safeName("../../secret.txt") == "secret.txt", "path traversal")
check(FileSafety.safeName("..\\..\\photo.jpg") == "photo.jpg", "Windows path traversal")
check(FileSafety.safeName("..") == "Download", "parent path")
check(FileSafety.safeName("") == "Download", "empty name")
check(FileSafety.safeName("夏の写真.jpg") == "夏の写真.jpg", "Unicode names")
let existing = [PhoneEntry(object: 1, storage: 1, name: "Photos", size: 0, folder: true)]
expectFailure("duplicate upload") { try FileSafety.checkUpload(name: "photos", entries: existing) }
try FileSafety.checkUpload(name: "new.jpg", entries: existing)
for invalid in ["", "   ", ".", "..", "a/b", "a\\b", String(repeating: "x", count: 241)] {
    expectFailure("invalid phone name: \(invalid)") { try FileSafety.validatePhoneName(invalid) }
}
try FileSafety.validatePhoneName("Summer photos")
let cancellation = TransferCancellation()
check(!cancellation.isCancelled, "cancellation starts clear")
cancellation.request()
check(cancellation.isCancelled, "cancellation request")
cancellation.reset()
check(!cancellation.isCancelled, "cancellation reset")
check(TransferMetrics.summary(bytes: 0, total: 100, elapsed: 1) == "Calculating speed…", "empty transfer metrics")
check(TransferMetrics.summary(bytes: 50, total: 100, elapsed: 1).contains("/s"), "transfer speed metrics")
check(TransferMetrics.summary(bytes: 50, total: 100, elapsed: 1).contains("left"), "transfer ETA metrics")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let destination = directory.appendingPathComponent("important.txt")
try Data("original".utf8).write(to: destination)
expectFailure("failed download") {
    try FileSafety.download(to: destination) { fd in
        _ = "partial".withCString { write(fd, $0, 7) }
        throw TransferError(message: "Cable disconnected")
    }
}
check(try String(contentsOf: destination, encoding: .utf8) == "original", "failed transfer preserves original")
check(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["important.txt"], "partial file cleanup")
try FileSafety.download(to: destination) { fd in
    check("complete".withCString { write(fd, $0, 8) } == 8, "complete write")
}
check(try String(contentsOf: destination, encoding: .utf8) == "complete", "publish successful transfer")
check(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["important.txt"], "successful cleanup")
guard let session = mtp_create() else { fatalError("Cannot create MTP session") }
defer { mtp_destroy(session) }
check(mtp_list(session, 0, UInt32.max, nil, nil) == -1, "list without phone")
check(String(cString: mtp_error(session)).contains("Connect your phone"), "actionable USB error")
check(mtp_download(session, 1, -1, nil, nil) == -1, "download without phone")
check(mtp_upload(session, 1, 0, "/missing", "missing", nil, nil) == -1, "upload without phone")
var folderID: UInt32 = 0
check(mtp_create_folder(session, 1, 0, "Folder", &folderID) == -1, "create folder without phone")
check(mtp_rename(session, 1, "Renamed") == -1, "rename without phone")
check(mtp_delete(session, 1) == -1, "delete without phone")

let scanRoot = directory.appendingPathComponent("Upload Folder")
let nested = scanRoot.appendingPathComponent("Nested")
try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
try Data("one".utf8).write(to: scanRoot.appendingPathComponent("one.txt"))
try Data("twenty".utf8).write(to: nested.appendingPathComponent("two.txt"))
try Data("hidden".utf8).write(to: scanRoot.appendingPathComponent(".DS_Store"))
let tree = try UploadScanner.scan(scanRoot)
check(tree.isDirectory, "folder scan type")
check(tree.fileCount == 2, "recursive file count and hidden-file skip")
check(tree.size == 9, "recursive byte count")
check(tree.children?.map(\.name) == ["Nested", "one.txt"], "stable folder ordering")
let link = directory.appendingPathComponent("unsafe-link")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
expectFailure("symbolic-link rejection") { _ = try UploadScanner.scan(link) }

let downloadedFolder = directory.appendingPathComponent("Downloaded Folder")
expectFailure("failed folder download") {
    try FileSafety.downloadDirectory(to: downloadedFolder) { temporary in
        try Data("partial".utf8).write(to: temporary.appendingPathComponent("partial.txt"))
        throw TransferError(message: "Phone disconnected")
    }
}
check(!FileManager.default.fileExists(atPath: downloadedFolder.path), "failed folder is not published")
check(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".android-transfer-folder-") }, "folder temporary cleanup")
try FileSafety.downloadDirectory(to: downloadedFolder) { temporary in
    try Data("complete".utf8).write(to: temporary.appendingPathComponent("complete.txt"))
}
check(try String(contentsOf: downloadedFolder.appendingPathComponent("complete.txt"), encoding: .utf8) == "complete", "completed folder publication")
expectFailure("existing folder preservation") {
    try FileSafety.downloadDirectory(to: downloadedFolder) { _ in }
}
print("Passed \(count) checks.")
