# Jira Sprint

A native macOS current-sprint story list using SwiftUI, AppKit, and the authenticated [Atlassian CLI](https://developer.atlassian.com/cloud/acli/) (`acli`). It follows the visual and keyboard conventions of `gh-inbox`, but is a separate app with its own domain and configuration.

## Current scope

- Fetches stories through one or more configurable JQL tabs using `acli jira workitem search`.
- Displays story key, summary, status, assignee, and priority.
- Keyboard navigation, numbered query tabs, browser opening, URL copying, and periodic refresh.
- Keyboard- and mouse-driven actions to self-assign stories and transition their status.
- Caches results and selection per query and preserves existing stories when a refresh fails.
- Debug-only dry-run and native form smoke coverage; tests never mutate real Jira stories.

## Requirements

- macOS 14 or newer.
- Swift 5.9 or newer.
- Atlassian CLI (`acli`) with an authenticated Jira site.

Verify the CLI and its search support:

```sh
acli --version
acli jira workitem search --help
acli jira workitem assign --help
acli jira workitem transition --help
```

`ACLI_PATH` overrides the executable. Otherwise the app searches `PATH`, Homebrew, `~/.local/bin/acli`, and `/usr/bin/acli`. The app stores no credentials.

## Install with Homebrew

```sh
brew tap abelfubu/tap
brew trust abelfubu/tap
brew install --cask jira-sprint
```

Homebrew installs the `acli` dependency automatically. The release apps are universal (Apple Silicon and Intel), ad-hoc signed, and not notarized; macOS may require **right-click → Open** on first launch.

## Build and run

```sh
cd ~/dev/jira-sprint
swift run
```

Build and open an ad-hoc-signed app bundle:

```sh
./scripts/build-app.sh --open
```

The bundle is written to `dist/Jira Sprint.app`.

For a distributable universal release, run `./scripts/package-release.sh 0.1.0` (universal packaging requires full Xcode; normal app builds only need Command Line Tools). This verifies the app signature and architectures, then writes `dist/Jira-Sprint-0.1.0.zip` and its SHA-256 checksum.

## Create a release

Commit and push your changes to `main`, then create and push an annotated semantic-version tag. The leading `v` is required; a tag such as `0.2.0` without it does not trigger publishing.

```sh
git switch main
git pull origin main
git tag -a v0.2.0 -m "Release v0.2.0"
git push origin v0.2.0
```

The tag workflow builds and tests the universal app, publishes the GitHub release, and updates the `jira-sprint` Homebrew cask automatically. Use a new version for every release. See the [publishing documentation](https://github.com/abelfubu/gh-inbox/blob/main/docs/homebrew-publishing.md) for credentials, verification, and the manual fallback.

## App icon

The app icon uses the same dark palette and blue bolt as the window header. Its editable source is `Assets/AppIcon.svg`; generated outputs are `Assets/AppIcon.icns` and `Assets/AppIcon.png`. The app build copies the icon into `Contents/Resources` and declares it in `Info.plist`.

After editing the SVG, regenerate all macOS icon sizes and rebuild the app:

```sh
./scripts/build-icon.sh
./scripts/build-app.sh
```

Icon generation uses macOS's built-in Quick Look, `sips`, and `iconutil`; no additional renderer is required.

## Configuration

The app reads `~/.config/jira-sprint/config.json` and creates defaults when the file is missing. See [`config.example.json`](config.example.json).

```json
{
  "queries": [
    {
      "label": "Sprint",
      "jql": "sprint in openSprints() ORDER BY rank ASC"
    },
    {
      "label": "Mine",
      "jql": "sprint in openSprints() AND assignee = currentUser() ORDER BY rank ASC"
    }
  ],
  "limit": 100,
  "site": "https://example.atlassian.net",
  "statuses": ["To Do", "In Progress", "In Review", "Blocked", "Done"]
}
```

- `queries`: ordered query tabs with a display `label` and complete `jql`. The first tab loads at launch; other tabs load when selected. The defaults include Stories, Errors, Tasks, and other sprint work-item types; add an `issuetype` clause only if you want to restrict them.
- `jql`: legacy single-query setting used when `queries` is omitted or contains no valid entries. Existing single-query configs remain compatible.
- `limit`: maximum results per query, clamped to `1`–`200`; defaults to `100`.
- `site`: optional Jira base URL used to construct browse links when `acli` does not return an API `self` or browse URL.
- `statuses`: ordered status choices for the transition picker. The app also adds statuses found in loaded results, removes duplicates and the current status, and defaults to `To Do`, `In Progress`, `In Review`, `Blocked`, and `Done`. Jira validates whether each named transition is allowed by the story's workflow. Loaded status chips use Jira's `statusCategory.colorName`: `yellow` maps to the accent blue, `green` to green, and `blue-gray` to muted gray. Missing or unknown category metadata falls back to status-name colors.
- `font`: optional installed font family; defaults to JetBrains Mono. Use `System` for San Francisco.
- `colors`: optional `#RRGGBB` or `#RRGGBBAA` overrides. Supported names are `background`, `chrome`, `surface`, `raised`, `hover`, `selected`, `border`, `foreground`, `muted`, `dim`, `accent`, `green`, `red`, `yellow`, `orange`, and `purple`.
- `shortcuts`: optional action-to-bindings overrides. Omitted actions keep their defaults; an empty array disables an action.

Shortcut action IDs: `nextStory`, `previousStory`, `nextQuery`, `previousQuery`, `tab1`–`tab9`, `openSelected`, `actions`, `cancel`, `refresh`, `copy`, `openConfig`, and `closeWindow`.

Bindings support `cmd`, `shift`, `alt`/`option`, and `ctrl`/`control`, plus `enter`, `escape`, `space`, arrows, and `tab`. Configuration, colors, font, and shortcuts reload on refresh.

## Keyboard and mouse

| Key | Action |
|---|---|
| `h` / `[` | Previous query tab |
| `l` / `]` | Next query tab |
| `1`–`9` | Select the corresponding query tab |
| `j` / `↓` | Next story |
| `k` / `↑` | Previous story |
| `Enter` / `o` | Open selected story in Jira |
| `a` | Open actions for the selected story |
| `y` | Copy selected story URL, or its key if no URL is available |
| `Escape` | Close the action/status popup before clearing selection or dismissing a notice |
| `r` / `⌘R` | Refresh the current query and reload config |
| `⌘⇧O` | Open JSON config |
| `⌘W` | Close window |

In an action or status popup, `j`/`↓` and `k`/`↑` navigate, Enter selects, and Escape cancels. **Assign to me** runs `acli jira workitem assign --assignee @me --yes`; choosing a status runs `acli jira workitem transition --status … --yes`. Both close the popup and restore story-panel focus on success. Errors leave the popup open for correction.

Single-click selects a story, double-click opens it, and right-click provides open, copy, self-assignment, and status actions. The header ellipsis opens the same action menu as `a`. Clicking a query tab selects it. Displayed story text is selectable and copyable.

## Architecture

| File | Responsibility |
|---|---|
| `Sources/JiraSprint/JiraSprintApp.swift` | App scene, window sizing, native menu commands, test entry point |
| `Sources/JiraSprint/ContentView.swift` | Native UI, action/status popups, keyboard handling, focus, native smoke tests and screenshots |
| `Sources/JiraSprint/SprintStore.swift` | Query caches, selection, refresh coordination, action state, and the single dry-run mutation boundary |
| `Sources/JiraSprint/JiraClient.swift` | `acli` discovery/execution, assignment and transition commands, tolerant Jira JSON decoding |
| `Sources/JiraSprint/Models.swift` | Story model and default sprint JQL |
| `Sources/JiraSprint/Config.swift` | Config validation, persistence, and defaults |
| `Sources/JiraSprint/Shortcuts.swift` | Shortcut parsing, matching, menu equivalents, and hints |
| `Sources/JiraSprint/Theme.swift` | Palette and typography |
| `Sources/JiraSprint/SelfTests.swift` | Deterministic config, decoding, color, and shortcut tests |
| `scripts/build-app.sh` | Release build, icon installation, app bundle creation, and ad-hoc signing |
| `scripts/build-icon.sh` | Regenerates the complete macOS icon set from `Assets/AppIcon.svg` |

## Verification

```sh
swift build
JIRA_SPRINT_SELF_TEST=1 .build/debug/JiraSprint
JIRA_SPRINT_KEY_SMOKE=1 .build/debug/JiraSprint
JIRA_SPRINT_FORM_SMOKE=1 JIRA_SPRINT_DRY_RUN=1 .build/debug/JiraSprint
```

The keyboard and form smoke tests use debug-only fixtures and do not invoke `acli` or open a browser. Form smoke forces dry-run internally even if `JIRA_SPRINT_DRY_RUN` is omitted, then verifies self-assignment, status selection, cancellation, and focus restoration without changing fixture data. Keyboard smoke changes the general pasteboard while testing URL copying.

To exercise the UI manually without mutating Jira, use `JIRA_SPRINT_DRY_RUN=1 swift run`. The dry-run guard exists only in debug builds; release builds always perform the requested action through `acli`.

Capture the app's own rendered view using debug-only fixture data:

```sh
JIRA_SPRINT_SCREENSHOT=/tmp/jira-sprint.png \
JIRA_SPRINT_WIDTH=480 JIRA_SPRINT_HEIGHT=760 \
.build/debug/JiraSprint
```

Add `JIRA_SPRINT_FORM=actions` or `JIRA_SPRINT_FORM=status` to capture either popup. Add `JIRA_SPRINT_LIVE=1` to capture real Jira results instead of fixtures. `JIRA_SPRINT_FIXTURE=1 swift run` runs the UI with the same sample stories and without network access. Fixture, keyboard/form-smoke, self-test, dry-run, and live/fixture screenshot hooks are excluded from release builds.

## Troubleshooting

- **`acli` unavailable:** install and authenticate Atlassian CLI, then restart the app. Set `ACLI_PATH` when it is installed elsewhere.
- **No stories:** run the configured JQL with `acli jira workitem search --jql '…' --limit 100 --json` and confirm your Jira issue-type name.
- **Stories do not open:** set `site` to your Jira base URL if the CLI response does not contain enough URL metadata.
- **Refresh fails:** the previous stories remain visible and the error appears below the header.
- **A status is rejected:** Jira's workflow does not allow that named transition for the story. Add the exact workflow status names to `statuses`, then retry; the failed popup remains open with the CLI error.
