import Foundation

struct EDPTransportRuntimeStatus: Sendable {
    let backend: EDPTransportBackend
    let finderHidden: Bool
    let runtimeDescription: String
}

enum EDPTransportRuntimePolicy {
    static func verifySelectedRuntime(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        requireFinderHidden: Bool = true
    ) throws -> EDPTransportRuntimeStatus {
        let backend = try EDPTransportProvider.selectedBackend(environment: environment)
        let capabilities = EDPTransportProvider.capabilities(for: backend)
        if requireFinderHidden && !capabilities.finderHidden {
            throw EDPTransportSelectionError.backendCannotHideTransport(backend)
        }

        switch backend {
        case .fuseT:
            let status = try EDPFuseTRuntimePolicy.verifyInstalled()
            guard status.registeredWithPluginKit else {
                throw EDPFuseTRuntimePolicyError(
                    "FUSE-T FSKit module is signed but is not registered with PluginKit"
                )
            }
            return EDPTransportRuntimeStatus(
                backend: backend,
                finderHidden: capabilities.finderHidden,
                runtimeDescription: "FUSE-T \(status.moduleBundleID) team=\(status.teamID)"
            )

        case .macFUSELocal:
            let status = try EDPMacFUSERuntimePolicy.verifyInstalled()
            guard status.localRegisteredWithPluginKit else {
                throw EDPMacFUSERuntimePolicyError(
                    "macFUSE Local FSKit module is signed but is not registered with PluginKit"
                )
            }
            guard status.mfMountFrameworkPresent else {
                throw EDPMacFUSERuntimePolicyError("MFMount.framework is missing")
            }
            return EDPTransportRuntimeStatus(
                backend: backend,
                finderHidden: capabilities.finderHidden,
                runtimeDescription: "macFUSE Local \(status.localModuleBundleID) team=\(status.teamID)"
            )
        }
    }
}
