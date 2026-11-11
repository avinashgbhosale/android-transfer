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
print("Passed \(count) checks.")
