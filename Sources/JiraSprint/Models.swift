import Foundation

struct Story: Identifiable, Equatable, Sendable {
    let key: String
    let summary: String
    let status: String
    let assignee: String
    let issueType: String
    let priority: String?
    let browseURL: URL?

    var id: String { key }
}

enum SprintForm: Equatable {
    case actions
    case status
}

enum SprintAction: CaseIterable {
    case assignToMe
    case changeStatus

    var title: String {
        switch self {
        case .assignToMe: "Assign to me"
        case .changeStatus: "Change status"
        }
    }

    var symbol: String {
        switch self {
        case .assignToMe: "person.crop.circle.badge.checkmark"
        case .changeStatus: "arrow.right.circle"
        }
    }
}

enum SprintMutation: Equatable, Sendable {
    case assignToMe(key: String)
    case transition(key: String, status: String)
}

enum SprintConfig {
    static let defaultJQL = "sprint in openSprints() AND issuetype = Story ORDER BY rank ASC"
    static let defaultStatuses = ["To Do", "In Progress", "In Review", "Blocked", "Done"]

    static func statusChoices(configured: [String], available: [String], current: String) -> [String] {
        var seen: Set<String> = []
        return (configured + available).compactMap { value in
            let status = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = status.lowercased()
            guard !status.isEmpty, identity != current.lowercased(), seen.insert(identity).inserted else { return nil }
            return status
        }
    }
}
