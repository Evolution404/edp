import FSKit
import ServiceManagement
import SwiftUI

private let edpFSKitBundleID = "com.edp.drive.fskit-poc.extension"

@main
struct EDPFSKitPoCApp: App {
    var body: some Scene {
        WindowGroup {
            FSKitSetupView()
        }
        .windowResizability(.contentSize)
    }
}

private struct FSKitSetupView: View {
    private enum ModuleState: Equatable {
        case checking
        case awaitingApproval
        case disabled(url: String)
        case enabled(url: String)
        case failed(message: String)
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var moduleState: ModuleState = .checking

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            statusCard
            actions
        }
        .padding(28)
        .frame(width: 600)
        .task {
            refresh()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refresh()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EDP Drive")
                .font(.title2.weight(.semibold))
            Text("Native FSKit")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        switch moduleState {
        case .checking:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Checking file system extension…")
                        .font(.headline)
                    Text("Verifying the FSKit module with macOS.")
                        .foregroundStyle(.secondary)
                }
            }

        case .awaitingApproval:
            statusBlock(
                systemImage: "externaldrive.badge.questionmark",
                title: "File system extension needs approval",
                detail: "The native FSKit extension is installed with EDP Drive, but macOS has not exposed it to FSKit yet. Enable it once in System Settings → General → Login Items & Extensions → File System Extensions."
            )

        case let .disabled(url):
            statusBlock(
                systemImage: "externaldrive.badge.exclamationmark",
                title: "File system extension is disabled",
                detail: "macOS discovered the EDP FSKit module, but it is currently disabled. Enable it in File System Extensions.\n\n\(url)"
            )

        case let .enabled(url):
            statusBlock(
                systemImage: "checkmark.circle.fill",
                title: "Native FSKit is enabled",
                detail: "EDP Drive can now receive native FSKit resources without macFUSE.\n\n\(url)"
            )

        case let .failed(message):
            statusBlock(
                systemImage: "exclamationmark.triangle",
                title: "Unable to query FSKit",
                detail: message
            )
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            switch moduleState {
            case .awaitingApproval, .disabled:
                Button("Open Login Items & Extensions") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .buttonStyle(.borderedProminent)

            default:
                EmptyView()
            }

            Button("Refresh") {
                refresh()
            }
            .disabled(moduleState == .checking)

            Spacer()

            if case .enabled = moduleState {
                Label("Ready", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusBlock(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refresh() {
        moduleState = .checking

        FSClient.shared.fetchInstalledExtensions { modules, error in
            let nextState: ModuleState

            if let error {
                nextState = .failed(message: error.localizedDescription)
            } else if let module = modules?.first(where: { $0.bundleIdentifier == edpFSKitBundleID }) {
                let path = module.url.path
                nextState = module.isEnabled ? .enabled(url: path) : .disabled(url: path)
            } else {
                nextState = .awaitingApproval
            }

            DispatchQueue.main.async {
                moduleState = nextState
            }
        }
    }
}
