# Cistern

A beautifully crafted macOS menu bar app for monitoring your CircleCI builds.

![Cistern Screenshot](./assets/screenshot.png)

## Features

- **Lives in your menu bar** — Always visible, never in the way
- **Real-time build status** — See your builds at a glance with color-coded status icons
- **Animated running builds** — A spinning "C" indicator shows builds in progress with live-updating duration
- **Click to open** — Jump straight to any build in CircleCI
- **Configurable refresh interval** — From 1 second to 1 hour, with a smooth logarithmic slider
- **Filter by organization** — Focus on the builds that matter to you
- **Shows only your builds** — No noise from other team members' pipelines
- **Secure token storage** — API token stored safely in macOS Keychain
- **Native macOS app** — Built with Swift and AppKit, lightweight and fast
- **Dark mode support** — Looks great on both light and dark menu bars

## Installation

1. Clone this repository
2. Open `Cistern.xcodeproj` in Xcode
3. Build and run (⌘R)
4. Click the menu bar icon and go to Settings to add your CircleCI API token

## Getting a CircleCI API Token

1. Go to [CircleCI](https://app.circleci.com)
2. Click your profile icon → **User Settings**
3. Select **Personal API Tokens**
4. Click **Create New Token**
5. Copy the token and paste it into Cistern's settings

## Build Status Icons

| Icon | Status |
|------|--------|
| ✓ Green | Success |
| Spinning C (orange) | Running |
| ✗ Red | Failed |
| ⏸ Yellow | On Hold |
| − Gray | Canceled / Not Run |

## Requirements

- macOS 13.0 or later
- Xcode 15.0 or later (for building)

## Architecture

Cistern is built with a clean, simple architecture:

```
Cistern/
├── AppDelegate.swift           # App lifecycle
├── StatusBarController.swift   # Menu bar UI and animations
├── Models/                     # Data models
│   ├── Build.swift
│   ├── Pipeline.swift
│   ├── Workflow.swift
│   └── Organization.swift
├── Services/                   # Business logic
│   ├── CircleCIClient.swift    # API client
│   ├── KeychainService.swift   # Secure storage
│   └── Settings.swift          # User preferences
└── Views/
    └── SettingsWindowController.swift
```

## Why "Cistern"?

Cisterns are circular. Also, it starts with "CI".

## License

[MIT](LICENSE)
