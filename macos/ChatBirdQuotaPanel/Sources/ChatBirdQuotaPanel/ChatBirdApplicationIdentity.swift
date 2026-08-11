import Foundation

let chatBirdBundleIdentifier = "dev.chatbird.app"
let chatBirdLaunchAgentLabel = chatBirdBundleIdentifier
let legacyChatBirdBundleIdentifier = "dev.chatbird.codex-quota-panel"
let legacyChatBirdLaunchAgentLabel = legacyChatBirdBundleIdentifier

private let migratableChatBirdPreferenceKeys = [
    "presentation-mode",
    "pet-enabled",
    "selected-quota-provider",
    "chatbird-pet-origin",
]

@discardableResult
func migrateLegacyChatBirdPreferences(
    from legacyValues: [String: Any],
    to defaults: UserDefaults
) -> [String] {
    var migratedKeys: [String] = []
    for key in migratableChatBirdPreferenceKeys {
        guard defaults.object(forKey: key) == nil,
              let value = legacyValues[key]
        else { continue }
        defaults.set(value, forKey: key)
        migratedKeys.append(key)
    }
    return migratedKeys
}

@discardableResult
func migrateLegacyChatBirdPreferencesIfNeeded(
    defaults: UserDefaults = .standard
) -> [String] {
    guard let legacyValues = UserDefaults.standard.persistentDomain(
        forName: legacyChatBirdBundleIdentifier
    ) else { return [] }
    return migrateLegacyChatBirdPreferences(
        from: legacyValues,
        to: defaults
    )
}
