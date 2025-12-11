import Cocoa

class StatusBarController {
    private var statusItem: NSStatusItem
    private var circleCIClient: CircleCIClient
    private var pollingTimer: Timer?
    private var animationTimer: Timer?
    private var loadingTimer: Timer?
    private var lastUpdatedTimer: Timer?
    private var builds: [Build] = []
    private var animationFrame: Int = 0
    private var isLoading: Bool = false
    private var lastUpdated: Date?
    private var lastUpdatedMenuItem: NSMenuItem?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        circleCIClient = CircleCIClient()

        setupStatusItem()
        buildMenu()
        startPolling()
        startLastUpdatedTimer()

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

    private func setupStatusItem() {
        if let button = statusItem.button {
            button.image = createStatusImage(symbolName: "circle.dotted", color: nil)
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
            let image = configuredImage.copy() as! NSImage
            image.lockFocus()
            color.set()
            let imageRect = NSRect(origin: .zero, size: image.size)
            imageRect.fill(using: .sourceAtop)
            image.unlockFocus()
            image.isTemplate = false
            return image
        } else {
            // Template mode for automatic dark/light adaptation
            let image = configuredImage.copy() as! NSImage
            image.isTemplate = true
            return image
        }
    }

    private func createRotatedCImage(angle: CGFloat, color: NSColor?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
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
            context.addArc(center: center, radius: radius, startAngle: .pi * 0.25, endAngle: .pi * 1.75, clockwise: true)
            context.strokePath()

            return true
        }
        image.isTemplate = (color == nil)
        return image
    }

    private func buildMenu() {
        let menu = NSMenu()

        if !KeychainService.hasToken() {
            let noTokenItem = NSMenuItem(title: "No API token configured", action: nil, keyEquivalent: "")
            noTokenItem.isEnabled = false
            menu.addItem(noTokenItem)
        } else if builds.isEmpty {
            let loadingItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            menu.addItem(loadingItem)
        } else {
            for build in builds.prefix(10) {
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

        let quitItem = NSMenuItem(title: "Quit Cistern", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
            // Will be animated
            item.image = createRotatedCImage(angle: 0, color: .systemOrange)
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

        item.attributedTitle = formatMenuTitle(projectName: build.projectName, branch: branch, workflowName: build.workflowName, duration: build.durationString)

        return item
    }

    private func formatMenuTitle(projectName: String, branch: String, workflowName: String, duration: String) -> NSAttributedString {
        let title = "\(projectName) • \(branch) • \(workflowName) "
        let result = NSMutableAttributedString(string: title)
        result.append(NSAttributedString(
            string: duration,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        ))
        return result
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let hasRunningBuilds = builds.contains { $0.status == .running }
        let overallStatus = builds.map { $0.status }.worstStatus()

        // Start or stop animation based on running builds
        if hasRunningBuilds {
            startAnimation()
        } else {
            stopAnimation()
            button.image = createStatusImage(symbolName: overallStatus.symbolName, color: overallStatus.color)
        }
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

        // Rotating "C" in system color (template mode)
        let angle = CGFloat(animationFrame % 36) * (.pi * 2 / 36)
        button.image = createRotatedCImage(angle: angle, color: nil)

        animationFrame += 1
    }

    private func animateIcon() {
        guard let button = statusItem.button else { return }

        // Slowly rotating "C" - 36 frames for full rotation (every 10°)
        let angle = CGFloat(animationFrame % 36) * (.pi * 2 / 36)
        let animatedImage = createRotatedCImage(angle: angle, color: .systemOrange)

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
                    item.attributedTitle = formatMenuTitle(projectName: build.projectName, branch: branch, workflowName: build.workflowName, duration: build.durationString)
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
            stopAnimation() // Stop running builds animation if active
            startLoadingAnimation()
        }

        Task {
            do {
                let fetchedBuilds = try await circleCIClient.fetchLatestBuilds()
                await MainActor.run {
                    self.isLoading = false
                    self.stopLoadingAnimation()
                    self.builds = fetchedBuilds
                    self.lastUpdated = Date()
                    self.buildMenu()
                    self.updateStatusIcon()
                }
            } catch {
                await MainActor.run {
                    print("Error fetching builds: \(error)")
                    self.isLoading = false
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
              let url = URL(string: build.webURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
