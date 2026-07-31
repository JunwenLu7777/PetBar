//
//  WindowStackGeometry.swift
//  ChatBirdQuotaPanel
//
//  模块职责：窗口栈几何——宠物定位结果模型、Codex 原生窗口识别
//  （mascot effect/锚点/活动堆叠/合成表面）、窗口栈枚举与遮挡判定、
//  overlay 状态文件签名与重载判定。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct LocatedPet {
    let overlayRect: NSRect
    let visibleRect: NSRect
    let panelScale: CGFloat
    let screen: NSScreen
    let source: String
}

func locatedPetGeometryDiffers(
    _ previous: LocatedPet?,
    from current: LocatedPet
) -> Bool {
    guard let previous else { return true }
    return rectDiffers(previous.visibleRect, from: current.visibleRect)
        || rectDiffers(previous.screen.visibleFrame, from: current.screen.visibleFrame)
        || abs(previous.panelScale - current.panelScale) > 0.01
}

struct MascotEffectPetGeometry {
    let visibleRect: CGRect
    let scale: CGFloat
}

func isMascotEffectWindow(
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

func isMascotAnchorWindow(
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

func isCodexPetCompositionSurfaceWindow(
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
    // window's exact bounds to intersect the ChatBird panel.
    return intersectingActivityStacks.contains { activityIndex, activity in
        if activityIndex < panelIndex {
            return true
        }
        return entries[..<panelIndex].contains { surface in
            isCodexPetCompositionSurfaceWindow(surface)
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

func mascotEffectPetGeometry(
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

struct OverlayStateFileSignature: Equatable {
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

func overlayStateNeedsReload(
    previous: OverlayStateFileSignature?,
    current: OverlayStateFileSignature?
) -> Bool {
    guard let current else { return true }
    return current != previous
}

func shouldDiscoverMascotEffectWindows(
    now: CFAbsoluteTime,
    lastDiscoveryAt: CFAbsoluteTime,
    hasCachedGenericWindow: Bool
) -> Bool {
    if !hasCachedGenericWindow || lastDiscoveryAt <= 0 || now < lastDiscoveryAt {
        return true
    }
    return now - lastDiscoveryAt >= overlayStateRefreshInterval
}
