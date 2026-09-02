import Foundation

final class EDPXPCSmokeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var passed = false
    private var detail = "no reply"

    func set(passed: Bool, detail: String) {
        lock.lock()
        self.passed = passed
        self.detail = detail
        lock.unlock()
    }

    func snapshot() -> (Bool, String) {
        lock.lock()
        defer { lock.unlock() }
        return (passed, detail)
    }
}

final class EDPXPCDataResult: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var errorMessage: String?

    func set(data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func set(error: String) {
        lock.lock()
        errorMessage = error
        lock.unlock()
    }

    func snapshot() -> (Data?, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (data, errorMessage)
    }
}

private struct EDPXPCPolicySmokeError: Error, CustomStringConvertible {
    let description: String
}

enum EDPXPCPolicySmokeRunner {
    private static func waitReply(
        label: String,
        timeout: DispatchTime = .now() + 15,
        invoke: (@escaping (String?) -> Void) -> Void
    ) throws {
        let result = EDPXPCSmokeResult()
        let semaphore = DispatchSemaphore(value: 0)
        invoke { errorMessage in
            result.set(passed: errorMessage == nil, detail: errorMessage ?? "\(label) completed")
            semaphore.signal()
        }
        guard semaphore.wait(timeout: timeout) == .success else {
            throw EDPXPCPolicySmokeError(description: "\(label) timed out")
        }
        let captured = result.snapshot()
        guard captured.0 else {
            throw EDPXPCPolicySmokeError(description: "\(label) failed: \(captured.1)")
        }
    }

    private static func snapshot(proxy: EDPVaultXPCProtocol) throws -> EDPXPCSnapshot {
        let result = EDPXPCDataResult()
        let semaphore = DispatchSemaphore(value: 0)
        proxy.snapshot { @Sendable data in
            result.set(data: data)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 15) == .success else {
            throw EDPXPCPolicySmokeError(description: "snapshot timed out")
        }
        let captured = result.snapshot()
        if let errorMessage = captured.1 {
            throw EDPXPCPolicySmokeError(description: "snapshot failed: \(errorMessage)")
        }
        guard let data = captured.0,
              let snapshot = try? JSONDecoder().decode(EDPXPCSnapshot.self, from: data) else {
            throw EDPXPCPolicySmokeError(description: "snapshot decode failed")
        }
        return snapshot
    }

    static func run(deviceID: String) -> Bool {
        let connection = NSXPCConnection(
            machServiceName: edpVaultMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
            fputs("XPC_POLICY_SMOKE_ERROR=\(error.localizedDescription)\n", stderr)
        }) as? EDPVaultXPCProtocol else {
            print("RESULT=XPC_POLICY_SMOKE_PROXY_UNAVAILABLE")
            return false
        }
        connection.resume()
        defer { connection.invalidate() }

        do {
            let before = try snapshot(proxy: proxy)
            guard let device = before.devices.first(where: { $0.deviceID == deviceID }) else {
                throw EDPXPCPolicySmokeError(description: "device not found in snapshot")
            }
            let originalGlobal = before.globalAutoMountEnabled
            let originalDisplayName = device.displayName
            let originalAutoMount = Dictionary(
                uniqueKeysWithValues: device.partitions.map { ($0.partitionType, $0.autoMount) }
            )
            guard Set(originalAutoMount.keys) == Set(EDPPartitionKind.allCases.map(\.rawValue)) else {
                throw EDPXPCPolicySmokeError(description: "snapshot is missing one or more partition policies")
            }

            let acceptanceName = "EDP Acceptance \(UUID().uuidString.prefix(8))"
            var restoreRequired = false

            func restore() {
                for kind in EDPPartitionKind.allCases {
                    if let enabled = originalAutoMount[kind.rawValue] {
                        try? waitReply(label: "restore partition \(kind.rawValue)") { reply in
                            proxy.setPartitionAutoMount(
                                deviceID: deviceID,
                                partitionType: kind.rawValue,
                                enabled: enabled,
                                withReply: reply
                            )
                        }
                    }
                }
                try? waitReply(label: "restore display name") { reply in
                    proxy.setDeviceDisplayName(
                        deviceID: deviceID,
                        displayName: originalDisplayName,
                        withReply: reply
                    )
                }
                try? waitReply(label: "restore global automount") { reply in
                    proxy.setGlobalAutoMount(enabled: originalGlobal, withReply: reply)
                }
            }

            defer {
                if restoreRequired {
                    restore()
                }
            }

            restoreRequired = true
            try waitReply(label: "disable global automount") { reply in
                proxy.setGlobalAutoMount(enabled: false, withReply: reply)
            }
            for kind in EDPPartitionKind.allCases {
                try waitReply(label: "disable partition \(kind.rawValue) automount") { reply in
                    proxy.setPartitionAutoMount(
                        deviceID: deviceID,
                        partitionType: kind.rawValue,
                        enabled: false,
                        withReply: reply
                    )
                }
            }
            try waitReply(label: "set acceptance display name") { reply in
                proxy.setDeviceDisplayName(
                    deviceID: deviceID,
                    displayName: acceptanceName,
                    withReply: reply
                )
            }

            var check = try snapshot(proxy: proxy)
            guard check.globalAutoMountEnabled == false,
                  let disabledDevice = check.devices.first(where: { $0.deviceID == deviceID }),
                  disabledDevice.displayName == acceptanceName,
                  disabledDevice.partitions.allSatisfy({ !$0.autoMount }) else {
                throw EDPXPCPolicySmokeError(description: "disabled policy state did not round-trip")
            }

            try waitReply(label: "enable global automount") { reply in
                proxy.setGlobalAutoMount(enabled: true, withReply: reply)
            }
            check = try snapshot(proxy: proxy)
            guard check.globalAutoMountEnabled else {
                throw EDPXPCPolicySmokeError(description: "global automount enable did not round-trip")
            }
            try waitReply(label: "disable global automount after probe") { reply in
                proxy.setGlobalAutoMount(enabled: false, withReply: reply)
            }

            for kind in EDPPartitionKind.allCases {
                let toggled = !(originalAutoMount[kind.rawValue] ?? false)
                try waitReply(label: "toggle partition \(kind.rawValue) automount") { reply in
                    proxy.setPartitionAutoMount(
                        deviceID: deviceID,
                        partitionType: kind.rawValue,
                        enabled: toggled,
                        withReply: reply
                    )
                }
            }
            check = try snapshot(proxy: proxy)
            guard let toggledDevice = check.devices.first(where: { $0.deviceID == deviceID }) else {
                throw EDPXPCPolicySmokeError(description: "device disappeared during policy probe")
            }
            for kind in EDPPartitionKind.allCases {
                let expected = !(originalAutoMount[kind.rawValue] ?? false)
                guard toggledDevice.partitions.first(where: { $0.partitionType == kind.rawValue })?.autoMount == expected else {
                    throw EDPXPCPolicySmokeError(description: "partition \(kind.rawValue) automount did not round-trip")
                }
            }

            restore()
            restoreRequired = false
            let restored = try snapshot(proxy: proxy)
            guard restored.globalAutoMountEnabled == originalGlobal,
                  let restoredDevice = restored.devices.first(where: { $0.deviceID == deviceID }),
                  restoredDevice.displayName == originalDisplayName else {
                throw EDPXPCPolicySmokeError(description: "policy restore verification failed")
            }
            for kind in EDPPartitionKind.allCases {
                guard restoredDevice.partitions.first(where: { $0.partitionType == kind.rawValue })?.autoMount
                        == originalAutoMount[kind.rawValue] else {
                    throw EDPXPCPolicySmokeError(description: "partition \(kind.rawValue) restore verification failed")
                }
            }

            print("POLICY_SMOKE_DEVICE_ID=\(deviceID)")
            print("POLICY_SMOKE_DISPLAY_NAME_RESTORED=\(originalDisplayName)")
            print("RESULT=XPC_POLICY_SMOKE_OK")
            return true
        } catch {
            fputs("XPC_POLICY_SMOKE_ERROR=\(error)\n", stderr)
            print("RESULT=XPC_POLICY_SMOKE_FAILED")
            return false
        }
    }
}
