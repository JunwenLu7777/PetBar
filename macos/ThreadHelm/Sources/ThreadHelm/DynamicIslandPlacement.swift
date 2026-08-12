import AppKit
import CoreGraphics
import Foundation

enum DynamicIslandPresentationState: Equatable {
    case hidden
    case capsule
    case expanded(DynamicIslandTab)
}

let dynamicIslandCapsuleSize = NSSize(width: 404, height: 58)
let dynamicIslandTaskSize = NSSize(width: 820, height: 560)
let dynamicIslandConfirmationSize = NSSize(width: 820, height: 600)
let dynamicIslandQuotaSize = NSSize(width: 820, height: 470)
let dynamicIslandTopGap: CGFloat = 6
let dynamicIslandHorizontalMargin: CGFloat = 8
let dynamicIslandBottomMargin: CGFloat = 6
let dynamicIslandCapsuleDragThreshold: CGFloat = 4

struct DynamicIslandScreenParameters {
    let displayID: CGDirectDisplayID
    let frame: NSRect
    let visibleFrame: NSRect
    let safeAreaInsets: NSEdgeInsets
    let auxiliaryTopLeftArea: NSRect
    let auxiliaryTopRightArea: NSRect
}

func dynamicIslandRequestedSize(
    for state: DynamicIslandPresentationState
) -> NSSize {
    switch state {
    case .hidden, .capsule:
        return dynamicIslandCapsuleSize
    case .expanded(.tasks):
        return dynamicIslandTaskSize
    case .expanded(.confirmation):
        return dynamicIslandConfirmationSize
    case .expanded(.quota):
        return dynamicIslandQuotaSize
    }
}

func dynamicIslandFittedSize(
    requested: NSSize,
    visibleFrame: NSRect
) -> NSSize {
    NSSize(
        width: min(
            requested.width,
            max(1, visibleFrame.width - 2 * dynamicIslandHorizontalMargin)
        ),
        height: min(
            requested.height,
            max(
                1,
                visibleFrame.height
                    - dynamicIslandTopGap
                    - dynamicIslandBottomMargin
            )
        )
    )
}

func dynamicIslandFrame(
    size requested: NSSize,
    visibleFrame: NSRect,
    topGap: CGFloat = dynamicIslandTopGap
) -> NSRect {
    let size = dynamicIslandFittedSize(
        requested: requested,
        visibleFrame: visibleFrame
    )
    let top = visibleFrame.maxY - topGap
    // NSWindow normalizes global origins to whole AppKit points. Match that
    // behavior here so odd-width displays keep a stable, testable snap frame.
    return NSRect(
        x: (visibleFrame.midX - size.width / 2).rounded(.down),
        y: top - size.height,
        width: size.width,
        height: size.height
    )
}

func dynamicIslandCapsuleDragExceededThreshold(
    from start: NSPoint,
    to end: NSPoint,
    threshold: CGFloat = dynamicIslandCapsuleDragThreshold
) -> Bool {
    let deltaX = end.x - start.x
    let deltaY = end.y - start.y
    let resolvedThreshold = max(0, threshold)
    return deltaX * deltaX + deltaY * deltaY
        >= resolvedThreshold * resolvedThreshold
}

func dynamicIslandDisplayID(for screen: NSScreen) -> CGDirectDisplayID? {
    guard let number = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
    ] as? NSNumber else {
        return nil
    }
    return CGDirectDisplayID(number.uint32Value)
}

func dynamicIslandScreenContaining(
    point: NSPoint,
    screens: [NSScreen] = NSScreen.screens
) -> NSScreen? {
    screens.first { $0.frame.contains(point) }
}

func dynamicIslandScreen(
    displayID: CGDirectDisplayID?,
    screens: [NSScreen] = NSScreen.screens
) -> NSScreen? {
    guard let displayID else { return nil }
    return screens.first { dynamicIslandDisplayID(for: $0) == displayID }
}

func dynamicIslandScreenParameters(
    for screen: NSScreen
) -> DynamicIslandScreenParameters? {
    guard let displayID = dynamicIslandDisplayID(for: screen) else {
        return nil
    }
    return DynamicIslandScreenParameters(
        displayID: displayID,
        frame: screen.frame,
        visibleFrame: screen.visibleFrame,
        safeAreaInsets: screen.safeAreaInsets,
        auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea ?? .zero,
        auxiliaryTopRightArea: screen.auxiliaryTopRightArea ?? .zero
    )
}
