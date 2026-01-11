import Cocoa

class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var circleCIClient: CircleCIClient
    private var pollingTimer: Timer?
    private var animationTimer: Timer?
    private var lastUpdatedTimer: Timer?
    private var fetchTask: Task<Void, Never>?
    private var builds: [Build] = []
    private var isMenuOpen: Bool = false
    private var displayedBuilds: [Build] {
        // Always show all running builds first, then limit non-running builds
        let runningBuilds = builds.filter { $0.status == .running }
        let otherBuilds = builds.filter { $0.status != .running }
        let maxOtherBuilds = max(0, 10 - runningBuilds.count)
        return runningBuilds + otherBuilds.prefix(maxOtherBuilds)
    }
    private var animationFrame: Int = 0
    private var isLoading: Bool = true  // Start as loading until first fetch completes
    private var loadingCount: Int = 0
    private var lastUpdated: Date?
    private var lastUpdatedMenuItem: NSMenuItem?
    private var loadingMenuItem: NSMenuItem?

    // Cached animation frames to avoid recreating images every frame
    private var cachedRunningFrames: [NSImage] = []
    private var cachedLoadingFrames: [NSImage] = []
    private let totalFrames = 36  // One full rotation

    // Cached status images - precomputed at startup for each BuildStatus
    private var cachedStatusImages: [BuildStatus: NSImage] = [:]
    private var loadingImage: NSImage?  // The circle.dotted template image

    // Track previous build statuses for change detection
    private var previousBuildStatuses: [String: BuildStatus] = [:]

    // Stable menu structure - only created once
    private var buildMenuItems: [NSMenuItem] = []
    private var separatorBeforeLastUpdated: NSMenuItem?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        circleCIClient = CircleCIClient()

        super.init()

        cacheStatusImages()
        cacheAnimationFrames()
        setupStatusItem()
        buildMenu()
        startPolling()
        startLastUpdatedTimer()

        // Request notification permissions
        NotificationService.shared.requestAuthorization()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .settingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .tokenDidChange,
            object: nil
        )

        // Regenerate cached frames when appearance changes (light/dark mode)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    deinit {
        // Clean up all timers
        pollingTimer?.invalidate()
        lastUpdatedTimer?.invalidate()
        animationTimer?.invalidate()
        fetchTask?.cancel()

        // Remove notification observers
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func cacheStatusImages() {
        // Pre-generate status images for all build statuses
        for status in [
            BuildStatus.success, .running, .failed, .error, .failing,
            .onHold, .canceled, .notRun, .unknown,
        ] {
            if let image = createStatusImage(symbolName: status.symbolName, color: status.color) {
                cachedStatusImages[status] = image
            }
        }
        // Also cache the loading/unknown template image
        loadingImage = createStatusImage(symbolName: "circle.dotted", color: nil)
    }

    private func cacheAnimationFrames() {
        // Pre-generate all animation frames to avoid creating images every frame
        cachedRunningFrames = (0..<totalFrames).map { frame in
            let angle = CGFloat(frame) * (.pi * 2 / CGFloat(totalFrames))
            return createRotatedCImage(angle: angle, color: .systemOrange)
        }
        cachedLoadingFrames = (0..<totalFrames).map { frame in
            let phase = CGFloat(frame) / CGFloat(totalFrames)
            return createDottedCircleWithPulsingDot(phase: phase)
        }
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

    @objc private func settingsDidChange() {
        // Restart polling with new interval
        pollingTimer?.invalidate()
        pollingTimer = nil
        startPolling()
    }

    @objc private func appearanceDidChange() {
        // Regenerate all cached images with new appearance colors
        cacheStatusImages()
        cacheAnimationFrames()
        updateStatusIcon()
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            button.image = loadingImage
        }
        statusItem.isVisible = true
    }

    private func createStatusImage(symbolName: String, color: NSColor?) -> NSImage? {
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CircleCI Status") else {
            return nil
        }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let configuredImage = baseImage.withSymbolConfiguration(config) else {
            return nil
        }

        if let color = color {
            // Create colored version by drawing with tint
            guard let img = configuredImage.copy() as? NSImage else { return nil }
            img.lockFocus()
            color.set()
            let imageRect = NSRect(origin: .zero, size: img.size)
            imageRect.fill(using: .sourceAtop)
            img.unlockFocus()
            img.isTemplate = false
            return img
        } else {
            // Template mode for automatic dark/light adaptation
            guard let img = configuredImage.copy() as? NSImage else { return nil }
            img.isTemplate = true
            return img
        }
    }

    private func createDottedCircleWithPulsingDot(phase: CGFloat) -> NSImage {
        // Get the same SF Symbol used for idle state
        guard let baseImage = NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: nil) else {
            return NSImage()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let symbolImage = baseImage.withSymbolConfiguration(config) else {
            return NSImage()
        }

        // Create a copy to draw on
        guard let image = symbolImage.copy() as? NSImage else {
            return NSImage()
        }

        image.lockFocus()

        // Tint with labelColor for proper dark/light mode support
        NSColor.labelColor.set()
        let imageRect = NSRect(origin: .zero, size: image.size)
        imageRect.fill(using: .sourceAtop)

        // Draw pulsing green dot in center
        // Use sine wave for smooth pulse (0.3 to 1.0 opacity range)
        let pulseAlpha = 0.3 + 0.7 * (0.5 + 0.5 * sin(phase * .pi * 2))
        let greenDotRadius: CGFloat = 2.0
        // Use floor to avoid rounding up from .5 values
        let centerX = floor(image.size.width / 2)
        let centerY = floor(image.size.height / 2)
        NSColor.systemGreen.withAlphaComponent(pulseAlpha).setFill()
        let greenDotRect = CGRect(
            x: centerX - greenDotRadius,
            y: centerY - greenDotRadius,
            width: greenDotRadius * 2,
            height: greenDotRadius * 2
        )
        NSBezierPath(ovalIn: greenDotRect).fill()

        image.unlockFocus()
        image.isTemplate = false  // Not template since we have a colored dot
        return image
    }

    private func createRotatedCImage(angle: CGFloat, color: NSColor?) -> NSImage {
        let size = NSSize(width: 18, height: 18)

        // Create image with fixed bitmap representation (NOT a drawing handler)
        // Drawing handlers create new bitmap representations on each display, causing VM leaks
        let image = NSImage(size: size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        // Move to center, rotate, move back
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: angle)
        context.translateBy(x: -size.width / 2, y: -size.height / 2)

        // Draw "C" shape (arc)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = 6
        let lineWidth: CGFloat = 2.5

        let drawColor = color ?? NSColor.black
        context.setStrokeColor(drawColor.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)

        // Draw arc from roughly 45° to 315° (leaving a gap for the "C" opening)
        context.addArc(
            center: center, radius: radius, startAngle: .pi * 0.25, endAngle: .pi * 1.75, clockwise: true)
        context.strokePath()

        image.unlockFocus()
        image.isTemplate = (color == nil)
        return image
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
        } else if builds.isEmpty && isLoading {
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
        } else if builds.isEmpty {
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
        separatorBeforeLastUpdated?.isHidden = visibleBuilds.isEmpty && !isLoading && KeychainService.hasToken()
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
            item.image = cachedRunningFrames.first
        } else {
            item.image = cachedStatusImages[build.status]
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
        guard let lastUpdated = lastUpdated else {
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
        let hasRunningBuilds = visibleBuilds.contains { $0.status == .running }
        let overallStatus = visibleBuilds.map { $0.status }.worstStatus()

        // Check if all builds are stale (> 30 mins since last completed)
        let staleThreshold: TimeInterval = 30 * 60
        let mostRecentStop = visibleBuilds.compactMap { $0.stoppedAt }.max()
        let isStale =
            !hasRunningBuilds && (mostRecentStop == nil || Date().timeIntervalSince(mostRecentStop!) > staleThreshold)

        // Start or stop animation based on running builds
        if hasRunningBuilds {
            startAnimation()
        } else {
            stopAnimation()
            // Only update image if it actually changed to avoid VM leaks
            let newImage = isStale ? loadingImage : cachedStatusImages[overallStatus]
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
        let frameIndex = animationFrame % totalFrames
        button.image = cachedLoadingFrames[frameIndex]

        animationFrame += 1
    }

    private func animateIcon() {
        guard let button = statusItem.button else { return }

        // Use cached frame instead of creating new image
        let frameIndex = animationFrame % totalFrames
        let animatedImage = cachedRunningFrames[frameIndex]

        // Update status bar icon
        button.image = animatedImage

        // Update menu item icons only when menu is open - updating invisible items leaks VM
        if isMenuOpen, let menu = statusItem.menu {
            for item in menu.items {
                if let build = item.representedObject as? Build, build.status == .running {
                    item.image = animatedImage
                }
            }
        }

        animationFrame += 1
    }

    private func startPolling() {
        refreshData()

        let interval = Settings.pollInterval
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }

    @objc private func refreshData() {
        refreshData(showLoading: builds.isEmpty)
    }

    @objc private func manualRefresh() {
        refreshData(showLoading: true, force: true)
    }

    private func refreshData(showLoading: Bool, force: Bool = false) {
        guard KeychainService.hasToken() else {
            builds = []
            buildMenu()
            return
        }

        // Prevent concurrent fetches
        if let currentTask = fetchTask {
            if force {
                currentTask.cancel()
            } else {
                return  // Skip update if one is already in progress
            }
        }

        // Show loading animation only on manual refresh or initial load
        if showLoading {
            isLoading = true
            loadingCount = 0
            stopAnimation()  // Stop running builds animation if active
            startLoadingAnimation()
        }

        fetchTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let fetchedBuilds = try await self.circleCIClient.fetchLatestBuilds { [weak self] count in
                    // Use DispatchQueue instead of Task to avoid accumulating Task objects
                    DispatchQueue.main.async { [weak self] in
                        self?.loadingCount = count
                        self?.loadingMenuItem?.title = "Loading... (\(count))"
                    }
                }

                // Check for cancellation before updating UI
                try Task.checkCancellation()

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.fetchTask = nil
                    self.isLoading = false
                    self.loadingCount = 0
                    self.stopLoadingAnimation()
                    self.checkForBuildChangesAndNotify(fetchedBuilds)
                    self.builds = fetchedBuilds
                    self.lastUpdated = Date()
                    self.buildMenu()
                    self.updateStatusIcon()
                }
            } catch is CancellationError {
                // Task was cancelled, do nothing
                await MainActor.run { [weak self] in
                    self?.fetchTask = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.fetchTask = nil

                    // Don't clear builds on error, just stop loading state
                    self.isLoading = false
                    self.loadingCount = 0
                    self.stopLoadingAnimation()
                    // self.builds = [] // Don't clear existing builds on transient errors
                    self.buildMenu()  // Update menu (e.g. to remove loading status)
                    self.updateStatusIcon()
                }
            }
        }
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
