import Testing
@testable import TravelLockdown

@Test("a newly launched app presents an inactive unlocked state")
func initialMenuStateIsUnlocked() {
    let status = LockdownStatus.make(controls: [])

    #expect(status.isActive == false)
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
