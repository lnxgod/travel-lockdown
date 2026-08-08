import Darwin
import Foundation
import Security

protocol DeclaredNonSecretSnapshotModel: Codable, Sendable {
    static var snapshotModelID: String { get }
}

enum ManualRecoveryMarker: String, Codable, Equatable, Sendable {
    case unresolved
}

struct SnapshotModelRegistry: Sendable {
    private struct Registration: Sendable {
        let modelID: String
        let canonicalize: @Sendable (Data) throws -> Data
    }

    private var registrations: [ControlID: Registration] = [:]

    mutating func register<Model: DeclaredNonSecretSnapshotModel>(
        _ model: Model.Type,
        for controlID: ControlID,
        secretMarkerValidationProjection: (@Sendable (Model) -> Model)? = nil
    ) {
        registrations[controlID] = Registration(
            modelID: Model.snapshotModelID,
            canonicalize: { payload in
                if secretMarkerValidationProjection == nil {
                    try BaselineStore.validatePayload(payload)
                }

                let decoded: Model
                do {
                    decoded = try JSONDecoder().decode(Model.self, from: payload)
                } catch {
                    throw BaselineStoreError.invalidSnapshotPayload
                }

                let canonicalPayload: Data
                do {
                    canonicalPayload = try SnapshotModelEncoder.encode(decoded)
                } catch {
                    throw BaselineStoreError.invalidSnapshotPayload
                }

                if let secretMarkerValidationProjection {
                    let validationPayload: Data
                    do {
                        validationPayload = try SnapshotModelEncoder.encode(
                            secretMarkerValidationProjection(decoded)
                        )
                    } catch {
                        throw BaselineStoreError.invalidSnapshotPayload
                    }
                    try BaselineStore.validatePayload(validationPayload)
                }
                return canonicalPayload
            }
        )
    }

    fileprivate func canonicalized(_ snapshot: ControlSnapshot) throws -> ControlSnapshot {
        if snapshot.modelID == ControlSnapshot.emptyModelID {
            guard snapshot.payload.isEmpty else {
                throw BaselineStoreError.invalidSnapshotPayload
            }
            return .empty(for: snapshot.id)
        }

        guard let registration = registrations[snapshot.id],
              registration.modelID == snapshot.modelID else {
            throw BaselineStoreError.undeclaredSnapshotModel
        }
        return ControlSnapshot(
            id: snapshot.id,
            modelID: registration.modelID,
            payload: try registration.canonicalize(snapshot.payload)
        )
    }

    fileprivate func decodedSnapshot(
        id: ControlID,
        modelID: String?,
        payload: Data
    ) throws -> ControlSnapshot {
        if let modelID {
            return try canonicalized(
                ControlSnapshot(id: id, modelID: modelID, payload: payload)
            )
        }

        if payload.isEmpty {
            return .empty(for: id)
        }

        guard let registration = registrations[id] else {
            throw BaselineStoreError.undeclaredSnapshotModel
        }
        return ControlSnapshot(
            id: id,
            modelID: registration.modelID,
            payload: try registration.canonicalize(payload)
        )
    }
}

private enum SnapshotModelEncoder {
    static func encode<Model: Encodable>(_ model: Model) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(model)
    }
}

private extension CodingUserInfoKey {
    static let snapshotModelRegistry = CodingUserInfoKey(
        rawValue: "TravelLockdown.snapshotModelRegistry"
    )!
}

struct ControlSnapshot: Codable, Equatable, Sendable {
    fileprivate static let emptyModelID = "TravelLockdown.empty"

    let id: ControlID
    fileprivate let modelID: String
    fileprivate let payload: Data

    static func empty(for id: ControlID) -> ControlSnapshot {
        ControlSnapshot(id: id, modelID: emptyModelID, payload: Data())
    }

    static func capturing<Model: DeclaredNonSecretSnapshotModel>(
        _ model: Model,
        for id: ControlID
    ) throws -> ControlSnapshot {
        ControlSnapshot(
            id: id,
            modelID: Model.snapshotModelID,
            payload: try SnapshotModelEncoder.encode(model)
        )
    }

    func decoded<Model: DeclaredNonSecretSnapshotModel>(
        as model: Model.Type,
        for expectedID: ControlID
    ) throws -> Model {
        guard id == expectedID, modelID == Model.snapshotModelID else {
            throw BaselineStoreError.invalidSnapshotPayload
        }
        do {
            return try JSONDecoder().decode(Model.self, from: payload)
        } catch {
            throw BaselineStoreError.invalidSnapshotPayload
        }
    }

    fileprivate init(id: ControlID, modelID: String, payload: Data) {
        self.id = id
        self.modelID = modelID
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case modelID
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ControlID.self, forKey: .id)
        let modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        let payload = try container.decode(Data.self, forKey: .payload)
        guard let registry = decoder.userInfo[.snapshotModelRegistry] as? SnapshotModelRegistry else {
            throw BaselineStoreError.undeclaredSnapshotModel
        }
        self = try registry.decodedSnapshot(id: id, modelID: modelID, payload: payload)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(payload, forKey: .payload)
    }
}

struct LockdownBaseline: Codable, Equatable, Sendable {
    let version: Int
    let capturedAt: Date
    let snapshots: [ControlSnapshot]
    let recoveryState: RecoveryState

    init(
        version: Int,
        capturedAt: Date,
        snapshots: [ControlSnapshot],
        recoveryState: RecoveryState = .active
    ) {
        self.version = version
        self.capturedAt = capturedAt
        self.snapshots = snapshots
        self.recoveryState = recoveryState
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case capturedAt
        case snapshots
        case recoveryState
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        snapshots = try container.decode([ControlSnapshot].self, forKey: .snapshots)
        recoveryState = try container.decodeIfPresent(
            RecoveryState.self,
            forKey: .recoveryState
        ) ?? .active
    }
}

struct RestorationStatus: Equatable, Sendable {
    let id: ControlID
    let matchesSnapshot: Bool
    let detail: String
    let manualRecovery: ManualRecoveryInstruction?

    init(
        id: ControlID,
        matchesSnapshot: Bool,
        detail: String,
        manualRecovery: ManualRecoveryInstruction? = nil
    ) {
        self.id = id
        self.matchesSnapshot = matchesSnapshot
        self.detail = detail
        self.manualRecovery = manualRecovery
    }
}

struct RestoreResult: Equatable, Sendable {
    let expectedIDs: Set<ControlID>
    let statuses: [RestorationStatus]
    let recoveryToken: String?

    init(
        expectedIDs: Set<ControlID>,
        statuses: [RestorationStatus],
        recoveryToken: String? = nil
    ) {
        self.expectedIDs = expectedIDs
        self.statuses = statuses
        self.recoveryToken = recoveryToken
    }

    var isFullyRestored: Bool {
        !expectedIDs.isEmpty
            && statuses.count == expectedIDs.count
            && Set(statuses.map(\.id)) == expectedIDs
            && Set(statuses.filter(\.matchesSnapshot).map(\.id)) == expectedIDs
            && statuses.allSatisfy { $0.manualRecovery == nil }
    }
}

enum BaselineStoreError: Error, Equatable {
    case disallowedSecret
    case undeclaredSnapshotModel
    case invalidSnapshotPayload
    case secureRandomUnavailable
    case transactionUnavailable
    case transactionLockFailed
}

protocol BaselineTransactionLock: Sendable {
    func release()
}

protocol BaselineTransactionLocking: Sendable {
    func acquireExclusiveLock(in directory: URL) throws -> any BaselineTransactionLock
}

private struct AdvisoryBaselineTransactionLocking: BaselineTransactionLocking {
    func acquireExclusiveLock(in directory: URL) throws -> any BaselineTransactionLock {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let lockURL = directory.appendingPathComponent("baseline.lock")
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw BaselineStoreError.transactionLockFailed
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            _ = close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN {
                throw BaselineStoreError.transactionUnavailable
            }
            throw BaselineStoreError.transactionLockFailed
        }

        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw BaselineStoreError.transactionLockFailed
        }
        return AdvisoryBaselineTransactionLock(descriptor: descriptor)
    }
}

private final class AdvisoryBaselineTransactionLock: @unchecked Sendable, BaselineTransactionLock {
    private let stateLock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        let descriptorToClose = stateLock.withLock {
            let currentDescriptor = descriptor
            descriptor = -1
            return currentDescriptor
        }
        guard descriptorToClose >= 0 else { return }
        _ = flock(descriptorToClose, LOCK_UN)
        _ = close(descriptorToClose)
    }

    deinit {
        release()
    }
}

private struct PendingRecoveryReview: Codable, Equatable {
    let tokenHash: String
    let purpose: RecoverySetupPurpose
    let bindingFingerprint: String
}

final class BaselineTransaction: @unchecked Sendable {
    private let store: BaselineStore
    private let lock: any BaselineTransactionLock

    fileprivate init(store: BaselineStore, lock: any BaselineTransactionLock) {
        self.store = store
        self.lock = lock
    }

    var exists: Bool {
        store.exists
    }

    func load() throws -> LockdownBaseline {
        try store.loadUnlocked()
    }

    func save(_ baseline: LockdownBaseline) throws {
        try store.saveUnlocked(baseline)
    }

    func prepareAfterVerifiedRestore(
        _ result: RestoreResult,
        matching baseline: LockdownBaseline
    ) throws -> Bool {
        try store.prepareAfterVerifiedRestoreUnlocked(result, matching: baseline)
    }

    func removePrepared(matching baseline: LockdownBaseline) throws -> Bool {
        try store.removePreparedUnlocked(matching: baseline)
    }

    func issueRecoveryReviewToken(
        purpose: RecoverySetupPurpose,
        bindingFingerprint: String
    ) throws -> String {
        try store.issueRecoveryReviewTokenUnlocked(
            purpose: purpose,
            bindingFingerprint: bindingFingerprint
        )
    }

    func matchesRecoveryReview(
        token: String,
        purpose: RecoverySetupPurpose,
        bindingFingerprint: String
    ) -> Bool {
        store.matchesRecoveryReviewUnlocked(
            token: token,
            purpose: purpose,
            bindingFingerprint: bindingFingerprint
        )
    }

    func discardRecoveryReviewIfMatching(
        token: String,
        purpose: RecoverySetupPurpose,
        bindingFingerprint: String
    ) {
        store.discardRecoveryReviewIfMatchingUnlocked(
            token: token,
            purpose: purpose,
            bindingFingerprint: bindingFingerprint
        )
    }

    func release() {
        lock.release()
    }

    deinit {
        release()
    }
}

struct BaselineStore: Sendable {
    private static let baselineFilename = "baseline.json"
    private static let pendingFilename = "baseline.json.pending"
    private static let recoveryReviewFilename = "recovery-review.json"
    private static let pendingRecoveryReviewFilename = "recovery-review.json.pending"

    let directory: URL
    private let modelRegistry: SnapshotModelRegistry
    private let transactionLocking: any BaselineTransactionLocking

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TravelLockdown", isDirectory: true),
        modelRegistry: SnapshotModelRegistry = SnapshotModelRegistry(),
        transactionLocking: any BaselineTransactionLocking = AdvisoryBaselineTransactionLocking()
    ) {
        self.directory = directory
        self.modelRegistry = modelRegistry
        self.transactionLocking = transactionLocking
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: baselineURL.path)
    }

    func load() throws -> LockdownBaseline {
        try loadUnlocked()
    }

    func save(_ baseline: LockdownBaseline) throws {
        let transaction = try beginExclusiveTransaction()
        defer { transaction.release() }
        try transaction.save(baseline)
    }

    func prepareAfterVerifiedRestore(
        _ result: RestoreResult,
        matching baseline: LockdownBaseline
    ) throws -> Bool {
        let transaction = try beginExclusiveTransaction()
        defer { transaction.release() }
        return try transaction.prepareAfterVerifiedRestore(result, matching: baseline)
    }

    func removePrepared(matching baseline: LockdownBaseline) throws -> Bool {
        let transaction = try beginExclusiveTransaction()
        defer { transaction.release() }
        return try transaction.removePrepared(matching: baseline)
    }

    func beginExclusiveTransaction() throws -> BaselineTransaction {
        BaselineTransaction(
            store: self,
            lock: try transactionLocking.acquireExclusiveLock(in: directory)
        )
    }

    fileprivate func loadUnlocked() throws -> LockdownBaseline {
        let data = try Data(contentsOf: baselineURL)
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotModelRegistry] = modelRegistry
        let baseline = try decoder.decode(LockdownBaseline.self, from: data)
        try Self.validateEnvelope(baseline)
        return baseline
    }

    fileprivate func saveUnlocked(_ baseline: LockdownBaseline) throws {
        try Self.validateEnvelope(baseline)
        let canonicalBaseline = LockdownBaseline(
            version: baseline.version,
            capturedAt: baseline.capturedAt,
            snapshots: try baseline.snapshots.map(modelRegistry.canonicalized),
            recoveryState: baseline.recoveryState
        )
        try Self.validateEnvelope(canonicalBaseline)

        let fileManager = FileManager.default
        try ensureOwnerOnlyDirectory()

        let data = try JSONEncoder().encode(canonicalBaseline)
        try data.write(to: pendingURL, options: .atomic)
        defer {
            try? fileManager.removeItem(at: pendingURL)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pendingURL.path
        )

        if exists {
            _ = try fileManager.replaceItemAt(
                baselineURL,
                withItemAt: pendingURL,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: pendingURL, to: baselineURL)
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: baselineURL.path
        )
    }

    fileprivate func issueRecoveryReviewTokenUnlocked(
        purpose: RecoverySetupPurpose,
        bindingFingerprint: String
    ) throws -> String {
        guard Self.isLowercaseHexDigest(bindingFingerprint) else {
            throw BaselineStoreError.invalidSnapshotPayload
        }

        var token: String
        var tokenHash: String
        let previousTokenHash = loadRecoveryReviewRecordUnlocked()?.tokenHash
        repeat {
            token = try Self.randomRecoveryReviewToken()
            tokenHash = RecoverySnapshotFingerprint.tokenHash(token)
        } while tokenHash == previousTokenHash

        let record = PendingRecoveryReview(
            tokenHash: tokenHash,
            purpose: purpose,
            bindingFingerprint: bindingFingerprint
        )
        try saveRecoveryReviewRecordUnlocked(record)
        return token
    }

    fileprivate func matchesRecoveryReviewUnlocked(
        token: String,
        purpose: RecoverySetupPurpose,
        bindingFingerprint: String
    ) -> Bool {
        guard Self.isLowercaseHexDigest(token),
              Self.isLowercaseHexDigest(bindingFingerprint),
              let record = loadRecoveryReviewRecordUnlocked(),
              record.purpose == purpose,
              record.bindingFingerprint == bindingFingerprint else {
            return false
        }
        return Self.constantTimeEqual(
            record.tokenHash,
            RecoverySnapshotFingerprint.tokenHash(token)
        )
    }

    fileprivate func discardRecoveryReviewIfMatchingUnlocked(
        token: String,
        purpose: RecoverySetupPurpose,
        bindingFingerprint: String
    ) {
        guard matchesRecoveryReviewUnlocked(
            token: token,
            purpose: purpose,
            bindingFingerprint: bindingFingerprint
        ) else {
            return
        }
        try? FileManager.default.removeItem(at: recoveryReviewURL)
    }

    private func saveRecoveryReviewRecordUnlocked(_ record: PendingRecoveryReview) throws {
        try Self.validateRecoveryReviewRecord(record)
        try ensureOwnerOnlyDirectory()

        let fileManager = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: pendingRecoveryReviewURL, options: .atomic)
        defer {
            try? fileManager.removeItem(at: pendingRecoveryReviewURL)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pendingRecoveryReviewURL.path
        )

        if fileManager.fileExists(atPath: recoveryReviewURL.path) {
            _ = try fileManager.replaceItemAt(
                recoveryReviewURL,
                withItemAt: pendingRecoveryReviewURL,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: pendingRecoveryReviewURL, to: recoveryReviewURL)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: recoveryReviewURL.path
        )
    }

    private func loadRecoveryReviewRecordUnlocked() -> PendingRecoveryReview? {
        guard let data = try? Data(contentsOf: recoveryReviewURL),
              let record = try? JSONDecoder().decode(PendingRecoveryReview.self, from: data),
              (try? Self.validateRecoveryReviewRecord(record)) != nil else {
            return nil
        }
        return record
    }

    private func ensureOwnerOnlyDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private static func validateRecoveryReviewRecord(_ record: PendingRecoveryReview) throws {
        guard isLowercaseHexDigest(record.tokenHash),
              isLowercaseHexDigest(record.bindingFingerprint) else {
            throw BaselineStoreError.invalidSnapshotPayload
        }
    }

    private static func randomRecoveryReviewToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw BaselineStoreError.secureRandomUnavailable
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseHexDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        guard leftBytes.count == rightBytes.count else { return false }
        return zip(leftBytes, rightBytes).reduce(UInt8.zero) { difference, pair in
            difference | (pair.0 ^ pair.1)
        } == 0
    }

    fileprivate func removePreparedUnlocked(matching baseline: LockdownBaseline) throws -> Bool {
        guard baseline.recoveryState == .prepared,
              exists,
              try loadUnlocked() == baseline else {
            return false
        }
        try FileManager.default.removeItem(at: baselineURL)
        return !exists
    }

    private static func validateEnvelope(_ baseline: LockdownBaseline) throws {
        guard baseline.version == 1,
              baseline.recoveryState == .active
                || baseline.recoveryState == .prepared else {
            throw BaselineStoreError.invalidSnapshotPayload
        }
    }

    fileprivate static func validatePayload(_ payload: Data) throws {
        let forbiddenMarkers = ["password=", "passphrase=", "token=", "recovery-key=", "private-key="]
        let text = String(decoding: payload, as: UTF8.self).lowercased()
        if forbiddenMarkers.contains(where: text.contains) {
            throw BaselineStoreError.disallowedSecret
        }
    }

    fileprivate func prepareAfterVerifiedRestoreUnlocked(
        _ result: RestoreResult,
        matching baseline: LockdownBaseline
    ) throws -> Bool {
        let baselineIDs = baseline.snapshots.map(\.id)
        guard baseline.recoveryState == .active,
              result.isFullyRestored,
              Set(baselineIDs).count == baselineIDs.count,
              Set(baselineIDs) == result.expectedIDs,
              try loadUnlocked() == baseline else {
            return false
        }

        let prepared = LockdownBaseline(
            version: baseline.version,
            capturedAt: baseline.capturedAt,
            snapshots: baseline.snapshots,
            recoveryState: .prepared
        )
        try saveUnlocked(prepared)
        return try loadUnlocked() == prepared
    }

    private var baselineURL: URL {
        directory.appendingPathComponent(Self.baselineFilename)
    }

    private var pendingURL: URL {
        directory.appendingPathComponent(Self.pendingFilename)
    }

    private var recoveryReviewURL: URL {
        directory.appendingPathComponent(Self.recoveryReviewFilename)
    }

    private var pendingRecoveryReviewURL: URL {
        directory.appendingPathComponent(Self.pendingRecoveryReviewFilename)
    }
}
