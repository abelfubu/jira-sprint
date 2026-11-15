import Foundation

struct SprintQuery: Codable, Equatable, Sendable {
    var label: String
    var jql: String
}

struct JiraConfig: Codable, Equatable, Sendable {
    var jql: String?
    var queries: [SprintQuery]? = nil
    var limit: Int?
    var site: String?
    var colors: [String: String]?
    var font: String?
    var shortcuts: [String: [String]]?
    var statuses: [String]? = nil

    static let standard = JiraConfig(
        jql: SprintConfig.defaultJQL,
        limit: 100,
        site: nil,
        colors: nil,
        font: nil,
        shortcuts: nil
    )

    var effectiveJQL: String {
        let value = jql?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : SprintConfig.defaultJQL
    }

    var effectiveQueries: [SprintQuery] {
        let configured = queries?.compactMap { query -> SprintQuery? in
            let label = query.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let jql = query.jql.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !jql.isEmpty else { return nil }
            return SprintQuery(label: label, jql: jql)
        } ?? []
        return configured.isEmpty
            ? [SprintQuery(label: "Current sprint", jql: effectiveJQL)]
            : configured
    }

    var effectiveLimit: Int {
        min(max(limit ?? 100, 1), 200)
    }

    var effectiveStatuses: [String] {
        SprintConfig.statusChoices(configured: statuses?.isEmpty == false ? statuses! : SprintConfig.defaultStatuses,
                                   available: [], current: "")
    }

    var effectiveSite: String? {
        guard let raw = site?.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: raw),
              let scheme = components.scheme, ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }
}

struct ConfigStore: Sendable {
    let url: URL

    static let standard = ConfigStore(
        url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/jira-sprint/config.json")
    )

    func load() throws -> JiraConfig {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(JiraConfig.standard).write(to: url, options: .atomic)
            return .standard
        }
        return try JSONDecoder().decode(JiraConfig.self, from: Data(contentsOf: url))
    }
}
