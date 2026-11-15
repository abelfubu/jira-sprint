# AGENTS.md

## Mission

Build a focused native macOS Jira current-sprint companion with the visual and keyboard conventions of `gh-inbox`. Keep Jira domain state independent from GitHub and use the authenticated `acli` executable; do not add credential storage or runtime dependencies.

## Working rules

- Keep the first mutation-free slice read-only. When mutations are added, route every Jira mutation through one store boundary with a debug-only dry run.
- Never change a real story's status or assignee merely to test the app.
- Preserve existing stories across refresh failures and stable selection by story key.
- Keep one keyboard focus owner and route bindings through `ShortcutMap`.
- Keep displayed story text selectable; use row tap gestures rather than row-wide buttons.
- Add deterministic coverage for decoding, config, and selection logic. Use native smoke tests for keyboard/focus behavior and screenshots for visual changes.
- Treat `~/.config/jira-sprint/config.json` as user-owned runtime data. Use temporary fixtures in tests.

## Verification

```sh
swift build
JIRA_SPRINT_SELF_TEST=1 .build/debug/JiraSprint
JIRA_SPRINT_KEY_SMOKE=1 .build/debug/JiraSprint
JIRA_SPRINT_FORM_SMOKE=1 JIRA_SPRINT_DRY_RUN=1 .build/debug/JiraSprint
JIRA_SPRINT_SCREENSHOT=/tmp/jira-sprint.png .build/debug/JiraSprint
```

All test hooks are DEBUG-only. Form smoke forces dry-run internally as defense in depth; never remove that guard or run mutation-flow tests without dry-run. Update `README.md` and `config.example.json` whenever behavior, shortcuts, or configuration changes.
