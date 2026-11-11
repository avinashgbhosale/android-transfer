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
enum TransferJobState: String {
    case queued = "Queued"
    case preparing = "Preparing"
    case transferring = "Transferring"
    case completed = "Completed"
    case failed = "Failed"
}
struct TransferJob: Identifiable {
    let id: UUID
    let name: String
    let direction: String
    var detail: String
    var progress: Double
    var state: TransferJobState
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
    @Published var jobs: [TransferJob] = []
    @Published var dropTargeted = false
    let queue = DispatchQueue(label: "AndroidTransfer.USB")
    private var session: OpaquePointer?
    var current: Location { path.last! }
    var selected: PhoneEntry? { entries.first { $0.id == selection } }
    var filtered: [PhoneEntry] { entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var hasTransfers: Bool { !jobs.isEmpty }

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
    private func updateJob(_ id: UUID, state: TransferJobState? = nil, progress: Double? = nil, detail: String? = nil) {
        DispatchQueue.main.async {
            guard let index = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            if let state { self.jobs[index].state = state }
            if let progress { self.jobs[index].progress = min(1, max(0, progress)) }
            if let detail { self.jobs[index].detail = detail }
        }
    }
    func clearFinishedJobs() {
        guard !busy else { return }
        jobs.removeAll { $0.state == .completed || $0.state == .failed }
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
    func createFolder() {
        guard connected, !busy, current.storage != 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Create folder on phone"
        alert.informativeText = "Enter a name for the new folder in \(current.name)."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "New Folder")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        do {
            try FileSafety.checkUpload(name: name, entries: entries)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let location = current
        run("Creating \(name)…") {
            var folderID: UInt32 = 0
            try self.check(mtp_create_folder(self.session, location.storage, location.parent, name, &folderID))
            let entries = try self.list(location)
            DispatchQueue.main.async {
                self.entries = entries
                self.status = "Created folder \(name)."
            }
        }
    }
    func renameSelected() {
        guard connected, !busy, current.storage != 0, let entry = selected else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(entry.folder ? "folder" : "file")"
        alert.informativeText = "Enter a new name for \(entry.name)."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: entry.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        if name == entry.name { return }
        do {
            try FileSafety.checkUpload(name: name, entries: entries.filter { $0.id != entry.id })
        } catch {
            self.error = error.localizedDescription
            return
        }
        let location = current
        run("Renaming \(entry.name)…") {
            try self.check(mtp_rename(self.session, entry.object, name))
            let entries = try self.list(location)
            DispatchQueue.main.async {
                self.entries = entries
                self.selection = entries.first(where: { $0.object == entry.object })?.id
                self.status = "Renamed \(entry.name) to \(name)."
            }
        }
    }
    func deleteSelected() {
        guard connected, !busy, current.storage != 0, let entry = selected else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Permanently delete \(entry.name)?"
        alert.informativeText = entry.folder
            ? "The folder and everything inside it will be deleted from the phone. This cannot be undone."
            : "The file will be deleted from the phone. This cannot be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        alert.buttons[1].hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let location = current
        run("Deleting \(entry.name)…") {
            try self.check(mtp_delete(self.session, entry.object))
            let entries = try self.list(location)
            DispatchQueue.main.async {
                self.entries = entries
                self.selection = nil
                self.status = "Deleted \(entry.name)."
            }
        }
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
    func download() {
        guard !busy, let entry = selected, !entry.folder else { return }
        let panel = NSSavePanel()
        panel.title = "Download to Mac"; panel.nameFieldStringValue = FileSafety.safeName(entry.name)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let jobID = UUID()
        jobs.append(TransferJob(id: jobID, name: entry.name, direction: "Phone → Mac",
                                detail: destination.deletingLastPathComponent().path, progress: 0, state: .queued))
        run("Downloading \(entry.name)…", transfer: true) {
            do {
                self.updateJob(jobID, state: .transferring)
                let sink = ProgressSink { value in
                    DispatchQueue.main.async { self.progress = value }
                    self.updateJob(jobID, progress: value)
                }
                try FileSafety.download(to: destination) { fd in
                    try self.check(mtp_download(self.session, entry.object, fd, progressCallback, Unmanaged.passUnretained(sink).toOpaque()))
                }
                self.updateJob(jobID, state: .completed, progress: 1, detail: destination.path)
                DispatchQueue.main.async { self.status = "Saved \(entry.name) to \(destination.deletingLastPathComponent().lastPathComponent)." }
            } catch {
                self.updateJob(jobID, state: .failed, detail: error.localizedDescription)
                throw error
            }
        }
    }
    func upload() {
        guard !busy, connected, current.storage != 0 else { return }
        let panel = NSOpenPanel()
        panel.title = "Upload files or folders to phone"; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        enqueueUploads(panel.urls)
    }
    func enqueueDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        guard connected, !busy, current.storage != 0 else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: NSURL.self) {
            group.enter()
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = object as? URL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if urls.isEmpty { self.error = "The dropped items do not contain files or folders." }
            else { self.enqueueUploads(urls.sorted { $0.path < $1.path }) }
        }
        return true
    }
    func enqueueUploads(_ urls: [URL]) {
        guard !busy, connected, current.storage != 0, !urls.isEmpty else { return }
        let location = current
        let queued = urls.map { url in
            TransferJob(id: UUID(), name: url.lastPathComponent, direction: "Mac → Phone",
                        detail: "Waiting to scan", progress: 0, state: .queued)
        }
        jobs.append(contentsOf: queued)
        run("Preparing upload…", transfer: true) {
            var existing = try self.list(location)
            var failures = 0
            for (index, pair) in zip(urls, queued).enumerated() {
                let file = pair.0, job = pair.1
                do {
                    self.updateJob(job.id, state: .preparing, detail: "Scanning")
                    let node = try UploadScanner.scan(file)
                    try FileSafety.checkUpload(name: node.name, entries: existing)
                    existing.append(PhoneEntry(object: 0, storage: location.storage, name: node.name,
                                               size: node.size, folder: node.isDirectory))
                    let count = node.fileCount
                    self.updateJob(job.id, state: .transferring,
                                   detail: node.isDirectory ? "\(count) file(s)" : ByteCountFormatter.string(fromByteCount: Int64(clamping: node.size), countStyle: .file))
                    DispatchQueue.main.async {
                        self.status = "Uploading \(index + 1)/\(urls.count): \(node.name)…"; self.progress = 0
                    }
                    var completed: UInt64 = 0
                    try self.uploadNode(node, storage: location.storage, parent: location.parent,
                                        jobID: job.id, completed: &completed, total: node.size)
                    self.updateJob(job.id, state: .completed, progress: 1,
                                   detail: node.isDirectory ? "\(count) file(s) uploaded" : "Uploaded")
                } catch {
                    failures += 1
                    self.updateJob(job.id, state: .failed, detail: error.localizedDescription)
                }
            }
            let entries = try self.list(location)
            DispatchQueue.main.async {
                self.entries = entries
                self.status = failures == 0 ? "Uploaded \(urls.count) item(s)." : "Finished with \(failures) failed item(s)."
                if failures > 0 { self.error = "Some items failed. Review the transfer queue for details." }
            }
        }
    }
    private func uploadNode(_ node: LocalUploadNode, storage: UInt32, parent: UInt32,
                            jobID: UUID, completed: inout UInt64, total: UInt64) throws {
        try FileSafety.validatePhoneName(node.name)
        if let children = node.children {
            var folderID: UInt32 = 0
            try check(mtp_create_folder(session, storage, parent, node.name, &folderID))
            for child in children {
                try uploadNode(child, storage: storage, parent: folderID, jobID: jobID,
                               completed: &completed, total: total)
            }
            if total == 0 { updateJob(jobID, progress: 1) }
            return
        }
        let alreadyCompleted = completed
        let sink = ProgressSink { value in
            let aggregate = total == 0 ? 1 : (Double(alreadyCompleted) + value * Double(node.size)) / Double(total)
            DispatchQueue.main.async { self.progress = aggregate }
            self.updateJob(jobID, progress: aggregate, detail: "Uploading \(node.name)")
        }
        try check(mtp_upload(session, storage, parent, node.url.path, node.name,
                             progressCallback, Unmanaged.passUnretained(sink).toOpaque()))
        completed += node.size
        let aggregate = total == 0 ? 1 : Double(completed) / Double(total)
        updateJob(jobID, progress: aggregate)
    }
}
