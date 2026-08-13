//
//  WindowStackGeometry.swift
//  ThreadHelm
//
//  模块职责：枚举窗口栈，识别 Codex 原生活动窗口，并判断它与
//  ThreadHelm 动态岛的相交和遮挡关系。
//

import AppKit
import CoreGraphics
import Darwin
import Foundation

struct WindowStackEntry {
    let number: CGWindowID
    let ownerProcessID: pid_t?
    let ownerName: String
    let name: String
    let alpha: Double
    let bounds: CGRect
}

func isCodexNativeWindowOwner(_ ownerName: String) -> Bool {
    let normalizedOwner = ownerName.lowercased()
    return normalizedOwner.contains("codex")
        || normalizedOwner.contains("chatgpt")
}

func isCodexNativeActivityStackWindow(
    _ entry: WindowStackEntry
) -> Bool {
    let normalizedName = entry.name
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    return isCodexNativeWindowOwner(entry.ownerName)
        && normalizedName == "codex pet activity stack backing"
        && entry.alpha > 0.05
        && entry.bounds.width >= 160
        && entry.bounds.width <= 900
        && entry.bounds.height >= 32
        && entry.bounds.height <= 300
}

func isCodexNativeCompositionSurfaceWindow(
    _ entry: WindowStackEntry
) -> Bool {
    let normalizedName = entry.name
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    return isCodexNativeWindowOwner(entry.ownerName)
        && normalizedName == "codex pet composition surface"
        && entry.alpha > 0.05
        && entry.bounds.width >= 160
        && entry.bounds.width <= 2_000
        && entry.bounds.height >= 80
        && entry.bounds.height <= 2_000
}

func nativeWindowOwnersMatch(
    _ lhs: WindowStackEntry,
    _ rhs: WindowStackEntry
) -> Bool {
    if let lhsPID = lhs.ownerProcessID,
       let rhsPID = rhs.ownerProcessID,
       lhsPID > 0,
       rhsPID > 0
    {
        return lhsPID == rhsPID
    }
    return lhs.ownerName.caseInsensitiveCompare(rhs.ownerName) == .orderedSame
}

func nativeActivityStackOccludesPanel(
    entries: [WindowStackEntry],
    panelWindowNumber: CGWindowID
) -> Bool {
    guard let panelIndex = entries.firstIndex(where: {
        $0.number == panelWindowNumber
    }) else { return false }
    let panelBounds = entries[panelIndex].bounds
    guard panelBounds.width > 0, panelBounds.height > 0 else { return false }

    let intersectingActivityStacks = entries.enumerated().filter { _, entry in
        isCodexNativeActivityStackWindow(entry)
            && entry.bounds.intersects(panelBounds)
    }
    guard !intersectingActivityStacks.isEmpty else { return false }

    // CGWindowListCopyWindowInfo returns windows from front to back. Newer
    // Codex builds use the backing window for the activity pill's geometry,
    // while a separate composition surface in front of the panel draws it.
    // Treat either window as the z-order signal, but require the backing
    // window's exact bounds to intersect the ThreadHelm panel.
    return intersectingActivityStacks.contains { activityIndex, activity in
        if activityIndex < panelIndex {
            return true
        }
        return entries[..<panelIndex].contains { surface in
            isCodexNativeCompositionSurfaceWindow(surface)
                && nativeWindowOwnersMatch(surface, activity)
                && surface.bounds.intersects(panelBounds)
        }
    }
}

func nativeActivityStackIntersectsPanel(
    entries: [WindowStackEntry],
    panelWindowNumber: CGWindowID
) -> Bool {
    guard let panel = entries.first(where: {
        $0.number == panelWindowNumber
    }) else { return false }
    guard panel.bounds.width > 0, panel.bounds.height > 0 else { return false }
    return entries.contains { entry in
        isCodexNativeActivityStackWindow(entry)
            && entry.bounds.intersects(panel.bounds)
    }
}

func currentWindowStackEntries() -> [WindowStackEntry] {
    let options: CGWindowListOption = [
        .optionOnScreenOnly,
        .excludeDesktopElements,
    ]
    guard let windows = CGWindowListCopyWindowInfo(
        options,
        kCGNullWindowID
    ) as? [[String: Any]] else { return [] }

    return windows.compactMap { window in
        guard let number = window[kCGWindowNumber as String] as? NSNumber,
              let ownerName = window[kCGWindowOwnerName as String] as? String,
              let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?
                .doubleValue,
              let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rawBounds)
        else { return nil }
        return WindowStackEntry(
            number: number.uint32Value,
            ownerProcessID: (window[kCGWindowOwnerPID as String] as? NSNumber)?
                .int32Value,
            ownerName: ownerName,
            name: window[kCGWindowName as String] as? String ?? "",
            alpha: alpha,
            bounds: bounds
        )
    }
}
