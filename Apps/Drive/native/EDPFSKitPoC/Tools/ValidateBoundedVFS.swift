import Foundation

@main
private enum ValidateBoundedVFS {
    private struct ValidationError: Error, CustomStringConvertible {
        let description: String
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ValidationError(description: message) }
    }

    static func main() {
        do {
            let trueStatus = try EDPNativeBoundedProcess.run(
                executable: "/usr/bin/true",
                arguments: [],
                timeout: 1,
                label: "bounded true probe"
            )
            try require(trueStatus == 0, "bounded normal process returned \(trueStatus)")

            let started = Date()
            var timedOut = false
            do {
                _ = try EDPNativeBoundedProcess.run(
                    executable: "/bin/sleep",
                    arguments: ["5"],
                    timeout: 0.1,
                    label: "bounded timeout probe",
                    terminateGrace: 0.1,
                    killGrace: 0.1
                )
            } catch {
                timedOut = true
            }
            let elapsed = Date().timeIntervalSince(started)
            try require(timedOut, "bounded timeout probe unexpectedly succeeded")
            try require(elapsed < 1.5, "bounded timeout probe blocked for \(elapsed) seconds")

            try EDPNativeMountTable.unmountPath("/private/tmp/edp-definitely-not-a-mountpoint")

            print("BOUNDED_VFS_TIMEOUT_SECONDS=\(String(format: "%.3f", elapsed))")
            print("RESULT=BOUNDED_VFS_UNMOUNT_GUARD_OK")
        } catch {
            fputs("VALIDATION_ERROR=\(error)\n", stderr)
            exit(1)
        }
    }
}
