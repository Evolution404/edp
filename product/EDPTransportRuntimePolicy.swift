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
            /* FSKit module enablement/registration belongs to the logged-in
             * user's session. The privileged daemon must validate only the
             * signed runtime here; the console-user MFMount launch is the
             * authoritative availability check for that session. */
            guard status.mfMountFrameworkPresent else {
                throw EDPMacFUSERuntimePolicyError("MFMount.framework is missing")
            }
            return EDPTransportRuntimeStatus(
                backend: backend,
                finderHidden: capabilities.finderHidden,
                runtimeDescription: "macFUSE Local \(status.localModuleBundleID) team=\(status.teamID) userRegistered=\(status.localRegisteredWithPluginKit)"
            )
        }
    }
}
