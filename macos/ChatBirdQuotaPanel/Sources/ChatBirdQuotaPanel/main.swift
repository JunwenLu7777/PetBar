import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private let refreshInterval: TimeInterval = 60
private let taskProgressRefreshInterval: TimeInterval = 2
private let codexTaskProgressRescanInterval: TimeInterval = 5
private let taskAnimationFramesPerSecond: TimeInterval = 8
private let taskAnimationDegreesPerTick: CGFloat = 36
private let panelVersion = "1.0.0"
private let panelEdition = "chatbird-nt"
private let chatBirdPetID = "chatbird-nt"
private let chatBirdPetAvatarID = "custom:\(chatBirdPetID)"
// Track fast enough that the panel preserves its 14 px visual gap while the
// pet window is moving between animation positions.
private let followInterval: TimeInterval = 0.03
private let idlePetLocationPollInterval: TimeInterval = 0.20
private let petMovementGraceInterval: TimeInterval = 0.50
private let overlayStateRefreshInterval: TimeInterval = 0.25
private let taskProgressRowHeight: CGFloat = 28
private let maximumVisibleTaskRows = 5

private enum QuotaLevel: Equatable {
    case healthy
    case warning
    case critical
    case exhausted
}

private func quotaLevel(for remainingPercent: Int) -> QuotaLevel {
    switch max(0, min(100, remainingPercent)) {
    case 50...100:
        return .healthy
    case 20...49:
        return .warning
    case 1...19:
        return .critical
    default:
        return .exhausted
    }
}

private let quotaResetClockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = .current
    formatter.dateFormat = "HH:mm"
    return formatter
}()

private let quotaResetCalendarFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = .current
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter
}()

private func quotaResetTimeDescription(
    _ date: Date,
    now: Date = Date()
) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
        return "今天 \(quotaResetClockFormatter.string(from: date))"
    }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
       calendar.isDate(date, inSameDayAs: tomorrow)
    {
        return "明天 \(quotaResetClockFormatter.string(from: date))"
    }
    return quotaResetCalendarFormatter.string(from: date)
}

private struct CodexResetCreditsPresentation: Equatable {
    let availableText: String
    let expiryLines: [String]
    let hasAvailableCredits: Bool
}

private func codexResetCreditsPresentation(
    snapshot: CodexResetCreditsSnapshot?,
    now: Date = Date()
) -> CodexResetCreditsPresentation {
    guard let snapshot else {
        return CodexResetCreditsPresentation(
            availableText: "重置额度暂不可用",
            expiryLines: [],
            hasAvailableCredits: false
        )
    }
    let credits = snapshot.availableCredits(at: now)
    guard !credits.isEmpty else {
        return CodexResetCreditsPresentation(
            availableText: "暂无可用重置额度",
            expiryLines: [],
            hasAvailableCredits: false
        )
    }
    var expiryTexts = credits.prefix(4).map { credit in
        credit.expiresAt.map { quotaResetTimeDescription($0, now: now) } ?? "无过期时间"
    }
    if credits.count > expiryTexts.count {
        expiryTexts[expiryTexts.count - 1] = "+\(credits.count - expiryTexts.count + 1)"
    }
    let expiryLines: [String]
    if expiryTexts.count <= 2 {
        expiryLines = expiryTexts
    } else {
        expiryLines = [
            expiryTexts.prefix(2).joined(separator: " · "),
            expiryTexts.dropFirst(2).joined(separator: " · "),
        ]
    }
    return CodexResetCreditsPresentation(
        availableText: "\(credits.count) 次可用",
        expiryLines: expiryLines,
        hasAvailableCredits: true
    )
}

// A fixed landscape canvas keeps ChatBird compact above the pet while giving
// task titles enough horizontal room to remain useful and clickable.
private let panelDesignWidth: CGFloat = 388
private let baseExpandedPanelHeight: CGFloat = 226
private func panelSizeForTaskRows(_ count: Int) -> NSSize {
    _ = max(1, min(maximumVisibleTaskRows, count))
    return NSSize(width: panelDesignWidth, height: baseExpandedPanelHeight)
}

private func rectDiffers(
    _ lhs: NSRect,
    from rhs: NSRect,
    tolerance: CGFloat = 0.1
) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) > tolerance
        || abs(lhs.origin.y - rhs.origin.y) > tolerance
        || abs(lhs.size.width - rhs.size.width) > tolerance
        || abs(lhs.size.height - rhs.size.height) > tolerance
}

private func shouldPollPetLocation(
    now: CFAbsoluteTime,
    lastPollAt: CFAbsoluteTime,
    lastMovementAt: CFAbsoluteTime,
    force: Bool
) -> Bool {
    if force || lastPollAt <= 0 {
        return true
    }
    let recentlyMoving = lastMovementAt > 0
        && now - lastMovementAt <= petMovementGraceInterval
    let interval = recentlyMoving
        ? followInterval
        : idlePetLocationPollInterval
    return now - lastPollAt >= interval
}

private let expandedPanelSize = panelSizeForTaskRows(1)
private let panelPetGap: CGFloat = 14
private let panelScreenMargin: CGFloat = 8
private let pointerTipBottomInset: CGFloat = 1
private let pointerHorizontalSafeInset: CGFloat = 18
private let canonicalPetSpriteSize = NSSize(width: 163, height: 177)
private let petAtlasFrameSize = NSSize(width: 192, height: 208)
// Alpha bounds (threshold 20) of every distinct visible frame in ChatBird's
// 8x11 v2 atlas. Matching both width and height lets us recover the zoom factor
// without mistaking animation-specific silhouette changes for a resize.
private let petFrameVisiblePixelSizes: [NSSize] = [
    NSSize(width: 121, height: 190), NSSize(width: 121, height: 194),
    NSSize(width: 123, height: 187), NSSize(width: 125, height: 183),
    NSSize(width: 125, height: 191), NSSize(width: 126, height: 192),
    NSSize(width: 131, height: 183), NSSize(width: 132, height: 198),
    NSSize(width: 133, height: 182), NSSize(width: 133, height: 198),
    NSSize(width: 135, height: 183), NSSize(width: 135, height: 187),
    NSSize(width: 136, height: 188), NSSize(width: 136, height: 198),
    NSSize(width: 137, height: 179), NSSize(width: 137, height: 193),
    NSSize(width: 138, height: 175), NSSize(width: 141, height: 185),
    NSSize(width: 141, height: 198), NSSize(width: 142, height: 198),
    NSSize(width: 143, height: 198), NSSize(width: 144, height: 198),
    NSSize(width: 146, height: 198), NSSize(width: 147, height: 198),
    NSSize(width: 148, height: 198), NSSize(width: 149, height: 198),
    NSSize(width: 153, height: 198), NSSize(width: 155, height: 198),
    NSSize(width: 162, height: 198), NSSize(width: 163, height: 198),
    NSSize(width: 165, height: 198), NSSize(width: 167, height: 198),
    NSSize(width: 171, height: 198), NSSize(width: 175, height: 198),
    NSSize(width: 177, height: 198), NSSize(width: 180, height: 198),
    NSSize(width: 181, height: 198), NSSize(width: 182, height: 104),
    NSSize(width: 182, height: 144), NSSize(width: 182, height: 179),
    NSSize(width: 182, height: 183), NSSize(width: 182, height: 186),
    NSSize(width: 182, height: 196),
]
private let visualScaleTolerance: CGFloat = 0.12
private let minimumPanelScale: CGFloat = 0.20
private let maximumPanelScale: CGFloat = 8
// Keep the information panel readable even when the pet sprite is displayed
// at its smaller default scale. 388×226 at 0.95 is about 369×215 points,
// matching the user-marked target region while remaining centered on the pet.
private let minimumPresentedPanelScale: CGFloat = 0.95
// The v2 sprite has a small transparent top padding inside Codex's stored
// mascot anchor. Add it so the panel measures from ChatBird's visible tuft.
private let petSpriteTopPaddingInsideAnchor: CGFloat = 7

private final class ChatBirdPetSelectionStore {
    private let configURL: URL

    init(configURL: URL? = nil) {
        if let configURL {
            self.configURL = configURL
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let codexHome = environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true).path
        self.configURL = URL(fileURLWithPath: codexHome, isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    func chatBirdIsSelected() -> Bool {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return false
        }
        var section = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let sectionName = Self.sectionName(in: line) {
                section = sectionName
                continue
            }
            guard section == "desktop", Self.isSelectedAvatarLine(line),
                  let quoteStart = line.firstIndex(of: "\"")
            else { continue }
            let remainder = line[line.index(after: quoteStart)...]
            guard let quoteEnd = remainder.firstIndex(of: "\"") else { continue }
            return String(remainder[..<quoteEnd]) == chatBirdPetAvatarID
        }
        return false
    }

    @discardableResult
    func selectChatBird() -> Bool {
        do {
            let original = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            let updated = Self.updatingDesktopSelection(in: original, avatarID: chatBirdPetAvatarID)
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let data = updated.data(using: .utf8) else { return false }
            try data.write(to: configURL, options: .atomic)
            return chatBirdIsSelected()
        } catch {
            return false
        }
    }

    static func updatingDesktopSelection(in text: String, avatarID: String) -> String {
        let selectionLine = "selected-avatar-id = \"\(avatarID)\""
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var output: [String] = []
        var section = ""
        var desktopSeen = false
        var desktopSelectionWritten = false

        func appendDesktopSelectionIfNeeded() {
            guard section == "desktop", !desktopSelectionWritten else { return }
            output.append(selectionLine)
            desktopSelectionWritten = true
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let sectionName = sectionName(in: trimmed) {
                appendDesktopSelectionIfNeeded()
                section = sectionName
                if section == "desktop" {
                    desktopSeen = true
                    desktopSelectionWritten = false
                }
                output.append(rawLine)
                continue
            }

            if (section.isEmpty || section == "desktop"), isSelectedAvatarLine(trimmed) {
                if section == "desktop", !desktopSelectionWritten {
                    output.append(selectionLine)
                    desktopSelectionWritten = true
                }
                continue
            }
            output.append(rawLine)
        }

        appendDesktopSelectionIfNeeded()
        if !desktopSeen {
            if let last = output.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                output.append("")
            }
            output.append("[desktop]")
            output.append(selectionLine)
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static func sectionName(in line: String) -> String? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        return String(line[line.index(after: line.startIndex)..<close])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isSelectedAvatarLine(_ line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        return line[..<equals].trimmingCharacters(in: .whitespaces) == "selected-avatar-id"
    }
}

private struct PreparedCodexOverlayNotificationState {
    let stateData: Data
    let backupData: Data
}

private enum CodexOverlayNotificationState {
    private static let persistedAtomContainerKey = "electron-persisted-atom-state"
    private static let firstAwakeKey = "first-awake-pet-notification-avatar-ids"
    private static let mutedNotificationKey = "avatar-overlay-muted-notification-ids-v1"
    private static let localThreadKeyPrefix = "thread-client-id-v1:local%3A"
    private static let localNotificationPrefix = "local:local:"

    private enum StateError: LocalizedError {
        case invalidJSON(String)
        case invalidArray(String)
        case writeCancelled

        var errorDescription: String? {
            switch self {
            case let .invalidJSON(name):
                return "\(name) 不是有效的 JSON 对象"
            case let .invalidArray(key):
                return "\(key) 不是字符串数组"
            case .writeCancelled:
                return "Codex 已重新启动，已取消原生气泡状态写入"
            }
        }
    }

    static func prepare(
        stateData: Data,
        sessionIndexData: Data?,
        existingBackupData: Data?
    ) throws -> PreparedCodexOverlayNotificationState {
        var root = try jsonObject(from: stateData, name: "Codex 状态")
        var atoms = root[persistedAtomContainerKey] as? [String: Any] ?? [:]
        var backup = try backupObject(from: existingBackupData)

        let firstAwakeKeyExisted = atoms[firstAwakeKey] != nil
        var firstAwake = try stringArray(in: atoms, key: firstAwakeKey)
        var addedFirstAwake = backupStringArray(
            in: backup,
            key: "addedFirstAwakeAvatarIDs"
        )
        if !firstAwake.contains(chatBirdPetAvatarID) {
            firstAwake.append(chatBirdPetAvatarID)
            if !addedFirstAwake.contains(chatBirdPetAvatarID) {
                addedFirstAwake.append(chatBirdPetAvatarID)
            }
        }
        atoms[firstAwakeKey] = firstAwake

        let mutedKeyExisted = atoms[mutedNotificationKey] != nil
        var muted = try stringArray(in: atoms, key: mutedNotificationKey)
        var addedMuted = backupStringArray(
            in: backup,
            key: "addedMutedNotificationIDs"
        )
        let knownThreadIDs = localThreadIDs(
            atoms: atoms,
            sessionIndexData: sessionIndexData
        )
        for threadID in knownThreadIDs.sorted() {
            let preferenceID = localNotificationPrefix + threadID
            guard !muted.contains(preferenceID) else { continue }
            muted.append(preferenceID)
            if !addedMuted.contains(preferenceID) {
                addedMuted.append(preferenceID)
            }
        }
        atoms[mutedNotificationKey] = muted

        backup["version"] = 1
        backup["createdFirstAwakeKey"] =
            (backup["createdFirstAwakeKey"] as? Bool ?? false) || !firstAwakeKeyExisted
        backup["createdMutedKey"] =
            (backup["createdMutedKey"] as? Bool ?? false) || !mutedKeyExisted
        backup["addedFirstAwakeAvatarIDs"] = addedFirstAwake
        backup["addedMutedNotificationIDs"] = addedMuted

        root[persistedAtomContainerKey] = atoms
        return PreparedCodexOverlayNotificationState(
            stateData: try JSONSerialization.data(withJSONObject: root),
            backupData: try JSONSerialization.data(
                withJSONObject: backup,
                options: [.sortedKeys]
            )
        )
    }

    static func restore(stateData: Data, backupData: Data) throws -> Data {
        var root = try jsonObject(from: stateData, name: "Codex 状态")
        guard var atoms = root[persistedAtomContainerKey] as? [String: Any] else {
            return stateData
        }
        let backup = try jsonObject(from: backupData, name: "ChatBird 状态备份")
        let addedFirstAwake = Set(
            backupStringArray(in: backup, key: "addedFirstAwakeAvatarIDs")
        )
        let addedMuted = Set(
            backupStringArray(in: backup, key: "addedMutedNotificationIDs")
        )

        if atoms[firstAwakeKey] != nil {
            let restored = try stringArray(in: atoms, key: firstAwakeKey)
                .filter { !addedFirstAwake.contains($0) }
            if backup["createdFirstAwakeKey"] as? Bool == true, restored.isEmpty {
                atoms.removeValue(forKey: firstAwakeKey)
            } else {
                atoms[firstAwakeKey] = restored
            }
        }

        if atoms[mutedNotificationKey] != nil {
            let restored = try stringArray(in: atoms, key: mutedNotificationKey)
                .filter { !addedMuted.contains($0) }
            if backup["createdMutedKey"] as? Bool == true, restored.isEmpty {
                atoms.removeValue(forKey: mutedNotificationKey)
            } else {
                atoms[mutedNotificationKey] = restored
            }
        }

        root[persistedAtomContainerKey] = atoms
        return try JSONSerialization.data(withJSONObject: root)
    }

    @discardableResult
    static func prepareFiles(
        stateURL: URL,
        sessionIndexURL: URL,
        backupURL: URL,
        canWrite: () -> Bool = { true }
    ) throws -> Bool {
        let fileManager = FileManager.default
        let stateData = fileManager.fileExists(atPath: stateURL.path)
            ? try Data(contentsOf: stateURL)
            : Data("{}".utf8)
        let sessionIndexData = fileManager.fileExists(atPath: sessionIndexURL.path)
            ? try Data(contentsOf: sessionIndexURL)
            : nil
        let existingBackupData = fileManager.fileExists(atPath: backupURL.path)
            ? try Data(contentsOf: backupURL)
            : nil
        let prepared = try prepare(
            stateData: stateData,
            sessionIndexData: sessionIndexData,
            existingBackupData: existingBackupData
        )

        let stateChanged =
            try canonicalJSONData(stateData) != canonicalJSONData(prepared.stateData)
        let backupChanged: Bool
        if let existingBackupData {
            backupChanged =
                try canonicalJSONData(existingBackupData)
                    != canonicalJSONData(prepared.backupData)
        } else {
            backupChanged = true
        }

        func currentInputsMatch() throws -> Bool {
            let currentStateData = fileManager.fileExists(atPath: stateURL.path)
                ? try Data(contentsOf: stateURL)
                : Data("{}".utf8)
            let currentSessionIndexData =
                fileManager.fileExists(atPath: sessionIndexURL.path)
                    ? try Data(contentsOf: sessionIndexURL)
                    : nil
            return currentStateData == stateData
                && currentSessionIndexData == sessionIndexData
        }

        func validateWriteBoundary() throws {
            guard canWrite(), try currentInputsMatch() else {
                throw StateError.writeCancelled
            }
        }

        let hasChanges = stateChanged || backupChanged
        if hasChanges {
            try validateWriteBoundary()
            try fileManager.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var wrotePreparedBackup = false
        if backupChanged {
            try validateWriteBoundary()
            try prepared.backupData.write(to: backupURL, options: .atomic)
            wrotePreparedBackup = true
        }
        do {
            if stateChanged {
                try validateWriteBoundary()
                try prepared.stateData.write(to: stateURL, options: .atomic)
            }
        } catch {
            if wrotePreparedBackup {
                if let existingBackupData {
                    try existingBackupData.write(to: backupURL, options: .atomic)
                } else if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
            }
            throw error
        }
        return hasChanges
    }

    static func restoreFiles(
        stateURL: URL,
        backupURL: URL,
        canWrite: () -> Bool = { true }
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupURL.path) else { return }
        guard fileManager.fileExists(atPath: stateURL.path) else {
            guard canWrite() else {
                throw StateError.writeCancelled
            }
            try fileManager.removeItem(at: backupURL)
            return
        }
        let stateData = try Data(contentsOf: stateURL)
        let backupData = try Data(contentsOf: backupURL)
        let restored = try restore(
            stateData: stateData,
            backupData: backupData
        )

        guard canWrite(),
              try Data(contentsOf: stateURL) == stateData,
              try Data(contentsOf: backupURL) == backupData
        else {
            throw StateError.writeCancelled
        }
        try restored.write(to: stateURL, options: .atomic)
        guard canWrite(),
              try Data(contentsOf: stateURL) == restored,
              try Data(contentsOf: backupURL) == backupData
        else {
            throw StateError.writeCancelled
        }
        try fileManager.removeItem(at: backupURL)
    }

    private static func jsonObject(from data: Data, name: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StateError.invalidJSON(name)
        }
        return object
    }

    private static func canonicalJSONData(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private static func backupObject(from data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        return try jsonObject(from: data, name: "ChatBird 状态备份")
    }

    private static func stringArray(
        in object: [String: Any],
        key: String
    ) throws -> [String] {
        guard let value = object[key] else { return [] }
        guard let strings = value as? [String] else {
            throw StateError.invalidArray(key)
        }
        return strings
    }

    private static func backupStringArray(
        in object: [String: Any],
        key: String
    ) -> [String] {
        object[key] as? [String] ?? []
    }

    private static func localThreadIDs(
        atoms: [String: Any],
        sessionIndexData: Data?
    ) -> Set<String> {
        var result = Set<String>()
        for key in atoms.keys where key.hasPrefix(localThreadKeyPrefix) {
            let encoded = String(key.dropFirst(localThreadKeyPrefix.count))
            if let decoded = encoded.removingPercentEncoding, validThreadID(decoded) {
                result.insert(decoded)
            }
        }

        if let sessionIndexData,
           let text = String(data: sessionIndexData, encoding: .utf8)
        {
            for line in text.split(whereSeparator: \.isNewline) {
                guard let lineData = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData)
                        as? [String: Any],
                      let threadID = object["id"] as? String,
                      validThreadID(threadID)
                else { continue }
                result.insert(threadID)
            }
        }
        return result
    }

    private static func validThreadID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)
        }
    }
}

private struct CodexOverlayNotificationDiskSnapshot: Equatable {
    let stateData: Data
    let sessionIndexData: Data?
}

private struct CodexOverlayNotificationPaths {
    let stateURL: URL
    let sessionIndexURL: URL
    let backupURL: URL

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexOverlayNotificationPaths {
        let stateURL: URL
        let codexHomeURL: URL
        if let override = environment["CHATBIRD_CODEX_STATE_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
            codexHomeURL = stateURL.deletingLastPathComponent()
        } else {
            let configuredHome = environment["CODEX_HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            codexHomeURL = configuredHome.flatMap { value in
                value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
            } ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
            stateURL = codexHomeURL.appendingPathComponent(".codex-global-state.json")
        }
        return CodexOverlayNotificationPaths(
            stateURL: stateURL,
            sessionIndexURL: codexHomeURL.appendingPathComponent("session_index.jsonl"),
            backupURL: codexHomeURL.appendingPathComponent(
                "chatbird-native-notification-backup.json"
            )
        )
    }

    func readSnapshot(
        fileManager: FileManager = .default
    ) throws -> CodexOverlayNotificationDiskSnapshot {
        let stateData = fileManager.fileExists(atPath: stateURL.path)
            ? try Data(contentsOf: stateURL)
            : Data("{}".utf8)
        let sessionIndexData = fileManager.fileExists(atPath: sessionIndexURL.path)
            ? try Data(contentsOf: sessionIndexURL)
            : nil
        return CodexOverlayNotificationDiskSnapshot(
            stateData: stateData,
            sessionIndexData: sessionIndexData
        )
    }

    @discardableResult
    func synchronize(canWrite: () -> Bool = { true }) throws -> Bool {
        try CodexOverlayNotificationState.prepareFiles(
            stateURL: stateURL,
            sessionIndexURL: sessionIndexURL,
            backupURL: backupURL,
            canWrite: canWrite
        )
    }
}

private enum CodexOverlayNotificationSyncDecision: Equatable {
    case waitForCodexExit
    case waitForStableFiles
    case synchronize
}

private struct CodexOverlayNotificationSyncProbe {
    private let requiredStableSampleCount: Int
    private var lastSnapshot: CodexOverlayNotificationDiskSnapshot?
    private var stableSampleCount = 0

    init(requiredStableSampleCount: Int) {
        self.requiredStableSampleCount = max(1, requiredStableSampleCount)
    }

    mutating func observe(
        codexRunning: Bool,
        snapshot: CodexOverlayNotificationDiskSnapshot?
    ) -> CodexOverlayNotificationSyncDecision {
        guard !codexRunning else {
            reset()
            return .waitForCodexExit
        }
        guard let snapshot else {
            reset()
            return .waitForStableFiles
        }
        if snapshot == lastSnapshot {
            stableSampleCount += 1
        } else {
            lastSnapshot = snapshot
            stableSampleCount = 1
        }
        return stableSampleCount >= requiredStableSampleCount
            ? .synchronize
            : .waitForStableFiles
    }

    mutating func reset() {
        lastSnapshot = nil
        stableSampleCount = 0
    }
}

private final class CodexOverlayNotificationSynchronizer {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    private let maximumAttempts: Int
    private let checkInterval: TimeInterval
    private let isCodexRunning: () -> Bool
    private let readSnapshot: () throws -> CodexOverlayNotificationDiskSnapshot
    private let synchronize: () throws -> Bool
    private let schedule: Schedule
    private let log: (String) -> Void
    private var probe: CodexOverlayNotificationSyncProbe
    private var observedCodexRunning: Bool?
    private var attemptCount = 0
    private var generation = 0

    init(
        requiredStableSampleCount: Int = 2,
        maximumAttempts: Int = 80,
        checkInterval: TimeInterval = 0.25,
        isCodexRunning: @escaping () -> Bool,
        readSnapshot: @escaping () throws -> CodexOverlayNotificationDiskSnapshot,
        synchronize: @escaping () throws -> Bool,
        schedule: @escaping Schedule,
        log: @escaping (String) -> Void
    ) {
        probe = CodexOverlayNotificationSyncProbe(
            requiredStableSampleCount: requiredStableSampleCount
        )
        self.maximumAttempts = max(1, maximumAttempts)
        self.checkInterval = max(0, checkInterval)
        self.isCodexRunning = isCodexRunning
        self.readSnapshot = readSnapshot
        self.synchronize = synchronize
        self.schedule = schedule
        self.log = log
    }

    func codexRunningStateDidChange(_ isRunning: Bool) {
        guard observedCodexRunning != isRunning else { return }
        observedCodexRunning = isRunning
        generation &+= 1
        probe.reset()
        attemptCount = 0
        guard !isRunning else { return }
        scheduleCheck(for: generation, after: 0)
    }

    func stop() {
        generation &+= 1
        observedCodexRunning = nil
        probe.reset()
        attemptCount = 0
    }

    private func scheduleCheck(
        for expectedGeneration: Int,
        after delay: TimeInterval? = nil
    ) {
        schedule(delay ?? checkInterval) { [weak self] in
            self?.runCheck(for: expectedGeneration)
        }
    }

    private func runCheck(for expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        guard !isCodexRunning() else {
            codexRunningStateDidChange(true)
            return
        }

        attemptCount += 1
        do {
            let snapshot = try readSnapshot()
            switch probe.observe(codexRunning: false, snapshot: snapshot) {
            case .waitForCodexExit:
                return
            case .waitForStableFiles:
                retryOrStop(for: expectedGeneration)
            case .synchronize:
                guard !isCodexRunning() else {
                    codexRunningStateDidChange(true)
                    return
                }
                let changed = try synchronize()
                guard generation == expectedGeneration else { return }
                generation &+= 1
                log(
                    changed
                        ? "ChatBird 已在 Codex 完全退出后同步原生任务气泡静音状态。"
                        : "ChatBird 已确认 Codex 原生任务气泡静音状态为最新。"
                )
            }
        } catch {
            retryOrStop(for: expectedGeneration)
        }
    }

    private func retryOrStop(for expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        guard attemptCount < maximumAttempts else {
            generation &+= 1
            log("ChatBird 暂时无法同步 Codex 原生任务气泡；将在下次 Codex 退出后重试。")
            return
        }
        scheduleCheck(for: expectedGeneration)
    }
}

private struct PanelPlacement {
    let origin: NSPoint
    let pointerCenterX: CGFloat
    let actualGap: CGFloat
    let centerError: CGFloat
}

/// Places the pointer tip on ChatBird's visible horizontal center and keeps its
/// tip exactly 14 logical points above the visible top tuft. All calculations
/// use AppKit points, so Retina and scaled displays preserve the same spacing.
private func panelPlacement(
    petVisibleRect: NSRect,
    panelSize: NSSize,
    panelScale: CGFloat,
    screenVisibleFrame: NSRect
) -> PanelPlacement {
    let minX = screenVisibleFrame.minX + panelScreenMargin
    let maxX = max(minX, screenVisibleFrame.maxX - panelSize.width - panelScreenMargin)
    let desiredX = petVisibleRect.midX - panelSize.width / 2
    let x = min(max(desiredX, minX), maxX)

    let desiredTipY = petVisibleRect.maxY + panelPetGap
    let desiredY = desiredTipY - pointerTipBottomInset * panelScale
    // Keep the pointer attached even near a display's top edge. Vertically
    // clamping the panel to the work area creates the large pet/panel split
    // reported on short or heavily scaled displays.
    let y = desiredY

    let originX = x
    let originY = y
    let rawPointerCenterX = petVisibleRect.midX - originX
    let safeMinX = min(pointerHorizontalSafeInset * panelScale, panelSize.width / 2)
    let safeMaxX = max(safeMinX, panelSize.width - safeMinX)
    let pointerCenterX = min(max(rawPointerCenterX, safeMinX), safeMaxX)
    let actualPointerX = originX + pointerCenterX
    let actualPointerTipY = originY + pointerTipBottomInset * panelScale

    return PanelPlacement(
        origin: NSPoint(x: originX, y: originY),
        pointerCenterX: pointerCenterX,
        actualGap: actualPointerTipY - petVisibleRect.maxY,
        centerError: actualPointerX - petVisibleRect.midX
    )
}

private func normalizedPanelScale(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else { return 1 }
    return min(max(value, minimumPanelScale), maximumPanelScale)
}

private func presentedPanelScale(_ value: CGFloat) -> CGFloat {
    max(normalizedPanelScale(value), minimumPresentedPanelScale)
}

private func scaledPanelSize(_ baseSize: NSSize, scale: CGFloat) -> NSSize {
    let safeScale = normalizedPanelScale(scale)
    return NSSize(width: baseSize.width * safeScale, height: baseSize.height * safeScale)
}

private struct VisiblePixelSelection {
    let bounds: CGRect
    let totalVisiblePixels: Int
}

private struct VisiblePixelComponent {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int
    var pixelCount: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
    var aspectRatio: Double { Double(width) / Double(height) }
    var bounds: CGRect {
        CGRect(x: minX, y: minY, width: width, height: height)
    }

    func union(_ other: VisiblePixelComponent) -> VisiblePixelComponent {
        VisiblePixelComponent(
            minX: min(minX, other.minX),
            minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX),
            maxY: max(maxY, other.maxY),
            pixelCount: pixelCount + other.pixelCount
        )
    }
}

private func mascotPixelSelection(
    imageWidth: Int,
    imageHeight: Int,
    isVisible: (_ x: Int, _ y: Int) -> Bool
) -> VisiblePixelSelection? {
    guard imageWidth > 0, imageHeight > 0 else { return nil }

    var mask = [UInt8](repeating: 0, count: imageWidth * imageHeight)
    var totalVisiblePixels = 0
    for y in 0..<imageHeight {
        for x in 0..<imageWidth where isVisible(x, y) {
            mask[y * imageWidth + x] = 1
            totalVisiblePixels += 1
        }
    }
    guard totalVisiblePixels > 0 else { return nil }

    var components: [VisiblePixelComponent] = []
    var queue: [Int] = []
    for start in mask.indices where mask[start] == 1 {
        mask[start] = 0
        queue.removeAll(keepingCapacity: true)
        queue.append(start)

        let startX = start % imageWidth
        let startY = start / imageWidth
        var component = VisiblePixelComponent(
            minX: startX,
            minY: startY,
            maxX: startX,
            maxY: startY,
            pixelCount: 0
        )
        var queueIndex = 0
        while queueIndex < queue.count {
            let index = queue[queueIndex]
            queueIndex += 1
            let x = index % imageWidth
            let y = index / imageWidth
            component.minX = min(component.minX, x)
            component.minY = min(component.minY, y)
            component.maxX = max(component.maxX, x)
            component.maxY = max(component.maxY, y)
            component.pixelCount += 1

            for neighborY in max(0, y - 1)...min(imageHeight - 1, y + 1) {
                for neighborX in max(0, x - 1)...min(imageWidth - 1, x + 1) {
                    let neighborIndex = neighborY * imageWidth + neighborX
                    guard mask[neighborIndex] == 1 else { continue }
                    mask[neighborIndex] = 0
                    queue.append(neighborIndex)
                }
            }
        }
        components.append(component)
    }

    let minimumMascotHeight = max(12, imageHeight / 16)
    let mascotCandidates = components.filter {
        $0.pixelCount >= 64
            && $0.width >= 8
            && $0.height >= minimumMascotHeight
            && $0.aspectRatio >= 0.20
            && $0.aspectRatio <= 2.10
    }
    guard let anchor = mascotCandidates.max(by: { left, right in
        func score(_ component: VisiblePixelComponent) -> Double {
            let bottomPosition = Double(component.maxY + 1) / Double(imageHeight)
            let heightShare = Double(component.height) / Double(imageHeight)
            let shapePenalty = abs(log(component.aspectRatio / 0.82)) * 0.20
            return bottomPosition * 5
                + heightShare * 4
                + log1p(Double(component.pixelCount)) / 10
                - shapePenalty
        }
        return score(left) < score(right)
    }) else { return nil }

    var mascot = anchor
    let horizontalJoinDistance = max(3, anchor.width / 8)
    let verticalJoinDistance = max(3, anchor.height / 12)
    for component in components where component.bounds != anchor.bounds {
        guard component.pixelCount >= 4,
              component.aspectRatio <= 2.40,
              component.maxY >= anchor.minY
        else { continue }

        let horizontalGap = max(
            0,
            max(mascot.minX - component.maxX - 1, component.minX - mascot.maxX - 1)
        )
        let verticalGap = max(
            0,
            max(mascot.minY - component.maxY - 1, component.minY - mascot.maxY - 1)
        )
        let joined = mascot.union(component)
        guard horizontalGap <= horizontalJoinDistance,
              verticalGap <= verticalJoinDistance,
              joined.width <= Int(Double(anchor.width) * 1.45),
              joined.height <= Int(Double(anchor.height) * 1.35)
        else { continue }
        mascot = joined
    }

    return VisiblePixelSelection(
        bounds: mascot.bounds,
        totalVisiblePixels: totalVisiblePixels
    )
}

private func isKnownCodexDesktopBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
    let normalizedIdentifier = bundleIdentifier?.lowercased() ?? ""
    return ["com.openai.codex", "com.openai.chatgpt", "com.openai.chat"]
        .contains(normalizedIdentifier)
}

private func isCodexDesktopApplication(
    bundleIdentifier: String?,
    localizedName: String?,
    bundleURL: URL?,
    activationPolicy: NSApplication.ActivationPolicy
) -> Bool {
    guard activationPolicy == .regular else { return false }

    if isKnownCodexDesktopBundleIdentifier(bundleIdentifier) {
        return true
    }

    let normalizedName = localizedName?.lowercased() ?? ""
    let normalizedBundleName = bundleURL?
        .deletingPathExtension()
        .lastPathComponent
        .lowercased() ?? ""
    let knownName = normalizedName == "codex" || normalizedName == "chatgpt"
    let knownBundle = normalizedBundleName == "codex" || normalizedBundleName == "chatgpt"
    return knownName && knownBundle
}

private func isCodexDesktopRunning() -> Bool {
    let applications = NSWorkspace.shared.runningApplications
    if applications.contains(where: { application in
        isKnownCodexDesktopBundleIdentifier(application.bundleIdentifier)
    }) {
        return true
    }

    // Compatibility fallback for unsigned or legacy builds without a known
    // bundle identifier. Keep the LaunchServices-backed name lookups off the
    // common path because they are comparatively expensive.
    return applications.contains { application in
        isCodexDesktopApplication(
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            bundleURL: application.bundleURL,
            activationPolicy: application.activationPolicy
        )
    }
}

private func isHideActivityAccessibilityLabel(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "hide activity" || normalized == "隐藏活动"
}

private func isOpenActivityNotificationAccessibilityLabel(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.contains("open notification")
        || normalized.contains("打开通知")
}

private func isMuteTaskMenuItemTitle(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "mute task" || normalized == "静音任务"
}

private func codexThreadURL(threadID: String) -> URL? {
    guard UUID(uuidString: threadID) != nil else { return nil }
    return URL(string: "codex://threads/\(threadID.lowercased())")
}

private func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func claudeResumeCommand(
    sessionID: String,
    workingDirectory: String,
    executablePath: String
) -> String? {
    guard UUID(uuidString: sessionID) != nil,
          workingDirectory.hasPrefix("/"),
          executablePath.hasPrefix("/")
    else { return nil }
    return "cd -- \(shellSingleQuoted(workingDirectory))"
        + " && exec \(shellSingleQuoted(executablePath))"
        + " --resume \(shellSingleQuoted(sessionID.lowercased()))"
}

private func normalizedTerminalTTY(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "??" else { return nil }
    let path = trimmed.hasPrefix("/dev/") ? trimmed : "/dev/\(trimmed)"
    guard path.range(
        of: #"^/dev/tty[A-Za-z0-9._-]+$"#,
        options: .regularExpression
    ) != nil else { return nil }
    return path
}

private func directControllingTTY(forProcessID processID: Int32) -> String? {
    guard processID > 1 else { return nil }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", "\(processID)", "-o", "tty="]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0,
          let text = String(
              data: output.fileHandleForReading.readDataToEndOfFile(),
              encoding: .utf8
          )
    else { return nil }
    return normalizedTerminalTTY(text)
}

private func parentProcessID(forProcessID processID: Int32) -> Int32? {
    guard processID > 1 else { return nil }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", "\(processID)", "-o", "ppid="]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0,
          let text = String(
              data: output.fileHandleForReading.readDataToEndOfFile(),
              encoding: .utf8
          ),
          let parent = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          parent > 1,
          parent != processID
    else { return nil }
    return parent
}

private func controllingTTYFromProcessChain(
    startingAt processID: Int32,
    directTTY: (Int32) -> String?,
    parentPID: (Int32) -> Int32?
) -> String? {
    var candidate = processID
    var visited = Set<Int32>()
    for _ in 0..<16 {
        guard candidate > 1, visited.insert(candidate).inserted else { break }
        if let tty = directTTY(candidate) {
            return tty
        }
        guard let parent = parentPID(candidate) else { break }
        candidate = parent
    }
    return nil
}

private func controllingTTY(forProcessID processID: Int32) -> String? {
    controllingTTYFromProcessChain(
        startingAt: processID,
        directTTY: { directControllingTTY(forProcessID: $0) },
        parentPID: { parentProcessID(forProcessID: $0) }
    )
}

private func terminalHostApplication(
    forProcessID processID: Int32
) -> NSRunningApplication? {
    var candidate = processID
    var visited = Set<Int32>()
    for _ in 0..<16 {
        guard candidate > 1, visited.insert(candidate).inserted else { break }
        if let application = NSRunningApplication(processIdentifier: candidate),
           application.bundleURL?.pathExtension.lowercased() == "app",
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            return application
        }
        guard let parent = parentProcessID(forProcessID: candidate) else { break }
        candidate = parent
    }
    return nil
}

private func ottyExecutablePath() -> String? {
    let candidates = [
        ProcessInfo.processInfo.environment["OTTY_BIN"],
        "/usr/local/bin/otty",
        "/opt/homebrew/bin/otty",
        "/Applications/Otty.app/Contents/MacOS/otty-cli",
    ].compactMap { $0 }
    return candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
    })
}

private func runOttyCLI(arguments: [String]) -> Data? {
    guard let executablePath = ottyExecutablePath() else { return nil }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    return output.fileHandleForReading.readDataToEndOfFile()
}

private func normalizedAbsolutePath(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: trimmed, isDirectory: true)
        .standardizedFileURL
        .path
}

private struct OttyTabSnapshot {
    let id: String
    let workingDirectory: String
    let isActive: Bool
}

private func ottyTabSnapshots(from data: Data) -> [OttyTabSnapshot]? {
    guard let root = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any],
        root["ok"] as? Bool == true,
        let rawTabs = root["data"] as? [[String: Any]]
    else { return nil }
    return rawTabs.compactMap { value in
        guard let id = value["id"] as? String,
              let cwd = value["cwd"] as? String,
              let normalizedCWD = normalizedAbsolutePath(cwd)
        else { return nil }
        return OttyTabSnapshot(
            id: id,
            workingDirectory: normalizedCWD,
            isActive: value["active"] as? Bool ?? false
        )
    }
}

private func ottyTabID(from data: Data, workingDirectory: String) -> String? {
    guard let target = normalizedAbsolutePath(workingDirectory),
          let tabs = ottyTabSnapshots(from: data)
    else { return nil }
    return tabs
        .filter { $0.workingDirectory == target }
        .sorted { $0.isActive && !$1.isActive }
        .first?
        .id
}

private func ottyHasActiveTab(from data: Data) -> Bool {
    ottyTabSnapshots(from: data)?.contains { $0.isActive } ?? false
}

private func ottyTabFocusArguments(tabID: String) -> [String]? {
    guard tabID.range(
        of: #"^[A-Za-z0-9._-]+$"#,
        options: .regularExpression
    ) != nil else { return nil }
    return ["--json", "tab", "focus", tabID]
}

private func activateRunningApplication(bundleIdentifier: String) -> Bool {
    guard let application = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
    ).first else { return false }
    return application.activate(options: [
        .activateAllWindows,
        .activateIgnoringOtherApps,
    ])
}

private func preferredClaudeTerminalBundleIdentifier(
    frontmostBundleIdentifier: String?,
    runningBundleIdentifiers: Set<String>,
    ottyHasActiveTab: Bool
) -> String? {
    let supportedBundleIdentifiers: Set<String> = [
        "io.appmakes.otty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
    ]
    if let frontmostBundleIdentifier,
       supportedBundleIdentifiers.contains(frontmostBundleIdentifier),
       runningBundleIdentifiers.contains(frontmostBundleIdentifier)
    {
        return frontmostBundleIdentifier
    }
    if ottyHasActiveTab,
       runningBundleIdentifiers.contains("io.appmakes.otty")
    {
        return "io.appmakes.otty"
    }
    if runningBundleIdentifiers == ["io.appmakes.otty"] {
        return "io.appmakes.otty"
    }
    if runningBundleIdentifiers.contains("com.googlecode.iterm2") {
        return "com.googlecode.iterm2"
    }
    if runningBundleIdentifiers.contains("com.apple.Terminal") {
        return "com.apple.Terminal"
    }
    return nil
}

private func focusExistingOttyTerminal(workingDirectory: String) -> Bool {
    guard NSRunningApplication.runningApplications(
        withBundleIdentifier: "io.appmakes.otty"
    ).isEmpty == false,
          let listData = runOttyCLI(arguments: ["--json", "tab", "list"]),
          let tabID = ottyTabID(
              from: listData,
              workingDirectory: workingDirectory
          ),
          let arguments = ottyTabFocusArguments(tabID: tabID),
          runOttyCLI(arguments: arguments) != nil
    else { return false }
    return activateRunningApplication(bundleIdentifier: "io.appmakes.otty")
}

private func iTerm2FocusScript(tty: String) -> String? {
    guard let tty = normalizedTerminalTTY(tty) else { return nil }
    return """
    tell application id "com.googlecode.iterm2"
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                repeat with aSession in sessions of aTab
                    if (tty of aSession as text) is "\(tty)" then
                        tell aSession to select
                        tell aTab to select
                        tell aWindow to select
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end repeat
        return false
    end tell
    """
}

private func ottyFocusScript(tty: String) -> String? {
    guard let tty = normalizedTerminalTTY(tty) else { return nil }
    return """
    tell application id "io.appmakes.otty"
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                if (tty of aTab as text) is "\(tty)" then
                    set selected of aTab to true
                    activate
                    return true
                end if
            end repeat
        end repeat
        return false
    end tell
    """
}

private func terminalFocusScript(tty: String) -> String? {
    guard let tty = normalizedTerminalTTY(tty) else { return nil }
    return """
    tell application id "com.apple.Terminal"
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                if (tty of aTab as text) is "\(tty)" then
                    set selected tab of aWindow to aTab
                    set index of aWindow to 1
                    activate
                    return true
                end if
            end repeat
        end repeat
        return false
    end tell
    """
}

private func appleScriptEscapedString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}

private func ottyResumeScript(command: String) -> String? {
    guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    let escapedCommand = appleScriptEscapedString(command)
    return """
    tell application id "io.appmakes.otty"
        set targetTab to do script "\(escapedCommand)"
        set targetWindow to front window
        set selected of targetTab to true
        set index of targetWindow to 1
        activate
        return true
    end tell
    """
}

private func iTerm2FocusScript(workingDirectory: String) -> String? {
    var isDirectory: ObjCBool = false
    guard workingDirectory.hasPrefix("/"),
          FileManager.default.fileExists(
              atPath: workingDirectory,
              isDirectory: &isDirectory
          ),
          isDirectory.boolValue
    else { return nil }
    let escapedPath = appleScriptEscapedString(workingDirectory)
    return """
    tell application id "com.googlecode.iterm2"
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                repeat with aSession in sessions of aTab
                    try
                        tell aSession to set sessionPath to variable named "session.path"
                        if sessionPath is "\(escapedPath)" or sessionPath is "file://\(escapedPath)" then
                            tell aSession to select
                            tell aTab to select
                            tell aWindow to select
                            activate
                            return true
                        end if
                    end try
                end repeat
            end repeat
        end repeat
        return false
    end tell
    """
}

private func iTerm2ResumeScript(command: String) -> String? {
    guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    let escapedCommand = appleScriptEscapedString(command)
    return """
    tell application id "com.googlecode.iterm2"
        activate
        if (count of windows) is 0 then
            create window with default profile command "\(escapedCommand)"
        else
            tell current window to create tab with default profile command "\(escapedCommand)"
        end if
        return true
    end tell
    """
}

private func executeAppleScriptReturningBoolean(_ source: String) -> Bool {
    guard let script = NSAppleScript(source: source) else { return false }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    return error == nil && result.booleanValue
}

private func focusExistingClaudeTerminal(
    processID: Int32,
    processStartIdentity: String
) -> Bool {
    guard isLiveClaudeProcess(processID),
          currentProcessStartIdentity(forProcessID: processID)
            == processStartIdentity,
          let tty = controllingTTY(forProcessID: processID),
          let hostApplication = terminalHostApplication(forProcessID: processID)
    else { return false }

    let source: String?
    switch hostApplication.bundleIdentifier {
    case "io.appmakes.otty":
        source = ottyFocusScript(tty: tty)
    case "com.googlecode.iterm2":
        source = iTerm2FocusScript(tty: tty)
    case "com.apple.Terminal":
        source = terminalFocusScript(tty: tty)
    default:
        return false
    }
    guard let source else { return false }
    return executeAppleScriptReturningBoolean(source)
}

private func focusExistingClaudeTerminal(workingDirectory: String) -> Bool {
    if focusExistingOttyTerminal(workingDirectory: workingDirectory) {
        return true
    }
    guard NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.googlecode.iterm2"
    ).isEmpty == false,
          let source = iTerm2FocusScript(workingDirectory: workingDirectory)
    else { return false }
    return executeAppleScriptReturningBoolean(source)
}

private func openClaudeSession(
    sessionID: String,
    workingDirectory: String
) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
        atPath: workingDirectory,
        isDirectory: &isDirectory
    ), isDirectory.boolValue else { return false }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let executableCandidates = [
        ProcessInfo.processInfo.environment["CLAUDE_BIN"],
        home.appendingPathComponent(".local/bin/claude").path,
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ].compactMap { $0 }
    guard let executablePath = executableCandidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
    }), let command = claudeResumeCommand(
        sessionID: sessionID,
        workingDirectory: workingDirectory,
        executablePath: executablePath
    ) else { return false }

    if NSRunningApplication.runningApplications(
        withBundleIdentifier: "io.appmakes.otty"
    ).isEmpty == false,
       let source = ottyResumeScript(command: command),
       executeAppleScriptReturningBoolean(source)
    {
        return true
    }

    if NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.googlecode.iterm2"
    ).isEmpty == false,
       let source = iTerm2ResumeScript(command: command),
       executeAppleScriptReturningBoolean(source)
    {
        return true
    }

    let escapedCommand = appleScriptEscapedString(command)
    let source = """
    tell application "Terminal"
        activate
        do script "\(escapedCommand)"
    end tell
    """
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return false }
    _ = script.executeAndReturnError(&error)
    return error == nil
}

private func isNativeActivityPillWindowTitle(_ value: String?) -> Bool {
    let normalized = value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    return normalized == "codex pet composition surface"
}

private func isNativeActivityToggleWindowTitle(_ value: String?) -> Bool {
    let normalized = value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    return normalized == "codex pet voice controls backing"
}

private func nativeActivityToggleClickPoint(
    position: CGPoint,
    size: CGSize
) -> CGPoint? {
    guard position.x.isFinite,
          position.y.isFinite,
          size.width.isFinite,
          size.height.isFinite,
          size.width >= 12,
          size.width <= 64,
          size.height >= 12,
          size.height <= 64
    else { return nil }
    return CGPoint(
        x: position.x + size.width / 2,
        y: position.y + size.height / 2
    )
}

private enum NativeActivityPillSuppressionResult {
    case permissionRequired
    case codexNotRunning
    case muted
    case buttonNotFound
    case actionFailed
}

private enum NativeActivitySuppressionStrategy: Equatable {
    case wait
    case muteViaMenu
}

private func nativeActivitySuppressionStrategy(
    notificationButtonCount: Int
) -> NativeActivitySuppressionStrategy {
    notificationButtonCount > 0 ? .muteViaMenu : .wait
}

private final class NativeActivityPillSuppressor {
    private var didRequestAccess = false

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessIfNeeded(prompt: Bool = true) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard prompt, !didRequestAccess else { return false }
        didRequestAccess = true
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func suppressActivityPillsIfNeeded() -> NativeActivityPillSuppressionResult {
        guard AXIsProcessTrusted() else { return .permissionRequired }
        let codexApplications = NSWorkspace.shared.runningApplications.filter {
            isCodexDesktopApplication(
                bundleIdentifier: $0.bundleIdentifier,
                localizedName: $0.localizedName,
                bundleURL: $0.bundleURL,
                activationPolicy: $0.activationPolicy
            )
        }
        guard !codexApplications.isEmpty else { return .codexNotRunning }

        var foundNotification = false
        var performedMenuAction = false
        for application in codexApplications {
            let applicationElement = AXUIElementCreateApplication(
                application.processIdentifier
            )
            let windows = elements(
                attribute: kAXWindowsAttribute as CFString,
                of: applicationElement
            )
            .sorted { elementArea($0) < elementArea($1) }

            let activityWindows = windows.filter {
                isNativeActivityPillWindowTitle(
                    attribute(kAXTitleAttribute as CFString, of: $0) as? String
                )
            }
            var notificationButtons = activityWindows.flatMap {
                activityNotificationButtons(in: $0)
            }
            if notificationButtons.isEmpty {
                notificationButtons = activityNotificationButtons(
                    in: applicationElement,
                    maximumElements: 3_000
                )
            }

            guard nativeActivitySuppressionStrategy(
                notificationButtonCount: notificationButtons.count
            ) == .muteViaMenu
            else { continue }
            foundNotification = foundNotification || !notificationButtons.isEmpty
            for button in notificationButtons {
                guard AXUIElementPerformAction(
                    button,
                    kAXShowMenuAction as CFString
                ) == .success
                else { continue }
                Thread.sleep(forTimeInterval: 0.08)
                guard let muteItem = muteTaskMenuItem(in: applicationElement),
                      AXUIElementPerformAction(
                          muteItem,
                          kAXPressAction as CFString
                      ) == .success
                else {
                    dismissOpenMenu(in: applicationElement)
                    continue
                }
                performedMenuAction = true
                Thread.sleep(forTimeInterval: 0.08)
            }
        }

        if performedMenuAction { return .muted }
        if foundNotification { return .actionFailed }
        return .buttonNotFound
    }

    private func activityNotificationButtons(
        in root: AXUIElement,
        maximumElements: Int = 1_200
    ) -> [AXUIElement] {
        descendants(in: root, maximumElements: maximumElements).filter { element in
            supportsAction(kAXShowMenuAction as CFString, on: element)
                && accessibilityStrings(of: element).contains(where: {
                    isOpenActivityNotificationAccessibilityLabel($0)
                })
        }
    }

    private func muteTaskMenuItem(in application: AXUIElement) -> AXUIElement? {
        descendants(in: application, maximumElements: 3_000).first { element in
            guard attribute(kAXRoleAttribute as CFString, of: element) as? String
                    == kAXMenuItemRole as String,
                  supportsPress(element)
            else { return false }
            return accessibilityStrings(of: element).contains(where: {
                isMuteTaskMenuItemTitle($0)
            })
        }
    }

    private func descendants(
        in root: AXUIElement,
        maximumElements: Int
    ) -> [AXUIElement] {
        var queue = [root]
        var index = 0
        while index < queue.count, index < maximumElements {
            let element = queue[index]
            index += 1
            queue.append(
                contentsOf: elements(
                    attribute: kAXChildrenAttribute as CFString,
                    of: element
                )
            )
        }
        return Array(queue.prefix(maximumElements))
    }

    private func dismissOpenMenu(in application: AXUIElement) {
        guard let menu = descendants(
            in: application,
            maximumElements: 3_000
        ).first(where: { element in
            attribute(kAXRoleAttribute as CFString, of: element) as? String
                == kAXMenuRole as String
                && supportsAction(kAXCancelAction as CFString, on: element)
        }) else { return }
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    }

    private func hideActivityButton(in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var index = 0
        let maximumElements = 1_200
        while index < queue.count, index < maximumElements {
            let element = queue[index]
            index += 1
            if supportsPress(element),
               accessibilityStrings(of: element).contains(where: {
                   isHideActivityAccessibilityLabel($0)
               })
            {
                return element
            }
            queue.append(
                contentsOf: elements(
                    attribute: kAXChildrenAttribute as CFString,
                    of: element
                )
            )
        }
        return nil
    }

    private func accessibilityStrings(of element: AXUIElement) -> [String] {
        [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
        ].compactMap {
            attribute($0 as CFString, of: element) as? String
        }
    }

    private func supportsPress(_ element: AXUIElement) -> Bool {
        supportsAction(kAXPressAction as CFString, on: element)
    }

    private func supportsAction(_ action: CFString, on element: AXUIElement) -> Bool {
        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNames) == .success,
              let names = actionNames as? [String]
        else { return false }
        return names.contains(action as String)
    }

    private func elements(attribute name: CFString, of element: AXUIElement)
        -> [AXUIElement]
    {
        attribute(name, of: element) as? [AXUIElement] ?? []
    }

    private func attribute(_ name: CFString, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }

    private func elementArea(_ element: AXUIElement) -> CGFloat {
        guard let value = attribute(kAXSizeAttribute as CFString, of: element),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return .greatestFiniteMagnitude }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return .greatestFiniteMagnitude
        }
        return size.width * size.height
    }
}

private final class NativeActivityPillSuppressionMonitor {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    private let interval: TimeInterval
    private let shouldSuppress: () -> Bool
    private let suppress: () -> Void
    private let schedule: Schedule
    private let stateLock = NSLock()
    private var isRunning = false
    private var generation = 0

    init(
        interval: TimeInterval,
        shouldSuppress: @escaping () -> Bool,
        suppress: @escaping () -> Void,
        schedule: @escaping Schedule
    ) {
        self.interval = max(0, interval)
        self.shouldSuppress = shouldSuppress
        self.suppress = suppress
        self.schedule = schedule
    }

    func start() {
        stateLock.lock()
        guard !isRunning else {
            stateLock.unlock()
            return
        }
        isRunning = true
        generation &+= 1
        let expectedGeneration = generation
        stateLock.unlock()
        scheduleCheck(for: expectedGeneration, after: 0)
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
    }

    private func scheduleCheck(
        for expectedGeneration: Int,
        after delay: TimeInterval
    ) {
        schedule(delay) { [weak self] in
            self?.runCheck(for: expectedGeneration)
        }
    }

    private func runCheck(for expectedGeneration: Int) {
        stateLock.lock()
        guard isRunning, generation == expectedGeneration else {
            stateLock.unlock()
            return
        }
        if shouldSuppress() {
            suppress()
        }
        let shouldScheduleNextCheck = isRunning
            && generation == expectedGeneration
        stateLock.unlock()
        guard shouldScheduleNextCheck else { return }
        scheduleCheck(
            for: expectedGeneration,
            after: interval
        )
    }
}

private func shouldPresentPanel(
    codexDesktopRunning: Bool,
    hiddenByUser: Bool,
    hasPetLocation: Bool
) -> Bool {
    codexDesktopRunning && !hiddenByUser && hasPetLocation
}

private enum PetPanelClickAction: Equatable {
    case none
    case show
    case hide
}

private func petPanelClickAction(
    clickCount: Int,
    clickLocation: NSPoint,
    petVisibleRect: NSRect,
    panelHidden: Bool,
    suppressVisibleDoubleClick: Bool
) -> PetPanelClickAction {
    guard petVisibleRect.contains(clickLocation) else {
        return .none
    }
    if panelHidden {
        return .show
    }
    guard !suppressVisibleDoubleClick, clickCount == 2 else {
        return .none
    }
    return .hide
}

private final class RuntimeHealthWriter {
    private let fileURL: URL = {
        if let override = ProcessInfo.processInfo.environment["CHATBIRD_PANEL_HEALTH_FILE"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/dev.chatbird.codex-quota-panel/panel-health.json")
    }()
    private var lastSignature = ""
    private var lastWriteAt: CFAbsoluteTime = 0

    func write(
        status: String,
        panelVisible: Bool,
        locationSource: String?,
        gap: CGFloat? = nil,
        centerError: CGFloat? = nil,
        panelScale: CGFloat = 1,
        panelSize: NSSize? = nil,
        force: Bool = false
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let safeScale = normalizedPanelScale(panelScale)
        let livePanelSize = panelSize ?? scaledPanelSize(expandedPanelSize, scale: safeScale)
        // Do not turn a live resize into 30 disk writes per second. Scale and
        // dimensions are included in the periodic payload, while the signature
        // remains limited to meaningful visibility/source changes.
        let signature = "\(status)|\(panelVisible)|\(locationSource ?? "none")"
        guard force || signature != lastSignature || now - lastWriteAt >= 15 else { return }

        var payload: [String: Any] = [
            "version": panelVersion,
            "edition": panelEdition,
            "petID": chatBirdPetID,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "status": status,
            "panelVisible": panelVisible,
            "codexWeeklyQuotaOnly": true,
            "claudeQuotaPeriods": ["5h", "weekly", "fable"],
            "panelBaseHeightPoints": expandedPanelSize.height,
            "panelWidthPoints": livePanelSize.width,
            "panelHeightPoints": livePanelSize.height,
            "panelScale": safeScale,
            "locationSource": locationSource ?? NSNull(),
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let gap { payload["petGapPoints"] = gap }
        if let centerError { payload["pointerCenterErrorPoints"] = centerError }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            lastSignature = signature
            lastWriteAt = now
        } catch {
            // The panel must remain usable even if a managed Mac blocks cache writes.
        }
    }
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?
}

private struct SpendControlLimit: Decodable {
    let remainingPercent: Int
    let resetsAt: Int64
}

private struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let individualLimit: SpendControlLimit?
}

private struct RateLimitsResult: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

private enum CodexResetCreditStatus: Equatable, Decodable {
    case available
    case other(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "available" ? .available : .other(value)
    }
}

private struct CodexResetCredit: Equatable, Decodable {
    let id: String
    let status: CodexResetCreditStatus
    let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case expiresAt = "expires_at"
    }
}

private struct CodexResetCreditsSnapshot: Equatable {
    let credits: [CodexResetCredit]
    let reportedAvailableCount: Int
    let updatedAt: Date

    func availableCredits(at date: Date) -> [CodexResetCredit] {
        credits
            .filter { credit in
                credit.status == .available
                    && (credit.expiresAt.map { $0 > date } ?? true)
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (left?, right?):
                    if left != right { return left < right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return lhs.id < rhs.id
            }
    }
}

private struct CodexResetCreditsResponse: Decodable {
    let credits: [CodexResetCredit]
    let availableCount: Int

    private enum CodingKeys: String, CodingKey {
        case credits
        case availableCount = "available_count"
    }
}

private struct RPCError: Decodable {
    let message: String
}

private struct RPCResponse: Decodable {
    let id: Int?
    let result: RateLimitsResult?
    let error: RPCError?
}

private enum QuotaProvider: String, CaseIterable {
    case codex
    case claudeCode

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claudeCode:
            return "Claude Code"
        }
    }

    var summaryRowName: String {
        switch self {
        case .codex:
            return "周额度"
        case .claudeCode:
            return "5 小时"
        }
    }

    var summaryWindowName: String {
        switch self {
        case .codex:
            return "周"
        case .claudeCode:
            return "5h"
        }
    }

    var iconResourceName: String {
        switch self {
        case .codex:
            return "ProviderIcon-codex"
        case .claudeCode:
            return "ProviderIcon-claude"
        }
    }

    var fallbackSymbolName: String {
        switch self {
        case .codex:
            return "sparkles"
        case .claudeCode:
            return "terminal"
        }
    }
}

private final class QuotaProviderPreference {
    private let defaults: UserDefaults
    private let key = "selected-quota-provider"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedProvider: QuotaProvider {
        get {
            guard let rawValue = defaults.string(forKey: key),
                  let provider = QuotaProvider(rawValue: rawValue)
            else { return .codex }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: key)
        }
    }
}

private struct QuotaRow: Equatable {
    let name: String
    let remainingPercent: Int
    let resetsAt: Date?
    let resetDescription: String?

    init(
        name: String,
        remainingPercent: Int,
        resetsAt: Date?,
        resetDescription: String? = nil
    ) {
        self.name = name
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }
}

private enum TaskProgressKind: String, Equatable {
    case reading
    case running
    case waitingForInput
    case completed
    case failed
    case idle

    var isActive: Bool {
        self == .running || self == .waitingForInput
    }
}

private enum TaskSource: String, Equatable {
    case codex
    case claudeCode
}

private func taskProgressSymbolName(for kind: TaskProgressKind) -> String {
    switch kind {
    case .running:
        return "arrow.triangle.2.circlepath"
    case .waitingForInput:
        return "questionmark.circle.fill"
    case .completed:
        return "checkmark.circle.fill"
    case .failed:
        return "exclamationmark.triangle.fill"
    case .reading:
        return "clock"
    case .idle:
        return "circle"
    }
}

private struct TaskProgressItem: Equatable {
    let title: String
    let kind: TaskProgressKind
    let startedAt: Date
    let updatedAt: Date
    let source: TaskSource
    let activityText: String?
    let statusOverride: String?
    let threadID: String?
    let sessionID: String?
    let workingDirectory: String?
    let processID: Int32?
    let processStartIdentity: String?

    init(
        title: String,
        kind: TaskProgressKind,
        startedAt: Date = .distantPast,
        updatedAt: Date? = nil,
        source: TaskSource = .codex,
        activityText: String? = nil,
        statusOverride: String? = nil,
        threadID: String? = nil,
        sessionID: String? = nil,
        workingDirectory: String? = nil,
        processID: Int32? = nil,
        processStartIdentity: String? = nil
    ) {
        self.title = title
        self.kind = kind
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.source = source
        self.activityText = activityText
        self.statusOverride = statusOverride
        self.threadID = threadID
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.processID = processID
        self.processStartIdentity = processStartIdentity
    }

    var statusText: String {
        if let statusOverride { return statusOverride }
        switch kind {
        case .reading:
            return "读取中"
        case .running:
            return "正在执行"
        case .waitingForInput:
            return "等你确认"
        case .completed:
            return "已完成"
        case .failed:
            return "执行失败"
        case .idle:
            return "等待"
        }
    }

    var identityKey: String {
        if let threadID { return "\(source.rawValue):\(threadID)" }
        if let sessionID { return "\(source.rawValue):\(sessionID)" }
        return "\(source.rawValue):\(normalizedTitle)"
    }

    var deduplicationKey: String {
        "\(source.rawValue):\(normalizedTitle)"
    }

    var canOpen: Bool {
        switch source {
        case .codex:
            return threadID != nil
        case .claudeCode:
            return (processID != nil && processStartIdentity != nil)
                || (sessionID != nil && workingDirectory != nil)
        }
    }

    private var normalizedTitle: String {
        title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

private struct ClaudeTerminalOpenRequest: Equatable {
    let sessionID: String?
    let workingDirectory: String?
    let processID: Int32?
    let processStartIdentity: String?

    init(
        sessionID: String?,
        workingDirectory: String?,
        processID: Int32?,
        processStartIdentity: String? = nil
    ) {
        let trimmedSessionID = sessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = trimmedSessionID.flatMap {
            UUID(uuidString: $0) == nil ? nil : $0.lowercased()
        }
        self.workingDirectory = workingDirectory.flatMap(normalizedAbsolutePath)
        let normalizedProcessID = processID.flatMap { $0 > 1 ? $0 : nil }
        let normalizedProcessStartIdentity = processStartIdentity?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedProcessID,
           let normalizedProcessStartIdentity,
           !normalizedProcessStartIdentity.isEmpty
        {
            self.processID = normalizedProcessID
            self.processStartIdentity = normalizedProcessStartIdentity
        } else {
            self.processID = nil
            self.processStartIdentity = nil
        }
    }
}

private enum ClaudeTerminalNavigationAction: Equatable {
    case focusProcess(processID: Int32, processStartIdentity: String)
    case resumeSession(sessionID: String, workingDirectory: String)
    case focusWorkingDirectory(String)
}

private func claudeTerminalNavigationPlan(
    for request: ClaudeTerminalOpenRequest
) -> [ClaudeTerminalNavigationAction] {
    var actions: [ClaudeTerminalNavigationAction] = []
    if let processID = request.processID,
       let processStartIdentity = request.processStartIdentity
    {
        actions.append(.focusProcess(
            processID: processID,
            processStartIdentity: processStartIdentity
        ))
    }
    if let sessionID = request.sessionID,
       let workingDirectory = request.workingDirectory
    {
        actions.append(.resumeSession(
            sessionID: sessionID,
            workingDirectory: workingDirectory
        ))
    } else if let workingDirectory = request.workingDirectory {
        // A directory is not a session identity. Only use it when no resumable
        // Claude session is available and the caller has no stronger target.
        actions.append(.focusWorkingDirectory(workingDirectory))
    }
    return actions
}

private func allowsGenericTerminalFallback(
    for request: ClaudeTerminalOpenRequest
) -> Bool {
    request.processID == nil
        && request.sessionID == nil
        && request.workingDirectory == nil
}

private func claudeTerminalOpenRequest(
    for item: TaskProgressItem
) -> ClaudeTerminalOpenRequest {
    ClaudeTerminalOpenRequest(
        sessionID: item.sessionID,
        workingDirectory: item.workingDirectory,
        processID: item.processID,
        processStartIdentity: item.processStartIdentity
    )
}

private func claudeTerminalOpenRequest(
    for prompt: ClaudePermissionPrompt,
    taskItems: [TaskProgressItem]
) -> ClaudeTerminalOpenRequest {
    let item = claudeTaskItem(
        forSessionID: prompt.sessionID,
        in: taskItems
    )
    return ClaudeTerminalOpenRequest(
        sessionID: prompt.sessionID,
        workingDirectory: prompt.workingDirectory,
        processID: item?.processID,
        processStartIdentity: item?.processStartIdentity
    )
}

@discardableResult
private func openClaudeTerminal(
    request: ClaudeTerminalOpenRequest
) -> Bool {
    for action in claudeTerminalNavigationPlan(for: request) {
        switch action {
        case .focusProcess(let processID, let processStartIdentity):
            if focusExistingClaudeTerminal(
                processID: processID,
                processStartIdentity: processStartIdentity
            ) {
                return true
            }
        case .resumeSession(let sessionID, let workingDirectory):
            if openClaudeSession(
                sessionID: sessionID,
                workingDirectory: workingDirectory
            ) {
                return true
            }
        case .focusWorkingDirectory(let workingDirectory):
            if focusExistingClaudeTerminal(
                workingDirectory: workingDirectory
            ) {
                return true
            }
        }
    }
    return false
}

private struct TaskProgressSnapshot: Equatable {
    let items: [TaskProgressItem]
    let isScrollable: Bool

    init(items: [TaskProgressItem], isScrollable: Bool = false) {
        self.items = items
        self.isScrollable = isScrollable
    }

    var kind: TaskProgressKind { items.first?.kind ?? .idle }
    var text: String {
        items.first?.statusText ?? "等待任务"
    }

    var rowCount: Int { max(1, min(maximumVisibleTaskRows, items.count)) }

    static let reading = TaskProgressSnapshot(items: [TaskProgressItem(
        title: "正在读取任务",
        kind: .reading
    )])

    static let idle = TaskProgressSnapshot(items: [TaskProgressItem(
        title: "暂无进行中的任务",
        kind: .idle
    )])

    static func displaying(_ sourceItems: [TaskProgressItem]) -> TaskProgressSnapshot {
        guard !sourceItems.isEmpty else { return .idle }

        // Recurring Codex tasks create a new thread on every run. Multiple
        // rows with the same title are indistinguishable in this compact view,
        // so show the highest-priority/newest sorted instance only.
        let sorted = sourceItems.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.title < $1.title }
            return $0.updatedAt > $1.updatedAt
        }
        var seenTitles = Set<String>()
        let deduplicated = sorted.filter { item in
            seenTitles.insert(item.deduplicationKey).inserted
        }
        guard !deduplicated.isEmpty else { return .idle }

        let active = deduplicated.filter(\.kind.isActive)
        if active.count > maximumVisibleTaskRows {
            return TaskProgressSnapshot(items: active, isScrollable: true)
        }

        let terminal = deduplicated.filter {
            $0.kind == .completed || $0.kind == .failed
        }
        let rows = Array((active + terminal).prefix(maximumVisibleTaskRows))
        guard !rows.isEmpty else { return .idle }
        return TaskProgressSnapshot(items: rows)
    }
}

private func claudeTaskItem(
    forSessionID sessionID: String?,
    in items: [TaskProgressItem]
) -> TaskProgressItem? {
    guard let sessionID else { return nil }
    return items.first {
        $0.source == .claudeCode
            && $0.sessionID?.caseInsensitiveCompare(sessionID) == .orderedSame
    }
}

private func claudeProcessID(
    forSessionID sessionID: String?,
    in items: [TaskProgressItem]
) -> Int32? {
    claudeTaskItem(forSessionID: sessionID, in: items)?.processID
}

private struct TaskActivityPreviewPayload: Equatable {
    let taskKey: String
    let body: String
}

private let maximumTaskActivityLines = 3
private let maximumTaskActivityCharacters = 4_096

private func taskActivityParagraph(from text: String) -> String? {
    let paragraph = text.components(separatedBy: .newlines)
        .map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return paragraph.isEmpty ? nil : paragraph
}

private func appendingTaskActivityParagraph(
    _ fragment: String,
    to current: String
) -> String {
    let combined = current.isEmpty ? fragment : "\(current) \(fragment)"
    return String(combined.suffix(maximumTaskActivityCharacters))
}

private func taskActivityVisibleTailText(
    from text: String,
    width: CGFloat,
    font: NSFont,
    lineSpacing: CGFloat,
    maximumLineCount: Int
) -> String {
    guard width > 0, maximumLineCount > 0, !text.isEmpty else {
        return ""
    }

    func renderedLineCount(_ candidate: String) -> Int {
        guard !candidate.isEmpty else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = lineSpacing
        let storage = NSTextStorage(
            string: candidate,
            attributes: [
                .font: font,
                .paragraphStyle: paragraph,
            ]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(
                width: width,
                height: .greatestFiniteMagnitude
            )
        )
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byCharWrapping
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        var lineCount = 0
        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(
                location: 0,
                length: layoutManager.numberOfGlyphs
            )
        ) { _, _, _, _, _ in
            lineCount += 1
        }
        return lineCount
    }

    guard renderedLineCount(text) > maximumLineCount else {
        return text
    }

    let characters = Array(text)
    var lowerBound = 1
    var upperBound = characters.count
    while lowerBound < upperBound {
        let candidateStart = lowerBound
            + (upperBound - lowerBound) / 2
        let candidate = String(characters.dropFirst(candidateStart))
        if renderedLineCount(candidate) <= maximumLineCount {
            upperBound = candidateStart
        } else {
            lowerBound = candidateStart + 1
        }
    }
    return String(characters.dropFirst(lowerBound))
}

private func taskActivityPreviewPayload(
    for item: TaskProgressItem
) -> TaskActivityPreviewPayload? {
    guard item.kind == .running else { return nil }
    let body = item.activityText.flatMap(taskActivityParagraph)
    return TaskActivityPreviewPayload(
        taskKey: item.identityKey,
        body: body ?? "正在思考"
    )
}

private final class TaskActivityPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TaskActivityPreviewView: NSView {
    static let bodyFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    static let bodyLineSpacing: CGFloat = 1
    static let horizontalInset: CGFloat = 13
    static let bodyOriginY: CGFloat = 31
    static let bottomInset: CGFloat = 9

    var bodyText = "正在思考" {
        didSet {
            guard bodyText != oldValue else { return }
            needsDisplay = true
        }
    }

    var visibleBodyText: String {
        taskActivityVisibleTailText(
            from: bodyText,
            width: max(0, bounds.width - Self.horizontalInset * 2),
            font: Self.bodyFont,
            lineSpacing: Self.bodyLineSpacing,
            maximumLineCount: maximumTaskActivityLines
        )
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let background = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 12,
            yRadius: 12
        )
        if let gradient = NSGradient(
            starting: NSColor(
                calibratedRed: 0.055,
                green: 0.15,
                blue: 0.26,
                alpha: 0.98
            ),
            ending: NSColor(
                calibratedRed: 0.025,
                green: 0.075,
                blue: 0.14,
                alpha: 0.99
            )
        ) {
            gradient.draw(in: background, angle: -90)
        }
        NSColor(
            calibratedRed: 0.47,
            green: 0.86,
            blue: 1.0,
            alpha: 0.28
        ).setStroke()
        background.lineWidth = 1
        background.stroke()

        drawText(
            "Codex 正在处理",
            in: NSRect(x: 13, y: 10, width: bounds.width - 26, height: 17),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.94),
            lineBreakMode: .byTruncatingTail
        )
        drawText(
            visibleBodyText,
            in: NSRect(
                x: Self.horizontalInset,
                y: Self.bodyOriginY,
                width: bounds.width - Self.horizontalInset * 2,
                height: max(
                    0,
                    bounds.height - Self.bodyOriginY - Self.bottomInset
                )
            ),
            font: Self.bodyFont,
            color: NSColor.white.withAlphaComponent(0.72),
            lineBreakMode: .byCharWrapping
        )
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        lineBreakMode: NSLineBreakMode
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        paragraph.lineSpacing = 1
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }
}

private final class TaskActivityPreviewController {
    private let previewSize = NSSize(width: 360, height: 84)
    private let contentView: TaskActivityPreviewView
    private let panel: TaskActivityPreviewPanel
    private var presentedTaskKey: String?

    init() {
        contentView = TaskActivityPreviewView(
            frame: NSRect(origin: .zero, size: previewSize)
        )
        panel = TaskActivityPreviewPanel(
            contentRect: NSRect(origin: .zero, size: previewSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
        contentView.autoresizingMask = [.width, .height]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue + 1
        )
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    var isVisible: Bool { panel.isVisible }
    var currentBody: String? {
        panel.isVisible ? contentView.visibleBodyText : nil
    }
    var currentPanelHeight: CGFloat { panel.frame.height }

    func show(
        item: TaskProgressItem,
        anchorRect: NSRect,
        visibleFrame: NSRect? = nil
    ) {
        guard let payload = taskActivityPreviewPayload(for: item) else {
            hide()
            return
        }
        presentedTaskKey = payload.taskKey
        contentView.bodyText = payload.body
        let resolvedVisibleFrame =
            visibleFrame ?? screenVisibleFrame(for: anchorRect)
        panel.setFrame(
            previewFrame(
                anchorRect: anchorRect,
                visibleFrame: resolvedVisibleFrame
            ),
            display: panel.isVisible
        )
        panel.orderFrontRegardless()
    }

    func update(item: TaskProgressItem) {
        guard let payload = taskActivityPreviewPayload(for: item),
              payload.taskKey == presentedTaskKey
        else {
            hide()
            return
        }
        contentView.bodyText = payload.body
    }

    func hide() {
        presentedTaskKey = nil
        panel.orderOut(nil)
    }

    private func screenVisibleFrame(for anchorRect: NSRect) -> NSRect {
        NSScreen.screens.first(where: {
            $0.frame.intersects(anchorRect)
        })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    private func previewFrame(
        anchorRect: NSRect,
        visibleFrame: NSRect
    ) -> NSRect {
        let margin: CGFloat = 8
        let proposedX = anchorRect.midX - previewSize.width / 2
        let maximumX = visibleFrame.maxX - previewSize.width - margin
        let x = max(
            visibleFrame.minX + margin,
            min(maximumX, proposedX)
        )
        let aboveY = anchorRect.maxY + margin
        let belowY = anchorRect.minY - previewSize.height - margin
        let proposedY = aboveY + previewSize.height <= visibleFrame.maxY - margin
            ? aboveY
            : belowY
        let maximumY = visibleFrame.maxY - previewSize.height - margin
        let y = max(
            visibleFrame.minY + margin,
            min(maximumY, proposedY)
        )
        return NSRect(origin: NSPoint(x: x, y: y), size: previewSize)
    }
}

private final class CodexTaskProgressReader {
    struct UnreadThreadState {
        let ids: Set<String>
        let isAvailable: Bool
    }

    private struct RolloutCandidate {
        let url: URL
        let modificationDate: Date
    }

    private struct ParsedCacheEntry {
        let modificationDate: Date
        let snapshot: TaskProgressSnapshot
    }

    private let fileManager = FileManager.default
    private let maximumTailBytes: UInt64 = 1_048_576
    private let rolloutRescanInterval: TimeInterval = codexTaskProgressRescanInterval
    private let activeTaskFreshness: TimeInterval = 30 * 60
    private let completedTaskVisibility: TimeInterval = 2 * 60
    private var cachedRollouts: [RolloutCandidate] = []
    private var cachedRolloutVisibility: [String: Bool] = [:]
    private var parsedCache: [String: ParsedCacheEntry] = [:]
    private var cachedThreadTitles: [String: String] = [:]
    private var cachedThreadIndexModificationDate: Date?
    private var cachedUnreadThreadIDs = Set<String>()
    private var cachedUnreadStateModificationDate: Date?
    private var hasCachedUnreadState = false
    private var nextRolloutScanAt = Date.distantPast

    func read() -> TaskProgressSnapshot {
        let now = Date()
        let threadTitles = readThreadTitleIndex()
        let unreadState = readUnreadThreadState()
        var items: [TaskProgressItem] = []
        for candidate in recentRollouts(at: now, unreadThreadIDs: unreadState.ids) {
            let cacheKey = candidate.url.path
            let snapshot: TaskProgressSnapshot
            if let cached = parsedCache[cacheKey],
               cached.modificationDate == candidate.modificationDate
            {
                snapshot = cached.snapshot
            } else {
                guard let lines = readTailLines(from: candidate.url) else { continue }
                snapshot = Self.parse(
                    lines: lines,
                    modificationDate: candidate.modificationDate,
                    now: now
                )
                parsedCache[cacheKey] = ParsedCacheEntry(
                    modificationDate: candidate.modificationDate,
                    snapshot: snapshot
                )
            }
            guard var item = snapshot.items.first, item.kind != .idle else { continue }
            let resolvedTitle = Self.resolvedTitle(
                for: candidate.url,
                indexedTitles: threadTitles,
                fallback: item.title
            )
            let threadID = Self.threadID(from: candidate.url)
            item = TaskProgressItem(
                title: resolvedTitle,
                kind: item.kind,
                startedAt: item.startedAt,
                updatedAt: item.updatedAt,
                activityText: item.activityText,
                statusOverride: item.statusOverride,
                threadID: threadID
            )
            guard Self.shouldDisplay(
                kind: item.kind,
                threadID: threadID,
                modificationDate: candidate.modificationDate,
                now: now,
                unreadState: unreadState,
                fallbackVisibility: completedTaskVisibility
            ) else { continue }
            items.append(item)
        }

        items.sort {
            if $0.updatedAt == $1.updatedAt { return $0.title < $1.title }
            return $0.updatedAt > $1.updatedAt
        }
        return .displaying(items)
    }

    static func parse(
        lines: [String],
        modificationDate: Date,
        now: Date
    ) -> TaskProgressSnapshot {
        var lifecycle: TaskProgressKind?
        var pendingUserInputCalls = Set<String>()
        var activeTools: [String: (text: String, updatedAt: Date)] = [:]
        var latestUserTitle: String?
        var activeTaskTitle: String?
        var publicCommentaryText = ""
        var latestPublicCommentary: String?
        var taskStartedAt = modificationDate
        var lastUpdatedAt = modificationDate

        for line in lines {
            guard line.contains("task_started")
                || line.contains("task_complete")
                || line.contains("task_failed")
                || line.contains("turn_aborted")
                || line.contains(#""type":"error""#)
                || line.contains("user_message")
                || line.contains("agent_message")
                || line.contains("request_user_input")
                || line.contains("function_call")
                || line.contains("custom_tool_call")
                || line.contains("function_call_output")
                || line.contains("custom_tool_call_output")
            else { continue }

            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = record["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String
            else { continue }

            if record["type"] as? String == "event_msg" {
                if payloadType == "user_message",
                   let message = payload["message"] as? String,
                   let title = taskTitle(from: message)
                {
                    latestUserTitle = title
                } else if payloadType == "task_started" {
                    lifecycle = .running
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    publicCommentaryText = ""
                    latestPublicCommentary = nil
                    activeTaskTitle = latestUserTitle ?? activeTaskTitle
                    taskStartedAt = timestamp(from: record) ?? modificationDate
                    lastUpdatedAt = timestamp(from: record) ?? modificationDate
                } else if payloadType == "task_complete" {
                    lifecycle = .completed
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    lastUpdatedAt = timestamp(from: record) ?? lastUpdatedAt
                } else if ["task_failed", "turn_aborted", "error"].contains(payloadType) {
                    lifecycle = .failed
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    lastUpdatedAt = timestamp(from: record) ?? lastUpdatedAt
                } else if payloadType == "agent_message",
                          payload["phase"] as? String == "commentary",
                          let message = payload["message"] as? String,
                          let commentary = sanitizedPublicCommentary(message)
                {
                    if latestPublicCommentary != commentary {
                        latestPublicCommentary = commentary
                        publicCommentaryText = appendingTaskActivityParagraph(
                            commentary,
                            to: publicCommentaryText
                        )
                    }
                    lastUpdatedAt = timestamp(from: record) ?? lastUpdatedAt
                }
                continue
            }

            if ["function_call", "custom_tool_call"].contains(payloadType),
               let name = payload["name"] as? String,
               let callID = payload["call_id"] as? String
            {
                let eventDate = timestamp(from: record) ?? lastUpdatedAt
                lastUpdatedAt = eventDate
                if name == "request_user_input" {
                    pendingUserInputCalls.insert(callID)
                    activeTools.removeValue(forKey: callID)
                } else {
                    activeTools[callID] = (
                        text: safeToolActivity(name: name),
                        updatedAt: eventDate
                    )
                }
                continue
            }

            if ["function_call_output", "custom_tool_call_output"].contains(payloadType),
               let callID = payload["call_id"] as? String
            {
                let wasPendingInput = pendingUserInputCalls.remove(callID) != nil
                let wasActiveTool = activeTools.removeValue(forKey: callID) != nil
                if wasPendingInput || wasActiveTool {
                    lastUpdatedAt = timestamp(from: record) ?? lastUpdatedAt
                }
            }
        }

        let title = activeTaskTitle ?? latestUserTitle ?? "Codex 任务"
        if lifecycle == .running, !pendingUserInputCalls.isEmpty {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .waitingForInput,
                startedAt: taskStartedAt,
                updatedAt: lastUpdatedAt
            )])
        }
        if let lifecycle {
            let activityText: String?
            if lifecycle == .running {
                activityText = runningActivityText(
                    activeTools: activeTools,
                    publicCommentaryText: publicCommentaryText
                )
            } else {
                activityText = nil
            }
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: lifecycle,
                startedAt: taskStartedAt,
                updatedAt: lastUpdatedAt,
                activityText: activityText
            )])
        }
        if !pendingUserInputCalls.isEmpty {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .waitingForInput,
                startedAt: taskStartedAt,
                updatedAt: lastUpdatedAt
            )])
        }
        if now.timeIntervalSince(modificationDate) <= 30 * 60 {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .running,
                startedAt: taskStartedAt,
                updatedAt: lastUpdatedAt,
                activityText: runningActivityText(
                    activeTools: activeTools,
                    publicCommentaryText: publicCommentaryText
                )
            )])
        }
        return .idle
    }

    private static func runningActivityText(
        activeTools: [String: (text: String, updatedAt: Date)],
        publicCommentaryText: String
    ) -> String {
        let activeTool = activeTools.values.max {
            $0.updatedAt < $1.updatedAt
        }?.text
        let sections = [
            activeTool,
            publicCommentaryText.isEmpty ? nil : publicCommentaryText,
        ].compactMap { $0 }
        return sections.isEmpty
            ? "正在思考"
            : sections.joined(separator: " · ")
    }

    private static func safeToolActivity(name: String) -> String {
        switch name.lowercased() {
        case "exec_command":
            return "正在运行命令"
        case "apply_patch":
            return "正在编辑文件"
        case let value
            where value.contains("web")
                || value.contains("browser")
                || value.contains("search"):
            return "正在搜索或检查网页"
        default:
            return "正在使用工具"
        }
    }

    private static func sanitizedPublicCommentary(_ message: String) -> String? {
        let markdownPatterns: [(String, String)] = [
            (#"!\[[^\]]*\]\([^)]+\)"#, ""),
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
            (#"[`*_>#~-]+"#, ""),
        ]
        var lines = message.components(separatedBy: .newlines).map {
            rawLine -> String in
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            for (pattern, replacement) in markdownPatterns {
                line = line.replacingOccurrences(
                    of: pattern,
                    with: replacement,
                    options: .regularExpression
                )
            }
            line = line.replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return line
        }
        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        let joined = lines.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func taskTitle(from rawMessage: String) -> String? {
        var value = rawMessage
        if let marker = value.range(
            of: "## My request for Codex:",
            options: [.caseInsensitive]
        ) {
            value = String(value[marker.upperBound...])
        }
        if let imageTag = value.range(of: "<image", options: [.caseInsensitive]) {
            value = String(value[..<imageTag.lowerBound])
        }

        let lines = value.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("# Files mentioned"),
                  !trimmed.hasPrefix("## My request"),
                  !trimmed.hasPrefix("/")
            else { return nil }
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#*- "))
        }
        let title = lines.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(80))
    }

    private static func timestamp(from record: [String: Any]) -> Date? {
        guard let raw = record["timestamp"] as? String else { return nil }
        return iso8601WithFractional.date(from: raw) ?? iso8601.date(from: raw)
    }

    static func threadID(from rolloutURL: URL) -> String? {
        let filename = rolloutURL.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let range = filename.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(filename[range]).lowercased()
    }

    static func resolvedTitle(
        for rolloutURL: URL,
        indexedTitles: [String: String],
        fallback: String
    ) -> String {
        guard let threadID = threadID(from: rolloutURL),
              let indexedTitle = indexedTitles[threadID],
              !indexedTitle.isEmpty
        else { return fallback }
        return indexedTitle
    }

    static func isUserVisibleSessionMetadata(line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any]
        else {
            return true
        }

        let threadSource = (payload["thread_source"] as? String)?.lowercased()
        if threadSource == "subagent" || threadSource == "automation" {
            return false
        }
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
            return false
        }
        return true
    }

    static func shouldDisplay(
        kind: TaskProgressKind,
        threadID: String?,
        modificationDate: Date,
        now: Date,
        unreadState: UnreadThreadState,
        fallbackVisibility: TimeInterval = 2 * 60
    ) -> Bool {
        guard kind == .completed || kind == .failed else { return true }
        if unreadState.isAvailable, let threadID {
            return unreadState.ids.contains(threadID)
        }
        return now.timeIntervalSince(modificationDate) <= fallbackVisibility
    }

    private func codexHomeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private func readThreadTitleIndex() -> [String: String] {
        let indexURL = codexHomeURL().appendingPathComponent("session_index.jsonl")
        guard let values = try? indexURL.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let modificationDate = values.contentModificationDate
        else {
            return cachedThreadTitles
        }

        if cachedThreadIndexModificationDate == modificationDate {
            return cachedThreadTitles
        }
        guard let data = try? Data(contentsOf: indexURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return cachedThreadTitles
        }

        var titles: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let rawID = record["id"] as? String,
                  let rawTitle = record["thread_name"] as? String
            else { continue }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            titles[rawID.lowercased()] = String(title.prefix(80))
        }

        cachedThreadTitles = titles
        cachedThreadIndexModificationDate = modificationDate
        return titles
    }

    private func readUnreadThreadState() -> UnreadThreadState {
        let stateURL: URL
        if let override = ProcessInfo.processInfo.environment["CHATBIRD_CODEX_STATE_FILE"],
           !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
        } else {
            stateURL = codexHomeURL().appendingPathComponent(".codex-global-state.json")
        }

        guard let values = try? stateURL.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let modificationDate = values.contentModificationDate
        else {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }
        if cachedUnreadStateModificationDate == modificationDate {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }

        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atomState = root["electron-persisted-atom-state"] as? [String: Any],
              let unreadByHost = atomState["unread-thread-ids-by-host-v1"] as? [String: Any]
        else {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }

        var ids = Set<String>()
        for value in unreadByHost.values {
            guard let hostIDs = value as? [String] else { continue }
            ids.formUnion(hostIDs.map { $0.lowercased() })
        }
        cachedUnreadThreadIDs = ids
        cachedUnreadStateModificationDate = modificationDate
        hasCachedUnreadState = true
        return UnreadThreadState(ids: ids, isAvailable: true)
    }

    private func recentRollouts(
        at now: Date,
        unreadThreadIDs: Set<String>
    ) -> [RolloutCandidate] {
        if let override = ProcessInfo.processInfo.environment["CHATBIRD_TASK_ROLLOUT_FILE"],
           !override.isEmpty
        {
            let url = URL(fileURLWithPath: override)
            guard isUserVisibleRollout(url) else { return [] }
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? now
            return [RolloutCandidate(url: url, modificationDate: modified)]
        }

        if now < nextRolloutScanAt, !cachedRollouts.isEmpty {
            return cachedRollouts.filter { fileManager.fileExists(atPath: $0.url.path) }
        }

        nextRolloutScanAt = now.addingTimeInterval(rolloutRescanInterval)
        let codexHome = codexHomeURL()
        let sessionsURL = codexHome.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            cachedRollouts = []
            return []
        }

        var candidates: [RolloutCandidate] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            let threadID = Self.threadID(from: url)
            let isUnread = threadID.map { unreadThreadIDs.contains($0) } ?? false
            guard now.timeIntervalSince(modified) <= activeTaskFreshness || isUnread,
                  isUserVisibleRollout(url)
            else {
                continue
            }
            candidates.append(RolloutCandidate(url: url, modificationDate: modified))
        }

        cachedRollouts = Array(candidates.sorted {
            $0.modificationDate > $1.modificationDate
        }.prefix(12))
        let activePaths = Set(cachedRollouts.map { $0.url.path })
        parsedCache = parsedCache.filter { activePaths.contains($0.key) }
        return cachedRollouts
    }

    private func isUserVisibleRollout(_ url: URL) -> Bool {
        if let cached = cachedRolloutVisibility[url.path] { return cached }

        var isVisible = true
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 262_144),
               let text = String(data: data, encoding: .utf8),
               let firstLine = text.split(separator: "\n", maxSplits: 1).first
            {
                isVisible = Self.isUserVisibleSessionMetadata(line: String(firstLine))
            }
        }
        cachedRolloutVisibility[url.path] = isVisible
        return isVisible
    }

    private func readTailLines(from url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let startOffset = fileSize > maximumTailBytes ? fileSize - maximumTailBytes : 0
        do {
            try handle.seek(toOffset: startOffset)
            guard var data = try handle.readToEnd(), !data.isEmpty else { return [] }
            if startOffset > 0, let firstNewline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(...firstNewline)
            }
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return text.split(whereSeparator: \.isNewline).map(String.init)
        } catch {
            return nil
        }
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()
}

private struct ClaudeAgentSnapshot: Equatable {
    let sessionID: String
    let title: String
    let workingDirectory: String
    let processID: Int32?
    let processStartIdentity: String?
    let kind: TaskProgressKind
    let startedAt: Date
    let statusOverride: String?
}

private func claudeAgentRefreshInterval(agentCount: Int) -> TimeInterval {
    agentCount > 0 ? taskProgressRefreshInterval : 15
}

private func shouldRefreshClaudeAgents(
    cachedAgentCount: Int,
    hasRecentlyModifiedTranscript: Bool
) -> Bool {
    cachedAgentCount > 0 || hasRecentlyModifiedTranscript
}

private func isLiveProcess(_ processID: Int32) -> Bool {
    guard processID > 1 else { return false }
    if Darwin.kill(processID, 0) == 0 {
        return true
    }
    return errno == EPERM
}

private func processStatusText(
    forProcessID processID: Int32,
    field: String
) -> String? {
    guard processID > 1 else { return nil }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", "\(processID)", "-o", "\(field)="]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    process.environment = environment
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0,
          let text = String(
              data: output.fileHandleForReading.readDataToEndOfFile(),
              encoding: .utf8
          )
    else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func currentProcessStartIdentity(
    forProcessID processID: Int32
) -> String? {
    processStatusText(forProcessID: processID, field: "lstart")
}

private func processCommandLine(forProcessID processID: Int32) -> String? {
    processStatusText(forProcessID: processID, field: "command")
}

private func isClaudeCodeCommandLine(_ value: String) -> Bool {
    let normalized = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard !normalized.isEmpty else { return false }
    let executable = normalized
        .split(whereSeparator: \.isWhitespace)
        .first
        .map(String.init) ?? ""
    let executableName = URL(fileURLWithPath: executable).lastPathComponent
    return executableName == "claude"
        || executableName == "claude.exe"
        || executableName.hasPrefix("claude-")
        || normalized.contains("/@anthropic-ai/claude-code/")
}

private func processChainContainsClaude(
    startingAt processID: Int32,
    commandLine: (Int32) -> String?,
    parentPID: (Int32) -> Int32?
) -> Bool {
    var candidate = processID
    var visited = Set<Int32>()
    for _ in 0..<16 {
        guard candidate > 1, visited.insert(candidate).inserted else { break }
        if let command = commandLine(candidate),
           isClaudeCodeCommandLine(command)
        {
            return true
        }
        guard let parent = parentPID(candidate) else { break }
        candidate = parent
    }
    return false
}

private func isLiveClaudeProcess(_ processID: Int32) -> Bool {
    isLiveProcess(processID)
        && processChainContainsClaude(
            startingAt: processID,
            commandLine: { processCommandLine(forProcessID: $0) },
            parentPID: { parentProcessID(forProcessID: $0) }
        )
}

private func claudeAgentActivityPriority(_ kind: TaskProgressKind) -> Int {
    switch kind {
    case .running:
        return 5
    case .waitingForInput:
        return 4
    case .reading:
        return 3
    case .completed:
        return 2
    case .failed:
        return 1
    case .idle:
        return 0
    }
}

private func shouldPreferClaudeAgent(
    _ candidate: ClaudeAgentSnapshot,
    over existing: ClaudeAgentSnapshot
) -> Bool {
    let candidatePIDRank = candidate.processID == nil ? 0 : 1
    let existingPIDRank = existing.processID == nil ? 0 : 1
    if candidatePIDRank != existingPIDRank {
        return candidatePIDRank > existingPIDRank
    }

    let candidateActivity = claudeAgentActivityPriority(candidate.kind)
    let existingActivity = claudeAgentActivityPriority(existing.kind)
    if candidateActivity != existingActivity {
        return candidateActivity > existingActivity
    }
    if candidate.startedAt != existing.startedAt {
        return candidate.startedAt > existing.startedAt
    }
    if candidate.title != existing.title {
        return candidate.title < existing.title
    }
    if candidate.workingDirectory != existing.workingDirectory {
        return candidate.workingDirectory < existing.workingDirectory
    }
    if candidate.processID != existing.processID {
        return (candidate.processID ?? 0) < (existing.processID ?? 0)
    }
    let candidateStartIdentity = candidate.processStartIdentity ?? ""
    let existingStartIdentity = existing.processStartIdentity ?? ""
    if candidateStartIdentity != existingStartIdentity {
        return candidateStartIdentity < existingStartIdentity
    }
    let candidateStatus = candidate.statusOverride ?? ""
    let existingStatus = existing.statusOverride ?? ""
    if candidateStatus != existingStatus {
        return candidateStatus < existingStatus
    }
    return false
}

private func claudeAgentsBySessionID(
    _ agents: [ClaudeAgentSnapshot],
    isProcessAlive: (Int32) -> Bool = isLiveClaudeProcess
) -> [String: ClaudeAgentSnapshot] {
    var result: [String: ClaudeAgentSnapshot] = [:]
    for agent in agents {
        let sessionID = agent.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard UUID(uuidString: sessionID) != nil else { continue }
        let normalizedProcessStartIdentity = agent.processStartIdentity?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let liveProcessID = agent.processID.flatMap {
            $0 > 1
                && normalizedProcessStartIdentity?.isEmpty == false
                && isProcessAlive($0)
                ? $0
                : nil
        }
        let normalized = ClaudeAgentSnapshot(
            sessionID: sessionID,
            title: agent.title,
            workingDirectory: agent.workingDirectory,
            processID: liveProcessID,
            processStartIdentity: liveProcessID == nil
                ? nil
                : normalizedProcessStartIdentity,
            kind: agent.kind,
            startedAt: agent.startedAt,
            statusOverride: agent.statusOverride
        )
        guard let existing = result[sessionID] else {
            result[sessionID] = normalized
            continue
        }
        if shouldPreferClaudeAgent(
            normalized,
            over: existing
        ) {
            result[sessionID] = normalized
        }
    }
    return result
}

private final class ClaudeTaskProgressReader {

    private struct TranscriptCandidate {
        let url: URL
        let modificationDate: Date
        let sessionID: String
    }

    private struct ParsedCacheEntry {
        let modificationDate: Date
        let activeKind: TaskProgressKind?
        let activeTitle: String
        let activeProcessID: Int32?
        let activeProcessStartIdentity: String?
        let item: TaskProgressItem?
    }

    private let fileManager = FileManager.default
    private let maximumTailBytes: UInt64 = 1_048_576
    private let transcriptRescanInterval: TimeInterval = 5
    private let completedTaskVisibility: TimeInterval = 2 * 60
    private var cachedCandidates: [TranscriptCandidate] = []
    private var parsedCache: [String: ParsedCacheEntry] = [:]
    private var nextTranscriptScanAt = Date.distantPast
    private var cachedAgents: [ClaudeAgentSnapshot] = []
    private var nextAgentRefreshAt = Date.distantPast

    func read() -> TaskProgressSnapshot {
        let now = Date()
        let cachedActiveSessionIDs = Set(
            cachedAgents.map { $0.sessionID.lowercased() }
        )
        var candidates = recentTranscripts(
            now: now,
            activeSessionIDs: cachedActiveSessionIDs
        )
        let hasRecentlyModifiedTranscript = candidates.contains {
            now.timeIntervalSince($0.modificationDate) <= 30
        }
        let agentSnapshots = shouldRefreshClaudeAgents(
            cachedAgentCount: cachedAgents.count,
            hasRecentlyModifiedTranscript: hasRecentlyModifiedTranscript
        ) ? recentAgents(now: now) : cachedAgents
        let agentsBySessionID = claudeAgentsBySessionID(
            agentSnapshots
        )
        let agents = agentsBySessionID.values.sorted {
            $0.sessionID < $1.sessionID
        }
        let activeSessionIDs = Set(agentsBySessionID.keys)
        let locatedSessionIDs = Set(candidates.map(\.sessionID))
        if !activeSessionIDs.isSubset(of: locatedSessionIDs) {
            nextTranscriptScanAt = .distantPast
            candidates = recentTranscripts(
                now: now,
                activeSessionIDs: activeSessionIDs
            )
        }

        var items: [TaskProgressItem] = []
        var parsedSessionIDs = Set<String>()
        for candidate in candidates {
            let agent = agentsBySessionID[candidate.sessionID]
            if agent == nil,
               now.timeIntervalSince(candidate.modificationDate)
                    > completedTaskVisibility {
                continue
            }
            let cacheKey = candidate.url.path
            let item: TaskProgressItem?
            if let cached = parsedCache[cacheKey],
               cached.modificationDate == candidate.modificationDate,
               cached.activeKind == agent?.kind,
               cached.activeTitle == (agent?.title ?? ""),
               cached.activeProcessID == agent?.processID,
               cached.activeProcessStartIdentity
                    == agent?.processStartIdentity
            {
                item = cached.item
            } else {
                let lines = readTailLines(from: candidate.url) ?? []
                item = Self.parseTranscript(
                    lines: lines,
                    sessionID: candidate.sessionID,
                    fallbackTitle: agent?.title ?? "Claude 会话",
                    workingDirectory: agent?.workingDirectory ?? "",
                    processID: agent?.processID,
                    processStartIdentity: agent?.processStartIdentity,
                    activeKind: agent?.kind,
                    startedAt: agent?.startedAt ?? candidate.modificationDate,
                    modificationDate: candidate.modificationDate,
                    now: now,
                    statusOverride: agent?.statusOverride
                )
                parsedCache[cacheKey] = ParsedCacheEntry(
                    modificationDate: candidate.modificationDate,
                    activeKind: agent?.kind,
                    activeTitle: agent?.title ?? "",
                    activeProcessID: agent?.processID,
                    activeProcessStartIdentity: agent?.processStartIdentity,
                    item: item
                )
            }
            if let item {
                items.append(item)
                parsedSessionIDs.insert(candidate.sessionID)
            }
        }

        for agent in agents where !parsedSessionIDs.contains(agent.sessionID) {
            items.append(TaskProgressItem(
                title: agent.title,
                kind: agent.kind,
                startedAt: agent.startedAt,
                updatedAt: agent.startedAt,
                source: .claudeCode,
                activityText: agent.kind == .running ? "正在思考" : nil,
                statusOverride: agent.statusOverride,
                sessionID: agent.sessionID,
                workingDirectory: agent.workingDirectory,
                processID: agent.processID,
                processStartIdentity: agent.processStartIdentity
            ))
        }

        return .displaying(items)
    }

    private func recentAgents(now: Date) -> [ClaudeAgentSnapshot] {
        if now < nextAgentRefreshAt {
            return cachedAgents
        }
        cachedAgents = readAgents()
        nextAgentRefreshAt = now.addingTimeInterval(
            claudeAgentRefreshInterval(agentCount: cachedAgents.count)
        )
        return cachedAgents
    }

    static func parseTranscript(
        lines: [String],
        sessionID: String,
        fallbackTitle: String,
        workingDirectory: String,
        processID: Int32? = nil,
        processStartIdentity: String? = nil,
        activeKind: TaskProgressKind?,
        startedAt: Date,
        modificationDate: Date,
        now: Date,
        statusOverride: String? = nil
    ) -> TaskProgressItem? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        var latestUserTitle: String?
        var detectedWorkingDirectory: String?
        var publicActivity = ""
        var activeTools: [String: (text: String, updatedAt: Date)] = [:]
        var pendingUserInputCalls = Set<String>()
        var lastUpdatedAt = modificationDate
        var lastStopReason: String?
        var lastMeaningfulRole: String?
        var failed = false

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { continue }
            let timestamp = timestamp(from: record) ?? lastUpdatedAt
            lastUpdatedAt = max(lastUpdatedAt, timestamp)
            if let cwd = record["cwd"] as? String, cwd.hasPrefix("/") {
                detectedWorkingDirectory = cwd
            }

            let type = (record["type"] as? String)?.lowercased()
            if type == "user",
               let message = record["message"] as? [String: Any] {
                if let content = message["content"] as? String,
                   let title = taskTitle(from: content) {
                    latestUserTitle = title
                    lastMeaningfulRole = "user"
                } else if let content = message["content"] as? [[String: Any]] {
                    var containsToolResult = false
                    for block in content {
                        let blockType = (block["type"] as? String)?.lowercased()
                        if blockType == "tool_result" {
                            containsToolResult = true
                            if let toolUseID = block["tool_use_id"] as? String {
                                activeTools.removeValue(forKey: toolUseID)
                                pendingUserInputCalls.remove(toolUseID)
                            }
                        }
                    }
                    if !containsToolResult,
                       let title = taskTitle(from: content.compactMap({
                           ($0["type"] as? String) == "text"
                               ? $0["text"] as? String
                               : nil
                       }).joined(separator: " ")) {
                        latestUserTitle = title
                        lastMeaningfulRole = "user"
                    }
                }
                continue
            }

            if type == "assistant",
               let message = record["message"] as? [String: Any] {
                lastMeaningfulRole = "assistant"
                lastStopReason = message["stop_reason"] as? String
                if message["error"] != nil || record["error"] != nil {
                    failed = true
                }
                guard let content = message["content"] as? [[String: Any]]
                else { continue }
                for block in content {
                    let blockType = (block["type"] as? String)?.lowercased()
                    if blockType == "text",
                       let text = block["text"] as? String,
                       let paragraph = taskActivityParagraph(from: text) {
                        publicActivity = appendingTaskActivityParagraph(
                            paragraph,
                            to: publicActivity
                        )
                    } else if blockType == "tool_use",
                              let name = block["name"] as? String {
                        let callID = block["id"] as? String ?? UUID().uuidString
                        if isUserInputTool(name) {
                            pendingUserInputCalls.insert(callID)
                        } else {
                            activeTools[callID] = (
                                safeToolActivity(name: name),
                                timestamp
                            )
                        }
                    }
                }
                continue
            }

            if type == "system",
               let subtype = (record["subtype"] as? String)?.lowercased(),
               subtype.contains("error") {
                failed = true
            }
        }

        let kind: TaskProgressKind
        if failed {
            kind = .failed
        } else if !pendingUserInputCalls.isEmpty {
            kind = .waitingForInput
        } else if let activeKind {
            if activeKind == .waitingForInput,
               lastStopReason == "end_turn",
               lastMeaningfulRole == "assistant" {
                kind = .completed
            } else {
                kind = activeKind
            }
        } else if lastStopReason == "end_turn" {
            kind = .completed
        } else if now.timeIntervalSince(modificationDate) <= 30 * 60 {
            kind = .running
        } else {
            return nil
        }

        let activeTool = activeTools.values.max {
            $0.updatedAt < $1.updatedAt
        }?.text
        let activityText: String?
        if kind == .running {
            let sections = [
                activeTool,
                publicActivity.isEmpty ? nil : publicActivity,
            ].compactMap { $0 }
            activityText = sections.isEmpty
                ? "正在思考"
                : sections.joined(separator: " · ")
        } else {
            activityText = nil
        }
        let normalizedFallback = taskTitle(from: fallbackTitle)
        let title = normalizedFallback == "Claude 会话"
            ? (latestUserTitle ?? "Claude 会话")
            : (normalizedFallback ?? latestUserTitle ?? "Claude 会话")
        let cwd = workingDirectory.hasPrefix("/")
            ? workingDirectory
            : (detectedWorkingDirectory ?? "")
        return TaskProgressItem(
            title: title,
            kind: kind,
            startedAt: startedAt,
            updatedAt: lastUpdatedAt,
            source: .claudeCode,
            activityText: activityText,
            statusOverride: statusOverride,
            sessionID: sessionID.lowercased(),
            workingDirectory: cwd.isEmpty ? nil : cwd,
            processID: processID,
            processStartIdentity: processStartIdentity
        )
    }

    private func readAgents() -> [ClaudeAgentSnapshot] {
        guard let claudeURL = locateClaude() else { return [] }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = claudeURL
        process.arguments = ["agents", "--json"]
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = launchEnvironment()
        do {
            try process.run()
        } catch {
            return []
        }

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let values = try? JSONSerialization.jsonObject(with: data)
            as? [[String: Any]]
        else { return [] }

        let fallbackStartedMilliseconds = Date().timeIntervalSince1970 * 1_000
        return values.compactMap { value in
            guard let rawSessionID = value["sessionId"] as? String,
                  UUID(uuidString: rawSessionID) != nil,
                  rawSessionID.lowercased()
                    != ClaudeQuotaClient.probeSessionID.uuidString.lowercased(),
                  let cwd = value["cwd"] as? String,
                  cwd.hasPrefix("/")
            else { return nil }
            let rawStatus = (
                value["status"] as? String
                    ?? value["state"] as? String
                    ?? "busy"
            ).lowercased()
            let kind: TaskProgressKind
            let statusOverride: String?
            switch rawStatus {
            case "failed", "error", "crashed":
                kind = .failed
                statusOverride = nil
            case "completed", "complete", "done":
                kind = .completed
                statusOverride = nil
            case "blocked":
                kind = .waitingForInput
                statusOverride = "已阻塞"
            case "waiting", "idle":
                kind = .waitingForInput
                statusOverride = "等待中"
            default:
                kind = .running
                statusOverride = nil
            }
            let rawTitle = value["name"] as? String ?? "Claude 会话"
            let title = Self.taskTitle(from: rawTitle) ?? "Claude 会话"
            let rawProcessID = value["pid"] as? Int
                ?? (value["pid"] as? NSNumber)?.intValue
            let processID = rawProcessID.flatMap(Int32.init(exactly:))
                .flatMap { $0 > 1 ? $0 : nil }
            let processStartIdentity = processID.flatMap(
                currentProcessStartIdentity(forProcessID:)
            )
            let startedMilliseconds = value["startedAt"] as? Double
                ?? (value["startedAt"] as? NSNumber)?.doubleValue
                ?? fallbackStartedMilliseconds
            return ClaudeAgentSnapshot(
                sessionID: rawSessionID.lowercased(),
                title: title,
                workingDirectory: cwd,
                processID: processID,
                processStartIdentity: processStartIdentity,
                kind: kind,
                startedAt: Date(
                    timeIntervalSince1970: startedMilliseconds / 1_000
                ),
                statusOverride: statusOverride
            )
        }
    }

    private func recentTranscripts(
        now: Date,
        activeSessionIDs: Set<String>
    ) -> [TranscriptCandidate] {
        if now < nextTranscriptScanAt {
            return cachedCandidates.filter {
                activeSessionIDs.contains($0.sessionID)
                    || now.timeIntervalSince($0.modificationDate)
                        <= completedTaskVisibility
            }
        }
        nextTranscriptScanAt = now.addingTimeInterval(transcriptRescanInterval)
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
            ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .appendingPathComponent("projects", isDirectory: true)
            },
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
            home.appendingPathComponent(".claude/projects", isDirectory: true),
        ].compactMap { $0 }

        var byPath: [String: TranscriptCandidate] = [:]
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                      !url.path.contains("/subagents/"),
                      let sessionID = Self.sessionID(from: url),
                      sessionID
                        != ClaudeQuotaClient.probeSessionID.uuidString.lowercased(),
                      let values = try? url.resourceValues(
                          forKeys: [
                              .contentModificationDateKey,
                              .isRegularFileKey,
                          ]
                      ),
                      values.isRegularFile == true,
                      let modificationDate = values.contentModificationDate,
                      activeSessionIDs.contains(sessionID)
                        || now.timeIntervalSince(modificationDate)
                            <= completedTaskVisibility
                else { continue }
                byPath[url.path] = TranscriptCandidate(
                    url: url,
                    modificationDate: modificationDate,
                    sessionID: sessionID
                )
            }
        }
        cachedCandidates = byPath.values.sorted {
            $0.modificationDate > $1.modificationDate
        }
        let activePaths = Set(cachedCandidates.map(\.url.path))
        parsedCache = parsedCache.filter { activePaths.contains($0.key) }
        return cachedCandidates
    }

    private func readTailLines(from url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let startOffset = fileSize > maximumTailBytes
            ? fileSize - maximumTailBytes
            : 0
        do {
            try handle.seek(toOffset: startOffset)
            guard var data = try handle.readToEnd(), !data.isEmpty else {
                return []
            }
            if startOffset > 0, let firstNewline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(...firstNewline)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text.split(whereSeparator: \.isNewline).map(String.init)
        } catch {
            return nil
        }
    }

    private func locateClaude() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            ProcessInfo.processInfo.environment["CLAUDE_BIN"],
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ].compactMap { $0 }
        return candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0)
        }).map(URL.init(fileURLWithPath:))
    }

    private func launchEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let standardPath = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        environment["PATH"] = "\(standardPath):\(environment["PATH"] ?? "")"
        environment["DISABLE_AUTOUPDATER"] = "1"
        return environment
    }

    private static func sessionID(from url: URL) -> String? {
        let value = url.deletingPathExtension().lastPathComponent.lowercased()
        return UUID(uuidString: value) == nil ? nil : value
    }

    private static func isUserInputTool(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("askuserquestion")
            || normalized.contains("request_user_input")
    }

    private static func safeToolActivity(name: String) -> String {
        let normalized = name.lowercased()
        if normalized.contains("bash") || normalized.contains("command") {
            return "正在运行命令"
        }
        if normalized.contains("edit")
            || normalized.contains("write")
            || normalized.contains("patch") {
            return "正在编辑文件"
        }
        if normalized.contains("read")
            || normalized.contains("grep")
            || normalized.contains("glob") {
            return "正在检查文件"
        }
        if normalized.contains("web") || normalized.contains("search") {
            return "正在搜索或检查网页"
        }
        return "正在使用工具"
    }

    private static func taskTitle(from rawText: String) -> String? {
        let text = rawText
            .replacingOccurrences(
                of: #"<[^>]+>"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"[`*_>#~-]+"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(80))
    }

    private static func timestamp(from record: [String: Any]) -> Date? {
        guard let raw = record["timestamp"] as? String else { return nil }
        return iso8601WithFractional.date(from: raw) ?? iso8601.date(from: raw)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()
}

private final class CombinedTaskProgressReader {
    private let codexReader = CodexTaskProgressReader()
    private let claudeReader = ClaudeTaskProgressReader()

    func read() -> TaskProgressSnapshot {
        let codexItems = codexReader.read().items.filter {
            $0.kind != .idle && $0.kind != .reading
        }
        let claudeItems = claudeReader.read().items.filter {
            $0.kind != .idle && $0.kind != .reading
        }
        return .displaying(codexItems + claudeItems)
    }
}

private func codexSnapshot(from response: RateLimitsResult) -> RateLimitSnapshot {
    if let snapshots = response.rateLimitsByLimitId {
        if let exactMatch = snapshots["codex"] {
            return exactMatch
        }
        if let idMatch = snapshots.values.first(where: { $0.limitId == "codex" }) {
            return idMatch
        }
    }
    return response.rateLimits
}

/// Codex currently exposes its weekly allowance as the only standard window,
/// while older builds exposed a short primary window plus a weekly secondary
/// window. Select by duration so the UI never falls back to the retired 5-hour
/// value when it encounters an older response shape.
private func weeklyRateLimitWindow(from snapshot: RateLimitSnapshot) -> RateLimitWindow? {
    let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
    let minimumWeeklyDurationMins: Int64 = 6 * 24 * 60
    let explicitWeeklyWindows = windows.filter {
        ($0.windowDurationMins ?? 0) >= minimumWeeklyDurationMins
    }
    if let longestWeeklyWindow = explicitWeeklyWindows.max(by: {
        ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0)
    }) {
        return longestWeeklyWindow
    }

    // Duration-free windows cannot be proven to be weekly. Refuse them rather
    // than presenting a retired short allowance as a weekly percentage.
    return nil
}

private enum PointerSide: Equatable {
    case left
    case right
    case bottom
}

private enum QuotaClientError: LocalizedError {
    case codexNotFound
    case launchFailed(String)
    case noResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "没有找到 Codex 本机服务"
        case .launchFailed(let detail):
            return "无法启动 Codex 本机服务：\(detail)"
        case .noResponse:
            return "Codex 暂未返回额度数据"
        case .server(let detail):
            return detail
        }
    }
}

private enum CodexResetCreditsClientError: LocalizedError {
    case credentialsUnavailable
    case invalidEndpoint
    case requestFailed
    case unauthorized
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .credentialsUnavailable:
            return "Codex 登录信息暂不可用"
        case .invalidEndpoint:
            return "重置额度服务地址无效"
        case .requestFailed:
            return "重置额度服务暂不可用"
        case .unauthorized:
            return "Codex 登录已过期"
        case .invalidResponse:
            return "无法识别重置额度数据"
        }
    }
}

private struct QuotaFailurePresentation: Equatable {
    let errorText: String?
    let statusText: String
}

private func quotaFailurePresentation(
    for error: Error,
    hasExistingRows: Bool,
    provider: QuotaProvider = .codex
) -> QuotaFailurePresentation {
    let displayError: String
    if provider == .claudeCode, let quotaError = error as? ClaudeQuotaError {
        switch quotaError {
        case .claudeNotFound:
            displayError = "未找到 Claude Code"
        case .launchFailed, .captureFailed, .parseFailed:
            displayError = "无法读取 Claude 额度"
        }
    } else if let quotaError = error as? QuotaClientError {
        switch quotaError {
        case .codexNotFound:
            displayError = "未找到 Codex"
        case .launchFailed:
            displayError = "无法读取 Codex 额度"
        case .noResponse, .server:
            displayError = "额度服务暂不可用"
        }
    } else {
        displayError = "额度暂不可用"
    }
    return QuotaFailurePresentation(
        errorText: hasExistingRows ? nil : displayError,
        statusText: "1 分钟后自动重试"
    )
}

private enum ClaudeQuotaError: LocalizedError {
    case claudeNotFound
    case launchFailed
    case captureFailed
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "没有找到 Claude Code"
        case .launchFailed:
            return "无法启动 Claude Code"
        case .captureFailed:
            return "Claude Code 暂未返回额度"
        case .parseFailed:
            return "无法识别 Claude Code 额度"
        }
    }
}

private struct ClaudeQuotaSnapshot: Equatable {
    let rows: [QuotaRow]
}

private enum ClaudeQuotaParser {
    static func parse(_ rawText: String) throws -> ClaudeQuotaSnapshot {
        let clean = stripTerminalControlSequences(rawText)
        guard !clean.isEmpty else { throw ClaudeQuotaError.parseFailed }

        guard let session = quotaRow(
            labelPattern: #"current\s*session"#,
            name: "5 小时",
            in: clean
        ) else {
            throw ClaudeQuotaError.parseFailed
        }

        var rows = [session]
        if let weekly = quotaRow(
            labelPattern: #"current\s*week\s*\(\s*all\s*models\s*\)"#,
            name: "周额度",
            in: clean
        ) {
            rows.append(weekly)
        }
        if let fable = quotaRow(
            labelPattern: #"current\s*week\s*\(\s*fable\s*\)"#,
            name: "Fable",
            in: clean
        ) {
            rows.append(fable)
        }
        return ClaudeQuotaSnapshot(rows: rows)
    }

    static func stripTerminalControlSequences(_ text: String) -> String {
        var clean = text
        let patterns = [
            #"\u001B\][^\u0007]*(?:\u0007|\u001B\\)"#,
            #"\u001B\[[0-?]*[ -/]*[@-~]"#,
            #"\u001B[@-_]"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            clean = expression.stringByReplacingMatches(
                in: clean,
                range: NSRange(clean.startIndex..<clean.endIndex, in: clean),
                withTemplate: ""
            )
        }

        var output = ""
        for character in clean.replacingOccurrences(of: "\r", with: "\n") {
            if character == "\u{8}" {
                if !output.isEmpty { output.removeLast() }
            } else if character == "\n" || character == "\t"
                        || character.unicodeScalars.allSatisfy({
                            $0.value >= 0x20 && $0.value != 0x7F
                        }) {
                output.append(character)
            }
        }
        return output
    }

    private static func quotaRow(
        labelPattern: String,
        name: String,
        in text: String
    ) -> QuotaRow? {
        guard let labelRange = lastMatchRange(
            pattern: labelPattern,
            in: text
        ) else { return nil }

        let afterLabel = text[labelRange.upperBound...]
        let boundary = afterLabel.range(
            of: #"(?i)current\s*(?:session|week)"#,
            options: .regularExpression
        )?.lowerBound
        let sectionEnd = boundary ?? afterLabel.endIndex
        let section = String(afterLabel[..<sectionEnd].prefix(1_200))

        guard let percentage = percentage(from: section) else { return nil }
        let resetDescription = resetDescription(from: section)
        let resetsAt = resetDescription.flatMap { resetDate(from: $0) }
        return QuotaRow(
            name: name,
            remainingPercent: percentage,
            resetsAt: resetsAt,
            resetDescription: resetsAt == nil ? resetDescription : nil
        )
    }

    private static func lastMatchRange(
        pattern: String,
        in text: String
    ) -> Range<String.Index>? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.matches(
            in: text,
            range: searchRange
        ).last else { return nil }
        return Range(match.range, in: text)
    }

    private static func percentage(from text: String) -> Int? {
        let patterns = [
            #"([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*(left|remaining|available|used)?"#,
            #"(left|remaining|available|used)\s*([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: range) else {
                continue
            }
            let valueGroup = index == 0 ? 1 : 2
            let qualifierGroup = index == 0 ? 2 : 1
            guard let valueRange = Range(match.range(at: valueGroup), in: text),
                  let value = Double(text[valueRange])
            else { continue }
            let qualifier = Range(match.range(at: qualifierGroup), in: text)
                .map { String(text[$0]).lowercased() } ?? ""
            let rounded = Int(value.rounded())
            let remaining = qualifier == "used" ? 100 - rounded : rounded
            return max(0, min(100, remaining))
        }
        return nil
    }

    private static func resetDescription(from text: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"resets?\s*([^\n\r]+)"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        var value = String(text[valueRange])
            .replacingOccurrences(
                of: #"\s*\([^)]*\)\s*"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: " at ", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if value.count > 36 {
            value = String(value.prefix(36))
        }
        return value.isEmpty ? nil : value
    }

    private static func resetDate(from rawValue: String, now: Date = Date()) -> Date? {
        let value = rawValue
            .lowercased()
            .replacingOccurrences(of: " at ", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let expression = try? NSRegularExpression(
            pattern: #"^(?:(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\s+([0-9]{1,2})\s+)?([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)$"#,
            options: [.caseInsensitive]
        )
        guard let expression,
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let hourRange = Range(match.range(at: 3), in: value),
              let meridiemRange = Range(match.range(at: 5), in: value),
              let rawHour = Int(value[hourRange])
        else { return nil }

        let minute = Range(match.range(at: 4), in: value)
            .flatMap { Int(value[$0]) } ?? 0
        guard (1...12).contains(rawHour), (0...59).contains(minute) else {
            return nil
        }
        let meridiem = String(value[meridiemRange]).lowercased()
        let hour = (rawHour % 12) + (meridiem == "pm" ? 12 : 0)
        let calendar = Calendar.current

        if let monthRange = Range(match.range(at: 1), in: value),
           let dayRange = Range(match.range(at: 2), in: value),
           let day = Int(value[dayRange])
        {
            let months = [
                "jan": 1, "feb": 2, "mar": 3, "apr": 4,
                "may": 5, "jun": 6, "jul": 7, "aug": 8,
                "sep": 9, "oct": 10, "nov": 11, "dec": 12,
            ]
            guard let month = months[String(value[monthRange]).lowercased()] else {
                return nil
            }
            let currentYear = calendar.component(.year, from: now)
            var components = DateComponents(
                year: currentYear,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
            guard var candidate = calendar.date(from: components) else { return nil }
            if candidate < now {
                components.year = currentYear + 1
                guard let nextYear = calendar.date(from: components) else { return nil }
                candidate = nextYear
            }
            return candidate
        }

        let startOfToday = calendar.startOfDay(for: now)
        guard var candidate = calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: startOfToday
        ) else { return nil }
        if candidate <= now {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: candidate)
            else { return nil }
            candidate = tomorrow
        }
        return candidate
    }
}

private final class CodexQuotaClient {
    private let decoder = JSONDecoder()

    func fetch(completion: @escaping (Result<RateLimitsResult, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.fetchSynchronously())
        }
    }

    private func fetchSynchronously() -> Result<RateLimitsResult, Error> {
        guard let codexURL = locateCodex() else {
            return .failure(QuotaClientError.codexNotFound)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = codexURL
        process.arguments = ["app-server", "--stdio"]
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        do {
            try process.run()
        } catch {
            return .failure(QuotaClientError.launchFailed(error.localizedDescription))
        }

        func writeLines(_ lines: [String]) {
            let text = lines.joined(separator: "\n") + "\n"
            if let data = text.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
        }

        writeLines([
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"chatbird-quota-panel\",\"version\":\"\(panelVersion)\"},\"capabilities\":{\"experimentalApi\":true}}}",
        ])

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
            if process.isRunning {
                process.terminate()
            }
        }

        var buffer = Data()
        var didSendReadRequest = false
        var finalResponse: RPCResponse?

        readLoop: while process.isRunning {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] as? Int
                else { continue }

                if id == 1 && !didSendReadRequest {
                    didSendReadRequest = true
                    writeLines([
                        #"{"jsonrpc":"2.0","method":"initialized"}"#,
                        #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}"#,
                    ])
                    continue
                }

                if id == 2 {
                    finalResponse = try? decoder.decode(RPCResponse.self, from: line)
                    break readLoop
                }
            }
        }

        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        if let result = finalResponse?.result {
            return .success(result)
        }
        if let error = finalResponse?.error {
            return .failure(QuotaClientError.server(error.message))
        }

        return .failure(QuotaClientError.noResponse)
    }

    private func locateCodex() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_BIN"],
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".codex/packages/standalone/current/bin/codex").path,
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path,
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ].compactMap { $0 }

        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }).map(URL.init(fileURLWithPath:))
    }
}

private final class CodexResetCreditsClient {
    private struct Credentials {
        let accessToken: String
        let accountID: String?
    }

    func fetch(
        completion: @escaping (Result<CodexResetCreditsSnapshot, Error>) -> Void
    ) {
        let credentials: Credentials
        do {
            credentials = try loadCredentials()
        } catch {
            completion(.failure(error))
            return
        }
        guard let endpoint = URL(
            string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
        ) else {
            completion(.failure(CodexResetCreditsClientError.invalidEndpoint))
            return
        }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 4
        )
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(credentials.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("ChatBirdQuotaPanel", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(CodexResetCreditsClientError.requestFailed))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                completion(.failure(CodexResetCreditsClientError.requestFailed))
                return
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                completion(.failure(CodexResetCreditsClientError.unauthorized))
                return
            }
            guard (200...299).contains(response.statusCode), let data else {
                completion(.failure(CodexResetCreditsClientError.requestFailed))
                return
            }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .custom { decoder in
                    try Self.decodeISO8601Date(from: decoder)
                }
                let payload = try decoder.decode(
                    CodexResetCreditsResponse.self,
                    from: data
                )
                guard payload.availableCount >= 0 else {
                    throw CodexResetCreditsClientError.invalidResponse
                }
                completion(.success(CodexResetCreditsSnapshot(
                    credits: payload.credits,
                    reportedAvailableCount: payload.availableCount,
                    updatedAt: Date()
                )))
            } catch {
                completion(.failure(CodexResetCreditsClientError.invalidResponse))
            }
        }.resume()
    }

    private func loadCredentials() throws -> Credentials {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome: URL
        if let configuredHome = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredHome.isEmpty
        {
            codexHome = URL(fileURLWithPath: configuredHome, isDirectory: true)
        } else {
            codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        }
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = (
                  tokens["access_token"] as? String
                      ?? tokens["accessToken"] as? String
              ),
              !accessToken.isEmpty
        else {
            throw CodexResetCreditsClientError.credentialsUnavailable
        }
        let accountID = tokens["account_id"] as? String
            ?? tokens["accountId"] as? String
        return Credentials(accessToken: accessToken, accountID: accountID)
    }

    private static func decodeISO8601Date(from decoder: Decoder) throws -> Date {
        let value = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        if let date = fractional.date(from: value) ?? seconds.date(from: value) {
            return date
        }
        throw CodexResetCreditsClientError.invalidResponse
    }
}

private final class ClaudeQuotaClient {
    private static let timeout: TimeInterval = 24
    private static let maximumOutputBytes = 1_048_576
    fileprivate static let probeSessionID =
        UUID(uuidString: "7ea8629d-a05f-4dc2-a0e1-b9cf8e81e407")!

    func fetch(completion: @escaping (Result<ClaudeQuotaSnapshot, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.fetchSynchronously())
        }
    }

    private func fetchSynchronously() -> Result<ClaudeQuotaSnapshot, Error> {
        guard let claudeURL = locateClaude() else {
            return .failure(ClaudeQuotaError.claudeNotFound)
        }
        do {
            let rawText = try captureUsage(from: claudeURL)
            return .success(try ClaudeQuotaParser.parse(rawText))
        } catch let error as ClaudeQuotaError {
            return .failure(error)
        } catch {
            return .failure(ClaudeQuotaError.captureFailed)
        }
    }

    private func captureUsage(from executableURL: URL) throws -> String {
        let workingDirectory = try prepareProbeWorkingDirectory()
        cleanupProbeTranscripts()

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var windowSize = winsize(
            ws_row: 50,
            ws_col: 160,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(
            &primaryFD,
            &secondaryFD,
            nil,
            nil,
            &windowSize
        ) == 0 else {
            throw ClaudeQuotaError.launchFailed
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let secondaryHandle = FileHandle(
            fileDescriptor: secondaryFD,
            closeOnDealloc: true
        )
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--allowed-tools",
            "",
            "--session-id",
            Self.probeSessionID.uuidString.lowercased(),
        ]
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle
        process.currentDirectoryURL = workingDirectory
        process.environment = launchEnvironment(workingDirectory: workingDirectory)

        do {
            try process.run()
        } catch {
            Darwin.close(primaryFD)
            try? secondaryHandle.close()
            throw ClaudeQuotaError.launchFailed
        }
        try? secondaryHandle.close()

        defer {
            _ = Self.write(Data("/exit\r".utf8), to: primaryFD)
            if process.isRunning {
                process.terminate()
            }
            let gracefulDeadline = Date().addingTimeInterval(0.8)
            while process.isRunning, Date() < gracefulDeadline {
                usleep(50_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            Darwin.close(primaryFD)
            cleanupProbeTranscripts()
        }

        var output = Data()
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(Self.timeout)
        var lastEnterAt = Date.distantPast
        var lastPromptResponseAt = Date.distantPast
        var usageSent = false
        var baseQuotaObservedAt: Date?
        var successObservedAt: Date?
        var respondedPrompts = Set<String>()
        let promptResponses: [(String, String)] = [
            ("doyoutrustthefilesinthisfolder", "y\r"),
            ("quicksafetycheck", "\r"),
            ("yesitrustthisfolder", "\r"),
            ("readytocodehere", "\r"),
            ("pressentertocontinue", "\r"),
            ("showplanusagelimits", "\r"),
            ("showplan", "\r"),
        ]

        while Date() < deadline {
            let chunk = Self.readAvailable(from: primaryFD)
            if !chunk.isEmpty {
                guard output.count + chunk.count <= Self.maximumOutputBytes else {
                    throw ClaudeQuotaError.captureFailed
                }
                output.append(chunk)

                if chunk.range(of: Data([0x1B, 0x5B, 0x36, 0x6E])) != nil {
                    _ = Self.write(Data("\u{1b}[1;1R".utf8), to: primaryFD)
                }

                let scanData = output.suffix(196_608)
                if let scanText = String(data: scanData, encoding: .utf8) {
                    let clean = ClaudeQuotaParser.stripTerminalControlSequences(scanText)
                    let normalized = Self.normalizedForPromptSearch(clean)
                    for (needle, response) in promptResponses
                        where normalized.contains(needle)
                            && !respondedPrompts.contains(needle)
                    {
                        _ = Self.write(Data(response.utf8), to: primaryFD)
                        respondedPrompts.insert(needle)
                        lastPromptResponseAt = Date()
                    }

                    if usageSent,
                       let rowCount = (try? ClaudeQuotaParser.parse(clean))?.rows.count {
                        if rowCount >= 2, baseQuotaObservedAt == nil {
                            baseQuotaObservedAt = Date()
                        }
                        if rowCount >= 3, successObservedAt == nil {
                            successObservedAt = Date()
                        }
                    }
                }
            }

            let now = Date()
            let readyAfterLaunch = now.timeIntervalSince(startedAt) >= 2
            let readyAfterPrompt = now.timeIntervalSince(lastPromptResponseAt) >= 0.8
            if !usageSent, readyAfterLaunch, readyAfterPrompt {
                guard Self.write(Data("/usage\r".utf8), to: primaryFD) else {
                    throw ClaudeQuotaError.captureFailed
                }
                usageSent = true
                lastEnterAt = now
            } else if usageSent, now.timeIntervalSince(lastEnterAt) >= 0.8 {
                let navigationKey = baseQuotaObservedAt == nil
                    ? "\r"
                    : "\u{1b}[B"
                _ = Self.write(Data(navigationKey.utf8), to: primaryFD)
                lastEnterAt = now
            }

            if let successObservedAt,
               now.timeIntervalSince(successObservedAt) >= 1.2 {
                break
            }
            if successObservedAt == nil,
               let baseQuotaObservedAt,
               now.timeIntervalSince(baseQuotaObservedAt) >= 3 {
                break
            }
            if !process.isRunning { break }
            usleep(60_000)
        }

        guard !output.isEmpty,
              let text = String(data: output, encoding: .utf8)
        else {
            throw ClaudeQuotaError.captureFailed
        }
        return text
    }

    private func locateClaude() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            ProcessInfo.processInfo.environment["CLAUDE_BIN"],
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ].compactMap { $0 }
        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }).map(URL.init(fileURLWithPath:))
    }

    private func prepareProbeWorkingDirectory() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(
                "dev.chatbird.codex-quota-panel",
                isDirectory: true
            )
            .appendingPathComponent("ClaudeProbe", isDirectory: true)
        let settingsDirectory = directory
            .appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(
            at: settingsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let settingsURL = settingsDirectory
            .appendingPathComponent("settings.local.json")
        let data = try JSONSerialization.data(
            withJSONObject: ["disableDeepLinkRegistration": "disable"],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
        return directory
    }

    private func launchEnvironment(workingDirectory: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let standardPath = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = existingPath.isEmpty
            ? standardPath
            : "\(standardPath):\(existingPath)"
        environment["PWD"] = workingDirectory.path
        environment["TERM"] = "xterm-256color"
        environment["DISABLE_AUTOUPDATER"] = "1"
        for key in [
            "CLAUDECODE",
            "CLAUDE_CODE_ENTRYPOINT",
            "CODEX_COMPANION_SESSION_ID",
            "CODEX_COMPANION_TRANSCRIPT_PATH",
            "CLAUDE_PLUGIN_DATA",
        ] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    private func cleanupProbeTranscripts() {
        let fileName = "\(Self.probeSessionID.uuidString.lowercased()).jsonl"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(
                ".config/claude/projects",
                isDirectory: true
            ),
        ]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator
                where url.lastPathComponent == fileName
            {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func normalizedForPromptSearch(_ text: String) -> String {
        String(text.lowercased().filter {
            $0.isLetter || $0.isNumber || $0 == "%"
        })
    }

    private static func readAvailable(from fileDescriptor: Int32) -> Data {
        var result = Data()
        while true {
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.read(fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                result.append(contentsOf: bytes.prefix(count))
                continue
            }
            break
        }
        return result
    }

    @discardableResult
    private static func write(_ data: Data, to fileDescriptor: Int32) -> Bool {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let address = buffer.baseAddress else { return -1 }
                return Darwin.write(
                    fileDescriptor,
                    address.advanced(by: offset),
                    data.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(10_000)
                continue
            }
            return false
        }
        return true
    }
}

private final class QuotaPanelView: NSView {
    var rows: [QuotaRow] = [] { didSet { needsDisplay = true } }
    var providerRemainingPercents: [QuotaProvider: Int] = [:] {
        didSet { needsDisplay = true }
    }
    var codexResetCredits: CodexResetCreditsSnapshot? {
        didSet { needsDisplay = true }
    }
    var selectedQuotaProvider: QuotaProvider = .codex {
        didSet {
            guard selectedQuotaProvider != oldValue else { return }
            needsDisplay = true
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
    }
    var statusText = "正在读取额度…" { didSet { needsDisplay = true } }
    var errorText: String? { didSet { needsDisplay = true } }
    var isQuotaRefreshing = false {
        didSet {
            guard isQuotaRefreshing != oldValue else { return }
            refreshAnimationTimerState()
            needsDisplay = true
        }
    }
    var taskProgress = TaskProgressSnapshot.reading {
        didSet {
            clampTaskScrollOffset()
            if taskProgress != oldValue {
                needsDisplay = true
                syncTaskSymbolViews()
                updateTrackingAreas()
                window?.invalidateCursorRects(for: self)
                reconcileTaskHover()
            }
        }
    }
    var pointerSide: PointerSide = .left {
        didSet {
            guard pointerSide != oldValue else { return }
            needsDisplay = true
            syncTaskSymbolViews()
            window?.invalidateCursorRects(for: self)
        }
    }
    var pointerCenterX: CGFloat? {
        didSet {
            guard pointerCenterX != oldValue else { return }
            needsDisplay = true
        }
    }
    var onRequestHide: (() -> Void)?
    var onOpenTask: ((TaskProgressItem) -> Void)?
    var onRequestQuotaRefresh: (() -> Void)?
    var onSelectQuotaProvider: ((QuotaProvider) -> Void)?
    var onHoverRunningTask: ((TaskProgressItem?, NSRect?) -> Void)?
    private var interactiveTrackingAreas: [NSTrackingArea] = []
    private var isHideButtonHovered = false
    private var hoveredQuotaProvider: QuotaProvider?
    private var hoveredTaskIndex: Int?
    private var hoveredTaskKey: String?
    private var taskScrollOffset = 0
    private var taskSymbolViews: [NSImageView] = []
    private var taskAnimationsEnabled = false
    private var animationTimer: Timer?
    private var animationDegrees: CGFloat = 0
    private static let trackingKindKey = "tracking-kind"
    private static let trackingIndexKey = "tracking-index"
    private static let trackingProviderKey = "tracking-provider"

    override var isFlipped: Bool { true }

    deinit {
        animationTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncTaskSymbolViews()
    }

    func setRunningTaskBadgeAnimationsEnabled(_ enabled: Bool) {
        guard taskAnimationsEnabled != enabled else { return }
        taskAnimationsEnabled = enabled
        refreshAnimationTimerState()
    }

    func scrollTaskList(by rowDelta: Int) {
        guard taskProgress.isScrollable, rowDelta != 0 else { return }
        let maximumOffset = max(
            0,
            taskProgress.items.count - maximumVisibleTaskRows
        )
        let nextOffset = max(
            0,
            min(maximumOffset, taskScrollOffset + rowDelta)
        )
        guard nextOffset != taskScrollOffset else { return }
        taskScrollOffset = nextOffset
        updateTaskHover(index: nil)
        needsDisplay = true
        syncTaskSymbolViews()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard taskListRect(in: panelBodyRect()).contains(point),
              taskProgress.isScrollable
        else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        scrollTaskList(by: delta < 0 ? 1 : -1)
    }

    private func clampTaskScrollOffset() {
        guard taskProgress.isScrollable else {
            taskScrollOffset = 0
            return
        }
        taskScrollOffset = min(
            taskScrollOffset,
            max(0, taskProgress.items.count - maximumVisibleTaskRows)
        )
    }

    func updateTaskHover(index: Int?) {
        guard let index, displayedTaskItems.indices.contains(index) else {
            hoveredTaskIndex = nil
            hoveredTaskKey = nil
            onHoverRunningTask?(nil, nil)
            needsDisplay = true
            return
        }

        let item = displayedTaskItems[index]
        hoveredTaskIndex = index
        hoveredTaskKey = item.identityKey
        if item.kind == .running, let anchorRect = taskRowScreenRect(index: index) {
            onHoverRunningTask?(item, anchorRect)
        } else {
            onHoverRunningTask?(nil, nil)
        }
        needsDisplay = true
    }

    func refreshHoveredTaskAnchor() {
        reconcileTaskHover()
    }

    private func reconcileTaskHover() {
        guard let hoveredTaskKey else { return }
        guard let index = displayedTaskItems.firstIndex(where: {
            $0.identityKey == hoveredTaskKey
        }) else {
            updateTaskHover(index: nil)
            return
        }
        updateTaskHover(index: index)
    }

    private func taskRowScreenRect(index: Int) -> NSRect? {
        guard let window else { return nil }
        let rowRect = taskRowRect(index: index, in: panelBodyRect())
        return window.convertToScreen(convert(rowRect, to: nil))
    }

    private func refreshAnimationTimerState() {
        let hasVisibleRunningTask = displayedTaskItems.contains {
            $0.kind == .running
        }
        let shouldAnimate = isQuotaRefreshing
            || (taskAnimationsEnabled && hasVisibleRunningTask)
        if shouldAnimate {
            guard animationTimer == nil else { return }
            let timer = Timer(
                timeInterval: 1.0 / taskAnimationFramesPerSecond,
                repeats: true
            ) {
                [weak self] _ in
                guard let self else { return }
                self.animationDegrees = (
                    self.animationDegrees + taskAnimationDegreesPerTick
                )
                    .truncatingRemainder(dividingBy: 360)
                for (index, imageView) in self.taskSymbolViews.enumerated() {
                    let item = self.displayedTaskItems[index]
                    imageView.frameCenterRotation = item.kind == .running
                        ? self.animationDegrees
                        : 0
                }
                if self.isQuotaRefreshing {
                    self.needsDisplay = true
                }
            }
            animationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
            animationDegrees = 0
            for imageView in taskSymbolViews {
                imageView.frameCenterRotation = 0
            }
        }
    }

    private func syncTaskSymbolViews() {
        for imageView in taskSymbolViews {
            imageView.removeFromSuperview()
        }
        taskSymbolViews.removeAll(keepingCapacity: true)

        let taskItems = displayedTaskItems
        let bodyRect = panelBodyRect()
        for (index, item) in taskItems.enumerated() {
            let rowRect = taskRowRect(index: index, in: bodyRect)
            let imageView = NSImageView(frame: NSRect(
                x: rowRect.minX + 7,
                y: rowRect.minY + 5.5,
                width: 15,
                height: 15
            ))
            imageView.image = NSImage(
                systemSymbolName: taskProgressSymbolName(for: item.kind),
                accessibilityDescription: item.statusText
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            )
            imageView.contentTintColor = taskProgressColor(for: item.kind)
            imageView.imageAlignment = .alignCenter
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageFrameStyle = .none
            imageView.isEditable = false
            addSubview(imageView)
            taskSymbolViews.append(imageView)
        }
        refreshAnimationTimerState()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .high

        let bodyRect = panelBodyRect()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()

        let background = NSColor(calibratedRed: 0.035, green: 0.09, blue: 0.16, alpha: 0.96)
        let border = NSColor(calibratedRed: 0.47, green: 0.86, blue: 1.0, alpha: 0.24)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 17, yRadius: 17)
        if let gradient = NSGradient(
            starting: NSColor(calibratedRed: 0.055, green: 0.15, blue: 0.26, alpha: 0.96),
            ending: NSColor(calibratedRed: 0.025, green: 0.075, blue: 0.14, alpha: 0.98)
        ) {
            gradient.draw(in: bodyPath, angle: -90)
        } else {
            background.setFill()
            bodyPath.fill()
        }

        border.setStroke()
        bodyPath.lineWidth = 1
        bodyPath.stroke()

        let arrow = NSBezierPath()
        switch pointerSide {
        case .left:
            let centerY = bodyRect.midY
            arrow.move(to: NSPoint(x: bodyRect.minX + 1, y: centerY - 8))
            arrow.line(to: NSPoint(x: 1, y: centerY))
            arrow.line(to: NSPoint(x: bodyRect.minX + 1, y: centerY + 8))
        case .right:
            let centerY = bodyRect.midY
            arrow.move(to: NSPoint(x: bodyRect.maxX - 1, y: centerY - 8))
            arrow.line(to: NSPoint(x: bounds.maxX - 1, y: centerY))
            arrow.line(to: NSPoint(x: bodyRect.maxX - 1, y: centerY + 8))
        case .bottom:
            let requestedCenterX = pointerCenterX ?? bodyRect.midX
            let centerX = min(
                max(requestedCenterX, bodyRect.minX + 12),
                bodyRect.maxX - 12
            )
            arrow.move(to: NSPoint(x: centerX - 8, y: bodyRect.maxY - 1))
            arrow.line(to: NSPoint(x: centerX, y: bounds.maxY - 1))
            arrow.line(to: NSPoint(x: centerX + 8, y: bodyRect.maxY - 1))
        }
        arrow.close()
        background.setFill()
        arrow.fill()
        border.setStroke()
        arrow.lineWidth = 1
        arrow.stroke()

        NSShadow().set()

        drawQuotaProviderButtons(in: bodyRect)
        let hideButton = hideButtonRect(in: bodyRect)
        let hideButtonPath = NSBezierPath(roundedRect: hideButton, xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(isHideButtonHovered ? 0.20 : 0.11).setFill()
        hideButtonPath.fill()
        NSColor.white.withAlphaComponent(isHideButtonHovered ? 0.38 : 0.20).setStroke()
        hideButtonPath.lineWidth = 0.75
        hideButtonPath.stroke()
        drawText(
            "收起",
            in: NSRect(x: hideButton.minX, y: hideButton.minY + 2, width: hideButton.width, height: 15),
            font: .systemFont(ofSize: 9.5, weight: .medium),
            color: NSColor.white.withAlphaComponent(isHideButtonHovered ? 1.0 : 0.86),
            alignment: .center
        )

        let quotaRect = quotaColumnRect(in: bodyRect)
        let taskRect = taskListRect(in: bodyRect)
        let dividerX = taskRect.minX - 11
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: dividerX, y: 39))
        divider.line(to: NSPoint(x: dividerX, y: bodyRect.maxY - 13))
        NSColor.white.withAlphaComponent(0.13).setStroke()
        divider.lineWidth = 0.75
        divider.stroke()

        if let errorText {
            drawText(
                errorText,
                in: NSRect(x: quotaRect.minX, y: 82, width: quotaRect.width, height: 34),
                font: .systemFont(ofSize: 10.5, weight: .medium),
                color: NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.43, alpha: 1),
                alignment: .center
            )
        } else if rows.isEmpty {
            drawText(
                selectedQuotaProvider == .codex
                    ? "正在读取周额度…"
                    : "正在读取 Claude 额度…",
                in: NSRect(x: quotaRect.minX, y: 85, width: quotaRect.width, height: 20),
                font: .systemFont(ofSize: 11, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.68),
                alignment: .center
            )
        } else if selectedQuotaProvider == .claudeCode || rows.count > 1 {
            drawCompactQuotaRows(Array(rows.prefix(3)), x: quotaRect.minX, width: quotaRect.width)
        } else {
            for row in rows.prefix(1) {
                drawArcQuotaRow(row, x: quotaRect.minX, width: quotaRect.width)
            }
        }

        drawText(
            statusText,
            in: NSRect(
                x: quotaRect.minX,
                y: 188,
                width: quotaRect.width - 17,
                height: 14
            ),
            font: .systemFont(ofSize: 8.4, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.48),
            alignment: .center
        )
        drawRefreshIcon(in: quotaRefreshButtonRect(in: bodyRect))

        drawText(
            "Codex + Claude 任务",
            in: NSRect(x: taskRect.minX + 2, y: 42, width: taskRect.width - 4, height: 16),
            font: .systemFont(ofSize: 10.2, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.58)
        )
        let taskItems = displayedTaskItems
        for (index, item) in taskItems.enumerated() {
            drawTaskProgressItem(item, index: index, rect: taskRowRect(index: index, in: bodyRect))
        }
        drawTaskScrollbar(in: bodyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for trackingArea in interactiveTrackingAreas {
            removeTrackingArea(trackingArea)
        }
        interactiveTrackingAreas.removeAll(keepingCapacity: true)

        let hideTrackingArea = NSTrackingArea(
            rect: hideButtonRect(in: panelBodyRect()),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: [Self.trackingKindKey: "hide"]
        )
        addTrackingArea(hideTrackingArea)
        interactiveTrackingAreas.append(hideTrackingArea)

        for provider in QuotaProvider.allCases {
            let providerTrackingArea = NSTrackingArea(
                rect: quotaProviderButtonRect(for: provider, in: panelBodyRect()),
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: [
                    Self.trackingKindKey: "quota-provider",
                    Self.trackingProviderKey: provider.rawValue,
                ]
            )
            addTrackingArea(providerTrackingArea)
            interactiveTrackingAreas.append(providerTrackingArea)
        }

        let items = displayedTaskItems
        for (index, _) in items.enumerated() {
            let trackingArea = NSTrackingArea(
                rect: taskRowRect(index: index, in: panelBodyRect()),
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: [
                    Self.trackingKindKey: "task",
                    Self.trackingIndexKey: index,
                ]
            )
            addTrackingArea(trackingArea)
            interactiveTrackingAreas.append(trackingArea)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let kind = event.trackingArea?.userInfo?[Self.trackingKindKey] as? String
        else { return }
        if kind == "hide" {
            isHideButtonHovered = true
        } else if kind == "quota-provider" {
            hoveredQuotaProvider = (
                event.trackingArea?.userInfo?[Self.trackingProviderKey] as? String
            ).flatMap(QuotaProvider.init(rawValue:))
        } else if kind == "task" {
            updateTaskHover(
                index: event.trackingArea?.userInfo?[Self.trackingIndexKey] as? Int
            )
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard let kind = event.trackingArea?.userInfo?[Self.trackingKindKey] as? String
        else { return }
        if kind == "hide" {
            isHideButtonHovered = false
        } else if kind == "quota-provider" {
            if hoveredQuotaProvider?.rawValue
                == event.trackingArea?.userInfo?[Self.trackingProviderKey] as? String
            {
                hoveredQuotaProvider = nil
            }
        } else if kind == "task",
                  hoveredTaskIndex
                    == event.trackingArea?.userInfo?[Self.trackingIndexKey] as? Int
        {
            updateTaskHover(index: nil)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let bodyRect = panelBodyRect()
        if hideButtonRect(in: bodyRect).contains(point) {
            onRequestHide?()
            return
        }
        if quotaRefreshButtonRect(in: bodyRect).contains(point) {
            onRequestQuotaRefresh?()
            return
        }
        for provider in QuotaProvider.allCases
            where quotaProviderButtonRect(for: provider, in: bodyRect).contains(point)
        {
            selectedQuotaProvider = provider
            onSelectQuotaProvider?(provider)
            return
        }
        for (index, item) in displayedTaskItems.enumerated()
            where taskRowRect(index: index, in: bodyRect).contains(point)
        {
            if item.canOpen {
                onOpenTask?(item)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let bodyRect = panelBodyRect()
        addCursorRect(hideButtonRect(in: bodyRect), cursor: .pointingHand)
        for provider in QuotaProvider.allCases {
            addCursorRect(
                quotaProviderButtonRect(for: provider, in: bodyRect),
                cursor: .pointingHand
            )
        }
        addCursorRect(quotaRefreshButtonRect(in: bodyRect), cursor: .pointingHand)
        for (index, item) in displayedTaskItems.enumerated() where item.canOpen {
            addCursorRect(taskRowRect(index: index, in: bodyRect), cursor: .pointingHand)
        }
    }

    private var displayedTaskItems: [TaskProgressItem] {
        let items = taskProgress.items.isEmpty
            ? TaskProgressSnapshot.idle.items
            : taskProgress.items
        guard taskProgress.isScrollable else { return items }
        let end = min(
            items.count,
            taskScrollOffset + maximumVisibleTaskRows
        )
        guard taskScrollOffset < end else { return [] }
        return Array(items[taskScrollOffset..<end])
    }

    private func panelBodyRect() -> NSRect {
        let arrowWidth: CGFloat = 10
        switch pointerSide {
        case .left:
            return NSRect(x: arrowWidth, y: 3, width: bounds.width - arrowWidth, height: bounds.height - 6)
        case .right:
            return NSRect(x: 0, y: 3, width: bounds.width - arrowWidth, height: bounds.height - 6)
        case .bottom:
            return NSRect(x: 3, y: 3, width: bounds.width - 6, height: bounds.height - arrowWidth - 3)
        }
    }

    private func quotaColumnRect(in bodyRect: NSRect) -> NSRect {
        NSRect(
            x: bodyRect.minX + 14,
            y: 38,
            width: 140,
            height: bodyRect.height - 51
        )
    }

    private func taskListRect(in bodyRect: NSRect) -> NSRect {
        let x = bodyRect.minX + 178
        return NSRect(
            x: x,
            y: 38,
            width: bodyRect.maxX - 14 - x,
            height: bodyRect.height - 51
        )
    }

    private func taskRowRect(index: Int, in bodyRect: NSRect) -> NSRect {
        let listRect = taskListRect(in: bodyRect)
        return NSRect(
            x: listRect.minX,
            y: 61 + CGFloat(index) * taskProgressRowHeight,
            width: listRect.width,
            height: 26
        )
    }

    private func hideButtonRect(in bodyRect: NSRect) -> NSRect {
        NSRect(x: bodyRect.maxX - 48, y: 10, width: 38, height: 18)
    }

    private func quotaProviderButtonRect(
        for provider: QuotaProvider,
        in bodyRect: NSRect
    ) -> NSRect {
        switch provider {
        case .codex:
            return NSRect(x: bodyRect.minX + 11, y: 8, width: 94, height: 23)
        case .claudeCode:
            return NSRect(x: bodyRect.minX + 115, y: 8, width: 104, height: 23)
        }
    }

    private func quotaRefreshButtonRect(in bodyRect: NSRect) -> NSRect {
        let quotaRect = quotaColumnRect(in: bodyRect)
        return NSRect(
            x: quotaRect.maxX - 18,
            y: 185,
            width: 18,
            height: 18
        )
    }

    private func drawArcQuotaRow(_ row: QuotaRow, x: CGFloat, width: CGFloat) {
        let remaining = max(0, min(100, row.remainingPercent))
        let level = quotaLevel(for: remaining)
        drawText(
            row.name,
            in: NSRect(x: x, y: 47, width: width, height: 17),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.88),
            alignment: .center
        )
        drawQuotaArc(remaining: remaining, centerX: x + width / 2)
        drawText(
            "\(remaining)%",
            in: NSRect(x: x, y: 91, width: width, height: 35),
            font: .monospacedDigitSystemFont(ofSize: 29, weight: .bold),
            color: level == .exhausted
                ? quotaColor(for: .critical)
                : NSColor.white.withAlphaComponent(0.98),
            alignment: .center
        )

        if level == .exhausted {
            drawText(
                "额度已耗尽",
                in: NSRect(x: x, y: 124, width: width, height: 14),
                font: .systemFont(ofSize: 9.4, weight: .semibold),
                color: quotaColor(for: .critical),
                alignment: .center
            )
        }

        drawQuotaResetCard(in: NSRect(x: x + 1, y: 140, width: width - 2, height: 43))
    }

    private func drawQuotaResetCard(in rect: NSRect) {
        let presentation = codexResetCreditsPresentation(snapshot: codexResetCredits)
        let card = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor.black.withAlphaComponent(0.16).setFill()
        card.fill()
        NSColor(
            calibratedRed: 0.28,
            green: 0.80,
            blue: 1,
            alpha: 0.16
        ).setStroke()
        card.lineWidth = 0.8
        card.stroke()

        drawText(
            "限额重置额度",
            in: NSRect(
                x: rect.minX + 8,
                y: rect.minY + 4,
                width: presentation.hasAvailableCredits
                    ? rect.width - 68
                    : rect.width - 16,
                height: 13
            ),
            font: .systemFont(ofSize: 8.0, weight: .semibold),
            color: NSColor(
                calibratedRed: 0.37,
                green: 0.88,
                blue: 1,
                alpha: 0.92
            )
        )
        drawText(
            presentation.availableText,
            in: NSRect(
                x: presentation.hasAvailableCredits
                    ? rect.maxX - 67
                    : rect.minX + 8,
                y: presentation.hasAvailableCredits
                    ? rect.minY + 4
                    : rect.minY + 22,
                width: presentation.hasAvailableCredits
                    ? 59
                    : rect.width - 16,
                height: 14
            ),
            font: .systemFont(
                ofSize: presentation.hasAvailableCredits ? 8.2 : 7.2,
                weight: .semibold
            ),
            color: NSColor.white.withAlphaComponent(
                presentation.hasAvailableCredits ? 0.88 : 0.58
            ),
            alignment: presentation.hasAvailableCredits ? .right : .center
        )
        guard presentation.hasAvailableCredits else { return }
        if let clock = NSImage(
            systemSymbolName: "clock",
            accessibilityDescription: "过期时间"
        ) {
            clock.draw(
                in: NSRect(x: rect.minX + 8, y: rect.minY + 21, width: 9, height: 9),
                from: .zero,
                operation: .sourceOver,
                fraction: 0.62,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
        for (index, line) in presentation.expiryLines.prefix(2).enumerated() {
            drawText(
                line,
                in: NSRect(
                    x: rect.minX + 20,
                    y: rect.minY + 18 + CGFloat(index) * 11,
                    width: rect.width - 28,
                    height: 11
                ),
                font: .monospacedDigitSystemFont(ofSize: 7.1, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.58),
                alignment: .left
            )
        }
    }

    private func drawCompactQuotaRows(
        _ rows: [QuotaRow],
        x: CGFloat,
        width: CGFloat
    ) {
        let isDense = rows.count >= 3
        for (index, row) in rows.enumerated() {
            let remaining = max(0, min(100, row.remainingPercent))
            let level = quotaLevel(for: remaining)
            let top = CGFloat(
                (isDense ? 53 : 65) + index * (isDense ? 38 : 49)
            )
            let labelHeight: CGFloat = isDense ? 13 : 15
            let trackOffset: CGFloat = isDense ? 15 : 18
            let trackHeight: CGFloat = isDense ? 4 : 6
            let resetOffset: CGFloat = isDense ? 21 : 27
            let resetHeight: CGFloat = isDense ? 11 : 13
            drawText(
                row.name,
                in: NSRect(
                    x: x + 2,
                    y: top,
                    width: width - 50,
                    height: labelHeight
                ),
                font: .systemFont(
                    ofSize: isDense ? 9.4 : 10.2,
                    weight: .semibold
                ),
                color: NSColor.white.withAlphaComponent(0.84)
            )
            drawText(
                "\(remaining)%",
                in: NSRect(
                    x: x + width - 47,
                    y: top - 1,
                    width: 45,
                    height: isDense ? 14 : 16
                ),
                font: .monospacedDigitSystemFont(
                    ofSize: isDense ? 11.5 : 12.5,
                    weight: .bold
                ),
                color: level == .exhausted
                    ? quotaColor(for: .critical)
                    : NSColor.white.withAlphaComponent(0.97),
                alignment: .right
            )

            let trackRect = NSRect(
                x: x + 2,
                y: top + trackOffset,
                width: width - 4,
                height: trackHeight
            )
            let trackRadius = trackHeight / 2
            let track = NSBezierPath(
                roundedRect: trackRect,
                xRadius: trackRadius,
                yRadius: trackRadius
            )
            NSColor.white.withAlphaComponent(0.14).setFill()
            track.fill()
            if remaining > 0 {
                let fillRect = NSRect(
                    x: trackRect.minX,
                    y: trackRect.minY,
                    width: trackRect.width * CGFloat(remaining) / 100,
                    height: trackRect.height
                )
                let fill = NSBezierPath(
                    roundedRect: fillRect,
                    xRadius: trackRadius,
                    yRadius: trackRadius
                )
                quotaColor(for: level).setFill()
                fill.fill()
            }

            let resetText: String
            if let date = row.resetsAt {
                resetText = "\(quotaResetTimeDescription(date)) 重置"
            } else if row.resetDescription != nil {
                resetText = "重置时间以 Claude 为准"
            } else if level == .exhausted {
                resetText = "额度已耗尽"
            } else {
                resetText = "重置时间未知"
            }
            drawText(
                resetText,
                in: NSRect(
                    x: x + 2,
                    y: top + resetOffset,
                    width: width - 4,
                    height: resetHeight
                ),
                font: .systemFont(
                    ofSize: isDense ? 7.8 : 8.4,
                    weight: .regular
                ),
                color: level == .exhausted
                    ? quotaColor(for: .critical)
                    : NSColor.white.withAlphaComponent(0.58),
                alignment: .center
            )
        }
    }

    private func drawQuotaProviderButtons(in bodyRect: NSRect) {
        for provider in QuotaProvider.allCases {
            let rect = quotaProviderButtonRect(for: provider, in: bodyRect)
            let isSelected = provider == selectedQuotaProvider
            let isHovered = provider == hoveredQuotaProvider
            let background = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            NSColor.white.withAlphaComponent(
                isSelected ? 0.16 : (isHovered ? 0.11 : 0.045)
            ).setFill()
            background.fill()
            let accent = taskSourceColor(for: provider == .codex ? .codex : .claudeCode)
            (isSelected
                ? accent.withAlphaComponent(0.58)
                : NSColor.white.withAlphaComponent(isHovered ? 0.22 : 0.10)
            ).setStroke()
            background.lineWidth = isSelected ? 1 : 0.75
            background.stroke()

            let iconRect = NSRect(
                x: rect.minX + 7,
                y: rect.minY + 5,
                width: 13,
                height: 13
            )
            drawProviderIcon(
                provider,
                in: iconRect,
                fraction: isSelected ? 0.98 : 0.62
            )
            let remainingText = providerRemainingPercents[provider]
                .map { "\($0)%" } ?? "--"
            drawText(
                "\(remainingText) · \(provider.summaryWindowName)",
                in: NSRect(
                    x: iconRect.maxX + 5,
                    y: rect.minY + 3,
                    width: rect.width - 29,
                    height: 17
                ),
                font: .monospacedDigitSystemFont(
                    ofSize: 9.2,
                    weight: isSelected ? .semibold : .medium
                ),
                color: NSColor.white.withAlphaComponent(isSelected ? 0.96 : 0.64)
            )
        }
    }

    private func drawProviderIcon(
        _ provider: QuotaProvider,
        in rect: NSRect,
        fraction: CGFloat
    ) {
        let image = Bundle.main.url(
            forResource: provider.iconResourceName,
            withExtension: "svg"
        ).flatMap(NSImage.init(contentsOf:))
            ?? NSImage(
                systemSymbolName: provider.fallbackSymbolName,
                accessibilityDescription: provider.displayName
            )
        image?.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: fraction,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func drawQuotaArc(remaining: Int, centerX: CGFloat) {
        let center = NSPoint(x: centerX, y: 128)
        let radius: CGFloat = 49
        let segments = 72

        let track = NSBezierPath()
        for index in 0...segments {
            let angle = .pi + .pi * CGFloat(index) / CGFloat(segments)
            let point = NSPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 { track.move(to: point) } else { track.line(to: point) }
        }
        NSColor.white.withAlphaComponent(0.15).setStroke()
        track.lineWidth = 7
        track.lineCapStyle = .round
        track.stroke()

        let visibleSegments = max(0, min(segments, Int(
            (CGFloat(remaining) / 100 * CGFloat(segments)).rounded()
        )))
        guard visibleSegments > 0 else { return }
        let levelColor = quotaColor(for: quotaLevel(for: remaining))
        for index in 0..<visibleSegments {
            let startProgress = CGFloat(index) / CGFloat(segments)
            let endProgress = CGFloat(index + 1) / CGFloat(segments)
            let startAngle = .pi + .pi * startProgress
            let endAngle = .pi + .pi * endProgress
            let path = NSBezierPath()
            path.move(to: NSPoint(
                x: center.x + cos(startAngle) * radius,
                y: center.y + sin(startAngle) * radius
            ))
            path.line(to: NSPoint(
                x: center.x + cos(endAngle) * radius,
                y: center.y + sin(endAngle) * radius
            ))
            levelColor.setStroke()
            path.lineWidth = 7
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    private func quotaColor(for level: QuotaLevel) -> NSColor {
        switch level {
        case .healthy:
            return NSColor(
                calibratedRed: 0.27,
                green: 0.66,
                blue: 1.0,
                alpha: 1
            )
        case .warning:
            return NSColor(
                calibratedRed: 1.0,
                green: 0.73,
                blue: 0.20,
                alpha: 1
            )
        case .critical:
            return NSColor(
                calibratedRed: 1.0,
                green: 0.34,
                blue: 0.30,
                alpha: 1
            )
        case .exhausted:
            return NSColor.white.withAlphaComponent(0.26)
        }
    }

    private func drawRefreshIcon(in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: isQuotaRefreshing ? animationDegrees : 0)
        transform.translateX(by: -center.x, yBy: -center.y)
        transform.concat()
        drawText(
            "↻",
            in: NSRect(x: rect.minX, y: rect.minY - 1, width: rect.width, height: rect.height),
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.72),
            alignment: .center
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawTaskScrollbar(in bodyRect: NSRect) {
        guard taskProgress.isScrollable,
              taskProgress.items.count > maximumVisibleTaskRows
        else { return }

        let listRect = taskListRect(in: bodyRect)
        let trackRect = NSRect(
            x: listRect.maxX - 2,
            y: 57,
            width: 2,
            height: CGFloat(maximumVisibleTaskRows) * taskProgressRowHeight - 4
        )
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 1, yRadius: 1)
        NSColor.white.withAlphaComponent(0.10).setFill()
        trackPath.fill()

        let visibleRatio = CGFloat(maximumVisibleTaskRows)
            / CGFloat(taskProgress.items.count)
        let thumbHeight = max(18, trackRect.height * visibleRatio)
        let maximumOffset = taskProgress.items.count - maximumVisibleTaskRows
        let offsetRatio = CGFloat(taskScrollOffset) / CGFloat(maximumOffset)
        let thumbRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY + (trackRect.height - thumbHeight) * offsetRatio,
            width: trackRect.width,
            height: thumbHeight
        )
        let thumbPath = NSBezierPath(roundedRect: thumbRect, xRadius: 1, yRadius: 1)
        NSColor.white.withAlphaComponent(0.46).setFill()
        thumbPath.fill()
    }

    private func drawTaskProgressItem(
        _ item: TaskProgressItem,
        index: Int,
        rect: NSRect
    ) {
        let rowBackground = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        let isClickable = item.canOpen
        if hoveredTaskIndex == index, isClickable {
            NSColor.white.withAlphaComponent(0.12).setFill()
            rowBackground.fill()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            rowBackground.lineWidth = 0.75
            rowBackground.stroke()
        } else if index.isMultiple(of: 2) {
            NSColor.white.withAlphaComponent(0.025).setFill()
            rowBackground.fill()
        }

        let sourceStrip = NSBezierPath(
            roundedRect: NSRect(
                x: rect.minX + 2,
                y: rect.minY + 6,
                width: 2.5,
                height: rect.height - 12
            ),
            xRadius: 1.25,
            yRadius: 1.25
        )
        taskSourceColor(for: item.source).setFill()
        sourceStrip.fill()

        let color = taskProgressColor(for: item.kind)
        drawText(
            item.title,
            in: NSRect(
                x: rect.minX + 28,
                y: rect.minY + 6,
                width: rect.width - 89,
                height: 15
            ),
            font: .systemFont(ofSize: 9.8, weight: index == 0 ? .semibold : .medium),
            color: NSColor.white.withAlphaComponent(isClickable ? 0.92 : 0.72)
        )
        drawText(
            item.statusText,
            in: NSRect(
                x: rect.maxX - 58,
                y: rect.minY + 6,
                width: 51,
                height: 15
            ),
            font: .systemFont(ofSize: 9.0, weight: .semibold),
            color: color,
            alignment: .right
        )
    }

    private func taskSourceColor(for source: TaskSource) -> NSColor {
        switch source {
        case .codex:
            return NSColor(
                calibratedRed: 0.25,
                green: 0.70,
                blue: 1.0,
                alpha: 0.92
            )
        case .claudeCode:
            return NSColor(
                calibratedRed: 0.75,
                green: 0.48,
                blue: 1.0,
                alpha: 0.94
            )
        }
    }

    private func taskProgressColor(for kind: TaskProgressKind) -> NSColor {
        switch kind {
        case .reading:
            return NSColor.white.withAlphaComponent(0.56)
        case .running:
            return NSColor(calibratedRed: 0.22, green: 0.68, blue: 1.0, alpha: 1)
        case .waitingForInput:
            return NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.22, alpha: 1)
        case .completed:
            return NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.58, alpha: 1)
        case .failed:
            return NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.30, alpha: 1)
        case .idle:
            return NSColor.white.withAlphaComponent(0.56)
        }
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
                .shadow: Self.textShadow,
            ]
        )
    }

    private static let textShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(
            calibratedRed: 0.0,
            green: 0.20,
            blue: 0.23,
            alpha: 0.84
        )
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: 1)
        return shadow
    }()

}

private struct LocatedPet {
    let overlayRect: NSRect
    let visibleRect: NSRect
    let panelScale: CGFloat
    let screen: NSScreen
    let source: String
}

private func locatedPetGeometryDiffers(
    _ previous: LocatedPet?,
    from current: LocatedPet
) -> Bool {
    guard let previous else { return true }
    return rectDiffers(previous.visibleRect, from: current.visibleRect)
        || rectDiffers(previous.screen.visibleFrame, from: current.screen.visibleFrame)
        || abs(previous.panelScale - current.panelScale) > 0.01
}

private struct MascotEffectPetGeometry {
    let visibleRect: CGRect
    let scale: CGFloat
}

private func isMascotEffectWindow(
    name: String?,
    layer: Int,
    rect: CGRect
) -> Bool {
    let normalizedName = name?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    if !normalizedName.isEmpty {
        return normalizedName == "codex pet mascot effect"
    }
    guard layer == 2,
          rect.width >= 120,
          rect.width <= 600,
          rect.height >= 120,
          rect.height <= 600
    else { return false }
    let aspect = rect.width / rect.height
    return aspect >= 0.55 && aspect <= 1.45
}

private func isMascotAnchorWindow(
    name: String?,
    layer: Int,
    rect: CGRect
) -> Bool {
    let normalizedName = name?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    if !normalizedName.isEmpty,
       normalizedName != "codex",
       normalizedName != "chatgpt"
    {
        return false
    }
    return layer == 3
        && rect.width >= 160
        && rect.width <= 900
        && rect.height >= 80
        && rect.height <= 300
}

private func mascotEffectPetGeometry(
    effectRect: CGRect,
    anchorRect: CGRect
) -> MascotEffectPetGeometry? {
    guard effectRect.width >= 80,
          effectRect.height >= 80,
          anchorRect.width >= 160,
          anchorRect.height >= 80,
          abs(effectRect.midX - anchorRect.midX) <= max(effectRect.width, anchorRect.width) * 0.40,
          anchorRect.minY >= effectRect.minY - 4,
          anchorRect.minY <= effectRect.maxY
    else { return nil }

    let scale = normalizedPanelScale(effectRect.width / 356)
    guard scale.isFinite, scale >= minimumPanelScale, scale <= maximumPanelScale else {
        return nil
    }

    let width = canonicalPetSpriteSize.width * scale
    let height = canonicalPetSpriteSize.height * scale
    let visibleRect = CGRect(
        x: effectRect.midX - width / 2,
        y: anchorRect.minY,
        width: width,
        height: height
    )
    guard visibleRect.maxY <= effectRect.maxY + max(12, effectRect.height * 0.15) else {
        return nil
    }
    return MascotEffectPetGeometry(visibleRect: visibleRect, scale: scale)
}

private struct OverlayStateFileSignature: Equatable {
    let modificationDate: Date
    let byteCount: UInt64
    let fileNumber: UInt64?

    init?(attributes: [FileAttributeKey: Any]) {
        guard let modificationDate = attributes[.modificationDate] as? Date,
              let byteCount = (attributes[.size] as? NSNumber)?.uint64Value
        else { return nil }
        self.modificationDate = modificationDate
        self.byteCount = byteCount
        self.fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

private func overlayStateNeedsReload(
    previous: OverlayStateFileSignature?,
    current: OverlayStateFileSignature?
) -> Bool {
    guard let current else { return true }
    return current != previous
}

private final class PetWindowLocator {
    private struct NamedWindow {
        let id: CGWindowID
        let rect: CGRect
        let name: String
        let layer: Int
    }

    private struct MascotEffectWindowPair {
        let effect: NamedWindow
        let anchor: NamedWindow
    }

    private struct StoredMascotMetrics {
        let left: CGFloat
        let top: CGFloat
        let width: CGFloat
        let height: CGFloat
        let topPadding: CGFloat
        let source: String
    }

    private struct StoredOverlayLocation {
        let rect: CGRect
        let mascot: StoredMascotMetrics?
        let isPrimary: Bool
    }

    private struct MatchedMascotMetrics {
        let metrics: StoredMascotMetrics
        let referenceSize: CGSize
    }

    private var cachedWindowID: CGWindowID?
    private var cachedMascotMetrics: StoredMascotMetrics?
    private var cachedOverlaySize: CGSize?
    private var cachedVisualMetrics: StoredMascotMetrics?
    private var cachedVisualOverlaySize: CGSize?
    private var cachedVisualWindowID: CGWindowID?
    private var cachedMascotEffectWindowID: CGWindowID?
    private var cachedMascotAnchorWindowID: CGWindowID?
    private var lastVisualProbeAt: CFAbsoluteTime = 0
    private var lastOverlayStateReadAt: CFAbsoluteTime = 0
    private var lastOverlayStateFileSignature: OverlayStateFileSignature?
    private var storedOverlayLocations: [StoredOverlayLocation] = []
    private(set) var overlayOpen: Bool?

    func locate() -> LocatedPet? {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastOverlayStateReadAt >= overlayStateRefreshInterval {
            lastOverlayStateReadAt = now
            refreshStoredOverlayState()
        }

        if let effectID = cachedMascotEffectWindowID,
           let anchorID = cachedMascotAnchorWindowID,
           let effectWindow = windowInfo(including: effectID),
           let anchorWindow = windowInfo(including: anchorID),
           let effect = namedWindow(from: effectWindow),
           let anchor = namedWindow(from: anchorWindow),
           let location = makeMascotEffectLocation(effectRect: effect.rect, anchorRect: anchor.rect)
        {
            return location
        }
        cachedMascotEffectWindowID = nil
        cachedMascotAnchorWindowID = nil

        if let cachedWindowID,
           let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, cachedWindowID) as? [[String: Any]],
           let window = windows.first,
           let candidate = candidate(from: window),
           let location = makeLocation(from: candidate.rect, windowID: cachedWindowID)
        {
            return location
        }

        cachedWindowID = nil
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return storedOverlayLocation()
        }

        if let pair = mascotEffectWindowPair(in: windows),
           let location = makeMascotEffectLocation(
               effectRect: pair.effect.rect,
               anchorRect: pair.anchor.rect
           )
        {
            cachedMascotEffectWindowID = pair.effect.id
            cachedMascotAnchorWindowID = pair.anchor.id
            return location
        }

        let candidates: [(id: CGWindowID, rect: CGRect, score: Double)] = windows.compactMap { window in
            guard let number = window[kCGWindowNumber as String] as? NSNumber,
                  let candidate = candidate(from: window)
            else { return nil }
            return (number.uint32Value, candidate.rect, candidate.score)
        }

        guard let best = candidates.min(by: { $0.score < $1.score }) else {
            return storedOverlayLocation()
        }
        cachedWindowID = best.id
        return makeLocation(from: best.rect, windowID: best.id) ?? storedOverlayLocation()
    }

    func locateSavedState() -> LocatedPet? {
        refreshStoredOverlayState()
        return storedOverlayLocation()
    }

    private func windowInfo(including windowID: CGWindowID) -> [String: Any]? {
        (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?
            .first
    }

    private func namedWindow(from window: [String: Any]) -> NamedWindow? {
        guard let number = window[kCGWindowNumber as String] as? NSNumber,
              let ownerName = window[kCGWindowOwnerName as String] as? String,
              let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer >= 0,
              layer < 50,
              let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
              alpha > 0.05,
              let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: rawBounds)
        else { return nil }

        let normalizedOwner = ownerName.lowercased()
        guard normalizedOwner.contains("codex") || normalizedOwner.contains("chatgpt") else {
            return nil
        }
        return NamedWindow(
            id: number.uint32Value,
            rect: rect,
            name: window[kCGWindowName as String] as? String ?? "",
            layer: layer
        )
    }

    private func mascotEffectWindowPair(
        in windows: [[String: Any]]
    ) -> MascotEffectWindowPair? {
        let named = windows.compactMap(namedWindow(from:))
        let effects = named.filter {
            isMascotEffectWindow(name: $0.name, layer: $0.layer, rect: $0.rect)
        }
        let anchors = named.filter {
            isMascotAnchorWindow(name: $0.name, layer: $0.layer, rect: $0.rect)
        }

        return effects.flatMap { effect in
            anchors.compactMap { anchor -> (MascotEffectWindowPair, CGFloat)? in
                guard mascotEffectPetGeometry(
                    effectRect: effect.rect,
                    anchorRect: anchor.rect
                ) != nil else { return nil }
                return (
                    MascotEffectWindowPair(effect: effect, anchor: anchor),
                    hypot(effect.rect.midX - anchor.rect.midX, effect.rect.minY - anchor.rect.minY)
                )
            }
        }
        .min(by: { $0.1 < $1.1 })?
        .0
    }

    private func makeMascotEffectLocation(
        effectRect: CGRect,
        anchorRect: CGRect
    ) -> LocatedPet? {
        guard let geometry = mascotEffectPetGeometry(
            effectRect: effectRect,
            anchorRect: anchorRect
        ),
        let convertedEffect = convertToAppKit(effectRect),
        let convertedVisible = convertToAppKit(geometry.visibleRect),
        convertedEffect.1 == convertedVisible.1
        else { return nil }

        return LocatedPet(
            overlayRect: convertedEffect.0,
            visibleRect: convertedVisible.0,
            panelScale: geometry.scale,
            screen: convertedEffect.1,
            source: "window-mascot-effect"
        )
    }

    private func makeLocation(from quartzRect: CGRect, windowID: CGWindowID) -> LocatedPet? {
        guard let converted = convertToAppKit(quartzRect) else { return nil }
        let visualMetrics = currentVisualMetrics(
            windowID: windowID,
            overlayRect: quartzRect
        )

        if let matched = bestStoredMetrics(matching: quartzRect),
           let quartzMetrics = scaledMetrics(matched.metrics, from: matched.referenceSize, to: quartzRect.size),
           let appMetrics = scaledMetrics(quartzMetrics, from: quartzRect.size, to: converted.0.size)
        {
            cachedMascotMetrics = quartzMetrics
            cachedOverlaySize = quartzRect.size
            if let visualMetrics,
               let appVisualMetrics = scaledMetrics(
                   visualMetrics,
                   from: quartzRect.size,
                   to: converted.0.size
               )
            {
                return LocatedPet(
                    overlayRect: converted.0,
                    visibleRect: visibleRect(in: converted.0, metrics: appVisualMetrics),
                    panelScale: reconciledPanelScale(
                        anchorMetrics: quartzMetrics,
                        visualMetrics: visualMetrics
                    ),
                    screen: converted.1,
                    source: "window-visual-probe"
                )
            }
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: appMetrics),
                panelScale: panelScale(for: quartzMetrics),
                screen: converted.1,
                source: "window-\(quartzMetrics.source)"
            )
        }

        // Keep the last verified relative anchor during the few milliseconds
        // between the live window moving and Codex persisting its new bounds.
        if let cachedMascotMetrics,
           let cachedOverlaySize,
           let quartzMetrics = scaledMetrics(cachedMascotMetrics, from: cachedOverlaySize, to: quartzRect.size),
           let appMetrics = scaledMetrics(quartzMetrics, from: quartzRect.size, to: converted.0.size)
        {
            self.cachedMascotMetrics = quartzMetrics
            self.cachedOverlaySize = quartzRect.size
            if let visualMetrics,
               let appVisualMetrics = scaledMetrics(
                   visualMetrics,
                   from: quartzRect.size,
                   to: converted.0.size
               )
            {
                return LocatedPet(
                    overlayRect: converted.0,
                    visibleRect: visibleRect(in: converted.0, metrics: appVisualMetrics),
                    panelScale: reconciledPanelScale(
                        anchorMetrics: quartzMetrics,
                        visualMetrics: visualMetrics
                    ),
                    screen: converted.1,
                    source: "window-visual-probe-cached-anchor"
                )
            }
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: appMetrics),
                panelScale: panelScale(for: quartzMetrics),
                screen: converted.1,
                source: "window-cached-anchor"
            )
        }

        if let visualMetrics,
           let appVisualMetrics = scaledMetrics(
               visualMetrics,
               from: quartzRect.size,
               to: converted.0.size
           )
        {
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: appVisualMetrics),
                panelScale: visualPanelScale(for: visualMetrics),
                screen: converted.1,
                source: "window-visual-probe-only"
            )
        }

        return nil
    }

    private func refreshStoredOverlayState() {
        let stateURL: URL
        if let override = ProcessInfo.processInfo.environment["CHATBIRD_CODEX_STATE_FILE"],
           !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
        } else {
            stateURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/.codex-global-state.json")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path)
        let signature = attributes.flatMap(OverlayStateFileSignature.init(attributes:))
        if !overlayStateNeedsReload(
            previous: lastOverlayStateFileSignature,
            current: signature
        ) {
            return
        }
        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        lastOverlayStateFileSignature = signature

        let containers: [[String: Any]] = [
            root,
            root["electron-persisted-atom-state"] as? [String: Any],
            root["state"] as? [String: Any],
            root["settings"] as? [String: Any],
        ].compactMap { $0 }
        guard let container = containers.first(where: {
            $0["electron-avatar-overlay-bounds"] is [String: Any]
        }) else {
            storedOverlayLocations = []
            return
        }
        overlayOpen = container["electron-avatar-overlay-open"] as? Bool
        guard let overlay = container["electron-avatar-overlay-bounds"] as? [String: Any] else {
            storedOverlayLocations = []
            return
        }

        var locations: [StoredOverlayLocation] = []

        func addEntry(_ entry: [String: Any], isPrimary: Bool = false) {
            guard let x = entry["x"] as? NSNumber,
                  let y = entry["y"] as? NSNumber
            else { return }

            // Some Codex builds update x/y and placement immediately but omit
            // width, height and mascot while the overlay is on an external
            // display. Retain that current-display entry with the canonical
            // reference size; it will be scaled against the live Quartz window.
            let width = (entry["width"] as? NSNumber)?.doubleValue ?? 356
            let height = (entry["height"] as? NSNumber)?.doubleValue ?? 320
            guard width > 0, height > 0 else { return }

            let rect = CGRect(
                x: x.doubleValue,
                y: y.doubleValue,
                width: width,
                height: height
            )
            let mascot = mascotMetrics(from: entry, overlayRect: rect)
                ?? centeredFallbackMetrics(for: rect.size)
            locations.append(StoredOverlayLocation(rect: rect, mascot: mascot, isPrimary: isPrimary))
        }

        // The root entry is the most recently active display and is the best fallback.
        addEntry(overlay, isPrimary: true)
        if let byDisplayID = overlay["byDisplayId"] as? [String: Any] {
            for value in byDisplayID.values {
                if let entry = value as? [String: Any] {
                    addEntry(entry)
                }
            }
        }
        // Older Codex releases sometimes only retain a resolution-keyed copy.
        if let byResolution = overlay["byResolution"] as? [String: Any] {
            for value in byResolution.values {
                if let entry = value as? [String: Any] {
                    addEntry(entry)
                }
            }
        }

        storedOverlayLocations = locations
    }

    private func centeredFallbackMetrics(for overlaySize: CGSize) -> StoredMascotMetrics {
        let width = min(canonicalPetSpriteSize.width, overlaySize.width)
        let height = min(canonicalPetSpriteSize.height, overlaySize.height)
        return StoredMascotMetrics(
            left: max(0, (overlaySize.width - width) / 2),
            top: petSpriteTopPaddingInsideAnchor,
            width: width,
            height: height,
            topPadding: petSpriteTopPaddingInsideAnchor,
            source: "state-centered-fallback"
        )
    }

    private func mascotMetrics(
        from entry: [String: Any],
        overlayRect: CGRect
    ) -> StoredMascotMetrics? {
        if let mascot = entry["mascot"] as? [String: Any],
           let left = mascot["left"] as? NSNumber,
           let top = mascot["top"] as? NSNumber,
           let width = mascot["width"] as? NSNumber
        {
            let derivedHeight = width.doubleValue * 177 / 163
            let height = (mascot["height"] as? NSNumber)?.doubleValue ?? derivedHeight
            let mascotScale = normalizedPanelScale(
                CGFloat(width.doubleValue) / canonicalPetSpriteSize.width
            )
            let metrics = StoredMascotMetrics(
                left: CGFloat(left.doubleValue),
                top: CGFloat(top.doubleValue),
                width: CGFloat(width.doubleValue),
                height: CGFloat(height),
                topPadding: petSpriteTopPaddingInsideAnchor * mascotScale,
                source: "state-mascot"
            )
            if metricsAreValid(metrics, for: overlayRect.size) { return metrics }
        }

        // Compatibility with Codex builds that persisted only an absolute
        // anchor rectangle instead of relative `mascot` metrics.
        if let anchor = entry["anchor"] as? [String: Any],
           let x = anchor["x"] as? NSNumber,
           let y = anchor["y"] as? NSNumber,
           let width = anchor["width"] as? NSNumber,
           let height = anchor["height"] as? NSNumber
        {
            let anchorScale = normalizedPanelScale(
                CGFloat(width.doubleValue) / canonicalPetSpriteSize.width
            )
            let metrics = StoredMascotMetrics(
                left: CGFloat(x.doubleValue - overlayRect.minX),
                top: CGFloat(y.doubleValue - overlayRect.minY),
                width: CGFloat(width.doubleValue),
                height: CGFloat(height.doubleValue),
                topPadding: petSpriteTopPaddingInsideAnchor * anchorScale,
                source: "state-anchor"
            )
            if metricsAreValid(metrics, for: overlayRect.size) { return metrics }
        }
        return nil
    }

    private func metricsAreValid(_ metrics: StoredMascotMetrics, for size: CGSize) -> Bool {
        metrics.left.isFinite
            && metrics.top.isFinite
            && metrics.width.isFinite
            && metrics.height.isFinite
            && metrics.topPadding.isFinite
            && metrics.width >= 24
            && metrics.height >= 40
            && metrics.left >= -2
            && metrics.top >= -2
            && metrics.left + metrics.width <= size.width + 2
            && metrics.top + metrics.height <= size.height + 2
    }

    private func scaledMetrics(
        _ metrics: StoredMascotMetrics,
        from referenceSize: CGSize,
        to liveSize: CGSize
    ) -> StoredMascotMetrics? {
        guard referenceSize.width > 0,
              referenceSize.height > 0,
              liveSize.width > 0,
              liveSize.height > 0
        else { return nil }

        let scaleX = liveSize.width / referenceSize.width
        let scaleY = liveSize.height / referenceSize.height
        guard scaleX.isFinite,
              scaleY.isFinite,
              scaleX >= 0.20,
              scaleX <= 8,
              scaleY >= 0.20,
              scaleY <= 8,
              abs(log(scaleX / scaleY)) <= 0.30
        else { return nil }

        let scaled = StoredMascotMetrics(
            left: metrics.left * scaleX,
            top: metrics.top * scaleY,
            width: metrics.width * scaleX,
            height: metrics.height * scaleY,
            topPadding: metrics.topPadding * scaleY,
            source: metrics.source
        )
        return metricsAreValid(scaled, for: liveSize) ? scaled : nil
    }

    private func bestStoredMetrics(matching liveRect: CGRect) -> MatchedMascotMetrics? {
        let matches = storedOverlayLocations.compactMap { stored -> (MatchedMascotMetrics, Double)? in
            guard let metrics = stored.mascot else { return nil }
            let scaleX = liveRect.width / stored.rect.width
            let scaleY = liveRect.height / stored.rect.height
            guard scaleX.isFinite,
                  scaleY.isFinite,
                  scaleX >= 0.20,
                  scaleX <= 8,
                  scaleY >= 0.20,
                  scaleY <= 8,
                  abs(log(scaleX / scaleY)) <= 0.30,
                  scaledMetrics(metrics, from: stored.rect.size, to: liveRect.size) != nil
            else { return nil }

            // Electron display IDs are not guaranteed to equal CGDirectDisplayID.
            // Match the live Quartz rectangle to the nearest persisted rectangle
            // instead; this remains stable across Retina scale and monitor order.
            let centerDistance = hypot(stored.rect.midX - liveRect.midX, stored.rect.midY - liveRect.midY)
            let primaryBonus = stored.isPrimary ? -1.0 : 0.0
            let uniformityPenalty = abs(log(scaleX / scaleY)) * 2_000
            let scalePenalty = abs(log(scaleX)) * 4
            let score = Double(uniformityPenalty + scalePenalty + centerDistance * 0.08) + primaryBonus
            return (
                MatchedMascotMetrics(metrics: metrics, referenceSize: stored.rect.size),
                score
            )
        }
        return matches.min(by: { $0.1 < $1.1 })?.0
    }

    private func panelScale(for metrics: StoredMascotMetrics) -> CGFloat {
        let widthScale = metrics.width / canonicalPetSpriteSize.width
        let heightScale = metrics.height / canonicalPetSpriteSize.height
        guard widthScale.isFinite,
              heightScale.isFinite,
              widthScale > 0,
              heightScale > 0
        else { return 1 }

        // Use both axes so a temporarily rounded Electron window dimension
        // cannot make the panel pulse by one pixel while ChatBird is zooming.
        return normalizedPanelScale(sqrt(widthScale * heightScale))
    }

    private func visualScaleCandidates(
        for metrics: StoredMascotMetrics
    ) -> [(scale: CGFloat, distortion: CGFloat)] {
        guard metrics.width.isFinite,
              metrics.height.isFinite,
              metrics.width > 0,
              metrics.height > 0
        else { return [] }

        let candidates = petFrameVisiblePixelSizes.compactMap { frameSize
            -> (scale: CGFloat, distortion: CGFloat)? in
            let expectedWidth = frameSize.width
                * canonicalPetSpriteSize.width / petAtlasFrameSize.width
            let expectedHeight = frameSize.height
                * canonicalPetSpriteSize.height / petAtlasFrameSize.height
            let widthScale = metrics.width / expectedWidth
            let heightScale = metrics.height / expectedHeight
            guard widthScale.isFinite,
                  heightScale.isFinite,
                  widthScale > 0,
                  heightScale > 0
            else { return nil }
            return (
                normalizedPanelScale(sqrt(widthScale * heightScale)),
                abs(log(widthScale / heightScale))
            )
        }
        guard let bestDistortion = candidates.map(\.distortion).min(),
              bestDistortion <= 0.15
        else { return [] }
        // One-pixel antialiasing differences matter at very small scales. Keep
        // all atlas frames whose aspect fit is within 2% of the best match.
        return candidates.filter { $0.distortion <= bestDistortion + 0.02 }
    }

    private func visualPanelScale(for metrics: StoredMascotMetrics) -> CGFloat {
        let scales = visualScaleCandidates(for: metrics)
            .map(\.scale)
            .sorted()
        guard !scales.isEmpty else { return 1 }
        return scales[scales.count / 2]
    }

    private func reconciledPanelScale(
        anchorMetrics: StoredMascotMetrics,
        visualMetrics: StoredMascotMetrics
    ) -> CGFloat {
        let anchorScale = panelScale(for: anchorMetrics)
        let candidates = visualScaleCandidates(for: visualMetrics)
        guard let visualScale = candidates.min(by: {
            abs(log($0.scale / anchorScale)) < abs(log($1.scale / anchorScale))
        })?.scale else { return anchorScale }
        guard anchorScale > 0, visualScale > 0 else { return anchorScale }

        // Ordinary sprite rows vary slightly in visible height. Keep the
        // persisted anchor scale for that small variation, but trust the real
        // pixels when Codex shrinks the rendered pet inside a stale anchor.
        let relativeDifference = abs(log(visualScale / anchorScale))
        return relativeDifference > visualScaleTolerance ? visualScale : anchorScale
    }

    private func visibleRect(in overlayRect: NSRect, metrics: StoredMascotMetrics) -> NSRect {
        let visibleHeight = max(1, metrics.height - metrics.topPadding)
        return NSRect(
            x: overlayRect.minX + metrics.left,
            y: overlayRect.maxY - metrics.top - metrics.height,
            width: metrics.width,
            height: visibleHeight
        )
    }

    private func storedOverlayLocation() -> LocatedPet? {
        guard overlayOpen != false else { return nil }

        for stored in storedOverlayLocations.sorted(by: { $0.isPrimary && !$1.isPrimary }) {
            guard let mascot = stored.mascot else { continue }
            guard let converted = convertToAppKit(stored.rect) else { continue }
            cachedMascotMetrics = mascot
            cachedOverlaySize = stored.rect.size
            guard let appMetrics = scaledMetrics(mascot, from: stored.rect.size, to: converted.0.size) else {
                continue
            }
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: appMetrics),
                panelScale: panelScale(for: mascot),
                screen: converted.1,
                source: "saved-\(mascot.source)"
            )
        }
        return nil
    }

    private func currentVisualMetrics(
        windowID: CGWindowID,
        overlayRect: CGRect
    ) -> StoredMascotMetrics? {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastVisualProbeAt >= 0.12 {
            lastVisualProbeAt = now
            if let metrics = probeVisibleMascotMetrics(
                windowID: windowID,
                overlaySize: overlayRect.size
            ) {
                cachedVisualMetrics = metrics
                cachedVisualOverlaySize = overlayRect.size
                cachedVisualWindowID = windowID
                return metrics
            }
        }

        // A live pixel probe can occasionally fail while macOS is compositing
        // the transparent Electron overlay. The persisted mascot rectangle may
        // already be stale after a move, so keep the last verified pixels for
        // this exact window ID until a newer successful probe replaces them.
        guard cachedVisualWindowID == windowID,
              let cachedVisualMetrics,
              let cachedVisualOverlaySize
        else { return nil }
        return scaledMetrics(
            cachedVisualMetrics,
            from: cachedVisualOverlaySize,
            to: overlayRect.size
        )
    }

    private func probeVisibleMascotMetrics(
        windowID: CGWindowID,
        overlaySize: CGSize
    ) -> StoredMascotMetrics? {
        // Never trigger the macOS Screen Recording consent dialog just to
        // position this companion panel. Pixel probing is an optional accuracy
        // enhancement only when the user has already granted that permission.
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming]
        ), image.width >= 80, image.height >= 80,
        let data = image.dataProvider?.data,
        let bytes = CFDataGetBytePtr(data)
        else { return nil }

        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let bytesPerRow = image.bytesPerRow
        guard bytesPerPixel >= 4,
              overlaySize.width > 0,
              overlaySize.height > 0
        else { return nil }

        guard let selection = mascotPixelSelection(
            imageWidth: image.width,
            imageHeight: image.height,
            isVisible: { x, y in
                let offset = y * bytesPerRow + x * bytesPerPixel
                for channel in 0..<min(bytesPerPixel, 4)
                    where bytes[offset + channel] > 20
                {
                    return true
                }
                return false
            }
        ) else { return nil }

        let totalPixels = image.width * image.height
        guard selection.totalVisiblePixels >= 64,
              selection.totalVisiblePixels < Int(Double(totalPixels) * 0.80)
        else { return nil }

        // Window captures use backing pixels on Retina displays. Width is
        // always complete even when macOS clips transparent rows, so use it as
        // the uniform backing scale for both axes.
        let backingScale = CGFloat(image.width) / overlaySize.width
        guard backingScale.isFinite, backingScale > 0 else { return nil }
        let metrics = StoredMascotMetrics(
            left: selection.bounds.minX / backingScale,
            top: selection.bounds.minY / backingScale,
            width: selection.bounds.width / backingScale,
            height: selection.bounds.height / backingScale,
            topPadding: 0,
            source: "visual-pixels"
        )
        return metricsAreValid(metrics, for: overlaySize) ? metrics : nil
    }

    private func candidate(from window: [String: Any]) -> (rect: CGRect, score: Double)? {
        guard let ownerName = window[kCGWindowOwnerName as String] as? String,
              let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer >= 0,
              layer < 50,
              let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
              alpha > 0.05,
              let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rawBounds),
              bounds.width >= 160,
              bounds.width <= 900,
              bounds.height >= 120,
              bounds.height <= 1_000
        else { return nil }

        let normalizedOwner = ownerName.lowercased()
        guard normalizedOwner.contains("codex") || normalizedOwner.contains("chatgpt") else {
            return nil
        }

        let name = window[kCGWindowName as String] as? String ?? ""
        var score = Double(abs(bounds.width - 356) + abs(bounds.height - 320) * 0.35)
        score += Double(abs(layer - 3) * 50)
        if name == "ChatGPT" || name == "Codex" { score -= 80 }

        if let distance = storedOverlayLocations.map({ stored in
            hypot(bounds.midX - stored.rect.midX, bounds.midY - stored.rect.midY)
        }).min() {
            score += Double(distance * 0.08)
        }
        return (bounds, score)
    }

    private func convertToAppKit(_ quartzRect: CGRect) -> (NSRect, NSScreen)? {
        let center = CGPoint(x: quartzRect.midX, y: quartzRect.midY)

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard displayBounds.contains(center) || displayBounds.intersects(quartzRect) else {
                continue
            }

            guard displayBounds.width > 0, displayBounds.height > 0 else { continue }
            let scaleX = screen.frame.width / displayBounds.width
            let scaleY = screen.frame.height / displayBounds.height
            let x = screen.frame.minX + (quartzRect.minX - displayBounds.minX) * scaleX
            let y = screen.frame.maxY
                - (quartzRect.minY - displayBounds.minY) * scaleY
                - quartzRect.height * scaleY
            return (
                NSRect(
                    x: x,
                    y: y,
                    width: quartzRect.width * scaleX,
                    height: quartzRect.height * scaleY
                ),
                screen
            )
        }
        return nil
    }

    func scalingSelfTest() -> Bool {
        let baseSize = CGSize(width: 356, height: 320)
        let base = StoredMascotMetrics(
            left: 165,
            top: 8,
            width: 163,
            height: 177,
            topPadding: petSpriteTopPaddingInsideAnchor,
            source: "self-test"
        )
        let centeredFallback = centeredFallbackMetrics(for: baseSize)
        guard abs(centeredFallback.left + centeredFallback.width / 2 - baseSize.width / 2) <= 0.01,
              let scaledFallback = scaledMetrics(
                  centeredFallback,
                  from: baseSize,
                  to: CGSize(width: 408, height: 400)
              ),
              abs(scaledFallback.left + scaledFallback.width / 2 - 204) <= 0.01
        else { return false }
        for factor in [0.25, 0.5, 1.0, 1.25, 2.0, 3.0] as [CGFloat] {
            let liveSize = CGSize(width: baseSize.width * factor, height: baseSize.height * factor)
            guard let scaled = scaledMetrics(base, from: baseSize, to: liveSize),
                  abs(scaled.left - base.left * factor) <= 0.01,
                  abs(scaled.top - base.top * factor) <= 0.01,
                  abs(scaled.width - base.width * factor) <= 0.01,
                  abs(scaled.height - base.height * factor) <= 0.01,
                  abs(scaled.topPadding - base.topPadding * factor) <= 0.01,
                  abs(panelScale(for: scaled) - factor) <= 0.01
            else { return false }
        }
        guard scaledMetrics(
            base,
            from: baseSize,
            to: CGSize(width: baseSize.width * 2, height: baseSize.height * 0.5)
        ) == nil else { return false }

        // The Electron overlay may retain its old transparent bounds while
        // the pet itself is zoomed inside them. In that case the visible
        // pixels, not the stale anchor, must drive the whole panel scale.
        let visualCases: [(
            anchor: CGFloat,
            visual: CGFloat,
            expected: CGFloat,
            frame: NSSize
        )] = [
            (1.0, 0.4, 0.4, NSSize(width: 182, height: 196)),
            (1.0, 0.7, 0.7, NSSize(width: 182, height: 196)),
            (0.5, 0.5, 0.5, NSSize(width: 182, height: 196)),
            (1.0, 0.94, 1.0, NSSize(width: 182, height: 196)),
            (1.0, 1.0, 1.0, NSSize(width: 121, height: 190)),
            (1.0, 0.4, 0.4, NSSize(width: 121, height: 190)),
        ]
        for test in visualCases {
            let anchor = StoredMascotMetrics(
                left: 0,
                top: 0,
                width: canonicalPetSpriteSize.width * test.anchor,
                height: canonicalPetSpriteSize.height * test.anchor,
                topPadding: 0,
                source: "self-test-anchor"
            )
            let visual = StoredMascotMetrics(
                left: 0,
                top: 0,
                width: test.frame.width * canonicalPetSpriteSize.width
                    / petAtlasFrameSize.width * test.visual,
                height: test.frame.height * canonicalPetSpriteSize.height
                    / petAtlasFrameSize.height * test.visual,
                topPadding: 0,
                source: "self-test-visual"
            )
            guard abs(reconciledPanelScale(anchorMetrics: anchor, visualMetrics: visual)
                - test.expected) <= 0.01
            else { return false }
        }
        return true
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quotaClient = CodexQuotaClient()
    private let codexResetCreditsClient = CodexResetCreditsClient()
    private let claudeQuotaClient = ClaudeQuotaClient()
    private let quotaProviderPreference = QuotaProviderPreference()
    private let taskProgressReader = CombinedTaskProgressReader()
    private let locator = PetWindowLocator()
    private let healthWriter = RuntimeHealthWriter()
    private let petSelectionStore = ChatBirdPetSelectionStore()
    private let taskActivityPreviewController = TaskActivityPreviewController()
    private var claudePermissionPanelController: ClaudePermissionPanelController!
    private var claudePermissionHookServer: ClaudePermissionHookServer?
    private let quotaView = QuotaPanelView(frame: NSRect(origin: .zero, size: expandedPanelSize))
    private var panel: NSPanel!
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var taskProgressTimer: Timer?
    private var followTimer: Timer?
    private var globalMouseMonitor: Any?
    private var isRefreshing = false
    private var quotaRowsByProvider: [QuotaProvider: [QuotaRow]] = [:]
    private var codexResetCreditsSnapshot: CodexResetCreditsSnapshot?
    private var isRefreshingTaskProgress = false
    private var lastLocatedPet: LocatedPet?
    private var lastLocatedAt: CFAbsoluteTime = 0
    private var lastPetLocationPollAt: CFAbsoluteTime = 0
    private var lastPetMovementAt: CFAbsoluteTime = 0
    private var currentPanelScale: CGFloat = 1
    private var currentBasePanelSize = expandedPanelSize
    private var isPanelHiddenByUser = false
    private var ignoreVisiblePetDoubleClickUntil: CFAbsoluteTime = 0
    private var cachedCodexDesktopRunning = false
    private lazy var codexOverlayNotificationSynchronizer: CodexOverlayNotificationSynchronizer = {
        let paths = CodexOverlayNotificationPaths.current()
        return CodexOverlayNotificationSynchronizer(
            isCodexRunning: { [weak self] in
                self?.cachedCodexDesktopRunning ?? true
            },
            readSnapshot: {
                try paths.readSnapshot()
            },
            synchronize: { [weak self] in
                try paths.synchronize {
                    self?.cachedCodexDesktopRunning == false
                }
            },
            schedule: { delay, check in
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + delay,
                    execute: check
                )
            },
            log: { message in
                fputs("\(message)\n", stderr)
            }
        )
    }()
    private lazy var nativeActivityPillSuppressionMonitor: NativeActivityPillSuppressionMonitor = {
        let suppressor = NativeActivityPillSuppressor()
        let queue = DispatchQueue(
            label: "dev.chatbird.codex-quota-panel.native-activity",
            qos: .utility
        )
        return NativeActivityPillSuppressionMonitor(
            interval: taskProgressRefreshInterval,
            shouldSuppress: {
                suppressor.isTrusted
            },
            suppress: {
                if case .muted = suppressor.suppressActivityPillsIfNeeded() {
                    fputs("ChatBird 已自动静音新出现的 Codex 原生任务气泡。\n", stderr)
                }
            },
            schedule: { delay, check in
                queue.asyncAfter(
                    deadline: .now() + delay,
                    execute: check
                )
            }
        )
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = petSelectionStore.selectChatBird()
        quotaView.selectedQuotaProvider = quotaProviderPreference.selectedProvider
        makePanel()
        startClaudePermissionHook()
        makeStatusItem()
        startPetClickMonitor()
        startCodexDesktopMonitoring()
        updateStatusItem()
        healthWriter.write(status: "started", panelVisible: false, locationSource: nil, force: true)
        followPet()
        refreshQuota()
        refreshBackgroundQuotaSummary(
            for: quotaView.selectedQuotaProvider == .codex ? .claudeCode : .codex
        )
        refreshTaskProgress()
        nativeActivityPillSuppressionMonitor.start()

        followTimer = Timer.scheduledTimer(withTimeInterval: followInterval, repeats: true) { [weak self] _ in
            self?.followPet(forceLocationPoll: false)
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshQuota()
        }
        taskProgressTimer = Timer.scheduledTimer(
            withTimeInterval: taskProgressRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshTaskProgress()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        nativeActivityPillSuppressionMonitor.stop()
        codexOverlayNotificationSynchronizer.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        claudePermissionPanelController?.cancelAll()
        claudePermissionHookServer?.stop()
        taskActivityPreviewController.hide()
        quotaView.setRunningTaskBadgeAnimationsEnabled(false)
        refreshTimer?.invalidate()
        taskProgressTimer?.invalidate()
        followTimer?.invalidate()
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        healthWriter.write(status: "terminated", panelVisible: false, locationSource: nil, force: true)
    }

    private func makePanel() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: expandedPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = quotaView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        quotaView.onRequestHide = { [weak self] in
            self?.hidePanelByUser()
        }
        quotaView.onRequestQuotaRefresh = { [weak self] in
            self?.refreshQuota()
        }
        quotaView.onSelectQuotaProvider = { [weak self] provider in
            self?.selectQuotaProvider(provider)
        }
        quotaView.onHoverRunningTask = { [weak self] item, anchorRect in
            guard let self else { return }
            guard let item, let anchorRect else {
                self.taskActivityPreviewController.hide()
                return
            }
            self.taskActivityPreviewController.show(
                item: item,
                anchorRect: anchorRect
            )
        }
        quotaView.onOpenTask = { item in
            switch item.source {
            case .codex:
                guard let threadID = item.threadID,
                      let url = codexThreadURL(threadID: threadID)
                else { return }
                NSWorkspace.shared.open(url)
            case .claudeCode:
                openClaudeTerminal(
                    request: claudeTerminalOpenRequest(for: item)
                )
            }
        }
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "ChatBird"
        item.button?.toolTip = "ChatBird 额度面板"
        item.button?.target = self
        item.button?.action = #selector(handleStatusItem)
        item.isVisible = false
        statusItem = item
    }

    private func startCodexDesktopMonitoring() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(
            self,
            selector: #selector(codexDesktopApplicationStateDidChange(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(codexDesktopApplicationStateDidChange(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        cachedCodexDesktopRunning = isCodexDesktopRunning()
        codexOverlayNotificationSynchronizer.codexRunningStateDidChange(
            cachedCodexDesktopRunning
        )
    }

    @objc private func codexDesktopApplicationStateDidChange(
        _ notification: Notification
    ) {
        guard let application = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication else { return }
        let bundleIdentifier = application.bundleIdentifier
        let isCodexApplication =
            isKnownCodexDesktopBundleIdentifier(bundleIdentifier)
            || isCodexDesktopApplication(
                bundleIdentifier: bundleIdentifier,
                localizedName: application.localizedName,
                bundleURL: application.bundleURL,
                activationPolicy: application.activationPolicy
            )
        guard isCodexApplication else { return }

        let isRunning = notification.name
            == NSWorkspace.didLaunchApplicationNotification
            ? true
            : isCodexDesktopRunning()
        guard isRunning != cachedCodexDesktopRunning else { return }
        cachedCodexDesktopRunning = isRunning
        codexOverlayNotificationSynchronizer.codexRunningStateDidChange(
            isRunning
        )
        followPet(forceLocationPoll: true)
    }

    private func startClaudePermissionHook() {
        claudePermissionPanelController = ClaudePermissionPanelController(
            anchorWindowProvider: { [weak self] in self?.panel },
            openTerminal: { [weak self] prompt in
                self?.openTerminalForClaudePermission(prompt)
            }
        )

        let server = ClaudePermissionHookServer()
        server.onPrompt = { [weak self] prompt, completion in
            self?.claudePermissionPanelController.enqueue(
                prompt: prompt,
                completion: completion
            )
        }
        server.onRequestExpired = { [weak self] requestID in
            self?.claudePermissionPanelController.expire(requestID: requestID)
        }
        server.onStateChange = { state in
            switch state {
            case .ready:
                fputs("ChatBird Claude Hook 已监听 \(ClaudeHookConstants.url)\n", stderr)
            case .failed(let reason):
                fputs("ChatBird Claude Hook 启动失败：\(reason)\n", stderr)
            case .starting, .stopped:
                break
            }
        }
        do {
            try server.start()
            claudePermissionHookServer = server
        } catch {
            fputs("ChatBird Claude Hook 启动失败：\(error.localizedDescription)\n", stderr)
        }
    }

    private func openTerminalForClaudePermission(_ prompt: ClaudePermissionPrompt) {
        let request = claudeTerminalOpenRequest(
            for: prompt,
            taskItems: quotaView.taskProgress.items
        )
        if openClaudeTerminal(request: request) {
            return
        }
        // A generic activation can expose an unrelated tab. It is only safe
        // when the prompt contains no process, session, or directory target.
        guard allowsGenericTerminalFallback(for: request) else { return }
        let supportedBundleIdentifiers = [
            "io.appmakes.otty",
            "com.googlecode.iterm2",
            "com.apple.Terminal",
        ]
        let runningBundleIdentifiers = Set(
            supportedBundleIdentifiers.filter {
                NSRunningApplication.runningApplications(
                    withBundleIdentifier: $0
                ).isEmpty == false
            }
        )
        let hasActiveOttyTab: Bool
        if runningBundleIdentifiers.contains("io.appmakes.otty"),
           let data = runOttyCLI(arguments: ["--json", "tab", "list"])
        {
            hasActiveOttyTab = ottyHasActiveTab(from: data)
        } else {
            hasActiveOttyTab = false
        }
        if let bundleIdentifier = preferredClaudeTerminalBundleIdentifier(
            frontmostBundleIdentifier: NSWorkspace.shared
                .frontmostApplication?
                .bundleIdentifier,
            runningBundleIdentifiers: runningBundleIdentifiers,
            ottyHasActiveTab: hasActiveOttyTab
        ), activateRunningApplication(bundleIdentifier: bundleIdentifier) {
            return
        }
        let terminalURL = URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app",
            isDirectory: true
        )
        NSWorkspace.shared.openApplication(
            at: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func updateStatusItem() {
        statusItem?.button?.title = "ChatBird"
        statusItem?.button?.toolTip = "显示 ChatBird 额度面板"
        statusItem?.isVisible = isPanelHiddenByUser
    }

    @objc private func handleStatusItem() {
        showPanelFromStatusItem()
    }

    private func startPetClickMonitor() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            let clickCount = event.clickCount
            let clickLocation = NSEvent.mouseLocation
            DispatchQueue.main.async {
                self?.handlePetClick(at: clickLocation, clickCount: clickCount)
            }
        }
    }

    private func handlePetClick(at location: NSPoint, clickCount: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        guard cachedCodexDesktopRunning, let pet = locator.locate() else { return }
        let action = petPanelClickAction(
            clickCount: clickCount,
            clickLocation: location,
            petVisibleRect: pet.visibleRect,
            panelHidden: isPanelHiddenByUser,
            suppressVisibleDoubleClick: now < ignoreVisiblePetDoubleClickUntil
        )
        guard action != .none else { return }

        lastLocatedPet = pet
        lastLocatedAt = now
        if action == .show {
            ignoreVisiblePetDoubleClickUntil = now + NSEvent.doubleClickInterval
            showPanelFromStatusItem()
        } else {
            hidePanelByUser()
        }
    }

    private func hidePanelByUser() {
        isPanelHiddenByUser = true
        taskActivityPreviewController.hide()
        quotaView.setRunningTaskBadgeAnimationsEnabled(false)
        panel.orderOut(nil)
        updateStatusItem()
        healthWriter.write(
            status: "hidden-by-user",
            panelVisible: false,
            locationSource: nil,
            panelScale: currentPanelScale,
            panelSize: scaledPanelSize(currentBasePanelSize, scale: currentPanelScale),
            force: true
        )
    }

    @objc private func showPanelFromStatusItem() {
        isPanelHiddenByUser = false
        updateStatusItem()
        followPet()
    }

    private func followPet(forceLocationPoll: Bool = true) {
        let now = CFAbsoluteTimeGetCurrent()
        guard cachedCodexDesktopRunning else {
            lastLocatedPet = nil
            lastLocatedAt = 0
            lastPetLocationPollAt = 0
            lastPetMovementAt = 0
            taskActivityPreviewController.hide()
            quotaView.setRunningTaskBadgeAnimationsEnabled(false)
            panel.orderOut(nil)
            healthWriter.write(
                status: "waiting-for-codex",
                panelVisible: false,
                locationSource: nil,
                panelScale: currentPanelScale,
                panelSize: scaledPanelSize(currentBasePanelSize, scale: currentPanelScale)
            )
            return
        }

        guard shouldPollPetLocation(
            now: now,
            lastPollAt: lastPetLocationPollAt,
            lastMovementAt: lastPetMovementAt,
            force: forceLocationPoll
        ) else { return }
        lastPetLocationPollAt = now

        let pet: LocatedPet
        if let located = locator.locate() {
            if locatedPetGeometryDiffers(lastLocatedPet, from: located) {
                lastPetMovementAt = now
            }
            lastLocatedPet = located
            lastLocatedAt = now
            pet = located
        } else if let recent = lastLocatedPet, now - lastLocatedAt <= 0.50 {
            // Preserve the last exact attachment only across a brief window-list
            // transition. Never leave the panel at an unrelated screen corner.
            pet = recent
        } else {
            taskActivityPreviewController.hide()
            quotaView.setRunningTaskBadgeAnimationsEnabled(false)
            panel.orderOut(nil)
            healthWriter.write(
                status: "waiting-for-pet-location",
                panelVisible: false,
                locationSource: nil,
                panelScale: currentPanelScale,
                panelSize: scaledPanelSize(currentBasePanelSize, scale: currentPanelScale)
            )
            return
        }

        let basePanelSize = currentBasePanelSize
        currentPanelScale = presentedPanelScale(pet.panelScale)
        if isPanelHiddenByUser {
            taskActivityPreviewController.hide()
            quotaView.setRunningTaskBadgeAnimationsEnabled(false)
            panel.orderOut(nil)
            claudePermissionPanelController?.reposition()
            return
        }

        quotaView.setRunningTaskBadgeAnimationsEnabled(true)

        let currentPanelSize = scaledPanelSize(basePanelSize, scale: currentPanelScale)
        let placement = panelPlacement(
            petVisibleRect: pet.visibleRect,
            panelSize: currentPanelSize,
            panelScale: currentPanelScale,
            screenVisibleFrame: pet.screen.visibleFrame
        )

        quotaView.pointerSide = .bottom
        let targetPointerCenterX = placement.pointerCenterX / currentPanelScale
        if quotaView.pointerCenterX.map({
            abs($0 - targetPointerCenterX) > 0.1
        }) ?? true {
            quotaView.pointerCenterX = targetPointerCenterX
        }
        let targetOrigin = placement.origin
        let targetFrame = NSRect(origin: targetOrigin, size: currentPanelSize)
        let panelFrameChanged = rectDiffers(panel.frame, from: targetFrame)
        if panelFrameChanged {
            panel.setFrame(targetFrame, display: false)
        }
        // Keep the view's design coordinate system at the current task-list
        // height while its frame follows the scaled window. AppKit then scales
        // every visual and hit target together without changing proportions.
        let targetViewFrame = NSRect(origin: .zero, size: currentPanelSize)
        let targetViewBounds = NSRect(origin: .zero, size: basePanelSize)
        let contentGeometryChanged = rectDiffers(
            quotaView.frame,
            from: targetViewFrame
        ) || rectDiffers(
            quotaView.bounds,
            from: targetViewBounds
        )
        if contentGeometryChanged {
            quotaView.frame = targetViewFrame
            quotaView.bounds = targetViewBounds
            quotaView.needsDisplay = true
            panel.invalidateCursorRects(for: quotaView)
        }
        if panelFrameChanged || contentGeometryChanged {
            quotaView.refreshHoveredTaskAnchor()
            claudePermissionPanelController?.reposition()
        }
        if shouldPresentPanel(
            codexDesktopRunning: true,
            hiddenByUser: isPanelHiddenByUser,
            hasPetLocation: true
        ), !panel.isVisible {
            panel.orderFrontRegardless()
        }
        healthWriter.write(
            status: "following-pet",
            panelVisible: true,
            locationSource: pet.source,
            gap: placement.actualGap,
            centerError: placement.centerError,
            panelScale: currentPanelScale,
            panelSize: currentPanelSize
        )
    }

    private func refreshQuota() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let provider = quotaView.selectedQuotaProvider
        quotaView.isQuotaRefreshing = true
        if quotaView.rows.isEmpty {
            quotaView.errorText = nil
            quotaView.statusText = provider == .codex
                ? "正在读取 Codex 额度…"
                : "正在读取 Claude 额度…"
        } else {
            quotaView.statusText = "正在更新…"
        }

        switch provider {
        case .codex:
            refreshCodexResetCredits()
            quotaClient.fetch { [weak self] result in
                let rowsResult = result.map(Self.makeRows(from:))
                DispatchQueue.main.async {
                    self?.completeQuotaRefresh(
                        provider: provider,
                        result: rowsResult
                    )
                }
            }
        case .claudeCode:
            claudeQuotaClient.fetch { [weak self] result in
                let rowsResult = result.map(\.rows)
                DispatchQueue.main.async {
                    self?.completeQuotaRefresh(
                        provider: provider,
                        result: rowsResult
                    )
                }
            }
        }
    }

    private func completeQuotaRefresh(
        provider: QuotaProvider,
        result: Result<[QuotaRow], Error>
    ) {
        isRefreshing = false
        guard quotaView.selectedQuotaProvider == provider else {
            refreshQuota()
            return
        }
        quotaView.isQuotaRefreshing = false

        switch result {
        case .success(let rows):
            cacheQuotaRows(rows, for: provider)
            quotaView.rows = rows
            quotaView.errorText = rows.isEmpty
                ? (provider == .codex
                    ? "周额度暂不可用"
                    : "Claude 额度暂不可用")
                : nil
            quotaView.statusText = rows.isEmpty
                ? "没有可确认的额度数据"
                : "\(Self.timeFormatter.string(from: Date())) 更新 · 1分钟"
        case .failure(let error):
            let existingRows = quotaRowsByProvider[provider] ?? []
            quotaView.rows = existingRows
            let presentation = quotaFailurePresentation(
                for: error,
                hasExistingRows: !existingRows.isEmpty,
                provider: provider
            )
            quotaView.errorText = presentation.errorText
            quotaView.statusText = presentation.statusText
        }
    }

    private func selectQuotaProvider(_ provider: QuotaProvider) {
        quotaProviderPreference.selectedProvider = provider
        quotaView.selectedQuotaProvider = provider
        quotaView.rows = quotaRowsByProvider[provider] ?? []
        quotaView.codexResetCredits = codexResetCreditsSnapshot
        quotaView.errorText = nil
        quotaView.statusText = quotaView.rows.isEmpty
            ? "正在读取额度…"
            : "正在更新…"
        if !isRefreshing {
            refreshQuota()
        }
    }

    private func cacheQuotaRows(_ rows: [QuotaRow], for provider: QuotaProvider) {
        quotaRowsByProvider[provider] = rows
        guard let remaining = rows.first(where: {
            $0.name == provider.summaryRowName
        })?.remainingPercent else { return }
        var summaries = quotaView.providerRemainingPercents
        summaries[provider] = remaining
        quotaView.providerRemainingPercents = summaries
    }

    private func refreshCodexResetCredits() {
        codexResetCreditsClient.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    self.codexResetCreditsSnapshot = snapshot
                    self.quotaView.codexResetCredits = snapshot
                case .failure:
                    self.codexResetCreditsSnapshot = nil
                    self.quotaView.codexResetCredits = nil
                }
            }
        }
    }

    private func refreshBackgroundQuotaSummary(for provider: QuotaProvider) {
        switch provider {
        case .codex:
            refreshCodexResetCredits()
            quotaClient.fetch { [weak self] result in
                guard case .success(let response) = result else { return }
                let rows = Self.makeRows(from: response)
                DispatchQueue.main.async {
                    self?.cacheQuotaRows(rows, for: provider)
                }
            }
        case .claudeCode:
            claudeQuotaClient.fetch { [weak self] result in
                guard case .success(let snapshot) = result else { return }
                DispatchQueue.main.async {
                    self?.cacheQuotaRows(snapshot.rows, for: provider)
                }
            }
        }
    }

    private func refreshTaskProgress() {
        guard !isRefreshingTaskProgress else { return }
        isRefreshingTaskProgress = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = self.taskProgressReader.read()
            DispatchQueue.main.async {
                self.isRefreshingTaskProgress = false
                self.quotaView.taskProgress = snapshot
                let nextBaseSize = panelSizeForTaskRows(snapshot.rowCount)
                if nextBaseSize != self.currentBasePanelSize {
                    self.currentBasePanelSize = nextBaseSize
                    self.followPet()
                }
            }
        }
    }

    private static func makeRows(from response: RateLimitsResult) -> [QuotaRow] {
        let snapshot = codexSnapshot(from: response)

        if let window = weeklyRateLimitWindow(from: snapshot) {
            return [QuotaRow(
                name: "周额度",
                remainingPercent: max(0, 100 - window.usedPercent),
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )]
        }

        return []
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

}

private func printQuotaOnce() -> Never {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    CodexQuotaClient().fetch { result in
        switch result {
        case .success(let response):
            let snapshot = codexSnapshot(from: response)
            guard let window = weeklyRateLimitWindow(from: snapshot) else {
                fputs("Codex 暂未返回可确认的周额度\n", stderr)
                semaphore.signal()
                return
            }
            let remaining = max(0, 100 - window.usedPercent)
            print("codex-weekly: remaining=\(remaining)%")
            exitCode = 0
        case .failure(let error):
            fputs("\(error.localizedDescription)\n", stderr)
        }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 20) == .timedOut {
        fputs("读取额度超时\n", stderr)
    }
    exit(exitCode)
}

private func printClaudeQuotaOnce() -> Never {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    ClaudeQuotaClient().fetch { result in
        switch result {
        case .success(let snapshot):
            let details = snapshot.rows.map {
                "\($0.name)=\($0.remainingPercent)%"
            }.joined(separator: " ")
            print("claude-quota: \(details)")
            exitCode = snapshot.rows.count >= 2 ? 0 : 1
        case .failure(let error):
            fputs("\(error.localizedDescription)\n", stderr)
        }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 30) == .timedOut {
        fputs("读取 Claude 额度超时\n", stderr)
    }
    exit(exitCode)
}

private func printPanelConfiguration() -> Never {
    print(
        "panel-config: version=\(panelVersion) "
            + "edition=\(panelEdition) petID=\(chatBirdPetID) "
            + "codexWeeklyQuotaOnly=true "
            + "claudeQuotaPeriods=5h,weekly,fable "
            + "width=\(Int(expandedPanelSize.width)) "
            + "height=\(Int(expandedPanelSize.height))"
    )
    exit(0)
}

private func printTaskProgressOnce() -> Never {
    let snapshot = CombinedTaskProgressReader().read()
    let details = snapshot.items.enumerated().map { index, item in
        "\(index + 1):\(item.title)[\(item.source.rawValue):\(item.kind.rawValue)]"
    }.joined(separator: " | ")
    print("task-progress: count=\(snapshot.items.count) \(details)")
    exit(0)
}

private func printPanelPlacementOnce(savedStateOnly: Bool = false) -> Never {
    let locator = PetWindowLocator()
    let result = savedStateOnly ? locator.locateSavedState() : locator.locate()
    guard let location = result else {
        fputs("没有找到已打开的 ChatBird 窗口或已保存的位置\n", stderr)
        exit(1)
    }

    let livePanelScale = presentedPanelScale(location.panelScale)
    let livePanelSize = scaledPanelSize(expandedPanelSize, scale: livePanelScale)
    let placement = panelPlacement(
        petVisibleRect: location.visibleRect,
        panelSize: livePanelSize,
        panelScale: livePanelScale,
        screenVisibleFrame: location.screen.visibleFrame
    )
    print(
        "panel-location: source=\(location.source) "
            + "overlayX=\(Int(location.overlayRect.minX.rounded())) "
            + "overlayY=\(Int(location.overlayRect.minY.rounded())) "
            + "petCenterX=\(Int(location.visibleRect.midX.rounded())) "
            + "petTop=\(Int(location.visibleRect.maxY.rounded())) "
            + "panelX=\(Int(placement.origin.x)) "
            + "panelY=\(Int(placement.origin.y)) "
            + "panelScale=\(String(format: "%.3f", livePanelScale)) "
            + "panelWidth=\(String(format: "%.1f", livePanelSize.width)) "
            + "panelHeight=\(String(format: "%.1f", livePanelSize.height)) "
            + "gap=\(String(format: "%.1f", placement.actualGap)) "
            + "centerError=\(String(format: "%.1f", placement.centerError))"
    )
    exit(0)
}

private func prepareCodexOverlayNotifications() -> Never {
    guard let flagIndex = CommandLine.arguments.firstIndex(
        of: "--prepare-codex-overlay-notifications"
    ), CommandLine.arguments.count > flagIndex + 3
    else {
        fputs(
            "用法：--prepare-codex-overlay-notifications STATE SESSION_INDEX BACKUP\n",
            stderr
        )
        exit(2)
    }
    let stateURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let sessionIndexURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
    let backupURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 3])
    if isCodexDesktopRunning() {
        print(
            "codex-overlay-notifications: deferred until Codex exits "
                + "(ChatBird will synchronize automatically)"
        )
        exit(0)
    }
    do {
        try CodexOverlayNotificationState.prepareFiles(
            stateURL: stateURL,
            sessionIndexURL: sessionIndexURL,
            backupURL: backupURL,
            canWrite: {
                !isCodexDesktopRunning()
            }
        )
        print("codex-overlay-notifications: prepared")
        exit(0)
    } catch {
        fputs("准备 Codex 原生气泡状态失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private func restoreCodexOverlayNotifications() -> Never {
    guard let flagIndex = CommandLine.arguments.firstIndex(
        of: "--restore-codex-overlay-notifications"
    ), CommandLine.arguments.count > flagIndex + 2
    else {
        fputs("用法：--restore-codex-overlay-notifications STATE BACKUP\n", stderr)
        exit(2)
    }
    let stateURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let backupURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
    if isCodexDesktopRunning() {
        fputs(
            "恢复 Codex 原生气泡状态前请先完全退出 Codex；恢复文件已保留。\n",
            stderr
        )
        exit(1)
    }
    do {
        try CodexOverlayNotificationState.restoreFiles(
            stateURL: stateURL,
            backupURL: backupURL,
            canWrite: {
                !isCodexDesktopRunning()
            }
        )
        print("codex-overlay-notifications: restored")
        exit(0)
    } catch {
        fputs("恢复 Codex 原生气泡状态失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private func printAccessibilityStatus() -> Never {
    if AXIsProcessTrusted() {
        print("accessibility: authorized")
        exit(0)
    }
    fputs("accessibility: required for muting Codex activity pills\n", stderr)
    exit(1)
}

private func suppressNativeActivityOnce() -> Never {
    let result = NativeActivityPillSuppressor().suppressActivityPillsIfNeeded()
    switch result {
    case .muted:
        print("native-activity: muted")
        exit(0)
    case .permissionRequired:
        fputs("native-activity: accessibility permission required\n", stderr)
    case .codexNotRunning:
        fputs("native-activity: Codex is not running\n", stderr)
    case .buttonNotFound:
        fputs("native-activity: notification button not found\n", stderr)
    case .actionFailed:
        fputs("native-activity: Mute task action failed\n", stderr)
    }
    exit(1)
}

private func runPlacementSelfTest() -> Never {
    struct TestCase {
        let name: String
        let petRect: NSRect
        let panelSize: NSSize
        let panelScale: CGFloat
        let screenRect: NSRect
    }

    let cases = [
        TestCase(
            name: "built-in-display",
            petRect: NSRect(x: 1_110, y: 318, width: 163, height: 170),
            panelSize: expandedPanelSize,
            panelScale: 1,
            screenRect: NSRect(x: 0, y: 0, width: 1_512, height: 982)
        ),
        TestCase(
            name: "external-negative-origin",
            petRect: NSRect(x: -554, y: 500, width: 163, height: 170),
            panelSize: expandedPanelSize,
            panelScale: 1,
            screenRect: NSRect(x: -1_920, y: -98, width: 1_920, height: 1_080)
        ),
        TestCase(
            name: "scaled-pet",
            petRect: NSRect(x: 420, y: 260, width: 203.75, height: 212.5),
            panelSize: scaledPanelSize(expandedPanelSize, scale: 1.25),
            panelScale: 1.25,
            screenRect: NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        ),
        TestCase(
            name: "three-quarter-scale",
            petRect: NSRect(x: 280, y: 210, width: 122.25, height: 127.5),
            panelSize: scaledPanelSize(expandedPanelSize, scale: 0.75),
            panelScale: 0.75,
            screenRect: NSRect(x: 0, y: 0, width: 1_280, height: 720)
        ),
        TestCase(
            name: "left-screen-edge",
            petRect: NSRect(x: 8, y: 180, width: 81.5, height: 85),
            panelSize: scaledPanelSize(expandedPanelSize, scale: 0.5),
            panelScale: 0.5,
            screenRect: NSRect(x: 0, y: 0, width: 1_280, height: 720)
        ),
        TestCase(
            name: "right-screen-edge",
            petRect: NSRect(x: 1_050, y: 180, width: 163, height: 170),
            panelSize: scaledPanelSize(expandedPanelSize, scale: 2),
            panelScale: 2,
            screenRect: NSRect(x: 0, y: 0, width: 1_280, height: 720)
        ),
    ]

    for test in cases {
        let placement = panelPlacement(
            petVisibleRect: test.petRect,
            panelSize: test.panelSize,
            panelScale: test.panelScale,
            screenVisibleFrame: test.screenRect
        )
        guard abs(placement.actualGap - panelPetGap) <= 0.01 else {
            fputs("\(test.name): gap=\(placement.actualGap), expected=\(panelPetGap)\n", stderr)
            exit(1)
        }
        let baseSize = expandedPanelSize
        guard abs(test.panelSize.width - baseSize.width * test.panelScale) <= 0.01,
              abs(test.panelSize.height - baseSize.height * test.panelScale) <= 0.01
        else {
            fputs("\(test.name): panel did not scale proportionally\n", stderr)
            exit(1)
        }
        guard abs(placement.centerError) <= 0.01 else {
            fputs("\(test.name): centerError=\(placement.centerError)\n", stderr)
            exit(1)
        }
    }

    let pixelWidth = 360
    let pixelHeight = 320
    let expectedPetBounds = CGRect(x: 128, y: 118, width: 105, height: 188)
    let selectionWithActivityPill = mascotPixelSelection(
        imageWidth: pixelWidth,
        imageHeight: pixelHeight,
        isVisible: { x, y in
            let activityPill = (10...349).contains(x) && (20...76).contains(y)
            let petBody = (128...232).contains(x) && (118...278).contains(y)
            let leftFoot = (134...164).contains(x) && (282...305).contains(y)
            let rightFoot = (196...226).contains(x) && (282...305).contains(y)
            return activityPill || petBody || leftFoot || rightFoot
        }
    )
    guard selectionWithActivityPill?.bounds == expectedPetBounds else {
        fputs(
            "activity-pill segmentation: bounds="
                + "\(String(describing: selectionWithActivityPill?.bounds)), "
                + "expected=\(expectedPetBounds)\n",
            stderr
        )
        exit(1)
    }

    let selectionWithoutActivityPill = mascotPixelSelection(
        imageWidth: pixelWidth,
        imageHeight: pixelHeight,
        isVisible: { x, y in
            let petBody = (128...232).contains(x) && (118...278).contains(y)
            let leftFoot = (134...164).contains(x) && (282...305).contains(y)
            let rightFoot = (196...226).contains(x) && (282...305).contains(y)
            return petBody || leftFoot || rightFoot
        }
    )
    guard selectionWithoutActivityPill?.bounds == expectedPetBounds else {
        fputs(
            "pet-only segmentation: bounds="
                + "\(String(describing: selectionWithoutActivityPill?.bounds)), "
                + "expected=\(expectedPetBounds)\n",
            stderr
        )
        exit(1)
    }

    let detectedPetRect = NSRect(
        x: expectedPetBounds.minX,
        y: CGFloat(pixelHeight) - expectedPetBounds.maxY,
        width: expectedPetBounds.width,
        height: expectedPetBounds.height
    )
    let detectedPlacement = panelPlacement(
        petVisibleRect: detectedPetRect,
        panelSize: expandedPanelSize,
        panelScale: 1,
        screenVisibleFrame: NSRect(x: 0, y: 0, width: 1_512, height: 982)
    )
    guard abs(detectedPlacement.centerError) <= 0.01 else {
        fputs(
            "activity-pill placement centerError=\(detectedPlacement.centerError)\n",
            stderr
        )
        exit(1)
    }

    let liveEffectRect = CGRect(x: 1_615, y: 771, width: 243, height: 252)
    let liveAnchorRect = CGRect(x: 1_536, y: 836, width: 384, height: 122)
    guard isMascotEffectWindow(name: nil, layer: 2, rect: liveEffectRect),
    !isMascotEffectWindow(name: nil, layer: 3, rect: liveEffectRect),
    isMascotAnchorWindow(name: nil, layer: 3, rect: liveAnchorRect),
    !isMascotAnchorWindow(
        name: nil,
        layer: 3,
        rect: CGRect(x: 1_563, y: 770, width: 345, height: 54)
    ),
    let effectGeometry = mascotEffectPetGeometry(
        effectRect: liveEffectRect,
        anchorRect: liveAnchorRect
    ),
    abs(effectGeometry.visibleRect.midX - liveEffectRect.midX) <= 0.01,
    abs(effectGeometry.visibleRect.minY - liveAnchorRect.minY) <= 0.01,
    abs(effectGeometry.scale - 243 / 356) <= 0.01,
    mascotEffectPetGeometry(
        effectRect: liveEffectRect,
        anchorRect: liveAnchorRect.offsetBy(dx: 1_000, dy: 0)
    ) == nil
    else {
        fputs("mascot-effect geometry self-test failed\n", stderr)
        exit(1)
    }

    guard PetWindowLocator().scalingSelfTest() else {
        fputs("mascot scaling self-test failed\n", stderr)
        exit(1)
    }

    let stateSignature = OverlayStateFileSignature(
        attributes: [
            .modificationDate: Date(timeIntervalSince1970: 1_000),
            .size: NSNumber(value: 369_470),
            .systemFileNumber: NSNumber(value: 42),
        ]
    )
    let changedStateSignature = OverlayStateFileSignature(
        attributes: [
            .modificationDate: Date(timeIntervalSince1970: 1_001),
            .size: NSNumber(value: 369_470),
            .systemFileNumber: NSNumber(value: 42),
        ]
    )
    guard let stateSignature,
          let changedStateSignature,
          overlayStateNeedsReload(previous: nil, current: stateSignature),
          !overlayStateNeedsReload(previous: stateSignature, current: stateSignature),
          overlayStateNeedsReload(previous: stateSignature, current: changedStateSignature),
          overlayStateNeedsReload(previous: stateSignature, current: nil)
    else {
        fputs("overlay state cache self-test failed\n", stderr)
        exit(1)
    }

    let unchangedRect = NSRect(x: 10, y: 20, width: 388, height: 226)
    guard !rectDiffers(unchangedRect, from: unchangedRect),
          !rectDiffers(
              unchangedRect,
              from: unchangedRect.offsetBy(dx: 0.05, dy: -0.05)
          ),
          rectDiffers(
              unchangedRect,
              from: unchangedRect.offsetBy(dx: 0.2, dy: 0)
          ),
          rectDiffers(
              unchangedRect,
              from: NSRect(x: 10, y: 20, width: 389, height: 226)
          )
    else {
        fputs("panel geometry invalidation self-test failed\n", stderr)
        exit(1)
    }

    let petPollingCases: [(Bool, String)] = [
        (
            shouldPollPetLocation(
                now: 100,
                lastPollAt: 99.99,
                lastMovementAt: 99.99,
                force: true
            ),
            "forced"
        ),
        (
            shouldPollPetLocation(
                now: 100,
                lastPollAt: 0,
                lastMovementAt: 0,
                force: false
            ),
            "initial"
        ),
        (
            !shouldPollPetLocation(
                now: 100,
                lastPollAt: 99.98,
                lastMovementAt: 99.9,
                force: false
            ),
            "moving-too-soon"
        ),
        (
            shouldPollPetLocation(
                now: 100,
                lastPollAt: 99.96,
                lastMovementAt: 99.9,
                force: false
            ),
            "moving-due"
        ),
        (
            !shouldPollPetLocation(
                now: 100,
                lastPollAt: 99.85,
                lastMovementAt: 98,
                force: false
            ),
            "idle-too-soon"
        ),
        (
            shouldPollPetLocation(
                now: 100,
                lastPollAt: 99.79,
                lastMovementAt: 98,
                force: false
            ),
            "idle-due"
        ),
    ]
    guard petPollingCases.allSatisfy(\.0) else {
        let failed = petPollingCases.filter { !$0.0 }.map(\.1).joined(separator: ",")
        fputs("pet polling self-test failed: \(failed)\n", stderr)
        exit(1)
    }

    print("placement-self-test: 6/6 passed; activity-pill-segmentation=2/2; activity-pill-centerError=0.0; unnamed-pet-windows=4/4; mascot-effect-geometry=2/2; mascot-scaling=6/6; visual-scaling=6/6; panel-scaling=6/6; overlay-state-cache=4/4; geometry-invalidation=4/4; pet-polling=6/6; gap=14.0; centerError=0.0")
    exit(0)
}

private func runLifecycleSelfTest() -> Never {
    struct DesktopCase {
        let bundleIdentifier: String?
        let localizedName: String?
        let bundlePath: String?
        let activationPolicy: NSApplication.ActivationPolicy
        let expected: Bool
    }

    let desktopCases = [
        DesktopCase(
            bundleIdentifier: "com.openai.codex",
            localizedName: "ChatGPT",
            bundlePath: "/Applications/ChatGPT.app",
            activationPolicy: .regular,
            expected: true
        ),
        DesktopCase(
            bundleIdentifier: "com.openai.chatgpt",
            localizedName: "ChatGPT",
            bundlePath: "/Applications/ChatGPT.app",
            activationPolicy: .regular,
            expected: true
        ),
        DesktopCase(
            bundleIdentifier: nil,
            localizedName: "Codex",
            bundlePath: "/Applications/Codex.app",
            activationPolicy: .regular,
            expected: true
        ),
        DesktopCase(
            bundleIdentifier: "dev.chatbird.codex-quota-panel",
            localizedName: "ChatBird 额度面板",
            bundlePath: "/Applications/ChatBird 额度面板.app",
            activationPolicy: .accessory,
            expected: false
        ),
        DesktopCase(
            bundleIdentifier: nil,
            localizedName: "codex",
            bundlePath: "/usr/local/bin/codex",
            activationPolicy: .prohibited,
            expected: false
        ),
    ]

    for (index, test) in desktopCases.enumerated() {
        let actual = isCodexDesktopApplication(
            bundleIdentifier: test.bundleIdentifier,
            localizedName: test.localizedName,
            bundleURL: test.bundlePath.map { URL(fileURLWithPath: $0) },
            activationPolicy: test.activationPolicy
        )
        guard actual == test.expected else {
            fputs("desktop lifecycle case \(index + 1) failed\n", stderr)
            exit(1)
        }
    }

    let visibilityCases = [
        (true, false, true, true),
        (false, false, true, false),
        (true, true, true, false),
        (true, false, false, false),
    ]
    for (index, test) in visibilityCases.enumerated() {
        let actual = shouldPresentPanel(
            codexDesktopRunning: test.0,
            hiddenByUser: test.1,
            hasPetLocation: test.2
        )
        guard actual == test.3 else {
            fputs("panel visibility case \(index + 1) failed\n", stderr)
            exit(1)
        }
    }

    let petRect = NSRect(x: 400, y: 260, width: 163, height: 177)
    let petClickCases: [PetPanelClickAction] = [
        petPanelClickAction(
            clickCount: 1,
            clickLocation: NSPoint(x: petRect.midX, y: petRect.midY),
            petVisibleRect: petRect,
            panelHidden: true,
            suppressVisibleDoubleClick: false
        ),
        petPanelClickAction(
            clickCount: 2,
            clickLocation: NSPoint(x: petRect.midX, y: petRect.midY),
            petVisibleRect: petRect,
            panelHidden: false,
            suppressVisibleDoubleClick: false
        ),
        petPanelClickAction(
            clickCount: 2,
            clickLocation: NSPoint(x: petRect.midX, y: petRect.midY),
            petVisibleRect: petRect,
            panelHidden: false,
            suppressVisibleDoubleClick: true
        ),
        petPanelClickAction(
            clickCount: 1,
            clickLocation: NSPoint(x: petRect.midX, y: petRect.midY),
            petVisibleRect: petRect,
            panelHidden: false,
            suppressVisibleDoubleClick: false
        ),
        petPanelClickAction(
            clickCount: 1,
            clickLocation: NSPoint(x: petRect.maxX + 1, y: petRect.midY),
            petVisibleRect: petRect,
            panelHidden: true,
            suppressVisibleDoubleClick: false
        ),
    ]
    let expectedPetClickActions: [PetPanelClickAction] = [.show, .hide, .none, .none, .none]
    guard petClickCases == expectedPetClickActions else {
        fputs("pet click restore behavior failed\n", stderr)
        exit(1)
    }

    let activityWindowTitles: [(String?, Bool)] = [
        ("Codex Pet Composition Surface", true),
        ("  CODEX PET COMPOSITION SURFACE  ", true),
        ("Codex Pet Activity Stack Backing", false),
        ("ChatGPT", false),
        (nil, false),
    ]
    for (title, expected) in activityWindowTitles {
        guard isNativeActivityPillWindowTitle(title) == expected else {
            fputs(
                "activity-window title '\(title ?? "nil")' did not match expected=\(expected)\n",
                stderr
            )
            exit(1)
        }
    }

    guard isNativeActivityToggleWindowTitle("Codex Pet Voice Controls Backing"),
          !isNativeActivityToggleWindowTitle("Codex Pet Activity Stack Backing"),
          let togglePoint = nativeActivityToggleClickPoint(
              position: CGPoint(x: 1_768, y: 836),
              size: CGSize(width: 24, height: 24)
          ),
          abs(togglePoint.x - 1_780) <= 0.01,
          abs(togglePoint.y - 848) <= 0.01,
          nativeActivityToggleClickPoint(
              position: CGPoint(x: 1_700, y: 800),
              size: CGSize(width: 120, height: 120)
          ) == nil
    else {
        fputs("activity-toggle target validation failed\n", stderr)
        exit(1)
    }

    let accessibilityLabels = [
        ("Hide activity", true),
        ("隐藏活动", true),
        ("Show activity, 1 item", false),
        ("显示活动，1 项", false),
        ("Hide ChatBird", false),
    ]
    for (label, expected) in accessibilityLabels {
        guard isHideActivityAccessibilityLabel(label) == expected else {
            fputs(
                "accessibility-label '\(label)' did not match expected=\(expected)\n",
                stderr
            )
            exit(1)
        }
    }

    let muteTaskMenuTitles = [
        ("Mute task", true),
        ("  MUTE TASK  ", true),
        ("静音任务", true),
        ("Hide activity", false),
        ("Unmute task", false),
    ]
    guard muteTaskMenuTitles.allSatisfy({
        isMuteTaskMenuItemTitle($0.0) == $0.1
    }) else {
        fputs("mute-task menu title matching failed\n", stderr)
        exit(1)
    }

    guard nativeActivitySuppressionStrategy(notificationButtonCount: 0) == .wait,
          nativeActivitySuppressionStrategy(notificationButtonCount: 1) == .muteViaMenu
    else {
        fputs("native activity suppression strategy failed\n", stderr)
        exit(1)
    }

    print("lifecycle-self-test: desktop-app=5/5 visibility=4/4 pet-click-restore=5/5 activity-window=5/5 activity-toggle-target=6/6 accessibility-label=5/5 mute-menu=5/5 no-input-injection=2/2 hidden-window=orderOut status-item=restore")
    exit(0)
}

private func runNativeNotificationStateSelfTest() -> Never {
    var suppressionEligible = false
    var suppressionAttemptCount = 0
    var scheduledSuppressionChecks: [() -> Void] = []
    let suppressionMonitor = NativeActivityPillSuppressionMonitor(
        interval: 0,
        shouldSuppress: {
            suppressionEligible
        },
        suppress: {
            suppressionAttemptCount += 1
        },
        schedule: { _, check in
            scheduledSuppressionChecks.append(check)
        }
    )
    suppressionMonitor.start()
    guard scheduledSuppressionChecks.count == 1,
          suppressionAttemptCount == 0
    else {
        fputs("native activity monitor did not schedule its initial check\n", stderr)
        exit(1)
    }
    scheduledSuppressionChecks.removeFirst()()
    guard scheduledSuppressionChecks.count == 1,
          suppressionAttemptCount == 0
    else {
        fputs("native activity monitor ignored its eligibility gate\n", stderr)
        exit(1)
    }
    suppressionEligible = true
    scheduledSuppressionChecks.removeFirst()()
    guard scheduledSuppressionChecks.count == 1,
          suppressionAttemptCount == 1
    else {
        fputs("native activity monitor did not suppress an eligible pill\n", stderr)
        exit(1)
    }
    suppressionMonitor.start()
    guard scheduledSuppressionChecks.count == 1 else {
        fputs("native activity monitor start was not idempotent\n", stderr)
        exit(1)
    }
    suppressionMonitor.stop()
    scheduledSuppressionChecks.removeFirst()()
    guard scheduledSuppressionChecks.isEmpty,
          suppressionAttemptCount == 1
    else {
        fputs("native activity monitor did not cancel stale checks\n", stderr)
        exit(1)
    }

    let concurrentCheckStarted = DispatchSemaphore(value: 0)
    let allowConcurrentCheckToFinish = DispatchSemaphore(value: 0)
    let concurrentSuppressionFinished = DispatchSemaphore(value: 0)
    let concurrentStopStarted = DispatchSemaphore(value: 0)
    let concurrentStopFinished = DispatchSemaphore(value: 0)
    let concurrentQueue = DispatchQueue(
        label: "dev.chatbird.codex-quota-panel.native-activity-self-test"
    )
    let concurrentMonitor = NativeActivityPillSuppressionMonitor(
        interval: 60,
        shouldSuppress: {
            concurrentCheckStarted.signal()
            return allowConcurrentCheckToFinish.wait(
                timeout: .now() + 2
            ) == .success
        },
        suppress: {
            concurrentSuppressionFinished.signal()
        },
        schedule: { delay, check in
            concurrentQueue.asyncAfter(
                deadline: .now() + delay,
                execute: check
            )
        }
    )
    concurrentMonitor.start()
    guard concurrentCheckStarted.wait(timeout: .now() + 2) == .success else {
        fputs("native activity monitor concurrency check did not start\n", stderr)
        exit(1)
    }
    DispatchQueue.global(qos: .utility).async {
        concurrentStopStarted.signal()
        concurrentMonitor.stop()
        concurrentStopFinished.signal()
    }
    guard concurrentStopStarted.wait(timeout: .now() + 2) == .success,
          concurrentStopFinished.wait(timeout: .now() + 0.05) == .timedOut
    else {
        fputs("native activity monitor stop did not wait for an active check\n", stderr)
        exit(1)
    }
    allowConcurrentCheckToFinish.signal()
    guard concurrentSuppressionFinished.wait(timeout: .now() + 2) == .success,
          concurrentStopFinished.wait(timeout: .now() + 2) == .success
    else {
        fputs("native activity monitor did not finish a synchronized stop\n", stderr)
        exit(1)
    }

    let initialState: [String: Any] = [
        "electron-persisted-atom-state": [
            "first-awake-pet-notification-avatar-ids": ["codex"],
            "avatar-overlay-muted-notification-ids-v1": ["local:local:already-muted"],
            "thread-client-id-v1:local%3Aknown-thread": "client-1",
        ],
        "unrelated": ["keep": true],
    ]
    let initialData = try! JSONSerialization.data(withJSONObject: initialState)
    let sessionIndex = """
    {"id":"indexed-thread","title":"not persisted by ChatBird"}
    invalid-json-line
    {"id":"already-muted"}
    """.data(using: .utf8)
    let initialSnapshot = CodexOverlayNotificationDiskSnapshot(
        stateData: initialData,
        sessionIndexData: sessionIndex
    )

    var syncProbe = CodexOverlayNotificationSyncProbe(
        requiredStableSampleCount: 3
    )
    guard syncProbe.observe(codexRunning: true, snapshot: nil) == .waitForCodexExit,
          syncProbe.observe(codexRunning: false, snapshot: initialSnapshot)
            == .waitForStableFiles,
          syncProbe.observe(codexRunning: false, snapshot: initialSnapshot)
            == .waitForStableFiles,
          syncProbe.observe(codexRunning: false, snapshot: initialSnapshot)
            == .synchronize
    else {
        fputs("native notification stable-exit policy failed\n", stderr)
        exit(1)
    }

    let changedSnapshot = CodexOverlayNotificationDiskSnapshot(
        stateData: initialData,
        sessionIndexData: #"{"id":"late-thread"}"#.data(using: .utf8)
    )
    guard syncProbe.observe(codexRunning: false, snapshot: changedSnapshot)
            == .waitForStableFiles
    else {
        fputs("native notification changed disk did not reset stability\n", stderr)
        exit(1)
    }

    enum TestSyncError: Error {
        case transient
    }
    var codexRunning = true
    var snapshotReadCount = 0
    var synchronizationAttemptCount = 0
    var scheduledChecks: [() -> Void] = []
    let synchronizer = CodexOverlayNotificationSynchronizer(
        requiredStableSampleCount: 2,
        maximumAttempts: 5,
        checkInterval: 0,
        isCodexRunning: { codexRunning },
        readSnapshot: {
            snapshotReadCount += 1
            return initialSnapshot
        },
        synchronize: {
            synchronizationAttemptCount += 1
            if synchronizationAttemptCount == 1 {
                throw TestSyncError.transient
            }
            return true
        },
        schedule: { _, check in
            scheduledChecks.append(check)
        },
        log: { _ in }
    )
    synchronizer.codexRunningStateDidChange(true)
    guard scheduledChecks.isEmpty,
          snapshotReadCount == 0,
          synchronizationAttemptCount == 0
    else {
        fputs("native notification sync touched disk while Codex was running\n", stderr)
        exit(1)
    }

    codexRunning = false
    synchronizer.codexRunningStateDidChange(false)
    for _ in 0..<3 {
        guard !scheduledChecks.isEmpty else {
            fputs("native notification sync did not schedule a retry\n", stderr)
            exit(1)
        }
        let check = scheduledChecks.removeFirst()
        check()
    }
    guard snapshotReadCount == 3,
          synchronizationAttemptCount == 2,
          scheduledChecks.isEmpty
    else {
        fputs("native notification transient sync retry failed\n", stderr)
        exit(1)
    }

    codexRunning = true
    synchronizer.codexRunningStateDidChange(true)
    codexRunning = false
    synchronizer.codexRunningStateDidChange(false)
    guard scheduledChecks.count == 1 else {
        fputs("native notification sync did not restart after the next exit\n", stderr)
        exit(1)
    }
    let staleCheck = scheduledChecks.removeFirst()
    codexRunning = true
    synchronizer.codexRunningStateDidChange(true)
    staleCheck()
    guard snapshotReadCount == 3,
          synchronizationAttemptCount == 2
    else {
        fputs("native notification relaunch did not cancel stale sync work\n", stderr)
        exit(1)
    }
    synchronizer.stop()

    let fallbackPaths = CodexOverlayNotificationPaths.current(
        environment: [:],
        homeDirectory: URL(fileURLWithPath: "/tmp/chatbird-home", isDirectory: true)
    )
    let configuredHomePaths = CodexOverlayNotificationPaths.current(
        environment: ["CODEX_HOME": "/tmp/chatbird-codex-home"],
        homeDirectory: URL(fileURLWithPath: "/tmp/ignored-home", isDirectory: true)
    )
    let explicitStatePaths = CodexOverlayNotificationPaths.current(
        environment: [
            "CODEX_HOME": "/tmp/ignored-codex-home",
            "CHATBIRD_CODEX_STATE_FILE": "/tmp/chatbird-state/custom-state.json",
        ],
        homeDirectory: URL(fileURLWithPath: "/tmp/ignored-home", isDirectory: true)
    )
    guard fallbackPaths.stateURL.path
            == "/tmp/chatbird-home/.codex/.codex-global-state.json",
          fallbackPaths.sessionIndexURL.path
            == "/tmp/chatbird-home/.codex/session_index.jsonl",
          configuredHomePaths.backupURL.path
            == "/tmp/chatbird-codex-home/chatbird-native-notification-backup.json",
          explicitStatePaths.stateURL.path
            == "/tmp/chatbird-state/custom-state.json",
          explicitStatePaths.sessionIndexURL.path
            == "/tmp/chatbird-state/session_index.jsonl"
    else {
        fputs("native notification path resolution failed\n", stderr)
        exit(1)
    }

    let firstPreparation: PreparedCodexOverlayNotificationState
    do {
        firstPreparation = try CodexOverlayNotificationState.prepare(
            stateData: initialData,
            sessionIndexData: sessionIndex,
            existingBackupData: nil
        )
    } catch {
        fputs("native notification prepare failed: \(error)\n", stderr)
        exit(1)
    }

    func persistedAtoms(in data: Data) -> [String: Any] {
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return root["electron-persisted-atom-state"] as! [String: Any]
    }
    let preparedAtoms = persistedAtoms(in: firstPreparation.stateData)
    let firstAwake = preparedAtoms["first-awake-pet-notification-avatar-ids"] as? [String]
    let muted = preparedAtoms["avatar-overlay-muted-notification-ids-v1"] as? [String]
    guard firstAwake == ["codex", chatBirdPetAvatarID],
          muted == [
              "local:local:already-muted",
              "local:local:indexed-thread",
              "local:local:known-thread",
          ]
    else {
        fputs("native notification prepare did not add the expected values\n", stderr)
        exit(1)
    }

    let secondIndex = #"{"id":"later-thread"}"#.data(using: .utf8)
    let secondPreparation: PreparedCodexOverlayNotificationState
    do {
        secondPreparation = try CodexOverlayNotificationState.prepare(
            stateData: firstPreparation.stateData,
            sessionIndexData: secondIndex,
            existingBackupData: firstPreparation.backupData
        )
    } catch {
        fputs("native notification re-prepare failed: \(error)\n", stderr)
        exit(1)
    }

    var changedRoot = try! JSONSerialization.jsonObject(
        with: secondPreparation.stateData
    ) as! [String: Any]
    var changedAtoms = changedRoot["electron-persisted-atom-state"] as! [String: Any]
    changedAtoms["first-awake-pet-notification-avatar-ids"] = [
        "codex",
        chatBirdPetAvatarID,
        "custom:user-pet",
    ]
    changedAtoms["avatar-overlay-muted-notification-ids-v1"] = [
        "local:local:already-muted",
        "local:local:indexed-thread",
        "local:local:known-thread",
        "local:local:later-thread",
        "local:local:user-choice",
    ]
    changedRoot["electron-persisted-atom-state"] = changedAtoms
    let changedData = try! JSONSerialization.data(withJSONObject: changedRoot)

    let restoredData: Data
    do {
        restoredData = try CodexOverlayNotificationState.restore(
            stateData: changedData,
            backupData: secondPreparation.backupData
        )
    } catch {
        fputs("native notification restore failed: \(error)\n", stderr)
        exit(1)
    }
    let restoredAtoms = persistedAtoms(in: restoredData)
    guard restoredAtoms["first-awake-pet-notification-avatar-ids"] as? [String]
        == ["codex", "custom:user-pet"],
        restoredAtoms["avatar-overlay-muted-notification-ids-v1"] as? [String]
        == ["local:local:already-muted", "local:local:user-choice"]
    else {
        fputs("native notification restore did not preserve user values\n", stderr)
        exit(1)
    }

    let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("chatbird-native-state-\(UUID().uuidString)", isDirectory: true)
    let stateURL = testDirectory.appendingPathComponent("state.json")
    let sessionIndexURL = testDirectory.appendingPathComponent("session_index.jsonl")
    let backupURL = testDirectory.appendingPathComponent("backup.json")
    do {
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
        try initialData.write(to: stateURL)
        try sessionIndex?.write(to: sessionIndexURL)
        var relaunchCancellationObserved = false
        do {
            try CodexOverlayNotificationState.prepareFiles(
                stateURL: stateURL,
                sessionIndexURL: sessionIndexURL,
                backupURL: backupURL,
                canWrite: { false }
            )
        } catch {
            relaunchCancellationObserved = true
        }
        guard relaunchCancellationObserved,
              try Data(contentsOf: stateURL) == initialData,
              !FileManager.default.fileExists(atPath: backupURL.path)
        else {
            fputs("native notification relaunch guard wrote state\n", stderr)
            exit(1)
        }

        var writeBoundaryCancellationObserved = false
        var writeBoundaryCheckCount = 0
        do {
            try CodexOverlayNotificationState.prepareFiles(
                stateURL: stateURL,
                sessionIndexURL: sessionIndexURL,
                backupURL: backupURL,
                canWrite: {
                    writeBoundaryCheckCount += 1
                    return writeBoundaryCheckCount < 3
                }
            )
        } catch {
            writeBoundaryCancellationObserved = true
        }
        guard writeBoundaryCancellationObserved,
              writeBoundaryCheckCount == 3,
              try Data(contentsOf: stateURL) == initialData,
              !FileManager.default.fileExists(atPath: backupURL.path)
        else {
            fputs("native notification partial write did not roll back backup\n", stderr)
            exit(1)
        }

        let externallyChangedData = Data(#"{"external-write":true}"#.utf8)
        var snapshotChangeCancellationObserved = false
        var snapshotBoundaryCheckCount = 0
        do {
            try CodexOverlayNotificationState.prepareFiles(
                stateURL: stateURL,
                sessionIndexURL: sessionIndexURL,
                backupURL: backupURL,
                canWrite: {
                    snapshotBoundaryCheckCount += 1
                    if snapshotBoundaryCheckCount == 1 {
                        try! externallyChangedData.write(to: stateURL, options: .atomic)
                    }
                    return true
                }
            )
        } catch {
            snapshotChangeCancellationObserved = true
        }
        guard snapshotChangeCancellationObserved,
              try Data(contentsOf: stateURL) == externallyChangedData,
              !FileManager.default.fileExists(atPath: backupURL.path)
        else {
            fputs("native notification changed snapshot was overwritten\n", stderr)
            exit(1)
        }
        try initialData.write(to: stateURL, options: .atomic)

        let firstFilePreparationChanged = try CodexOverlayNotificationState.prepareFiles(
            stateURL: stateURL,
            sessionIndexURL: sessionIndexURL,
            backupURL: backupURL
        )
        let filePreparedAtoms = persistedAtoms(in: try Data(contentsOf: stateURL))
        guard firstFilePreparationChanged,
              FileManager.default.fileExists(atPath: backupURL.path),
              filePreparedAtoms["first-awake-pet-notification-avatar-ids"] as? [String]
                == ["codex", chatBirdPetAvatarID]
        else {
            fputs("native notification file prepare did not persist state\n", stderr)
            exit(1)
        }

        var exitRoot = initialState
        var exitAtoms = exitRoot["electron-persisted-atom-state"] as! [String: Any]
        exitAtoms["thread-client-id-v1:local%3Alate-state-thread"] = "client-late"
        exitRoot["electron-persisted-atom-state"] = exitAtoms
        try JSONSerialization.data(withJSONObject: exitRoot).write(to: stateURL)
        try """
        {"id":"indexed-thread"}
        {"id":"late-index-thread"}
        """.data(using: .utf8)!.write(to: sessionIndexURL)

        let exitRepairChanged = try CodexOverlayNotificationState.prepareFiles(
            stateURL: stateURL,
            sessionIndexURL: sessionIndexURL,
            backupURL: backupURL
        )
        let repairedStateData = try Data(contentsOf: stateURL)
        let repairedBackupData = try Data(contentsOf: backupURL)
        let repairedAtoms = persistedAtoms(in: repairedStateData)
        let repairedMuted = repairedAtoms[
            "avatar-overlay-muted-notification-ids-v1"
        ] as? [String]
        guard exitRepairChanged,
              repairedMuted?.contains("local:local:already-muted") == true,
              repairedMuted?.contains("local:local:indexed-thread") == true,
              repairedMuted?.contains("local:local:late-index-thread") == true,
              repairedMuted?.contains("local:local:late-state-thread") == true
        else {
            fputs("native notification exit repair missed late thread IDs\n", stderr)
            exit(1)
        }

        let idempotentPreparationChanged = try CodexOverlayNotificationState.prepareFiles(
            stateURL: stateURL,
            sessionIndexURL: sessionIndexURL,
            backupURL: backupURL
        )
        guard !idempotentPreparationChanged,
              try Data(contentsOf: stateURL) == repairedStateData,
              try Data(contentsOf: backupURL) == repairedBackupData
        else {
            fputs("native notification exit repair was not idempotent\n", stderr)
            exit(1)
        }

        var restoreCancellationObserved = false
        do {
            try CodexOverlayNotificationState.restoreFiles(
                stateURL: stateURL,
                backupURL: backupURL,
                canWrite: { false }
            )
        } catch {
            restoreCancellationObserved = true
        }
        guard restoreCancellationObserved,
              try Data(contentsOf: stateURL) == repairedStateData,
              try Data(contentsOf: backupURL) == repairedBackupData
        else {
            fputs("native notification active-Codex restore changed files\n", stderr)
            exit(1)
        }

        try CodexOverlayNotificationState.restoreFiles(
            stateURL: stateURL,
            backupURL: backupURL
        )
        let fileRestoredAtoms = persistedAtoms(in: try Data(contentsOf: stateURL))
        guard !FileManager.default.fileExists(atPath: backupURL.path),
              fileRestoredAtoms[
                "first-awake-pet-notification-avatar-ids"
              ] as? [String] == ["codex"],
              fileRestoredAtoms[
                "avatar-overlay-muted-notification-ids-v1"
              ] as? [String] == ["local:local:already-muted"]
        else {
            fputs("native notification file restore retained its backup\n", stderr)
            exit(1)
        }
    } catch {
        fputs("native notification file lifecycle failed: \(error)\n", stderr)
        try? FileManager.default.removeItem(at: testDirectory)
        exit(1)
    }
    try? FileManager.default.removeItem(at: testDirectory)

    print(
        "native-notification-state-self-test: "
            + "prepare=pass reinstall=pass restore=pass "
            + "file-lifecycle=pass user-values=preserved "
            + "live-monitor=pass "
            + "deferred-sync=pass stable-exit=pass relaunch-guard=pass retry=pass "
            + "snapshot-guard=pass transaction-rollback=pass restore-guard=pass "
            + "late-threads=pass idempotent=pass"
    )
    exit(0)
}

private func runTaskProgressSelfTest() -> Never {
    let now = Date()
    let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
    let completed = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
    let failed = #"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#
    let request = #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-1"}}"#
    let response = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call-1"}}"#
    let cases: [(String, [String], Date, TaskProgressKind)] = [
        ("running", [started], now, .running),
        ("waiting", [started, request], now, .waitingForInput),
        ("resumed", [started, request, response], now, .running),
        ("completed", [started, completed], now, .completed),
        ("failed", [started, failed], now, .failed),
        ("fresh-tail-fallback", [], now, .running),
        ("idle", [], now.addingTimeInterval(-31 * 60), .idle),
    ]

    for test in cases {
        let result = CodexTaskProgressReader.parse(
            lines: test.1,
            modificationDate: test.2,
            now: now
        )
        guard result.kind == test.3 else {
            fputs("task progress case \(test.0) failed: \(result.kind.rawValue)\n", stderr)
            exit(1)
        }
    }

    let timestampedStarted = #"{"timestamp":"2026-07-25T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#
    let publicCommentary = #"{"timestamp":"2026-07-25T10:02:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"**第一行会被后续输出覆盖。**\n第二行。\n第三行。\n第四行覆盖第一行。","agent_reasoning":"隐藏推理绝不显示"}}"#
    let continuedCommentary = #"{"timestamp":"2026-07-25T10:06:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"继续检查最终构建与安装状态。"}}"#
    let commandStarted = #"{"timestamp":"2026-07-25T10:03:00Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"tool-1","arguments":"secret command"}}"#
    let commandFinished = #"{"timestamp":"2026-07-25T10:04:00Z","type":"response_item","payload":{"type":"function_call_output","call_id":"tool-1","output":"secret output"}}"#
    let hiddenReasoning = #"{"timestamp":"2026-07-25T10:05:00Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"隐藏推理绝不显示"}]}}"#
    let toolActive = CodexTaskProgressReader.parse(
        lines: [timestampedStarted, publicCommentary, commandStarted, hiddenReasoning],
        modificationDate: now,
        now: now
    )
    let expectedToolUpdate = ISO8601DateFormatter().date(from: "2026-07-25T10:03:00Z")
    guard toolActive.items.first?.updatedAt == expectedToolUpdate,
          toolActive.items.first?.activityText
            == "正在运行命令 · 第一行会被后续输出覆盖。 第二行。 第三行。 第四行覆盖第一行。",
          toolActive.items.first?.activityText?.contains("secret") == false,
          toolActive.items.first?.activityText?.contains("隐藏推理") == false
    else {
        fputs("safe active tool summary or updatedAt failed\n", stderr)
        exit(1)
    }

    let commentaryFallback = CodexTaskProgressReader.parse(
        lines: [
            timestampedStarted,
            publicCommentary,
            commandStarted,
            commandFinished,
            hiddenReasoning,
        ],
        modificationDate: now,
        now: now
    )
    let expectedCommentaryUpdate = ISO8601DateFormatter().date(from: "2026-07-25T10:04:00Z")
    guard commentaryFallback.items.first?.updatedAt == expectedCommentaryUpdate,
          commentaryFallback.items.first?.activityText
            == "第一行会被后续输出覆盖。 第二行。 第三行。 第四行覆盖第一行。",
          commentaryFallback.items.first?.activityText?.contains("secret") == false,
          commentaryFallback.items.first?.activityText?.contains("隐藏推理") == false
    else {
        fputs("public commentary fallback or privacy filtering failed\n", stderr)
        exit(1)
    }

    let rollingCommentary = CodexTaskProgressReader.parse(
        lines: [
            timestampedStarted,
            publicCommentary,
            commandStarted,
            commandFinished,
            continuedCommentary,
            continuedCommentary,
            hiddenReasoning,
        ],
        modificationDate: now,
        now: now
    )
    let expectedAccumulatedUpdate = ISO8601DateFormatter().date(
        from: "2026-07-25T10:06:00Z"
    )
    guard rollingCommentary.items.first?.updatedAt == expectedAccumulatedUpdate,
          rollingCommentary.items.first?.activityText
            == "第一行会被后续输出覆盖。 第二行。 第三行。 第四行覆盖第一行。 继续检查最终构建与安装状态。"
    else {
        fputs("single-paragraph public commentary accumulation failed\n", stderr)
        exit(1)
    }

    let sortingBase = Date(timeIntervalSince1970: 10_000)
    let scrollingPresentation = TaskProgressSnapshot.displaying((0..<7).map { index in
        TaskProgressItem(
            title: "活跃任务 \(index + 1)",
            kind: index == 1 ? .waitingForInput : .running,
            startedAt: sortingBase.addingTimeInterval(Double(index)),
            updatedAt: sortingBase.addingTimeInterval(Double(index))
        )
    })
    guard scrollingPresentation.isScrollable,
          scrollingPresentation.items.count == 7,
          scrollingPresentation.items.first?.title == "活跃任务 7",
          scrollingPresentation.items.last?.title == "活跃任务 1",
          scrollingPresentation.items.contains(where: { $0.kind == .waitingForInput })
    else {
        fputs("active task scrolling selection or updatedAt sorting failed\n", stderr)
        exit(1)
    }

    let mixedPresentation = TaskProgressSnapshot.displaying([
        TaskProgressItem(
            title: "运行任务",
            kind: .running,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(60)
        ),
        TaskProgressItem(
            title: "等待输入",
            kind: .waitingForInput,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(50)
        ),
        TaskProgressItem(
            title: "完成 A",
            kind: .completed,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(40)
        ),
        TaskProgressItem(
            title: "失败 B",
            kind: .failed,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(30)
        ),
        TaskProgressItem(
            title: "完成 C",
            kind: .completed,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(20)
        ),
        TaskProgressItem(
            title: "完成 D",
            kind: .completed,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(10)
        ),
    ])
    guard !mixedPresentation.isScrollable,
          mixedPresentation.items.map(\.title)
            == ["运行任务", "等待输入", "完成 A", "失败 B", "完成 C"]
    else {
        fputs("active-first terminal backfill failed\n", stderr)
        exit(1)
    }

    let titledUserMessage = ##"{"type":"event_msg","payload":{"type":"user_message","message":"# Files mentioned by the user:\n/a.png\n## My request for Codex:\n列出具体任务名称"}}"##
    let titled = CodexTaskProgressReader.parse(
        lines: [titledUserMessage, started],
        modificationDate: now,
        now: now
    )
    guard titled.items.first?.title == "列出具体任务名称" else {
        fputs("task title extraction failed\n", stderr)
        exit(1)
    }

    let indexedThreadID = "12345678-1234-4abc-8def-1234567890ab"
    let indexedRollout = URL(fileURLWithPath:
        "/tmp/rollout-2026-07-16T16-52-47-\(indexedThreadID).jsonl"
    )
    let indexedTitle = CodexTaskProgressReader.resolvedTitle(
        for: indexedRollout,
        indexedTitles: [indexedThreadID: "正式任务名称"],
        fallback: "Codex 任务"
    )
    guard indexedTitle == "正式任务名称" else {
        fputs("task index title mapping failed\n", stderr)
        exit(1)
    }

    guard panelSizeForTaskRows(1) == NSSize(width: 388, height: 226),
          panelSizeForTaskRows(maximumVisibleTaskRows).width
            > panelSizeForTaskRows(maximumVisibleTaskRows).height,
          abs(presentedPanelScale(243 / 356) - 0.95) <= 0.001,
          abs(
              scaledPanelSize(
                  panelSizeForTaskRows(1),
                  scale: presentedPanelScale(243 / 356)
              ).width - 368.6
          ) <= 0.1,
          codexThreadURL(threadID: indexedThreadID)?.absoluteString
            == "codex://threads/\(indexedThreadID)",
          codexThreadURL(threadID: "not-a-thread") == nil
    else {
        fputs("wide-panel or Codex thread deep-link validation failed\n", stderr)
        exit(1)
    }

    _ = NSApplication.shared
    let clickView = QuotaPanelView(
        frame: NSRect(origin: .zero, size: panelSizeForTaskRows(1))
    )
    let clickWindow = NSWindow(
        contentRect: clickView.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    clickWindow.contentView = clickView
    clickView.pointerSide = .bottom
    clickView.taskProgress = TaskProgressSnapshot(items: [
        TaskProgressItem(
            title: "可点击任务",
            kind: .running,
            startedAt: now,
            threadID: indexedThreadID
        ),
    ])
    var openedThreadID: String?
    clickView.onOpenTask = { openedThreadID = $0.threadID }
    let rowPointInWindow = clickView.convert(NSPoint(x: 200, y: 66), to: nil)
    guard let clickEvent = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: rowPointInWindow,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: clickWindow.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ) else {
        fputs("task click event creation failed\n", stderr)
        exit(1)
    }
    clickView.mouseDown(with: clickEvent)
    guard openedThreadID == indexedThreadID else {
        fputs("task row click hit testing failed\n", stderr)
        exit(1)
    }

    let scrollingView = QuotaPanelView(
        frame: NSRect(origin: .zero, size: panelSizeForTaskRows(maximumVisibleTaskRows))
    )
    let scrollingWindow = NSWindow(
        contentRect: scrollingView.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    scrollingWindow.contentView = scrollingView
    scrollingView.pointerSide = .bottom
    scrollingView.taskProgress = TaskProgressSnapshot.displaying((0..<7).map { index in
        let threadID = String(
            format: "12345678-1234-4abc-8def-%012d",
            index + 1
        )
        return TaskProgressItem(
            title: "滚动任务 \(index + 1)",
            kind: index == 1 ? .waitingForInput : .running,
            startedAt: now,
            updatedAt: now.addingTimeInterval(Double(index)),
            threadID: threadID
        )
    })
    var scrolledThreadID: String?
    scrollingView.onOpenTask = { scrolledThreadID = $0.threadID }
    let scrollingPointInWindow = scrollingView.convert(NSPoint(x: 200, y: 66), to: nil)
    guard let scrolledClickEvent = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: scrollingPointInWindow,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: scrollingWindow.windowNumber,
        context: nil,
        eventNumber: 2,
        clickCount: 1,
        pressure: 1
    ) else {
        fputs("task scroll event creation failed\n", stderr)
        exit(1)
    }
    scrollingView.scrollTaskList(by: 1)
    scrollingView.mouseDown(with: scrolledClickEvent)
    guard scrolledThreadID == "12345678-1234-4abc-8def-000000000006" else {
        fputs("task scrolled click hit testing failed\n", stderr)
        exit(1)
    }

    let refreshView = QuotaPanelView(
        frame: NSRect(origin: .zero, size: panelSizeForTaskRows(1))
    )
    let refreshWindow = NSWindow(
        contentRect: refreshView.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    refreshWindow.contentView = refreshView
    refreshView.pointerSide = .bottom
    var refreshRequestCount = 0
    refreshView.onRequestQuotaRefresh = { refreshRequestCount += 1 }
    let refreshPointInWindow = refreshView.convert(NSPoint(x: 148, y: 194), to: nil)
    guard let refreshClickEvent = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: refreshPointInWindow,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: refreshWindow.windowNumber,
        context: nil,
        eventNumber: 3,
        clickCount: 1,
        pressure: 1
    ) else {
        fputs("quota refresh click event creation failed\n", stderr)
        exit(1)
    }
    refreshView.mouseDown(with: refreshClickEvent)
    guard refreshRequestCount == 1 else {
        fputs("quota refresh click hit testing failed\n", stderr)
        exit(1)
    }

    let runningPreviewItem = TaskProgressItem(
        title: "运行任务",
        kind: .running,
        startedAt: now,
        updatedAt: now,
        activityText: "正在编辑文件",
        threadID: indexedThreadID
    )
    let completedPreviewItem = TaskProgressItem(
        title: "完成任务",
        kind: .completed,
        startedAt: now,
        updatedAt: now,
        activityText: "这段内容不应显示",
        threadID: indexedThreadID
    )
    guard taskActivityPreviewPayload(for: runningPreviewItem)?.body == "正在编辑文件",
          taskActivityPreviewPayload(for: completedPreviewItem) == nil
    else {
        fputs("task activity preview eligibility failed\n", stderr)
        exit(1)
    }

    let tailWindowFont = NSFont.monospacedSystemFont(
        ofSize: 10,
        weight: .regular
    )
    let sevenCharacterWidth = ("abcdefg" as NSString).size(
        withAttributes: [.font: tailWindowFont]
    ).width + 0.5
    let firstTailWindow = taskActivityVisibleTailText(
        from: "abcdefghijklmnopqrstuv",
        width: sevenCharacterWidth,
        font: tailWindowFont,
        lineSpacing: 0,
        maximumLineCount: 3
    )
    let nextTailWindow = taskActivityVisibleTailText(
        from: "abcdefghijklmnopqrstuvw",
        width: sevenCharacterWidth,
        font: tailWindowFont,
        lineSpacing: 0,
        maximumLineCount: 3
    )
    guard firstTailWindow == "bcdefghijklmnopqrstuv",
          nextTailWindow == "cdefghijklmnopqrstuvw"
    else {
        fputs("task activity character tail window failed\n", stderr)
        exit(1)
    }

    let previewController = TaskActivityPreviewController()
    previewController.show(
        item: runningPreviewItem,
        anchorRect: NSRect(x: 100, y: 100, width: 180, height: 26),
        visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
    )
    let compactPreviewHeight = previewController.currentPanelHeight
    guard previewController.isVisible,
          previewController.currentBody == "正在编辑文件"
    else {
        fputs("task activity preview presentation failed\n", stderr)
        exit(1)
    }
    previewController.update(item: TaskProgressItem(
        title: "运行任务",
        kind: .running,
        startedAt: now,
        updatedAt: now.addingTimeInterval(2),
        activityText: "正在运行命令",
        threadID: indexedThreadID
    ))
    guard previewController.isVisible,
          previewController.currentBody == "正在运行命令"
    else {
        fputs("task activity preview live update failed\n", stderr)
        exit(1)
    }
    previewController.update(item: TaskProgressItem(
        title: "运行任务",
        kind: .running,
        startedAt: now,
        updatedAt: now.addingTimeInterval(3),
        activityText: "第一句。 第二句。 第三句。 第四句。 继续检查最终状态。",
        threadID: indexedThreadID
    ))
    guard previewController.isVisible,
          previewController.currentBody
            == "第一句。 第二句。 第三句。 第四句。 继续检查最终状态。",
          previewController.currentPanelHeight == compactPreviewHeight
    else {
        fputs("task activity preview single-paragraph window failed\n", stderr)
        exit(1)
    }
    previewController.update(item: completedPreviewItem)
    guard !previewController.isVisible else {
        fputs("task activity preview terminal dismissal failed\n", stderr)
        exit(1)
    }

    let hoverView = QuotaPanelView(
        frame: NSRect(origin: .zero, size: panelSizeForTaskRows(1))
    )
    let hoverWindow = NSWindow(
        contentRect: hoverView.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    hoverWindow.contentView = hoverView
    hoverView.pointerSide = .bottom
    hoverView.taskProgress = TaskProgressSnapshot(items: [runningPreviewItem])
    var hoveredActivity: String?
    var hoveredAnchor: NSRect?
    hoverView.onHoverRunningTask = { item, anchor in
        hoveredActivity = item?.activityText
        hoveredAnchor = anchor
    }
    hoverView.updateTaskHover(index: 0)
    guard hoveredActivity == "正在编辑文件", hoveredAnchor != nil else {
        fputs("task hover callback presentation failed\n", stderr)
        exit(1)
    }
    hoverView.taskProgress = TaskProgressSnapshot(items: [TaskProgressItem(
        title: "运行任务",
        kind: .running,
        startedAt: now,
        updatedAt: now.addingTimeInterval(2),
        activityText: "正在搜索或检查网页",
        threadID: indexedThreadID
    )])
    guard hoveredActivity == "正在搜索或检查网页" else {
        fputs("task hover callback segmented update failed\n", stderr)
        exit(1)
    }
    hoverView.taskProgress = TaskProgressSnapshot(items: [completedPreviewItem])
    guard hoveredActivity == nil, hoveredAnchor == nil else {
        fputs("task hover callback terminal dismissal failed\n", stderr)
        exit(1)
    }

    let unreadState = CodexTaskProgressReader.UnreadThreadState(
        ids: [indexedThreadID],
        isAvailable: true
    )
    let readState = CodexTaskProgressReader.UnreadThreadState(
        ids: [],
        isAvailable: true
    )
    let unavailableState = CodexTaskProgressReader.UnreadThreadState(
        ids: [],
        isAvailable: false
    )
    let completedVisibilityCases = [
        CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(-3600),
            now: now,
            unreadState: unreadState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: readState
        ),
        CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: unavailableState,
            fallbackVisibility: 120
        ),
        CodexTaskProgressReader.shouldDisplay(
            kind: .failed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(-3600),
            now: now,
            unreadState: unreadState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .failed,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: readState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(-180),
            now: now,
            unreadState: unavailableState,
            fallbackVisibility: 120
        ),
    ]
    guard completedVisibilityCases.allSatisfy({ $0 }),
          CodexTaskProgressReader.shouldDisplay(
            kind: .running,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: readState
          )
    else {
        fputs("completed task filtering failed\n", stderr)
        exit(1)
    }

    let topLevelMetadata = #"{"type":"session_meta","payload":{"thread_source":"user","source":{"cli":{}}}}"#
    let subagentMetadata = #"{"type":"session_meta","payload":{"thread_source":"subagent","source":{"subagent":{"thread_spawn":{}}}}}"#
    let automationMetadata = #"{"type":"session_meta","payload":{"thread_source":"automation","source":"vscode"}}"#
    let sourceOnlySubagentMetadata = #"{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{}}}}}"#
    let rolloutVisibilityCases = [
        CodexTaskProgressReader.isUserVisibleSessionMetadata(line: topLevelMetadata),
        !CodexTaskProgressReader.isUserVisibleSessionMetadata(line: subagentMetadata),
        !CodexTaskProgressReader.isUserVisibleSessionMetadata(line: automationMetadata),
        !CodexTaskProgressReader.isUserVisibleSessionMetadata(line: sourceOnlySubagentMetadata),
        CodexTaskProgressReader.isUserVisibleSessionMetadata(line: started),
    ]
    guard rolloutVisibilityCases.allSatisfy({ $0 }) else {
        fputs("task non-user session filtering failed\n", stderr)
        exit(1)
    }

    let truncated = TaskProgressSnapshot.displaying((0..<7).map { index in
        TaskProgressItem(
            title: "任务 \(index + 1)",
            kind: .running,
            startedAt: now,
            updatedAt: now.addingTimeInterval(Double(index))
        )
    })
    guard truncated.isScrollable,
          truncated.items.count == 7,
          truncated.items.first?.title == "任务 7",
          truncated.items.last?.title == "任务 1"
    else {
        fputs("task list scrolling data source failed\n", stderr)
        exit(1)
    }

    let completedPresentation = TaskProgressSnapshot.displaying([
        TaskProgressItem(
            title: "AI 观点运营台 · Codex Chrome 单条发布与回复",
            kind: .completed,
            startedAt: now,
            statusOverride: "最新"
        ),
        TaskProgressItem(
            title: "  AI 观点运营台 · Codex Chrome 单条发布与回复  ",
            kind: .completed,
            startedAt: now.addingTimeInterval(-300),
            statusOverride: "旧记录"
        ),
        TaskProgressItem(title: "相同标题的实时任务", kind: .running, startedAt: now),
        TaskProgressItem(title: "相同标题的实时任务", kind: .running, startedAt: now),
    ])
    guard completedPresentation.items.count == 2,
          completedPresentation.items[0].kind == .running,
          completedPresentation.items[0].title == "相同标题的实时任务",
          completedPresentation.items[1].kind == .completed,
          completedPresentation.items[1].statusText == "最新"
    else {
        fputs("task presentation deduplication failed\n", stderr)
        exit(1)
    }

    let taskSymbolCases: [(TaskProgressKind, String)] = [
        (.running, "arrow.triangle.2.circlepath"),
        (.waitingForInput, "questionmark.circle.fill"),
        (.completed, "checkmark.circle.fill"),
        (.failed, "exclamationmark.triangle.fill"),
        (.reading, "clock"),
        (.idle, "circle"),
    ]
    guard taskSymbolCases.allSatisfy({
        taskProgressSymbolName(for: $0.0) == $0.1
            && NSImage(systemSymbolName: $0.1, accessibilityDescription: nil) != nil
    }) else {
        fputs("task status system symbols failed\n", stderr)
        exit(1)
    }

    let claudeSessionID = "b687a9ef-4535-4bb4-a9d5-e692bbcdb0a6"
    let otherClaudeSessionID = "7fa9c621-795c-47e7-a570-07ee5e0b821d"
    let staleClaudeSessionID = "9fa3f2bd-788e-42e1-bcc9-d288c2e44e65"
    let tiedClaudeSessionID = "9ba02518-76d0-44e6-813c-e1330482baf7"
    let liveClaudeProcessStartIdentity = "Sun Jul 26 18:20:00 2026"
    let duplicateClaudeAgentCandidates = [
        ClaudeAgentSnapshot(
            sessionID: claudeSessionID.uppercased(),
            title: "无法精确定位的重复记录",
            workingDirectory: "/tmp/shared-project",
            processID: nil,
            processStartIdentity: nil,
            kind: .waitingForInput,
            startedAt: now,
            statusOverride: "已阻塞"
        ),
        ClaudeAgentSnapshot(
            sessionID: claudeSessionID,
            title: "可精确定位的实时记录",
            workingDirectory: "/tmp/shared-project",
            processID: 57_704,
            processStartIdentity: liveClaudeProcessStartIdentity,
            kind: .running,
            startedAt: now.addingTimeInterval(-30),
            statusOverride: nil
        ),
    ]
    let duplicateClaudeAgents = claudeAgentsBySessionID(
        duplicateClaudeAgentCandidates,
        isProcessAlive: { $0 == 57_704 }
    )
    let reversedDuplicateClaudeAgents = claudeAgentsBySessionID(
        Array(duplicateClaudeAgentCandidates.reversed()),
        isProcessAlive: { $0 == 57_704 }
    )
    let staleClaudeAgents = claudeAgentsBySessionID([
        ClaudeAgentSnapshot(
            sessionID: staleClaudeSessionID,
            title: "失效 PID 记录",
            workingDirectory: "/tmp/shared-project",
            processID: 42_424,
            processStartIdentity: "Sun Jul 26 17:00:00 2026",
            kind: .running,
            startedAt: now,
            statusOverride: nil
        ),
    ], isProcessAlive: { _ in false })
    let statusTiedClaudeAgentCandidates = [
        ClaudeAgentSnapshot(
            sessionID: tiedClaudeSessionID,
            title: "状态相同优先级",
            workingDirectory: "/tmp/shared-project",
            processID: nil,
            processStartIdentity: nil,
            kind: .waitingForInput,
            startedAt: now,
            statusOverride: "等待中"
        ),
        ClaudeAgentSnapshot(
            sessionID: tiedClaudeSessionID,
            title: "状态相同优先级",
            workingDirectory: "/tmp/shared-project",
            processID: nil,
            processStartIdentity: nil,
            kind: .waitingForInput,
            startedAt: now,
            statusOverride: "已阻塞"
        ),
    ]
    let statusTiedClaudeAgents = claudeAgentsBySessionID(
        statusTiedClaudeAgentCandidates,
        isProcessAlive: { _ in false }
    )
    let reversedStatusTiedClaudeAgents = claudeAgentsBySessionID(
        Array(statusTiedClaudeAgentCandidates.reversed()),
        isProcessAlive: { _ in false }
    )
    guard duplicateClaudeAgents == reversedDuplicateClaudeAgents,
          duplicateClaudeAgents.count == 1,
          duplicateClaudeAgents[claudeSessionID]?.processID == 57_704,
          duplicateClaudeAgents[claudeSessionID]?.title == "可精确定位的实时记录",
          staleClaudeAgents[staleClaudeSessionID]?.processID == nil,
          statusTiedClaudeAgents == reversedStatusTiedClaudeAgents
    else {
        fputs("duplicate Claude session merging failed\n", stderr)
        exit(1)
    }

    let preciseClaudeRequest = ClaudeTerminalOpenRequest(
        sessionID: claudeSessionID,
        workingDirectory: "/tmp/shared-project",
        processID: 57_704,
        processStartIdentity: liveClaudeProcessStartIdentity
    )
    let unverifiedPIDRequest = ClaudeTerminalOpenRequest(
        sessionID: claudeSessionID,
        workingDirectory: "/tmp/shared-project",
        processID: 57_704
    )
    guard claudeTerminalNavigationPlan(for: preciseClaudeRequest) == [
        .focusProcess(
            processID: 57_704,
            processStartIdentity: liveClaudeProcessStartIdentity
        ),
        .resumeSession(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/shared-project"
        ),
    ], claudeTerminalNavigationPlan(for: unverifiedPIDRequest) == [
        .resumeSession(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/shared-project"
        ),
    ], claudeTerminalNavigationPlan(for: ClaudeTerminalOpenRequest(
        sessionID: claudeSessionID,
        workingDirectory: "/tmp/shared-project",
        processID: nil
    )) == [
        .resumeSession(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/shared-project"
        ),
    ], claudeTerminalNavigationPlan(for: ClaudeTerminalOpenRequest(
        sessionID: nil,
        workingDirectory: "/tmp/shared-project",
        processID: nil
    )) == [
        .focusWorkingDirectory("/tmp/shared-project"),
    ], allowsGenericTerminalFallback(for: preciseClaudeRequest) == false,
       allowsGenericTerminalFallback(for: ClaudeTerminalOpenRequest(
           sessionID: claudeSessionID,
           workingDirectory: nil,
           processID: nil
       )) == false,
       allowsGenericTerminalFallback(for: ClaudeTerminalOpenRequest(
           sessionID: nil,
           workingDirectory: nil,
           processID: nil
       ))
    else {
        fputs("Claude terminal navigation precedence failed\n", stderr)
        exit(1)
    }

    let permissionPrompt = ClaudePermissionPrompt(
        requestID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        interactionKind: .toolApproval,
        toolName: "Bash",
        sessionID: claudeSessionID.uppercased(),
        workingDirectory: "/tmp/shared-project",
        title: "Claude 精确导航",
        message: "允许执行测试命令吗？",
        planText: nil,
        questions: [],
        originalToolInput: [:],
        suggestions: []
    )
    let sameDirectoryTaskItems = [
        TaskProgressItem(
            title: "同目录的另一条 Claude 会话",
            kind: .running,
            startedAt: now.addingTimeInterval(-60),
            source: .claudeCode,
            sessionID: otherClaudeSessionID,
            workingDirectory: "/tmp/shared-project",
            processID: 12_345,
            processStartIdentity: "Sun Jul 26 18:19:00 2026"
        ),
        TaskProgressItem(
            title: "Claude 精确导航",
            kind: .waitingForInput,
            startedAt: now,
            source: .claudeCode,
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/shared-project",
            processID: 57_704,
            processStartIdentity: liveClaudeProcessStartIdentity
        ),
    ]
    let taskOpenRequest = claudeTerminalOpenRequest(
        for: sameDirectoryTaskItems[1]
    )
    let permissionOpenRequest = claudeTerminalOpenRequest(
        for: permissionPrompt,
        taskItems: sameDirectoryTaskItems
    )
    let taskNavigationPlan = claudeTerminalNavigationPlan(for: taskOpenRequest)
    let permissionNavigationPlan = claudeTerminalNavigationPlan(
        for: permissionOpenRequest
    )
    guard taskOpenRequest == permissionOpenRequest,
          taskOpenRequest == preciseClaudeRequest,
          taskNavigationPlan == permissionNavigationPlan,
          taskNavigationPlan.contains(
              .focusWorkingDirectory("/tmp/shared-project")
          ) == false
    else {
        fputs("Claude navigation entry points diverged\n", stderr)
        exit(1)
    }

    let claudeLines = [
        #"{"type":"user","timestamp":"2026-07-25T10:00:00.000Z","message":{"role":"user","content":"兼容 Claude Code"}}"#,
        #"{"type":"assistant","timestamp":"2026-07-25T10:00:01.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"private chain"},{"type":"text","text":"正在检查 Claude 任务"}],"stop_reason":null}}"#,
    ]
    let claudeItem = ClaudeTaskProgressReader.parseTranscript(
        lines: claudeLines,
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude-project",
        processID: 57_704,
        processStartIdentity: liveClaudeProcessStartIdentity,
        activeKind: .running,
        startedAt: now.addingTimeInterval(-30),
        modificationDate: now,
        now: now
    )
    let sourceMerged = TaskProgressSnapshot.displaying([
        TaskProgressItem(
            title: "Codex 同名任务",
            kind: .running,
            startedAt: now.addingTimeInterval(-40),
            updatedAt: now.addingTimeInterval(-2)
        ),
        TaskProgressItem(
            title: "Codex 同名任务",
            kind: .running,
            startedAt: now.addingTimeInterval(-20),
            updatedAt: now,
            source: .claudeCode,
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/claude-project"
        ),
    ])
    let chainedTTY = controllingTTYFromProcessChain(
        startingAt: 90,
        directTTY: { $0 == 50 ? "/dev/ttys003" : nil },
        parentPID: {
            switch $0 {
            case 90: return 70
            case 70: return 50
            default: return nil
            }
        }
    )
    let cyclicTTY = controllingTTYFromProcessChain(
        startingAt: 90,
        directTTY: { _ in nil },
        parentPID: { $0 == 90 ? 70 : 90 }
    )
    let claudeProcessChainDetected = processChainContainsClaude(
        startingAt: 90,
        commandLine: {
            $0 == 70
                ? "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
                : "/bin/zsh"
        },
        parentPID: { $0 == 90 ? 70 : nil }
    )
    let reusedUnrelatedProcessRejected = processChainContainsClaude(
        startingAt: 90,
        commandLine: { _ in "/usr/bin/python3 unrelated-worker.py" },
        parentPID: { $0 == 90 ? 70 : nil }
    ) == false
    let selfProcessID = ProcessInfo.processInfo.processIdentifier
    let iTermTTYFocus = iTerm2FocusScript(tty: "/dev/ttys003")
    let ottyTTYFocus = ottyFocusScript(tty: "/dev/ttys003")
    let compoundClaudeResumeCommand = claudeResumeCommand(
        sessionID: claudeSessionID,
        workingDirectory: "/tmp/Claude's project",
        executablePath: "/opt/homebrew/bin/claude"
    )
    let ottyCompoundResume = compoundClaudeResumeCommand.flatMap {
        ottyResumeScript(command: $0)
    }
    let escapedCompoundClaudeResumeCommand = compoundClaudeResumeCommand.map(
        appleScriptEscapedString
    )
    let ottyQuotedResume = ottyResumeScript(command: #"printf "Claude""#)
    let terminalTTYFocus = terminalFocusScript(tty: "/dev/ttys003")
    let completedClaudeItem = TaskProgressItem(
        title: "已完成的 Claude 会话",
        kind: .completed,
        startedAt: now.addingTimeInterval(-120),
        source: .claudeCode,
        sessionID: claudeSessionID,
        workingDirectory: "/tmp/claude-project"
    )
    guard let compoundClaudeResumeCommand,
          let ottyCompoundResume,
          let escapedCompoundClaudeResumeCommand,
          let ottyQuotedResume,
          claudeItem?.source == .claudeCode,
          claudeItem?.activityText == "正在检查 Claude 任务",
          claudeItem?.activityText?.contains("private chain") == false,
          claudeItem?.sessionID == claudeSessionID,
          claudeItem?.processID == 57_704,
          claudeItem?.processStartIdentity
            == liveClaudeProcessStartIdentity,
          claudeProcessID(
              forSessionID: claudeSessionID.uppercased(),
              in: [claudeItem].compactMap { $0 }
          ) == 57_704,
          claudeItem?.canOpen == true,
          sourceMerged.items.count == 2,
          sourceMerged.items.first?.source == .claudeCode,
          normalizedTerminalTTY("ttys003") == "/dev/ttys003",
          normalizedTerminalTTY("/dev/ttys003") == "/dev/ttys003",
          normalizedTerminalTTY("??") == nil,
          normalizedTerminalTTY("../ttys003") == nil,
          chainedTTY == "/dev/ttys003",
          cyclicTTY == nil,
          claudeProcessChainDetected,
          reusedUnrelatedProcessRejected,
          codexTaskProgressRescanInterval == 5,
          taskAnimationFramesPerSecond == 8,
          taskAnimationDegreesPerTick == 36,
          !shouldRefreshClaudeAgents(
              cachedAgentCount: 0,
              hasRecentlyModifiedTranscript: false
          ),
          shouldRefreshClaudeAgents(
              cachedAgentCount: 0,
              hasRecentlyModifiedTranscript: true
          ),
          shouldRefreshClaudeAgents(
              cachedAgentCount: 1,
              hasRecentlyModifiedTranscript: false
          ),
          claudeAgentRefreshInterval(agentCount: 0) == 15,
          claudeAgentRefreshInterval(agentCount: 1)
            == taskProgressRefreshInterval,
          isClaudeCodeCommandLine("/opt/homebrew/bin/claude") == true,
          isClaudeCodeCommandLine(
              "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
          ) == true,
          isClaudeCodeCommandLine("/bin/zsh") == false,
          currentProcessStartIdentity(forProcessID: selfProcessID) != nil,
          isLiveClaudeProcess(selfProcessID) == false,
          iTermTTYFocus?.contains(
              #"if (tty of aSession as text) is "/dev/ttys003" then"#
          ) == true,
          iTermTTYFocus?.contains("tell aSession to select") == true,
          iTermTTYFocus?.contains("activate") == true,
          iTerm2FocusScript(tty: "not a tty") == nil,
          ottyTTYFocus?.contains(
              #"if (tty of aTab as text) is "/dev/ttys003" then"#
          ) == true,
          ottyTTYFocus?.contains("set selected of aTab to true") == true,
          ottyTTYFocus?.contains("activate") == true,
          ottyFocusScript(tty: "not a tty") == nil,
          ottyQuotedResume.contains(
              #"set targetTab to do script "printf \"Claude\"""#
          ),
          ottyQuotedResume.contains(" in front window") == false,
          ottyQuotedResume.contains(" in targetTab") == false,
          ottyQuotedResume.contains("set targetWindow to front window"),
          ottyQuotedResume.contains("set selected of targetTab to true"),
          ottyQuotedResume.contains("set index of targetWindow to 1"),
          ottyQuotedResume.contains("activate"),
          ottyResumeScript(command: " \n") == nil,
          ottyCompoundResume.contains(
              "set targetTab to do script \"\(escapedCompoundClaudeResumeCommand)\""
          ),
          terminalTTYFocus?.contains(
              #"if (tty of aTab as text) is "/dev/ttys003" then"#
          ) == true,
          terminalTTYFocus?.contains(
              #"set selected tab of aWindow to aTab"#
          ) == true,
          terminalTTYFocus?.contains("activate") == true,
          terminalFocusScript(tty: "not a tty") == nil,
          iTerm2FocusScript(workingDirectory: "/tmp")?.contains(
              #"tell aSession to set sessionPath to variable named "session.path""#
          ) == true,
          iTerm2FocusScript(workingDirectory: "tmp") == nil,
          iTerm2ResumeScript(command: "claude --resume test")?.contains(
              #"tell current window to create tab with default profile command "claude --resume test""#
          ) == true,
          iTerm2ResumeScript(command: "") == nil,
          ottyTabID(
              from: Data(
                  #"""
                  {"ok":true,"data":[
                    {"id":"t_other","cwd":"/tmp/other","active":true},
                    {"id":"t_claude","cwd":"/tmp/Claude's project","active":false}
                  ]}
                  """#.utf8
              ),
              workingDirectory: "/tmp/Claude's project"
          ) == "t_claude",
          ottyHasActiveTab(
              from: Data(
                  #"""
                  {"ok":true,"data":[
                    {"id":"t_active","cwd":"/tmp","active":true}
                  ]}
                  """#.utf8
              )
          ),
          ottyTabFocusArguments(tabID: "t_claude")
              == ["--json", "tab", "focus", "t_claude"],
          compoundClaudeResumeCommand
            == "cd -- '/tmp/Claude'\\''s project' && exec '/opt/homebrew/bin/claude' --resume '\(claudeSessionID)'",
          claudeResumeCommand(
            sessionID: "not-a-uuid",
            workingDirectory: "/tmp",
            executablePath: "/opt/homebrew/bin/claude"
          ) == nil,
          completedClaudeItem.canOpen,
          preferredClaudeTerminalBundleIdentifier(
              frontmostBundleIdentifier: "io.appmakes.otty",
              runningBundleIdentifiers: [
                  "io.appmakes.otty",
                  "com.googlecode.iterm2",
                  "com.apple.Terminal",
              ],
              ottyHasActiveTab: true
          ) == "io.appmakes.otty",
          preferredClaudeTerminalBundleIdentifier(
              frontmostBundleIdentifier: nil,
              runningBundleIdentifiers: [
                  "io.appmakes.otty",
                  "com.googlecode.iterm2",
                  "com.apple.Terminal",
              ],
              ottyHasActiveTab: true
          ) == "io.appmakes.otty",
          preferredClaudeTerminalBundleIdentifier(
              frontmostBundleIdentifier: "com.googlecode.iterm2",
              runningBundleIdentifiers: [
                  "io.appmakes.otty",
                  "com.googlecode.iterm2",
                  "com.apple.Terminal",
              ],
              ottyHasActiveTab: true
          ) == "com.googlecode.iterm2",
          preferredClaudeTerminalBundleIdentifier(
              frontmostBundleIdentifier: nil,
              runningBundleIdentifiers: ["io.appmakes.otty"],
              ottyHasActiveTab: false
          ) == "io.appmakes.otty",
          preferredClaudeTerminalBundleIdentifier(
              frontmostBundleIdentifier: nil,
              runningBundleIdentifiers: ["com.googlecode.iterm2"],
              ottyHasActiveTab: false
          ) == "com.googlecode.iterm2",
          preferredClaudeTerminalBundleIdentifier(
              frontmostBundleIdentifier: nil,
              runningBundleIdentifiers: ["com.apple.Terminal"],
              ottyHasActiveTab: false
          ) == "com.apple.Terminal"
    else {
        fputs("Claude task compatibility failed\n", stderr)
        exit(1)
    }

    print("task-progress-self-test: lifecycle=7/7; safe-activity=pass; updated-sort=pass; active-scroll=pass; terminal-backfill=pass; title=1/1; index=1/1; deep-link=2/2; click-hit=pass; scroll-hit=pass; refresh-hit=pass; hover-live=pass; completed-unread=pass; read-state=6/6; top-level-filter=5/5; task-dedup=pass; system-symbols=6/6; claude-source=pass; claude-public-output=pass; claude-agent-merge=order-independent+dead-pid; claude-navigation=identity-first; claude-entry-points=same-cwd; claude-terminal-focus=pid-chain+3-hosts; claude-iterm-resume=2/2; claude-otty=3/3; claude-resume=2/2")
    exit(0)
}

private func runChatBirdEditionSelfTest() -> Never {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("chatbird-edition-\(UUID().uuidString)", isDirectory: true)
    let config = directory.appendingPathComponent("config.toml")
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let initial = """
        selected-avatar-id = "codex"
        [general]
        model = "gpt"
        [desktop]
        avatar-overlay-mascot-width-px = 163
        selected-avatar-id = "custom:old-pet"
        [features]
        test = true
        """
        try initial.data(using: .utf8)?.write(to: config, options: .atomic)
        let store = ChatBirdPetSelectionStore(configURL: config)
        guard store.selectChatBird(), store.chatBirdIsSelected() else {
            throw NSError(domain: "ChatBirdEditionSelfTest", code: 1)
        }
        let chatBirdText = try String(contentsOf: config, encoding: .utf8)
        guard chatBirdText.components(separatedBy: "selected-avatar-id").count - 1 == 1,
              chatBirdText.contains("selected-avatar-id = \"custom:chatbird-nt\"")
        else {
            throw NSError(domain: "ChatBirdEditionSelfTest", code: 2)
        }
        let missingDesktop = ChatBirdPetSelectionStore.updatingDesktopSelection(
            in: "[general]\nmodel = \"gpt\"\n",
            avatarID: chatBirdPetAvatarID
        )
        guard missingDesktop.contains("[desktop]\nselected-avatar-id = \"custom:chatbird-nt\"") else {
            throw NSError(domain: "ChatBirdEditionSelfTest", code: 3)
        }
    } catch {
        fputs("ChatBird edition self-test failed: \(error)\n", stderr)
        exit(1)
    }

    print("chatbird-edition-self-test: edition=chatbird-nt pet=chatbird-nt persistence=pass duplicate-key=pass")
    exit(0)
}

private func runWeeklyQuotaSelfTest() -> Never {
    let legacy = RateLimitSnapshot(
        limitId: "codex",
        limitName: "Codex",
        primary: RateLimitWindow(
            usedPercent: 19,
            windowDurationMins: 300,
            resetsAt: 1_800_000_000
        ),
        secondary: RateLimitWindow(
            usedPercent: 42,
            windowDurationMins: 10_080,
            resetsAt: 1_800_604_800
        ),
        individualLimit: nil
    )
    let current = RateLimitSnapshot(
        limitId: "codex",
        limitName: "Codex",
        primary: RateLimitWindow(
            usedPercent: 25,
            windowDurationMins: 10_080,
            resetsAt: 1_800_604_800
        ),
        secondary: nil,
        individualLimit: nil
    )
    let retiredShortOnly = RateLimitSnapshot(
        limitId: "codex",
        limitName: "Codex",
        primary: RateLimitWindow(
            usedPercent: 7,
            windowDurationMins: 300,
            resetsAt: 1_800_000_000
        ),
        secondary: nil,
        individualLimit: nil
    )
    let metadataFree = RateLimitSnapshot(
        limitId: "codex",
        limitName: "Codex",
        primary: RateLimitWindow(
            usedPercent: 12,
            windowDurationMins: nil,
            resetsAt: 1_800_604_800
        ),
        secondary: nil,
        individualLimit: nil
    )
    let spendOnly = RateLimitSnapshot(
        limitId: "codex",
        limitName: "Codex",
        primary: nil,
        secondary: nil,
        individualLimit: SpendControlLimit(
            remainingPercent: 93,
            resetsAt: 1_800_604_800
        )
    )
    let upstreamFailure = QuotaClientError.server(
        "failed to fetch codex rate limits: private upstream response"
    )
    let emptyFailurePresentation = quotaFailurePresentation(
        for: upstreamFailure,
        hasExistingRows: false
    )
    let staleFailurePresentation = quotaFailurePresentation(
        for: upstreamFailure,
        hasExistingRows: true
    )
    let resetReferenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let resetCredits = CodexResetCreditsSnapshot(
        credits: [
            CodexResetCredit(
                id: "active",
                status: .available,
                expiresAt: resetReferenceDate.addingTimeInterval(24 * 60 * 60)
            ),
            CodexResetCredit(
                id: "expired",
                status: .available,
                expiresAt: resetReferenceDate.addingTimeInterval(-60)
            ),
            CodexResetCredit(
                id: "redeemed",
                status: .other("redeemed"),
                expiresAt: resetReferenceDate.addingTimeInterval(2 * 24 * 60 * 60)
            ),
        ],
        reportedAvailableCount: 1,
        updatedAt: resetReferenceDate
    )
    let resetCreditsPresentation = codexResetCreditsPresentation(
        snapshot: resetCredits,
        now: resetReferenceDate
    )

    guard weeklyRateLimitWindow(from: legacy)?.usedPercent == 42,
          weeklyRateLimitWindow(from: current)?.usedPercent == 25,
          weeklyRateLimitWindow(from: retiredShortOnly) == nil,
          weeklyRateLimitWindow(from: metadataFree) == nil,
          weeklyRateLimitWindow(from: spendOnly) == nil,
          quotaLevel(for: 100) == .healthy,
          quotaLevel(for: 50) == .healthy,
          quotaLevel(for: 49) == .warning,
          quotaLevel(for: 20) == .warning,
          quotaLevel(for: 19) == .critical,
          quotaLevel(for: 1) == .critical,
          quotaLevel(for: 0) == .exhausted,
          emptyFailurePresentation.errorText == "额度服务暂不可用",
          emptyFailurePresentation.statusText == "1 分钟后自动重试",
          staleFailurePresentation.errorText == nil,
          staleFailurePresentation.statusText == "1 分钟后自动重试",
          resetCredits.availableCredits(at: resetReferenceDate).map(\.id) == ["active"],
          resetCreditsPresentation.availableText == "1 次可用",
          resetCreditsPresentation.hasAvailableCredits,
          resetCreditsPresentation.expiryLines.count == 1,
          refreshInterval == 60
    else {
        fputs("weekly quota self-test failed\n", stderr)
        exit(1)
    }
    print("weekly-quota-self-test: legacy-secondary=pass current-primary=pass retired-short-window=ignored metadata-free=ignored spend-control=ignored thresholds=7/7 reset-credits=available-only failure-copy=pass stale-row=preserved refresh=60s")
    exit(0)
}

private func runClaudeQuotaSelfTest() -> Never {
    let remainingFixture = """
    Settings:  Status  Config  Usage
    Current session
    91% left
    Resets 8:30pm (Asia/Singapore)
    Current week (all models)
    93% left
    Resets Jul 30 at 12pm (Asia/Singapore)
    Current week (Fable)
    97% left
    Resets Jul 30 at 12pm (Asia/Singapore)
    """
    let usedFixture = """
    Settings: Usage
    Current session
    9% used
    Resets 8:30pm
    Current week (all models)
    7% used
    Resets Jul 30 at 12pm
    Current week (Fable)
    3% used
    Resets Jul 30 at 12pm
    """
    let withoutFableFixture = """
    Current session
    9% used
    Resets 8:30pm
    Current week (all models)
    7% used
    Resets Jul 30 at 12pm
    """
    _ = NSApplication.shared
    let providerView = QuotaPanelView(
        frame: NSRect(origin: .zero, size: panelSizeForTaskRows(1))
    )
    let providerWindow = NSWindow(
        contentRect: providerView.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    providerWindow.contentView = providerView
    providerView.pointerSide = .bottom
    var clickedProvider: QuotaProvider?
    providerView.onSelectQuotaProvider = { clickedProvider = $0 }
    let providerPointInWindow = providerView.convert(
        NSPoint(x: 135, y: 20),
        to: nil
    )
    if let event = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: providerPointInWindow,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: providerWindow.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ) {
        providerView.mouseDown(with: event)
    }

    guard let remaining = try? ClaudeQuotaParser.parse(remainingFixture),
          let used = try? ClaudeQuotaParser.parse(usedFixture),
          let withoutFable = try? ClaudeQuotaParser.parse(withoutFableFixture),
          remaining.rows.map(\.name) == ["5 小时", "周额度", "Fable"],
          remaining.rows.map(\.remainingPercent) == [91, 93, 97],
          used.rows.map(\.remainingPercent) == [91, 93, 97],
          withoutFable.rows.map(\.name) == ["5 小时", "周额度"],
          remaining.rows.allSatisfy({ $0.resetsAt != nil || $0.resetDescription != nil }),
          QuotaProvider.codex.displayName == "Codex",
          QuotaProvider.claudeCode.displayName == "Claude Code",
          QuotaProvider.allCases == [.codex, .claudeCode],
          clickedProvider == .claudeCode
    else {
        fputs("claude quota self-test failed\n", stderr)
        exit(1)
    }

    print("claude-quota-self-test: left-percent=3/3 used-percent=3/3 windows=5h+weekly+fable legacy-without-fable=pass provider-buttons=2/2 click-hit=pass")
    exit(0)
}

private func renderPreviewOnce(to outputPath: String) -> Never {
    _ = NSApplication.shared
    var previewTaskTemplates = [
        TaskProgressItem(title: "制作 ChatBird 宠物", kind: .running, startedAt: Date()),
        TaskProgressItem(title: "等待确认视觉方向", kind: .waitingForInput, startedAt: Date()),
        TaskProgressItem(
            title: "检查 Claude 运行结果",
            kind: .running,
            startedAt: Date(),
            source: .claudeCode,
            sessionID: "b687a9ef-4535-4bb4-a9d5-e692bbcdb0a6",
            workingDirectory: "/tmp"
        ),
        TaskProgressItem(title: "检查额度面板比例", kind: .running, startedAt: Date()),
        TaskProgressItem(title: "生成发布包", kind: .waitingForInput, startedAt: Date()),
    ]
    if CommandLine.arguments.contains("--preview-completed") {
        previewTaskTemplates[0] = TaskProgressItem(
            title: "检查完成状态图标",
            kind: .completed,
            startedAt: Date()
        )
    } else if CommandLine.arguments.contains("--preview-waiting") {
        previewTaskTemplates[0] = TaskProgressItem(
            title: "等待用户确认",
            kind: .waitingForInput,
            startedAt: Date()
        )
    } else if CommandLine.arguments.contains("--preview-failed") {
        previewTaskTemplates[0] = TaskProgressItem(
            title: "检查失败状态图标",
            kind: .failed,
            startedAt: Date()
        )
    }
    let countFlag = "--preview-task-count"
    let requestedPreviewCount: Int
    if let flagIndex = CommandLine.arguments.firstIndex(of: countFlag),
       CommandLine.arguments.indices.contains(flagIndex + 1),
       let parsedCount = Int(CommandLine.arguments[flagIndex + 1]) {
        requestedPreviewCount = parsedCount
    } else {
        requestedPreviewCount = 3
    }
    let previewCount = max(1, min(maximumVisibleTaskRows, requestedPreviewCount))
    let previewTasks: TaskProgressSnapshot
    if CommandLine.arguments.contains("--preview-scrollable") {
        previewTasks = TaskProgressSnapshot.displaying((0..<7).map { index in
            let isClaude = !index.isMultiple(of: 2)
            return TaskProgressItem(
                title: "活跃任务 \(index + 1)",
                kind: index == 1 ? .waitingForInput : .running,
                startedAt: Date(),
                updatedAt: Date().addingTimeInterval(Double(index)),
                source: isClaude ? .claudeCode : .codex,
                sessionID: isClaude
                    ? String(format: "b687a9ef-4535-4bb4-a9d5-%012d", index + 1)
                    : nil,
                workingDirectory: isClaude ? "/tmp" : nil
            )
        })
    } else {
        previewTasks = TaskProgressSnapshot(
            items: Array(previewTaskTemplates.prefix(previewCount))
        )
    }
    let quotaFlag = "--preview-quota"
    let previewRemaining: Int
    if let flagIndex = CommandLine.arguments.firstIndex(of: quotaFlag),
       CommandLine.arguments.indices.contains(flagIndex + 1),
       let parsedRemaining = Int(CommandLine.arguments[flagIndex + 1])
    {
        previewRemaining = max(0, min(100, parsedRemaining))
    } else {
        previewRemaining = 94
    }
    let previewPanelSize = panelSizeForTaskRows(previewTasks.rowCount)
    let view = QuotaPanelView(frame: NSRect(origin: .zero, size: previewPanelSize))
    view.pointerSide = .bottom
    let previewNow = Date()
    view.providerRemainingPercents = [
        .codex: CommandLine.arguments.contains("--preview-claude-quota")
            ? 97
            : previewRemaining,
        .claudeCode: CommandLine.arguments.contains("--preview-claude-quota")
            ? previewRemaining
            : 85,
    ]
    view.codexResetCredits = CodexResetCreditsSnapshot(
        credits: [
            CodexResetCredit(
                id: "preview-tomorrow",
                status: .available,
                expiresAt: Calendar.current.date(
                    byAdding: .hour,
                    value: 19,
                    to: previewNow
                )
            ),
            CodexResetCredit(
                id: "preview-next-week",
                status: .available,
                expiresAt: Calendar.current.date(
                    byAdding: .day,
                    value: 6,
                    to: previewNow
                )
            ),
            CodexResetCredit(
                id: "preview-later",
                status: .available,
                expiresAt: Calendar.current.date(
                    byAdding: .day,
                    value: 18,
                    to: previewNow
                )
            ),
        ],
        reportedAvailableCount: 3,
        updatedAt: previewNow
    )
    if CommandLine.arguments.contains("--preview-claude-quota") {
        view.selectedQuotaProvider = .claudeCode
        view.rows = [
            QuotaRow(
                name: "5 小时",
                remainingPercent: previewRemaining,
                resetsAt: Calendar.current.date(byAdding: .hour, value: 4, to: Date())
            ),
            QuotaRow(
                name: "周额度",
                remainingPercent: 63,
                resetsAt: Calendar.current.date(byAdding: .day, value: 5, to: Date())
            ),
            QuotaRow(
                name: "Fable",
                remainingPercent: 97,
                resetsAt: Calendar.current.date(byAdding: .day, value: 5, to: Date())
            ),
        ]
    } else {
        view.rows = [QuotaRow(
            name: "周额度",
            remainingPercent: previewRemaining,
            resetsAt: Calendar.current.date(byAdding: .day, value: 7, to: Date())
        )]
    }
    view.statusText = "12:43 更新 · 1分钟"
    view.taskProgress = previewTasks
    view.layoutSubtreeIfNeeded()

    let scale: CGFloat = 2
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(previewPanelSize.width * scale),
        pixelsHigh: Int(previewPanelSize.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("无法创建预览画布\n", stderr)
        exit(1)
    }
    bitmap.size = previewPanelSize

    view.cacheDisplay(in: view.bounds, to: bitmap)

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("无法编码预览图片\n", stderr)
        exit(1)
    }

    do {
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print(outputPath)
        exit(0)
    } catch {
        fputs("写入预览失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--print-quota") {
    printQuotaOnce()
}

if CommandLine.arguments.contains("--print-claude-quota") {
    printClaudeQuotaOnce()
}

if CommandLine.arguments.contains("--print-panel-location") {
    printPanelPlacementOnce()
}

if CommandLine.arguments.contains("--print-saved-panel-location") {
    printPanelPlacementOnce(savedStateOnly: true)
}

if CommandLine.arguments.contains("--prepare-codex-overlay-notifications") {
    prepareCodexOverlayNotifications()
}

if CommandLine.arguments.contains("--restore-codex-overlay-notifications") {
    restoreCodexOverlayNotifications()
}

if CommandLine.arguments.contains("--check-accessibility") {
    printAccessibilityStatus()
}

if CommandLine.arguments.contains("--suppress-native-activity-once") {
    suppressNativeActivityOnce()
}

if CommandLine.arguments.contains("--self-test-placement") {
    runPlacementSelfTest()
}

if CommandLine.arguments.contains("--self-test-lifecycle") {
    runLifecycleSelfTest()
}

if CommandLine.arguments.contains("--self-test-native-notification-state") {
    runNativeNotificationStateSelfTest()
}

if CommandLine.arguments.contains("--self-test-task-progress") {
    runTaskProgressSelfTest()
}

if CommandLine.arguments.contains("--self-test-chatbird-edition") {
    runChatBirdEditionSelfTest()
}

if CommandLine.arguments.contains("--self-test-weekly-quota") {
    runWeeklyQuotaSelfTest()
}

if CommandLine.arguments.contains("--self-test-claude-quota") {
    runClaudeQuotaSelfTest()
}

if CommandLine.arguments.contains("--self-test-claude-hook") {
    runClaudeHookSelfTest()
}

if CommandLine.arguments.contains("--install-claude-hook") {
    do {
        let changed = try ClaudeHookConfiguration.install()
        print(changed
            ? "ChatBird Claude Hook 已安装：\(ClaudeHookConstants.url)"
            : "ChatBird Claude Hook 已经安装")
        exit(0)
    } catch {
        fputs("安装 ChatBird Claude Hook 失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--uninstall-claude-hook") {
    do {
        let changed = try ClaudeHookConfiguration.uninstall()
        print(changed
            ? "ChatBird Claude Hook 已移除"
            : "没有找到 ChatBird Claude Hook")
        exit(0)
    } catch {
        fputs("移除 ChatBird Claude Hook 失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--print-claude-hook-status") {
    do {
        switch try ClaudeHookConfiguration.status() {
        case .installed:
            print("installed \(ClaudeHookConstants.url)")
        case .missing:
            print("missing")
        case .conflict(let handlers):
            print("conflict \(handlers.joined(separator: " | "))")
        }
        exit(0)
    } catch {
        fputs("读取 ChatBird Claude Hook 状态失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--print-panel-config") {
    printPanelConfiguration()
}

if CommandLine.arguments.contains("--print-task-progress") {
    printTaskProgressOnce()
}

if let previewFlag = CommandLine.arguments.firstIndex(of: "--render-claude-hook-preview"),
   CommandLine.arguments.indices.contains(previewFlag + 2)
{
    let kind = CommandLine.arguments[previewFlag + 1]
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[previewFlag + 2])
    do {
        try renderClaudePermissionPreview(kind: kind, to: outputURL)
        print(outputURL.path)
        exit(0)
    } catch {
        fputs("写入 Claude Hook 预览失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if let previewFlag = CommandLine.arguments.firstIndex(of: "--render-preview"),
   CommandLine.arguments.indices.contains(previewFlag + 1)
{
    renderPreviewOnce(to: CommandLine.arguments[previewFlag + 1])
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
