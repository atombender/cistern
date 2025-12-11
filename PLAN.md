# Cistern - CircleCI Menu Bar App

A macOS menu bar app that displays CircleCI build status for followed projects.

## Technology Choice

**Swift + AppKit** - Native macOS development for best performance and system integration.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Menu Bar (NSStatusItem)              │
├─────────────────────────────────────────────────────────┤
│  NSMenu                                                 │
│  ├── ● org/repo-a (main) - Success                     │
│  ├── ● org/repo-b (main) - Running                     │
│  ├── ● org/repo-c (feature) - Failed                   │
│  ├── ─────────────────                                 │
│  ├── Refresh Now                                        │
│  ├── Settings...                                        │
│  └── Quit                                               │
└─────────────────────────────────────────────────────────┘
```

**Display Logic**: Show only the newest build per project (flat list, no nesting).

## CircleCI API Integration

### Authentication
- API token stored in macOS Keychain
- Header: `Circle-Token: <token>`

### Endpoints Used

1. **Get followed pipelines**: `GET /api/v2/pipeline?mine=true`
   - Returns pipelines for projects you follow (max 250)
   - Response includes: `id`, `project_slug`, `vcs.branch`, `trigger.actor`

2. **Get pipeline workflows**: `GET /api/v2/pipeline/{pipeline-id}/workflow`
   - Returns workflows for a pipeline
   - Workflow has `status`: `success`, `running`, `not_run`, `failed`, `error`, `failing`, `on_hold`, `canceled`

### Data Flow
1. Fetch recent pipelines (`/pipeline?mine=true`)
2. Group pipelines by project slug, keep only the newest per project
3. For each pipeline, fetch workflows to get status
4. Aggregate: pipeline status = worst workflow status
5. Display as flat list: one row per project showing newest build

## Project Structure

```
Cistern/
├── Cistern.xcodeproj
├── Cistern/
│   ├── AppDelegate.swift          # App lifecycle, menu bar setup
│   ├── StatusBarController.swift  # NSStatusItem management
│   ├── MenuBuilder.swift          # Build NSMenu from data
│   ├── CircleCIClient.swift       # API client
│   ├── Models/
│   │   ├── Pipeline.swift         # Pipeline model
│   │   ├── Workflow.swift         # Workflow model
│   │   └── Project.swift          # Grouped project data
│   ├── Services/
│   │   ├── KeychainService.swift  # Secure token storage
│   │   └── PollingService.swift   # Background refresh timer
│   ├── Views/
│   │   └── SettingsWindow.swift   # Settings UI (token input)
│   ├── Assets.xcassets/           # App icon, status icons
│   └── Info.plist
└── README.md
```

## Implementation Steps

### Step 1: Project Setup
- [ ] Create new macOS App project in Xcode
- [ ] Configure as menu bar only app (LSUIElement = YES)
- [ ] Set up basic NSStatusItem with placeholder icon

### Step 2: Menu Bar Foundation
- [ ] Create StatusBarController to manage NSStatusItem
- [ ] Build static NSMenu with placeholder items
- [ ] Add Quit menu item that works
- [ ] Test app appears in menu bar

### Step 3: CircleCI API Client
- [ ] Create data models: Pipeline, Workflow, Project
- [ ] Implement CircleCIClient with URLSession
- [ ] Add endpoint: fetchPipelines(mine: true)
- [ ] Add endpoint: fetchWorkflows(pipelineId:)
- [ ] Handle API errors and rate limiting

### Step 4: Keychain Integration
- [ ] Create KeychainService for secure token storage
- [ ] Add/retrieve/delete API token
- [ ] Handle first-launch (no token) case

### Step 5: Settings Window
- [ ] Create simple settings window with token input field
- [ ] Add "Save" button that stores to Keychain
- [ ] Add "Test Connection" button
- [ ] Show settings on first launch if no token

### Step 6: Dynamic Menu Building
- [ ] Create MenuBuilder to construct menu from API data
- [ ] Show one item per project (newest build only)
- [ ] Format: "● org/repo (branch) - Status"
- [ ] Add status indicators (●) with colors via attributed strings
- [ ] Make items clickable → open CircleCI in browser

### Step 7: Polling & Refresh
- [ ] Create PollingService with configurable interval (default: 60s)
- [ ] Refresh data on timer tick
- [ ] Add "Refresh Now" menu item
- [ ] Update menu bar icon based on overall status (green/yellow/red)

### Step 8: Polish
- [ ] Add loading state while fetching
- [ ] Handle offline/error states gracefully
- [ ] Add "Last updated: X" footer
- [ ] Test with real CircleCI account

## Status Icon Mapping

| Workflow Status | Icon Color | Menu Bar Icon |
|-----------------|------------|---------------|
| success         | 🟢 Green   | ✓ (if all success) |
| running         | 🟡 Yellow  | ↻ (if any running) |
| failed/error    | 🔴 Red     | ✗ (if any failed) |
| on_hold         | 🟠 Orange  | ⏸ |
| canceled        | ⚫ Gray    | — |

Priority for menu bar icon: failed > running > on_hold > success

## URL Scheme for Opening Builds

CircleCI web URLs follow this pattern:
- Pipeline: `https://app.circleci.com/pipelines/{project-slug}/{pipeline-number}`
- Workflow: `https://app.circleci.com/pipelines/{project-slug}/{pipeline-number}/workflows/{workflow-id}`

## Future Enhancements (Out of Scope for v1)

- Notifications on status change
- Filter to specific projects/branches
- Multiple organizations support
- Keyboard shortcuts
- Dark/light mode icon variants

## Dependencies

None - using only Apple frameworks:
- Foundation (networking, JSON)
- AppKit (UI)
- Security (Keychain)

## Sources

- [CircleCI API v2 Documentation](https://circleci.com/docs/api/v2/index.html)
- [CircleCI API Introduction](https://circleci.com/docs/api-intro/)
- [API v2 Pipeline Status Discussion](https://discuss.circleci.com/t/api-v2-is-it-possible-to-get-pipeline-status/34483)
