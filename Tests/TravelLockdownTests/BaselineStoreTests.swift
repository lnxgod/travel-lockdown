import Foundation
import Testing
@testable import TravelLockdown

@Suite("BaselineStoreTests")
struct BaselineStoreTests {
    private struct TextSnapshot: DeclaredNonSecretSnapshotModel {
        static let snapshotModelID = "tests.text"

        let value: String
    }

    private struct UndeclaredSnapshot: DeclaredNonSecretSnapshotModel {
        static let snapshotModelID = "tests.undeclared"

        let enabled: Bool
    }

    private struct MismatchedSnapshot: DeclaredNonSecretSnapshotModel {
        static let snapshotModelID = TextSnapshot.snapshotModelID

        let enabled: Bool
    }

    private struct CompatibleSupersetSnapshot: DeclaredNonSecretSnapshotModel {
        static let snapshotModelID = TextSnapshot.snapshotModelID

        let value: String
        let credential: String
    }

    private struct LegacyControlSnapshot: Codable {
        let id: ControlID
        let payload: Data
    }

    private struct LegacyLockdownBaseline: Codable {
        let version: Int
        let capturedAt: Date
        let snapshots: [LegacyControlSnapshot]
    }

    private struct StoredBaselineProbe: Decodable {
        struct Snapshot: Decodable {
            let payload: Data
        }

        let snapshots: [Snapshot]
    }

    @Test("baseline round-trips only allowed control snapshots")
    func baselineRoundTrips() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory, modelRegistry: textSnapshotRegistry())
        let baseline = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 1),
            snapshots: [
                try ControlSnapshot.capturing(TextSnapshot(value: "off"), for: .bluetooth),
                try ControlSnapshot.capturing(TextSnapshot(value: "handoff=false"), for: .continuity)
            ]
        )

        try store.save(baseline)

        #expect(try store.load() == baseline)
    }

    @Test("prepared recovery state round-trips and legacy state defaults active")
    func recoveryStateRoundTripsWithSafeLegacyDefault() throws {
        let preparedDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: preparedDirectory) }
        let preparedStore = BaselineStore(
            directory: preparedDirectory,
            modelRegistry: textSnapshotRegistry()
        )
        let prepared = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 1),
            snapshots: [
                try ControlSnapshot.capturing(
                    TextSnapshot(value: "reviewed"),
                    for: .bluetooth
                )
            ],
            recoveryState: .prepared
        )
        try preparedStore.save(prepared)
        #expect(try preparedStore.load() == prepared)

        let legacyDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        let encoded = try JSONEncoder().encode(
            LockdownBaseline(
                version: 1,
                capturedAt: Date(timeIntervalSince1970: 2),
                snapshots: prepared.snapshots,
                recoveryState: .active
            )
        )
        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "recoveryState")
        try JSONSerialization.data(withJSONObject: legacyObject).write(
            to: legacyDirectory.appendingPathComponent("baseline.json")
        )
        let legacyStore = BaselineStore(
            directory: legacyDirectory,
            modelRegistry: textSnapshotRegistry()
        )

        #expect(try legacyStore.load().recoveryState == .active)
    }

    @Test("only an unchanged prepared snapshot can be discarded")
    func preparedRemovalIsStateAndIdentityBound() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory, modelRegistry: textSnapshotRegistry())
        let prepared = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 1),
            snapshots: [
                try ControlSnapshot.capturing(TextSnapshot(value: "reviewed"), for: .bluetooth)
            ],
            recoveryState: .prepared
        )
        try store.save(prepared)
        let mismatched = LockdownBaseline(
            version: prepared.version,
            capturedAt: Date(timeIntervalSince1970: 2),
            snapshots: prepared.snapshots,
            recoveryState: .prepared
        )

        #expect(try store.removePrepared(matching: mismatched) == false)
        #expect(store.exists)
        #expect(try store.removePrepared(matching: prepared))
        #expect(store.exists == false)
    }

    @Test("baseline rejects a payload marked as a credential")
    func baselineRejectsCredentialPayload() throws {
        let baseline = LockdownBaseline(
            version: 1,
            capturedAt: Date(),
            snapshots: [
                try ControlSnapshot.capturing(
                    TextSnapshot(value: "password=secret"),
                    for: .wifiPolicy
                )
            ]
        )

        #expect(throws: BaselineStoreError.disallowedSecret) {
            try BaselineStore.validate(baseline)
        }
    }

    @Test("saving a credential-bearing baseline preserves the last safe baseline")
    func saveRejectsCredentialAndRetainsExistingBaseline() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory, modelRegistry: textSnapshotRegistry())
        let safe = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 1),
            snapshots: [
                try ControlSnapshot.capturing(
                    TextSnapshot(value: "enabled=false"),
                    for: .bluetooth
                )
            ]
        )
        try store.save(safe)
        let unsafe = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 2),
            snapshots: [
                try ControlSnapshot.capturing(
                    TextSnapshot(value: "TOKEN=secret"),
                    for: .wifiPolicy
                )
            ]
        )

        #expect(throws: BaselineStoreError.disallowedSecret) {
            try store.save(unsafe)
        }
        #expect(try store.load() == safe)
    }

    @Test("all forbidden credential markers are rejected")
    func allForbiddenCredentialMarkersAreRejected() throws {
        let forbiddenMarkers = [
            "password=secret",
            "passphrase=secret",
            "token=secret",
            "recovery-key=secret",
            "private-key=secret"
        ]

        for marker in forbiddenMarkers {
            let baseline = LockdownBaseline(
                version: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                snapshots: [
                    try ControlSnapshot.capturing(
                        TextSnapshot(value: marker),
                        for: .wifiPolicy
                    )
                ]
            )

            #expect(throws: BaselineStoreError.disallowedSecret) {
                try BaselineStore.validate(baseline)
            }
        }
    }

    @Test("an undeclared snapshot model cannot be persisted")
    func undeclaredSnapshotModelCannotBePersisted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory)
        let baseline = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 1),
            snapshots: [
                try ControlSnapshot.capturing(
                    UndeclaredSnapshot(enabled: false),
                    for: .bluetooth
                )
            ]
        )

        #expect(throws: BaselineStoreError.undeclaredSnapshotModel) {
            try store.save(baseline)
        }
        #expect(store.exists == false)
    }

    @Test("a declared model identifier cannot carry a different payload shape")
    func declaredModelIdentifierRequiresItsRegisteredPayloadShape() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory, modelRegistry: textSnapshotRegistry())
        let baseline = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 1),
            snapshots: [
                try ControlSnapshot.capturing(
                    MismatchedSnapshot(enabled: false),
                    for: .bluetooth
                )
            ]
        )

        #expect(throws: BaselineStoreError.invalidSnapshotPayload) {
            try store.save(baseline)
        }
        #expect(store.exists == false)
    }

    @Test("compatible superset fields cannot survive persistence")
    func compatibleSupersetIsCanonicalizedBeforePersistence() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory, modelRegistry: textSnapshotRegistry())
        let baseline = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 1),
            snapshots: [
                try ControlSnapshot.capturing(
                    CompatibleSupersetSnapshot(value: "off", credential: "secret"),
                    for: .bluetooth
                )
            ]
        )

        try store.save(baseline)

        let persistedData = try Data(
            contentsOf: directory.appendingPathComponent("baseline.json")
        )
        let stored = try JSONDecoder().decode(StoredBaselineProbe.self, from: persistedData)
        let persistedPayload = String(decoding: try #require(stored.snapshots.first).payload, as: UTF8.self)
        #expect(persistedPayload.contains("credential") == false)
        #expect(
            try store.load().snapshots == [
                ControlSnapshot.capturing(TextSnapshot(value: "off"), for: .bluetooth)
            ]
        )
    }

    @Test("compatible superset fields cannot survive load")
    func compatibleSupersetIsCanonicalizedDuringLoad() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encodedBaseline = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 1),
            snapshots: [
                try ControlSnapshot.capturing(
                    CompatibleSupersetSnapshot(value: "off", credential: "secret"),
                    for: .bluetooth
                )
            ]
        )
        try JSONEncoder().encode(encodedBaseline).write(
            to: directory.appendingPathComponent("baseline.json")
        )
        let store = BaselineStore(directory: directory, modelRegistry: textSnapshotRegistry())

        #expect(
            try store.load().snapshots == [
                ControlSnapshot.capturing(TextSnapshot(value: "off"), for: .bluetooth)
            ]
        )
    }

    @Test("loading rejects an undeclared encoded snapshot model")
    func loadingRejectsUndeclaredSnapshotModel() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 1),
            snapshots: [
                try ControlSnapshot.capturing(
                    UndeclaredSnapshot(enabled: false),
                    for: .bluetooth
                )
            ]
        )
        try JSONEncoder().encode(baseline).write(
            to: directory.appendingPathComponent("baseline.json")
        )
        let store = BaselineStore(directory: directory)

        #expect(throws: BaselineStoreError.undeclaredSnapshotModel) {
            try store.load()
        }
    }

    @Test("a valid legacy snapshot is migrated through the current declared model")
    func validLegacySnapshotIsSafelyMigrated() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capturedAt = Date(timeIntervalSince1970: 1)
        let legacy = LegacyLockdownBaseline(
            version: 1,
            capturedAt: capturedAt,
            snapshots: [
                LegacyControlSnapshot(
                    id: .bluetooth,
                    payload: try JSONEncoder().encode(TextSnapshot(value: "off"))
                )
            ]
        )
        try JSONEncoder().encode(legacy).write(
            to: directory.appendingPathComponent("baseline.json")
        )
        let store = BaselineStore(directory: directory, modelRegistry: textSnapshotRegistry())

        #expect(
            try store.load() == LockdownBaseline(
                version: 1,
                capturedAt: capturedAt,
                snapshots: [
                    ControlSnapshot.capturing(TextSnapshot(value: "off"), for: .bluetooth)
                ]
            )
        )
    }

    @Test("an unvalidated legacy snapshot fails closed and remains on disk")
    func unvalidatedLegacySnapshotIsRetained() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baselineURL = directory.appendingPathComponent("baseline.json")
        let legacyData = try JSONEncoder().encode(
            LegacyLockdownBaseline(
                version: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                snapshots: [
                    LegacyControlSnapshot(
                        id: .bluetooth,
                        payload: Data("untyped legacy state".utf8)
                    )
                ]
            )
        )
        try legacyData.write(to: baselineURL)
        let store = BaselineStore(directory: directory, modelRegistry: textSnapshotRegistry())

        #expect(throws: BaselineStoreError.invalidSnapshotPayload) {
            try store.load()
        }
        #expect(store.exists == true)
        #expect(try Data(contentsOf: baselineURL) == legacyData)
    }

    @Test("saved baselines remain owner-readable and owner-writable after replacement")
    func savedBaselineIsOwnerOnlyAfterReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory)
        try store.save(LockdownBaseline(version: 1, capturedAt: .now, snapshots: []))
        let baselineURL = directory.appendingPathComponent("baseline.json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: baselineURL.path
        )

        let replacement = LockdownBaseline(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 2),
            snapshots: [ControlSnapshot.empty(for: .wake)]
        )
        try store.save(replacement)

        let attributes = try FileManager.default.attributesOfItem(atPath: baselineURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try store.load() == replacement)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("baseline.json.pending").path
            ) == false
        )
    }

    @Test("one-off baseline save cannot bypass a held transaction")
    func oneOffSaveRespectsExclusiveTransaction() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory)
        let heldTransaction = try store.beginExclusiveTransaction()
        defer { heldTransaction.release() }
        let baseline = LockdownBaseline(version: 1, capturedAt: .now, snapshots: [])

        #expect(throws: BaselineStoreError.transactionUnavailable) {
            try store.save(baseline)
        }
        #expect(store.exists == false)
    }

    @Test("a partial restore never deletes the baseline")
    func partialRestoreRetainsBaseline() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory)
        let baseline = LockdownBaseline(version: 1, capturedAt: .now, snapshots: [])
        try store.save(baseline)
        let partial = RestoreResult(expectedIDs: [.bluetooth, .continuity], statuses: [
            RestorationStatus(id: .bluetooth, matchesSnapshot: true, detail: "restored"),
            RestorationStatus(id: .continuity, matchesSnapshot: false, detail: "not restored")
        ])

        #expect(try store.removeAfterVerifiedRestore(partial, matching: baseline) == false)
        #expect(store.exists == true)
    }

    @Test("a complete result for another control set cannot delete the loaded baseline")
    func mismatchedRestoreResultRetainsBaseline() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory)
        let baseline = LockdownBaseline(
            version: 1,
            capturedAt: .now,
            snapshots: [ControlSnapshot.empty(for: .bluetooth)]
        )
        try store.save(baseline)
        let forged = RestoreResult(
            expectedIDs: [.continuity],
            statuses: [
                RestorationStatus(
                    id: .continuity,
                    matchesSnapshot: true,
                    detail: "forged complete result"
                )
            ]
        )

        #expect(try store.removeAfterVerifiedRestore(forged, matching: baseline) == false)
        #expect(store.exists == true)
    }

    @Test("only a complete verified restore deletes the baseline")
    func verifiedRestoreDeletesBaseline() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BaselineStore(directory: directory)
        let baseline = LockdownBaseline(
            version: 1,
            capturedAt: .now,
            snapshots: [
                ControlSnapshot.empty(for: .bluetooth),
                ControlSnapshot.empty(for: .continuity)
            ]
        )
        try store.save(baseline)
        let complete = RestoreResult(expectedIDs: [.bluetooth, .continuity], statuses: [
            RestorationStatus(id: .continuity, matchesSnapshot: true, detail: "restored"),
            RestorationStatus(id: .bluetooth, matchesSnapshot: true, detail: "restored")
        ])

        #expect(try store.removeAfterVerifiedRestore(complete, matching: baseline) == true)
        #expect(store.exists == false)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func textSnapshotRegistry() -> SnapshotModelRegistry {
        var registry = SnapshotModelRegistry()
        registry.register(TextSnapshot.self, for: .bluetooth)
        registry.register(TextSnapshot.self, for: .continuity)
        registry.register(TextSnapshot.self, for: .wifiPolicy)
        return registry
    }
}
