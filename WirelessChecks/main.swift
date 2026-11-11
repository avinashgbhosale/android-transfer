import Foundation
import WirelessCore
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let server = WirelessServer(folder: folder)
server.setFiles([SharedFile(url: URL(fileURLWithPath: CommandLine.arguments[2]))])
server.onReady = { port, token in
    print("http://127.0.0.1:\(port)/\(token)/")
    fflush(stdout)
}
server.onFailure = { message in fputs(message, stderr); exit(1) }
server.start()
DispatchQueue.global().async {
    while let command = readLine() {
        if command == "restart" { server.stop { server.start() } }
        if command == "quit" { server.stop { exit(0) } }
    }
}
dispatchMain()
