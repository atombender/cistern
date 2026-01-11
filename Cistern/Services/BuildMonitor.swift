import Cocoa
import Foundation

class BuildMonitor {
    private let circleCIClient: CircleCIClient
    private var pollingTimer: Timer?
    private var fetchTask: Task<Void, Never>?

    // State
    private(set) var builds: [Build] = []
    private(set) var isLoading: Bool = true
    private(set) var lastUpdated: Date?

    // Callbacks
    var onBuildsChanged: (([Build]) -> Void)?
    var onLoadingStateChanged: ((Bool, Int) -> Void)?  // isLoading, count
    var onError: ((Error) -> Void)?

    init() {
        self.circleCIClient = CircleCIClient()

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

    deinit {
        pollingTimer?.invalidate()
        fetchTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func startPolling() {
        refreshData()

        let interval = Settings.pollInterval
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }

    func manualRefresh() {
        refreshData(showLoading: true, force: true)
    }

    @objc private func settingsDidChange() {
        pollingTimer?.invalidate()
        startPolling()
    }

    private func refreshData(showLoading: Bool = false, force: Bool = false) {
        guard KeychainService.hasToken() else {
            self.builds = []
            self.onBuildsChanged?([])
            return
        }

        // Prevent concurrent fetches
        if let currentTask = fetchTask {
            if force {
                currentTask.cancel()
            } else {
                return
            }
        }

        // Determine if we should show loading state
        // If it's a manual refresh, or if we have no builds yet (initial load), show loading
        let shouldShowLoading = showLoading || builds.isEmpty

        if shouldShowLoading {
            isLoading = true
            onLoadingStateChanged?(true, 0)
        }

        fetchTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let fetchedBuilds = try await self.circleCIClient.fetchLatestBuilds { [weak self] count in
                    DispatchQueue.main.async { [weak self] in
                        if self?.isLoading == true {
                            self?.onLoadingStateChanged?(true, count)
                        }
                    }
                }

                try Task.checkCancellation()

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.fetchTask = nil
                    self.isLoading = false
                    self.onLoadingStateChanged?(false, 0)

                    self.builds = fetchedBuilds
                    self.lastUpdated = Date()
                    self.onBuildsChanged?(fetchedBuilds)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.fetchTask = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.fetchTask = nil
                    self.isLoading = false
                    self.onLoadingStateChanged?(false, 0)
                    self.onError?(error)
                    // Don't clear builds on error, keep existing
                }
            }
        }
    }
}
