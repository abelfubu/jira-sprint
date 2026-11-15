import AppKit
import SwiftUI

private enum FocusTarget {
    case panel
    case formInput
}

struct ContentView: View {
    @ObservedObject var store: SprintStore
    @FocusState private var focusTarget: FocusTarget?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = store.errorMessage { errorLine(error) }
            listBody
            statusBar
        }
        .background(Theme.background)
        .overlay { formOverlay }
        .focusable()
        .focused($focusTarget, equals: .panel)
        .focusEffectDisabled()
        .onKeyPress { press in
            if store.activeForm != nil { return handleFormKey(press) }
            guard let action = store.shortcuts.action(for: press) else { return .ignored }
            focusTarget = .panel
            store.performShortcut(action)
            return .handled
        }
        .simultaneousGesture(TapGesture().onEnded {
            if store.activeForm == nil { focusTarget = .panel }
        })
        .onAppear {
            focusTarget = .panel
            store.start()
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["JIRA_SPRINT_FORM"] == "actions" { store.showActions() }
            if environment["JIRA_SPRINT_FORM"] == "status" { store.showStatusChoices() }
            if environment["JIRA_SPRINT_KEY_SMOKE"] == "1" { runKeySmoke() }
            if environment["JIRA_SPRINT_FORM_SMOKE"] == "1" { runFormSmoke() }
            if let path = environment["JIRA_SPRINT_SCREENSHOT"] { captureOwnView(at: path) }
            #endif
        }
        .onChange(of: store.activeForm) { _, form in
            if form == nil {
                focusTarget = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if store.activeForm == nil { focusTarget = .panel }
                }
            } else {
                DispatchQueue.main.async { focusTarget = .formInput }
            }
        }
        .onDisappear { store.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.system(size: 12, weight: .semibold))
                Text("JIRA SPRINT")
                    .sprintFont(12, weight: .semibold)
                    .foregroundStyle(Theme.foreground)
                Text("\(store.stories.count)")
                    .sprintFont(10.5)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.raised, in: Capsule())
                Spacer()
                Button { store.showActions() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .disabled(store.selectedStory == nil)
                .help("Story actions (\(store.shortcuts.display(for: .actions)))")
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(store.isRefreshing ? Theme.accent : Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Refresh (\(store.shortcuts.display(for: .refresh)))")
            }
            if store.queries.count > 1 { queryTabs }
            Text(store.jql)
                .sprintFont(10)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(height: 88)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var queryTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(store.queries.enumerated()), id: \.offset) { index, query in
                        Button {
                            store.selectQuery(index)
                            focusTarget = .panel
                        } label: {
                            HStack(spacing: 4) {
                                if index < 9 {
                                    Text("\(index + 1)")
                                        .foregroundStyle(index == store.selectedQueryIndex ? Theme.foreground : Theme.dim)
                                }
                                Text(query.label)
                            }
                            .sprintFont(10.5, weight: index == store.selectedQueryIndex ? .semibold : .regular)
                            .foregroundStyle(index == store.selectedQueryIndex ? Theme.foreground : Theme.muted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(index == store.selectedQueryIndex ? Theme.raised : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
            }
            .onChange(of: store.selectedQueryIndex) { _, index in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    private var listBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.stories) { story in
                        StoryRow(story: story, selected: story.key == store.selectedStoryKey) {
                            store.selectStory(story)
                        } open: {
                            store.selectStory(story)
                            store.openSelected()
                        } assign: {
                            store.selectStory(story)
                            store.assignSelectedToMe()
                        } changeStatus: {
                            store.selectStory(story)
                            store.showStatusChoices()
                        }
                        .id(story.key)
                    }
                }
                .padding(6)
            }
            .onChange(of: store.selectedStoryKey) { _, key in
                guard let key else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(key, anchor: .center) }
            }
            .overlay {
                if store.stories.isEmpty { emptyState }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if store.isRefreshing {
                ProgressView().controlSize(.small)
                Text("Loading \(store.selectedQuery.label.lowercased())…")
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 24, weight: .light))
                Text("No stories in \(store.selectedQuery.label)")
                Text("Adjust this query in the config, then refresh.")
                    .sprintFont(10.5)
                    .foregroundStyle(Theme.dim)
            }
        }
        .sprintFont(12)
        .foregroundStyle(Theme.muted)
        .padding(24)
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            if let notice = store.notice {
                Text(notice)
                    .sprintFont(10.5)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface)
            }
            HStack(spacing: 8) {
                if store.queries.count > 1 {
                    Text("\(store.shortcuts.display(for: .previousQuery))/\(store.shortcuts.display(for: .nextQuery)) tabs")
                    Text("·")
                }
                Text("\(store.shortcuts.display(for: .nextStory))/\(store.shortcuts.display(for: .previousStory)) navigate")
                Text("·")
                Text("\(store.shortcuts.display(for: .actions)) actions")
                Text("·")
                Text("\(store.shortcuts.display(for: .openSelected)) open")
                Text("·")
                Text("\(store.shortcuts.display(for: .copy)) copy")
                Spacer()
                if let updated = store.lastUpdated {
                    Text(updated.formatted(date: .omitted, time: .shortened))
                }
            }
            .sprintFont(10)
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.chrome)
        }
    }

    @ViewBuilder
    private var formOverlay: some View {
        if let form = store.activeForm {
            ZStack {
                Color.black.opacity(0.48)
                    .ignoresSafeArea()
                    .onTapGesture { store.dismissForm() }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(form == .actions ? "Story actions" : "Change status")
                                .sprintFont(12, weight: .semibold)
                                .foregroundStyle(Theme.foreground)
                            if let story = store.actionStory {
                                Text(form == .actions ? story.key : "\(story.key) · \(story.status)")
                                    .sprintFont(10.5)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer()
                        if store.isPerformingAction {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { store.dismissForm() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.muted)
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                        }
                    }
                    .padding(12)
                    Rectangle().fill(Theme.border).frame(height: 1)
                    if let error = store.errorMessage {
                        Text(error)
                            .sprintFont(10.5)
                            .foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                    }
                    if store.isPerformingAction {
                        Text("Updating \(store.actionStory?.key ?? "story")…")
                            .sprintFont(11)
                            .foregroundStyle(Theme.muted)
                            .padding(16)
                    } else if form == .actions {
                        ForEach(Array(SprintAction.allCases.enumerated()), id: \.offset) { index, action in
                            Button { store.selectFormItem(index) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: action.symbol)
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 17)
                                    Text(action.title)
                                        .sprintFont(11.5)
                                        .foregroundStyle(Theme.foreground)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(index == store.formSelection ? Theme.raised : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                        }
                    } else if store.statusChoices.isEmpty {
                        Text("No other statuses configured.")
                            .sprintFont(11)
                            .foregroundStyle(Theme.muted)
                            .padding(16)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(store.statusChoices.enumerated()), id: \.offset) { index, status in
                                    Button { store.selectFormItem(index) } label: {
                                        HStack(spacing: 10) {
                                            Circle()
                                                .fill(Theme.statusColor(status))
                                                .frame(width: 7, height: 7)
                                            Text(status)
                                                .sprintFont(11.5)
                                                .foregroundStyle(Theme.statusColor(status))
                                            Spacer()
                                            if index == store.formSelection {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(Theme.muted)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(index == store.formSelection ? Theme.raised : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .focusable(false)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                }
                            }
                        }
                        .frame(height: min(CGFloat(store.statusChoices.count) * 34, 360))
                    }
                    Rectangle().fill(Theme.border).frame(height: 1)
                    Text("\(store.shortcuts.display(for: .nextStory))/\(store.shortcuts.display(for: .previousStory)) navigate · ↵ select · \(store.shortcuts.display(for: .cancel)) cancel")
                        .sprintFont(9.5)
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .frame(width: 340)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()
            .focused($focusTarget, equals: .formInput)
            .focusEffectDisabled()
            .onKeyPress { handleFormKey($0) }
        }
    }

    private func handleFormKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .return {
            store.submitForm()
            return .handled
        }
        guard let action = store.shortcuts.action(for: press, in: [.nextStory, .previousStory, .cancel, .refresh]) else {
            return .ignored
        }
        switch action {
        case .nextStory: store.moveFormSelection(1)
        case .previousStory: store.moveFormSelection(-1)
        case .cancel: store.dismissForm()
        case .refresh: store.refresh()
        default: break
        }
        return .handled
    }

    private func errorLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .sprintFont(11)
        .foregroundStyle(Theme.red)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
    }

    #if DEBUG
    private func sendKey(_ character: String, keyCode: UInt16) {
        guard let window = NSApp.windows.first,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: character,
                                           charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode) else { return }
        NSApp.sendEvent(event)
    }

    private func runKeySmoke() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            precondition(store.stories.count >= 2, "Keyboard smoke needs at least two fixture stories")
            precondition(focusTarget == .panel, "The story panel did not receive initial focus")
            sendKey("j", keyCode: 38)
            precondition(store.selectedStoryKey == store.stories[1].key, "j did not select the second story")
            sendKey("k", keyCode: 40)
            precondition(store.selectedStoryKey == store.stories[0].key, "k did not select the first story")
            sendKey("j", keyCode: 38)
            precondition(store.selectedStoryKey == store.stories[1].key, "j did not select the second story")
            sendKey("l", keyCode: 37)
            precondition(store.selectedQueryIndex == 1, "l did not select the next query")
            precondition(store.selectedStoryKey == store.stories[0].key, "The second query did not establish its selection")
            sendKey("h", keyCode: 4)
            precondition(store.selectedQueryIndex == 0, "h did not select the previous query")
            precondition(store.selectedStoryKey == store.stories[1].key, "The first query did not restore its selection")
            sendKey("k", keyCode: 40)
            precondition(store.selectedStoryKey == store.stories[0].key, "k did not select the first story after tab navigation")
            sendKey("2", keyCode: 19)
            precondition(store.selectedQueryIndex == 1, "2 did not select the second query")
            sendKey("1", keyCode: 18)
            precondition(store.selectedQueryIndex == 0, "1 did not select the first query")
            sendKey("y", keyCode: 16)
            precondition(NSPasteboard.general.string(forType: .string)?.contains(store.stories[0].key) == true,
                         "y did not copy the selected story URL")
            sendKey("\u{1b}", keyCode: 53)
            precondition(store.selectedStoryKey == nil, "Escape did not clear the selection")
            sendKey("j", keyCode: 38)
            precondition(store.selectedStoryKey == store.stories[0].key, "j did not restore a selection")
            print("native key smoke: PASS")
            exit(0)
        }
    }

    private func runFormSmoke() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            precondition(focusTarget == .panel && store.activeForm == nil, "Form smoke needs an initially focused story panel")
            let key = store.selectedStoryKey
            let originalStatus = store.selectedStory?.status
            sendKey("a", keyCode: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                precondition(store.activeForm == .actions && focusTarget == .formInput, "a did not open and focus story actions")
                store.selectStory(store.stories[1])
                let backgroundKey = store.selectedStoryKey
                precondition(store.actionStory?.key == key, "Actions did not pin the originally selected story")
                sendKey("j", keyCode: 38)
                precondition(store.formSelection == 1 && store.selectedStoryKey == backgroundKey, "Form navigation leaked into story selection")
                sendKey("\r", keyCode: 36)
                precondition(store.activeForm == .status, "Change status action did not open the status picker")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    precondition(focusTarget == .formInput && store.statusChoices.count >= 2, "Status picker was not populated and focused")
                    sendKey("j", keyCode: 38)
                    let status = store.statusChoices[store.formSelection]
                    sendKey("\r", keyCode: 36)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        precondition(store.activeForm == nil && focusTarget == .panel, "Status submission did not restore panel focus")
                        precondition(store.notice?.contains("Dry run") == true && store.notice?.contains(status) == true,
                                     "Status dry run did not report the selected transition")
                        precondition(store.stories.first { $0.key == key }?.status == originalStatus, "Dry run changed fixture story status")
                        sendKey("a", keyCode: 0)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            precondition(store.activeForm == .actions && store.formSelection == 0, "Actions did not reopen at the first item")
                            sendKey("\r", keyCode: 36)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                precondition(store.activeForm == nil && focusTarget == .panel, "Assignment did not restore panel focus")
                                precondition(store.notice?.contains("Dry run") == true && store.notice?.contains("@me") == true,
                                             "Assignment dry run did not report @me")
                                sendKey("a", keyCode: 0)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    sendKey("\u{1b}", keyCode: 53)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        precondition(store.activeForm == nil && focusTarget == .panel, "Escape did not dismiss actions and restore focus")
                                        precondition(store.selectedStoryKey == store.stories[1].key, "Escape cleared story selection instead of only the form")
                                        print("native action form smoke: PASS")
                                        exit(0)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func captureOwnView(at path: String) {
        let live = ProcessInfo.processInfo.environment["JIRA_SPRINT_LIVE"] == "1"
        DispatchQueue.main.asyncAfter(deadline: .now() + (live ? 10 : 1)) {
            guard let view = NSApp.windows.first?.contentView,
                  let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else { exit(1) }
            do {
                try data.write(to: URL(fileURLWithPath: path))
                print(path)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
    }
    #endif
}

private struct StoryRow: View {
    let story: Story
    let selected: Bool
    let select: () -> Void
    let open: () -> Void
    let assign: () -> Void
    let changeStatus: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .frame(width: 15)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(story.key)
                        .sprintFont(11, weight: .medium)
                        .foregroundStyle(Theme.muted)
                    Text(story.summary)
                        .sprintFont(12.5, weight: .light)
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                HStack(spacing: 8) {
                    chip(story.status, color: statusColor)
                    Text(story.assignee).foregroundStyle(Theme.muted)
                    if let priority = story.priority {
                        Text(priority).foregroundStyle(priorityColor(priority))
                    }
                }
                .sprintFont(10.5)
                .lineLimit(1)
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(selected ? Theme.raised : hovered ? Theme.hover : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { open() }
        .onTapGesture(count: 1) { select() }
        .contextMenu {
            Button("Open in Jira") { open() }
            Button("Copy story URL") {
                select()
                let value = story.browseURL?.absoluteString ?? story.key
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            Divider()
            Button("Assign to me") {
                select()
                assign()
            }
            Button("Change status…") {
                select()
                changeStatus()
            }
        }
    }

    private var statusColor: Color { Theme.statusColor(story.status) }

    private func priorityColor(_ priority: String) -> Color {
        switch priority.lowercased() {
        case "highest", "critical": Theme.red
        case "high": Theme.orange
        case "low", "lowest": Theme.dim
        default: Theme.muted
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}
