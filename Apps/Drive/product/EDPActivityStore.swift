import Foundation

final class EDPActivityStore: @unchecked Sendable {
    private let capacity: Int
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
        activities.insert(EDPXPCActivity(
            id: UUID(),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            level: level,
            deviceID: deviceID,
            partitionType: partitionType,
            message: message
        ), at: 0)
        if activities.count > capacity {
            activities.removeLast(activities.count - capacity)
        }
    }

    func snapshot() -> [EDPXPCActivity] {
        activities
    }
}
