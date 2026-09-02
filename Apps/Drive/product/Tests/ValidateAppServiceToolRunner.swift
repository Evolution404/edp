import Foundation

@main
struct ValidateAppServiceToolRunner {
    static func main() async throws {
        let success = try await runUserTool(
            "/usr/bin/printf",
            ["EDP_USER_TOOL_OK"],
            timeout: .seconds(2)
        )
        precondition(success == "EDP_USER_TOOL_OK")

        do {
            _ = try await runUserTool(
                "/bin/sh",
                ["-c", "printf EDP_TYPED_FAILURE; exit 7"],
                timeout: .seconds(2)
            )
            preconditionFailure("nonzero user tool unexpectedly succeeded")
        } catch let error as EDPUserToolError {
            guard case .failed(_, let status, let output) = error else {
                preconditionFailure("expected typed failed result, got \(error)")
            }
            precondition(status == 7)
            precondition(output.contains("EDP_TYPED_FAILURE"))
        }

        let timeoutStart = ContinuousClock.now
        do {
            _ = try await runUserTool(
                "/bin/sleep",
                ["2"],
                timeout: .milliseconds(100)
            )
            preconditionFailure("timed user tool unexpectedly succeeded")
        } catch let error as EDPUserToolError {
            guard case .timedOut = error else {
                preconditionFailure("expected timeout result, got \(error)")
            }
        }
        precondition(timeoutStart.duration(to: .now) < .seconds(2))

        let cancellationStart = ContinuousClock.now
        let task = Task {
            try await runUserTool(
                "/bin/sleep",
                ["2"],
                timeout: .seconds(5)
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            preconditionFailure("cancelled user tool unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: task cancellation must terminate the child without waiting
            // for its natural process lifetime.
        }
        precondition(cancellationStart.duration(to: .now) < .seconds(2))

        print("RESULT=DRIVE_APP_USER_TOOL_BOUNDED_TYPED_CANCELLABLE_OK")
    }
}
