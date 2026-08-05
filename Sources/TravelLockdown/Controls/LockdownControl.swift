protocol LockdownControl: Sendable {
    var id: ControlID { get }
    func capture() async throws -> ControlSnapshot
    func plan(from snapshot: ControlSnapshot) async throws -> [PlannedChange]
    func apply() async throws
    func verify() async throws -> ControlStatus
    func restore(from snapshot: ControlSnapshot) async throws
    func verifyRestored(from snapshot: ControlSnapshot) async throws -> RestorationStatus
}

struct AnyLockdownControl: LockdownControl {
    let id: ControlID

    private let captureOperation: @Sendable () async throws -> ControlSnapshot
    private let planOperation: @Sendable (ControlSnapshot) async throws -> [PlannedChange]
    private let applyOperation: @Sendable () async throws -> Void
    private let verifyOperation: @Sendable () async throws -> ControlStatus
    private let restoreOperation: @Sendable (ControlSnapshot) async throws -> Void
    private let verifyRestoredOperation:
        @Sendable (ControlSnapshot) async throws -> RestorationStatus

    init<Control: LockdownControl>(_ control: Control) {
        id = control.id
        captureOperation = { try await control.capture() }
        planOperation = { try await control.plan(from: $0) }
        applyOperation = { try await control.apply() }
        verifyOperation = { try await control.verify() }
        restoreOperation = { try await control.restore(from: $0) }
        verifyRestoredOperation = { try await control.verifyRestored(from: $0) }
    }

    func capture() async throws -> ControlSnapshot {
        try await captureOperation()
    }

    func plan(from snapshot: ControlSnapshot) async throws -> [PlannedChange] {
        try await planOperation(snapshot)
    }

    func apply() async throws {
        try await applyOperation()
    }

    func verify() async throws -> ControlStatus {
        try await verifyOperation()
    }

    func restore(from snapshot: ControlSnapshot) async throws {
        try await restoreOperation(snapshot)
    }

    func verifyRestored(from snapshot: ControlSnapshot) async throws -> RestorationStatus {
        try await verifyRestoredOperation(snapshot)
    }
}
