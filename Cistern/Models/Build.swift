import Cocoa

struct Build {
    let projectSlug: String
    let projectName: String
    let branch: String
    let workflowName: String
    let status: BuildStatus
    let webURL: String
    /// When the workflow was created (used for sorting by recency)
    let createdAt: Date
    /// For completed builds, the final duration. For running builds, this is nil.
    let completedDuration: TimeInterval?
    /// For running builds, the start time. For completed builds, this is nil.
    let startedAt: Date?
    /// For completed builds, the time it finished.
    let stoppedAt: Date?

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

    var color: NSColor? {
        switch self {
        case .success: return .systemGreen
        case .running: return .systemOrange
        case .failing: return .systemOrange
        case .failed, .error: return .systemRed
        case .onHold: return .systemYellow
        case .canceled, .notRun: return .systemGray
        case .unknown: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .running, .failing:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .failed, .error:
            return "xmark.circle.fill"
        case .onHold:
            return "pause.circle.fill"
        case .canceled, .notRun:
            return "minus.circle.fill"
        case .unknown:
            return "circle.dotted"
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
