import SwiftUI
import AppKit
import TransferCore
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: TransferModel?
    weak var wireless: WirelessModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true {
            let alert = NSAlert()
            alert.messageText = "Wait for the current operation to finish"
            alert.informativeText = "Keep the phone connected until the transfer completes."
            alert.runModal()
            return .terminateCancel
        }
        if wireless?.stopping == true {
            wireless?.stop { sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        if wireless?.running == true || wireless?.starting == true {
            let alert = NSAlert()
            alert.messageText = "Stop wireless sharing and quit?"
            alert.informativeText = "Any active wireless transfers will be interrupted."
            alert.addButton(withTitle: "Keep sharing"); alert.addButton(withTitle: "Stop and quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            wireless?.stop { sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        return .terminateNow
    }
}
@main
struct AndroidTransferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = TransferModel()
    @StateObject private var wireless = WirelessModel()
    var body: some Scene {
        WindowGroup {
            TabView {
                WirelessView(model: wireless).tabItem { Label("Wireless", systemImage: "wifi") }
                ContentView(model: model).tabItem { Label("USB cable", systemImage: "cable.connector") }
            }.onAppear { delegate.model = model; delegate.wireless = wireless }
                .frame(minWidth: 900, minHeight: 700)
        }.defaultSize(width: 1000, height: 760)
    }
}
struct ContentView: View {
    @ObservedObject var model: TransferModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                Label("Android Transfer", systemImage: "cable.connector").font(.title3.bold())
                Label(model.connected ? "Phone connected" : "Ready to connect", systemImage: model.connected ? "checkmark.circle.fill" : "iphone")
                    .foregroundStyle(model.connected ? .green : .secondary)
                Divider()
                Text("CONNECT WITH USB").font(.caption.bold()).foregroundStyle(.secondary)
                instruction("1", "Plug in your phone", "Use a USB cable that carries data.")
                instruction("2", "Unlock Android", "Allow file access if prompted.")
                instruction("3", "Choose File transfer", "Tap the USB notification on your phone.")
                Button(model.connected ? "Reconnect phone" : "Connect phone", action: model.connect)
                    .buttonStyle(.borderedProminent).disabled(model.busy)
                Spacer()
                Text("Files travel directly over USB.\nNo account or cloud upload.").font(.caption).foregroundStyle(.secondary)
                if model.connected { Button("Disconnect", action: model.disconnect).disabled(model.busy) }
            }.padding(24).frame(width: 230).frame(maxHeight: .infinity).background(.quaternary.opacity(0.4))
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.current.name).font(.largeTitle.bold())
                        Text(model.path.map(\.name).joined(separator: " / ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button { model.navigate(Array(model.path.dropLast())) } label: { Image(systemName: "arrow.up") }
                        .help("Parent folder").disabled(model.busy || model.path.count < 2)
                    Button { model.navigate(model.path) } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh folder").disabled(model.busy || !model.connected)
                }
                HStack {
                    Button(action: model.upload) { Label("Upload to phone", systemImage: "arrow.up.doc") }
                        .disabled(model.busy || !model.connected || model.current.storage == 0)
                    Button(action: model.download) { Label("Download to Mac", systemImage: "arrow.down.doc") }
                        .disabled(model.busy || model.selected == nil || model.selected?.folder == true)
                    Button("Open folder", action: model.openSelected).disabled(model.busy || model.selected?.folder != true)
                }
                TextField("Search this folder", text: $model.search).textFieldStyle(.roundedBorder)
                if !model.connected && !model.busy {
                    VStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.plus").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("Your phone’s files, on your Mac").font(.title2)
                        Text("Follow the steps on the left, then click Connect phone.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(model.filtered, selection: $model.selection) {
                        TableColumn("Name") { entry in
                            Label(entry.name, systemImage: entry.folder ? "folder.fill" : "doc")
                                .foregroundStyle(entry.folder ? Color.accentColor : Color.primary)
                        }
                        TableColumn("Size") { entry in
                            Text(entry.folder ? (model.current.storage == 0 ? "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)) free" : "—") : ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }.width(min: 90, ideal: 120)
                    }.disabled(model.busy)
                        .overlay {
                            if model.dropTargeted {
                                RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12))
                                VStack(spacing: 8) {
                                    Image(systemName: "arrow.down.doc").font(.system(size: 34))
                                    Text("Drop files or folders to upload").font(.headline)
                                }.foregroundStyle(Color.accentColor)
                            }
                        }
                        .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted,
                                perform: model.enqueueDroppedItems)
                    if model.filtered.isEmpty && !model.busy { Text(model.search.isEmpty ? "This folder is empty." : "No matching files.").foregroundStyle(.secondary) }
                }
                if model.hasTransfers {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Transfer queue").font(.headline)
                            Spacer()
                            Button("Clear finished", action: model.clearFinishedJobs).disabled(model.busy)
                        }
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(model.jobs) { job in
                                    HStack(spacing: 10) {
                                        Image(systemName: job.state == .completed ? "checkmark.circle.fill" : job.state == .failed ? "exclamationmark.triangle.fill" : "arrow.left.arrow.right.circle")
                                            .foregroundStyle(job.state == .completed ? .green : job.state == .failed ? .orange : Color.accentColor)
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack { Text(job.name).lineLimit(1); Spacer(); Text(job.state.rawValue).font(.caption).foregroundStyle(.secondary) }
                                            ProgressView(value: job.progress)
                                            Text("\(job.direction) · \(job.detail)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }.frame(maxHeight: 170)
                    }
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                if let progress = model.progress { ProgressView(value: progress) }
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    Spacer()
                    if let progress = model.progress { Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
                }
            }.padding(24)
        }
    }
    private func instruction(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.bold()).frame(width: 22, height: 22).background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
