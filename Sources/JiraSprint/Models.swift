import Foundation

struct Story: Identifiable, Equatable, Sendable {
    let key: String
    let summary: String
    let status: String
    var statusColorName: String? = nil
    let assignee: String
    let issueType: String
    var issueTypeIconURL: URL? = nil
    var issueTypeAvatarID: Int? = nil
    var isSubtask: Bool = false
    var parentKey: String? = nil
    let priority: String?
    let browseURL: URL?

    var id: String { key }
}

struct SprintListItem: Identifiable, Equatable, Sendable {
    let story: Story
    let childCount: Int
    let depth: Int
    let isExpanded: Bool
    let showsDisclosure: Bool
    let isLoadingChildren: Bool

    var id: String { story.key }
}

enum SprintHierarchy {
    static func disclosureVisible(for item: SprintListItem) -> Bool {
        item.childCount > 0
    }

    static func scopedChildren(keys: [String], stories: [Story]) -> [Story] {
        let candidates = Dictionary(stories.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return keys.compactMap { key in
            guard seen.insert(key).inserted, let story = candidates[key], story.isSubtask else { return nil }
            return story
        }
    }

    static func rows(stories: [Story], expandedParents: Set<String>,
                     loadedParents: Set<String>, loadingParents: Set<String>) -> [SprintListItem] {
        var seen: Set<String> = []
        let unique = stories.filter { seen.insert($0.key).inserted }
        let possibleParents = Set(unique.filter { !$0.isSubtask }.map(\.key))
        var childrenByParent: [String: [Story]] = [:]
        var topLevel: [Story] = []

        for story in unique {
            // Sprint search cannot decode parent links. Unknown parents are not confirmed orphans;
            // keep those children hidden until their parent is expanded instead of looking expanded by default.
            if story.isSubtask, story.parentKey == nil { continue }
            if let parentKey = story.parentKey, parentKey != story.key, possibleParents.contains(parentKey) {
                childrenByParent[parentKey, default: []].append(story)
            } else {
                topLevel.append(story)
            }
        }

        return topLevel.flatMap { story -> [SprintListItem] in
            let children = childrenByParent[story.key] ?? []
            let expanded = expandedParents.contains(story.key)
            let parent = SprintListItem(
                story: story,
                childCount: children.count,
                depth: 0,
                isExpanded: expanded,
                showsDisclosure: !story.isSubtask && (!children.isEmpty || !loadedParents.contains(story.key)),
                isLoadingChildren: loadingParents.contains(story.key)
            )
            guard expanded else { return [parent] }
            return [parent] + children.map {
                SprintListItem(story: $0, childCount: 0, depth: 1, isExpanded: false,
                               showsDisclosure: false, isLoadingChildren: false)
            }
        }
    }
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

enum IssueTypeGlyph: Equatable, Sendable {
    case story, bug, task, subtask, epic, improvement, newFeature, generic

    init(iconURL: URL?, avatarID: Int? = nil, isSubtask: Bool = false) {
        if isSubtask { self = .subtask; return }
        switch avatarID {
        case 10315: self = .story; return
        case 10303: self = .bug; return
        case 10316: self = .subtask; return
        default: break
        }
        let asset = iconURL?.lastPathComponent.lowercased().replacingOccurrences(of: ".svg", with: "")
        switch asset {
        case "story": self = .story
        case "bug": self = .bug
        case "task": self = .task
        case "subtask", "sub-task", "subtask_alternate": self = .subtask
        case "epic": self = .epic
        case "improvement": self = .improvement
        case "newfeature", "new-feature": self = .newFeature
        default: self = .generic
        }
    }

    var systemImageName: String {
        switch self {
        case .story: "bookmark.fill"
        case .bug: "ladybug.fill"
        case .task: "checkmark.square.fill"
        case .subtask: "arrow.turn.down.right"
        case .epic: "bolt.fill"
        case .improvement: "arrow.up.square.fill"
        case .newFeature: "plus.square.fill"
        case .generic: "doc.text.fill"
        }
    }
}

enum SprintConfig {
    static let defaultJQL = "sprint in openSprints() ORDER BY rank ASC"
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
