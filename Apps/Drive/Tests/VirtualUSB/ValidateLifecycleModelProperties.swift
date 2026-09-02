import Foundation

private struct LifecycleModelFailure: Error, CustomStringConvertible, Sendable {
    let description: String
}

private struct LifecycleModelRNG {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return x
    }

    mutating func percent() -> Int {
        Int(next() % 100)
    }

    mutating func bool() -> Bool {
        (next() & 1) == 1
    }
}

private enum LifecycleModelEvent: Sendable, CustomStringConvertible {
    case attemptLaunched(Int)
    case bridgeActivated(Int)
    case bridgeFailed(Int, recoverable: Bool)
    case cleanupFinished(Int, hostAlreadyRecovered: Bool)
    case hostRecoveryFinished(Bool)
    case publicationFinished(Int)
    case filesystemMounted(Int)
    case stageFailed(EDPLifecycleFailureCode)
    case cancel

    var description: String {
        switch self {
        case .attemptLaunched(let attempt):
            return "attemptLaunched(\(attempt))"
        case .bridgeActivated(let attempt):
            return "bridgeActivated(\(attempt))"
        case .bridgeFailed(let attempt, let recoverable):
            return "bridgeFailed(\(attempt),recoverable=\(recoverable))"
        case .cleanupFinished(let attempt, let recovered):
            return "cleanupFinished(\(attempt),hostAlreadyRecovered=\(recovered))"
        case .hostRecoveryFinished(let succeeded):
            return "hostRecoveryFinished(\(succeeded))"
        case .publicationFinished(let attempt):
            return "publicationFinished(\(attempt))"
        case .filesystemMounted(let attempt):
            return "filesystemMounted(\(attempt))"
        case .stageFailed(let code):
            return "stageFailed(\(code.rawValue))"
        case .cancel:
            return "cancel"
        }
    }
}

enum EDPLifecycleModelProperties {
    static let fixedSeed: UInt64 = 0xED_50_5A_17_2026_0831

    static func run(sequenceCount: Int = 10_000, stepsPerSequence: Int = 32) throws {
        guard sequenceCount >= 10_000 else {
            throw LifecycleModelFailure(description: "model sequence count must be >= 10000")
        }

        var mountedCoverage = 0
        var failedCoverage = 0
        var retryCoverage = 0
        var recoveryCoverage = 0
        var cancellationCoverage = 0
        var publicationCoverage = 0
        var filesystemCoverage = 0
        var totalSteps = 0

        for sequenceIndex in 0..<sequenceCount {
            let sequenceSeed = mixedSeed(index: sequenceIndex)
            var rng = LifecycleModelRNG(seed: sequenceSeed)
            var machine = EDPFSKitMountLifecycleMachine()
            var trace = [String]()
            var publicationInFlight = false
            var publicationOwned = false
            var cancelledBeforeTerminal = false
            var terminal: EDPFSKitMountLifecycleState?
            var previousBudget = machine.recoveryBudget
            var retryLaunches = 0
            var recoveryConsumptions = 0
            var hostRecoveryActions = 0

            let startAction = machine.start()
            trace.append("start -> \(String(describing: startAction)); state=\(String(describing: machine.state)); budget=\(machine.recoveryBudget)")

            for step in 0..<stepsPerSequence {
                totalSteps += 1
                let before = machine.state
                let event = makeEvent(for: before, rng: &rng)
                if case .cancel = event, terminalState(before) == nil {
                    cancelledBeforeTerminal = true
                    cancellationCoverage += 1
                }

                let action = apply(event, to: &machine)
                trace.append(
                    "\(step): \(event) -> \(String(describing: action)); state=\(String(describing: machine.state)); budget=\(machine.recoveryBudget); publicationInFlight=\(publicationInFlight); publicationOwned=\(publicationOwned); cancelled=\(cancelledBeforeTerminal)"
                )

                try require(
                    machine.recoveryBudget <= previousBudget && machine.recoveryBudget >= 0,
                    invariant: "recovery budget increased or became negative",
                    sequenceIndex: sequenceIndex,
                    sequenceSeed: sequenceSeed,
                    trace: trace
                )
                if machine.recoveryBudget < previousBudget {
                    recoveryConsumptions += 1
                    recoveryCoverage += 1
                    try require(
                        recoveryConsumptions <= 1,
                        invariant: "recovery budget consumed more than once",
                        sequenceIndex: sequenceIndex,
                        sequenceSeed: sequenceSeed,
                        trace: trace
                    )
                }
                previousBudget = machine.recoveryBudget

                switch action {
                case .launchAttempt(let attempt):
                    if attempt > 0 {
                        retryLaunches += 1
                        retryCoverage += 1
                    }
                    try require(
                        attempt <= 1 && retryLaunches <= 1,
                        invariant: "mount retried more than once",
                        sequenceIndex: sequenceIndex,
                        sequenceSeed: sequenceSeed,
                        trace: trace
                    )
                    try require(
                        !cancelledBeforeTerminal,
                        invariant: "cancelled mount launched a new attempt",
                        sequenceIndex: sequenceIndex,
                        sequenceSeed: sequenceSeed,
                        trace: trace
                    )
                case .restartHost:
                    hostRecoveryActions += 1
                    try require(
                        hostRecoveryActions <= 1 && !cancelledBeforeTerminal,
                        invariant: "host recovery repeated or ran after cancellation",
                        sequenceIndex: sequenceIndex,
                        sequenceSeed: sequenceSeed,
                        trace: trace
                    )
                case .publish:
                    publicationCoverage += 1
                    try require(
                        !publicationInFlight && !publicationOwned && !cancelledBeforeTerminal,
                        invariant: "publication duplicated or occurred after cancellation",
                        sequenceIndex: sequenceIndex,
                        sequenceSeed: sequenceSeed,
                        trace: trace
                    )
                    publicationInFlight = true
                case .mountFilesystem:
                    filesystemCoverage += 1
                    try require(
                        publicationInFlight && !publicationOwned && !cancelledBeforeTerminal,
                        invariant: "filesystem mount lacked a successful publication or ran after cancellation",
                        sequenceIndex: sequenceIndex,
                        sequenceSeed: sequenceSeed,
                        trace: trace
                    )
                    publicationInFlight = false
                    publicationOwned = true
                case .cleanup:
                    publicationInFlight = false
                    publicationOwned = false
                case .fail:
                    // EDPMountCoordinator cancels an in-flight publication token before
                    // delivering terminal failure. A concrete published device,
                    // however, must only disappear through cleanup.
                    publicationInFlight = false
                case .complete, .waitForBridge:
                    break
                }

                if let existingTerminal = terminal {
                    try require(
                        machine.state == existingTerminal,
                        invariant: "terminal state changed after a late event",
                        sequenceIndex: sequenceIndex,
                        sequenceSeed: sequenceSeed,
                        trace: trace
                    )
                } else if let reached = terminalState(machine.state) {
                    terminal = reached
                    switch reached {
                    case .mounted:
                        mountedCoverage += 1
                        try require(
                            publicationOwned,
                            invariant: "mounted terminal state lost publication ownership",
                            sequenceIndex: sequenceIndex,
                            sequenceSeed: sequenceSeed,
                            trace: trace
                        )
                    case .failed:
                        failedCoverage += 1
                        try require(
                            !publicationOwned,
                            invariant: "failed terminal state retained publication ownership",
                            sequenceIndex: sequenceIndex,
                            sequenceSeed: sequenceSeed,
                            trace: trace
                        )
                    default:
                        break
                    }
                }
            }

            // The Disk Arbitration terminal gate is the production completion
            // once-only primitive. Feed several randomly ordered callback/timeout
            // events and require exactly one accepted terminal event per sequence.
            var completionGate = EDPDiskArbitrationCompletionGate()
            var accepted = 0
            var firstTerminalEvent: EDPDiskArbitrationTerminalEvent?
            for eventIndex in 0..<8 {
                let event: EDPDiskArbitrationTerminalEvent = rng.bool() ? .callback : .timeout
                if eventIndex == 0 { firstTerminalEvent = event }
                if completionGate.accept(event) { accepted += 1 }
            }
            try require(
                accepted == 1 && completionGate.terminalEvent == firstTerminalEvent,
                invariant: "completion gate accepted more than one terminal event",
                sequenceIndex: sequenceIndex,
                sequenceSeed: sequenceSeed,
                trace: trace
            )
        }

        try requireCoverage(mountedCoverage > 0, "no mounted terminal coverage")
        try requireCoverage(failedCoverage > 0, "no failed terminal coverage")
        try requireCoverage(retryCoverage > 0, "no retry coverage")
        try requireCoverage(recoveryCoverage > 0, "no recovery-budget coverage")
        try requireCoverage(cancellationCoverage > 0, "no cancellation coverage")
        try requireCoverage(publicationCoverage > 0, "no publication coverage")
        try requireCoverage(filesystemCoverage > 0, "no filesystem-mount coverage")

        print("MODEL_SEED=0x\(String(fixedSeed, radix: 16))")
        print("MODEL_SEQUENCES=\(sequenceCount)")
        print("MODEL_STEPS=\(totalSteps)")
        print("MODEL_COVERAGE=mounted:\(mountedCoverage),failed:\(failedCoverage),retry:\(retryCoverage),recovery:\(recoveryCoverage),cancel:\(cancellationCoverage),publish:\(publicationCoverage),filesystem:\(filesystemCoverage)")
        print("RESULT=DRIVE_LIFECYCLE_MODEL_PROPERTIES_OK")
    }

    private static func mixedSeed(index: Int) -> UInt64 {
        var z = fixedSeed &+ UInt64(index) &* 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    private static func terminalState(
        _ state: EDPFSKitMountLifecycleState
    ) -> EDPFSKitMountLifecycleState? {
        switch state {
        case .mounted, .failed:
            return state
        default:
            return nil
        }
    }

    private static func makeEvent(
        for state: EDPFSKitMountLifecycleState,
        rng: inout LifecycleModelRNG
    ) -> LifecycleModelEvent {
        let roll = rng.percent()
        switch state {
        case .idle:
            return roll < 50 ? .cancel : .bridgeActivated(0)
        case .preparing(let attempt):
            if roll < 75 { return .attemptLaunched(attempt) }
            if roll < 88 { return .cancel }
            return .stageFailed(.teardownFailed)
        case .waitingForBridge(let attempt):
            if roll < 40 { return .bridgeActivated(attempt) }
            if roll < 65 { return .bridgeFailed(attempt, recoverable: true) }
            if roll < 82 { return .bridgeFailed(attempt, recoverable: false) }
            return .cancel
        case .cleaningUp(let attempt, _, _):
            if roll < 55 { return .cleanupFinished(attempt, hostAlreadyRecovered: false) }
            if roll < 78 { return .cleanupFinished(attempt, hostAlreadyRecovered: true) }
            return .cancel
        case .recoveringHost:
            if roll < 55 { return .hostRecoveryFinished(true) }
            if roll < 80 { return .hostRecoveryFinished(false) }
            return .cancel
        case .publishing(let attempt):
            if roll < 55 { return .publicationFinished(attempt) }
            if roll < 80 { return .stageFailed(.publicationFailed) }
            return .cancel
        case .mountingFilesystem(let attempt):
            if roll < 55 { return .filesystemMounted(attempt) }
            if roll < 80 { return .stageFailed(.filesystemMountFailed) }
            return .cancel
        case .mounted, .failed:
            switch roll % 6 {
            case 0: return .cancel
            case 1: return .bridgeActivated(Int(rng.next() % 3))
            case 2: return .bridgeFailed(Int(rng.next() % 3), recoverable: rng.bool())
            case 3: return .publicationFinished(Int(rng.next() % 3))
            case 4: return .filesystemMounted(Int(rng.next() % 3))
            default: return .stageFailed(.teardownFailed)
            }
        }
    }

    private static func apply(
        _ event: LifecycleModelEvent,
        to machine: inout EDPFSKitMountLifecycleMachine
    ) -> EDPFSKitMountLifecycleAction {
        switch event {
        case .attemptLaunched(let attempt):
            return machine.attemptLaunched(attempt)
        case .bridgeActivated(let attempt):
            return machine.bridgeActivated(attempt)
        case .bridgeFailed(let attempt, let recoverable):
            return machine.bridgeFailed(
                attempt,
                recoverable: recoverable,
                failure: EDPLifecycleFailure(
                    code: recoverable ? .bridgeExtensionUnavailable : .bridgeProcessExited,
                    detail: recoverable ? "model bridge extension unavailable" : "model bridge process exited"
                )
            )
        case .cleanupFinished(let attempt, let recovered):
            return machine.cleanupFinished(attempt, hostAlreadyRecovered: recovered)
        case .hostRecoveryFinished(let succeeded):
            return machine.hostRecoveryFinished(succeeded)
        case .publicationFinished(let attempt):
            return machine.publicationFinished(attempt)
        case .filesystemMounted(let attempt):
            return machine.filesystemMounted(attempt)
        case .stageFailed(let code):
            return machine.stageFailed(EDPLifecycleFailure(
                code: code,
                detail: "model injected \(code.rawValue)"
            ))
        case .cancel:
            return machine.cancel()
        }
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        invariant: String,
        sequenceIndex: Int,
        sequenceSeed: UInt64,
        trace: [String]
    ) throws {
        guard condition() else {
            throw LifecycleModelFailure(
                description: "MODEL_PROPERTY_FAILURE invariant=\(invariant) fixedSeed=0x\(String(fixedSeed, radix: 16)) sequence=\(sequenceIndex) sequenceSeed=0x\(String(sequenceSeed, radix: 16))\nTRACE:\n\(trace.joined(separator: "\n"))"
            )
        }
    }

    private static func requireCoverage(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw LifecycleModelFailure(
                description: "MODEL_COVERAGE_FAILURE fixedSeed=0x\(String(fixedSeed, radix: 16)) \(message)"
            )
        }
    }
}
