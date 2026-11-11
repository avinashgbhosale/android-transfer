import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import WirelessCore
import UniformTypeIdentifiers

final class WirelessModel: ObservableObject {
    @Published var confirmStop = false
    @Published var running = false
    @Published var starting = false
    @Published var stopping = false
    @Published var addresses: [String] = []
    @Published var address = ""
    @Published var port: UInt16 = 0
    @Published var token = ""
    @Published var status = "Start sharing, then scan the QR code with your phone."
    @Published var files: [SharedFile] = []
    @Published var error: String?
    @Published var dropTargeted = false
    private var server: WirelessServer?
    let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Android Transfer", isDirectory: true)
    var link: String { running && !address.isEmpty ? "http://\(address):\(port)/\(token)/" : "" }
    var qr: NSImage? {
        guard !link.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
    func start() {
        guard !starting, !running, !stopping else { return }
        addresses = localAddresses(); address = addresses.first ?? ""
        guard !address.isEmpty else { error = "No local network address found. Connect your Mac to Wi-Fi and try again."; return }
        starting = true; error = nil
        let server = WirelessServer(folder: folder)
        self.server = server
        server.onReady = { [weak self, weak server] port, token in DispatchQueue.main.async {
            guard let self, let server, self.server === server, !self.stopping else { return }
            self.port = port; self.token = token; self.running = true; self.starting = false
            self.status = "Ready. Scan the QR code on your phone."
        } }
        server.onStatus = { [weak self, weak server] message in DispatchQueue.main.async {
            guard let self, let server, self.server === server, !self.stopping else { return }
            self.status = message
            if message.hasPrefix("Received ") || message.hasPrefix("Sent ") {
                TransferNotifications.shared.send(title: "Wireless transfer complete", body: message)
            }
        } }
        server.onFailure = { [weak self, weak server] message in DispatchQueue.main.async {
            guard let self, let server, self.server === server, !self.stopping else { return }
            self.error = message; self.running = false; self.starting = false
        } }
        server.setFiles(files); server.start()
    }
    func stop(completion: @escaping () -> Void = {}) {
        running = false; starting = false; token = ""
        guard let server else { DispatchQueue.main.async(execute: completion); return }
        stopping = true
        status = "Stopping sharing and cleaning up incomplete uploads…"
        server.stop { DispatchQueue.main.async {
            if self.server === server {
                self.server = nil; self.stopping = false
                self.status = "Sharing stopped. The previous link no longer works."
            }
            completion()
        } }
    }
    func addFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.title = "Choose files your phone can download"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !files.contains(where: { $0.url == url }) { files.append(SharedFile(url: url)) }
        server?.setFiles(files)
    }
    func addDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup(), lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: NSURL.self) {
            group.enter()
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = object as? URL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            var rejected = 0
            for url in urls {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                if values?.isRegularFile == true {
                    if !self.files.contains(where: { $0.url == url }) { self.files.append(SharedFile(url: url)) }
                } else { rejected += 1 }
            }
            self.server?.setFiles(self.files)
            if rejected > 0 { self.error = "Wireless sharing accepts files only; use USB to upload folders." }
        }
        return !providers.isEmpty
    }
    func remove(_ id: String) { files.removeAll { $0.id == id }; server?.setFiles(files) }
    func copyLink() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) }
    func revealFolder() {
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); NSWorkspace.shared.open(folder) }
        catch { self.error = error.localizedDescription }
    }
}

struct WirelessView: View {
    @ObservedObject var model: WirelessModel
    @ObservedObject private var notifications = TransferNotifications.shared
    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Wireless transfer", systemImage: "wifi").font(.largeTitle.bold())
                Text("Same Wi-Fi. No Android app needed.").foregroundStyle(.secondary)
                if model.running {
                    if let qr = model.qr {
                        Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 230, height: 230).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Scan this QR code with your phone camera")
                    }
                    Text("Scan with your phone camera").font(.headline)
                    if model.addresses.count > 1 {
                        Picker("Mac address", selection: $model.address) {
                            ForEach(model.addresses, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Text(model.link).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                    HStack {
                        Button("Copy link", action: model.copyLink)
                        Button("Open page") { if let url = URL(string: model.link) { NSWorkspace.shared.open(url) } }
                    }
                    Button("Stop sharing", role: .destructive) { model.confirmStop = true }
                } else {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 100)).foregroundStyle(.secondary).frame(width: 260, height: 230)
                    Button(model.stopping ? "Stopping…" : model.starting ? "Starting…" : "Start wireless sharing", action: model.start)
                        .buttonStyle(.borderedProminent).disabled(model.starting || model.stopping)
                }
                Text("Use a trusted Wi-Fi network. Transfers use local HTTP, and anyone with the link can access the shared files while sharing is on.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(action: notifications.toggle) {
                    Label(notifications.enabled ? "Notifications on" : "Enable notifications",
                          systemImage: notifications.enabled ? "bell.fill" : "bell")
                }
            }.frame(width: 310)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("Mac → Phone").font(.title2.bold())
                Text("Add files here, then tap Refresh files on your phone.").foregroundStyle(.secondary)
                Button("Add files to share…", action: model.addFiles)
                List(model.files) { file in
                    HStack {
                        Image(systemName: "doc")
                        Text(file.url.lastPathComponent).lineLimit(2)
                        Spacer()
                        Button { model.remove(file.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Stop sharing this file")
                    }.padding(.vertical, 5)
                }.overlay {
                    if model.dropTargeted {
                        RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12))
                        Text("Drop files to share").font(.headline).foregroundStyle(Color.accentColor)
                    } else if model.files.isEmpty {
                        Text("Add or drop files here. Only these files appear on your phone.").foregroundStyle(.secondary).padding()
                    }
                }
                .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted, perform: model.addDroppedFiles)
                Divider()
                Text("Phone → Mac").font(.title2.bold())
                Text("Choose files on the phone’s transfer page and tap Send selected files. Duplicate names get a numbered prefix.").foregroundStyle(.secondary)
                Button("Open received files", action: model.revealFolder)
                Text(model.folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Text(model.status).font(.callout).textSelection(.enabled)
                Text("If the page won’t open, allow local network access or incoming connections when macOS asks. Guest Wi-Fi may block device-to-device traffic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(28)
        .confirmationDialog("Stop wireless sharing? Active transfers will be interrupted.", isPresented: $model.confirmStop) {
            Button("Stop sharing", role: .destructive) { model.stop() }
        }
    }
}
