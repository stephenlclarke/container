import Foundation
import AppKit
import SystemConfiguration
import Network
import Darwin

// The service retains the runner's existing launchd login session and environment.
if CommandLine.arguments.dropFirst().elementsEqual(["--service"]) {
    let script = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ContainerFamily/runner/container-only/runsvc.sh").path
    let arguments = ["/bin/bash", script].map { strdup($0) } + [nil]
    arguments.withUnsafeBufferPointer { buffer in
        _ = execv("/bin/bash", buffer.baseAddress!)
    }
    perror("Container Build Runner")
    exit(1)
}

// Explicit first-run consent only; actual qualification still runs the original HTTP test.
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Container Build Runner Setup"
let message = NSTextField(wrappingLabelWithString: "Allow Local Network access for Container Build Runner when macOS asks. This permits the dedicated build runner to test temporary local virtual machines.")
message.frame = NSRect(x: 24, y: 32, width: 412, height: 90)
window.contentView?.addSubview(message)
window.center()
window.makeKeyAndOrderFront(nil)
application.activate(ignoringOtherApps: true)
guard let configuration = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
      let router = configuration["Router"] as? String else {
    fputs("No IPv4 router available for Local Network setup\n", stderr)
    exit(1)
}
let connection = NWConnection(host: NWEndpoint.Host(router), port: 9, using: .tcp)
connection.stateUpdateHandler = { state in
    switch state {
    case .waiting where connection.currentPath?.unsatisfiedReason == .localNetworkDenied:
        message.stringValue = "Local Network access is awaiting approval. Allow Container Build Runner in the macOS prompt or Privacy & Security settings."
    case .ready:
        message.stringValue = "The setup connection is allowed. The build will separately verify the original HTTP integration test."
    case .failed(let error):
        message.stringValue = "Setup connection ended: \(error). The build will separately verify the original HTTP integration test."
    default:
        break
    }
}
connection.start(queue: .main)
DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
    connection.cancel()
    exit(0)
}
application.run()
