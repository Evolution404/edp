import Foundation

enum EDPTransportBackend: String, Codable, CaseIterable, Sendable {
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

struct EDPTransportSessionError: Error, CustomStringConvertible {
    let description: String
}

protocol EDPManagedProcess: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

extension Process: EDPManagedProcess {}

final class EDPTransportSession {
    let backend: EDPTransportBackend
    let mountpoint: String
    let capabilities: EDPTransportCapabilities
    private let process: any EDPManagedProcess

    init(
        backend: EDPTransportBackend,
        mountpoint: String,
        capabilities: EDPTransportCapabilities,
        process: any EDPManagedProcess
    ) {
        self.backend = backend
        self.mountpoint = mountpoint
        self.capabilities = capabilities
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    func stop(
        unmount: (String) throws -> Void,
        isMounted: (String) -> Bool,
        gracefulExitSeconds: TimeInterval = 5
    ) throws {
        if isMounted(mountpoint) {
            try unmount(mountpoint)
        }
        guard !isMounted(mountpoint) else {
            throw EDPTransportSessionError(
                description: "transport mount remained active after VFS unmount: \(mountpoint)"
            )
        }

        let deadline = Date().addingTimeInterval(gracefulExitSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }
    }
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
    case backendCannotHideTransport(EDPTransportBackend)
    case backendCannotWrite(EDPTransportBackend)

    var description: String {
        switch self {
        case .backendCannotHideTransport(let backend):
            return "EDP transport backend \(backend.rawValue) does not satisfy Finder-hidden product policy"
        case .backendCannotWrite(let backend):
            return "EDP transport backend \(backend.rawValue) does not satisfy writable product policy"
        }
    }
}

enum EDPTransportProvider {
    static func selectedBackend() -> EDPTransportBackend {
        .macFUSELocal
    }

    static func capabilities(for backend: EDPTransportBackend) -> EDPTransportCapabilities {
        switch backend {
        case .macFUSELocal:
            return EDPTransportCapabilities(
                finderHidden: true,
                writable: true,
                diskImagesCompatible: true,
                localVolume: true
            )
        }
    }

    static func executableName(for backend: EDPTransportBackend, readOnly: Bool) -> String {
        switch backend {
        case .macFUSELocal:
            return readOnly ? "edp-mfmount-local-readonly" : "edp-mfmount-local-readwrite"
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

        let executable = request.binaryRoot + "/" + executableName(
            for: backend,
            readOnly: request.readOnly
        )
        switch backend {
        case .macFUSELocal:
            return EDPTransportLaunchSpec(
                executable: executable,
                arguments: commonArguments,
                environment: ["EDP_MFMOUNT_OPTIONS": "local,nobrowse"],
                capabilities: capabilities
            )
        }
    }
}
