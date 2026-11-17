import AppKit
import Foundation
import SwiftUI

#if DEBUG
enum SelfTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    static func run() {
        do {
            try testConfig()
            try testConfigStore()
            try testQueries()
            try testStatuses()
            try testDecoding()
            try testIssueTypeGlyphs()
            try testHierarchy()
            try testArrayDecoding()
            try testInvalidResponse()
            try testArguments()
            try testThemeAndShortcuts()
            print("Self-tests passed")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Self-test failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func testConfig() throws {
        let json = ##"{"jql":"project = NOM AND sprint in openSprints()","limit":500,"site":"https://example.atlassian.net/","colors":{"accent":"#2F81F7"},"shortcuts":{"nextStory":["n"]}}"##
        let config = try JSONDecoder().decode(JiraConfig.self, from: Data(json.utf8))
        try expect(config.effectiveJQL == "project = NOM AND sprint in openSprints()", "Custom JQL")
        try expect(config.effectiveLimit == 200, "Result limit is capped")
        try expect(config.effectiveSite == "https://example.atlassian.net", "Site normalization")
        try expect(!SprintConfig.defaultJQL.contains("issuetype"), "Default sprint includes every work-item type")
        try expect(JiraConfig(jql: " ", limit: 0, site: "not a URL", colors: nil, font: nil, shortcuts: nil).effectiveJQL == SprintConfig.defaultJQL,
                   "Blank JQL restores the default")
        try expect(JiraConfig(jql: nil, limit: 0, site: nil, colors: nil, font: nil, shortcuts: nil).effectiveLimit == 1,
                   "Result limit has a positive lower bound")
    }

    private static func testConfigStore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.json")
        let config = try ConfigStore(url: url).load()
        try expect(config.effectiveJQL == SprintConfig.defaultJQL, "Default config values")
        try expect(FileManager.default.fileExists(atPath: url.path), "Default config creation")
    }

    private static func testQueries() throws {
        let json = #"{"jql":"legacy = true","queries":[{"label":" Sprint ","jql":" sprint in openSprints() "},{"label":"Mine","jql":"assignee = currentUser()"},{"label":" ","jql":"invalid"}]}"#
        let config = try JSONDecoder().decode(JiraConfig.self, from: Data(json.utf8))
        try expect(config.effectiveQueries.count == 2, "Configured query tabs")
        try expect(config.effectiveQueries[0].label == "Sprint" && config.effectiveQueries[0].jql == "sprint in openSprints()",
                   "Query labels and JQL are trimmed")
        let legacy = JiraConfig(jql: "legacy = true", limit: nil, site: nil, colors: nil, font: nil, shortcuts: nil)
        try expect(legacy.effectiveQueries == [SprintQuery(label: "Current sprint", jql: "legacy = true")],
                   "Legacy single-query config remains compatible")
    }

    private static func testStatuses() throws {
        let config = JiraConfig(jql: nil, limit: nil, site: nil, colors: nil, font: nil, shortcuts: nil,
                                statuses: [" To Do ", "Waiting for review", "to do", ""])
        try expect(config.effectiveStatuses == ["To Do", "Waiting for review"], "Status config trims and deduplicates")
        try expect(JiraConfig.standard.effectiveStatuses == SprintConfig.defaultStatuses, "Default status choices")
        let choices = SprintConfig.statusChoices(configured: ["To Do", "In Progress"],
                                                 available: ["Blocked", "to do"], current: "In Progress")
        try expect(choices == ["To Do", "Blocked"], "Status picker excludes current and duplicate cached statuses")
    }

    private static func testDecoding() throws {
        let json = """
        {"issues":[{
          "key":"NOM-123","self":"https://example.atlassian.net/rest/api/3/issue/123",
          "fields":{
            "summary":"Retry rejected invoices","status":{"name":"In Progress"},
            "assignee":{"displayName":"Abel"},"issuetype":{
              "name":"Story","iconUrl":"https://example.atlassian.net/images/icons/issuetypes/story.svg",
              "avatarId":10315,"subtask":false
            },
            "priority":{"name":"High"}
          }
        },{
          "key":"ITA-556","fields":{
            "summary":"Draft invoice status","status":{
              "name":"En curso","statusCategory":{"key":"indeterminate","colorName":"yellow"}
            },
            "assignee":null,"issuetype":{
              "name":"Error","iconUrl":"https://example.atlassian.net/images/icons/issuetypes/bug.svg",
              "avatarId":10303,"subtask":false
            }
          }
        },{
          "key":"NOM-123","fields":{"summary":"Duplicate"}
        }]}
        """
        let stories = try JiraClient.decodeSearch(Data(json.utf8))
        guard let story = stories.first else { throw Failure(description: "Missing decoded story") }
        try expect(stories.count == 2 && story.id == "NOM-123", "Stable identity and deduplication")
        try expect(story.summary == "Retry rejected invoices" && story.status == "In Progress", "Summary and status")
        try expect(story.assignee == "Abel" && story.issueType == "Story" && story.priority == "High", "People and type metadata")
        try expect(stories[1].key == "ITA-556" && stories[1].issueType == "Error" && stories[1].assignee == "Unassigned",
                   "Mixed sprint work-item types remain visible")
        try expect(stories[1].statusColorName == "yellow", "Jira status category color is preserved")
        try expect(stories[0].issueTypeIconURL?.lastPathComponent == "story.svg" &&
                   stories[1].issueTypeIconURL?.lastPathComponent == "bug.svg", "Jira issue-type icon URLs are preserved")
        try expect(stories[0].issueTypeAvatarID == 10315 && stories[1].issueTypeAvatarID == 10303,
                   "Jira universal avatar IDs are preserved")
        try expect(story.browseURL?.absoluteString == "https://example.atlassian.net/browse/NOM-123", "Browse URL derived from API self URL")
        let configuredSite = try JiraClient.decodeSearch(Data(json.utf8), site: "https://nomoapp.atlassian.net")
        try expect(configuredSite.first?.browseURL?.absoluteString == "https://nomoapp.atlassian.net/browse/NOM-123",
                   "Configured Jira site takes precedence over internal API hosts")
    }

    private static func testHierarchy() throws {
        let childJSON = #"{"issues":[{"key":"C-1","fields":{"summary":"Child","parent":{"key":"P-1"},"issuetype":{"name":"Sub-task","subtask":true}}}]}"#
        let child = try JiraClient.decodeSearch(Data(childJSON.utf8))[0]
        try expect(child.parentKey == "P-1" && child.isSubtask, "Jira parent and subtask metadata are decoded")
        let keys = try JiraClient.decodeSubtaskKeys(Data(#"{"fields":{"subtasks":[{"key":"C-1"},{"key":"C-2"}]}}"#.utf8))
        try expect(keys == ["C-1", "C-2"], "Parent view decodes child relationships")

        func story(_ key: String, subtask: Bool = false) -> Story {
            Story(key: key, summary: key, status: "To Do", assignee: "Unassigned",
                  issueType: subtask ? "Sub-task" : "Story", isSubtask: subtask, priority: nil, browseURL: nil)
        }
        let parent = story("P-1")
        let emptyParent = story("P-2")
        var orphan = story("O-1", subtask: true)
        orphan.parentKey = "OUT-1"
        let source = [parent, child, emptyParent, orphan, child]
        let scoped = SprintHierarchy.scopedChildren(keys: ["C-1", "OUTSIDE-1", "P-2", "C-1"], stories: source)
        try expect(scoped.map(\.key) == ["C-1"],
                   "Expansion reuses only in-scope subtasks and ignores outside or non-subtask keys")
        let collapsed = SprintHierarchy.rows(stories: source, expandedParents: [],
                                             loadedParents: ["P-1", "P-2"], loadingParents: [])
        try expect(collapsed.map(\.id) == ["P-1", "P-2", "O-1"], "Subtasks are collapsed by default and duplicates are removed")
        try expect(collapsed[0].childCount == 1 && collapsed[0].showsDisclosure, "Parent exposes its subtask count")
        try expect(!collapsed[1].showsDisclosure, "Loaded parents without children lose their disclosure control")
        try expect(collapsed[2].depth == 0 && !collapsed[2].showsDisclosure, "Orphaned subtasks remain visible at top level")
        var unresolved = child
        unresolved.parentKey = nil
        let unresolvedRows = SprintHierarchy.rows(stories: [parent, unresolved], expandedParents: [],
                                                  loadedParents: [], loadingParents: [])
        try expect(unresolvedRows.map(\.id) == ["P-1"], "Unresolved sprint subtasks do not appear expanded by default")
        let uncheckedEmpty = SprintHierarchy.rows(stories: [story("EMPTY-1")], expandedParents: [],
                                                  loadedParents: [], loadingParents: [])
        let checkedEmpty = SprintHierarchy.rows(stories: [story("EMPTY-1")], expandedParents: [],
                                                loadedParents: ["EMPTY-1"], loadingParents: [])
        try expect(uncheckedEmpty[0].showsDisclosure, "Unchecked parents can be expanded")
        try expect(!SprintHierarchy.disclosureVisible(for: uncheckedEmpty[0], selected: false),
                   "Unchecked unselected rows do not clutter the list with chevrons")
        try expect(SprintHierarchy.disclosureVisible(for: uncheckedEmpty[0], selected: true),
                   "Selected unchecked rows expose their disclosure control")
        try expect(SprintHierarchy.disclosureVisible(for: collapsed[0], selected: false),
                   "Confirmed parents always expose their disclosure control")
        try expect(!checkedEmpty[0].showsDisclosure && checkedEmpty[0].childCount == 0,
                   "Checked parents with zero subtasks hide their disclosure chevron")
        try expect(!SprintHierarchy.disclosureVisible(for: checkedEmpty[0], selected: true),
                   "Selection does not resurrect a checked-empty chevron")

        let expanded = SprintHierarchy.rows(stories: source, expandedParents: ["P-1"],
                                            loadedParents: ["P-1", "P-2"], loadingParents: [])
        try expect(expanded.map(\.id) == ["P-1", "C-1", "P-2", "O-1"], "Expanding inserts children below their parent")
        try expect(expanded[1].depth == 1 && expanded[1].story.parentKey == "P-1", "Child rows retain indentation and parent identity")
        let unknown = SprintHierarchy.rows(stories: [parent], expandedParents: [], loadedParents: [], loadingParents: ["P-1"])
        try expect(unknown[0].showsDisclosure && unknown[0].isLoadingChildren, "Unknown parents support lazy loading")
    }

    private static func testIssueTypeGlyphs() throws {
        func glyph(_ asset: String) -> IssueTypeGlyph {
            IssueTypeGlyph(iconURL: URL(string: "https://example.atlassian.net/images/icons/issuetypes/\(asset).svg"))
        }
        try expect(glyph("story") == .story && glyph("bug") == .bug && glyph("task") == .task,
                   "Standard Jira story, bug, and task icon assets")
        try expect(glyph("subtask") == .subtask && glyph("epic") == .epic,
                   "Standard Jira subtask and epic icon assets")
        try expect(glyph("improvement") == .improvement && glyph("newfeature") == .newFeature,
                   "Standard Jira improvement and new-feature icon assets")
        try expect(glyph("10002") == .generic && IssueTypeGlyph(iconURL: nil) == .generic,
                   "Custom or missing Jira icons retain the generic fallback")
        try expect(IssueTypeGlyph(iconURL: nil, avatarID: 10315) == .story &&
                   IssueTypeGlyph(iconURL: nil, avatarID: 10303) == .bug &&
                   IssueTypeGlyph(iconURL: nil, avatarID: 10316) == .subtask,
                   "Jira Cloud universal avatar IDs select icons without localized names")
        try expect(IssueTypeGlyph(iconURL: nil, avatarID: 99999, isSubtask: true) == .subtask,
                   "Jira subtask metadata handles custom avatar IDs")
    }

    private static func testArrayDecoding() throws {
        let json = #"[{"key":"NOM-124","fields":{"summary":"Flat response","assignee":null}}]"#
        let stories = try JiraClient.decodeSearch(Data(json.utf8), site: "https://example.atlassian.net")
        try expect(stories.count == 1 && stories[0].assignee == "Unassigned", "Array response and unassigned fallback")
        try expect(stories[0].browseURL?.absoluteString == "https://example.atlassian.net/browse/NOM-124", "Configured site fallback")
        let empty = try JiraClient.decodeSearch(Data(#"{"workitems":[]}"#.utf8))
        try expect(empty.isEmpty, "Work-item response envelope")
    }

    private static func testInvalidResponse() throws {
        do {
            _ = try JiraClient.decodeSearch(Data(#"{"error":"unauthorized"}"#.utf8))
            throw Failure(description: "Malformed response should fail")
        } catch JiraClient.ClientError.invalidResponse {
            // Expected.
        }
    }

    private static func testArguments() throws {
        let arguments = JiraClient.searchArguments(jql: "sprint in openSprints()", limit: 100)
        try expect(arguments == ["jira", "workitem", "search", "--jql", "sprint in openSprints()", "--limit", "100", "--json"],
                   "acli search invocation")
        try expect(JiraClient.assignArguments(key: "NOM-123") ==
                   ["jira", "workitem", "assign", "--key", "NOM-123", "--assignee", "@me", "--yes", "--json"],
                   "acli self-assignment invocation")
        try expect(JiraClient.transitionArguments(key: "NOM-123", status: "In Review") ==
                   ["jira", "workitem", "transition", "--key", "NOM-123", "--status", "In Review", "--yes", "--json"],
                   "acli transition invocation")
    }

    private static func testThemeAndShortcuts() throws {
        try expect(Color(sprintHex: "#0D1117") != nil, "RGB color parsing")
        try expect(Color(sprintHex: "#FFFFFF80") != nil, "RGBA color parsing")
        try expect(Color(sprintHex: "not-a-color") == nil, "Invalid color rejection")
        try expect(Theme.statusColor("En curso", jiraColorName: "yellow") == Theme.accent,
                   "Jira in-progress category uses blue")
        try expect(Theme.statusColor("En entorno DEV", jiraColorName: "green") == Theme.green,
                   "Jira done category uses green")
        try expect(Theme.statusColor("Tareas por hacer", jiraColorName: "blue-gray") == Theme.muted,
                   "Jira to-do category uses gray")
        Theme.applyFont("Geist Mono")
        try expect(Theme.fontFamily == "Geist Mono", "Custom font family")
        Theme.applyFont(" ")
        try expect(Theme.fontFamily == "JetBrains Mono", "Blank font restores the default")
        let upper = ShortcutBinding.parse("K")
        try expect(upper?.key == "k" && upper?.shift == true, "Uppercase shortcut parsing")
        let command = ShortcutBinding.parse("cmd-shift-o")
        try expect(command?.key == "o" && command?.command == true && command?.shift == true, "Modified shortcut parsing")
        let custom = ShortcutMap(overrides: ["nextStory": ["n"]])
        try expect(custom.display(for: .nextStory) == "n" && custom.display(for: .previousStory) == "k",
                   "Shortcut overrides preserve unspecified defaults")
        try expect(custom.display(for: .nextQuery) == "l" && custom.display(for: .previousQuery) == "h",
                   "Query navigation defaults")
        try expect(custom.display(for: .tab1) == "1" && custom.display(for: .tab9) == "9",
                   "Numbered query tab defaults")
        try expect(custom.display(for: .actions) == "a" && custom.display(for: .openSelected) == "↵",
                   "Action menu shortcut preserves browser opening defaults")
        try expect(custom.display(for: .fold) == "f", "Subtask folding shortcut")
    }
}
#endif
