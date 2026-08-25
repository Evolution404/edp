import Foundation
import FSKit

let bundleID = "com.edp.usbvault.fskit-poc.extension"
let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 1

FSClient.shared.fetchInstalledExtensions { modules, error in
    defer { semaphore.signal() }

    if let error {
        fputs("FSCLIENT_ERROR=\(error)\n", stderr)
        return
    }

    guard let module = modules?.first(where: { $0.bundleIdentifier == bundleID }) else {
        fputs("FSKIT_MODULE_NOT_FOUND=\(bundleID)\n", stderr)
        return
    }

    print("FSKIT_MODULE_FOUND=\(module.bundleIdentifier)")
    print("FSKIT_MODULE_ENABLED=\(module.isEnabled)")
    print("FSKIT_MODULE_URL=\(module.url.path)")
    print("FSKIT_MODULE_ATTRIBUTES=\(module.attributes)")
    exitCode = 0
}

if semaphore.wait(timeout: .now() + 15) == .timedOut {
    fputs("FSCLIENT_TIMEOUT\n", stderr)
    exit(2)
}

exit(exitCode)
