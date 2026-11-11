import Foundation
import Network
import TransferCore

public struct SharedFile: Identifiable {
    public let id: String
    public let url: URL
    public init(url: URL) { self.id = UUID().uuidString; self.url = url }
}

public final class WirelessServer {
    private let queue = DispatchQueue(label: "AndroidTransfer.Wireless")
    private var listener: NWListener?
    private var clients: [UUID: HTTPClient] = [:]
    private var files: [SharedFile] = []
    private var token = ""
    private var folder: URL
    public var onReady: ((UInt16, String) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onFailure: ((String) -> Void)?
    public init(folder: URL) { self.folder = folder }
    public func setFiles(_ files: [SharedFile]) { queue.async { self.files = files } }
    public func start() {
        queue.async { [self] in
            guard self.listener == nil else { return }
            do {
                try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
                self.token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        if let port = listener?.port { self.onReady?(port.rawValue, self.token) }
                    case .failed(let error): self.onFailure?(error.localizedDescription); self.stopOnQueue()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self, weak listener] connection in
                    guard let self, let listener, self.listener === listener, self.clients.count < 16 else { connection.cancel(); return }
                    let client = HTTPClient(connection: connection, queue: self.queue, folder: self.folder, token: self.token,
                                            files: { [weak self] in self?.files ?? [] }, status: { [weak self] in self?.onStatus?($0) })
                    self.clients[client.id] = client
                    client.finished = { [weak self, weak client] in if let client { self?.clients.removeValue(forKey: client.id) } }
                    client.start()
                }
                listener.start(queue: self.queue)
            } catch { self.onFailure?(error.localizedDescription) }
        }
    }
    /// Completion runs only after connections close and partial uploads are removed.
    public func stop(completion: @escaping () -> Void = {}) {
        queue.async { self.stopOnQueue(); completion() }
    }
    private func stopOnQueue() {
        listener?.cancel(); listener = nil
        let active = Array(clients.values)
        for client in active { client.close() }
        clients.removeAll(); token = ""
    }
}

private final class HTTPClient {
    let id = UUID()
    var finished: (() -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let folder: URL
    private let token: String
    private let files: () -> [SharedFile]
    private let status: (String) -> Void
    private var buffer = Data()
    private var uploading = false
    private var remaining: UInt64 = 0
    private var total: UInt64 = 0
    private var handle: FileHandle?
    private var temporary: URL?
    private var filename = ""
    private var closed = false
    private var responding = false
    private var timer: DispatchSourceTimer?
    private var lastProgress = Date.distantPast
    init(connection: NWConnection, queue: DispatchQueue, folder: URL, token: String,
         files: @escaping () -> [SharedFile], status: @escaping (String) -> Void) {
        self.connection = connection; self.queue = queue; self.folder = folder
        self.token = token; self.files = files; self.status = status
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
        }
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.setEventHandler { [weak self] in self?.close() }
        timer.schedule(deadline: .now() + 60); timer.resume()
        receive()
    }
    func close() {
        guard !closed else { return }; closed = true
        timer?.cancel(); timer = nil
        try? handle?.close(); handle = nil
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        if uploading { status("Upload interrupted. Incomplete data removed.") }
        connection.cancel(); finished?()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            self.timer?.schedule(deadline: .now() + 60)
            if let data, !data.isEmpty {
                if self.uploading { self.consume(data) }
                else { self.buffer.append(data); self.parseHeader() }
            }
            if self.closed { return }
            if self.responding { return }
            if error != nil || complete { self.close(); return }
            if self.uploading || self.handle == nil && !self.buffer.isEmpty { self.receive() }
        }
    }
    private func parseHeader() {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 16384 { respond(431, "Headers too large") }
            return
        }
        guard end.lowerBound <= 16384, let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { respond(400, "Invalid headers"); return }
        let body = Data(buffer[end.upperBound...]); buffer.removeAll()
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0",
              let url = URLComponents(string: String(request[1])), url.scheme == nil, url.host == nil else { respond(400, "Invalid request"); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { respond(400, "Invalid header"); return }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { respond(400, "Duplicate header"); return }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard url.path.hasPrefix("/\(token)/") else { respond(403, "This link is invalid or has expired. Scan the QR code on your Mac."); return }
        if let origin = headers["origin"], origin != "http://\(headers["host"] ?? "")" { respond(403, "Origin not allowed"); return }
        guard headers["transfer-encoding"] == nil else { respond(400, "Content-Length is required"); return }
        let route = String(url.path.dropFirst(token.count + 2))
        if request[0] == "GET" {
            if route.isEmpty {
                guard let page = Bundle.module.url(forResource: "index", withExtension: "html"), let data = try? Data(contentsOf: page) else { respond(500, "Page unavailable"); return }
                respond(200, data: data, type: "text/html; charset=utf-8")
            } else if route == "files" {
                let entries = files().map { file -> [String: Any] in
                    let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return ["id": file.id, "name": file.url.lastPathComponent, "size": size]
                }
                respond(200, data: (try? JSONSerialization.data(withJSONObject: entries)) ?? Data("[]".utf8), type: "application/json")
            } else if route.hasPrefix("download/"), let file = files().first(where: { $0.id == String(route.dropFirst(9)) }) {
                download(file)
            } else { respond(404, "File not shared or no longer available") }
        } else if request[0] == "POST", route == "upload" {
            guard let length = headers["content-length"].flatMap(UInt64.init), length <= 20 * 1024 * 1024 * 1024,
                  let name = url.queryItems?.first(where: { $0.name == "name" })?.value, !name.isEmpty else { respond(400, "A filename and Content-Length up to 20 GB are required"); return }
            filename = FileSafety.safeName(name)
            guard !filename.contains("\0"), filename.utf8.count <= 240, !filename.hasPrefix(".") else { respond(400, "Use a visible filename under 240 bytes"); return }
            do {
                var template = Array(folder.appendingPathComponent(".incoming-XXXXXX").path.utf8CString)
                let fd = mkstemp(&template)
                guard fd >= 0 else { throw TransferError(message: "Cannot create destination file") }
                temporary = URL(fileURLWithPath: String(cString: template))
                handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                total = length; remaining = length; uploading = true
                if headers["expect"]?.lowercased() == "100-continue" { connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent) }
                consume(body)
            } catch { respond(500, error.localizedDescription) }
        } else { respond(405, "Method not allowed") }
    }
    private func consume(_ data: Data) {
        guard UInt64(data.count) <= remaining else { respond(400, "Body exceeds Content-Length"); return }
        do {
            try handle?.write(contentsOf: data); remaining -= UInt64(data.count)
            if Date().timeIntervalSince(lastProgress) > 0.2 {
                lastProgress = Date()
                status("Receiving \(filename): \(total == 0 ? 100 : Int(Double(total - remaining) / Double(total) * 100))%")
            }
            if remaining == 0 {
                try handle?.synchronize(); try handle?.close(); handle = nil
                guard let temporary else { throw TransferError(message: "Temporary file missing") }
                // link() publishes without overwriting an existing destination, even in a race.
                var saved = filename
                for attempt in 0...10000 {
                    if attempt > 0 { saved = "\(attempt)-\(filename)" }
                    if link(temporary.path, folder.appendingPathComponent(saved).path) == 0 { break }
                    if errno != EEXIST || attempt == 10000 { throw TransferError(message: "Cannot save file in receive folder") }
                }
                try? FileManager.default.removeItem(at: temporary); self.temporary = nil; uploading = false
                status("Received \(saved)")
                respond(200, data: try JSONSerialization.data(withJSONObject: ["saved": saved]), type: "application/json")
            }
        } catch { respond(500, "Upload failed: \(error.localizedDescription)") }
    }
    private func download(_ file: SharedFile) {
        do {
            handle = try FileHandle(forReadingFrom: file.url)
            total = try handle!.seekToEnd(); try handle!.seek(toOffset: 0); remaining = total
            responding = true
            let encoded = file.url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "download"
            let head = responseHeader(200, length: total, type: "application/octet-stream", extra: "Content-Disposition: attachment; filename*=UTF-8''\(encoded)\r\n")
            connection.send(content: head, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close() } else { self?.sendChunk(name: file.url.lastPathComponent) }
            })
        } catch { respond(404, "Cannot read this file. Share it again from your Mac.") }
    }
    private func sendChunk(name: String) {
        guard !closed else { return }
        timer?.schedule(deadline: .now() + 60)
        guard remaining > 0 else { status("Sent \(name)"); close(); return }
        do {
            guard let data = try handle?.read(upToCount: Int(min(remaining, 65536))), !data.isEmpty else { close(); return }
            remaining -= UInt64(data.count)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close() } else { self?.sendChunk(name: name) }
            })
        } catch { close() }
    }
    private func responseHeader(_ code: Int, length: UInt64, type: String, extra: String = "") -> Data {
        Data("HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Length: \(length)\r\nContent-Type: \(type)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'\r\n\(extra)\r\n".utf8)
    }
    private func respond(_ code: Int, _ message: String) { respond(code, data: Data(message.utf8), type: "text/plain; charset=utf-8") }
    private func respond(_ code: Int, data: Data, type: String) {
        guard !closed else { return }
        responding = true
        connection.send(content: responseHeader(code, length: UInt64(data.count), type: type) + data,
                        completion: .contentProcessed { [weak self] _ in self?.close() })
    }
}

public func localAddresses() -> [String] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0 else { return [] }
    defer { freeifaddrs(pointer) }
    var result: [(String, String)] = []
    var current = pointer
    while let interface = current {
        defer { current = interface.pointee.ifa_next }
        guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
              interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        let name = String(cString: interface.pointee.ifa_name)
        guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            result.append((name, String(cString: host)))
        }
    }
    return result.sorted { $0.0 < $1.0 }.map(\.1)
}
