import Foundation
import Darwin

if let startupError = RawBrokerProcessSecurity.validateBrokerStartup() {
    fputs("EDP Studio raw broker refused startup: \(startupError)\n", stderr)
    exit(EXIT_FAILURE)
}

let delegate = RawBrokerListenerDelegate()
let listener = NSXPCListener(machServiceName: RawBrokerConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
