import AppKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

#if !EDP_UI_AUTOMATION
@_silgen_name("edp_raw_fd_broker_run_child")
private func edpRawFDBrokerRunChild(_ socketFD: Int32, _ rawPath: UnsafePointer<CChar>) -> Int32
#endif

#if !EDP_UI_AUTOMATION
@main
#endif
struct EDPUSBVaultApp: App {
    @StateObject private var model = EDPVaultViewModel()

    init() {
#if !EDP_UI_AUTOMATION
        if let brokerIndex = CommandLine.arguments.firstIndex(of: "--raw-fd-broker"),
           CommandLine.arguments.count > brokerIndex + 2,
           let socketFD = Int32(CommandLine.arguments[brokerIndex + 1]) {
            let rawPath = CommandLine.arguments[brokerIndex + 2]
            let status = rawPath.withCString { edpRawFDBrokerRunChild(socketFD, $0) }
            exit(status)
        }
#endif
        if CommandLine.arguments.contains("--refresh-raw-access-smoke") {
            let connection = NSXPCConnection(
                machServiceName: edpVaultMachServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            let result = EDPXPCSmokeResult()
            let semaphore = DispatchSemaphore(value: 0)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                result.set(passed: false, detail: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=RAW_ACCESS_XPC_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.refreshRawAccess { @Sendable errorMessage in
                result.set(
                    passed: errorMessage == nil,
                    detail: errorMessage ?? "Full Disk Access broker probe accepted"
                )
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 30) == .success else {
                connection.invalidate()
                print("RESULT=RAW_ACCESS_XPC_TIMEOUT")
                exit(1)
            }
            connection.invalidate()
            let captured = result.snapshot()
            print("RAW_ACCESS_XPC_DETAIL=\(captured.1)")
            print(captured.0 ? "RESULT=RAW_ACCESS_XPC_OK" : "RESULT=RAW_ACCESS_XPC_FAILED")
            exit(captured.0 ? 0 : 1)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--xpc-policy-smoke"),
           CommandLine.arguments.count > index + 1 {
            let deviceID = CommandLine.arguments[index + 1]
            exit(EDPXPCPolicySmokeRunner.run(deviceID: deviceID) ? 0 : 1)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--xpc-mount-smoke"),
           CommandLine.arguments.count > index + 2,
           let partitionType = UInt32(CommandLine.arguments[index + 1]),
           [UInt32(1), 2, 4].contains(partitionType) {
            let deviceID = CommandLine.arguments[index + 2]
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                fputs("XPC_MOUNT_SMOKE_ERROR=\(error.localizedDescription)\n", stderr)
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_MOUNT_SMOKE_PROXY_UNAVAILABLE")
                exit(1)
            }
            let mountResult = EDPXPCSmokeResult()
            let mountSemaphore = DispatchSemaphore(value: 0)
            proxy.mountPartition(
                deviceID: deviceID,
                partitionType: partitionType
            ) { @Sendable errorMessage in
                mountResult.set(passed: errorMessage == nil, detail: errorMessage ?? "mount completed")
                mountSemaphore.signal()
            }
            guard mountSemaphore.wait(timeout: .now() + 90) == .success else {
                print("RESULT=XPC_MOUNT_SMOKE_MOUNT_TIMEOUT")
                exit(1)
            }
            let mounted = mountResult.snapshot()
            print("XPC_MOUNT_SMOKE_DETAIL=\(mounted.1)")
            print(mounted.0 ? "RESULT=XPC_MOUNT_SMOKE_OK" : "RESULT=XPC_MOUNT_SMOKE_FAILED")
            exit(mounted.0 ? 0 : 1)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--xpc-unmount-smoke"),
           CommandLine.arguments.count > index + 2,
           let partitionType = UInt32(CommandLine.arguments[index + 1]),
           [UInt32(1), 2, 4].contains(partitionType) {
            let deviceID = CommandLine.arguments[index + 2]
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                fputs("XPC_UNMOUNT_SMOKE_ERROR=\(error.localizedDescription)\n", stderr)
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_UNMOUNT_SMOKE_PROXY_UNAVAILABLE")
                exit(1)
            }
            let unmountResult = EDPXPCSmokeResult()
            let unmountSemaphore = DispatchSemaphore(value: 0)
            proxy.unmountPartition(
                deviceID: deviceID,
                partitionType: partitionType
            ) { @Sendable errorMessage in
                unmountResult.set(passed: errorMessage == nil, detail: errorMessage ?? "unmount completed")
                unmountSemaphore.signal()
            }
            guard unmountSemaphore.wait(timeout: .now() + 90) == .success else {
                print("RESULT=XPC_UNMOUNT_SMOKE_TIMEOUT")
                exit(1)
            }
            let unmounted = unmountResult.snapshot()
            print("XPC_UNMOUNT_SMOKE_DETAIL=\(unmounted.1)")
            print(unmounted.0 ? "RESULT=XPC_UNMOUNT_SMOKE_OK" : "RESULT=XPC_UNMOUNT_SMOKE_FAILED")
            exit(unmounted.0 ? 0 : 1)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--xpc-eject-smoke"),
           CommandLine.arguments.count > index + 1 {
            let deviceID = CommandLine.arguments[index + 1]
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                fputs("XPC_EJECT_SMOKE_ERROR=\(error.localizedDescription)\n", stderr)
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_EJECT_SMOKE_PROXY_UNAVAILABLE")
                exit(1)
            }
            let ejectResult = EDPXPCSmokeResult()
            let ejectSemaphore = DispatchSemaphore(value: 0)
            proxy.eject(deviceID: deviceID) { @Sendable errorMessage in
                ejectResult.set(passed: errorMessage == nil, detail: errorMessage ?? "eject completed")
                ejectSemaphore.signal()
            }
            guard ejectSemaphore.wait(timeout: .now() + 90) == .success else {
                print("RESULT=XPC_EJECT_SMOKE_TIMEOUT")
                exit(1)
            }
            let ejected = ejectResult.snapshot()
            print("XPC_EJECT_SMOKE_DETAIL=\(ejected.1)")
            print(ejected.0 ? "RESULT=XPC_EJECT_SMOKE_OK" : "RESULT=XPC_EJECT_SMOKE_FAILED")
            exit(ejected.0 ? 0 : 1)
        }

        if CommandLine.arguments.contains("--xpc-diagnostics") {
            let result = EDPXPCDataResult()
            let semaphore = DispatchSemaphore(value: 0)
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                result.set(error: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_DIAGNOSTICS_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.diagnostics { @Sendable data in
                result.set(data: data)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 10) == .success else {
                connection.invalidate()
                print("RESULT=XPC_DIAGNOSTICS_TIMEOUT")
                exit(1)
            }
            connection.invalidate()
            let captured = result.snapshot()
            if let error = captured.1 {
                print("XPC_DIAGNOSTICS_ERROR=\(error)")
                print("RESULT=XPC_DIAGNOSTICS_FAILED")
                exit(1)
            }
            guard let data = captured.0 else {
                print("RESULT=XPC_DIAGNOSTICS_EMPTY")
                exit(1)
            }
            print(String(decoding: data, as: UTF8.self))
            print("RESULT=PRIVILEGED_XPC_DIAGNOSTICS_OK")
            exit(0)
        }

        if CommandLine.arguments.contains("--xpc-snapshot") {
            let result = EDPXPCDataResult()
            let semaphore = DispatchSemaphore(value: 0)
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                result.set(error: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_SNAPSHOT_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.snapshot { @Sendable data in
                result.set(data: data)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 10) == .success else {
                connection.invalidate()
                print("RESULT=XPC_SNAPSHOT_TIMEOUT")
                exit(1)
            }
            connection.invalidate()
            let captured = result.snapshot()
            if let error = captured.1 {
                print("XPC_SNAPSHOT_ERROR=\(error)")
                print("RESULT=XPC_SNAPSHOT_FAILED")
                exit(1)
            }
            guard let data = captured.0,
                  let snapshot = try? JSONDecoder().decode(EDPXPCSnapshot.self, from: data) else {
                print("RESULT=XPC_SNAPSHOT_DECODE_FAILED")
                exit(1)
            }
            print("SNAPSHOT_SERVICE_VERSION=\(snapshot.serviceVersion)")
            print("SNAPSHOT_DEVICE_COUNT=\(snapshot.devices.count)")
            for device in snapshot.devices {
                print("SNAPSHOT_DEVICE=\(device.bsdName)|\(device.deviceID)|metadataDeviceID=\(device.metadataDeviceID ?? "-")|\(device.vidPID)|onlyID=\(device.labelOnlyID.map(String.init) ?? "-")|\(device.sizeBytes)|authorized=\(device.authorized)|mounted=\(device.mounted)|privilegedAccessReady=\(device.privilegedAccessReady)|partitions=\(device.partitionTypes.map(String.init).joined(separator: ","))")
                for partition in device.partitions.sorted(by: { $0.partitionType < $1.partitionType }) {
                    print("SNAPSHOT_PARTITION=\(device.deviceID)|type=\(partition.partitionType)|autoMount=\(partition.autoMount)|credential=\(partition.credentialStatus.rawValue)|mount=\(partition.mountState.rawValue)|filesystem=\(partition.filesystem ?? "-")|readOnly=\(partition.readOnly.map(String.init) ?? "-")|mountPoint=\(partition.mountPoint ?? "-")")
                }
            }
            print("SNAPSHOT_GLOBAL_AUTOMOUNT=\(snapshot.globalAutoMountEnabled)")
            print("RESULT=PRIVILEGED_XPC_SNAPSHOT_OK")
            exit(0)
        }

        if CommandLine.arguments.contains("--xpc-health") {
            let result = EDPXPCSmokeResult()
            let semaphore = DispatchSemaphore(value: 0)
            let connection = NSXPCConnection(
                machServiceName: edpVaultMachServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                result.set(passed: false, detail: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_HEALTH_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.healthCheck { @Sendable response in
                let valid = response == "com.edp.drive.service:running"
                result.set(passed: valid, detail: response)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 12) == .success else {
                connection.invalidate()
                print("RESULT=XPC_HEALTH_TIMEOUT")
                exit(1)
            }
            connection.invalidate()
            let snapshot = result.snapshot()
            print("XPC_HEALTH_DETAIL=\(snapshot.1)")
            print(snapshot.0 ? "RESULT=EDP_SERVICE_HEALTH_OK" : "RESULT=EDP_SERVICE_HEALTH_FAILED")
            exit(snapshot.0 ? 0 : 1)
        }

        if CommandLine.arguments.contains("--xpc-graceful-stop") {
            let result = EDPXPCSmokeResult()
            let replySemaphore = DispatchSemaphore(value: 0)
            let disconnectSemaphore = DispatchSemaphore(value: 0)
            let connection = NSXPCConnection(
                machServiceName: edpVaultMachServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            connection.interruptionHandler = { @Sendable in disconnectSemaphore.signal() }
            connection.invalidationHandler = { @Sendable in disconnectSemaphore.signal() }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                result.set(passed: false, detail: error.localizedDescription)
                replySemaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_GRACEFUL_STOP_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.requestGracefulShutdown { @Sendable errorMessage in
                result.set(
                    passed: errorMessage == nil,
                    detail: errorMessage ?? "graceful teardown completed"
                )
                replySemaphore.signal()
            }
            guard replySemaphore.wait(timeout: .now() + 90) == .success else {
                connection.invalidate()
                print("RESULT=XPC_GRACEFUL_STOP_TIMEOUT")
                exit(1)
            }
            let snapshot = result.snapshot()
            guard snapshot.0 else {
                connection.invalidate()
                print("XPC_GRACEFUL_STOP_DETAIL=\(snapshot.1)")
                print("RESULT=EDP_SERVICE_GRACEFUL_STOP_FAILED")
                exit(1)
            }
            let disconnected = disconnectSemaphore.wait(timeout: .now() + 12) == .success
            connection.invalidate()
            guard disconnected else {
                print("RESULT=XPC_GRACEFUL_STOP_EXIT_TIMEOUT")
                exit(1)
            }
            print("XPC_GRACEFUL_STOP_DETAIL=\(snapshot.1)")
            print("RESULT=EDP_SERVICE_GRACEFUL_STOP_OK")
            exit(0)
        }

        if CommandLine.arguments.contains("--xpc-smoke") {
            let result = EDPXPCSmokeResult()
            let semaphore = DispatchSemaphore(value: 0)
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                result.set(passed: false, detail: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_SMOKE_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.diagnostics { @Sendable data in
                let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let valid = payload?["eventDrivenDiscovery"] as? Bool == true
                    && payload?["credentialStore"] as? String == "System Keychain"
                result.set(
                    passed: valid,
                    detail: valid ? "diagnostics contract OK" : "unexpected diagnostics payload"
                )
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 10) == .success else {
                connection.invalidate()
                print("RESULT=XPC_SMOKE_TIMEOUT")
                exit(1)
            }
            connection.invalidate()
            let snapshot = result.snapshot()
            print("XPC_SMOKE_DETAIL=\(snapshot.1)")
            print(snapshot.0 ? "RESULT=PRIVILEGED_XPC_ROUNDTRIP_OK" : "RESULT=PRIVILEGED_XPC_ROUNDTRIP_FAILED")
            exit(snapshot.0 ? 0 : 1)
        }

        if CommandLine.arguments.contains("--register-service") {
            let mode = Bundle.main.object(forInfoDictionaryKey: "EDPServiceMode") as? String ?? "legacy"
            print("EDP_SERVICE_MODE=\(mode)")
            if mode == "smappservice" {
                let service = SMAppService.daemon(plistName: "com.edp.drive.service.plist")
                do {
                    if service.status != .enabled && service.status != .requiresApproval {
                        try service.register()
                    }
                    switch service.status {
                    case .enabled:
                        print("EDP_SERVICE_STATUS=enabled")
                        exit(0)
                    case .requiresApproval:
                        print("EDP_SERVICE_STATUS=requiresApproval")
                        exit(0)
                    case .notRegistered:
                        print("EDP_SERVICE_STATUS=notRegistered")
                        exit(1)
                    case .notFound:
                        print("EDP_SERVICE_STATUS=notFound")
                        exit(1)
                    @unknown default:
                        print("EDP_SERVICE_STATUS=unknown")
                        exit(1)
                    }
                } catch {
                    FileHandle.standardError.write(Data("EDP_SERVICE_ERROR=\(error)\n".utf8))
                    exit(1)
                }
            } else {
                let legacyURL = URL(fileURLWithPath: "/Library/LaunchDaemons/com.edp.drive.service.plist")
                switch SMAppService.statusForLegacyPlist(at: legacyURL) {
                case .enabled:
                    print("EDP_SERVICE_STATUS=enabled")
                    exit(0)
                case .requiresApproval:
                    print("EDP_SERVICE_STATUS=requiresApproval")
                    exit(0)
                case .notRegistered:
                    print("EDP_SERVICE_STATUS=notRegistered")
                    exit(1)
                case .notFound:
                    print("EDP_SERVICE_STATUS=notFound")
                    exit(1)
                @unknown default:
                    print("EDP_SERVICE_STATUS=unknown")
                    exit(1)
                }
            }
        }

        if CommandLine.arguments.contains("--reregister-service") {
            let mode = Bundle.main.object(forInfoDictionaryKey: "EDPServiceMode") as? String ?? "legacy"
            guard mode == "smappservice" else {
                print("RESULT=SERVICE_REREGISTER_NOT_APPLICABLE")
                exit(1)
            }
            let service = SMAppService.daemon(plistName: "com.edp.drive.service.plist")
            do {
                try service.unregister()
                try service.register()
                switch service.status {
                case .enabled:
                    print("RESULT=SERVICE_REREGISTERED_ENABLED")
                    exit(0)
                case .requiresApproval:
                    print("RESULT=SERVICE_REREGISTERED_REQUIRES_APPROVAL")
                    exit(0)
                case .notRegistered:
                    print("RESULT=SERVICE_REREGISTER_NOT_REGISTERED")
                    exit(1)
                case .notFound:
                    print("RESULT=SERVICE_REREGISTER_NOT_FOUND")
                    exit(1)
                @unknown default:
                    print("RESULT=SERVICE_REREGISTER_UNKNOWN")
                    exit(1)
                }
            } catch {
                print("SERVICE_REREGISTER_ERROR=\(error)")
                print("RESULT=SERVICE_REREGISTER_FAILED")
                exit(1)
            }
        }
    }

    var body: some Scene {
        Window("EDP Drive", id: "main") {
            EDPMainView(model: model)
        }
        .defaultSize(width: 980, height: 680)

        MenuBarExtra {
            EDPMenuBarView(model: model)
        } label: {
            Label(
                "EDP Drive",
                systemImage: model.snapshot.devices.contains(where: { $0.connected })
                    ? "externaldrive.fill.badge.checkmark"
                    : "externaldrive"
            )
        }
        // Window style keeps one stable popover alive while the user drills through
        // device -> partition pages. Unlike AppKit cascading NSMenu submenus, there is
        // no narrow hover corridor that can accidentally dismiss the hierarchy.
        .menuBarExtraStyle(.window)
    }
}
