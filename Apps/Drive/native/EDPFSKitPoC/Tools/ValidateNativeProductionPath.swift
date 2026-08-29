import Foundation

@main
enum ValidateNativeProductionPath {
    static func main() throws {
        let mounts = EDPNativeMountTable.entries()
        print("NATIVE_MOUNT_TABLE_ENTRIES=\(mounts.count)")
        print("RESULT=NATIVE_MOUNT_TABLE_API_OK")

        let media = try EDPNativeDeviceDiscovery.allWholeUSBMedia()
        print("NATIVE_WHOLE_USB_MEDIA=\(media.count)")
        for item in media {
            print("NATIVE_USB=\(item.bsdName)\t\(item.vid):\(item.pid)\t\(item.size)\t\(item.mediaName)")
        }
        print("RESULT=NATIVE_IOKIT_DISCOVERY_API_OK")

        _ = try EDPDiskArbitrationController()
        _ = try EDPDiskEventMonitor()
        print("RESULT=NATIVE_DISK_ARBITRATION_API_OK")
        print("RESULT=NATIVE_PRODUCTION_PATH_API_OK")
    }
}
