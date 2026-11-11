import Foundation
import AppKit
import MTPBridge

import TransferCore

struct Location {
    let storage: UInt32
    let parent: UInt32
    let name: String
    static let root = Location(storage: 0, parent: UInt32.max, name: "Phone")
}
private final class EntryCollector { var entries: [PhoneEntry] = [] }
private let entryCallback: MTPEntryCallback = { object, storage, name, size, folder, context in
    guard let context, let name else { return }
    Unmanaged<EntryCollector>.fromOpaque(context).takeUnretainedValue().entries.append(
        PhoneEntry(object: object, storage: storage, name: String(cString: name), size: size, folder: folder != 0))
}
private final class ProgressSink {
    let update: (Double) -> Void
    var last = Date.distantPast
    init(_ update: @escaping (Double) -> Void) { self.update = update }
}
private let progressCallback: MTPProgressCallback = { done, total, context in
    guard let context else { return 0 }
    let sink = Unmanaged<ProgressSink>.fromOpaque(context).takeUnretainedValue()
    if Date().timeIntervalSince(sink.last) > 0.08 || done == total {
        sink.last = Date()
        sink.update(total == 0 ? 0 : min(1, Double(done) / Double(total)))
    }
    return 0
}

// Every libmtp call, including connection lifetime, runs on this single queue.
final class TransferModel: ObservableObject {
    @Published var entries: [PhoneEntry] = []
    @Published var selection: String?
    @Published var path: [Location] = [.root]
    @Published var busy = false
    @Published var connected = false
    @Published var status = "Connect your Android phone to get started."
    @Published var progress: Double? = nil
    @Published var error: String?
    @Published var search = ""
    let queue = DispatchQueue(label: "AndroidTransfer.USB")
    private var session: OpaquePointer?
    var current: Location { path.last! }
    var selected: PhoneEntry? { entries.first { $0.id == selection } }
    var filtered: [PhoneEntry] { entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }

    private func check(_ result: Int32) throws {
        if result != 0 { throw TransferError(message: session.map { String(cString: mtp_error($0)) } ?? "USB session unavailable.") }
    }
    private func list(_ location: Location) throws -> [PhoneEntry] {
        let collector = EntryCollector()
        try check(mtp_list(session, location.storage, location.parent, entryCallback, Unmanaged.passUnretained(collector).toOpaque()))
        return collector.entries.sorted {
            if $0.folder != $1.folder { return $0.folder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private func run(_ message: String, transfer: Bool = false, work: @escaping () throws -> Void) {
        guard !busy else { return }
        busy = true; status = message; error = nil; progress = transfer ? 0 : nil
        queue.async {
            do { try work() }
            catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self.error = message; self.status = "Operation failed. See details below." }
            }
            DispatchQueue.main.async { self.busy = false; self.progress = nil }
        }
    }
    func connect() {
        guard !busy else { return }
        connected = false; entries = []; selection = nil; path = [.root]
        run("Looking for your phone…") {
            if self.session == nil { self.session = mtp_create() }
            guard self.session != nil else { throw TransferError(message: "Cannot start USB session.") }
            try self.check(mtp_connect(self.session))
            let entries = try self.list(.root)
            DispatchQueue.main.async {
                self.connected = true; self.entries = entries
                self.status = entries.isEmpty ? "No storage available. Unlock your phone and reconnect." : "Connected. Open a storage location to browse files."
            }
        }
    }
    func navigate(_ newPath: [Location]) {
        guard connected, !busy, let target = newPath.last else { return }
        run("Reading \(target.name)…") {
            let entries = try self.list(target)
            DispatchQueue.main.async {
                self.path = newPath; self.entries = entries; self.selection = nil; self.search = ""
                self.status = "\(entries.count) items"
            }
        }
    }
    func openSelected() {
        guard let entry = selected, entry.folder else { return }
        navigate(path + [Location(storage: entry.storage, parent: entry.object, name: entry.name)])
    }
    func disconnect() {
        run("Disconnecting…") {
            if let session = self.session { mtp_destroy(session); self.session = nil }
            DispatchQueue.main.async {
                self.connected = false; self.entries = []; self.path = [.root]; self.selection = nil
                self.status = "Disconnected. You can unplug your phone."
            }
        }
    }
    private func progressSink() -> ProgressSink {
        ProgressSink { value in DispatchQueue.main.async { self.progress = value } }
    }
    func download() {
        guard !busy, let entry = selected, !entry.folder else { return }
        let panel = NSSavePanel()
        panel.title = "Download to Mac"; panel.nameFieldStringValue = FileSafety.safeName(entry.name)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        run("Downloading \(entry.name)…", transfer: true) {
            let sink = self.progressSink()
            try FileSafety.download(to: destination) { fd in
                try self.check(mtp_download(self.session, entry.object, fd, progressCallback, Unmanaged.passUnretained(sink).toOpaque()))
            }
            DispatchQueue.main.async { self.status = "Saved \(entry.name) to \(destination.deletingLastPathComponent().lastPathComponent)." }
        }
    }
    func upload() {
        guard !busy, connected, current.storage != 0 else { return }
        let panel = NSOpenPanel()
        panel.title = "Upload files to phone"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let files = panel.urls, location = current
        run("Preparing upload…", transfer: true) {
            var existing = try self.list(location)
            // Validate the complete batch before transferring any files.
            for file in files {
                try FileSafety.checkUpload(name: file.lastPathComponent, entries: existing)
                existing.append(PhoneEntry(object: 0, storage: location.storage, name: file.lastPathComponent, size: 0, folder: false))
            }
            for (index, file) in files.enumerated() {
                DispatchQueue.main.async { self.status = "Uploading \(index + 1)/\(files.count): \(file.lastPathComponent)…"; self.progress = 0 }
                let sink = self.progressSink()
                try self.check(mtp_upload(self.session, location.storage, location.parent, file.path, file.lastPathComponent,
                                          progressCallback, Unmanaged.passUnretained(sink).toOpaque()))
            }
            let entries = try self.list(location)
            DispatchQueue.main.async { self.entries = entries; self.status = "Uploaded \(files.count) file(s)." }
        }
    }
}
