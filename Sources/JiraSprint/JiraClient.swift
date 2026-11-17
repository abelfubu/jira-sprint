import Foundation

struct JiraClient: Sendable {
    enum ClientError: LocalizedError {
        case executableNotFound
        case failed(String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                return "Atlassian CLI (acli) was not found. Install and authenticate it, or set ACLI_PATH."
            case let .failed(message): return message
            case let .invalidResponse(message): return message
            }
        }
    }

    let executable: URL

    init() throws {
        guard let executable = Self.findExecutable() else { throw ClientError.executableNotFound }
        self.executable = executable
    }

    func fetchStories(jql: String, limit: Int, site: String?) throws -> [Story] {
        let output = try Self.run(executable: executable, arguments: Self.searchArguments(jql: jql, limit: limit))
        return try Self.decodeSearch(Data(output.utf8), site: site)
    }

    func perform(_ mutation: SprintMutation) throws {
        let arguments: [String]
        switch mutation {
        case let .assignToMe(key): arguments = Self.assignArguments(key: key)
        case let .transition(key, status): arguments = Self.transitionArguments(key: key, status: status)
        }
        _ = try Self.run(executable: executable, arguments: arguments)
    }

    static func searchArguments(jql: String, limit: Int) -> [String] {
        ["jira", "workitem", "search", "--jql", jql, "--limit", String(limit), "--json"]
    }

    static func assignArguments(key: String) -> [String] {
        ["jira", "workitem", "assign", "--key", key, "--assignee", "@me", "--yes", "--json"]
    }

    static func transitionArguments(key: String, status: String) -> [String] {
        ["jira", "workitem", "transition", "--key", key, "--status", status, "--yes", "--json"]
    }

    static func decodeSearch(_ data: Data, site: String? = nil) throws -> [Story] {
        let root = try JSONSerialization.jsonObject(with: data)
        let objects: [[String: Any]]
        if let array = root as? [[String: Any]] {
            objects = array
        } else if let dictionary = root as? [String: Any] {
            let containers = ["issues", "workitems", "results", "items"]
            guard let key = containers.first(where: { dictionary[$0] != nil }),
                  let array = dictionary[key] as? [[String: Any]] else {
                throw ClientError.invalidResponse("acli returned JSON without an issues array.")
            }
            objects = array
        } else {
            throw ClientError.invalidResponse("acli returned an unsupported JSON response.")
        }

        var seen: Set<String> = []
        return objects.compactMap { object in
            guard let key = object["key"] as? String, !key.isEmpty, seen.insert(key).inserted else { return nil }
            let fields = object["fields"] as? [String: Any] ?? object
            let summary = fields["summary"] as? String ?? "(no summary)"
            let status = name(in: fields["status"]) ?? "Unknown"
            let statusObject = fields["status"] as? [String: Any]
            let statusCategory = statusObject?["statusCategory"] as? [String: Any]
            let statusColorName = statusCategory?["colorName"] as? String
            let assignee = name(in: fields["assignee"]) ?? "Unassigned"
            let issueType = name(in: fields["issuetype"]) ?? "Story"
            let priority = name(in: fields["priority"])
            let browseURL = browseURL(for: object, key: key, site: site)
            return Story(key: key, summary: summary, status: status, statusColorName: statusColorName, assignee: assignee,
                         issueType: issueType, priority: priority, browseURL: browseURL)
        }
    }

    private static func name(in value: Any?) -> String? {
        if let name = value as? String { return name }
        let object = value as? [String: Any]
        return object?["displayName"] as? String ?? object?["name"] as? String
    }

    private static func browseURL(for object: [String: Any], key: String, site: String?) -> URL? {
        for field in ["browseURL", "url"] {
            if let value = object[field] as? String, let url = URL(string: value), url.host != nil {
                return url
            }
        }
        if let value = object["self"] as? String, let components = URLComponents(string: value),
           let scheme = components.scheme, let host = components.host {
            var browse = URLComponents()
            browse.scheme = scheme
            browse.host = host
            browse.port = components.port
            browse.path = "/browse/\(key)"
            return browse.url
        }
        guard let site, !site.isEmpty else { return nil }
        return URL(string: site)?.appendingPathComponent("browse").appendingPathComponent(key)
    }

    private static func findExecutable() -> URL? {
        var candidates: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["ACLI_PATH"] { candidates.append(explicit) }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/acli" })
        }
        candidates += ["/opt/homebrew/bin/acli", "/usr/local/bin/acli", "/usr/bin/acli"]
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/acli").path)
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private static func run(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = ProcessOutput()
        let errors = ProcessOutput()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async {
            output.store(stdout.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global().async {
            errors.store(stderr.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()
        let outputData = output.load()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.load(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClientError.failed(message.isEmpty ? "acli exited with status \(process.terminationStatus)." : message)
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}

private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
