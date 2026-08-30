import Foundation

enum EDPPreviewScenario: String, CaseIterable {
    case healthyOneDevice = "healthy-one-device"
    case noDevice = "no-device"
    case twoDevices = "two-devices"
    case fdaRequired = "fda-required"
    case serviceStopped = "service-stopped"
    case credentialMissing = "credential-missing"
    case partitionError = "partition-error"
    case allMounted = "all-mounted"
    case offlineSavedDevice = "offline-saved-device"

    static func fromCommandLine(_ arguments: [String] = CommandLine.arguments) -> EDPPreviewScenario {
        guard let index = arguments.firstIndex(of: "--edp-preview-scenario"),
              arguments.indices.contains(index + 1),
              let scenario = EDPPreviewScenario(rawValue: arguments[index + 1]) else {
            return .healthyOneDevice
        }
        return scenario
    }
}

struct EDPPreviewConfiguration {
    let snapshot: EDPXPCSnapshot
    let serviceStatus: String
    let transportRuntimeReady: Bool
    let serviceDesiredRunning: Bool
    let rawAccessHelperInstalled: Bool
}

enum EDPPreviewScenarioFactory {
    private static let primaryID = "EDP-PHYSICAL-ID-V3:21c4:0cd1:3164177653:124736503808:disk&ven_lexar&prod_usb_flash_drive"
    private static let secondaryID = "EDP-PHYSICAL-ID-V3:1209:ed02:2387350191:64000000000:disk&ven_edp&prod_backup_drive"

    static func configuration(for scenario: EDPPreviewScenario) -> EDPPreviewConfiguration {
        var primary = device(
            id: primaryID,
            metadataID: "disk&ven_lexar&prod_usb_flash_drive",
            bsdName: "disk6",
            mediaName: "Lexar USB Flash Drive",
            displayName: "EDP 工作盘",
            vidPID: "21c4:0cd1",
            onlyID: 3_164_177_653,
            size: 124_736_503_808,
            connected: true,
            rawReady: true,
            boot: .mounted,
            exchange: .mounted,
            secure: .unmounted
        )
        let secondary = device(
            id: secondaryID,
            metadataID: "disk&ven_edp&prod_backup_drive",
            bsdName: "disk7",
            mediaName: "EDP Backup Drive",
            displayName: "EDP 备份盘",
            vidPID: "1209:ed02",
            onlyID: 2_387_350_191,
            size: 64_000_000_000,
            connected: true,
            rawReady: true,
            boot: .mounted,
            exchange: .unmounted,
            secure: .mounted
        )

        var devices = [primary]
        var activities = defaultActivities(deviceID: primaryID)
        var serviceStatus = "运行中"
        let runtimeReady = true
        var serviceDesiredRunning = true
        let rawAccessHelperInstalled = true

        switch scenario {
        case .healthyOneDevice:
            break
        case .noDevice:
            devices = []
            activities = []
        case .twoDevices:
            devices = [primary, secondary]
        case .fdaRequired:
            primary = replacing(primary, rawReady: false)
            devices = [primary]
            activities.insert(activity("需要完全磁盘访问", level: "warning", deviceID: primaryID), at: 0)
        case .serviceStopped:
            serviceStatus = "已停止"
            serviceDesiredRunning = false
            devices = []
            activities = [activity("后台服务已停止", level: "warning")]
        case .credentialMissing:
            primary = replacingPartition(primary, type: EDPPartitionKind.secure.rawValue) { partition in
                EDPXPCPartition(
                    partitionType: partition.partitionType,
                    displayName: partition.displayName,
                    encrypted: true,
                    autoMount: false,
                    credentialStatus: .missing,
                    mountState: .unmounted,
                    filesystem: "ExFAT",
                    readOnly: false,
                    mountPoint: nil,
                    lastError: nil
                )
            }
            devices = [primary]
            activities.insert(activity("保密区缺少密码", level: "warning", deviceID: primaryID, partitionType: 4), at: 0)
        case .partitionError:
            primary = replacingPartition(primary, type: EDPPartitionKind.exchange.rawValue) { partition in
                EDPXPCPartition(
                    partitionType: partition.partitionType,
                    displayName: partition.displayName,
                    encrypted: true,
                    autoMount: partition.autoMount,
                    credentialStatus: .saved,
                    mountState: .failed,
                    filesystem: "ExFAT",
                    readOnly: false,
                    mountPoint: nil,
                    lastError: "文件系统扩展启动失败"
                )
            }
            devices = [primary]
            activities.insert(activity("交换区挂载失败：文件系统扩展启动失败", level: "error", deviceID: primaryID, partitionType: 2), at: 0)
        case .allMounted:
            primary = replacingPartition(primary, type: EDPPartitionKind.secure.rawValue) { partition in
                EDPXPCPartition(
                    partitionType: partition.partitionType,
                    displayName: partition.displayName,
                    encrypted: true,
                    autoMount: true,
                    credentialStatus: .saved,
                    mountState: .mounted,
                    filesystem: "ExFAT",
                    readOnly: false,
                    mountPoint: "/Volumes/保密区",
                    lastError: nil
                )
            }
            devices = [primary]
        case .offlineSavedDevice:
            primary = replacing(primary, bsdName: "", connected: false, rawReady: true)
            primary = replacingPartitions(primary) { partition in
                EDPXPCPartition(
                    partitionType: partition.partitionType,
                    displayName: partition.displayName,
                    encrypted: partition.encrypted,
                    autoMount: partition.autoMount,
                    credentialStatus: partition.credentialStatus,
                    mountState: .unmounted,
                    filesystem: partition.filesystem,
                    readOnly: partition.readOnly,
                    mountPoint: nil,
                    lastError: nil
                )
            }
            devices = [primary]
            activities = [activity("设备已保存，目前未连接", deviceID: primaryID)]
        }

        return EDPPreviewConfiguration(
            snapshot: EDPXPCSnapshot(
                devices: devices,
                activities: activities,
                serviceVersion: "0.6.0-preview",
                timestamp: "2026-08-30T14:00:00+08:00"
            ),
            serviceStatus: serviceStatus,
            transportRuntimeReady: runtimeReady,
            serviceDesiredRunning: serviceDesiredRunning,
            rawAccessHelperInstalled: rawAccessHelperInstalled
        )
    }

    private static func device(
        id: String,
        metadataID: String,
        bsdName: String,
        mediaName: String,
        displayName: String,
        vidPID: String,
        onlyID: UInt64,
        size: UInt64,
        connected: Bool,
        rawReady: Bool,
        boot: EDPMountState,
        exchange: EDPMountState,
        secure: EDPMountState
    ) -> EDPXPCDevice {
        EDPXPCDevice(
            deviceID: id,
            metadataDeviceID: metadataID,
            bsdName: bsdName,
            mediaName: mediaName,
            displayName: displayName,
            vidPID: vidPID,
            labelOnlyID: onlyID,
            sizeBytes: size,
            connected: connected,
            privilegedAccessReady: rawReady,
            partitions: [
                partition(type: .boot, state: boot, autoMount: true, credential: .notRequired),
                partition(type: .exchange, state: exchange, autoMount: true, credential: .saved),
                partition(type: .secure, state: secure, autoMount: false, credential: .saved),
            ]
        )
    }

    private static func partition(
        type: EDPPartitionKind,
        state: EDPMountState,
        autoMount: Bool,
        credential: EDPCredentialStatus
    ) -> EDPXPCPartition {
        let mounted = state == .mounted
        return EDPXPCPartition(
            partitionType: type.rawValue,
            displayName: type.displayName,
            encrypted: type.isEncrypted,
            autoMount: autoMount,
            credentialStatus: credential,
            mountState: state,
            filesystem: type == .boot ? "FAT16" : "ExFAT",
            readOnly: type == .boot,
            mountPoint: mounted ? "/Volumes/\(type.displayName)" : nil,
            lastError: nil
        )
    }

    private static func replacing(
        _ source: EDPXPCDevice,
        bsdName: String? = nil,
        connected: Bool? = nil,
        rawReady: Bool? = nil
    ) -> EDPXPCDevice {
        EDPXPCDevice(
            deviceID: source.deviceID,
            metadataDeviceID: source.metadataDeviceID,
            bsdName: bsdName ?? source.bsdName,
            mediaName: source.mediaName,
            displayName: source.displayName,
            vidPID: source.vidPID,
            labelOnlyID: source.labelOnlyID,
            sizeBytes: source.sizeBytes,
            connected: connected ?? source.connected,
            privilegedAccessReady: rawReady ?? source.privilegedAccessReady,
            partitions: source.partitions
        )
    }

    private static func replacingPartition(
        _ source: EDPXPCDevice,
        type: UInt32,
        transform: (EDPXPCPartition) -> EDPXPCPartition
    ) -> EDPXPCDevice {
        replacingPartitions(source) { partition in
            partition.partitionType == type ? transform(partition) : partition
        }
    }

    private static func replacingPartitions(
        _ source: EDPXPCDevice,
        transform: (EDPXPCPartition) -> EDPXPCPartition
    ) -> EDPXPCDevice {
        EDPXPCDevice(
            deviceID: source.deviceID,
            metadataDeviceID: source.metadataDeviceID,
            bsdName: source.bsdName,
            mediaName: source.mediaName,
            displayName: source.displayName,
            vidPID: source.vidPID,
            labelOnlyID: source.labelOnlyID,
            sizeBytes: source.sizeBytes,
            connected: source.connected,
            privilegedAccessReady: source.privilegedAccessReady,
            partitions: source.partitions.map(transform)
        )
    }

    private static func activity(
        _ message: String,
        level: String = "info",
        deviceID: String? = nil,
        partitionType: UInt32? = nil
    ) -> EDPXPCActivity {
        EDPXPCActivity(
            id: UUID(),
            timestamp: "14:00:00",
            level: level,
            deviceID: deviceID,
            partitionType: partitionType,
            message: message
        )
    }

    private static func defaultActivities(deviceID: String) -> [EDPXPCActivity] {
        [
            activity("交换区已自动挂载", deviceID: deviceID, partitionType: 2),
            activity("已识别标准 EDP 加密盘", deviceID: deviceID),
        ]
    }
}
