import Foundation
import FSKit

let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

FSClient.shared.fetchInstalledExtensions { modules, error in
    if let error {
        print("ERROR=\(error)")
        exitCode = 2
        sem.signal()
        return
    }
    let sorted = (modules ?? []).sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    print("COUNT=\(sorted.count)")
    for module in sorted {
        print("MODULE bundle=\(module.bundleIdentifier) enabled=\(module.isEnabled) url=\(module.url.path)")
    }
    sem.signal()
}

if sem.wait(timeout: .now() + 15) == .timedOut {
    print("ERROR=timeout")
    exit(3)
}
exit(exitCode)
