import Foundation

class CircleCIClient {
    private let baseURL = "https://circleci.com/api/v2"
    private let session: URLSession
    private let decoder: JSONDecoder
    private var cachedToken: String?

    deinit {
        session.invalidateAndCancel()
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil

        self.session = URLSession(configuration: config)

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
        if cachedToken == nil {
            cachedToken = KeychainService.getToken()
        }

        guard let token = cachedToken else {
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

        // 2. Fetch pipelines up to 14 days old to catch workflow reruns on older pipelines
        let maxPipelineAge: TimeInterval = 14 * 24 * 60 * 60  // 14 days
        let maxWorkflowAge: TimeInterval = 24 * 60 * 60  // 24 hours for workflow display
        let workflowCutoffDate = Date().addingTimeInterval(-maxWorkflowAge)
        let maxBuilds = 10

        // Use a dictionary to track unique pipelines across all orgs
        // Key: projectSlug + branch
        var latestPipelinesMap: [String: Pipeline] = [:]

        for orgSlug in orgSlugs {
            do {
                // Fetch unique pipelines for this org (deduplicated by branch)
                let pipelines = try await fetchLatestPipelines(
                    orgSlug: orgSlug,
                    minAge: 0,
                    maxAge: maxPipelineAge
                )

                // Merge into global map, keeping the newest one if duplicates exist across orgs (unlikely but safe)
                for pipeline in pipelines {
                    let key = "\(pipeline.projectSlug)|\(pipeline.branch)"
                    if let existing = latestPipelinesMap[key] {
                        if pipeline.createdAt > existing.createdAt {
                            latestPipelinesMap[key] = pipeline
                        }
                    } else {
                        latestPipelinesMap[key] = pipeline
                    }
                }
            } catch {
                // Silently continue - pipelines from other orgs may still work
            }
        }

        // Sort by recency
        let sortedPipelines = latestPipelinesMap.values.sorted(by: { $0.createdAt > $1.createdAt })

        // 4. Fetch workflows for each pipeline and filter by recency
        return await fetchWorkflowsForPipelines(
            pipelines: sortedPipelines,
            workflowCutoffDate: workflowCutoffDate,
            maxBuilds: maxBuilds
        )
    }

    private func fetchWorkflowsForPipelines(
        pipelines: [Pipeline],
        workflowCutoffDate: Date,
        maxBuilds: Int
    ) async -> [Build] {
        struct BuildKey: Hashable {
            let projectSlug: String
            let branch: String
            let workflowName: String
        }

        var seenKeys = Set<BuildKey>()
        var runningBuilds: [Build] = []
        var otherBuilds: [Build] = []

        let excludeRegex: NSRegularExpression? = {
            guard let pattern = Settings.excludeWorkflowPattern, !pattern.isEmpty else { return nil }
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }()

        for pipeline in pipelines {
            // Stop early if we have enough builds and pipeline is old
            if otherBuilds.count >= maxBuilds && pipeline.createdAt < workflowCutoffDate {
                break
            }

            do {
                let workflows = try await fetchWorkflows(pipelineId: pipeline.id)

                for workflow in workflows where workflow.createdAt > workflowCutoffDate {
                    if let regex = excludeRegex {
                        let subject = "\(pipeline.projectName)/\(workflow.name)"
                        let range = NSRange(subject.startIndex..., in: subject)
                        if regex.firstMatch(in: subject, range: range) != nil {
                            continue
                        }
                    }
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

        // 5. Combine and sort: running builds first, then all sorted by newest workflow first
        return runningBuilds.sorted { $0.createdAt > $1.createdAt }
            + otherBuilds.sorted { $0.createdAt > $1.createdAt }
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
            status: status,
            webURL: pipeline.webURL,
            createdAt: workflow.createdAt,
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
            cachedToken = nil
            throw CircleCIError.unauthorized
        default:
            throw CircleCIError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    private func fetchLatestPipelines(
        orgSlug: String, minAge: TimeInterval, maxAge: TimeInterval
    ) async throws -> [Pipeline] {
        let encodedSlug = orgSlug.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? orgSlug
        let minCutoffDate = Date().addingTimeInterval(-minAge)  // Skip pipelines newer than this
        let maxCutoffDate = Date().addingTimeInterval(-maxAge)  // Stop at pipelines older than this

        // Key: projectSlug|branch
        var uniquePipelines: [String: Pipeline] = [:]
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

                if shouldStopPagination(
                    pipelines: pipelinesResponse.items,
                    maxCutoffDate: maxCutoffDate,
                    minCutoffDate: minCutoffDate,
                    uniquePipelines: &uniquePipelines
                ) {
                    return Array(uniquePipelines.values)
                }

                pageToken = pipelinesResponse.nextPageToken
                if pageToken == nil {
                    return Array(uniquePipelines.values)
                }
            case 401:
                cachedToken = nil
                throw CircleCIError.unauthorized
            case 429:
                throw CircleCIError.rateLimited
            default:
                throw CircleCIError.httpError(statusCode: httpResponse.statusCode)
            }
        }
    }

    private func shouldStopPagination(
        pipelines: [Pipeline],
        maxCutoffDate: Date,
        minCutoffDate: Date,
        uniquePipelines: inout [String: Pipeline]
    ) -> Bool {
        for pipeline in pipelines {
            if pipeline.createdAt < maxCutoffDate {
                return true
            }

            if pipeline.createdAt <= minCutoffDate {
                let key = "\(pipeline.projectSlug)|\(pipeline.branch)"
                if uniquePipelines[key] == nil {
                    uniquePipelines[key] = pipeline
                }
            }
        }
        return false
    }

    private func fetchWorkflows(pipelineId: String) async throws -> [Workflow] {
        let request = try makeRequest(endpoint: "/pipeline/\(pipelineId)/workflow")
        let (data, httpResponse) = try await performRequest(request)

        switch httpResponse.statusCode {
        case 200:
            let workflowsResponse = try decoder.decode(WorkflowsResponse.self, from: data)
            return workflowsResponse.items
        case 401:
            cachedToken = nil
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
