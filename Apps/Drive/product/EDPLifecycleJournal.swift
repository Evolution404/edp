import Foundation

struct EDPLifecycleOperationContext: Sendable {
    let id: UUID
    let operation: String
    let deviceID: String
    let partitionType: UInt32?
    let startedAtNanoseconds: UInt64

    init(
        id: UUID = UUID(),
        operation: String,
        deviceID: String,
        partitionType: UInt32?,
        startedAtNanoseconds: UInt64
    ) {
        self.id = id
        self.operation = operation
        self.deviceID = deviceID
        self.partitionType = partitionType
        self.startedAtNanoseconds = startedAtNanoseconds
    }
}

struct EDPLifecycleJournalEntry: Codable, Equatable, Sendable {
    let sequence: UInt64
    let operationID: String
    let operation: String
    let deviceID: String
    let partitionType: UInt32?
    let state: String
    let event: String
    let attempt: Int?
    let recoveryBudget: Int?
    let elapsedMs: UInt64
    let ownedResources: [String]
    let diagnosticCode: String?

    var jsonObject: [String: Any] {
        var result: [String: Any] = [
            "sequence": sequence,
            "operationID": operationID,
            "operation": operation,
            "deviceID": deviceID,
            "state": state,
            "event": event,
            "elapsedMs": elapsedMs,
            "ownedResources": ownedResources,
        ]
        if let partitionType { result["partitionType"] = partitionType }
        if let attempt { result["attempt"] = attempt }
        if let recoveryBudget { result["recoveryBudget"] = recoveryBudget }
        if let diagnosticCode { result["diagnosticCode"] = diagnosticCode }
        return result
    }
}

final class EDPLifecycleJournal: @unchecked Sendable {
    static let defaultCapacity = 256

    private let lock = NSLock()
    private let capacity: Int
    private var nextSequence: UInt64 = 0
    private var entries = [EDPLifecycleJournalEntry]()

    init(capacity: Int = EDPLifecycleJournal.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    func record(
        context: EDPLifecycleOperationContext,
        scheduler: any EDPLifecycleScheduling,
        state: String,
        event: String,
        attempt: Int? = nil,
        recoveryBudget: Int? = nil,
        ownedResources: [String] = [],
        diagnosticCode: String? = nil
    ) {
        let now = scheduler.nowNanoseconds
        let elapsed = now >= context.startedAtNanoseconds
            ? (now - context.startedAtNanoseconds) / 1_000_000
            : 0
        lock.lock()
        nextSequence &+= 1
        entries.append(EDPLifecycleJournalEntry(
            sequence: nextSequence,
            operationID: context.id.uuidString.lowercased(),
            operation: context.operation,
            deviceID: context.deviceID,
            partitionType: context.partitionType,
            state: state,
            event: event,
            attempt: attempt,
            recoveryBudget: recoveryBudget,
            elapsedMs: elapsed,
            ownedResources: Array(Set(ownedResources)).sorted(),
            diagnosticCode: diagnosticCode
        ))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
    }

    func snapshot() -> [EDPLifecycleJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func jsonObjects() -> [[String: Any]] {
        snapshot().map(\.jsonObject)
    }
}
