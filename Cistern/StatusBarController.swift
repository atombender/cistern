import Cocoa

@MainActor
class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private let buildMonitor = BuildMonitor()
    private var animationTimer: Timer?
    private var lastUpdatedTimer: Timer?

    private var isMenuOpen: Bool = false
    private var displayedBuilds: [Build] {
        // Always show all running builds first, then limit non-running builds
        let runningBuilds = buildMonitor.builds.filter { $0.status == .running }
        let otherBuilds = buildMonitor.builds.filter { $0.status != .running }
        let maxOtherBuilds = max(0, 10 - runningBuilds.count)
        return runningBuilds + otherBuilds.prefix(maxOtherBuilds)
    }
    private var animationFrame: Int = 0
    private var hasFailingBuilds: Bool = false
    private var loadingCount: Int = 0
    private var lastUpdatedMenuItem: NSMenuItem?
    private var loadingMenuItem: NSMenuItem?

    // Stable menu structure - only created once
    private var buildMenuItems: [NSMenuItem] = []
    private var separatorBeforeLastUpdated: NSMenuItem?

    // Track previous build statuses for change detection
    private var previousBuildStatuses: [String: BuildStatus] = [:]

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        setupStatusItem()
        buildMenu()
        startLastUpdatedTimer()

        // Request notification permissions
        NotificationService.shared.requestAuthorization()

        setupBuildMonitor()
        buildMonitor.startPolling()
    }
    private func setupBuildMonitor() {
        buildMonitor.onBuildsChanged = { [weak self] builds in
            guard let self = self else { return }
            self.checkForBuildChangesAndNotify(builds)
            self.buildMenu()
            self.updateStatusIcon()
        }

        buildMonitor.onLoadingStateChanged = { [weak self] isLoading, count in
            guard let self = self else { return }
            self.loadingCount = count
            if isLoading {
                self.startLoadingAnimation()
                self.loadingMenuItem?.title = "Loading... (\(count))"
            } else {
                self.stopLoadingAnimation()
                self.buildMenu()  // Remove loading item
            }
        }
    }

    deinit {
        // Clean up all timers
        lastUpdatedTimer?.invalidate()
        animationTimer?.invalidate()
    }

    private func startLastUpdatedTimer() {
        lastUpdatedTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Only update menu items when menu is open - updating invisible items leaks VM
            if self.isMenuOpen {
                self.lastUpdatedMenuItem?.title = self.lastUpdatedString()
                self.updateRunningBuildDurations()
            }
        }
        RunLoop.main.add(lastUpdatedTimer!, forMode: .common)
    }

    private func updateRunningBuildDurations() {
        // Only update when menu is open - updating invisible menu items leaks VM
        guard isMenuOpen, let menu = statusItem.menu else { return }
        for item in menu.items {
            guard let build = item.representedObject as? Build, build.status == .running else {
                continue
            }
            let maxBranchLength = 20
            let branch: String
            if build.branch.count > maxBranchLength {
                branch = String(build.branch.prefix(maxBranchLength - 1)) + "…"
            } else {
                branch = build.branch
            }
            // Use plain title for running builds to avoid NSAttributedString VM leaks
            // The duration updates every second, creating unique strings each time
            item.attributedTitle = nil
            item.title = "\(build.projectName) • \(branch) • \(build.workflowName)  \(build.durationString)"
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // Update menu items immediately when menu opens
        lastUpdatedMenuItem?.title = lastUpdatedString()
        updateRunningBuildDurations()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            button.image = StatusIconService.shared.getLoadingImage()
        }
        statusItem.isVisible = true
    }

    private func buildMenu() {
        // Create menu structure only once
        if statusItem.menu == nil {
            createMenuStructure()
        }

        guard let menu = statusItem.menu else { return }

        // Update build items
        let visibleBuilds = displayedBuilds

        // Hide all existing build menu items first
        for item in buildMenuItems {
            item.isHidden = true
        }

        if !KeychainService.hasToken() {
            // Show "no token" message in first build slot
            ensureBuildMenuItemExists(at: 0, in: menu)
            let item = buildMenuItems[0]
            item.title = "No API token configured"
            item.attributedTitle = nil
            item.image = nil
            item.isEnabled = false
            item.action = nil
            item.representedObject = nil
            item.isHidden = false
            loadingMenuItem = nil
        } else if buildMonitor.builds.isEmpty && buildMonitor.isLoading {
            // Show loading message
            ensureBuildMenuItemExists(at: 0, in: menu)
            let item = buildMenuItems[0]
            let loadingText = loadingCount > 0 ? "Loading... (\(loadingCount))" : "Loading..."
            item.title = loadingText
            item.attributedTitle = nil
            item.image = nil
            item.isEnabled = false
            item.action = nil
            item.representedObject = nil
            item.isHidden = false
            loadingMenuItem = item
        } else if buildMonitor.builds.isEmpty {
            // Show "no builds" message
            ensureBuildMenuItemExists(at: 0, in: menu)
            let item = buildMenuItems[0]
            item.title = "No recent builds found"
            item.attributedTitle = nil
            item.image = nil
            item.isEnabled = false
            item.action = nil
            item.representedObject = nil
            item.isHidden = false
            loadingMenuItem = nil
        } else {
            // Show builds
            loadingMenuItem = nil
            for (index, build) in visibleBuilds.enumerated() {
                ensureBuildMenuItemExists(at: index, in: menu)
                updateMenuItem(buildMenuItems[index], with: build)
                buildMenuItems[index].isHidden = false
            }
        }

        // Update separator visibility
        separatorBeforeLastUpdated?.isHidden =
            visibleBuilds.isEmpty && !buildMonitor.isLoading
            && KeychainService.hasToken()
    }

    private func createMenuStructure() {
        let menu = NSMenu()

        // Separator before "last updated" (will be positioned after build items)
        separatorBeforeLastUpdated = NSMenuItem.separator()
        menu.addItem(separatorBeforeLastUpdated!)

        // Last updated item
        lastUpdatedMenuItem = NSMenuItem(title: lastUpdatedString(), action: nil, keyEquivalent: "")
        lastUpdatedMenuItem?.isEnabled = false
        menu.addItem(lastUpdatedMenuItem!)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Cistern", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    private func ensureBuildMenuItemExists(at index: Int, in menu: NSMenu) {
        while buildMenuItems.count <= index {
            let item = NSMenuItem(title: "", action: #selector(openBuild(_:)), keyEquivalent: "")
            item.target = self
            // Insert before the separator
            let insertIndex = buildMenuItems.count
            menu.insertItem(item, at: insertIndex)
            buildMenuItems.append(item)
        }
    }

    private func updateMenuItem(_ item: NSMenuItem, with build: Build) {
        item.representedObject = build
        item.isEnabled = true
        item.action = #selector(openBuild(_:))

        // Set icon from precomputed cache
        if build.status == .running {
            item.image = StatusIconService.shared.getRunningFrame(index: 0)
        } else if build.status == .failing {
            item.image = StatusIconService.shared.getFailingFrame(index: 0)
        } else {
            item.image = StatusIconService.shared.getStatusImage(for: build.status)
        }

        // Truncate long branch names
        let maxBranchLength = 20
        let branch: String
        if build.branch.count > maxBranchLength {
            branch = String(build.branch.prefix(maxBranchLength - 1)) + "…"
        } else {
            branch = build.branch
        }

        item.attributedTitle = formatMenuTitle(
            projectName: build.projectName, branch: branch, workflowName: build.workflowName,
            duration: build.durationString)
    }

    private func lastUpdatedString() -> String {
        guard let lastUpdated = buildMonitor.lastUpdated else {
            return "Last updated: Never"
        }

        let seconds = Int(Date().timeIntervalSince(lastUpdated))
        if seconds < 5 {
            return "Last updated: Just now"
        } else if seconds < 60 {
            return "Last updated: \(seconds)s ago"
        } else {
            let minutes = seconds / 60
            return "Last updated: \(minutes)m ago"
        }
    }

    // Cache for complete menu titles - keyed by full content
    private var cachedMenuTitles: [String: NSAttributedString] = [:]

    private func formatMenuTitle(
        projectName: String, branch: String, workflowName: String, duration: String
    ) -> NSAttributedString {
        let cacheKey = "\(projectName)|\(branch)|\(workflowName)|\(duration)"

        if let cached = cachedMenuTitles[cacheKey] {
            return cached
        }

        // Create new attributed string
        let baseText = "\(projectName) • \(branch) • \(workflowName) "
        let result = NSMutableAttributedString(string: baseText + duration)

        // Color just the duration part
        let durationRange = NSRange(location: baseText.count, length: duration.count)
        result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: durationRange)

        // Cache with size limit - use LRU-style eviction
        if cachedMenuTitles.count > 1000 {
            // Remove oldest half when limit reached
            let keysToRemove = Array(cachedMenuTitles.keys.prefix(500))
            for key in keysToRemove {
                cachedMenuTitles.removeValue(forKey: key)
            }
        }
        cachedMenuTitles[cacheKey] = result

        return result
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let visibleBuilds = displayedBuilds

        // Find the newest build by createdAt time
        guard let newestBuild = visibleBuilds.max(by: { $0.createdAt < $1.createdAt }) else {
            // No builds - show loading icon
            stopAnimation()
            button.image = StatusIconService.shared.getLoadingImage()
            return
        }

        // Check if builds are stale (> 30 mins since newest build completed)
        let staleThreshold: TimeInterval = 30 * 60
        let isStale =
            newestBuild.stoppedAt == nil
            ? false  // Running/failing builds are not stale
            : Date().timeIntervalSince(newestBuild.stoppedAt!) > staleThreshold

        // Determine icon based on newest build's status
        switch newestBuild.status {
        case .running:
            hasFailingBuilds = false
            startAnimation()
        case .failing:
            hasFailingBuilds = true
            startAnimation()
        default:
            hasFailingBuilds = false
            stopAnimation()
            let newImage: NSImage? =
                isStale
                ? StatusIconService.shared.getLoadingImage()
                : StatusIconService.shared.getStatusImage(for: newestBuild.status)
            if button.image !== newImage {
                button.image = newImage
            }
        }
    }

    private func checkForBuildChangesAndNotify(_ newBuilds: [Build]) {
        for build in newBuilds {
            let key = "\(build.projectSlug)/\(build.branch)/\(build.workflowName)"
            let oldStatus = previousBuildStatuses[key]

            // Build started: now running, wasn't running before (or is new)
            if build.status == .running && oldStatus != .running {
                NotificationService.shared.sendBuildStarted(build: build)
            }

            // Build finished: was running, now completed
            if let old = oldStatus, old == .running && build.status != .running {
                NotificationService.shared.sendBuildFinished(build: build)
            }
        }

        // Update tracked statuses
        previousBuildStatuses = Dictionary(
            uniqueKeysWithValues: newBuilds.map { build in
                ("\(build.projectSlug)/\(build.branch)/\(build.workflowName)", build.status)
            }
        )
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }

        // Reset frame
        animationFrame = 0
        animateIcon()  // Show first frame immediately

        // Start timer
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.animateIcon()
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil

        // Remove layer animation if present (cleanup from previous version)
        if let button = statusItem.button, let layer = button.layer {
            layer.removeAnimation(forKey: "rotation")
        }
    }

    private func startLoadingAnimation() {
        guard animationTimer == nil else { return }

        // Reset frame
        animationFrame = 0
        animateLoadingIcon()  // Show first frame immediately

        // Start timer
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.animateLoadingIcon()
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    private func stopLoadingAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil

        // Remove layer animation if present (cleanup from previous version)
        if let button = statusItem.button, let layer = button.layer {
            layer.removeAnimation(forKey: "pulse")
        }
    }

    private func animateLoadingIcon() {
        guard let button = statusItem.button else { return }

        // Use cached frame instead of creating new image
        button.image = StatusIconService.shared.getLoadingFrame(index: animationFrame)

        animationFrame += 1
    }

    private func animateIcon() {
        guard let button = statusItem.button else { return }

        // Use cached frame instead of creating new image
        // Use orange (failing) frames if any build is failing, otherwise neutral (running) frames
        let runningImage =
            hasFailingBuilds
            ? StatusIconService.shared.getFailingFrame(index: animationFrame)
            : StatusIconService.shared.getRunningFrame(index: animationFrame)
        let failingImage = StatusIconService.shared.getFailingFrame(index: animationFrame)

        guard let animatedImage = runningImage else { return }

        // Update status bar icon
        button.image = animatedImage

        // Update menu item icons only when menu is open - updating invisible items leaks VM
        if isMenuOpen, let menu = statusItem.menu {
            for item in menu.items {
                if let build = item.representedObject as? Build {
                    if build.status == .running {
                        item.image = runningImage
                    } else if build.status == .failing {
                        item.image = failingImage
                    }
                }
            }
        }

        animationFrame += 1
    }

    @objc private func manualRefresh() {
        buildMonitor.manualRefresh()
    }

    @objc private func openBuild(_ sender: NSMenuItem) {
        guard let build = sender.representedObject as? Build,
            let url = URL(string: build.webURL)
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
