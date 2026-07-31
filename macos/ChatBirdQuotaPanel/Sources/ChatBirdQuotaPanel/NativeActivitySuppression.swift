//
//  NativeActivitySuppression.swift
//  ChatBirdQuotaPanel
//
//  模块职责：通过 Accessibility API 抑制 Codex 原生"活动"角标与通知气泡
//  （隐藏角标窗口、模拟菜单静音），并提供周期性的抑制监视器。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func isNativeActivityPillWindowTitle(_ value: String?) -> Bool {
    let normalized = value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    return normalized == "codex pet composition surface"
}

func shouldHideNativeActivityBadgeWindow(
    title: String?,
    hasShowActivityButton: Bool
) -> Bool {
    isNativeActivityPillWindowTitle(title) && hasShowActivityButton
}

func offscreenOrigin(
    displayBounds: [CGRect],
    windowSize: CGSize,
    margin: CGFloat = 64
) -> CGPoint? {
    guard windowSize.width.isFinite,
          windowSize.height.isFinite,
          windowSize.width > 0,
          windowSize.height > 0,
          margin.isFinite,
          margin >= 0
    else { return nil }

    let validDisplayBounds = displayBounds.filter { bounds in
        bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.width > 0
            && bounds.height > 0
    }
    guard var desktopBounds = validDisplayBounds.first else { return nil }
    for bounds in validDisplayBounds.dropFirst() {
        desktopBounds = desktopBounds.union(bounds)
    }

    let origin = CGPoint(
        x: desktopBounds.minX - windowSize.width - margin,
        y: desktopBounds.minY - windowSize.height - margin
    )
    return origin.x.isFinite && origin.y.isFinite ? origin : nil
}

func activeDisplayBounds() -> [CGRect] {
    var displayCount: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
          displayCount > 0
    else { return [] }

    var displayIDs = [CGDirectDisplayID](
        repeating: CGMainDisplayID(),
        count: Int(displayCount)
    )
    let result = displayIDs.withUnsafeMutableBufferPointer { buffer in
        CGGetActiveDisplayList(
            displayCount,
            buffer.baseAddress,
            &displayCount
        )
    }
    guard result == .success else { return [] }
    return displayIDs.prefix(Int(displayCount)).map(CGDisplayBounds)
}

func isNativeActivityToggleWindowTitle(_ value: String?) -> Bool {
    let normalized = value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    return normalized == "codex pet voice controls backing"
}

func nativeActivityToggleClickPoint(
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

enum NativeActivityPillSuppressionResult {
    case permissionRequired
    case codexNotRunning
    case badgeHidden
    case muted
    case buttonNotFound
    case actionFailed
}

enum NativeActivityBadgeWindowHidingResult {
    case alreadyHidden
    case moved
    case failed
}

enum NativeActivitySuppressionStrategy: Equatable {
    case wait
    case muteViaMenu
}

func nativeActivitySuppressionStrategy(
    notificationButtonCount: Int
) -> NativeActivitySuppressionStrategy {
    notificationButtonCount > 0 ? .muteViaMenu : .wait
}

final class NativeActivityPillSuppressor {
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

        let displayBounds = activeDisplayBounds()
        var badgeWindowHidden = false
        var badgeWindowHidingFailed = false
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
            for window in activityWindows {
                let title = attribute(
                    kAXTitleAttribute as CFString,
                    of: window
                ) as? String
                let hasShowActivityButton = showActivityButton(in: window) != nil
                guard shouldHideNativeActivityBadgeWindow(
                    title: title,
                    hasShowActivityButton: hasShowActivityButton
                ) else { continue }

                switch hideActivityBadgeWindow(
                    window,
                    displayBounds: displayBounds
                ) {
                case .alreadyHidden, .moved:
                    badgeWindowHidden = true
                case .failed:
                    badgeWindowHidingFailed = true
                }
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

        if badgeWindowHidingFailed { return .actionFailed }
        if performedMenuAction { return .muted }
        if badgeWindowHidden { return .badgeHidden }
        if foundNotification { return .actionFailed }
        return .buttonNotFound
    }

    private func showActivityButton(in root: AXUIElement) -> AXUIElement? {
        descendants(in: root, maximumElements: 1_200).first { element in
            supportsPress(element)
                && accessibilityStrings(of: element).contains(where: {
                    isShowActivityAccessibilityLabel($0)
                })
        }
    }

    private func hideActivityBadgeWindow(
        _ window: AXUIElement,
        displayBounds: [CGRect]
    ) -> NativeActivityBadgeWindowHidingResult {
        guard let size = elementSize(window),
              let targetOrigin = offscreenOrigin(
                  displayBounds: displayBounds,
                  windowSize: size
              )
        else { return .failed }

        if let position = elementPosition(window) {
            let frame = CGRect(origin: position, size: size)
            if displayBounds.allSatisfy({ !$0.intersects(frame) }) {
                return .alreadyHidden
            }
        }

        var mutableOrigin = targetOrigin
        guard let positionValue = AXValueCreate(.cgPoint, &mutableOrigin),
              AXUIElementSetAttributeValue(
                  window,
                  kAXPositionAttribute as CFString,
                  positionValue
              ) == .success
        else { return .failed }
        return .moved
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
        guard let size = elementSize(element) else {
            return .greatestFiniteMagnitude
        }
        return size.width * size.height
    }

    private func elementPosition(_ element: AXUIElement) -> CGPoint? {
        guard let value = attribute(
            kAXPositionAttribute as CFString,
            of: element
        ),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &position),
              position.x.isFinite,
              position.y.isFinite
        else { return nil }
        return position
    }

    private func elementSize(_ element: AXUIElement) -> CGSize? {
        guard let value = attribute(kAXSizeAttribute as CFString, of: element),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size),
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else { return nil }
        return size
    }
}

final class NativeActivityPillSuppressionMonitor {
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
