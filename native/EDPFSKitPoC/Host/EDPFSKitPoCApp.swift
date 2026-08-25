import SwiftUI
import FSKit

@main
struct EDPFSKitPoCApp: App {
    @State private var status = "Checking FSKit module…"

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("EDP USB Vault — Native FSKit PoC")
                    .font(.title2)
                Text(status)
                    .textSelection(.enabled)
                Button("Refresh") {
                    refresh()
                }
            }
            .padding(24)
            .frame(minWidth: 560, minHeight: 180)
            .task {
                refresh()
            }
        }
    }

    private func refresh() {
        FSClient.shared.fetchInstalledExtensions { modules, error in
            let message: String
            if let error {
                message = "FSClient error: \(error)"
            } else {
                let bundleID = "com.edp.usbvault.fskit-poc.extension"
                if let module = modules?.first(where: { $0.bundleIdentifier == bundleID }) {
                    message = "FSKit module discovered: \(module.bundleIdentifier)\nEnabled: \(module.isEnabled)\nURL: \(module.url.path)"
                } else {
                    message = "FSKit module not yet discovered: \(bundleID)"
                }
            }

            DispatchQueue.main.async {
                status = message
            }
        }
    }
}
