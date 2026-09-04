import Dispatch
import Foundation
import IOKit

struct EDPIOMediaGeneration: Equatable, Sendable {
    let bsdName: String
    let registryEntryID: UInt64
}

struct EDPIOMediaLifecycleError: Error, CustomStringConvertible, Sendable {
    let description: String
}

private func edpIORegistryProperty(
    _ entry: io_registry_entry_t,
    _ key: String
) -> CFTypeRef? {
    IORegistryEntryCreateCFProperty(
        entry,
        key as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue()
}

enum EDPIOKitMediaLifecycle {
    static func mediaGeneration(forBSDName bsdName: String) -> EDPIOMediaGeneration? {
        guard let matching = IOServiceMatching("IOMedia") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard (edpIORegistryProperty(service, "BSD Name") as? String) == bsdName else {
                continue
            }
            var registryEntryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryEntryID) == KERN_SUCCESS else {
                return nil
            }
            return EDPIOMediaGeneration(
                bsdName: bsdName,
                registryEntryID: registryEntryID
            )
        }
        return nil
    }

    static func registryEntryExists(_ registryEntryID: UInt64) -> Bool {
        guard let matching = IORegistryEntryIDMatching(registryEntryID) else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }
}

private func edpIOMediaTerminationCallback(
    _ context: UnsafeMutableRawPointer?,
    _ iterator: io_iterator_t
) {
    guard let context else {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
        return
    }
    let monitor = Unmanaged<EDPIOMediaTerminationMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
    monitor.handleTermination(iterator)
}

final class EDPIOMediaTerminationMonitor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let generation: EDPIOMediaGeneration
    private let completion: @Sendable () -> Void
    private var notificationPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var finished = false

    init(
        generation: EDPIOMediaGeneration,
        queue: DispatchQueue,
        completion: @escaping @Sendable () -> Void
    ) throws {
        self.queue = queue
        self.generation = generation
        self.completion = completion

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw EDPIOMediaLifecycleError(
                description: "IONotificationPortCreate failed for \(generation.bsdName)"
            )
        }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        guard let matching = IORegistryEntryIDMatching(generation.registryEntryID) else {
            IONotificationPortDestroy(port)
            notificationPort = nil
            throw EDPIOMediaLifecycleError(
                description: "IORegistryEntryIDMatching failed for \(generation.bsdName)"
            )
        }
        let status = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            matching,
            edpIOMediaTerminationCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &iterator
        )
        guard status == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            notificationPort = nil
            throw EDPIOMediaLifecycleError(
                description: "IOServiceAddMatchingNotification failed for \(generation.bsdName): \(status)"
            )
        }

        // Draining arms the notification. Initial matches are the still-live
        // generation, not termination events.
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }

        // Close the arm/check race without polling. If the exact generation
        // disappeared during registration, the terminal condition is already true.
        if !EDPIOKitMediaLifecycle.registryEntryExists(generation.registryEntryID) {
            queue.async { [weak self] in self?.finish() }
        }
    }

    deinit {
        if iterator != 0 { IOObjectRelease(iterator) }
        if let notificationPort {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
            IONotificationPortDestroy(notificationPort)
        }
    }

    fileprivate func handleTermination(_ iterator: io_iterator_t) {
        var exactGenerationTerminated = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            var registryEntryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &registryEntryID) == KERN_SUCCESS,
               registryEntryID == generation.registryEntryID {
                exactGenerationTerminated = true
            }
            IOObjectRelease(service)
        }
        if exactGenerationTerminated { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        completion()
    }
}
