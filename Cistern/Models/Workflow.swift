import Foundation

struct WorkflowsResponse: Codable {
    let items: [Workflow]
    let nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken = "next_page_token"
    }
}

struct Workflow: Codable {
    let id: String
    let name: String
    let status: WorkflowStatus
    let createdAt: Date
    let stoppedAt: Date?
    let pipelineId: String
    let pipelineNumber: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case createdAt = "created_at"
        case stoppedAt = "stopped_at"
        case pipelineId = "pipeline_id"
        case pipelineNumber = "pipeline_number"
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

    var displayName: String {
        switch self {
        case .success: return "Success"
        case .running: return "Running"
        case .notRun: return "Not Run"
        case .failed: return "Failed"
        case .error: return "Error"
        case .failing: return "Failing"
        case .onHold: return "On Hold"
        case .canceled: return "Canceled"
        case .unknown: return "Unknown"
        }
    }
}
