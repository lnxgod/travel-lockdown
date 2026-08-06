import Testing
@testable import TravelLockdown

@Test("a newly launched app presents an inactive unlocked state")
func initialMenuStateIsUnlocked() {
    let status = LockdownStatus.make(controls: [])

    #expect(status.isActive == false)
}

@Test("menu-bar presentation exposes ready, verified, and attention states")
func menuBarPresentationTracksLockdownState() {
    let ready = MenuBarPresentation.make(state: .off, hasOperationAttention: false)
    #expect(ready.systemImage == "lock.shield")
    #expect(ready.helpText.contains("status and preflight"))

    let verified = MenuBarPresentation.make(state: .verified, hasOperationAttention: false)
    #expect(verified.systemImage == "lock.shield.fill")
    #expect(verified.helpText.contains("on and verified"))

    let attention = MenuBarPresentation.make(state: .attention, hasOperationAttention: false)
    #expect(attention.systemImage == "exclamationmark.shield.fill")

    let unmanaged = MenuBarPresentation.make(state: .unmanaged, hasOperationAttention: false)
    #expect(unmanaged == attention)

    let operationFailure = MenuBarPresentation.make(
        state: .off,
        hasOperationAttention: true
    )
    #expect(operationFailure == attention)
}

@Test("only a complete noncompliant control set is clearly unlocked")
func clearlyUnlockedRequiresEveryControlExactlyOnce() {
    let unlocked = LockdownStatus.make(controls: ControlID.allCases.map {
        ControlStatus(id: $0, verification: .nonCompliant, detail: "normal")
    })
    let incomplete = LockdownStatus.make(controls: [
        ControlStatus(id: .bluetooth, verification: .nonCompliant, detail: "normal")
    ])
    let unknown = LockdownStatus.make(controls: ControlID.allCases.map {
        ControlStatus(
            id: $0,
            verification: $0 == .wifiPolicy ? .unavailable : .nonCompliant,
            detail: "checked"
        )
    })
    let duplicate = LockdownStatus.make(
        controls: ControlID.allCases.map {
            ControlStatus(id: $0, verification: .nonCompliant, detail: "normal")
        } + [
            ControlStatus(id: .bluetooth, verification: .nonCompliant, detail: "duplicate")
        ]
    )

    #expect(unlocked.isClearlyUnlocked)
    #expect(incomplete.isClearlyUnlocked == false)
    #expect(unknown.isClearlyUnlocked == false)
    #expect(duplicate.isClearlyUnlocked == false)
}

@Test("a single unavailable required control prevents an active lockdown state")
func incompleteControlsCannotProduceLockedState() {
    let status = LockdownStatus.make(
        controls: [
            ControlStatus(id: .bluetooth, verification: .compliant, detail: "Bluetooth is off"),
            ControlStatus(id: .wifiPolicy, verification: .unavailable, detail: "Manual Wi-Fi policy is not verified")
        ]
    )

    #expect(status.isActive == false)
}

@Test("only a complete compliant control set produces an active lockdown state")
func completeControlsProduceLockedState() {
    let status = LockdownStatus.make(
        controls: [
            ControlStatus(id: .bluetooth, verification: .compliant, detail: "Bluetooth is off"),
            ControlStatus(id: .continuity, verification: .compliant, detail: "Continuity is off"),
            ControlStatus(id: .wifiPolicy, verification: .compliant, detail: "Manual Wi-Fi policy is verified"),
            ControlStatus(id: .ingress, verification: .compliant, detail: "Ingress is restricted"),
            ControlStatus(id: .wake, verification: .compliant, detail: "Wake settings are restricted")
        ]
    )

    #expect(status.isActive == true)
}

@Test("a duplicate failed required control prevents an active lockdown state")
func duplicateFailedControlCannotProduceLockedState() {
    let status = LockdownStatus.make(
        controls: [
            ControlStatus(id: .bluetooth, verification: .compliant, detail: "Bluetooth is off"),
            ControlStatus(id: .continuity, verification: .compliant, detail: "Continuity is off"),
            ControlStatus(id: .wifiPolicy, verification: .compliant, detail: "Manual Wi-Fi policy is verified"),
            ControlStatus(id: .ingress, verification: .compliant, detail: "Ingress is restricted"),
            ControlStatus(id: .wake, verification: .compliant, detail: "Wake settings are restricted"),
            ControlStatus(id: .wifiPolicy, verification: .failed, detail: "Manual Wi-Fi policy check failed")
        ]
    )

    #expect(status.isActive == false)
}

@Test("dry-run plans redact SSID-like detail from normal menu output")
func normalMenuDetailRedactsNetworkNames() {
    let change = PlannedChange(
        control: .wifiPolicy,
        summary: "Remove profile ConferenceGuest from automatic join",
        sensitivity: .networkMetadata
    )

    #expect(change.menuSummary == "Configure manual Wi-Fi connection")
}
