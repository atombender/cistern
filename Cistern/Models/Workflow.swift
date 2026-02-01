import Foundation

struct WorkflowsResponse: Codable {
    let items: [Workflow]
}

struct Workflow: Codable {
    let id: String
    let name: String
    let status: WorkflowStatus
    let createdAt: Date
    let stoppedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case createdAt = "created_at"
        case stoppedAt = "stopped_at"
    }

    /// Duration of this workflow in seconds
    var duration: TimeInterval {
        let end = stoppedAt ?? Date()
        return end.timeIntervalSince(createdAt)
    }
}

enum WorkflowStatus: String, Codable {
    case success
    case running
    case notRun = "not_run"
    case failed
    case error
    case failing
    case onHold = "on_hold"
    case canceled
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = WorkflowStatus(rawValue: rawValue) ?? .unknown
    }
}
