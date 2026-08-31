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

struct EDPRemountQuiescenceToken: Equatable, Sendable {
    let sessionKey: String
    let generation: UInt64
    let notBeforeNanoseconds: UInt64
}

struct EDPRemountQuiescenceGate: Sendable {
    private var generations = [String: UInt64]()
    private var active = [String: EDPRemountQuiescenceToken]()

    mutating func begin(
        sessionKey: String,
        nowNanoseconds: UInt64,
        stabilizationSeconds: TimeInterval
    ) -> EDPRemountQuiescenceToken {
        let generation = (generations[sessionKey] ?? 0) &+ 1
        generations[sessionKey] = generation
        let delay = UInt64(max(0, stabilizationSeconds) * 1_000_000_000)
        let token = EDPRemountQuiescenceToken(
            sessionKey: sessionKey,
            generation: generation,
            notBeforeNanoseconds: nowNanoseconds &+ delay
        )
        active[sessionKey] = token
        return token
    }

    func activeToken(for sessionKey: String) -> EDPRemountQuiescenceToken? {
        active[sessionKey]
    }

    func remainingDelay(
        for sessionKey: String,
        nowNanoseconds: UInt64
    ) -> TimeInterval? {
        guard let token = active[sessionKey] else { return nil }
        guard nowNanoseconds < token.notBeforeNanoseconds else { return 0 }
        return TimeInterval(token.notBeforeNanoseconds - nowNanoseconds) / 1_000_000_000
    }

    mutating func complete(_ token: EDPRemountQuiescenceToken) -> Bool {
        guard active[token.sessionKey] == token else { return false }
        active.removeValue(forKey: token.sessionKey)
        return true
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
