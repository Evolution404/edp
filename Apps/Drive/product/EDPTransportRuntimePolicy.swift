import Foundation

struct EDPTransportRuntimeStatus: Sendable {
    let backend: EDPTransportBackend
    let finderHidden: Bool
    let runtimeDescription: String
}

enum EDPTransportRuntimePolicy {
    static func verifySelectedRuntime(
        requireFinderHidden: Bool = true
    ) throws -> EDPTransportRuntimeStatus {
        let backend = EDPTransportProvider.selectedBackend()
        let capabilities = EDPTransportProvider.capabilities(for: backend)
        if requireFinderHidden && !capabilities.finderHidden {
            throw EDPTransportSelectionError.backendCannotHideTransport(backend)
        }

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
