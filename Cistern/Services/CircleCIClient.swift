import Foundation

class CircleCIClient {
    private let baseURL = "https://circleci.com/api/v2"
    private let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil  // Disable URL caching to prevent memory accumulation
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)

        // Create decoder once and reuse - avoid recreating on every API call
        let jsonDecoder = JSONDecoder()
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterWithoutFractional = ISO8601DateFormatter()
        formatterWithoutFractional.formatOptions = [.withInternetDateTime]

        jsonDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Try ISO8601 with fractional seconds first
            if let date = formatterWithFractional.date(from: dateString) {
                return date
            }

            // Fall back to without fractional seconds
            if let date = formatterWithoutFractional.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(dateString)"
            )
        }
        self.decoder = jsonDecoder
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
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CircleCIError.invalidResponse
        }

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

        // 2. Fetch pipelines up to 14 days old to catch workflow reruns on older pipelines
        let maxPipelineAge: TimeInterval = 14 * 24 * 60 * 60  // 14 days
        let maxWorkflowAge: TimeInterval = 24 * 60 * 60  // 24 hours for workflow display
        let workflowCutoffDate = Date().addingTimeInterval(-maxWorkflowAge)
        let maxBuilds = 10

        var allPipelines: [Pipeline] = []
        for orgSlug in orgSlugs {
            do {
                let pipelines = try await fetchPipelines(
                    orgSlug: orgSlug,
                    minAge: 0,
                    maxAge: maxPipelineAge
                )
                allPipelines.append(contentsOf: pipelines)
            } catch {
                // Silently continue - pipelines from other orgs may still work
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
            .sorted(by: { $0.createdAt > $1.createdAt })

        // 4. Fetch workflows for each pipeline and filter by recency
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
            // Stop if we have enough non-running builds and pipeline is old
            if otherBuilds.count >= maxBuilds && pipeline.createdAt < workflowCutoffDate {
                break
            }

            do {
                let workflows = try await fetchWorkflows(pipelineId: pipeline.id)
                fetchedCount += 1
                onProgress?(fetchedCount)

                for workflow in workflows where workflow.createdAt > workflowCutoffDate {
                    let buildKey = BuildKey(
                        projectSlug: pipeline.projectSlug,
                        branch: pipeline.branch,
                        workflowName: workflow.name
                    )

                    guard !seenKeys.contains(buildKey) else { continue }
                    seenKeys.insert(buildKey)

                    let build = createBuild(from: workflow, pipeline: pipeline)
                    if build.status == .running {
                        runningBuilds.append(build)
                    } else if otherBuilds.count < maxBuilds {
                        otherBuilds.append(build)
                    }
                }
            } catch {
                // Silently continue - other pipelines may still have workflows
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

    private func fetchPipelines(
        orgSlug: String, minAge: TimeInterval, maxAge: TimeInterval
    ) async throws -> [Pipeline] {
        let encodedSlug = orgSlug.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? orgSlug
        let minCutoffDate = Date().addingTimeInterval(-minAge)  // Skip pipelines newer than this
        let maxCutoffDate = Date().addingTimeInterval(-maxAge)  // Stop at pipelines older than this
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
                    if pipeline.createdAt < maxCutoffDate {
                        // Reached pipelines older than max threshold, stop paginating
                        return allPipelines
                    }
                    // Only include pipelines within the [minAge, maxAge] range
                    if pipeline.createdAt <= minCutoffDate {
                        allPipelines.append(pipeline)
                    }
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
