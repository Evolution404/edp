import Foundation

@main
struct ValidateFastRegression {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw FastRegressionError.usage
        }
        let goldenPath = CommandLine.arguments[1]
        try ValidateEDPNativeCore.run(goldenPath: goldenPath)
        try ValidateEDPMetadataProbe.run(goldenPath: goldenPath)
        try ValidateTransportLifecycle.run()
        ValidateBoundedVFS.run()
        try ValidateProductModels.run()
        print("RESULT=DRIVE_FAST_COMBINED_BINARY_OK")
    }
}

private enum FastRegressionError: Error, CustomStringConvertible {
    case usage

    var description: String {
        switch self {
        case .usage:
            return "usage: validate-fast-regression <fixtures/golden/disks.json>"
        }
    }
}
