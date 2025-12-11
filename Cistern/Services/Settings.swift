import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let organization = "organization"
        static let pollInterval = "pollInterval"
    }

    static var organization: String? {
        get { defaults.string(forKey: Keys.organization) }
        set { defaults.set(newValue, forKey: Keys.organization) }
    }

    /// Poll interval in seconds (default: 10, range: 1-3600)
    static var pollInterval: TimeInterval {
        get {
            let value = defaults.double(forKey: Keys.pollInterval)
            return value > 0 ? value : 10
        }
        set { defaults.set(newValue, forKey: Keys.pollInterval) }
    }
}
