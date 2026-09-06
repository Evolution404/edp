import Foundation

final class EDPActivityStore: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var activities = [EDPXPCActivity]()

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func add(
        _ message: String,
        level: String = "info",
        deviceID: String? = nil,
        partitionType: UInt32? = nil
    ) {
        let activity = EDPXPCActivity(
            id: UUID(),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            level: level,
            deviceID: deviceID,
            partitionType: partitionType,
            message: message
        )
        lock.lock()
        activities.insert(activity, at: 0)
        if activities.count > capacity {
            activities.removeLast(activities.count - capacity)
        }
        lock.unlock()
    }

    func snapshot() -> [EDPXPCActivity] {
        lock.lock()
        let result = activities
        lock.unlock()
        return result
    }
}
