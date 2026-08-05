enum Sensitivity: Equatable, Sendable {
    case `public`
    case networkMetadata
}

struct PlannedChange: Equatable, Sendable {
    let control: ControlID
    let summary: String
    let sensitivity: Sensitivity

    var menuSummary: String {
        switch sensitivity {
        case .public:
            summary
        case .networkMetadata:
            "Configure manual Wi-Fi connection"
        }
    }
}

struct DryRunPlan: Equatable, Sendable {
    let changes: [PlannedChange]
}
