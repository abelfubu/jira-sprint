import AppKit
import Foundation

@MainActor
final class SprintStore: ObservableObject {
    @Published private(set) var rows: [SprintListItem] = []
    @Published private(set) var selectedStoryKey: String?
    @Published private(set) var queries = [SprintQuery(label: "Current sprint", jql: SprintConfig.defaultJQL)]
    @Published private(set) var selectedQueryIndex = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var shortcuts = ShortcutMap.standard
    @Published private(set) var activeForm: SprintForm?
    @Published private(set) var actionStory: Story?
    @Published private(set) var formSelection = 0
    @Published private(set) var isPerformingAction = false

    let configStore: ConfigStore
    private var autoTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var configuredStatuses = SprintConfig.defaultStatuses
    private var resultsByQuery: [Int: [Story]] = [:]
    private var childrenByQuery: [Int: [String: [Story]]] = [:]
    private var expandedByQuery: [Int: Set<String>] = [:]
    private var loadedParentsByQuery: [Int: Set<String>] = [:]
    private var loadingParentsByQuery: [Int: Set<String>] = [:]
    private var pendingParentsByQuery: [Int: [String]] = [:]
    private var childTasks: [String: Task<Void, Never>] = [:]
    private var childTaskTokens: [String: UUID] = [:]
    private var requestLimit = 100
    private var jiraSite: String?
    private var loadedQueries: Set<Int> = []
    private var selectionByQuery: [Int: String] = [:]
    private var updatedByQuery: [Int: Date] = [:]

    #if DEBUG
    private var fixtureMode: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["JIRA_SPRINT_FIXTURE"] == "1"
            || environment["JIRA_SPRINT_KEY_SMOKE"] == "1"
            || environment["JIRA_SPRINT_FORM_SMOKE"] == "1"
            || (environment["JIRA_SPRINT_SCREENSHOT"] != nil && environment["JIRA_SPRINT_LIVE"] != "1")
    }
    #endif

    init(configStore: ConfigStore = .standard) {
        self.configStore = configStore
    }

    deinit {
        autoTask?.cancel()
        refreshTask?.cancel()
    }

    var jql: String { selectedQuery.jql }
    var selectedQuery: SprintQuery { queries[selectedQueryIndex] }
    var stories: [Story] { rows.map(\.story) }
    var selectedStory: Story? { stories.first { $0.key == selectedStoryKey } }
    var totalStoryCount: Int { Set(allStories.map(\.key)).count }
    private var allStories: [Story] {
        let children = childrenByQuery[selectedQueryIndex]?.values.flatMap { $0 } ?? []
        return attachKnownParents(to: (resultsByQuery[selectedQueryIndex] ?? []) + children)
    }
    private var allCachedStories: [Story] {
        let base = resultsByQuery.values.flatMap { $0 }
        let children = childrenByQuery.values.flatMap { $0.values.flatMap { $0 } }
        return attachKnownParents(to: base + children)
    }

    func start() {
        #if DEBUG
        if fixtureMode {
            loadFixtures()
            return
        }
        #endif
        refresh()
        guard autoTask == nil else { return }
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        autoTask?.cancel()
        autoTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        childTasks.values.forEach { $0.cancel() }
        childTasks.removeAll()
        childTaskTokens.removeAll()
        pendingParentsByQuery.removeAll()
    }

    func refresh(preservingNotice: Bool = false) {
        guard refreshTask == nil else { return }
        if !preservingNotice { notice = nil }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            var requestedIndex: Int?
            do {
                let config = try self.configStore.load()
                Theme.apply(config.colors ?? [:])
                Theme.applyFont(config.font)
                self.shortcuts = ShortcutMap(overrides: config.shortcuts)
                self.configuredStatuses = config.effectiveStatuses
                self.applyQueries(config.effectiveQueries)
                let queryIndex = self.selectedQueryIndex
                requestedIndex = queryIndex
                let query = self.selectedQuery
                let limit = config.effectiveLimit
                let site = config.effectiveSite
                self.requestLimit = limit
                self.jiraSite = site
                let stories = try await Task.detached(priority: .userInitiated) {
                    let client = try JiraClient()
                    return try client.fetchStories(jql: query.jql, limit: limit, site: site)
                }.value
                self.resultsByQuery[queryIndex] = stories
                self.loadedQueries.insert(queryIndex)
                self.updatedByQuery[queryIndex] = Date()
                if self.selectedQueryIndex == queryIndex {
                    self.rebuildRows()
                    self.errorMessage = nil
                    self.lastUpdated = self.updatedByQuery[queryIndex]
                }

            } catch {
                if requestedIndex == nil || requestedIndex == self.selectedQueryIndex {
                    self.errorMessage = error.localizedDescription
                    self.ensureSelection()
                }
            }
            self.isRefreshing = false
            self.refreshTask = nil
            if let requestedIndex, self.selectedQueryIndex != requestedIndex,
               !self.loadedQueries.contains(self.selectedQueryIndex) {
                self.refresh()
            }
        }
    }

    func selectQuery(_ index: Int) {
        guard queries.indices.contains(index), index != selectedQueryIndex else { return }
        selectionByQuery[selectedQueryIndex] = selectedStoryKey
        selectedQueryIndex = index
        selectedStoryKey = selectionByQuery[index]
        lastUpdated = updatedByQuery[index]
        errorMessage = nil
        notice = nil
        rebuildRows()
        if !loadedQueries.contains(index), refreshTask == nil { refresh() }
    }

    func selectStory(_ story: Story) {
        guard stories.contains(where: { $0.key == story.key }) else { return }
        updateSelection(story.key)
        notice = nil
    }

    func moveSelection(_ delta: Int) {
        guard !stories.isEmpty else { return }
        guard let selectedStoryKey, let index = stories.firstIndex(where: { $0.key == selectedStoryKey }) else {
            updateSelection(delta < 0 ? stories.last?.key : stories.first?.key)
            return
        }
        let next = min(max(index + delta, 0), stories.count - 1)
        updateSelection(stories[next].key)
    }

    func performShortcut(_ action: ShortcutAction) {
        switch action {
        case .nextStory: moveSelection(1)
        case .previousStory: moveSelection(-1)
        case .nextQuery: selectQuery((selectedQueryIndex + 1) % queries.count)
        case .previousQuery: selectQuery((selectedQueryIndex - 1 + queries.count) % queries.count)
        case .tab1: selectQuery(0)
        case .tab2: selectQuery(1)
        case .tab3: selectQuery(2)
        case .tab4: selectQuery(3)
        case .tab5: selectQuery(4)
        case .tab6: selectQuery(5)
        case .tab7: selectQuery(6)
        case .tab8: selectQuery(7)
        case .tab9: selectQuery(8)
        case .openSelected: openSelected()
        case .fold: toggleFold()
        case .actions: showActions()
        case .cancel:
            if activeForm != nil {
                dismissForm()
            } else {
                updateSelection(nil)
                notice = nil
            }
        case .refresh: refresh()
        case .copy: copySelected()
        case .openConfig: openConfig()
        case .closeWindow: NSApp.keyWindow?.close()
        }
    }

    func openSelected() {
        if activeForm != nil {
            submitForm()
            return
        }
        guard let story = selectedStory else { return }
        guard let url = story.browseURL else {
            notice = "Set site in ~/.config/jira-sprint/config.json to open \(story.key)."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copySelected() {
        guard let story = selectedStory else { return }
        let value = story.browseURL?.absoluteString ?? story.key
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        notice = "Copied \(story.key)"
    }

    var statusChoices: [String] {
        guard let story = actionStory ?? selectedStory else { return [] }
        return SprintConfig.statusChoices(configured: configuredStatuses,
                                          available: allCachedStories.map(\.status),
                                          current: story.status)
    }

    func jiraColorName(for status: String) -> String? {
        allCachedStories
            .first { $0.status.caseInsensitiveCompare(status) == .orderedSame }?.statusColorName
    }

    var formItemCount: Int {
        switch activeForm {
        case .actions: SprintAction.allCases.count
        case .status: statusChoices.count
        case nil: 0
        }
    }

    func showActions() {
        guard let story = selectedStory, !isPerformingAction else { return }
        actionStory = story
        formSelection = 0
        activeForm = .actions
        errorMessage = nil
        notice = nil
    }

    func showStatusChoices() {
        if activeForm != .actions || actionStory == nil { actionStory = selectedStory }
        guard actionStory != nil, !isPerformingAction else { return }
        formSelection = 0
        activeForm = .status
        errorMessage = nil
        notice = nil
    }

    func assignSelectedToMe() {
        guard let story = actionStory else { return }
        perform(.assignToMe(key: story.key))
    }

    func moveFormSelection(_ delta: Int) {
        guard formItemCount > 0, !isPerformingAction else { return }
        formSelection = (formSelection + delta + formItemCount) % formItemCount
    }

    func selectFormItem(_ index: Int) {
        guard index >= 0, index < formItemCount, !isPerformingAction else { return }
        formSelection = index
        submitForm()
    }

    func submitForm() {
        guard !isPerformingAction else { return }
        switch activeForm {
        case .actions:
            guard SprintAction.allCases.indices.contains(formSelection) else { return }
            switch SprintAction.allCases[formSelection] {
            case .assignToMe: assignSelectedToMe()
            case .changeStatus: showStatusChoices()
            }
        case .status:
            guard let story = actionStory, statusChoices.indices.contains(formSelection) else { return }
            perform(.transition(key: story.key, status: statusChoices[formSelection]))
        case nil:
            break
        }
    }

    func dismissForm() {
        guard !isPerformingAction else { return }
        activeForm = nil
        actionStory = nil
        formSelection = 0
    }

    private func perform(_ mutation: SprintMutation) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        errorMessage = nil
        notice = nil
        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                #if DEBUG
                let environment = ProcessInfo.processInfo.environment
                let dryRun = environment["JIRA_SPRINT_DRY_RUN"] == "1"
                    || environment["JIRA_SPRINT_FORM_SMOKE"] == "1"
                if dryRun {
                    switch mutation {
                    case let .assignToMe(key): self.notice = "Dry run: would assign \(key) to @me"
                    case let .transition(key, status): self.notice = "Dry run: would transition \(key) to \(status)"
                    }
                    self.activeForm = nil
                    self.actionStory = nil
                    self.formSelection = 0
                    self.isPerformingAction = false
                    return
                }
                #endif

                try await Task.detached(priority: .userInitiated) {
                    try JiraClient().perform(mutation)
                }.value
                switch mutation {
                case let .assignToMe(key): self.notice = "Assigned \(key) to you"
                case let .transition(key, status): self.notice = "Transitioned \(key) to \(status)"
                }
                self.activeForm = nil
                self.actionStory = nil
                self.formSelection = 0
                self.isPerformingAction = false
                self.refresh(preservingNotice: true)
            } catch {
                self.errorMessage = error.localizedDescription
                self.isPerformingAction = false
            }
        }
    }

    func prepareChildren(for story: Story) {
        guard !story.isSubtask else { return }
        #if DEBUG
        if fixtureMode { return }
        #endif
        let queryIndex = selectedQueryIndex
        guard loadedParentsByQuery[queryIndex]?.contains(story.key) != true else { return }
        var pending = pendingParentsByQuery[queryIndex] ?? []
        if !pending.contains(story.key) { pending.append(story.key) }
        pendingParentsByQuery[queryIndex] = pending
        drainChildQueue(queryIndex: queryIndex)
    }

    private func drainChildQueue(queryIndex: Int) {
        guard queries.indices.contains(queryIndex) else { return }
        var pending = pendingParentsByQuery[queryIndex] ?? []
        pending.removeAll { loadedParentsByQuery[queryIndex]?.contains($0) == true }
        pendingParentsByQuery[queryIndex] = pending
        guard !pending.isEmpty else { return }
        let prefix = "\(queryIndex):"
        let activeCount = childTasks.keys.filter { $0.hasPrefix(prefix) }.count
        guard activeCount < 3 else { return }
        let parentKey = pending.removeFirst()
        pendingParentsByQuery[queryIndex] = pending
        loadChildren(parentKey: parentKey, queryIndex: queryIndex)
    }

    func toggleFold(_ story: Story? = nil) {
        guard let target = story ?? selectedStory else { return }
        let queryIndex = selectedQueryIndex
        var expanded = expandedByQuery[queryIndex] ?? []

        if let parentKey = target.parentKey,
           rows.contains(where: { $0.story.key == parentKey && $0.childCount > 0 }) {
            expanded.remove(parentKey)
            expandedByQuery[queryIndex] = expanded
            updateSelection(parentKey)
            rebuildRows()
            return
        }

        guard let row = rows.first(where: { $0.story.key == target.key }),
              row.showsDisclosure || row.childCount > 0 else { return }
        let expanding = !expanded.contains(target.key)
        if expanding { expanded.insert(target.key) } else { expanded.remove(target.key) }
        expandedByQuery[queryIndex] = expanded
        updateSelection(target.key)
        rebuildRows()
        #if DEBUG
        let force = !fixtureMode
        #else
        let force = true
        #endif
        if expanding { loadChildren(parentKey: target.key, queryIndex: queryIndex, force: force) }
    }

    private func loadChildren(parentKey: String, queryIndex: Int, force: Bool = false) {
        guard queries.indices.contains(queryIndex), childTasks[childTaskID(queryIndex: queryIndex, parentKey: parentKey)] == nil else { return }
        if !force, loadedParentsByQuery[queryIndex]?.contains(parentKey) == true { return }
        let query = queries[queryIndex]
        let id = childTaskID(queryIndex: queryIndex, parentKey: parentKey)
        let token = UUID()
        childTaskTokens[id] = token
        loadingParentsByQuery[queryIndex, default: []].insert(parentKey)
        if selectedQueryIndex == queryIndex { rebuildRows() }
        pendingParentsByQuery[queryIndex]?.removeAll { $0 == parentKey }
        childTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.childTaskTokens[id] == token {
                    self.loadingParentsByQuery[queryIndex]?.remove(parentKey)
                    self.childTasks[id] = nil
                    self.childTaskTokens[id] = nil
                    self.drainChildQueue(queryIndex: queryIndex)
                }
            }
            do {
                let keys = try await Task.detached(priority: .userInitiated) {
                    try JiraClient().fetchSubtaskKeys(parentKey: parentKey)
                }.value
                guard !Task.isCancelled, self.childTaskTokens[id] == token,
                      self.queries.indices.contains(queryIndex), self.queries[queryIndex] == query else { return }
                self.loadingParentsByQuery[queryIndex]?.remove(parentKey)
                let candidates = self.resultsByQuery[queryIndex] ?? []
                let children = SprintHierarchy.scopedChildren(keys: keys, stories: candidates)
                self.childrenByQuery[queryIndex, default: [:]][parentKey] = children
                self.loadedParentsByQuery[queryIndex, default: []].insert(parentKey)
                if children.isEmpty { self.expandedByQuery[queryIndex]?.remove(parentKey) }
                if self.selectedQueryIndex == queryIndex {
                    if self.errorMessage?.hasPrefix("Could not load subtasks for \(parentKey):") == true {
                        self.errorMessage = nil
                    }
                    self.rebuildRows()
                }
            } catch {
                guard self.childTaskTokens[id] == token,
                      self.queries.indices.contains(queryIndex), self.queries[queryIndex] == query else { return }
                self.loadingParentsByQuery[queryIndex]?.remove(parentKey)
                if self.selectedQueryIndex == queryIndex {
                    self.errorMessage = "Could not load subtasks for \(parentKey): \(error.localizedDescription)"
                    self.rebuildRows()
                }
            }
        }
    }

    private func childTaskID(queryIndex: Int, parentKey: String) -> String {
        "\(queryIndex):\(parentKey)"
    }

    private func attachKnownParents(to stories: [Story]) -> [Story] {
        var parentByChild: [String: String] = [:]
        for (parentKey, children) in childrenByQuery.values.flatMap({ $0 }) {
            for child in children { parentByChild[child.key] = parentKey }
        }
        return stories.map { story in
            guard story.parentKey == nil, let parentKey = parentByChild[story.key] else { return story }
            var copy = story
            copy.parentKey = parentKey
            return copy
        }
    }

    private func rebuildRows() {
        rows = SprintHierarchy.rows(stories: allStories,
                                    expandedParents: expandedByQuery[selectedQueryIndex] ?? [],
                                    loadedParents: loadedParentsByQuery[selectedQueryIndex] ?? [],
                                    loadingParents: loadingParentsByQuery[selectedQueryIndex] ?? [])
        ensureSelection()
    }

    private func applyQueries(_ newQueries: [SprintQuery]) {
        guard newQueries != queries else { return }
        queries = newQueries
        resultsByQuery.removeAll()
        childrenByQuery.removeAll()
        expandedByQuery.removeAll()
        loadedParentsByQuery.removeAll()
        loadingParentsByQuery.removeAll()
        childTasks.values.forEach { $0.cancel() }
        childTasks.removeAll()
        childTaskTokens.removeAll()
        pendingParentsByQuery.removeAll()
        loadedQueries.removeAll()
        selectionByQuery.removeAll()
        updatedByQuery.removeAll()
        selectedQueryIndex = 0
        rows = []
        selectedStoryKey = nil
        lastUpdated = nil
    }

    private func openConfig() {
        do {
            _ = try configStore.load()
            NSWorkspace.shared.open(configStore.url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateSelection(_ key: String?) {
        selectedStoryKey = key
        selectionByQuery[selectedQueryIndex] = key
    }

    private func ensureSelection() {
        if stories.isEmpty {
            updateSelection(nil)
        } else if selectedStory == nil {
            updateSelection(stories.first?.key)
        }
    }

    #if DEBUG
    private func loadFixtures() {
        queries = [
            SprintQuery(label: "Sprint", jql: SprintConfig.defaultJQL),
            SprintQuery(label: "Mine", jql: "\(SprintConfig.defaultJQL) AND assignee = currentUser()"),
            SprintQuery(label: "Blocked", jql: "\(SprintConfig.defaultJQL) AND status = Blocked"),
        ]
        let fixtures = [
            Story(key: "NOM-241", summary: "Show invoice delivery failures in the activity feed",
                  status: "In Progress", assignee: "Abel de la Fuente", issueType: "Story",
                  issueTypeIconURL: URL(string: "https://example.atlassian.net/images/icons/issuetypes/story.svg"), priority: "High",
                  browseURL: URL(string: "https://example.atlassian.net/browse/NOM-241")),
            Story(key: "NOM-238", summary: "Retry rejected VeriFactu income documents",
                  status: "In Review", assignee: "Jimena", issueType: "Bug",
                  issueTypeIconURL: URL(string: "https://example.atlassian.net/images/icons/issuetypes/bug.svg"), priority: "Highest",
                  browseURL: URL(string: "https://example.atlassian.net/browse/NOM-238")),
            Story(key: "NOM-235", summary: "Add accountant filters to the invoice list",
                  status: "To Do", assignee: "Unassigned", issueType: "Task",
                  issueTypeIconURL: URL(string: "https://example.atlassian.net/images/icons/issuetypes/task.svg"), priority: "Medium",
                  browseURL: URL(string: "https://example.atlassian.net/browse/NOM-235")),
            Story(key: "NOM-229", summary: "Validate Brazilian NDFe tax totals before submission",
                  status: "Blocked", assignee: "Marius Enache", issueType: "Sub-task",
                  issueTypeIconURL: URL(string: "https://example.atlassian.net/images/icons/issuetypes/subtask.svg"),
                  parentKey: "NOM-241", priority: "High",
                  browseURL: URL(string: "https://example.atlassian.net/browse/NOM-229")),
            Story(key: "NOM-218", summary: "Display SDI notification timestamps",
                  status: "Done", assignee: "Abel de la Fuente", issueType: "Epic",
                  issueTypeIconURL: URL(string: "https://example.atlassian.net/images/icons/issuetypes/epic.svg"), priority: "Low",
                  browseURL: URL(string: "https://example.atlassian.net/browse/NOM-218")),
        ]
        for index in queries.indices {
            resultsByQuery[index] = fixtures
            loadedParentsByQuery[index] = ["NOM-241"]
            loadedQueries.insert(index)
            updatedByQuery[index] = Date()
        }
        selectedQueryIndex = 0
        rebuildRows()
        updateSelection(fixtures[0].key)
        lastUpdated = Date()
        errorMessage = nil
        notice = "Fixture data — no acli request made"
    }
    #endif
}
