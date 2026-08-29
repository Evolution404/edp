import Darwin
import Foundation

@main
enum ValidateFinderNobrowseMount {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fputs("usage: validate-finder-nobrowse-mount diskN /absolute/mountpoint\n", stderr)
            exit(2)
        }
        let bsdName = CommandLine.arguments[1]
        let mountPoint = CommandLine.arguments[2]
        guard mountPoint.hasPrefix("/") else {
            fputs("mount point must be absolute\n", stderr)
            exit(2)
        }

        do {
            let controller = try EDPDiskArbitrationController()
            let actual = try controller.mountNobrowse(bsdName, at: mountPoint)
            guard actual == mountPoint else {
                fputs("unexpected mount point: \(actual)\n", stderr)
                exit(1)
            }
            guard let entry = EDPNativeMountTable.entries().first(where: {
                $0.source == "/dev/\(bsdName)" && $0.mountpoint == mountPoint
            }) else {
                fputs("mounted volume missing from native mount table\n", stderr)
                exit(1)
            }
            guard entry.flags & UInt32(MNT_DONTBROWSE) != 0 else {
                fputs("nobrowse flag missing from staged Finder mount\n", stderr)
                exit(1)
            }
            let seeded = try EDPFinderVolumeDefaults.seedIfMissing(
                at: actual,
                owner: (getuid(), getgid())
            )
            guard seeded else {
                fputs("fresh staging volume unexpectedly already had Finder defaults\n", stderr)
                exit(1)
            }
            let storeURL = URL(fileURLWithPath: actual, isDirectory: true)
                .appendingPathComponent(".DS_Store")
            let stored = try Data(contentsOf: storeURL)
            guard stored == (try EDPFinderVolumeDefaults.templateData(for: (getuid(), getgid()))) else {
                fputs("Finder defaults written to staging volume do not match template\n", stderr)
                exit(1)
            }
            let inheritedProbe = try EDPFinderVolumeDefaults.templateData(
                windowSize: CGSize(width: 922, height: 587)
            )
            guard inheritedProbe.range(of: Data("{{120, 120}, {0922, 0587}}".utf8)) != nil else {
                fputs("Finder inherited window size was not encoded into the template\n", stderr)
                exit(1)
            }
            let seededAgain = try EDPFinderVolumeDefaults.seedIfMissing(
                at: actual,
                owner: (getuid(), getgid())
            )
            guard !seededAgain, try Data(contentsOf: storeURL) == stored else {
                fputs("existing Finder defaults were unexpectedly overwritten\n", stderr)
                exit(1)
            }
            try controller.unmount(bsdName)
            print("FINDER_STAGING_MOUNT=\(actual)")
            print("FINDER_DEFAULTS_SEEDED=1")
            print("RESULT=FINDER_NOBROWSE_PRESEED_OK")
        } catch {
            fputs("FINDER_NOBROWSE_ERROR=\(error)\n", stderr)
            exit(1)
        }
    }
}
