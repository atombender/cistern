import Cocoa

struct Build {
    let projectSlug: String
    let projectName: String
    let branch: String
    let workflowName: String
    let pipelineNumber: Int
    let status: BuildStatus
    let webURL: String
    /// For completed builds, the final duration. For running builds, this is nil.
    let completedDuration: TimeInterval?
    /// For running builds, the start time. For completed builds, this is nil.
    let startedAt: Date?

    var duration: TimeInterval {
        if let completed = completedDuration {
            return completed
        } else if let start = startedAt {
            return Date().timeIntervalSince(start)
        }
        return 0
    }

    var durationString: String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

enum BuildStatus: String {
    case success
    case running
    case notRun
    case failed
    case error
    case failing
    case onHold
    case canceled
    case unknown

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

    var color: NSColor? {
        switch self {
        case .success: return .systemGreen
        case .running: return .systemOrange
        case .failed, .error, .failing: return .systemRed
        case .onHold: return .systemYellow
        case .canceled, .notRun: return .systemGray
        case .unknown: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath.circle.fill"
        case .failed, .error, .failing: return "xmark.circle.fill"
        case .onHold: return "pause.circle.fill"
        case .canceled, .notRun: return "minus.circle.fill"
        case .unknown: return "circle.dotted"
        }
    }

    /// Priority for determining worst status (higher = worse)
    var priority: Int {
        switch self {
        case .failed, .error: return 5
        case .failing: return 4
        case .running: return 3
        case .onHold: return 2
        case .canceled, .notRun, .unknown: return 1
        case .success: return 0
        }
    }

    static func from(workflowStatus: WorkflowStatus) -> BuildStatus {
        switch workflowStatus {
        case .success: return .success
        case .running: return .running
        case .notRun: return .notRun
        case .failed: return .failed
        case .error: return .error
        case .failing: return .failing
        case .onHold: return .onHold
        case .canceled: return .canceled
        case .unknown: return .unknown
        }
    }
}

extension Array where Element == BuildStatus {
    /// Returns the worst status from the array based on priority
    func worstStatus() -> BuildStatus {
        guard !isEmpty else { return .unknown }
        return self.max(by: { $0.priority < $1.priority }) ?? .unknown
    }
}
