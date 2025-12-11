import Cocoa

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var tokenField: NSSecureTextField!
    private var orgField: NSTextField!
    private var pollSlider: NSSlider!
    private var pollValueLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var saveButton: NSButton!
    private var testButton: NSButton!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 290),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cistern Settings"
        window.center()

        super.init(window: window)

        setupUI()
        loadSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let padding: CGFloat = 20
        let fieldHeight: CGFloat = 24
        let buttonWidth: CGFloat = 100

        // Token label
        let tokenLabel = NSTextField(labelWithString: "CircleCI API Token:")
        tokenLabel.frame = NSRect(x: padding, y: 240, width: 150, height: fieldHeight)
        contentView.addSubview(tokenLabel)

        // Token field
        tokenField = NSSecureTextField(frame: NSRect(
            x: padding,
            y: 210,
            width: contentView.bounds.width - (padding * 2),
            height: fieldHeight
        ))
        tokenField.placeholderString = "Enter your CircleCI personal API token"
        contentView.addSubview(tokenField)

        // Token help text
        let tokenHelpLabel = NSTextField(wrappingLabelWithString: "Get your token from CircleCI → User Settings → Personal API Tokens")
        tokenHelpLabel.frame = NSRect(x: padding, y: 185, width: contentView.bounds.width - (padding * 2), height: 20)
        tokenHelpLabel.font = NSFont.systemFont(ofSize: 11)
        tokenHelpLabel.textColor = .secondaryLabelColor
        contentView.addSubview(tokenHelpLabel)

        // Org label
        let orgLabel = NSTextField(labelWithString: "Organization (optional):")
        orgLabel.frame = NSRect(x: padding, y: 155, width: 200, height: fieldHeight)
        contentView.addSubview(orgLabel)

        // Org field
        orgField = NSTextField(frame: NSRect(
            x: padding,
            y: 125,
            width: contentView.bounds.width - (padding * 2),
            height: fieldHeight
        ))
        orgField.placeholderString = "e.g., gh/my-org (leave empty for all orgs)"
        contentView.addSubview(orgField)

        // Poll interval label
        let pollLabel = NSTextField(labelWithString: "Refresh interval:")
        pollLabel.frame = NSRect(x: padding, y: 90, width: 120, height: fieldHeight)
        contentView.addSubview(pollLabel)

        // Poll value label (shows current value)
        pollValueLabel = NSTextField(labelWithString: "10s")
        pollValueLabel.frame = NSRect(x: contentView.bounds.width - padding - 50, y: 90, width: 50, height: fieldHeight)
        pollValueLabel.alignment = .right
        contentView.addSubview(pollValueLabel)

        // Poll interval slider (logarithmic scale: 1s to 1h)
        pollSlider = NSSlider(frame: NSRect(
            x: padding,
            y: 65,
            width: contentView.bounds.width - (padding * 2),
            height: 21
        ))
        pollSlider.minValue = 0
        pollSlider.maxValue = 100
        pollSlider.target = self
        pollSlider.action = #selector(sliderChanged(_:))
        contentView.addSubview(pollSlider)

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: padding, y: 35, width: contentView.bounds.width - (padding * 2), height: fieldHeight)
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        contentView.addSubview(statusLabel)

        // Test button
        testButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        testButton.frame = NSRect(
            x: contentView.bounds.width - padding - buttonWidth - 10 - buttonWidth,
            y: padding - 10,
            width: buttonWidth,
            height: 30
        )
        testButton.bezelStyle = .rounded
        contentView.addSubview(testButton)

        // Save button
        saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.frame = NSRect(
            x: contentView.bounds.width - padding - buttonWidth,
            y: padding - 10,
            width: buttonWidth,
            height: 30
        )
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)
    }

    private func loadSettings() {
        if let token = KeychainService.getToken() {
            tokenField.stringValue = token
        }
        if let org = Settings.organization {
            orgField.stringValue = org
        }
        pollSlider.doubleValue = secondsToSlider(Settings.pollInterval)
        updatePollLabel()
    }

    // Convert slider value (0-100) to seconds (1-3600) using logarithmic scale
    private func sliderToSeconds(_ sliderValue: Double) -> TimeInterval {
        // Map 0-100 to 1-3600 logarithmically
        let minLog = log(1.0)
        let maxLog = log(3600.0)
        let scale = minLog + (sliderValue / 100.0) * (maxLog - minLog)
        return exp(scale)
    }

    // Convert seconds to slider value
    private func secondsToSlider(_ seconds: TimeInterval) -> Double {
        let minLog = log(1.0)
        let maxLog = log(3600.0)
        let scale = log(max(1, min(3600, seconds)))
        return ((scale - minLog) / (maxLog - minLog)) * 100.0
    }

    private func formatInterval(_ seconds: TimeInterval) -> String {
        let secs = Int(round(seconds))
        if secs < 60 {
            return "\(secs)s"
        } else if secs < 3600 {
            let mins = secs / 60
            let remainSecs = secs % 60
            if remainSecs == 0 {
                return "\(mins)m"
            } else {
                return "\(mins)m \(remainSecs)s"
            }
        } else {
            return "1h"
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        updatePollLabel()
    }

    private func updatePollLabel() {
        let seconds = sliderToSeconds(pollSlider.doubleValue)
        pollValueLabel.stringValue = formatInterval(seconds)
    }

    @objc private func testConnection() {
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !token.isEmpty else {
            showStatus("Please enter a token", isError: true)
            return
        }

        // Temporarily save the token for testing
        let previousToken = KeychainService.getToken()
        _ = KeychainService.setToken(token)

        showStatus("Testing...", isError: false)
        testButton.isEnabled = false

        let client = CircleCIClient()
        Task {
            do {
                let success = try await client.testConnection()
                await MainActor.run {
                    if success {
                        showStatus("Connection successful!", isError: false)
                        statusLabel.textColor = .systemGreen
                    } else {
                        showStatus("Connection failed", isError: true)
                        // Restore previous token if test failed
                        if let prev = previousToken {
                            _ = KeychainService.setToken(prev)
                        } else {
                            KeychainService.deleteToken()
                        }
                    }
                    testButton.isEnabled = true
                }
            } catch {
                await MainActor.run {
                    showStatus("Error: \(error.localizedDescription)", isError: true)
                    // Restore previous token on error
                    if let prev = previousToken {
                        _ = KeychainService.setToken(prev)
                    } else {
                        KeychainService.deleteToken()
                    }
                    testButton.isEnabled = true
                }
            }
        }
    }

    @objc private func saveSettings() {
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let org = orgField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pollInterval = sliderToSeconds(pollSlider.doubleValue)

        guard !token.isEmpty else {
            showStatus("Please enter a token", isError: true)
            return
        }

        if KeychainService.setToken(token) {
            Settings.organization = org.isEmpty ? nil : org
            Settings.pollInterval = pollInterval
            showStatus("Settings saved successfully!", isError: false)
            statusLabel.textColor = .systemGreen

            // Close window after short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.window?.close()
                // Post notification to refresh data and update poll interval
                NotificationCenter.default.post(name: .settingsDidChange, object: nil)
            }
        } else {
            showStatus("Failed to save token to Keychain", isError: true)
        }
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .labelColor
    }
}

extension Notification.Name {
    static let tokenDidChange = Notification.Name("tokenDidChange")
    static let settingsDidChange = Notification.Name("settingsDidChange")
}
