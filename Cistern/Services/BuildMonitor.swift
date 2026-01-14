import Cocoa
import Foundation

@MainActor
class BuildMonitor {
    private let circleCIClient: CircleCIClient
    private var pollingTask: Task<Void, Never>?
    private var isFetching: Bool = false

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
        pollingTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func startPolling() {
        // Cancel any existing polling task
        pollingTask?.cancel()

        // Create a single long-running Task that polls in a loop
        // This avoids creating thousands of Tasks over time which leaks VM
        pollingTask = Task { [weak self] in
            // Initial fetch
            await self?.doFetch(showLoading: false)

            // Polling loop
            while !Task.isCancelled {
                let interval = Settings.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

                if Task.isCancelled { break }
                await self?.doFetch(showLoading: false)
            }
        }
    }

    func manualRefresh() {
        Task {
            await doFetch(showLoading: true)
        }
    }

    @objc private func settingsDidChange() {
        // Restart polling with new settings
        startPolling()
    }

    private func doFetch(showLoading: Bool) async {
        guard KeychainService.hasToken() else {
            self.builds = []
            self.onBuildsChanged?([])
            return
        }

        // Prevent concurrent fetches
        guard !isFetching else { return }
        isFetching = true

        // Determine if we should show loading state
        let shouldShowLoading = showLoading || builds.isEmpty

        if shouldShowLoading {
            isLoading = true
            onLoadingStateChanged?(true, 0)
        }

        do {
            let fetchedBuilds = try await circleCIClient.fetchLatestBuilds()

            isFetching = false
            isLoading = false
            onLoadingStateChanged?(false, 0)

            builds = fetchedBuilds
            lastUpdated = Date()
            onBuildsChanged?(fetchedBuilds)
        } catch is CancellationError {
            isFetching = false
        } catch {
            isFetching = false
            isLoading = false
            onLoadingStateChanged?(false, 0)
            onError?(error)
        }
    }
}
