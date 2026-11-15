import AppKit
import Foundation

@MainActor
final class SprintStore: ObservableObject {
    @Published private(set) var stories: [Story] = []
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
    private var loadedQueries: Set<Int> = []
    private var selectionByQuery: [Int: String] = [:]
    private var updatedByQuery: [Int: Date] = [:]

    init(configStore: ConfigStore = .standard) {
        self.configStore = configStore
    }

    deinit {
        autoTask?.cancel()
        refreshTask?.cancel()
    }

    var jql: String { selectedQuery.jql }
    var selectedQuery: SprintQuery { queries[selectedQueryIndex] }
    var selectedStory: Story? { stories.first { $0.key == selectedStoryKey } }

    func start() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["JIRA_SPRINT_FIXTURE"] == "1"
            || environment["JIRA_SPRINT_KEY_SMOKE"] == "1"
            || environment["JIRA_SPRINT_FORM_SMOKE"] == "1"
            || (environment["JIRA_SPRINT_SCREENSHOT"] != nil && environment["JIRA_SPRINT_LIVE"] != "1") {
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
                let stories = try await Task.detached(priority: .userInitiated) {
                    let client = try JiraClient()
                    return try client.fetchStories(jql: query.jql, limit: limit, site: site)
                }.value
                self.resultsByQuery[queryIndex] = stories
                self.loadedQueries.insert(queryIndex)
                self.updatedByQuery[queryIndex] = Date()
                if self.selectedQueryIndex == queryIndex {
                    self.stories = stories
                    self.errorMessage = nil
                    self.lastUpdated = self.updatedByQuery[queryIndex]
                    self.ensureSelection()
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
        stories = resultsByQuery[index] ?? []
        selectedStoryKey = selectionByQuery[index]
        lastUpdated = updatedByQuery[index]
        errorMessage = nil
        notice = nil
        ensureSelection()
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
                                          available: resultsByQuery.values.flatMap { $0.map(\.status) },
                                          current: story.status)
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

    private func applyQueries(_ newQueries: [SprintQuery]) {
        guard newQueries != queries else { return }
        queries = newQueries
        resultsByQuery.removeAll()
        loadedQueries.removeAll()
        selectionByQuery.removeAll()
        updatedByQuery.removeAll()
        selectedQueryIndex = 0
        stories = []
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
                  status: "In Progress", assignee: "Abel de la Fuente", issueType: "Story", priority: "High",
                  browseURL: URL(string: "https://example.atlassian.net/browse/NOM-241")),
            Story(key: "NOM-238", summary: "Retry rejected VeriFactu income documents",
                  status: "In Review", assignee: "Jimena", issueType: "Story", priority: "Highest",
                  browseURL: URL(string: "https://example.atlassian.net/browse/NOM-238")),
            Story(key: "NOM-235", summary: "Add accountant filters to the invoice list",
                  status: "To Do", assignee: "Unassigned", issueType: "Story", priority: "Medium",
                  browseURL: URL(string: "https://example.atlassian.net/browse/NOM-235")),
            Story(key: "NOM-229", summary: "Validate Brazilian NDFe tax totals before submission",
                  status: "Blocked", assignee: "Marius Enache", issueType: "Story", priority: "High",
                  browseURL: URL(string: "https://example.atlassian.net/browse/NOM-229")),
            Story(key: "NOM-218", summary: "Display SDI notification timestamps",
                  status: "Done", assignee: "Abel de la Fuente", issueType: "Story", priority: "Low",
                  browseURL: URL(string: "https://example.atlassian.net/browse/NOM-218")),
        ]
        for index in queries.indices {
            resultsByQuery[index] = fixtures
            loadedQueries.insert(index)
            updatedByQuery[index] = Date()
        }
        selectedQueryIndex = 0
        stories = fixtures
        updateSelection(fixtures[0].key)
        lastUpdated = Date()
        errorMessage = nil
        notice = "Fixture data — no acli request made"
    }
    #endif
}
