//
//  PanelPlacement.swift
//  ChatBirdQuotaPanel
//
//  模块职责：面板相对宠物窗口的摆放计算（指针居中、14pt 间隙）与
//  面板缩放的归一化/呈现工具。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct PanelPlacement {
    let origin: NSPoint
    let pointerCenterX: CGFloat
    let actualGap: CGFloat
    let centerError: CGFloat
}

/// Keeps the legacy panel visible when Codex is running but the pet window is
/// temporarily unavailable. The fallback stays on the selected display and
/// yields to the exact pet-attached placement as soon as the locator recovers.
func detachedPanelFrame(
    panelSize: NSSize,
    screenVisibleFrame: NSRect
) -> NSRect {
    let minimumX = screenVisibleFrame.minX + panelScreenMargin
    let maximumX = max(
        minimumX,
        screenVisibleFrame.maxX - panelSize.width - panelScreenMargin
    )
    let x = maximumX

    let minimumY = screenVisibleFrame.minY + panelScreenMargin
    let maximumY = max(
        minimumY,
        screenVisibleFrame.maxY - panelSize.height - panelScreenMargin
    )
    let desiredY = screenVisibleFrame.maxY - panelSize.height - 12
    let y = min(max(desiredY, minimumY), maximumY)

    return NSRect(origin: NSPoint(x: x, y: y), size: panelSize)
}

/// Places the pointer tip on ChatBird's visible horizontal center and keeps its
/// tip exactly 14 logical points above the visible top tuft. All calculations
/// use AppKit points, so Retina and scaled displays preserve the same spacing.
func panelPlacement(
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

func normalizedPanelScale(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else { return 1 }
    return min(max(value, minimumPanelScale), maximumPanelScale)
}

func presentedPanelScale(_ value: CGFloat) -> CGFloat {
    max(normalizedPanelScale(value), minimumPresentedPanelScale)
}

func scaledPanelSize(_ baseSize: NSSize, scale: CGFloat) -> NSSize {
    let safeScale = normalizedPanelScale(scale)
    return NSSize(width: baseSize.width * safeScale, height: baseSize.height * safeScale)
}

/// 指针相对面板的朝向，供额度面板/活动预览等气泡视图复用。
enum PointerSide: Equatable {
    case left
    case right
    case bottom
}
