import Foundation

struct Organization: Codable {
    let id: String?
    let name: String
    let vcsType: String
    let slug: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case vcsType = "vcs_type"
        case slug
    }
}
