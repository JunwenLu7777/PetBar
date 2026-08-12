import Foundation

let threadHelmBundleIdentifier = "dev.threadhelm.app"
let threadHelmLaunchAgentLabel = threadHelmBundleIdentifier
let legacyThreadHelmBundleIdentifiers = [
    "dev.chatbird.app",
    "dev.chatbird.codex-quota-panel",
]
let legacyThreadHelmLaunchAgentLabels = legacyThreadHelmBundleIdentifiers

private let migratableThreadHelmPreferenceKeys = [
    "selected-quota-provider",
]

@discardableResult
func migrateLegacyThreadHelmPreferences(
    from legacyDomains: [[String: Any]],
    to defaults: UserDefaults
) -> [String] {
    var migratedKeys: [String] = []
    for legacyValues in legacyDomains {
        for key in migratableThreadHelmPreferenceKeys {
            guard defaults.object(forKey: key) == nil,
                  let value = legacyValues[key]
            else { continue }
            defaults.set(value, forKey: key)
            migratedKeys.append(key)
        }
    }
    return migratedKeys
}

@discardableResult
func migrateLegacyThreadHelmPreferencesIfNeeded(
    defaults: UserDefaults = .standard
) -> [String] {
    let legacyDomains = legacyThreadHelmBundleIdentifiers.compactMap {
        UserDefaults.standard.persistentDomain(forName: $0)
    }
    return migrateLegacyThreadHelmPreferences(
        from: legacyDomains,
        to: defaults
    )
}
