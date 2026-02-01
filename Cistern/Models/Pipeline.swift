import Foundation

struct PipelinesResponse: Codable {
    let items: [Pipeline]
    let nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken = "next_page_token"
    }
}

struct Pipeline: Codable {
    let id: String
    let projectSlug: String
    let number: Int
    let createdAt: Date
    let vcs: PipelineVCS?

    enum CodingKeys: String, CodingKey {
        case id
        case projectSlug = "project_slug"
        case number
        case createdAt = "created_at"
        case vcs
    }

    var branch: String {
        vcs?.branch ?? "unknown"
    }

    var projectName: String {
        // project_slug format: "gh/org/repo" or "bb/org/repo"
        let components = projectSlug.split(separator: "/")
        if components.count >= 3 {
            return "\(components[1])/\(components[2])"
        }
        return projectSlug
    }

    var webURL: String {
        // https://app.circleci.com/pipelines/gh/org/repo/123
        "https://app.circleci.com/pipelines/\(projectSlug)/\(number)"
    }
}

struct PipelineVCS: Codable {
    let branch: String?
}
