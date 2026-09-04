import Foundation

protocol EDPLifecycleScheduling: AnyObject, Sendable {
    var nowNanoseconds: UInt64 { get }

    func schedule(
        on queue: DispatchQueue,
        after delay: TimeInterval,
        _ operation: @escaping @Sendable () -> Void
    )
}

extension EDPLifecycleScheduling {
    func deadline(after delay: TimeInterval) -> UInt64 {
        let clamped = max(0, delay)
        let nanoseconds = UInt64(clamped * 1_000_000_000)
        return nowNanoseconds &+ nanoseconds
    }

    func hasReached(_ deadline: UInt64) -> Bool {
        nowNanoseconds >= deadline
    }
}

final class EDPDispatchLifecycleScheduler: EDPLifecycleScheduling, @unchecked Sendable {
    static let shared = EDPDispatchLifecycleScheduler()

    private init() {}

    var nowNanoseconds: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func schedule(
        on queue: DispatchQueue,
        after delay: TimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) {
        let clamped = max(0, delay)
        queue.asyncAfter(deadline: .now() + clamped, execute: operation)
    }
}
