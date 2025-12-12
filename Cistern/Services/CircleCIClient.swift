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

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let start = Date()
        let (data, response) = try await session.data(for: request)
        let latency = Int(Date().timeIntervalSince(start) * 1000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CircleCIError.invalidResponse
        }

        let url = request.url?.absoluteString ?? "unknown"
        print("API: \(httpResponse.statusCode) \(url) (\(latency)ms)")

        return (data, httpResponse)
    }

    func fetchLatestBuilds(onProgress: ((Int) -> Void)? = nil) async throws -> [Build] {
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

        // 2. Fetch pipelines for each organization (up to 7 days old for pagination)
        let maxPipelineAge: TimeInterval = 7 * 24 * 60 * 60
        var allPipelines: [Pipeline] = []
        for orgSlug in orgSlugs {
            do {
                let pipelines = try await fetchPipelines(orgSlug: orgSlug, maxAge: maxPipelineAge)
                allPipelines.append(contentsOf: pipelines)
            } catch {
                // Continue with other orgs if one fails
                print("Failed to fetch pipelines for \(orgSlug): \(error)")
            }
        }

        // 3. Group pipelines by [project, branch] and keep only newest per group
        struct PipelineKey: Hashable {
            let projectSlug: String
            let branch: String
        }
        let latestPipelines = Dictionary(grouping: allPipelines, by: {
            PipelineKey(projectSlug: $0.projectSlug, branch: $0.branch)
        })
            .compactMapValues { $0.sorted(by: { $0.createdAt > $1.createdAt }).first }
            .values
            .sorted(by: { $0.createdAt > $1.createdAt })  // Most recent first

        // 4. Fetch workflows only for pipelines we need to display
        // We need all running builds + up to 10 non-running builds
        // Track seen [project, branch, workflow] to avoid duplicates
        let maxWorkflowAge: TimeInterval = 24 * 60 * 60
        let cutoffDate = Date().addingTimeInterval(-maxWorkflowAge)
        let maxBuilds = 10

        struct BuildKey: Hashable {
            let projectSlug: String
            let branch: String
            let workflowName: String
        }

        var seenKeys = Set<BuildKey>()
        var runningBuilds: [Build] = []
        var otherBuilds: [Build] = []
        var fetchedCount = 0

        for pipeline in latestPipelines {
            // Stop if we have enough non-running builds (but always check for running ones)
            if otherBuilds.count >= maxBuilds && pipeline.createdAt < cutoffDate {
                break
            }

            do {
                let workflows = try await fetchWorkflows(pipelineId: pipeline.id)
                fetchedCount += 1
                onProgress?(fetchedCount)

                for workflow in workflows where workflow.createdAt > cutoffDate {
                    let key = BuildKey(
                        projectSlug: pipeline.projectSlug, branch: pipeline.branch, workflowName: workflow.name)

                    // Skip if we've already seen this [project, branch, workflow] combination
                    guard !seenKeys.contains(key) else { continue }
                    seenKeys.insert(key)

                    let build = createBuild(from: workflow, pipeline: pipeline)
                    if build.status == .running {
                        runningBuilds.append(build)
                    } else if otherBuilds.count < maxBuilds {
                        otherBuilds.append(build)
                    }
                }
            } catch {
                print("Failed to fetch workflows for pipeline \(pipeline.id): \(error)")
            }
        }

        // 5. Combine and sort: running builds first, then others by project/branch/workflow
        let allBuilds = runningBuilds.sorted {
            ($0.projectName, $0.branch, $0.workflowName) < ($1.projectName, $1.branch, $1.workflowName)
        } + otherBuilds.sorted {
            ($0.projectName, $0.branch, $0.workflowName) < ($1.projectName, $1.branch, $1.workflowName)
        }

        return allBuilds
    }

    private func createBuild(from workflow: Workflow, pipeline: Pipeline) -> Build {
        let status = BuildStatus.from(workflowStatus: workflow.status)

        let completedDuration: TimeInterval?
        let startedAt: Date?
        let stoppedAt: Date?

        if let stopped = workflow.stoppedAt {
            completedDuration = workflow.duration
            startedAt = nil
            stoppedAt = stopped
        } else {
            completedDuration = nil
            startedAt = workflow.createdAt
            stoppedAt = nil
        }

        return Build(
            projectSlug: pipeline.projectSlug,
            projectName: pipeline.projectName,
            branch: pipeline.branch,
            workflowName: workflow.name,
            pipelineNumber: pipeline.number,
            status: status,
            webURL: pipeline.webURL,
            completedDuration: completedDuration,
            startedAt: startedAt,
            stoppedAt: stoppedAt
        )
    }

    private func fetchCollaborations() async throws -> [Organization] {
        let request = try makeRequest(endpoint: "/me/collaborations")
        let (data, httpResponse) = try await performRequest(request)

        switch httpResponse.statusCode {
        case 200:
            return try decoder.decode([Organization].self, from: data)
        case 401:
            throw CircleCIError.unauthorized
        default:
            throw CircleCIError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    private func fetchPipelines(orgSlug: String, maxAge: TimeInterval) async throws -> [Pipeline] {
        let encodedSlug = orgSlug.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? orgSlug
        let cutoffDate = Date().addingTimeInterval(-maxAge)
        var allPipelines: [Pipeline] = []
        var pageToken: String?

        // Paginate until we hit pipelines older than maxAge (API returns in recency order)
        while true {
            var endpoint = "/pipeline?org-slug=\(encodedSlug)&mine=true"
            if let token = pageToken {
                endpoint += "&page-token=\(token)"
            }

            let request = try makeRequest(endpoint: endpoint)
            let (data, httpResponse) = try await performRequest(request)

            switch httpResponse.statusCode {
            case 200:
                let pipelinesResponse = try decoder.decode(PipelinesResponse.self, from: data)

                // Filter and check if we've hit old pipelines
                for pipeline in pipelinesResponse.items {
                    if pipeline.createdAt < cutoffDate {
                        // Reached pipelines older than threshold, stop paginating
                        return allPipelines
                    }
                    allPipelines.append(pipeline)
                }

                pageToken = pipelinesResponse.nextPageToken
                if pageToken == nil {
                    return allPipelines
                }
            case 401:
                throw CircleCIError.unauthorized
            case 429:
                throw CircleCIError.rateLimited
            default:
                throw CircleCIError.httpError(statusCode: httpResponse.statusCode)
            }
        }
    }

    private func fetchWorkflows(pipelineId: String) async throws -> [Workflow] {
        let request = try makeRequest(endpoint: "/pipeline/\(pipelineId)/workflow")
        let (data, httpResponse) = try await performRequest(request)

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

    func testConnection() async throws -> Bool {
        let request = try makeRequest(endpoint: "/me")
        let (_, httpResponse) = try await performRequest(request)
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
