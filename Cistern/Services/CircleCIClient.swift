import Foundation

class CircleCIClient {
    private let baseURL = "https://circleci.com/api/v2"
    private let session: URLSession

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Try ISO8601 with fractional seconds first
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                return date
            }

            // Fall back to without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }
        return decoder
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    private func makeRequest(endpoint: String) throws -> URLRequest {
        guard let token = KeychainService.getToken() else {
            throw CircleCIError.noToken
        }

        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw CircleCIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "Circle-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func fetchLatestBuilds() async throws -> [Build] {
        // 1. Determine which orgs to fetch
        let orgSlugs: [String]
        if let configuredOrg = Settings.organization {
            // Use configured org only
            orgSlugs = [configuredOrg]
        } else {
            // Fetch all user's organizations
            let orgs = try await fetchCollaborations()
            orgSlugs = orgs.map { $0.slug }
        }

        // 2. Fetch pipelines for each organization
        var allPipelines: [Pipeline] = []
        for orgSlug in orgSlugs {
            do {
                let pipelines = try await fetchPipelines(orgSlug: orgSlug)
                allPipelines.append(contentsOf: pipelines)
            } catch {
                // Continue with other orgs if one fails
                print("Failed to fetch pipelines for \(orgSlug): \(error)")
            }
        }

        // 3. Group by project slug and keep only newest per project
        let latestPipelines = Dictionary(grouping: allPipelines, by: { $0.projectSlug })
            .compactMapValues { $0.sorted(by: { $0.createdAt > $1.createdAt }).first }
            .values
            .sorted(by: { $0.projectName < $1.projectName })

        // 4. Fetch workflow status for each pipeline
        var builds: [Build] = []
        for pipeline in latestPipelines {
            let info = try await fetchPipelineInfo(pipelineId: pipeline.id)
            let build = Build(
                projectSlug: pipeline.projectSlug,
                projectName: pipeline.projectName,
                branch: pipeline.branch,
                workflowName: info.workflowName,
                pipelineNumber: pipeline.number,
                status: info.status,
                webURL: pipeline.webURL,
                completedDuration: info.completedDuration,
                startedAt: info.startedAt
            )
            builds.append(build)
        }

        return builds
    }

    private func fetchCollaborations() async throws -> [Organization] {
        let request = try makeRequest(endpoint: "/me/collaborations")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CircleCIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try decoder.decode([Organization].self, from: data)
        case 401:
            throw CircleCIError.unauthorized
        default:
            throw CircleCIError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    private func fetchPipelines(orgSlug: String) async throws -> [Pipeline] {
        let encodedSlug = orgSlug.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? orgSlug
        let request = try makeRequest(endpoint: "/pipeline?org-slug=\(encodedSlug)&mine=true")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CircleCIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let pipelinesResponse = try decoder.decode(PipelinesResponse.self, from: data)
            return pipelinesResponse.items
        case 401:
            throw CircleCIError.unauthorized
        case 429:
            throw CircleCIError.rateLimited
        default:
            throw CircleCIError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    private func fetchWorkflows(pipelineId: String) async throws -> [Workflow] {
        let request = try makeRequest(endpoint: "/pipeline/\(pipelineId)/workflow")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CircleCIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let workflowsResponse = try decoder.decode(WorkflowsResponse.self, from: data)
            return workflowsResponse.items
        case 401:
            throw CircleCIError.unauthorized
        case 429:
            throw CircleCIError.rateLimited
        default:
            throw CircleCIError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    struct PipelineInfo {
        let status: BuildStatus
        let workflowName: String
        /// For completed builds, the final duration. For running builds, this is nil.
        let completedDuration: TimeInterval?
        /// For running builds, the start time. For completed builds, this is nil.
        let startedAt: Date?
    }

    private func fetchPipelineInfo(pipelineId: String) async throws -> PipelineInfo {
        let workflows = try await fetchWorkflows(pipelineId: pipelineId)

        guard !workflows.isEmpty else {
            return PipelineInfo(status: .unknown, workflowName: "", completedDuration: nil, startedAt: nil)
        }

        // Get the most recent workflow (latest createdAt)
        let latestWorkflow = workflows.max(by: { $0.createdAt < $1.createdAt })!
        let status = BuildStatus.from(workflowStatus: latestWorkflow.status)

        if latestWorkflow.stoppedAt != nil {
            // Completed build - return final duration
            return PipelineInfo(
                status: status, workflowName: latestWorkflow.name, completedDuration: latestWorkflow.duration,
                startedAt: nil)
        } else {
            // Running build - return start time for live updates
            return PipelineInfo(
                status: status, workflowName: latestWorkflow.name, completedDuration: nil,
                startedAt: latestWorkflow.createdAt)
        }
    }

    func testConnection() async throws -> Bool {
        let request = try makeRequest(endpoint: "/me")
        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CircleCIError.invalidResponse
        }

        return httpResponse.statusCode == 200
    }
}

enum CircleCIError: LocalizedError {
    case noToken
    case invalidURL
    case invalidResponse
    case unauthorized
    case rateLimited
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No API token configured. Please add your CircleCI token in Settings."
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from CircleCI"
        case .unauthorized:
            return "Invalid API token. Please check your token in Settings."
        case .rateLimited:
            return "Rate limited by CircleCI. Please wait a moment."
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        }
    }
}
