import Foundation

enum EDPTransportBackend: String, Codable, CaseIterable, Sendable {
    case fuseT = "fuset"
    case macFUSELocal = "macfuse-local"
}

struct EDPTransportCapabilities: Equatable, Sendable {
    let finderHidden: Bool
    let writable: Bool
    let diskImagesCompatible: Bool
    let localVolume: Bool
}

struct EDPTransportLaunchSpec: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let capabilities: EDPTransportCapabilities
}

struct EDPTransportRequest: Sendable {
    let binaryRoot: String
    let rawDevice: String
    let rawFD: Int32
    let vid: String
    let pid: String
    let deviceSize: UInt64
    let partitionType: UInt32
    let controlFD: Int32
    let mountpoint: String
    let volumeName: String
    let readOnly: Bool
}

enum EDPTransportSelectionError: Error, CustomStringConvertible {
    case unsupportedBackend(String)
    case backendCannotHideTransport(EDPTransportBackend)
    case backendCannotWrite(EDPTransportBackend)

    var description: String {
        switch self {
        case .unsupportedBackend(let value):
            return "unsupported EDP transport backend: \(value)"
        case .backendCannotHideTransport(let backend):
            return "EDP transport backend \(backend.rawValue) does not satisfy Finder-hidden product policy"
        case .backendCannotWrite(let backend):
            return "EDP transport backend \(backend.rawValue) does not satisfy writable product policy"
        }
    }
}

enum EDPTransportProvider {
    static let environmentKey = "EDP_TRANSPORT"

    static func selectedBackend(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> EDPTransportBackend {
        let value = environment[environmentKey] ?? EDPTransportBackend.macFUSELocal.rawValue
        guard let backend = EDPTransportBackend(rawValue: value) else {
            throw EDPTransportSelectionError.unsupportedBackend(value)
        }
        return backend
    }

    static func capabilities(for backend: EDPTransportBackend) -> EDPTransportCapabilities {
        switch backend {
        case .fuseT:
            return EDPTransportCapabilities(
                finderHidden: false,
                writable: true,
                diskImagesCompatible: true,
                localVolume: false
            )
        case .macFUSELocal:
            return EDPTransportCapabilities(
                finderHidden: true,
                writable: true,
                diskImagesCompatible: true,
                localVolume: true
            )
        }
    }

    static func launchSpec(
        for backend: EDPTransportBackend,
        request: EDPTransportRequest,
        requireFinderHidden: Bool
    ) throws -> EDPTransportLaunchSpec {
        let capabilities = capabilities(for: backend)
        if requireFinderHidden && !capabilities.finderHidden {
            throw EDPTransportSelectionError.backendCannotHideTransport(backend)
        }
        if !request.readOnly && !capabilities.writable {
            throw EDPTransportSelectionError.backendCannotWrite(backend)
        }

        let commonArguments = [
            "--raw-device", request.rawDevice,
            "--raw-fd", String(request.rawFD),
            "--vid", request.vid,
            "--pid", request.pid,
            "--device-size", String(request.deviceSize),
            "--partition-type", String(request.partitionType),
            "--control-fd", String(request.controlFD),
            "--mountpoint", request.mountpoint,
            "--volume-name", request.volumeName,
        ]

        switch backend {
        case .fuseT:
            return EDPTransportLaunchSpec(
                executable: request.binaryRoot + (request.readOnly ? "/edp-fuset-readonly" : "/edp-fuset-readwrite"),
                arguments: commonArguments,
                environment: [:],
                capabilities: capabilities
            )
        case .macFUSELocal:
            return EDPTransportLaunchSpec(
                executable: request.binaryRoot + (request.readOnly ? "/edp-mfmount-local-readonly" : "/edp-mfmount-local-readwrite"),
                arguments: commonArguments,
                environment: ["EDP_MFMOUNT_OPTIONS": "local,nobrowse"],
                capabilities: capabilities
            )
        }
    }
}
