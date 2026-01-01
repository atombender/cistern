import Cocoa

class StatusBarController {
    private var statusItem: NSStatusItem
    private var circleCIClient: CircleCIClient
    private var pollingTimer: Timer?
    private var animationTimer: Timer?
    private var loadingTimer: Timer?
    private var lastUpdatedTimer: Timer?
    private var builds: [Build] = []
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

    // Cached status images to avoid recreating on every menu build
    private var cachedStatusImages: [String: NSImage] = [:]

    // Track previous build statuses for change detection
    private var previousBuildStatuses: [String: BuildStatus] = [:]

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        circleCIClient = CircleCIClient()

        setupStatusItem()
        cacheAnimationFrames()
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
            self?.lastUpdatedMenuItem?.title = self?.lastUpdatedString() ?? ""
        }
        RunLoop.main.add(lastUpdatedTimer!, forMode: .common)
    }

    @objc private func settingsDidChange() {
        // Restart polling with new interval
        pollingTimer?.invalidate()
        pollingTimer = nil
        startPolling()
    }

    @objc private func appearanceDidChange() {
        // Regenerate frames with new appearance colors
        cachedLoadingFrames = (0..<totalFrames).map { frame in
            let phase = CGFloat(frame) / CGFloat(totalFrames)
            return createDottedCircleWithPulsingDot(phase: phase)
        }
        cachedStatusImages.removeAll()
        updateStatusIcon()
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            button.image = createStatusImage(symbolName: "circle.dotted", color: nil)
        }
        statusItem.isVisible = true
    }

    private func createStatusImage(symbolName: String, color: NSColor?) -> NSImage? {
        // Create cache key from symbol name and color
        let colorKey = color?.description ?? "template"
        let cacheKey = "\(symbolName)-\(colorKey)"

        // Return cached image if available
        if let cached = cachedStatusImages[cacheKey] {
            return cached
        }

        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CircleCI Status") else {
            return nil
        }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let configuredImage = baseImage.withSymbolConfiguration(config) else {
            return nil
        }

        let image: NSImage?
        if let color = color {
            // Create colored version by drawing with tint
            guard let img = configuredImage.copy() as? NSImage else { return nil }
            img.lockFocus()
            color.set()
            let imageRect = NSRect(origin: .zero, size: img.size)
            imageRect.fill(using: .sourceAtop)
            img.unlockFocus()
            img.isTemplate = false
            image = img
        } else {
            // Template mode for automatic dark/light adaptation
            guard let img = configuredImage.copy() as? NSImage else { return nil }
            img.isTemplate = true
            image = img
        }

        // Cache and return
        if let image = image {
            cachedStatusImages[cacheKey] = image
        }
        return image
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
        let image = NSImage(size: size, flipped: false) { _ in
            let context = NSGraphicsContext.current!.cgContext

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

            return true
        }
        image.isTemplate = (color == nil)
        return image
    }

    private func buildMenu() {
        let menu = NSMenu()
        loadingMenuItem = nil

        if !KeychainService.hasToken() {
            let noTokenItem = NSMenuItem(title: "No API token configured", action: nil, keyEquivalent: "")
            noTokenItem.isEnabled = false
            menu.addItem(noTokenItem)
        } else if builds.isEmpty && isLoading {
            let loadingText = loadingCount > 0 ? "Loading... (\(loadingCount))" : "Loading..."
            loadingMenuItem = NSMenuItem(title: loadingText, action: nil, keyEquivalent: "")
            loadingMenuItem?.isEnabled = false
            menu.addItem(loadingMenuItem!)
        } else if builds.isEmpty {
            let noBuildsItem = NSMenuItem(title: "No recent builds found", action: nil, keyEquivalent: "")
            noBuildsItem.isEnabled = false
            menu.addItem(noBuildsItem)
        } else {
            for build in displayedBuilds {
                let item = createMenuItem(for: build)
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

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

        statusItem.menu = menu
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

    private func createMenuItem(for build: Build) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(openBuild(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = build

        // Set icon
        if build.status == .running {
            // Use cached frame (will be animated)
            item.image = cachedRunningFrames.first
        } else {
            item.image = createStatusImage(symbolName: build.status.symbolName, color: build.status.color)
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

        return item
    }

    private func formatMenuTitle(
        projectName: String, branch: String, workflowName: String, duration: String
    ) -> NSAttributedString {
        let title = "\(projectName) • \(branch) • \(workflowName) "
        let result = NSMutableAttributedString(string: title)
        result.append(
            NSAttributedString(
                string: duration,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            ))
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
            if isStale {
                // Show neutral icon in system color
                button.image = createStatusImage(symbolName: "circle.dotted", color: nil)
            } else {
                button.image = createStatusImage(symbolName: overallStatus.symbolName, color: overallStatus.color)
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

        animationFrame = 0
        // Use .common run loop mode so animation continues while menu is open
        animationTimer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.animateIcon()
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func startLoadingAnimation() {
        guard loadingTimer == nil else { return }

        animationFrame = 0
        loadingTimer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            self?.animateLoadingIcon()
        }
        RunLoop.main.add(loadingTimer!, forMode: .common)
    }

    private func stopLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = nil
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

        // Update menu item icons and durations for running builds
        if let menu = statusItem.menu {
            for item in menu.items {
                if let build = item.representedObject as? Build, build.status == .running {
                    item.image = animatedImage

                    // Update duration text
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
        refreshData(showLoading: true)
    }

    private func refreshData(showLoading: Bool) {
        guard KeychainService.hasToken() else {
            builds = []
            buildMenu()
            return
        }

        // Show loading animation only on manual refresh or initial load
        if showLoading {
            isLoading = true
            loadingCount = 0
            stopAnimation()  // Stop running builds animation if active
            startLoadingAnimation()
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let fetchedBuilds = try await self.circleCIClient.fetchLatestBuilds { [weak self] count in
                    Task { @MainActor [weak self] in
                        self?.loadingCount = count
                        self?.loadingMenuItem?.title = "Loading... (\(count))"
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.isLoading = false
                    self.loadingCount = 0
                    self.stopLoadingAnimation()
                    self.checkForBuildChangesAndNotify(fetchedBuilds)
                    self.builds = fetchedBuilds
                    self.lastUpdated = Date()
                    self.buildMenu()
                    self.updateStatusIcon()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.isLoading = false
                    self.loadingCount = 0
                    self.stopLoadingAnimation()
                    self.builds = []
                    self.buildMenu()
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
